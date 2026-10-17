import AppKit
import Foundation

/// 主面板模块入口。App 层调用 PanelModule.start()（经 ModuleRegistry 统一启动）。
public enum PanelModule: AppModule {
    public static let identifier = "panel"

    public static func start() {
        // 创建面板并注入 ServiceLocator，供状态栏（08）与热键模块经
        // ServiceLocator.panel?.toggle()/show()/hide() 开合面板
        PanelController.shared.prepare()
        ServiceLocator.panel = PanelController.shared
        // 预览呈现能力注入（specs/12 契约面）：Clipboard 经
        // ServiceLocator.panelPreview 协议调用，不引用 Panel 具体类型（CONTRACT §1.3）
        ServiceLocator.panelPreview = PanelPreviewPresenterAdapter()

        // 排障探针：FRSET_JSON_PROBE=<json 文件路径|clip> 时，启动 2s 后直接打开 JSON 检视器。
        // 用于无鼠标环境下验证窗口/树表渲染（拖放与点击的最终落点就是这个方法）。
        if let target = ProcessInfo.processInfo.environment["FRSET_JSON_PROBE"], !target.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if target == "clip", let text = NSPasteboard.general.string(forType: .string) {
                    Log.info("Panel", "JSON 探针：用剪贴板内容打开检视器（\(text.count) 字符）")
                    JSONInspectorWindowController.shared.open(text: text, title: "剪贴板 JSON")
                } else {
                    Log.info("Panel", "JSON 探针：打开文件 \(target)")
                    JSONInspectorWindowController.shared.open(fileURL: URL(fileURLWithPath: target))
                }
            }
        }
    }
}
