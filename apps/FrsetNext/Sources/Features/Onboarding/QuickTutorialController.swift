import AppKit
import Combine

enum QuickTutorial: String, CaseIterable, Identifiable, Hashable {
    case clipboard, screenshot, transfer

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: return "找回刚刚复制的内容"
        case .screenshot: return "截图并复制或识别文字"
        case .transfer: return "把文件发送到手机"
        }
    }
    var symbol: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .screenshot: return "camera.viewfinder"
        case .transfer: return "iphone.and.arrow.forward"
        }
    }
}

enum QuickTutorialStatus: Int, Equatable {
    case notStarted, inProgress, completed
    var label: String {
        switch self {
        case .notStarted: return "未开始"
        case .inProgress: return "进行中"
        case .completed: return "已完成"
        }
    }
}

extension Notification.Name {
    static let tutorialScreenshotCaptured = Notification.Name("Kitnest.tutorial.screenshotCaptured")
    static let tutorialScreenshotCopied = Notification.Name("Kitnest.tutorial.screenshotCopied")
    static let tutorialScreenshotOCRCompleted = Notification.Name("Kitnest.tutorial.screenshotOCRCompleted")
    static let tutorialFileTransferCompleted = Notification.Name("Kitnest.tutorial.fileTransferCompleted")
}

final class QuickTutorialController: ObservableObject {
    static let shared = QuickTutorialController()
    private let defaults = UserDefaults.standard
    private let selectionKey = "onboarding.quickTutorial.selected"
    @Published private(set) var selected: QuickTutorial?
    @Published private(set) var message = ""
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var clipboardOpenRetry: DispatchWorkItem?

    private init() {
        selected = defaults.string(forKey: selectionKey).flatMap(QuickTutorial.init(rawValue:))
        observers = [
            NotificationCenter.default.addObserver(forName: .tutorialScreenshotCaptured, object: nil, queue: .main) { [weak self] note in
                guard let self, self.selected == .screenshot, self.status(.screenshot) == .inProgress,
                      self.step(.screenshot) == 1,
                      let path = note.userInfo?["path"] as? String,
                      path != self.defaults.string(forKey: self.key(.screenshot, "capturePath")) else { return }
                self.defaults.set(path, forKey: self.key(.screenshot, "capturePath"))
                self.setStep(2, for: .screenshot)
                self.message = "截图已暂存。请在操作条选择「复制」或「识字」。"
            },
            NotificationCenter.default.addObserver(forName: .tutorialScreenshotCopied, object: nil, queue: .main) { [weak self] note in
                guard let self, self.selected == .screenshot, self.step(.screenshot) >= 2,
                      note.userInfo?["path"] as? String == self.defaults.string(forKey: self.key(.screenshot, "capturePath")) else { return }
                self.complete(.screenshot, message: "截图已复制到系统剪贴板，可以回到原应用粘贴。")
            },
            NotificationCenter.default.addObserver(forName: .tutorialScreenshotOCRCompleted, object: nil, queue: .main) { [weak self] note in
                guard let self, self.selected == .screenshot, self.step(.screenshot) >= 2,
                      note.userInfo?["path"] as? String == self.defaults.string(forKey: self.key(.screenshot, "capturePath")) else { return }
                let result = CaptureOCRNotify.isSilent
                    ? "识别文字已复制到系统剪贴板；通知中也会显示结果。"
                    : "识别文字已显示在 Kitnest 的结果窗口中。"
                self.complete(.screenshot, message: result)
            },
            NotificationCenter.default.addObserver(forName: .tutorialFileTransferCompleted, object: nil, queue: .main) { [weak self] note in
                guard let self, self.selected == .transfer, self.step(.transfer) >= 2,
                      let paths = note.userInfo?["paths"] as? [String],
                      let target = self.defaults.string(forKey: self.key(.transfer, "targetPath")),
                      paths.contains(target) else { return }
                self.complete(.transfer, message: "已由所选发送方式确认传输。暂存副本位于本地中转目录。")
            }
        ]
        resumeTracking()
    }

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func status(_ task: QuickTutorial) -> QuickTutorialStatus {
        QuickTutorialStatus(rawValue: defaults.integer(forKey: key(task, "status"))) ?? .notStarted
    }

    func step(_ task: QuickTutorial) -> Int { defaults.integer(forKey: key(task, "step")) }
    var currentStep: Int { selected.map(step) ?? 0 }
    var displayStep: Int {
        guard let selected else { return 1 }
        switch selected {
        case .clipboard: return min(step(selected) + 1, 3)
        case .screenshot: return step(selected) <= 1 ? 1 : min(step(selected), 3)
        case .transfer: return step(selected) <= 1 ? 1 : min(step(selected), 3)
        }
    }
    var currentStatus: QuickTutorialStatus { selected.map(status) ?? .notStarted }
    var sampleText: String { defaults.string(forKey: key(.clipboard, "sample")) ?? "Kitnest 新手教程示例" }
    var transferTargetID: String? { defaults.string(forKey: key(.transfer, "targetID")) }
    var resultActionTitle: String {
        switch selected {
        case .clipboard: return "打开剪贴板工作台"
        case .screenshot: return "在访达中显示截图"
        case .transfer: return "在访达中显示暂存文件"
        case nil: return "查看结果位置"
        }
    }

