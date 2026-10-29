// main.swift — AndroMeld 式 MCP 读屏通道探针（⑤域基础设施）
// 拉起 app_process McpUiMain（root + shell 级 UiAutomation，无需辅助功能服务授权），
// 走 JSON-Lines 协议：{"ready":true} → mark → tree
// 编译: swiftc main.swift -o /tmp/amd_mcpui
// 运行: /tmp/amd_mcpui [expect包名] [timeoutMs]
//
// 协议来源：temp/AndroMeld/逆向-06-六域实现方案与源码依据.md §5.1
//   op 集仅 mark / tree（未知 op 抛 IllegalArgumentException）
//   tree 参数：timeoutMs / quietMs / churnMs / expect（=期待的前台应用包名）/ focusMs / sinceMark / changeMs
//   节点：p/d/b[l,t,r,b]/f/c/t/cd/h/id/pkg + r[min,max,current]
//   flags：1=clickable 2=longClickable 4=checkable 8=checked 16=scrollable 32=editable
//          128=focused 256=selected 512=!enabled 1024=password 2048=hintText
//
// 注意：必须 root 跑——shell uid 下 UiAutomation.connect() 会静默挂起（连 ready 都没有）。

import Foundation

func runADB(_ adb: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: adb)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try? p.run()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}

let adb = "/Users/sunyiyang/.local/bin/adb"
guard FileManager.default.fileExists(atPath: adb) else {
    print("❌ 找不到 adb: \(adb)"); exit(2)
}

let expectPkg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let timeoutMs = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 4000) : 4000

// 选设备
let serial: String = {
    let out = runADB(adb, ["devices"])
    for line in out.split(separator: "\n").dropFirst() {
        let parts = line.split(separator: "\t")
        if parts.count >= 2, parts[1].hasPrefix("device") { return String(parts[0]) }
    }
    return ""
}()
guard !serial.isEmpty else { print("❌ 无在线设备"); exit(2) }

// 取 APK 路径（CLASSPATH）
let pmOut = runADB(adb, ["-s", serial, "shell", "pm path com.catchingnow.andfiles.helper"])
guard let apkLine = pmOut.split(separator: "\n").first(where: { $0.contains("package:") }) else {
    print("❌ 手机未安装 helper APK"); exit(2)
}
let apk = apkLine.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces)

// 拉起 McpUiMain
let p = Process()
p.executableURL = URL(fileURLWithPath: adb)
p.arguments = ["-s", serial, "shell",
               "su -c 'export CLASSPATH=\(apk); exec /system/bin/app_process / --nice-name=frset-mcpuiprobe com.catchingnow.andfiles.helper.McpUiMain'"]
let inPipe = Pipe(), outPipe = Pipe()
p.standardInput = inPipe
p.standardOutput = outPipe
p.standardError = Pipe()
try p.run()

let outHandle = outPipe.fileHandleForReading
var buffer = Data()
var lines: [String] = []
DispatchQueue.global().async {
    while true {
        let chunk = outHandle.availableData
        if chunk.isEmpty { break }
        buffer.append(contentsOf: chunk)
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            lines.append(String(data: lineData, encoding: .utf8) ?? "")
        }
    }
}

func send(_ s: String) { inPipe.fileHandleForWriting.write((s + "\n").data(using: .utf8)!) }

// 等 ready
let readyDeadline = Date().addingTimeInterval(8)
while Date() < readyDeadline, !lines.contains(where: { $0.contains("\"ready\"") }) {
    Thread.sleep(forTimeInterval: 0.1)
}
guard lines.contains(where: { $0.contains("\"ready\"") }) else {
    print("❌ 未收到 ready（root 是否可用？）"); p.terminate(); exit(3)
}
print("✅ ready")

// mark + tree
send("{\"id\":1,\"op\":\"mark\"}")
Thread.sleep(forTimeInterval: 0.3)
var req = "{\"id\":2,\"op\":\"tree\",\"timeoutMs\":\(timeoutMs),\"quietMs\":300"
if !expectPkg.isEmpty { req += ",\"expect\":\"\(expectPkg)\"" }
req += "}"
send(req)

let treeDeadline = Date().addingTimeInterval(Double(timeoutMs) / 1000 + 5)
while Date() < treeDeadline {
    if let idx = lines.firstIndex(where: { $0.contains("\"nodes\"") }) {
        if let data = lines[idx].data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let nodes = obj["nodes"] as? [[String: Any]] ?? []
            let wins = obj["windows"] as? [[String: Any]] ?? []
            print("✅ settle=\(obj["settle"] ?? "?") 屏幕=\(obj["width"] ?? 0)x\(obj["height"] ?? 0) keyboard=\(obj["keyboard"] ?? false) windows=\(wins.count) nodes=\(nodes.count)")
            let flagsOf: ([String: Any]) -> Int = { ($0["f"] as? Int) ?? 0 }
            let focused = nodes.filter { flagsOf($0) & 128 != 0 }
            let editable = nodes.filter { flagsOf($0) & 32 != 0 }
            let withText = nodes.filter { !(($0["t"] as? String) ?? "").isEmpty }
            print("— 聚焦 \(focused.count) / 可编辑 \(editable.count) / 有文本 \(withText.count)")
            for n in focused.prefix(6) {
                print("  聚焦: c=\(n["c"] ?? "") t=\(n["t"] ?? "") id=\(n["id"] ?? "") b=\(n["b"] ?? [])")
            }
            for n in editable.prefix(6) {
                let bb = (n["b"] as? [Int]) ?? []
                print("  可编辑: c=\(n["c"] ?? "") t=\(n["t"] ?? "") id=\(n["id"] ?? "") b=\(bb) flags=\(flagsOf(n))")
            }
            let texts = withText.compactMap { $0["t"] as? String }
            if !texts.isEmpty {
                print("— 界面文本(前 30): \(texts.prefix(30).joined(separator: " | "))")
            }
            p.terminate()
            exit(0)
        }
    }
    Thread.sleep(forTimeInterval: 0.15)
}
print("❌ 未收到 tree 响应（已收 \(lines.count) 行）")
for l in lines.suffix(2) { print("  · \(l.prefix(300))") }
p.terminate()
exit(4)
