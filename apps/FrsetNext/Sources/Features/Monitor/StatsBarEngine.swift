import AppKit
import SwiftUI

// MARK: - STATS 部件引擎桥（FrsetStatsBar ObjC/C 模块）
//
// 菜单栏合并条由引擎自建状态项并绘制（12 种部件形态 × 7 模块，配置与 Stats 互通，
// 存于 ~/Library/Application Support/FrsetStats/widgets.plist）。本桥只做三件事：
//   1) 启停：FSStatsTickStart()（SMC + 0.5s 采样 + 部件引擎）
//   2) 点击回调：部件点击 → 打开主面板并直达对应监测页、面板贴在点击的图标位置
//      （注入版 FSOpenPanelAtModule/FSSettlePanel 同款语义：打开前预排监测态，
//       首帧即监测页；顶边贴菜单栏下缘，x 对齐点击锚点——仅打开时校）
//   3) 设置入口：FSBarSettingsOpen()（Stats 风格部件设置窗）
//
// 重建版自带的 monitor.* 双排状态项在引擎启用时不再注册——合并条即其替代
// （与注入版「原生项隐藏、合并条呈现」的最终观感一致）。

public enum StatsBarEngine {

    /// 引擎模块索引 → 重建版监测页（索引口径见 frset_barwidgets.h：CPU0 内存1 GPU2 磁盘3 网络4 传感器5 电池6）
    public static func module(forIndex index: Int) -> MonitorModuleID {
        switch index {
        case 0: return .cpu
        case 1: return .memory
        case 2: return .gpu
        case 3: return .disk
        case 4: return .network
        case 5: return .sensors
        case 6: return .battery
        default: return .cpu
        }
    }

    /// 启动部件引擎（监测模块启动时调用一次）
    /// v43：引擎幂等标志。菜单栏监控只允许一套（STATS 合并条）——
    /// 模块重复启动 / 探针重入都不得再建第二个状态项。
    private static var isStarted = false

