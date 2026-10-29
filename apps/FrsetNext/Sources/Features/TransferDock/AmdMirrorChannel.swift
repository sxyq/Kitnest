// AmdMirrorChannel.swift — AndroMeld 式直连镜像通道（stdio 协议 42）
// 逆向来源：temp/AndroMeld/逆向-05-完整实现档案.md（2026-10-29 实测字节级）
//
// 链路：本进程 --adb shell--> app_process MirrorServerMain（shell uid，DisplayManager
// 直连镜像，无 MediaProjection 弹窗）--stdout--> 本文件解析器。
//
// 出站协议（手机→Mac，实测 229 条消息零错位验证）：
//   握手 17B: "ADMR" | ver u32 BE(=42) | uptime i64 BE | kind u8(1=mirror)
//   op 17: 会话标识  i16 + len i32 + 包名
//   op 31: heartbeat-ack（无 payload）
//   op 1 : 视频 CSD  w i32 h i32 displayId i32 csd1Len i32 csd1 csd2Len i32 csd2
//   op 2 : 视频帧    flags i32(1=IDR) pts i64(μs) size i32 data[size]
//   op 20: 显示信息  a i32 w i32 h i32 density i32 f i32 z i32
// 入站协议（Mac→手机，op 1B 起）：
//   11 = host stop；4 = 请求关键帧；36 = 帧 ACK(i64 已确认字节)

import Foundation

// MARK: - 大端字节序追加（协议所有多字节字段均为大端）
extension Data {
    /// 追加大端整数
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    /// 追加大端 float32（IEEE754 位模式）
    mutating func appendBEFloat(_ value: Float) {
        appendBE(value.bitPattern)
    }
}

/// 通道状态
enum AmdMirrorChannelState: Equatable {
    case idle
    case starting
    case handshaked(version: Int)
    case streaming
    case stopped(reason: String)
}

/// 解析出的一条视频配置
struct AmdMirrorVideoConfig: Equatable {
    var width: Int
    var height: Int
    var displayId: Int
    /// SPS（含 Annex-B start code）
    var csd1: Data
    /// PPS（含 Annex-B start code）
    var csd2: Data
}

/// 通道委托——回调固定在解析线程（非主线程），UI 侧自行跳线程
protocol AmdMirrorChannelDelegate: AnyObject {
    func amdMirrorChannel(_ ch: AmdMirrorChannel, didHandshake version: Int)
    func amdMirrorChannel(_ ch: AmdMirrorChannel, didReceive config: AmdMirrorVideoConfig)
    func amdMirrorChannel(_ ch: AmdMirrorChannel, didReceiveFrame flags: Int, ptsUs: Int64, data: Data)
    func amdMirrorChannel(_ ch: AmdMirrorChannel, didChangeState state: AmdMirrorChannelState)
    func amdMirrorChannel(_ ch: AmdMirrorChannel, didLog line: String)
}

final class AmdMirrorChannel {

    weak var delegate: AmdMirrorChannelDelegate?

    private(set) var state: AmdMirrorChannelState = .idle

    /// adb 可执行文件探测（与 TransferCastEngines.findADB 同源，保持自包含）
    static func findADB() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var process: Process?
    private var stdinFD: Int32 = -1
    private let parseQueue = DispatchQueue(label: "frset.amd.mirror.parse")
    /// 接收缓冲（[UInt8] + 读指针——绝不用 Data.removeFirst + 绝对索引，越界陷阱）
    private var buf: [UInt8] = []
    private var readPos = 0
    /// 累计出站字节数（帧 ACK 用）
    private var sentBytes: Int64 = 0
    private var handshakeDone = false

    // MARK: - 启动 / 停止

    /// 拉起 MirrorServerMain（零弹窗：shell uid + DisplayManager 直连）
    func start(serial: String?, maxDim: Int = 1600, bitrate: Int = 8_000_000) {
        parseQueue.async { [weak self] in
            self?._start(serial: serial, maxDim: maxDim, bitrate: bitrate)
        }
    }

