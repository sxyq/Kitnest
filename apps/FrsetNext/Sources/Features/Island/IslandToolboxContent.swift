import SwiftUI

/// 刘海的全部功能目录；工具内容直接嵌入正式运行面板。
struct IslandToolboxContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    @Binding var selectedTool: String?
    /// Root 在文件面板显示期间保留本页挂载，避免收起刘海丢失输入。
    var onFileDialog: ((Bool) -> Void)? = nil
    @Stored private var query = ""
    @Stored private var category: ToolCategory? = nil
    @Stored private var previewResultVisible = false
    @Environment(\.isSettingsPreview) private var isSettingsPreview

    private var preview: Bool { previewOnly || controller.previewOnly || isSettingsPreview }
    private var tint: Color { controller.configuration.color(for: .tools) }
    private var pages: [IslandPage] { IslandPage.allCases.filter { $0 != .home && $0 != .tools } }

    init(controller: IslandController, previewOnly: Bool, selectedTool: Binding<String?>,
         onFileDialog: ((Bool) -> Void)? = nil) {
        self.controller = controller
        self.previewOnly = previewOnly
        self._selectedTool = selectedTool
        self.onFileDialog = onFileDialog
    }

    var body: some View {
        let tools = ToolRegistry.enabledTools
        let selected = tools.first { $0.id == selectedTool }
        HStack(spacing: Theme.Space.md) {
            directory(tools)
                .frame(width: 200)
            Group {
                if preview {
                    previewContent(selected)
                } else if let selected {
                    ToolRunnerView(tool: selected,
                                   intent: selected.id == "deduplicate" ? .preview : .standard,
                                   compact: true, onFileDialog: { isOpen in
                                       if !isOpen { controller.expand(takeFocus: true) }
                                       onFileDialog?(isOpen)
                                   })
                        .id(selected.id)
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
            .glassCard(radius: Theme.Radius.card, fill: IslandLayout.cardFill, stroke: IslandLayout.cardStroke)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(tint)
        .preferredColorScheme(.dark)
        .onChange(of: selectedTool) { _ in previewResultVisible = false }
    }

    private func directory(_ tools: [ToolDescriptor]) -> some View {
        let visible = tools.filter { tool in
            (category == nil || tool.category == category) &&
                (query.isEmpty || [tool.name, tool.keyword, tool.toolDescription]
                    .contains { $0.localizedCaseInsensitiveContains(query) })
        }
        let visiblePages = pages.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            TextField("搜索工具", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: Theme.TextSize.small))
                .onSubmit {
                    if let tool = visible.first { selectedTool = tool.id }
                    else if let page = visiblePages.first { controller.page = page }
                }
            Picker("分类", selection: $category) {
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
                            Button { controller.page = page } label: {
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
            }
        }
    }

    // 设置预览复用现有固定示例，只演示布局；不创建运行面板和 ToolOutput。
    private func previewContent(_ tool: ToolDescriptor?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Label(tool?.name ?? "工具布局预览", systemImage: tool?.systemImage ?? "curlybraces")
                    .font(.system(size: Theme.TextSize.body, weight: .semibold))
                Text("设置预览 · 固定演示内容")
                    .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                Text(IslandSample.clipboard[2].body)
                    .font(.system(size: Theme.TextSize.small, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.sm)
                    .background(Theme.rowHoverFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                if let tool {
                    ForEach(tool.options) { option in
                        HStack {
                            Text(option.title)
                            Spacer()
                            Text(option.choices[option.defaultIndex]).foregroundStyle(.secondary)
                        }.font(.system(size: Theme.TextSize.caption))
                    }
                }
                Button("执行预览") { previewResultVisible = true }.buttonStyle(IslandButtonStyle())
                if previewResultVisible {
                    Text("结果区域 · " + IslandSample.clipboard[2].title)
                        .font(.system(size: Theme.TextSize.small))
                    HStack {
                        Button("复制预览") { controller.feedback = "预览：复制结果" }
                        Button("保存预览") { controller.feedback = "预览：存为剪贴板条目" }
                    }.buttonStyle(IslandButtonStyle())
                }
            }.padding(Theme.Space.md)
        }
    }
}
