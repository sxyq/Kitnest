import AppKit
import Foundation

// MARK: - 渲染健康探针（v71：白屏实障排查基础设施）
//
// 用户实障：窗口点开后过一会白屏、无法正确展现。白屏类问题的共同特征是
// **发生时无异常、无崩溃**——SwiftUI/图层静默失效，事后无从下手。
// 本探针按固定周期（默认 5s）dump 关键窗口的渲染健康快照：
//   · 窗口：frame / alpha / visible / occlusion
//   · contentView：frame / hidden / wantsLayer / layer 状态
//   · 布局：subviews 数 / needsLayout / inLiveResize
// 白屏发生时日志里必有「最后一次健康 → 首次异常」的现场，可直接定位
// 是 frame 塌缩 / alpha 归零 / layer 清空 / 子视图被移除哪一类。
//
// 用法：日志 tag = "RenderProbe"，字段 key=value 单行可 grep。
// 关键入口（show/hide/切页）也会即时调用 snapshot()，事件流可与周期快照对齐。

public enum RenderProbe {

    /// 探针是否启用（v73：默认**关闭**——2026-10-19 性能审计实测发现生产环境
    /// 每 5s 全窗口快照并落盘一行日志（app.log 一天 100KB+，5s 一次主线程遍历），
    /// 白屏问题已定位修复后无常态运行必要。排障时显式设 FRSET_RENDER_PROBE=1 开启。）
    public static var isEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["FRSET_RENDER_PROBE"] {
            return env == "1"
        }
        return false
    }

    private static var timer: Timer?
    private static var lastSnapshot: [String: String] = [:]

    /// 安装周期探针（AppBootstrap 调用一次）
    public static func install() {
        guard isEnabled, timer == nil else { return }
        let t = Timer(timeInterval: 5.0, repeats: true) { _ in
            snapshotAll(reason: "periodic")
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.info("RenderProbe", "installed interval=5s")
    }

    /// 全部关键窗口快照（事件入口调用，reason 标注触发源）
    public static func snapshotAll(reason: String) {
        guard isEnabled else { return }
        DispatchQueue.main.async {
            dumpWindow(PanelController.shared.panelFrameForPopout.map { _ in PanelWindowHandle.shared }, name: "panel", reason: reason)
            dumpNamedWindows(reason: reason)
        }
    }

    /// 单窗口即时快照（show/hide/close 事件入口用）
    public static func snapshot(_ window: NSWindow?, name: String, reason: String) {
        guard isEnabled, let window else { return }
        DispatchQueue.main.async {
            emit(name: name, reason: reason, window: window)
        }
    }

    // MARK: 实现

    /// 按标题/类名遍历 app 自己的关键窗口
    private static func dumpNamedWindows(reason: String) {
        for w in NSApp.windows {
            let name: String
            switch w {
            case is SettingsWindow: name = "settings"
            default:
                let title = w.title
                if title.contains("性能监测") { name = "monitorPopout" }
                else if title.contains("预览") || title.contains("检视") { name = "preview" }
                else if title.contains("统计") { name = "statistics" }
                else { continue }
            }
            emit(name: name, reason: reason, window: w)
        }
    }

    private static func dumpWindow(_ handle: PanelWindowHandle?, name: String, reason: String) {
        guard let handle, let w = handle.window else { return }
        emit(name: name, reason: reason, window: w)
    }

    private static func emit(name: String, reason: String, window w: NSWindow) {
        let cv = w.contentView
        let layer = cv?.layer
        let subviews = cv?.subviews.count ?? -1
        let frameStr = "\(Int(w.frame.width))x\(Int(w.frame.height))@\(Int(w.frame.minX)),\(Int(w.frame.minY))"
        let cvFrame = cv.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "nil"
        var flags = [String]()
        if w.alphaValue < 0.05 { flags.append("alpha0") }
        if !(w.isVisible) { flags.append("invisible") }
        if cv?.isHidden == true { flags.append("cvHidden") }
        if cvFrame == "0x0" { flags.append("cvZero") }
        if subviews == 0 { flags.append("noSubviews") }
        if layer == nil { flags.append("noLayer") }
        if w.occlusionState.contains(.visible) == false { flags.append("occluded") }
        let flagStr = flags.isEmpty ? "ok" : flags.joined(separator: ",")
        let line = "name=\(name) reason=\(reason) frame=\(frameStr) alpha=\(String(format: "%.2f", w.alphaValue)) vis=\(w.isVisible) cv=\(cvFrame) sub=\(subviews) layer=\(layer != nil) flags=\(flagStr)"
        // 变化时才 INFO（防刷屏）；异常态一律 INFO
        if flags.isEmpty {
            if lastSnapshot[name] != line {
                lastSnapshot[name] = line
                Log.info("RenderProbe", line)
            }
        } else {
            Log.info("RenderProbe", line + (flags.joined(separator: ",").contains("alpha0|cvZero|noSubviews") ? "  <<<< 异常" : ""))
        }
    }
}

/// PanelController 窗口句柄桥（避免 RenderProbe 直接依赖 FloatingPanel 类型细节）
final class PanelWindowHandle {
    static let shared = PanelWindowHandle()
    var window: NSWindow? { PanelController.shared.panelWindowForProbe }
}
