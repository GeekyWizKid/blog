---
title: GJavaDoc：用 LLM 给遗留代码“清运”出文档
date: 2025-09-07
tags: [Kotlin, Code Analysis, LLM]
categories: [技术]
draft: false
---

项目地址：[GJavaDoc](https://github.com/GeekyWizKid/GJavaDoc)

核心观点：把“确定性的事实”尽可能多地通过静态/字节码分析拿到，把“解释性文字”留给 LLM。只有事实充分，文档才稳定、可复现、可增量。

<!--more-->

## 1. 总体流程

```mermaid
flowchart LR
  SRC[源代码/字节码] --> PARSE[AST/ASM]
  PARSE --> INDEX[符号索引/引用关系]
  INDEX --> SLICE[调用切片/异常切片]
  SLICE --> PROMPT[结构化 Prompt]
  PROMPT --> LLM[模型生成]
  LLM --> MERGE[校验/格式化]
  MERGE --> OUT[注释/Javadoc/站点文档]
```

## 2. 事实获取：AST + 字节码

事实来源（择优组合）：
- JavaParser/Spoon：源码级 AST，拿到注解、泛型、注释残存；
- ASM：字节码级，能走第三方库（无源码）；
- ClassGraph：类路径扫描，定位入口与外部依赖；
- Git：diff/ blame，识别变更范围供增量化。

示例（Kotlin + ASM）提取方法签名、抛出异常、方法调用：

```kotlin
class MethodScanner : ClassVisitor(ASM9) {
  val methods = mutableListOf<MethodInfo>()
  override fun visitMethod(acc: Int, name: String, desc: String, sig: String?, exceptions: Array<out String>?): MethodVisitor {
    val info = MethodInfo(name, desc, exceptions?.toList().orEmpty())
    methods += info
    return object : MethodVisitor(ASM9) {
      override fun visitMethodInsn(op: Int, owner: String, name: String, desc: String, itf: Boolean) {
        info.calls += Call(owner, name, desc)
      }
    }
  }
}
```

## 3. 调用切片与异常路径

对于文档的“关键问题”（前置条件、边界、异常、副作用、并发），我们用切片方式给模型喂“证据”：

```kotlin
data class Slice(
  val fqName: String,
  val params: List<Param>,
  val returns: String,
  val calls: List<Call>,
  val throws: List<String>,
  val concurrency: ConcurrencyFacts,
)

data class ConcurrencyFacts(val usesLock: Boolean, val syncBlocks: Int, val usesAtomic: Boolean)
```

并发特征可通过字节码/AST 探测（`monitorenter`/`monitorexit`、`java.util.concurrent` 族使用等）。

## 4. 结构化 Prompt，减少幻觉

让模型输出“固定 JSON 结构”，再做严格校验：

```json
{
  "summary": "一句话概述",
  "preconditions": ["输入必须...", "状态要求..."],
  "side_effects": ["写库...", "发消息..."],
  "failure_paths": ["TokenExpiredException: ...", "IOError: ..."],
  "concurrency": { "thread_safe": false, "notes": "使用synchronized保护cache" },
  "returns": "返回语义/边界",
  "examples": ["...代码示例..."]
}
```

Kotlin 端用 `kotlinx.serialization` 解析，失败则降级提示或分段重试。

## 5. 增量化与并发

基于 Git 变更与内容哈希做最小化刷新：

```kotlin
data class Fingerprint(val symbol: String, val sha: String)

fun dirtySymbols(): List<String> =
  gitDiff().mapNotNull { changedFile -> index.symbolsIn(changedFile) }
    .flatten()
    .filter { fp[it] != hash(symbolSource(it)) }
```

并发流水线（限 N 并发，防止模型/网络打爆）：

```kotlin
suspend fun <T> parallel(xs: List<T>, n: Int, f: suspend (T) -> Unit) = coroutineScope {
  val sem = Semaphore(n)
  xs.map { x -> launch { sem.withPermit { f(x) } } }.joinAll()
}
```

## 6. 生成到落地：注释与站点

- 注释层：把 JSON 映射为 Javadoc/KDoc，补齐 `@param/@return/@throws`；
- 站点层：把方法/类/模块按导航组织，额外附“调用关系”、“异常清单”、“并发注意”。

Javadoc 例：

```java
/**
 * 重置用户密码。
 * <p>
 * 前置条件：Token 未过期，用户存在。
 * 副作用：会写入数据表 user_vault；发送一封通知邮件。
 * 失败分支：TokenExpiredException / UserNotFoundException。
 * 并发：方法内部使用 synchronized 保护缓存，不建议并发调用。
 * @param userId 用户ID
 * @throws TokenExpiredException when token expired
 * @return 新密码摘要
 */
```

## 7. 风险与对策

- 幻觉与错配：Prompt 必须包含“调用/异常/并发证据”，输出必须过 JSON Schema 校验；
- 大型项目：对公共库先构建“全局符号索引”，按模块/层级逐步推进；
- 私有代码：走企业代理/本地模型，审计与脱敏；
- 成本：对变更过的符号优先，老代码只在首次/定期批量覆盖。

## 8. 结语

文档生成不是“让模型瞎编”，而是“让模型把事实讲清楚”。GJavaDoc 的要义就是：事实靠分析，表达交给模型，增量与并发把效率抬起来。
