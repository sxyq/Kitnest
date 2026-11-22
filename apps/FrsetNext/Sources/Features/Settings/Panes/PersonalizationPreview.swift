// 2026-11-23 由 PersonalizationSettingsPane.swift 拆出：纯类型搬家，无行为变化。
import AppKit
import Combine
import ImageIO
import SwiftUI

// MARK: - 主面板分段拖拽落位（v181）
//
// 只在「拖到某一行上」时把被拖项挪到该行的位置；松手前就能看到实时重排。
struct SegmentDropDelegate: DropDelegate {
    let target: PanelCenterPage
    @Binding var order: [PanelCenterPage]
    @Binding var dragging: PanelCenterPage?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - 设置实时预览：复用正式界面，一页一个对象

/// 固定内容供所有正式预览组件共用；图片只在内存绘制一次。
enum SettingsPreviewSamples {
    static let date = Date(timeIntervalSince1970: 1_793_491_200)
    static let clipboardItems: [ClipboardItem] = [
        ClipboardItem(id: "appearance-note", type: .text,
                      content: "周五交付\n整理截图、核对文案，再发给同事。", title: "周五交付",
                      timestamp: date, sourceApp: "com.apple.Notes", isNote: true, dedupeKey: "appearance-note"),
        ClipboardItem(id: "appearance-link", type: .url,
                      content: "https://developer.apple.com/design/", title: "Apple 设计资源",
                      timestamp: date.addingTimeInterval(-120), sourceApp: "com.apple.Safari",
                      dedupeKey: "appearance-link"),
        ClipboardItem(id: "appearance-file", type: .file,
                      content: "/SettingsPreview/设计说明.pdf", title: "设计说明.pdf", subtitle: "PDF 文档 · 240 KB",
                      timestamp: date.addingTimeInterval(-240), sourceApp: "com.apple.finder",
                      dedupeKey: "appearance-file"),
        ClipboardItem(id: "appearance-image", type: .image,
                      title: "山间日落", subtitle: "320 × 180",
                      timestamp: date.addingTimeInterval(-360), sourceApp: "com.apple.Preview",
                      dedupeKey: "appearance-image"),
        ClipboardItem(id: "appearance-code", type: .text,
                      content: """
                      import SwiftUI

                      struct ProjectNoteView: View {
                          let title = "项目笔记"
                          let tasks = ["整理截图", "完成文案", "交付设计"]

                          var body: some View {
                              VStack(alignment: .leading, spacing: 12) {
                                  Text(title).font(.headline)
                                  ForEach(tasks, id: \\.self) { task in
                                      Label(task, systemImage: "checkmark.circle")
                                  }
                              }
                              .padding(16)
                          }
                      }
                      """, title: "项目笔记.swift",
                      timestamp: date.addingTimeInterval(-480), sourceApp: "com.apple.TextEdit",
                      dedupeKey: "appearance-code"),
        ClipboardItem(id: "appearance-color", type: .text, content: "#7B5CFF", title: "#7B5CFF",
                      timestamp: date.addingTimeInterval(-600), sourceApp: "com.apple.DigitalColorMeter",
                      isGeneratedByTool: true, sourceToolAnalyticsId: "colorpicker", sourceToolKeyword: "colorpicker",
                      dedupeKey: "appearance-color"),
        ClipboardItem(id: "appearance-long", type: .text,
                      content: """
                      项目设计记录：从整理到交付

                      本周的任务是整理一套可以反复阅读的项目资料。短标题用于快速定位，长正文保留背景、讨论过程和最终决定，让接手的人能够理解每一步为什么这样安排。

                      一、信息整理
                      收集已有笔记，按内容用途归类。界面上优先展示标题、来源与摘要；完整内容保持原有段落，不为了放进卡片而删去上下文。阅读时可以滚动，字号变化仍以真实尺寸呈现。

                      二、设计细节
                      同一个按钮在不同页面使用一致名称。颜色、圆角、卡片间距与列表密度分别调整，避免一项变化掩盖另一项。长标题需要自然换行，图片保持比例，代码保留缩进和换行。

                      三、协作流程
                      每个模块保留独立草稿，切换页面时继续上一次编辑。预览选择属于当前窗口，只影响阅读内容；保存后正式界面读取已保存值，取消则重新加载模块配置。

                      四、交付说明
                      文本应让第一次打开资料的人知道当前内容、可执行动作和下一步。结果展示在动作发生的位置，失败原因直接写明，用户可以保留草稿继续编辑。

                      五、阅读体验
                      在紧凑、标准和宽松密度下，正文都应能连续阅读。较小的视口通过真实滚动容纳内容，不能把整张界面缩小后当作字号或密度的效果。图片、笔记和代码也沿用同一组正式组件。

                      交付清单
                      • 项目笔记与设计说明
                      • 图片素材与 Swift 示例
                      • 长正文的完整段落
                      • 保存结果与取消行为说明

                      以上内容仅用于设置窗口中的固定展示，不连接网络、不启动采集，也不写入真实剪贴板或文件。
                      """, title: "项目设计记录：从整理到交付",
                      timestamp: date.addingTimeInterval(-720), sourceApp: "com.apple.TextEdit",
                      dedupeKey: "appearance-long"),
    ]

    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 320, height: 180))
        image.lockFocus()
        NSColor(srgbRed: 0.25, green: 0.30, blue: 0.58, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 180)).fill()
        NSColor(srgbRed: 1, green: 0.73, blue: 0.47, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 222, y: 102, width: 48, height: 48)).fill()
        for (color, points) in [
            (NSColor(srgbRed: 0.35, green: 0.42, blue: 0.62, alpha: 1),
             [NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 74), NSPoint(x: 82, y: 128),
              NSPoint(x: 183, y: 44), NSPoint(x: 254, y: 114), NSPoint(x: 320, y: 55), NSPoint(x: 320, y: 0)]),
            (NSColor(srgbRed: 0.13, green: 0.21, blue: 0.38, alpha: 1),
             [NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 22), NSPoint(x: 130, y: 87),
              NSPoint(x: 242, y: 26), NSPoint(x: 320, y: 62), NSPoint(x: 320, y: 0)]),
        ] {
            color.setFill()
            let mountain = NSBezierPath()
            mountain.move(to: points[0])
            for point in points.dropFirst() { mountain.line(to: point) }
            mountain.close()
            mountain.fill()
        }
        image.unlockFocus()
        return image
    }()
}

