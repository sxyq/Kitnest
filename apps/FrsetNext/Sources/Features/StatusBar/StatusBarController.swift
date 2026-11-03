import AppKit
import Foundation
import SwiftUI

// MARK: - 状态项运行时条目（NSStatusItem + 其描述符）

/// 一个已创建的动态状态项：持有 NSStatusItem 与对应的描述符
private struct StatusItemEntry {
    let descriptor: StatusItemDescriptor
    let item: NSStatusItem
    /// 双层项的自定义内容视图（nil = 单行标题项）
    let twoLineView: MenuBarTwoLineView?
}

// MARK: - 双层状态项视图（2026-10-16 v3，参照 STATS 源码重建）
//
// 实证依据（stats-recon/stats-source，STATS 同款方案）：
// 1) 状态项内容用 `button.addSubview(自定义 NSView)` 呈现，**不用 NSImage**——
//    位图模板图在 NSStatusBarButton 上不渲染（2026-10-16 本机实证：图赋值后
//    按钮连同图层背景一起不绘制；SF Symbol 模板图正常，疑与位图 rep 的模板
//    着色路径有关）。v2 的 NSBitmapImageRep 方案因此弃用；
// 2) `statusItem(withLength: 视图宽度)`——长度必须等于视图宽，否则按钮过窄
//    把子视图裁成残影（v1「<<」裁剪 Bug 根因）；
// 3) `button.image = NSImage()` 空图占位，否则按钮不绘制子视图（STATS 实证）；
// 4) 文字用 `NSColor.textColor`，随菜单栏明暗自适应——用户反馈"不要色块"，
//    默认不着色；网络上行/下行如需配色再由上层决定；
// 5) 宽度"只增不减"：内容变宽才更新 item.length，避免每秒重排（STATS 的
//    固定 rowWidth 同思路）。

final class MenuBarTwoLineView: NSView {
    private var line1: String = ""
    private var line2: String = ""
    private let font = NSFont.systemFont(ofSize: 9, weight: .light)
    /// 宽度变化回调（STATS widthHandler 同款，暂留扩展位）
    var widthHandler: (() -> Void)?

    /// 更新两行文本（无变化不触发重绘）
    func setTexts(_ l1: String, _ l2: String) {
        guard l1 != line1 || l2 != line2 else { return }
        line1 = l1; line2 = l2
        needsDisplay = true
    }

    /// 内容宽度（两行取宽者 + 内边距）
    var contentWidth: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let w1 = (line1 as NSString).size(withAttributes: attrs).width
        let w2 = (line2 as NSString).size(withAttributes: attrs).width
        return ceil(max(w1, w2)) + 4
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor   // 自适应菜单栏明暗，无固定色块
        ]
        let rowHeight = bounds.height / 2
        // NSView 原点在左下：第一行画在上半（高 y），第二行画在下半（低 y）
        (line1 as NSString).draw(in: NSRect(x: 0, y: rowHeight, width: bounds.width, height: rowHeight),
                                 withAttributes: attrs)
        (line2 as NSString).draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight),
                                 withAttributes: attrs)
    }
}

// MARK: - 菜单栏状态项总控

/// StatusBarController：Item-0（主图标）+ 由 StatusItemRegistry 注册的动态状态项
/// - 左键主图标 → ServiceLocator.panel?.toggle()；右键 → 主菜单
/// - 动态状态项：1s 刷新标题，点击优先 onTap，否则弹 popover
/// - 每 5s 重新同步注册表（新增/移除），尊重 menuBarIconsVisible，最多展示 6 个（其余合并到「更多」）
public final class StatusBarController: NSObject {

    public static let shared = StatusBarController()

    /// 除主图标外最多展示的动态状态项数量
    private static let maxVisibleItems = 6
    /// 「更多」聚合项的标题
    private static let overflowTitle = "⋯"
    /// 隐藏标记：注册方（如监测模块）在设置里关掉某项时，不注销 descriptor，
    /// 而是让 title() 返回以本前缀开头的字符串；本模块据此隐藏该项（硬编码，避免跨模块引用）
    private static let hiddenMarker = "⟨monitor:hidden⟩"

