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
    /// 生成指定**点数**的二维码位图（内部按 3× 超采样后交给 SwiftUI 缩放）
    static func make(from string: String, size: CGFloat) -> NSImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scale = size / max(1, output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}

/// 二维码视图：**恒白底**——暗色模式下二维码若跟着反色，很多手机扫不出来。
struct QRCodeView: View {
    let text: String
    var size: CGFloat = 76

    var body: some View {
        Group {
            if let image = QRCodeImage.make(from: text, size: size * 3) {
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
