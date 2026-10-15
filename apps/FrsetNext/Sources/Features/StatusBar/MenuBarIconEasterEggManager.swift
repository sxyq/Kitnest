import AppKit
import Foundation

// MARK: - 图标彩蛋（Symbol Mode Easter Egg，spec 13 §6）
//
// 原作触发器是「连续拒绝付费弹窗 10 次」（rejectCountInCurrentProcess，0x100640488 cmp #0xa）；
// 重建版无 Paywall，触发器按任务书改造为「连续单击状态栏主图标 10 次」。
// 触发链（spec §6.2 逐条对齐）：
//   第 1 次  → 气泡「🤫 This is not a button. Probably.」
//   第 2-8 次 → phaseOne/Two/Three 语录队列（原作 ⬜ 清单未完整探明，spec §11.3，重建版留空静默）
//   第 9 次  → 气泡「🎁 Well. Since you insisted... here you go.」
//   第 10 次 → unlock()：置 custom_icon_easter_egg_unlocked → 撒彩带 → 弹解锁庆祝对话框
//   拒庆祝框 → 「Fine. I'm officially ignoring you now. Enjoy the silence. 🤫」+ hasShownIgnoreIntro
//
// 字段命名对应原作 fieldDescriptor（spec §6.4）：rejectCountInCurrentProcess /
// hasShownIgnoreIntro / phaseOne|Two|ThreeQueue / bubbleDisplayDuration 等。

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
    /// 「已展示过拒绝后的静默语录」标记（原作 hasShownIgnoreIntro，spec §6.2 末行）
    private static let ignoreIntroShownKey = "easterEggHasShownIgnoreIntro"
    /// 解锁所需连续单击次数（原作第 10 次拒绝触发解锁）
    private static let requiredClicks = 10

    /// 拒绝解锁庆祝框后的静默语录（原作 §6.2 逐字原文）
    private static let ignoreQuote = "Fine. I'm officially ignoring you now. Enjoy the silence. 🤫"

    /// 已捕获的拒绝语录（原作 §6.2：第 1 次 / 第 9 次；2-8 次语录队列未探明，保持静默）
    private static let firstRejectQuote = "🤫 This is not a button. Probably."
    private static let ninthRejectQuote = "🎁 Well. Since you insisted... here you go."

    // MARK: 时长常量（对应原作 4 个存储属性，spec §6.4；值待实机校准 ⚠️）
    /// 气泡展示时长（对应 bubbleDisplayDuration，原作疑为 3.0）
    private static let bubbleDisplayDuration: TimeInterval = 3.0
    /// 气泡消失动画时长（对应 bubbleDismissAnimationDuration，原作疑为 0.25）
    private static let bubbleDismissAnimationDuration: TimeInterval = 0.25
    /// 解锁撒彩带提前量（对应 unlockConfettiLeadDuration，原作疑为 1.0）
    private static let unlockConfettiLeadDuration: TimeInterval = 1.0
    /// 图标动画锁定时长（对应 iconAnimationLockDuration，原作疑为 1.0）
    private static let iconAnimationLockDuration: TimeInterval = 1.0

    // MARK: 状态（对应原作字段）

    /// 本进程内累计的连续单击次数（对应 rejectCountInCurrentProcess）
    private var clickCountInCurrentProcess = 0
    /// 三段拒绝语录队列（原作 phaseOne/Two/ThreeMessages；清单 ⬜ 未探明，重建版留空）
    private var phaseOneQueue: [String] = []
    private var phaseTwoQueue: [String] = []
    private var phaseThreeQueue: [String] = []
    /// 是否已展示过「静默语录」（对应 hasShownIgnoreIntro）
    private var hasShownIgnoreIntro: Bool {
        get { UserDefaults.standard.bool(forKey: Self.ignoreIntroShownKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.ignoreIntroShownKey) }
    }
    /// 动画锁（对应 isAnimationLocked / animationLockWorkItem：锁定期内不接受新的彩蛋动作）
    private var isAnimationLocked = false
    private var animationLockWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: 对外状态

    /// 是否已解锁（消费点：主菜单/设置页显示「自定义菜单栏图标」选项，对应 revealCustomMenuBarIconOption）
    var isUnlocked: Bool {
        UserDefaults.standard.bool(forKey: Self.unlockedKey)
    }

    /// 主图标左键单击计数（由 StatusBarController.mainItemClicked 调用）
    func registerMainIconClick() {
        guard !isAnimationLocked else { return }
        clickCountInCurrentProcess += 1
        switch clickCountInCurrentProcess {
        case 1:
            showBubble(Self.firstRejectQuote)
        case Self.requiredClicks - 1:
            showBubble(Self.ninthRejectQuote)
        case Self.requiredClicks:
            unlock()
        case 2...Self.requiredClicks - 2:
            // 2-8 次：phaseOne/Two/Three 语录队列未探明（spec §11.3），队列为空时静默
            if let quote = nextPhaseMessage() { showBubble(quote) }
        default:
            break
        }
    }

    // MARK: 气泡（原作 AboutEasterEggBubble）

    /// 展示一条语录气泡（3.0s 后自动消失，对应 bubbleDisplayDuration）
    private func showBubble(_ text: String) {
        MenuBarIconEasterEggOverlayController.shared.presentBubble(text, duration: Self.bubbleDisplayDuration)
    }

    /// 依拒绝次数取下一条语录（phaseOne 2-3 / phaseTwo 4-6 / phaseThree 7-8，对应 spec §6.2 分段）
    private func nextPhaseMessage() -> String? {
        let index = clickCountInCurrentProcess - 2
        let queue: [String]
        switch clickCountInCurrentProcess {
        case 2...3:   queue = phaseOneQueue
        case 4...6:   queue = phaseTwoQueue
        default:      queue = phaseThreeQueue
        }
        guard index >= 0, index < queue.count else { return nil }
        return queue[index]
    }

    // MARK: 解锁

    /// 解锁：置持久化 → 撒彩带 → 弹解锁庆祝对话框（spec §6.2 第 10 次分支 0x100640d2c）
    private func unlock() {
        guard !isUnlocked else { return }
        UserDefaults.standard.set(true, forKey: Self.unlockedKey)
        lockAnimation()

        if Self.unlockConfettiLeadDuration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.unlockConfettiLeadDuration) {
                self.presentUnlockCelebration()
            }
        } else {
            presentUnlockCelebration()
        }
        // 解锁后图标样式系统立即生效（此时 custom 选项已可见）
        MenuBarIconStyleApplier.shared.refresh()
        Log.info("StatusBar", "图标彩蛋已解锁（连续单击主图标 \(Self.requiredClicks) 次）")
    }

    /// 解锁庆祝对话框（spec §6.3「unlock（庆祝）」）：🏆 Fine, You Win! + 撒彩带
    private func presentUnlockCelebration() {
        let dialog = MenuBarIconEasterEggDialog(kind: .unlock, isCelebration: true)
        MenuBarIconEasterEggOverlayController.shared.present(
            dialog: dialog,
            onConfirm: { [weak self] in
                // 确认 → 打开设置页的图标选项区（解锁后的自定义图标在设置里选）
                // 注：对话框的收窗由 present(dialog:) 内部统一处理（fireOnce 去重），此处不再调dismissDialog
                ServiceLocator.settings?.open(pane: "general")
                self?.clickCountInCurrentProcess = 0
            },
            onCancel: { [weak self] in
                // 拒庆祝框 → 静默语录 + hasShownIgnoreIntro（spec §6.2 末行）
                self?.showIgnoreIntro()
                self?.clickCountInCurrentProcess = 0
            }
        )
    }

    /// 拒绝解锁庆祝框后的静默语录（对应 hasShownIgnoreIntro）
    private func showIgnoreIntro() {
        hasShownIgnoreIntro = true
        Toast.show(Self.ignoreQuote, icon: "face.smiling.inverse")
    }

    // MARK: 动画锁

    private func lockAnimation() {
        isAnimationLocked = true
        animationLockWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.isAnimationLocked = false }
        animationLockWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.iconAnimationLockDuration, execute: item)
    }

    // MARK: - 对话框文案（原作 §6.3 原文；消费点：MenuBarIconEasterEggDialogCopy）

    func dialogText(for kind: MenuBarIconEasterEggDialogKind) -> String {
        MenuBarIconEasterEggDialogCopy.body(for: MenuBarIconEasterEggDialog(kind: kind, isCelebration: false))
    }

    /// 展示某一类彩蛋对话框（regret / hide / restore 由设置页的图标选项触发）
    func presentDialog(kind: MenuBarIconEasterEggDialogKind,
                       onConfirm: @escaping () -> Void,
                       onCancel: @escaping () -> Void = {}) {
        MenuBarIconEasterEggOverlayController.shared.present(
            dialog: MenuBarIconEasterEggDialog(kind: kind, isCelebration: false),
            onConfirm: { [weak self] in
                // 注：收窗由 present(dialog:) 统一处理（fireOnce 去重），此处不再调 dismissDialog
                onConfirm()
                self?.clickCountInCurrentProcess = 0
            },
            onCancel: { [weak self] in
                onCancel()
                self?.clickCountInCurrentProcess = 0
            }
        )
    }

    // MARK: - 一次性提示键落盘
    //
    // spec §6.2：拒绝解锁对话框后置 hasShownIgnoreIntro（键名 hasShownIgnoreIntro，
    // ⬜ 原作 defaults 键名未探明，此处自定 easterEggHasShownIgnoreIntro，注释标明）。
    // 注意：hasSeenDoubleTapShortcutTip_v1 属 specs/14 范围，本文件不涉及。

    /// 是否已展示过静默语录（供设置页/调试查询）
    var hasShownIgnoreIntroduction: Bool { hasShownIgnoreIntro }
}