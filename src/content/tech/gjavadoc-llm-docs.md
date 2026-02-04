---
title: "GJavaDoc 深度解析：在 IDEA 内把遗留 Java 代码清理出可用接口文档"
description: "基于源码逐行阅读，对 GJavaDoc 的设计与实现做一份工程级的深度解析"
date: 2025-09-07
tags: ["IntelliJ Plugin", "Kotlin", "PSI", "WALA", "LLM", "文档工程"]
image: "https://images.unsplash.com/photo-1518779578993-ec3579fee39f?auto=format&fit=crop&w=1600&q=80"
---

项目地址：[GJavaDoc](https://github.com/GeekyWizKid/GJavaDoc)

本文基于源码逐行阅读的结果，对 GJavaDoc 的设计与实现做一份"工程级"的深度解析：为什么这样设计、关键权衡是什么、哪里容易踩坑，以及如何把它用在你自己的遗留项目里。

核心策略一句话概括——"事实交给程序，表达交给模型"。把能确定的事实（入口、签名、相关类型、代码片段、模块归属、历史产物）用静态分析和 PSI 拿稳，再让 LLM 按强约束的提示把事实"讲清楚"。这样文档才稳定、可复现、可增量、可并发生成。

## 1. 总体架构（IDE 内的流水线）

- 插件骨架：Tool Window + 后台任务，配置使用 IntelliJ 的 `PersistentStateComponent` 保存
- 任务调度：`QueueManager` 用"RPS 限速 + 信号量并发 + 有界队列 + 重试 + 心跳"的组合保证流畅与可控
- 增量：`ExistingOutputs` 只认 `docs/`，以"文件名去时间戳"的方式判重

## 2. 入口识别：注解扫描的正确打开方式

从 Settings 读取注解列表（支持逗号/空白分隔，自动去掉前导 @），在 `GlobalSearchScope` 内遍历 Java 文件→类→方法，命中类注解或方法注解即视为入口。

细节：
- 用 `PsiDocumentManager` 计算行号，后续用于"锚点切片"和"上下文展示"
- 支持限制到某个 Module 的搜索范围，与工具窗的模块选择联动

## 3. 调用图与切片：WALA 反射接入，锚点式证据

设计要点：
- 通过 `ModuleManager + CompilerModuleExtension + ModuleRootManager` 收集 classpath
- 用"反射"调用 WALA API（兼容包名迁移），避免插件对 WALA 有编译期硬依赖
- 构建 0-CFA 调用图，给出图规模摘要
- 返回 `CGSliceResult{ summary, anchors[] }`，anchors 用"文件路径 + 起止行号"定位证据

> 这种"摘要 + 锚点"的轻切片策略有两个好处：始终可用（缺 JAR、版本差异都能降级），与 `ContextPackager` 的行号拼接天然匹配。

## 4. 上下文打包：只给模型需要看的

打包内容：
1. Entry 方法源码（带行号）
2. 调用图摘要
3. anchors 对应的多段源码
4. 相关类型（DTO/VO/Entity/Enum）：三套规则筛选，按 `typeDepth` 展开
5. 被调方法清单（可开关）

截断：超出 `maxChars` 直接裁剪并标注 `... [truncated]`，防止把 LLM 堵死。

## 5. 提示与生成：OpenAI/Ollama 双栈兼容

选择：`LLMClientFactory.create()` 依据 `useHttpClient` 决定 `HttpLLMClient` 还是 `StubLLMClient`。

健壮性：
- `extractContent()` 能从多种响应体中提取 `content`
- `stripThinkTags()` 移除推理块，得到干净的 Markdown
- `unwrapMarkdownFence()` 解除围栏，直写 `.md` 更可读

## 6. 调度与并发：RPS + 并发闸门 + 心跳

关键点：
- RPS：通过 `scheduleAtFixedRate` 按 `requestsPerSecond` 驱动 `tick()`
- 并发：`Semaphore` 作为硬闸门
- 队列：`backlog` + 有界 `ArrayBlockingQueue`，避免瞬时洪峰
- 重试：`retry(maxAttempts/backoffMs)` 配置化
- 心跳：每 250ms 合并上报 `QueueStatus` 到 MessageBus

## 7. 与替代方案的对比

- 只手写 Javadoc：准确但人力重、不可持续
- 只靠 LLM"读仓库"：可复现性差，易幻觉
- 只做静态分析：事实够硬，但"写好话"很难

GJavaDoc 的平衡点：事实由 PSI/轻切片提供，表达交给 LLM，中间用提示规范与清洗把关；配合并发与增量，在 IDE 内形成"所见即得"的工程化流水线。

---

文档生成不是"让模型瞎编"，而是"让模型把事实讲清楚"。把"事实管道"做好，把"生成规范"定紧，才是把遗留代码"清理出"可用文档的正解。
