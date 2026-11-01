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
                    Text("暂无任务")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.vertical, 2)
                } else {
                    ForEach(queue.tasks) { task in
                        ArchiveTaskRow(task: task)
                    }
                }
            }
        }
        .padding(compact ? 8 : 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        win.title = "归档任务"
        win.isReleasedWhenClosed = false
        // v179：这是全工程唯一一个「裸 NSWindow」——默认浅灰底 + 系统三钮，
        // 与设置/OCR 等文档窗不是一套。统一官方外观（灰底 + 透明标题栏 + 圆钮）。
        win.applyOfficialChrome()
        super.init(window: win)
        win.delegate = self
        win.contentViewController = NSHostingController(rootView: ArchiveProgressPanel())
        win.minSize = NSSize(width: 320, height: 160)
        win.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    public func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}
