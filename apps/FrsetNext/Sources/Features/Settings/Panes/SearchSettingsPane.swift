import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - 搜索设置页（specs/18 §4 行集合，页签 id "search"）
//
// 行集合自上而下（对齐原作代码地址序推断）：
// 1. 搜索栏区：调整搜索栏（编辑模式入口）+ 搜索栏项目列表（**拖拽排序** / 移除，至少保留 1 项）
// 2. 搜索引擎区：全量引擎逐行排序 + 添加到/从搜索栏移除 + 自定义引擎（三连校验 / 行内编辑 / 删除）
// 3. 行为区：「搜索或打开链接后清空输入框」开关（clearSearchInputAfterWebAction）
// 4. 底部：统一草稿保存、取消与恢复默认（切页不应用）
//
// 交互对齐（缺口 SE-3 / SE-2 / SE-7）：
// - SE-3：原作是**拖拽排序**（specs/18 §4 锚点 SearchBarOrderingTipCoordinateSpace + 'Search Bar Reorder Tip'），
//   此处用 SwiftUI `.onDrag` / `.onDrop(of:delegate:)` 实现，数据侧挂 SearchServiceManager.moveInSearchBar(fromOffsets:toOffset:)。
// - SE-2：原作自定义引擎有行内编辑表单（SearchServiceManager.__editingEngine，specs/18 §4 @0x100502288-0x100503cd4）。
// - SE-7：引擎区可排序（SearchServiceManager.moveEngine 已有数据方法，此前零 UI 调用点）。

struct SearchSettingsPane: View {
    var body: some View {
        SettingsDraftEditor(id: "searchDisplay", makeDraft: { SearchDisplayDraft() }) { draft in
            SearchSettingsContent(draft: draft)
        }
    }
}

final class SearchDisplayDraft: SettingsEditableDraft {
    let service = SearchServiceManager.shared.makeDraft()
    @Published var showWeb = true
    @Published var showClipboard = true
    @Published var showFiles = true
    @Published var isAddingCustomEngine = false
    @Published var newEngineName = ""
    @Published var newEngineURL = SearchServiceManager.customEngineURLPlaceholder
    @Published var formErrorMessage: String?
    @Published var editingEngineID: String?
    @Published var editEngineName = ""
    @Published var editEngineURL = ""
    @Published var editErrorMessage: String?
    private var observation: AnyCancellable?
    private var savedDisplay: [Bool] = []
    private var displayValues: [Bool] { [showWeb, showClipboard, showFiles, service.clearSearchInputAfterWebAction] }

