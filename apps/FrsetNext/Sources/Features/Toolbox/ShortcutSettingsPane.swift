import SwiftUI
import AppKit

public struct ShortcutSettingsPane: View {
    @Stored private var revision = 0
    @Stored private var confirmReset = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            pair("openFrset", nil)
            pair("floatingClipboard", "openAndSearch")
            Divider().padding(.vertical, 18)
            pair("screenshot", "screenshotOCR")
            pair("screenshotCopy", "colorPicker")
            pair("screenshotPin", nil)
            Divider().padding(.vertical, 18)
            pair("screenshotTranslate", "translateSelection")
            Divider().padding(.top, 18)
            Button { confirmReset = true } label: {
                Label("恢复默认快捷键", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.link)
            .frame(height: 50)
        }
        .padding(.horizontal, 30)
        .font(.system(size: 12))
        .id(revision)
        .confirmationDialog("恢复默认快捷键？", isPresented: $confirmReset) {
            Button("恢复默认快捷键") {
                AppBootstrap.restoreDefaultShortcuts()
                revision += 1
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func pair(_ left: String, _ right: String?) -> some View {
        HStack(spacing: 30) {
            shortcutRow(left)
            if let right { shortcutRow(right) }
            else { Color.clear.frame(maxWidth: .infinity) }
        }
        .frame(height: 51)
    }

    private func shortcutRow(_ id: String) -> some View {
        let entry = AppBootstrap.defaultHotkeys.first { $0.id == id }!
        let binding = AppBootstrap.shortcutBinding(for: id)
        return HStack(spacing: 12) {
            Text(entry.title)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
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
        .frame(maxWidth: .infinity)
    }
}
