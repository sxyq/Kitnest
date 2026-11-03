import AppKit
import SwiftUI

// MARK: - 代码预览独立窗口
//
// 预览窗（剪贴板条目）里的代码视图是「就地看一条」；这里给的是常驻窗口：
// 粘任意代码、换主题/语言、复制富文本，适合边写文档边对照。
//
// 入口：
//   · 状态栏菜单「代码预览…」（自动取剪贴板里的代码，取不到给示例）
//   · 深链 frsetnext://code?file=/path/to/a.swift（排障/自动化）
//   · 深链 frsetnext://code?text=<URL 编码的代码>

public final class CodePreviewWindowController: NSWindowController {

    public static let shared = CodePreviewWindowController(window: nil)

    private override init(window: NSWindow?) {
        super.init(window: window)
    }

    @objc required dynamic init?(coder: NSCoder) {
        fatalError("CodePreviewWindowController 不走 coder")
    }

    // MARK: 入口

    /// 任意文本打开
    public func open(text: String, fileName: String? = nil, title: String? = nil) {
        let controller = makeWindowIfNeeded()
        // NSHostingController 会把窗口缩成视图的 fittingSize（实测 980×700 → 560×360），
        // 换内容前后手动兜住内容尺寸
        let size = controller.window?.contentLayoutRect.size ?? NSSize(width: 980, height: 700)
        let view = CodePreviewView(code: text, fileName: fileName)
        controller.contentViewController = NSHostingController(rootView: view)
        controller.window?.setContentSize(size)
        // v192：窗口外观跟随代码主题的明暗。
        // 之前系统是浅色，窗口标题栏就是浅灰白，而代码区是深色主题 →
        // 上半截浅、下半截深，像两个窗口拼在一起（用户截图里很明显）。
        let theme = CodePreviewPreferences.themeID
            .map { CodeThemeCatalog.theme(id: $0) } ?? CodeThemeCatalog.systemDefault
        controller.window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        controller.window?.backgroundColor = theme.background.withAlphaComponent(0.92)
        controller.window?.title = title ?? (fileName.map { "代码预览 · \($0)" } ?? "代码预览")
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 文件打开（按扩展名锁语言；> 8MB 拒绝，避免把内存打满）
    public func open(fileURL: URL) {
        let maxBytes = 8 * 1024 * 1024
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > maxBytes {
            presentAlert(title: "文件过大",
                         message: "\(fileURL.lastPathComponent) 超过 8 MB，请用编辑器查看。")
            return
        }
        guard var text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            presentAlert(title: "无法解码", message: "不是 UTF-8 文本文件：\(fileURL.lastPathComponent)")
            return
        }
        if text.isEmpty { text = "// 空文件" }
        open(text: text, fileName: fileURL.lastPathComponent)
    }

    /// 状态栏入口：优先取剪贴板里的文本；没有就给一段示例（让窗口不空着）
    public func openFromPasteboardOrSample() {
        if let raw = NSPasteboard.general.string(forType: .string),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           raw.count <= 200_000 {
            open(text: raw)
        } else {
            open(text: Self.sample, fileName: "Sample.swift",
                 title: "代码预览 · 示例（复制一段代码再打开可替换）")
        }
    }

    override public func close() {
        window?.orderOut(nil)
    }

    // MARK: 窗口

    private func makeWindowIfNeeded() -> CodePreviewWindowController {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.minSize = NSSize(width: 560, height: 360)
            window.isReleasedWhenClosed = false
            window.applyOfficialChrome()
            self.window = window
            shouldCascadeWindows = true
            window.center()
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

    // MARK: 示例

    static let sample = """
    import SwiftUI

    /// 主题示例：换主题 / 换语言都在工具条里
    struct Greeting: View {
        @State private var name = "Frset"

        var body: some View {
            VStack(spacing: 12) {
                Text("Hello, \\(name)!")
                    .font(.system(size: 24, weight: .semibold))
                Button("改名") { name = "World" }
            }
            .padding(24)
        }
    }
    """
}
