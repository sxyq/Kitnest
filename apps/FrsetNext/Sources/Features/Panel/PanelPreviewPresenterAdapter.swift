import AppKit
import Foundation

// MARK: - PanelPreviewPresenting 适配器（specs/12 契约面）
//
// Clipboard 模块禁止直接引用 Panel 模块的 MainPanelPreviewPopoverCoordinator
// （CONTRACT §1.3）。本适配器在 Panel 侧实现 Core/Registry.swift 的
// PanelPreviewPresenting 协议，逐方法转调协调器；Clipboard 侧一律经
// ServiceLocator.panelPreview 协议调用（注册点：PanelModule.start()）。

final class PanelPreviewPresenterAdapter: PanelPreviewPresenting {

    private let coordinator = MainPanelPreviewPopoverCoordinator.shared

    /// isFloatingSource → source（.floatingPreview / .mainPreview）；entry 固定 .mainList
    func presentPreview(for item: ClipboardItem,
                        anchorRectInWindow: CGRect?,
                        anchorView: NSView?,
                        isFloatingSource: Bool) -> Bool {
        coordinator.present(for: item,
                            anchorRectInWindow: anchorRectInWindow,
                            anchorView: anchorView,
                            source: isFloatingSource ? .floatingPreview : .mainPreview,
                            entry: .mainList)
    }

    /// 程序化关闭（reason 固定 .programmatic）
    func dismissPreview() {
        coordinator.dismiss(reason: .programmatic)
    }

    /// 行悬停调度：透传 hovering/item/anchorRectProvider（协议侧可为 nil，协调器侧兜底 { nil }）
    func rowHover(_ hovering: Bool,
                  item: ClipboardItem,
                  anchorRectProvider: (() -> CGRect?)?,
                  isFloatingSource: Bool) {
        coordinator.rowHover(hovering,
                             item: item,
                             source: isFloatingSource ? .floatingPreview : .mainPreview,
                             anchorProvider: anchorRectProvider ?? { nil })
    }

    /// 空格键键盘预览（带延时 WorkItem，透传）
    func requestKeyboardPreview(item: ClipboardItem,
                                anchorRectProvider: (() -> CGRect?)?) {
        coordinator.requestKeyboardPreview(item: item,
                                           anchorProvider: anchorRectProvider ?? { nil })
    }

    /// 取消未决的键盘预览（透传）
    func cancelKeyboardPreview() {
        coordinator.cancelKeyboardPreview()
    }

    /// 面板即将出现：清抑制与未决 WorkItem（透传）
    func prepareForPanelAppear() {
        coordinator.prepareForPanelAppear()
    }

    /// 刷新预览导航顺序表（透传）
    func setPreviewOrder(_ ids: [String]) {
        coordinator.setPreviewOrder(ids)
    }

    /// 锚条目被删除 → 同步关闭预览（透传）
    func notifyItemRemoved(itemID: String) {
        coordinator.notifyItemRemoved(itemID: itemID)
    }
}
