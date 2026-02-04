---
title: "writing-helper 深度解析：Next.js 15 流式多提供商写作助手"
description: "如何在 Next.js 15 下，用统一代理层把 OpenAI / Grok / DeepSeek / Ollama 等提供商整合进一套流式（SSE）写作体验"
date: 2025-09-07
tags: ["LLM", "Next.js", "Streaming", "SSE", "Proxy"]
image: "https://images.unsplash.com/photo-1752440284390-26d0527bbb9f?auto=format&fit=crop&w=1600&q=80"
---

这篇文章基于源码实读，对 writing-helper 的架构与实现做"工程级"解析：如何在 Next.js 15 下，用统一代理层把 OpenAI / Grok / DeepSeek / Ollama 等提供商整合进一套流式（SSE）写作体验，并兼顾 CORS、安全与可用性。

本项目地址： [writing-helper](https://github.com/GeekyWizKid/writing-helper)

## 0. 项目概览

- 技术栈：Next.js 15（App Router）、TypeScript、Tailwind、Turbopack
- 关键模块：
  - 流式代理：`src/app/api/stream-proxy/route.ts`
  - 普通代理：`src/app/api/proxy/route.ts`
  - 前端 API 客户端：`src/app/lib/api.ts`
  - API Key 管理：`src/app/lib/secureApiKey.ts`
  - 流式展示：`src/app/components/StreamingContent.tsx`

## 1. 目标与约束

- 低延迟：TTFB 小于百毫秒，首段 1s 内到达，整段逐字流式
- 多提供商：OpenAI / xAI Grok / DeepSeek / Ollama 等统一接入，不改前端
- 可用性：超时/断开可恢复，统一错误语义
- 安全：Origin 白名单 + API Key 本地加密存储
- 可维护：日志可读，问题定位简单

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

关键点：
- CORS 白名单通过 `ALLOWED_ORIGINS` 环境变量控制
- 将请求体规范化为"流式"格式
- IPv6/localhost 兼容：`localhost` → `127.0.0.1`
- 读取上游响应流，逐行拆包并转译

```ts
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

## 4. 前端客户端：双模（流式/直返）+ Provider 自适应

- Provider 检测：通过 URL 包含词判定 grok/xai、ollama/11434、deepseek，否则视作 OpenAI 兼容
- 流式：`generateContentStream()` 请求 `/api/stream-proxy`，解析 `data: {json}` 行
- 非流式：`generateContent()` 请求 `/api/proxy`，尽量容错

## 5. UI：打字机 + 自动滚动 + 渲染 Markdown

- 新 token 到达时采用"差量打字机"动画（20ms/字符），减少抖动与 CPU 开销
- 自动滚动到底部；完成后关闭光标闪烁
- 使用 `react-markdown + remark-gfm` 渲染输出

## 6. 安全：Origin 白名单 + Key 加密存储

- CORS：两个 API Route 使用 `ALLOWED_ORIGINS`
- API Key 本地管理：基于"浏览器指纹"生成 16 字节 key，XOR + base64 简单加密

## 7. 可靠性细节

- 超时与中断：两个路由都用 `AbortController` 做 10 分钟上游超时
- IPv4 强制：把 `localhost` 替换为 `127.0.0.1`
- Ollama URL 归一：自动修正，减少用户配置心智

---

结语：writing-helper 用"统一代理 + SSE"的方式把多提供商揉进一套顺手的创作体验里。上游差异被很好地在服务端抹平，前端只需专注"逐字渐显 + Markdown 渲染"。这是一套稳健、可扩展、可复用的最小可行架构。
