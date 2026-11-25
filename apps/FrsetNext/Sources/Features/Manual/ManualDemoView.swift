import SwiftUI

struct ManualDemoFrame: Decodable {
    let title: String
    let action: String
    let items: [String]
    let selected: Int
}

/// 文章中的预设画面与操作步骤同步播放；所有按钮只改变演示。
struct ManualDemoView: View {
    let title: String
    let symbol: String
    let steps: [String]
    let frames: [ManualDemoFrame]
    let scene: String

    @Stored private var step = 0
    @Stored private var playing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lastStep: Int { steps.count - 1 }
    /// 2026-11-26 修复：frames 来自文档 `<!-- frame: -->` 元数据，与 steps 独立，
    /// 可能缺失或帧数少于步数——原 `frames[step]` 强下标在首帧即越界崩溃。
    /// 这里钳制到有效范围，完全无帧时给占位帧（items 为空，不渲染步骤行）。
    private var frame: ManualDemoFrame {
        guard !frames.isEmpty else {
            return ManualDemoFrame(title: title, action: "—", items: [], selected: 0)
        }
        return frames[min(max(0, step), frames.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("操作演示", systemImage: "play.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("示例演示").font(.caption).foregroundStyle(.secondary)
                Button {
                    if playing {
                        playing = false
                    } else {
                        if step == lastStep { advance(to: 0) }
                        playing = true
                    }
                } label: {
                    Label(playing ? "暂停" : "播放", systemImage: playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                Button("重来") { playing = false; advance(to: 0) }
                    .buttonStyle(.borderless)
            }

            HStack(spacing: 6) {
                preset("看懂用途", index: 0)
                preset("跟着操作", index: min(1, lastStep))
                preset("查看结果", index: lastStep)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(title, systemImage: symbol)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("\(step + 1) / \(steps.count)")
                        .font(.system(size: 11, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(frame.title).font(.system(size: 13, weight: .semibold))
                    Divider()
                    illustration
                    ForEach(Array(frame.items.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 8) {
                            Image(systemName: index == frame.selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(index == frame.selected ? Theme.accent : .secondary)
                            Text(item).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .background(index == frame.selected ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay(alignment: .trailing) {
                            if index == frame.selected {
                                Image(systemName: "cursorarrow")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .offset(x: -8, y: 6)
                            }
                        }
                    }
                    Label(frame.action, systemImage: "hand.tap")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            playing = false
                            advance(to: step == lastStep ? 0 : step + 1)
                        } label: {
                            Label(step == lastStep ? "重新演示" : "演示：\(frame.action)",
                                  systemImage: step == lastStep ? "arrow.counterclockwise" : "cursorarrow.click")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .help("只切换演示步骤，不执行真实操作")
                    }
                }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .id(step)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 5)))
                ProgressView(value: Double(step + 1), total: Double(steps.count))
                    .tint(Theme.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                    Button {
                        playing = false
                        advance(to: index)
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 20, height: 20)
                                .background(index == step ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05),
                                            in: Circle())
                            Text(text)
                                .font(.system(size: 12))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(index == step ? Theme.accent : .secondary)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("预设演示只展示操作步骤，不会打开或修改你的文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
        .task(id: playing) { @MainActor in
            guard playing else { return }
            for index in step..<steps.count {
                advance(to: index)
                do { try await Task.sleep(nanoseconds: 2_400_000_000) }
                catch { return }
            }
            playing = false
        }
        .onDisappear { playing = false }
    }

    private func advance(to index: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            step = index
        }
    }

    @ViewBuilder private var illustration: some View {
        if scene == "photo" || scene == "crop" {
            Image(nsImage: SettingsPreviewSamples.image)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if scene == "crop" {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [5]))
                            .frame(width: step == 0 ? 65 : 125, height: step == 0 ? 38 : 72)
                    }
                }
        } else if scene == "displays" {
            HStack(spacing: 18) {
                ForEach(["普通外接屏", "内置刘海屏"], id: \.self) { name in
                    VStack(spacing: 4) {
                        Image(systemName: name == "普通外接屏" ? "display" : "laptopcomputer")
                            .font(.system(size: 38))
                            .foregroundStyle((step == lastStep) == (name == "普通外接屏") ? Theme.accent : .secondary)
                        Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
            }
        } else if scene == "clipboard" {
            HStack(alignment: .top, spacing: 10) {
                Label("周五交付", systemImage: "doc.text")
                    .font(.system(size: 11)).padding(10)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                Divider().frame(height: 48)
                Text(step == 0 ? "点选记录查看内容" : "周五交付\n整理图片、文字和交付清单。")
                    .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func preset(_ title: String, index: Int) -> some View {
        Button(title) {
            playing = false
            advance(to: index)
        }
        .font(.system(size: 11, weight: .medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(step == index ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 7))
        .buttonStyle(.plain)
        .foregroundStyle(step == index ? Theme.accent : .secondary)
    }
}
