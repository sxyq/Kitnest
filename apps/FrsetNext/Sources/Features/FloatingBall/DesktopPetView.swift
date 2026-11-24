import SwiftUI

// MARK: - 海豚桌面精灵视图
// 用 SwiftUI Shape/Path 绘制小海豚，不依赖任何外部图片资源。
// 动画全部走 TimelineView(.animation(minimumInterval:)) 限频 + SwiftUI 隐式过渡，
// 没有 Timer / CADisplayLink 全帧率循环。

/// v288（2026-11-24 审计包 04）：自定义形象 PNG 缓存（路径 + mtime 绑定）。
///
/// 旧实现 `petContent` 里每次 `NSImage(contentsOfFile:)`——动画时钟约 3fps，
/// 等于每 0.3s 从盘上完整解码一张 PNG（还要走一次图片初始化），纯属重复工作；
/// 换形象/换文件本来就该即时生效，所以缓存键取 **路径 + mtime**：路径变了或
/// 文件被外部替换（mtime 变）都会自动重读，不缓存失效问题。mtime 探测是
/// 一次 stat 系统调用，成本可以忽略；海豚动画本体（呼吸/漂浮/眨眼）不动。
private enum PetImageCache {
    private static let lock = NSLock()
    private static var cached: (path: String, mtime: Date, image: NSImage)?

    static func image(at path: String) -> NSImage? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.path == path, cached.mtime == (mtime ?? .distantPast) {
            return cached.image
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cached = (path, mtime ?? .distantPast, image)
        return image
    }
}

struct DesktopPetView: View {
    let appearance: DesktopPetAppearance
    /// 拖动中 → 装饰动画冻结
    let isDragging: Bool

    var onTap: () -> Void = {}
    var onDoubleTap: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onHide: () -> Void = {}
    var onQuit: () -> Void = {}

    /// 本工程 @State 宏不可用（SwiftUIMacros 插件缺失），按项目约定用 @Stored 兼容层。
    @Stored private var isHovered = false

    /// 独立动画时钟频率：约 3 fps，低功耗
    private static let clockInterval: TimeInterval = 0.3

    var body: some View {
        Group {
            // v287：静态模式 / 拖动中不跑动画时钟——角色静止时零重绘开销。
            if appearance.motionMode == .staticMode || isDragging {
                petContent(t: 0)
            } else {
                TimelineView(.animation(minimumInterval: Self.clockInterval)) { context in
                    petContent(t: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        // 悬停：一次性弹簧过渡（抬头 / 轻摇尾），不持续追踪
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .rotationEffect(.degrees(isHovered ? -2.5 : 0), anchor: .bottom)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture(count: 1) { onTap() }
        .contextMenu {
            Button("设置", action: onOpenSettings)
            Button("隐藏精灵", action: onHide)
            Divider()
            Button("退出精灵", action: onQuit)
        }
        .accessibilityLabel("海豚桌面精灵")
        .accessibilityHint("单击展开面板，双击自定义动作，右键打开菜单")
    }

    /// 单帧内容：自定义 PNG 优先（用户替换形象），否则用内置矢量海豚。
    @ViewBuilder
    private func petContent(t: TimeInterval) -> some View {
        // 呼吸：±1.5 % 缩放，周期 3.5 s
        let breathe = sin(t * 2 * .pi / 3.5) * 0.015
        // 漂浮：±1 pt 垂直偏移，周期 5.2 s（与呼吸异频，更自然）
        let floatY = sin(t * 2 * .pi / 5.2) * 1.0
        // 眨眼：每 5.5 s 眨一次，持续 0.12 s
        let isBlinking = t > 0 && t.truncatingRemainder(dividingBy: 5.5) < 0.12
        Group {
            if let path = appearance.customImagePath,
               let image = PetImageCache.image(at: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                dolphinBody(isBlinking: isBlinking)
            }
        }
        .scaleEffect(1.0 + breathe)
        .offset(y: floatY)
    }

    // MARK: - 海豚绘制

    @ViewBuilder
    private func dolphinBody(isBlinking: Bool) -> some View {
        let s = appearance.sizeMode.scale
        ZStack {
            // 尾鳍（最后面）
            DolphinTailShape()
                .fill(appearance.finColor)

            // 背鳍
            DolphinDorsalFinShape()
                .fill(appearance.finColor)

            // 身体
            DolphinBodyShape()
                .fill(appearance.bodyColor)

            // 腹部浅色
            DolphinBellyShape()
                .fill(appearance.bellyColor)

            // 胸鳍
            DolphinPectoralFinShape()
                .fill(appearance.finColor)

            // 眼睛
            PetEyeView(isBlinking: isBlinking,
                       eyeColor: appearance.eyeColor,
                       highlightColor: appearance.eyeHighlightColor)

            // 嘴线
            DolphinMouthShape()
                .stroke(appearance.mouthColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            // 呼气孔
            Circle()
                .fill(appearance.finColor.opacity(0.45))
                .frame(width: 3.5, height: 3.5)
                .offset(x: -4, y: -13)

            // 悬停气泡
            if appearance.showsBubble && isHovered {
                PetBubbleView()
                    .offset(y: -34)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .scaleEffect(s)
        .frame(width: 56, height: 44)
    }
}

// MARK: - 眼睛（支持眨眼）

private struct PetEyeView: View {
    let isBlinking: Bool
    let eyeColor: Color
    let highlightColor: Color

    var body: some View {
        if isBlinking {
            // 眨眼：一条弧线
            Path { p in
                p.move(to: CGPoint(x: -5, y: 0))
                p.addQuadCurve(to: CGPoint(x: 5, y: 0), control: CGPoint(x: 0, y: 3))
            }
            .stroke(eyeColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: 12, height: 6)
            .offset(x: 14, y: -5)
        } else {
            ZStack {
                Circle().fill(eyeColor).frame(width: 7, height: 7)
                Circle().fill(highlightColor).frame(width: 2.5, height: 2.5)
                    .offset(x: -1.2, y: -1.2)
            }
            .offset(x: 14, y: -5)
        }
    }
}

// MARK: - 悬停气泡

private struct PetBubbleView: View {
    var body: some View {
        Text("你好~")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.white.opacity(0.88))
                    .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
            )
            .overlay(alignment: .bottom) {
                // 小尾巴
                Path { p in
                    p.move(to: CGPoint(x: -3, y: 0))
                    p.addLine(to: CGPoint(x: 0, y: 4))
                    p.addLine(to: CGPoint(x: 3, y: 0))
                }
                .fill(Color.white.opacity(0.88))
                .offset(y: 3)
            }
    }
}

// MARK: - 海豚各部件形状（Path 绘制，无外部资源）

/// 身体主轮廓（侧面，头朝右）
private struct DolphinBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        // 鼻尖
        p.move(to: CGPoint(x: w * 0.90, y: h * 0.47))
        // 头顶 → 额头 → 背部
        p.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.16),
                       control: CGPoint(x: w * 0.86, y: h * 0.18))
        // 背部 → 尾根
        p.addQuadCurve(to: CGPoint(x: w * 0.16, y: h * 0.32),
                       control: CGPoint(x: w * 0.32, y: h * 0.10))
        // 尾根 → 腹部
        p.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.82),
                       control: CGPoint(x: w * 0.10, y: h * 0.62))
        // 腹部 → 下颌 → 鼻尖
        p.addQuadCurve(to: CGPoint(x: w * 0.90, y: h * 0.47),
                       control: CGPoint(x: w * 0.88, y: h * 0.82))
        p.closeSubpath()
        return p
    }
}

