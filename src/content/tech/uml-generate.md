---
title: "uml-generate 深度解析：用多厂商流式 LLM 一键生成 PlantUML"
description: "拆解 uml-generate 的工程实现：如何在纯前端环境下，串起多家 LLM 的流式输出，并将结果即时转译为可编辑、可导出的 PlantUML 图表"
date: 2025-09-07
tags: ["UML", "PlantUML", "Streaming", "LLM", "Frontend"]
image: "https://images.unsplash.com/photo-1527430253228-e93688616381?auto=format&fit=crop&w=1600&q=80"
---

本文基于源码实读，拆解 uml-generate 的工程实现：如何在"纯前端"环境下，串起多家 LLM 的流式输出，并将结果即时转译为可编辑、可导出的 PlantUML 图表。

项目地址： https://github.com/GeekyWizKid/uml-generate

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

## 多提供商流式适配

统一的 Provider registry 定义了 URL、请求头、请求体格式、响应提取与是否支持流式：

- OpenAI/DeepSeek/Kimi：OpenAI 兼容
- Anthropic Claude：事件型流
- Gemini/Qwen：非流式

流式解析的核心在 `generateUMLStream()`：
- OpenAI 兼容：行以 `data: {json}` 到达，取 `choices[0].delta.content`
- Claude：事件型流，识别 `type=content_block_delta` 的 `delta.text`，`message_stop` 收尾
- Gemini/Qwen：仅非流式，走常规请求

## 提示工程（Prompt）

`buildUMLPrompt()` 明确要求输出"六段结构"，并必须包含三类 UML 图（顺序、活动、状态），且强制使用 PlantUML 语法、不加 Markdown 围栏：

- 第一部分：核心要点与假设
- 第二、三、四部分：分别是顺序图、活动图、状态图，必要时以 TODO 占位
- 第五部分：占位符清单
- 第六部分：迭代建议
- 图块必须使用 `@startuml` 与 `@enduml` 包裹，便于解析与渲染

这种"强结构 + 最小必要图"策略，能在素材不完备时仍保持产出可用，并方便后续增量补齐。

## PlantUML 渲染与回退

前端使用 `plantuml-encoder` 将 UML 源码压缩为 URL 片段，然后依次尝试多台服务器：

- 本地 Docker：`http://localhost:8080/svg/…`
- 第三方：`https://plantuml-server.kkeisuke.dev/svg/…`
- 官方：`https://www.plantuml.com/plantuml/svg/…`

功能细节：
- 放大预览：Portal 模态框
- 导出：SVG 直接保存；PNG 通过 Canvas 将 SVG 树转成位图
- 内嵌编辑：弹窗修改 PlantUML 代码后重新渲染

## 小结

uml-generate 在纯前端实现了"多提供商流式生成 + PlantUML 即时渲染"的最小可用闭环。其工程价值在于：

- 通过 Provider 适配器，抹平各家流式差异
- 通过多服务器回退，显著提升渲染稳定性
- 通过强约束 Prompt，让输出结构规整、便于解析

如果你的场景需要"更强安全"或"无跨域"，可以将本项目的前端 UX 与服务端代理结合，形成企业内可落地的"UML 生成助手"。
