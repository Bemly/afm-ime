# FoundationModels 框架能力全测绘（macOS 27 SDK）

> 测绘日期：2026-09-04・测绘机：macOS 27.0 (26A5425a) arm64・Swift 6.4（仅 CommandLineTools，无 Xcode）
> 目标：
>
> **零幻觉**
>
> 地列出 FoundationModels 能做什么 —— 每个 API 都来自本机 SDK 编译器生成的接口文件，并与 Apple 官方文档交叉核对；能跑的用实验代码实测。

## 0. 测绘方法与信源（可复现）



| 信源          | 路径 / 地址                                                                                                                                                                                              | 性质                      |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- |
| Swift 接口事实底 | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`（3647 行） | 编译器生成，所有 public 签名的权威来源 |
| 官方文档        | [https://developer.apple.com/documentation/FoundationModels](https://developer.apple.com/documentation/FoundationModels) 及各符号子页                                                                      | 用途语义、Topic 分类           |
| CLI         | `/usr/bin/fm` 全部子命令 `--help`                                                                                                                                                                         | 命令行 / 服务形态              |
| 实测代码        | `Sources/FMStructBench`、`Sources/CloudModelBench`、`Sources/ProviderBench`（`swift run <target>`）                                                                                                      | 本机运行结果                  |

**标注约定**：【接口】= 直接来自 swiftinterface；【文档】= 官方文档表述；【实测】= 本机运行验证。版本列：26 = macOS 26 起可用，**27β = macOS 27 新增、官方标注 Beta**。整个框架在 tvOS 不可用、watchOS 27 起。

**顶层类型共 35 个**（5 class/protocol 组合 + 大量 struct/enum），按官方 Topics 分为 12 个能力域。



***

## 1. 能力地图（一页看全）



| #  | 能力域                | 核心类型                                                                                                                     | 版本                     | 本输入法是否相关             |
| -- | ------------------ | ------------------------------------------------------------------------------------------------------------------------ | ---------------------- | -------------------- |
| 1  | 端侧模型               | `SystemLanguageModel`                                                                                                    | 26                     | ✅ 已用（FMReranker）     |
| 2  | 私有云模型 PCC          | `PrivateCloudComputeLanguageModel`                                                                                       | 27β                    | ❌ 需 entitlement + 联网 |
| 3  | 会话与生成              | `LanguageModelSession` / `Response` / `ResponseStream`                                                                   | 26                     | ✅ 已用                 |
| 4  | 提示构造               | `Instructions` / `Prompt` + 两个 result builder                                                                            | 26                     | ✅ 已用（字符串形态）          |
| 5  | 对话记录               | `Transcript`（Entry×6 / Segment×3）                                                                                        | 26（策略类型 27β）           | ✅ Provider 用到        |
| 6  | 多模态（图像）            | `Attachment` / `ImageAttachmentContent` / `ImageReference`                                                               | 27β                    | ❌ 输入法不需要             |
| 7  | 结构化输出              | `@Generable`/`@Guide` 宏、`Generable`、`GenerationSchema`、`DynamicGenerationSchema`、`GeneratedContent`、`GenerationGuide`    | 26（动态 schema 26，宏随宏插件） | ⚠️ 实测劣于自由文本          |
| 8  | 工具调用               | `Tool` 协议、`ToolDefinition`/`ToolCall`、`ToolCallingMode`                                                                  | 26                     | ❌ 暂不需要               |
| 9  | 生成控制               | `GenerationOptions`（采样 / 温度 /max token / 工具模式）、`ContextOptions`（schema 注入 / 推理档位）                                        | 26 / 27β               | 可用                   |
| 10 | **自定义模型 Provider** | `LanguageModel` / `LanguageModelExecutor` / `…Request` / `…Channel` / `LanguageModelCapabilities` / `LanguageModelError` | **27β**                | ✅ 已实验（ProviderBench） |
| 11 | 动态会话 Profile       | `DynamicInstructions` 家族、`DynamicProfile`/`Profile`/`Modifier`、生命周期钩子                                                    | 27β                    | ❌ 过重                 |
| 12 | 会话自定义属性 / 反馈       | `SessionProperty`/`SessionPropertyKey`/`SessionPropertyValues`；`LanguageModelFeedback`                                   | 27β / 26               | ❌                    |

**官方文档对框架的原话**【文档】："Perform tasks with models that specialize in language understanding, structured output, and tool calling"；"provides access to **any** large language model, like the on-device and Private Cloud Compute models"——27 代的定位已经是" 统一 LLM 抽象层 "。



***

## 2. 模型后端层

### 2.1 `SystemLanguageModel`（端侧 AFM，class，26）【接口】



| 成员           | 签名 / 取值                                                                                                                                      | 说明                                                                              |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| 获取实例         | `static var default: SystemLanguageModel`；`init(useCase: .general/.contentTagging, guardrails:)`；`init(adapter:guardrails:)`（27，Adapter 见下）  | 默认模型                                                                            |
| 可用性          | `var availability`：enum `.available` / `.unavailable(UnavailableReason)`；`var isAvailable: Bool`                                             | reason 三值：`deviceNotEligible` / `appleIntelligenceNotEnabled` / `modelNotReady` |
| 用途           | `UseCase`：`.general`、`.contentTagging`（内容标注专用模型）                                                                                             | —                                                                               |
| 安全护栏         | `Guardrails.default` / `.permissiveContentTransformations`                                                                                   | 两档                                                                              |
| 模型变体         | `var variant: Variant`；`Variant.core3` / `.coreAdvanced3`（displayName）                                                                       | 当前代两个档位                                                                         |
| 能力 / 上下文     | `var contextSize: Int`、`var supportedLanguages: Set<Locale.Language>`、`func supportsLocale(_:) -> Bool`（同步版）                                 | —                                                                               |
| **token 计数** | `tokenCount(for:)` 五个重载：PromptRepresentable / Instructions / `[any Tool]` / GenerationSchema / `[Transcript.Entry]`，全部 `async throws -> Int` | 不上模型也能数 token                                                                   |
| 适配器（27β）     | `Adapter`：`init(fileURL:)`/`init(name:)`、`compile() async`、`compatibleAdapterIdentifiers(name:)`、`removeObsoleteAdapters()`；错误 `AssetError`  | 加载外部适配模型资产                                                                      |

### 2.2 `PrivateCloudComputeLanguageModel`（PCC 私有云计算，class，27β）【接口】【文档】



* 定位【文档】："runs on Private Cloud Compute to provide enhanced capabilities（更大上下文、更强推理）while maintaining privacy guarantees"。

* 成员：`availability`（reason：`deviceNotEligible`/`systemNotReady`）、`isAvailable`、`quotaUsage`、`contextSize`、`supportedLanguages`、`supportsLocale(...) async throws`。

* `QuotaUsage`：`status`（`BelowLimit(isApproachingLimit:)` / `LimitReached`）、`resetDate`、`isLimitReached`、`LimitIncreaseSuggestion.show()`。

* 错误 `Error`：`NetworkFailure` / `QuotaLimitReached` / `ServiceUnavailable`。

* **门槛**：需要 entitlement `com.apple.developer.private-cloud-compute`【文档】。它同样实现 `LanguageModel` 协议（见第 10 节）。

### 2.3 模型选择关系



```
LanguageModel(协议, 27β)

