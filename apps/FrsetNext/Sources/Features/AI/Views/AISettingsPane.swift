import SwiftUI
import AppKit

// MARK: - AI 设置页
//
// 服务参数与凭证归本页草稿，文本动作与提示词归 AI 文本工具页。

public final class AIProviderSettingsViewModel: SettingsEditableDraft {
    @Published public var provider: LLMProviderKind = AISettings.providerKind {
        didSet { configurationChanged(); models = LLMResolver.shared.cachedModels(for: provider) ?? [] }
    }
    @Published public var modelText = AISettings.selectedModel { didSet { configurationChanged() } }
    @Published public var models: [String] = []
    @Published public var isTesting = false
    @Published public var testResult: AIConnectionTestResult?
    @Published public var infoMessage: String?
    @Published private var baseURLs: [LLMProviderKind: String]
    @Published private var candidateKeys: [LLMProviderKind: String] = [:]
    @Published private var removedKeys: Set<LLMProviderKind> = []
    private var savedProvider = AISettings.providerKind
    private var savedModel = AISettings.selectedModel
    private var savedURLs: [LLMProviderKind: String]
    private let connectionService: AIProviderConnectionService
    private let credentialCoordinator: AICredentialCommitCoordinator
    private var configurationGeneration = 0

    public var baseURLText: String {
        get { baseURLs[provider]! }
        set { baseURLs[provider] = newValue; configurationChanged() }
    }
    public var apiKeyText: String {
        get { candidateKeys[provider] ?? "" }
        set {
            if newValue.isEmpty { candidateKeys.removeValue(forKey: provider) }
            else { candidateKeys[provider] = newValue }
            removedKeys.remove(provider)
            configurationChanged()
        }
    }
    public var hasStoredKey: Bool {
        !removedKeys.contains(provider) && credentialCoordinator.store.hasCredential(for: provider)
    }
    public var isDirty: Bool {
        provider != savedProvider || modelText != savedModel || baseURLs != savedURLs ||
        !candidateKeys.isEmpty || !removedKeys.isEmpty
    }

    public init(connectionService: AIProviderConnectionService = .shared,
                credentialCoordinator: AICredentialCommitCoordinator = .shared) {
        self.connectionService = connectionService
        self.credentialCoordinator = credentialCoordinator
        let current = Dictionary(uniqueKeysWithValues: LLMProviderKind.allCases.map {
            ($0, AISettings.baseURL(for: $0).absoluteString)
        })
        baseURLs = current
        savedURLs = current
        models = LLMResolver.shared.cachedModels(for: provider) ?? []
    }

    public func selectProvider(_ kind: LLMProviderKind) { provider = kind }

    public func removeKey() {
        candidateKeys.removeValue(forKey: provider)
        if credentialCoordinator.store.hasCredential(for: provider) { removedKeys.insert(provider) }
        configurationChanged()
        infoMessage = "已在草稿中移除密钥，保存后生效。"
    }

    public func save() -> String? {
        for key in candidateKeys.values {
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "请输入非空 API Key 后再保存。"
            }
        }
        let changed = isDirty
        for (kind, key) in candidateKeys where key.trimmingCharacters(in: .whitespacesAndNewlines) != credentialCoordinator.store.credential(for: kind) {
            if let reason = credentialCoordinator.commit(key, for: kind) { return "\(kind.displayName)：\(reason)" }
        }
        for kind in removedKeys where credentialCoordinator.store.hasCredential(for: kind) {
            if let reason = credentialCoordinator.remove(for: kind) { return "\(kind.displayName)：\(reason)" }
        }
        for kind in LLMProviderKind.allCases where baseURLs[kind] != savedURLs[kind] {
            AISettings.setBaseURL(baseURLs[kind]!, for: kind)
            AIProviderModelDiscoveryCache.shared.invalidate(kind)
        }
        if provider != savedProvider { AISettings.providerKind = provider }
        if modelText != savedModel { AISettings.selectedModel = modelText }
        guard UserDefaults.standard.synchronize() else { return "AI 服务设置写入磁盘失败，调整已保留" }
        candidateKeys = [:]
        removedKeys = []
        savedProvider = provider
        savedModel = modelText
        savedURLs = baseURLs
        if changed { LLMService.shared.reload() }
        return nil
    }

    public func discard() {
        provider = AISettings.providerKind
        modelText = AISettings.selectedModel
        baseURLs = Dictionary(uniqueKeysWithValues: LLMProviderKind.allCases.map {
            ($0, AISettings.baseURL(for: $0).absoluteString)
        })
        candidateKeys = [:]
        removedKeys = []
        savedProvider = provider
        savedModel = modelText
        savedURLs = baseURLs
        infoMessage = nil
        configurationChanged()
    }

    public func restoreDefaults() {
        provider = .anthropic
        modelText = ""
        baseURLs = Dictionary(uniqueKeysWithValues: LLMProviderKind.allCases.map {
            ($0, $0.defaultBaseURL.absoluteString)
        })
        candidateKeys = [:]
        removedKeys = []
        infoMessage = nil
        configurationChanged()
    }

    private func configurationChanged() {
        configurationGeneration += 1
        isTesting = false
        testResult = nil
    }

    /// 明确操作候选服务，不保存配置或凭证。
    public func testConnection() {
        guard !provider.needsCredential || !apiKeyText.isEmpty || hasStoredKey else {
            testResult = AIConnectionTestResult(ok: false, message: "请填写 API Key 后再测试服务。")
            return
        }
        isTesting = true
        testResult = nil
        let candidateKey = removedKeys.contains(provider) ? "" : (apiKeyText.isEmpty ? nil : apiKeyText)
        let candidateURL = baseURLText
        let candidateModel = modelText
        let kind = provider
        let generation = configurationGeneration
        Task { [self] in
            let result = await connectionService.test(provider: kind, baseURL: candidateURL,
                                                      model: candidateModel, apiKey: candidateKey)
            await MainActor.run {
                guard generation == self.configurationGeneration else { return }
                self.testResult = result
                self.isTesting = false
                if result.ok { self.models = result.models }
            }
        }
    }
}

