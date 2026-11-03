import AppKit
import Vision

// MARK: - 二维码识别（v117；原版能力移植）
//
// 证据：原版二进制 `__swift5_reflstr` 中出现 `translat | ocrOnly | qrCode` 三连
// （截图动作枚举），说明原版截图链支持「识别图中二维码」。
// 本文件按同语义移植：Vision `VNDetectBarcodesRequest`（QR / EAN / Code128 全支持），
// 结果先复制到剪贴板，并按内容类型给「打开链接 / 复制 / 好」。

enum QRCodeRecognizer {

    /// 识别图片中的所有条码（QR 优先）
    static func recognize(_ image: CGImage, completion: @escaping ([String]) -> Void) {
        let request = VNDetectBarcodesRequest { req, _ in
            let payloads = (req.results as? [VNBarcodeObservation] ?? [])
                .compactMap { $0.payloadStringValue }
                .filter { !$0.isEmpty }
            DispatchQueue.main.async { completion(Array(NSOrderedSet(array: payloads)) as? [String] ?? payloads) }
        }
        // 优先二维码，再退到通用条码
        request.symbologies = [.qr, .aztec, .ean13, .ean8, .code128, .code39, .pdf417, .dataMatrix]
        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        }
    }

    /// 截图后「识码」：识别 → 自动复制 → 弹结果（链接可一键打开）
    static func run(image: CGImage) {
        recognize(image) { payloads in
            guard !payloads.isEmpty else {
                Toast.show("未识别到二维码/条码", icon: "qrcode.viewfinder", isWarning: true)
                return
            }
            let joined = payloads.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(joined, forType: .string)
            Toast.show(payloads.count == 1 ? "已识别并复制" : "已识别 \(payloads.count) 条并复制",
                       icon: "qrcode.viewfinder")

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = payloads.count == 1 ? "识别到内容（已复制）" : "识别到 \(payloads.count) 条（已复制）"
            alert.informativeText = String(joined.prefix(600))
            let firstURL = payloads.first { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }
            if firstURL != nil { alert.addButton(withTitle: "打开链接") }
            alert.addButton(withTitle: "好")
            let resp = alert.runModal()
            if firstURL != nil, resp == .alertFirstButtonReturn, let s = firstURL, let url = URL(string: s) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
