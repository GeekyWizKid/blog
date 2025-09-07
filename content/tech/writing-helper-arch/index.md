---
title: 写作助手 writing-helper 架构笔记（多模型、流式、低延迟）
date: 2025-09-07
tags: [LLM, Next.js, Edge, Streaming]
categories: [技术]
draft: false
---

这篇文章讨论我的项目 [writing-helper](https://github.com/GeekyWizKid/writing-helper)：一个基于 Next.js 的多模型写作助手，支持 OpenAI、Claude、Gemini 等，强调“可用性”和“低延迟”。

我将从“问题—方案—实现—坑点—扩展阅读”五个方面说明，风格参考阮一峰老师的科普式写法。

<!--more-->

## 一、问题

- 写作需要结构化思考：标题、提纲、语气、证据链接、引用格式。
- 多模型兼容：不同供应商 SDK、鉴权、流式协议并不一致。
- 海外 API 在国内的“延迟”和“抖动”。
- 风格可控：写作人希望“像谁写的一样”。

## 二、方案

1) 抽象一层 `LLM Provider Adapter`：统一 `chat(messages, options) => AsyncIterable<Tokens>`。

2) 采用 Next.js App Router + Edge Runtime（能用就用），前置到边缘节点，降低 TTFB；回源写“服务端代理”。

3) Prompt 模板化：系统提示 + 结构化约束（JSON/Markdown/Schema），可插拔“写作风格”。

4) Streaming：SSE/FetchReader 推送到浏览器，编辑器侧渐显，提高主观速度。

5) 限流与重试：Provider 级别实现 `retry(backoff)` 与 `circuit-breaker`，并记录 `quota`。

## 三、实现要点

### 1. Provider 适配层

```ts
// 统一签名，屏蔽 SDK 差异
export interface LLMProvider {
  name: string
  chat: (messages: ChatMessage[], opt?: ChatOptions) => AsyncIterable<string>
}

// 以 OpenAI 为例
export const openaiProvider: LLMProvider = {
  name: 'openai',
  async *chat(messages, opt) {
    const res = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${opt?.apiKey}` , 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: opt?.model ?? 'gpt-4o-mini', stream: true, messages })
    })
    for await (const chunk of readSSE(res.body)) {
      yield chunk.data
    }
  }
}
```

要点：所有 Provider 都返回 `AsyncIterable<string>`，上层只关心“流”。

### 2. Edge + 代理

- Edge Route 负责鉴权、参数校验、快速返回首包（TTFB）。
- Node Route 作为“回源代理”，处理长尾（重试、熔断、日志）。

```
Browser ──SSE──> Edge (校验/预处理) ──RPC──> Node(Provider代理/重试)
```

### 3. 模板与风格

把“风格”拆成可组合的片段：

- `tone`: 正式/科普/新闻/学术
- `structure`: 金字塔/倒金字塔/FAQ/术语表
- `devices`: 比喻、类比、反例

```ts
const template = renderPrompt({
  tone: 'explainer',
  structure: 'pyramid',
  devices: ['analogy', 'counterexample']
})
```

### 4. 流式传输

浏览器端用 `ReadableStream` + `TextDecoder`，边读边写入编辑器（ProseMirror/TipTap）：

```ts
const res = await fetch('/api/generate', { method: 'POST', body })
for await (const token of readSSE(res.body)) editor.chain().insertContent(token).run()
```

### 5. 限流与重试

实现按 Provider 的 `token per minute` 与并发数控制：

```ts
const limiter = pLimit(3)
await limiter(() => retryWithExponentialBackoff(() => provider.chat(msgs)))
```

## 四、坑点

- SSE 与反向代理：某些 CDN 会合并/缓存流，务必关闭。
- 跨区域延迟：建议国内边缘 + 海外代理双通道，按 RTT 动态切换。
- 模板漂移：风格过强会牺牲事实密度，需提供“事实优先模式”。

## 五、扩展阅读

- Next.js Edge Runtime 指南
- OpenAI/Anthropic/Gemini Streaming 协议差异
- ProseMirror/Tiptap 流式协作实践
