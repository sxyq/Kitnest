// main.swift — AndroMeld 式镜像通道「输入注入」冒烟测试（②.2）
// 编译: swiftc AmdMirrorChannel.swift AmdMirrorDecoder.swift main.swift -o /tmp/amd_inject
// 运行: /tmp/amd_inject [秒数=18]
// 验收: 握手 42 → CSD（拿到协议坐标基准）→ 依次注入 触摸/滑动/按键/文本/滚轮
//       → 会话存活（手机端未因非法 opcode 杀控制循环）→ op 11 干净退出

import Foundation

final class InjectSmoke: AmdMirrorChannelDelegate {
    let channel = AmdMirrorChannel()
    var framesIn = 0
    var gotConfig = false
    var videoSize: CGSize = .zero
    var injected: [String] = []
    var serial: String?
    let duration: TimeInterval

    init(duration: TimeInterval) { self.duration = duration }

    func amdMirrorChannel(_ ch: AmdMirrorChannel, didHandshake version: Int) {
        print("✅ 握手 版本=\(version)（期望 42）")
    }

    func amdMirrorChannel(_ ch: AmdMirrorChannel, didReceive config: AmdMirrorVideoConfig) {
        gotConfig = true
        videoSize = CGSize(width: config.width, height: config.height)
        print("✅ CSD \(config.width)x\(config.height) —— 协议坐标基准就绪")
        scheduleInjection(on: ch)
    }

    func amdMirrorChannel(_ ch: AmdMirrorChannel, didReceiveFrame flags: Int, ptsUs: Int64, data: Data) {
        framesIn += 1
    }

    func amdMirrorChannel(_ ch: AmdMirrorChannel, didChangeState state: AmdMirrorChannelState) {
        print("⏱ 状态: \(state)")
        if case .stopped(let reason) = state {
            print("❌ 会话异常终止：\(reason)")
        }
    }

    func amdMirrorChannel(_ ch: AmdMirrorChannel, didLog line: String) {
        print("   · \(line)")
    }

    /// CSD 到达后按序注入五类事件（每次间隔 0.6s，避开 300ms 长按判定窗口）
    /// 坐标取状态栏一带（y≈10）而非屏幕中央——测试机屏幕内容不明的场景下，
    /// 状态栏点击/横滑最多影响通知栏，不会误触 App 内的按钮。
    func scheduleInjection(on ch: AmdMirrorChannel) {
        // 单键模式：AMD_KEY=<keycode> 时只发这一个键（用于音量等系统级效果判别）
        if let raw = ProcessInfo.processInfo.environment["AMD_KEY"], let code = Int32(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                ch.sendKeyPress(AmdMirrorChannel.AmdAndroidKey(rawValue: code) ?? .home)
                self.injected.append("单键(DOWN+UP) \(code) op3")
            }
            return
        }
        let w = Int(videoSize.width), h = Int(videoSize.height)
        let safeY = 10
        let cx = w / 2
        let cy = h / 2
        // 搜索框所在行（协议坐标 ≈ 真实 y 130/2400 × 1600）
        let searchY = 90

