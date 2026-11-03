import Foundation

// MARK: - 主面板顶部页面开关 + 顺序（v177 / v181）
//
// 用户需求：「设置里可以自定义顶部的中转 / 首页 / 监测 / 投屏这些按钮的展现与显示，
// 并且动态加载；如果全关闭了，就不占内存」；v181 追加「开关与「文件中转」总开关解耦，
// 并且可以拖拽调整顺序」。
//
// 这里只负责两件事：
//   ① 哪些页面启用（`panel.segment.*`）；
//   ② 它们的左右顺序（`panel.segment.order`，CSV）。
// 真正的懒加载在 `PanelRootView`：内容用 if/else 分支，未选中的分支不会被创建；
// 关掉的页面更不会被创建，因此 `TransferDockView` / `CastView` 这类重型视图连 init 都不会跑。
//
// 与旧开关 `panel.transferDock` 的关系（v181 拆分）：
// - 旧开关**不再**决定分段是否出现，它只表示「文件中转这个功能启用与否」；
// - 分段显隐只由 `panel.segment.*` 决定；
// - 功能关着但分段开着时，中转页显示一句「已关闭」的说明（不再整页消失），
//   这样两个开关各自可解释，也不会出现「勾了却不出现」的困惑。

public enum PanelSegments {

    public static let homeKey = "panel.segment.home"
    public static let monitorKey = "panel.segment.monitor"
    public static let transferKey = "panel.segment.transfer"
    public static let castKey = "panel.segment.cast"
    /// 顺序：逗号分隔的 `PanelCenterPage.rawValue`，如 "home,performance,transfer,cast"
    public static let orderKey = "panel.segment.order"

    /// 出厂顺序（也是「恢复默认」用的顺序）
    public static let defaultOrder: [PanelCenterPage] = [.home, .performance, .transfer, .cast]

    public static func key(for page: PanelCenterPage) -> String {
        switch page {
        case .home:        return homeKey
        case .performance: return monitorKey
        case .transfer:    return transferKey
        case .cast:        return castKey
        }
    }

    public static func title(_ page: PanelCenterPage) -> String {
        switch page {
        case .home:        return "主页"
        case .performance: return "监测"
        case .transfer:    return "中转"
        case .cast:        return "投屏"
        }
    }

    /// 设置里的完整称呼（分段按钮上放不下，设置列表里用这个）
    public static func fullTitle(_ page: PanelCenterPage) -> String {
        switch page {
        case .home:        return "主页"
        case .performance: return "性能监测"
        case .transfer:    return "文件中转"
        case .cast:        return "投屏"
        }
    }

    /// 出厂默认：只开「主页 / 监测」。
    /// v183（用户）：「中转和投屏这两个按钮默认关闭，要用再去设置里开」——
    /// 这两个功能分别依赖局域网/ADB 与投屏配对，绝大多数人不需要，
    /// 默认摆一个空页只会让面板顶栏看起来更挤。
    public static func defaultEnabled(_ page: PanelCenterPage) -> Bool {
        switch page {
        case .home, .performance: return true
        case .transfer, .cast:    return false
        }
    }

    public static func isEnabled(_ page: PanelCenterPage) -> Bool {
        Preferences.shared.value(key(for: page), default: defaultEnabled(page))
    }

    public static func setEnabled(_ page: PanelCenterPage, _ on: Bool) {
        Preferences.shared.set(key(for: page), on)
    }

    // MARK: 顺序

    /// 当前顺序（**总是**包含四个页面，缺的按默认顺序补在后面——
    /// 这样以后加第五页时，老用户的顺序串不会把它吃掉）
    public static var order: [PanelCenterPage] {
        get { decode(Preferences.shared.value(orderKey, default: "")) }
        set { Preferences.shared.set(orderKey, encode(newValue)) }
    }

    public static func decode(_ raw: String) -> [PanelCenterPage] {
        var pages: [PanelCenterPage] = []
        for token in raw.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard let page = PanelCenterPage(rawValue: trimmed), !pages.contains(page) else { continue }
            pages.append(page)
        }
        for page in defaultOrder where !pages.contains(page) { pages.append(page) }
        return pages
    }

    public static func encode(_ pages: [PanelCenterPage]) -> String {
        // 去重 + 补全：写盘的一定是完整的四页
        var normalized = pages
        for page in defaultOrder where !normalized.contains(page) { normalized.append(page) }
        var seen = Set<PanelCenterPage>()
        return normalized.filter { seen.insert($0).inserted }.map(\.rawValue).joined(separator: ",")
    }

    /// 把 `page` 插到 `target` 位置（拖拽落点语义）
    public static func move(_ page: PanelCenterPage, toIndex target: Int,
                            in pages: [PanelCenterPage]) -> [PanelCenterPage] {
        guard let from = pages.firstIndex(of: page) else { return pages }
        var result = pages
        result.remove(at: from)
        result.insert(page, at: max(0, min(target, result.count)))
        return result
    }

    // MARK: 生效顺序

    /// 顶部实际出现的页面：按用户顺序过滤掉关掉的。
    /// v181 起**不再**受「文件中转」总开关约束（总开关只影响中转页里的功能）。
    public static func enabledPages() -> [PanelCenterPage] {
        enabledPages(order: order)
    }

    /// 同上，但顺序由调用方给（SwiftUI 侧用 @AppStorage 的值，保证即时刷新）
    public static func enabledPages(order pages: [PanelCenterPage]) -> [PanelCenterPage] {
        pages.filter { isEnabled($0) }
    }
}

// MARK: - 全局入口开关（v192）
//
// 用户（2026-11-03）：「状态栏里面的那两个性能监测界面和那个主页，都是在设置中
// 也能够添加进行关闭，跟那个中转和投屏一样」。
//
// 与 `PanelSegments` 的分工：
//   · PanelSegments 管**主面板顶部的分段按钮**（主页/监测/中转/投屏）；
//   · 这里管**菜单栏（状态栏）里的入口项**与两个独立窗口是否可达：
//       - entry.home          菜单栏「打开面板」+ ⌥A 热键
//       - entry.monitorPopout 菜单栏「性能监测…」+ ⌥P 热键
//       - entry.statsBar      菜单栏 STATS 合并条（性能部件本身）
// 两者独立：关掉顶部「监测」分段不影响独立监测窗，反之亦然。

public enum GlobalEntries {

    public static let homeKey = "entry.home"
    public static let monitorPopoutKey = "entry.monitorPopout"
    public static let statsBarKey = "entry.statsBar"

    /// 出厂默认：三个都开（性能监测是本产品的核心卖点，用户明确要求默认打开）
    public static func isEnabled(_ key: String) -> Bool {
        Preferences.shared.value(key, default: true)
    }

    public static func setEnabled(_ key: String, _ on: Bool) {
        Preferences.shared.set(key, on)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// 菜单栏菜单在这三个开关变化后要重建（缓存的是 NSMenu 结构，不是勾选态）
    public static let didChangeNotification = Notification.Name("FrsetNext.GlobalEntries.didChange")
}
