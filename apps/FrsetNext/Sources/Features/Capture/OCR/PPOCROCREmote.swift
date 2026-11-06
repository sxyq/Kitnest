import AppKit
import CoreGraphics
import Foundation

// MARK: - 独立进程里的本地 PP-OCR（v144）
//
// 为什么从「进程内」改成「子进程」：
//   ONNX Runtime 不支持卸载。实测在主进程里 `ReleaseSession` + `dlclose` 之后，
//   dyld 镜像列表里 libonnxruntime **仍然存在**（_dyld_image_count 可查），
//   RSS 从 100.9 MB 一点不降；连 `malloc_zone_pressure_relief` 都救不回来。
//   结论：进程内「识别完就关闭」是做不到的，只有**进程退出**才能把运行时/模型/
//   内存池整块还给系统。
//
// 于是：主 App 用 Apple Vision 定位文本行 → 把原图 + 行框交给一次性的
//   FrsetOCRHelper 进程 → 它加载模型、逐行识别、打印结果、立即退出。
//   空闲时本地 OCR 的常驻内存为 0（这正是用户要的语义）。
//
// 代价：每次识别多一次进程启动 + 模型加载（实测 ~110-150 ms），
//   相对整次 OCR（几百毫秒到 1 秒）可以接受；换来的是空闲零占用。
enum PPOCROCREmote {

    struct Result {
        let text: String
        let confidence: Double
    }

    /// helper 可执行文件位置（与主 App 同包，构建时一起签名）
    private static var helperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/FrsetOCRHelper")
    }

    private static var libraryPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/libonnxruntime.dylib").path
    }

    private static var modelPath: String {
        Bundle.main.resourceURL?.appendingPathComponent("OCR/ppocr_rec.onnx").path ?? ""
    }

    private static var dictionaryPath: String {
        Bundle.main.resourceURL?.appendingPathComponent("OCR/ppocr_keys_v1.txt").path ?? ""
    }

    /// 运行时是否可用（只查文件，不加载任何东西）
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: helperURL.path)
            && FileManager.default.fileExists(atPath: modelPath)
            && FileManager.default.fileExists(atPath: libraryPath)
    }

    /// 一次请求识别多行（同一张图）。返回顺序与 boxes 一致；失败的位置为 nil。
    /// 整个子进程只起一次，跑完即退出——内存随之全部归还。
    static func recognize(image: CGImage, boxes: [CGRect]) -> [Result?] {
        guard !boxes.isEmpty, isAvailable else { return [] }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("frset-ocr-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)) != nil else {
            Log.warn("Capture", "本地 OCR：创建临时目录失败")
            return []
        }
        defer { try? fm.removeItem(at: workDir) }

        let rawURL = workDir.appendingPathComponent("frame.raw")
        let boxURL = workDir.appendingPathComponent("boxes.json")
        guard writeRaw(image, to: rawURL) else {
            Log.warn("Capture", "本地 OCR：原图编码失败")
            return []
        }
        let boxPayload: [String: Any] = [
            "boxes": boxes.map { [Double($0.origin.x), Double($0.origin.y),
                                  Double($0.width), Double($0.height)] }
        ]
        guard let boxData = try? JSONSerialization.data(withJSONObject: boxPayload) else { return [] }
        guard (try? boxData.write(to: boxURL)) != nil else { return [] }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [libraryPath, modelPath, dictionaryPath, rawURL.path, boxURL.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            Log.warn("Capture", "本地 OCR：子进程启动失败 \(error.localizedDescription)")
            return []
        }

        // 后台读管道（子进程输出很小，但别在主线程阻塞；同时留超时兜底）
        var output = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            output = outPipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            Log.warn("Capture", "本地 OCR：子进程超时（10s），已终止")
            return []
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, !output.isEmpty else {
            let err = (try? errPipe.fileHandleForReading.readDataToEndOfFile()) ?? Data()
            let message = String(data: err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Log.warn("Capture", "本地 OCR：子进程失败（status \(process.terminationStatus)）\(message)")
            return []
        }

        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let items = object["results"] as? [Any] else {
            Log.warn("Capture", "本地 OCR：结果解析失败")
            return []
        }
        return items.map { item in
            guard let dict = item as? [String: Any],
                  let text = dict["text"] as? String, !text.isEmpty else { return nil }
            let confidence = (dict["confidence"] as? Double) ?? 0
            return Result(text: text, confidence: confidence)
        }
    }

    /// 自检（排障深链用）：起一个子进程、识别一行小程序生成的文字，验证整条链路
    @discardableResult
    // MARK: - 像素编码（BGRA，紧凑；比 PNG 编码快一个量级）

    private static func writeRaw(_ image: CGImage, to url: URL) -> Bool {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return false }
        var data = Data("FOCR1".utf8)
        var widthLE = UInt32(w).littleEndian
        var heightLE = UInt32(h).littleEndian
        withUnsafeBytes(of: &widthLE) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &heightLE) { data.append(contentsOf: $0) }
        data.append(contentsOf: pixels)
        return (try? data.write(to: url)) != nil
    }
}
