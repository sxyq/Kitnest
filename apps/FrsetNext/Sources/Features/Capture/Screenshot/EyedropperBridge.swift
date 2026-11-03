import Foundation

// MARK: - 「工具箱 → 取色器」程序化接缝

/// 取色器的可等待入口。
///
/// 背景：原作取色器同时挂在工具箱体系（`Models.ToolKind.colorPicker`），但重建版的
/// 跨模块契约（CONTRACT §1.3）禁止 Toolbox 直接引用 `Eyedropper` 的具体类型。
/// 这里暴露一个与 UI 无关的纯 async 函数，由 App 层在向 ToolRegistry 注册
/// 「取色器」工具时调用，取色完成后把 HEX 作为工具结果回流。
///
/// 实现刻意复用 `Eyedropper` 既有的会话机制（同一套 overlay / 放大镜 / 取消判定），
/// 不另起 UI，也不改变手动取色的任何行为。
public enum EyedropperPickBridge {

    /// 启动取色会话并等待一次结果。
    ///
    /// - Returns: 十六进制颜色字符串（如 `"#A1B2C3"`）；用户取消（Esc / 右键 / 点击空图）、
    ///   缺少屏幕录制权限、或无可用屏幕时返回 `nil`。
    ///
    /// 保证：`continuation` 恰好 resume 一次，绝不悬挂——所有终止路径都会回到
    /// `Eyedropper.pickColor(completion:)` 的单次回调上；同时重复调用会先以 `nil`
    /// 结束上一个未完成的等待者。
    public static func pickColor() async -> String? {
        await withCheckedContinuation { continuation in
            // 取色会话必须在主线程建立（NSEvent / NSApp / 窗口），且不能阻塞调用方
            DispatchQueue.main.async {
                Eyedropper.shared.pickColor { hex in
                    continuation.resume(returning: hex)
                }
            }
        }
    }
}