    public static func start() {
        guard !isStarted else {
            Log.info("Monitor", "STATS 引擎已在运行，忽略重复启动（菜单栏只允许一套合并条）")
            return
        }
        isStarted = true
        // 引擎点击回调必须是无捕获的 C 函数指针——经顶层跳板函数转接
        // （闭包字面量里嵌 async 块会被判为“捕获上下文”，无法形成 C 指针）
        FSStatsSetOpenMonitorHandler(statsBarOpenMonitorTrampoline)
        syncMainItem()
        startScreenGapProbe()
        FSStatsTickStart()
        Log.info("Monitor", "STATS 部件引擎已启动（合并条 + 设置窗 + Stats 配置互通）")
        // 部件设置全量自测（FRSET_WIDGET_SELFTEST=1）：逐项写读所有配置后原样恢复
        WidgetSettingsSelfTest.runIfRequested()
        // 排障探针：FRSET_STATSBAR_PROBE=<模块索引|settings|cycle> 时，3s 后按引擎点击的
        // 同一条链路（跳板 → openMonitor → popover）走一遍，验证接线
        // （不依赖合成鼠标事件；"settings" 打开部件设置窗；"cycle" 每 4s 轮播各模块页）
        if let probe = ProcessInfo.processInfo.environment["FRSET_STATSBAR_PROBE"] {
            if probe == "home" {
                // 只开主面板首页（v60：性能页已删，面板恒为 主页/中转站 两页）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    Log.info("StatsBar", "探针触发 home（主面板首页）")
                    PanelController.shared.show()
                }
            } else if probe == "poschk" {
                // v30：坐标系/稳定性探针——每 2s 采一次 × 8 次，看主图标与合并条
                // 的 window.frame 是否稳定（2026-10-16：疑主图标位置自行漂移）
                for i in 0..<8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0 + Double(i) * 2.0) {
                        for (name, item) in [("merged", FSBarMergedItem()), ("main", StatusBarController.shared.mainStatusItem)] {
                            guard let item, let b = item.button, let w = b.window else { continue }
                            let wf = w.frame
                            let scr = w.convertToScreen(b.convert(b.bounds, to: nil))
                            Log.info("StatsBar", "poschk[\(i)] \(name): win.x=\(Int(wf.origin.x)) w=\(Int(wf.width)) 右缘=\(Int(wf.maxX)) | screen.x=\(Int(scr.origin.x)) w=\(Int(scr.width)) 右缘=\(Int(scr.maxX))")
                        }
                    }
                }
            } else if probe == "recchk" {
                // 录屏管线自检：设置窗 → 开录 → 4s → 停止（无需鼠标；产物落 ~/Movies）
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    Log.info("StatsBar", "探针 recchk：打开设置窗并开录")
                    StatsBarEngine.openRecorder()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        FSScreenRecBeginFromSettings()
                        Log.info("StatsBar", "recchk: 已请求开始 running=\(FSScreenRecIsRunning())")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                            FSScreenRecStop()
                            Log.info("StatsBar", "recchk: 已请求停止")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                Log.info("StatsBar", "recchk: 收尾后 running=\(FSScreenRecIsRunning())")
                            }
                        }
                    }
                }
            } else if probe == "recorder" {
                // 录屏设置小窗视觉/可用性探针（无鼠标事件路径）
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    Log.info("StatsBar", "探针触发 recorder")
                    StatsBarEngine.openRecorder()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        for w in NSApp.windows {
                            Log.info("StatsBar", "窗口: \(w.className) frame=\(w.frame) visible=\(w.isVisible) level=\(w.level.rawValue)")
                        }
                    }
                }
            } else if probe == "settings" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    Log.info("StatsBar", "探针触发 settings")
                    StatsBarEngine.openSettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        for w in NSApp.windows {
                            Log.info("StatsBar", "窗口: \(w.className) frame=\(w.frame) visible=\(w.isVisible) title=\(w.title)")
                        }
                    }
                }
            } else if probe == "cycle" {
                for idx in 0...6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0 + Double(idx) * 4.0) {
                        Log.info("StatsBar", "探针轮播 module=\(idx)")
                        statsBarOpenMonitorTrampoline(Int32(idx))
                    }
                }
            } else if let idx = Int(probe) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    Log.info("StatsBar", "探针触发 module=\(idx)")
                    statsBarOpenMonitorTrampoline(Int32(idx))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        for w in NSApp.windows {
                            Log.info("StatsBar", "窗口: \(w.className) frame=\(w.frame) visible=\(w.isVisible) title=\(w.title)")
                        }
                    }
                }
            }
        }
    }

    /// 停止（App 退出前）
    public static func stop() {
        FSStatsTickStop()
        screenGapTimer?.invalidate()
        screenGapTimer = nil
        isStarted = false
    }

    /// v30：屏幕口径空隙下发器（每 0.5s）。
    /// 主图标 fan 样式的 window.frame 读数持续偏低 ~48pt（2026-10-17 实测），
    /// 而 convertToScreen 的内容坐标与截图吻合——用真实屏幕空隙驱动引擎保邻。
    private static var screenGapTimer: Timer?

    private static func startScreenGapProbe() {
        screenGapTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            guard let merged = FSBarMergedItem(), let main = StatusBarController.shared.mainStatusItem,
                  let mb = merged.button, let mw = mb.window,
                  let nb = main.button, let nw = nb.window else {
                FSBarSetScreenGap(-1)
                return
            }
            let mScr = mw.convertToScreen(mb.convert(mb.bounds, to: nil))
            let nScr = nw.convertToScreen(nb.convert(nb.bounds, to: nil))
            FSBarSetScreenGap(nScr.minX - mScr.maxX)   // >0 = 有空隙
        }
        RunLoop.main.add(timer, forMode: .common)
        screenGapTimer = timer
    }

    /// v30：把重建版主图标项注册给引擎（位置校准/保邻的参照物）。
    /// 重建版没有注入版的"原生监控项"，主项由状态栏自建——不注册的话引擎
    /// FSBarMainItem() 永远为 nil，校准与保邻全部静默跳过（漂移没人管）。
    /// 幂等：主项重建后重复调用即可。
    public static func syncMainItem(attempts: Int = 10) {
        guard let item = StatusBarController.shared.mainStatusItem else {
            // 主项尚未创建（启动早期监测模块可能先于状态栏）：有限次重试
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { syncMainItem(attempts: attempts - 1) }
            return
        }
        FSBarSetMainItem(item)
    }

    /// 部件点击 → 打开监测独立窗口（v60：性能监测只留独立窗一套实现）。
    ///
    /// v30-v59 行为（已废弃）：预排主面板监测页 → panel.show(atAnchor:)。
    /// v60 行为：未开窗口 → 打开并停在该模块；已开 → 只切模块（不挪位置）。
    static func openMonitor(index: Int) {
        let module = module(forIndex: index)
        Log.info("StatsBar", "部件点击 → 监测独立窗口 module=\(module.displayName)")
        let popout = MonitorPopoutWindowController.shared
        if popout.isVisible {
            popout.showModule(module)
        } else {
            popout.open(module: module)
        }
    }

    /// 打开 Stats 风格部件设置窗（监测面板页脚齿轮）
    public static func openSettings() {
        FSBarSettingsOpen()
    }

    /// 打开录屏设置小窗（截图菜单「录屏」——注入版独有能力，v47 移植）
    public static func openRecorder() {
        FSScreenRecOpenSettings()
    }
}

/// C 函数指针跳板（无捕获）：引擎部件点击 → 主队列 → openMonitor。
/// module 口径：CPU0 内存1 GPU2 磁盘3 网络4 传感器5 电池6。
private func statsBarOpenMonitorTrampoline(_ index: Int32) {
    Log.info("StatsBar", "部件点击回调 module=\(index)")
    DispatchQueue.main.async { StatsBarEngine.openMonitor(index: Int(index)) }
}
