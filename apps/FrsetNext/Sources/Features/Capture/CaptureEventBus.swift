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
    /// OCR / 取色产出的文本（供剪贴板、翻译等模块消费）
    public static var onTextRecognized: ((String) -> Void)?
}

// MARK: - 截图模式与产出

/// 截图模式（沿用原作 CaptureMode 语义）
public enum CaptureMode: String, CaseIterable, Identifiable {
    case area, full, ocr, pin, long, annotate, color

    public var id: String { rawValue }

    /// 面板入口标题
    public var title: String {
        switch self {
        case .area:     return "区域截图"
        case .full:     return "全屏截图"
        case .ocr:      return "截图识字"
        case .pin:      return "屏幕钉图"
        case .long:     return "长截图"
        case .annotate: return "标注编辑"
        case .color:    return "取色器"
        }
    }

    /// 面板入口图标（SF Symbols）
    public var systemImage: String {
        switch self {
        case .area:     return "crop"
        case .full:     return "macwindow"
        case .ocr:      return "text.viewfinder"
        case .pin:      return "pin"
        case .long:     return "rectangle.stack"
        case .annotate: return "pencil.and.outline"
        case .color:    return "eyedropper"
        }
    }
}

/// 截图完成后的默认动作（设置项）
public enum CaptureDefaultAction: String, CaseIterable, Identifiable {
    case save, clipboard, ocr, pin

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .save:      return "保存到文件夹"
        case .clipboard: return "复制到剪贴板"
        case .ocr:       return "识别图中文字"
        case .pin:       return "钉在屏幕上"
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
