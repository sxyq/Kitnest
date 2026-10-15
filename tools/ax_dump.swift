// AX 树导出器（验收工具）：dump 某进程的全部窗口与元素结构（role/title/identifier/value）
// 用法：ax_dump <pid> [maxDepth]；输出 JSON 到 stdout。
// 编译：swiftc -O ax_dump.swift -o ax_dump
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else {
    FileHandle.standardError.write("用法: ax_dump <pid> [maxDepth]\n".data(using: .utf8)!)
    exit(2)
}
let maxDepth = args.count >= 3 ? Int(args[2]) ?? 12 : 12

func attr(_ el: AXUIElement, _ key: String) -> AnyObject? {
    var v: CFTypeRef?
    let r = AXUIElementCopyAttributeValue(el, key as CFString, &v)
    return r == .success ? (v as AnyObject?) : nil
}

func str(_ el: AXUIElement, _ key: String) -> String {
    if let s = attr(el, key) as? String { return s }
    if let n = attr(el, key) as? NSNumber { return n.stringValue }
    if let arr = attr(el, key) as? [String] { return arr.joined(separator: " | ") }
    return ""
}

final class Node {
    var role = "", title = "", ident = "", value = "", desc = ""
    var children: [Node] = []
    init(_ el: AXUIElement) {
        role = str(el, kAXRoleAttribute as String)
        title = str(el, kAXTitleAttribute as String)
        ident = str(el, kAXIdentifierAttribute as String)
        desc = str(el, kAXDescriptionAttribute as String)
        if let v = attr(el, kAXValueAttribute as String) as? String, v.count <= 60 { value = v }
    }
}

func walk(_ el: AXUIElement, _ depth: Int) -> Node {
    let n = Node(el)
    guard depth < maxDepth else { return n }
    for key in [kAXChildrenAttribute as String, kAXContentsAttribute as String, kAXMenuBarAttribute as String] {
        guard let arr = attr(el, key) as? [AXUIElement] else { continue }
        for c in arr { n.children.append(walk(c, depth + 1)) }
        if !n.children.isEmpty { break }
    }
    return n
}

func toJSON(_ n: Node, _ depth: Int) -> String {
    let pad = String(repeating: "  ", count: depth)
    var fields: [String] = ["\"role\": \"\(n.role)\""]
    if !n.title.isEmpty { fields.append("\"title\": \"\(n.title)\"") }
    if !n.ident.isEmpty { fields.append("\"id\": \"\(n.ident)\"") }
    if !n.desc.isEmpty { fields.append("\"desc\": \"\(n.desc)\"") }
    if !n.value.isEmpty { fields.append("\"value\": \"\(n.value)\"") }
    var s = "{\(fields.joined(separator: ", "))"
    if !n.children.isEmpty {
        s += ",\n\(pad)\"children\": [\n"
        s += n.children.map { pad + "  " + toJSON($0, depth + 1) }.joined(separator: ",\n")
        s += "\n\(pad)]"
    }
    return s + "}"
}

let app = AXUIElementCreateApplication(pid)
var dummy: CFTypeRef?
let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &dummy)
guard err == .success, let wins = dummy as? [AXUIElement] else {
    let msg = "AX 查询失败（err=\(err.rawValue)）——请确认已授予辅助功能权限（系统设置→隐私与安全性→辅助功能）\n"
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    print("{\"error\": \"ax_permission_denied\", \"code\": \(err.rawValue)}")
    exit(1)
}
var out: [String] = []
if let menuBar = attr(app, kAXMenuBarAttribute as String) as? AXUIElement {
    out.append(toJSON(walk(menuBar, 0), 1))
}
// 状态栏图标菜单（AXExtrasMenuBar：菜单栏型应用的真实入口）
if let extras = attr(app, "AXExtrasMenuBar" as String) as? AXUIElement {
    out.append(toJSON(walk(extras, 0), 1))
}
for w in wins { out.append(toJSON(walk(w, 0), 1)) }
print("[\n" + out.joined(separator: ",\n") + "\n]")