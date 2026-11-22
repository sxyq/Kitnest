import AppKit
import SwiftUI

// MARK: - 监测页共用的进程表、图标与退出菜单

/// 进程表（原版「高占用进程」）：表头 + 行（应用图标 + 名称 + 右侧一/两列数值）
///
/// v84（用户需求「归类 + 展开 + 图标 + 退出」）：
/// · 归类：数据层已按 App 合并（Helper/Renderer 归到宿主），行显示「名称 + N 个进程」；
/// · 展开：点击行展开组内子进程明细（按当前维度降序，第一行即「占得最多」的那个）；
/// · 退出：右键（或长按）行 → 菜单「退出 xxx」，结束整组全部 pid；
/// · 图标：StatsAppIcon 按 App 名解析真实 bundle 图标。
struct StatsProcTable: View {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    struct Column {
        var title: String
        var color: Color?
    }

    var title: String
    var columns: [Column]
    var items: [StatsProcItem]
    var subtitle: (StatsProcItem) -> String? = { _ in nil }
    var values: (StatsProcItem) -> [String]
    /// 展开行的数值格式（子进程用）——默认与主行相同
    var childValues: ((StatsProcItem) -> [String])? = nil

    /// 已展开的组（按 bundle 路径/进程名标识——pid 会随排序变化，不能当键）
    @Stored private var expandedIDs: Set<String> = []

    /// 数值列宽：单列 86（对齐原版），双列各 64——否则 380 宽窗里名字只剩 5~6 个字符
    private var columnWidth: CGFloat { columns.count > 1 ? 64 : 86 }

    private func childValueTexts(_ child: StatsProcItem) -> [String] {
        if let childValues { return childValues(child) }
        return values(child)
    }

