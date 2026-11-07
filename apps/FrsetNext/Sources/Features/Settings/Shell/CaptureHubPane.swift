import SwiftUI

// MARK: - 「截图与钉图」总页
//
// v262 之前这里是三个页签：截图 / 钉图 / 图帘（原名悬挂架）。用户的要求是
// 「截图设置、钉图设置、图帘的效果全都放在当前这个设置栏里面」——
// 三页签每次只能看到一部分，调完钉图描边想再调截图水印得来回切。
//
// 合并成一页之后：一路滚下来就能看到所有截图相关设置，
// 侧边栏搜索和深链仍然能定位（用 `scrollTo` 锚点，不再切页签）。

struct CaptureHubPane: View {
    /// 0 = 截图，1 = 钉图，2 = 图帘。由深链/搜索写入，本页只负责滚过去。
    @Binding var scrollTarget: Int

    private let anchors = ["capture.block.capture", "capture.block.pin", "capture.block.curtain"]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 30) {
                    block(title: "截图",
                          subtitle: "保存位置、截图后动作、水印、文字识别",
                          anchor: anchors[0]) {
                        CaptureSettingsPane()
                    }
                    block(title: "钉图",
                          subtitle: "钉住之后的边框、圆角、投影与工具条",
                          anchor: anchors[1]) {
                        PinSettingsPane()
                    }
                    block(title: "图帘",
                          subtitle: "截图后挂到屏幕顶边的帘线上，临时暂存",
                          anchor: anchors[2]) {
                        CurtainSettingsPane()
                    }
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { jump(proxy, animated: false) }
            .onChange(of: scrollTarget) { _ in jump(proxy, animated: true) }
        }
    }

    private func jump(_ proxy: ScrollViewProxy, animated: Bool) {
        guard anchors.indices.contains(scrollTarget) else { return }
        let anchor = anchors[scrollTarget]
        let action = { proxy.scrollTo(anchor, anchor: .top) }
        if animated {
            withAnimation(Theme.Motion.spring) { action() }
        } else {
            // 首次进入时视图还没布局完，scrollTo 会打到空处，延一帧
            DispatchQueue.main.async { action() }
        }
    }

    @ViewBuilder
    private func block<Content: View>(title: String,
                                      subtitle: String,
                                      anchor: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
            content()
        }
        .id(anchor)
    }
}
