import SwiftUI
import UniformTypeIdentifiers

// MARK: - 搜索设置页（specs/18 §4 行集合，页签 id "search"）
//
// 行集合自上而下（对齐原作代码地址序推断）：
// 1. 搜索栏区：调整搜索栏（编辑模式入口）+ 搜索栏项目列表（**拖拽排序** / 移除，至少保留 1 项）
// 2. 搜索引擎区：全量引擎逐行排序 + 添加到/从搜索栏移除 + 自定义引擎（三连校验 / 行内编辑 / 删除）
// 3. 行为区：「搜索或打开链接后清空输入框」开关（clearSearchInputAfterWebAction）
// 4. 底部：重置搜索设置（确认弹窗 → Reset Successfully Toast）
//
// 交互对齐（缺口 SE-3 / SE-2 / SE-7）：
// - SE-3：原作是**拖拽排序**（specs/18 §4 锚点 SearchBarOrderingTipCoordinateSpace + 'Search Bar Reorder Tip'），
//   此处用 SwiftUI `.onDrag` / `.onDrop(of:delegate:)` 实现，数据侧挂 SearchServiceManager.moveInSearchBar(fromOffsets:toOffset:)。
// - SE-2：原作自定义引擎有行内编辑表单（SearchServiceManager.__editingEngine，specs/18 §4 @0x100502288-0x100503cd4）。
// - SE-7：引擎区可排序（SearchServiceManager.moveEngine 已有数据方法，此前零 UI 调用点）。

struct SearchSettingsPane: View {
    /// 引擎数据中心（原作 SearchServiceManager 等价，实现在 Models/SearchEngine.swift）
    @ObservedObject private var service = SearchServiceManager.shared

    // 编辑模式（搜索栏拖拽/增删）
    @Stored private var isEditingSearchBar = false
    /// 正在拖拽的搜索栏引擎 id（非空 = 拖拽进行中，用于隐藏插入位提示行）
    @Stored private var draggingSearchBarID: String? = nil
    /// 拖拽悬停的目标引擎 id（落点高亮）
    @Stored private var searchBarDropTargetID: String? = nil
    // 自定义引擎表单（新增态）
    @Stored private var isAddingCustomEngine = false
    @Stored private var newEngineName = ""
    @Stored private var newEngineURL = ""
    @Stored private var formErrorMessage: String? = nil
    // 自定义引擎行内编辑（原作 __editingEngine）
    @Stored private var editingEngineID: String? = nil
    @Stored private var editEngineName = ""
    @Stored private var editEngineURL = ""
    @Stored private var editErrorMessage: String? = nil
    // 删除自定义引擎（确认弹窗承接）
    @Stored private var enginePendingDelete: SearchEngine? = nil
    // 重置确认
    @Stored private var confirmReset = false

    /// 一次性拖拽提示键（原作 defaults 键 hasSeenSearchBarOrderingTip）
    static let orderingTipKey = "hasSeenSearchBarOrderingTip"

