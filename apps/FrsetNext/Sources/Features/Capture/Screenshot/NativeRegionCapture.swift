import AppKit
import CoreGraphics
import CoreVideo
import ImageIO
import ScreenCaptureKit
import Foundation

// MARK: - 原生像素区域截图

/// 按「屏幕原生像素」截取一块区域。
///
/// v166.7（用户：「截图能否提高分辨率，跟屏幕原生像素一致」）：
/// 实测这台机器（1710×1112pt / scale 2 / 面板 2560×1664）几条通道的真实表现
/// （边缘能量越高越锐，系统截图约 12~15）：
///
/// | 通道 | 尺寸 | 锐度 |
/// |---|---|---|
/// | `screencapture -x`（整屏）| 3420×2224 | **12.38** ✅ 真 2x |
/// | `screencapture -x -R…` | 3420×2224 | 12.38 ✅ 但慢且不稳定（0.5~1.5s）|
/// | `screencapture -x **-o** -R…` | 3420×2224 | 8.34 ❌ 被降级成 1x 放大 |
/// | SCK（`captureResolution = .best`）| 3420×2224 | 7.14 ❌ 插值放大 |
/// | `CGDisplayCreateImage` | 3420×2224 | 8.31 ❌ 放大 |
/// | legacy `CGWindowListCreateImage(.bestResolution)` | 3466×2348 | 8.60 ❌ 放大 |
///
/// 结论：**只有整屏 `screencapture` 能拿到真 Retina 细节**，约 208ms。
/// 所以流程改成「整屏抓 → 内存里裁」，既避开 `-R` 的不稳定，也不要 `-o`。
/// 注意 `-o`（去窗口阴影）会让 screencapture 走另一条渲染路径、直接掉到 1x —— 别加。
enum NativeRegionCapture {

    /// 单个通道的时间上限（由会话预算派发，见 `CaptureBudget`）。
    /// 旧实现是写死 4s：BMP 超时后再给 PNG 4s，两条通道叠加。
    struct ChannelLimit: Sendable {
        let seconds: Double
        static let `default` = ChannelLimit(seconds: CaptureBudget.channelSeconds)
        var nanoseconds: UInt64 { UInt64(max(0.05, seconds) * 1_000_000_000) }
    }

    /// 抓指定屏幕的整屏原生像素图（screencapture，同步，**禁止主线程调用**）
    static func captureScreen(_ screen: NSScreen) -> CGImage? {
        guard let displayID = ScreenSnapshot.displayID(of: screen),
              let idx = ScreenSnapshot.screencaptureDisplayIndex(for: displayID) else { return nil }
        return captureScreenOnDisplay(index: idx)
    }

    /// 输出格式固定 BMP（2026-11-23 实测，见下方 `captureOnce` 注释）。
    /// 个别系统版本不认 bmp 时退回 png，行为与旧实现一致。
    static func captureScreenOnDisplay(index: Int, isCancelled: () -> Bool = { false },
                                       limit: ChannelLimit = .default) -> CGImage? {
        let deadline = DispatchTime.now().uptimeNanoseconds + limit.nanoseconds
        if let image = captureOnce(index: index, format: "bmp", isCancelled: isCancelled,
                                   deadline: deadline) { return image }
        guard !isCancelled() else { return nil }
        // 预算已经用完就不再开第二条通道（旧实现无条件再等一个 4s）。
        let remaining = Double(deadline) - Double(DispatchTime.now().uptimeNanoseconds)
        guard remaining > 300_000_000 else {
            Log.warn("Capture", "原生像素截图：预算用尽，不再尝试 PNG 回退")
            return nil
        }
        return captureOnce(index: index, format: "png", isCancelled: isCancelled, deadline: deadline)
    }

