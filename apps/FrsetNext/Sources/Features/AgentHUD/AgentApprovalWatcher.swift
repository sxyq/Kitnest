import Combine
import Foundation

// MARK: - 批准/提问拦截框架（v130（AndroMeld/AgentHUD）：Agent HUD 核心接入 B3，P2）
//
// Agent HUD 的做法是「往 agent 自己的设置里写 hook」。这里做**最小实现**：
//   监听一个约定的 hook 输出文件，命中「需要批准/提问」事件 → 系统通知 + 点击跳转。
//
// hook 接线（具体 agent 的 hook 配置留此说明，由用户按需写入 agent 设置）：
//
//   Claude Code（~/.claude/settings.json）示例——Notification/PreToolUse 钩子把事件追加到
//   监听文件（每行一个 JSON）：
//     {
//       "hooks": {
//         "Notification": [{
//           "hooks": [{
//             "type": "command",
//             "command": "echo \"{\\\"type\\\":\\\"approval\\\",\\\"agent\\\":\\\"Claude Code\\\",\\\"title\\\":\\\"$CLAUDE_NOTIFICATION\\\"}\" >> ~/.claude/agent-hud-events.jsonl"
//           }]
//         }]
//       }
//     }
//
//   Codex（~/.codex/config.toml 的 notify / hooks）同理追加到 ~/.codex/agent-hud-events.jsonl。
//
// 事件行格式（本框架只认这几个字段，其余忽略）：
//   {"type":"approval"|"question", "agent":"Claude Code", "title":"…", "body":"…", "ts":1730000000}
//
// 没接 hook 时框架零开销（文件不存在 → 轮询直接返回）。

public final class AgentApprovalWatcher: ObservableObject {

    public static let shared = AgentApprovalWatcher()

    /// 约定的 hook 输出文件（两处都监听；不存在 = 未接线）
    public static let eventFiles: [String] = [
        NSHomeDirectory() + "/.claude/agent-hud-events.jsonl",
        NSHomeDirectory() + "/.codex/agent-hud-events.jsonl",
    ]

    /// 待处理事件（最近 20 条）
    @Published public private(set) var pending: [(id: String, type: String, agent: String, title: String, body: String, date: Date)] = []
    /// 已消费的各文件字节偏移（只读新增行）
    private var offsets: [String: UInt64] = [:]
    private var timer: Timer?
    private var notifiedIDs = Set<String>()

    private init() {}

    /// 启动轮询（5s；文件不存在零开销返回）
    public func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            autoreleasepool { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 逐文件读新增行（append-only，按偏移增量读）
    private func poll() {
        let fm = FileManager.default
        for path in Self.eventFiles {
            guard let fh = FileHandle(forReadingAtPath: path) else {
                offsets[path] = 0
                continue
            }
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            let from = offsets[path] ?? 0
            guard size > from else { continue }
            try? fh.seek(toOffset: from)
            offsets[path] = size
            guard let data = try? fh.readToEnd() else { continue }
            for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                let type = (obj["type"] as? String) ?? ""
                guard type == "approval" || type == "question" else { continue }
                let title = (obj["title"] as? String) ?? "Agent 请求处理"
                let body = (obj["body"] as? String) ?? ""
                let agent = (obj["agent"] as? String) ?? "Agent"
                let ts = (obj["ts"] as? Double) ?? Date().timeIntervalSince1970
                let id = "\(path)#\(from)#\(title)"
                let entry = (id: id, type: type, agent: agent,
                             title: title, body: body, date: Date(timeIntervalSince1970: ts))
                pending.insert(entry, at: 0)
                if pending.count > 20 { pending.removeLast(pending.count - 20) }
                // 每条只通知一次
                if !notifiedIDs.contains(id) {
                    notifiedIDs.insert(id)
                    notify(entry)
                }
            }
        }
    }

    /// 系统通知 + 点击跳转（NSUserNotification：不引入新框架/不要授权）
    private func notify(_ entry: (id: String, type: String, agent: String, title: String, body: String, date: Date)) {
        let n = NSUserNotification()
        n.title = entry.type == "approval" ? "Agent 请求批准" : "Agent 提问"
        n.subtitle = entry.agent
        n.informativeText = entry.title + (entry.body.isEmpty ? "" : "\n" + entry.body)
        n.soundName = NSUserNotificationDefaultSoundName
        n.userInfo = ["agenthud": "approval"]
        NSUserNotificationCenter.default.deliver(n)
        Toast.show("\(entry.agent)：\(entry.title)", icon: "bell.badge.fill", isWarning: true)
        Log.info("AgentHUD", "待处理事件：[\(entry.type)] \(entry.title)")
    }
}

/// 通知点击 → 打开 Agent HUD（NSUserNotificationCenterDelegate）
public final class AgentApprovalClickHandler: NSObject, NSUserNotificationCenterDelegate {
    public static let shared = AgentApprovalClickHandler()
    /// 由 AgentHUDModule.startIfNeeded() 挂到 NSUserNotificationCenter.default.delegate
    public func userNotificationCenter(_ center: NSUserNotificationCenter,
                                       didActivate notification: NSUserNotification) {
        guard notification.userInfo?["agenthud"] as? String == "approval" else { return }
        DispatchQueue.main.async {
            AgentHUDWindowController.shared.show()
        }
    }
    // 允许在 app 前台时也弹系统通知
    public func userNotificationCenter(_ center: NSUserNotificationCenter,
                                       shouldPresent notification: NSUserNotification) -> Bool { true }
}
