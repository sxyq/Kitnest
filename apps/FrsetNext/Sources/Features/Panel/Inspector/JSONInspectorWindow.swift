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

    /// 下一次 open(fileURL:) 预填的搜索词（深链排障用）
    public var openQuery: String = ""

    /// 视图状态（窗口单例复用，换内容只改这里）
    private var state: JSONInspectorState?

    private override init(window: NSWindow?) {
        super.init(window: window)
    }

    @objc required dynamic init?(coder: NSCoder) {
        fatalError("JSONInspectorWindowController 不走 NSCoder")
    }

    // MARK: - 打开入口

    /// 用一段 JSON 文本打开（剪贴板条目 / 已读入内存的内容）
    /// - Parameter query: 打开时预填的搜索词（深链/自动化验收用，正常调用传空）
    public func open(text: String, title: String = "JSON 检视器", query: String = "") {
        let controller = makeWindowIfNeeded()
        controller.state?.load(text: text, title: title,
                              subtitle: "\(text.utf8.count) 字节", query: query)
        controller.window?.title = title
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // v198：从触发点（拖入/菜单）展开整块检视器
        if let w = controller.window { WindowReveal.playInFromMouse(on: w) }
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
        // 按扩展名放行：.jsonl / .ndjson 每行一条记录，首字符不一定能代表整份内容
        let ext = fileURL.pathExtension.lowercased()
        let jsonish = ["json", "jsonl", "ndjson", "geojson", "ipynb"].contains(ext)
        guard jsonish || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else {
            presentAlert(title: "不是 JSON 文件", message: fileURL.lastPathComponent)
            return
        }

        let controller = makeWindowIfNeeded()
        controller.state?.load(text: trimmed,
                   title: fileURL.lastPathComponent,
                   subtitle: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file),
                   query: openQuery)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // v198：从触发点（拖入/菜单）展开整块检视器
        if let w = controller.window { WindowReveal.playInFromMouse(on: w) }
    }

    override public func close() {
        guard let w = window, w.isVisible else { return }
        WindowReveal.playOutToLastAnchor(on: w) { [weak w] in
            w?.orderOut(nil)
            if let w { WindowReveal.reset(w) }
        }
    }

    // MARK: - 窗口（复用单实例）

    /// 单例复用：窗口只在第一次 open 时创建，之后换内容即可
    private func makeWindowIfNeeded() -> JSONInspectorWindowController {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            // 640 太窄：视图工具条 + 表格列一挤就出现左侧被裁（实测截图）
            window.minSize = NSSize(width: 720, height: 440)
            window.title = "JSON 检视器"
            window.isReleasedWhenClosed = false
            // v179：原来只设了底色，标题栏仍是系统样式（与其它文档窗不一致）
            window.applyOfficialChrome()
            // 普通窗口语义：点击别处只是失焦，**不会**自动关闭（不像预览 popover
            // 那样一点外面就消失）——大文件要看半天，不能点一下就没了。
            // 这里刻意不注册 windowDidResignKey / resignFirstResponder 关闭逻辑。
            // 朴素 NSView 当 contentView + NSHostingView 铺满：
            // contentViewController 会把窗口撑成 SwiftUI fittingSize，超宽时内容居中溢出被裁
            let state = JSONInspectorState()
            let host = NSHostingView(rootView: JSONInspectorRootView(state: state))
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            window.contentView = container
            window.setContentSize(NSSize(width: 980, height: 680))
            self.state = state
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

/// 宿主视图状态（NSHostingController 的 rootView 需要值类型快照，用 ObservableObject 驱动）
final class JSONInspectorState: ObservableObject {
    @Published var title: String = "JSON 检视器"
    @Published var subtitle: String = ""
    @Published var text: String = ""
    @Published var nodeCountText: String = ""
    /// 解析结果（ObservableObject 持有：闭包里也要能改，@State 在闭包里写不了）
    @Published var document: JSONDocument?
    @Published var parseFailed = false
    /// 预填搜索词（空 = 不搜索）
    @Published var searchSeed: String = ""
    /// 每次打开新内容换一个 id：让内部视图按新文档重算默认视图（记录表 → 表格，其余 → 树形）
    @Published var sessionID = UUID()

    func load(text: String, title: String, subtitle: String, query: String = "") {
        sessionID = UUID()
        self.title = title
        self.subtitle = subtitle
        self.text = text
        self.searchSeed = query
    }
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
            } else if let document = state.document {
                JSONInspectorView(document: document, compact: false, initialQuery: state.searchSeed)
                    .id(ObjectIdentifier(document))
            } else {
                JSONInspectorView(text: state.text, compact: false, initialQuery: state.searchSeed)
            }

            Divider()

            // 底部状态条
            HStack {
                Text(state.nodeCountText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 22)
            .background(Theme.cardFill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: parse)
        .onChange(of: state.text) { _ in parse() }
        // 主题统一入口：JSON 检视器的强调色 + Midnight（此前两者都没接）
        .frsetThemeChrome()
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
                if document.isJSONL {
                    state.nodeCountText = "JSONL · 有效 \(document.validLineCount) 行" +
                        (document.errorLines.isEmpty ? "" : " · 错误 \(document.errorLines.count) 行") +
                        " · \(document.totalNodeCount) 个节点"
                } else {
                    state.nodeCountText = "\(document.totalNodeCount) 个节点" +
                        (document.isTruncated ? " · 已截断" : "")
                }
            } else {
                state.document = nil
                state.parseFailed = true
                state.nodeCountText = ""
            }
        }
    }

    /// 复制「格式化后」的 JSON（原来是复制原文，跟按钮名字对不上）
    private func copyFormatted() {
        let payload: String
        if let document = state.document, !document.isJSONL,
           let data = document.sourceText.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           let text = String(data: pretty, encoding: .utf8) {
            payload = text
        } else {
            payload = state.document?.sourceText ?? state.text
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        Toast.show("已复制格式化 JSON", icon: "doc.on.doc")
    }
}
