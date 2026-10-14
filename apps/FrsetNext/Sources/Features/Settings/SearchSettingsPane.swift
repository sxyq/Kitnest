import SwiftUI

// MARK: - 搜索设置页（specs/18 §4 行集合，页签 id "search"）
//
// 行集合自上而下（对齐原作代码地址序推断）：
// 1. 搜索栏区：调整搜索栏（编辑模式入口）+ 搜索栏项目列表（增删/排序，至少保留 1 项）
// 2. 搜索引擎区：内置 11 引擎逐行添加/移除 + 自定义引擎表单（三连校验）+ 删除（确认弹窗）
// 3. 行为区：「搜索或打开链接后清空输入框」开关（clearSearchInputAfterWebAction）
// 4. 底部：重置搜索设置（确认弹窗 → Reset Successfully Toast）

struct SearchSettingsPane: View {
    /// 引擎数据中心（原作 SearchServiceManager 等价，实现在 Toolbox/SearchEngine.swift）
    @ObservedObject private var service = SearchServiceManager.shared

    // 编辑模式（搜索栏拖拽/增删）
    @Stored private var isEditingSearchBar = false
    // 自定义引擎表单
    @Stored private var isAddingCustomEngine = false
    @Stored private var newEngineName = ""
    @Stored private var newEngineURL = ""
    @Stored private var formErrorMessage: String? = nil
    // 删除自定义引擎（确认弹窗承接）
    @Stored private var enginePendingDelete: SearchEngine? = nil
    // 重置确认
    @Stored private var confirmReset = false

