import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 2026-11-12：只在用户切换开关时修改 ZIP 关联，启动与安装不重设。
final class ArchiveDefaultApplication: ObservableObject {
    static let shared = ArchiveDefaultApplication()
    @Published private(set) var enabled = false
    @Published private(set) var changing = false
    @Published private(set) var applicationName = ""
    /// 文案用：去掉 .app 后缀，读起来像应用名而不是路径
    var applicationDisplayName: String {
        applicationName.hasSuffix(".app") ? String(applicationName.dropLast(4)) : applicationName
    }
    @Published private(set) var errorMessage: String?

    func refresh() {
        let application = NSWorkspace.shared.urlForApplication(toOpen: .zip)
        enabled = application.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
        applicationName = application.map { FileManager.default.displayName(atPath: $0.path) } ?? "尚未设置"
    }

    func setEnabled(_ value: Bool) {
        refresh()
        guard value != enabled else { return }
        errorMessage = nil
        let defaults = UserDefaults.standard
        let key = Preferences.Keys.archivePreviousZIPApplication
        let target: URL
        if value {
            if let current = NSWorkspace.shared.urlForApplication(toOpen: .zip),
               let identifier = Bundle(url: current)?.bundleIdentifier {
                defaults.set(identifier, forKey: key)
            }
            target = Bundle.main.bundleURL
        } else {
            // 已手动关联 Kitnest 的用户没有历史记录，关闭时交回系统归档工具。
            let identifier = defaults.string(forKey: key) ?? "com.apple.archiveutility"
            guard let previous = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                errorMessage = "原来的 ZIP 应用已不在这台 Mac 上。请在访达的「显示简介 → 打开方式」中重新选择。"
                return
            }
            target = previous
        }
        changing = true
        NSWorkspace.shared.setDefaultApplication(at: target, toOpen: .zip) { error in
            DispatchQueue.main.async {
                self.changing = false
                self.refresh()
                if let error {
                    self.errorMessage = "未能更改 ZIP 默认应用：\(error.localizedDescription)"
                } else if self.enabled != value {
                    self.errorMessage = "ZIP 默认应用仍为\(self.applicationName)，请完成系统的更改确认。"
                } else {
                    if !value { defaults.removeObject(forKey: key) }
                    Toast.show(value ? "ZIP 将用 Kitnest Lite 打开" : "已恢复 ZIP 打开方式", icon: "archivebox")
                }
            }
        }
    }
}

/// 教程与设置复用同一开关，显示系统关联而非本地布尔值。
// MARK: - v273（ArcZip 1.2.5 对齐）：打开行为 / 悬浮预览 / 进度窗设置

/// 「打开压缩包」：双击压缩包时直接解压到所在文件夹（ArcZip 1.2.5
/// `extraction.opening` 同款能力）。DMG/ISO 始终浏览；按住 Shift 临时浏览。
struct ArchiveOpenBehaviorOptions: View {
    @AppStorage(Preferences.Keys.archiveOpenDirectExtract) private var directExtract = false
    @AppStorage(Preferences.Keys.archiveOpenTrashOriginal) private var trashOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(title: "双击时快速解压",
                        subtitle: "双击直接解压到当前文件夹，按住 Shift 可浏览。") {
                Toggle("双击时快速解压", isOn: $directExtract)
                    .labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "原包处理",
                        subtitle: "解压后原包保留或移入废纸篓。") {
                Picker("原包处理", selection: $trashOriginal) {
                    Text("保留原包").tag(false)
                    Text("移到废纸篓").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                .disabled(!directExtract)
            }
            Text("DMG、ISO 始终浏览")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// 「悬浮预览」：列表悬停弹出条目预览的总开关与解压大小上限
/// （ArcZip 1.2.5 `settings.browsing.hover.video.limit` 同款口径：按解压后大小计算，包含上限）。
struct ArchiveHoverPreviewOptions: View {
    @AppStorage(Preferences.Keys.archiveHoverEnabled) private var hoverEnabled = true
    @AppStorage(Preferences.Keys.archiveHoverSizeLimitMB) private var sizeLimitMB = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(title: "开启悬浮预览",
                        subtitle: "悬停约 1 秒弹出条目预览。") {
                Toggle("开启悬浮预览", isOn: $hoverEnabled)
                    .labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "可预览大小上限",
                        subtitle: "按解压后的大小计算。") {
                Picker("可预览大小上限", selection: $sizeLimitMB) {
                    Text("10 MB").tag(10)
                    Text("50 MB").tag(50)
                    Text("100 MB").tag(100)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                    Text("2 GB").tag(2000)
                }
                .labelsHidden().frame(width: 130)
                .disabled(!hoverEnabled)
            }
        }
    }
}

