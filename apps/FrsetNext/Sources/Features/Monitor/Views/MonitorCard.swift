import SwiftUI

/// 材质容器与无服务依赖的图形分开，正式界面继续使用原有材质。
public struct MonitorCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(10)
            // 普通内容卡统一走 `.surface(.card)`（= glassCard）：实色轻填充 + 发丝边，
            // 不叠阴影不叠模糊（原 GlassCardBackground 带 6/2 投影，已按 v285 收敛）。
            .surface(.card, radius: Theme.Radius.card)
    }
}