    private var mainItem: NSStatusItem?
    private var entries: [StatusItemEntry] = []
    private var overflowItem: NSStatusItem?
    private var overflowDescriptors: [StatusItemDescriptor] = []
    /// 上次同步时的状态项 id 序列（用于判定是否需要重建）
    private var lastIDs: [String] = []

    /// 性能探针开关（FRSET_PERF_PROBE=1）：仅性能测试时打开，生产零日志
    private static let perfProbe = ProcessInfo.processInfo.environment["FRSET_PERF_PROBE"] != nil
    /// 布局核验：每个状态项上次记录到的窗口框架键（变化才记日志）
    private var lastLayoutKeys: [String: String] = [:]

    private var currentPopover: NSPopover?
    private var refreshTimer: Timer?
    private var syncTimer: Timer?
    private var defaultsObservation: NSObjectProtocol?
    private var statisticsObservation: NSObjectProtocol?
    private var didInstall = false

    private override init() { super.init() }

    // MARK: 安装

    /// 安装主图标并启动刷新/同步定时器（必须在主线程调用，内部会兜底切主线程）
    public func install() {
        if Thread.isMainThread {
            performInstall()
        } else {
            DispatchQueue.main.async { self.performInstall() }
        }
    }

    private func performInstall() {
        guard !didInstall else { return }
        didInstall = true
        installMainItem()
        syncStatusItems()
        startTimers()
        observePreferences()
        statisticsObservation = NotificationCenter.default.addObserver(
            forName: Notification.Name("frset.openStatistics"), object: nil, queue: .main
        ) { [weak self] _ in self?.showStatisticsAction(nil) }
        Log.info("StatusBar", "installed")
    }

