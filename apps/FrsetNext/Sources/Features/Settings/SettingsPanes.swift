import AppKit
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 外观（四选一 radio：系统/浅色/深色/Midnight；键 appearance）
            SettingsSection(title: "外观") {
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
            SettingsSection(title: "语言") {
                SettingsGroupBox {
                    SettingsRow(icon: "globe",
                                title: "显示语言",
                                subtitle: "切换后立即生效，无需重启应用") {
                        Picker("", selection: languageBinding) {
                            Text("跟随系统").tag("auto")
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
            SettingsSection(title: "启动") {
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
            SettingsSection(title: "菜单栏") {
                SettingsGroupBox {
                    SettingsToggleRow(
                        icon: "menubar.rectangle",
                        title: "显示菜单栏图标",
                        subtitle: "关闭后仅可通过快捷键唤起（由状态栏模块响应）",
                        isOn: $menuBarIconsVisible
                    )
                }
            }

            // 数据
            SettingsSection(title: "数据") {
                SettingsGroupBox {
                    SettingsRow(icon: "folder", title: "数据目录",
                                subtitle: AppDirectories.base.path) {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([AppDirectories.base])
                        }
                        .controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(icon: "trash", title: "清除数据",
                                subtitle: "删除本地数据库、图片缓存等全部数据，操作不可恢复") {
                        Button("清除…", role: .destructive) { confirmClearData = true }
                            .controlSize(.small)
                    }
                    .confirmationDialog("确认清除全部数据？",
                                        isPresented: $confirmClearData,
                                        titleVisibility: .visible) {
                        Button("清除全部数据", role: .destructive, action: clearAllData)
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将删除 \(AppDirectories.base.path) 下的所有内容（含剪贴板历史与缓存），此操作不可恢复。")
                    }
                }
            }
        }
    }

    // MARK: 外观四选一 radio（specs/18 §5：系统/浅色/深色/Midnight，键 appearance）

    private func appearanceRadio(_ mode: AppearanceMode) -> some View {
        let isSelected = appearance.mode == mode
        return Button {
            appearance.apply(mode)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Image(systemName: mode.systemImage)
                    .font(.system(size: 16))
                Text(mode.title)
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
        .help(mode.title)
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
