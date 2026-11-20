import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

final class ClipboardHistorySettingsDraft: SettingsEditableDraft {
    @Published var retentionDays = Double(Preferences.shared.value(Preferences.Keys.clipboardRetentionDays, default: 30))
    @Published var storageLimitMB = Double(Preferences.shared.value(Preferences.Keys.clipboardStorageLimitMB, default: 2048))
    private var saved: [Double] = []
    init() { saved = values }
    private var values: [Double] { [retentionDays, storageLimitMB] }
    var isDirty: Bool { values != saved }
    func save() -> String? {
        if retentionDays != saved[0] { Preferences.shared.set(Preferences.Keys.clipboardRetentionDays, Int(retentionDays)) }
        if storageLimitMB != saved[1] { Preferences.shared.set(Preferences.Keys.clipboardStorageLimitMB, Int(storageLimitMB)) }
        guard UserDefaults.standard.synchronize() else { return "剪贴板历史设置写入磁盘失败，调整已保留" }
        saved = values
        objectWillChange.send()
        return nil
    }
    func discard() {
        retentionDays = Double(Preferences.shared.value(Preferences.Keys.clipboardRetentionDays, default: 30))
        storageLimitMB = Double(Preferences.shared.value(Preferences.Keys.clipboardStorageLimitMB, default: 2048))
        saved = values
    }
    func restoreDefaults() { retentionDays = 30; storageLimitMB = 2048 }
}

final class ClipboardCaptureSettingsDraft: SettingsEditableDraft {
    struct Values: Equatable {
        var autoPaste = false
        var ignoredApps: [String] = []
        var automaticImageOCR = true
        static var current: Self {
            Self(autoPaste: Preferences.shared.value(Preferences.Keys.clipboardAutoPaste, default: false),
                 ignoredApps: Preferences.shared.value(Preferences.Keys.clipboardIgnoredApps, default: []),
                 automaticImageOCR: Preferences.shared.value("automaticScreenshotOCREnabled", default: true))
        }
    }
    @Published var values = Values.current
    private var saved = Values.current
    var isDirty: Bool { values != saved }
    func save() -> String? {
        if values.autoPaste != saved.autoPaste { Preferences.shared.set(Preferences.Keys.clipboardAutoPaste, values.autoPaste) }
        if values.ignoredApps != saved.ignoredApps { Preferences.shared.set(Preferences.Keys.clipboardIgnoredApps, values.ignoredApps) }
        if values.automaticImageOCR != saved.automaticImageOCR { Preferences.shared.set("automaticScreenshotOCREnabled", values.automaticImageOCR) }
        guard UserDefaults.standard.synchronize() else { return "剪贴板捕获设置写入磁盘失败，调整已保留" }
        saved = values
        objectWillChange.send()
        return nil
    }
    func discard() { values = .current; saved = values }
    func restoreDefaults() { values = Values() }
}

// MARK: - 剪贴板设置页（07 号设置模块通过 SettingsPaneRegistry 消费）
//
// 2026-10-20 统一版式：原实现用 `Form(.grouped)`，在 macOS 上会自绘**整页纯白底**
// + 灰色分组框，与其它设置页「灰底页面 + 浅色圆角卡片」不一致（用户反复反馈）。
// 现改用 SettingsSection / SettingsGroupBox / SettingsRow 这套共用组件，
// 与「常规」「数据」「监测设置」完全同构；外层滚动与 34/18 内边距由 SettingsRootView 提供。

public struct ClipboardSettingsPane: View {

    /// v272：剪贴板拆成三个二级页（历史 / 捕获 / 浮动窗），侧边栏一项对一页。
    /// 「标签管理」「忽略应用」这两行原先重复摆在「常规 → 剪贴板」段，已并回这里并删掉重复。
    public enum Section: Hashable { case history, capture, floating, appearance }
    var section: Section = .history

