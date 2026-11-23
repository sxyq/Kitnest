// 2026-11-23 由 PersonalizationSettingsPane.swift 拆出：纯类型搬家，无行为变化。
import AppKit
import Combine
import ImageIO
import SwiftUI

// MARK: - 外观草稿：控件只更新预览，保存才应用到正式窗口。

final class AppearanceSettingsDraft: SettingsEditableDraft {
    let scope: PersonalizationSettingsPart
    @Published var personalization = Personalization.shared.makeDraft() {
        didSet { observeChanges() }
    }
    @Published var panelWidth = Preferences.shared.value(Preferences.Keys.panelWidth, default: 400.0)
    @Published var toolbarStyle = CaptureToolbarStyle.current.rawValue
    @Published var appearance = AppearanceManager.shared.mode
    @Published var segmentHome = Preferences.shared.value(PanelSegments.homeKey, default: true)
    @Published var segmentMonitor = Preferences.shared.value(PanelSegments.monitorKey, default: true)
    @Published var pageOrder = PanelSegments.order
    @Published var previewSelectedItemID: String? = "appearance-note"
    @Published var floating = FloatingClipDeskStore(settingsPreview: true) {
        didSet { observeChanges() }
    }
    @Published var floatingFrame: NSRect?
    private var savedPersonalization = Personalization.shared.makeDraft()
    private var savedValues: [String] = []
    private var observation: AnyCancellable?

    init(scope: PersonalizationSettingsPart) {
        self.scope = scope
        savedValues = values
        observeChanges()
    }

    var isDirty: Bool {
        (scope == .floatingClipboard && floatingFrame != nil) || values != savedValues || !scope.personalizationFields.allSatisfy {
            $0.matches(personalization, savedPersonalization)
        }
    }

    private var values: [String] {
        switch scope {
        case .mainPanel:
            return [String(panelWidth), String(segmentHome), String(segmentMonitor),
                    PanelSegments.encode(pageOrder)]
        case .floatingClipboard:
            return [floating.layout.rawValue, floating.cardSize.rawValue, String(Double(floating.splitRatio)),
                    String(floating.hoverPreviewEnabled)]
        case .captureToolbar: return [toolbarStyle]
        case .shared: return [appearance.rawValue]
        default: return []
        }
    }

    private func observeChanges() {
        observation = personalization.objectWillChange.merge(with: floating.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var previewPages: [PanelCenterPage] {
        pageOrder.filter {
            switch $0 {
            case .home: return segmentHome
            case .performance: return segmentMonitor
            }
        }
    }

    func save() -> String? {
        let preferences = Preferences.shared
        switch scope {
        case .mainPanel:
            if values[0] != savedValues[0] { preferences.set(Preferences.Keys.panelWidth, panelWidth) }
            if values[1] != savedValues[1] { preferences.set(PanelSegments.homeKey, segmentHome) }
            if values[2] != savedValues[2] { preferences.set(PanelSegments.monitorKey, segmentMonitor) }
            if values[3] != savedValues[3] { PanelSegments.order = pageOrder }
        case .floatingClipboard:
            let applied = FloatingClipDeskStore.shared
            if values[0] != savedValues[0] { applied.layout = floating.layout }
            if values[1] != savedValues[1] { applied.cardSize = floating.cardSize }
            if values[2] != savedValues[2] { applied.splitRatio = floating.splitRatio; applied.persistSplitRatio() }
            if values[3] != savedValues[3] { applied.hoverPreviewEnabled = floating.hoverPreviewEnabled }
            if let frame = floatingFrame {
                FloatingClipboardWindowController.shared.window?.setFrame(frame, display: true)
                FloatingClipboardPinState.shared.save(frame: frame)
            }
        case .captureToolbar:
            if values != savedValues { preferences.set(CaptureToolbarStyle.preferenceKey, toolbarStyle) }
        case .shared:
            if values != savedValues { AppearanceManager.shared.apply(appearance) }
        default: break
        }
        let fields = scope.personalizationFields.filter { !$0.matches(personalization, savedPersonalization) }
        if !fields.isEmpty {
            Personalization.shared.applyDraft(personalization, fields: fields)
        }
        guard UserDefaults.standard.synchronize() else {
            return "外观设置写入磁盘失败，草稿已保留，请重新保存。"
        }
        savedPersonalization = personalization.makeDraft()
        savedValues = values
        floatingFrame = nil
        objectWillChange.send()
        return nil
    }

    func discard() {
        floatingFrame = nil
        reloadSavedValues(preservingOwned: false)
        savedPersonalization = personalization.makeDraft()
        savedValues = values
    }

    func refreshUnownedValues() { reloadSavedValues(preservingOwned: true) }

    private func reloadSavedValues(preservingOwned: Bool) {
        let current = Personalization.shared.makeDraft()
        if preservingOwned {
            for field in scope.personalizationFields { field.copy(current, personalization) }
        }
        // 原地刷新，不换实例：控件在 init 时捕获了 draft.personalization，
        // 换实例会让控件写旧对象、预览读新对象，点击看起来完全没反应。
        personalization.copyValues(from: current)
        if !preservingOwned || scope != .mainPanel {
            panelWidth = Preferences.shared.value(Preferences.Keys.panelWidth, default: 400.0)
            segmentHome = Preferences.shared.value(PanelSegments.homeKey, default: true)
            segmentMonitor = Preferences.shared.value(PanelSegments.monitorKey, default: true)
            pageOrder = PanelSegments.order
        }
        if !preservingOwned || scope != .captureToolbar { toolbarStyle = CaptureToolbarStyle.current.rawValue }
        if !preservingOwned || scope != .shared { appearance = AppearanceManager.shared.mode }
        if !preservingOwned || scope != .floatingClipboard {
            floating.layout = FloatingClipPrefs.layout
            floating.cardSize = FloatingClipPrefs.cardSize
            floating.splitRatio = FloatingClipPrefs.splitRatio
            floating.hoverPreviewEnabled = FloatingClipPrefs.hoverPreviewEnabled
        }
    }

    func restoreDefaults() {
        discard()
        let defaults = Personalization.makeDefaultDraft()
        for field in scope.personalizationFields { field.copy(personalization, defaults) }
        switch scope {
        case .mainPanel:
            panelWidth = 400
            segmentHome = true
            segmentMonitor = true
            pageOrder = PanelSegments.defaultOrder
        case .floatingClipboard:
            floating.layout = .grid
            floating.cardSize = .medium
            floating.splitRatio = 0.52
            floating.hoverPreviewEnabled = true
            if let visible = FloatingClipboardWindowController.shared.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                var frame = FloatingClipboardPinState.shared.clampedFrame()
                frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
                floatingFrame = frame
            }
        case .captureToolbar: toolbarStyle = CaptureToolbarStyle.pillBar.rawValue
        case .shared: appearance = .system
        default: break
        }
    }
}

