import Foundation

/// 启动期排障开关：只读 `ProcessInfo`，不写任何持久状态、不改默认行为。
///
/// 存在的原因：无人值守截图/录屏时，面板与存储窗的 `NSApp.activate` 会把用户
/// 当前前台 app 的焦点抢走。带上 `--no-activate` 后这两个窗口只 `orderFrontRegardless`
/// 上屏，不激活 app、不拿 key——前台 app、键盘焦点、鼠标位置全部不变。
///
/// 用法：`open -g -a /Applications/Kitnest.app --args --panel-pin --no-activate`
/// （`-g` 让 launch 本身也不把 app 带到前台；`--panel-pin` 防止失焦即收起。）
enum DebugLaunch {

    /// 面板/存储窗只上屏，不激活 app、不抢 key。
    /// 两种开启方式：启动参数 `--no-activate`（推荐，随进程生效一次），
    /// 或 `defaults write com.sxyq.frsetnext probe.noActivate -bool true`
    /// （已在运行的实例也能即时读取；验完记得删掉这个键）。
    static var noActivate: Bool {
        if ProcessInfo.processInfo.arguments.contains("--no-activate") { return true }
        return UserDefaults.standard.bool(forKey: "probe.noActivate")
    }
}