    /// 标签管理 sheet 呈现
    @Stored private var isManagingTags = false
    /// 标签总管（复用现有 TagStore，不新建计数链路）
    @ObservedObject private var tagStore = TagStore.shared
    @ObservedObject private var floatingStore = FloatingClipboardWindowController.shared.store
    /// v115：当前占用（进页时取一次；「立即清理」后刷新——此前是 body 裸计算值，
    /// 无状态变化不重渲染，清理后占用显示不变，加重"没生效"错觉）
    @Stored private var usageBytes: Int64 = 0
    @Stored private var clearingHistory = false
    @Stored private var backupRequest: ClipboardBackupRequest?

    /// v200：当前生效的悬浮剪贴板呼出方式（组合键或双击修饰键），显示在「浮动窗」区。
    private var floatingShortcutSummary: String {
        if let m = AppBootstrap.doubleTapModifier(for: "floatingClipboard") {
            return "双击 \(m.symbol)（可在快捷键页修改）"
        }
        if let b = AppBootstrap.shortcutBinding(for: "floatingClipboard") {
            return "\(ShortcutManager.display(keyCode: b.keyCode, modifiers: b.modifiers))（可在快捷键页修改）"
        }
        return "未设置（可在快捷键页配置）"
    }
    /// 权限状态（v111：自动粘贴行的「去授权」入口按授权态显隐）
    @ObservedObject private var permissions = PermissionCenter.shared

    private let preferences = Preferences.shared

    public init(section: Section = .history) {
        self.section = section
    }

