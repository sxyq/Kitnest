import SwiftUI

// MARK: - 面板过渡期的内容动效闸门（临时）
//
// 为什么需要它
// ------------
// 面板开合这一段过渡上原本叠着两条动效链：
//
//   ① GenieWarp（v237 起的主路径）：抓真窗快照 → 预渲染整条帧序列 →
//      覆盖窗用 CAKeyframeAnimation 逐帧播放 → 结束后把真窗 alpha 拉回 1；
//   ② 面板内容侧的 SwiftUI 动效（v74/v82 起的历史动效）：首个 page 挂载的
//      淡入（PanelRootView:703）、网盘链接条的纵向挤压（:732）、监测页内容的
//      offset 过渡（MonitorDetailView:75/101）。
//
// ②会在①抓完快照之后继续改内容，于是「预渲染的最后一帧」和「交接时的真窗」
// 不是同一个画面——用户看到的就是「两套动画在打架 / 收尾跳一下」。
//
// 处理办法：调神灯手感期间，先把②整体停掉，让这段过渡只由神灯负责。
// 默认关闭（`contentAnimationsDisabled == true`）；手感定稿后想恢复历史动效，
// 一条命令即可抬闸：
//
//     defaults write com.frset.frsetnext motion.panelContent -bool YES
//
enum PanelMotion {

    /// 内容侧历史动效是否整体停用。默认 true（临时关）；`motion.panelContent=YES` 恢复。
    static var contentAnimationsDisabled: Bool {
        let key = "motion.panelContent"
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return !UserDefaults.standard.bool(forKey: key)
    }

    /// 内容侧隐式动画统一入口：被闸掉时返回 nil，SwiftUI 视为「无动画」。
    static func animation(_ animation: Animation?) -> Animation? {
        contentAnimationsDisabled ? nil : animation
    }

    /// 内容侧 transition 统一入口：被闸掉时退化为 identity（不占位、不淡入）。
    static func transition(_ transition: AnyTransition) -> AnyTransition {
        contentAnimationsDisabled ? .identity : transition
    }

    /// 面板开合专属：展开/收起若走不了神灯（抓不到快照、被总开关关掉），
    /// 不再退到 WindowReveal 那套缩放动画，而是直接落位——
    /// 否则「神灯 + 缩放」两套会先后播一遍，就是用户说的重复播放。
    static var fallbackAnimationDisabled: Bool { contentAnimationsDisabled }
}
