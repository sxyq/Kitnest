import SwiftUI

// MARK: - 设置导航：一级目录 + 二级页（v272）
//
// 用户（2026-11-09）：「第一页的常规也需要进行拆分，剪贴板、文件中转，这些全部都是
// 作为一个一级目录存在，然后下面放一些二级目录的菜单，包括常规这一栏的这些个性化，
// 这些设置全都要进行拆分。」
//
// 旧模型：`SettingsSidebarSelection` 有 6 个互不相干的 case（分类 / 截图块 / 监测模块 /
// 监测设置 / 部件设置 / 手动），侧边栏靠「分组标题 + 特判」拼出来，「常规」「剪贴板」
// 「文件中转」各自仍是一整页长滚动——一级目录只是视觉分组，没有真正的二级页。
//
// 新模型：
//   · `SettingsGroup`  = 一级目录（常规 / 音频 / 剪贴板 / 文件中转 / 截图 / 工具 / 搜索与 AI / 性能监测）
//   · `SettingsPage`   = 二级页，侧边栏唯一可选中粒度，也是内容区唯一分发粒度
//   · 一级目录永远常驻展开（不做手风琴），点一级标题 = 跳到它的第一个二级页
//
// 这样「新建一个设置项该放哪」只需回答「属于哪个一级目录的哪个二级页」，
// 深链、搜索索引、内容区分发三处共用同一份枚举，不会再各自漂移。

// MARK: - 一级目录

enum SettingsGroup: String, CaseIterable, Identifiable, Hashable {
    case general
    case audio
    case clipboard
    case transfer
    case capture
    case tools
    case searchAI
    case monitor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:  return "常规"
        case .audio:    return "音频"
        case .clipboard: return "剪贴板"
        case .transfer: return "文件中转"
        case .capture:  return "截图"
        case .tools:    return "工具"
        case .searchAI: return "搜索与 AI"
        case .monitor:  return "性能监测"
        }
    }

    var systemImage: String {
        switch self {
        case .general:  return "gearshape"
        case .audio:    return "speaker.wave.2"
        case .clipboard: return "doc.on.clipboard"
        case .transfer: return "arrow.left.arrow.right.square"
        case .capture:  return "camera.viewfinder"
        case .tools:    return "hammer"
        case .searchAI: return "magnifyingglass"
        case .monitor:  return "waveform.path.ecg"
        }
    }

    /// 二级页顺序（侧边栏渲染、⌘↑/⌘↓ 跳转、搜索兜底都读这一份）
    var pages: [SettingsPage] {
        switch self {
        case .general:
            return [.generalStart, .generalPanel, .generalWindows, .generalPersonal, .generalMenuBar]
        case .audio:
            return [.audio]
        case .clipboard:
            return [.clipboardHistory, .clipboardCapture, .clipboardFloating]
        case .transfer:
            return [.transferDisplay, .transferCast, .transferScan, .transferCloud, .transferLocal]
        case .capture:
            return CaptureSettingsBlock.allCases.map { .capture($0) }
        case .tools:
            return [.tools, .shortcuts]
        case .searchAI:
            return [.search, .ai]
        case .monitor:
            return [.monitorModule(.cpu), .monitorModule(.memory), .monitorModule(.gpu),
                    .monitorModule(.disk), .monitorModule(.network), .monitorModule(.sensors),
                    .monitorModule(.power), .monitorModule(.battery), .monitorSettings, .monitorWidgets]
        }
    }

    /// 某个二级页属于哪个一级目录（找不到时按常规兜底）
    static func group(of page: SettingsPage) -> SettingsGroup {
        for group in SettingsGroup.allCases where group.pages.contains(page) {
            return group
        }
        return .general
    }
}

// MARK: - 二级页

