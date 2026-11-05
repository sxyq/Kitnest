#!/usr/bin/env swift
// 官网抓图辅助：完整保存 / 还原系统剪贴板（含图片的多种表示）。
// 用法：swift tools/pasteboard_backup.swift save   <目录>
//       swift tools/pasteboard_backup.swift restore <目录>
// 为什么要这个：抓主面板前要往剪贴板灌几条演示文本，而用户此刻剪贴板里
// 可能是一张多格式图片（PNGf / TIFF / JPEG…）。pbpaste 只能拿纯文本，
// 直接 pbcopy 会把图片弄丢，所以按 pasteboard item × type 整体存档。
import AppKit
import Foundation

let pb = NSPasteboard.general
let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法：pasteboard_backup.swift save|restore <目录>")
    exit(1)
}
let mode = args[1]
let dir = args[2]
let fm = FileManager.default

if mode == "save" {
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var meta: [[String]] = []
    for (i, item) in (pb.pasteboardItems ?? []).enumerated() {
        var types: [String] = []
        for (j, t) in item.types.enumerated() {
            guard let d = item.data(forType: t) else { continue }
            try? d.write(to: URL(fileURLWithPath: "\(dir)/\(i)-\(j).dat"))
            types.append(t.rawValue)
        }
        meta.append(types)
    }
    let json = try! JSONSerialization.data(withJSONObject: meta, options: [])
    try! json.write(to: URL(fileURLWithPath: "\(dir)/meta.json"))
    print("✓ 已保存 \(meta.count) 个剪贴板项 / \(meta.reduce(0) { $0 + $1.count }) 种表示")
} else if mode == "restore" {
    let json = try! Data(contentsOf: URL(fileURLWithPath: "\(dir)/meta.json"))
    let meta = try! JSONSerialization.jsonObject(with: json) as! [[String]]
    pb.clearContents()
    var items: [NSPasteboardItem] = []
    for (i, types) in meta.enumerated() {
        let item = NSPasteboardItem()
        for (j, t) in types.enumerated() {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(i)-\(j).dat")) {
                item.setData(d, forType: NSPasteboard.PasteboardType(t))
            }
        }
        items.append(item)
    }
    if !items.isEmpty { pb.writeObjects(items) }
    print("✓ 已还原 \(items.count) 个剪贴板项")
} else {
    print("未知模式：\(mode)")
    exit(1)
}
