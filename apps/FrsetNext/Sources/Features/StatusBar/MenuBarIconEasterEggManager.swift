import Foundation

// MARK: - 图标彩蛋（Symbol Mode Easter Egg，spec 13 §6）
//
// 原作触发器是「连续拒绝付费弹窗 10 次」（rejectCountInCurrentProcess，0x100640488 cmp #0xa）；
// 重建版无 Paywall，触发器按任务书改造为「连续单击状态栏主图标 10 次」。
// 原作 DialogKind（unlock/regret/hide/restore）的文案保留复用；中间语录队列（phaseOne/Two/Three）
// 在原作二进制中未完整探明（spec §11.3），已捕获的 5 条先行接线，其余留空。
// 完整的对话框浮层 / 彩带庆祝 / 自定义 Symbol 选择 UI 为 P2 待办（见交付回报）。

/// 彩蛋对话框类别（对应原作 CustomMenuBarIconEasterEggDialogKind）
enum MenuBarIconEasterEggDialogKind {
    case unlock       // 首次问询 / 解锁庆祝
    case regret       // 后悔（重新显示选项）
    case hide         // 隐藏选项
    case restore      // 恢复（hide 的逆操作）
}

/// 图标彩蛋管理器（对应原作 CustomMenuBarIconEasterEggManager，字段表见 spec §6.4）
final class MenuBarIconEasterEggManager {

    static let shared = MenuBarIconEasterEggManager()

    /// 解锁持久化键（原作 defaults 键，读写点 0x100308ed8）
    private static let unlockedKey = "custom_icon_easter_egg_unlocked"
    /// 解锁所需连续单击次数（原作第 10 次拒绝触发解锁）
    private static let requiredClicks = 10

    /// 解锁对话框文案（原作 §6.3「unlock（庆祝）」原文）
    private static let unlockTitle = "🏆 Fine, You Win!"
    private static let unlockBody = "Symbol Easter Egg Unlocked"

    /// 已捕获的拒绝语录（原作 §6.2：第 1 次 / 第 9 次；2-8 次语录队列未探明，保持静默）
    private static let firstRejectQuote = "🤫 This is not a button. Probably."
    private static let ninthRejectQuote = "🎁 Well. Since you insisted... here you go."

    /// 本进程内累计的连续单击次数（对应原作 rejectCountInCurrentProcess）
    private var clickCountInCurrentProcess = 0

    private init() {}

    /// 是否已解锁（供设置页显示自定义图标选项时查询，对应 revealCustomMenuBarIconOption）
    var isUnlocked: Bool {
        UserDefaults.standard.bool(forKey: Self.unlockedKey)
    }

    /// 主图标左键单击计数（由 StatusBarController.mainItemClicked 调用）
    func registerMainIconClick() {
        clickCountInCurrentProcess += 1
        switch clickCountInCurrentProcess {
        case 1:
            Toast.show(Self.firstRejectQuote)
        case Self.requiredClicks - 1:
            Toast.show(Self.ninthRejectQuote)
        case Self.requiredClicks:
            unlock()
        default:
            break   // 2-8 次：语录队列未探明，静默（spec §11.3）
        }
    }

    /// 解锁：持久化 + 通知条庆祝（原作此处还有撒彩带与解锁对话框浮层，P2 待办）
    private func unlock() {
        UserDefaults.standard.set(true, forKey: Self.unlockedKey)
        Toast.show("\(Self.unlockTitle) · \(Self.unlockBody)", icon: "sparkles")
    }

    // MARK: 对话框文案（原作 §6.3 原文保留，供 P2 对话框浮层直接取用）

    func dialogText(for kind: MenuBarIconEasterEggDialogKind) -> String {
        switch kind {
        case .unlock:
            return "I'll pretend you clicked 'Reject' by mistake. Do you want to unlock Symbol Mode and pick a symbol you like, or should I just go back to sleep?"
        case .regret:
            return "Want the Symbol option back? I can put it right where you left it."
        case .hide:
            return "Not feeling the symbol vibe anymore? We can hide the symbol option and pretend I never gave you anything in the first place."
        case .restore:
            return "Miss it already?"
        }
    }
}
