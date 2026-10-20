import AppKit
import Foundation

// MARK: - 网盘链接识别（LinkSwift 接入 · Layer 1）
//
// 域名表与分享页规则提取自 LinkSwift v1.1.3 的 @match 声明（AGPL-3.0 上游项目）：
//   https://github.com/hmjz100/LinkSwift
// 本文件只做识别与展示，不包含任何解析逻辑（解析在 Layer 2：WKWebView + 注入脚本）。

/// 支持的网盘服务商（枚举远端数据，禁止在 UI 层硬编码字符串）
public enum CloudDriveProvider: String, CaseIterable, Sendable {
    case baidu, aliyun, mobile139, tianyi189, xunlei, quark, uc, pan123

    public var displayName: String {
        switch self {
        case .baidu: return "百度网盘"
        case .aliyun: return "阿里云盘"
        case .mobile139: return "移动云盘"
        case .tianyi189: return "天翼云盘"
        case .xunlei: return "迅雷云盘"
        case .quark: return "夸克网盘"
        case .uc: return "UC 网盘"
        case .pan123: return "123 云盘"
        }
    }

    /// 品牌色（图标底色/文字色）
    public var tint: NSColor {
        switch self {
        case .baidu: return NSColor(srgbRed: 0.18, green: 0.45, blue: 0.94, alpha: 1)
        case .aliyun: return NSColor(srgbRed: 0.98, green: 0.55, blue: 0.10, alpha: 1)
        case .mobile139: return NSColor(srgbRed: 0.13, green: 0.62, blue: 0.55, alpha: 1)
        case .tianyi189: return NSColor(srgbRed: 0.13, green: 0.42, blue: 0.80, alpha: 1)
        case .xunlei: return NSColor(srgbRed: 0.15, green: 0.62, blue: 0.96, alpha: 1)
        case .quark: return NSColor(srgbRed: 0.36, green: 0.42, blue: 0.95, alpha: 1)
        case .uc: return NSColor(srgbRed: 0.95, green: 0.35, blue: 0.20, alpha: 1)
        case .pan123: return NSColor(srgbRed: 0.20, green: 0.60, blue: 0.90, alpha: 1)
        }
    }

    /// SF Symbol（无品牌图标时用）
    public var symbolName: String { "externaldrive.fill.badge.icloud" }
}

/// 一条识别出的网盘链接
public struct CloudDriveLink: Equatable, Sendable {
    public let url: URL
    public let provider: CloudDriveProvider
    /// 是否为分享页（分享页才可直接解析；个人主页链接只提示）
    public let isSharePage: Bool

    public init(url: URL, provider: CloudDriveProvider, isSharePage: Bool) {
        self.url = url
        self.provider = provider
        self.isSharePage = isSharePage
    }

    public var host: String { url.host ?? "" }
}

public enum CloudDriveLinkDetector {

    /// 精确主机 → 服务商（根域名匹配）
    private static let exactHosts: [String: CloudDriveProvider] = [
        "pan.baidu.com": .baidu,
        "yun.baidu.com": .baidu,
        "www.aliyundrive.com": .aliyun,
        "aliyundrive.com": .aliyun,
        "www.alipan.com": .aliyun,
        "alipan.com": .aliyun,
        "yun.139.com": .mobile139,
        "caiyun.139.com": .mobile139,
        "cloud.189.cn": .tianyi189,
        "pan.xunlei.com": .xunlei,
        "pan.quark.cn": .quark,
        "drive.uc.cn": .uc,
    ]

    /// 通配主机（123 云盘多域名）
    private static let wildcardSuffixes: [(String, CloudDriveProvider)] = [
        (".123pan.com", .pan123),
        (".123pan.cn", .pan123),
        (".123684.com", .pan123),
        (".123865.com", .pan123),
        (".123952.com", .pan123),
        (".123912.com", .pan123),
        ("123pan.com", .pan123),
        ("123pan.cn", .pan123),
        ("123684.com", .pan123),
        ("123865.com", .pan123),
        ("123952.com", .pan123),
        ("123912.com", .pan123),
    ]

