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
    @Stored private var isEditingSearchBar = true
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
    // v47 首页搜索分类开关（与首页分类行的眼睛按钮共用同一批键）
    @AppStorage(Preferences.Keys.searchCategoryWeb) private var showWeb = true
    @AppStorage(Preferences.Keys.searchCategoryClipboard) private var showClipboard = true
    @AppStorage(Preferences.Keys.searchCategoryFiles) private var showFiles = true

    /// 一次性拖拽提示键（原作 defaults 键 hasSeenSearchBarOrderingTip）
    static let orderingTipKey = "hasSeenSearchBarOrderingTip"

    /// 首次拖拽提示一次性标记
    private var hasSeenOrderingTip: Bool {
        UserDefaults.standard.bool(forKey: Self.orderingTipKey)
    }

    /// v47：首页搜索分类开关（首页分类行的眼睛按钮与此处共用同一批键）。
    /// 网页分类含 WKWebView 内嵌预览；本地文件走系统 Spotlight（mdfind，Everything 的 macOS 对应物）。
    private var searchCategorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("首页搜索分类")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 22) {
                Toggle("网页搜索（引擎 + 内嵌预览）", isOn: $showWeb)
                    .toggleStyle(.checkbox)
                Toggle("剪贴板历史", isOn: $showClipboard)
                    .toggleStyle(.checkbox)
                Toggle("本地文件（Spotlight）", isOn: $showFiles)
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
            searchCategorySection
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
                        if editingEngineID == engine.id { engineEditForm(engine) }
                        Divider()
                    }
                    if isAddingCustomEngine { customEngineForm }
                }
                HStack(spacing: 36) {
                    Button {
                        isAddingCustomEngine.toggle()
                        if isAddingCustomEngine { clearForm() }
                    } label: { Label(L10n.t("Custom Search"), systemImage: "plus") }
                    Button { confirmReset = true } label: {
                        Label(L10n.t("Reset Search"), systemImage: "arrow.clockwise")
                    }
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
            Text("将删除自定义搜索引擎「\(enginePendingDelete?.name ?? "")」，此操作不可恢复。")
        }
        .confirmationDialog(L10n.t("Reset Search Settings"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(L10n.t("Reset"), role: .destructive) { performReset() }
            Button(L10n.t("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("This will reset all search engine settings to default"))
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
        // 拖拽源：整行可拖；拖起时记录拖拽中引擎并消费一次性排序提示
        .onDrag {
            draggingSearchBarID = engine.id
            markOrderingTipShownIfNeeded()
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
        Toast.show(L10n.t("Search Bar Reorder Tip"), icon: "hand.draw")
    }

    /// 从搜索栏移除；最后 1 项时阻止并提示（原作 "Search Bar Minimum Alert"）
    private func removeFromSearchBar(_ engine: SearchEngine) {
        if SearchServiceManager.shared.removeFromSearchBar(engineID: engine.id) {
            // 「已从搜索栏移除」无独立键面，复用 'Remove from Search Bar' 译文（从搜索栏移除）
            Toast.show(L10n.t("Remove from Search Bar"), icon: "checkmark.circle.fill")
        } else {
            Toast.show(L10n.t("Search Bar Minimum Alert"), icon: "exclamationmark.triangle.fill", isWarning: true)
        }
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
                    Button(L10n.t("Edit")) { beginEditing(engine) }
                    Button(L10n.t("Delete"), role: .destructive) { enginePendingDelete = engine }
                }
                Toggle(L10n.t("Clear input after searching or opening links"), isOn: clearInputBinding)
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
        SearchServiceManager.shared.addToSearchBar(engineID: engine.id)
        Toast.show(L10n.t("Added to Search Bar"), icon: "checkmark.circle.fill")
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
            engineFormFields(name: $newEngineName,
                             url: $newEngineURL,
                             errorMessage: $formErrorMessage,
                             placeholder: SearchServiceManager.customEngineURLPlaceholder)
            HStack {
                Spacer()
                Button(L10n.t("Save")) { saveCustomEngine() }
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
                Button(L10n.t("Cancel")) { cancelEditing() }
                    .controlSize(.small)
                Button(L10n.t("Save")) { saveEngineEdit(engine) }
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

    /// 三连校验：仅字母数字 / 名称长度上限 / URL 含 {query} 且可解析
    /// - Parameter excludingID: URL 查重时排除的引擎 id（编辑态排除自身）
    /// - Returns: 错误文案；nil = 通过
    private func validateEngineForm(name: String, url: String, excludingID: String?) -> String? {
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
        // 「已添加搜索引擎」无独立键面，保留直写
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
        Toast.show(L10n.t("Saved Successfully"), icon: "checkmark.circle.fill")
    }

    // MARK: - 3. 行为区

    private var clearInputBinding: Binding<Bool> {
        Binding(
            get: { SearchServiceManager.shared.clearSearchInputAfterWebAction },
            set: { SearchServiceManager.shared.clearSearchInputAfterWebAction = $0 }
        )
    }

    // MARK: - 4. 重置区（原作 "Reset Search Settings" 行 @0x1004ea838）

    private func performReset() {
        SearchServiceManager.shared.resetToDefaults()
        isEditingSearchBar = true
        draggingSearchBarID = nil
        searchBarDropTargetID = nil
        cancelEditing()
        clearForm()
        isAddingCustomEngine = false
        Toast.show(L10n.t("Reset Successfully"), icon: "checkmark.circle.fill")
    }

    // MARK: 删除自定义引擎

    private func performDeletePendingEngine() {
        guard let engine = enginePendingDelete else { return }
        if editingEngineID == engine.id { cancelEditing() }
        SearchServiceManager.shared.deleteCustomEngine(engineID: engine.id)
        enginePendingDelete = nil
        Toast.show(L10n.t("Deleted Successfully"), icon: "checkmark.circle.fill")
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
