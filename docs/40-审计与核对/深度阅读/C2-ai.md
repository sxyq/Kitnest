# C2 · AI 模块逐行测绘

> 范围：`apps/FrsetNext/Sources/Features/AI/`，25 个 `.swift`，**4 475 行**。全部整读。
> 符号对账：CSV 该目录 290 条声明，其中 **184 func + 30 init = 214 个函数级符号**，本文表格全覆盖；另有 3 个 CSV 未收录的静态函数（`LLMTransport.streamBytes`、`LLMService.send`、`AIChatViewModel.effectiveModel` 等属性型成员）也已补入并标注。
> 只读测绘，未修改源码、未执行构建。

---

## 1. 文件清单

| # | 路径 | 行数 | 一句话职责 |
|---|---|---|---|
| 1 | `AIChatView.swift` | 437 | 极简 Markdown 渲染 + 聊天气泡 + 聊天 VM + 面板区段容器（对话/文本工具切换） |
| 2 | `AISettingsPane.swift` | 431 | AI 设置页（服务商/Base URL/凭证/模型/连通性/默认动作/自定义工具） |
| 3 | `AISummaryView.swift` | 340 | 摘要/润色/翻译 + 自定义提示词工具面板 |
| 4 | `LLMProtocols.swift` | 302 | 协议分层（构造/解析/门面）+ 模板方法默认实现 + 错误与厂商元信息 |
| 5 | `CredentialStore.swift` | 292 | AES-256 加密文件凭证存储（绕过钥匙串）+ 内存实现 |
| 6 | `AppleTranslationProvider.swift` | 218 | 本机离线翻译 Provider + SwiftUI `.translationTask` 桥（1×1 隐藏窗） |
| 7 | `LLMTransport.swift` | 199 | 可取消流式传输（dataTask + delegate → AsyncThrowingStream）+ 行缓冲 + JSON 工具 |
| 8 | `QNWTranslator.swift` | 197 | 360 免 Key 翻译通道（multipart 表单 + 切块 + 行对齐） |
| 9 | `TranslationToolSession.swift` | 196 | 翻译调度器（按偏好取候选 Provider 依次尝试）+ 语言判定 + 行号协议解析 |
| 10 | `AICredentialJournal.swift` | 180 | 凭证提交审计日志（JSONL，只记指纹）+ 提交协调器 |
| 11 | `LLMSessionStore.swift` | 179 | 会话/消息持久化（复用 Storage 的 llm_sessions / llm_messages） |
| 12 | `TranslationProvider.swift` | 175 | 翻译 Provider 协议 + LLM/QNW 实现 + 注册表（含 Apple） |
| 13 | `OpenAICompatibleService.swift` | 137 | OpenAI 协议网关适配器（Bearer + /v1 归一 + 模型过滤） |
| 14 | `GeminiService.swift` | 130 | Gemini 适配器（key 走 query + streamGenerateContent + role 映射） |
| 15 | `LegacyGeminiMigrator.swift` | 128 | 旧版 Gemini-only 配置一次性迁移（带台账） |
| 16 | `OllamaService.swift` | 126 | 本地 Ollama 适配器（无鉴权 + NDJSON） |
| 17 | `AnthropicService.swift` | 126 | Claude 适配器（x-api-key + anthropic-version + system 独立字段） |
| 18 | `AISettings.swift` | 122 | AI 偏好读写（厂商/地址/模型/温度/最大 token/翻译 Provider/OCR Refiner/系统提示词） |
| 19 | `LLMResolver.swift` | 120 | 模型发现双层缓存（内存+Preferences，TTL 30min）+ 厂商/模型解析 |
| 20 | `AIConnectionService.swift` | 107 | 连通性测试（临时凭证 + 临时地址，先探目录再退化为极小对话） |
| 21 | `LLMService.swift` | 105 | LLM 门面（按偏好路由 + 门面重载 + 跨模块 `LLMServiceProtocol`） |
| 22 | `CustomAIToolStore.swift` | 93 | 自定义提示词工具（Preferences 存 JSON） |
| 23 | `TranslationDiagnostics.swift` | 73 | 翻译链路自检（逐个 Provider + 会话回落） |
| 24 | `AIModule.swift` | 41 | 模块启动：迁移 → 重建门面 → 注入 ServiceLocator → 注册面板/设置 |
| 25 | `AIEventBus.swift` | 21 | AI 产出文本出站回调（交 App 层接剪贴板） |

合计 4 475 行，与 `wc -l` 一致。

---

## 2. 类型清单

### 2.1 协议层（LLMProtocols.swift）
| 协议 | 职责 | 实现者 |
|---|---|---|
| `LLMCredentialStoring` | 凭证增删读清 + `hasCredential` 默认实现 | `CredentialStore`、`InMemoryCredentialStore` |
| `LLMRequestBuilding` | `kind` / `baseURL`(可写) / `defaultModel` / `makeRequest` / `makeModelsRequest` | 四家适配器 |
| `LLMResponseParsing` | `parseStreamLine` / `parseComplete` / `parseModelIDs` / `readableError` / `isTerminalLine` | 四家适配器 |
| `LLMProviderAdapting` | 门面：聚合上两者 + `availableModels` / `send` / `complete` / `requireCredential` | 协议扩展给模板方法 |

- **模板方法**：`send` 用 `LLMTransport.streamBytes` + `LLMLineBuffer` 拼流；`complete` 走 `send(stream:false)`；`availableModels` 走 `makeModelsRequest` → `parseModelIDs`（空列表回退 `[defaultModel]`）；`checkResponse` 把 HTTP ≥400 翻成 `LLMError.httpStatus`。
- **依赖**：`AISettings`（温度/maxTokens）、`LLMTransport`、`LLMError`。
- **被依赖**：`LLMService`、`LLMResolver`、`AIConnectionService`。

### 2.2 `LLMTransport` / `AIProviderURLSessionDelegate` / `LLMLineBuffer` / `LLMJSON` / `SessionBox`
- **职责**：所有网络请求的唯一出入口；把字节流桥接成 `AsyncThrowingStream<Data, Error>`；SSE/NDJSON 行切分；JSON 兜底取值。
- **状态**：delegate 持有 `statusCode` / `errorBody`（≥400 时单独攒）；`SessionBox` 持 `URLSession?` + `NSLock`。
- **生命周期**：每次 `streamBytes` 新建一个 ephemeral session + delegate + dataTask；`onFinish` 或 `onTermination` 都会 `invalidate()`。
- **依赖**：`LLMError`、`LLMJSON`。
- **被依赖**：`LLMProviderAdapting.send`。

