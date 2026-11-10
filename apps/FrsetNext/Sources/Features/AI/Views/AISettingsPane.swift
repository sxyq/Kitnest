import SwiftUI
import AppKit

// MARK: - AI 设置页
//
// 注册到 SettingsPaneRegistry（id: "ai"）：厂商 / Base URL / 模型 / API Key / 连接测试 / 默认动作。

public final class AIProviderSettingsViewModel: ObservableObject {
    @Published public var provider: LLMProviderKind = AISettings.providerKind
    @Published public var baseURLText: String = AISettings.baseURL(for: AISettings.providerKind).absoluteString
    @Published public var modelText: String = AISettings.selectedModel
    @Published public var apiKeyText: String = ""
    @Published public var models: [String] = []
    @Published public var isTesting: Bool = false
    @Published public var isLoadingModels: Bool = false
    @Published public var testResult: AIConnectionTestResult?
    @Published public var hasStoredKey: Bool = false

    @Published public var infoMessage: String?

    // 自定义工具管理
    @Published public var customTools: [CustomAITool] = []
    @Published public var newToolName: String = ""
    @Published public var newToolSystemPrompt: String = ""
    @Published public var newToolTemplate: String = "请处理以下内容：\n\n{input}"

    private let connectionService: AIProviderConnectionService
    private let credentialCoordinator: AICredentialCommitCoordinator
    private var configurationGeneration = 0

    public init(connectionService: AIProviderConnectionService = .shared,
                credentialCoordinator: AICredentialCommitCoordinator = .shared) {
        self.connectionService = connectionService
        self.credentialCoordinator = credentialCoordinator
        self.customTools = CustomAIToolStore.shared.all()
    }


    public func reload() {
        configurationGeneration += 1
        isTesting = false
        isLoadingModels = false
        infoMessage = nil
        provider = AISettings.providerKind
        baseURLText = AISettings.baseURL(for: provider).absoluteString
        modelText = AISettings.selectedModel
        hasStoredKey = CredentialStore.shared.hasCredential(for: provider)
        apiKeyText = ""
        models = LLMResolver.shared.cachedModels(for: provider) ?? []
        testResult = nil
        customTools = CustomAIToolStore.shared.all()
    }

    // MARK: 厂商 / 地址

    public func selectProvider(_ kind: LLMProviderKind) {
        provider = kind
        AISettings.providerKind = kind
        // 切换厂商后立即重建门面，保证 ServiceLocator 里注入的实例同步更新
        LLMService.shared.reload()
        reload()
    }

    public func commitBaseURL() {
        AISettings.setBaseURL(baseURLText, for: provider)
        AIProviderModelDiscoveryCache.shared.invalidate(provider)
        LLMService.shared.reload()
        infoMessage = "服务地址已保存。"
    }

    // MARK: 凭证