public struct AISettingsPane: View {
    public init() {}
    public var body: some View {
        SettingsDraftEditor(id: "aiProvider", makeDraft: { AIProviderSettingsViewModel() }) { draft in
            AIProviderSettingsContent(vm: draft)
        }
    }
}

private struct AIProviderSettingsContent: View {
    @ObservedObject var vm: AIProviderSettingsViewModel
    var body: some View {
        VStack(spacing: 20) {
            SettingsSection("服务配置") {
                SettingsGroupBox {
                    SettingsRow(title: "服务商") {
                        Picker("", selection: Binding(get: { vm.provider }, set: { vm.selectProvider($0) })) {
                            ForEach(LLMProviderKind.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Base URL", subtitle: "留空使用厂商默认地址") {
                        TextField("https://…", text: $vm.baseURLText).textFieldStyle(.roundedBorder)
                    }
                    Text(providerHint).font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
            SettingsSection("凭证") {
                SettingsGroupBox {
                    SettingsRow(title: "API Key") {
                        SecureField(vm.provider.needsCredential ? "保存后不再明文显示" : "本地服务无需密钥",
                                    text: $vm.apiKeyText).textFieldStyle(.roundedBorder)
                        Button("移除（待保存）") { vm.removeKey() }
                            .controlSize(.small).disabled(!vm.hasStoredKey && vm.apiKeyText.isEmpty)
                    }
                    HStack {
                        Label(vm.hasStoredKey ? "已有已保存密钥" : vm.provider.needsCredential ? "尚未保存密钥" : "无需密钥",
                              systemImage: vm.hasStoredKey ? "checkmark.shield.fill" : "lock")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    Text("密钥沿用现有加密凭证存储，仅在本页保存时提交，不进入配置导出。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 8)
                }
            }
            SettingsSection("模型") {
                SettingsGroupBox {
                    SettingsRow(title: "模型名称", subtitle: "留空跟随厂商默认模型") {
                        Menu {
                            if vm.models.isEmpty { Text("测试服务后获取模型清单") }
                            ForEach(vm.models, id: \.self) { item in
                                Button(item) { vm.modelText = item }
                            }
                        } label: { Text("模型清单") }
                        .menuStyle(.borderlessButton).fixedSize()
                        TextField("手动输入模型名", text: $vm.modelText).textFieldStyle(.roundedBorder)
                    }
                }
            }
            SettingsSection("测试服务 · 即时操作") {
                SettingsGroupBox {
                    SettingsRow(title: "测试服务") {
                        Button { vm.testConnection() } label: {
                            HStack(spacing: 6) {
                                if vm.isTesting { ProgressView().controlSize(.small) }
                                Text(vm.isTesting ? "测试中…" : "测试服务并获取模型")
                            }
                        }
                        .controlSize(.small).disabled(vm.isTesting)
                    }
                    if let result = vm.testResult {
                        Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 11)).foregroundStyle(result.ok ? Color.green : Color.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "耗时 %.2fs", result.elapsed))
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 6)
                    }
                    if let info = vm.infoMessage {
                        Text(info).font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 6)
                    }
                    Text("立即请求草稿中的服务地址与密钥；模型目录不可用时发送一次短对话。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
        }
        .font(.system(size: 13))
    }
    private var providerHint: String {
        switch vm.provider {
        case .anthropic: return "默认 https://api.anthropic.com，鉴权使用 x-api-key。"
        case .gemini: return "默认 https://generativelanguage.googleapis.com，密钥通过 URL 参数传递。"
        case .openAICompatible: return "支持 OpenAI 协议网关（DeepSeek / 月之暗面 / 智谱 / Groq 等）。"
        case .ollama: return "默认 http://localhost:11434，本地服务无需密钥；模型需先执行 ollama pull。"
        }
    }
}