&#x20;├── SystemLanguageModel            端侧，26 就有 class，27 起补上协议实现

&#x20;├── PrivateCloudComputeLanguageModel  Apple 私有云，27β，需 entitlement

&#x20;├── CoreAI 模型（CoreAI.framework，.aimodel 资产走 ANE）【文档，见 §13 坑】

&#x20;├── MLX 模型（开源 Swift 包 MLXFoundationModels，不在系统 SDK）

&#x20;└── 你自己写的 Provider（ProviderBench 已验证）
```



***

## 3. 会话层 `LanguageModelSession`（class，26）【接口】

### 3.1 初始化器（4 类）



| 形态               | 签名要点                                                                                                          |
| ---------------- | ------------------------------------------------------------------------------------------------------------- |
| 字符串 instructions | `init(model: some LanguageModel, tools: [any Tool] = [], instructions: String?)`（class 内 4 个 init 均显式传 model） |
| Instructions 值   | 同上前置，`instructions: Instructions?`                                                                            |
| result builder   | `init(tools:..., @InstructionsBuilder ...)`（带 throws (Failure) 版本）                                            |
| 从历史恢复            | `init(model:tools:transcript: Transcript)`；27β 另有 `init(profile:history:)`                                    |

### 3.2 生成方法：respond（一次性）与 streamResponse（流式），各自一个 3×3 重载矩阵

三个**输入形态**：`String`（@\_disfavoredOverload）/ `Prompt` / `@PromptBuilder` 闭包。

三个**输出形态**：



| 输出形态          | 返回                                                                                              | 用途            |
| ------------- | ----------------------------------------------------------------------------------------------- | ------------- |
| 自由文本          | `Response<String>`                                                                              | 本输入法现状        |
| 运行时 schema    | `Response<GeneratedContent>`（参数 `schema: GenerationSchema, includeSchemaInPrompt: Bool = true`） | 不使用宏的结构化      |
| 强类型 Generable | `Response<Content> where Content: Generable`（`generating: Content.Type`）                        | @Generable 模型 |

27β 起每个重载又多一个 "全参数版"：额外带 `contextOptions: ContextOptions`、`metadata: [String: any ConvertibleToGeneratedContent]`。



* 流式 `streamResponse(...)` 参数矩阵相同，返回 `ResponseStream<Content>`：它是 `AsyncSequence`，元素是 `Snapshot`（含 `content: Content.PartiallyGenerated` 增量内容、rawContent、transcriptEntries、usage），并提供 `collect() async throws -> Response<Content>` 一步收齐。

* **框架内部永远按流式工作**：即使调一次性 respond，也是收集完 stream 再返回【文档，ProviderBench 侧面验证：Executor 只需要写 channel 流】。

### 3.3 `Response<Content>` 与用量



* 字段：`content: Content`、`rawContent: GeneratedContent`、`transcriptEntries: ArraySlice<Transcript.Entry>`、`usage`。

* `Usage`：`Input(totalTokenCount, cachedTokenCount)`、`Output(totalTokenCount, reasoningTokenCount)`，以及合计 `totalTokenCount`。

### 3.4 会话属性与控制



* 属性：`transcript`、`isResponding`、`usage`、`history: Transcript.HistoryView`、`properties: SessionPropertyValues`、`transcriptErrorHandlingPolicy`（27β）。

* `prewarm(promptPrefix:)`：预热（模型加载 / KV cache）。

* **没有** cancel/interrupt/reset 公开方法（接口内 grep 无）；中断靠 Task 取消。

* 静态错误 `Session.Error`：`concurrentRequests`（同一会话并发请求）、`transcriptMutationWhileResponding`（响应中改 transcript）。

* 生成错误 `Session.GenerationError` 九种：`exceededContextWindowSize` / `assetsUnavailable` / `guardrailViolation` / `unsupportedGuide` / `unsupportedLanguageOrLocale` / `decodingFailure` / `rateLimited` / `concurrentRequests` / `refusal(Refusal, Context)`；其中 `Refusal` 提供 `explanation: Response<String>` 与 `explanationStream`（模型解释为何拒答）。



***

## 4. 提示层：Instructions / Prompt（26）【接口】



* `struct Instructions`：`init(_ content: some InstructionsRepresentable)`，builder 为 `@InstructionsBuilder`（支持 if/for/ 数组、有限可用性分支）。

* `struct Prompt`：`init(_ content: some PromptRepresentable)`，builder 为 `@PromptBuilder`。

* 桥接协议：`InstructionsRepresentable.instructionsRepresentation`、`PromptRepresentable.promptRepresentation`—— 字符串、GeneratedContent、Tool、Attachment、Generable 类型都有实现，所以这些东西能直接写进 builder 闭包。

* 27β 动态版：`DynamicInstructions`（协议）+ `AnyDynamicInstructions`（类型擦除）、`TupleDynamicInstructions`（参数包，支持变参组合）、`ConditionalDynamicInstructions`（if 分支）、`EmptyDynamicInstructions`、`DynamicInstructionsForEach`（别名 `ForEach`，按数据集循环生成 instructions，可混入 Tool）。



***

## 5. 对话记录 `Transcript`（struct，26；RandomAccessCollection）【接口】

### 5.1 两层结构树



```
Transcript（可下标遍历、Codable、数组字面量初始化）

