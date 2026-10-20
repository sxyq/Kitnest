import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - 设置模块自带的基础页签（通用 / 快捷键 / 关于）
// 其他模块（监测/剪贴板/搜索/AI/工具）的页签由各自模块注册，此处不引用。

// MARK: - 通用页

struct GeneralSettingsPane: View {
    /// v40 面板内嵌模式（主面板「主页 → 常规」）：左侧标题列收窄、宽行改分行布局——
    /// 面板内容区约 576pt，原 800pt 窗口版式（190pt 标题列 + 4 图标横排）放不下。
    var compact: Bool = false

    // 直接用 AppStorage 读写 Preferences 约定的键，保证跨模块一致
    @AppStorage(Preferences.Keys.launchAtLogin) private var launchAtLogin = false
    @AppStorage("showSystemStatus") private var showSystemStatus = true
    @AppStorage("showCalendar") private var showCalendar = true
    @AppStorage("automaticScreenshotOCREnabled") private var automaticScreenshotOCR = true
    /// 主面板是否显示「文件中转」入口（v40 侧边栏一级项）
    @AppStorage(Preferences.Keys.panelTransferDock) private var transferDockEnabled = true
    @Stored private var monitorRevision = 0
    // 外观四选一 / 语言切换（specs/18 §5/§6）
    @ObservedObject private var appearance = AppearanceManager.shared
    @ObservedObject private var language = LanguageManager.shared
    /// 语言版本号：languageDidChange 到达时自增，驱动本视图重绘（契约 §10.3；
    /// 用 @Stored 而非 @State，见 CONTRACT §7.4）
    @Stored private var l10nVersion: Int = 0
    /// 标签管理 sheet 呈现（原版「标签管理 [编辑]」行入口）
    @Stored private var isManagingTags = false
    /// 标签总管（复用现有 TagStore，不新建计数链路）
    @ObservedObject private var tagStore = TagStore.shared
    /// 忽略应用（隐私名单）修订号：Preferences 无观察者，用自增驱动重绘
    @Stored private var ignoredAppsRevision = 0

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
    /// 是否展示自定义图标选项（原作 revealCustomMenuBarIconOption；未落盘时默认展示）
    /// v83：彩蛋解锁门控已移除——自定义图标为常规功能，直接可用。
    @AppStorage(Self.revealCustomIconOptionKey) private var revealCustomIconOption = true

