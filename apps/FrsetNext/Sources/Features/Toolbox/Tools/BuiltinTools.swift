import Foundation
import AppKit

// MARK: - 内置工具注册
// 每个工具：id / 名称 / 图标 / 分类 / 选项 / 执行函数。
// 文本转换复用本模块转换器，AI 动作复用现有翻译会话与摘要提示词。

public enum BuiltinTools {
    /// 工具默认输出行为（设置页可切换）
    public enum DefaultAction: String, CaseIterable {
        case copy = "复制到剪贴板"
        case save = "存为剪贴板条目"
    }

    public static let defaultActionKey = "toolbox.defaultAction"

    public static var defaultAction: DefaultAction {
        let raw = Preferences.shared.value(defaultActionKey, default: DefaultAction.copy.rawValue)
        return DefaultAction(rawValue: raw) ?? .copy
    }

    public static func setDefaultAction(_ action: DefaultAction) {
        Preferences.shared.set(defaultActionKey, action.rawValue)
    }

    // MARK: 注册入口（ToolboxModule.start 调用）

    public static func registerAll() {
        registerAITool(id: "translate", name: "Translate", description: "Translate text",
                       kind: .translation)
        registerAITool(id: "summary", name: "Summary", description: "Summarize text with AI",
                       kind: .summary)
        registerQRCodeTool()
        registerUUIDTool()
        registerTimestampTool()
        registerJSONTool()
        registerImageCompressTool()
        registerIPTool()
        registerVarNameTool()
        registerBase64Tool()
        registerURLEncodeTool()
        registerCodePreviewTool()
        registerHashTool()
    }

    private static func registerAITool(id: String, name: String, description: String,
                                       kind: ToolKind) {
        ToolRegistry.register(ToolDescriptor(
            identifier: id, kind: kind, name: L10n.t(name),
            keyword: id, toolDescription: L10n.t(description),
            systemImage: id == "translate" ? "character.bubble" : "text.alignleft",
            category: .convert, placeholder: L10n.t(description)
        ) { input, _ in
            do {
                if kind == .translation {
                    return ToolOutput(text: try await TranslationToolSession.shared.complete(input))
                }
                guard let service = ServiceLocator.llmService else {
                    return .error("请先配置 AI 服务商")
                }
                let action = AISummaryAction.summarize
                return ToolOutput(text: try await service.complete(
                    prompt: action.prompt(for: input), system: action.systemPrompt, model: nil))
            } catch {
                return .error(error.localizedDescription)
            }
        })
    }

