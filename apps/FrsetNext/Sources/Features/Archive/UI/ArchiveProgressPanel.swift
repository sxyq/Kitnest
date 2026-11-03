import AppKit
import SwiftUI

// MARK: - 进度与任务面板（v127（ArcZip P2）：ArcZip「进度与任务」）
//
// 可展开/收起的底部抽屉式面板：
//   · 顶部汇总：「运行中 2 · 等待 1 · 失败 0」+ 全部取消 / 清除已完成
//   · 任务行：图标（kind）+ 标题 + 进度条（无百分比时 indeterminate 转圈）+ 取消按钮
// 两种用法：
//   1. 嵌入创建面板（ArchiveProgressPanel(compact: true)，压缩时显示）
//   2. 独立浮窗（ArchiveProgressWindowController.show()，浏览窗工具栏按钮弹出——主代理接线）

// MARK: 面板视图

public struct ArchiveProgressPanel: View {

    @ObservedObject private var queue = ArchiveTaskQueue.shared
    private let compact: Bool
    /// v127：项目内 @State 宏不可用（SwiftUIMacros 插件缺失），用 @Stored 兼容层
    @Stored private var expanded: Bool

    public init(compact: Bool = false, expanded: Bool = true) {
        self.compact = compact
        self._expanded = Stored(wrappedValue: expanded)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded {
                if queue.tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("暂无任务")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                        if !compact {
                            Text("压缩、解压、加密另存都会汇到这里。开始压缩后点「转到后台」，"
                                 + "面板关掉任务照跑，右下角的进度条会接住它。")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                } else if compact {
                    // 内嵌在创建面板里：只显示最近几条，不滚动（面板本身高度由 sheet 决定）
                    ForEach(queue.tasks) { task in
                        ArchiveTaskRow(task: task)
                    }
                } else {
                    // v182：独立窗里任务会越攒越多，之前没有滚动容器 —— 超出的行直接被窗口裁掉。
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 0) {
                            ForEach(queue.tasks) { task in
                                ArchiveTaskRow(task: task)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .padding(compact ? 8 : 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(compact ? Color.clear : Color(nsColor: .controlBackgroundColor))
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(Theme.Motion.fast) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起" : "展开")

            // 顶部汇总：「运行中 2 · 等待 1 · 失败 0」
            Text(queue.summaryText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            if queue.tasks.contains(where: { !$0.isFinished }) {
                Button("全部取消") { queue.cancelAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            if queue.tasks.contains(where: { $0.isFinished }) {
                Button("清除已完成") { queue.clearFinished() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: 任务行

struct ArchiveTaskRow: View {

    @ObservedObject private var queue = ArchiveTaskQueue.shared
    let task: ArchiveTaskQueue.ArchiveTask

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: task.kind.icon)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if task.state == .running || task.state == .waiting {
                    if task.progress >= 0 {
                        // 有 -bsp1 百分比：确定进度条
                        ProgressView(value: task.progress)
                            .controlSize(.small)
                    } else {
                        // 兜底：不确定进度（7zz 没吐百分比）
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !task.message.isEmpty {
                    Text(task.message)
                        .font(.system(size: 11))
                        .foregroundStyle(task.state == .failed ? Color.red : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: task.state.icon)
                .font(.system(size: 11))
                .foregroundStyle(stateColor)

            // v181：完成后能直接跳到产物（压缩包 / 解压目录）——
            // 原来任务行只写「完成」，用户还得自己回想「压到哪儿去了」
            if task.isFinished, let output = task.outputURL,
               FileManager.default.fileExists(atPath: output.path) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("在访达中显示：\(output.lastPathComponent)")
            }

            if !task.isFinished {
                Button {
                    queue.cancel(taskID: task.id)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("取消该任务（终止 7zz 子进程）")
            }
        }
        .padding(.vertical, 3)
    }

    private var iconColor: Color {
        switch task.kind {
        case .encrypt: return .orange
        case .remove: return .red
        default: return Theme.accent
        }
    }

    private var stateColor: Color {
        switch task.state {
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .running: return Theme.accent
        case .waiting: return .secondary
        }
    }
}

// MARK: 独立浮窗（浏览窗工具栏 / 菜单入口用）

public final class ArchiveProgressWindowController: NSWindowController, NSWindowDelegate {

    private static var current: ArchiveProgressWindowController?

    /// 任务窗是否可见（HUD 用它避免重复展示，v180）
    public static var isVisible: Bool { current?.window?.isVisible == true }

    /// 弹出（或前置）任务面板浮窗
    public static func show() {
        if let current {
            current.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = ArchiveProgressWindowController()
        current = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.probeCloseIfNeeded()
    }

    public static func toggle() {
        if let win = current?.window, win.isVisible {
            win.orderOut(nil)
            return
        }
        show()
    }

    private init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "任务队列"
        win.isReleasedWhenClosed = false
        // v179：这是全工程唯一一个「裸 NSWindow」——默认浅灰底 + 系统三钮，
        // 与设置/OCR 等文档窗不是一套。统一官方外观（灰底 + 透明标题栏 + 圆钮）。
        win.applyOfficialChrome()
        super.init(window: win)
        win.delegate = self
        // v181：`NSHostingController` 默认会用 SwiftUI 的 fittingSize 反向压窗口——
        // 任务行是「图标 + 文本 + Spacer」，理想宽度只有 ~190pt，窗口一开就被压窄、
        // 标题被截成「任务…」、按钮挤在一起。这里禁掉反推并显式给内容尺寸。
        // v182：用 NSHostingView 直接当 contentView，不走 contentViewController ——
        // NSWindowController 在 showWindow 时会把窗口高度压回 SwiftUI 的 fittingSize
        // （实测 400×260 → 400×122，内容被裁）。这样窗口尺寸完全由我们说了算。
        // 外面再套一个朴素 NSView 当 contentView：NSHostingView 直接当 contentView 时，
        // 窗口会把高度对齐到 SwiftUI 的 fittingHeight（400×260 → 400×90+32），
        // 说明文字照样被裁。普通 NSView 没有 intrinsicContentSize，窗口才不会自动缩。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 170))
        container.autoresizingMask = [.width, .height]
        // 顶端/左对齐：否则窗口一拉高，整块内容会垂直居中，上方留一大片灰
        // 铺满 + 同色底：否则内容卡片下面会露出一大片灰（窗口底色），像界面没画完
        let host = NSHostingView(rootView: ArchiveProgressPanel()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor)))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        win.contentView = container
        // v182（用户：「关不掉」截图里内容被裁掉一半）：窗口高度只有 122pt 时，
        // 底下的说明文字既被横向裁切又被纵向裁切，看起来像界面坏了。
        // 这里给一个能装下空态文案的最小尺寸，并且**不信任旧的自动保存尺寸**——
        // 之前被压成 189pt 那次留下的 320×122 会被原样恢复，setContentSize 完全没用。
        win.minSize = NSSize(width: 380, height: 160)
        win.setContentSize(NSSize(width: 400, height: 170))
        // v180：记住上次位置（原来是每次 center，用户挪到角落下次又回中间）。
        // v182：只存**位置**，不存尺寸。`setFrameAutosaveName` 会把旧版本压出来的
        // 320×122 原样恢复（宽度被 minSize 夹回 380，高度却仍是 122，内容照样被裁），
        // 而且恢复发生在 setContentSize 之后，怎么设都没用。
        if let saved = UserDefaults.standard.string(forKey: "archive.task.window.origin") {
            win.setFrameOrigin(NSPointFromString(saved))
        } else {
            win.center()
        }
        clampToScreen(win)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 排障（v182）：`probe.taskClose=YES` → 1s 后对自绘圆钮做一次**合成鼠标点击**
    /// （构造 NSEvent 交给 window.sendEvent，走完整 hitTest + 事件派发，不动系统光标），
    /// 并记录 hitTest 命中的视图。用来区分「按钮没接住点击」和「按钮动作没生效」。
    func probeCloseIfNeeded() {
        let mode = UserDefaults.standard.string(forKey: "probe.taskClose") ?? ""
        guard !mode.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let win = self?.window,
                  let btn = win.standardWindowButton(.closeButton) else {
                Log.warn("Archive", "任务窗探针：找不到标准关闭钮")
                return
            }
            let p = btn.convert(NSPoint(x: btn.bounds.midX, y: btn.bounds.midY), to: nil)
            let hit = win.contentView?.superview?.hitTest(p)
            Log.info("Archive", "任务窗探针：content=\(win.contentView?.frame ?? .zero) "
                     + "fitting=\(win.contentView?.fittingSize ?? .zero) ")
            Log.info("Archive", "任务窗探针：frame=\(win.frame) btnFrame=\(btn.frame) "
                     + "enabled=\(btn.isEnabled) hasTarget=\(btn.target != nil) "
                     + "action=\(btn.action.map(NSStringFromSelector) ?? "nil") "
                     + "hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") "
                     + "isKey=\(win.isKeyWindow) appActive=\(NSApp.isActive)")
            if mode == "key" {
                let std = win.standardWindowButton(.closeButton)
                Log.info("Archive", "任务窗探针：stdClose exists=\(std != nil) "
                         + "enabled=\(std?.isEnabled ?? false) alpha=\(std?.alphaValue ?? -1) "
                         + "closable=\(win.styleMask.contains(.closable)) "
                         + "delegate=\(String(describing: win.delegate.map { type(of: $0) }))")
                // ⌘W / 菜单「关闭」走的就是 performClose
                win.performClose(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    Log.info("Archive", "任务窗探针：performClose 后 isVisible=\(win.isVisible)")
                    if win.isVisible {
                        win.close()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            Log.info("Archive", "任务窗探针：close() 后 isVisible=\(win.isVisible)")
                        }
                    }
                }
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p,
                                             modifierFlags: [], timestamp: now,
                                             windowNumber: win.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1),
               let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p,
                                           modifierFlags: [], timestamp: now + 0.05,
                                           windowNumber: win.windowNumber, context: nil,
                                           eventNumber: 1, clickCount: 1, pressure: 0) {
                win.sendEvent(down)
                win.sendEvent(up)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Log.info("Archive", "任务窗探针：合成点击后 isVisible=\(win.isVisible)")
            }
        }
    }

    public func windowDidMove(_ notification: Notification) {
        guard let win = window else { return }
        UserDefaults.standard.set(NSStringFromPoint(win.frame.origin),
                                  forKey: "archive.task.window.origin")
    }

    /// 记住的位置可能来自另一块屏幕 / 分辨率变了 —— 落到屏幕外就回中间
    private func clampToScreen(_ win: NSWindow) {
        let visible = (win.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        if !visible.isEmpty && !visible.intersects(win.frame) {
            win.center()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        Self.current = nil
        // 关掉详情窗时若仍有任务在跑 → HUD 重新接管（下次 runloop，窗口已真正隐藏）
        DispatchQueue.main.async { ArchiveTaskCenter.shared.refresh() }
    }
}
