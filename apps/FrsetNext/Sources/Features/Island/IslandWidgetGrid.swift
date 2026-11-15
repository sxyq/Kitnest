import SwiftUI

/// 总设置决定画布；异构组件超出时进入下一页，拖动只调整现有顺序。
struct IslandWidgetGrid<Content: View>: View {
    @ObservedObject var controller: IslandController
    @ViewBuilder var content: (IslandWidget, IslandWidgetSize) -> Content
    @Stored private var page = 0
    @Stored private var target: IslandWidget? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Placement: Identifiable {
        var item: IslandWidget
        var size: IslandWidgetSize
        var column: Int
        var row: Int
        var id: String { item.id }
    }

    private var pages: [[Placement]] {
        let columns = controller.configuration.columns
        let rows = controller.configuration.rows
        var result: [[Placement]] = [[]]
        var occupancy = [Set<Int>()]
        for item in controller.widgetOrder where !controller.configuration.hiddenWidgets.contains(item) {
            let size = controller.configuration.size(for: item)
            var placement: (page: Int, index: Int)?
            for page in occupancy.indices {
                if let index = (0..<(columns * rows)).first(where: { index in
                    let x = index % columns, y = index / columns
                    return x + size.columns <= columns && y + size.rows <= rows &&
                        (y..<(y + size.rows)).allSatisfy { row in
                            (x..<(x + size.columns)).allSatisfy { !occupancy[page].contains(row * columns + $0) }
                        }
                }) { placement = (page, index); break }
            }
            if placement == nil {
                result.append([]); occupancy.append([])
                placement = (result.count - 1, 0)
            }
            let (page, index) = placement!
            for y in index / columns..<(index / columns + size.rows) {
                for x in index % columns..<(index % columns + size.columns) { occupancy[page].insert(y * columns + x) }
            }
            result[page].append(Placement(item: item, size: size, column: index % columns, row: index / columns))
        }
        return result
    }

    var body: some View {
        let layouts = pages
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let gap: CGFloat = 8
                let columns = CGFloat(controller.configuration.columns)
                let rows = CGFloat(controller.configuration.rows)
                let cell = CGSize(width: (geometry.size.width - gap * (columns - 1)) / columns,
                                  height: (geometry.size.height - gap * (rows - 1)) / rows)
                ZStack(alignment: .topLeading) {
                    ForEach(layouts[min(page, layouts.count - 1)]) { placement in
                        let item = placement.item
                        let span = placement.size
                        content(item, span)
                            .overlay(alignment: .topTrailing) {
                                Button { move(item, step: -1) } label: {
                                    Image(systemName: "line.3.horizontal")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                    .buttonStyle(IslandButtonStyle(help: "拖动排列 · 点击前移 · 右键选顺序", tipAlignment: .bottomTrailing))
                                    .frame(width: 24, height: 24).contentShape(Rectangle())
                                    .onDrag {
                                        controller.beginInteraction()
                                        return NSItemProvider(object: "kitnest-widget:\(item.rawValue)" as NSString)
                                    }
                                    .contextMenu {
                                        Button("前移") { move(item, step: -1) }
                                        Button("后移") { move(item, step: 1) }
                                    }
                                    .focusable()
                                    .onMoveCommand { direction in
                                        if direction == .up || direction == .left { move(item, step: -1) }
                                        if direction == .down || direction == .right { move(item, step: 1) }
                                    }
                                    .padding(6)
                                    .accessibilityLabel("拖动\(item.title)")
                            }
                            .frame(width: cell.width * CGFloat(span.columns) + gap * CGFloat(span.columns - 1),
                                   height: cell.height * CGFloat(span.rows) + gap * CGFloat(span.rows - 1))
                            .clipped()
                            .overlay(RoundedRectangle(cornerRadius: IslandLayout.cardRadius)
                                .strokeBorder(target == item ? controller.configuration.color(for: item) : .clear, lineWidth: 2))
                            .offset(x: CGFloat(placement.column) * (cell.width + gap), y: CGFloat(placement.row) * (cell.height + gap))
                            .dropDestination(for: String.self) { values, _ in
                                guard let raw = values.first?.replacingOccurrences(of: "kitnest-widget:", with: ""),
                                      let source = IslandWidget(rawValue: raw) else { return false }
                                controller.move(source, before: item)
                                controller.endInteraction()
                                return true
                            } isTargeted: { isTargeted in target = isTargeted ? item : nil }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
                .animation(reduceMotion ? nil : Theme.Motion.page, value: controller.configuration.widgetSizes)
                .animation(reduceMotion ? nil : Theme.Motion.page, value: controller.widgetOrder)
                .animation(reduceMotion ? nil : Theme.Motion.page, value: [controller.configuration.columns, controller.configuration.rows])
            }
            if layouts.count > 1 {
                HStack(spacing: 12) {
                    Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                    Text("组件 \(min(page + 1, layouts.count)) / \(layouts.count)").font(.system(size: 10)).monospacedDigit()
                    Button { page = min(layouts.count - 1, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= layouts.count - 1)
                }.buttonStyle(IslandButtonStyle()).frame(height: 18)
            }
        }
    }

    private func move(_ item: IslandWidget, step: Int) {
        let order = controller.widgetOrder
        let index = order.firstIndex(of: item)!
        let next = index + step
        guard order.indices.contains(next) else { return }
        if step < 0 { controller.move(item, before: order[next]) }
        else { controller.move(order[next], before: item) }
    }
}