### 2.3 `CredentialStore` / `InMemoryCredentialStore`
- **职责**：凭证加密落盘（`$AppSupport/FrsetNext/ai-credentials.bin`，0600），主密钥 `.ai-keystore`（0600）。
- **状态**：`cache: [String:String]?`（内存明文，进程内常驻）；静态 `secretCache: [String: Data]`（按 keystore 路径缓存主密钥）。
- **生命周期**：`init` 即 `load()`；`setCredential` 同步加密写盘（主线程也会走）。
- **依赖**：`CommonCrypto`（PBKDF2 / CCCrypt / CC_SHA256）、`AppDirectories`、`Preferences`。
- **被依赖**：`LLMResolver`、`AICredentialCommitCoordinator`、`AIConnectionService`（用 InMemory 版）、`LegacyGeminiMigrator`、`AISettingsPane`。

### 2.4 四家适配器（Anthropic / Gemini / OpenAICompatible / Ollama）
| 维度 | Anthropic | Gemini | OpenAI 兼容 | Ollama |
|---|---|---|---|---|
| 端点 | `/v1/messages` | `/v1beta/models/{m}:streamGenerateContent?alt=sse` | `/chat/completions` | `/api/chat` |
| 鉴权 | `x-api-key` + `anthropic-version: 2023-06-01` | `?key=` query | `Authorization: Bearer` | 无 |
| system | 顶层 `system` 字段 | `systemInstruction.parts` | 混在 messages | 插入首条 message |
| 流格式 | SSE，`content_block_delta.delta.text` | SSE，`candidates[0].content.parts[].text` | SSE，`choices[0].delta.content` | NDJSON，`message.content` |
| 终止行 | `type == message_stop` | **未实现**（默认 false） | `data: [DONE]` | `done == true && content 为空` |
| 地址归一 | 去尾 `/v1` | 去尾 `/v1beta` `/v1` | 剥 `/chat/completions` `/models` 后补 `/v1` | 去尾 `/api` `/v1` |
- **状态**：只有 `credentialStore`（let）与 `defaultModel`（let）；`baseURL` 是计算属性，读写 `AISettings`。
- **生命周期**：`LLMResolver.provider(for:)` **每次新建**（保证切地址/凭证立即生效），`shared` 单例基本不用。
- **被依赖**：`LLMResolver`、`AIConnectionService`。

### 2.5 `LLMService`（门面，`LLMServiceProtocol`）
- **状态**：`_provider`（锁保护）、`resolver`；`currentModel` 每次问 resolver。
- **生命周期**：`shared` 单例，`init` 即解析一次；偏好变更靠显式 `reload()`。
- **依赖**：`LLMResolver`、`AISettings`、`DatabaseManager.bumpStat`。
- **被依赖**：`AIModule`、`AIChatViewModel`、`AISummaryViewModel`、`TranslationProvider`（经 `ServiceLocator.llmService`）、Toolbox/Clipboard/PinWindow（跨模块）。

### 2.6 翻译 Provider 体系
- `TranslationProvider` 协议（`translate` / `translateLines` / 可选 `stream`）。
- `LLMTranslationProvider`（id `llm`）：plain / document 两套 system 提示词；`translateLines` 用 `⟦n⟧` 行号协议 + `parseMarkedLines` 校验。
- `QNWTranslationProvider`（id `qnw`）：360 免 Key，逐行兜底。
- `AppleTranslationProvider`（id `apple`）：macOS 15+，`LanguageAvailability` 判语言包，`AppleTranslationBridge` 拿 `TranslationSession`。
- `TranslationProviderRegistry`：顺序 = auto 优先级（llm → qnw → apple）。
- `TranslationToolSession`：对外唯一入口（`translate` / `complete` / `translateDocument` / `translateNumberedBlocks`），`attempt` 依次尝试候选。

### 2.7 设置与迁移
- `AISettings`（enum，纯静态）：键集中定义，`baseURL(for:)` 三级回落（per-provider → 共享 → 内置常量）。
- `AIProviderSettingsViewModel` + `AISettingsPane`：设置页。
- `LegacyGeminiMigrationLedger` / `UserDefaultsLegacyGeminiStore` / `LegacyGeminiMigrator`：一次性迁移（台账键 `legacy_gemini_migration_version`）。
- `AIProviderModelDiscoveryCache` / `LLMResolver`：模型发现缓存与解析。
- `AICredentialJournalStore` / `AICredentialCommitCoordinator`：凭证审计。
- `CustomAITool` / `CustomAIToolStore`：自定义工具。
- `AIConnectionTestResult` / `AIProviderConnectionService`：连通性测试。

### 2.8 UI
`MarkdownText`、`ChatBubble`（private）、`AIChatViewModel`、`AIChatView`、`AISectionState`、`AISectionTab`、`AISectionView`、`AISummaryAction`、`AISummaryViewModel`、`AISummaryView`、`AIProviderSettingsViewModel`、`AISettingsPane`。

---

## 3. 函数级清单

### 3.1 AIChatView.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(_ content:)` | 12 | `MarkdownText` 存原文 |
| `init()` | 83 | VM 初始：先铺缓存模型，避免下拉空白 |
| `onAppear()` | 94 | 同步偏好 → 载入最近一次会话 → **已配置凭证才**自动拉模型（否则每次打开弹"尚未配置 Key"错误） |
| `refreshModels()` | 111 | forceRefresh 拉模型列表；失败写 `errorMessage` |
| `send()` | 127 | 空/正在流式则退出；落库 user 消息 + 自动命名 + 启动流任务 |
| `stop()` | 147 | 取消流任务 |
| `startNewChat()` | 152 | 停流 + 建新会话 + 清状态 |
| `ensureSession()` | 165 | 懒建会话 |
| `performStream(history:model:sessionID:)` | 172 | 逐 token 累加并 `MainActor.run` 推给 UI；结束 `commit`，异常 `finishPartial`（保留已产出内容，取消不报错） |
| `commit(reply:sessionID:)` | 192 | 空回复直接收尾；否则落库 assistant 消息 |
| `finishPartial(reply:sessionID:)` | 204 | 异常路径：有部分内容则落库 |
| `init()` | 219 | `AIChatView` 空初始化 |
| `lastAnchor()` | 330 | 滚动锚点（最后一条消息 id / "streaming"） |
| `errorBanner(_:)` | 334 | 错误横幅 |
| `init()` | 398 | `AISectionView` 空初始化 |
| `init()` | 425 | `AISectionState` 默认 tab = chat |

