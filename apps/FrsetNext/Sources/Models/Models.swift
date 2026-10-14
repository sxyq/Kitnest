import Foundation

// MARK: - 剪贴板（05 号规格，字段与 clipboard.sqlite 一一对应）

public enum ClipboardItemType: String, Codable, CaseIterable, Sendable {
    case text, richtext, image, file, url
}

public struct ClipboardItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let type: ClipboardItemType
    public var content: String?
    public var title: String?
    public var subtitle: String?
    public let timestamp: Date
    public let sourceApp: String?
    public let imagePath: String?
    public let thumbnailPath: String?
    public let isGeneratedByTool: Bool
    public let isNote: Bool
    public let sourceToolAnalyticsId: String?
    public let sourceToolKeyword: String?
    public let textPath: String?
    public let richTextPath: String?
    public let fullTextCharCount: Int?
    public let fullTextLineCount: Int?
    public let sourceInput: String?
    public let fileIconKey: String?
    public let imageDimensionUnit: String?
    public let payloadKey: String?
    public var storageBytes: Int
    public let dedupeKey: String
    public var aliasTitle: String?
    public var tagIDs: [String]

    public init(id: String = UUID().uuidString,
                type: ClipboardItemType,
                content: String? = nil,
                title: String? = nil,
                subtitle: String? = nil,
                timestamp: Date = Date(),
                sourceApp: String? = nil,
                imagePath: String? = nil,
                thumbnailPath: String? = nil,
                isGeneratedByTool: Bool = false,
                isNote: Bool = false,
                sourceToolAnalyticsId: String? = nil,
                sourceToolKeyword: String? = nil,
                textPath: String? = nil,
                richTextPath: String? = nil,
                fullTextCharCount: Int? = nil,
                fullTextLineCount: Int? = nil,
                sourceInput: String? = nil,
                fileIconKey: String? = nil,
                imageDimensionUnit: String? = nil,
                payloadKey: String? = nil,
                storageBytes: Int = 0,
                dedupeKey: String,
                aliasTitle: String? = nil,
                tagIDs: [String] = []) {
        self.id = id; self.type = type; self.content = content; self.title = title
        self.subtitle = subtitle; self.timestamp = timestamp; self.sourceApp = sourceApp
        self.imagePath = imagePath; self.thumbnailPath = thumbnailPath
        self.isGeneratedByTool = isGeneratedByTool; self.isNote = isNote
        self.sourceToolAnalyticsId = sourceToolAnalyticsId; self.sourceToolKeyword = sourceToolKeyword
        self.textPath = textPath; self.richTextPath = richTextPath
        self.fullTextCharCount = fullTextCharCount; self.fullTextLineCount = fullTextLineCount
        self.sourceInput = sourceInput; self.fileIconKey = fileIconKey
        self.imageDimensionUnit = imageDimensionUnit; self.payloadKey = payloadKey
        self.storageBytes = storageBytes; self.dedupeKey = dedupeKey
        self.aliasTitle = aliasTitle; self.tagIDs = tagIDs
    }

    /// 去重键：类型前缀 + 内容指纹（05 §5.2）
    public static func makeDedupeKey(type: ClipboardItemType, content: String?, imageHash: String?) -> String {
        switch type {
        case .image:  return "img:" + (imageHash ?? UUID().uuidString)
        case .file:   return "file:" + (content ?? "").sha256
        default:      return "txt:" + (content ?? "").sha256
        }
    }

    public var displayTitle: String {
        if let a = aliasTitle, !a.isEmpty { return a }
        if let t = title, !t.isEmpty { return t }
        return (content ?? "").truncatedForDisplay
    }
}

public struct Tag: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var colorHex: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, colorHex: String = "#8E8E93",
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.colorHex = colorHex
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct FileTypeIcon: Codable, Hashable, Sendable {
    public let iconKey: String
    public let handlerBundleId: String?
    public let iconPath: String?
    public let updatedAt: Date
    public init(iconKey: String, handlerBundleId: String? = nil, iconPath: String? = nil, updatedAt: Date = Date()) {
        self.iconKey = iconKey; self.handlerBundleId = handlerBundleId
        self.iconPath = iconPath; self.updatedAt = updatedAt
    }
}

// MARK: - 工具箱（10 号规格）

public enum ToolKind: String, Codable, CaseIterable, Sendable {
    case timestampConverter, ipAddress, varNameConverter, base64, urlEncode
    case jsonFormat, codePreview, imageCompress, colorPicker, translation, hashGenerator
}

public struct ToolInvocationRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let kind: ToolKind
    public let input: String
    public let output: String
    public let createdAt: Date
    public init(id: String = UUID().uuidString, kind: ToolKind, input: String, output: String, createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.input = input; self.output = output; self.createdAt = createdAt
    }
}

// MARK: - AI（09 号规格）

public enum LLMProviderKind: String, Codable, CaseIterable, Sendable {
    case anthropic, gemini, openAICompatible, ollama
}

public struct LLMMessage: Codable, Identifiable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public let id: String
    public var role: Role
    public var content: String
    public init(id: String = UUID().uuidString, role: Role, content: String) {
        self.id = id; self.role = role; self.content = content
    }
}

public struct LLMChatSession: Codable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var messages: [LLMMessage]
    public var provider: LLMProviderKind
    public var model: String?
    public let createdAt: Date
    public var updatedAt: Date
    public init(id: String = UUID().uuidString, title: String = "新会话", messages: [LLMMessage] = [],
                provider: LLMProviderKind = .anthropic, model: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.messages = messages
        self.provider = provider; self.model = model
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

// MARK: - 监测（03 号规格）

public struct MonitorSample: Sendable {
    public var cpuUsage: Double          // 0..1
    public var systemCPU: Double
    public var userCPU: Double
    public var idleCPU: Double
    public var perCore: [Double]
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var memoryPressure: Double    // 0..1
    public var swapUsed: UInt64
    public var diskRead: UInt64          // bytes/s
    public var diskWrite: UInt64
    public var netUpload: UInt64         // bytes/s
    public var netDownload: UInt64
    public var temperatures: [String: Double]
    public var batteryLevel: Double?
    public init() {
        cpuUsage = 0; systemCPU = 0; userCPU = 0; idleCPU = 1; perCore = []
        memoryUsed = 0; memoryTotal = 0; memoryPressure = 0; swapUsed = 0
        diskRead = 0; diskWrite = 0; netUpload = 0; netDownload = 0
        temperatures = [:]; batteryLevel = nil
    }
}

// MARK: - 日历（10 号规格 B）

public struct CalendarDay: Identifiable, Hashable, Sendable {
    public let id: String
    public var date: Date
    public var isToday: Bool
    public var isWeekend: Bool
    public var lunarText: String?
    public var holidayText: String?
    public var events: [CalendarEvent]
    public init(date: Date, isToday: Bool = false, isWeekend: Bool = false,
                lunarText: String? = nil, holidayText: String? = nil, events: [CalendarEvent] = []) {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd"
        self.id = fmt.string(from: date)
        self.date = date; self.isToday = isToday; self.isWeekend = isWeekend
        self.lunarText = lunarText; self.holidayText = holidayText; self.events = events
    }
}

public struct CalendarEvent: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var startDate: Date
    public var endDate: Date?
    public var isAllDay: Bool
    public init(id: String = UUID().uuidString, title: String, startDate: Date,
                endDate: Date? = nil, isAllDay: Bool = false) {
        self.id = id; self.title = title; self.startDate = startDate
        self.endDate = endDate; self.isAllDay = isAllDay
    }
}