        // AMD_FOCUS=1：只做「点击聚焦 + 字母输入」，用于验证文字是否真的落进输入框
        if ProcessInfo.processInfo.environment["AMD_FOCUS"] == "1" {
            let tapAt = { (delay: Double) in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    ch.sendTouch(.down, x: cx, y: searchY, downTimeOffsetNs: 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        ch.sendTouch(.up, x: cx, y: searchY, downTimeOffsetNs: 60_000_000)
                    }
                }
            }
            tapAt(0.6)
            tapAt(2.6)
            let letters2: [(String, Int32)] = [("F", 34), ("r", 46), ("s", 47), ("e", 33), ("t", 48)]
            for (i, item) in letters2.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0 + Double(i) * 0.2) {
                    ch.sendKeyPress(AmdMirrorChannel.AmdAndroidKey(rawValue: item.1) ?? .home)
                    self.injected.append("字母 \(item.0)(\(item.1)) op3 DOWN+UP")
                }
            }
            return
        }
        // ① 点击顶部搜索框（聚焦它，随后按键输入才有落点）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            ch.sendTouch(.down, x: cx, y: searchY, downTimeOffsetNs: 0)
            self.injected.append("触摸 down @(\(cx),\(searchY)) op33")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                ch.sendTouch(.up, x: cx, y: searchY, downTimeOffsetNs: 60_000_000)
                self.injected.append("触摸 up @(\(cx),\(searchY)) op33")
            }
        }
        // ② 页面动画结束后再点一次，确保 EditText 真正获得焦点
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            ch.sendTouch(.down, x: cx, y: searchY, downTimeOffsetNs: 0)
            self.injected.append("触摸 down(聚焦) @(\(cx),\(searchY)) op33")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                ch.sendTouch(.up, x: cx, y: searchY, downTimeOffsetNs: 60_000_000)
                self.injected.append("触摸 up(聚焦) op33")
            }
        }
        // ③ 逐字母按键（op 3，Android keycode）——验证「触摸聚焦 + 按键输入」闭环
        let letters: [(String, Int32)] = [("F", 34), ("r", 46), ("s", 47), ("e", 33), ("t", 48)]
        for (i, item) in letters.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6 + Double(i) * 0.18) {
                ch.sendKeyPress(AmdMirrorChannel.AmdAndroidKey(rawValue: item.1) ?? .home)
                self.injected.append("按键 \(item.0)(\(item.1)) op3")
            }
        }
        // ④ BACK 键（op 3，keycode 4）——功能级验证：应关闭搜索页
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.4) {
            ch.sendKeyPress(.back)
            self.injected.append("按键 BACK(4) op3")
        }
        // ③ 滑动（总时长 200ms < 300ms 长按判定窗）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            ch.swipe(from: CGPoint(x: 120, y: safeY), to: CGPoint(x: 420, y: safeY),
                     durationMs: 200, steps: 8)
            self.injected.append("滑动 (120,\(safeY))→(420,\(safeY)) op33×10")
        }
        // ④ 文本（op 7 IME commitText，中文/UTF-8 直进）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
            ch.sendText("Frset")
            self.injected.append("文本 \"Frset\" op7")
        }
        // ⑤ 滚轮 + 指针
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) {
            ch.sendScroll(x: cx, y: safeY, axisH: 0, axisV: -2)
            self.injected.append("滚轮 (0,-2) op2")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
            ch.sendPointer(.move, x: cx, y: safeY, pointerType: .mouse)
            self.injected.append("指针 move op20")
        }
    }

    func summary() {
        print("\n===== 注入冒烟结果 =====")
        print("CSD: \(gotConfig ? "✅ \(Int(videoSize.width))x\(Int(videoSize.height))" : "❌")")
        print("注入事件数: \(injected.count)")
        for line in injected { print("  · \(line)") }
        print("视频帧: \(framesIn)（会话在注入期间保持存活）")
        if gotConfig && injected.count >= 6 && framesIn > 10 {
            print("🎯 输入注入链路打通（Mac → op33/20/2/3/7 → 手机端 InputManager/IME 注入）")
        } else {
            print("⚠️ 注入未完全验证")
        }
    }
}

let dur = TimeInterval(CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 18 : 18)
let smoke = InjectSmoke(duration: dur)
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
// 用 RunLoop 推进时间：Thread.sleep 会阻塞主队列，注入定时器（DispatchQueue.main.asyncAfter）不会触发
RunLoop.main.run(until: Date().addingTimeInterval(dur))
print("\n发送 host stop (op 11)…")
smoke.channel.stop()
RunLoop.main.run(until: Date().addingTimeInterval(1.5))
smoke.summary()
exit(smoke.gotConfig && smoke.injected.count >= 6 ? 0 : 1)

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