    /// 首次拖拽提示一次性标记
    private var hasSeenOrderingTip: Bool {
        UserDefaults.standard.bool(forKey: Self.orderingTipKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            searchBarSection
            enginesSection
            behaviorSection
            resetSection
        }
        .coordinateSpace(name: "SearchBarOrderingTipCoordinateSpace")   // 原作提示锚点同名
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
                            subtitle: isEditingSearchBar
                                ? "按住项目拖拽可调整顺序，拖拽过程中显示插入位；完成后点击完成"
                                : "进入编辑模式，拖拽调整搜索栏中显示的引擎") {
                    Button(isEditingSearchBar ? "完成" : "编辑") {
                        isEditingSearchBar.toggle()
                        if !isEditingSearchBar {
                            draggingSearchBarID = nil
                            searchBarDropTargetID = nil
                        }
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                }
                SettingsDivider()

                // 搜索栏项目列表（激活集，保序；编辑模式 = 拖拽排序）
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

    /// 搜索栏项目行：编辑模式整行可拖（拖拽手柄 + 落位高亮）；两种模式都可移除
    private func searchBarRow(_ engine: SearchEngine) -> some View {
        let isDropTarget = isEditingSearchBar && searchBarDropTargetID == engine.id
        return HStack(spacing: 10) {
            if isEditingSearchBar {
                // 拖拽手柄（提示这是可拖动的行）
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: engine.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(engine.name)
                .font(.system(size: 13))
                .fontWeight(isEditingSearchBar ? .medium : .regular)
            Spacer()
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
        .padding(.horizontal, isEditingSearchBar ? 4 : 0)
        .background(
            RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        // 拖拽源：整行可拖；拖起时记录拖拽中引擎并消费一次性排序提示
        .onDrag {
            draggingSearchBarID = engine.id
            markOrderingTipShownIfNeeded()
            return NSItemProvider(object: engine.id as NSString)
        } preview: {
            HStack(spacing: 6) {
                Image(systemName: engine.systemImage).font(.system(size: 12))
                Text(engine.name).font(.system(size: 13))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.smallRadius).fill(Theme.cardBackground))
        }
        // 落位目标：非编辑模式传入空类型列表，等价于关闭本行的接收
        .onDrop(of: isEditingSearchBar ? [UTType.text] : [], delegate: searchBarDropDelegate(targetID: engine.id))
    }

    /// 拖拽落位代理：悬停即换位（对齐 List.onMove 的实时跟手感）。
    /// order / draggingID 均在**落位瞬间**实时读取，避免拖拽过程中多次换位后读到过期快照。
    private func searchBarDropDelegate(targetID: String) -> SearchBarReorderDelegate {
        SearchBarReorderDelegate(
            targetID: targetID,
            currentOrder: { SearchServiceManager.shared.activeBarItems },
            currentDraggingID: { draggingSearchBarID },
            setDraggingID: { draggingSearchBarID = $0 },
            setDropTargetID: { searchBarDropTargetID = $0 },
            move: { fromOffsets, toOffset in
                SearchServiceManager.shared.moveInSearchBar(fromOffsets: fromOffsets, toOffset: toOffset)
            }
        )
    }

    /// 首次进入拖拽时显示一次性提示（对齐原作 'Search Bar Reorder Tip' → hasSeenSearchBarOrderingTip）
    private func markOrderingTipShownIfNeeded() {
        guard !hasSeenOrderingTip else { return }
        UserDefaults.standard.set(true, forKey: Self.orderingTipKey)
        Toast.show("拖拽可调整搜索栏顺序", icon: "hand.draw")
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
                // 全量引擎（内置 11 + 自定义）：图标 + 名称 + 排序 + 添加到/从搜索栏移除
                ForEach(Array(service.allEngines.enumerated()), id: \.element.id) { index, engine in
                    engineRow(engine, index: index)
                    // 自定义引擎展开中的行内编辑表单（原作 __editingEngine）
                    if editingEngineID == engine.id {
                        SettingsDivider()
                        engineEditForm(engine)
                    }
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

    /// 引擎行：排序（上/下移）+（自定义）编辑/删除 + 添加到/从搜索栏移除
    private func engineRow(_ engine: SearchEngine, index: Int) -> some View {
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
            // 排序控件（引擎可排序；首/末行对应方向禁用）
            Button {
                SearchServiceManager.shared.moveEngine(engineID: engine.id, up: true)
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .help("上移")
            Button {
                SearchServiceManager.shared.moveEngine(engineID: engine.id, up: false)
            } label: {
                Image(systemName: "arrow.down").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .disabled(index == service.allEngines.count - 1)
            .help("下移")
            if !engine.isBuiltIn {
                // 自定义引擎：行内编辑 + 删除（删除走确认弹窗）
                Button {
                    beginEditing(engine)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("编辑此自定义引擎")
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
            engineFormFields(name: $newEngineName,
                             url: $newEngineURL,
                             errorMessage: $formErrorMessage,
                             placeholder: SearchServiceManager.customEngineURLPlaceholder)
            HStack {
                Spacer()
                Button("保存") { saveCustomEngine() }
                    .controlSize(.small)
                    .disabled(newEngineName.isEmpty || newEngineURL.isEmpty)
            }
        }
        .padding(.vertical, 6)
    }

    /// 引擎编辑表单（行内展开；复用与新增完全相同的三连校验）
    private func engineEditForm(_ engine: SearchEngine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            engineFormFields(name: $editEngineName,
                             url: $editEngineURL,
                             errorMessage: $editErrorMessage,
                             placeholder: SearchServiceManager.customEngineURLPlaceholder)
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { cancelEditing() }
                    .controlSize(.small)
                Button("保存") { saveEngineEdit(engine) }
                    .controlSize(.small)
                    .disabled(editEngineName.isEmpty || editEngineURL.isEmpty)
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
                Text("名称").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("例如：MySearch", text: name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("搜索 URL").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(placeholder, text: url)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text("请使用 {query} 作为搜索词占位符")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let message = errorMessage.wrappedValue {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    /// 三连校验：仅字母数字 / 名称长度上限 / URL 含 {query} 且可解析
    /// - Parameter excludingID: URL 查重时排除的引擎 id（编辑态排除自身）
    /// - Returns: 错误文案；nil = 通过
    private func validateEngineForm(name: String, url: String, excludingID: String?) -> String? {
        // ① 名称仅字母数字（原作 "Only letters and numbers allowed" @0x100508200）
        guard name.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return "名称仅支持字母和数字"
        }
        // ② 名称长度上限（原作 "Name Too Long Limit" @0x100500ff0）
        guard name.count <= SearchServiceManager.customEngineNameLimit else {
            return "名称过长（最多 \(SearchServiceManager.customEngineNameLimit) 个字符）"
        }
        // ③ URL 含 {query} 占位符且格式合法（原作 "Invalid URL Format" @0x1005041e8）
        guard url.contains("{query}"),
              url.contains("://"),
              URL(string: url.replacingOccurrences(of: "{query}", with: "test")) != nil else {
            return "URL 格式无效，请使用 {query} 作为搜索词占位符"
        }
        guard !service.allEngines.contains(where: { $0.urlTemplate == url && $0.id != excludingID }) else {
            return "已存在相同 URL 的搜索引擎"
        }
        return nil
    }

    private func saveCustomEngine() {
        let name = newEngineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = newEngineURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if let message = validateEngineForm(name: name, url: url, excludingID: nil) {
            formErrorMessage = message
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

    // MARK: 引擎行内编辑（原作 __editingEngine）

    private func beginEditing(_ engine: SearchEngine) {
        editingEngineID = engine.id
        editEngineName = engine.name
        editEngineURL = engine.urlTemplate
        editErrorMessage = nil
    }

    private func cancelEditing() {
        editingEngineID = nil
        editEngineName = ""
        editEngineURL = ""
        editErrorMessage = nil
    }

    private func saveEngineEdit(_ engine: SearchEngine) {
        let name = editEngineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = editEngineURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if let message = validateEngineForm(name: name, url: url, excludingID: engine.id) {
            editErrorMessage = message
            return
        }
        SearchServiceManager.shared.updateCustomEngine(id: engine.id, name: name, urlTemplate: url)
        cancelEditing()
        Toast.show("已保存", icon: "checkmark.circle.fill")
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
        draggingSearchBarID = nil
        searchBarDropTargetID = nil
        cancelEditing()
        clearForm()
        isAddingCustomEngine = false
        Toast.show("重置成功", icon: "checkmark.circle.fill")
    }

    // MARK: 删除自定义引擎

    private func performDeletePendingEngine() {
        guard let engine = enginePendingDelete else { return }
        if editingEngineID == engine.id { cancelEditing() }
        SearchServiceManager.shared.deleteCustomEngine(engineID: engine.id)
        enginePendingDelete = nil
        Toast.show("已删除", icon: "checkmark.circle.fill")
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