    private static func registerUUIDTool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "uuid", kind: .uuid, name: "UUID",
            keyword: "uuid", toolDescription: L10n.t("Generate random UUID v4 values"),
            systemImage: "number", category: .convert,
            placeholder: L10n.t("Generate random UUID v4 values")
        ) { _, _ in
            ToolOutput(text: UUID().uuidString.lowercased())
        })
    }

    // MARK: 1. 时间戳转换

    private static func registerTimestampTool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "timestamp",
            kind: .timestampConverter,
            name: L10n.t("Timestamp"),
            keyword: "time",
            toolDescription: L10n.t("Convert between timestamps and dates"),
            systemImage: "clock",
            category: .convert,
            placeholder: "输入 Unix 时间戳（1700000000）或日期（2025-03-01 12:00:00），留空显示当前时间",
            options: [
                ToolOption(id: "direction", title: "方向", choices: ["自动", "时间戳→日期", "日期→时间戳"])
            ],
            execute: { input, options in
                let direction = options["direction"] ?? "自动"
                let text = TimestampConverter.convert(input, direction: direction)
                return ToolOutput(text: text)
            }))
    }

    // MARK: 2. IP 地址查询

    private static func registerIPTool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "ip",
            kind: .ipAddress,
            name: L10n.t("IP Addresses"),
            keyword: "ip",
            toolDescription: L10n.t("View your public and local IP addresses"),
            systemImage: "network",
            category: .network,
            placeholder: "无需输入，点击执行即查询（公网走 api.ipify.org，失败降级内网 IP）",
            options: [
                ToolOption(id: "scope", title: "范围", choices: ["公网 + 内网", "仅内网"])
            ],
            execute: { _, options in
                let onlyLocal = (options["scope"] ?? "公网 + 内网") == "仅内网"
                if onlyLocal {
                    let local = IPAddressService.localIPAddress() ?? "未找到可用网卡地址"
                    return ToolOutput(text: "内网 IP：\(local)")
                }
                let report = await IPAddressService.query(timeout: 6)
                let text = IPAddressService.displayText(report)
                return ToolOutput(text: text,
                                  isError: report.publicIP == nil && report.localIP == nil,
                                  note: "公网来源：api.ipify.org（免 Key）；失败时自动降级为内网 IP")
            }))
    }

    // MARK: 3. 变量名转换

    private static func registerVarNameTool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "varname",
            kind: .varNameConverter,
            name: L10n.t("Variable Naming"),
            keyword: "var",
            toolDescription: "转换变量命名格式（本地执行）",
            systemImage: "chevron.left.forwardslash.chevron.right",
            category: .convert,
            placeholder: "输入变量名，如 user_name / UserName / user-name",
            options: [
                ToolOption(id: "style", title: "目标格式", choices: VarNameStyle.titles)
            ],
            execute: { input, options in
                let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return ToolOutput.error("请输入变量名") }
                let style = VarNameStyle(rawValue: options["style"] ?? "") ?? .camel
                let result = VarNameConverter.convert(raw, to: style)
                return ToolOutput(text: result)
            }))
    }

    // MARK: 4. Base64 编解码

    private static func registerBase64Tool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "base64",
            kind: .base64,
            name: L10n.t("Base64"),
            keyword: "base64",
            toolDescription: L10n.t("Encode or decode Base64 text"),
            systemImage: "doc.text.magnifyingglass",
            category: .encode,
            placeholder: "输入文本（编码）或 Base64 串（解码），支持中文",
            options: [
                ToolOption(id: "mode", title: "操作", choices: ["编码", "解码"])
            ],
            execute: { input, options in
                let mode = options["mode"] ?? "编码"
                if mode == "解码" {
                    let (text, error) = Base64Coder.decode(input)
                    if let error { return ToolOutput.error(error) }
                    return ToolOutput(text: text)
                }
                let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return ToolOutput.error("请输入待编码的文本") }
                return ToolOutput(text: Base64Coder.encode(raw), note: "按 UTF-8 编码，中文可正常往返")
            }))
    }

    // MARK: 5. URL 编解码

    private static func registerURLEncodeTool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "urlencode",
            kind: .urlEncode,
            name: L10n.t("URL Encode"),
            keyword: "url",
            toolDescription: L10n.t("Encode or decode URL text"),
            systemImage: "link",
            category: .encode,
            placeholder: "输入 URL 或查询参数文本",
            options: [
                ToolOption(id: "mode", title: "操作", choices: ["编码", "解码"]),
                ToolOption(id: "charset", title: "编码强度", choices: ["标准", "严格"])
            ],
            execute: { input, options in
                let mode = options["mode"] ?? "编码"
                if mode == "解码" {
                    let (text, error) = URLEncoderTool.decode(input)
                    if let error { return ToolOutput.error(error) }
                    return ToolOutput(text: text)
                }
                let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return ToolOutput.error("请输入待编码的内容") }
                let strict = (options["charset"] ?? "标准") == "严格"
                return ToolOutput(text: URLEncoderTool.encode(raw, strict: strict),
                                  note: strict ? "严格模式：仅保留 - . _ ~ 与字母数字" : "标准模式：保留 URL 查询参数常用字符")
            }))
    }

    // MARK: 6. JSON 格式化 / 压缩

    private static func registerJSONTool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "json",
            kind: .jsonFormat,
            name: L10n.t("JSON"),
            keyword: "json",
            toolDescription: L10n.t("Format or minify JSON"),
            systemImage: "curlybraces",
            category: .format,
            placeholder: "粘贴 JSON 文本",
            options: [
                ToolOption(id: "mode", title: "操作", choices: ["格式化", "压缩"])
            ],
            execute: { input, options in
                let pretty = (options["mode"] ?? "格式化") == "格式化"
                let (text, error) = JSONFormatterTool.process(input, pretty: pretty)
                if let error { return ToolOutput.error(error) }
                return ToolOutput(text: text)
            }))
    }

    // MARK: 7. 代码预览（统一走 CodePreview 引擎：30+ 语言 / 14 套主题 / 富文本）

    private static func registerCodePreviewTool() {
        // 选项里放常用语言（全量 30+ 太长）；默认自动识别
        let common: [String] = ["自动识别", "Swift", "Objective-C", "C", "C++", "C#",
                                "Java", "Kotlin", "Go", "Rust", "Python", "Ruby", "PHP",
                                "JavaScript", "TypeScript", "Dart", "SQL", "Shell",
                                "PowerShell", "HTML", "CSS", "JSON", "YAML", "Markdown"]
        ToolRegistry.register(ToolDescriptor(
            identifier: "codepreview",
            kind: .codePreview,
            name: "代码预览",
            systemImage: "chevron.left.slash.chevron.right",
            category: .format,
            placeholder: "粘贴任意代码片段（30+ 语言自动识别；输出为带配色的卡片图）",
            options: [
                ToolOption(id: "language", title: "语言", choices: common)
            ],
            execute: { input, options in
                let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return ToolOutput.error("请输入代码片段") }

                let choice = options["language"] ?? "自动识别"
                let languageID: String
                if choice == "自动识别" {
                    languageID = CodeLanguageCatalog.detect(raw)
                } else {
                    languageID = CodeLanguageCatalog.all.first { $0.name == choice }?.id ?? "plain"
                }
                let theme = CodePreviewPreferences.themeID.map { CodeThemeCatalog.theme(id: $0) }
                    ?? CodeThemeCatalog.systemDefault
                let renderOptions = CodeRenderOptions(language: languageID,
                                                      theme: theme,
                                                      fontSize: 13,
                                                      showsLineNumbers: true)
                let image = CodeCardImage.render(code: raw, options: renderOptions)
                let lines = CodeHighlighter.statistics(raw).lines
                let name = CodeLanguageCatalog.displayName(languageID)
                return ToolOutput(text: raw,
                                  image: image,
                                  note: "已按 \(name) 着色（\(theme.name) 风格），共 \(lines) 行；右键复制卡片图，复制结果按钮复制代码。")
            }))
    }

    // MARK: 8. 图片压缩（本地重采样 + JPEG；与原作 TinyPNG 网络压缩不同）

    private static func registerImageCompressTool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "imagecompress",
            kind: .imageCompress,
            name: L10n.t("TinyPNG"),
            keyword: "tinypng",
            toolDescription: L10n.t("TinyPNG Compress Images"),
            systemImage: "photo",
            category: .media,
            inputKind: .filePath,
            placeholder: "选择一张图片（png / jpg / heic）",
            options: [
                ToolOption(id: "maxDimension", title: "最长边", choices: ["1024", "1600", "2048"], defaultIndex: 1),
                ToolOption(id: "quality", title: "JPEG 质量", choices: ["0.5", "0.7", "0.85"], defaultIndex: 1),
                ToolOption(id: "format", title: "输出格式", choices: ["JPEG", "PNG"])
            ],
            execute: { input, options in
                let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { return ToolOutput.error("请先选择图片文件") }
                let maxDimension = CGFloat(Double(options["maxDimension"] ?? "1600") ?? 1600)
                let quality = Double(options["quality"] ?? "0.7") ?? 0.7
                let asPNG = (options["format"] ?? "JPEG") == "PNG"
                do {
                    let result = try ImageCompressor.compress(path: path,
                                                              maxDimension: maxDimension,
                                                              quality: quality,
                                                              asPNG: asPNG)
                    var lines: [String] = []
                    lines.append("原始大小：\(ImageCompressor.byteText(result.originalBytes))")
                    lines.append("压缩后：\(ImageCompressor.byteText(result.compressedBytes))")
                    if result.originalBytes > 0 {
                        lines.append("节省：\(String(format: "%.1f%%", result.savedPercent * 100))")
                    }
                    lines.append("输出尺寸：\(Int(result.pixelSize.width))×\(Int(result.pixelSize.height))")
                    if let url = result.fileURL { lines.append("输出文件：\(url.path)") }
                    return ToolOutput(text: lines.joined(separator: "\n"),
                                      image: result.image,
                                      note: "与原作差异：原作使用 TinyPNG 网络 API（需 Key、有配额）；此处为本地 CoreGraphics 重采样 + JPEG 重编码，不联网、无配额")
                } catch {
                    return ToolOutput.error(error.localizedDescription)
                }
            }))
    }

    // MARK: 9. 哈希生成

    private static func registerHashTool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "hash",
            kind: .hashGenerator,
            name: "哈希生成",
            systemImage: "number",
            category: .encode,
            placeholder: "输入待计算哈希的文本（支持中文）",
            options: [
                ToolOption(id: "algorithm", title: "算法", choices: ["MD5", "SHA1", "SHA256"], defaultIndex: 2)
            ],
            execute: { input, options in
                let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return ToolOutput.error("请输入待计算哈希的文本") }
                let algorithm = options["algorithm"] ?? "SHA256"
                let digest = HashGenerator.digest(raw, algorithm: algorithm)
                return ToolOutput(text: digest,
                                  note: "MD5 / SHA1 已不适用于安全场景，仅作校验比对用途；建议优先 SHA256")
            }))
    }

    // MARK: 10. 二维码生成
    // 说明：Models/ToolKind 未定义 qrCode 用例（Models 已定稿且契约禁止修改），
    // 统计上暂归到 .codePreview（同为"渲染类输出"）。待 Models 扩展 ToolKind 后可一行调整为 .qrCode。

    private static func registerQRCodeTool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "qrcode",
            kind: .qrCode,
            name: L10n.t("QR Code"),
            keyword: "qrcode",
            toolDescription: L10n.t("Generate QR Code from text or URL"),
            systemImage: "qrcode",
            category: .media,
            placeholder: "输入要编码的文本或链接",
            options: [
                ToolOption(id: "size", title: "尺寸", choices: ["256", "512", "1024"], defaultIndex: 1),
                ToolOption(id: "correction", title: "纠错等级", choices: ["L", "M", "Q", "H"], defaultIndex: 1)
            ],
            execute: { input, options in
                let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return ToolOutput.error("请输入要编码的内容") }
                let size = CGFloat(Double(options["size"] ?? "512") ?? 512)
                let correction = options["correction"] ?? "M"
                guard let image = QRCodeGenerator.image(from: raw, size: size, correction: correction) else {
                    return ToolOutput.error("二维码生成失败：内容可能过长或包含不受支持的字符")
                }
                return ToolOutput(text: raw, image: image, note: "纠错等级 \(correction)，输出 \(Int(size)) pt；可在预览图上右键复制图片")
            }))
    }
}