    init() {
        discard()
        observation = service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var isDirty: Bool {
        if isAddingCustomEngine && (!newEngineName.isEmpty || newEngineURL != SearchServiceManager.customEngineURLPlaceholder) { return true }
        if let engine = service.customEngines.first(where: { $0.id == editingEngineID }),
           editEngineName != engine.name || editEngineURL != engine.urlTemplate { return true }
        let saved = SearchServiceManager.shared
        return service.allEngines != saved.allEngines || service.activeBarItems != saved.activeBarItems
            || service.clearSearchInputAfterWebAction != saved.clearSearchInputAfterWebAction
            || displayValues != savedDisplay
    }

    func save() -> String? {
        if isAddingCustomEngine {
            saveCustomEngine()
            if let reason = formErrorMessage { return reason }
        }
        if let engine = service.customEngines.first(where: { $0.id == editingEngineID }) {
            saveEngineEdit(engine)
            if let reason = editErrorMessage { return reason }
        }
        if let reason = SearchServiceManager.shared.applyDraft(service) { return reason }
        let defaults = UserDefaults.standard
        if showWeb != savedDisplay[0] { defaults.set(showWeb, forKey: Preferences.Keys.searchCategoryWeb) }
        if showClipboard != savedDisplay[1] { defaults.set(showClipboard, forKey: Preferences.Keys.searchCategoryClipboard) }
        if showFiles != savedDisplay[2] { defaults.set(showFiles, forKey: Preferences.Keys.searchCategoryFiles) }
        guard defaults.synchronize() else { return "搜索设置写入磁盘失败，调整已保留" }
        savedDisplay = displayValues
        objectWillChange.send()
        return nil
    }

    func discard() {
        isAddingCustomEngine = false
        clearForm()
        cancelEditing()
        service.copyValues(from: .shared)
        showWeb = categoryValue(Preferences.Keys.searchCategoryWeb)
        showClipboard = categoryValue(Preferences.Keys.searchCategoryClipboard)
        showFiles = categoryValue(Preferences.Keys.searchCategoryFiles)
        savedDisplay = displayValues
    }

    func restoreDefaults() {
        isAddingCustomEngine = false
        clearForm()
        cancelEditing()
        service.resetToDefaults()
        service.clearSearchInputAfterWebAction = true
        showWeb = true
        showClipboard = true
        showFiles = true
    }

    func isDirty(in scope: String) -> Bool { displayValues != savedDisplay }
    func restoreDefaults(in scope: String) {
        showWeb = true; showClipboard = true; showFiles = true
        service.clearSearchInputAfterWebAction = true
    }
    func discard(in scope: String) {
        showWeb = categoryValue(Preferences.Keys.searchCategoryWeb)
        showClipboard = categoryValue(Preferences.Keys.searchCategoryClipboard)
        showFiles = categoryValue(Preferences.Keys.searchCategoryFiles)
        service.clearSearchInputAfterWebAction = SearchServiceManager.shared.clearSearchInputAfterWebAction
        savedDisplay = displayValues
    }
    func save(in scope: String) -> String? {
        let defaults = UserDefaults.standard
        if showWeb != savedDisplay[0] { defaults.set(showWeb, forKey: Preferences.Keys.searchCategoryWeb) }
        if showClipboard != savedDisplay[1] { defaults.set(showClipboard, forKey: Preferences.Keys.searchCategoryClipboard) }
        if showFiles != savedDisplay[2] { defaults.set(showFiles, forKey: Preferences.Keys.searchCategoryFiles) }
        if service.clearSearchInputAfterWebAction != savedDisplay[3] {
            SearchServiceManager.shared.clearSearchInputAfterWebAction = service.clearSearchInputAfterWebAction
        }
        guard defaults.synchronize() else { return "搜索展示设置写入磁盘失败，调整已保留" }
        savedDisplay = displayValues
        objectWillChange.send()
        return nil
    }

    /// 三连校验：仅字母数字 / 名称长度上限 / URL 含 {query} 且可解析
    /// - Parameter excludingID: URL 查重时排除的引擎 id（编辑态排除自身）
    /// - Returns: 错误文案；nil = 通过
    private func validateEngineForm(name: String, url: String, excludingID: String?) -> String? {
        guard !name.isEmpty else { return "请输入搜索引擎名称" }
        // ① 名称仅字母数字（原作 "Only letters and numbers allowed" @0x100508200）
        guard name.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return L10n.t("Only letters and numbers allowed")
        }
        // ② 名称长度上限（原作 "Name Too Long Limit" @0x100500ff0）
        guard name.count <= SearchServiceManager.customEngineNameLimit else {
            return L10n.t("Name Too Long Limit")
        }
        // ③ URL 含 {query} 占位符且格式合法（原作 "Invalid URL Format" @0x1005041e8）
        guard url.contains("{query}"),
              url.contains("://"),
              URL(string: url.replacingOccurrences(of: "{query}", with: "test")) != nil else {
            return L10n.t("Invalid URL Format")
        }
        guard !service.allEngines.contains(where: { $0.urlTemplate == url && $0.id != excludingID }) else {
            return "已存在相同 URL 的搜索引擎"
        }
        return nil
    }