### 3.2 AIConnectionService.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(ok:message:models:elapsed:)` | 15 | 结果值对象 |
| `init()` | 23 | 服务单例 |
| `rawStoredBaseURL(_:)` | 100 | 读当前 per-provider 地址原文 |
| `restoreBaseURL(_:_:)` | 104 | 还原地址 |

> ⚠ CSV 未收录 `test(provider:baseURL:model:apiKey:)`（第 31 行，`async`）。它先用 `InMemoryCredentialStore` 装候选 key，再把候选 baseURL **临时写进全局 Preferences**（`defer` 还原），先探 `/models`（不耗 token），失败退化为一次"回复 OK 两个字"的极小对话。

### 3.3 AICredentialJournal.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(fileURL:)` | 50 | 默认 `ai-credential-journal.jsonl` |
| `recordGlobal(action:)` | 62 | 全局动作（provider = `"*"`） |
| `entries(limit:)` | 67 | 读最近 n 条（时间升序） |
| `clear()` | 74 | 删除日志文件 |
| `encodeLine(_:)` | 122 | 单条 → JSON 行 |
| `loadAll(fileURL:)` | 127 | 逐行解码，坏行跳过 |
| `fingerprint(_:)` | 137 | SHA-256 前 6 字节 → 12 位十六进制 |
| `commit(_:for:)` | 160 | 协调器：写/删凭证 + 记审计 |
| `remove(for:)` | 171 | 删凭证 + 记审计 |
| `clearAll()` | 176 | 清全部 + 记 global audit |

> CSV 未收录 `record(action:provider:secret:)`（55 行）与私有 `record(action:providerRaw:secret:)`（82 行）。后者是热路径优化：常规追加走 `FileHandle.seekToEnd` O(1) 写一行，只有行数达 500 才全量裁剪重写。

### 3.4 AIEventBus.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `emitResult(_:)` | 17 | 非空才回调 `onResultProduced` |

### 3.5 AIModule.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `start()` | 12 | 迁移 → `LLMService.reload()` → 注入 `ServiceLocator.llmService` → 注册面板/设置页 → `ModuleRegistry.register` |
| `reload()` | 38 | 供外部触发门面重建 |

### 3.6 AISettings.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `baseURLKey(for:)` | 19 | `ai.baseURL.<provider>` |
| `baseURL(for:)` | 35 | per-provider → 共享 `ai.baseURL` → 内置常量；非法 URL 也回落 |
| `setBaseURL(_:for:)` | 46 | 空串等价删除 |

> 其余为属性（`providerKind` / `selectedModel` / `temperature`(0…2 钳制) / `maxTokens`(256…200000 钳制) / `translationProviderPreference`（含 v146 旧值迁移） / `ocrRefinerPreference` / `systemPrompt`）。

### 3.7 AISettingsPane.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `reload()` | 38 | 从偏好重载全部草稿值；`apiKeyText` 清空（不回显） |
| `selectProvider(_:)` | 51 | 写偏好 + `LLMService.reload()` + reload |
| `commitBaseURL()` | 59 | 写地址 + 失效模型缓存 + reload |
| `saveKey()` | 68 | 走协调器（写 + 审计）+ 清草稿 + reload |
| `removeKey()` | 82 | 删凭证 + 审计 + reload |
| `addCustomTool()` | 91 | 校验名称/模板后 upsert |
| `deleteCustomTool(id:)` | 109 | 删除 |
| `refreshModels()` | 117 | 起 Task 拉模型 |
| `loadModelsAsync()` | 124 | forceRefresh 拉取并写 info |
| `commitModel()` | 140 | 写偏好 + reload |
| `testConnection()` | 148 | 用页面未保存的候选配置测连通（不污染已存配置） |
| `init()` | 179 | `AISettingsPane` 空初始化 |

### 3.8 AISummaryView.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `prompt(for:)` | 45 | 每种动作的 user 提示（前置"请对以下内容…"） |
| `saveAsDefault()` | 59 | 写 `ai.defaultAction` |
| `init(inputText:)` | 80 | VM 初始化并载入自定义工具 |
| `reloadTools()` | 86 | 设置页改完回面板时刷新 |
| `run(_:)` | 92 | 校验输入 → 组 system+user → 起流 |
| `runCustom(_:)` | 105 | 自定义工具：`tool.render(input:)` 套模板 |
| `stop()` | 116 | 取消任务 |
| `copyResult()` | 122 | 写剪贴板 + Toast + 1.5s 态 |
| `saveToClipboard()` | 134 | 经 `AIEventBus` 交剪贴板模块落库 |
| `validatedInput()` | 145 | 空则设错误；正在跑则返回 nil（静默） |
| `start(messages:)` | 155 | 清状态 + 起流任务 |
| `perform(messages:model:)` | 166 | 逐 token 推 UI；异常时保留部分输出，取消不报错 |
| `init(inputText:)` | 192 | `AISummaryView` 注入初值 |

### 3.9 AnthropicService.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(credentialStore:)` | 24 | 注入凭证源 |
| `makeRequest(_:credential:)` | 30 | `/v1/messages`，`x-api-key` + `anthropic-version`，`conversation`（剔 system）+ 顶层 `system`，`max_tokens` 必填 |
| `makeModelsRequest(credential:)` | 55 | `GET /v1/models?limit=1000` |
| `parseStreamLine(_:)` | 69 | 只认 `content_block_delta`；`error` 字段抛 `LLMError.provider` |
| `parseComplete(_:)` | 84 | `content[].text` 拼接 |
| `parseModelIDs(_:)` | 94 | `data[].id` |
| `readableError(from:)` | 101 | 走 `LLMJSON.errorMessage` |
| `isTerminalLine(_:)` | 109 | JSON 解析判 `type == message_stop`（不做字符串包含，兼容网关空格差异） |
| `normalizedBase()` | 120 | 去尾斜杠、去尾 `/v1`（防 `/v1/v1/messages`） |