    public var body: some View {
        VStack(spacing: 20) {
            switch section {
            case .history:  historySection
            case .capture:  captureSection
            case .floating: floatingSection
            case .appearance:
                AppearanceSettingsEditor(scope: .clipboardAppearance) { draft in
                    SettingsGroupBox {
                        HStack(alignment: .top, spacing: 14) {
                            AppearancePreviewBlock(scope: .clipboardList, draft: draft)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 0.5)
                                .padding(.vertical, 4)
                            PersonalizationSettingsView(part: .clipboardAppearance,
                                                        draft: draft, compact: true)
                                .frame(width: 270, alignment: .topLeading)
                        }
                    }
                }
            }
        }
        .font(.system(size: 13))
        .sheet(isPresented: $isManagingTags) { TagManagementSheet() }
        .sheet(item: $backupRequest) { request in
            ClipboardBackupSheet(request: request) {
                backupRequest = nil
                usageBytes = ClipboardStorageUsageProvider.shared.totalBytes
            }
        }
        .onAppear {
            if section == .history {
                usageBytes = ClipboardStorageUsageProvider.shared.totalBytes
            }
        }
    }

    // MARK: - 历史

    private var historySection: some View {
        SettingsDraftEditor(id: "clipboardHistory", makeDraft: { ClipboardHistorySettingsDraft() }) { draft in
        SettingsSection("历史") {
            SettingsGroupBox {
                sliderRow("保留天数",
                          valueText: "\(Int(draft.retentionDays)) 天",
                          value: Binding(get: { draft.retentionDays }, set: { draft.retentionDays = $0 }),
                          range: 1...365,
                          step: 1)
                SettingsDivider()
                sliderRow("容量上限",
                          valueText: "\(Int(draft.storageLimitMB)) MB",
                          value: Binding(get: { draft.storageLimitMB }, set: { draft.storageLimitMB = $0 }),
                          range: 256...8192,
                          step: 256)
                SettingsDivider()
                // v115：占用改为状态存储——此前是 body 里的裸计算值，点「立即清理」
                // 后无状态变化不重渲染，占用显示永远停在进页时刻（加重"没生效"错觉）
                SettingsRow(title: "当前占用") {
                    Text(Self.bytesText(usageBytes))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                SettingsDivider()
                SettingsRow(title: "清理历史",
                            subtitle: "即时操作，按已保存的保留天数与容量上限删除超限条目") {
                    Button("立即清理") {
                        let savedDays = preferences.value(Preferences.Keys.clipboardRetentionDays, default: 30)
                        let savedLimit = preferences.value(Preferences.Keys.clipboardStorageLimitMB, default: 2048)
                        // v115：无论删没删都给反馈——此前删 0 条时零提示，用户误判按钮失效
                        // v210：清理移到后台队列（批量删除 + 目录遍历不占主线程），
                        // 两个调度器结果都回来后再统一提示一次。
                        let group = DispatchGroup()
                        var r1 = ClipboardPruneResult.none
                        var r2 = ClipboardPruneResult.none
                        group.enter()
                        ClipboardHistoryRetentionPruneScheduler.shared.pruneAsync { r in
                            r1 = r; group.leave()
                        }
                        group.enter()
                        ClipboardStoragePruneScheduler.shared.pruneAsync { r in
                            r2 = r; group.leave()
                        }
                        group.notify(queue: .main) {
                            let removed = r1.removed + r2.removed
                            usageBytes = ClipboardStorageUsageProvider.shared.totalBytes
                            if removed > 0 {
                                let reclaimed = Self.bytesText(r1.reclaimedBytes + r2.reclaimedBytes)
                                Toast.show("已清理 \(removed) 条，回收 \(reclaimed)", icon: "trash")
                            } else {
                                Toast.show("没有超过已保存保留期（\(savedDays) 天）或容量上限（\(savedLimit) MB）的条目",
                                           icon: "checkmark.circle")
                            }
                        }
                    }
                    .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(title: "清除历史，保留已存项目", subtitle: "删除全部未收藏历史；保留收藏项目、标签、文件中转及原文件。即时操作。") {
                    Button(clearingHistory ? "正在清理…" : "清除历史…") {
                        clearingHistory = true
                        ClipboardManager.shared.clearUnsavedHistory {
                            clearingHistory = false
                            usageBytes = ClipboardStorageUsageProvider.shared.totalBytes
                        }
                    }
                    .controlSize(.small)
                    .disabled(clearingHistory)
                }
                SettingsDivider()
                SettingsRow(title: "密码加密备份", subtitle: "备份剪贴板、收藏项目、标签与完整附件；外部文件仅保存路径。密码不保存。") {
                    HStack(spacing: 8) {
                        Button("加密备份…") {
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = "Kitnest-剪贴板.7z"
                            panel.allowedContentTypes = [UTType(filenameExtension: "7z")!]
                            if panel.runModal() == .OK, let url = panel.url {
                                backupRequest = ClipboardBackupRequest(url: url, importing: false)
                            }
                        }
                        Button("恢复备份…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [UTType(filenameExtension: "7z")!]
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                backupRequest = ClipboardBackupRequest(url: url, importing: true)
                            }
                        }
                    }.controlSize(.small)
                }
                SettingsDivider()
                // v272：从「常规 → 剪贴板」并回来的标签管理（原处已删，避免两处入口）
                SettingsRow(title: "标签管理",
                            subtitle: "给条目打标签，主面板筛选栏按标签过滤") {
                    HStack(spacing: 12) {
                        Button("编辑") { isManagingTags = true }
                            .controlSize(.small)
                        Text(Self.tagCountText(tagStore.tags.count))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        }
    }

    // MARK: - 捕获

    private var captureSection: some View {
        SettingsDraftEditor(id: "clipboardCapture", makeDraft: { ClipboardCaptureSettingsDraft() }) { draft in
        SettingsSection("捕获") {
            SettingsGroupBox {
                Text("捕获为自适应轮询：闲置 1 秒，检测到新内容后 0.5 秒突发（持续 2 秒）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                SettingsDivider()
                SettingsRow(title: "复制后自动粘贴到前台应用",
                            subtitle: "需要「辅助功能」权限，默认关闭。") {
                    HStack(spacing: 8) {
                        // v111：权限引导窗统一入口（授权状态实时观察）
                        if !permissions.status(.accessibility).isGranted {
                            Button("去授权") { PermissionGuideWindowController.shared.show() }
                                .controlSize(.small)
                                .buttonStyle(.borderless)
                        }
                        Toggle("", isOn: Binding(get: { draft.values.autoPaste }, set: { draft.values.autoPaste = $0 }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
                SettingsDivider()
                // v272：从「常规 → 剪贴板」并回来的隐私名单（原处已删）
                SettingsRow(title: "忽略应用（隐私名单）",
                            subtitle: "这些应用里复制的内容不会进历史") {
                    IgnoredAppsEditor(apps: Binding(get: { draft.values.ignoredApps }, set: { draft.values.ignoredApps = $0 }))
                }
                SettingsDivider()
                SettingsRow(title: "自动图片文字识别", subtitle: "新捕获的图片自动提取文字，保存后生效") {
                    Toggle("", isOn: Binding(get: { draft.values.automaticImageOCR }, set: { draft.values.automaticImageOCR = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
        }
    }

    // MARK: - 浮动窗

    private var floatingSection: some View {
        AppearanceSettingsEditor(scope: .floatingClipboard) { draft in
            SettingsSection("浮动窗") {
                SettingsGroupBox {
                    AppearancePreviewBlock(scope: .clipboard, draft: draft)
                    SettingsDivider()
                    SettingsRow(title: "布局") {
                        Picker("", selection: Binding(
                            get: { draft.floating.layout },
                            set: { draft.floating.layout = $0 })) {
                            ForEach(FloatingClipLayout.allCases, id: \.self) { layout in
                                Text(layout.label).tag(layout)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    SettingsDivider()
                    SettingsRow(title: "卡片档位") {
                        Picker("", selection: Binding(
                            get: { draft.floating.cardSize },
                            set: { draft.floating.cardSize = $0 })) {
                            ForEach(FloatingClipCardSize.allCases, id: \.self) { size in
                                Text(size.label).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    SettingsDivider()
                    SettingsRow(title: "两栏比例", subtitle: "卡片区占比；也可拖动预览中间的分隔条") {
                        HStack(spacing: 8) {
                            Slider(value: Binding(get: { Double(draft.floating.splitRatio) },
                                set: { draft.floating.splitRatio = CGFloat($0) }), in: 0.22...0.78)
                                .frame(width: 180)
                            Text("\(Int(draft.floating.splitRatio * 100))%")
                                .monospacedDigit().frame(width: 38)
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: "悬停预览", subtitle: "关闭后仍可单击记录查看详情") {
                        Toggle("鼠标移到记录时更新详情", isOn: Binding(
                            get: { draft.floating.hoverPreviewEnabled },
                            set: { draft.floating.hoverPreviewEnabled = $0 }))
                            .toggleStyle(.checkbox)
                    }
                    SettingsDivider()
                    SettingsRow(title: "立即显示浮动窗", subtitle: "即时操作，不随外观设置保存") {
                        Toggle("", isOn: Binding(
                            get: { floatingStore.isVisible },
                            set: { visible in
                                if visible { FloatingClipboardWindowController.shared.show() }
                                else { FloatingClipboardWindowController.shared.hide() }
                            }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(title: "呼出快捷键", subtitle: floatingShortcutSummary) {
                        Button("前往快捷键") {
                            ServiceLocator.settings?.open(pane: "shortcuts#floatingClipboard")
                        }
                        .controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(title: "浮动窗位置", subtitle: draft.floatingFrame == nil ? "重置为当前屏幕中央，保存后生效" : "已准备居中位置，保存后生效") {
                        Button("重置位置") {
                            let state = FloatingClipboardPinState.shared
                            guard let visible = NSScreen.main?.visibleFrame else { return }
                            var frame = state.clampedFrame()
                            frame.origin = NSPoint(x: visible.midX - frame.width / 2,
                                                   y: visible.midY - frame.height / 2)
                            draft.floatingFrame = frame
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - 行组件

    /// 滑块行：标题 + 右侧数值，下方通栏滑块（与卡片内其它行同一节奏）
    private func sliderRow(_ title: String,
                           valueText: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
            .controlSize(.small)
        }
        .padding(.vertical, 9)
    }

    /// 标签计数（与旧「常规」页同一口径）
    private static func tagCountText(_ count: Int) -> String {
        String(format: L10n.t(count == 1 ? "%d Tag" : "%d Tags"), count)
    }

    private static func bytesText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}

private struct ClipboardBackupRequest: Identifiable {
    let id = UUID()
    let url: URL
    let importing: Bool
}

/// 手动操作期间存在的设置页 sheet；密码与明文资料不进入偏好。
private struct ClipboardBackupSheet: View {
    let request: ClipboardBackupRequest
    let close: () -> Void
    @Stored private var password = ""
    @Stored private var confirmation = ""
    @Stored private var busy = false
    @Stored private var message: String?
    @Stored private var session: ClipboardBackup.RestoreSession?
    @Stored private var operation: ClipboardBackup.Operation?
    @Stored private var replace = false
    @Stored private var useBackupConflicts = false
    @Stored private var missingRecords: [ClipboardBackup.MissingRecord]?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.importing ? "恢复剪贴板备份" : "加密备份剪贴板")
                .font(.system(size: 17, weight: .semibold))
            Text(request.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            if let session {
                ScrollView {
                    Text(session.summary).font(.system(size: 13)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 220)
                Picker("恢复方式", selection: $replace) {
                    Text("合并到本机").tag(false)
                    Text("替换剪贴板资料").tag(true)
                }.pickerStyle(.segmented)
                if replace {
                    Text("替换全部剪贴板历史、收藏项目和标签，保留 AI 对话及其他模块资料。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Picker("冲突记录（含本机缺失附件）", selection: $useBackupConflicts) {
                        Text("保留本机").tag(false)
                        Text("使用备份").tag(true)
                    }
                }
            } else {
                if let missingRecords, !missingRecords.isEmpty {
                    Text("\(missingRecords.count) 条记录缺少附件。仅备份完整记录时，这些记录继续保留在本机；加密包包含跳过清单。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(missingRecords) { record in
                                Text(record.title + "\n" + record.paths.joined(separator: "\n"))
                                    .font(.system(size: 12)).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 180)
                }
                SecureField("密码", text: $password)
                if !request.importing { SecureField("再次输入密码", text: $confirmation) }
                Text(request.importing ? "先解密并展示资料数量，确认后才恢复。" : "7z 同时加密正文、附件和文件名。请自行保管密码。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let message { Text(message).foregroundStyle(.red).font(.system(size: 12)).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small); Text("正在处理…").foregroundStyle(.secondary) }
                Spacer()
                Button("取消") { operation?.cancel(); if !busy { session?.cleanup() }; password = ""; close() }
                    .keyboardShortcut(.cancelAction)
                Button(session == nil ? (request.importing ? "读取备份" : (missingRecords?.isEmpty == false ? "仅备份完整记录" : "加密备份")) : "确认恢复") { execute() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (!request.importing && missingRecords == nil) || (session == nil && (password.isEmpty || (!request.importing && password != confirmation))))
            }
        }
        .padding(24)
        .frame(width: 430)
        .frsetThemeChrome()
        .onAppear { if !request.importing { reviewExport() } }
        .onDisappear { operation?.cancel(); if !busy { session?.cleanup() }; password = ""; confirmation = "" }
    }

    private func execute() {
        busy = true
        message = nil
        if let session {
            operation = ClipboardManager.shared.restoreBackup(session, replace: replace, useBackupConflicts: useBackupConflicts, completion: finish)
        } else if request.importing {
            operation = ClipboardManager.shared.prepareBackupRestore(from: request.url, password: password) { result in
                busy = false
                operation = nil
                switch result {
                case .success(let prepared): session = prepared; password = ""
                case .failure(let error): message = error.localizedDescription
                }
            }
        } else {
            operation = ClipboardManager.shared.exportBackup(to: request.url, password: password, skipping: missingRecords ?? [], completion: finish)
        }
    }

    private func reviewExport() {
        busy = true
        operation = ClipboardManager.shared.reviewBackupExport { result in
            busy = false
            operation = nil
            switch result {
            case .success(let records): missingRecords = records
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        busy = false
        operation = nil
        switch result {
        case .success(let text):
            session?.cleanup()
            password = ""; confirmation = ""
            Toast.show(text, icon: "checkmark.circle")
            close()
        case .failure(let error):
            session = nil
            password = ""; confirmation = ""
            message = error.localizedDescription
            if !request.importing { reviewExport() }
        }
    }
}
