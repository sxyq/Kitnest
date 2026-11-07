import AppKit

// MARK: - 标准窗口红绿灯（v205）
//
// 用户：「其他界面也需要去统一这种红绿灯按钮，单独的界面……这种其他的有
// 单独窗口的都需要添加这种红绿灯，全部进行统一」。
//
// v205 之前：所有内容窗用自绘灰圆钮 + 把系统红/黄/绿 alpha 置 0。
// 现在统一回 macOS 标准 traffic lights：
//   · 拆除自绘圆钮（历史实例一并清理）
//   · 红/黄/绿 alpha 恢复 1；窗口能力允许的按钮自然可点，
//     固定尺寸窗口的黄/绿由系统置灰——三颗灯的形状/位置仍是统一的。
//
// 边界：hover 剪贴板预览是 .borderless 无边框窗，不调用本方法，
// 保持「没有标题栏 / 没有红绿灯」的贴附预览形态；只有独立内容窗才用红绿灯。

private var roundCloseButtonKey: UInt8 = 0

extension NSWindow {
    /// 恢复系统红黄绿三钮（幂等；可重复调用）
    func restoreStandardTrafficLights() {
        if let legacy = objc_getAssociatedObject(self, &roundCloseButtonKey) as? NSButton {
            legacy.removeFromSuperview()
            objc_setAssociatedObject(self, &roundCloseButtonKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
        // v260（红绿灯「颜色分层」根因）：旧版把三颗灯 alpha 置 0，这里无条件
        // `alphaValue = 1` 恢复。但 layer-backed 视图上赋值会重建 CALayer，
        // 三颗灯因此脱离窗口统一渲染通道、被单独合成，边缘出现错位/分层。
        // v260 补：只有确实被置过 0 时才赋值；正常窗口一次都不碰 CALayer。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for button in [standardWindowButton(.closeButton),
                       standardWindowButton(.miniaturizeButton),
                       standardWindowButton(.zoomButton)] {
            button?.isHidden = false
            if let b = button, b.alphaValue != 1 { b.alphaValue = 1 }
        }
        CATransaction.commit()
    }

}