### 3.10 AppleTranslationProvider.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init()` | 43 | Provider 无状态 |
| `translate(_:to:mode:)` | 50 | 校验非空/macOS 15 → 判语言对 → 查语言包已装 → 取 session → 翻译 |
| `translateLines(_:to:)` | 62 | 跳过空行，批量 `translations(from:)`，按槽位回填（保证行数严格对齐） |
| `languageCode(for:fallbackSource:)` | 98 | 目标文案 → BCP-47（zh-Hans / zh-Hant 区分） |
| `has(_:)` | 103 | 内部：关键字包含判定 |
| `detectSourceCode(for:targetCode:)` | 121 | `NLLanguageRecognizer` 取主导语言；与目标相同则按字符集兜底反转 |
| `isInstalled(_:)` | 134 | `LanguageAvailability().status == .installed`（**不弹下载框**） |
| `session(from:to:)` | 173 | 桥：登记单等待者 + `ensureWindow` + 设 config + 8s 超时 |
| `deliver(_:)` | 194 | `.translationTask` 回调交付 session |
| `ensureWindow()` | 201 | 1×1 透明、`alphaValue=0`、鼠标穿透、`ignoresCycle` 的宿主窗 |

**散文（本机翻译桥的三处脆弱点）**
- `TranslationSession` 只能从 SwiftUI `.translationTask` 修饰符拿到，没有同步构造入口——所以必须挂一个真实窗口承载该修饰符。窗口 `alphaValue = 0` 但 `level = .normal`，在窗口列表里可见（`ignoresCycle` 让 Cmd-Tab 循环看不到）。
- **单等待者**：`session(from:to:)` 里有 `if let previous = pending { previous.resume(throwing: .timedOut) }`。并发两次翻译，第一次会被以"超时"错误结束——串行调用是隐含前提（`TranslationToolSession.attempt` 是串行的，所以实际安全）。
- 8s 超时用 `Task.sleep` 实现，超时后 `Pending` 置 nil 并 resume 抛错；但 `.translationTask` 之后仍可能调用 `deliver`，此时 `pending == nil` 直接 return，session 被丢弃——不泄漏 continuation。

### 3.11 CredentialStore.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(fileURL:keyFileURL:)` | 48 | 默认落在 `AppDirectories.base`；立即 `load()` |
| `credential(for:)` | 57 | 锁内读缓存 |
| `setCredential(_:for:)` | 62 | 空等价删除；锁内改缓存 + **同步加密落盘**（失败只记日志，缓存已改） |
| `removeCredential(for:)` | 77 | 转 `setCredential(nil)` |
| `clear()` | 81 | 清空并落盘 |
| `configuredProviders()` | 89 | 已配置厂商列表（设置页统计用） |
| `load()` | 97 | 文件不存在 → 空缓存；解密失败 → 空缓存且**不覆盖原文件** |
| `persist(_:)` | 114 | 加密 + 原子写 + 0600 |
| `ensureFileProtection(_:)` | 120 | `posixPermissions = 0o600` |
| `masterSecret(keyFileURL:)` | 134 | 静态 `secretCache` 命中即返回，否则读/建 |
| `loadMasterSecret(keyFileURL:)` | 148 | 有文件则剥 `FRSTKEY1` 头；无则 32 字节 CSPRNG 生成并落盘 0600 |
| `derivedKey(salt:keyFileURL:)` | 167 | `secret + "FrsetNext.credential.v1"` → PBKDF2-SHA256 10 万轮 → 32 字节 |
| `encryptEnvelope(_:keyFileURL:)` | 191 | `FRSTCRE1` + salt16 + iv16 + AES-256-CBC(PKCS7) 密文 |
| `decryptEnvelope(_:keyFileURL:)` | 223 | 校验 magic/长度 → 派生 → 解密 → JSON → `[String:String]` |
| `randomBytes(_:)` | 258 | 数组随机填充 |
| `randomFill(_:_:)` | 265 | `arc4random_buf` |
| `init(_:)` | 276 | 内存实现：初始字典 |
| `credential(for:)` | 280 | 锁内读 |
| `setCredential(_:for:)` | 284 | 锁内写/删 |
| `removeCredential(for:)` | 290 | 转 set nil |
| `clear()` | 291 | 全清 |

**散文（为什么不用钥匙串）**
- 原作被诟病"每次读 API Key 都弹钥匙串授权"。重建刻意改成本地加密文件：消除授权弹窗与首次访问系统 UI。
- 安全边界诚实标注：同用户身份的其他进程读到 `.ai-keystore` 仍可解密，属"防明文落盘 + 防误备份泄漏"级别，不抗恶意软件。
- 每次加密都会重新随机 salt/IV（同一明文两次加密结果不同），代价是每次 save 都要跑一次 10 万轮 PBKDF2（主线程 ~30–80ms）。

### 3.12 CustomAIToolStore.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `render(input:)` | 34 | 模板含 `{input}` 则替换，否则追加到末尾 |
| `init(prefs:)` | 51 | 注入偏好 |
| `all()` | 56 | 锁内解码并按 `createdAt` 升序 |
| `upsert(_:)` | 62 | 按 id 覆盖或追加 |
| `delete(id:)` | 71 | 按 id 删除 |
| `persist(_:)` | 82 | 编码成 JSON 字符串写 `ai.customTools` |
| `decode(_:)` | 88 | 空/损坏 → `[]` |

### 3.13 GeminiService.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(credentialStore:)` | 24 | 注入凭证源 |
| `makeRequest(_:credential:)` | 30 | `/{v1beta}/models/{m}:streamGenerateContent?alt=sse&key=`；`contents` 角色映射 assistant→model；`systemInstruction` |
| `makeModelsRequest(credential:)` | 65 | `GET /{v1beta}/models?key=` |
| `parseStreamLine(_:)` | 79 | `candidates[0].content.parts[].text` 拼接 |
| `parseComplete(_:)` | 92 | 同上（非流式），缺字段抛 decoding |
| `parseModelIDs(_:)` | 103 | 只保留 `supportedGenerationMethods` 含 `generateContent` 的；剥 `models/` 前缀 |
| `readableError(from:)` | 116 | `LLMJSON.errorMessage` |
| `normalizedBase()` | 123 | 去尾 `/v1beta`、`/v1` |

### 3.14 LegacyGeminiMigrator.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(prefs:)` | 25 | UserDefaults 存储实现 |
| `legacyString(_:)` | 29 | 空白视为不存在 |
| `removeLegacy(_:)` | 35 | 删旧键 |
| `init(prefs:)` | 48 | 台账实现 |
| `markMigrated()` | 55 | 写版本号 |
| `migrateIfNeeded()` | 81 | 已迁移则 false；依次迁 key / 地址 / 模型 / 厂商，最后**无条件清理旧键**并记账 |
| `firstValue(_:)` | 122 | 候选键名逐个探测 |