struct AppearancePreviewVisibilityKey: PreferenceKey {
    static let defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

private enum AppearancePreviewWallpaper {
    private static var cachedURL: URL?
    private static var cachedImage: NSImage?

    static func image() -> NSImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if cachedURL == url { return cachedImage }
        cachedURL = url
        cachedImage = nil
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceShouldCacheImmediately: true,
           ] as CFDictionary) {
            cachedImage = NSImage(cgImage: thumbnail, size: .zero)
        }
        return cachedImage
    }
}

struct AppearancePreviewBlock: View {
    enum Scope { case mainPanel, floatingWindow, clipboard, clipboardList, captureToolbar, notification }
    let scope: Scope
    @ObservedObject var draft: AppearanceSettingsDraft

    private var p: Personalization { draft.personalization }
    private var theme: ThemeAppearance {
        ThemeAppearance(personalization: p, isMidnight: draft.appearance == .midnight)
    }
    @Stored private var wallpaper: NSImage?
    @StateObject private var presentation = PanelPresentationState()
    @StateObject private var toolbarModel = CaptureToolbarModel()
    @StateObject private var toastState = MenuBarToastAnimationState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsPreviewViewport) private var viewport
    @Stored private var toastReplay = 0
    @Stored private var openReplay = 0
    @Stored private var revealed = true
    /// 打开动画预览：正式面板是「从锚点长出来」（WindowReveal，scale 0.90→1 + 淡入），
    /// 只做淡入时 0.18/0.22/0.28 三档几乎看不出来，用户会以为点开动画没反应。
    @Stored private var revealScale: CGFloat = 1
    @Stored private var isVisible = true
    @Stored private var toolbarFeedback: String?

    private var previewItems: [ClipboardItem] {
        SettingsPreviewSamples.clipboardItems
    }
    private var needsWallpaper: Bool {
        p.material == .vibrancy && !reduceTransparency
    }

    var body: some View {
        SettingsSection("效果预览", alwaysExpanded: true) {
            VStack(alignment: .leading, spacing: 8) {
            GeometryReader { viewport in
                let size = previewSize
                let width = min(size.width, max(0, viewport.size.width - 12))
                // 2026-11-14：正式组件按可用宽度排版，壁纸只沿边保留 6pt，不整窗缩放。
                previewContent
                    .frame(width: width, height: size.height)
                    .environment(\.isSettingsPreview, true)
                    .environment(\.settingsPreviewClipboardItems, previewItems)
                    .environment(\.settingsPreviewImage, SettingsPreviewSamples.image)
                    .environment(\.settingsPreviewClipboardSelection, $draft.previewSelectedItemID)
                    .environment(\.settingsPreviewPersonalization, p)
                    .environment(\.settingsPreviewIsMidnight, draft.appearance == .midnight)
                    .environment(\.colorScheme, previewColorScheme)
                    .tint(theme.accent)
                    .opacity(revealed ? 1 : 0)
                    .scaleEffect(revealScale, anchor: .top)
                    .offset(y: revealed ? 0 : -4)
                    // v282（用户：「这里点了没有反应」）：预览区本身就是「重播」按钮。
                    // 以前只有切换档位才会重播，用户点画面期待它演一遍，结果毫无反馈。
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if scope != .notification { openReplay &+= 1 }
                    }
                    .help(scope == .notification ? "通知预览" : "点一下重播打开动画")
                    .padding(6)
                    .background {
                        if needsWallpaper {
                            wallpaperBackground
                                .frame(width: width + 12, height: size.height + 12)
                                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                        }
                    }
                    .frame(width: viewport.size.width, height: size.height + 12, alignment: .leading)
            }
            .frame(height: previewSize.height + 12)
            .background(alignment: .center) {
                GeometryReader { geo in
                    Color.clear.preference(key: AppearancePreviewVisibilityKey.self,
                        value: geo.frame(in: .named("settingsPreviewViewport")).intersects(
                            viewport))
                }
            }
            if scope == .captureToolbar, let toolbarFeedback {
                Text(toolbarFeedback).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onPreferenceChange(AppearancePreviewVisibilityKey.self) {
            isVisible = $0
            // 滚出视口时把开合状态复位：任务在 sleep 后看到 !isVisible 会直接 return，
            // 只复位 revealed 会让面板永久停在 0.92 缩放。
            if !$0 { revealed = true; revealScale = 1 }
        }
        .onAppear {
            if needsWallpaper { wallpaper = AppearancePreviewWallpaper.image() }
            // 进页面先演示一次「打开」，否则只有切换动画档位才看得到。
            if scope != .notification, openReplay == 0 { openReplay = 1 }
            if scope == .captureToolbar {
                toolbarModel.style = CaptureToolbarStyle(rawValue: draft.toolbarStyle)!
                toolbarModel.preview = CaptureAppearanceSample.image
                toolbarModel.isSettingsPreview = true
                toolbarModel.onPreviewFeedback = { toolbarFeedback = $0 }
            }
            if scope == .notification {
                toastState.message = "操作完成"
                toastState.icon = "checkmark"
            }
        }
        .onChange(of: needsWallpaper) { needed in
            wallpaper = needed ? AppearancePreviewWallpaper.image() : nil
        }
        .onChange(of: draft.toolbarStyle) { style in
            if scope == .captureToolbar { toolbarModel.style = CaptureToolbarStyle(rawValue: style)! }
        }
        .onChange(of: p.openAnimation) { _ in
            if scope != .notification { openReplay &+= 1 }
        }
        .onChange(of: p.toastDuration) { _ in
            if scope == .notification { toastReplay &+= 1 }
        }
        .onChange(of: p.toastFollowPanel) { _ in
            if scope == .notification { toastReplay &+= 1 }
        }
        .task(id: openReplay) { @MainActor in
            // 正式面板的开合走 WindowReveal 的 CAAnimation，不受系统「减弱动态效果」
            // 影响；预览若跟着 reduceMotion 降级，就会变成瞬间切换，用户只会看到
            // 「点了没反应」。这里与正式实现一致，始终演示缩放+淡入。
            if openReplay == 0 || scope == .notification || !isVisible { return }
            // 先把面板按到起点（无动画），等它真正画出来，再按当前档位的时长展开。
            // 直接 withAnimation 改 false→true 会在首帧合并，等于没有动画——这也是
            // 之前「切换打开动画没反应」的另一半原因。
            revealed = false
            revealScale = 0.90
            do { try await Task.sleep(nanoseconds: 80_000_000) }
            catch { return }
            if !isVisible { return }
            withAnimation(.easeOut(duration: p.openAnimation.duration)) {
                revealed = true
                revealScale = 1
            }
        }
        .task(id: "\(toastReplay)-\(isVisible)") { @MainActor in
            // v274（用户：「它的这个没有展示它的一个效果」）：预览要连续演示，
            // 不能播一次就只剩壁纸。隐藏后先等一帧真正落地再弹入——false→true
            // 挤在同一帧时 SwiftUI 会合并更新，弹簧 scale 根本看不到。
            // 不按 reduceMotion 降级：正式通知条（Toast.swift）固定走 springBouncy，
            // 预览必须复现真实观感，否则系统开了「减弱动态效果」就永远看不到弹入。
            guard scope == .notification, isVisible else { return }
            toastState.isVisible = false
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            while !Task.isCancelled {
                withAnimation(Theme.Motion.springBouncy) {
                    toastState.isVisible = true
                }
                do { try await Task.sleep(nanoseconds: UInt64(p.toastDuration * 1_000_000_000)) }
                catch { return }
                withAnimation(Theme.Motion.springBouncy) {
                    toastState.isVisible = false
                }
                do { try await Task.sleep(nanoseconds: 900_000_000) }
                catch { return }
            }
        }
        .onDisappear {
            toastState.isVisible = false
            revealed = true
            revealScale = 1
            toolbarModel.onPreviewFeedback = nil
            toolbarFeedback = nil
            }
        }
        .id(scope)
    }

    private var previewColorScheme: ColorScheme {
        switch draft.appearance {
        case .light: return .light
        case .dark, .midnight: return .dark
        case .system: return colorScheme
        }
    }

    private var panelSize: CGSize {
        CGSize(width: max(320, CGFloat(draft.panelWidth)), height: 360)
    }

    private var toastSize: CGSize {
        let textWidth = ("操作完成" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold)
        ]).width
        return CGSize(width: textWidth + 120, height: 108)
    }

    private var previewSize: CGSize {
        switch scope {
        case .mainPanel: return panelSize
        case .floatingWindow: return CGSize(width: 520, height: 250)
        case .clipboard:
            return CGSize(width: 620, height: 380)
        case .clipboardList:
            return CGSize(width: max(320, CGFloat(draft.panelWidth)),
                          height: 260)
        case .captureToolbar:
            let size = CaptureActionToolbarPanel.panelSize(
                for: toolbarModel.preview?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                style: CaptureToolbarStyle(rawValue: draft.toolbarStyle)!)
            return CGSize(width: size.width, height: toolbarModel.preview == nil ? 56 : size.height)
        case .notification:
            return CGSize(width: max(panelSize.width, toastSize.width), height: toastSize.height + 36)
        }
    }

    @ViewBuilder private var previewContent: some View {
        switch scope {
        case .mainPanel:
            PanelRootView(presentation: presentation, onDismiss: {}, onOpenSettings: {},
                          personalization: p, previewPages: draft.previewPages)
                .background(LiquidGlassBackground(cornerRadius: p.cornerRadius))
                .clipShape(RoundedRectangle(cornerRadius: p.cornerRadius))
        case .floatingWindow:
            VStack(spacing: 0) {
                PreviewWindowChrome(onPress: { openReplay &+= 1 }).frame(height: 32)
                MonitorNetworkThroughputCard(down: 1_800_000, up: 240_000,
                    downHistory: [200_000, 700_000, 420_000, 1_300_000, 900_000, 1_800_000],
                    upHistory: [100_000, 180_000, 120_000, 320_000, 160_000, 240_000],
                    timeSpan: 60, slots: 6)
                    .padding(10)
            }
            .background(GlassSurface(cornerRadius: p.cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: p.cornerRadius))
        case .clipboard:
            FloatingClipboardDeskView(store: draft.floating, personalization: p)
                .overlay(alignment: .topLeading) {
                    PreviewWindowChrome(onPress: { openReplay &+= 1 }).frame(height: 32)
                }
        case .captureToolbar:
            CaptureActionToolbarView(model: toolbarModel)
        case .clipboardList:
            ClipboardSectionView(personalization: p)
                .background(GlassSurface(cornerRadius: p.cornerRadius))
                .clipShape(RoundedRectangle(cornerRadius: p.cornerRadius))
        case .notification:
            ZStack(alignment: .top) {
                VStack(spacing: 4) {
                    Text(p.toastFollowPanel ? "主面板下缘" : "屏幕中线")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Rectangle().fill(theme.cardStroke).frame(height: 1)
                }
                .padding(.horizontal, 12)
                .padding(.top, p.toastFollowPanel ? 0 : 14)
                MenuBarToastContentView(state: toastState)
                    .frame(width: toastSize.width, height: toastSize.height)
                    .offset(y: p.toastFollowPanel ? 18 : 30)
            }
        }
    }

    @ViewBuilder private var wallpaperBackground: some View {
        if let image = wallpaper {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

}

/// 使用 AppKit 的原生窗口按钮，不另画红绿灯。
private struct PreviewWindowChrome: NSViewRepresentable {
    let onPress: () -> Void

    final class Coordinator: NSObject {
        var onPress: () -> Void
        init(onPress: @escaping () -> Void) { self.onPress = onPress }
        @objc func press(_ sender: NSButton) { onPress() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPress: onPress) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        for (i, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            if let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) {
                button.target = context.coordinator
                button.action = #selector(Coordinator.press(_:))
                button.setFrameOrigin(NSPoint(x: CGFloat(14 + i * 20), y: 8))
                view.addSubview(button)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onPress = onPress }
}