/// 「进度窗口」：任务队列浮窗保持置顶（ArcZip 1.2.5 `settings.progress.keep_on_top`）。
struct ArchiveProgressWindowOptions: View {
    @AppStorage(Preferences.Keys.archiveProgressKeepOnTop) private var keepOnTop = false

    var body: some View {
        SettingsRow(title: "保持置顶",
                    subtitle: "浮窗始终在最前。") {
            Toggle("保持置顶", isOn: $keepOnTop)
                .labelsHidden().toggleStyle(.switch)
        }
    }
}

/// v273：双击直接解压（`archive.open.directExtract`）。
/// 冲突保护：目标位置已有同名文件时不解压，回退到浏览窗口并提示——
/// 无确认的覆盖比多开一个窗口更危险。无法列举（加密/损坏）同样回退浏览。
enum ArchiveQuickExtract {

    /// 镜像格式始终浏览（ArcZip 1.2.5 extraction.opening.browse_formats 同款规则）。
    static func isDirectEligible(_ url: URL) -> Bool {
        !["dmg", "iso"].contains(url.pathExtension.lowercased())
    }

    static func run(url: URL, trashOriginal: Bool) {
        let dir = url.deletingLastPathComponent()
        ArchiveCore.list(url: url) { entries, error in
            if let error {
                Log.warn("Archive", "快速解压：列举失败（\(error)），回退浏览")
                ArchiveBrowserWindowController.show(url: url)
                return
            }
            let fm = FileManager.default
            let conflicts = entries.contains { entry in
                !entry.isDirectory && fm.fileExists(atPath: dir.appendingPathComponent(entry.path).path)
            }
            if conflicts {
                Toast.show("\(url.lastPathComponent) 中存在同名文件，已改为浏览",
                           icon: "exclamationmark.triangle", isWarning: true)
                ArchiveBrowserWindowController.show(url: url)
                return
            }
            Log.info("Archive", "快速解压：\(url.lastPathComponent) → \(dir.path)（原包\(trashOriginal ? "移入废纸篓" : "保留")）")
            _ = ArchiveCore.extract(url: url, to: dir) { ok, message in
                if ok {
                    Toast.show("已解压 \(url.lastPathComponent)", icon: "archivebox")
                    if trashOriginal { NSWorkspace.shared.recycle([url]) }
                } else {
                    Toast.show("解压失败：\(message)", icon: "exclamationmark.triangle", isWarning: true)
                }
            }
        }
    }
}

struct ArchiveDefaultApplicationOption: View {
    @ObservedObject private var association = ArchiveDefaultApplication.shared
    @AppStorage(ArchiveCreationPreferences.passwordEnabled) private var passwordEnabled = false
    @AppStorage(ArchiveCreationPreferences.encryptFileNames) private var encryptFileNames = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Label("ZIP 关联", systemImage: "archivebox")
                    .font(.system(size: 12, weight: .medium))
                Toggle("ZIP 使用 Kitnest Lite 打开", isOn: Binding(
                    get: { association.enabled }, set: { association.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .disabled(association.changing)
                Text(association.changing ? "正在更改…" : "当前打开方式：\(association.applicationDisplayName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("关闭后回到原来的应用。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("定位 ZIP 应用") {
                        if let application = NSWorkspace.shared.urlForApplication(toOpen: .zip) {
                            NSWorkspace.shared.activateFileViewerSelecting([application])
                        }
                    }
                    Button("定位归档工具") {
                        if let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.archiveutility") {
                            NSWorkspace.shared.activateFileViewerSelecting([application])
                        }
                    }
                }
                .buttonStyle(.link)
                Text("其他格式：显示简介 → 打开方式 → 全部更改")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 5) {
                Label("Finder 服务", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
                Text("压缩：右键 → 服务 → 用 Kitnest Lite 压缩")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("解压：右键 → 服务 → 解压到此处 / 解压到…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("复制路径、终端打开：右键 → 服务，默认未启用")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开键盘设置") {
                    if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard")!) {
                        Toast.show("无法打开键盘设置", isWarning: true)
                    }
                }
                .buttonStyle(.link)
            }
            Divider()
            Text("新建压缩包默认值").font(.headline)
            Toggle("默认启用密码保护", isOn: $passwordEnabled)
                .toggleStyle(.checkbox)
            Toggle("7z 默认加密文件名", isOn: $encryptFileNames)
                .toggleStyle(.checkbox)
            Text("密码每次输入。ZIP 只加密内容，7z 还能隐藏文件名，TAR.GZ 不支持。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = association.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { association.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            association.refresh()
        }
    }
}