enum SettingsPage: Hashable {
    // 常规（5）
    /// 启动与外观：登录启动 / 外观四选一 / 语言
    case generalStart
    /// 主面板：预览 + 字号 / 圆角 / 宽度 / 材质 / 页面顺序
    case generalPanel
    /// 独立窗口与浮层：预览 + 玻璃四参数 / 密度 / 缩略图 / 徽章 / 通知条
    case generalWindows
    /// 个性化（通用）：强调色 / 打开动画 / 动作条 / 背景图 / 入口 / 恢复默认
    case generalPersonal
    /// 菜单栏：功能开关 / AI 服务商 / 图标样式 / 部件
    case generalMenuBar

    // 音频（1）
    case audio

    // 剪贴板（3）
    case clipboardHistory
    case clipboardCapture
    case clipboardFloating

    // 文件中转（5）
    case transferDisplay
    case transferCast
    case transferScan
    case transferCloud
    case transferLocal

    // 截图（5）
    case capture(CaptureSettingsBlock)

    // 工具（2）
    case tools
    case shortcuts

    // 搜索与 AI（2）
    case search
    case ai

    // 性能监测（10）
    case monitorModule(MonitorModuleID)
    case monitorSettings
    case monitorWidgets

    // 页脚常驻（3）
    case statistics
    case about
    case manual

    /// 页面标题（内容区大标题 + 侧边栏 tooltip）
    var title: String {
        switch self {
        case .generalStart:      return "启动与外观"
        case .generalPanel:      return "主面板"
        case .generalWindows:    return "独立窗口与浮层"
        case .generalPersonal:   return "个性化"
        case .generalMenuBar:    return "菜单栏"

        case .audio:             return "音频混音器"

        case .clipboardHistory:  return "历史"
        case .clipboardCapture:  return "捕获"
        case .clipboardFloating: return "浮动窗"

        case .transferDisplay:   return "显示"
        case .transferCast:      return "投屏画质"
        case .transferScan:      return "手机扫码直传"
        case .transferCloud:     return "云端中转"
        case .transferLocal:     return "本地暂存"

        case .capture(let block): return block.title

        case .tools:             return "工具"
        case .shortcuts:         return "快捷键"

        case .search:            return "搜索"
        case .ai:                return "AI"

        case .monitorModule(let module): return module == .sensors ? "传感器" : module.displayName
        case .monitorSettings:   return "监测设置"
        case .monitorWidgets:    return "部件设置"

        case .statistics:        return "数据"
        case .about:             return "关于"
        case .manual:            return "使用手册"
        }
    }

    /// 二级行左侧的小图标（与一级目录区分开，避免每行都是同一个大图标）
    var systemImage: String {
        switch self {
        case .generalStart:      return "power"
        case .generalPanel:      return "rectangle.topthird.inset.filled"
        case .generalWindows:    return "macwindow.on.rectangle"
        case .generalPersonal:   return "paintpalette"
        case .generalMenuBar:    return "menubar.rectangle"

        case .audio:             return "speaker.wave.2"

        case .clipboardHistory:  return "clock.arrow.circlepath"
        case .clipboardCapture:  return "arrow.down.doc"
        case .clipboardFloating: return "rectangle.on.rectangle"

        case .transferDisplay:   return "eye"
        case .transferCast:      return "airplayvideo"
        case .transferScan:      return "qrcode.viewfinder"
        case .transferCloud:     return "cloud"
        case .transferLocal:     return "internaldrive"

        case .capture(let block): return block.icon

        case .tools:             return "wrench.and.screwdriver"
        case .shortcuts:         return "command"

        case .search:            return "magnifyingglass"
        case .ai:                return "sparkles"

        case .monitorModule(let module): return module.systemImage
        case .monitorSettings:   return "slider.horizontal.3"
        case .monitorWidgets:    return "menubar.rectangle"

        case .statistics:        return "chart.bar.xaxis"
        case .about:             return "info.circle"
        case .manual:            return "book.closed"
        }
    }

