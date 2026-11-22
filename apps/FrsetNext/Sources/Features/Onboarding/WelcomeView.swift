import SwiftUI

// 首屏展示三个真实操作教程；原有功能卡片收在「探索更多」。

struct WelcomeView: View {

    @ObservedObject private var permissions = PermissionCenter.shared
    @ObservedObject private var tutorials = QuickTutorialController.shared
    @Stored private var showAllFeatures = false

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let task = tutorials.selected {
                        tutorialDetail(task)
                    } else {
                        quickStart
                        HStack {
                            Button(showAllFeatures ? "收起探索更多" : "探索更多功能") {
                                showAllFeatures.toggle()
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("快捷键可在设置中自定义")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.tertiaryText)
                        }
                        if showAllFeatures {
                            Button("打开归档设置") {
                                WelcomeWindowController.shared.close()
                                ServiceLocator.settings?.open(pane: "archive")
                            }.buttonStyle(.link)
                            featureSection("日常工作", items: [
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
                            featureSection("智能与互联", items: [
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
                            featureSection("进阶与隐私", items: [
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
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
            footer
        }
        .frame(width: 760, height: 620)
        .background(Color(OfficialChrome.windowBackground))
        // v208：原生标题栏由窗口负责
        .onAppear { permissions.refreshAll() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                permissions.refreshAll()
                if tutorials.selected == .screenshot {
                    Task { await permissions.probeScreenRecording() }
                }
            }
        .task(id: tutorials.selected) {
            if tutorials.selected == .screenshot { await permissions.probeScreenRecording() }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 6) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
            Text("欢迎使用 Kitnest Lite")
                .font(.system(size: 22, weight: .semibold))
                Text("从一个真实任务开始，其他功能随时探索")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.top, OfficialChrome.titlebarInset)   // v272：统一标题栏净空
        .padding(.bottom, 12)
    }

    // MARK: - 新手任务

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("先完成一件事")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(QuickTutorial.allCases) { task in tutorialCard(task) }
            }
        }
    }

    private func tutorialCard(_ task: QuickTutorial) -> some View {
        let status = tutorials.status(task)
        return Button {
            if status == .completed { tutorials.restart(task) }
            else { tutorials.select(task) }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: task.symbol)
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text(status.label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                Text(task.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.leading)
                Text(status == .completed ? "重新学习这项操作" : taskDescription(task))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                Label(status == .inProgress ? "继续教程" : status == .completed ? "重新学习" : "开始教程",
                      systemImage: "arrow.right")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
            .glassCard(radius: Theme.Radius.card)
        }
        .buttonStyle(.plain)
    }

    private func taskDescription(_ task: QuickTutorial) -> String {
        switch task {
        case .clipboard: return "复制示例 → 打开历史 → 重新复制"
        case .screenshot: return "框选屏幕 → 复制图片或识别文字"
        }
    }

    private func tutorialDetail(_ task: QuickTutorial) -> some View {
        let status = tutorials.status(task)
        return VStack(alignment: .leading, spacing: 14) {
            Button { tutorials.returnToTasks() } label: {
                Label("上一步 · 新手任务", systemImage: "chevron.left")
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 9) {
                Image(systemName: task.symbol).font(.system(size: 21)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(.system(size: 18, weight: .semibold))
                    Text(status.label).font(.system(size: 11)).foregroundStyle(status == .completed ? Color.green : Color.secondary)
                }
                Spacer()
                Text("\(tutorials.displayStep) / 3")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            if status == .completed {
                Button("重新学习") { tutorials.restart(task) }.buttonStyle(.borderedProminent)
            } else {
                tutorialSteps(task)
            }
            if !tutorials.message.isEmpty {
                Label(tutorials.message, systemImage: status == .completed ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 12)).foregroundStyle(status == .completed ? Color.green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
            if status == .completed {
                if task != .screenshot {
                    Button(tutorials.resultActionTitle) { tutorials.openResult() }
                        .buttonStyle(.bordered)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("跳过") { tutorials.skip() }.buttonStyle(.borderless)
                Spacer()
                Button("稍后继续") { WelcomeWindowController.shared.close() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .glassCard(radius: Theme.Radius.card)
    }

    @ViewBuilder
    private func tutorialSteps(_ task: QuickTutorial) -> some View {
        switch task {
        case .clipboard:
            VStack(alignment: .leading, spacing: 10) {
                tutorialStep(1, "复制一段示例文字", done: tutorials.currentStep >= 1)
                if tutorials.currentStep <= 1 {
                    Button("复制示例文字") { tutorials.copyClipboardExample() }.buttonStyle(.borderedProminent)
                }
                tutorialStep(2, "等待它出现在剪贴板历史", done: tutorials.currentStep >= 2)
                if tutorials.currentStep >= 2 && tutorials.currentStatus != .completed {
                    Button(tutorials.currentStep == 2 ? "打开剪贴板" : "返回剪贴板继续") {
                        tutorials.openClipboard()
                    }.buttonStyle(.borderedProminent)
                }
                tutorialStep(3, "从列表重新复制这条内容", done: tutorials.currentStatus == .completed)
                if tutorials.currentStep == 3 { Text("完成后会自动确认；返回原应用按 ⌘V 粘贴。").font(.system(size: 11)).foregroundStyle(.secondary) }
                if ClipboardManager.shared.isRecordingPaused {
                    Button("恢复剪贴板记录") { tutorials.resumeClipboardRecording() }.buttonStyle(.bordered)
                }
            }
        case .screenshot:
            VStack(alignment: .leading, spacing: 10) {
                tutorialStep(1, "开始截图并框选内容", done: tutorials.currentStep > 1)
                if tutorials.currentStep == 0 || tutorials.currentStep == 1 {
                    Button("开始截图") { tutorials.startScreenshot() }.buttonStyle(.borderedProminent)
                }
                if tutorials.currentStep >= 1 {
                    tutorialStep(2, "完成选区后从操作条选择复制或识字", done: tutorials.currentStatus == .completed)
                    Text("选「复制」写入系统剪贴板，选「识字」打开 OCR 结果。Esc 可取消并重新开始。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if tutorials.currentStep >= 2 { tutorialStep(3, "确认结果位置", done: tutorials.currentStatus == .completed) }
                }
                if tutorials.currentStep >= 2 && tutorials.currentStatus != .completed {
                    Button("重新截图") { tutorials.startScreenshot() }.buttonStyle(.bordered)
                }
                if !permissions.status(.screenRecording).isGranted {
                    Label("屏幕录制权限仅用于本次截图和识字。", systemImage: "lock.shield")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                    Button(permissions.status(.screenRecording) == .denied ? "打开屏幕录制设置" : "请求屏幕录制权限") {
                        if permissions.status(.screenRecording) == .denied {
                            permissions.openSystemSettings(.screenRecording)
                        } else {
                            permissions.request(.screenRecording) { _ in
                                Task { await permissions.probeScreenRecording() }
                            }
                        }
                    }.buttonStyle(.bordered)
                }
            }
        }
    }

    private func tutorialStep(_ number: Int, _ text: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
            Text("\(number). \(text)").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
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
                hotkeyRow(shortcutDisplay("clipboardPanel"), "打开剪贴板")
                hotkeyRow(shortcutDisplay("screenshot"), "区域截图")
                hotkeyRow(shortcutDisplay("floatingClipboard"), "悬浮剪贴板")
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

    private func shortcutDisplay(_ id: String) -> String {
        guard let binding = AppBootstrap.shortcutBinding(for: id) else { return "未设置" }
        return ShortcutManager.display(keyCode: binding.keyCode, modifiers: binding.modifiers)
    }

    // MARK: - 权限引导卡

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: permissions.allCoreGranted ? "lock.open.fill" : "lock.shield.fill")
                .font(.system(size: 20))
                .foregroundStyle(permissions.allCoreGranted ? Color(nsColor: .systemGreen) : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(permissions.allCoreGranted ? "核心权限已就绪" : "核心权限尚未就绪")
                    .font(.system(size: 13, weight: .semibold))
                Group {
                    if permissions.allCoreGranted {
                        Text("屏幕录制与辅助功能均已授权。")
                    } else {
                        ForEach(PermissionKind.allCases.filter { $0.isCore && !permissions.status($0).isGranted }) { kind in
                            Text("\(kind.title)\(permissions.status(kind).label)：\(kind.features.joined(separator: "、"))暂不可用")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
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
            Button("跳过引导") {
                QuickTutorialController.shared.returnToTasks()
                WelcomeWindowController.shared.finishOnboarding()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            Button("查看全部功能") {
                tutorials.returnToTasks()
                showAllFeatures = true
            }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
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