### 3.15 LLMResolver.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `key(for:)` | 21 | `ai.models.<provider>` |
| `timeKey(for:)` | 22 | `ai.models.<provider>.updatedAt` |
| `models(for:)` | 25 | 内存命中且未过期 → 返回；否则读 Preferences 并校验 TTL，回填内存 |
| `store(_:for:)` | 40 | 同时写内存与 Preferences（JSON 字符串 + 时间戳） |
| `invalidate(_:)` | 52 | 清两处 |
| `provider(for:)` | 80 | 每次新建适配器（切地址/凭证即生效） |
| `effectiveModel(for:)` | 93 | 用户选择 > 厂商默认 |
| `cachedModels(for:)` | 117 | 仅缓存查询 |

> CSV 未收录 `availableModels(for:forceRefresh:)`（100 行，`async`）。逻辑：非强制且命中缓存直接返回；拉取失败时**回退陈旧缓存**（避免 UI 空掉），仍无则抛错。

### 3.16 LLMService.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(resolver:)` | 16 | 解析当前 provider |
| `reload()` | 22 | 锁内重建 provider + 日志（厂商/模型） |
| `complete(messages:model:)` | 69 | 拼流为整串 |
| `complete(prompt:system:model:)` | 79 | 协议实现：单段提问包装 |
| `stream(prompt:system:model:)` | 84 | 协议实现：流式 |
| `buildMessages(prompt:system:)` | 90 | system 为空则用默认助手提示词 |
| `withSystemIfNeeded(_:)` | 99 | 无 system 时前置默认提示词（不重复追加） |

> CSV 未收录 `send(messages:model:stream:)`（45 行）与 `provider` / `providerKind` / `currentModel` / `isConfigured` 属性。`send` 里 `DatabaseManager.shared.bumpStat("ai_request_count")` 计一次请求。

### 3.17 LLMSessionStore.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init()` | 13 | 无状态（库走 `DatabaseManager.shared.clipboard`） |
| `listSessions(limit:)` | 42 | 只查元数据（不拉消息体） |
| `loadSession(id:)` | 62 | 元数据 + 消息 |
| `renameSession(id:title:)` | 79 | 改标题 + 更新时间 |
| `clearAll()` | 90 | 事务内清空两表 |
| `appendMessage(sessionID:role:content:)` | 104 | 插消息 + 更新会话 `updated_at` |
| `messages(for:)` | 119 | 按 `created_at` 升序 |
| `autoTitle(sessionID:from:)` | 132 | 标题仍为"新会话"/空时用首句前 24 字 |
| `snippet(from:around:radius:)` | 145 | 命中词前后 30 字摘要 |

> CSV 未收录 `createSession(title:provider:model:)`（19 行）。**注意**：`renameSession` / `clearAll` / `snippet` / `LLMSessionSearchHit` 在当前源码里**没有任何调用方**（全仓 grep 确认），属预留/死代码。

### 3.18 LLMTransport.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `urlSession(_:dataTask:didReceive response:completionHandler:)` | 27 | 记录 statusCode，`.allow` |
| `urlSession(_:dataTask:didReceive data:)` | 35 | <400 直接 `onData`；≥400 攒 `errorBody` |
| `urlSession(_:task:didCompleteWithError:)` | 41 | 有 error → `onFinish(error)`；≥400 → 组装 `LLMError.httpStatus`（优先厂商 `refineError`） |
| `invalidate()` | 100 | 锁内取走 session 后 `invalidateAndCancel`（避免持锁调用） |
| `truncate(_:limit:)` | 109 | 换行压成空格 + 截断加 `…` |
| `ingest(_:)` | 124 | 追加并 drain（不强制） |
| `flush()` | 129 | drain（强制取尾行） |
| `drain(force:)` | 133 | **单趟扫描**收集行边界、末尾一次 `removeSubrange`（v126 修 O(n²)） |
| `object(_:)` | 165 | Data → `[String:Any]`，失败抛带原文片段的 decoding |
| `errorMessage(_:)` | 175 | 依次尝试 `error.message` / `error.type` / `error` 字符串 / `message+success=false` |
| `ssePayload(_:)` | 185 | 剥 `data:` 前缀，识别 `[DONE]` |
| `streamPayload(_:)` | 193 | 优先 SSE；否则整行裸 JSON（NDJSON/部分网关） |

**散文（可取消流式的实现要点）**
- 不用 `URLSession.bytes(for:)`：那样拿不到底层 task 句柄，取消不彻底。这里自建 `dataTask` + `URLSessionDataDelegate`，`continuation.onTermination` 里 `task.cancel()` + `invalidateAndCancel()`。
- `didReceive response` 不在这里直接抛错（continuation 只允许 finish 一次），而是记 statusCode 等 `didComplete` 统一处理——这样 HTTP 4xx/5xx 的错误体能被完整攒下来。
- `drain` 的性能坑：旧实现每行 `range(of:)` + `removeSubrange` 前移整段，一个 chunk 攒几十行就 O(n²)——SSE 是 AI 热路径，已改为单趟扫描。

### 3.19 OllamaService.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(credentialStore:)` | 21 | 注入凭证源 |
| `requireCredential()` | 26 | 覆写为空串（本地无需鉴权） |
| `makeRequest(_:credential:)` | 30 | `/api/chat`；`options.temperature` / `num_predict`；system 插首条 message |
| `makeModelsRequest(credential:)` | 59 | `GET /api/tags` |
| `parseStreamLine(_:)` | 72 | NDJSON，`message.content`；`error` 字符串直接抛 |
| `parseComplete(_:)` | 83 | `message.content`，回退 `response` 字段 |
| `parseModelIDs(_:)` | 93 | `models[].name` ?? `model`，排序 |
| `readableError(from:)` | 99 | `error` 字符串优先 |
| `isTerminalLine(_:)` | 107 | `done == true` **且**该行无增量文本（避免丢掉收尾文本） |
| `normalizedBase()` | 119 | 去尾 `/api` `/v1` |