    /// 域名 → 服务商
    public static func provider(forHost host: String) -> CloudDriveProvider? {
        let h = host.lowercased()
        if let p = exactHosts[h] { return p }
        for (suffix, p) in wildcardSuffixes where h == suffix || h.hasSuffix(suffix) {
            return p
        }
        return nil
    }

    /// 分享页判定（按各家实际路径规则）：
    ///   通用：/s/、/share/、/shareweb/
    ///   天翼 189：/t/<id>
    ///   移动 139：/w/、/m/（caiyun 移动云盘）
    ///   123 云盘：<uid>.share.123pan.cn/123pan/<id>?notoken=1（用户实证 2026-10-20
    ///   「复制了 123 下载链接没弹下载助手」——路径是 /123pan/<id> 而非 /s/，
    ///   旧判定误落「非分享页」，解析/下载助手全链路降级）
    public static func isSharePage(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let host = url.host?.lowercased() ?? ""
        if path.contains("/share") || path.contains("/s/") { return true }
        if host.contains("189.cn"), path.hasPrefix("/t/") { return true }
        if host.contains("139.com"), path.contains("/w/") || path.contains("/m/") { return true }
        // 123 云盘：/123pan/<id> 直达分享；*.share.* 子域本身就是分享域
        if provider(forHost: host) == .pan123 {
            if path.hasPrefix("/123pan/") || path.contains("/share") { return true }
            if host.contains("share.") { return true }
        }
        return false
    }

    /// 裸域名被 NSDataDetector 识别时会补成 http://，统一升到 https（网盘分享页都强制 https）
    private static func normalized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              let host = components.host,
              provider(forHost: host) != nil else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    /// v101 性能审计：探测器/正则静态化（此前每条目构造一次）
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let bareDomainRegex = try? NSRegularExpression(pattern: #"(?i)((?:pan\.baidu|yun\.baidu|www\.aliyundrive|aliyundrive|www\.alipan|alipan|yun\.139|caiyun\.139|cloud\.189|pan\.xunlei|pan\.quark|drive\.uc|(?:[a-z0-9-]+\.)?123(?:pan|684|865|952|912)\.(?:com|cn))[^\s"'<>）)]*)"#)

    /// 从一段文本中提取第一条网盘链接（含无 scheme 的裸域名）
    public static func detect(in text: String) -> CloudDriveLink? {
        guard !text.isEmpty else { return nil }
        // 1) 标准 URL（NSDataDetector 兜底复杂文本）
        if let detector = Self.linkDetector {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                guard let url = match.url, let host = url.host, let p = provider(forHost: host) else { continue }
                let fixed = normalized(url)
                return CloudDriveLink(url: fixed, provider: p, isSharePage: isSharePage(fixed))
            }
        }
        // 2) 裸域名（如 pan.quark.cn/s/xxx 复制时丢 scheme）
        let pattern = #"(?i)((?:pan\.baidu|yun\.baidu|www\.aliyundrive|aliyundrive|www\.alipan|alipan|yun\.139|caiyun\.139|cloud\.189|pan\.xunlei|pan\.quark|drive\.uc|(?:[a-z0-9-]+\.)?123(?:pan|684|865|952|912)\.(?:com|cn))[^\s"'<>）)]*)"#
        if let re = Self.bareDomainRegex {
            let range = NSRange(text.startIndex..., in: text)
            if let m = re.firstMatch(in: text, options: [], range: range),
               let r = Range(m.range, in: text) {
                var raw = String(text[r])
                if !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
                if let url = URL(string: raw), let host = url.host, let p = provider(forHost: host) {
                    return CloudDriveLink(url: url, provider: p, isSharePage: isSharePage(url))
                }
            }
        }
        return nil
    }

    /// 从剪贴板条目列表挑出最近一条网盘链接（首页条数据源）
    public static func recentLink(in items: [ClipboardItem], scanLimit: Int = 40) -> CloudDriveLink? {
        for item in items.prefix(scanLimit) {
            guard item.type == .text || item.type == .url || item.type == .file || item.type == .richtext else { continue }
            if let link = detect(in: item.content ?? item.title ?? "") {
                return link
            }
        }
        return nil
    }
}