// MARK: - NSServices 访达集成就地部分（v127（ArcZip P3）：P3-4）
//
// 构建系统限制说明：本工程用 build.sh 直接 swiftc 编译 Sources/**，**没有 app extension
// target 与 provisioning**，因此 ArcZip 的 FinderSync 扩展（访达侧栏按钮/工具栏）
// 与 QuickLook 扩展（空格预览插件）**不可行**，明确不做。
// 就地集成改走 NSServices（Info.plist 声明 + 本文件实现）：在访达选中文件右键 → 服务：
//   · 解压到此处（批量，解到各文件所在目录）
//   · 解压到…（批量，NSOpenPanel 选目录）
//   · 压缩（交给既有创建压缩包面板 ArchiveCreateWindowController.show）
//
// 挂载点：AppDelegate.applicationDidFinishLaunching 里 `NSApp.servicesProvider = ...`。
// 服务 selector 名与 Info.plist 的 NSMessage 一一对应：
//   extractHere:userData:error: / extractTo:userData:error: / compress:userData:error:

public final class ArchiveServicesProvider: NSObject {

    // v127（ArcZip P3）：servicesProvider 需稳定实例（系统按 selector 回调）
    public static let shared = ArchiveServicesProvider()

    // MARK: 服务入口（签名与 NSServices 约定一致）

    /// 「解压到此处」：批量解压到每个压缩包所在目录（即访达当前目录）
    @objc public func extractHere(_ pboard: NSPasteboard, userData: String,
                                  error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let archives = Self.archives(from: pboard)
        guard !archives.isEmpty else {
            error.pointee = "选中的文件里没有可解压的压缩包" as NSString
            return
        }
        // v127（ArcZip P3）：批量解压文案——「将 N 个文件解压到当前目录」
        Toast.show("将 \(archives.count) 个文件解压到当前目录", icon: "archivebox")
        for url in archives {
            let dir = url.deletingLastPathComponent()
            ArchiveCore.extract(url: url, to: dir) { ok, msg in
                if !ok {
                    Toast.show("\(url.lastPathComponent) 解压失败：\(msg)",
                               icon: "exclamationmark.triangle", isWarning: true)
                }
            }
        }
    }

