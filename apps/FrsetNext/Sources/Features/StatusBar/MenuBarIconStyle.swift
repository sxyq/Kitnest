import AppKit
import Foundation

// MARK: - 菜单栏图标样式（spec 13 §6 / §7）
//
// 还原原作四项图标样式偏好键（spec §6.1 实证键名）与动态风扇图标：
// - logo   → 应用内置 SF Symbol「square.stack.3d.up」（模板图，随菜单栏明暗变色）；
// - fan    → 风扇图标，RotatingLayerView 上 CABasicAnimation("transform.rotation.z") 无限旋转，
//            转速随系统 CPU 负载动态调整（对应原作 StatusBarController currentRotationDuration /
//            currentSpeedLevel；重建版无同名字段，在此以 applier 内的 currentRotationDuration 等价实现）；
// - date   → 显示当前日期（原作 ⬜ 渲染细节未探明，取 M/d，⬜ 见 spec §11.6）；
// - custom → 用户指定的 SF Symbol 名（解锁彩蛋后才在菜单/设置里出现，对应 revealCustomMenuBarIconOption）。
//
// 偏好键沿用原作键名（spec §6.1）：menu-bar-icon-logo / -fan / -date / -custom；
// ⬜ 原作是否为「四布尔键」还是「单枚举键」未探明，重建版采用四布尔键（与原作键名一一对应）。

// MARK: - 样式枚举

/// 菜单栏主图标样式（对应原作 menu-bar-icon-* 四键）
enum MenuBarIconStyle: String, CaseIterable {
    case logo, fan, date, custom

    /// 偏好键（spec §6.1 实证键名）
    var preferenceKey: String {
        switch self {
        case .logo:   return "menu-bar-icon-logo"
        case .fan:    return "menu-bar-icon-fan"
        case .date:   return "menu-bar-icon-date"
        case .custom: return "menu-bar-icon-custom"
        }
    }

    var title: String {
        switch self {
        case .logo:   return "Logo"
        case .fan:    return "动态风扇"
        case .date:   return "日期"
        case .custom: return "自定义图标"
        }
    }

    var subtitle: String {
        switch self {
        case .logo:   return "应用图标"
        case .fan:    return "图标转速随 CPU 使用率动态调整"
        case .date:   return "在菜单栏显示当前日期"
        case .custom: return "使用自定义 SF Symbol 图标"
        }
    }

    var systemImage: String {
        switch self {
        case .logo:   return "square.stack.3d.up"
        case .fan:    return "fan"
        case .date:   return "calendar"
        case .custom: return "wand.and.stars"
        }
    }
}

// MARK: - 样式偏好存储

/// 图标样式偏好的读写（键名见 MenuBarIconStyle.preferenceKey）
enum MenuBarIconStyleStore {

    /// 自定义 Symbol 名（⬜ 原作键名未探明，此处自定 menu-bar-icon-custom-symbol，注释标明）
    static let customSymbolKey = "menu-bar-icon-custom-symbol"
    /// 设置页是否显示自定义选项（原作 revealCustomMenuBarIconOption，0x1005eeabc）
    static let revealCustomOptionKey = "revealCustomMenuBarIconOption"
    /// custom 缺省 Symbol（未指定时的兜底）
    static let defaultCustomSymbol = "sparkles"

    /// 当前选中的样式：四个布尔键中唯一置 true 者；全 false / 多 true 时按 CaseIterable 序取首个
    static var current: MenuBarIconStyle {
        for style in MenuBarIconStyle.allCases
        where UserDefaults.standard.bool(forKey: style.preferenceKey) {
            return style
        }
        return .logo
    }

    /// 选中某样式：清掉其余三键，只置目标键
    static func select(_ style: MenuBarIconStyle) {
        let defaults = UserDefaults.standard
        for candidate in MenuBarIconStyle.allCases {
            defaults.set(candidate == style, forKey: candidate.preferenceKey)
        }
        Log.info("StatusBar", "菜单栏图标样式切换为 \(style.rawValue)")
    }

    /// 是否显示「自定义图标」选项（对应原作 revealCustomMenuBarIconOption，0x1005eeabc）
    /// v83：解锁门控随彩蛋机制移除——自定义图标是常规功能，未落盘时默认展示，
    /// 仅由 hide/restore 的显式开关控制。
    static var revealsCustomOption: Bool {
        UserDefaults.standard.object(forKey: revealCustomOptionKey) as? Bool ?? true
    }

