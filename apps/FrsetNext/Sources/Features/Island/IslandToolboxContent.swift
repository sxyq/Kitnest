import AppKit
import SwiftUI

/// 首页五档快捷目录只选择原工具，不执行工具或创建独立窗口。
struct IslandToolboxShortcuts: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    let size: IslandWidgetSize
    @Binding var selectedTool: String?
    @Environment(\.isSettingsPreview) private var isSettingsPreview

    private var tools: [ToolDescriptor] {
        if previewOnly || controller.previewOnly || isSettingsPreview {
            return IslandToolboxContent.previewTools
        }
        return ToolRegistry.enabledTools
    }

    var body: some View {
        let limit = size == .small ? 1 : size == .wide ? 2 : size == .square ? 6 : 4
        Group {
            if tools.isEmpty {
                Text("暂无已启用工具").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if size == .strip {
                HStack(spacing: 8) { ForEach(Array(tools.prefix(limit))) { shortcut($0) } }
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                                             count: size == .square ? 2 : 1), alignment: .leading, spacing: 6) {
                        ForEach(Array(tools.prefix(limit))) { shortcut($0) }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 进入选定工具详情，按尺寸展示名称或说明，不执行工具。
    private func shortcut(_ tool: ToolDescriptor) -> some View {
        Button { selectedTool = tool.id; controller.page = .tools } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(tool.name, systemImage: tool.systemImage).lineLimit(1)
                if size == .square || size == .tall {
                    Text(tool.toolDescription).foregroundStyle(.secondary).lineLimit(2)
                }
            }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(IslandButtonStyle()).help("打开工具：" + tool.name)
    }
}

/// 刘海的全部功能目录；工具内容直接嵌入正式运行面板。
struct IslandToolboxContent: View {
    static var previewTools: [ToolDescriptor] {
        ["json", "uuid", "timestamp", "base64", "urlencode", "deduplicate"].compactMap { ToolRegistry.tool(id: $0) }
    }
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    @Binding var selectedTool: String?
    /// Root 在文件面板显示期间保留本页挂载，避免收起刘海丢失输入。
    var onFileDialog: ((Bool) -> Void)? = nil
    @Environment(\.isSettingsPreview) private var isSettingsPreview

    private var preview: Bool { previewOnly || controller.previewOnly || isSettingsPreview }
    private var tint: Color { controller.configuration.color(for: .tools) }
    private var pages: [IslandPage] { IslandPage.allCases.filter { $0 != .home && $0 != .tools && $0 != .custom } }

    init(controller: IslandController, previewOnly: Bool, selectedTool: Binding<String?>,
         onFileDialog: ((Bool) -> Void)? = nil) {
        self.controller = controller
        self.previewOnly = previewOnly
        self._selectedTool = selectedTool
        self.onFileDialog = onFileDialog
    }

    var body: some View {
        let tools = preview ? Self.previewTools : ToolRegistry.enabledTools
        let selected = tools.first { $0.id == selectedTool }
        GeometryReader { geometry in
        HStack(spacing: Theme.Space.md) {
            directory(tools)
                .frame(width: min(200, max(110, geometry.size.width * 0.32)))
            Group {
                if let selected {
                    if let build = selected.build {
                        build()
                    } else {
                    ToolRunnerView(tool: selected,
                                   initialInput: controller.toolInputs[selected.id] ?? (preview ? (selected.inputKind == .filePath ? "设计资料/首页说明.png" : IslandSample.clipboard[2].body) : ""),
                                   intent: selected.id == "deduplicate" ? .preview : .standard,
                                   compact: true, onFileDialog: { isOpen in
                                       if !isOpen { controller.resumeAfterOutside() }
                                       onFileDialog?(isOpen)
                                   }, presentFileDialog: { controller.performOutside($0) },
                                   onInputChange: { controller.toolInputs[selected.id] = $0 })
                        .id(selected.id)
                    }
                } else {
                    VStack(spacing: Theme.Space.md) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 24)).foregroundStyle(tint)
                        Text(tools.isEmpty ? "暂无已启用工具" : "选择工具，在这里输入与执行")
                            .font(.system(size: Theme.TextSize.body))
                        Text("其他功能从左侧目录进入；工具开关与输出行为沿用总设置。")
                            .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                    }.padding(Theme.Space.lg)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassCard(radius: IslandLayout.cardRadius, fill: IslandLayout.cardFill, stroke: IslandLayout.cardStroke)
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(tint)
        .environment(\.colorScheme, .dark)
    }

    private func directory(_ tools: [ToolDescriptor]) -> some View {
        let visible = tools.filter { tool in
            (controller.toolCategory == nil || tool.category == controller.toolCategory) &&
                (controller.toolQuery.isEmpty || [tool.name, tool.keyword, tool.toolDescription]
                    .contains { $0.localizedCaseInsensitiveContains(controller.toolQuery) })
        }
        let visiblePages = pages.filter { controller.toolQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(controller.toolQuery) }
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            TextField("搜索工具", text: $controller.toolQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: Theme.TextSize.small))
                .onSubmit {
                    if let tool = visible.first { selectedTool = tool.id }
                    else if let page = visiblePages.first { controller.selectPage(page) }
                }
            Picker("分类", selection: $controller.toolCategory) {
                Text("全部工具").tag(Optional<ToolCategory>.none)
                ForEach(ToolCategory.allCases, id: \.self) { item in
                    Text(item.title).tag(Optional(item))
                }
            }.font(.system(size: Theme.TextSize.caption))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("功能目录").font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.Space.xs) {
                        ForEach(visiblePages) { page in
                            Button { controller.selectPage(page) } label: {
                                Text(page.title).font(.system(size: Theme.TextSize.caption)).lineLimit(1)
                                    .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.sm)
                                    .background(Theme.rowHoverFill, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                            }.buttonStyle(IslandButtonStyle()).help(page.title)
                        }
                    }
                    Divider()
                    ForEach(ToolCategory.allCases, id: \.self) { item in
                        let matches = visible.filter { $0.category == item }
                        if !matches.isEmpty {
                            Text(item.title).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                            ForEach(matches) { tool in
                                Button { selectedTool = tool.id } label: {
                                    Label(tool.name, systemImage: tool.systemImage)
                                        .font(.system(size: Theme.TextSize.small)).lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(Theme.Space.sm)
                                        .background(selectedTool == tool.id ? tint.opacity(0.16) : .clear,
                                                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                                }
                                .buttonStyle(IslandButtonStyle())
                                .accessibilityAddTraits(selectedTool == tool.id ? .isSelected : [])
                                .help(tool.toolDescription)
                            }
                        }
                    }
                    if tools.isEmpty {
                        Text("可在总设置 → 工具中启用工具")
                            .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                    } else if visible.isEmpty {
                        Text("没有匹配的工具")
                            .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                    }
                }
            }.islandGlowClip()
        }
    }

}

