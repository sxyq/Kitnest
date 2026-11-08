import AppKit
import CoreGraphics
import Foundation

// MARK: - 固定比例（v264 · 1Capture「自定义固定比例」对齐）
//
// 1Capture 的设置里有「固定比例（可增删多组）」：做素材图 / 封面 / 头像时，
// 靠鼠标拖出一个精确的 16:9 几乎不可能。这里把它落成三件事：
//   ① 一份可增删的比例表（预置 6 组 + 用户自定义）；
//   ② 框选时按选中的比例锁死（拖拽方向决定从哪个角生长）；
//   ③ 临时按住 ⇧ 变正方形（不改变设置，松手即恢复）。
//
// 所有比例都存成「宽:高」两个整数（如 16:9）。屏幕比例、方形、竖版都在表里，
// 不引入浮点，避免 16:9 存成 1.7777778 后比较时抖动。

public struct CaptureAspectRatio: Identifiable, Codable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var width: Int
    public var height: Int
    public var builtin: Bool

    public init(id: String = UUID().uuidString, name: String,
                width: Int, height: Int, builtin: Bool = false) {
        self.id = id
        self.name = name
        self.width = max(1, width)
        self.height = max(1, height)
        self.builtin = builtin
    }

    /// 比例值（宽 / 高）
    public var ratio: CGFloat { CGFloat(width) / CGFloat(height) }

    /// 显示用：16:9
    public var label: String { "\(width):\(height)" }

    /// 预置比例：方形 / 经典相机 / 宽屏 / 竖版
    public static let builtins: [CaptureAspectRatio] = [
        CaptureAspectRatio(id: "builtin.1x1",  name: "方形", width: 1, height: 1, builtin: true),
        CaptureAspectRatio(id: "builtin.4x3",  name: "4:3",  width: 4, height: 3, builtin: true),
        CaptureAspectRatio(id: "builtin.3x2",  name: "3:2",  width: 3, height: 2, builtin: true),
        CaptureAspectRatio(id: "builtin.16x9", name: "16:9", width: 16, height: 9, builtin: true),
        CaptureAspectRatio(id: "builtin.3x4",  name: "3:4 竖", width: 3, height: 4, builtin: true),
        CaptureAspectRatio(id: "builtin.9x16", name: "9:16 竖", width: 9, height: 16, builtin: true),
    ]

    /// 解析用户输入（"16:9" / "16x9" / "1600×900"），返回最简比
    public static func parse(_ raw: String) -> (Int, Int)? {
        let normalized = raw
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "x", with: ":")
            .replacingOccurrences(of: "X", with: ":")
            .replacingOccurrences(of: "×", with: ":")
            .replacingOccurrences(of: "*", with: ":")
            .replacingOccurrences(of: "/", with: ":")
        let parts = normalized.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
        let g = gcd(w, h)
        return (w / g, h / g)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(1, x)
    }
}

// MARK: - 比例存储

public enum CaptureRatioStore {

    static let keyItems = "capture.aspectRatios"
    static let keySelected = "capture.aspectRatio.selected"

    /// 全部比例（预置在前，自定义按加入顺序）
    public static var all: [CaptureAspectRatio] {
        let custom = customItems
        return CaptureAspectRatio.builtins + custom
    }

    public static var customItems: [CaptureAspectRatio] {
        guard let data = UserDefaults.standard.data(forKey: keyItems),
              let list = try? JSONDecoder().decode([CaptureAspectRatio].self, from: data) else {
            return []
        }
        return list
    }

    /// 当前选中的比例 id（空 / 不存在 = 自由框选）
    public static var selectedID: String {
        get { Preferences.shared.value(keySelected, default: "") }
        set { Preferences.shared.set(keySelected, newValue) }
    }

    /// 当前生效的比例（nil = 自由）
    public static var selected: CaptureAspectRatio? {
        let id = selectedID
        guard !id.isEmpty else { return nil }
        return all.first { $0.id == id }
    }

    public static func add(name: String, width: Int, height: Int) -> CaptureAspectRatio? {
        guard width > 0, height > 0 else { return nil }
        let g = greatestCommonDivisor(width, height)
        var list = customItems
        // 同比例已存在 → 直接复用（避免表里三条 16:9）
        if let existing = all.first(where: { $0.width == width / g && $0.height == height / g }) {
            return existing
        }
        let item = CaptureAspectRatio(name: name.isEmpty ? "\(width / g):\(height / g)" : name,
                                      width: width / g, height: height / g)
        list.append(item)
        save(list)
        return item
    }

    public static func remove(id: String) {
        guard let item = customItems.first(where: { $0.id == id }) else { return }
        save(customItems.filter { $0.id != item.id })
        if selectedID == id { selectedID = "" }
    }

    private static func save(_ list: [CaptureAspectRatio]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: keyItems)
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(1, x)
    }

    // MARK: 拖拽约束

    /// 把「起点 → 当前点」约束成指定比例，返回修正后的当前点。
    ///
    /// 规则与系统截图一致：**起点是锚点**，宽高取拖拽方向上的较大者，
    /// 方向（四个象限）保持不变。这样从左上往右下拖和从右下往左上拖都不会跳。
    public static func constrain(from start: CGPoint, to current: CGPoint,
                                 ratio: CGFloat, bounds: CGRect) -> CGPoint {
        guard ratio > 0 else { return current }
        let dx = current.x - start.x
        let dy = current.y - start.y
        let sx: CGFloat = dx >= 0 ? 1 : -1
        let sy: CGFloat = dy >= 0 ? 1 : -1

        // 以「投影更大」的一边为准，另一边按比例推算
        var w = abs(dx)
        var h = abs(dy)
        if w / max(h, 0.0001) > ratio {
            h = w / ratio
        } else {
            w = h * ratio
        }
        // 防止推到屏幕外：按可用空间收缩（保持比例）
        let maxW = sx > 0 ? bounds.maxX - start.x : start.x - bounds.minX
        let maxH = sy > 0 ? bounds.maxY - start.y : start.y - bounds.minY
        if w > maxW { w = maxW; h = w / ratio }
        if h > maxH { h = maxH; w = h * ratio }

        return CGPoint(x: start.x + sx * w, y: start.y + sy * h)
    }

    /// 按住 ⇧ 时的正方形（与选中比例的优先级：比例 > ⇧；两者都没有 = 自由）
    public static func square(from start: CGPoint, to current: CGPoint) -> CGPoint {
        let dx = current.x - start.x
        let dy = current.y - start.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx >= 0 ? side : -side),
                       y: start.y + (dy >= 0 ? side : -side))
    }
}