    /// 写入 revealCustomMenuBarIconOption（hide / restore 对话框的落点）
    static func setRevealsCustomOption(_ reveals: Bool) {
        UserDefaults.standard.set(reveals, forKey: revealCustomOptionKey)
    }

    /// 当前自定义 Symbol 名（设置页经 @AppStorage 直接写 customSymbolKey，此处只读）
    static var customSymbol: String {
        let raw = UserDefaults.standard.string(forKey: customSymbolKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultCustomSymbol : trimmed
    }
}

// MARK: - 旋转图层视图（spec 13 §7 RotatingLayerView）

/// 承载旋转图标的 NSView：内部 NSImageView 显示模板图，整体图层做 transform.rotation.z 无限旋转。
/// 字段名沿用原作语义（spec §2 字段表：imageLayer / storedDuration / isTemplateImage 等）。
final class RotatingLayerView: NSView {

    /// 当前旋转周期（秒），由 CPU 负载驱动（对应原作 currentRotationDuration）
    private(set) var storedDuration: CFTimeInterval = RotatingLayerView.slowestDuration

    private let imageView = NSImageView()
    // v49：回归 CABasicAnimation（Core Animation 渲染线程驱动，主线程零逐帧开销）。
    // v46 的 60fps Timer 逐帧写 layer.transform 实测每帧都触发 NSViewBackingLayer
    // display 整视图位图重绘（sample 实测占主线程 Timer 时间的约 1/3），与引擎部件
    // 刷新叠加后菜单栏明显卡顿——废弃该方案。v46 要解决的"相位跳变"改由
    // 「变速时从 presentation 当前角度续接」解决：读 presentation 角度 → remove 旧
    // 动画 → 模型层同步该角度 → 新动画 from=当前角 to=当前角+2π、duration=新周期。
    private var spinRunning = false

    /// 转速档位边界：负载 0 → 最慢，负载 1 → 最快
    static let slowestDuration: CFTimeInterval = 4.0
    static let fastestDuration: CFTimeInterval = 0.6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        // 四向弹性边距：按钮宽度变化时保持在按钮内居中（2026-10-16）
        autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
        autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
    }

    /// 设置旋转中的图标（模板图）
    func setSymbol(_ name: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(config) else { return }
        // v56（用户：风车没有中心点）：SF Symbol 的轴心是**空心环**——合成一个
        //   实心圆点补上。模板图渲染（alpha 决定形状），颜色随菜单栏明暗自动反相。
        let size = NSSize(width: 18, height: 18)
        let composed = NSImage(size: size, flipped: false) { rect in
            let natural = base.size
            let drawRect = NSRect(x: rect.midX - natural.width / 2,
                                  y: rect.midY - natural.height / 2,
                                  width: natural.width,
                                  height: natural.height)
            base.draw(in: drawRect)
            let d: CGFloat = 3.0
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2,
                                        width: d, height: d)).fill()
            return true
        }
        composed.isTemplate = true
        imageView.image = composed
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        // v49 修复「公转」：macOS 上 NSView 托管 layer 的默认 anchorPoint 是 (0,0)
        // （左下角），不像 iOS 是中心——逐帧/动画旋转时图标整体绕角点打转（用户实测
        // 反馈"绕着一个点旋转，类似公转"）。改为绕中心：anchorPoint=(0.5,0.5) 且
        // position=视图中心，同帧修正（禁隐式动画防跳）。
        guard let l = layer, bounds.width > 0.5, bounds.height > 0.5 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if l.anchorPoint.x != 0.5 || l.anchorPoint.y != 0.5 {
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
        let target = CGPoint(x: bounds.midX, y: bounds.midY)
        if abs(l.position.x - target.x) > 0.25 || abs(l.position.y - target.y) > 0.25 {
            l.position = target
        }
        CATransaction.commit()
    }

    /// 设置旋转周期并立即生效（v49：变速从当前相位续接，不重置相位）
    func setRotationDuration(_ duration: CFTimeInterval) {
        let clamped = min(max(duration, Self.fastestDuration), Self.slowestDuration)
        guard abs(clamped - storedDuration) > 0.01 else { return }
        storedDuration = clamped
        guard spinRunning, let l = layer, l.animation(forKey: "spin") != nil else { return }
        // presentation 当前角度（考虑在飞动画；无展示层时退回模型层）
        let current = (l.presentation() ?? l).value(forKeyPath: "transform.rotation.z") as? CGFloat ?? 0
        l.removeAnimation(forKey: "spin")
        applyRotation(duration: clamped, resumeFrom: current)
    }

    /// 挂载一圈旋转动画（v49：CA 渲染线程插值，主线程零逐帧开销）
    private func applyRotation(duration: CFTimeInterval, resumeFrom: CGFloat) {
        guard let l = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 模型层同步到续接角度：动画移除/窗口重建时不会跳回 0°
        l.transform = CATransform3DMakeRotation(resumeFrom, 0, 0, 1)
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = resumeFrom
        anim.toValue = resumeFrom + 2 * CGFloat.pi
        anim.duration = duration
        // v155：连续旋转必须匀速。此前没有 timingFunction，CA 套的是默认曲线
        // （≈CSS ease）——每圈都「先加速再减速」，接缝处速度从 0 跳回最大，
        // 观感就是转一下喘一口气。linear 让位置与速度在接缝两侧都连续。
        anim.timingFunction = Theme.Motion.caLinear
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        l.add(anim, forKey: "spin")
        CATransaction.commit()
    }

    /// 开始旋转（v49：单条 CABasicAnimation 无限循环）
    func spin() {
        guard layer != nil, !spinRunning else { return }
        spinRunning = true
        applyRotation(duration: storedDuration, resumeFrom: 0)
    }

    /// 停止旋转（样式切走时调用）
    func stop() {
        spinRunning = false
        layer?.removeAnimation(forKey: "spin")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}

