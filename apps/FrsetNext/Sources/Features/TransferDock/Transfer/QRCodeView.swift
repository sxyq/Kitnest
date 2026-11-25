import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - 二维码
//
// 用于「局域网直传」：把 http://<局域网 IP>:<port>/s/<token>/ 编成二维码，
// 手机相机一扫就在浏览器打开直传页——不需要装 App，也不需要云。
//
// 参考开源做法（不引依赖，只借形态）：
//   · qrcp（CLI）：起本地 HTTP 服务 + 打印二维码，手机扫码即可下载/上传；
//   · LocalSend（Flutter）：同一网段直连，但两端都要装 App；
//   · PairDrop / Snapdrop：浏览器 WebRTC，需要信令与公网页面。
// 手机端要「零安装」，最稳的是 qrcp 这条路，所以这里就内置一个 HTTP 服务。

enum QRCodeImage {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    /// 2026-11-26 修复（二轮 low）：QRCodeView 每次 body 求值都会重算位图
    /// （connectURL/statusText 抖动也算重算）。按「文本 + 目标尺寸」缓存，
    /// NSCache 自动按内存压力回收，id 失效无需关心。
    private static let cache = NSCache<NSString, NSImage>()

    /// 生成指定**点数**的二维码位图（内部按整数倍超采样后交给 SwiftUI 缩放）
    static func make(from string: String, size: CGFloat) -> NSImage? {
        guard !string.isEmpty else { return nil }
        let key = "\(Int(size.rounded()))|\(string)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // 2026-11-26 修复（二轮 low）：原来 scale = size / 模块数 不是整数倍，
        // CGAffineTransform 放大时模块边界被抗锯齿，长 URL 在小尺寸下模块宽高不均，
        // 部分手机/微信扫不出。改为整数倍（每模块正好 N 个像素）。
        // 像素目标按 2× 屏（Retina）折算，再除回点数，SwiftUI 按 size 点摆放时近似 1:1。
        let modules = max(1, output.extent.width.rounded())
        let targetPixels = max(size, 1) * 2
        let scale = max(1, (targetPixels / modules).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: scaled.extent.width / 2, height: scaled.extent.height / 2))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 二维码视图：**恒白底**——暗色模式下二维码若跟着反色，很多手机扫不出来。
struct QRCodeView: View {
    let text: String
    var size: CGFloat = 76

    var body: some View {
        Group {
            // 2026-11-26：不再传 size*3 超采样（3 倍后再缩回会被抗锯齿），
            // make 内部按整数倍模块 + 2× 屏像素生成。
            if let image = QRCodeImage.make(from: text, size: size) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color.white))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
        }
    }
}
