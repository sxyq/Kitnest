import AppKit
import SwiftUI

// MARK: - 创建压缩包面板（v124；ArcZip「压缩用途预设」5 种 + 强度 6 档 + 密码 + 分卷）
//
// 入口：面板「压缩…」按钮 / frsetnext://archive?action=compress&path=…
// 预设决定推荐格式与强度，用户仍可手动改格式/强度——预设是建议不是枷锁。

public final class ArchiveCreateModel: ObservableObject {

    @Published public var presetIndex = 0
    @Published public var format = "zip"
    @Published public var level = 5
    @Published public var usePassword = false
    @Published public var password = ""
    @Published public var showPassword = false
    @Published public var volumeEnabled = false
    @Published public var volumeMB = 200
    @Published public var outputName = ""
    @Published public var busy = false
    @Published public var errorText: String?
    /// v127（ArcZip P2）：包内名是否用 Windows 安全名（弹窗「用建议名继续」时置 true）
    @Published public var useWindowsSafeNames = false

    /// v127：Windows 文件名弹窗只弹一次（用户已选择）
    private var nameCheckConfirmed = false
    /// v127：进行中任务的 taskID（取消传播用）
    private var currentTaskID: UUID?

    public let files: [URL]
    /// 输出目录（默认取第一个文件所在目录）
    public let outputDir: URL

    /// 强度 6 档（ArcZip：store / fastest / fast / normal / maximum / ultra）
    public static let levels: [(String, Int)] = [
        ("仅打包不压缩", 0), ("最快", 1), ("快速", 3),
        ("标准", 5), ("最大", 7), ("极限", 9),
    ]

    public init(files: [URL]) {
        self.files = files
        self.outputDir = files.first?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        let stem = files.count == 1
            ? (files[0].deletingPathExtension().lastPathComponent)
            : (files.first?.deletingLastPathComponent().lastPathComponent ?? "归档")
        self.outputName = stem
        applyPreset(0)
    }

    /// 套用预设：格式 + 强度（用户之后手改不回滚）
    public func applyPreset(_ index: Int) {
        presetIndex = index
        guard ArchiveCore.presets.indices.contains(index) else { return }
        let p = ArchiveCore.presets[index]
        format = p.format
        level = p.level
        syncOutputExtension()
    }

    /// 格式变了就跟着改扩展名，避免「名字.zip 内容是 7z」
    public func syncOutputExtension() {
        let base = (outputName as NSString).deletingPathExtension
        let ext = format == "tar.gz" ? "tar.gz" : format
        outputName = base + "." + ext
        // v164：tar.gz 走「tar → gzip」两趟，gzip 是单流、没有分卷；切到该格式就顺手关掉分卷，
        // 免得点了「创建」才被核心层拒绝
        if !supportsVolumes { volumeEnabled = false }
    }

    /// 分卷能力：tar.gz 没有分卷（7zz 的 -v 只会切 tar，产出 .tar.001 且没有 gz 那一趟）
    public var supportsVolumes: Bool { format != "tar.gz" }

    public var outputURL: URL {
        outputDir.appendingPathComponent(outputName)
    }

    /// ZIP 的密码只支持 ASCII（ArcZip「中文密码支持」：引导改用 7z）
    public var passwordWarning: String? {
        guard usePassword, !password.isEmpty else { return nil }
        if format != "7z" && password.unicodeScalars.contains(where: { $0.value > 127 }) {
            return "ZIP 密码仅支持 ASCII；中文密码请把格式改为 7z"
        }
        return nil
    }

    /// v127（ArcZip P2）：Windows 文件名问题摘要（面板黄条 + 弹窗列表）
    public var windowsNameIssues: [(name: String, reason: String, suggested: String)] {
        ArchiveCore.windowsNameIssues(files.map { $0.lastPathComponent })
    }

    public var windowsNameWarning: String? {
        let issues = windowsNameIssues
        guard !issues.isEmpty else { return nil }
        return "\(issues.count) 个文件名在 Windows 上可能打不开："
            + issues.map { $0.name }.joined(separator: "、")
    }

    /// v127：取消进行中的压缩（进度面板 / 关窗时调，走任务队列的取消传播）
    public func cancelCreate() {
        if let id = currentTaskID {
            ArchiveTaskQueue.shared.cancel(taskID: id)
        }
    }

    public func create(completion: @escaping (Bool, String) -> Void) {
        guard !files.isEmpty else { errorText = "没有选中文件"; return }
        guard !outputName.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorText = "请填写文件名"; return
        }
        if usePassword {
            guard !password.isEmpty else { errorText = "请填写密码，或关闭密码保护"; return }
        }
        // v127（ArcZip P2）：Windows 文件名修正——有问题就弹窗列出，
        // 「用建议名继续 / 保持原名」二选一只改包内名，磁盘原名不动
        if !nameCheckConfirmed {
            let issues = windowsNameIssues
            if !issues.isEmpty {
                let alert = NSAlert()
                alert.messageText = "以下文件名在 Windows 上可能打不开"
                alert.informativeText =
                    issues.map { "· \($0.name)\n   \($0.reason)\n   建议改为：\($0.suggested)" }
                        .joined(separator: "\n")
                    + "\n\n「用建议名继续」只改归档内名字，磁盘上的原文件名不动。"
                alert.addButton(withTitle: "用建议名继续")
                alert.addButton(withTitle: "保持原名")
                NSApp.activate(ignoringOtherApps: true)
                useWindowsSafeNames = (alert.runModal() == .alertFirstButtonReturn)
                nameCheckConfirmed = true
            }
        }
        busy = true
        errorText = nil
        currentTaskID = ArchiveCore.create(
            files: files, to: outputURL, level: level,
            password: usePassword ? password : nil,
            volumeMB: volumeEnabled ? volumeMB : 0,
            useWindowsSafeNames: useWindowsSafeNames) { [weak self] ok, msg in
            guard let self else { return }
            self.busy = false
            self.currentTaskID = nil
            if ok { completion(true, msg) }
            else { self.errorText = msg; completion(false, msg) }
        }
    }
}

