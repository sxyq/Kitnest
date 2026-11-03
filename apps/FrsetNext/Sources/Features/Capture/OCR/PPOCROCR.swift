import AppKit
import CoreGraphics
import Foundation

// MARK: - 本地 PP-OCR 识别（离线中文 OCR）
//
// 定位：**Apple Vision 负责"文字在哪"（文本行检测），PP-OCR 负责"这是什么"（逐行识别）**。
// 为什么要拼两个引擎（v142）：
//   · 纯 Vision：零依赖、离线、快，但中文小字/中英混排会错（本机基准 CER 1.8%，
//     9pt 混排用例 7.1%——错字集中在形近字与标点）；
//   · 纯 PP-OCR：中文更强，但要自己实现 DB 文本检测后处理（连通域 + 轮廓 + unclip），
//     工程量大且易错；
//   · 混合：用 Vision 的检测框（它很准），把每行裁图交给 PP-OCRv4 mobile rec，
//     **只需 10MB 模型 + CTC 解码**，绕开最难的检测后处理。
//
// 模型与运行时（随 App 打包，装好即用，不需要 Key、不联网）：
//   · Resources/OCR/ppocr_rec.onnx  （PP-OCRv4 mobile rec，10MB，中英数字标点）
//   · Resources/OCR/ppocr_keys_v1.txt（PaddleOCR 字典，6623 字）
//   · Vendor/ocr/libonnxruntime.dylib（ONNX Runtime 1.31，运行时 dlopen 加载）
//
// 降级策略：模型缺失 / 运行时加载失败 / 推理异常 → 全部回退 Apple Vision（功能不残）。

public final class PPOCROCR {

    public static let shared = PPOCROCR()

    /// 识别结果（文本 + 置信度）
    public struct Result {
        public let text: String
        public let confidence: Double
    }

    /// 模型输入高度（PaddleOCR rec 标准 48）
    private static let inputHeight = 48
    /// 模型输入宽度上限（PaddleOCR rec 训练用 320；实测**按行原比例**铺到 960
    /// 明显更准——320 会把长行压扁，掉字：「隐私与安全性」→「隐与安全性」）
    private static let maxInputWidth = 960

    private var session: UnsafeMutableRawPointer?
    private var dictionary: [String] = []
    private var loadError: String?
    private let lock = NSLock()

    /// 资源目录（可注入，便于离线测试用外部路径）
    public var libraryPath: String?
    public var modelPath: String?
    public var dictionaryPath: String?

    private init() {}

    // MARK: - 可用性

    /// 是否具备本地识别能力（模型 + 字典 + 运行时都就绪）。
    /// 注意：这里**会触发懒加载**——首次调用会 dlopen 运行库并建会话（约百毫秒级，
    /// 之后常驻）。调用方都在 OCR 后台线程，不会卡 UI。
    public var isAvailable: Bool {
        ensureSession() != nil
    }

    /// 预热（App 启动空闲时调用，把加载成本挪出用户操作路径）
    public func prepare() {
        _ = ensureSession()
    }