    /// 子进程显示名：去掉与组名重复的前缀，让「哪个 Helper 占得多」一眼可辨。
    /// 「Microsoft Edge Helper (Renderer)」→「Helper (Renderer)」；主进程本身 → 「主进程」。
    private func childLabel(_ child: StatsProcItem, group: String) -> String {
        var name = child.name
        if name == group { return "主进程" }
        if name.hasPrefix(group) {
            name = String(name.dropFirst(group.count)).trimmingCharacters(in: .whitespaces)
            while name.hasPrefix("-") || name.hasPrefix("—") {
                name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        return name.isEmpty ? child.name : name
    }

    var body: some View {
        VStack(spacing: 6) {
            MonitorSectionTitle(title)
            HStack(spacing: 8) {
                Text("进程")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    if let color = column.color {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color)
                            .frame(width: 9, height: 9)
                            .frame(width: columnWidth, alignment: .trailing)
                    } else {
                        Text(column.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: columnWidth, alignment: .trailing)
                    }
                }
            }
            ForEach(items) { item in
                let expandable = !item.children.isEmpty
                let expanded = expandedIDs.contains(item.groupKey)
                // v129（内存）：values(item) 每行只算一次——原实现 body 求值里调 3 次
                //（数值列 / onTapGesture / contextMenu 各一次），每次返回新建 [String] +
                // N 个格式化字符串。tick 驱动的重绘下（1~2s 一帧 ×4 表×8 行）是
                // 32B/48B 小块（malloc 直方图峰值）的稳定churn 源之一。
                let rowValues = values(item)
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        // 展开指示：可展开组显示 chevron，单进程组留空占位（不再用 3pt 圆点）
                        Group {
                            if expandable {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.tertiaryText)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 8)
                        StatsAppIcon(name: item.name, path: item.iconPath, size: 16)
                        Text(item.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let note = subtitle(item), !note.isEmpty {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        if expandable, !expanded {
                            Text("\(item.children.count) 进程")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiaryText)
                                .fixedSize()
                        }
                        Spacer(minLength: 4)
                        // v129（内存）：indices 遍历替代 Array(enumerated())——
                        // 后者每帧为每行建 [(offset, element)] 元组数组（48B 级小块）。
                        ForEach(rowValues.indices, id: \.self) { i in
                            Text(rowValues[i])
                                .font(.system(size: 12).monospacedDigit())
                                .lineLimit(1)
                                .frame(width: columnWidth, alignment: .trailing)
                        }
                        // v84：显式退出按钮（右键菜单之外的直达入口；整组 pid 一并结束）
                        Button {
                            StatsProcQuitter.confirmAndQuit(item: item)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("退出 \(item.name)（\(item.pids.count) 个进程）")
                    }
                    .contentShape(Rectangle())
                    // v84：点击展开/收起（原 v71 是点开菜单；退出改走右键，避免误触）
                    .onTapGesture {
                        guard expandable else {
                            if !isSettingsPreview { ProcMenuPresenter.shared.present(for: item, values: rowValues, at: NSEvent.mouseLocation) }
                            return
                        }
                        if expanded { expandedIDs.remove(item.groupKey) } else { expandedIDs.insert(item.groupKey) }
                    }
                    .contextMenu { if !isSettingsPreview { StatsProcContextMenu(item: item, values: rowValues) } }

                    // 展开：组内子进程明细（缩进 + 小字号 + 同列对齐）
                    if expanded, expandable {
                        ForEach(item.children) { child in
                            // v129（内存）：同上，childValueTexts 每行只算一次 + indices 遍历
                            let childTexts = childValueTexts(child)
                            HStack(spacing: 8) {
                                Color.clear.frame(width: 8)
                                Color.clear.frame(width: 16)
                                Text(childLabel(child, group: item.name))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                ForEach(childTexts.indices, id: \.self) { i in
                                    Text(childTexts[i])
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(width: columnWidth, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 进程图标（v86 重写）：按**可执行路径**取宿主 App 图标，路径为空时才回落到名字。
///
/// 旧实现的问题（用户反馈「图标并没有正确展现」）：
///   · 按进程名查硬编码表 + 异步扫 /Applications 建索引 → 首次渲染必然落空，
///     而落空结果被永久写进缓存（`cache[name] = 通用图标`），索引就绪后也再也不刷新；
///   · 归类键是「进程名去 Helper/括号」，与真实 App 无绑定，同名不同 App 会串图标。
/// 现在：归类与图标同源——C 层给出的可执行路径截取 `.app`，NSWorkspace 直接取宿主图标，
/// 不依赖任何名字猜测，也不存在「先落空后不刷新」。缓存键 = 路径，一次解析终身复用。
struct StatsAppIcon: View {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    var name: String
    /// 宿主 `.app` 路径，或（无 bundle 的进程）可执行文件路径
    var path: String = ""
    var size: CGFloat = 16

    var body: some View {
        Group {
            if isSettingsPreview {
                Image(systemName: "app.fill").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
            } else if let icon = Self.cachedIcon(path: path, name: name) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // 连可执行路径都拿不到（内核进程等）——保持原版观感：深灰圆角方块
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.82))
            }
        }
        .frame(width: size, height: size)
    }

    /// 路径 → 图标缓存（只缓存成功结果；失败不写缓存，避免「一次落空、永不刷新」）
    // v129（内存）：原无界 [String: NSImage] 字典按进程可执行路径无限增长——
    // NSWorkspace 图标是多分辨率位图 NSImage（内部 CGImage 底座属 non-object 原始块，
    // heap：__DataStorage/位图底座随缓存条目线性驻留），FRSET_PROC_CAP=512 下
    // 采样会路过数百个不同路径。改 NSCache + countLimit=192（可视行 ~40 个，
    // 4 轮滚动余量），内存压力下自动淘汰。NSCache 线程安全，原 NSLock 一并去掉。
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 192
        return c
    }()

    static func cachedIcon(path: String, name: String) -> NSImage? {
        let key = (path.isEmpty ? "name:" + name : path) as NSString
        if let hit = cache.object(forKey: key) { return hit }

        var icon: NSImage?
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else if !name.isEmpty {
            // 兜底：仅当拿不到路径时，才用名字在运行中的 App 里找同名 bundle
            icon = NSWorkspace.shared.runningApplications
                .first { ($0.localizedName ?? "") == name }
                .flatMap { $0.bundleURL?.path }
                .map { NSWorkspace.shared.icon(forFile: $0) }
        }
        guard let image = icon else { return nil }
        image.size = NSSize(width: 32, height: 32)   // 32pt 源图，16pt 显示更锐利（Retina）
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 进程菜单（v71：用户需求「进程可点击→选择退出」）：点击行以 NSMenu 在鼠标位置弹出，
/// 右键走 SwiftUI contextMenu（同一菜单构造）。退出 = SIGTERM 全部合并 pid。
final class ProcMenuPresenter: NSObject {
    static let shared = ProcMenuPresenter()

    /// 在屏幕坐标处弹出菜单（onTapGesture 点击路径）
    func present(for item: StatsProcItem, values: [String], at screenPoint: NSPoint) {
        let menu = buildMenu(item: item, values: values)
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    /// 构建菜单（含 target-action 退出项；菜单持有 item → 关闭后释放）
    func buildMenu(item: StatsProcItem, values: [String]) -> NSMenu {
        let menu = NSMenu()
        let pidText = item.pids.count > 1 ? "\(item.pids.count) 个进程 · PID \(item.pids.map(String.init).joined(separator: ", "))"
                                         : "PID \(item.pid)"
        let info = NSMenuItem(title: "\(item.name) · \(pidText) · \(values.joined(separator: " · "))",
                              action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 \(item.name)",
                                  action: #selector(quit(_:)),
                                  keyEquivalent: "")
        quitItem.target = self
        quitItem.representedObject = item
        menu.addItem(quitItem)
        menu.addItem(.separator())
        let cancel = NSMenuItem(title: "取消", action: nil, keyEquivalent: "")
        menu.addItem(cancel)
        return menu
    }

    @objc private func quit(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? StatsProcItem else { return }
        StatsProcQuitter.quit(item: item)
    }
}

/// SwiftUI contextMenu（右键路径）：菜单内容与 NSMenu 版一致
struct StatsProcContextMenu: View {
    let item: StatsProcItem
    let values: [String]

    var body: some View {
        Text(verbatim: "\(item.name) · PID \(item.pids.map(String.init).joined(separator: ", "))")
            .foregroundStyle(.secondary)
        Divider()
        Button(role: .destructive) {
            StatsProcQuitter.quit(item: item)
        } label: {
            Label("退出 \(item.name)", systemImage: "xmark.circle")
        }
        Divider()
        Text(verbatim: values.joined(separator: " · "))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

/// 退出进程：SIGTERM 全部合并 pid（同 App 的 Helper/Renderer 一并结束）
enum StatsProcQuitter {
    static func quit(item: StatsProcItem) {
        var succeeded = 0
        for pid in item.pids where kill(pid, SIGTERM) == 0 { succeeded += 1 }
        DispatchQueue.main.async {
            if succeeded > 0 {
                Toast.show("已请求退出 \(item.name)（\(succeeded) 个进程）", icon: "xmark.circle")
            } else {
                Toast.show("无法退出 \(item.name)：权限不足或已退出", icon: "exclamationmark.triangle")
            }
        }
    }

    /// v84：行内「退出」按钮走确认框（避免误点杀掉正在编辑的 App）；
    /// 右键菜单是显式选择，仍直接退出。
    static func confirmAndQuit(item: StatsProcItem) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出 \(item.name)？"
        alert.informativeText = item.pids.count > 1
            ? "将结束该应用的 \(item.pids.count) 个进程，未保存的内容可能丢失。"
            : "未保存的内容可能丢失。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        quit(item: item)
    }
}
