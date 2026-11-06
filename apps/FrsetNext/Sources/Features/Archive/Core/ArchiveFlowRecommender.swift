import AppKit
import SwiftUI

// MARK: - Flow 智能推荐（v127（ArcZip P3）：P3-3）
//
// 「Flow 会根据压缩包内容，推荐此刻最合适的操作」：
//   含 .app → 安装应用到 /Applications；含字体 → 安装字体；单个文件 → 用默认应用打开；
//   多张图片 → 解压全部图片；含 .dmg → 挂载磁盘映像；其余 → 解压到… / 浏览内容。
//
// 交付两件东西：
//   1) ArchiveFlowRecommender.recommend(for:url:) —— 规则引擎（纯逻辑，不依赖任何窗口）
//   2) ArchiveFlowBar —— 横向推荐条 View（供浏览窗顶部接入；见文件末尾 demo() 注释）
//
// 动作实做程度：「解压到…」「打开文件（单文件）」「安装应用」三个完整落地（调
// ArchiveCore.extract / extractEntryToTemp + NSWorkspace）；「安装字体」「挂载磁盘映像」
// 「解压全部图片」同样为真实实现（见各 action 注释）。

// MARK: - 推荐条目

public struct ArchiveFlowRecommendation: Identifiable {
    /// 稳定 id（规则 key，同一次 recommend 内唯一）
    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    /// 点击执行（已绑定好归档 URL 与相关条目）
    public let action: () -> Void
    /// 优先级（小者靠前；由规则枚举顺序决定）
    let priority: Int

    init(id: String, title: String, subtitle: String, systemImage: String,
         priority: Int, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.action = action
        self.priority = priority
    }
}

// MARK: - 规则引擎

