import SwiftUI
import AppKit

// MARK: - 图帘设置（对标 1Capture「拖放架 → 悬挂」）
//
// 「图帘」是 v263 起对用户露出的名字：截图后挂在屏幕顶边帘线上的一条临时暂存区。
// 之前叫「截图悬挂架」，代码里也顺手把 Shelf* 改成 Curtain*（偏好键仍是 shelf.*，
// 改了会丢老用户设置）。
//
// 这一页的第一行必须是**总开关**，而且默认是关的：
// 关着的时候不会创建任何窗口、不会在后台留任何东西——用户要的是
// 「可以开、可以关，不是常驻」。其余选项在关闭时置灰，但仍然可见，
// 让人先看清楚能调什么再决定开不开。

public struct CurtainSettingsPane: View {

    @Stored private var enabled: Bool
    @Stored private var style: CurtainRopeStyle
    @Stored private var duration: Double
    @Stored private var maxCards: Double
    @Stored private var cardWidth: Double
    @Stored private var railScales: Bool
    @Stored private var attachOnCapture: Bool
    @Stored private var showing: Bool
    /// 快捷键录入后 self 不会自动刷新，用 revision 抖一下
    @Stored private var revision = 0

    public init() {
        _enabled = Stored(wrappedValue: CurtainPref.enabled)
        _style = Stored(wrappedValue: CurtainPref.ropeStyle)
        _duration = Stored(wrappedValue: CurtainPref.displayDuration)
        _maxCards = Stored(wrappedValue: Double(CurtainPref.maxCards))
        _cardWidth = Stored(wrappedValue: Double(CurtainPref.cardWidth))
        _railScales = Stored(wrappedValue: CurtainPref.railScalesWithCards)
        _attachOnCapture = Stored(wrappedValue: CurtainPref.attachOnCapture)
        // 不能在 View.init 里碰 @MainActor 单例，先给 false，onAppear 再同步真值
        _showing = Stored(wrappedValue: false)
    }