    public func saveKey() {
        let key = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            infoMessage = "请输入 API Key 后再保存。"
            return
        }
        // 走协调器：写入凭证的同时登记一条审计日志（只记指纹，不记明文）
        credentialCoordinator.commit(key, for: provider)
        apiKeyText = ""
        hasStoredKey = true
        infoMessage = "API Key 已加密保存（应用数据目录，权限 0600），并已记录提交审计日志。"
        LLMService.shared.reload()
    }

    public func removeKey() {
        credentialCoordinator.remove(for: provider)
        hasStoredKey = false
        infoMessage = "已删除该厂商的 API Key，并已记录提交审计日志。"
        LLMService.shared.reload()
    }

    // MARK: 自定义工具

    public func addCustomTool() {
        let name = newToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = newToolSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = newToolTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !template.isEmpty else {
            infoMessage = "自定义工具需要填写名称与提示词模板。"
            return
        }
        CustomAIToolStore.shared.upsert(CustomAITool(name: name,
                                                     systemPrompt: system,
                                                     promptTemplate: template))
        customTools = CustomAIToolStore.shared.all()
        newToolName = ""
        newToolSystemPrompt = ""
        newToolTemplate = "请处理以下内容：\n\n{input}"
        infoMessage = "自定义工具「\(name)」已保存，可在文本工具面板中使用。"
    }

    public func deleteCustomTool(id: String) {
        CustomAIToolStore.shared.delete(id: id)
        customTools = CustomAIToolStore.shared.all()
        infoMessage = "已删除自定义工具。"
    }

    // MARK: 模型

    public func refreshModels() {
        isLoadingModels = true
        let kind = provider
        let generation = configurationGeneration
        Task { [self] in
            do {
                let list = try await LLMResolver.shared.availableModels(for: kind, forceRefresh: true)
                await MainActor.run {
                    guard generation == self.configurationGeneration else { return }
                    self.models = list
                    self.isLoadingModels = false
                    self.infoMessage = "已拉取 \(list.count) 个模型。"
                }
            } catch {
                await MainActor.run {
                    guard generation == self.configurationGeneration else { return }
                    self.isLoadingModels = false
                    self.infoMessage = "拉取模型列表失败：\(error.localizedDescription)"
                }
            }
        }
    }

    public func commitModel() {
        AISettings.selectedModel = modelText
        LLMService.shared.reload()
    }

    // MARK: 连接测试

    /// 测试「当前页面上尚未保存的候选配置」，不污染已保存内容
    public func testConnection() {
        guard !provider.needsCredential || !apiKeyText.isEmpty || hasStoredKey else {
            testResult = AIConnectionTestResult(ok: false, message: "请先填写 API Key 再测试连接。")
            return
        }
        isTesting = true
        testResult = nil
        let candidateKey = apiKeyText.isEmpty ? nil : apiKeyText
        let candidateURL = baseURLText
        let candidateModel = modelText
        let kind = provider
        let generation = configurationGeneration
        Task { [self] in
            let result = await connectionService.test(provider: kind,
                                                      baseURL: candidateURL,
                                                      model: candidateModel,
                                                      apiKey: candidateKey)
            await MainActor.run {
                guard generation == self.configurationGeneration else { return }
                self.testResult = result
                self.isTesting = false
                if result.ok, !result.models.isEmpty {
                    self.models = result.models
                }
                self.hasStoredKey = CredentialStore.shared.hasCredential(for: kind)
            }
        }
    }
}

public struct AISettingsPane: View {
    @StateObject private var vm = AIProviderSettingsViewModel()

    public init() {}

