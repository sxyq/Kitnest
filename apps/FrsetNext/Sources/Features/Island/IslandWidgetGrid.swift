import SwiftUI

/// 总设置决定画布；异构组件超出时进入下一页，拖动只调整现有顺序。
struct IslandWidgetGrid<Content: View>: View {
    @ObservedObject var controller: IslandController
    @ViewBuilder var content: (IslandWidget, IslandWidgetSize) -> Content
    @Stored private var target: IslandWidget? = nil
    @Stored private var previewOrder: [IslandWidget]?
    // 指针只通知单个 Canvas 绘制层，不触发卡片内容与排列计算。
    @Stored private var glow = StoredBox((location: CGPoint.zero, active: false))
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Placement: Identifiable {
        var item: IslandWidget
        var size: IslandWidgetSize
        var column: Int
        var row: Int
        var id: String { item.id }

        func frame(cell: CGSize, gap: CGFloat) -> CGRect {
            CGRect(x: CGFloat(column) * (cell.width + gap),
                   y: CGFloat(row) * (cell.height + gap),
                   width: cell.width * CGFloat(size.columns) + gap * CGFloat(size.columns - 1),
                   height: cell.height * CGFloat(size.rows) + gap * CGFloat(size.rows - 1))
        }
    }

    private var pages: [[Placement]] {
        let columns = controller.layoutColumns
        let rows = controller.layoutRows
        var result: [[Placement]] = [[]]
        var occupancy = [Set<Int>()]
        for item in previewOrder ?? controller.widgetOrder where !controller.configuration.hiddenWidgets.contains(item) {
            let requested = controller.configuration.requestedSize(for: item)
            let size = IslandWidgetSize.allCases.filter {
                $0.columns <= columns && $0.rows <= rows && $0.columns <= requested.columns && $0.rows <= requested.rows
            }.max { $0.columns * $0.rows < $1.columns * $1.rows }!
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
                let columns = CGFloat(controller.layoutColumns)
                let rows = CGFloat(controller.layoutRows)
                let cell = CGSize(width: (geometry.size.width - gap * (columns - 1)) / columns,
                                  height: (geometry.size.height - gap * (rows - 1)) / rows)
                let visible = layouts[min(controller.componentPage, layouts.count - 1)]
                ZStack(alignment: .topLeading) {
                    ForEach(visible) { placement in
                        let item = placement.item
                        let span = placement.size
                        let frame = placement.frame(cell: cell, gap: gap)
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
                                        controller.draggedWidget = item
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
                            .frame(width: frame.width, height: frame.height)
                            .clipped()
                            .overlay(RoundedRectangle(cornerRadius: IslandLayout.cardRadius)
                                .strokeBorder(target == item ? controller.configuration.color(for: item) : .clear, lineWidth: 2))
                            .offset(x: frame.minX, y: frame.minY)
                            .dropDestination(for: String.self) { values, _ in
                                guard let raw = values.first?.replacingOccurrences(of: "kitnest-widget:", with: ""),
                                      let source = IslandWidget(rawValue: raw) else { return false }
                                controller.move(source, before: item)
                                previewOrder = nil
                                controller.endInteraction()
                                return true
                            } isTargeted: { isTargeted in
                                target = isTargeted ? item : nil
                                if isTargeted, let source = controller.draggedWidget, source != item {
                                    var order = controller.widgetOrder
                                    order.removeAll { $0 == source }
                                    order.insert(source, at: order.firstIndex(of: item)!)
                                    previewOrder = order
                                }
                            }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .overlay {
                    IslandGlow(enabled: controller.glowEnabled && controller.expanded, pointer: glow,
                               frames: visible.map { $0.frame(cell: cell, gap: gap) },
                               radius: min(cell.width, cell.height) * 0.9)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        if controller.glowEnabled && controller.expanded { glow.value = (point, true) }
                    case .ended: glow.value.active = false
                    }
                }
                .onDisappear { glow.value.active = false }
                .clipped()
                .animation(reduceMotion ? nil : Theme.Motion.page, value: controller.configuration.widgetSizes)
                .animation(reduceMotion ? nil : Theme.Motion.page, value: controller.widgetOrder)
                .animation(reduceMotion ? nil : Theme.Motion.page, value: previewOrder)
                .animation(reduceMotion ? nil : Theme.Motion.page, value: [controller.configuration.columns, controller.configuration.rows])
            }
        }
        .task(id: layouts.count) { controller.setComponentPageCount(layouts.count) }
        .onChange(of: controller.draggedWidget) { if $0 == nil { previewOrder = nil; target = nil } }
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