    func select(_ task: QuickTutorial) {
        selected = task
        defaults.set(task.rawValue, forKey: selectionKey)
        defaults.set(WelcomeWindowController.onboardingVersion,
                     forKey: Preferences.Keys.onboardingWelcomeSeenVersion)
        message = ""
    }

    func returnToTasks() {
        selected = nil
        defaults.removeObject(forKey: selectionKey)
        message = ""
    }

    func skip() { returnToTasks() }

    func resumeClipboardRecording() {
        ClipboardManager.shared.resumeRecording()
        objectWillChange.send()
    }

    func begin(_ task: QuickTutorial) {
        select(task)
        if status(task) == .completed {
            defaults.set(QuickTutorialStatus.inProgress.rawValue, forKey: key(task, "status"))
            setStep(0, for: task)
        } else if status(task) == .notStarted {
            defaults.set(QuickTutorialStatus.inProgress.rawValue, forKey: key(task, "status"))
            setStep(0, for: task)
        }
        resumeTracking()
    }

    func restart(_ task: QuickTutorial) {
        defaults.set(QuickTutorialStatus.notStarted.rawValue, forKey: key(task, "status"))
        setStep(0, for: task)
        begin(task)
    }

    func copyClipboardExample() {
        guard !ClipboardManager.shared.isRecordingPaused else {
            message = "剪贴板记录已暂停。恢复记录后再复制示例文字。"
            return
        }
        let text = "Kitnest 新手教程示例 · \(UUID().uuidString.prefix(6))"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            message = "示例文字写入剪贴板失败，请重试。"
            return
        }
        defaults.set(text, forKey: key(.clipboard, "sample"))
        defaults.set(pasteboard.changeCount, forKey: key(.clipboard, "changeCount"))
        defaults.set(QuickTutorialStatus.inProgress.rawValue, forKey: key(.clipboard, "status"))
        setStep(1, for: .clipboard)
        message = "示例已复制，Kitnest 正在将它保存到剪贴板历史。"
        resumeTracking()
    }

    var clipboardSampleSaved: Bool {
        // 2026-11-26 修复：原实现对全部历史做全量线性扫描 + 全文比较，被 0.5s 轮询和
        // 250ms 重试循环反复调用。示例条目刚写入时位于最前，只扫最近 200 条即可，
        // 把周期性主线程开销钳住。
        ClipboardManager.shared.items.prefix(200).contains { $0.content == sampleText }
    }

    var isScreenshotActive: Bool {
        selected == .screenshot && status(.screenshot) == .inProgress && step(.screenshot) >= 1
    }

    func openClipboard() {
        guard clipboardSampleSaved else { retryOpenClipboard(attempt: 0); return }
        clipboardOpenRetry?.cancel(); clipboardOpenRetry = nil
        setStep(3, for: .clipboard)
        message = "在列表找到示例并点击复制；看到完成提示后回到 Kitnest。"
        WelcomeWindowController.shared.close()
        NSApp.activate(ignoringOtherApps: true)
        MonitorCenterPresenter.shared.selectHome()
        ServiceLocator.panel?.show()
    }

    /// v266：示例刚写进系统剪贴板时，历史落库有几百毫秒延迟。
    /// 旧实现直接 return —— 用户点「打开剪贴板」毫无反应，以为教程坏了。
    /// 现在最多等 2 秒（8×250ms），仍没有就明确说缺什么。
    private func retryOpenClipboard(attempt: Int) {
        clipboardOpenRetry?.cancel()
        guard attempt < 8 else {
            clipboardOpenRetry = nil
            message = "没有等到示例进入历史。确认剪贴板监听已开启，或手动复制示例文本后再点「打开剪贴板」。"
            return
        }
        message = "示例还在写入剪贴板历史，稍等一下…"
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.clipboardSampleSaved { self.openClipboard() }
            else { self.retryOpenClipboard(attempt: attempt + 1) }
        }
        clipboardOpenRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func startScreenshot() {
        begin(.screenshot)
        message = "正在确认屏幕录制权限…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await ScreenshotManager.shared.probePermission() else {
                await PermissionCenter.shared.probeScreenRecording()
                guard self.selected == .screenshot else { return }
                self.message = "本教程只需要屏幕录制权限。授权后回到这里，再点「开始截图」。"
                return
            }
            guard self.selected == .screenshot else { return }
            self.defaults.set(ScreenshotManager.shared.recent.first?.url.path ?? "",
                              forKey: self.key(.screenshot, "capturePath"))
            self.setStep(1, for: .screenshot)
            self.message = "框选窗口或区域；按 Esc 可取消。完成后从操作条选择复制或识字。"
            WelcomeWindowController.shared.close()
            ScreenshotManager.shared.captureRegion()
        }
    }

    func openTransfer() {
        if status(.transfer) != .inProgress { begin(.transfer) }
        if step(.transfer) == 0 {
            defaults.set(LocalTransferStore.shared.items.map(\.id), forKey: key(.transfer, "initialIDs"))
            setStep(1, for: .transfer)
        }
        message = step(.transfer) < 2
            ? "添加一个你选择的文件；Kitnest 不会自动上传或发送。"
            : "选中暂存文件，选择发送方式并在手机端接收。"
        WelcomeWindowController.shared.close()
        NSApp.activate(ignoringOtherApps: true)
        MonitorCenterPresenter.shared.selectTransferDock()
        ServiceLocator.panel?.show()
    }

    func chooseTransferFile() {
        if status(.transfer) != .inProgress { begin(.transfer) }
        if step(.transfer) == 0 {
            defaults.set(LocalTransferStore.shared.items.map(\.id), forKey: key(.transfer, "initialIDs"))
            setStep(1, for: .transfer)
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要加入本地暂存的文件"
        guard panel.runModal() == .OK else { return }
        LocalTransferStore.shared.add(urls: panel.urls) { [weak self] count in
            guard let self else { return }
            guard count > 0 else {
                self.message = LocalTransferStore.shared.lastError ?? "文件未加入本地暂存。"
                return
            }
            let initial = Set(self.defaults.stringArray(forKey: self.key(.transfer, "initialIDs")) ?? [])
            if let item = LocalTransferStore.shared.items.first(where: { !initial.contains($0.id) }) {
                self.defaults.set(item.stagedURL.path, forKey: self.key(.transfer, "targetPath"))
                self.defaults.set(item.id, forKey: self.key(.transfer, "targetID"))
            }
            self.setStep(2, for: .transfer)
            self.message = "文件已暂存。文件中转已打开；选中它，选择发送方式并在手机端接收。"
            self.openTransfer()
        }
    }

    func openResult() {
        guard let task = selected else { return }
        switch task {
        case .clipboard:
            FloatingClipboardWindowController.shared.show()
        case .screenshot:
            if let path = defaults.string(forKey: key(.screenshot, "capturePath")), !path.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        case .transfer:
            if let path = defaults.string(forKey: key(.transfer, "targetPath")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else {
                NSWorkspace.shared.open(LocalTransferPaths.root)
            }
        }
    }

    private func resumeTracking() {
        guard timer == nil, QuickTutorial.allCases.contains(where: { status($0) == .inProgress }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshProgress() }
    }

    private func refreshProgress() {
        if status(.clipboard) == .inProgress {
            if step(.clipboard) == 1, clipboardSampleSaved {
                setStep(2, for: .clipboard)
                message = "示例已出现在剪贴板历史。打开剪贴板并重新复制它。"
            }
            let pasteboard = NSPasteboard.general
            if step(.clipboard) == 3,
               pasteboard.changeCount > defaults.integer(forKey: key(.clipboard, "changeCount")),
               pasteboard.string(forType: .string) == sampleText,
               pasteboard.data(forType: ClipboardManager.selfWriteMarkerPasteboardType) != nil {
                complete(.clipboard, message: "已从 Kitnest 历史重新复制。回到原应用按 ⌘V 粘贴。")
            }
        }
        if status(.transfer) == .inProgress {
            let initial = Set(defaults.stringArray(forKey: key(.transfer, "initialIDs")) ?? [])
            if step(.transfer) == 1,
               LocalTransferStore.shared.items.contains(where: { !initial.contains($0.id) }) {
                setStep(2, for: .transfer)
                if let item = LocalTransferStore.shared.items.first(where: { !initial.contains($0.id) }) {
                    defaults.set(item.stagedURL.path, forKey: key(.transfer, "targetPath"))
                    defaults.set(item.id, forKey: key(.transfer, "targetID"))
                }
                message = "文件已进入本地暂存。打开文件中转，选中它并主动发送。"
            }
        }
        if !QuickTutorial.allCases.contains(where: { status($0) == .inProgress }) {
            timer?.invalidate()
            timer = nil
        }
    }

    private func complete(_ task: QuickTutorial, message: String) {
        defaults.set(QuickTutorialStatus.completed.rawValue, forKey: key(task, "status"))
        defaults.set(WelcomeWindowController.onboardingVersion,
                     forKey: Preferences.Keys.onboardingWelcomeSeenVersion)
        setStep(3, for: task)
        self.message = message
        Toast.show(message, icon: "checkmark.circle.fill")
    }

    private func setStep(_ step: Int, for task: QuickTutorial) {
        defaults.set(step, forKey: key(task, "step"))
        objectWillChange.send()
    }

    private func key(_ task: QuickTutorial, _ field: String) -> String {
        "onboarding.quickTutorial.\(task.rawValue).\(field)"
    }
}
