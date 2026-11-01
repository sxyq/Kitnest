import AppKit
import Combine
import SwiftUI

// MARK: - 归档任务中心（v180）
//
// 交互设计（用户 2026-11-02：「这是压缩相关功能，改一下入口，并想清楚交互」）：
//
// 归档任务有两个界面层级，各管一件事：
//   ① **任务条 HUD**（新增）——任务在跑时自动从右下角浮出，不抢焦点。
//      它回答「现在有没有在干活、干到哪了」，是**唯一自动出现**的入口。
//   ② **任务窗**（已有）——完整列表：每条任务、进度、取消、清除已完成。
//      从 HUD 的「展开」、归档窗工具栏的「任务」按钮、状态栏菜单进入。
//
// 三条约束（都是踩过的坑）：
//   · **不重复**：创建压缩包面板自己内嵌了进度条，它可见时不弹 HUD；
//     完整任务窗可见时也不弹 HUD。
//   · **不打断**：HUD 是 nonactivating panel，点按钮只处理点击，不激活 App、
//     不抢当前 App 的键盘焦点。
//   · **可静音**：用户点掉 HUD 后，本批任务内不再自动弹；新任务入队时解除静音。
//
// 任务从哪来都一致：访达服务、创建面板、归档窗解压/保存、文件盒压缩，
// 最终都走 `ArchiveTaskQueue`，所以 HUD 不需要在各个入口分别接线。

@MainActor
final class ArchiveTaskCenter {

    static let shared = ArchiveTaskCenter()

    private var bag = Set<AnyCancellable>()
    private var hideWork: DispatchWorkItem?
    private var started = false
    /// 本批任务被用户手动收起后不再自动弹（新任务入队时清空）
    private var muted = false
    private var lastActiveIDs: Set<UUID> = []

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        ArchiveTaskQueue.shared.$tasks
            .receive(on: RunLoop.main)
            .sink { [weak self] tasks in
                Task { @MainActor in self?.apply(tasks) }
            }
            .store(in: &bag)
        Log.info("Archive", "任务中心已启动（HUD 自动出现）")
        ArchiveTaskDemo.startIfRequested()
    }

    /// 窗口显隐变化后重新判断（创建面板关闭 / 任务窗关闭）
    func refresh() {
        apply(ArchiveTaskQueue.shared.tasks)
    }

    /// 用户在 HUD 上点「收起」
    func muteCurrentBatch() {
        muted = true
        ArchiveTaskHUDController.shared.hide()
    }

    private func apply(_ tasks: [ArchiveTaskQueue.ArchiveTask]) {
        let active = tasks.filter { !$0.isFinished }
        let activeIDs = Set(active.map(\.id))

        // 有新任务加入 → 解除静音（上一批被收起，不代表这一批也要藏）
        if !activeIDs.subtracting(lastActiveIDs).isEmpty {
            muted = false
            hideWork?.cancel()
            hideWork = nil
        }
        lastActiveIDs = activeIDs

        guard !active.isEmpty else {
            // 全部结束：先在 HUD 上停一下「已完成 / N 项失败」，再淡出。
            // 失败留久一点（8s），让用户来得及看到是哪一项。
            guard ArchiveTaskHUDController.shared.isVisible else { return }
            let failed = tasks.contains { $0.state == .failed }
            ArchiveTaskHUDController.shared.showFinished(failed: failed, total: tasks.count)
            hideWork?.cancel()
            let work = DispatchWorkItem { ArchiveTaskHUDController.shared.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (failed ? 8 : 2.5), execute: work)
            return
        }

        hideWork?.cancel()
        hideWork = nil

        guard !muted else { return }
        // 创建面板自己带进度条；任务窗是完整列表 —— 任一可见都不弹 HUD
        guard !ArchiveProgressWindowController.isVisible,
              !ArchiveCreateWindowController.hasVisibleWindow else {
            ArchiveTaskHUDController.shared.hide()
            return
        }

        ArchiveTaskHUDController.shared.show(tasks: tasks)
    }
}

// MARK: - 任务条 HUD

@MainActor
final class ArchiveTaskHUDModel: ObservableObject {
    @Published var icon = "archivebox"
    @Published var tint = Theme.accent
    @Published var title = ""
    @Published var subtitle = ""
    @Published var countText = ""
    /// < 0 = 不确定进度（7zz 没吐百分比）
    @Published var progress: Double = 0
    @Published var finished = false
}