/// 背鳍（向后弯的三角）
private struct DolphinDorsalFinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.50, y: h * 0.18))
        p.addQuadCurve(to: CGPoint(x: w * 0.32, y: h * 0.02),
                       control: CGPoint(x: w * 0.40, y: h * 0.04))
        p.addQuadCurve(to: CGPoint(x: w * 0.30, y: h * 0.20),
                       control: CGPoint(x: w * 0.30, y: h * 0.10))
        p.closeSubpath()
        return p
    }
}

/// 胸鳍（体侧小鳍）
private struct DolphinPectoralFinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.52, y: h * 0.58))
        p.addQuadCurve(to: CGPoint(x: w * 0.38, y: h * 0.78),
                       control: CGPoint(x: w * 0.40, y: h * 0.72))
        p.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.65),
                       control: CGPoint(x: w * 0.48, y: h * 0.72))
        p.closeSubpath()
        return p
    }
}

/// 尾鳍（双叶）
private struct DolphinTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        // 上叶
        p.move(to: CGPoint(x: w * 0.20, y: h * 0.32))
        p.addQuadCurve(to: CGPoint(x: w * 0.02, y: h * 0.15),
                       control: CGPoint(x: w * 0.08, y: h * 0.18))
        p.addQuadCurve(to: CGPoint(x: w * 0.10, y: h * 0.38),
                       control: CGPoint(x: w * 0.04, y: h * 0.30))
        // 下叶
        p.addQuadCurve(to: CGPoint(x: w * 0.02, y: h * 0.60),
                       control: CGPoint(x: w * 0.04, y: h * 0.48))
        p.addQuadCurve(to: CGPoint(x: w * 0.20, y: h * 0.44),
                       control: CGPoint(x: w * 0.10, y: h * 0.52))
        p.closeSubpath()
        return p
    }
}

/// 腹部浅色区
private struct DolphinBellyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.28, y: h * 0.56))
        p.addQuadCurve(to: CGPoint(x: w * 0.58, y: h * 0.80),
                       control: CGPoint(x: w * 0.38, y: h * 0.76))
        p.addQuadCurve(to: CGPoint(x: w * 0.86, y: h * 0.52),
                       control: CGPoint(x: w * 0.82, y: h * 0.74))
        p.addQuadCurve(to: CGPoint(x: w * 0.58, y: h * 0.62),
                       control: CGPoint(x: w * 0.72, y: h * 0.52))
        p.addQuadCurve(to: CGPoint(x: w * 0.28, y: h * 0.56),
                       control: CGPoint(x: w * 0.42, y: h * 0.56))
        p.closeSubpath()
        return p
    }
}

/// 嘴线（微笑弧线）
private struct DolphinMouthShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.88, y: h * 0.50))
        p.addQuadCurve(to: CGPoint(x: w * 0.72, y: h * 0.58),
                       control: CGPoint(x: w * 0.82, y: h * 0.58))
        return p
    }
}
