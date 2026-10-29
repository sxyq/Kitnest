// main.swift — AndroMeld 式镜像链路端到端冒烟测试
// 编译: swiftc AmdMirrorChannel.swift AmdMirrorDecoder.swift main.swift -o /tmp/amd_smoke
// 运行: /tmp/amd_smoke [秒数=15]
// 验收: 握手 42 → CSD → AVSampleBufferVideoRenderer 持续解码 → 正常退出（op 11）

import Foundation
import CoreMedia
import AVFoundation

final class Smoke: AmdMirrorChannelDelegate {
    let channel = AmdMirrorChannel()
    let decoder = AmdMirrorDecoder()
    // 裸 AVSampleBufferVideoRenderer enqueue 会抛异常（必须有 video target），
    // 用 DisplayLayer 自带的 renderer——与 frset UI 上屏同一通道
    private let layer = AVSampleBufferDisplayLayer()
    private var renderer: AVSampleBufferVideoRenderer { layer.sampleBufferRenderer }
    var framesIn = 0
    var enqueued = 0
    var keyframes = 0
    var bytesIn: Int64 = 0
    var firstFrameAt: Date?
    var gotConfig = false
    var serial: String?
    var duration: TimeInterval

    init(duration: TimeInterval) { self.duration = duration }

    func amdMirrorChannel(_ ch: AmdMirrorChannel, didHandshake version: Int) {
        print("✅ 握手 版本=\(version)（期望 42）")
    }

    func amdMirrorChannel(_ ch: AmdMirrorChannel, didReceive config: AmdMirrorVideoConfig) {
        gotConfig = true
        print("✅ CSD \(config.width)x\(config.height) sps=\(config.csd1.count)B pps=\(config.csd2.count)B")
        let ok = decoder.configure(width: config.width, height: config.height,
                                   sps: config.csd1, pps: config.csd2)
        print(ok ? "✅ CMVideoFormatDescription 建立" : "❌ 格式建立失败")
        decoder.onSampleBuffer = { [weak self] sb, _ in
            guard let self else { return }
            self.renderer.enqueue(sb)
            self.enqueued += 1
        }
    }

    func amdMirrorChannel(_ ch: AmdMirrorChannel, didReceiveFrame flags: Int, ptsUs: Int64, data: Data) {
        if framesIn == 0 {
            print("🟡 首帧: flags=\(flags) pts=\(ptsUs) size=\(data.count) head=\(data.prefix(8).map { String(format: "%02x", $0) }.joined())")
        }
        framesIn += 1
        bytesIn += Int64(data.count)
        if flags == 1 { keyframes += 1 }
        if firstFrameAt == nil { firstFrameAt = Date() }
        decoder.decode(data, ptsUs: ptsUs, keyframe: flags == 1)
    }

    func amdMirrorChannel(_ ch: AmdMirrorChannel, didChangeState state: AmdMirrorChannelState) {
        print("⏱ 状态: \(state)")
    }

    func amdMirrorChannel(_ ch: AmdMirrorChannel, didLog line: String) {
        print("   · \(line)")
    }

    func summary() {
        let dt = (firstFrameAt.map { Date().timeIntervalSince($0) } ?? 0)
        print("\n===== 冒烟结果 =====")
        print("收到 CSD: \(gotConfig ? "✅" : "❌")")
        print("视频帧: \(framesIn) (IDR \(keyframes))  入队解码: \(enqueued)  封装失败: \(decoder.sampleErrors)")
        print("Layer 渲染状态: \(layer.status.rawValue) (0=pending 1=rendering 2=failed) readyForDisplay=\(layer.isReadyForDisplay)")
        print("字节: \(bytesIn)  流时长: \(String(format: "%.1f", dt))s  FPS: \(dt > 0 ? String(format: "%.1f", Double(framesIn)/dt) : "-")")
        if gotConfig && enqueued > 10 && layer.isReadyForDisplay {
            print("🎯 端到端链路打通（adb → app_process → stdio 42 → AVFoundation 硬解上屏）")
        } else {
            print("⚠️ 链路未完全打通，见上方日志")
        }
    }
}

let dur = TimeInterval(CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 15 : 15)
let smoke = Smoke(duration: dur)
smoke.channel.delegate = smoke

let serial: String? = {
    guard let adb = AmdMirrorChannel.findADB(),
          let out = try? Process.runAndReadStdout(adb, ["devices"]) else { return nil }
    for line in out.split(separator: "\n").dropFirst() {
        let parts = line.split(separator: "\t")
        if parts.count >= 2, parts[1].hasPrefix("device") { return String(parts[0]) }
    }
    return nil
}()
print("adb 设备: \(serial ?? "默认")，拉起 MirrorServerMain…")

smoke.channel.start(serial: serial)
Thread.sleep(forTimeInterval: dur)
print("\n发送 host stop (op 11)…")
smoke.channel.stop()
Thread.sleep(forTimeInterval: 1.5)
smoke.summary()
exit(smoke.enqueued > 10 ? 0 : 1)

extension Process {
    static func runAndReadStdout(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }
}
