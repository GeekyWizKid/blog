---
title: writing-helper 深度解析：Next.js 15 流式多提供商写作助手（SSE + 统一代理）
date: 2025-09-07
tags: [LLM, Next.js, Streaming, SSE, Proxy]
categories: [技术]
draft: false
# Use the correct param name `featureimage` and a direct Unsplash image URL
featureimage: https://images.unsplash.com/photo-1752440284390-26d0527bbb9f?auto=format&fit=crop&w=1600&q=80
---

这篇文章基于源码实读，对 writing-helper 的架构与实现做“工程级”解析：如何在 Next.js 15 下，用统一代理层把 OpenAI / Grok / DeepSeek / Ollama 等提供商整合进一套流式（SSE）写作体验，并兼顾 CORS、安全与可用性。

本项目地址： [writing-helper](https://github.com/GeekyWizKid/writing-helper)

<!--more-->

## 0. 项目概览

- 技术栈：Next.js 15（App Router）、TypeScript、Tailwind、Turbopack
- 关键模块：
  - 流式代理：`src/app/api/stream-proxy/route.ts`
  - 普通代理：`src/app/api/proxy/route.ts`
  - 前端 API 客户端：`src/app/lib/api.ts`
  - API Key 管理：`src/app/lib/secureApiKey.ts`
  - 流式展示：`src/app/components/StreamingContent.tsx`

## 1. 目标与约束

- 低延迟：TTFB 小于百毫秒，首段 1s 内到达，整段逐字流式；
- 多提供商：OpenAI / xAI Grok / DeepSeek / Ollama 等统一接入，不改前端；
- 可用性：超时/断开可恢复，统一错误语义；
- 安全：Origin 白名单 + API Key 本地加密存储；
- 可维护：日志可读，问题定位简单。

## 2. 架构总览

```
Editor ──SSE──> /api/stream-proxy（CORS/映射/超时）
                  │
                  └──fetch──> 各家 API（OpenAI/Grok/DeepSeek/Ollama）
                                │
                                └─ 统一封装为 OpenAI Delta 事件
Editor ──HTTP──> /api/proxy（直返 JSON、统一字段）
```

## 3. 流式代理（SSE）：把不同厂商流统一成 OpenAI Delta

文件：`src/app/api/stream-proxy/route.ts:1`

关键点：
- CORS 白名单通过 `ALLOWED_ORIGINS` 环境变量控制；OPTIONS/POST 都设置 `Access-Control-Allow-*`。
- 将请求体规范化为“流式”格式：非 Ollama 直接 `{...body, stream:true}`；Ollama 重写为 `/api/generate` 且构造 `{model,prompt,system,stream}`。
- IPv6/localhost 兼容：`localhost` → `127.0.0.1`。
- 读取上游响应流，逐行拆包并转译：
  - Ollama：把 `{response, done}` 转换为 OpenAI 的 `chat.completion.chunk` 事件，结束时注入 `[DONE]`。
  - OpenAI 兼容：识别 `data: {json}` / `[DONE]` 并透传。

片段：

```ts
// src/app/api/stream-proxy/route.ts:112
const stream = new ReadableStream({ async start(controller) {
  const reader = response.body?.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    buffer = lines.pop() || '';
    for (const line of lines) {
      const s = line.trim();
      if (!s || s === 'data: [DONE]') continue;
      if (isOllama) {
        const o = JSON.parse(s);
        if (o.response) {
          const chunk = { object:'chat.completion.chunk', choices:[{ delta:{ content:o.response } }] };
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(chunk)}\n\n`));
        }
        if (o.done) controller.enqueue(encoder.encode('data: [DONE]\n\n'));
      } else if (s.startsWith('data: ')) {
        const data = JSON.parse(s.slice(6));
        controller.enqueue(encoder.encode(`data: ${JSON.stringify(data)}\n\n`));
      }
    }
  }
}})
```

## 4. 普通代理：统一非流式 JSON 响应

文件：`src/app/api/proxy/route.ts:1`

关键点：
- 同样的 CORS 白名单与 10 分钟 Abort 超时（Vercel 部署时 `maxDuration=60`）。
- 对 Ollama，把非 `/api/generate` 的 URL 重写；解析返回的 `response/prompt_eval_count/eval_count`，再封装成 OpenAI `chat.completion` 统一结构。
- 对非 Ollama，原样透传 JSON，同时设置 CORS 响应头。
- 常见错误分支：超时（504）、连接失败（502，ECONNREFUSED）、一般错误（502）。

## 5. 前端客户端：双模（流式/直返）+ Provider 自适应

文件：`src/app/lib/api.ts:1`

- Provider 检测：通过 URL 包含词判定 grok/xai、ollama/11434、deepseek，否则视作 OpenAI 兼容。
- 流式：`generateContentStream()` 请求 `/api/stream-proxy`，解析 `data: {json}` 行，并把 `choices[0].delta.content` 片段推给 UI。
- 非流式：`generateContent()` 请求 `/api/proxy`，对多种字段位尝试提取正文：`choices[0].message.content` / `message.content` / `content` / `output` / `response` / `text` / 纯字符串，尽量容错。
- 另有“润色功能”与“简历生成”的同构实现（`polish*` / `resumeApi.ts`）。

```ts
// src/app/lib/api.ts（流式部分）
const response = await fetch('/api/stream-proxy', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ targetUrl: llmApiUrl, headers, body: requestBody, isOllama })
});
// 逐行拆包、识别 [DONE]，把 delta.content 交给 onChunk
```

## 6. UI：打字机 + 自动滚动 + 渲染 Markdown

文件：`src/app/components/StreamingContent.tsx:1`

- 新 token 到达时采用“差量打字机”动画（20ms/字符），减少抖动与 CPU 开销；
- 自动滚动到底部；完成后关闭光标闪烁；
- 使用 `react-markdown + remark-gfm` 渲染输出。

## 7. 安全：Origin 白名单 + Key 加密存储（客户端）

- CORS：两个 API Route 使用 `ALLOWED_ORIGINS`；如果传入 `origin` 不在白名单，则回退到白名单首个域名；
- API Key 本地管理：`src/app/lib/secureApiKey.ts:1`
  - 基于“浏览器指纹”生成 16 字节 key（UA/屏幕分辨率/时区）；
  - XOR + base64 简单加密；sessionStorage 为主，可选 localStorage 记住 7 天；
  - 过期自动清理；支持多 provider；提供安全提醒。

说明：这是“防君子不防小人”的浏览器端加密，主要目的避免明文落地与误泄露，更强需求请结合服务端 KMS。

## 8. 可靠性细节与可用性小招

- 超时与中断：两个路由都用 `AbortController` 做 10 分钟上游超时，Vercel 限额下 `maxDuration=60`，超时返回 504；
- IPv4 强制：把 `localhost` 替换为 `127.0.0.1`，规避某些环境下 IPv6 解析/代理异常；
- Ollama URL 归一：若传入不是 `/api/generate`，自动修正，减少用户配置心智；
- 错误可读性：代理侧记录 `status + errorText`，前端展示精简消息；流模式中也会注入 error 事件为 UI 兜底。

## 9. 可改进建议（Roadmap）

- SSE 事件封装：为非 OpenAI 兼容流增加 `event: token` / `event: done`，减少前端解析分支；
- 速率控制：在 `/api/stream-proxy` 增加 per-IP 简易限流，避免公共部署被滥用；
- Content-Security-Policy：对外部脚本/连接做严格白名单（connect-src），配合 `ALLOWED_ORIGINS`；
- 观测：在服务端为流建立基本指标（首 token 延迟/总时延/断流计数）；
- 提示工程：把“写作风格 JSON”做成可持久化模板，附可视化编辑器。

---

结语：writing-helper 用“统一代理 + SSE”的方式把多提供商揉进一套顺手的创作体验里。上游差异被很好地在服务端抹平，前端只需专注“逐字渐显 + Markdown 渲染”。这是一套稳健、可扩展、可复用的最小可行架构。