// MARK: - 菜单动作

/// 主菜单里「自定义菜单栏图标…」的动作宿主。
/// 独立成类而非挂在 StatusBarController 上：主控制器不在本轮改动范围内。
final class MenuBarIconStyleMenuActions: NSObject {

    static let shared = MenuBarIconStyleMenuActions()

    /// 选中某种图标样式（子菜单单选）
    @objc func selectIconStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = MenuBarIconStyle(rawValue: raw) else { return }
        MenuBarIconStyleStore.select(style)
        MenuBarIconStyleApplier.shared.refresh()
    }

    /// 打开设置页的「通用」页签（图标样式区在菜单栏分节内）
    @objc func openCustomIconSettings(_ sender: Any?) {
        MenuBarIconStyleApplier.shared.refresh()
        ServiceLocator.settings?.open(pane: "general")
    }

    /// 隐藏自定义图标选项（v83：原彩蛋 hide 对话框随彩蛋机制一并移除，直接执行）
    @objc func hideIconOption(_ sender: Any?) {
        MenuBarIconStyleStore.setRevealsCustomOption(false)
        toastHidden()
    }

    private func toastHidden() {
        Toast.show("已隐藏自定义菜单栏图标", icon: "eye.slash")
    }

    /// 恢复自定义图标选项（v83：原彩蛋 restore 对话框随彩蛋机制一并移除，直接执行）
    @objc func restoreIconOption(_ sender: Any?) {
        MenuBarIconStyleStore.setRevealsCustomOption(true)
        MenuBarIconStyleApplier.shared.refresh()
        Toast.show("已恢复自定义菜单栏图标选项", icon: "checkmark.circle.fill")
    }
}

// MARK: - CPU 负载采样

/// 系统 CPU 负载采样（host_processor_info + PROCESSOR_CPU_LOAD_INFO，负载 0…1）。
/// 原作转速↔CPU 映射表⬜ 未探明（spec §11.4），此处按线性映射实现最小版。
enum SystemCPULoad {

    /// 上一次采样的累计 ticks（v56：原来直接拿累计值相除 = 开机以来平均负载，几乎恒定，
    /// 风车转速因此看不出变化。改为「两次采样差值」得到区间占用）
    private static var lastTotals: (user: Double, system: Double, idle: Double)?
    private static var ema: Double = 0

    /// 读取一次区间 CPU 负载（0…1）；首次调用无历史 → 返回 0（下次开始有效）
    static func current() -> Double {
        guard let totals = readTotals() else { return ema }
        defer { lastTotals = totals }
        guard let prev = lastTotals else { return ema }
        let du = totals.user - prev.user
        let ds = totals.system - prev.system
        let di = totals.idle - prev.idle
        let total = du + ds + di
        guard total > 0 else { return ema }
        let instant = min(max((du + ds) / total, 0), 1)
        // 平滑：0.6 旧 + 0.4 新（与小猫的 EMA 同思路，但响应更快一点）
        ema = ema * 0.6 + instant * 0.4
        return ema
    }

