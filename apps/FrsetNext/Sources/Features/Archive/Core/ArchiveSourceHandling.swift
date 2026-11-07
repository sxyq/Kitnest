import AppKit

// MARK: - 压缩完成后的原文件处理（v258）
//
// 对齐 ArcZip 的 completion 逻辑：压缩成功之后**主动问一次**「原文件保留还是收走」，
// 勾了「记住」之后按选择静默执行，不再每次弹。
//
// 三条硬规则：
//   · 只走废纸篓（NSWorkspace.recycle），永远不做不可恢复的删除；
//   · 输出包在源目录内部时直接跳过——否则会把刚做好的包一起回收；
//   · 提示发生在创建面板关闭之后，避免弹窗挂在一个正在消失的窗口上。

enum ArchiveSourceHandling {

    /// ask：每次询问；keep：永远保留；trash：直接进废纸篓
    enum Mode: String {
        case ask, keep, trash
    }

    private static let defaultsKey = "archive.compressSourceHandling"

    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// 压缩成功后的统一入口
    static func offerCleanup(sources: [URL], output: URL) {
        guard !sources.isEmpty else { return }
        // 输出落在被压缩的目录里（用户把输出目录改成了那个文件夹）→ 不能动源文件
        if sources.contains(where: { isDirectory($0) && output.path.hasPrefix($0.path + "/") }) {
            Log.info("Archive", "压缩完成：输出在源目录内，跳过原文件处理")
            return
        }
        switch mode {
        case .keep:
            return
        case .trash:
            recycle(sources)
        case .ask:
            ask(sources: sources, output: output)
        }
    }

    // MARK: 询问

    private static func ask(sources: [URL], output: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "压缩完成，原文件怎么处理？"
        alert.informativeText = "已创建「\(output.lastPathComponent)」。\n"
            + "原文件 \(sources.count) 项仍在原位置；移到废纸篓后随时可以恢复。"
        alert.addButton(withTitle: "保留原文件")
        alert.addButton(withTitle: "移到废纸篓")

        let remember = NSButton(checkboxWithTitle: "记住我的选择，之后不再询问", target: nil, action: nil)
        remember.state = .off
        alert.accessoryView = remember

        NSApp.activate(ignoringOtherApps: true)
        let toTrash = alert.runModal() == .alertSecondButtonReturn
        if remember.state == .on { mode = toTrash ? .trash : .keep }
        if toTrash { recycle(sources) }
    }

    // MARK: 回收

    private static func recycle(_ urls: [URL]) {
        NSWorkspace.shared.recycle(urls) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Log.warn("Archive", "原文件移到废纸篓失败：\(error.localizedDescription)")
                    Toast.show("原文件移到废纸篓失败：\(error.localizedDescription)",
                               icon: "exclamationmark.triangle")
                } else if urls.count == 1 {
                    Toast.show("原文件已移到废纸篓：\(urls[0].lastPathComponent)", icon: "trash")
                } else {
                    Toast.show("\(urls.count) 项原文件已移到废纸篓", icon: "trash")
                }
            }
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }
}