@MainActor
final class ArchiveTaskHUDController {

    static let shared = ArchiveTaskHUDController()

    private var panel: NSPanel?
    private let model = ArchiveTaskHUDModel()

    var isVisible: Bool { panel?.isVisible == true }

    private init() {}

    func show(tasks: [ArchiveTaskQueue.ArchiveTask]) {
        let active = tasks.filter { !$0.isFinished }
        guard let current = active.first(where: { $0.state == .running }) ?? active.first else { return }
        let waiting = tasks.filter { $0.state == .waiting }.count
        let running = tasks.filter { $0.state == .running }.count
        let finishedCount = tasks.filter { $0.isFinished }.count
        let total = tasks.count

        model.finished = false
        model.icon = current.kind.icon
        model.tint = current.state == .running ? Theme.accent : .secondary
        model.title = "\(current.kind.label)中 · \(current.title)"
        model.subtitle = current.message.isEmpty ? "\(running) 个进行中" : current.message
        model.progress = current.progress
        var bits: [String] = []
        if finishedCount > 0 { bits.append("\(finishedCount)/\(total)") }
        if waiting > 0 { bits.append("等待 \(waiting)") }
        model.countText = bits.joined(separator: " · ")

        present()
    }

    func showFinished(failed: Bool, total: Int) {
        model.finished = true
        model.icon = failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        model.tint = failed ? Color(red: 0.95, green: 0.35, blue: 0.30) : Color(red: 0.28, green: 0.76, blue: 0.42)
        model.title = failed ? "归档任务有失败" : "归档任务已完成"
        model.subtitle = failed ? "点开查看是哪一项失败" : "共 \(total) 项"
        model.progress = 1
        model.countText = ""
        present()
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.dFast
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        }
    }

    private func present() {
        let panel = ensurePanel()
        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.Motion.dPage
                panel.animator().alphaValue = 1
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let root = ArchiveTaskHUDView(
            model: model,
            onExpand: { [weak self] in
                self?.hide()
                ArchiveProgressWindowController.show()
            },
            onDismiss: {
                ArchiveTaskCenter.shared.muteCurrentBatch()
            })

        let hosting = NSHostingView(rootView: root)
        hosting.setFrameSize(hosting.fittingSize)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// 右下角（Dock 上方），留 16pt 边距
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 16,
                                     y: vf.minY + 16))
    }
}

// MARK: - 任务条视图

struct ArchiveTaskHUDView: View {
    @ObservedObject var model: ArchiveTaskHUDModel
    var onExpand: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(model.tint.opacity(0.16))
                    .frame(width: 30, height: 30)
                Image(systemName: model.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    if !model.countText.isEmpty {
                        Text(model.countText)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }

                if model.finished {
                    // 完成态不再显示进度条，避免"一直在跑"的错觉
                    EmptyView()
                } else if model.progress >= 0 {
                    ProgressView(value: max(0, min(1, model.progress)))
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }

                Text(model.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            VStack(spacing: 6) {
                Button(action: onExpand) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("展开任务列表")
                .accessibilityLabel("展开任务列表")

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("收起（任务继续在后台运行）")
                .accessibilityLabel("收起任务条")
            }
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 336)
        .glassPlate()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous))
        .onTapGesture(perform: onExpand)
    }
}

// MARK: - 排障：演示任务（probe.archiveTask=YES）
//
// 用来验证 HUD 的浮现/进度/完成态——真机压缩要真选文件，自动化点不到。
// 走的仍是 ArchiveTaskQueue 的真实入队通道，不伪造 UI 状态。
enum ArchiveTaskDemo {
    static func startIfRequested() {
        guard UserDefaults.standard.bool(forKey: "probe.archiveTask") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            ArchiveTaskQueue.shared.enqueue(kind: .compress, title: "演示压缩 · Photos-2026.zip") { taskID, done in
                let total = 24
                var step = 0
                func tick() {
                    step += 1
                    if step > total {
                        done(true, "压缩完成")
                        return
                    }
                    ArchiveTaskQueue.shared.updateProgress(
                        taskID: taskID, Double(step) / Double(total), message: "压缩中 \(step)/\(total) 项")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: tick)
                }
                ArchiveTaskQueue.shared.updateProgress(taskID: taskID, 0, message: "准备中…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: tick)
            }
        }
    }
}
