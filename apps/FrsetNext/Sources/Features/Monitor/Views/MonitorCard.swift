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
            .background(GlassCardBackground(cornerRadius: Theme.cornerRadius))
    }
}