    /// 首次拖拽提示一次性标记（原作 defaults 键 hasSeenSearchBarOrderingTip）
    private var hasSeenOrderingTip: Bool {
        UserDefaults.standard.bool(forKey: "hasSeenSearchBarOrderingTip")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            searchBarSection
            enginesSection
            behaviorSection
            resetSection
        }
        .confirmationDialog(deleteConfirmTitle, isPresented: deleteConfirmBinding, titleVisibility: .visible) {
            Button("删除", role: .destructive) { performDeletePendingEngine() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除自定义搜索引擎「\(enginePendingDelete?.name ?? "")」，此操作不可恢复。")
        }
        .confirmationDialog("重置搜索设置？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("重置", role: .destructive) { performReset() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会将所有搜索引擎设置恢复为默认值。")
        }
    }

    /// 删除确认弹窗绑定（enginePendingDelete 非空即呈现）
    private var deleteConfirmBinding: Binding<Bool> {
        Binding(get: { enginePendingDelete != nil }, set: { if !$0 { enginePendingDelete = nil } })
    }
    private var deleteConfirmTitle: String { "删除搜索引擎" }

    // MARK: - 1. 搜索栏区

    private var searchBarSection: some View {
        SettingsSection(title: "搜索栏") {
            SettingsGroupBox {
                // 编辑模式入口（原作 PlainButtonStyle 行 @0x1004bf318）
                SettingsRow(icon: "slider.horizontal.3",
                            title: "调整搜索栏",
                            subtitle: isEditingSearchBar ? "上下移动可调整顺序，完成后点击完成" : "进入编辑模式，调整搜索栏中显示的引擎") {
                    Button(isEditingSearchBar ? "完成" : "编辑") {
                        isEditingSearchBar.toggle()
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                }
                SettingsDivider()

                // 搜索栏项目列表（激活集，保序）
                if service.activeBarEngines.isEmpty {
                    Text("搜索栏暂无项目")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(service.activeBarEngines) { engine in
                        searchBarRow(engine)
                        if engine.id != service.activeBarEngines.last?.id {
                            SettingsDivider()
                        }
                    }
                }
            }
        }
    }

    /// 搜索栏项目行：编辑模式显示上移/下移/移除；普通模式仅展示
    private func searchBarRow(_ engine: SearchEngine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: engine.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(engine.name)
                .font(.system(size: 13))
            Spacer()
            if isEditingSearchBar {
                Button {
                    moveInSearchBar(engine, up: true)
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(service.activeBarItems.first == engine.id)
                Button {
                    moveInSearchBar(engine, up: false)
                } label: {
                    Image(systemName: "arrow.down").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(service.activeBarItems.last == engine.id)
            }
            Button {
                removeFromSearchBar(engine)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("从搜索栏移除")
        }
        .padding(.vertical, 6)
    }

    /// 搜索栏内移动（首次移动显示一次性提示 → hasSeenSearchBarOrderingTip）
    private func moveInSearchBar(_ engine: SearchEngine, up: Bool) {
        SearchServiceManager.shared.moveInSearchBar(engineID: engine.id, up: up)
        if !hasSeenOrderingTip {
            UserDefaults.standard.set(true, forKey: "hasSeenSearchBarOrderingTip")
            Toast.show("拖拽可调整搜索栏顺序", icon: "hand.draw")
        }
    }

    /// 从搜索栏移除；最后 1 项时阻止并提示（原作 "Search Bar Minimum Alert"）
    private func removeFromSearchBar(_ engine: SearchEngine) {
        if SearchServiceManager.shared.removeFromSearchBar(engineID: engine.id) {
            Toast.show("已从搜索栏移除", icon: "checkmark.circle.fill")
        } else {
            Toast.show("搜索栏至少需要保留一项", icon: "exclamationmark.triangle.fill", isWarning: true)
        }
    }

    // MARK: - 2. 搜索引擎区

    private var enginesSection: some View {
        SettingsSection(title: "搜索引擎") {
            SettingsGroupBox {
                // 全量引擎（内置 11 + 自定义）：图标 + 名称 + 添加到/从搜索栏移除
                ForEach(service.allEngines) { engine in
                    engineRow(engine)
                    if engine.id != service.allEngines.last?.id {
                        SettingsDivider()
                    }
                }
                SettingsDivider()
                // 添加自定义搜索引擎表单入口
                SettingsRow(icon: "plus.circle",
                            title: "添加自定义搜索引擎",
                            subtitle: "支持任何含 {query} 占位符的搜索 URL") {
                    Button(isAddingCustomEngine ? "收起" : "添加") {
                        isAddingCustomEngine.toggle()
                        if !isAddingCustomEngine { clearForm() }
                    }
                    .controlSize(.small)
                }
                if isAddingCustomEngine {
                    SettingsDivider()
                    customEngineForm
                }
            }
        }
    }

    /// 引擎行：添加到/从搜索栏移除 +（自定义）删除
    private func engineRow(_ engine: SearchEngine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: engine.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(engine.name)
                    .font(.system(size: 13))
                Text(engine.urlTemplate)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !engine.isBuiltIn {
                // 自定义引擎：删除（走确认弹窗，复用删除确认文案）
                Button {
                    enginePendingDelete = engine
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除此自定义引擎")
            }
            // 在搜索栏内 → 移除；不在 → 添加
            if service.activeBarItems.contains(engine.id) {
                Button("从搜索栏移除") { removeFromSearchBar(engine) }
                    .controlSize(.small)
            } else {
                Button("添加到搜索栏") { addToSearchBar(engine) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    private func addToSearchBar(_ engine: SearchEngine) {
        SearchServiceManager.shared.addToSearchBar(engineID: engine.id)
        Toast.show("已添加至搜索栏", icon: "checkmark.circle.fill")
    }

    // MARK: 自定义引擎表单（三连校验，specs/18 §4.1）

    private var customEngineForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("名称").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("例如：MySearch", text: $newEngineName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("搜索 URL").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(SearchServiceManager.customEngineURLPlaceholder, text: $newEngineURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text("请使用 {query} 作为搜索词占位符")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let message = formErrorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("保存") { saveCustomEngine() }
                    .controlSize(.small)
                    .disabled(newEngineName.isEmpty || newEngineURL.isEmpty)
            }
        }
        .padding(.vertical, 6)
    }

    /// 表单校验三连：仅字母数字 / 名称超长 / URL 含 {query} 占位符
    private func saveCustomEngine() {
        let name = newEngineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = newEngineURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // ① 名称仅字母数字（原作 "Only letters and numbers allowed" @0x100508200）
        guard name.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            formErrorMessage = "名称仅支持字母和数字"
            return
        }
        // ② 名称长度上限（原作 "Name Too Long Limit" @0x100500ff0）
        guard name.count <= SearchServiceManager.customEngineNameLimit else {
            formErrorMessage = "名称过长（最多 \(SearchServiceManager.customEngineNameLimit) 个字符）"
            return
        }
        // ③ URL 含 {query} 占位符且格式合法（原作 "Invalid URL Format" @0x1005041e8）
        guard url.contains("{query}"),
              url.contains("://"),
              URL(string: url.replacingOccurrences(of: "{query}", with: "test")) != nil else {
            formErrorMessage = "URL 格式无效，请使用 {query} 作为搜索词占位符"
            return
        }
        guard !service.allEngines.contains(where: { $0.urlTemplate == url }) else {
            formErrorMessage = "已存在相同 URL 的搜索引擎"
            return
        }

        SearchServiceManager.shared.addCustomEngine(name: name, urlTemplate: url)
        clearForm()
        isAddingCustomEngine = false
        Toast.show("已添加搜索引擎", icon: "checkmark.circle.fill")
    }

    private func clearForm() {
        newEngineName = ""
        newEngineURL = SearchServiceManager.customEngineURLPlaceholder
        formErrorMessage = nil
    }

    // MARK: - 3. 行为区

    private var behaviorSection: some View {
        SettingsSection(title: "行为") {
            SettingsGroupBox {
                SettingsToggleRow(
                    icon: "xmark.circle",
                    title: "搜索或打开链接后清空输入框",
                    subtitle: "执行 Web 搜索或打开链接后自动清空搜索框（clearSearchInputAfterWebAction）",
                    isOn: clearInputBinding
                )
            }
        }
    }

    private var clearInputBinding: Binding<Bool> {
        Binding(
            get: { SearchServiceManager.shared.clearSearchInputAfterWebAction },
            set: { SearchServiceManager.shared.clearSearchInputAfterWebAction = $0 }
        )
    }

    // MARK: - 4. 重置区（原作 "Reset Search Settings" 行 @0x1004ea838）

    private var resetSection: some View {
        SettingsSection(title: "重置") {
            SettingsGroupBox {
                SettingsRow(icon: "arrow.counterclockwise",
                            title: "重置搜索设置",
                            subtitle: "恢复全部搜索引擎与搜索栏为默认值") {
                    Button("重置…", role: .destructive) { confirmReset = true }
                        .controlSize(.small)
                }
            }
        }
    }

    private func performReset() {
        SearchServiceManager.shared.resetToDefaults()
        isEditingSearchBar = false
        Toast.show("重置成功", icon: "checkmark.circle.fill")
    }

    // MARK: 删除自定义引擎

    private func performDeletePendingEngine() {
        guard let engine = enginePendingDelete else { return }
        SearchServiceManager.shared.deleteCustomEngine(engineID: engine.id)
        enginePendingDelete = nil
        Toast.show("已删除", icon: "checkmark.circle.fill")
    }
}