    private func _start(serial: String?, maxDim: Int, bitrate: Int) {
        guard let adb = Self.findADB() else {
            _set(.stopped(reason: "找不到 adb 可执行文件"))
            return
        }
        // 1) 取 APK 路径（CLASSPATH 必须指向已安装的 helper APK）
        let pmOut = runADB(adb, serial, ["shell", "pm path com.catchingnow.andfiles.helper"])
        var apk: String? = nil
        for rawLine in pmOut.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("package:"), line.hasSuffix(".apk") {
                apk = String(line.dropFirst("package:".count))
                break
            }
        }
        guard let apk else {
            _set(.stopped(reason: "手机未安装 AndroMeld helper（com.catchingnow.andfiles.helper）"))
            return
        }
        // 2) 组启动命令（argv 表见档案 1.1；实测通过的形态）
        //    注意：空参数必须用设备端变量 "$T" 展开——裸 '' 会被 adb 客户端
        //    转义后错位，导致手机端 main() 参数解析 abort（实测 exit=134）。
        let session = "frset-\(Int(Date().timeIntervalSince1970))"
        //  argv: 0=maxDim 1=bitrate 2=displayId 3=mode 4=session 5=transport
        //        6=userId 7=ime 8=fusionLinks 9=hdr 10=kind(mirror)
        let shell = "T=''; export CLASSPATH=\(apk); exec /system/bin/app_process / "
            + "--nice-name=frset-mirror com.catchingnow.andfiles.helper.MirrorServerMain "
            + "\(maxDim) \(bitrate) 0 \"$T\" \(session) \"$T\" 0 false true false mirror"
        log("启动: \(shell)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        var args = ["-s"]
        if let serial { args.append(serial) }
        args += ["shell", shell]
        p.arguments = args
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.terminationHandler = { [weak self] proc in
            let r = "exit=\(proc.terminationStatus) \(proc.terminationReason)"
            self?.parseQueue.async { [weak self] in
                guard let self, self.process === proc else { return }
                self._set(.stopped(reason: "进程退出 \(r)"))
                self.stopHeartbeat()
            }
        }
        do {
            try p.run()
        } catch {
            _set(.stopped(reason: "无法启动 adb: \(error)"))
            return
        }
        process = p
        stdinFD = inPipe.fileHandleForWriting.fileDescriptor
        _set(.starting)

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            self.parseQueue.async { [weak self] in
                self?.feed(data)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            for l in line.split(separator: "\n") where !l.isEmpty {
                self?.parseQueue.async { [weak self] in self?.log("[手机] \(l)") }
            }
        }
    }

