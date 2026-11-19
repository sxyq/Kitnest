import SwiftUI

/// 手册中的预设操作只推进演示步骤；正式组件沿用设置页的预览环境。
struct ManualDemoView: View {
    let title: String
    let demoID: String
    let symbol: String
    let steps: [String]
    @Stored private var step = 0
    @Stored private var playing = false
    @Stored private var selected: String? = "appearance-note"
    @Stored private var selectedPreset = 0
    @StateObject private var toolbar = CaptureToolbarModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var finished: Bool { !steps.isEmpty && step == steps.count - 1 }
    private var example: (input: String, result: String) { ManualDemoSamples.example(title: title, steps: steps) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("跟着做一遍", systemImage: "play.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("示例演示").font(.caption).foregroundStyle(.secondary)
                Button {
                    if playing { playing = false }
                    else { if finished { advance(to: 0) }; playing = true }
                } label: {
                    Label(playing ? "暂停" : "播放", systemImage: playing ? "pause.fill" : "play.fill")
                }.buttonStyle(.bordered)
                Button("重来") { playing = false; advance(to: 0) }
                    .buttonStyle(.borderless)
            }
            presetPicker
            Text("画面只展示预设示例，不会读取或修改你的剪贴板、文件或电脑数据。")
                .font(.caption).foregroundStyle(.secondary)
            stage
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .clipped()
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    if finished {
                        Label("完成", systemImage: "checkmark.circle.fill")
                            .font(.caption).padding(8)
                            .background(.regularMaterial, in: Capsule()).padding(10)
                            .transition(.opacity)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                    Button {
                        playing = false
                        advance(to: index)
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 20, height: 20)
                                .background(index == step ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05), in: Circle())
                            Text(text).font(.system(size: 12)).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if index == step { Image(systemName: "arrow.left").font(.caption) }
                        }.foregroundStyle(index == step ? Theme.accent : .secondary)
                            .padding(.vertical, 3)
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
        .onAppear {
            toolbar.isSettingsPreview = true
            toolbar.preview = SettingsPreviewSamples.image
            toolbar.onPreviewFeedback = { _ in
                playing = false
                advance(to: min(step + 1, steps.count - 1))
            }
        }
        .task(id: playing) { @MainActor in
            if !playing { return }
            for index in step..<steps.count {
                advance(to: index)
                do { try await Task.sleep(nanoseconds: 2_400_000_000) }
                catch { return }
            }
            playing = false
        }
        .onDisappear { playing = false; toolbar.onPreviewFeedback = nil }
    }

    private func advance(to index: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            step = index
            selectedPreset = index == 0 ? 0 : index == steps.count - 1 ? 2 : 1
            selected = "appearance-note"
        }
    }

    private var presetPicker: some View {
        HStack(spacing: 6) {
            preset("了解用途", icon: "sparkles", index: 0) { advance(to: 0) }
            preset("跟着操作", icon: "hand.tap", index: 1) { advance(to: min(1, max(0, steps.count - 1))) }
            preset("查看结果", icon: "checkmark.circle", index: 2) { advance(to: max(0, steps.count - 1)) }
        }
    }

    private func preset(_ title: String, icon: String, index: Int, action: @escaping () -> Void) -> some View {
        Button {
            playing = false
            selectedPreset = index
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(selectedPreset == index ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selectedPreset == index ? Theme.accent.opacity(0.45) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedPreset == index ? Theme.accent : .secondary)
    }

    @ViewBuilder private var stage: some View {
        switch demoID {
        case "clipboard":
            if title.contains("备份") || title.contains("暂停") || title.contains("标签") || title.contains("编辑") {
                walkthrough
            } else {
                HStack(spacing: 1) {
                    ClipboardSectionView()
                        .environment(\.isSettingsPreview, true)
                        .environment(\.settingsPreviewClipboardItems, Array(SettingsPreviewSamples.clipboardItems.prefix(4)))
                        .environment(\.settingsPreviewImage, SettingsPreviewSamples.image)
                        .environment(\.settingsPreviewClipboardSelection, $selected)
                    if step > 0 {
                        Text("周五交付\n整理截图、核对文案，再发给同事。")
                            .font(.system(size: 12)).padding(12).frame(maxWidth: .infinity)
                            .transition(.opacity)
                    }
                }.padding(8)
            }
        case "capture":
            capture
        case "monitor":
            monitor
        case "transfer":
            if title.contains("压缩") || title.contains("归档") { archive }
            else { walkthrough }
        case "recording":
            recording
        case "settings" where title.contains("Dock"):
            dockPreview
        case "entry" where title.contains("刘海") || title.contains("多屏"):
            multiDisplayPreview
        case "tools" where title.contains("代码"):
            CodePreviewView(code: "let count = 3\nprint(count)", fileName: "example.swift")
                .environment(\.isSettingsPreview, true).padding(10)
        case "tools" where title.contains("二维码"):
            HStack(spacing: 16) {
                samplePanel("链接", text: "https://example.com")
                if step > 0 {
                    VStack(spacing: 6) {
                        QRCodeView(text: "https://example.com", size: 84)
                        Text("预设链接二维码").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(16)
        case "tools" where title.contains("图片") && title.contains("压缩"):
            HStack(spacing: 14) {
                picture.padding(8).overlay(alignment: .bottom) { Text("日落.png · 2.4 MB").font(.caption) }
                Image(systemName: "arrow.right").foregroundStyle(Theme.accent)
                if step > 0 {
                    picture.padding(8).overlay(alignment: .bottom) { Text("压缩结果 · 860 KB").font(.caption) }
                }
            }.padding(14)
        default:
            walkthrough
        }
    }

    private var walkthrough: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                samplePanel("输入与选择", text: example.input)
                Image(systemName: "arrow.right").foregroundStyle(Theme.accent).padding(.top, 32)
                if step > 0 {
                    samplePanel(finished ? "结果" : "操作中", text: finished ? example.result : steps[step])
                        .transition(.opacity)
                }
            }
            if steps.indices.contains(step) {
                Text(steps[step]).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).id(step).transition(.opacity)
            }
        }.padding(16)
    }

    private func samplePanel(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11.5, design: demoID == "tools" ? .monospaced : .default))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var dockPreview: some View {
        VStack(spacing: 12) {
            if step < 2 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Circle().fill(.red).frame(width: 8, height: 8); Text("设置").font(.caption); Spacer() }
                    Divider()
                    Label("常规　　刘海工作台　　搜索", systemImage: "gearshape")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Label("窗口正在独立显示", systemImage: "macwindow")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12).frame(maxWidth: 360, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                .transition(.opacity)
            } else {
                Text("设置窗口已关闭").font(.caption).foregroundStyle(.secondary)
                    .frame(height: 78).transition(.opacity)
            }
            HStack(spacing: 12) {
                Image(systemName: "face.smiling").foregroundStyle(.secondary)
                if step < 2 { Image(systemName: "app.fill").foregroundStyle(Theme.accent).font(.system(size: 22)) }
                Divider().frame(height: 22)
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .font(.system(size: 19)).padding(.horizontal, 18).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(alignment: .top) {
                if step < 2 { Text("Kitnest").font(.system(size: 9)).offset(y: -15) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: step)
    }

    private var multiDisplayPreview: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Label("显示范围", systemImage: "display.2")
                Spacer()
                Text("自动 · 刘海优先").foregroundStyle(Theme.accent)
            }
            .font(.system(size: 11, weight: .medium))
            HStack(spacing: 8) {
            displayPreview(name: "普通外接屏", hasNotch: false,
                               searchVisible: step == 2, expanded: step == 4)
            displayPreview(name: "内置刘海屏", hasNotch: true,
                               searchVisible: false, expanded: step == 3)
            }
            Text(["选择自动显示范围", "保存后按屏幕情况显示入口", "停留后只出现短搜索条",
                  "打开后只有一份完整工作台", "点击另一屏入口，当前内容随之迁移"][min(step, 4)])
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .padding(12)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: step)
    }

    private func displayPreview(name: String, hasNotch: Bool, searchVisible: Bool, expanded: Bool) -> some View {
        VStack(spacing: 5) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07))
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 4, height: 4)
                        Circle().fill(.yellow).frame(width: 4, height: 4)
                        Circle().fill(.green).frame(width: 4, height: 4)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 5).padding(.top, 5)
                    Spacer(minLength: 0)
                }
                if hasNotch {
                    Capsule().fill(.black).frame(width: 40, height: 7)
                } else if searchVisible {
                    Label("搜索…", systemImage: "magnifyingglass")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                        .frame(width: 100, height: 17)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 7)
                }
                if expanded {
                    VStack(spacing: 3) {
                        Label("Kitnest", systemImage: "square.3.layers.3d")
                            .font(.system(size: 9, weight: .medium))
                        Text("剪贴板　搜索　工具")
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 9).padding(.top, 18).padding(.bottom, 7)
                }
            }
            .frame(height: 70)
            Text(name).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var picture: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(
                LinearGradient(colors: [Color.indigo.opacity(0.75), Color.orange.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            VStack(spacing: 4) {
                Image(systemName: "photo").font(.system(size: 28, weight: .medium))
                Text("预设图片").font(.system(size: 10, weight: .medium))
            }.foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: 150, height: 96)
    }

    @ViewBuilder private var capture: some View {
        if title.contains("翻译") || title.contains("文字识别") {
            HStack(spacing: 12) {
                samplePanel("框选文字", text: example.input)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [4])))
                if step > 1 { samplePanel(title.contains("翻译") ? "译文" : "识别文字", text: example.result) }
            }.padding(16)
        } else if title.contains("取色") {
            HStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 12).fill(Color(red: 123.0/255, green: 92.0/255, blue: 1))
                    .frame(width: 110, height: 110)
                    .overlay(Image(systemName: "scope").font(.largeTitle).foregroundStyle(.white))
                samplePanel(step > 0 ? "选中色值" : "移动指针对准像素", text: step > 0 ? example.result : "#7B5CFF")
            }.padding(16)
        } else if title.contains("二维码") {
            HStack(spacing: 20) {
                QRCodeView(text: "https://example.com", size: 96)
                if step > 0 { samplePanel("识别结果", text: "https://example.com") }
            }.padding(16)
        } else if title.contains("动作条") {
            ScrollView(.horizontal) {
                CaptureActionToolbarView(model: toolbar).environment(\.isSettingsPreview, true)
                    .fixedSize(horizontal: true, vertical: false).padding(8)
            }
        } else if title.contains("图帘") || title.contains("历史") {
            VStack(alignment: .leading, spacing: 10) {
                Label(title.contains("图帘") ? "屏幕边缘 · 图帘" : "截图历史", systemImage: symbol)
                HStack(spacing: 10) {
                    ForEach(0..<3) { index in
                        picture.padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(index == step % 3 ? Theme.accent : .clear, lineWidth: 2))
                    }
                }
                Text(title.contains("图帘")
                     ? (step > 1 ? "选择图片 → 复制、保存或钉图" : "展开后选择一张截图")
                     : (step > 1 ? "双击继续标注 · 右键复制、显示位置或删除" : "搜索或按截图方式筛选"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
        } else if title.contains("长截图") {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<(step == 0 ? 2 : 5), id: \.self) { index in
                        Text("\(index + 1). 项目资料与操作说明").font(.system(size: 11)).padding(5)
                    }
                }.padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                Text(finished ? "拼接完成\n保存长图" : "在选区内向下滚动\n逐段采集页面").font(.system(size: 12))
            }.padding(12)
        } else {
            VStack(spacing: 8) {
                if title.contains("钉图"), finished {
                    Label("钉图已关闭", systemImage: "xmark.circle").font(.headline).frame(height: 150)
                } else {
                    picture
                        .padding(title.contains("美化") && step > 0 ? 14 : 0)
                        .background(title.contains("美化") ? Theme.accent.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay { captureOverlay }
                        .offset(x: title.contains("钉图") && step > 0 ? 16 : 0)
                }
                Label(captureCaption, systemImage: title.contains("钉图") ? "pin.fill" : symbol)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(14)
        }
    }

    @ViewBuilder private var captureOverlay: some View {
        if title.contains("标注"), step > 0 {
            RoundedRectangle(cornerRadius: 4).strokeBorder(.red, lineWidth: 2)
                .frame(width: 150, height: 70)
                .overlay(alignment: .topTrailing) {
                    Label("重点", systemImage: "arrow.down.left").font(.caption).foregroundStyle(.red).offset(x: 28, y: -20)
                }
        } else if title.contains("抹除"), step < 2 {
            Image(systemName: "star.fill").font(.system(size: 26)).foregroundStyle(.orange)
                .padding(12).background(step > 0 ? Color.red.opacity(0.25) : .clear, in: Circle())
        } else if title.contains("水印"), step > 0 {
            Text("Kitnest · 项目资料").font(.system(size: 17, weight: .medium)).rotationEffect(.degrees(-20)).opacity(0.4)
        } else if title.contains("延时"), !finished {
            Text("\(max(1, 3 - step))").font(.system(size: 48, weight: .bold)).foregroundStyle(Theme.accent)
        } else if title.contains("钉图"), step > 0 {
            Image(systemName: "pin.fill").foregroundStyle(Theme.accent).padding(10).background(.regularMaterial, in: Circle())
        } else if title == "截图", step < 2 {
            RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [5]))
                .frame(width: 180, height: 90)
        }
    }

    private var captureCaption: String {
        if title.contains("钉图") { return finished ? "关闭钉图窗口" : step > 0 ? "置顶参考图 · 拖动位置与调整大小" : "截图后点击「钉住」" }
        if title.contains("美化") { return step > 0 ? "背景、边距与圆角已调整" : "选择截图并打开美化" }
        if title.contains("抹除") { return step > 1 ? "所选星形物体已移除" : "选择抹除笔刷并涂过星形物体" }
        if title.contains("水印") { return step > 0 ? "预览文字水印位置与透明度" : "开启水印并输入文字" }
        if title.contains("工作流") { return step > 0 ? "截图 → 识字 → 复制文字" : "选择截图后的自动动作" }
        return finished ? "截图已选取 · 复制或保存" : "选择窗口或拖动框选区域"
    }

    private var archive: some View {
        let extracting = title.contains("解压")
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title.contains("分卷") ? example.input : extracting ? "旅行照片.zip" : "设计说明.pdf\n会议记录.txt", systemImage: extracting ? "doc.zipper" : "doc.on.doc")
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").foregroundStyle(Theme.accent)
                if step > 0 {
                    Label(title.contains("分卷") ? example.result : extracting ? "旅行照片/\n日落.jpg · 行程.txt" : "项目资料.zip\n包含 2 个文件",
                          systemImage: extracting ? "folder" : "doc.zipper")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(title.contains("分卷") ? "7z · 密码保护 · 加密文件名 · 分卷 100 MB" : extracting ? "选择目标文件夹 → 解压" : "选择 ZIP 格式 → 创建归档")
                .font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(step + 1), total: Double(steps.count))
        }.padding(20)
    }

    private var recording: some View {
        VStack(spacing: 8) {
            picture.frame(maxHeight: 130)
            HStack(spacing: 8) {
                Image(systemName: title.contains("剪辑") ? "scissors" : "record.circle")
                    .foregroundStyle(finished ? Theme.accent : .red)
                Text(title.contains("剪辑") ? "保留 00:03 — 00:12" : finished ? "00:08 · 已停止" : step == 0 ? "选择录制范围" : "00:08 · 录制中")
                Spacer()
                Text(finished ? "已导出 录屏.mp4" : "30 FPS · 麦克风关闭")
            }.font(.system(size: 11))
            if title.contains("剪辑") {
                HStack(spacing: 0) {
                    ForEach(0..<12) { index in
                        Rectangle().fill(index > 1 && index < 10 && step > 0 ? Theme.accent.opacity(0.5) : Color.secondary.opacity(0.15))
                            .frame(height: 18).overlay(Rectangle().strokeBorder(Color.primary.opacity(0.2)))
                    }
                }
            }
        }.padding(14)
    }

    @ViewBuilder private var monitor: some View {
        let values = MonitorDetailPreviewValues.fixed
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("示例数据").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if title.contains("内存维护") {
                Text(step == 0 ? "保存文稿 → 打开内存维护" : finished ? "维护报告：缓存已释放\n全部唤醒：恢复暂停应用" : "深度释放 → 管理员授权\n等待维护结束")
                    .font(.system(size: 13))
                Label(finished ? "查看报告与暂停应用" : "只在主动确认后执行", systemImage: finished ? "checkmark.circle" : "wind")
                    .font(.caption).foregroundStyle(.secondary)
            } else if title.contains("存储管理") {
                Text("扫描范围：下载文件夹\n设计资料 1.2 GB\n旧安装包 800 MB").font(.system(size: 13))
                Label(finished ? "确认所选项目后移到废纸篓" : "扫描用量 → 在 Finder 显示 → 勾选项目", systemImage: "externaldrive")
                    .font(.caption).foregroundStyle(.secondary)
            } else if title.contains("网络连接") || title.contains("诊断") || title.contains("端口") {
                Text("Wi-Fi · 已连接\n局域网地址 192.168.1.8\n8080 · 示例应用 · 127.0.0.1\n8081 · 示例服务 · 0.0.0.0").font(.system(size: 12, design: .monospaced))
                Text(step > 1 ? "对外筛选 → 显示 8081 · 局域网可访问" : "查看监听地址与所属应用").font(.caption).foregroundStyle(.secondary)
            } else if title.contains("温度") || title.contains("传感器") || title.contains("风扇") {
                ForEach([("CPU 包温", "48°C"), ("GPU", "43°C"), ("电池", "31°C"), ("风扇", "1800 RPM")], id: \.0) { name, value in
                    HStack { Text(name); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 12))
                }
            } else if title.localizedCaseInsensitiveContains("CPU") || title == "处理器使用情况" {
                Text("总占用 38% · 用户 26% · 系统 12%").font(.caption)
                MonitorCoreGrid(values: values.sample.perCore, columns: 4)
                MonitorAreaSparkline(values: values.history.cpu, color: .blue, upperBound: 1)
                    .frame(height: 52)
            } else if title.contains("内存") {
                Text("已用 10 GB / 16 GB · 交换 1 GB").font(.system(size: 15, weight: .medium))
                MonitorStackedBar(segments: [
                    .init(id: "应用", value: 6, color: .blue), .init(id: "联动", value: 2, color: .orange),
                    .init(id: "压缩", value: 2, color: .purple), .init(id: "可用", value: 6, color: .gray)
                ]).frame(height: 10)
                Text("应用 6 GB · 联动 2 GB · 压缩 2 GB · 可用 6 GB").font(.caption)
                MonitorAreaSparkline(values: values.history.memory, color: .green, upperBound: 1).frame(height: 55)
            } else if title.contains("电池") {
                HStack(spacing: 18) {
                    Image(systemName: "battery.75percent").font(.system(size: 48)).foregroundStyle(.green)
                    Text("75% · 正在充电\n循环次数 120 次\n电池温度 31°C").font(.system(size: 14))
                }
            } else if title.contains("网络") || title.contains("流量") || title.contains("网速") {
                MonitorNetworkThroughputCard(down: 2_800_000, up: 400_000,
                    downHistory: values.history.netDownload, upHistory: values.history.netUpload, timeSpan: 60, slots: 60)
            } else if title.contains("磁盘") {
                Text("示例 SSD · APFS\n已用 332 GB / 512 GB").font(.system(size: 14))
                ProgressView(value: 332, total: 512)
                Text("读取 18 MB/s · 写入 7 MB/s").font(.caption)
            } else if title.contains("功耗") || title.contains("电源") {
                Text("整机功耗 24.6 W\nCPU 8.4 W · GPU 4.2 W").font(.system(size: 14))
                MonitorAreaSparkline(values: values.history.power, color: .orange).frame(height: 65)
            } else if title.localizedCaseInsensitiveContains("GPU") || title.contains("显卡") || title.contains("图形处理器") {
                HStack {
                    MonitorRing(value: 0.24).frame(width: 70, height: 70)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("图形处理 · 24% · 43°C").font(.caption)
                        MonitorAreaSparkline(values: values.history.gpu, color: .purple, upperBound: 1)
                            .frame(height: 48)
                    }
                }
            } else {
                Text("CPU 38% · 内存 10 GB / 16 GB\n电池 75% · CPU 温度 48°C").font(.system(size: 14))
                MonitorAreaSparkline(values: values.history.cpu, color: .blue, upperBound: 1).frame(height: 65)
            }
            if steps.indices.contains(step) { Text(steps[step]).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
        }.padding(16)
    }
}
