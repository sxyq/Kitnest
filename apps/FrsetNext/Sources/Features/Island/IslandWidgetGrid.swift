import SwiftUI

/// 固定 16 格画布；异构组件超出时进入下一页，拖动只调整现有顺序。
struct IslandWidgetGrid<Content: View>: View {
    @ObservedObject var controller: IslandController
    @ViewBuilder var content: (IslandWidget, IslandWidgetSize) -> Content
    @Stored private var page = 0
    @Stored private var target: IslandWidget? = nil
    @Stored private var resizing: IslandWidget? = nil
    @Stored private var dragSize: IslandWidgetSize? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Placement: Identifiable {
        var item: IslandWidget
        var size: IslandWidgetSize
        var column: Int
        var row: Int
        var id: String { item.id }
    }

    private var pages: [[Placement]] {
        var result: [[Placement]] = [[]]
        var occupancy = [Set<Int>()]
        for item in controller.widgetOrder where !controller.configuration.hiddenWidgets.contains(item) {
            let size = controller.configuration.size(for: item)
            var placement: (page: Int, index: Int)?
            for page in occupancy.indices {
                if let index = (0..<16).first(where: { index in
                    let x = index % 4, y = index / 4
                    return x + size.columns <= 4 && y + size.rows <= 4 &&
                        (y..<(y + size.rows)).allSatisfy { row in
                            (x..<(x + size.columns)).allSatisfy { !occupancy[page].contains(row * 4 + $0) }
                        }
                }) { placement = (page, index); break }
            }
            if placement == nil {
                result.append([]); occupancy.append([])
                placement = (result.count - 1, 0)
            }
            let (page, index) = placement!
            for y in index / 4..<(index / 4 + size.rows) {
                for x in index % 4..<(index % 4 + size.columns) { occupancy[page].insert(y * 4 + x) }
            }
            result[page].append(Placement(item: item, size: size, column: index % 4, row: index / 4))
        }
        return result
    }

    var body: some View {
        let layouts = pages
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let gap: CGFloat = 8
                let cell = CGSize(width: (geometry.size.width - gap * 3) / 4,
                                  height: (geometry.size.height - gap * 3) / 4)
                ZStack(alignment: .topLeading) {
                    ForEach(layouts[min(page, layouts.count - 1)]) { placement in
                        let item = placement.item
                        let span = resizing == item ? dragSize ?? placement.size : placement.size
                        content(item, span)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24).contentShape(Rectangle())
                                    .onDrag {
                                        controller.beginInteraction()
                                        return NSItemProvider(object: "kitnest-widget:\(item.rawValue)" as NSString)
                                    }
                                    .padding(6)
                                    .accessibilityLabel("拖动\(item.title)")
                            }
                            .overlay(alignment: .bottomTrailing) {
                                Button {
                                    let sizes = IslandWidgetSize.allCases
                                    controller.resize(item, to: sizes[(sizes.firstIndex(of: placement.size)! + 1) % sizes.count])
                                } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 9)).frame(width: 20, height: 20)
                                }
                                .buttonStyle(IslandButtonStyle(help: "拖动调尺寸 · 点按切换 · 右键选择", tipAlignment: .bottomTrailing))
                                .contextMenu {
                                    ForEach(IslandWidgetSize.allCases) { size in
                                        Button(size.rawValue) { controller.resize(item, to: size) }
                                    }
                                    Button("前移") { move(item, step: -1) }
                                    Button("后移") { move(item, step: 1) }
                                }
                                .padding(5)
                                .accessibilityLabel("\(item.title)尺寸与顺序")
                                .focusable()
                                .onMoveCommand { direction in
                                    if direction == .up || direction == .down { move(item, step: direction == .up ? -1 : 1) }
                                    else {
                                        let sizes = IslandWidgetSize.allCases
                                        let index = sizes.firstIndex(of: placement.size)!
                                        let step = direction == .left ? sizes.count - 1 : 1
                                        let next = (index + step) % sizes.count
                                        controller.resize(item, to: sizes[next])
                                    }
                                }
                                .highPriorityGesture(DragGesture(minimumDistance: 5)
                                    .onChanged { value in
                                        if resizing == nil { resizing = item; controller.beginInteraction() }
                                        let columns = CGFloat(placement.size.columns) + value.translation.width / (cell.width + gap)
                                        let rows = CGFloat(placement.size.rows) + value.translation.height / (cell.height + gap)
                                        dragSize = rows >= 1.5 ? .square : columns >= 3 ? .strip : columns >= 1.5 ? .wide : .small
                                    }
                                    .onEnded { _ in
                                        if let dragSize { controller.resize(item, to: dragSize) }
                                        resizing = nil; dragSize = nil; controller.endInteraction()
                                    })
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