    private static func readTotals() -> (user: Double, system: Double, idle: Double)? {
        var processorCount: mach_msg_type_number_t = 0
        var infoCount: mach_msg_type_number_t = 0
        var infoArray: processor_info_array_t?
        let kernelResult = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                              &processorCount, &infoArray, &infoCount)
        guard kernelResult == KERN_SUCCESS, let infoArray, infoCount > 0 else { return nil }
        defer {
            // host_processor_info 分配的内存需显式释放
            let byteCount = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: infoArray)), byteCount)
        }
        let loads = UnsafeMutableRawPointer(infoArray).assumingMemoryBound(to: processor_cpu_load_info.self)
        var user: Double = 0
        var system: Double = 0
        var idle: Double = 0
        for i in 0..<Int(infoCount) {
            user += Double(loads[i].cpu_ticks.0)
            system += Double(loads[i].cpu_ticks.1)
            idle += Double(loads[i].cpu_ticks.2)
        }
        let total = user + system + idle
        guard total > 0 else { return nil }
        return (user, system, idle)
    }
}

// MARK: - 样式应用器

/// 把选中的样式应用到主状态项按钮（ToastAnchor.button，即 StatusBarController 安装的主图标）。
/// 应用器观察图标样式变化；date/fan 两种动态样式另起轻量定时器。
final class MenuBarIconStyleApplier {

    static let shared = MenuBarIconStyleApplier()

    /// date 样式刷新间隔（跨日/跨分钟）
    private static let dateRefreshInterval: TimeInterval = 60
    /// CPU 采样间隔
    private static let cpuSampleInterval: TimeInterval = 2
    /// fan 样式状态项固定宽度（容纳 18pt 旋转视图 + 左右留白）
    static let fanItemLength: CGFloat = 30
    /// fan 旋转视图边长
    static let fanViewSize: CGFloat = 18

    private var defaultsObservation: NSObjectProtocol?
    private var dateTimer: Timer?
    private var cpuTimer: Timer?
    private var rotatingView: RotatingLayerView?
    private var appliedStyle: MenuBarIconStyle?
    private var appliedCustomSymbol: String?
    /// 当前旋转周期（等价原作 StatusBarController.currentRotationDuration 字段）
    private(set) var currentRotationDuration: CFTimeInterval = RotatingLayerView.slowestDuration

    private init() {}

    // MARK: 生命周期