    /// 「解压到…」：选一个目录，把所有压缩包解进去
    @objc public func extractTo(_ pboard: NSPasteboard, userData: String,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let archives = Self.archives(from: pboard)
        guard !archives.isEmpty else {
            error.pointee = "选中的文件里没有可解压的压缩包" as NSString
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "解压到这里"
        guard panel.runModal() == .OK, let dir = panel.url else {
            error.pointee = "已取消" as NSString
            return
        }
        Toast.show("将 \(archives.count) 个文件解压到 \(dir.lastPathComponent)", icon: "archivebox")
        for url in archives {
            ArchiveCore.extract(url: url, to: dir) { ok, msg in
                if !ok {
                    Toast.show("\(url.lastPathComponent) 解压失败：\(msg)",
                               icon: "exclamationmark.triangle", isWarning: true)
                }
            }
        }
    }

    /// 「用 Kitnest 打开」（v167）：右键选中的压缩包 → 直达归档浏览窗
    ///
    /// 与「双击压缩包」「拖进面板」走同一个入口 `ArchiveBrowserWindowController.show`，
    /// 不另开一套窗口。多选时逐个打开（同包已开则系统侧前置，由 controller 去重）。
    @objc public func openArchive(_ pboard: NSPasteboard, userData: String,
                                  error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let archives = Self.archives(from: pboard)
        guard !archives.isEmpty else {
            error.pointee = "选中的文件里没有可打开的压缩包" as NSString
            return
        }
        for url in archives {
            ArchiveBrowserWindowController.show(url: url)
        }
    }

    /// 「压缩」：把选中的文件交给既有创建压缩包面板（5 种用途预设 / 分卷 / 密码都在那边）
    @objc public func compress(_ pboard: NSPasteboard, userData: String,
                               error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(from: pboard)
        guard !urls.isEmpty else {
            error.pointee = "没有选中文件" as NSString
            return
        }
        ArchiveCreateWindowController.show(files: urls)
    }

    @objc public func copyPaths(_ pboard: NSPasteboard, userData: String,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(from: pboard)
        guard !urls.isEmpty else {
            let message = "复制路径失败：服务没有收到文件或目录 URL"
            error.pointee = message as NSString
            Toast.show(message, icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        let text = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            let message = "\(urls.count) 个路径复制失败：无法写入系统剪贴板"
            error.pointee = message as NSString
            Toast.show(message, icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        Toast.show("已复制 \(urls.count) 个绝对路径", icon: "doc.on.doc")
    }

    @objc public func openInTerminal(_ pboard: NSPasteboard, userData: String,
                                     error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(from: pboard)
        guard !urls.isEmpty else {
            let message = "终端打开失败：服务没有收到文件或目录 URL"
            error.pointee = message as NSString
            Toast.show(message, icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        var directories: [URL] = []
        var seen = Set<URL>()
        var failures: [String] = []
        for url in urls {
            do {
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                let directory = isDirectory ? url : url.deletingLastPathComponent()
                if seen.insert(directory).inserted { directories.append(directory) }
            } catch {
                failures.append("\(url.path)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            let message = "终端打开失败：\n" + failures.joined(separator: "\n")
            error.pointee = message as NSString
            Toast.show(message, icon: "exclamationmark.triangle", isWarning: true)
        }
        guard !directories.isEmpty else { return }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            let message = "终端打开失败：找不到 Terminal；目录：" + directories.map(\.path).joined(separator: "\n")
            error.pointee = message as NSString
            Toast.show(message, icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        for directory in directories {
            NSWorkspace.shared.open([directory], withApplicationAt: terminal,
                                    configuration: NSWorkspace.OpenConfiguration()) { application, failure in
                DispatchQueue.main.async {
                    if let failure {
                        Toast.show("\(directory.path) 终端打开失败：\(failure.localizedDescription)",
                                   icon: "exclamationmark.triangle", isWarning: true)
                    } else if application != nil {
                        Toast.show("已在终端打开：\(directory.path)", icon: "terminal")
                    } else {
                        Toast.show("\(directory.path) 终端打开失败：系统未返回 Terminal 应用", isWarning: true)
                    }
                }
            }
        }
    }

    // MARK: 粘贴板解析

    /// 读 pboard 里的文件 URL（只取真实文件路径）
    private static func fileURLs(from pboard: NSPasteboard) -> [URL] {
        let urls = pboard.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { $0.standardizedFileURL }
    }

    /// 只留可解压的压缩包（ArchiveCore.isArchive 过滤 33 种扩展名）
    private static func archives(from pboard: NSPasteboard) -> [URL] {
        fileURLs(from: pboard).filter { ArchiveCore.isArchive($0) }
    }
}

// v127（ArcZip P3）：补充说明——
// 1) NSServices 的菜单项文案在 Info.plist（NSMenuItem/解压到此处·解压到…·压缩），
//    系统在「访达 → 选中文件右键 → 服务」里展示；用户可在
//    「系统设置 → 键盘 → 键盘快捷键 → 服务」里开关。
// 2) 右键「按默认设置快速压缩」（ArcZip 的一键压缩）未单列服务项：NSServices 走
//    ArchiveCreateWindowController 面板已含「通用分享」等 5 种预设，一键语义由预设承担；
//    如需真正无面板的快速压缩，可后续加第 4 个 NSMessage（quickCompress）直接调
//    ArchiveCore.create(files:to:level:5)，但那要先定输出命名规则，留待下一轮。