└─ Entry（6 case，均带 id）

&#x20;  ├─ instructions(Instructions{segments, toolDefinitions})

&#x20;  ├─ prompt(Prompt{segments, options, contextOptions, metadata, responseFormat})

&#x20;  ├─ response(Response{assetIDs, segments, metadata})

&#x20;  ├─ reasoning(Reasoning{segments, signature: Data?, metadata})        27β

&#x20;  ├─ toolCalls(ToolCalls → \[ToolCall{id, toolName, arguments: GeneratedContent, metadata}])

&#x20;  └─ toolOutput(ToolOutput{toolName, segments})

&#x20;       Segment（3 case）

&#x20;       ├─ text(TextSegment{id, content: String})

&#x20;       ├─ structure(StructuredSegment{schemaName, content: GeneratedContent})

&#x20;       └─ attachment(AttachmentSegment{content: Attachment, label?})
```



* `ToolDefinition{name, description, parameters: GenerationSchema}`，可 `init(tool: some Tool)` 自动生成。

* `ResponseFormat`：由 Generable 类型或 GenerationSchema 构造（prompt 级别的输出格式约束）。

* `HistoryView`：可变集合，session.history 可 append / 改。

* 每个 Entry 都有 `description`（日志友好）。

* `TranscriptErrorHandlingPolicy`（27β）两个静态策略：`.revertTranscript`（出错回滚）/ `.preserveTranscript`（出错保留）。



***

## 6. 多模态：图像输入（27β）【接口】【文档】



* `ImageAttachmentContent`：四种构造 ——`CGImage` / `CIImage` / `CVPixelBuffer` / 图片文件 `URL`，均可带方向。

* `Transcript.ImageAttachment`：可取 `url`/`cgImage`/`ciImage`，`pixelBuffer(resolution:pixelFormat:)`，带 `orientation`。

* `Attachment<Content>`：泛型附件，`.label(_:)` 加标签，同时是 Prompt/Instructions 可表示的。

* `ImageReference`：**不直接装图像数据，只持有 attachmentLabel**，靠 `resolved(in: [Entry]) -> ImageAttachment?` 在 transcript 里回查（让模型输出 "指向某张图" 的引用）；带 PartiallyGenerated。

* CLI 侧对应：`fm respond --image a.jpg --text '描述' [--label x]`，`fm count-tokens --image`。

* 能力声明：模型必须含 `.vision` capability（系统模型支持；自定义 Provider 自行声明）。



***

## 7. 结构化输出（Guided Generation，26）【接口】+【实测】

### 7.1 宏（需要 FoundationModelsMacros 编译插件）



* `@Generable(description:name:representNilExplicitlyInGeneratedContent:)`：附到 struct/class，自动补 `Generable` 一致性与 `init(_ generatedContent:)`。

* `@Guide(description:_:)` 三个重载：值约束 `GenerationGuide<T>...`、字符串正则 `Regex`、纯描述。

* **本机坑（实测）**：仅装 CommandLineTools 时插件二进制 `FoundationModelsMacros` 不存在（`usr/lib/swift/host/plugins/` 只有 ObservationMacros/SwiftMacros），使用宏的代码无法编译；Xcode 工具链才自带。绕法见 7.4。

### 7.2 协议与标准类型支持



* `Generable = ConvertibleFromGeneratedContent + ConvertibleToGeneratedContent`，要求 `generationSchema`、`init(_:)`、`generatedContent`、`PartiallyGenerated`（流式增量类型）。

* 原生遵守 `Generable` 的标准类型：**Bool / String / Int / Float / Double / Decimal / Array（元素也要 Generable）/ Never / Optional**；`GeneratedContent` 自身也遵守。

### 7.3 `GenerationSchema`（运行时 schema，不需要宏）



* 对象：`init(type: any Generable.Type, description:, properties: [Property])`；`Property` 支持普通 / 可选类型、字符串可挂 Regex guide。

* 枚举：`init(type:anyOf: [String])`（字符串枚举）、`init(type:anyOf types: [any Generable.Type])`（类型联合）。

* 动态根：`init(root: DynamicGenerationSchema, dependencies:)`。

* Codable、`name`、`debugDescription`；错误 `SchemaError`（duplicateType/duplicateProperty/emptyTypeChoices/undefinedReferences）。

* `DynamicGenerationSchema`（26）：运行时拼 schema，7 个构造器 ——null /object (properties) / 显式 nil 策略 /anyOf (schema) /anyOf (String) /arrayOf（带元素个数上下限）/ 基本类型带 guides /referenceTo（跨类型引用）；`Property(name:description:schema:isOptional:)`。

### 7.4 `GeneratedContent`（生成结果的动态容器）



* 构造：键值对 properties（KeyValuePairs / 序列 /uniquingKeysWith）、单值包裹、`init(json: String)`。

* 读取：`value(T.self)` / `value(T.self, forProperty:)`（含可选版）、`jsonString`、`kind`（六 case：null/bool/number/string/array/structure (properties:orderedKeys:)）、`isComplete`、`id: GenerationID?`。

* 错误 `ParsingError{rawContent, underlyingError, debugDescription}`（27β）。

* **不写宏的结构化路径**：`session.respond(to:, schema:)` 拿 GeneratedContent，或标准类型 `respond(to:, generating: Int.self)`。

### 7.5 `GenerationGuide<Value>`（取值约束）



| 作用于                      | API                                                           |
| ------------------------ | ------------------------------------------------------------- |
| String                   | `.constant(_:)`、`.anyOf([String])`、`.pattern(Regex)`          |
| Int/Float/Double/Decimal | `.minimum/.maximum/.range(ClosedRange)`                       |
| Array                    | `.minimumCount/.maximumCount/.count(范围或定值)/.element(子 guide)` |

### 7.6 实测结论（FMStructBench，案例 beng bu zhu le，每格 8 次）【实测】



* 自由文本回序号：32/32 可解析，搞笑语境 16/16 正确选「绷不住了」、地名 8/8 选「蚌埠住了」，P50≈367ms。

* 裸 `generating: Int.self`（无字段名 / 范围）：32/32 稳定返回 **-5**，完全不可用。

* `GenerationSchema(type: String.self, anyOf: 候选)`：格式保证三选一，但目标命中仅 4/32、20/32 失败（含安全层拦截 "sensitive or unsafe content"），且偏向错别字。

* **结论：结构化约束只保证输出格式，不提升语义判断；"回一个序号" 场景保持自由文本。**



***

## 8. 工具调用 Tool（26）【接口】【文档】



```
protocol Tool\<Arguments, Output>: Sendable {

&#x20;   associatedtype Arguments: ConvertibleFromGeneratedContent

&#x20;   associatedtype Output: PromptRepresentable

&#x20;   var name: String { get }

&#x20;   var description: String { get }

&#x20;   var parameters: GenerationSchema { get }

&#x20;   var includesSchemaInInstructions: Bool { get }

&#x20;   @concurrent func call(arguments: Arguments) async throws -> Output

}
```



* 模型决定调用时，transcript 出现 `ToolCalls/ToolCall`（参数是 GeneratedContent），App 执行后写回 `ToolOutput`，框架再继续生成。

* 开关在 `GenerationOptions.ToolCallingMode`：`allowed`（默认，模型可调用）/ `required`（必须调用）/ `disallowed`。

* Session 初始化用 `tools: [any Tool]` 注入；动态 instructions 里也可插 Tool。

* 错误 `LanguageModelError.ToolCallError{tool, underlyingError}`。

* CLI 内置两个工具：`fm respond/chat --tool barcode|ocr`（可重复）。



***

## 9. 生成控制

### 9.1 `GenerationOptions`（26）【接口】



| 属性                                              | 取值                                                                                                                                                    |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sampling: SamplingMode?` / 计算属性 `samplingMode` | `SamplingMode`：`.greedy`；`.random(topK:seed:)`；`.random(probabilityThreshold:seed:)`（Kind 三 case：greedy/randomTopK/randomProbabilityThreshold，可带随机种子） |
| `temperature: Double?`                          | 采样温度；官方建议后端不支持 greedy 时用 temperature=0 近似【文档】                                                                                                         |
| `maximumResponseTokens: Int?`                   | 输出上限                                                                                                                                                  |
| `toolCallingMode: ToolCallingMode?`             | allowed/required/disallowed                                                                                                                           |

