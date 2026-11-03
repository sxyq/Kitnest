import SwiftUI

// MARK: - 欢迎窗内容（重建版自研，非原版复刻）
//
// v183（用户：「新手引导也要优化，把新功能全都加上去」）：
//   · 新增「30 秒上手」三步条——第一次打开先知道「点哪、按什么、去哪找」；
//   · 功能卡补上这一版新增的能力：文件归档（解压/压缩/任务队列）、
//     监测的充电/电池/功耗三页拆分、带宽流向、温度热区、剪贴板就地预览；
//   · 新卡片用 NEW 角标标出来，老用户也能一眼看到变化；
//   · 快捷键表补齐到 16 条（窗口截图 / 取色 / 划词翻译 / 监测独立窗）。
//
// 窗口尺寸 760×620 固定（防 NSHostingView 约束循环，见 WelcomeWindowController）。

struct WelcomeView: View {

    @ObservedObject private var permissions = PermissionCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    quickStart
                    featureSection("核心工作区", items: [
                        FeatureItem(symbol: "square.stack.3d.up", title: "主面板", tint: .blue, lines: [
                            "搜索框：网页 / 剪贴板历史 / 本地文件三合一",
                            "日历、剪贴板、文件中转同屏；顶部页面可自定义增删与排序",
                        ]),
                        FeatureItem(symbol: "camera.viewfinder", title: "截图工具箱", tint: .indigo, lines: [
                            "区域 / 窗口 / 长截图，9 种标注工具，可直接美化导出",
                            "OCR 识字、截图翻译、取色、钉图、AI 抹除",
                        ]),
                        FeatureItem(symbol: "chart.xyaxis.line", title: "性能监测", tint: .green, lines: [
                            "独立监测窗 + 菜单栏 STATS 合并条（12 种部件形态）",
                            "电池 / 功耗两页分工（充电状态已并入电池），带宽流向、温度热区",
                        ], badge: "新"),
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
                            "时间戳、IP、二维码、图片压缩、单位换算等",
                            "命令面板（⌥K）统一检索全部功能",
                        ]),
                        FeatureItem(symbol: "arrow.left.arrow.right", title: "文件传输 · 投屏", tint: .teal, lines: [
                            "隔空投送收发、扫码直传、ADB 文件互传",
                            "Android 无线配对 + 镜像投屏（零安装）",
                        ]),
                        FeatureItem(symbol: "clipboard", title: "剪贴板增强", tint: .cyan, lines: [
                            "历史记录、悬浮窗、标签、复制后自动粘贴",
                            "鼠标停在条目上就地展开预览，不再弹独立窗",
                        ], badge: "新"),
                    ])
                    featureSection("新增能力与隐私", items: [
                        FeatureItem(symbol: "archivebox", title: "文件归档", tint: .brown, lines: [
                            "zip / 7z 解压与压缩、密码归档、解压前路径核对",
                            "长任务转后台，任务队列可查进度、一键在访达中显示",
                        ], badge: "新"),
                        FeatureItem(symbol: "lock.shield", title: "隐私与本地", tint: .gray, lines: [
                            "截图、OCR、剪贴板全部在本机处理，不上传",
                            "AI 只调用你自己配置的服务商；归档在本地完成",
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
            Text("菜单栏效率工具 · 剪贴板 / 截图 / 监测 / 传输 / 归档 一站合一")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - 30 秒上手

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("30 秒上手")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                step(1, "点菜单栏图标", "打开主面板：搜索、剪贴板、日历")
                step(2, "按 ⌥S 截图", "框选后直接标注 / 识字 / 翻译")
                step(3, "按 ⌥K 找功能", "命令面板搜一切，不用记路径")
            }
        }
    }

    private func step(_ index: Int, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(index)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Color.accentColor))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: Theme.Radius.card)
    }

    // MARK: - 功能区

    private struct FeatureItem {
        let symbol: String
        let title: String
        let tint: Color
        let lines: [String]
        /// 新功能角标（如「新」）
        var badge: String? = nil
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
                    .background(item.tint.opacity(0.13),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                if let badge = item.badge {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule(style: .continuous).fill(Color.accentColor))
                }
                Spacer(minLength: 0)
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
        .glassCard(radius: Theme.Radius.card)
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
                hotkeyRow("⇧⌥W", "窗口截图")
                hotkeyRow("⇧⌥S", "截图并识字")
                hotkeyRow("⇧⌥T", "截图翻译")
                hotkeyRow("⇧⌥L", "长截图")
                hotkeyRow("⇧⌥P", "截图并贴图")
                hotkeyRow("⇧⌥D", "划词翻译")
                hotkeyRow("⌥C", "取色")
                hotkeyRow("⇧⌘9", "悬浮剪贴板")
                hotkeyRow("⇧⌥R", "暂停 / 恢复剪贴板")
                hotkeyRow("⌥P", "性能监测")
                hotkeyRow("⌥M", "监测独立窗口")
                hotkeyRow("⌥T", "文件中转")
                hotkeyRow("⌥K", "命令面板")
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
                .background(.quaternary.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
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
        .glassCard(radius: Theme.Radius.card)
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