    /// PNG → BMP（2026-11-23，用户：「高负载时按了截图要等好几秒」）。
    ///
    /// 本机 2560×1440 单屏实测（空闲 / 8 核满载）：
    /// | 格式 | 采集+校验 | 峰值 | 文件 |
    /// |---|---|---|---|
    /// | png | 389 / 424ms（最慢 1487ms）| 430 / 1487ms | 0.7MB |
    /// | bmp | 204 / 198ms | 252 / 223ms | 14.7MB |
    /// 两者像素级一致（同帧 meanMaxDiff 0.01），BMP 只省掉 PNG 的压缩/解压 CPU：
    /// 满载时 PNG 编码线程被饿死，这才是「好几秒」的来源，不是抓屏本身慢。
    /// 14.7MB 写在页面缓存里，读回比解 PNG 快（解码 42ms → 21ms）。
    private static func captureOnce(index: Int, format: String, isCancelled: () -> Bool,
                                    deadline: UInt64) -> CGImage? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("frset-capture-\(UUID().uuidString).\(format)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        return run(arguments: ["-x", "-D\(index)", "-t", format, tmp.path],
                   tmp: tmp, isCancelled: isCancelled, deadline: deadline)
    }

    /// 按 AppKit 全局坐标（左下原点，点）截一块区域
    static func capture(appKitRect: CGRect) -> CGImage? {
        guard appKitRect.width >= 1, appKitRect.height >= 1 else { return nil }
        let screen = NSScreen.screens.first { $0.frame.contains(appKitRect) }
        guard let screen, let full = captureScreen(screen) else { return nil }
        // crop 内部按 image.width / screenFrame.width 自适应缩放，
        // 所以 2x 整屏图裁出来就是 2x 区域
        return ImageProcessor.crop(full, rectInPoints: appKitRect, screenFrame: screen.frame)
    }

    private static func run(arguments: [String], tmp: URL, isCancelled: () -> Bool,
                            deadline: UInt64) -> CGImage? {
        if isCancelled() { return nil }
        let started = DispatchTime.now().uptimeNanoseconds
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        do { try task.run() } catch {
            Log.warn("Capture", "原生像素截图：启动 screencapture 失败 \(error.localizedDescription)")
            return nil
        }
        // 30ms 一片地等：连续按快捷键时旧任务要能被立刻掐掉，
        // 不能留着和新的抢 WindowServer（用户：「连按几下反而更卡」）。
        while done.wait(timeout: .now() + 0.03) == .timedOut {
            if isCancelled() {
                task.terminate()
                Log.info("Capture", "原生像素截图：任务已取消，终止 screencapture")
                return nil
            }
            if DispatchTime.now().uptimeNanoseconds > deadline {
                task.terminate()
                Log.warn("Capture", "原生像素截图：screencapture 超时（通道预算用尽）")
                return nil
            }
        }
        guard task.terminationStatus == 0 else {
            Log.warn("Capture", "原生像素截图：screencapture 退出码 \(task.terminationStatus)")
            return nil
        }
        // v292（性能第二轮 B1）：拆开「进程退出 → 文件读取 → 解码」三段。
        // 旧日志把整段都算作抓取耗时，容易把 BMP 文件读取/解码误归因为 screencapture 本身。
        let procMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let readStart = DispatchTime.now().uptimeNanoseconds
        // 2026-11-24 v293：不再 `Data(contentsOf:)`——BMP 单张 14.7MB，
        // 先整体复制进内存再交给 ImageIO，等于多一次 14.7MB memcpy 和一份峰值占用。
        // 现在直接按 URL 建 source，并强制立即解码（shouldCacheImmediately）：
        // 解码结果进内存后临时文件可以安全删除，不会留下「文件已删、图还在懒加载」。
        let attrs = try? FileManager.default.attributesOfItem(atPath: tmp.path)
        let fileBytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let decoded = DispatchTime.now().uptimeNanoseconds
        guard let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(
                src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            Log.warn("Capture", "原生像素截图：输出图像解码失败")
            return nil
        }
        let readMs = Double(decoded - readStart) / 1_000_000
        let fileMB = Double(fileBytes) / 1_048_576
        let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - decoded) / 1_000_000
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        Log.info("Capture", String(format: "原生像素截图：%@ 进程 %.0fms · 文件 %.1fMB 读取 %.1fms · 解码 %.1fms · 总计 %.0fms %d×%dpx",
                                   (tmp.pathExtension), procMs, fileMB, readMs, decodeMs, ms, img.width, img.height))
        return img
    }
}