### 9.2 `ContextOptions`（27β）【接口】



* `includeSchemaInPrompt: Bool?`：schema 是否写进 prompt 文本。

* `reasoningLevel: ReasoningLevel?`：`.light / .moderate / .deep / .custom(String)`—— 推理强度档位（对应云端的 reasoning effort）。



***

## 10. 自定义模型 Provider（27β，本轮重点验证）【接口】【文档】【实测】

官方文档原文：Executor 是 "框架与 \*\* 真正生成 token 的系统（如 server API 或本地推理引擎）\*\* 之间的桥"。四个必备类型：

### 10.1 `protocol LanguageModel: Sendable`



```
associatedtype Executor: LanguageModelExecutor where Self == Self.Executor.Model

var capabilities: LanguageModelCapabilities { get }

var executorConfiguration: Self.Executor.Configuration { get }
```

### 10.2 `LanguageModelCapabilities`



* `init([Capability])`、`contains(_:)`；四个静态能力：`.vision` / `.guidedGeneration` / `.reasoning` / `.toolCalling`。

* 框架在调 Executor 前校验能力，缺能力直接抛 `LanguageModelError.unsupportedCapability`，不发请求。

### 10.3 `protocol LanguageModelExecutor: Sendable`



```
associatedtype Configuration: Hashable, Sendable   // 框架按 Configuration 缓存 Executor 实例

associatedtype Model: LanguageModel

init(configuration: Configuration) throws

func prewarm(model: Model, transcript: Transcript)   // 有默认实现，不保证被调用

func respond(to request: LanguageModelExecutorGenerationRequest,

&#x20;            model: Model, streamingInto channel: LanguageModelExecutorGenerationChannel) async throws
```