    /// 不可用时的原因（供设置页/日志展示）
    public var unavailableReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return session == nil ? loadError : nil
    }

    /// 懒加载会话（首次调用时初始化；失败记原因并保持不可用）
    private func ensureSession() -> UnsafeMutableRawPointer? {
        lock.lock()
        if let s = session { lock.unlock(); return s }
        if let err = loadError { lock.unlock(); return nil }
        lock.unlock()

        let lib = libraryPath ?? defaultLibraryPath()
        let model = modelPath ?? defaultModelPath()
        let dict = dictionaryPath ?? defaultDictionaryPath()
        guard FileManager.default.fileExists(atPath: model) else {
            lock.lock(); loadError = "缺少识别模型：\(model)"; lock.unlock()
            return nil
        }
        guard FileManager.default.fileExists(atPath: dict) else {
            lock.lock(); loadError = "缺少字典：\(dict)"; lock.unlock()
            return nil
        }
        var errBuf = [CChar](repeating: 0, count: 512)
        let handle = model.withCString { modelPathC in
            lib.withCString { libPathC in
                FSPPOCRSessionCreate(libPathC, modelPathC, &errBuf, 512)
            }
        }
        guard let handle else {
            let message = String(cString: errBuf)
            lock.lock(); loadError = message.isEmpty ? "ONNX Runtime 加载失败" : message; lock.unlock()
            Log.warn("Capture", "本地 PP-OCR 不可用：\(loadError ?? "")")
            return nil
        }
        var chars = (try? String(contentsOfFile: dict, encoding: .utf8))
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? []
        // 文件尾部带换行 → split 会多出一个空串，不去掉会让类别映射整体错一位
        while let last = chars.last, last.isEmpty { chars.removeLast() }
        lock.lock()
        session = handle
        dictionary = chars
        loadError = nil
        lock.unlock()
        Log.info("Capture", "本地 PP-OCR 已就绪：模型 \(model)（字典 \(chars.count) 字）")
        return handle
    }

    private func defaultLibraryPath() -> String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libonnxruntime.dylib").path
    }

    private func defaultModelPath() -> String {
        Bundle.main.resourceURL?.appendingPathComponent("OCR/ppocr_rec.onnx").path ?? ""
    }

    private func defaultDictionaryPath() -> String {
        Bundle.main.resourceURL?.appendingPathComponent("OCR/ppocr_keys_v1.txt").path ?? ""
    }

    // MARK: - 识别

    /// 识别一行文本（输入为该行的裁图）
    public func recognize(line image: CGImage) -> Result? {
        guard let handle = ensureSession() else { return nil }
        guard let (input, width) = Self.makeInput(from: image) else { return nil }
        var t: Int64 = 0, c: Int64 = 0
        let raw: UnsafeMutablePointer<Float>? = input.withUnsafeBufferPointer { buf in
            FSPPOCRRun(handle, buf.baseAddress, Int64(Self.inputHeight), Int64(width), &t, &c)
        }
        guard let raw, t > 0, c > 0 else { return nil }
        defer { FSPPOCRFree(raw) }
        lock.lock()
        let dict = dictionary
        lock.unlock()
        return Self.decode(raw: raw, t: Int(t), c: Int(c), dictionary: dict)
    }

    /// 批量识别（同一张图里的多行）
    public func recognize(lines images: [CGImage]) -> [Result?] {
        images.map { recognize(line: $0) }
    }

    // MARK: - 预处理

    /// 裁图 → 归一化 CHW float32（PaddleOCR rec 口径：等比缩放到高 48、宽 ≤320、
    /// 右侧补零，RGB 各通道 (x/255 - 0.5)/0.5）
    static func makeInput(from image: CGImage) -> ([Float], Int)? {
        let srcW = image.width, srcH = image.height
        guard srcW > 0, srcH > 0 else { return nil }
        // 等比缩放到高 48；宽度按行实际比例（上限 960）——动态宽度输入模型支持，
        // 长行不会被压扁（320 固定宽时实测「勾选FrsetNext」→「勾FrseNex」掉字）
        let ratio = Double(srcW) / Double(srcH)
        let resizedW = max(1, min(maxInputWidth, Int((Double(inputHeight) * ratio).rounded())))
        // 画到 RGB 缓冲（先缩放，再转 CHW）
        let bytesPerRow = resizedW * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * inputHeight)
        guard let ctx = CGContext(data: &rgba, width: resizedW, height: inputHeight,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: resizedW, height: inputHeight))
        var out = [Float](repeating: 0, count: inputHeight * resizedW * 3)
        for y in 0..<inputHeight {
            for x in 0..<resizedW {
                let i = (y * bytesPerRow + x * 4)
                let r = Float(Double(rgba[i]) / 255.0 - 0.5)
                let g = Float(Double(rgba[i + 1]) / 255.0 - 0.5)
                let b = Float(Double(rgba[i + 2]) / 255.0 - 0.5)
                let plane = inputHeight * resizedW
                out[y * resizedW + x] = r
                out[plane + y * resizedW + x] = g
                out[plane * 2 + y * resizedW + x] = b
            }
        }
        return (out, resizedW)
    }

    // MARK: - CTC 解码

    /// CTC 贪心解码：逐时间步取最大类，去重、跳过空白，算平均置信度
    static func decode(raw: UnsafeMutablePointer<Float>, t: Int, c: Int, dictionary: [String]) -> Result? {
        guard c > 1 else { return nil }
        // 字典：第 0 类是 CTC blank，其余按序；PP-OCR 最后一类是空格
        var chars = dictionary
        if chars.count + 2 == c { chars.append(" ") }
        var text = ""
        var confSum: Double = 0
        var confCount = 0
        var previous = -1
        for step in 0..<t {
            let base = step * c
            var best = 0
            var bestVal = -Float.greatestFiniteMagnitude
            var sumExp: Double = 0
            for k in 0..<c {
                let v = raw[base + k]
                if v > bestVal { bestVal = v; best = k }
                sumExp += exp(Double(v))
            }
            // 模型导出可能已带 softmax：值域 [0,1] 时直接当概率用
            let prob: Double
            if Double(bestVal) <= 1.0, Double(bestVal) >= 0 {
                prob = Double(bestVal)
            } else {
                prob = exp(Double(bestVal)) / max(sumExp, 1e-9)
            }
            if best != 0 && best != previous {
                if best - 1 < chars.count {
                    text += chars[best - 1]
                    confSum += prob
                    confCount += 1
                }
            }
            previous = best
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let confidence = confCount > 0 ? confSum / Double(confCount) : 0
        return Result(text: trimmed, confidence: confidence)
    }
}
