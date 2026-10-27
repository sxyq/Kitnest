import Foundation
import CoreGraphics

// FrsetOCRHelper —— 本地 PP-OCR 的**一次性识别进程**。
//
// 为什么要有这个进程：
//   ONNX Runtime 不支持卸载。实测在主进程里 `ReleaseSession` + `dlclose` 之后，
//   dyld 镜像列表里它**仍然存在**，RSS 从 100.9 MB 一点不降；`malloc_zone_pressure_relief`
//   也救不回来。也就是说「识别完就把内存关掉」在进程内做不到——只有进程退出，
//   运行时/模型/内存池才会被系统整块回收。
//
// 分工：主 App（Apple Vision）负责**定位文本行**，本进程负责**认字**。
// 每次识别现起一个、跑完即退，空闲时占用为 0。
//
// 调用：FrsetOCRHelper <lib> <model> <dict> <raw> <boxes.json>
//   raw       ："FOCR1" + UInt32(width) + UInt32(height) + BGRA 像素（行宽 = width*4）
//   boxes.json：{"boxes":[[x,y,w,h], ...]}，坐标为图像像素、**左上原点**（CGImage 裁剪口径）
// 输出：stdout 一行 JSON {"results":[{"text":"..","confidence":0.93} | null, ...]}

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 6 else {
    fail(2, "usage: FrsetOCRHelper <lib> <model> <dict> <raw> <boxes.json>")
}
let libPath = args[1]
let modelPath = args[2]
let dictPath = args[3]
let rawPath = args[4]
let boxesPath = args[5]

PPOCROCR.shared.libraryPath = libPath
PPOCROCR.shared.modelPath = modelPath
PPOCROCR.shared.dictionaryPath = dictPath

// MARK: - 读取原始像素

guard let raw = FileManager.default.contents(atPath: rawPath) else {
    fail(3, "缺少像素文件：\(rawPath)")
}
guard raw.count > 13, String(data: raw.prefix(5), encoding: .ascii) == "FOCR1" else {
    fail(3, "像素文件头无效（期望 FOCR1）")
}
func u32(_ offset: Int) -> Int {
    let b = [UInt8](raw[offset..<(offset + 4)])
    return Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16) | (Int(b[3]) << 24)
}
let width = u32(5)
let height = u32(9)
guard width > 0, height > 0, width <= 20000, height <= 20000 else {
    fail(3, "尺寸非法：\(width)x\(height)")
}
let pixelStart = 13
let expected = width * height * 4
guard raw.count >= pixelStart + expected else {
    fail(3, "像素数据不足：期望 \(expected) 字节，实得 \(raw.count - pixelStart)")
}

let pixels = raw.subdata(in: pixelStart..<(pixelStart + expected))
guard let provider = CGDataProvider(data: pixels as CFData),
      let image = CGImage(width: width, height: height,
                          bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: provider, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent) else {
    fail(4, "无法从像素重建图像")
}

// MARK: - 读取行框

struct BoxRequest: Decodable { let boxes: [[Double]] }
let boxesData = (try? Data(contentsOf: URL(fileURLWithPath: boxesPath))) ?? Data()
let boxes = (try? JSONDecoder().decode(BoxRequest.self, from: boxesData))?.boxes ?? []
guard !boxes.isEmpty else {
    // 没有行就不必加载模型（省掉这次进程的 100ms 加载）
    FileHandle.standardOutput.write(Data(#"{"results":[]}"#.utf8))
    exit(0)
}

// MARK: - 逐行识别

let bounds = CGRect(x: 0, y: 0, width: width, height: height)
var results: [Any] = []
results.reserveCapacity(boxes.count)
var recognised = 0
for box in boxes {
    guard box.count >= 4 else {
        results.append(NSNull())
        continue
    }
    let rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        .integral
        .intersection(bounds)
    guard rect.width >= 4, rect.height >= 4,
          let crop = image.cropping(to: rect),
          let result = PPOCROCR.shared.recognize(line: crop) else {
        results.append(NSNull())
        continue
    }
    recognised += 1
    results.append(["text": result.text, "confidence": result.confidence])
}

let payload: [String: Any] = ["results": results]
guard let out = try? JSONSerialization.data(withJSONObject: payload) else {
    fail(5, "结果序列化失败")
}
FileHandle.standardOutput.write(out)
FileHandle.standardError.write(Data(" recognised \(recognised)/\(boxes.count)\n".utf8))
exit(0)