### 10.4 `LanguageModelExecutorGenerationRequest`（框架帮你整理好的上游请求）

字段：`id: UUID`、`transcript: Transcript`、`enabledToolDefinitions: [ToolDefinition]`、`schema: GenerationSchema?`、`generationOptions`、`contextOptions`、`metadata: [String: GeneratedContent]`。

### 10.5 `LanguageModelExecutorGenerationChannel`（回灌管道，AsyncSequence）



* `send(_ event: Event) async`；Event 三类：`.response(action:)` / `.reasoning(action:)` / `.toolCalls(action:)`。

* Response.Action：`appendText(_:segmentID:tokenCount:)`、`replaceTextSegment`、`addAttachmentSegment/removeAttachmentSegment`、`updateMetadata`、`updateUsage(input:output:metadata:)`。

* Reasoning.Action：appendText/replaceTextSegment/`updateSignature(Data, tokenCount:)`/updateMetadata/updateUsage。

* ToolCalls.Action：`toolCall(id:name:action:)`/removeToolCall/updateMetadata/updateUsage；ToolCall.Action：`appendArguments(_:tokenCount:)`。

* 用量结构：`Usage.Input(total, cached)`、`Usage.Output(total, reasoning)`。

* **方法 return 或 throw 即结束 channel，无需显式关闭**【文档】。

