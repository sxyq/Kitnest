import SwiftUI
import AppKit

public struct ShortcutSettingsPane: View {
    @Stored private var revision = 0

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            pair("openFrset", nil)
            pair("floatingClipboard", "openAndSearch")
            Divider().padding(.vertical, 8)
            pair("screenshot", "screenshotOCR")
            pair("screenshotCopy", "colorPicker")
            pair("screenshotPin", nil)
            Divider().padding(.vertical, 8)
            pair("screenshotTranslate", "translateSelection")
            Divider().padding(.vertical, 8)
            // 面板内快捷键（官方原版第四组，静态展示不可改）：粘贴 ↩ / 搜索剪贴板 ⌘F
            // / 预览 ⎋ / 新建笔记 ⌘N（2026-10-18 逐项对照官方快捷键页补齐）
            HStack(spacing: 30) {
                staticRow("粘贴", key: "↩")
                staticRow("搜索剪贴板", key: "⌘ F")
            }
            .frame(height: 37)
            HStack(spacing: 30) {
                staticRow("搜索（面板内）", key: "⌘ K")
                staticRow("预览", key: "⎋")
                staticRow("新建笔记", key: "⌘ N")
            }
            .frame(height: 37)
            Divider().padding(.top, 8)
            // 原版行为（2026-10-18 AX 实测）：点击即重置、无二次确认，随后弹「已重置」通知条。
            Button {
                AppBootstrap.restoreDefaultShortcuts()
                revision += 1
                Toast.show("已重置", icon: "arrow.clockwise")
            } label: {
                Label("恢复默认快捷键", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.link)
            .frame(height: 42)
        }
        .padding(.horizontal, 30)
        .font(.system(size: 12))
        .id(revision)
    }

    private func pair(_ left: String, _ right: String?) -> some View {
        HStack(spacing: 30) {
            shortcutRow(left)
            if let right { shortcutRow(right) }
            else { Color.clear.frame(maxWidth: .infinity) }
        }
        .frame(height: 37)
    }

    /// 面板内快捷键静态行（官方第四组：键位固定、不提供录入/清除）
    private func staticRow(_ title: String, key: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 150, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.025)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.09), lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }

    private func shortcutRow(_ id: String) -> some View {
        let entry = AppBootstrap.defaultHotkeys.first { $0.id == id }!
        let binding = AppBootstrap.shortcutBinding(for: id)
        let doubleTap = AppBootstrap.doubleTapModifier(for: id)

        return HStack(spacing: 10) {
            Text(entry.title)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)

            if let modifier = doubleTap {
                // 双击模式：原组合键位置换成「双击修饰键」下拉（原版 ⌘ ⌘ / ⌥ ⌥ / ⌃ ⌃ / ⇧ ⇧）
                Menu {
                    ForEach(DoubleTapModifier.allCases) { candidate in
                        Button {
                            AppBootstrap.setDoubleTapModifier(id, candidate)
                            revision += 1
                        } label: {
                            Text(candidate.display)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(modifier.display)
                            .font(.system(size: 11))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .frame(width: 150, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.025)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.09), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 150)
                .help("双击 \(modifier.symbol) 触发「\(entry.title)」")
            } else {
                ShortcutRecorderButton(
                    display: binding.map { ShortcutManager.display(keyCode: $0.keyCode, modifiers: $0.modifiers) },
                    onCapture: { code, modifiers in
                        _ = AppBootstrap.setShortcut(id, keyCode: code, modifiers: modifiers)
                        revision += 1
                    },
                    onClear: {
                        _ = AppBootstrap.setShortcut(id, keyCode: nil)
                        revision += 1
                    })
                    .frame(width: 150)
                    .help(ShortcutManager.shared.failureReason(id: id) ?? "点击录入快捷键；右键可清除")
            }

            DoubleTapSwitch(isOn: doubleTap != nil) {
                AppBootstrap.setDoubleTap(id, enabled: doubleTap == nil)
                revision += 1
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 双击快捷键开关（原版 DoubleTapInlineSwitch：小号系统开关样式）

/// 用户确认：原版该控件就是一个小号**开关**（开=蓝、圆点在右；关=灰、圆点在左），
/// 不是带「2×」字样的胶囊。AX 描述沿用原版的 2× 标识。
struct DoubleTapSwitch: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.accent : Color.primary.opacity(0.16))
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
        .help("双击快捷键")
        .accessibilityLabel("2×")
    }
}