### 3.20 OpenAICompatibleService.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(credentialStore:)` | 22 | 注入凭证源 |
| `makeRequest(_:credential:)` | 28 | `/chat/completions`，Bearer；`temperature` / `max_tokens` 恒定传入 |
| `makeModelsRequest(credential:)` | 52 | `GET /models` |
| `parseStreamLine(_:)` | 66 | `choices[0].delta.content` |
| `parseComplete(_:)` | 78 | `choices[0].message.content` |
| `parseModelIDs(_:)` | 90 | 过滤 embedding/tts/whisper/dall-e/moderation/rerank/babbage/davinci，排序 |
| `readableError(from:)` | 105 | `LLMJSON.errorMessage` |
| `isTerminalLine(_:)` | 112 | `data: [DONE]` / `data:[DONE]` / `[DONE]` |
| `normalizedBase()` | 121 | 只裁路径部分（保留 `scheme://`）；剥 `/chat/completions` `/models`；已含 `/v1|/v2|/v3|/v4|/api/v1|/openai/v1` 则不补 |

### 3.21 QNWTranslator.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `translate(_:to:)` | 27 | 判目标语言 → 按 1200 字切块 → 逐块请求 → 行数对齐回填（对不上就整段拼接不丢内容） |
| `translateBlocks(_:to:)` | 60 | 拼成一段翻译后按行切回，行数不等抛 `formatMismatch` |
| `languageCode(for:source:)` | 72 | 13 种语言文案 → 360 语言码；兜底按 CJK 比例 |
| `has(_:)` | 74 | 内部：关键字匹配 |
| `request(_:to:)` | 95 | multipart 表单 `query/lang=auto/tolang`，15s 超时；解析 `Envelope.code == 0` |
| `appendField(_:_:)` | 103 | 内部：拼一段 multipart 字段 |
| `chunks(of:)` | 146 | 按行累计切块，不切断单行 |

**散文（免 Key 通道的代价）**
- 这是**第三方无鉴权公网接口**（`ai.api.360qnw.com`）：文本会离开本机。auto 模式下未配 Key 时，翻译内容默认走这条路——隐私上必须在文档里明确。
- 逐句机翻，无上下文与术语一致性；`translateBlocks` 要求行数严格相等，360 按句切分时常对不上 → 抛 `formatMismatch` → `ScreenTranslator` 回退到 `llm` 逐块翻译（若 llm 也不可用则整条链路失败）。

### 3.22 TranslationDiagnostics.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `run()` | 18 | 打偏好/注册表/生效项 → 查本机语言包状态 → 逐 Provider 各翻一次 → 再走会话回落链路 |
| `label(_:)` | 61 | `LanguageAvailability.Status` → 中文 |
| `oneLine(_:)` | 70 | 换行转 ` / ` |

### 3.23 TranslationProvider.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `stream(_:to:)` | 41 | 协议默认实现：不支持流式返回 nil |
| `init(serviceProvider:)` | 54 | 注入 LLM 服务解析闭包（默认查 `ServiceLocator`） |
| `translate(_:to:mode:)` | 60 | plain/document 两套 system；document 强制"一行对一行" |
| `translateLines(_:to:)` | 80 | `⟦n⟧` 行号协议 + `parseMarkedLines` 校验，不齐抛 `formatMismatch` |
| `stream(_:to:)` | 102 | 走 `service.stream` |
| `resolvedTarget(_:for:)` | 111 | 未指定则按 CJK 比例自动定目标 |
| `init()` | 125 | QNW Provider 无状态 |
| `translate(_:to:mode:)` | 129 | 转 `QNWTranslator.translate` |
| `translateLines(_:to:)` | 133 | 转 `QNWTranslator.translateBlocks` |
| `provider(id:)` | 157 | 按 id 查 |
| `resolve(preference:)` | 165 | `auto` → 全部（按优先级）；指定 id → 只试它（失败即报错）；未知 id → 全部 |
| `effectiveProvider(preference:)` | 172 | 第一个可用 |

### 3.24 TranslationToolSession.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(providersProvider:)` | 40 | 延迟解析候选（避免模块启动顺序影响） |
| `translate(_:to:)` | 59 | 空输入 Toast + 抛错；取第一个可用 Provider，支持流式则直接流，否则整段一次性吐出 |
| `complete(_:to:)` | 90 | 一次性翻译（写回剪贴板等场景） |
| `cjkRatio(_:)` | 105 | CJK+全角标点占比（去空白） |
| `autoTarget(for:)` | 120 | 占比 >0.25 → English，否则 简体中文 |
| `translateDocument(_:to:)` | 127 | 整段翻译（保留换行/段落） |
| `translateNumberedBlocks(_:to:)` | 139 | 逐块翻译，按候选 Provider 依次尝试（失败记 warn） |
| `parseMarkedLines(_:reply:expected:)` | 156 | 两套正则：`⟦n⟧` / `n.`；行数不齐返回空 |
| `attempt(_:)` | 181 | 依次问候选 Provider，第一个成功即返回；全失败抛最后一个错误，失败记 debug |

### 3.25 LLMProtocols.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `hasCredential(for:)` | 100 | 协议扩展：非空白即视为有 |
| `requireCredential()` | 166 | 缺失抛 `missingCredential(kind)`（中文可读） |
| `send(messages:model:stream:)` | 174 | 模板方法：非流式走一次性 `data(for:)`；流式走 `streamBytes` + 行缓冲；`isTerminalLine` 命中即 finish；收尾 `flush`；`onTermination` 取消 job |
| `complete(messages:model:)` | 228 | 拼流为整串 |
| `checkResponse(_:_:)` | 237 | ≥400 抛 `httpStatus`（优先厂商错误文案，回退截断原文） |
| `isTerminalLine(_:)` | 245 | 协议默认 false |

---

## 4. 关键数据流

### 4.1 一次聊天请求

```
AIChatView 输入 → AIChatViewModel.send()
  ├─ LLMSessionStore.appendMessage(.user)          [SQLite: DatabaseManager.clipboard]
  ├─ LLMSessionStore.autoTitle(...)
  └─ Task → performStream
        → LLMService.send(messages:model:stream:true)
            ├─ DatabaseManager.bumpStat("ai_request_count")
            ├─ withSystemIfNeeded（补默认 system）
            └─ provider.send(...)                       [模板方法]
                  ├─ requireCredential()                [CredentialStore 内存缓存]
                  ├─ makeRequest(...)                   [厂商适配器]
                  └─ LLMTransport.streamBytes(...)
                        ├─ URLSession(ephemeral, delegate: AIProviderURLSessionDelegate)
                        ├─ didReceive data → continuation.yield(Data)
                        └─ LLMLineBuffer.ingest → 逐行
                              ├─ isTerminalLine → finish
                              └─ parseStreamLine → delta → continuation.yield(String)
        → 每个 delta: MainActor.run { streamingText = snapshot }   [每 token 一次 UI 更新]
  ├─ 成功 → commit() → appendMessage(.assistant)
  └─ 失败 → finishPartial()（保留部分输出；取消不报错）
```

