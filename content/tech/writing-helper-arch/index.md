---
title: 写作助手 writing-helper 架构笔记（多模型、流式、低延迟）
date: 2025-09-07
tags: [LLM, Next.js, Edge, Streaming]
categories: [技术]
draft: false
# Use the correct param name `featureimage` and a direct Unsplash image URL
featureimage: https://images.unsplash.com/photo-1752440284390-26d0527bbb9f?auto=format&fit=crop&w=1600&q=80
---

这篇文章系统记录 writing-helper 的核心设计：如何在“多模型可替换、端到端低延迟、逐字流式”的约束下，把“写作助手”做成真正可用的生产组件。

本项目地址： [writing-helper](https://github.com/GeekyWizKid/writing-helper)

<!--more-->

**目标与约束**
- 低延迟：TTFB < 150ms，首段 1s 内到达，整段流式输出；
- 多模型：OpenAI / Anthropic / Google / 本地大模型 可热切换，统一协议；
- 高可用：降级与回退（fallback）、超时保护、断路器；
- 可控风格：语气/结构/长度可配置，输出结构化；
- 经济可控：按 token 成本预算路由，缓存热门请求。

**架构概览**
```
Editor ──SSE──> Edge Route (Auth/参数/限流)
                  │
                  └──RPC──> Node Router (路由/并发/超时/熔断)
                                 │
                                 ├─ Provider(OpenAI)
                                 ├─ Provider(Anthropic)
                                 ├─ Provider(Gemini)
                                 └─ Provider(Local/Serverless)
                              ↘  Cache/Quota/Tracing
```

## 1. Provider 抽象与路由

统一签名只暴露“可迭代的流”，避免上层感知不同 SDK/协议差异：

```ts
export type ChatMessage = { role: 'system'|'user'|'assistant', content: string }
export type Stream<T> = AsyncIterable<T>

export interface ChatOptions {
  model?: string
  timeoutMs?: number
  maxTokens?: number
  temperature?: number
  meta?: Record<string, string>
}

export interface Provider {
  name: string
  costPer1kTokens: number
  supports: { images?: boolean; json?: boolean; tools?: boolean }
  chat(messages: ChatMessage[], opt?: ChatOptions): Stream<string>
}
```

路由策略样例：先按“预算/功能”筛选备选 Provider，再按健康度与历史 P95 延迟加权选择。

```ts
type Health = { p95: number; failureRate: number }

export function pickProvider(
  providers: Provider[],
  require: Partial<Provider['supports']>,
  budget: number,
  health: Map<string, Health>
): Provider {
  const candidates = providers
    .filter(p => Object.entries(require).every(([k, v]) => !v || (p.supports as any)[k]))
    .filter(p => p.costPer1kTokens <= budget)
  candidates.sort((a, b) => (health.get(a.name)?.p95 ?? 9e9) - (health.get(b.name)?.p95 ?? 9e9))
  return candidates[0] ?? providers[0]
}
```

## 2. 真正的流式：端到端 SSE

在边缘/Node 均保持“背压友好”的 Reader → Writer 管道：

```ts
// Edge Route (Next.js App Router)
export async function POST(req: Request) {
  const { messages, opt } = await req.json()
  const provider = pickProvider(/*...*/)

  const stream = new ReadableStream({
    async start(controller) {
      const encoder = new TextEncoder()
      const start = Date.now()
      try {
        for await (const token of provider.chat(messages, opt)) {
          // 以 SSE 事件传输，保持心跳
          controller.enqueue(encoder.encode(`data: ${token}\n\n`))
        }
        controller.enqueue(encoder.encode('event: done\n\n'))
        controller.close()
      } catch (e) {
        controller.enqueue(encoder.encode(`event: error\ndata: ${String(e)}\n\n`))
        controller.close()
      } finally {
        console.log('ttfb(ms)=', Date.now() - start)
      }
    }
  })

  return new Response(stream, {
    headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' }
  })
}
```

客户端渐显：

```ts
const res = await fetch('/api/generate', { method: 'POST', body })
const reader = res.body!.getReader()
const decoder = new TextDecoder()
let buf = ''
for (;;) {
  const { value, done } = await reader.read()
  if (done) break
  buf += decoder.decode(value, { stream: true })
  for (const line of buf.split('\n\n')) {
    if (!line.startsWith('data: ')) continue
    const token = line.slice(6)
    editor.chain().insertContent(token).run()
  }
}
```

## 3. Prompt 工程与可复用模板

把“结构/语气/引用”抽象为参数，生成“半结构化提示”：

```ts
type Style = { tone: 'explainer'|'academic'|'news'; structure: 'pyramid'|'faq'|'outline'; cite?: boolean }

export function buildPrompt(input: { topic: string; bullets?: string[] }, style: Style) {
  return [
    { role: 'system', content: `你是严谨的中文写作者，优先事实，其次文采。` },
    { role: 'user', content: [
        `主题: ${input.topic}`,
        style.bullets ? `要点: ${style.bullets?.join('；')}` : '',
        `输出: 使用 ${style.structure} 结构，段落短句，关键术语中文+英文。`,
        style.cite ? `若引用数据, 给出链接 [标题](URL)` : ''
      ].filter(Boolean).join('\n') }
  ] as ChatMessage[]
}
```

## 4. 限流、重试与熔断

按 Provider 的 TPM（tokens per minute）进行漏桶限流，异常时指数退避并熔断：

```ts
import pLimit from 'p-limit'

const limit = pLimit(4) // 并发

async function withRetry<T>(f: () => Promise<T>, max = 3) {
  let n = 0, lastErr: unknown
  while (n++ < max) {
    try { return await f() } catch (e) {
      lastErr = e
      await new Promise(r => setTimeout(r, 200 * 2 ** (n - 1)))
    }
  }
  throw lastErr
}
```

## 5. 成本与缓存

- 基于 Prompt+上下文 哈希的结果缓存，命中直接重放流（服务器端把 token 流录制为 NDJSON）；
- 结合“语义缓存”（embedding 近似），对高度相似输入复用结论段落；
- 在 Edge 记录每次请求的 token 用量、单价与估算成本，超预算路由到更便宜模型。

## 6. 监控与可观测

- 指标：TTFB、首 50 个 token 延迟、整流耗时、失败率、每 Provider 的 P50/P95、SSE 断流次数；
- Trace：一次生成跨 Edge→Node→Provider 的分布式追踪，便于查抖动；
- 日志脱敏：屏蔽 Access Token/用户私密输入。

## 7. 安全与合规

- 输入校验（长度、非法控制字符）；
- 输出护栏（违禁词、URL 白名单、外链剔除）；
- 审计与配额：每用户用量、最大并发与速率限制。

## 8. Roadmap

- 工具调用（检索/计算/翻译）统一抽象；
- 协作写作：多人光标、段落锁；
- 模板市场：风格与结构可分享。

结语：把“低延迟流式 + 多提供商抽象 + 成本/健康路由”做好，写作助手才能从 Demo 变产品。
