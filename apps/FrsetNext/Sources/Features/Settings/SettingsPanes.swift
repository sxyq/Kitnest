import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - 设置模块自带的基础页签（通用 / 快捷键 / 关于）
// 其他模块（监测/剪贴板/搜索/AI/工具）的页签由各自模块注册，此处不引用。

// MARK: - 通用页

struct GeneralSettingsPane: View {
    // 直接用 AppStorage 读写 Preferences 约定的键，保证跨模块一致
    @AppStorage(Preferences.Keys.launchAtLogin) private var launchAtLogin = false
    @AppStorage(Preferences.Keys.menuBarIconsVisible) private var menuBarIconsVisible = true
    @AppStorage(Preferences.Keys.panelWidth) private var panelWidth: Double = 400
    @AppStorage(Preferences.Keys.panelHeight) private var panelHeight: Double = 700
    @Stored private var confirmClearData = false
    // 外观四选一 / 语言切换（specs/18 §5/§6）
    @ObservedObject private var appearance = AppearanceManager.shared
    @ObservedObject private var language = LanguageManager.shared
    /// 语言版本号：languageDidChange 到达时自增，驱动本视图重绘（契约 §10.3；
    /// 用 @Stored 而非 @State，见 CONTRACT §7.4）
    @Stored private var l10nVersion: Int = 0

