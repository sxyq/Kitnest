import CoreGraphics
import Foundation

// MARK: - 文字识别 Refiner 层（v147）
//
// 和翻译 Provider 同一个思路：把「识别」拆成可替换的环节。
// 当前两个实现：
//   · system —— 只用 Apple Vision（零依赖、最快，中文小字容易错）
//   · local  —— Vision 定位 + 本地 PP-OCR 认字（子进程，中文更准，空闲零占用）
//
// 以后接云 OCR（百度/腾讯）时，只需再实现一个 `OCRRefiner` 并注册，不动调用方。

public protocol OCRRefiner: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var summary: String { get }
    var isAvailable: Bool { get }
    func refine(_ observations: [OCRTextObservation], image: CGImage) -> [OCRTextObservation]
}

/// 仅系统识别：不做任何加工
public final class SystemOCRRefiner: OCRRefiner {
    public let id = "system"
    public let displayName = "系统识别（Apple Vision）"
    public let summary = "零依赖、最快；中文小字/中英混排偶有错字"
    public var isAvailable: Bool { true }

    public init() {}

    public func refine(_ observations: [OCRTextObservation], image: CGImage) -> [OCRTextObservation] {
        observations
    }
}

/// 系统定位 + 本地 PP-OCR 认字
public final class LocalOCRRefiner: OCRRefiner {
    public let id = "local"
    public var displayName: String { "系统定位 + 本地模型认字" }
    public var summary: String { "中文/中英混排更准；识别时起一次性子进程，跑完即退（空闲 0 占用）" }
    public var isAvailable: Bool { PPOCROCREmote.isAvailable }

    public init() {}

    public func refine(_ observations: [OCRTextObservation], image: CGImage) -> [OCRTextObservation] {
        OCRService.refineWithPPOCR(observations, image: image)
    }
}

// MARK: - 注册表

public final class OCRRefinerRegistry {
    public static let shared = OCRRefinerRegistry()

    private let refiners: [OCRRefiner]

    public init(refiners: [OCRRefiner] = [SystemOCRRefiner(), LocalOCRRefiner()]) {
        self.refiners = refiners
    }

    public var all: [OCRRefiner] { refiners }

    public func refiner(id: String) -> OCRRefiner? { refiners.first { $0.id == id } }

    /// `auto` → 本地可用就用本地（更准），否则纯系统；指定 id → 只用它
    public func resolve(preference: String) -> OCRRefiner {
        if preference == "auto" {
            return refiners.first { $0.id == "local" && $0.isAvailable }
                ?? refiners.first { $0.id == "system" }
                ?? SystemOCRRefiner()
        }
        return refiner(id: preference) ?? SystemOCRRefiner()
    }

    /// 当前生效的 Refiner
    public var active: OCRRefiner {
        resolve(preference: AISettings.ocrRefinerPreference)
    }
}