    /// 卸载全部状态项（退出或调试用）
    public func uninstall() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.uninstall() }; return }
        refreshTimer?.invalidate(); refreshTimer = nil
        syncTimer?.invalidate(); syncTimer = nil
        if let obs = defaultsObservation { NotificationCenter.default.removeObserver(obs); defaultsObservation = nil }
        if let obs = statisticsObservation { NotificationCenter.default.removeObserver(obs); statisticsObservation = nil }
        teardownItems()
        if let main = mainItem { NSStatusBar.system.removeStatusItem(main); mainItem = nil }
        didInstall = false
    }

    private func installMainItem() {
        // v71（实测：菜单栏图标被挤出屏幕外）：不再钉 Preferred Position=322。
        // 322 是 2026-10-16 旧屏/旧图标数下的相邻槽位；如今菜单栏图标增多后，
        // 钉死位置导致主图标 + 合并条整组被挤到屏幕右缘外（只剩末字符残段）。
        // 清掉钉位让系统自动排布（同队列其他 app 图标右侧）。
        UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(Self.statusItemName("main"))")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.statusItemName("main")   // 固定 autosaveName（带前缀），位置持久化稳定
        let symbol = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Frset")
        symbol?.isTemplate = true                 // 模板图：随菜单栏明暗自动变色
        item.button?.image = symbol
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Frset（右键查看更多）"
        item.button?.target = self
        item.button?.action = #selector(mainItemClicked(_:))
        // 左键开面板，右键弹菜单
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        ToastAnchor.button = item.button       // 通知条定位锚点（spec 13 §3，主状态项图标）
        mainItem = item
        // v30：把主图标项注册给 STATS 引擎（位置校准/保邻的参照物）
        StatsBarEngine.syncMainItem()
    }

    /// v30：主图标状态项（STATS 引擎保邻修正的参照物；只读）
    public var mainStatusItem: NSStatusItem? { mainItem }

    /// 调整主图标状态项宽度（MenuBarIconStyleApplier 的 fan 样式需要固定宽度容纳旋转视图；
    /// 传 NSStatusItem.variableLength 恢复自适应）。2026-10-16：fan 的 18pt 子视图
    /// 在可变长度按钮里被裁剪成「<<」状扇叶，故 fan 期间固定 30pt 并居中。
    public func setMainItemLength(_ length: CGFloat) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.setMainItemLength(length) }; return }
        mainItem?.length = length
    }

    /// 主状态项当前长度（排障用：验证 setMainItemLength 对 variableLength 创建的项是否生效）
    public var mainItemLength: CGFloat? { mainItem?.length }

    private func startTimers() {
        refreshTimer?.invalidate()
        // v128（流畅度）：Timer 回调体进 autoreleasepool（标题格式化/布局键字符串
        // 的临时对象随回调排空，不等 runloop 回收）。
        let refresh = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            autoreleasepool { self?.refreshTitles() }
        }
        RunLoop.main.add(refresh, forMode: .common)
        refreshTimer = refresh

        syncTimer?.invalidate()
        let sync = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            // v128（流畅度）：同上
            autoreleasepool { self?.syncStatusItems() }
        }
        RunLoop.main.add(sync, forMode: .common)
        syncTimer = sync
    }

    /// 偏好变化时立即生效（menuBar.iconsVisible）
    ///
    /// v84（2026-10-20 用户反馈「设置界面随便点两下就卡死」）：
    /// Personalization 一次 persist 会连写 15 个键 → 15 次 didChangeNotification；
    /// 拖动个性化滑块时每帧一次 persist → 每秒数百次通知，每次都同步跑
    /// syncStatusItems（遍历状态项 + 重绘双层图 + C 引擎对齐），主线程被淹没。
    /// 改为 250ms 合并节流：连续通知只跑最后一次。
    private var prefSyncWorkItem: DispatchWorkItem?

    private func observePreferences() {
        defaultsObservation = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.prefSyncWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.syncStatusItems() }
            self.prefSyncWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    // MARK: 同步（新建/移除）

    /// 防重入标志：2026-10-16 崩溃实证——refreshTitles 变更 isVisible 会引发系统写
    /// defaults → UserDefaults.didChangeNotification → observePreferences →
    /// syncStatusItems 的同步递归，深栈后溢出（EXC_BAD_ACCESS at stack guard）。
    private var isSyncing = false

    /// 与 StatusItemRegistry 对齐：id 序列变化才重建，否则只刷新标题
    public func syncStatusItems() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.syncStatusItems() }; return }
        guard didInstall else { return }
        guard !isSyncing else { return }        // 防重入（同步递归链直接截断）
        isSyncing = true
        defer { isSyncing = false }
        // 关闭开关时只保留主图标；再过滤掉注册方标记为隐藏的项
        let descriptors = Preferences.shared.menuBarIconsVisible
            ? StatusItemRegistry.all.filter { !Self.isHidden($0) }
            : []
        let ids = descriptors.map { $0.id }
        Log.debug("StatusBar", "sync: descriptors=\(descriptors.count) ids=\(ids) lastIDs=\(lastIDs)")
        guard ids != lastIDs else { refreshTitles(); return }
        rebuild(descriptors)
    }

    /// 该项是否被注册方标记为隐藏（title 带隐藏标记前缀）
    private static func isHidden(_ d: StatusItemDescriptor) -> Bool {
        if d.title().hasPrefix(hiddenMarker) { return true }
        if let attr = d.attributedTitle?(), attr.string.hasPrefix(hiddenMarker) { return true }
        // 双层项：返回 nil 视为隐藏（如读不到功耗数据）
        if let twoLine = d.twoLineTitle { return twoLine() == nil }
        return false
    }

    /// 诊断：打印状态项按钮的真实窗口位置/尺寸（系统布局结果）。
    /// 2026-10-16 排障：双层项日志 img=true/visible=true 但菜单栏不可见，
    /// 需区分「系统没给位置（frame 为零/屏幕外）」与「有位置但渲染异常」。
    static func diagnose(_ id: String, button: NSStatusBarButton, item: NSStatusItem) {
        let frame = button.window?.frame ?? .zero
        let imgSize = button.image?.size ?? .zero
        let inScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
        Log.info("StatusBar", "diag \(id): frame=\(frame) imgSize=\(imgSize) imgPos=\(button.imagePosition.rawValue) title='\(button.title)' hidden=\(button.isHidden) winVis=\(button.window?.isVisible ?? false) alpha=\(button.alphaValue) onScreen=\(inScreen) screens=\(NSScreen.screens.count)")
    }

    // MARK: 状态项位置持久化（STATS save/restoreNSStatusItemPosition 同款）
    //
    // 系统在 removeStatusItem 时会**删除**该 autosaveName 的
    // 「NSStatusItem Preferred Position <id>」键；不先备份的话，重建出来的项
    // 拿不到原位置，只能落到默认位——与别家状态项重叠（2026-10-16 实证：
    // 四个双层项 frame 互相叠在一起、菜单栏只看到一个残影）。
    // STATS 的解法：移除前把位置存到自家键，重建后写回系统键。
    //
    // autosaveName 带「frsetnext.」前缀：与原版 Frset.app 的状态项同名 id
    // （monitor.* / main）隔离——2026-10-16 实证两版共存时同名 autosaveName
    // 会让系统拒绝为后注册的项布局（frame=(0,0,w,0)，菜单栏不显示），
    // 前缀后两版可同时运行、各自管理位置。

    /// 状态项在系统位置存储中的唯一名（autosaveName + 位置键共用）
    static func statusItemName(_ id: String) -> String { "frsetnext.\(id)" }

    private static func saveStatusItemPosition(id: String) {
        let name = Self.statusItemName(id)
        guard let position = UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position \(name)") as? NSNumber else { return }
        UserDefaults.standard.set(position.intValue, forKey: "NSStatusItem Restore Position \(name)")
    }

    private static func restoreStatusItemPosition(id: String) {
        let name = Self.statusItemName(id)
        let prev = UserDefaults.standard.integer(forKey: "NSStatusItem Restore Position \(name)")
        guard prev != 0 else { return }
        UserDefaults.standard.set(prev, forKey: "NSStatusItem Preferred Position \(name)")
        UserDefaults.standard.removeObject(forKey: "NSStatusItem Restore Position \(name)")
    }

    private func rebuild(_ descriptors: [StatusItemDescriptor]) {
        teardownItems()
        let visible = Array(descriptors.prefix(Self.maxVisibleItems))
        // 反向创建：系统把每个新状态项插到已有项的左侧，创建序与显示序相反。
        // 描述符序已是「功耗首位」（power, cpu, network, memory），反向创建后
        // 菜单栏显示序即功耗在最左（2026-10-16 用户需求：功耗项排首位）。
        // 主图标在 installMainItem 中最先创建 → 落在本组最右（与原版布局一致）。
        let creationOrder = Array(visible.reversed())
        entries = creationOrder.map { d in
            let (item, view) = makeStatusItem(for: d)
            let entry = StatusItemEntry(descriptor: d, item: item, twoLineView: view)
            item.isVisible = true      // 防系统/持久化隐藏（2026-10-16 实证动态项全部不可见）
            return entry
        }
        let rest = Array(descriptors.dropFirst(Self.maxVisibleItems))
        overflowDescriptors = rest
        if rest.isEmpty {
            overflowItem = nil
        } else {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = Self.overflowTitle
            item.button?.font = NSFont.menuBarFont(ofSize: 13)
            item.button?.toolTip = "更多状态项"
            let menu = NSMenu()
            menu.delegate = self                  // 打开时按最新数据重建（见 menuNeedsUpdate）
            item.menu = menu
            overflowItem = item
        }
        lastIDs = descriptors.map { $0.id }
        refreshTitles()
        Log.info("StatusBar", "synced: visible=\(visible.count) overflow=\(rest.count)")
    }

    /// 创建状态项；双层项返回其内容视图（STATS 模式：子视图 + 定长 + 空图占位）
    private func makeStatusItem(for d: StatusItemDescriptor) -> (NSStatusItem, MenuBarTwoLineView?) {
        var twoLineView: MenuBarTwoLineView?
        // 双层项：先建视图、按当前内容量出宽度，状态项长度=视图宽（v1「<<」裁剪根因修复）
        if let pair = d.twoLineTitle?() {
            let v = MenuBarTwoLineView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
            v.setTexts(pair.0, pair.1)
            v.setFrameSize(NSSize(width: v.contentWidth, height: v.frame.height))
            twoLineView = v
        }
        // 恢复系统位置键（必须在创建前写回，STATS 同款顺序）
        Self.restoreStatusItemPosition(id: d.id)
        let item = NSStatusBar.system.statusItem(withLength: twoLineView?.frame.width ?? NSStatusItem.variableLength)
        // 固定 autosaveName（带 frsetnext. 前缀，与原版隔离）：系统按名持久化
        // 位置/可见性，避免无名项按创建计数器累加（Item-N 无限增长）导致布局状态漂移
        item.autosaveName = Self.statusItemName(d.id)
        item.button?.font = NSFont.menuBarFont(ofSize: 11)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp])
        item.button?.toolTip = d.id
        if let view = twoLineView, let button = item.button {
            button.image = NSImage()              // 空图占位：无图按钮不绘制子视图（STATS 实证）
            button.addSubview(view)
            // 按钮内垂直居中；尺寸未定时靠四向弹性边距自动保持居中
            let y = max(2, (button.bounds.height - view.frame.height) / 2)
            view.frame = NSRect(x: 0, y: y, width: view.frame.width, height: view.frame.height)
            view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        }
        // 单行项才设 title——双层项内容由子视图呈现，同时设 title 会重叠成多行堆叠
        if d.twoLineTitle == nil {
            item.button?.title = d.title()
        }
        if let button = item.button { Self.diagnose(d.id, button: button, item: item) }
        return (item, twoLineView)
    }

    private func teardownItems() {
        currentPopover?.close(); currentPopover = nil
        // 先备份系统位置键再移除（系统会删除它，见 saveStatusItemPosition 注释）
        for e in entries {
            Self.saveStatusItemPosition(id: e.descriptor.id)
            NSStatusBar.system.removeStatusItem(e.item)
        }
        entries = []
        if let overflow = overflowItem { NSStatusBar.system.removeStatusItem(overflow) }
        overflowItem = nil
        overflowDescriptors = []
    }

    // MARK: 刷新

    private func refreshTitles() {
        guard Thread.isMainThread else { return }
        let probe = Self.perfProbe
        let t0 = probe ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if probe {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                if ms >= 0.5 {
                    Log.info("Perf", String(format: "refreshTitles %.2fms entries=%d", ms, entries.count))
                }
            }
        }
        var needsResync = false
        for e in entries {
            // 运行中被标记隐藏（两次同步之间）：先就地隐藏，再触发同步释放名额
            if Self.isHidden(e.descriptor) {
                if e.item.isVisible { e.item.isVisible = false }
                needsResync = true
                continue
            }
            if !e.item.isVisible { e.item.isVisible = true }
            // 双层项：更新自定义视图的两行文本；宽度只增不减，避免每秒重排
            if let pair = e.descriptor.twoLineTitle?() {
                if let view = e.twoLineView {
                    view.setTexts(pair.0, pair.1)
                    let w = view.contentWidth
                    if w > view.frame.width + 0.5 {
                        view.setFrameSize(NSSize(width: w, height: view.frame.height))
                        e.item.length = w
                        view.widthHandler?()
                    }
                }
                continue
            }
            guard let button = e.item.button else { continue }
            if let attributed = e.descriptor.attributedTitle?() {
                button.attributedTitle = attributed
            } else {
                let text = e.descriptor.title()
                if button.title != text { button.title = text }
            }
        }
        // 「更多」聚合项：其下全部被隐藏时一并隐藏
        if let overflow = overflowItem {
            let hasVisible = overflowDescriptors.contains { !Self.isHidden($0) }
            if overflow.isVisible != hasVisible { overflow.isVisible = hasVisible }
            if !hasVisible { needsResync = true }
        }
        // 有项被隐藏 → 重建名额；**异步**跳出当前栈：2026-10-16 崩溃实证，
        // 同步递归（refresh → isVisible 变更 → UserDefaults 通知 → observePreferences
        // → syncStatusItems → refresh …）会导致栈溢出（EXC_BAD_ACCESS at stack guard）。
        if needsResync { DispatchQueue.main.async { [weak self] in self?.syncStatusItems() } }
        verifyLayout(tag: "refresh")
    }

    /// 布局核验：系统每给状态项分配/改变窗口框架就记录一次（含无效框架 (0,0,w,0)）。
    /// 2026-10-16 排障「原版 app 运行时动态项不显示」：区分「系统没布局」
    /// 「布局到屏幕外」「有框架仍不渲染」三种状态。
    private func verifyLayout(tag: String) {
        if let main = mainItem, let button = main.button {
            let frame = button.window?.frame ?? .zero
            let key = "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
            if lastLayoutKeys["main"] != key {
                lastLayoutKeys["main"] = key
                Log.debug("StatusBar", "layout[\(tag)] main: frame=\(frame) len=\(main.length) vis=\(main.isVisible) hidden=\(button.isHidden) subviews=\(button.subviews.count)")
            }
        }
        for e in entries {
            guard let button = e.item.button else { continue }
            let frame = button.window?.frame ?? .zero
            let key = "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
            guard lastLayoutKeys[e.descriptor.id] != key else { continue }
            lastLayoutKeys[e.descriptor.id] = key
            Log.debug("StatusBar", "layout[\(tag)] \(e.descriptor.id): frame=\(frame) len=\(e.item.length) vis=\(e.item.isVisible) hidden=\(button.isHidden) subviews=\(button.subviews.count)")
        }
    }

    // MARK: 交互

    @objc private func mainItemClicked(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else { return }
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        // v83（2026-10-20 用户需求「点开面板不要弹表情+英文」）：
        // 原「连续单击主图标 10 次解锁」彩蛋（第 1 次必弹
        // "🤫 This is not a button. Probably." 气泡）已整体移除——
        // 该彩蛋是原版付费墙拒绝计数的移植产物，与重建版产品定位无关，
        // 且首次点击就打气泡、干扰正常使用（用户实测反馈）。
        // 自定义菜单栏图标功能保留（门控去掉，见 StatusBarMenuBuilder）。
        if isRightClick {
            let menu = StatusBarMenuBuilder.mainMenu(target: self)
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 6),
                       in: button)
        } else {
            // v73：主图标左键 → 锚点展开（面板停到图标正下方 + 三角指示器 + 长出来动画）
            ServiceLocator.panel?.toggle(atAnchor: button.window?.frame)
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton,
              let entry = entries.first(where: { $0.item.button === button }) else { return }
        handle(descriptor: entry.descriptor, anchor: button)
    }

    @objc private func overflowItemAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let d = overflowDescriptors.first(where: { $0.id == id }),
              let button = overflowItem?.button else { return }
        handle(descriptor: d, anchor: button)
    }

    /// 点击行为：优先 onTap，其次 popover，最后回落为打开主面板
    private func handle(descriptor d: StatusItemDescriptor, anchor button: NSStatusBarButton) {
        if let onTap = d.onTap {
            onTap()
            return
        }
        if let build = d.popover {
            showPopover(build(), relativeTo: button)
            return
        }
        // v73：回落打开主面板也走锚点展开（在该部件正下方）
        ServiceLocator.panel?.toggle(atAnchor: button.window?.frame)
    }

    private func showPopover(_ view: AnyView, relativeTo button: NSStatusBarButton) {
        currentPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient                 // 点击外部自动关闭
        popover.animates = true
        popover.delegate = self
        // v74（用户反馈「两套界面/时间不一样」）：popover 与主页性能页统一——
        // 尺寸 292×260 → 340×620（接近主面板 360×630，同一信息密度），
        // 打开期间提升采样频率到用户间隔（隐藏态默认 ≥5s 会让数值显得"不走"）。
        popover.contentSize = NSSize(width: 340, height: 620)
        popover.contentViewController = NSHostingController(rootView: view)
        MonitorSampler.shared.setSettingsActive(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        currentPopover = popover
    }

    /// STATS 部件引擎的部件点击 → 监测详情 popover（锚点 = 合并条按钮）。
    /// 与状态项点击同一套呈现（transient + 主面板同宽）；深数据页较长，
    /// 按内容实际高度自适应（上限 = 屏幕可用高度 - 边距）。
    public func presentStatsPopover(_ view: AnyView, anchor button: NSStatusBarButton) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.presentStatsPopover(view, anchor: button) }
            return
        }
        currentPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: view)
        host.view.layoutSubtreeIfNeeded()
        let fitting = host.view.fittingSize
        let maxHeight = (button.window?.screen?.visibleFrame.height ?? 800) - 36
        popover.contentSize = NSSize(
            width: max(Theme.panelWidth, fitting.width),
            height: min(max(fitting.height, 200), maxHeight)
        )
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        currentPopover = popover
    }

    // MARK: 菜单动作（StatusBarMenuBuilder 组装的菜单目标）

    @objc func openPanelAction(_ sender: Any?) {
        // v73：菜单唤起也停到主图标正下方（与左键点击一致）
        ServiceLocator.panel?.show(atAnchor: mainItem?.button?.window?.frame)
    }

    @objc func openSettingsAction(_ sender: Any?) { ServiceLocator.settings?.open(pane: nil) }

    @objc func openMonitorSettingsAction(_ sender: Any?) {
        ServiceLocator.settings?.open(pane: "monitor")
    }

    /// v180：归档任务详情（压缩/解压队列）
    @objc func openArchiveTasksAction(_ sender: Any?) {
        ArchiveProgressWindowController.show()
    }

    /// 代码预览窗（代码美化：换主题/语言 + 复制富文本，可直接粘进 Word）
    @objc func openCodePreviewAction(_ sender: Any?) {
        CodePreviewWindowController.shared.openFromPasteboardOrSample()
    }

    /// 欢迎与权限引导（重建版 onboarding：欢迎窗 + 权限引导窗手动入口）
    @objc func showOnboardingAction(_ sender: Any?) {
        WelcomeWindowController.shared.show()
    }

    /// 检查更新（v112：手动检查，feed 在 设置 → 关于 配置）
    @objc func checkForUpdatesAction(_ sender: Any?) {
        AppUpdateChecker.shared.checkNowManual()
    }

    @objc func toggleMonitorModuleAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let module = MonitorModuleID(rawValue: rawValue) else { return }
        MonitorPreferences.setModuleEnabled(module, !MonitorPreferences.isModuleEnabled(module))
        syncStatusItems()
    }

    @objc func toggleMonitorCombinedAction(_ sender: NSMenuItem) {
        MonitorPreferences.combinedMode.toggle()
        syncStatusItems()
    }

    /// 打开统计窗（spec 17 S1/S2：打开即埋点 statistics_open，埋点在 StatisticsWindowController.openStatistics 内）
    @objc func showStatisticsAction(_ sender: Any?) {
        StatisticsWindowController.shared.openStatistics()
    }

    @objc func toggleIconsAction(_ sender: NSMenuItem) {
        let next = !Preferences.shared.menuBarIconsVisible
        Preferences.shared.menuBarIconsVisible = next
        syncStatusItems()
        Toast.show(next ? "已显示菜单栏状态项" : "已隐藏菜单栏状态项", icon: "menubar.rectangle")
    }

    @objc func quitAction(_ sender: Any?) { NSApp.terminate(nil) }
}

// MARK: - NSPopoverDelegate / NSMenuDelegate

extension StatusBarController: NSPopoverDelegate, NSMenuDelegate {
    public func popoverDidClose(_ notification: Notification) {
        currentPopover = nil
        // v74：popover 关闭 → 恢复隐藏态降频（与打开时的提升配对）
        MonitorSampler.shared.setSettingsActive(false)
    }

    /// 「更多」菜单：每次打开按最新数据重建
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === overflowItem?.menu else { return }
        menu.removeAllItems()
        // 隐藏项不出现在「更多」菜单里
        for d in overflowDescriptors where !Self.isHidden(d) {
            let item = NSMenuItem(title: d.title(),
                                  action: #selector(overflowItemAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = d.id
            menu.addItem(item)
        }
    }
}
