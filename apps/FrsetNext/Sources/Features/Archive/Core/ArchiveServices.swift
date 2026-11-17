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
                    Toast.show(value ? "ZIP 将用 Kitnest 打开" : "已恢复 ZIP 打开方式", icon: "archivebox")
                }
            }
        }
    }
}

/// 教程与设置复用同一开关，显示系统关联而非本地布尔值。
struct ArchiveDefaultApplicationOption: View {
    @ObservedObject private var association = ArchiveDefaultApplication.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("用 Kitnest 默认打开 ZIP", isOn: Binding(
                get: { association.enabled }, set: { association.setEnabled($0) }))
                .toggleStyle(.switch)
                .disabled(association.changing)
            Text("开启后，双击 ZIP 在 Kitnest 中查看并解压；关闭后恢复此前的打开方式。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(association.changing ? "正在更改…" : "当前默认：\(association.applicationName)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("压缩：访达选中文件 → 右键 → 服务 → 用 Kitnest 压缩。访达原有的「压缩」保持不变。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("复制路径与终端打开：Finder 选中文件或目录 → 右键 → 服务 →「用 Kitnest 复制路径」或「用 Kitnest 在终端打开」。请在系统设置 → 键盘 → 键盘快捷键 → 服务中分别启用这两项。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("打开系统键盘设置") {
                if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard")!) {
                    Toast.show("无法打开系统键盘设置，请从系统设置进入键盘 → 键盘快捷键 → 服务", isWarning: true)
                }
            }
            .buttonStyle(.link)
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
