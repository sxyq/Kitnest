import AppKit
import CoreGraphics

// MARK: - Mermaid 流程图渲染（轻量）
//
// 预览里的 ```mermaid / ```plantuml 代码块此前只是「◇ 流程图（mermaid）」标签 + 源码，
// 等于没渲染。这里做一个够用的真渲染器：
//   · 支持 flowchart / graph（TD、TB、BT、LR、RL）
//   · 节点形状：A[矩形] B(圆角) C{菱形} D([胶囊]) E[[子程序]] F((圆))
//   · 连线：-->  ---  -.->  ==>  以及 -->|文字|
//   · 分层布局：最长路径分层 + 同层均分；节点尺寸按文字自适应
//   · 输出 NSImage（@2x），供 NSTextAttachment 嵌进富文本
//
// 不追求 mermaid.js 全语法（时序图/状态图等）——遇到不认识的语句按「节点纯文本」降级，
// 保证永不崩、永远有图。

final class MermaidRenderer {

    static let shared = MermaidRenderer()

    private enum Shape {
        case rect, rounded, diamond, capsule, subroutine, circle
    }

    private struct Node {
        var id: String
        var label: String
        var shape: Shape
    }

    private struct Edge {
        var from: String
        var to: String
        var label: String?
        var dashed: Bool
    }

    private struct LayoutNode {
        var node: Node
        var layer: Int
        var indexInLayer: Int
        var size: CGSize
        var origin: CGPoint = .zero
    }

    // MARK: 对外

    /// 渲染 mermaid 文本为图片；无法解析时返回 nil（调用方回退为代码块）
    func image(for source: String, maxWidth: CGFloat = 520) -> NSImage? {
        let graph = parse(source)
        guard !graph.nodes.isEmpty else { return nil }
        return draw(nodes: graph.nodes, edges: graph.edges,
                    direction: graph.direction, maxWidth: maxWidth)
    }

    // MARK: 解析

    private struct Graph {
        var nodes: [Node] = []
        var edges: [Edge] = []
        var direction: String = "TD"
    }

