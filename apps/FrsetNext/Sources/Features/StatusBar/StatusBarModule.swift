import Foundation

// MARK: - 模块入口

/// StatusBarModule：菜单栏与图标体系
/// start() 安装状态栏（主图标 + 注册表动态状态项）并预热文件类型图标缓存
public enum StatusBarModule: AppModule {
    public static let identifier = "statusbar"

    public static func start() {
        StatusBarController.shared.install()
        _ = FileTypeIconProvider.shared
        Log.info("StatusBar", "module started")
    }
}
