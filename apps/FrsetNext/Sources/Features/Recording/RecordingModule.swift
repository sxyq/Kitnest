import SwiftUI
import AppKit

// MARK: - 录屏模块入口（v264）
//
// 这一版把「录屏五件套」做成一个独立模块：
//   ① 摄像头画中画 ② 显示按键 ③ 忽略指定 App ④ 点击动画 ⑤ 裁剪导出
// 模块本身只负责注册面板区段；真正的采集在 ScreenRecorder，
// 设置页挂在「截图与钉图」总页的最后一块（录屏和截图是同一类工作流）。

public enum RecordingModule: AppModule {
    public static let identifier = "recording"

    public static func start() {
        PanelSectionRegistry.register(PanelSectionDescriptor(
            id: "recording",
            title: "录屏",
            priority: 45,
            build: { AnyView(RecordingPanelSection()) }))

        // 排障探针：FRSET_RECORD_PROBE=1 → 启动 4s 后直接开录 3 秒再停，
        // 用来在无人值守时验证「采集 → 合成 → 写盘」整条链路。
        if ProcessInfo.processInfo.environment["FRSET_RECORD_PROBE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                Task { @MainActor in
                    var options = RecordingOptions.current()
                    // 叠加探针：强制打开按键/点击，验证 Core Image 合成 + 写盘
                    if ProcessInfo.processInfo.environment["FRSET_RECORD_OVERLAY_PROBE"] == "1" {
                        options.showKeys = true
                        options.showClicks = true
                    }
                    await ScreenRecorder.shared.start(options: options)
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    _ = await ScreenRecorder.shared.stop()
                    Log.info("Recording", "探针：录制 3 秒结束")
                }
            }
        }

        Log.info("Recording", "录屏模块已启动")
    }
}

// MARK: - 主面板区段

struct RecordingPanelSection: View {
    @ObservedObject private var recorder = ScreenRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: recorder.state.isActive ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(recorder.state.isActive ? Color.red : Color.secondary)
                Text(recorder.state.isActive ? "录制中 \(recorder.elapsedText)" : "录屏")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if recorder.state.isActive {
                    Button("暂停 / 继续") { recorder.togglePause() }
                        .controlSize(.small)
                    Button("停止并编辑") { Task { await recorder.stop() } }
                        .controlSize(.small)
                } else {
                    Button("录整屏") { recorder.startDisplayRecording() }
                        .controlSize(.small)
                    Button("录区域…") { recorder.startRegionRecording() }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            Text("摄像头画中画、按键显示、点击动画、忽略 App 都在 设置 → 截图与钉图 → 录屏 里。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
    }
}
