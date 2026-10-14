import Foundation
import AppKit

// MARK: - 内置工具注册
// 每个工具：id / 名称 / 图标 / 分类 / 选项 / 执行函数。
// 执行函数只依赖本模块的转换器，不引用任何其他 Features。

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
        registerTimestampTool()
        registerIPTool()
        registerVarNameTool()
        registerBase64Tool()
        registerURLEncodeTool()
        registerJSONTool()
        registerCodePreviewTool()
        registerImageCompressTool()
        registerHashTool()
        registerQRCodeTool()
    }

    // MARK: 1. 时间戳转换

    private static func registerTimestampTool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "timestamp",
            kind: .timestampConverter,
            name: "时间戳转换",
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
            name: "IP 地址查询",
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
            name: "变量名转换",
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
            name: "Base64 编解码",
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
            name: "URL 编解码",
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
            name: "JSON 格式化",
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

    // MARK: 7. 代码预览

    private static func registerCodePreviewTool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "codepreview",
            kind: .codePreview,
            name: "代码预览",
            systemImage: "chevron.left.slash.chevron.right",
            category: .format,
            placeholder: "粘贴代码片段（Swift / Python / JavaScript / JSON）",
            options: [
                ToolOption(id: "language", title: "语言", choices: CodeLanguage.titles)
            ],
            execute: { input, options in
                let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return ToolOutput.error("请输入代码片段") }
                let language = CodeLanguage(rawValue: (options["language"] ?? "swift").lowercased()) ?? .plain
                let image = CodeHighlighter.cardImage(code: raw, language: language)
                let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).count
                return ToolOutput(text: raw,
                                  image: image,
                                  note: "已按 \(language.rawValue) 关键字着色，共 \(lines) 行；输出为卡片图，可另存为图片")
            }))
    }

    // MARK: 8. 图片压缩（本地重采样 + JPEG；与原作 TinyPNG 网络压缩不同）

    private static func registerImageCompressTool() {
        ToolRegistry.register(ToolDescriptor(
            identifier: "imagecompress",
            kind: .imageCompress,
            name: "图片压缩",
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
            kind: .codePreview,
            name: "二维码生成",
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
                return ToolOutput(text: raw, image: image, note: "纠错等级 \(correction)，输出 \(Int(size)) pt；可在预览图上右键存储")
            }))
    }
}
