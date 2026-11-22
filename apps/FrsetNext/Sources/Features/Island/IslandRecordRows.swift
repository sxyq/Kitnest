// 本文件由 IslandContent.swift 拆出（2026-11-23 文档体系整理，纯类型搬家，无行为变化）。
import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers

struct IslandRecordPreview: View {
    let item: ClipboardItem
    let sessionID: UUID
    @Stored private var model: PreviewPopoverContentModel?

    var body: some View {
        ZStack {
            if let model { PreviewPopoverContentView(model: model, usesWindowChrome: false, showsTOC: false) }
            else { ProgressView().controlSize(.small) }
        }
        .task {
            let loaded = await Task.detached(priority: .userInitiated) { [item, sessionID] in
                PreviewPopoverContentModel(item: item, source: .mainPreview, sessionID: sessionID,
                    inlineText: PreviewPopoverDataBridge.shared.fullText(for: item), fullTextLoaded: true)
            }.value
            guard !Task.isCancelled else { return }
            model = loaded
        }
    }
}

/// 刘海列表行只携带两个正式来源的引用，不修改、迁移或删除源记录。
struct IslandRecentRow: View, Identifiable {
    let id: String
    let title: String
    let icon: String
    var date: Date
    var clipboard: ClipboardItem? = nil
    var transfer: LocalTransferItem? = nil
    var url: URL? = nil
    var sample: IslandSample? = nil

    var previewKey: String {
        [id, url?.path, clipboard?.id, clipboard?.dedupeKey, transfer?.id, title].compactMap { $0 }.joined(separator: "|")
    }

    var previewItem: ClipboardItem {
        if let url, clipboard?.type != .image {
            return ClipboardItem(id: id, type: .file, content: url.path, title: title,
                                 subtitle: transfer?.originalPath, timestamp: date,
                                 sourceApp: transfer != nil ? "中转站" : clipboard?.sourceApp,
                                 dedupeKey: previewKey, fileCategories: clipboard?.fileCategories ?? 0)
        }
        let type: ClipboardItemType = icon == "photo" ? .image : icon == "link" ? .url
            : icon == "folder" || icon == "archivebox" || icon == "doc.text" ? .file : .text
        return clipboard ?? ClipboardItem(id: id, type: type, content: type == .file ? title : sample?.body,
                                          title: title, subtitle: sample?.detail, timestamp: date, dedupeKey: id,
                                          fileCategories: 0)
    }

    /// 文件记录已按路径拆行，不能复制原剪贴板条目里未选中的其他文件。
    @MainActor func copy(previewOnly: Bool) async -> String? {
        if previewOnly { return "复制效果预览" }
        if clipboard?.type == .image, let item = clipboard {
            return ClipboardManager.shared.copy(item, autoPaste: false)
        }
        if let url { return ClipboardManager.shared.copyFiles([url], successMessage: "已复制 " + title) }
        guard let item = clipboard else { return "记录没有可复制的内容" }
        let result = await Task.detached(priority: .userInitiated) { () -> (String, String?) in
            var failure: String?
            let text = ClipboardManager.shared.fullText(for: item) { failure = $0 }
            return (text, failure)
        }.value
        if let failure = result.1 { return failure }
        if item.type == .richtext {
            let fullItem = ClipboardItem(id: item.id, type: item.type, content: result.0,
                richTextPath: item.richTextPath, dedupeKey: item.dedupeKey)
            return ClipboardManager.shared.copy(fullItem, autoPaste: false)
        }
        return ClipboardManager.shared.copyText(result.0, successMessage: "已复制 " + title)
    }


    var body: some View {
        ClipboardRow(item: previewItem, isHighlighted: false, onCopy: {})
    }
}

/// 只取消记录列表的系统焦点装饰，保留方向键与复制命令。
struct IslandRecordFocusAppearance: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}
