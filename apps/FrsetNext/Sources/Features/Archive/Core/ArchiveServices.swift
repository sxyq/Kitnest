import AppKit
import Foundation

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
// 三个 selector 名与 Info.plist 的 NSMessage 一一对应：
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

    /// 「用 FrsetNext 打开」（v167）：右键选中的压缩包 → 直达归档浏览窗
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
