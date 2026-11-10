import SwiftUI

// MARK: - 「截图」分类的单块设置页（v271）
//
// 演进：v234 截图独立成一级 → v261 截图/钉图/图帘各占一个页签 →
// v262 三页签合并成一页长滚动（用户当时要「全都放在同一个设置栏里」）→
// v271 用户对着「截图」段说「这些选项都进行拆分」，并选择「拆回侧边栏独立项」。
//
// 现在：截图 / 钉图 / 图帘 / 录屏 / 工作流 各自是侧边栏的一项，
// 本视图只渲染其中一块——标题、副标题与 `CaptureSettingsBlock` 共用一份口径，
// 不再有「滚到第几段」的锚点逻辑（`captureSub` 已删除）。

struct CaptureBlockPage: View {
    let block: CaptureSettingsBlock

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                header
                content
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 页头（标题在 SettingsRootView.header，这里只补一句作用域说明 + 发丝分隔）
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(block.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .capture:   CaptureSettingsPane()
        case .pin:       PinSettingsPane()
        case .curtain:   CurtainSettingsPane()
        case .recording: RecordingSettingsPane()
        case .workflow:  WorkflowSettingsPane()
        }
    }
}