### 4.2 翻译（含三级回落）

```
调用方（Toolbox / 剪贴板 / 截图 / 屏幕翻译）
  → TranslationToolSession.complete / translate / translateDocument / translateNumberedBlocks
  → providersProvider() = TranslationProviderRegistry.resolve(preference: 用户偏好)
        偏好 auto → [llm, qnw, apple]；指定 id → [该 id]
  → attempt()：过滤 isAvailable → 依次 body(provider)
        ├─ LLMTranslationProvider → ServiceLocator.llmService.complete/stream
        │      └─ 逐块模式用 ⟦n⟧ 协议 + parseMarkedLines 校验
        ├─ QNWTranslationProvider → QNWTranslator（multipart，1200 字切块）
        └─ AppleTranslationProvider → LanguageAvailability → AppleTranslationBridge.session → TranslationSession.translate
```

### 4.3 设置页保存凭证

```
AISettingsPane「保存」
  → AIProviderSettingsViewModel.saveKey()
  → AICredentialCommitCoordinator.commit(key, for:)
      ├─ CredentialStore.setCredential  → PBKDF2(10万) → AES-CBC → ai-credentials.bin(0600)
      └─ AICredentialJournalStore.record(.save) → JSONL 追加一行（含 SHA-256 前 12 位指纹）
  → LLMService.reload()
```

### 4.4 连通性测试

```
「测试连接」→ AIProviderConnectionService.test(provider:baseURL:model:apiKey:)
  ├─ InMemoryCredentialStore(候选 key)（不写真实存储）
  ├─ 临时 AISettings.setBaseURL(候选)   ← 全局偏好被改
  ├─ ① adapter.availableModels（/models 探测，不耗 token）
  │     成功 → 缓存结果 + 判断目标模型是否在清单里
  └─ ② 失败 → adapter.complete("回复 OK 两个字") 极小对话探测
  └─ defer 还原 baseURL
```

---

## 5. 资源清单

### 5.1 网络
- `URLSession`：`LLMTransport` 每次请求一个 `ephemeral` session（自定义 delegate，读完即 `invalidateAndCancel`）；`QNWTranslator` 用 `URLSession.shared`。
- 超时：请求 60s（`LLMTransport.requestTimeout`）、资源 600s（流式长连接）、QNW 15s、Apple 桥 8s。
- 端点：`api.anthropic.com`、`generativelanguage.googleapis.com`、`api.openai.com`（或用户自填任意 OpenAI 网关）、`localhost:11434`、`ai.api.360qnw.com`。

### 5.2 线程 / 锁
- `LLMService.lock`（NSLock）、`CredentialStore.lock`、`CredentialStore.secretLock`（静态）、`AIProviderModelDiscoveryCache.lock`、`AICredentialJournalStore.lock`、`CustomAIToolStore.lock`、`LLMTransport.SessionBox.lock`。
- `URLSession(configuration:delegate:delegateQueue: nil)` → 系统自建串行 delegate 队列。
- `Task`：每次 send/translate 一个；`@MainActor` 用于 UI 回写。

### 5.3 文件路径
- `$AppSupport/FrsetNext/ai-credentials.bin`（0600，`FRSTCRE1` 魔数）
- `$AppSupport/FrsetNext/.ai-keystore`（0600，`FRSTKEY1` 魔数 + 32 字节）
- `$AppSupport/FrsetNext/ai-credential-journal.jsonl`（0600，上限 500 行）

### 5.4 数据库
- `DatabaseManager.shared.clipboard` 库中的 `llm_sessions` / `llm_messages` 两表（AI 模块不建表）。
- `bumpStat("ai_request_count")` 统计。

### 5.5 Preferences / UserDefaults 键
| 键 | 默认 |
|---|---|
| `Preferences.Keys.aiProvider` | `anthropic` |
| `Preferences.Keys.aiModel` | `""`（跟随厂商默认） |
| `Preferences.Keys.aiBaseURL` | `""`（共享回落） |
| `ai.baseURL.<provider>` | `""` |
| `ai.models.<provider>` / `.updatedAt` | `""` / `0`（TTL 30min） |
| `ai.temperature` | `0.7`（钳制 0…2） |
| `ai.maxTokens` | `4096`（钳制 256…200000） |
| `ai.defaultAction` | `summarize` |
| `ai.systemPrompt` | 空 → 内置 `fallbackSystemPrompt` |
| `ai.translationProvider` | `auto`（并迁移旧键 `ai.translationEngine`：ai→llm、quick→qnw） |
| `ocr.refiner` | `auto` |
| `ai.customTools` | `""`（JSON 数组） |
| `legacy_gemini_migration_version` | `0` |
| 旧键（迁移后删除） | `gemini.apiKey` / `gemini.api_key` / `geminiAPIKey` / `geminiApiKey` / `gemini.baseURL` / `gemini.apiBaseURL` / `geminiBaseURL` / `gemini.model` / `geminiModel` |

### 5.6 单例
`LLMService.shared`、`LLMResolver.shared`、`AIProviderModelDiscoveryCache.shared`、`CredentialStore.shared`、`AICredentialJournalStore.shared`、`AICredentialCommitCoordinator.shared`、`AIProviderConnectionService.shared`、`CustomAIToolStore.shared`、`LLMSessionStore.shared`、`TranslationProviderRegistry.shared`、`TranslationToolSession.shared`、`AppleTranslationBridge.shared`、`LegacyGeminiMigrator.shared`、以及四家适配器各自的 `shared`（实际很少用）。

### 5.7 隐藏窗口
`AppleTranslationBridge.ensureWindow()` 的 1×1 透明窗（`alphaValue=0`、`ignoresMouseEvents`、`canJoinAllSpaces`、`ignoresCycle`），进程内常驻。

---

## 6. 不变量与陷阱