    /// 停止会话：先发 op 11（host stop，服务器干净退出），超时杀进程
    func stop() {
        parseQueue.async { [weak self] in
            guard let self else { return }
            self.stopHeartbeat()
            self.sendControl([11])
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                if self.stdinFD >= 0 { close(self.stdinFD); self.stdinFD = -1 }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, let p = self.process, p.isRunning else { return }
                p.terminate()
            }
        }
    }

    /// 请求关键帧（op 4）
    func requestKeyframe() {
        parseQueue.async { [weak self] in self?.sendControl([4]) }
    }

    // MARK: - 心跳保活（op 10）
    //
    // 手机端有看门狗：收不到 keepalive 就判定会话失联并主动停止（实测日志
    // 「Stopping mirror session: heartbeat timeout」）。入站 op 10 无 payload，
    // 每次收到都刷新看门狗期限。周期取 5s（看门狗上限远大于此）。
    private var heartbeatTimer: DispatchSourceTimer?
    private static let heartbeatInterval: TimeInterval = 5.0

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: parseQueue)
        timer.schedule(deadline: .now() + 2, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.sendControl([10])   // op 10 = keepalive
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    /// 帧 ACK（op 36 + 已确认字节数 i64 BE）
    /// 注意：仅当会话启用了帧 ACK 时才能发（否则手机端抛 "Frame ACK is not
    /// enabled" 杀死控制循环——实测教训）。当前启动参数未启用，默认不发送。
    private var frameAckEnabled = false

    func acknowledge(bytes: Int64) {
        guard frameAckEnabled else { return }
        var payload = Data([36])
        var v = bytes.bigEndian
        withUnsafeBytes(of: &v) { payload.append(contentsOf: $0) }
        parseQueue.async { [weak self] in self?.sendControl([UInt8](payload)) }
    }

    // MARK: - 输入注入（②.2）
    //
    // 字节级规格来源：temp/AndroMeld/逆向-06-六域实现方案与源码依据.md 附录 A
    // （全部大端；来源 D2.java 分发循环 + MirrorServerMain 处理方法，行号见档案）
    //
    //   op 33 触摸（MotionEvent 主路径）：pointerType u8 | action u8 | downTimeOffsetNs u32 | x i32 | y i32
    //         wire action：0=DOWN 1=MOVE 2=UP 3=CANCEL（**与 MotionEvent 常量编号相反**）
    //   op 20 指针/鼠标：pointerType u8 | action u8 | x i32 | y i32
    //         action：0=down(pressure 1.0) 1=move 2=up/hover(pressure 0) 3=cancel
    //   op 2  滚轮：x i32 | y i32 | axisH f32 | axisV f32（AXIS_HSCROLL=10 / VSCROLL=9）
    //   op 3  按键：phase u8(1=UP，否则 DOWN) | keycode i32 | metaState i32
    //   op 7  IME 文本：len i32 | UTF-8 字节（中文直接 UTF-8，天然支持）
    //
    // 坐标语义：协议传**视频流编码分辨率下的像素**（非归一化），手机端按
    // p0(v, src, dst)=clamp(v,0,src)/src×dst 换算到真实屏幕后注入。

    /// 触摸动作（wire 编号，注意与 MotionEvent 常量相反）
    enum AmdTouchAction: UInt8 {
        case down = 0, move = 1, up = 2, cancel = 3
    }

    /// 指针类型
    enum AmdPointerType: UInt8 {
        case mouse = 1, pen = 2, finger = 3
    }

    /// 鼠标/指针动作
    enum AmdPointerAction: UInt8 {
        case down = 0, move = 1, up = 2, cancel = 3
    }

    /// 常用 Android keycode（与 macOS 虚拟键码不同，需映射）
    enum AmdAndroidKey: Int32 {
        case home = 3, back = 4, call = 5, endCall = 6
        case dpadUp = 19, dpadDown = 20, dpadLeft = 21, dpadRight = 22
        case volumeUp = 24, volumeDown = 25, power = 26, camera = 27
        case tab = 61, space = 62, enter = 66, del = 67, menu = 82
        case escape = 111, appSwitch = 187
    }

    /// 视频编码分辨率（op 1 CSD 带来）——协议坐标的基准
    private(set) var videoSize: CGSize = .zero

    /// 把视图坐标换算为协议坐标（协议用视频流编码分辨率像素）
    func protocolPoint(from viewPoint: CGPoint, in viewSize: CGSize) -> CGPoint {
        guard videoSize.width > 0, videoSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return viewPoint }
        return CGPoint(x: viewPoint.x * videoSize.width / viewSize.width,
                       y: viewPoint.y * videoSize.height / viewSize.height)
    }

    /// 触摸注入（op 33）
    /// - Parameter downTimeOffsetNs: 距手势起点的纳秒偏移（手机端据此做 300ms 长按判定，
    ///   move 累计超过 300ms 会被判为长按并注入 CANCEL）
    func sendTouch(_ action: AmdTouchAction,
                   x: Int, y: Int,
                   pointerType: AmdPointerType = .finger,
                   downTimeOffsetNs: UInt32 = 0) {
        var payload = Data([33, pointerType.rawValue, action.rawValue])
        payload.appendBE(UInt32(downTimeOffsetNs))
        payload.appendBE(Int32(x))
        payload.appendBE(Int32(y))
        parseQueue.async { [weak self] in self?.sendControl([UInt8](payload)) }
    }

    /// 指针/鼠标注入（op 20）
    func sendPointer(_ action: AmdPointerAction,
                     x: Int, y: Int,
                     pointerType: AmdPointerType = .mouse) {
        var payload = Data([20, pointerType.rawValue, action.rawValue])
        payload.appendBE(Int32(x))
        payload.appendBE(Int32(y))
        parseQueue.async { [weak self] in self?.sendControl([UInt8](payload)) }
    }

    /// 滚轮注入（op 2）：axisH/axisV 为滚动量（正=右/上，负=左/下）
    func sendScroll(x: Int, y: Int, axisH: Float = 0, axisV: Float = 0) {
        var payload = Data([2])
        payload.appendBE(Int32(x))
        payload.appendBE(Int32(y))
        payload.appendBEFloat(axisH)
        payload.appendBEFloat(axisV)
        parseQueue.async { [weak self] in self?.sendControl([UInt8](payload)) }
    }

    /// 按键注入（op 3）：phaseUp=true 表示抬起，否则按下
    func sendKey(_ key: AmdAndroidKey, metaState: Int32 = 0, phaseUp: Bool = false) {
        var payload = Data([3, phaseUp ? 1 : 0])
        payload.appendBE(key.rawValue)
        payload.appendBE(metaState)
        parseQueue.async { [weak self] in self?.sendControl([UInt8](payload)) }
    }

    /// 完整一次按键（DOWN 后跟 UP）——真实按键成对，只发 DOWN 可能被系统丢弃
    func sendKeyPress(_ key: AmdAndroidKey, metaState: Int32 = 0, holdMs: UInt32 = 40) {
        sendKey(key, metaState: metaState, phaseUp: false)
        parseQueue.asyncAfter(deadline: .now() + .milliseconds(Int(holdMs))) { [weak self] in
            self?.sendKey(key, metaState: metaState, phaseUp: true)
        }
    }

    /// 文本注入（op 7 IME commitText，UTF-8 直进，支持中文）
    func sendText(_ text: String) {
        let bytes = Array(text.utf8)
        var payload = Data([7])
        payload.appendBE(Int32(bytes.count))
        payload.append(contentsOf: bytes)
        parseQueue.async { [weak self] in self?.sendControl([UInt8](payload)) }
    }

    /// 轻点（down → 短暂停顿 → up）
    func tap(x: Int, y: Int, durationMs: UInt32 = 60) {
        sendTouch(.down, x: x, y: y, downTimeOffsetNs: 0)
        parseQueue.asyncAfter(deadline: .now() + .milliseconds(Int(durationMs))) { [weak self] in
            self?.sendTouch(.up, x: x, y: y, downTimeOffsetNs: durationMs * 1_000_000)
        }
    }

    /// 滑动（down → 若干 move → up）；stepMs 决定总时长，超过 300ms 手机端会判长按并取消
    func swipe(from: CGPoint, to: CGPoint, durationMs: UInt32 = 200, steps: Int = 10) {
        let start = ProcessInfo.processInfo.systemUptime
        sendTouch(.down, x: Int(from.x), y: Int(from.y), downTimeOffsetNs: 0)
        for i in 1...max(steps, 1) {
            let t = Double(i) / Double(max(steps, 1))
            let offset = UInt32(Double(durationMs) * 1_000_000 * t)
            let px = Int(from.x + (to.x - from.x) * t)
            let py = Int(from.y + (to.y - from.y) * t)
            parseQueue.asyncAfter(deadline: .now() + .milliseconds(Int(Double(durationMs) * t))) { [weak self] in
                self?.sendTouch(.move, x: px, y: py, downTimeOffsetNs: offset)
            }
        }
        _ = start
        parseQueue.asyncAfter(deadline: .now() + .milliseconds(Int(durationMs))) { [weak self] in
            self?.sendTouch(.up, x: Int(to.x), y: Int(to.y), downTimeOffsetNs: durationMs * 1_000_000)
        }
    }

    // MARK: - 出站流解析

    private func feed(_ data: Data) {
        sentBytes += Int64(data.count)
        buf.append(contentsOf: data)
        if ProcessInfo.processInfo.environment["AMD_DEBUG"] != nil {
            log("feed +\(data.count)B readPos=\(readPos) buf=\(buf.count) hs=\(handshakeDone)")
        }
        // 握手：17 字节起
        if !handshakeDone {
            guard remaining() >= 17 else { return }
            let head = Array(buf[readPos..<(readPos + 4)])
            guard String(bytes: head, encoding: .ascii) == "ADMR" else {
                _set(.stopped(reason: "握手魔数错误: \(head)"))
                process?.terminate()
                return
            }
            let version = readU32(4)
            readPos += 17
            delegate?.amdMirrorChannel(self, didHandshake: version)
            _set(.handshaked(version: version))
            log("握手 ok 版本=\(version)")
            handshakeDone = true
        }
        // 消息循环
        while parseOne() {}
        compact()
    }

    private func remaining() -> Int { buf.count - readPos }

    /// 回收已消费前缀
    private func compact() {
        guard readPos > 65536 else { return }
        buf.removeFirst(readPos)
        readPos = 0
    }

    /// 尝试解析一条消息；缓冲不足返回 false
    /// 出站 opcode 全表（静态还原 + 实测验证，来源逆向-05 档案）
    private func parseOne() -> Bool {
        guard let op = peek(1)?.first else { return false }
        switch op {
        case 31: // heartbeat-ack
            readPos += 1
            return true
        case 17: // secure window state: 1B visible
            guard remaining() >= 2 else { return false }
            readPos += 2
            return true
        case 11: // IME 事件: 1B code
            guard remaining() >= 2 else { return false }
            readPos += 2
            return true
        case 12, 15: // 剪贴板 pending / 锁定提示: 仅 1B
            readPos += 1
            return true
        case 10: // IME 剪贴板快照: 1B kind + i32 len + data
            guard remaining() >= 6 else { return false }
            let len = readI32(2)
            guard len >= 0, len <= 4 << 20, remaining() >= 6 + len else { return false }
            readPos += 6 + len
            return true
        case 8: // IME 状态: i32 a + i32 len + str
            guard remaining() >= 9 else { return false }
            let len = readI32(5)
            guard len >= 0, len <= 1 << 20, remaining() >= 9 + len else { return false }
            readPos += 9 + len
            return true
        case 1: // 视频 CSD
            guard remaining() >= 21 else { return false }
            let w = readI32(1), h = readI32(5), disp = readI32(9)
            let l1 = readI32(13)
            guard l1 >= 0, l1 <= 1024, remaining() >= 17 + l1 + 4 else { return false }
            let l2 = readI32(17 + l1)
            guard l2 >= 0, l2 <= 1024, remaining() >= 21 + l1 + l2 else { return false }
            let csd1 = Data(buf[(readPos + 17)..<(readPos + 17 + l1)])
            let csd2 = Data(buf[(readPos + 21 + l1)..<(readPos + 21 + l1 + l2)])
            readPos += 21 + l1 + l2
            let cfg = AmdMirrorVideoConfig(width: w, height: h, displayId: disp, csd1: csd1, csd2: csd2)
            log("视频配置 \(w)x\(h) display=\(disp) csd1=\(l1)B csd2=\(l2)B")
            // 协议坐标基准（注入用）：视频流编码分辨率
            videoSize = CGSize(width: w, height: h)
            delegate?.amdMirrorChannel(self, didReceive: cfg)
            _set(.streaming)
            // 开始心跳保活（实测：缺 op 10 时手机端看门狗会以 heartbeat timeout 杀会话）
            startHeartbeat()
            return true
        case 3: // 简版配置: 3×i32
            guard remaining() >= 13 else { return false }
            readPos += 13
            return true
        case 2: // 视频帧: flags i32 pts i64 size i32 data
            guard remaining() >= 17 else { return false }
            let flags = readI32(1)
            let pts = readI64(5)
            let size = readI32(13)
            guard size >= 0, size <= 16 << 20 else {
                log("非法帧大小 \(size)，进入重同步")
                return resync()
            }
            guard remaining() >= 17 + size else { return false }
            let frame = Data(buf[(readPos + 17)..<(readPos + 17 + size)])
            readPos += 17 + size
            delegate?.amdMirrorChannel(self, didReceiveFrame: flags, ptsUs: pts, data: frame)
            return true
        case 4: // 尺寸请求: 3×i32
            guard remaining() >= 13 else { return false }
            readPos += 13
            return true
        case 5: // 音频帧: pts i64 + len i32 + PCM
            guard remaining() >= 13 else { return false }
            let len = readI32(9)
            guard len >= 0, len <= 1 << 20, remaining() >= 13 + len else { return false }
            readPos += 13 + len
            return true
        case 14: // display task state: i32 a + B b + B c + 4×i32(d,e,f,g) + i32 len1 + str1 + i32 len2 + str2
            guard remaining() >= 27 else { return false }
            let l1 = readI32(23)
            guard l1 >= 0, l1 <= 1 << 20, remaining() >= 27 + l1 + 4 else { return false }
            let l2 = readI32(27 + l1)
            guard l2 >= 0, l2 <= 1 << 20, remaining() >= 31 + l1 + l2 else { return false }
            readPos += 31 + l1 + l2
            return true
        case 18: // 通知事件: i64 + i64 uptime + i32 len + str
            guard remaining() >= 21 else { return false }
            let len = readI32(17)
            guard len >= 0, len <= 1 << 20, remaining() >= 21 + len else { return false }
            readPos += 21 + len
            return true
        case 20: // 显示信息: 6×i32
            guard remaining() >= 25 else { return false }
            readPos += 25
            return true
        case 25: // 指针回显: 2×i32
            guard remaining() >= 9 else { return false }
            readPos += 9
            return true
        case 27: // 文件分享桥: i64 id + i64 uptime + i32 len1 + str1 + i64 + i32 len2 + str2 + i32
            guard remaining() >= 21 else { return false }
            let l1 = readI32(17)
            guard l1 >= 0, l1 <= 1 << 20, remaining() >= 21 + l1 + 8 else { return false }
            let l2 = readI32(29 + l1)
            guard l2 >= 0, l2 <= 1 << 20, remaining() >= 33 + l1 + l2 else { return false }
            readPos += 37 + l1 + l2
            return true
        case 28: // 文件保存 chunk: i64 id + 1B + i32 len + data
            guard remaining() >= 14 else { return false }
            let len = readI32(10)
            guard len >= 0, len <= 4 << 20, remaining() >= 14 + len else { return false }
            readPos += 14 + len
            return true
        case 29: // IME/音频路由状态: 2×1B
            guard remaining() >= 3 else { return false }
            readPos += 3
            return true
        case 30: // 剪贴板图片: i32 len + data
            guard remaining() >= 5 else { return false }
            let len = readI32(1)
            guard len >= 0, len <= 8 << 20, remaining() >= 5 + len else { return false }
            readPos += 5 + len
            return true
        default:
            // 未知 opcode（6/7/9/13/16/19/21-24/26 等）：锚点重同步
            log("未知 opcode \(op)@\(readPos)，重同步")
            return resync()
        }
    }

    /// 流错位后的重同步：向前扫描寻找可信锚点
    /// 锚点 A：CSD 头 `01 + w>0 h>0 合理 + l1∈[4,64]`
    /// 锚点 B：帧头 `02 + flags∈{0,1} + pts 合理 + size∈[4,16MB]`
    private func resync() -> Bool {
        let scanEnd = buf.count
        var p = readPos + 1
        while p + 17 <= scanEnd {
            let b0 = buf[p]
            if b0 == 1, p + 21 <= scanEnd {
                let w = readI32At(p + 1), h = readI32At(p + 5)
                let l1 = readI32At(p + 13)
                if w > 200, w <= 8000, h > 200, h <= 8000, (12...24).contains(l1) {
                    log("重同步命中 CSD 锚点@\(p)")
                    readPos = p
                    return true
                }
            }
            if b0 == 2 {
                let flags = readI32At(p + 1)
                let size = readI32At(p + 13)
                if flags == 0 || flags == 1, size >= 4, size <= 4 << 20, p + 17 + size <= scanEnd {
                    // 校验帧数据以 Annex-B start code 开头
                    let d0 = buf[p + 17], d1 = buf[p + 18], d2 = buf[p + 19], d3 = buf[p + 20]
                    if d0 == 0, d1 == 0, d2 == 0, d3 == 1 || (d0 == 0x65 || d0 == 0x41 || d0 == 0x67 || d0 == 0x68 || d0 == 0x01 || d0 == 0x06) {
                        log("重同步命中帧锚点@\(p)")
                        readPos = p
                        return true
                    }
                }
            }
            p += 1
        }
        // 没找到锚点：保留最后 16 字节，丢弃其余（等待更多数据）
        readPos = max(readPos, scanEnd - 16)
        return false
    }

    private func readI32At(_ pos: Int) -> Int {
        guard pos >= 0, pos + 4 <= buf.count else { return -1 }
        let b = [UInt8](buf[pos..<(pos + 4)])
        return Int(Int32(truncatingIfNeeded: Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])))
    }

    // MARK: - 缓冲读取工具（全部相对 readPos 的绝对下标，防 Data 索引偏移陷阱）

    private func peek(_ n: Int) -> [UInt8]? {
        guard remaining() >= n else { return nil }
        return Array(buf[readPos..<(readPos + n)])
    }

    private func readU32(_ off: Int) -> Int {
        let lo = readPos + off, hi = lo + 4
        guard lo >= 0, hi <= buf.count else {
            log("⚠️ readU32 越界 off=\(off) readPos=\(readPos) buf=\(buf.count)")
            return 0
        }
        // 注意：ArraySlice 下标继承绝对索引，必须转实体数组后再用 0 基下标
        let b = [UInt8](buf[lo..<hi])
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }
    private func readI32(_ off: Int) -> Int {
        Int(Int32(truncatingIfNeeded: readU32(off)))
    }
    private func readI64(_ off: Int) -> Int64 {
        let lo = readPos + off, hi = lo + 8
        guard lo >= 0, hi <= buf.count else {
            log("⚠️ readI64 越界 off=\(off) readPos=\(readPos) buf=\(buf.count)")
            return 0
        }
        let b = [UInt8](buf[lo..<hi])
        var v: Int64 = 0
        for x in b { v = (v << 8) | Int64(x) }
        return v
    }

    // MARK: - 私有工具

    private func sendControl(_ bytes: [UInt8]) {
        guard stdinFD >= 0 else { return }
        // 直接走 write(2)：NSFileHandle.writeData 在管道破裂时抛 ObjC 异常无法捕获
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let n = write(stdinFD, base + written, bytes.count - written)
                if n <= 0 { break } // 对端已关闭——进程终止中，忽略
                written += n
            }
        }
    }

    private func _set(_ s: AmdMirrorChannelState) {
        state = s
        delegate?.amdMirrorChannel(self, didChangeState: s)
    }

    private func log(_ line: String) {
        delegate?.amdMirrorChannel(self, didLog: line)
    }

    private func runADB(_ adb: String, _ serial: String?, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        var a = [String]()
        if let serial { a += ["-s", serial] }
        a += args
        p.arguments = a
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
