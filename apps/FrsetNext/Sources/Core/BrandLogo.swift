import AppKit

// MARK: - 品牌 logo 资源（2026-10-18）
//
// 来源：官方原版 FrsetClean.app 的 Assets.car（CUICatalog 私有 API 导出，
// 48×48 / 52×52 PNG），存放于 Resources/BrandLogos/。
// 用途：搜索源列表与搜索栏显示真实品牌 logo（官方原版观感），
//       无对应资源时调用方回退 SF Symbol。

enum BrandLogo {

    private static var cache: [String: NSImage] = [:]

    /// 按资源名取品牌 logo（如 "icon_google"）；缺失返回 nil
    static func image(_ name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png",
                                        subdirectory: "BrandLogos"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
}
