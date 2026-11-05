#!/usr/bin/env swift
// Kitnest 整窗抓取工具（v216）
//
// 用法：swift tools/shotkit.swift <输出png> [深链] [窗口标题关键字] [等待秒数]
//   例：swift tools/shotkit.swift /tmp/panel.png "kitnest://panel"
//
// 为什么不用 `screencapture -l<id>`：
//   · screencapture 依赖窗口此刻在屏上且可见，App 失焦自动收起时就会抓空；
//   · 这里用 ScreenCaptureKit 直接按窗口取内容，**不裁屏幕、不受遮挡影响**，
//     所以「截图不完整」由这里根治。
//
// 做法：
//   1) 先发深链（如 kitnest://panel）触发界面；
//   2) 轮询 SCShareableContent，命中目标窗口（bundle + 标题关键字）立刻抓；
//   3) 抓完打印窗口尺寸与文件大小，供校验。

import Cocoa
import Foundation
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法：shotkit <输出png> [深链] [标题关键字] [等待秒数]")
    exit(1)
}
let outPath = args[1]
let deepLink = args.count > 2 ? args[2] : ""
let titleFilter = args.count > 3 ? args[3] : ""
let settle = args.count > 4 ? (Double(args[4]) ?? 1.0) : 1.0
let bundleID = "com.sxyq.frsetnext"

// CoreGraphics / ScreenCaptureKit 需要 NSApplication 先初始化（否则 CGS_REQUIRE_INIT 断言失败）
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if !deepLink.isEmpty {
    NSWorkspace.shared.open(URL(string: deepLink)!)
}

func ownWindows() async -> [SCWindow] {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
        return []
    }
    return content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
}

var target: SCWindow?
let deadline = Date().addingTimeInterval(15)
while Date() < deadline {
    let wins = await ownWindows()
    // 选窗优先级（抓主面板时容易撞上别的窗，比如「存储管理」）：
    //   ① 标题关键字匹配（指定了才算）
    //   ② 无标题的窗口 —— 主面板就是无标题的那扇
    //   ③ 窄窗优先 —— 面板宽 360pt，别的窗（设置 932、存储管理 1080）都更宽
    let sorted = wins.sorted { a, b in
        let ta = (a.title ?? "").isEmpty ? 0 : 1
        let tb = (b.title ?? "").isEmpty ? 0 : 1
        if ta != tb { return ta < tb }
        let wa = a.frame.width < 460 ? 0 : 1
        let wb = b.frame.width < 460 ? 0 : 1
        if wa != wb { return wa < wb }
        return a.frame.width < b.frame.width
    }
    for w in sorted {
        if !titleFilter.isEmpty && !(w.title ?? "").contains(titleFilter) { continue }
        if w.frame.width < 60 || w.frame.height < 60 { continue }
        target = w
        break
    }
    if target != nil { break }
    usleep(80_000)
}

guard let win = target else {
    print("✗ 没找到窗口（bundle=\(bundleID) 标题含「\(titleFilter)」）")
    exit(2)
}

// 等内容渲染 / 动画收敛
Thread.sleep(forTimeInterval: settle)

do {
    let filter = SCContentFilter(desktopIndependentWindow: win)
    let config = SCStreamConfiguration()
    config.width = Int(win.frame.width * 2)
    config.height = Int(win.frame.height * 2)
    config.showsCursor = false
    config.captureResolution = .best
    let cg: CGImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    let rep = NSBitmapImageRep(cgImage: cg)
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: outPath))
    print("✓ 窗口 id=\(win.windowID) 标题=「\(win.title ?? "")」 逻辑尺寸=\(Int(win.frame.width))x\(Int(win.frame.height)) "
        + "像素=\(rep.pixelsWide)x\(rep.pixelsHigh) 文件=\(data.count) bytes")
} catch {
    print("✗ 抓取失败：\(error)")
    exit(3)
}