    func saveCustomEngine() {
        let name = newEngineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = newEngineURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if let message = validateEngineForm(name: name, url: url, excludingID: nil) {
            formErrorMessage = message
            return
        }
        service.addCustomEngine(name: name, urlTemplate: url)
        clearForm()
        isAddingCustomEngine = false
    }

    func clearForm() {
        newEngineName = ""
        newEngineURL = SearchServiceManager.customEngineURLPlaceholder
        formErrorMessage = nil
    }

    // MARK: 引擎行内编辑（原作 __editingEngine）

    func beginEditing(_ engine: SearchEngine) {
        editingEngineID = engine.id
        editEngineName = engine.name
        editEngineURL = engine.urlTemplate
        editErrorMessage = nil
    }

    func cancelEditing() {
        editingEngineID = nil
        editEngineName = ""
        editEngineURL = ""
        editErrorMessage = nil
    }

    func saveEngineEdit(_ engine: SearchEngine) {
        let name = editEngineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = editEngineURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if let message = validateEngineForm(name: name, url: url, excludingID: engine.id) {
            editErrorMessage = message
            return
        }
        service.updateCustomEngine(id: engine.id, name: name, urlTemplate: url)
        cancelEditing()
    }

    private func categoryValue(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

private struct SearchSettingsContent: View {
    @ObservedObject var draft: SearchDisplayDraft
    /// 引擎数据中心（原作 SearchServiceManager 等价，实现在 Models/SearchEngine.swift）
    @ObservedObject private var service: SearchServiceManager
    @Stored private var showsPreview = true
    @Stored private var previewQuery = "设计"
    @Stored private var notice: String?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Stored private var translationPreference = AISettings.translationProviderPreference

    init(draft: SearchDisplayDraft) {
        self.draft = draft
        self.service = draft.service
    }

    // 编辑模式（搜索栏拖拽/增删）
    @Stored private var isEditingSearchBar = true
    /// 正在拖拽的搜索栏引擎 id（非空 = 拖拽进行中，用于隐藏插入位提示行）
    @Stored private var draggingSearchBarID: String? = nil
    /// 拖拽悬停的目标引擎 id（落点高亮）
    @Stored private var searchBarDropTargetID: String? = nil
    // 删除自定义引擎（确认弹窗承接）
    @Stored private var enginePendingDelete: SearchEngine? = nil
    /// v47：首页搜索分类开关（首页分类行的眼睛按钮与此处共用同一批键）。
    /// 网页分类含 WKWebView 内嵌预览；本地文件走系统 Spotlight（mdfind，Everything 的 macOS 对应物）。
    private var searchCategorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("首页搜索分类")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 22) {
                Toggle("网页搜索（引擎 + 内嵌预览）", isOn: $draft.showWeb)
                    .toggleStyle(.checkbox)
                Toggle("剪贴板历史", isOn: $draft.showClipboard)
                    .toggleStyle(.checkbox)
                Toggle("本地文件（Spotlight）", isOn: $draft.showFiles)
                    .toggleStyle(.checkbox)
            }
            Text("关闭的分类不在首页搜索结果中出现；首页分类行右侧的眼睛按钮同样可快速隐藏/显示。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
        // 2026-10-20 统一版式：设置页统一「浅色圆角卡片」，与常规/剪贴板页同构
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: Theme.cornerRadius)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            translationPrivacySection
            searchCategorySection
            Toggle(L10n.t("Clear input after searching or opening links"), isOn: $service.clearSearchInputAfterWebAction)
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("实时预览").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle("显示预览", isOn: $showsPreview).toggleStyle(.checkbox)
                }
                if showsPreview {
                    HStack(spacing: 6) {
                        Text("场景").font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(["设计", "SwiftUI", "/uuid"], id: \.self) { query in
                            Button(query) { previewQuery = query }
                                .buttonStyle(.bordered).controlSize(.mini)
                                .accessibilityLabel("预览场景：" + query)
                        }
                    }
                    SearchSectionView(draft: draft, query: $previewQuery)
                        .environment(\.isSettingsPreview, true)
                        .environment(\.settingsPreviewClipboardItems, SettingsPreviewSamples.clipboardItems)
                    Text("固定示例 · 输入、分类和引擎即时更新；演示操作不打开网页或复制真实内容。保存后应用到正式搜索。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .glassCard(radius: Theme.cornerRadius,
                       fill: reduceTransparency ? Color(nsColor: .controlBackgroundColor) : nil)
            if let notice { Text(notice).font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(L10n.t("Name")).frame(width: 142, alignment: .leading)
                    Text(L10n.t("URL")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.t("More"))
                }
                .foregroundStyle(.secondary)
                .frame(height: 26)
                LazyVStack(spacing: 0) {
                    ForEach(Array(service.allEngines.enumerated()), id: \.element.id) { index, engine in
                        engineRow(engine, index: index)
                        if draft.editingEngineID == engine.id { engineEditForm(engine) }
                        Divider()
                    }
                    if draft.isAddingCustomEngine { customEngineForm }
                }
                HStack(spacing: 36) {
                    Button {
                        draft.isAddingCustomEngine.toggle()
                        if draft.isAddingCustomEngine { draft.clearForm() }
                    } label: { Label(L10n.t("Custom Search"), systemImage: "plus") }
                }
                .buttonStyle(.link)
                .frame(height: 40)
            }
            .frame(minWidth: 380, maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassCard(radius: Theme.cornerRadius)
            Divider()
            VStack(spacing: 10) {
                Text(L10n.t("Search Bar")).foregroundStyle(.secondary).frame(height: 26)
                LazyVStack(spacing: 0) {
                    ForEach(service.activeBarEngines) { engine in
                        searchBarRow(engine)
                    }
                }
            }
            // v41：设置窗侧边栏版式内容区略窄，右侧搜索栏列给最小宽度，避免引擎名换行
            // 先加内边距再取剩余宽度：否则 maxWidth 先占满、padding 再外扩 24pt 会溢出窗口
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassCard(radius: Theme.cornerRadius)
            .frame(width: 210)
            }
        }
        .font(.system(size: 13))
        .coordinateSpace(name: "SearchBarOrderingTipCoordinateSpace")   // 原作提示锚点同名
        // 「删除搜索引擎」未在 793 键表命中（原版可能为代码拼接或动态串），保留直写
        .confirmationDialog("删除搜索引擎", isPresented: deleteConfirmBinding, titleVisibility: .visible) {
            Button(L10n.t("Delete"), role: .destructive) { performDeletePendingEngine() }
            Button(L10n.t("Cancel"), role: .cancel) {}
        } message: {
            Text("从草稿删除「\(enginePendingDelete?.name ?? "")」；保存后生效，取消可恢复。")
        }
    }

    private var translationPrivacySection: some View {
        SettingsSection("翻译服务与隐私") {
            SettingsGroupBox {
                SettingsRow(title: "默认翻译服务") {
                    Picker("默认翻译服务", selection: Binding(
                        get: { AISettings.translationProviderPreference },
                        set: { AISettings.translationProviderPreference = $0; translationPreference = $0 }
                    )) {
                        Text("自动（按授权服务回退）").tag(AISettings.translationAutoPreference)
                        ForEach(TranslationProviderRegistry.shared.all, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }.labelsHidden().frame(width: 230)
                }
                SettingsDivider()
                Toggle("允许在线翻译服务发送所选文字", isOn: Binding(
                    get: { TranslationPrivacyConsent.isOnlineAllowed },
                    set: { TranslationPrivacyConsent.setOnlineAllowed($0) }
                )).toggleStyle(.checkbox)
                Text("Apple 系统翻译在本机处理；AI 和 360 快速通道会联网。首次使用在线服务时会说明发送内容并询问授权。拒绝后自动模式只尝试本机服务。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                Text("当前可用服务：\(TranslationToolSession.shared.effectiveProviderName)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    /// 删除确认弹窗绑定（enginePendingDelete 非空即呈现）
    private var deleteConfirmBinding: Binding<Bool> {
        Binding(get: { enginePendingDelete != nil }, set: { if !$0 { enginePendingDelete = nil } })
    }

    // MARK: - 1. 搜索栏区

    /// 搜索栏项目行：编辑模式整行可拖（拖拽手柄 + 落位高亮）；两种模式都可移除
    private func searchBarRow(_ engine: SearchEngine) -> some View {
        let isDropTarget = isEditingSearchBar && searchBarDropTargetID == engine.id
        return HStack(spacing: 10) {
            if isEditingSearchBar {
                // 拖拽手柄（提示这是可拖动的行）
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Text(engine.name)
                .font(.system(size: 13))
                .fontWeight(isEditingSearchBar ? .medium : .regular)
                .lineLimit(1)
            Spacer()
            Button {
                removeFromSearchBar(engine)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.t("Remove from Search Bar"))
        }
        .frame(height: 34)
        .padding(.horizontal, 0)
        .background(
            RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                .fill(isDropTarget ? Theme.accent.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        // 拖拽源：整行可拖，排序只作用于草稿
        .onDrag {
            draggingSearchBarID = engine.id
            return NSItemProvider(object: engine.id as NSString)
        } preview: {
            HStack(spacing: 6) {
                engineIcon(engine, size: 13)
                Text(engine.name).font(.system(size: 13))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassCard(radius: Theme.smallRadius)
        }
        // 落位目标：非编辑模式传入空类型列表，等价于关闭本行的接收
        .onDrop(of: isEditingSearchBar ? [UTType.text] : [], delegate: searchBarDropDelegate(targetID: engine.id))
    }

    /// 拖拽落位代理：悬停即换位（对齐 List.onMove 的实时跟手感）。
    /// order / draggingID 均在**落位瞬间**实时读取，避免拖拽过程中多次换位后读到过期快照。
    private func searchBarDropDelegate(targetID: String) -> SearchBarReorderDelegate {
        SearchBarReorderDelegate(
            targetID: targetID,
            currentOrder: { service.activeBarItems },
            currentDraggingID: { draggingSearchBarID },
            setDraggingID: { draggingSearchBarID = $0 },
            setDropTargetID: { searchBarDropTargetID = $0 },
            move: { fromOffsets, toOffset in
                service.moveInSearchBar(fromOffsets: fromOffsets, toOffset: toOffset)
            }
        )
    }

    /// 从搜索栏移除；最后 1 项时阻止并提示（原作 "Search Bar Minimum Alert"）
    private func removeFromSearchBar(_ engine: SearchEngine) {
        notice = service.removeFromSearchBar(engineID: engine.id) ? nil : L10n.t("Search Bar Minimum Alert")
    }

    // MARK: - 2. 搜索引擎区

    private func engineRow(_ engine: SearchEngine, index: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                engineIcon(engine)
                Text(engine.name)
            }
            .frame(width: 142, alignment: .leading)
            Text(engine.urlTemplate)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if service.activeBarItems.contains(engine.id) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
            }
            Menu {
                if service.activeBarItems.contains(engine.id) {
                    Button(L10n.t("Remove from Search Bar")) { removeFromSearchBar(engine) }
                } else {
                    Button(L10n.t("Add to Search Bar")) { addToSearchBar(engine) }
                }
                Button("上移") { service.moveEngine(engineID: engine.id, up: true) }
                    .disabled(index == 0)
                Button("下移") { service.moveEngine(engineID: engine.id, up: false) }
                    .disabled(index == service.allEngines.count - 1)
                if !engine.isBuiltIn {
                    Button(L10n.t("Edit")) { draft.beginEditing(engine) }
                    Button(L10n.t("Delete"), role: .destructive) { enginePendingDelete = engine }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .frame(height: 46)
    }

    private func addToSearchBar(_ engine: SearchEngine) {
        service.addToSearchBar(engineID: engine.id)
    }

    /// 引擎图标：统一 SF Symbol。
    /// v42（2026-10-18 用户指示）：**不采用官方品牌 logo**——项目既有图标体系已统一，
    /// 不再为"对齐官方"引入一套彩色位图（Resources/BrandLogos 保留备用，不再引用）。
    private func engineIcon(_ engine: SearchEngine, size: CGFloat = 14) -> some View {
        Image(systemName: engine.systemImage)
            .font(.system(size: size - 2))
            .frame(width: 16)
    }

    // MARK: 自定义引擎表单（三连校验，specs/18 §4.1）

    private var customEngineForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            engineFormFields(name: $draft.newEngineName,
                             url: $draft.newEngineURL,
                             errorMessage: $draft.formErrorMessage,
                             placeholder: SearchServiceManager.customEngineURLPlaceholder)
            HStack {
                Spacer()
                Button("添加到草稿") { draft.saveCustomEngine() }
                    .controlSize(.small)
                    .disabled(draft.newEngineName.isEmpty || draft.newEngineURL.isEmpty)
            }
        }
        .padding(.vertical, 6)
    }

    /// 引擎编辑表单（行内展开；复用与新增完全相同的三连校验）
    private func engineEditForm(_ engine: SearchEngine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            engineFormFields(name: $draft.editEngineName,
                             url: $draft.editEngineURL,
                             errorMessage: $draft.editErrorMessage,
                             placeholder: SearchServiceManager.customEngineURLPlaceholder)
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.t("Cancel")) { draft.cancelEditing() }
                    .controlSize(.small)
                Button("应用到草稿") { draft.saveEngineEdit(engine) }
                    .controlSize(.small)
                    .disabled(draft.editEngineName.isEmpty || draft.editEngineURL.isEmpty)
            }
        }
        .padding(.vertical, 6)
    }

    /// 表单字段（名称 + URL + 错误位 + 占位符提示）
    private func engineFormFields(name: Binding<String>,
                                  url: Binding<String>,
                                  errorMessage: Binding<String?>,
                                  placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("Name")).font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("例如：MySearch", text: name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("搜索 URL").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(placeholder, text: url)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text(L10n.t("Use {query} for search term"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            if let message = errorMessage.wrappedValue {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: 删除自定义引擎

    private func performDeletePendingEngine() {
        guard let engine = enginePendingDelete else { return }
        if draft.editingEngineID == engine.id { draft.cancelEditing() }
        service.deleteCustomEngine(engineID: engine.id)
        enginePendingDelete = nil
    }
}

// MARK: - 搜索栏拖拽排序代理
//
// 悬停即换位（拖到目标行边界时调用 move(fromOffsets:toOffset:)），与 List.onMove 的跟手感一致。
// 落位换算规则：`toOffset` 取「移除前」数组坐标——向下拖传 `to + 1`，向上拖传 `to`。
private struct SearchBarReorderDelegate: DropDelegate {
    /// 本代理对应的落点行
    let targetID: String
    /// 实时读取当前搜索栏 id 序（拖拽中会随换位变化，故用闭包而非快照）
    let currentOrder: () -> [String]
    /// 实时读取当前拖拽中的引擎 id
    let currentDraggingID: () -> String?
    let setDraggingID: (String?) -> Void
    let setDropTargetID: (String?) -> Void
    let move: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingID = currentDraggingID(), draggingID != targetID else { return }
        let order = currentOrder()
        guard let from = order.firstIndex(of: draggingID),
              let to = order.firstIndex(of: targetID),
              from != to else { return }
        setDropTargetID(targetID)
        move(IndexSet(integer: from), from < to ? to + 1 : to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        setDraggingID(nil)
        setDropTargetID(nil)
        return true
    }

    func dropExited(info: DropInfo) {
        setDropTargetID(nil)
    }
}
