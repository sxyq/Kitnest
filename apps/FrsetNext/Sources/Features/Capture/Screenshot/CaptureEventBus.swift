import Foundation

// MARK: - 跨模块事件总线

/// 截图产出向外广播的总线。
///
/// 设计原因：本模块禁止直接引用其它 Features 的具体类型（见 CONTRACT §1.3），
/// 而原作中「截图后写入剪贴板历史」是一条真实链路（ClipboardOCRTextStorage）。
/// 这里改成回调：由 App 总控在接线阶段把 onImageCaptured 指向剪贴板模块的入库函数。
public enum CaptureEventBus {
    /// 图片已落盘：参数为文件 URL 与 PNG 原始数据
    public static var onImageCaptured: ((URL, Data) -> Void)?
    /// OCR 产出的文本（供剪贴板、翻译等模块消费）
    public static var onTextRecognized: ((String) -> Void)?
    /// 取色成功的 HEX 文本，由 App 层写入历史并记录取色次数。
    public static var onColorPicked: ((String) -> Void)?
}

// MARK: - 截图翻译 / 划词翻译请求（面板功能菜单 → App 层会话）

/// 翻译会话由 App 层持有（AppBootstrap），Capture 模块只发请求，
/// 保持 CONTRACT §1.3「模块之间不互相引用具体类型」。
public extension Notification.Name {
    /// 截图翻译：截取区域 → OCR → 交给划词翻译会话
    static let frsetScreenshotTranslate = Notification.Name("frset.screenshotTranslate.request")
    /// 划词翻译：读取当前选中文本 → 翻译
    static let frsetTranslateSelection = Notification.Name("frset.translateSelection.request")
}

// MARK: - 截图模式与产出

/// 截图模式（沿用原作 CaptureMode 语义）
public enum CaptureMode: String, CaseIterable, Identifiable {
    // v130（SnowShot 对齐）④：新增 .delayed 延时截图（N 秒后自动截图）
    case area, full, window, ocr, pin, long, annotate, color, delayed

    public var id: String { rawValue }

    /// 面板入口标题
    public var title: String {
        switch self {
        // v267：自适应之后「区域」这个限定已经不成立（悬停窗口单击就截窗），
        // 入口就叫「截图」；.window 保留给历史库标签与 ⇧⌥W 的兼容。
        case .area:     return "截图"
        case .full:     return "全屏截图"
        case .window:   return "窗口截图"
        case .ocr:      return "截图识字"
        case .pin:      return "屏幕钉图"
        case .long:     return "长截图"
        case .annotate: return "标注编辑"
        case .color:    return "取色器"
        case .delayed:  return "延时截图"
        }
    }

    /// 面板入口图标（SF Symbols）
    public var systemImage: String {
        switch self {
        case .area:     return "crop"
        case .full:     return "macwindow"
        case .window:   return "macwindow.on.rectangle"
        case .ocr:      return "text.viewfinder"
        case .pin:      return "pin"
        case .long:     return "rectangle.stack"
        case .annotate: return "pencil.and.outline"
        case .color:    return "eyedropper"
        case .delayed:  return "timer"
        }
    }
}

/// 截图完成后的默认动作（设置项；v67 扩展为动作链全量，与 CaptureActionChain.tools 对应）
public enum CaptureDefaultAction: String, CaseIterable, Identifiable {
    case save, clipboard, ocr, pin, screenTranslate, annotate, beautify

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .save:            return "保存到文件夹"
        case .clipboard:       return "复制到剪贴板"
        case .ocr:             return "识别图中文字"
        case .pin:             return "钉在屏幕上"
        case .screenTranslate: return "屏幕翻译（贴图回填）"
        case .annotate:        return "打开标注编辑"
        case .beautify:        return "截图美化"
        }
    }
}

/// 一张已保存的截图记录
public struct CapturedImage: Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public let createdAt: Date

    public init(id: UUID = UUID(), url: URL, createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.createdAt = createdAt
    }
}

/// 截图 / OCR 错误（中文提示直接给 UI 用）
public enum CaptureError: LocalizedError {
    case permissionDenied
    case captureFailed
    case saveFailed
    case invalidImage
    case noText

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "没有屏幕录制权限，无法截图"
        case .captureFailed:    return "截图失败，请重试"
        case .saveFailed:       return "截图保存失败，请检查保存路径"
        case .invalidImage:     return "无法读取图片数据"
        case .noText:           return "没有识别到文字"
        }
    }
}