    var body: some View {
        // v71（用户：各设置界面版式不一致，需统一组件）：灰底全宽行 → 卡片分组
        // （SettingsSection + SettingsGroupBox，与剪贴板/数据页同一套组件）。
        // 外层滚动由 SettingsRootView.panePage 提供。
        VStack(spacing: 20) {
            // 排障探针（2026-10-20）：probe.settingsMenuBarFirst=1 时把「菜单栏」区
            // 临时置顶（正常顺序不变），便于截屏核对菜单栏图标行；默认不生效。
            if probeMenuBarFirst { menuBarSection }
            SettingsSection("通用") {
                SettingsGroupBox {
                    formRow(L10n.t("Start"), height: 40) {
                        Toggle(L10n.t("Launch Frset at login"), isOn: launchAtLoginBinding)
                            .toggleStyle(.checkbox)
                    }
                    SettingsDivider()
                    formRow(L10n.t("Appearance"), height: 40) {
                        appearanceChoices
                    }
                    SettingsDivider()
                    formRow(L10n.t("Language"), height: 48) {
                        Picker("", selection: languageBinding) {
                            Text(L10n.t("Auto")).tag("auto")
                            ForEach(LanguageManager.availableLanguages, id: \.self) { code in
                                Text(LanguageManager.displayNames[code] ?? code).tag(code)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 157)
                    }
                }
            }

            SettingsSection("个性化") {
                SettingsGroupBox {
                    PersonalizationSettingsView()
                        .padding(.vertical, 6)
                }
            }

            if !probeMenuBarFirst {
                menuBarSection
            }

            SettingsSection("剪贴板") {
                SettingsGroupBox {
                    formRow(L10n.t("Auto Paste")) {
                        Toggle("", isOn: Preferences.shared.binding("clipboard.autoPaste", default: false))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    SettingsDivider()
                    formRow(L10n.t("Tag Management")) {
                        HStack(spacing: 12) {
                            actionButton(L10n.t("Edit")) { isManagingTags = true }
                            Text(tagCountText)
                                .foregroundStyle(.secondary)
                        }
                    }
                    SettingsDivider()
                    formRow(L10n.t("Ignored Apps"), height: 40) {
                        IgnoredAppsEditor(revision: $ignoredAppsRevision)
                    }
                }
            }
        }
        // 外层 SettingsRootView.panePage 已统一提供 34/18 内边距，此处不再重复
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 12))
        .sheet(isPresented: $isManagingTags) {
            TagManagementSheet()
        }
        .onAppear { tagStore.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: MonitorPreferences.didChangeNotification)) { _ in
            monitorRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: LanguageManager.languageDidChange)) { _ in
            l10nVersion &+= 1
        }
    }

    /// 外观四选一（系统/浅色/深色/Midnight）
    private var appearanceChoices: some View {
        HStack(spacing: 22) {
            ForEach(AppearanceMode.allCases) { mode in
                Button { appearance.apply(mode) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(appearance.mode == mode ? Theme.accent : Color.secondary.opacity(0.25))
                            .overlay {
                                if appearance.mode == mode {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 5))
                                        .foregroundStyle(.white)
                                }
                            }
                        Text(appearanceTitle(mode))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 排障探针：把「菜单栏」区置顶便于截屏（见 body 顶注释）
    private var probeMenuBarFirst: Bool {
        UserDefaults.standard.bool(forKey: "probe.settingsMenuBarFirst")
    }

    /// 「菜单栏」设置区（功能 / AI 服务商 / 菜单栏图标 / 菜单栏部件）
    private var menuBarSection: some View {
        SettingsSection("菜单栏") {
            SettingsGroupBox {
                formRow(L10n.t("Features")) {
                    Group {
                        if compact {
                            VStack(alignment: .leading, spacing: 7) {
                                featuresChoices
                            }
                        } else {
                            HStack(spacing: 22) {
                                featuresChoices
                            }
                        }
                    }
                    .buttonStyle(.link)
                }
                SettingsDivider()
                formRow(L10n.t("AI Providers")) {
                    HStack(spacing: 12) {
                        actionButton(L10n.t("Manage")) { openDetail("ai") }
                        Text(providerCountText)
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsDivider()
                formRow(L10n.t("Menu Bar Icon"), height: 76) {
                    menuBarIconChoices
                }
                SettingsDivider()
                formRow("菜单栏部件") {
                    HStack(spacing: 12) {
                        actionButton("设置") { StatsBarEngine.openSettings() }
                        Text("合并条：CPU / 内存 / GPU / 磁盘 / 网络 / 传感器 / 电池")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
    }

    /// 菜单栏图标四选一 + 小猫覆盖
    /// v86（2026-10-20 用户反馈「展现有截断、小猫没有图标」）：一律两行排布
    /// （3 + 2），文字单行固定宽不折行；小猫补猫图标预览，与其它选项同视觉权重。
    private var menuBarIconChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                iconChoice(L10n.t("settings_menu_bar_icon_fan_label"), symbol: "fan.fill", value: Self.menuBarIconStyleFan,
                           help: L10n.t("Fan icon speed changes with CPU usage"))
                iconChoice(L10n.t("Menu Bar Icon Logo"), symbol: "line.3.horizontal.decrease.circle.fill", value: Self.menuBarIconStyleLogo)
                iconChoice(L10n.t("Date"), symbol: "calendar", value: Self.menuBarIconStyleDate,
                           dayBadge: Self.todayDayNumber)
            }
            HStack(spacing: 16) {
                if revealsCustomMenuBarIcon {
                    iconChoice("自定义图标", symbol: customMenuBarSymbolBinding.wrappedValue,
                               value: Self.menuBarIconStyleCustom)
                }
                runCatChoice
            }
        }
    }

    /// 小猫：独立覆盖开关（勾选后盖住上方所选样式）。
    /// v86：补猫图标预览（SF Symbol cat.fill）+ 选中态与其它选项一致的胶囊高亮。
    private var runCatChoice: some View {
        Toggle(isOn: runCatBinding) {
            HStack(spacing: 6) {
                Image(systemName: "cat.fill")
                    .font(.system(size: 18))
                Text("小猫")
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(runCatBinding.wrappedValue ? Color.white : Color.primary)
                    .background {
                        if runCatBinding.wrappedValue {
                            RoundedRectangle(cornerRadius: 7).fill(Theme.accent)
                        }
                    }
            }
        }
        .toggleStyle(.checkbox)
        .help("菜单栏图标换成奔跑小猫（RunCat，速度随 CPU 变化）")
    }

    // MARK: 计数文案（原版 '%d Provider(s)' / '%d Tag(s)' 键面，复数按数量切换）

    /// AI 服务商计数（复用现有 CredentialStore.configuredProviders，不新建链路）
    private var providerCountText: String {
        let count = CredentialStore.shared.configuredProviders().count
        return String(format: L10n.t(count == 1 ? "%d Provider" : "%d Providers"), count)
    }

    /// 标签计数（复用现有 TagStore.tags）
    private var tagCountText: String {
        let count = tagStore.tags.count
        return String(format: L10n.t(count == 1 ? "%d Tag" : "%d Tags"), count)
    }

    /// 日期图标上的当日角标（原版日期按钮显示当天日期数）
    static var todayDayNumber: String {
        String(Calendar.current.component(.day, from: Date()))
    }

    /// 功能开关组（面板功能显隐）：系统监控 / 日历 / 截图检索 / 文件中转。
    /// v40 新增「文件中转」——控制主面板侧边栏一级入口是否出现。
    @ViewBuilder private var featuresChoices: some View {
        Toggle(L10n.t("System Monitor"), isOn: $showSystemStatus)
            .toggleStyle(.checkbox)
            .help(L10n.t("System Monitor in Main Panel"))
        Toggle(L10n.t("Calendar"), isOn: $showCalendar)
            .toggleStyle(.checkbox)
        Toggle(L10n.t("Screenshot Search"), isOn: $automaticScreenshotOCR)
            .toggleStyle(.checkbox)
            .help(L10n.t("Automatically recognize text in screenshots so you can find them by text search."))
        Toggle("文件中转", isOn: $transferDockEnabled)
            .toggleStyle(.checkbox)
            .help("在主面板顶部显示「文件中转」分段（完整的开关/端口/二维码见「设置 → 文件中转」）")
    }

    private func formRow<Content: View>(_ title: String, height: CGFloat = 40,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: compact ? 14 : 24) {
            Text(title)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: compact ? 104 : 190, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: height)
    }


    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).fontWeight(.semibold).frame(width: 56, height: 24)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private func iconChoice(_ title: String, symbol: String, value: String,
                            help: String? = nil, dayBadge: String? = nil) -> some View {
        Button { menuBarIconStyleBinding.wrappedValue = value } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(currentMenuBarIconStyle == value ? Color.white : Color.primary)
                    .background {
                        if currentMenuBarIconStyle == value {
                            RoundedRectangle(cornerRadius: 7).fill(Theme.accent)
                        }
                    }
                if let dayBadge {
                    // 原版日期按钮：日历图标右上角当日数字（15 号截图实证）
                    Text(dayBadge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent))
                        .offset(x: 8, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }

    private func openDetail(_ id: String) {
        ServiceLocator.settings?.open(pane: id)
    }

    // MARK: 菜单栏图标样式（spec 13 §6.1 偏好键 + §6 样式语义）

    /// 图标样式四键（原作实证键名）
    static let menuBarIconStyleLogoKey = "menu-bar-icon-logo"
    static let menuBarIconStyleFanKey = "menu-bar-icon-fan"
    static let menuBarIconStyleDateKey = "menu-bar-icon-date"
    static let menuBarIconStyleCustomKey = "menu-bar-icon-custom"
    /// 自定义 Symbol 名键（⬜ 原作键名未探明，重建侧自定）
    static let menuBarIconCustomSymbolKey = "menu-bar-icon-custom-symbol"
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

    /// 是否展示自定义图标（仅受 hide/restore 开关控制；v83 起不再依赖彩蛋解锁）
    private var revealsCustomMenuBarIcon: Bool {
        revealCustomIconOption
    }


    /// 当前选中的样式**内部标识**（全false / 多 true 时取 Logo）
    private var currentMenuBarIconStyle: String {
        if iconStyleCustom { return Self.menuBarIconStyleCustom }
        if iconStyleFan { return Self.menuBarIconStyleFan }
        if iconStyleDate { return Self.menuBarIconStyleDate }
        return Self.menuBarIconStyleLogo
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

    /// v32/v34 移植（注入版）：奔跑小猫开关。
    /// 状态存于引擎（widgets.plist 键 MainIconCat），Swift 侧经桥接头 C API 读写。
    private var runCatBinding: Binding<Bool> {
        Binding(
            get: { FSRunCatIconEnabled() },
            set: { FSRunCatIconSetEnabled($0) }
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

}

// MARK: - 关于页
//
// 对齐原版截图（original-settings-tabs/关于.png，1600×1124 = 800×562pt @2x）：
//   居中布局：App 图标(≈64pt) → "Frset"(≈20pt semibold) → "v1.3.12 · 更新日志"(12pt) →
//   双蓝按钮「给我们评分」「帮助与反馈」→「隐私政策 · 使用条款」(12pt) →
//   "Copyright © 2026, All rights reserved."(11pt tertiary)
// 文案全部走 L10n.t() 原版键面（Rate us / Help & Feedback / Privacy Policy /
// Terms of Service / Changelog），语言切换随 languageDidChange 重绘（同通用页机制）。
// 显示名固定 "Frset"、版本行固定 "v1.3.12" —— 像素级 1:1 验收要求与原版一致；
// Bundle 真实版本（1.0.0）不参与此页显示，避免双开 diff 出现可见差异。

struct AboutSettingsPane: View {
    /// 语言版本号：languageDidChange 到达时自增，驱动本视图重绘（同 GeneralSettingsPane 机制）
    @Stored private var l10nVersion: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .cornerRadius(14.5)

            Text(L10n.t("Frset"))
                .font(.system(size: 21, weight: .semibold))
                .padding(.top, 18)

            // v90（2026-10-20 用户要求）：外链全部移除，版本号回退 1.0.0
            Text("v\(Self.displayVersion)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Spacer(minLength: 24)

            aboutButton("导出使用记录") { DiagnosticsExporter.export() }

            Spacer(minLength: 24)

            Text("Copyright © 2026, All rights reserved.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .onReceive(NotificationCenter.default.publisher(for: LanguageManager.languageDidChange)) { _ in
            l10nVersion &+= 1
        }
    }

    /// 版本号（v90 用户要求回退 1.0.0；原对齐原版截图的 1.3.12 不再使用）
    static let displayVersion = "1.0.0"

    /// 外链目标（原版分别走 App Store 评分 / 帮助站 / 隐私与条款页；
    /// 重建无 App Store 与独立站点，统一降级为 GitHub 占位链接 —— 有意差异，记录在 specs/07）
    static let rateURL = URL(string: "https://github.com/frset/frset-next")
    static let feedbackURL = URL(string: "https://github.com/frset/frset-next/issues")
    static let changelogURL = URL(string: "https://github.com/frset/frset-next/releases")
    static let privacyURL = URL(string: "https://github.com/frset/frset-next")
    static let termsURL = URL(string: "https://github.com/frset/frset-next")

    private func aboutButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 112, height: 32)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }

    private func openURL(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 标签管理 sheet（原版「标签管理 [编辑]」入口）
//
// 原版标签管理界面未采到参考图（§8.3 未覆盖类），此处按原版键面搭建最小可用 UI：
// 列表 + 新建 + 删除，全部复用现有 TagStore；详细布局留待补采后对齐。

struct TagManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TagStore.shared
    @Stored private var l10nVersion: Int = 0
    // @Stored 替代 @State：本机工具链缺 SwiftUIMacros 插件（见 Core/StateCompat.swift）
    @Stored private var newTagName = ""
    @Stored private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("Tag Management")).font(.headline)
                Spacer()
                Button(L10n.t("Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            List {
                ForEach(store.tags, id: \.id) { tag in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: tag.colorHex) ?? .gray)
                            .frame(width: 10, height: 10)
                        Text(tag.name)
                        Spacer()
                        Button {
                            store.delete(id: tag.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if store.tags.isEmpty && !isAdding {
                    Text(L10n.t("No tags yet"))
                        .foregroundStyle(.secondary)
                }
                if isAdding {
                    HStack(spacing: 10) {
                        TextField(L10n.t("New Tag"), text: $newTagName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onSubmit(createTag)
                        Button(L10n.t("Add Tag")) { createTag() }
                            .controlSize(.small)
                            .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Spacer()
                Button {
                    isAdding = true
                } label: {
                    Label(L10n.t("Add Tag"), systemImage: "plus")
                }
                .controlSize(.small)
            }
            .padding(16)
        }
        .frame(width: 480, height: 360)
        .onAppear { store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LanguageManager.languageDidChange)) { _ in
            l10nVersion &+= 1
        }
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.create(name: name)
        newTagName = ""
        isAdding = false
    }
}


// MARK: - 忽略应用（隐私名单）编辑器（原版缺失功能 §3-2）

/// 名单内的来源 App 不写入剪贴板历史；名单存 Preferences（bundle id 数组）。
/// UI 沿用设置页风格：formRow 行 + 12pt 字号 + 细边框胶囊按钮。
struct IgnoredAppsEditor: View {
    @Binding var revision: Int
    @Stored private var expanded = false

    private var apps: [String] {
        _ = revision
        return Preferences.shared.value(Preferences.Keys.clipboardIgnoredApps, default: [String]())
    }

    private func persist(_ list: [String]) {
        Preferences.shared.set(Preferences.Keys.clipboardIgnoredApps, list.isEmpty ? nil : list)
        revision += 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded ? "收起（\(apps.count)）" : "管理（\(apps.count)）")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.18))
                        }
                }
                .buttonStyle(.plain)

                Button {
                    guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                          bundle != Bundle.main.bundleIdentifier else { return }
                    var list = apps
                    guard !list.contains(bundle) else { return }
                    list.append(bundle)
                    persist(list)
                } label: {
                    Text("+ 添加当前前台应用")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.18))
                        }
                }
                .buttonStyle(.plain)
                .help("把最前面那个应用加入忽略名单，它复制的内容将不再被采集")
            }

            if expanded {
                if apps.isEmpty {
                    Text("名单为空——所有应用的复制内容都会被采集")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(apps, id: \.self) { bundle in
                        HStack {
                            Text(bundle)
                                .font(.system(size: 11.5).monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button {
                                persist(apps.filter { $0 != bundle })
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("从名单移除")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}