### 10.6 `LanguageModelError`（27β 统一错误，九 case，全部带 debugDescription+metadata）



| case                         | 关联值要点                   |
| ---------------------------- | ----------------------- |
| contextSizeExceeded          | contextSize, tokenCount |
| rateLimited                  | resetDate?              |
| guardrailViolation           | —                       |
| refusal                      | explanation 文本          |
| unsupportedCapability        | 缺的 Capability           |
| unsupportedTranscriptContent | 不支持的 \[Entry]           |
| unsupportedGenerationGuide   | schemaName?             |
| unsupportedLanguageOrLocale  | LanguageCode            |
| timeout                      | —                       |

### 10.7 实测（ProviderBench）【实测】

`OpenAICompatModel: LanguageModel` + `actor OpenAICompatExecutor: LanguageModelExecutor`（transcript→OpenAI messages、options→temperature、HTTP→`appendText`），后端接本机 `fm serve`：标准 `LanguageModelSession(model: 自定义模型).respond(to:)` 编译通过并 3/3 正确返回，普通问答同样正常。**换 baseURL 即 DeepSeek/OpenAI/ 豆包 / 通义 / Ollama Provider**；CloudModelBench 同时给出不依赖 27 协议的 App 层 HTTP 对照。



***

## 11. 动态 Profile 与生命周期钩子（27β）【接口】



