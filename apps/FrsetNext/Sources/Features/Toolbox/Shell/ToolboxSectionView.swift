import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 工具箱面板 UI

/// 跨视图共享的"当前打开的工具"状态（搜索区段也可通过它唤起工具面板）
///
/// v88（2026-10-20）：弹出改走全局工具窗（ToolRunnerWindowController）——
/// 此前面板挂在本文件 .sheet 上，而主页不渲染「工具」区段时 sheet 无宿主，
/// 搜索/快捷键/命令面板点了工具毫无反应。
public final class ToolboxUIState: ObservableObject {
    public static let shared = ToolboxUIState()
    @Published public var activeToolID: String?
    private init() {}
    public func open(_ id: String) {
        activeToolID = id
        ToolRunnerWindowController.shared.show(toolID: id)
    }
}

private struct ToolSheetItem: Identifiable { let id: String }

// MARK: 主面板「工具」区段（id "tools", priority 50）

public struct ToolboxSectionView: View {
    @ObservedObject private var uiState = ToolboxUIState.shared
    @Stored private var refreshTick = 0

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Theme.sectionHeader("工具")
                Spacer()
                Button {
                    ServiceLocator.settings?.open(pane: "tools")
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("在设置中启用 / 禁用工具")
            }

            let groups = ToolRegistry.grouped()
            if groups.isEmpty {
                Text("没有已启用的工具，可在设置中开启")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups, id: \.0) { category, tools in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                        toolGrid(tools)
                    }
                }
            }
        }
        .id(refreshTick)
        .onAppear { refreshTick += 1 }
        // v88：弹出迁至全局工具窗（ToolRunnerWindowController），不再用 .sheet——
        // 本区段不在主页渲染时 .sheet 无宿主，工具点了没反应。
    }

    private func toolGrid(_ tools: [ToolDescriptor]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(tools) { tool in
                Button { uiState.open(tool.identifier) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 15))
                        Text(tool.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .glassCard(radius: 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tool.name)
            }
        }
    }
}

// MARK: 单个工具的运行面板（输入 → 选项 → 执行 → 输出 → 复制 / 存为剪贴板条目）

public struct ToolRunnerView: View {
    public let tool: ToolDescriptor
    /// 窗口模式下的关闭回调（.sheet 场景仍走 @Environment(dismiss)）
    var onClose: (() -> Void)? = nil
    /// 打开即执行（斜杠命令用：/uuid 这种不需要输入的，落地就有结果）
    var autoRun: Bool = false
    private let intent: ToolInvocationIntent
    @ObservedObject private var windowController = ToolRunnerWindowController.shared
    @Stored private var input: String = ""
    @Stored private var options: [String: String] = [:]
    @Stored private var output: ToolOutput?
    @Stored private var isRunning = false
    @Stored private var statusText: String = ""
    @Stored private var didAutoRun = false
    @Stored private var outputDraft = ""
    @Stored private var showOriginal = false
    @Stored private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    public init(tool: ToolDescriptor, onClose: (() -> Void)? = nil, autoRun: Bool = false,
                initialInput: String = "", intent: ToolInvocationIntent = .standard) {
        self.tool = tool
        self.onClose = onClose
        self.autoRun = autoRun
        self.intent = intent
        self._input = Stored(wrappedValue: initialInput)
        self._outputDraft = Stored(wrappedValue: initialInput)
        self._showOriginal = Stored(wrappedValue: initialInput.isEmpty)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: tool.systemImage)
                Text(tool.name).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("关闭") {
                    onClose?()
                    dismiss()
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }

            // 输入区
            if tool.inputKind == .filePath {
                HStack {
                    TextField(tool.placeholder, text: $input)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button("选择图片") { chooseFile() }
                }
            } else if tool.identifier == "deduplicate" {
                Picker("文本版本", selection: $showOriginal) {
                    Text("原文").tag(true)
                    Text("去重后").tag(false)
                }.pickerStyle(.segmented)
                TextEditor(text: Binding(get: { showOriginal ? input : outputDraft },
                    set: { if showOriginal { input = $0 } else { outputDraft = $0 } }))
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 180, maxHeight: .infinity)
                DisclosureGroup("选项") {
                    Toggle("忽略大小写", isOn: Binding(get: { options["ignoreCase"] == "true" },
                        set: { options["ignoreCase"] = String($0); Task { await run() } }))
                    Toggle("忽略行首尾空格", isOn: Binding(get: { options["trim"] == "true" },
                        set: { options["trim"] = String($0); Task { await run() } }))
                }.font(.system(size: 12))
                if let note = output?.note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
            } else {
                TextEditor(text: $input)
                    .font(.system(size: 12))
                    .frame(minHeight: 70, maxHeight: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if input.isEmpty {
                            Text(tool.placeholder)
                                .font(.system(size: 11))
                                .foregroundStyle(Color(NSColor.placeholderTextColor))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .allowsHitTesting(false)
                        }
                    }
            }

            if output?.isError == true {
                Text(output?.text ?? "").font(.system(size: 12)).foregroundStyle(.red)
            }

            // 选项区
            if !tool.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tool.options) { option in
                        HStack(spacing: 8) {
                            Text(option.title)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { options[option.id] ?? option.choices[option.defaultIndex] },
                                set: { options[option.id] = $0 }
                            )) {
                                ForEach(option.choices, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .font(.system(size: 11))
                        }
                    }
                }
            }

            // 执行
            HStack(spacing: 10) {
                Button {
                    Task { await run() }
                } label: {
                    HStack(spacing: 4) {
                        if isRunning { ProgressView().controlSize(.small).scaleEffect(0.7) }
                        Text(isRunning ? "执行中…" : "执行")
                    }
                }
                .disabled(isRunning)
                Spacer()
                if !statusText.isEmpty {
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Divider()

            // 输出区
            if tool.identifier == "deduplicate" {
                HStack {
                    Button("取消") { onClose?() }
                    Spacer()
                    Button(copied ? "✓ 已复制" : "复制结果") { copyText(outputDraft) }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(output == nil || output?.isError == true)
                        .frame(minWidth: 100)
                }
            } else if let output, !output.isError {
                outputArea(output)
            } else {
                Text("执行结果将显示在这里")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(NSColor.placeholderTextColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        // 独立窗口（onClose 非空）里使用统一标题栏净空，不把工具标题压到红绿灯下。
        .padding(.top, onClose == nil ? 0 : OfficialChrome.titlebarInset)
        .frame(width: onClose == nil ? 520 : nil, height: onClose == nil ? 520 : nil)
        .onAppear {
            options = tool.defaultOptions()
            // 斜杠命令落地即执行（只跑一次；无输入类工具靠它给结果）
            if autoRun, !didAutoRun {
                didAutoRun = true
                Task { await run() }
            }
        }
        .onChange(of: windowController.autoRunSequence) { _ in
            Task { await run() }
        }
    }

    @ViewBuilder
    private func outputArea(_ output: ToolOutput) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let image = output.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color(NSColor.windowBackgroundColor)))
                        .contextMenu {
                            Button("复制图片") { copyImage(image) }
                        }
                }
                if !output.text.isEmpty {
                    Text(output.text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(output.isError ? Color.red : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let note = output.note {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "info.circle").font(.system(size: 11))
                        Text(note).font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)

        HStack(spacing: 10) {
            Button(copied ? "✓ 已复制" : (intent == .preview && tool.identifier == "qrcode" ? "复制二维码" : "复制结果")) {
                if intent == .preview, tool.identifier == "qrcode", let image = output.image { copyImage(image) }
                else { copyText(output.text) }
            }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(output.text.isEmpty)
                .frame(minWidth: 100)
            if intent == .preview, tool.identifier == "qrcode" {
                Button("复制链接") { copyText(input) }
            } else if intent == .standard {
                Button("存为剪贴板条目") { saveToClipboard(output) }.disabled(output.text.isEmpty)
            }
            Spacer()
        }
    }

    // MARK: 行为

    private func run() async {
        guard !isRunning else { return }
        isRunning = true
        statusText = ""
        let result = await ToolRegistry.run(tool, input: input, options: options)
        await MainActor.run {
            withAnimation(.easeOut(duration: reduceMotion ? 0.08 : 0.12)) { output = result }
            outputDraft = result.text
            if tool.identifier == "deduplicate" { showOriginal = false }
            isRunning = false
            if intent == .standard, tool.identifier != "deduplicate" { applyDefaultAction(result) }
        }
    }

    /// 按设置中的"默认输出行为"自动处理结果
    private func applyDefaultAction(_ result: ToolOutput) {
        guard !result.text.isEmpty, !result.isError else { return }
        switch BuiltinTools.defaultAction {
        case .copy:
            copyText(result.text)
        case .save:
            saveToClipboard(result)
        }
    }

    private func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        if intent == .standard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.setString(text, forType: .string) { completed("已复制到剪贴板") }
            else { statusText = "复制失败：无法写入剪贴板" }
            return
        }
        let removed = ClipboardTextTransforms.deduplicate(input, ignoreCase: options["ignoreCase"] == "true",
                                                        trim: options["trim"] == "true").removed
        let message = tool.identifier == "deduplicate" ? "已复制，移除 \(removed) 条重复行" : "已复制到剪贴板"
        if let reason = ClipboardManager.shared.copyText(text, successMessage: message) { statusText = reason }
        else { completed(message) }
    }

    private func copyImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation else {
            statusText = "复制失败：无法生成图片数据"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setData(tiff, forType: .tiff) { completed("已复制二维码") }
        else { statusText = "复制失败：无法写入剪贴板" }
    }

    private func completed(_ message: String) {
        statusText = message
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    /// 不直接引用剪贴板模块：通过 ToolboxEventBus 回调交给总控
    private func saveToClipboard(_ result: ToolOutput) {
        statusText = ToolboxEventBus.emitResult(result.text, kind: tool.kind)
            ? "已存为剪贴板条目" : "保存失败：无法写入剪贴板历史"
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "选择要压缩的图片"
        if panel.runModal() == .OK, let url = panel.url {
            input = url.path
        }
    }
}