1. **`continuation` 只允许 finish 一次**。`LLMTransport` 把 HTTP 错误延迟到 `didComplete` 统一处理，就是为了避免"先抛错再 finish"。
2. **必须实现 `isTerminalLine`**（否则依赖连接关闭）。Gemini **没实现**（默认 false）——Gemini SSE 没有等价终止事件，只能等服务端断连；网关不关连接时会一直等到 60s 超时。
3. **`LLMLineBuffer` 必须跨 chunk 攒行**。TCP 分片会切断一行，单 chunk 直接 `split` 会丢半行 JSON。
4. **`normalizedBase` 必须去重版本前缀**。用户常填 `.../v1`、`.../v1/chat/completions`，不剥就会拼出 `/v1/v1/chat/completions`。
5. **凭证文件解析失败时不能覆盖原文件**（`load()` 里刻意不写回），否则一次解密失败就永久丢 key。
6. **`translationProviderPreference` 要兼容 v146 旧值**（ai/quick），否则老用户升级后翻译静默失效。
7. **`⟦n⟧` 协议的行数必须严格相等**，否则整块失败回退逐块翻译（质量骤降但不丢内容）。
8. **Apple 翻译要求语言包已 `.installed`**，`.supported` 直接抛错（不弹下载框）——这是产品决策，不是能力缺失。
9. **`AppleTranslationBridge` 单等待者**：并发翻译会让先到者以"超时"失败。
10. **`CredentialStore` 的静态 `secretCache` 永不失效**：进程内替换了 `.ai-keystore` 后仍用旧密钥（重启才生效）。

---

## 7. 重复实现 / 死代码 / 风险

### 7.1 重复实现
| 项 | 说明 |
|---|---|
| **三家 `normalizedBase()`** | 各写一份（Anthropic 去 `/v1`、Gemini 去 `/v1beta`+`/v1`、OpenAI 剥路径段并补 `/v1`、Ollama 去 `/api`+`/v1`）。逻辑相近但不能共用（各家版本前缀语义不同），属可接受的重复。 |
| **两家 `readableError` + 两家 `parseModelIDs`** | Anthropic/Gemini/OpenAI 的 `readableError` 完全相同（都只调 `LLMJSON.errorMessage`），可提到协议扩展。 |
| **语言码表两份** | `QNWTranslator.languageCode` 与 `AppleTranslationProvider.languageCode` 各维护一张 13 行映射（输出码不同：`zh`/`jp`/`kor` vs `zh-Hans`/`ja`/`ko`）。 |
| **`isTerminalLine` 三种实现** | Anthropic（JSON 判 type）、OpenAI（字符串判 `[DONE]`）、Ollama（JSON 判 done + 无增量）。语义不同，无法合并。 |
| **两套"自动目标语言"** | `TranslationToolSession.autoTarget`（>0.25 → English）被 QNW/Apple/LLM 各调用一次；Apple 的 `languageCode` 里又内联了一遍同样的 0.25 判断。 |
| **翻译入口三条** | `TranslationToolSession.translate`（流式）/`complete`（一次性）/`translateDocument`（文档）/`translateNumberedBlocks`（逐块）——四条路径都各自做空输入校验与候选筛选，`attempt` 只被其中三条复用。 |

### 7.2 死代码 / 半死代码
- `LLMSessionStore.renameSession(id:title:)`、`clearAll()`、`snippet(from:around:radius:)`、`LLMSessionSearchHit`：**全仓无调用方**（会话列表/重命名/清空/搜索都没有 UI 入口）。
- `AICredentialJournalStore.entries(limit:)`：无 UI 调用（审计日志只能人工看文件）。
- `CredentialStore.configuredProviders()`：只有设置页统计用一行。
- 四家适配器的 `static let shared`：实际都通过 `LLMResolver.provider(for:)` 新建，`shared` 仅作占位。
- `TranslationProvider.stream(_:to:)` 的协议默认实现返回 nil；`QNWTranslationProvider`/`AppleTranslationProvider` 都没实现流式（预期行为，非缺陷）。
- `LLMResponseParsing.isTerminalLine` 默认 false 的"兜底"实际让 Gemini 落到超时路径。

### 7.3 风险（按危险度）
1. **`AIConnectionService.test` 临时改写全局 baseURL**（高，架构性）：`defer` 会还原，但在这段时间里**其它任何并发 AI 请求都会打到候选地址**。用户在设置页测试连接时，后台若有一次聊天或翻译在跑，就会被导流到候选 URL（可能是错的内网地址）。
2. **360 免 Key 通道默认开启**（高，隐私）：`auto` 模式下未配置 Key 时，用户翻译的**全文**会发到 `ai.api.360qnw.com`。UI 只在 Provider 描述里写"免 Key 免登录"，没有明确的外发提示。
3. **`QNWTranslator` 用 `URLSession.shared`**（中）：不可取消、不受 `LLMTransport` 的超时/取消管控；请求发出后即使调用方 Task 取消也会跑完 15s。
4. **`CredentialStore.setCredential` 同步加密落盘**（中）：每次保存跑 10 万轮 PBKDF2（30–80ms）+ 文件 I/O，主线程调用会卡顿（设置页点"保存"可感知）。
5. **`LLMService.send` 每 token 一次 `MainActor.run`**（中）：长回复（几千 token）会造成高频主线程调度与 SwiftUI 重排；`AIChatViewModel.performStream` 同样每 token 更新 `@Published`。
6. **`DatabaseManager.shared.bumpStat` 在 send 起始同步执行**（低-中）：若统计表写锁被占用，会拖慢首字延迟。
7. **`secretCache` 无失效**（低）：换 keystore 后需重启。
8. **`AISettingsPane.saveKey` 成功后 `hasStoredKey = true` 无条件置真**（低）：`persist` 失败只记日志不抛错，UI 会显示"已保存"但实际没落盘（下一次启动 key 消失）。
9. **`LLMService` 的 `_provider` 与 `AISettings` 存在时序窗口**（低）：`reload()` 与属性读取分离，切厂商瞬间可能用旧 provider 发一次请求。
10. **`LLMSessionStore` 直接依赖 `DatabaseManager.clipboard`**（架构性）：AI 模块与剪贴板模块共用同一个 SQLite 文件，跨模块隐式耦合（虽然只碰 `llm_*` 表）。
11. **`CustomAIToolStore` 用 Preferences 存 JSON 数组**（低）：工具数量多/提示词长时会把 UserDefaults plist 撑大（无上限、无校验）。
12. **`LegacyGeminiMigrator` 无条件清理旧键**（低）：即使本次没有搬迁成功（例如凭证写入失败），旧明文 key 也会被删掉 —— 数据丢失风险（一次性、影响面小）。