* `DynamicProfile` 协议 + `Profile`（包 DynamicInstructions）、`AnyDynamicProfile`、`ConditionalDynamicProfile`、`Modifier`/`ModifiedDynamicProfile`/`DynamicProfileModifierContent`、builder `@DynamicProfileBuilder`、类型别名 `Profile`/`DynamicProfile`。

* Profile 修改器（链式返回 some DynamicProfile）：`model(_:)`、`temperature(_:)`、`samplingMode(_:)`、`maximumResponseTokens(_:)`、`reasoningLevel(_:)`、`toolCallingMode(_:)`、`historyTransform(_:)`、`transcriptErrorHandlingPolicy(_:)`。

* **生命周期钩子**（无参 / 带值两版）：`onPrompt` / `onResponse` / `onReasoning` / `onToolCall` / `onToolOutput` / `onActivate` / `onDeactivate`—— 官方定位用于搭 agent/skill 式抽象【文档】。对输入法过重，不采用。

## 12. 会话自定义属性（27β）与反馈（26）



* `@SessionProperty` 属性包装器（keyPath 到 SessionPropertyValues）、`SessionPropertyKey` 协议、`SessionPropertyValues`（按类型下标存取）、宏 `@SessionPropertyEntry()`—— 让 profile/tool 之间共享状态。

* `LanguageModelFeedback`（26）：`Sentiment`：positive/negative/neutral；`Issue.Category` 八类：unhelpful/tooVerbose/didNotFollowInstructions/incorrect/stereotypeOrBias/suggestiveOrSexual/vulgarOrOffensive/triggeredGuardrailUnexpectedly；`logFeedbackAttachment(sentiment:issues:desiredOutput/desiredResponseText/desiredResponseContent:)` 三个重载生成反馈附件 Data。



***

## 13. fm CLI 全命令测绘（`/usr/bin/fm`）【实测 help】



| 命令                           | 能力要点                                                                                                                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `available [--model system]` | 检查可用性（不带参数查全部）                                                                                                                                                                  |
| `respond <prompt>`           | 单次生成：`-i/--instructions`、`--schema <file>`、`--text/--image/--label`（多模态）、`--tool barcode\|ocr`、`--resume/--save-transcript`、`--[no-]stream`（默认开）、`-g/--greedy`、`-v`；支持 stdin 管道 |
| `chat`                       | 交互式会话：`--continue`、`--resume <name>`、会话存 `~/.fm/sessions/`、`--set-default-model`                                                                                                |
| `count-tokens`               | 数 token：instructions/text/image/transcript 都计入，`-q` 只输出整数；**仅端侧模型**                                                                                                             |
| `schema object`              | 生成结构化 schema：`--name`（必填）、`--string/--integer/--boolean/--double/--object/--anyOf`、修饰 `--array/--optional/--description`、嵌套 `--schema`、点号属性名 `address.street`                   |
| `serve`                      | **OpenAI Chat Completions 兼容服务器**：`--host/--port/--socket`；端点 `GET /health`、`GET /v1/models`、`POST /v1/chat/completions`（流式 / 非流式）；model 名固定 `system`                           |
| `license`                    | `--status/--show`，条款同意状态                                                                                                                                                        |



***

## 14. 能力边界与本机实测坑（重要）



1. **没有任何 embedding / 向量 / 最近邻 API**：全接口 grep `embedding/vector/nearest/similar/retrieval` 零匹配；fm CLI 也无 embed。向量能力属于独立的 `NaturalLanguage.NLEmbedding`（系统中文词向量 300 维 / 句向量 640 维，已实测），与本框架无关。