    /// 这一页对应的功能「怎么打开」——内容区标题下方那行灰字（v273）。
    ///
    /// 用户（2026-11-11）：「探查是否所有页面都有打开方式，正确的在设置中有提示给用户」。
    /// 此前全库 0 处「打开方式」提示：用户改完保存路径/水印/图帘样式，却不知道
    /// 该按哪个键把功能叫出来——设置项和入口是两套心智模型。
    /// 这里把入口写进导航模型本身：新增一个二级页时，`openHint` 是必答题，
    /// 内容区头部统一渲染，不会再出现「有的页写了、有的页忘了」。
    /// 依据：`AppBootstrap.defaultHotkeys`（keyCode/Carbon 掩码）与
    /// `StatusBarMenuBuilder` 的菜单项，全部为当前代码里的真实绑定。
    var openHint: String? {
        switch self {
        case .generalStart:
            return "登录时自动启动；菜单栏图标常驻，⌥A 打开主面板"
        case .generalPanel:
            return "⌥A 打开主面板；点面板外部自动收起"
        case .generalWindows:
            return "各自独立呼出：悬浮剪贴板 ⇧⌘V · 图帘 ⇧⌥G · 钉图 ⇧⌥P"
        case .generalPersonal:
            return "强调色与背景图同时作用于主面板和所有独立窗口"
        case .generalMenuBar:
            return "菜单栏图标：左键开主面板，右键出菜单（设置… ⌘,）"

        case .audio:
            return "只在本页调节（系统输出音量 / 设备 / 有声 App 监视），没有独立窗口"

        case .clipboardHistory:
            return "⌥V 直接打开剪贴板面板；⌥A 的主面板首页也是剪贴板"
        case .clipboardCapture:
            return "无需手动：复制后自动入库；⇧⌘V 可随时呼出悬浮窗"
        case .clipboardFloating:
            return "⇧⌘V 呼出 / 收起悬浮剪贴板"

        case .transferDisplay:
            return "主面板 → 中转 分页（⌥A 打开主面板）"
        case .transferCast:
            return "主面板 → 投屏 分页，同一 Wi-Fi 下选择接收设备"
        case .transferScan:
            return "主面板 → 中转 → 手机扫码，扫二维码后直传"
        case .transferCloud:
            return "主面板 → 中转 → 云端，需先登录账号"
        case .transferLocal:
            return "把文件拖到中转区即暂存，到期自动清理"

        case .capture(.capture):
            return "⌥S 截图 · ⇧⌥W 窗口 · ⇧⌥S 提取文字 · ⇧⌥C 截图并复制"
        case .capture(.pin):
            return "⇧⌥P 截图并贴图 · ⌃⌥P 重新钉住上一张"
        case .capture(.curtain):
            return "⇧⌥G 呼出图帘；菜单栏右键也有「图帘」"
        case .capture(.recording):
            return "⌃⌥R 开始 / 停止录屏 · ⌃⌥E 录制区域"
        case .capture(.workflow):
            return "截图完成后自动执行，无需手动触发"

        case .tools:
            return "主面板 → 工具；菜单栏右键 → 设置 → 工具"
        case .shortcuts:
            return "改完立即生效；组合键冲突时后注册的那条不生效"

        case .search:
            return "⌥F 打开搜索框；主面板内 ⌘K 也能搜"
        case .ai:
            return "在搜索框、截图动作条、划词翻译（⇧⌥D）里调用"

        case .monitorModule:
            return "菜单栏部件显示实时数值；主面板「监测」页看详情"
        case .monitorSettings:
            return "影响菜单栏与主面板的采样频率和显示项"
        case .monitorWidgets:
            return "决定菜单栏部件的形态、颜色与间距"

        case .statistics:
            return "菜单栏图标右键 → 使用统计"
        case .about, .manual:
            return nil
        }
    }

    /// 一级目录归属（页脚三项返回 nil）
    var group: SettingsGroup? {
        switch self {
        case .statistics, .about, .manual: return nil
        default: return SettingsGroup.group(of: self)
        }
    }
}
