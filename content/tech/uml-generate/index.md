---
title: uml-generate 深度解析：用多厂商流式 LLM 一键生成 PlantUML（前端纯实现）
date: 2025-09-07
tags: [UML, PlantUML, Streaming, LLM, Frontend]
categories: [技术]
draft: false
featureimage: https://images.unsplash.com/photo-1527430253228-e93688616381?auto=format&fit=crop&w=1600&q=80
---

本文基于源码实读，拆解 uml-generate 的工程实现：如何在“纯前端”环境下，串起多家 LLM 的流式输出，并将结果即时转译为可编辑、可导出的 PlantUML 图表。

项目地址： https://github.com/GeekyWizKid/uml-generate

<!--more-->

## 架构总览

纯前端 React + Vite 应用，直接请求各家 LLM API（支持流式），解析出文本中的 `@startuml ... @enduml` 片段，交由 PlantUML 渲染。

```
UI(App.jsx)
  ├─ 输入素材/选择 Provider/流式开关
  ├─ 文本输出（含生成中实时区域）
  └─ UML 输出（PlantUMLRenderer）

services/api.js
  ├─ Provider 适配（OpenAI/Claude/DeepSeek/Kimi/Gemini/Qwen/自定义）
  ├─ 普通/流式生成（统一回调增量文本）
  └─ Prompt 规范（顺序图/活动图/状态图 + 假设与占位符）

PlantUMLRenderer.jsx
  ├─ PlantUML 编码 + 多服务器回退（本地/第三方/官方）
  ├─ SVG/PNG 导出、复制代码、放大预览
  └─ 内嵌编辑器（编辑后局部替换并重新渲染）
```

关键文件：
- `src/App.jsx:1`：主页面（输入、选择提供商、流式开关、结果展示）
- `src/services/api.js:1`：统一调用层（多 Provider + 流式解析）
- `src/components/PlantUMLRenderer.jsx:1`：PlantUML 渲染与工具链

## 多提供商流式适配

统一的 Provider registry 定义了 URL、请求头、请求体格式、响应提取与是否支持流式：
- `src/services/api.js:4`（OpenAI/DeepSeek/Kimi，OpenAI 兼容）
- `src/services/api.js:19`（Anthropic Claude）
- `src/services/api.js:46`（Gemini，非流式）
- `src/services/api.js:64`（通义千问，非流式）
- `src/services/api.js:81`（自定义）

流式解析的核心在 `generateUMLStream()`：
- OpenAI 兼容（OpenAI/DeepSeek/Kimi）：行以 `data: {json}` 到达，取 `choices[0].delta.content`（`src/services/api.js:333`）。
- Claude：事件型流，识别 `type=content_block_delta` 的 `delta.text`，`message_stop` 收尾（`src/services/api.js:347`）。
- Gemini/Qwen：仅非流式，走 `generateUML()` 常规请求。

每次增量内容通过回调聚合到 `fullContent` 并回绑到 UI（`src/App.jsx:56` 流式状态管理）。

## 提示工程（Prompt）

`buildUMLPrompt()` 明确要求输出“六段结构”，并必须包含三类 UML 图（顺序、活动、状态），且强制使用 PlantUML 语法、不加 Markdown 围栏：
- 位置：`src/services/api.js:103`
- 重点：
  - 第一部分：核心要点与假设；
  - 第二、三、四部分：分别是顺序图、活动图、状态图，必要时以 TODO 占位；
  - 第五部分：占位符清单；第六部分：迭代建议；
  - 图块必须使用 `@startuml` 与 `@enduml` 包裹，便于解析与渲染。

这种“强结构 + 最小必要图”策略，能在素材不完备时仍保持产出可用，并方便后续增量补齐。

## PlantUML 渲染与回退

前端使用 `plantuml-encoder` 将 UML 源码压缩为 URL 片段，然后依次尝试多台服务器：
- 本地 Docker：`http://localhost:8080/svg/…`（`start-plantuml.sh` 快速拉起）
- 第三方：`https://plantuml-server.kkeisuke.dev/svg/…`
- 官方：`https://www.plantuml.com/plantuml/svg/…`

实现位于 `src/components/PlantUMLRenderer.jsx:22`：
- 逐个 `fetch`，30 秒超时（`AbortSignal.timeout(30000)`）。
- 命中 `<svg` 即视为成功，失败则继续回退（`src/components/PlantUMLRenderer.jsx:41`）。
- 渲染失败时提供外链（SVG/PNG/在线编辑）与源码查看（`src/components/PlantUMLRenderer.jsx:152`）。

功能细节：
- 放大预览：Portal 模态框（`src/components/PlantUMLRenderer.jsx:296`）。
- 导出：SVG 直接保存；PNG 通过 Canvas 将 SVG 树转成位图（`src/components/PlantUMLRenderer.jsx:78`）。
- 内嵌编辑：弹窗修改 PlantUML 代码后重新渲染，并仅替换被修改的 `@startuml ... @enduml` 块（`src/components/PlantUMLRenderer.jsx:238`）。

## UI 与交互

- 流式开关（`src/App.jsx:43`）：便于预览生成进度、降低长文本超时概率。
- 多 Provider 选择（`src/App.jsx:156`）与 Key 检查（`src/App.jsx:65`）。
- 文本区与图表区实时联动：边生成边渲染（`src/App.jsx:322` 与 `src/App.jsx:388`）。

## 安全与限制

- API Key 存储在 `localStorage`（`api.js:getStoredApiKeys()`），属于“便利优先”的本地存储方案；若面向公网部署，建议：
  - 后端代理签名请求，前端不直带 Key；
  - 或至少做浏览器侧加密与过期（参考 writing-helper 里的 `secureApiKey.ts` 思路）。
- CORS 由各厂商 API 决定（本项目纯前端，不提供自有代理）。若遇跨域限制，可临时走本地反向代理或 Vercel/Cloudflare Worker。
- PlantUML 外部服务依赖网络环境；生产推荐自建 Docker 服务（仓库已提供 `start-plantuml.sh`）。

## 体验建议（可以做的增强）

- 增加“类图/组件图”可选生成；
- 对流式内容做“增量提取”避免重复回渲染全部 SVG；
- 导出一键打包（Markdown + 图片）；
- 引入 simple rate limit（每秒最多 N 次生成），规避误触发封禁；
- 允许自定义 PlantUML 主题与样式变量。

## 小结

uml-generate 在纯前端实现了“多提供商流式生成 + PlantUML 即时渲染”的最小可用闭环。其工程价值在于：
- 通过 Provider 适配器，抹平各家流式差异；
- 通过多服务器回退，显著提升渲染稳定性；
- 通过强约束 Prompt，让输出结构规整、便于解析。

如果你的场景需要“更强安全”或“无跨域”，可以将本项目的前端 UX 与服务端代理结合，形成企业内可落地的“UML 生成助手”。

