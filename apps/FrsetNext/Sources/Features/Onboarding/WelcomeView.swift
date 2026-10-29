import SwiftUI

// MARK: - 欢迎窗内容（重建版自研，非原版复刻）
//
// 与原版 WelcomeWindow 的关系：原版欢迎窗只介绍原版自己的 5 页签设置 + 基础功能
// （逆向审计中的未实现项）。重建版功能面已数倍于原版（见 docs/audit-原版功能核对/
// 的核对结论：功能型类 171/190 已覆盖 + 反超项），因此这里**按当前实际功能重写**：
//   · 内容来源：FrsetNext 当前源码功能清单（AppBootstrap 默认热键表、CaptureMode、
//     AnnotationTool 9 种、TransferDock 三通道、AI 四服务商、Monitor 7 模块等）；
//   · 结构：Hero → 核心工作区 4 卡 → 效率与互联 4 卡 → 快捷键速览 → 权限引导卡 →
//     开始使用；
//   · 不逐项罗列设置项（设置窗侧边栏已覆盖），只做「能力地图 + 入口」。
//
// 窗口尺寸 760×620 固定（防 NSHostingView 约束循环，见 WelcomeWindowController）。

struct WelcomeView: View {

    @ObservedObject private var permissions = PermissionCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    featureSection("核心工作区", items: [
                        FeatureItem(symbol: "square.stack.3d.up", title: "主面板", tint: .blue, lines: [
                            "搜索框：网页 / 剪贴板历史 / 本地文件三合一",
                            "日历卡片、剪贴板列表、文件中转同屏协作",
                        ]),
                        FeatureItem(symbol: "camera.viewfinder", title: "截图工具箱", tint: .indigo, lines: [
                            "区域 / 全屏 / 长截图，截图后 9 种标注工具",
                            "OCR 识字、截图翻译、取色、钉图、AI 抹除",
                        ]),
                        FeatureItem(symbol: "chart.xyaxis.line", title: "性能监测", tint: .green, lines: [
                            "菜单栏 STATS 合并条：12 种部件形态随需组合",
                            "独立监测窗：CPU / 内存 / 磁盘 / 网络 / 传感器 / 进程 / 端口",
                        ]),
                        FeatureItem(symbol: "record.circle", title: "屏幕录制", tint: .red, lines: [
                            "区域录制，系统音 + 麦克风混音，可导出 GIF",
                        ]),
                    ])
                    featureSection("效率与互联", items: [
                        FeatureItem(symbol: "sparkles", title: "AI 体系", tint: .purple, lines: [
                            "Anthropic / Gemini / OpenAI 兼容 / Ollama 多服务商",
                            "对话、摘要、划词翻译、截图翻译一站式",
                        ]),
                        FeatureItem(symbol: "wrench.and.screwdriver", title: "工具箱", tint: .orange, lines: [
                            "时间戳转换、IP 查询、二维码、图片压缩、单位换算",
                            "命令面板（⌥K）统一检索全部功能",
                        ]),
                        FeatureItem(symbol: "arrow.left.arrow.right", title: "文件传输 · 投屏", tint: .teal, lines: [
                            "文件中转页：隔空投送收发、扫码直传、ADB 文件互传",
                            "投屏页：Android 无线配对 + 镜像投屏（零安装）",
                        ]),
                        FeatureItem(symbol: "clipboard", title: "剪贴板增强", tint: .cyan, lines: [
                            "历史记录、悬浮窗、标签管理、复制后自动粘贴",
                            "复制文件自动进中转站，悬停即可预览",
                        ]),
                    ])
                    hotkeySection
                    permissionBanner
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
            footer
        }
        .frame(width: 760, height: 620)
        .background(Color(OfficialChrome.windowBackground))
        .onAppear { permissions.refreshAll() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                permissions.refreshAll()
            }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 6) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
            Text("欢迎使用 FrsetNext")
                .font(.system(size: 22, weight: .semibold))
            Text("菜单栏效率工具 · 剪贴板 / 截图 / 监测 / 传输 一站合一")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - 功能区

    private struct FeatureItem {
        let symbol: String
        let title: String
        let tint: Color
        let lines: [String]
    }

    private func featureSection(_ title: String, items: [FeatureItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(items.indices, id: \.self) { i in
                    featureCard(items[i])
                }
            }
        }
    }

    private func featureCard(_ item: FeatureItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.tint)
                    .frame(width: 24, height: 24)
                    .background(item.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(item.lines, id: \.self) { line in
                    HStack(alignment: .top, spacing: 5) {
                        Text("·")
                            .foregroundStyle(Theme.tertiaryText)
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 快捷键速览

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("常用快捷键")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                hotkeyRow("⌥Space", "打开 / 收起主面板")
                hotkeyRow("⌥F", "打开并聚焦搜索框")
                hotkeyRow("⌥S", "区域截图")
                hotkeyRow("⇧⌥S", "截图并识字")
                hotkeyRow("⇧⌥T", "截图翻译")
                hotkeyRow("⇧⌥L", "长截图")
                hotkeyRow("⇧⌥P", "截图并贴图")
                hotkeyRow("⇧⌘9", "悬浮剪贴板")
                hotkeyRow("⌥P", "性能监测")
                hotkeyRow("⌥T", "文件中转")
                hotkeyRow("⌥K", "命令面板")
                hotkeyRow("⇧⌥R", "暂停 / 恢复剪贴板")
            }
            Text("全部可在 设置 → 快捷键 中自定义。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func hotkeyRow(_ keys: String, _ desc: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: 64, alignment: .leading)
            Text(desc)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 权限引导卡

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: permissions.allCoreGranted ? "lock.open.fill" : "lock.shield.fill")
                .font(.system(size: 20))
                .foregroundStyle(permissions.allCoreGranted ? Color(nsColor: .systemGreen) : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(permissions.allCoreGranted ? "核心权限已就绪" : "还差一步：完成权限引导")
                    .font(.system(size: 13, weight: .semibold))
                Text(permissions.allCoreGranted
                     ? "屏幕录制与辅助功能均已授权，全部功能可用。"
                     : "截图、自动粘贴、全局快捷键需要系统授权，约 30 秒完成。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("权限引导") {
                PermissionGuideWindowController.shared.show()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 12) {
            Button("使用手册") {
                ServiceLocator.settings?.open(pane: "manual")
            }
            .controlSize(.regular)
            Spacer()
            Button("开始使用") {
                WelcomeWindowController.shared.finishOnboarding()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}