public enum ArchiveFlowRecommender {

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg"
    ]
    private static let fontExtensions: Set<String> = ["otf", "ttf", "ttc"]

    /// v127（ArcZip P3）：带选中条目的推荐（「解压所选 Flow」置顶）。
    ///
    /// 返回**按优先级排序的完整列表**；UI 层取前 3-5 个展示，其余计「另有 N 个备选」
    /// （见 ArchiveFlowBar.displayLimit）。如需「解压所选」，用 `selected:` 传入勾选条目，会插到最前。
    public static func recommend(for entries: [ArchiveEntry], url: URL,
                                 selected: [ArchiveEntry]?) -> [ArchiveFlowRecommendation] {
        var result: [ArchiveFlowRecommendation] = []
        let files = entries.filter { !$0.isDirectory }

        // —— 解压所选（有勾选时置顶）——
        if let selected, !selected.isEmpty {
            result.append(ArchiveFlowRecommendation(
                id: "extract-selected",
                title: "解压所选 \(selected.count) 项",
                subtitle: "只解出勾选的条目",
                systemImage: "checkmark.circle",
                priority: 0) {
                    extractEntries(selected, of: url)
                })
        }

        // —— 含 .app 包 → 安装应用到 /Applications ——
        // 真实实现：整包解到临时目录 → 把顶层 .app 拷到 /Applications（失败则留在临时目录）
        // → NSWorkspace 打开（启动/预览）。不做签名校验（任务明确豁免）。
        let appEntries = entries.filter { $0.name.lowercased().hasSuffix(".app") }
        if let app = appEntries.first {
            result.append(ArchiveFlowRecommendation(
                id: "install-app",
                title: "安装应用到 /Applications",
                subtitle: "解出 \(app.name) 并放入应用程序文件夹",
                systemImage: "app.badge.checkmark",
                priority: 10) {
                    installApp(archiveURL: url, appPath: app.path)
                })
        }

        // —— 含 .dmg → 挂载磁盘映像（hdiutil attach）——
        let dmgEntries = files.filter { $0.name.lowercased().hasSuffix(".dmg") }
        if let dmg = dmgEntries.first {
            result.append(ArchiveFlowRecommendation(
                id: "mount-dmg",
                title: "挂载磁盘映像",
                subtitle: "解出 \(dmg.name) 后用 hdiutil 挂载",
                systemImage: "externaldrive.badge.plus",
                priority: 20) {
                    mountDMG(archiveURL: url, entry: dmg)
                })
        }

        // —— 含字体（.otf/.ttf/.ttc）→ 安装字体 ——
        // 真实实现：解出字体文件 → 拷到 ~/Library/Fonts（用户级安装，无需管理员）。
        let fontEntries = files.filter { fontExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }
        if !fontEntries.isEmpty {
            result.append(ArchiveFlowRecommendation(
                id: "install-fonts",
                title: "安装 \(fontEntries.count) 个字体",
                subtitle: "解出后装入 ~/Library/Fonts",
                systemImage: "textformat",
                priority: 30) {
                    installFonts(archiveURL: url, entries: fontEntries)
                })
        }

        // —— 单个文件 → 用默认应用打开（「打开文件 Flow」）——
        if files.count == 1, entries.count == 1, let only = files.first {
            result.append(ArchiveFlowRecommendation(
                id: "open-file",
                title: "用默认应用打开",
                subtitle: only.name,
                systemImage: "arrow.up.forward.app",
                priority: 40) {
                    openFile(url: url, entry: only)
                })
        }

        // —— 含多个图片 → 解压全部图片 ——
        let imageEntries = files.filter { imageExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }
        if imageEntries.count >= 2 {
            result.append(ArchiveFlowRecommendation(
                id: "extract-images",
                title: "解压全部图片",
                subtitle: "\(imageEntries.count) 张图片",
                systemImage: "photo.on.rectangle",
                priority: 50) {
                    extractEntries(imageEntries, of: url)
                })
        }

        // —— 默认（始终在末尾）：解压到… / 浏览内容 ——
        result.append(ArchiveFlowRecommendation(
            id: "extract-all",
            title: "解压到…",
            subtitle: "整个压缩包解出到指定目录",
            systemImage: "archivebox",
            priority: 900) {
                extractAll(url: url)
            })
        result.append(ArchiveFlowRecommendation(
            id: "browse",
            title: "浏览内容",
            subtitle: "打开完整归档浏览窗口",
            systemImage: "list.bullet.rectangle",
            priority: 901) {
                ArchiveBrowserWindowController.show(url: url)
            })

        return result.sorted { $0.priority < $1.priority }
    }

    // MARK: 动作实做

    /// 「解压到…」：NSOpenPanel 选目录 → ArchiveCore.extract（整包）
    static func extractAll(url: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "解压到这里"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        ArchiveCore.extract(url: url, to: dir) { ok, msg in
            Toast.show(ok ? "已解压到 \(dir.lastPathComponent)" : "解压失败：\(msg)",
                       icon: ok ? "archivebox" : "exclamationmark.triangle",
                       isWarning: !ok)
        }
    }

    /// 「解压所选 / 解压全部图片」：选目录后逐条目解出
    static func extractEntries(_ entries: [ArchiveEntry], of url: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "解压到这里"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let group = DispatchGroup()
        var failed = 0
        for entry in entries {
            group.enter()
            ArchiveCore.extract(url: url, entry: entry.path, to: dir) { ok, _ in
                if !ok { failed += 1 }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            Toast.show(failed == 0 ? "已解压 \(entries.count) 项到 \(dir.lastPathComponent)"
                                   : "\(failed)/\(entries.count) 项解压失败",
                       icon: failed == 0 ? "archivebox" : "exclamationmark.triangle",
                       isWarning: failed != 0)
        }
    }

    /// 「打开文件」（单文件）：解到临时目录 → 默认应用打开（与浏览窗 openExternally 同链路）
    static func openFile(url: URL, entry: ArchiveEntry) {
        ArchiveCore.extractEntryToTemp(url: url, entry: entry) { tempURL, err in
            if let tempURL {
                NSWorkspace.shared.open(tempURL)
            } else {
                Toast.show(err, icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }

    /// 「安装应用到 /Applications」：整包解到临时目录 → 顶层 .app 拷入 /Applications
    /// （无权限时留在临时目录）→ NSWorkspace 打开。不做签名校验。
    static func installApp(archiveURL: URL, appPath: String) {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("frset-flow-app-\(UUID().uuidString)", isDirectory: true)
        ArchiveCore.extract(url: archiveURL, to: staging) { ok, msg in
            guard ok else {
                Toast.show("解出应用失败：\(msg)", icon: "exclamationmark.triangle", isWarning: true)
                return
            }
            // 优先找与 appPath 同名的 .app；否则取顶层第一个 .app
            var appURL = staging.appendingPathComponent(appPath)
            if !FileManager.default.fileExists(atPath: appURL.path) {
                let children = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
                if let found = children.first(where: { $0.lowercased().hasSuffix(".app") }) {
                    appURL = staging.appendingPathComponent(found)
                }
            }
            guard FileManager.default.fileExists(atPath: appURL.path) else {
                Toast.show("包内未找到 .app", icon: "exclamationmark.triangle", isWarning: true)
                return
            }
            let installed = URL(fileURLWithPath: "/Applications")
                .appendingPathComponent(appURL.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: installed.path) {
                    try FileManager.default.removeItem(at: installed)
                }
                try FileManager.default.copyItem(at: appURL, to: installed)
                NSWorkspace.shared.open(installed)
                Toast.show("已安装 \(installed.lastPathComponent) 到 /Applications",
                           icon: "app.badge.checkmark")
            } catch {
                // /Applications 不可写（非管理员/受管设备）→ 从临时目录直接打开
                NSWorkspace.shared.open(appURL)
                Toast.show("无权限写入 /Applications，已从临时目录打开",
                           icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }

    /// 「安装字体」：逐条解到临时目录 → 拷入 ~/Library/Fonts（用户级字体目录）
    static func installFonts(archiveURL: URL, entries: [ArchiveEntry]) {
        let fontsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        let group = DispatchGroup()
        var done = 0
        for entry in entries {
            group.enter()
            ArchiveCore.extractEntryToTemp(url: archiveURL, entry: entry) { tempURL, _ in
                defer { group.leave() }
                guard let tempURL else { return }
                let dest = fontsDir.appendingPathComponent(tempURL.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: tempURL, to: dest)) != nil {
                    done += 1
                }
            }
        }
        group.notify(queue: .main) {
            if done > 0 {
                NSWorkspace.shared.open(fontsDir)
                Toast.show("已安装 \(done) 个字体到 ~/Library/Fonts", icon: "textformat")
            } else {
                Toast.show("字体安装失败", icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }

    /// 「挂载磁盘映像」：先解出 .dmg 到临时目录，再 `hdiutil attach`
    /// （ArchiveCore 只跑 7zz，故这里直接起 /usr/bin/hdiutil 子进程）
    static func mountDMG(archiveURL: URL, entry: ArchiveEntry) {
        ArchiveCore.extractEntryToTemp(url: archiveURL, entry: entry) { tempURL, err in
            guard let tempURL else {
                Toast.show("解出磁盘映像失败：\(err)", icon: "exclamationmark.triangle", isWarning: true)
                return
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            task.arguments = ["attach", tempURL.path, "-nobrowse"]
            let errPipe = Pipe()
            task.standardError = errPipe
            do {
                try task.run()
                DispatchQueue.global(qos: .userInitiated).async {
                    task.waitUntilExit()
                    let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                         encoding: .utf8) ?? ""
                    DispatchQueue.main.async {
                        if task.terminationStatus == 0 {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/Volumes"))
                            Toast.show("已挂载 \(tempURL.lastPathComponent)", icon: "externaldrive.badge.plus")
                        } else {
                            Toast.show("挂载失败：\(errText.trimmingCharacters(in: .whitespacesAndNewlines))",
                                       icon: "exclamationmark.triangle", isWarning: true)
                        }
                    }
                }
            } catch {
                Toast.show("无法启动 hdiutil：\(error.localizedDescription)",
                           icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }
}

// MARK: - 推荐条 UI（横向）

/// v127（ArcZip P3）：Flow 推荐条——展示 recommend() 的前 N 个 + 「另有 N 个备选」。
/// 可被浏览窗顶部直接接入（见文件末尾 demo() 注释）。
public struct ArchiveFlowBar: View {

    /// 同屏最多展示的推荐数（3-5 个按宽度，任务约定）
    public static let displayLimit = 4

    private let recommendations: [ArchiveFlowRecommendation]
    private let moreCount: Int

    /// 由 (entries, url) 直接算出推荐
    public init(entries: [ArchiveEntry], url: URL, selected: [ArchiveEntry]? = nil) {
        let all = ArchiveFlowRecommender.recommend(for: entries, url: url, selected: selected)
        self.recommendations = Array(all.prefix(Self.displayLimit))
        self.moreCount = max(0, all.count - Self.displayLimit)
        self.more = Array(all.dropFirst(Self.displayLimit))
    }

    private let more: [ArchiveFlowRecommendation]

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(recommendations) { rec in
                    chip(rec)
                }
                if moreCount > 0 {
                    Menu {
                        ForEach(more) { rec in
                            Button {
                                rec.action()
                            } label: {
                                Label(rec.title, systemImage: rec.systemImage)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("另有 \(moreCount) 个备选")
                            Image(systemName: "chevron.down")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .glassCard(radius: 6)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: 32)
    }

    /// 单行小胶囊（v181）：原来每个推荐是「图标 + 两行文字」的大卡，一行放 4 个显得很挤；
    /// 标题留在胶囊上、说明进 tooltip，顶部这一条轻下来了。
    private func chip(_ rec: ArchiveFlowRecommendation) -> some View {
        Button {
            rec.action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: rec.systemImage)
                    .font(.system(size: 10.5))
                Text(rec.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Theme.accent.opacity(0.10),
                        in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(rec.subtitle)
    }

}