    // MARK: 菜单栏图标样式（spec 13 §6：logo / fan / date / custom）
    //
    // 跨模块纪律：本页属Settings 模块，不得引用 StatusBar 模块的具体类型，
    // 因此这里只按 spec 13 §6.1 的实证 defaults 键名直接读写 UserDefaults；
    // 状态栏侧（MenuBarIconStyleStore / MenuBarIconStyleApplier）消费同一批键。
    @AppStorage(Self.menuBarIconStyleLogoKey) private var iconStyleLogo = false
    @AppStorage(Self.menuBarIconStyleFanKey) private var iconStyleFan = false
    @AppStorage(Self.menuBarIconStyleDateKey) private var iconStyleDate = false
    @AppStorage(Self.menuBarIconStyleCustomKey) private var iconStyleCustom = false
    @AppStorage(Self.menuBarIconCustomSymbolKey) private var iconCustomSymbol = Self.defaultCustomSymbol
    /// 图标彩蛋解锁键（原作 custom_icon_easter_egg_unlocked）；解锁后才出现「自定义图标」
    @AppStorage(Self.easterEggUnlockedKey) private var easterEggUnlocked = false
    /// 是否展示自定义图标选项（原作 revealCustomMenuBarIconOption；未落盘时默认展示）
    @AppStorage(Self.revealCustomIconOptionKey) private var revealCustomIconOption = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 外观（四选一 radio：系统/浅色/深色/Midnight；键 appearance）
            SettingsSection(title: L10n.t("Appearance")) {
                SettingsGroupBox {
                    HStack(spacing: 10) {
                        ForEach(AppearanceMode.allCases) { mode in
                            appearanceRadio(mode)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            }

            // 语言（跟随系统 + 22 语言；键 language，切换即时生效）
            SettingsSection(title: L10n.t("Language")) {
                SettingsGroupBox {
                    SettingsRow(icon: "globe",
                                title: "显示语言",              // TODO 待本地化：原作 793 键无对应键面
                                subtitle: "切换后立即生效，无需重启应用") {  // TODO 待本地化：原作 793 键无此句
                        Picker("", selection: languageBinding) {
                            Text(L10n.t("Auto")).tag("auto")
                            ForEach(LanguageManager.availableLanguages, id: \.self) { code in
                                Text(LanguageManager.displayNames[code] ?? code).tag(code)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 180)
                    }
                }
            }

            // 启动
            SettingsSection(title: L10n.t("Start")) {
                SettingsGroupBox {
                    SettingsToggleRow(
                        icon: "power",
                        title: "开机启动",
                        subtitle: "登录 macOS 后自动在后台启动 FrsetNext",
                        isOn: launchAtLoginBinding
                    )
                }
            }

            // 面板
            SettingsSection(title: "主面板") {
                SettingsGroupBox {
                    SettingsRow(icon: "rectangle.expand.vertical", title: "面板尺寸",
                                subtitle: "主面板默认显示宽高（像素）") {
                        VStack(alignment: .trailing, spacing: 4) {
                            Stepper("宽 \(Int(panelWidth))", value: $panelWidth, in: 320...720, step: 20)
                                .font(.system(size: 12))
                                .fixedSize()
                            Stepper("高 \(Int(panelHeight))", value: $panelHeight, in: 480...900, step: 20)
                                .font(.system(size: 12))
                                .fixedSize()
                        }
                    }
                }
            }

            // 菜单栏
            SettingsSection(title: "菜单栏") {   // TODO 待本地化：原作键为 "Menu Bar Icon"=菜单栏图标，语义不完全对应
                SettingsGroupBox {
                    SettingsToggleRow(
                        icon: "menubar.rectangle",
                        title: L10n.t("Show Menu Bar Icon"),
                        subtitle: "关闭后仅可通过快捷键唤起（由状态栏模块响应）",  // TODO 待本地化
                        isOn: $menuBarIconsVisible
                    )
                    SettingsDivider()
                    SettingsRow(icon: "square.stack.3d.up", title: "菜单栏图标样式",
                                subtitle: menuBarIconStyleHint) {
                        Picker("", selection: menuBarIconStyleBinding) {
                            ForEach(Self.menuBarIconStyleOptions(unlocked: easterEggUnlocked,
                                                                  revealsCustom: revealsCustomMenuBarIcon),
                                    id: \.title) { option in
                                // 展示名走本地化，tag 仍用内部标识
                                Text(Self.menuBarIconStyleDisplayName(option.title)).tag(option.title)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 160)
                    }
                    if currentMenuBarIconStyle == Self.menuBarIconStyleCustom {
                        SettingsDivider()
                        SettingsRow(icon: "wand.and.stars", title: "自定义图标名称",
                                    subtitle: "填写 SF Symbol 名（如 sparkles、fan.fill）") {
                            TextField("", text: customMenuBarSymbolBinding)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .frame(width: 160)
                        }
                    }
                }
            }

            // 数据
            SettingsSection(title: "数据") {
                SettingsGroupBox {
                    SettingsRow(icon: "folder", title: "数据目录",   // TODO 待本地化：原作键 "Storage Path"=存储路径，语义不完全对应
                                subtitle: AppDirectories.base.path) {
                        Button(L10n.t("Show_in_Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([AppDirectories.base])
                        }
                        .controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(icon: "trash", title: "清除数据",   // TODO 待本地化
                                subtitle: "删除本地数据库、图片缓存等全部数据，操作不可恢复") {  // TODO 待本地化
                        Button("清除…", role: .destructive) { confirmClearData = true }   // TODO 待本地化
                            .controlSize(.small)
                    }
                    .confirmationDialog("确认清除全部数据？",   // TODO 待本地化
                                        isPresented: $confirmClearData,
                                        titleVisibility: .visible) {
                        Button("清除全部数据", role: .destructive, action: clearAllData)   // TODO 待本地化
                        Button(L10n.t("Cancel"), role: .cancel) {}
                    } message: {
                        Text("将删除 \(AppDirectories.base.path) 下的所有内容（含剪贴板历史与缓存），此操作不可恢复。")  // TODO 待本地化
                    }
                }
            }
        }
        // 语言切换即时刷新（契约 §10.3）：LanguageManager.apply 广播 languageDidChange，
        // 这里自增版本号触发 body 重算 → 重新求值所有 L10n.t()
        .onReceive(NotificationCenter.default.publisher(for: LanguageManager.languageDidChange)) { _ in
            l10nVersion &+= 1
        }
    }

    // MARK: 菜单栏图标样式（spec 13 §6.1 偏好键 + §6 样式语义）

    /// 图标样式四键（原作实证键名）
    static let menuBarIconStyleLogoKey = "menu-bar-icon-logo"
    static let menuBarIconStyleFanKey = "menu-bar-icon-fan"
    static let menuBarIconStyleDateKey = "menu-bar-icon-date"
    static let menuBarIconStyleCustomKey = "menu-bar-icon-custom"
    /// 自定义 Symbol 名键（⬜ 原作键名未探明，重建侧自定）
    static let menuBarIconCustomSymbolKey = "menu-bar-icon-custom-symbol"
    /// 图标彩蛋解锁键（原作 custom_icon_easter_egg_unlocked）
    static let easterEggUnlockedKey = "custom_icon_easter_egg_unlocked"
    /// 是否展示自定义图标选项（原作 revealCustomMenuBarIconOption）
    static let revealCustomIconOptionKey = "revealCustomMenuBarIconOption"
    static let defaultCustomSymbol = "sparkles"

    // MARK: 样式**内部标识**（Picker tag / switch 匹配用，不是展示文案）
    //
    // 这三个常量同时充当 Picker 的 tag 与各处 switch 的匹配值，因此**不得**本地化——
    // 一旦随语言变化，menuBarIconStyleBinding 的 switch 会失配、四布尔键写错档。
    // 展示文案另走 `menuBarIconStyleDisplayName(_:)`。
    static let menuBarIconStyleLogo = "Logo"
    static let menuBarIconStyleFan = "动态风扇"
    static let menuBarIconStyleDate = "日期"
    static let menuBarIconStyleCustom = "自定义图标"

    /// 样式内部标识 → 展示文案（本地化在展示层做，不污染 tag）
    private static func menuBarIconStyleDisplayName(_ id: String) -> String {
        switch id {
        case menuBarIconStyleFan:     return L10n.t("Dynamic Fan Icon")   // 动态风扇图标
        case menuBarIconStyleDate:    return "日期"                        // TODO 待本地化：原作无独立"日期"样式键
        case menuBarIconStyleCustom:  return "自定义图标"                  // TODO 待本地化：同上
        default:                      return L10n.t("Menu Bar Icon Logo")  // Logo
        }
    }

    /// 是否展示自定义图标（需彩蛋已解锁，且未被 hide 对话框隐藏）
    private var revealsCustomMenuBarIcon: Bool {
        easterEggUnlocked && revealCustomIconOption
    }

    /// 可选样式（custom 仅在彩蛋解锁且未被隐藏时出现，对应原作 revealCustomMenuBarIconOption）
    /// 返回的 title 是**内部标识**（Picker tag），展示时经 menuBarIconStyleDisplayName 转换
    static func menuBarIconStyleOptions(unlocked: Bool, revealsCustom: Bool) -> [(title: String, key: String)] {
        var options = [(menuBarIconStyleLogo, menuBarIconStyleLogoKey),
                       (menuBarIconStyleFan, menuBarIconStyleFanKey),
                       (menuBarIconStyleDate, menuBarIconStyleDateKey)]
        if unlocked && revealsCustom {
            options.append((menuBarIconStyleCustom, menuBarIconStyleCustomKey))
        }
        return options
    }

    /// 当前选中的样式**内部标识**（全false / 多 true 时取 Logo）
    private var currentMenuBarIconStyle: String {
        if iconStyleCustom { return Self.menuBarIconStyleCustom }
        if iconStyleFan { return Self.menuBarIconStyleFan }
        if iconStyleDate { return Self.menuBarIconStyleDate }
        return Self.menuBarIconStyleLogo
    }

    /// 当前样式的说明文案（动态风扇：图标转速随 CPU 使用率动态调整）
    ///
    /// 注意：switch 的匹配值是**内部标识**（中文常量），不是展示文案；
    /// 展示文案才过 L10n，避免本地化后 switch 失配（改动此处务必同步 menuBarIconStyleBinding）。
    private var menuBarIconStyleHint: String {
        switch currentMenuBarIconStyle {
        case Self.menuBarIconStyleFan:     return L10n.t("Fan icon speed changes with CPU usage")
        case Self.menuBarIconStyleDate:    return "在菜单栏显示当前日期"        // TODO 待本地化
        case Self.menuBarIconStyleCustom:  return "使用自定义 SF Symbol 图标"    // TODO 待本地化
        default:                           return "应用图标"                  // TODO 待本地化
        }
    }

    /// 样式选择绑定：只置目标键、清其余三键（四布尔键语义，对齐原作 menu-bar-icon-*）
    private var menuBarIconStyleBinding: Binding<String> {
        Binding(
            get: { currentMenuBarIconStyle },
            set: { title in
                iconStyleLogo = false
                iconStyleFan = false
                iconStyleDate = false
                iconStyleCustom = false
                switch title {
                case Self.menuBarIconStyleFan:    iconStyleFan = true
                case Self.menuBarIconStyleDate:   iconStyleDate = true
                case Self.menuBarIconStyleCustom: iconStyleCustom = true
                default:                           iconStyleLogo = true
                }
            }
        )
    }

    private var customMenuBarSymbolBinding: Binding<String> {
        Binding(
            get: {
                let trimmed = iconCustomSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? Self.defaultCustomSymbol : trimmed
            },
            set: { iconCustomSymbol = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    // MARK: 外观四选一 radio（specs/18 §5：系统/浅色/深色/Midnight，键 appearance）

    /// 外观档位的本地化标题。
    /// AppearanceManager.swift 属他人领地不可改，故在此消费点按原始值映射到原作 L10n 键面
    /// （"Auto"=跟随系统 / "System"=系统 / "Light"=浅色 / "Dark"=深色 / "Midnight"）。
    private func appearanceTitle(_ mode: AppearanceMode) -> String {
        switch mode {
        case .system:   return L10n.t("System")
        case .light:    return L10n.t("Light")
        case .dark:     return L10n.t("Dark")
        case .midnight: return L10n.t("Midnight")
        }
    }

    private func appearanceRadio(_ mode: AppearanceMode) -> some View {
        let isSelected = appearance.mode == mode
        let title = appearanceTitle(mode)
        return Button {
            appearance.apply(mode)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Image(systemName: mode.systemImage)
                    .font(.system(size: 16))
                Text(title)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallRadius)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: 语言切换绑定（LanguageManager.apply 写 defaults "language" 并广播 languageDidChange）

    private var languageBinding: Binding<String> {
        Binding(
            get: { language.overrideDisplayLanguage },
            set: { LanguageManager.shared.apply($0) }
        )
    }

    // MARK: 开机启动（SMAppService，macOS 13+；注册失败时回滚开关状态）

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                guard #available(macOS 13.0, *) else {
                    Log.warn("Settings", "SMAppService 需 macOS 13+，开机启动不可用")
                    return
                }
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLogin = enabled
                } catch {
                    // 非 App Bundle 运行（如裸可执行文件调试）时会抛错，保持开关不动
                    Log.warn("Settings", "开机启动设置失败: \(error.localizedDescription)")
                }
            }
        )
    }

    // MARK: 清除数据（危险操作，已二次确认）

    private func clearAllData() {
        let fm = FileManager.default
        let base = AppDirectories.base
        do {
            if fm.fileExists(atPath: base.path) {
                try fm.removeItem(at: base)
            }
            _ = AppDirectories.base // 重新创建空目录
            Log.warn("Settings", "已清除全部本地数据: \(base.path)")
        } catch {
            Log.error("Settings", "清除数据失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - 关于页

struct AboutSettingsPane: View {
    /// 应用名（Bundle 缺失时回退）
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "FrsetNext"
    }
    /// 版本号（Bundle 缺失时显示 1.0.0）
    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (v?.isEmpty == false) ? v! : "1.0.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 应用信息
            SettingsGroupBox {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .cornerRadius(Theme.cornerRadius)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appName)
                            .font(.system(size: 17, weight: .semibold))
                        Text("版本 \(appVersion)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }

            // 工程说明
            SettingsSection(title: "关于本工程") {
                SettingsGroupBox {
                    SettingsRow(icon: "hammer", title: "正向重建工程",
                                subtitle: "基于逆向分析结论，使用原生技术栈正向重写的开源版本") {}
                    SettingsDivider()
                    SettingsRow(icon: "chevron.left.forwardslash.chevron.right", title: "技术栈",
                                subtitle: "Swift 5 / AppKit + SwiftUI / Combine / libsqlite3") {}
                }
            }

            // 许可与链接
            SettingsSection(title: "许可") {
                SettingsGroupBox {
                    SettingsRow(icon: "doc.text", title: "开源许可",
                                subtitle: "本工程以开源许可证发布，感谢所有开源项目的启发") {}
                    SettingsDivider()
                    SettingsRow(icon: "link", title: "GitHub 项目主页",
                                subtitle: "源码与问题反馈（占位链接，待发布后替换）") {
                        if let url = URL(string: "https://github.com/frset/frset-next") {
                            Link("前往", destination: url)
                                .controlSize(.small)
                        }
                    }
                }
            }

            Text("正向重建 · 致敬原作 Frset")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
