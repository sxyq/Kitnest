import Foundation

/// 主面板模块入口。App 层调用 PanelModule.start()（经 ModuleRegistry 统一启动）。
public enum PanelModule: AppModule {
    public static let identifier = "panel"

    public static func start() {
        // 创建面板并注入 ServiceLocator，供状态栏（08）与热键模块经
        // ServiceLocator.panel?.toggle()/show()/hide() 开合面板
        PanelController.shared.prepare()
        ServiceLocator.panel = PanelController.shared
    }
}