    private func parse(_ source: String) -> Graph {
        var graph = Graph()
        var nodeIndex: [String: Int] = [:]

        let rawLines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        // 头部：flowchart TD / graph LR
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("flowchart") || lower.hasPrefix("graph") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2 { graph.direction = String(parts[1]).uppercased() }
                break
            }
        }

        func ensureNode(_ id: String, label: String? = nil, shape: Shape? = nil) -> Int {
            if let idx = nodeIndex[id] {
                if let label, !label.isEmpty { graph.nodes[idx].label = label }
                if let shape { graph.nodes[idx].shape = shape }
                return idx
            }
            graph.nodes.append(Node(id: id, label: label ?? id, shape: shape ?? .rect))
            nodeIndex[id] = graph.nodes.count - 1
            return graph.nodes.count - 1
        }

        for line in rawLines {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            let lower = text.lowercased()
            if lower.hasPrefix("flowchart") || lower.hasPrefix("graph")
                || lower.hasPrefix("subgraph") || lower == "end"
                || lower.hasPrefix("%%") || lower.hasPrefix("style ")
                || lower.hasPrefix("classdef") || lower.hasPrefix("class ")
                || lower.hasPrefix("linkstyle") || lower.hasPrefix("click ") {
                continue
            }
            // 去掉行尾分号，允许一行多语句
            if text.hasSuffix(";") { text.removeLast() }
            for statement in splitStatements(text) {
                let parsed = parseStatement(statement)
                for node in parsed.nodes {
                    _ = ensureNode(node.id, label: node.label, shape: node.shape)
                }
                for edge in parsed.edges {
                    graph.edges.append(edge)
                }
            }
        }
        return graph
    }

    /// 用 ; 切分（忽略括号内的 ;）
    private func splitStatements(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for ch in text {
            if ch == "[" || ch == "(" || ch == "{" { depth += 1 }
            if ch == "]" || ch == ")" || ch == "}" { depth = max(0, depth - 1) }
            if ch == ";" && depth == 0 {
                parts.append(current); current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }

    private struct ParsedStatement {
        var nodes: [(id: String, label: String?, shape: Shape?)] = []
        var edges: [Edge] = []
    }

    /// 解析一条语句：节点定义 / 连线链。
    /// ⚠️ 这里必须是**纯函数**：早前版本把 `graph` 以 inout 传入、同时又传一个闭包去改它，
    /// 触发 Swift 独占访问冲突（Fatal access conflict），预览一打开就崩。
    private func parseStatement(_ statement: String) -> ParsedStatement {
        var result = ParsedStatement()
        let pattern = #"([A-Za-z_][A-Za-z0-9_]*)\s*(\[\[[^\]]*\]\]|\[[^\]]*\]|\(\([^\)]*\)\)|\([^\)]*\)|\{[^\}]*\})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = statement as NSString
        let matches = regex.matches(in: statement, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return result }

        var order: [String] = []
        for match in matches {
            let id = ns.substring(with: match.range(at: 1))
            var label: String?
            var shape: Shape?
            if match.range(at: 2).location != NSNotFound {
                let token = ns.substring(with: match.range(at: 2))
                let parsed = parseNodeToken(token)
                label = parsed.label
                shape = parsed.shape
            }
            result.nodes.append((id, label, shape))
            order.append(id)
        }

        for i in 0..<max(0, order.count - 1) {
            let from = order[i], to = order[i + 1]
            let between = textBetween(statement, fromID: from, toID: to)
            let dashed = between.contains("-.->") || between.contains("-.-")
            var label: String?
            if let barRegex = try? NSRegularExpression(pattern: #"\|([^\|]*)\|"#),
               let m = barRegex.firstMatch(in: between, range: NSRange(location: 0, length: (between as NSString).length)) {
                label = (between as NSString).substring(with: m.range(at: 1))
                    .trimmingCharacters(in: .whitespaces)
            }
            result.edges.append(Edge(from: from, to: to, label: label, dashed: dashed))
        }
        return result
    }

    private func parseNodeToken(_ token: String) -> (label: String?, shape: Shape?) {
        if token.hasPrefix("[[") { return (clean(token, 2, 2), .subroutine) }
        if token.hasPrefix("((") { return (clean(token, 2, 2), .circle) }
        if token.hasPrefix("([") { return (clean(token, 2, 2), .capsule) }
        if token.hasPrefix("[") { return (clean(token, 1, 1), .rect) }
        if token.hasPrefix("(") { return (clean(token, 1, 1), .rounded) }
        if token.hasPrefix("{") { return (clean(token, 1, 1), .diamond) }
        return (nil, nil)
    }

    private func clean(_ token: String, _ head: Int, _ tail: Int) -> String {
        var text = token
        if head > 0, text.count >= head { text = String(text.dropFirst(head)) }
        if tail > 0, text.count >= tail { text = String(text.dropLast(tail)) }
        return text
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 取 from 结束到 to 开始之间的片段（用于判定箭头样式与标签）
    private func textBetween(_ statement: String, fromID: String, toID: String) -> String {
        guard let fromRange = statement.range(of: fromID) else { return "" }
        let after = statement[fromRange.upperBound...]
        guard let toRange = after.range(of: toID) else { return "" }
        return String(after[..<toRange.lowerBound])
    }

    // MARK: 布局

    private func draw(nodes: [Node], edges: [Edge], direction: String, maxWidth: CGFloat) -> NSImage? {
        // 1) 分层（最长路径）
        var layerOf: [String: Int] = [:]
        for node in nodes { layerOf[node.id] = 0 }
        let maxIterations = max(1, nodes.count * 2)
        for _ in 0..<maxIterations {
            var changed = false
            for edge in edges {
                let fromLayer = layerOf[edge.from] ?? 0
                let toLayer = layerOf[edge.to] ?? 0
                if toLayer <= fromLayer {
                    layerOf[edge.to] = fromLayer + 1
                    changed = true
                }
            }
            if !changed { break }
        }

        let layerCount = (layerOf.values.max() ?? 0) + 1
        var layers: [[Node]] = Array(repeating: [], count: layerCount)
        for node in nodes {
            let layer = min(max(0, layerOf[node.id] ?? 0), layerCount - 1)
            layers[layer].append(node)
        }

        // 2) 尺寸
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        func measure(_ text: String) -> CGSize {
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let size = (text as NSString).size(withAttributes: attrs)
            return CGSize(width: max(48, ceil(size.width) + 26), height: 34)
        }

        var layouts: [[LayoutNode]] = []
        for (layerIdx, layer) in layers.enumerated() {
            var items: [LayoutNode] = []
            for (i, node) in layer.enumerated() {
                var size = measure(node.label)
                if node.shape == .diamond { size.width += 28; size.height = 44 }
                items.append(LayoutNode(node: node, layer: layerIdx, indexInLayer: i, size: size))
            }
            layouts.append(items)
        }

        // 3) 坐标
        let horizontal = direction == "LR" || direction == "RL"
        let gapMain: CGFloat = 46      // 层间距
        let gapCross: CGFloat = 26     // 同层间距
        var contentWidth: CGFloat = 0
        var contentHeight: CGFloat = 0

        if horizontal {
            var x: CGFloat = 0
            for layer in layouts {
                let layerWidth = layer.map(\.size.width).max() ?? 0
                var y: CGFloat = 0
                let totalHeight = layer.reduce(0) { $0 + $1.size.height } + gapCross * CGFloat(max(0, layer.count - 1))
                for i in layer.indices {
                    layouts[layouts.firstIndex(where: { $0.first?.layer == layer.first?.layer }) ?? 0][i].origin =
                        CGPoint(x: x + (layerWidth - layer[i].size.width) / 2, y: y)
                    y += layer[i].size.height + gapCross
                }
                contentHeight = max(contentHeight, totalHeight)
                x += layerWidth + gapMain
                contentWidth = x - gapMain
            }
        } else {
            var y: CGFloat = 0
            for layer in layouts {
                let layerHeight = layer.map(\.size.height).max() ?? 0
                let totalWidth = layer.reduce(0) { $0 + $1.size.width } + gapCross * CGFloat(max(0, layer.count - 1))
                var x: CGFloat = 0
                if let layerIdx = layer.first?.layer {
                    for i in layouts[layerIdx].indices {
                        layouts[layerIdx][i].origin =
                            CGPoint(x: x, y: y + (layerHeight - layouts[layerIdx][i].size.height) / 2)
                        x += layouts[layerIdx][i].size.width + gapCross
                    }
                }
                contentWidth = max(contentWidth, totalWidth)
                y += layerHeight + gapMain
                contentHeight = y - gapMain
            }
        }

        // 同层居中（窄层对齐到内容中线）
        if horizontal {
            for layerIdx in layouts.indices {
                for i in layouts[layerIdx].indices {
                    layouts[layerIdx][i].origin.y =
                        contentHeight - layouts[layerIdx][i].origin.y - layouts[layerIdx][i].size.height
                }
            }
        } else {
            for layerIdx in layouts.indices {
                let layerWidth = layouts[layerIdx].reduce(0) { $0 + $1.size.width }
                    + gapCross * CGFloat(max(0, layouts[layerIdx].count - 1))
                let offset = (contentWidth - layerWidth) / 2
                for i in layouts[layerIdx].indices {
                    layouts[layerIdx][i].origin.x += offset
                }
            }
            // AppKit 原点在左下：把「从上往下」的 y 翻过来，否则流程图会上下颠倒
            for layerIdx in layouts.indices {
                for i in layouts[layerIdx].indices {
                    layouts[layerIdx][i].origin.y =
                        contentHeight - layouts[layerIdx][i].origin.y - layouts[layerIdx][i].size.height
                }
            }
        }

        let margin: CGFloat = 16
        let canvasWidth = min(maxWidth, max(220, contentWidth + margin * 2))
        let canvasHeight = max(120, contentHeight + margin * 2)
        let scale: CGFloat = canvasWidth < contentWidth + margin * 2
            ? (canvasWidth - margin * 2) / max(1, contentWidth) : 1

        // 4) 绘制：用 NSImage 的 drawingHandler（延迟绘制）
        // ⚠️ 不要在 body/init 里 lockFocus 同步绘制——NSHostingView 正在建立桥接时
        // 切图形上下文会触发 Swift 运行时「Fatal access conflict」直接崩溃（2026-10-18 实测）。
        let canvasSize = NSSize(width: canvasWidth, height: canvasHeight)
        let labelColor = NSColor.labelColor
        let lineColor = NSColor.labelColor.withAlphaComponent(0.45)
        let fillColor = NSColor.labelColor.withAlphaComponent(0.05)

        var positions: [String: CGRect] = [:]
        for layer in layouts {
            for item in layer {
                positions[item.node.id] = CGRect(origin: item.origin, size: item.size)
            }
        }

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: margin, y: margin)

            // 连线先画（节点盖住端点）
            for edge in edges {
                guard let fromRect = positions[edge.from], let toRect = positions[edge.to] else { continue }
                let start = CGPoint(x: fromRect.midX, y: fromRect.minY)
                let end = CGPoint(x: toRect.midX, y: toRect.maxY)
                let p0 = self.anchorPoint(from: fromRect, toward: end)
                let p1 = self.anchorPoint(from: toRect, toward: start)

                ctx.setStrokeColor(lineColor.cgColor)
                ctx.setLineWidth(1.4)
                ctx.setLineDash(phase: 0, lengths: edge.dashed ? [4, 3] : [])
                ctx.beginPath()
                ctx.move(to: p0)
                let midY = (p0.y + p1.y) / 2
                ctx.addCurve(to: p1,
                             control1: CGPoint(x: p0.x, y: midY),
                             control2: CGPoint(x: p1.x, y: midY))
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
                self.drawArrowHead(ctx, at: p1, from: p0, color: lineColor)

                if let label = edge.label, !label.isEmpty {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                    let size = (label as NSString).size(withAttributes: attrs)
                    let point = CGPoint(x: (p0.x + p1.x) / 2 - size.width / 2, y: midY - size.height / 2)
                    (label as NSString).draw(at: point, withAttributes: attrs)
                }
            }

            // 节点
            for layer in layouts {
                for item in layer {
                    let rect = CGRect(origin: item.origin, size: item.size)
                    ctx.setFillColor(fillColor.cgColor)
                    ctx.setStrokeColor(lineColor.cgColor)
                    ctx.setLineWidth(1.2)

                    let path: CGPath
                    switch item.node.shape {
                    case .rect:
                        path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
                    case .rounded, .capsule:
                        path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
                    case .subroutine:
                        path = CGPath(rect: rect, transform: nil)
                    case .circle:
                        path = CGPath(ellipseIn: rect.insetBy(dx: 4, dy: 4), transform: nil)
                    case .diamond:
                        let p = CGMutablePath()
                        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
                        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                        p.closeSubpath()
                        path = p
                    }
                    ctx.addPath(path)
                    ctx.drawPath(using: .fillStroke)

                    if item.node.shape == .subroutine {
                        ctx.setStrokeColor(lineColor.withAlphaComponent(0.6).cgColor)
                        ctx.beginPath()
                        ctx.move(to: CGPoint(x: rect.minX + 5, y: rect.minY))
                        ctx.addLine(to: CGPoint(x: rect.minX + 5, y: rect.maxY))
                        ctx.move(to: CGPoint(x: rect.maxX - 5, y: rect.minY))
                        ctx.addLine(to: CGPoint(x: rect.maxX - 5, y: rect.maxY))
                        ctx.strokePath()
                    }

                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: labelColor]
                    let text = item.node.label as NSString
                    let size = text.size(withAttributes: attrs)
                    text.draw(at: CGPoint(x: rect.midX - size.width / 2,
                                          y: rect.midY - size.height / 2),
                              withAttributes: attrs)
                }
            }
            ctx.restoreGState()
            return true
        }
        return image
    }

    /// 从矩形中心朝目标方向的边界点
    private func anchorPoint(from rect: CGRect, toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y
        if abs(dx) < 0.01 && abs(dy) < 0.01 { return center }
        let scaleX = dx == 0 ? .greatestFiniteMagnitude : (rect.width / 2) / abs(dx)
        let scaleY = dy == 0 ? .greatestFiniteMagnitude : (rect.height / 2) / abs(dy)
        let s = min(scaleX, scaleY)
        return CGPoint(x: center.x + dx * s, y: center.y + dy * s)
    }

    private func drawArrowHead(_ ctx: CGContext, at point: CGPoint, from origin: CGPoint, color: NSColor) {
        let angle = atan2(point.y - origin.y, point.x - origin.x)
        let length: CGFloat = 7
        let width: CGFloat = 4
        let p1 = CGPoint(x: point.x - length * cos(angle) + width * sin(angle),
                         y: point.y - length * sin(angle) - width * cos(angle))
        let p2 = CGPoint(x: point.x - length * cos(angle) - width * sin(angle),
                         y: point.y - length * sin(angle) + width * cos(angle))
        ctx.setFillColor(color.cgColor)
        ctx.beginPath()
        ctx.move(to: point)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()
    }
}
