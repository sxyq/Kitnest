import AppKit

// 文件悬停入口复用剪贴板预览窗；正文读取与文件类型表供正式预览、归档共用。


public enum FilePreviewBuilder {

    /// 文本类扩展名（直接显示原文）
    public static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "xml", "csv", "tsv", "yml", "yaml", "log",
        "swift", "py", "js", "ts", "jsx", "tsx", "java", "kt", "go", "rs", "c", "cpp",
        "h", "hpp", "m", "mm", "sh", "zsh", "rb", "php", "html", "css", "scss", "sql", "plist"
    ]

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "tif", "ico"
    ]

    /// 读取完整正文，沿用 UTF-8 / Latin-1 文件编码。
    static func readText(url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

}

// MARK: - 文件预览入口（窗口与交互由剪贴板协调器统一持有）

public final class FileHoverPreviewController: NSResponder {
    public static let shared = FileHoverPreviewController()

    private var showWork: DispatchWorkItem?
    private var currentURL: URL?

    public func scheduleShow(url: URL,
                             after delay: TimeInterval = MainPanelPreviewPopoverCoordinator.shared.hoverPreviewOpenDelay,
                             anchorRectInScreen: CGRect? = nil,
                             sourceWindow: NSWindow? = nil) {
        let coordinator = MainPanelPreviewPopoverCoordinator.shared
        coordinator.cancelHoverClose()
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak sourceWindow] in
            self?.showNow(url: url, anchorRectInScreen: anchorRectInScreen, sourceWindow: sourceWindow)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    public func showNow(url: URL, anchorRectInScreen: CGRect? = nil, sourceWindow: NSWindow? = nil) {
        showWork?.cancel()
        showWork = nil
        currentURL = url
        MainPanelPreviewPopoverCoordinator.shared.presentFile(
            url: url, anchorRectInScreen: anchorRectInScreen, sourceWindow: sourceWindow)
    }

    public func scheduleHide() {
        showWork?.cancel()
        showWork = nil
        guard let currentURL else { return }
        MainPanelPreviewPopoverCoordinator.shared.scheduleHoverClose(itemID: Self.itemID(for: currentURL))
    }

    static func itemID(for url: URL) -> String { "file-preview:" + url.path }
}