// MARK: 视图

public struct ArchiveCreateView: View {

    @ObservedObject public var model: ArchiveCreateModel
    /// 创建成功后回调（关闭窗口/刷新）
    public var onDone: (Bool, String) -> Void

    public init(model: ArchiveCreateModel, onDone: @escaping (Bool, String) -> Void) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            presetPicker
            Divider()
            options
            if let warn = model.windowsNameWarning {
                Label(warn, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if let warn = model.passwordWarning {
                Label(warn, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if let err = model.errorText {
                Label(err, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            Divider()
            footer
            // v127（ArcZip P2）：压缩时显示进度与任务面板（ArcZip「进度与任务」）
            if model.busy {
                ArchiveProgressPanel(compact: true)
            }
        }
        .padding(14)
        .frame(width: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("创建压缩包")
                .font(.system(size: 13, weight: .semibold))
            Text("将 \(model.files.count) 个项目压缩为一个归档")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 用途预设

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("用途预设")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(Array(ArchiveCore.presets.enumerated()), id: \.element.id) { idx, preset in
                Button {
                    model.applyPreset(idx)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.presetIndex == idx
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.presetIndex == idx ? Theme.accent : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.title)
                                .font(.system(size: 11, weight: .medium))
                            Text(preset.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(preset.format.uppercased())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: 选项

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("文件名").frame(width: 56, alignment: .leading)
                TextField("", text: $model.outputName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
            HStack {
                Text("格式").frame(width: 56, alignment: .leading)
                Picker("", selection: $model.format) {
                    Text("ZIP").tag("zip")
                    Text("7z").tag("7z")
                    Text("TAR.GZ").tag("tar.gz")
                }
                .labelsHidden()
                .frame(width: 110)
                .onChange(of: model.format) { _ in model.syncOutputExtension() }

                Text("强度").frame(width: 36, alignment: .leading)
                Picker("", selection: $model.level) {
                    ForEach(ArchiveCreateModel.levels, id: \.1) { name, val in
                        Text(name).tag(val)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            HStack {
                Toggle("密码保护", isOn: $model.usePassword)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                if model.usePassword {
                    HStack(spacing: 4) {
                        if model.showPassword {
                            TextField("密码", text: $model.password)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        } else {
                            SecureField("密码", text: $model.password)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                        Button {
                            model.showPassword.toggle()
                        } label: {
                            Image(systemName: model.showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(model.showPassword ? "隐藏密码" : "显示密码（方便中文输入法）")
                    }
                    .frame(width: 190)
                }
                Spacer()
            }
            HStack {
                Toggle("分卷压缩", isOn: $model.volumeEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(!model.supportsVolumes)
                    .help(model.supportsVolumes
                          ? "按设定大小切成多卷（.001/.002…）"
                          : "TAR.GZ 不支持分卷：gzip 是单流格式")
                if !model.supportsVolumes {
                    Text("TAR.GZ 不支持分卷")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                } else if model.volumeEnabled {
                    TextField("", value: $model.volumeMB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .font(.system(size: 11))
                    Text("MB / 卷")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(model.outputURL.lastPathComponent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button("取消") {
                // v127：压缩进行中关掉 = 取消任务（取消传播会 terminate 7zz）
                model.cancelCreate()
                onDone(false, "已取消")
            }
            .keyboardShortcut(.cancelAction)
            Button("开始压缩") { model.create(completion: onDone) }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: 窗口

public final class ArchiveCreateWindowController: NSWindowController, NSWindowDelegate {

    private static var open: [String: ArchiveCreateWindowController] = [:]

    /// 为若干文件打开创建面板（同一组文件只开一个）
    public static func show(files: [URL]) {
        guard !files.isEmpty else { return }
        let key = files.map { $0.standardizedFileURL.path }.sorted().joined(separator: "|")
        if let existing = open[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = ArchiveCreateWindowController(files: files, key: key)
        open[key] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let model: ArchiveCreateModel
    private let key: String

    init(files: [URL], key: String) {
        self.model = ArchiveCreateModel(files: files)
        self.key = key
        let hosting: NSHostingController<ArchiveCreateView>
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "创建压缩包"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        let view = ArchiveCreateView(model: model) { [weak self] ok, msg in
            if ok {
                Toast.show(msg, icon: "archivebox")
                self?.close()
            } else if msg != "已取消" {
                // 错误已内联显示，这里不重复弹
            } else {
                self?.close()
            }
        }
        hosting = NSHostingController(rootView: view)
        win.contentViewController = hosting
        win.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// v127（ArcZip P2）：压缩进行中关窗先确认，确认则取消任务（退出等待保护的窗口侧）
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.busy else { return true }
        let alert = NSAlert()
        alert.messageText = "压缩仍在进行"
        alert.informativeText = "关闭窗口将取消当前压缩任务（7zz 子进程会被终止）。"
        alert.addButton(withTitle: "取消任务并关闭")
        alert.addButton(withTitle: "继续压缩")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.cancelCreate()
            return true
        }
        return false
    }

    public func windowWillClose(_ notification: Notification) {
        Self.open.removeValue(forKey: key)
    }
}