    func start() {
        guard defaultsObservation == nil else { return }
        defaultsObservation = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.apply()
        }
        // v82：小猫开关变化 → 强制重应用样式（apply 有“样式未变就跳过”守卫，
        // 这里先清空 applied 状态，确保关闭小猫后原图标/宽度立即恢复）。
        NotificationCenter.default.addObserver(
            forName: Notification.Name("FrsetRunCatIconChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.appliedStyle = nil
            self.appliedCustomSymbol = nil
            self.apply()
        }
        apply()
        // 主状态项按钮由 StatusBarController.installMainItem 登记锚点；
        // 若启动瞬间按钮尚未就绪，下一拍补一次应用
        if appliedStyle == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.apply() }
        }
    }

    /// 样式键变化时刷新（供设置页/菜单在写入后主动调一次，保证无观察者时也生效）
    func refresh() { apply() }

    // MARK: 应用

    private func apply() {
        let style = MenuBarIconStyleStore.current
        let customSymbol = style == .custom ? MenuBarIconStyleStore.customSymbol : nil
        guard let button = ToastAnchor.button else {
            Log.info("StatusBar", "iconStyle apply 跳过：锚点按钮未就绪")
            return
        }
        // 窗口尺寸保存也会发送偏好通知；图标未变时保持现有按钮布局和动画。
        guard appliedStyle != style || appliedCustomSymbol != customSymbol else { return }
        appliedStyle = style
        appliedCustomSymbol = customSymbol
        stopTimers()
        stopRotating()
        Log.info("StatusBar", "iconStyle 应用：\(style.rawValue)")

        switch style {
        case .logo, .custom:
            let symbol = style == .logo ? MenuBarIconStyle.logo.systemImage : customSymbol!
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Kitnest")
            image?.isTemplate = true
            button.image = image
            button.title = ""
            button.toolTip = "Kitnest（右键查看更多）"
            StatusBarController.shared.setMainItemLength(NSStatusItem.variableLength)
        case .date:
            button.image = nil
            button.title = Self.dateFormatter.string(from: Date())
            button.toolTip = "Kitnest（右键查看更多）"
            StatusBarController.shared.setMainItemLength(NSStatusItem.variableLength)
            startDateTimer()
        case .fan:
            // 空图占位：无图按钮不绘制子视图（STATS 实证，同双层项做法）；
            // 2026-10-16 之前此处设 nil，导致旋转视图整个不渲染、主图标不可见
            button.image = NSImage()
            button.title = ""
            button.toolTip = "Kitnest（动态风扇）"
            // 固定宽度容纳 18pt 旋转视图（variableLength 会把按钮压到只剩几个点，
            // 子视图被裁剪成「<<」状残影，2026-10-16 实证）
            StatusBarController.shared.setMainItemLength(Self.fanItemLength)
            startFan(on: button)
            Log.info("StatusBar", "iconStyle fan：length=\(Self.fanItemLength) itemLength=\(StatusBarController.shared.mainItemLength.map { String(describing: $0) } ?? "nil") bounds=\(button.bounds)")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    // MARK: date 定时器

    private func startDateTimer() {
        let timer = Timer(timeInterval: Self.dateRefreshInterval, repeats: true) { _ in
            // v128（流畅度）：回调体进 autoreleasepool（格式化临时对象随回调排空）
            autoreleasepool {
                guard let button = ToastAnchor.button else { return }
                button.title = Self.dateFormatter.string(from: Date())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dateTimer = timer
    }

    // MARK: fan 定时器 + 旋转视图

    private func startFan(on button: NSStatusBarButton) {
        let size = NSSize(width: Self.fanViewSize, height: Self.fanViewSize)
        let view = RotatingLayerView(frame: NSRect(origin: .zero, size: size))
        view.setSymbol(MenuBarIconStyle.fan.systemImage)
        // 挂到状态项按钮内（imagePosition 需为 noImage，避免与内置 image 叠加）
        button.imagePosition = .noImage
        button.addSubview(view)
        // 约束居中：不依赖 apply 瞬间的 button.bounds（那一刻按钮可能还没布局），
        // 按钮随后被系统拉到 30pt 宽时视图仍保持居中（2026-10-16 修复：
        // 此前按当时 bounds 手算 frame，布局后偏移/裁剪导致风扇不可见）
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: size.width),
            view.heightAnchor.constraint(equalToConstant: size.height),
        ])
        rotatingView = view
        view.spin()

        // 布局后核验：按钮真实宽度 / 子视图是否就位 / 窗口是否可见
        // （2026-10-16 主图标不可见排障：区分「按钮零宽」与「有位置不渲染」）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak button] in
            guard let b = button else { return }
            Log.info("StatusBar", "fan 布局核验：bounds=\(b.bounds) 子视图=\(b.subviews.count) 窗口=\(b.window?.frame ?? .zero) 可见=\(b.window?.isVisible ?? false)")
        }

        let timer = Timer(timeInterval: Self.cpuSampleInterval, repeats: true) { [weak self] _ in
            // v128（流畅度）：回调体进 autoreleasepool（CPU 采样的临时对象随回调排空）
            autoreleasepool { self?.updateFanSpeed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cpuTimer = timer
        updateFanSpeed()
    }

    /// 按当前 CPU 负载分档映射旋转周期（v56：与小猫同一套 7 档思路——离散档位，
    /// 负载越高转得越快，肉眼能看出变化；连续线性映射在 20%–40% 区间几乎看不出差别）
    private func updateFanSpeed() {
        let load = SystemCPULoad.current()
        let duration: CFTimeInterval
        switch load {
        case ..<0.10: duration = 4.0
        case ..<0.25: duration = 3.2
        case ..<0.40: duration = 2.6
        case ..<0.55: duration = 2.0
        case ..<0.70: duration = 1.5
        case ..<0.85: duration = 1.1
        default:      duration = 0.8
        }
        currentRotationDuration = duration
        rotatingView?.setRotationDuration(duration)
        // 换档才记日志（排障/验收用：CPU 升高应看到 duration 变小）
        if abs(duration - Self.lastLoggedDuration) > 0.01 {
            Self.lastLoggedDuration = duration
            Log.info("StatusBar", String(format: "fan 转速换档：CPU %.0f%% → 周期 %.1fs", load * 100, duration))
        }
    }

    /// 上次记录的档位周期（日志节流）
    private static var lastLoggedDuration: CFTimeInterval = -1

    // MARK: 收尾

    private func stopRotating() {
        rotatingView?.stop()
        rotatingView?.removeFromSuperview()
        rotatingView = nil
        if let button = ToastAnchor.button { button.imagePosition = .imageOnly }
    }

    private func stopTimers() {
        dateTimer?.invalidate(); dateTimer = nil
        cpuTimer?.invalidate(); cpuTimer = nil
    }
}
