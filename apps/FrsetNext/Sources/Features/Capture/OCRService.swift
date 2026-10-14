import Foundation
import CoreGraphics
import ImageIO
import Vision

// MARK: - 直连模式的图片缓存

/// 直连通道的图片缓存（对应原作 `ScreenshotOCRDirectImageStore`）：
/// 按图片内容缓存已解码的 CGImage，避免「识别 → 重新识别」时重复解码同一份数据。
public final class ScreenshotOCRDirectImageStore {
    public static let shared = ScreenshotOCRDirectImageStore()

    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    /// NSData 按内容做相等/哈希，天然适合做内容键
    private let cache = NSCache<NSData, Box>()

    private init() { cache.countLimit = 12 }

    /// 取（必要时解码并缓存）图片
    public func image(for data: Data) -> CGImage? {
        let key = data as NSData
        if let box = cache.object(forKey: key) { return box.image }
        guard let image = ImageProcessor.cgImage(from: data) else { return nil }
        cache.setObject(Box(image), forKey: key)
        return image
    }
}

// MARK: - OCR 服务（本机 Vision 直连通道）

/// OCR 双通道中的「直连」通道：直接在本进程用 Vision 的 VNRecognizeTextRequest 识别，
/// 离线、低延迟，对应原作 ScreenshotOCRDirectVisionClient。
///
/// 与原作差异：原作另有 Worker 子进程通道（ScreenshotOCRWorkerClient）用于兼容/后台场景，
/// 重建版只保留直连通道（本机 Vision 在 macOS 13+ 已足够稳定，Worker 通道曾是崩溃点）。
public final class OCRService: OCRServiceProtocol {

    public static let shared = OCRService()

    private init() {}

    // MARK: OCRServiceProtocol

    /// 返回识别出的整段文本（每段一行）
    public func recognizeText(imageData: Data) async throws -> String {
        let observations = try await recognizeObservations(imageData: imageData)
        return observations.map { $0.text }.joined(separator: "\n")
    }

    /// 返回带归一化 boundingBox 的片段（左下原点，供取词 / 翻译定位用）
    public func recognizeObservations(imageData: Data) async throws -> [OCRTextObservation] {
        // 经图片缓存解码，重复识别同一张图时省一次解码
        guard let image = ScreenshotOCRDirectImageStore.shared.image(for: imageData) else {
            throw CaptureError.invalidImage
        }
        return try await recognizeObservations(image: image)
    }

    // MARK: CGImage 入口（模块内使用）

    public func recognizeText(image: CGImage) async throws -> String {
        try await recognizeObservations(image: image).map { $0.text }.joined(separator: "\n")
    }

    public func recognizeObservations(image: CGImage) async throws -> [OCRTextObservation] {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let results = request.results, !results.isEmpty else { return [] }
        return results.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRTextObservation(text: candidate.string, boundingBox: observation.boundingBox)
        }
    }

    // MARK: 请求构造

    private func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // 自动语言纠正（英文单词纠错）
        request.usesLanguageCorrection = true
        // revision3 在中英混排上准确率更高（macOS 12+）
        if #available(macOS 12.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }
        request.recognitionLanguages = Self.currentLanguages
        return request
    }

    /// 识别语言：读 Preferences.ocrLanguages（默认 简体中文 + 英文）
    public static var currentLanguages: [String] {
        let langs = Preferences.shared.value(Preferences.Keys.ocrLanguages, default: ["zh-Hans", "en-US"])
        return langs.isEmpty ? ["zh-Hans", "en-US"] : langs
    }

    /// 写入识别语言
    public static func setLanguages(_ languages: [String]) {
        Preferences.shared.set(Preferences.Keys.ocrLanguages, languages)
    }
}
