import SwiftUI

/// 主面板区段通用容器：标题 + 可选头部附件 + "查看全部" + 内容卡片。
/// 其他模块的区段内容经 PanelSectionRegistry（AnyView）注入后由本容器包裹渲染。
public struct PanelSectionView<Accessory: View, Content: View>: View {
    let title: String
    let accessory: () -> Accessory
    let content: () -> Content

    public init(title: String,
                @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
                @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Theme.sectionHeader(title)
                Spacer()
                accessory()
                Button {
                    // "查看全部"事件：区段归属模块可监听此通知展开完整列表（跨模块走通知，避免直接引用）
                    NotificationCenter.default.post(name: .panelSectionViewAll,
                                                    object: nil,
                                                    userInfo: ["section": title])
                } label: {
                    Text("查看全部")
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.cardBackground)
                .cornerRadius(Theme.smallRadius)
        }
    }
}

/// 区段事件通知名（供各模块监听）
public extension Notification.Name {
    /// 某区段的"查看全部"被点击；userInfo["section"] = 区段标题
    static let panelSectionViewAll = Notification.Name("panel.section.viewAll")
}