2. **宏插件缺失**：CLT 无 `FoundationModelsMacros`（系统框架目录、CLT 插件目录均无实体），`@Generable/@Guide/@SessionPropertyEntry` 在无 Xcode 环境编不过；非宏 API（schema/Generable 标准类型 / Provider）不受影响。

3. **前置条件**：端侧模型要求设备支持并开启 Apple Intelligence，否则 availability 为 `.unavailable` 三原因之一；ad-hoc 签名二进制可直接用（本项目已验证，无需 entitlement）；**PCC 需要&#x20;**`com.apple.developer.private-cloud-compute`**&#x20;entitlement**。

4. **安全层会拦截**：实测同 prompt 偶发 / 在特定通道高频报 "sensitive or unsafe content"（对应 guardrailViolation /refusal），App 必须能静默降级。

5. **并发约束**：同一 Session 同时只能有一个生成请求（`concurrentRequests`），要并行就多开 session（本项目正是 "每次新建无状态 session"）。

6. **Beta 稳定性**：第 10/11/12 节与多模态、ContextOptions 均标 macOS 27.0 Beta，签名可能随正式版变化；26 的 API 为稳定基线。

7. **CoreAI 在当前 CLT SDK 不完整**：`CoreAI.framework` 仅有 1.2KB 伞模块（`@_exported import CoreAIDelegates`，后者实体不在 CLT），`CoreAILanguageModel` 类公开声明本机查不到，需完整 Xcode / 后续 beta 验证；MLX 路线是开源 SwiftPM 包，不在系统 SDK。

8. **无取消 API**：Session 没有 cancel 方法，靠结构化并发 Task 取消。

9. **延迟现实**（此前基准）：暖场生成 ≈0.32–0.44s，冷启动 ≈0.9–2s，做不了逐键级跟手，只适合异步增强。



***

## 15. 对本输入法（AFM 拼音）的落地清单



| 能力                                                             | 取舍                                                                                     |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| SystemLanguageModel + 自由文本 respond                             | **保持**，候选重排 / 整句兜底现状，每次新建无状态 session                                                   |
| tokenCount(for:)                                               | 可用于上文截断（光标前 ≤60 字）时精确预算，替代粗估                                                           |
| prewarm                                                        | App 启动后可预热一次，压掉首个请求冷启动                                                                 |
| GenerationOptions.greedy                                       | 重排任务可试 `.greedy` 降低选择抖动（值得 A/B）                                                        |
| 结构化 @Generable/schema                                          | **不采用于序号选择**（实测更差）；若以后要多字段结果再评估，且需先解决宏插件                                               |
| 自定义 Provider（27β）                                              | 已验证可行：FMReranker 面向 `any LanguageModel` 抽象，可插云端 / 本地模型；正式采用前等 API 稳定并做 `#available` 分支 |
| PCC / 多模态 / Tool / DynamicProfile / SessionProperty / Feedback | 输入法场景不需要                                                                               |
| 安全拦截 / 不可用                                                     | 维持静默降级到纯词典                                                                             |

## 16. 实验代码索引



| Target                    | 验证内容                                                | 运行                          |
| ------------------------- | --------------------------------------------------- | --------------------------- |
| `Sources/FMStructBench`   | 自由文本 vs 裸 Int vs anyOf 三通道准确率 / 失败率 / 延迟            | `swift run fmstructbench`   |
| `Sources/CloudModelBench` | App 层 OpenAI 兼容客户端：进程内 FM /fm serve / 云端（环境变量配 key） | `swift run cloudmodelbench` |
| `Sources/ProviderBench`   | 官方 LanguageModel/Executor 协议接入自定义后端（决定性验证）          | `swift run providerbench`   |



***

### 附：信源核对记录



* 35 个顶层类型、全部 public 方法签名、枚举 case、可用性版本：逐行读自 arm64e-apple-macos.swiftinterface（3647 行），无一条来自记忆或推测。

* Topic 分类与用途语义：与 [developer.apple.com/documentation/FoundationModels](https://developer.apple.com/documentation/FoundationModels) 官方目录、LanguageModelExecutor 符号页逐一对照一致。

* 标注 Beta 的类型官方文档页同样标 "Beta Software"。

* 运行时行为（延迟、结构化准确率、Provider 接入、fm serve）均来自本机实测，结果可由上表命令复现。