    public var body: some View {
        VStack(spacing: 20) {
            masterSwitch

            VStack(spacing: 20) {
                previewSection
                ropeSection
                behaviorSection
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.62)

            footer
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { showing = ImageCurtainController.shared.isShowing }
    }

    // MARK: 总开关

    private var masterSwitch: some View {
        // 外层 CaptureHubPane 已有「图帘」大标题，这里不再重复一次
        SettingsSection("启用") {
            SettingsGroupBox {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("截图完成后，把图挂在屏幕顶边的帘线上暂存")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("关掉时不创建窗口、不占用任何内存；开着也要等第一张截图才会出现。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: enabled) { CurtainPref.enabled = $0 }
                }
                .padding(.vertical, 8)

                if enabled {
                    SettingsDivider()
                    HStack(spacing: 10) {
                        Text(attachOnCapture
                             ? "下一张截图会自动挂上去"
                             : "已关闭自动上架：截图不会自动出现，只能手动唤出")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(showing ? "收起图帘" : "试一下") {
                            ImageCurtainController.shared.toggle()
                            showing = ImageCurtainController.shared.isShowing
                        }
                        .controlSize(.small)
                        .disabled(ImageCurtainController.shared.items.isEmpty && !showing)
                        .help(ImageCurtainController.shared.items.isEmpty
                              ? "先截一张图，架子上有东西才能显示"
                              : "显示或收起当前的图帘")
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }

    // MARK: 预览

    private var previewSection: some View {
        SettingsSection("预览") {
            SettingsGroupBox {
                CurtainPreview(style: style, cardWidth: CGFloat(cardWidth))
                    .frame(height: 168)
                    .padding(.vertical, 4)
                Text("卡片上方是夹子，踩着帘线；鼠标移上去会浮出保存 / 钉图 / 移除。按住 ⌘ 左右拖可以整条放大。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
            }
        }
    }

    // MARK: 样式

    private var ropeSection: some View {
        SettingsSection("帘线样式") {
            SettingsGroupBox {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(CurtainRopeStyle.allCases) { option in
                        VisualOptionCard(title: option.title,
                                         previewSize: CGSize(width: 96, height: 58),
                                         selected: style == option,
                                         action: {
                                             style = option
                                             CurtainPref.ropeStyle = option
                                         }) {
                            CurtainRopeThumb(style: option)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)

                SettingsDivider()
                Text(style.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 7)
            }
        }
    }

    // MARK: 行为

    private var behaviorSection: some View {
        SettingsSection("行为") {
            SettingsGroupBox {
                row("展示时长") {
                    Picker("", selection: $duration) {
                        Text("5 秒").tag(5.0)
                        Text("8 秒").tag(8.0)
                        Text("12 秒").tag(12.0)
                        Text("30 秒").tag(30.0)
                        Text("永不收起").tag(0.0)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: duration) { CurtainPref.displayDuration = $0 }
                    Text("到时只是收起，内容还在")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()
                row("最多挂") {
                    Picker("", selection: $maxCards) {
                        ForEach([4.0, 6.0, 8.0, 12.0], id: \.self) { value in
                            Text("\(Int(value)) 张").tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .onChange(of: maxCards) { CurtainPref.maxCards = Int($0) }
                    Text("超出时从最旧的开始挤掉（不删文件）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()
                row("卡片宽度") {
                    Slider(value: $cardWidth, in: 72...420, step: 4)
                        .frame(width: 200)
                        .onChange(of: cardWidth) { CurtainPref.cardWidth = CGFloat($0) }
                    Text("\(Int(cardWidth)) pt")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Text("也可以在图帘上按住 ⌘ 左右拖（或 ⌘ + 滚轮）直接放大缩小；屏幕上放不下时会自动收窄。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                SettingsDivider()
                row("帘线缩放") {
                    Toggle("", isOn: $railScales)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: railScales) { CurtainPref.railScalesWithCards = $0 }
                    Text("开着时卡片变大、帘线/夹子/绳结一起变粗；关掉只放大图片")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()
                row("快捷键") {
                    ShortcutRecorderButton(
                        display: AppBootstrap.shortcutBinding(for: "curtainToggle").map {
                            ShortcutManager.display(keyCode: $0.keyCode, modifiers: $0.modifiers)
                        },
                        onCapture: { code, modifiers in
                            _ = AppBootstrap.setShortcut("curtainToggle", keyCode: code, modifiers: modifiers)
                            revision += 1
                        },
                        onClear: {
                            _ = AppBootstrap.setShortcut("curtainToggle", keyCode: nil)
                            revision += 1
                        })
                        .frame(width: 160)
                    Text("随时展开 / 收起图帘")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()
                row("自动上架") {
                    Toggle("", isOn: $attachOnCapture)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: attachOnCapture) { CurtainPref.attachOnCapture = $0 }
                    Text("关掉后只能用菜单「显示图帘」或快捷键手动唤出")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()
                row("不进截图") {
                    Text("架子本身不会出现在任何截图或录屏里")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        Text("图帘是一次性暂存区：截图先挂这儿，需要时拖进聊天窗口或编辑器，不需要就等它自己收起。它不替代剪贴板历史和截图文件夹——原文件一直在原处。")
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row<Content: View>(_ title: String,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12.5))
                .frame(width: 74, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - 预览（绳子 + 两张卡）

private struct CurtainPreview: View {
    var style: CurtainRopeStyle
    var cardWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let scale = min(1, (geo.size.width - 40) / (cardWidth * 2 + 16 + 32))
            let cw = max(64, cardWidth * scale)
            let ch = cw * 0.62

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.18)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ZStack(alignment: .top) {
                        CurtainRopeSample(style: style)
                            .frame(width: cw * 2 + 16 + 44, height: 20)
                            .offset(y: 6)
                        HStack(spacing: 16) {
                            CurtainCardMock(width: cw, height: ch)
                            CurtainCardMock(width: cw, height: ch)
                        }
                        .padding(.top, 2)
                    }
                    .frame(height: ch + 26, alignment: .top)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
            }
        }
    }
}

private struct CurtainCardMock: View {
    var width: CGFloat
    var height: CGFloat

    /// 与 `CurtainMetrics.cornerRadius(for:)` 同一公式，预览才不会和真卡片长得不一样
    private var mockRadius: CGFloat { min(max(width * 0.09, 8), 18) }

    var body: some View {
        VStack(spacing: 0) {
            CurtainClip()
                .frame(width: 10, height: 13)
            ZStack {
                RoundedRectangle(cornerRadius: mockRadius, style: .continuous)
                    .fill(Color(white: 0.97))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.black.opacity(0.10))
                            .frame(width: width * CGFloat([0.56, 0.40, 0.48, 0.30][i]), height: 2.5)
                    }
                }
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: width, height: height)
            .overlay(RoundedRectangle(cornerRadius: mockRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
        }
    }
}

private struct CurtainClip: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                p.move(to: CGPoint(x: 1, y: 0))
                p.addLine(to: CGPoint(x: w - 1, y: 0))
                p.addLine(to: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: 0, y: h))
                p.closeSubpath()
            }
            .fill(Color(white: 0.66))
        }
    }
}

// MARK: - 单个绳子样式缩略

private struct CurtainRopeThumb: View {
    var style: CurtainRopeStyle

    var body: some View {
        ZStack {
            Color(white: 0.22)
            VStack(spacing: 0) {
                CurtainRopeSample(style: style, sag: 7)
                    .frame(height: 14)
                    .padding(.horizontal, 10)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
        }
    }
}

// MARK: - 绳子（设置页里的矢量预览，和窗口里的绘制同源同参数）

private struct CurtainRopeSample: View {
    var style: CurtainRopeStyle
    var sag: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CurtainRopeShape(sag: sag)
                    .stroke(strokeColor, style: strokeStyle)

                if style == .candyCane {
                    // 红白相间：白底上叠红色虚线，跟窗口里同一套画法
                    CurtainRopeShape(sag: sag)
                        .stroke(Color(red: 0.86, green: 0.03, blue: 0.16),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                                   dash: [3.2, 3.2]))
                }
                if style == .lights {
                    ForEach(0..<8, id: \.self) { i in
                        let t = (CGFloat(i) + 0.5) / 8
                        let p = point(at: t, size: geo.size)
                        Circle()
                            .fill(lampColors[i % lampColors.count])
                            .frame(width: 4, height: 4)
                            .position(p)
                    }
                }
                if style == .snow {
                    ForEach(0..<26, id: \.self) { i in
                        let t = CGFloat(i) / 26
                        let p = point(at: t, size: geo.size)
                        Circle()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 2.4, height: 2.4)
                            .position(x: p.x, y: p.y - 1.4)
                    }
                }
            }
        }
    }

    private var strokeColor: Color {
        style == .snow ? Color.white.opacity(0.80) : Color.white.opacity(0.74)
    }

    private var lineWidth: CGFloat {
        switch style {
        case .classic:   return 2.0
        case .candyCane: return 3.0
        case .lights:    return 1.4
        case .snow:      return 2.0
        }
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round)
    }

    private var lampColors: [Color] {
        [.yellow, .pink, .teal, .orange]
    }

    /// 三次贝塞尔取点：y = y0 + 3·sag·t·(1−t)
    private func point(at t: CGFloat, size: CGSize) -> CGPoint {
        let y0: CGFloat = 3
        let y = y0 + 3 * sag * t * (1 - t)
        return CGPoint(x: 2 + (size.width - 4) * t, y: y)
    }
}

private struct CurtainRopeShape: Shape {
    var sag: CGFloat

    /// 与窗口里的绘制同源：三次贝塞尔、控制点在 1/3 与 2/3。
    /// 用二次贝塞尔会在中间顶出一个尖，跟真绳差得远。
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y0: CGFloat = 3
        let w = rect.width - 4
        path.move(to: CGPoint(x: 2, y: y0))
        path.addCurve(to: CGPoint(x: 2 + w, y: y0),
                      control1: CGPoint(x: 2 + w / 3, y: y0 + sag),
                      control2: CGPoint(x: 2 + w * 2 / 3, y: y0 + sag))
        return path
    }
}