    public var body: some View {
        // 2026-10-20 统一版式：原 `Form(.grouped)` 在 macOS 会自绘整页纯白底，
        // 与其它设置页「灰底 + 浅色圆角卡片」不一致；改用共用组件（同常规/数据/剪贴板页）。
        VStack(spacing: 20) {
            SettingsSection("服务商") {
                SettingsGroupBox {
                    SettingsRow(title: "服务商") {
                        Picker("", selection: Binding(
                            get: { vm.provider },
                            set: { vm.selectProvider($0) })) {
                            ForEach(LLMProviderKind.allCases, id: \.rawValue) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Base URL")
                                .font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 8)
                            Text("留空使用默认")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        HStack(spacing: 8) {
                            TextField("https://…", text: $vm.baseURLText)
                                .textFieldStyle(.roundedBorder)
                            Button("应用") { vm.commitBaseURL() }
                                .controlSize(.small)
                        }
                        Text(providerHint)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 9)
                }
            }

            SettingsSection("凭证") {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsGroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            SecureField(vm.provider == .ollama ? "本地服务无需密钥" : "API Key（保存后不再明文显示）",
                                        text: $vm.apiKeyText)
                                .textFieldStyle(.roundedBorder)
                            HStack(spacing: 8) {
                                if vm.hasStoredKey {
                                    Label("已保存密钥", systemImage: "checkmark.shield.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.green)
                                } else {
                                    Label(vm.provider.needsCredential ? "尚未配置密钥" : "无需密钥",
                                          systemImage: vm.provider.needsCredential ? "exclamationmark.shield.fill" : "lock.open.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(vm.provider.needsCredential ? .orange : .secondary)
                                }
                                Spacer()
                                Button("删除") { vm.removeKey() }
                                    .controlSize(.small)
                                    .disabled(!vm.hasStoredKey)
                                Button("保存") { vm.saveKey() }
                                    .controlSize(.small)
                                    .disabled(vm.apiKeyText.isEmpty)
                            }
                        }
                        .padding(.vertical, 9)
                    }
                    Text("密钥保存在应用数据目录的 AES-256 加密文件中（权限 0600），不使用系统钥匙串，因此不会触发授权弹窗。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.leading, 2)
                }
            }

            SettingsSection("模型") {
                SettingsGroupBox {
                    HStack(spacing: 8) {
                        Menu {
                            if vm.models.isEmpty {
                                Text("点击右侧刷新拉取模型")
                            } else {
                                ForEach(vm.models, id: \.self) { item in
                                    Button(item) { vm.modelText = item; vm.commitModel() }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(vm.modelText.isEmpty ? "跟随厂商默认模型" : vm.modelText)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()

                        TextField("手动输入模型名", text: $vm.modelText, onCommit: { vm.commitModel() })
                            .textFieldStyle(.roundedBorder)

                        Button {
                            vm.refreshModels()
                        } label: {
                            HStack(spacing: 4) {
                                if vm.isLoadingModels { ProgressView().controlSize(.small) }
                                Text("刷新")
                            }
                        }
                        .controlSize(.small)
                        .disabled(vm.isLoadingModels)
                    }
                    .padding(.vertical, 9)
                }
            }

            SettingsSection("连通性") {
                SettingsGroupBox {
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            vm.testConnection()
                        } label: {
                            HStack(spacing: 6) {
                                if vm.isTesting { ProgressView().controlSize(.small) }
                                Text(vm.isTesting ? "测试中…" : "测试连接")
                            }
                        }
                        .controlSize(.small)
                        .disabled(vm.isTesting)

                        if let result = vm.testResult {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(result.ok ? Color.green : Color.red)
                                Text(String(format: "耗时 %.2fs", result.elapsed))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 9)

                    if let info = vm.infoMessage {
                        HStack {
                            Text(info)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 3)
                    }
                }
            }

            SettingsSection("文本工具") {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsGroupBox {
                        SettingsRow(title: "默认动作") {
                            Picker("", selection: Binding(
                                get: { AISummaryAction.storedDefault },
                                set: { $0.saveAsDefault() })) {
                                ForEach(AISummaryAction.allCases) { action in
                                    Text(action.title).tag(action)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                    }
                    Text("面板「AI → 摘要 / 润色 / 翻译」的默认入口动作。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.leading, 2)
                }
            }

            SettingsSection("自定义工具") {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsGroupBox {
                        if vm.customTools.isEmpty {
                            Text("尚未定义自定义工具。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 10)
                        } else {
                            ForEach(vm.customTools) { tool in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(tool.name).font(.system(size: 12, weight: .medium))
                                        Text(tool.systemPrompt.isEmpty ? tool.promptTemplate : tool.systemPrompt)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.tertiaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Button("删除") { vm.deleteCustomTool(id: tool.id) }
                                        .controlSize(.small)
                                }
                                .padding(.vertical, 6)
                                SettingsDivider()
                            }
                        }

                        VStack(spacing: 8) {
                            TextField("工具名称", text: $vm.newToolName)
                                .textFieldStyle(.roundedBorder)
                            TextField("系统提示词（可选）", text: $vm.newToolSystemPrompt)
                                .textFieldStyle(.roundedBorder)
                            TextField("提示词模板，用 {input} 代表待处理文本", text: $vm.newToolTemplate, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...4)
                        }
                        .padding(.vertical, 9)

                        HStack {
                            Spacer()
                            Button("添加自定义工具") { vm.addCustomTool() }
                                .controlSize(.small)
                                .disabled(vm.newToolName.trimmingCharacters(in: .whitespaces).isEmpty
                                          || vm.newToolTemplate.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.bottom, 6)
                    }
                    Text("定义后会在文本工具面板中显示为独立按钮，与内置动作并列。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.leading, 2)
                }
            }
        }
        .font(.system(size: 13))
        .onAppear { vm.reload() }
    }

    private var providerHint: String {
        switch vm.provider {
        case .anthropic:
            return "默认 https://api.anthropic.com，鉴权走 x-api-key 请求头。"
        case .gemini:
            return "默认 https://generativelanguage.googleapis.com，API Key 通过 URL 参数传递。"
        case .openAICompatible:
            return "可填任意 OpenAI 协议网关（DeepSeek / 月之暗面 / 智谱 / Groq 等），只需填到域名即可。"
        case .ollama:
            return "默认 http://localhost:11434，本地运行无需密钥；模型需先执行 ollama pull。"
        }
    }
}
