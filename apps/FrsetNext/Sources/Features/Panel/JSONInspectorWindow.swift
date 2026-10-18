import AppKit
import SwiftUI

// MARK: - JSON 检视器独立窗口（大文件的正确容器）
//
// popover 只有 340×500，适合看中小 JSON；拖进来的大文件（MB 级）需要宽屏 + 搜索 + 折叠，
// 所以这里给一个可缩放的独立窗口（900×640），复用 JSONInspectorView 渲染。
//
// 大文件保护：读盘前先用 FileManager 判断大小，> 32MB 直接拒绝（不进内存）；
// 解析后节点数 > 2 万由 JSONDocument 自己标记 isTruncated。

public final class JSONInspectorWindowController: NSWindowController {

    public static let shared = JSONInspectorWindowController(window: nil)

    private let maxFileBytes = 32 * 1024 * 1024

    private override init(window: NSWindow?) {
        super.init(window: window)
    }

    @objc required dynamic init?(coder: NSCoder) {
        fatalError("JSONInspectorWindowController 不走 NSCoder")
    }

    // MARK: - 打开入口

    /// 用一段 JSON 文本打开（剪贴板条目 / 已读入内存的内容）
    public func open(text: String, title: String = "JSON 检视器") {
        let controller = makeWindowIfNeeded()
        let host = controller.contentViewController as? JSONInspectorHostController
        host?.load(text: text, title: title, subtitle: "\(text.utf8.count) 字节")
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 用文件打开（拖入的 .json 文件）；超过 32MB 拒绝
    public func open(fileURL: URL) {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int else {
            presentAlert(title: "无法读取文件", message: fileURL.lastPathComponent)
            return
        }
        if size > maxFileBytes {
            presentAlert(title: "文件过大",
                         message: "\(fileURL.lastPathComponent) 为 \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))，超过 32 MB 上限。")
            return
        }

        var text = try? String(contentsOf: fileURL, encoding: .utf8)
        if text == nil {
            text = try? String(contentsOf: fileURL, encoding: .isoLatin1)
        }
        guard let content = text else {
            presentAlert(title: "无法解码", message: "不是 UTF-8 / Latin-1 文本文件。")
            return
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else {
            presentAlert(title: "不是 JSON 文件", message: fileURL.lastPathComponent)
            return
        }

        let controller = makeWindowIfNeeded()
        let host = controller.contentViewController as? JSONInspectorHostController
        host?.load(text: trimmed,
                   title: fileURL.lastPathComponent,
                   subtitle: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override public func close() {
        window?.orderOut(nil)
    }

    // MARK: - 窗口（复用单实例）

    /// 单例复用：窗口只在第一次 open 时创建，之后换内容即可
    private func makeWindowIfNeeded() -> JSONInspectorWindowController {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.minSize = NSSize(width: 640, height: 420)
            window.isReleasedWhenClosed = false
            window.backgroundColor = OfficialChrome.windowBackground   // 官方灰（统一窗口观感）
            // 普通窗口语义：点击别处只是失焦，**不会**自动关闭（不像预览 popover
            // 那样一点外面就消失）——大文件要看半天，不能点一下就没了。
            // 这里刻意不注册 windowDidResignKey / resignFirstResponder 关闭逻辑。
            window.contentViewController = JSONInspectorHostController()
            self.window = window
            shouldCascadeWindows = true
        }
        return self
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - 内容宿主（工具栏 + 树/表 + 状态条）

private final class JSONInspectorHostController: NSHostingController<JSONInspectorRootView> {

    /// 与 rootView 共享同一个状态实例（否则 load() 写进去的内容视图看不到）
    private var state: JSONInspectorState { rootView.state }

    init() {
        let state = JSONInspectorState()
        super.init(rootView: JSONInspectorRootView(state: state))
    }

    @MainActor @objc required dynamic init?(coder: NSCoder) {
        fatalError("JSONInspectorHostController 不走 coder")
    }

    func load(text: String, title: String, subtitle: String) {
        state.title = title
        state.subtitle = subtitle
        state.text = text
    }
}

/// 宿主视图状态（NSHostingController 的 rootView 需要值类型快照，用 ObservableObject 驱动）
final class JSONInspectorState: ObservableObject {
    @Published var title: String = "JSON 检视器"
    @Published var subtitle: String = ""
    @Published var text: String = ""
    @Published var nodeCountText: String = ""
    /// 解析结果（ObservableObject 持有：闭包里也要能改，@State 在闭包里写不了）
    @Published var document: JSONDocument?
    @Published var parseFailed = false
}

struct JSONInspectorRootView: View {
    @ObservedObject var state: JSONInspectorState

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(state.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    copyFormatted()
                } label: {
                    Label("复制格式化", systemImage: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(state.document == nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // 内容
            if state.parseFailed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("JSON 解析失败")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                JSONInspectorView(text: state.text, compact: false)
            }

            Divider()

            // 底部状态条
            HStack {
                Text(state.nodeCountText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 22)
            .background(Color.primary.opacity(0.03))
        }
        .onAppear(perform: parse)
        .onChange(of: state.text) { _ in parse() }
    }

    private func parse() {
        let text = state.text
        guard !text.isEmpty else {
            state.document = nil
            state.nodeCountText = ""
            return
        }
        // 解析放在下一轮（避免阻塞首次布局）
        DispatchQueue.main.async {
            if let document = JSONDocument(text: text) {
                state.document = document
                state.parseFailed = false
                state.nodeCountText = "\(document.totalNodeCount) 个节点" +
                    (document.isTruncated ? " · 已截断" : "")
            } else {
                state.document = nil
                state.parseFailed = true
                state.nodeCountText = ""
            }
        }
    }

    private func copyFormatted() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.text, forType: .string)
    }
}
