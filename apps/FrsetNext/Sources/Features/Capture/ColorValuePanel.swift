import SwiftUI
import AppKit

// v130（SnowShot 对齐）⑥：取色增强——色值面板
//
// Snow Shot 取色后显示色值 + 复制格式。本文件是取色完成后的色值面板：
//   · HEX / RGB / HSB 三种格式，点行即复制该格式；
//   · 取色历史（最近 10 个色块，点色块复取/复制）；
//   · 非激活浮窗，Esc / 关闭按钮 / 点击外部即收起。

// MARK: - 色值换算

enum ColorFormats {
    /// #RRGGBB
    static func hex(_ color: NSColor) -> String { EyedropperView.hex(of: color) }

    /// "R, G, B"（0-255）
    static func rgb(_ color: NSColor) -> String { EyedropperView.rgbText(of: color) }

    /// "H°, S%, B%"（HSB/HSV）
    static func hsb(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "0°, 0%, 0%" }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return "\(Int((h * 360).rounded()))°, \(Int((s * 100).rounded()))%, \(Int((b * 100).rounded()))%"
    }
}

// MARK: - 色值面板视图

struct ColorValueView: View {
    let color: NSColor
    let recentColors: [String]
    let onCopy: (String) -> Void
    let onPickRecent: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: color))
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("取色结果")
                        .font(.system(size: 11, weight: .semibold))
                    Text("点击任一行复制该格式")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            formatRow(title: "HEX", value: ColorFormats.hex(color))
            formatRow(title: "RGB", value: ColorFormats.rgb(color))
            formatRow(title: "HSB", value: ColorFormats.hsb(color))

            if !recentColors.isEmpty {
                Divider()
                Text("最近取色（点击复制）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                // v130⑥：取色历史，最近 10 个色块可复取
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 20), spacing: 6)], spacing: 6) {
                    ForEach(recentColors, id: \.self) { hex in
                        Button {
                            onPickRecent(hex)
                        } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(hexString: hex))
                                .frame(width: 20, height: 20)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(hex)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func formatRow(title: String, value: String) -> some View {
        Button {
            onCopy(value)
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 色值浮窗

final class ColorValuePanelController: NSObject, NSWindowDelegate {
    public static let shared = ColorValuePanelController()
    private var panel: NSPanel?
    private var outsideMonitor: Any?

    private override init() { super.init() }

    /// 在光标附近弹出色值面板
    func show(color: NSColor, recentColors: [String], at point: NSPoint? = nil) {
        close()
        let view = ColorValueView(
            color: color,
            recentColors: recentColors,
            onCopy: { text in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                Toast.show("已复制 \(text)", icon: "checkmark.circle.fill")
            },
            onPickRecent: { hex in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(hex, forType: .string)
                Toast.show("已复制 \(hex)", icon: "checkmark.circle.fill")
            },
            onClose: { [weak self] in self?.close() })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize

        let anchor = point ?? NSEvent.mouseLocation
        var origin = NSPoint(x: anchor.x + 18, y: anchor.y - size.height - 18)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = host
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 点击面板外部即关闭（global 需辅助功能授权，未授权时静默失效）
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        if let monitor = outsideMonitor { NSEvent.removeMonitor(monitor) }
        outsideMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - 颜色工具

private extension Color {
    /// #RRGGBB → Color（解析失败回退灰色）
    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&value) else {
            self = Color.gray
            return
        }
        self = Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}
