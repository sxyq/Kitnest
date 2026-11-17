import AppKit
import SwiftUI

private struct IslandWidgetPlacement: Identifiable, Equatable {
    let item: IslandWidget
    let size: IslandWidgetSize
    let position: IslandWidgetPosition
    var id: String { item.id }
    func frame(cell: CGSize) -> CGRect {
        CGRect(x: CGFloat(position.column) * (cell.width + 8), y: CGFloat(position.row) * (cell.height + 8),
               width: CGFloat(size.columns) * (cell.width + 8) - 8,
               height: CGFloat(size.rows) * (cell.height + 8) - 8)
    }
}

/// 正常使用不安装重排手势；编辑只改变布局草稿，离散网格变化才重新排列。
struct IslandWidgetGrid<Content: View>: View {
    @ObservedObject var controller: IslandController
    @ViewBuilder var content: (IslandWidget, IslandWidgetSize) -> Content
    @Stored private var placements: [IslandWidgetPlacement] = []
    @Stored private var active: IslandWidget?
    @Stored private var original: IslandConfiguration?
    @Stored private var footprint: CGSize?
    @Stored private var pressured = Set<IslandWidget>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let cell = CGSize(width: (geometry.size.width - CGFloat(controller.layoutColumns - 1) * 8) / CGFloat(controller.layoutColumns),
                                  height: (geometry.size.height - CGFloat(controller.layoutRows - 1) * 8) / CGFloat(controller.layoutRows))
                ZStack(alignment: .topLeading) {
                    if controller.editingLayout {
                        Canvas { context, _ in
                            for row in 0..<controller.layoutRows {
                                for column in 0..<controller.layoutColumns {
                                    let rect = CGRect(x: CGFloat(column) * (cell.width + 8), y: CGFloat(row) * (cell.height + 8),
                                                      width: cell.width, height: cell.height)
                                    context.stroke(Path(roundedRect: rect, cornerRadius: IslandLayout.cardRadius),
                                                   with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                                }
                            }
                        }.allowsHitTesting(false).accessibilityHidden(true)
                        if let active, let original, let position = original.widgetPositions?[active.rawValue] {
                            let old = IslandWidgetPlacement(item: active, size: original.size(for: active), position: position)
                            RoundedRectangle(cornerRadius: IslandLayout.cardRadius)
                                .strokeBorder(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .frame(width: old.frame(cell: cell).width, height: old.frame(cell: cell).height)
                                .offset(x: old.frame(cell: cell).minX, y: old.frame(cell: cell).minY)
                                .allowsHitTesting(false)
                        }
                    }
                    ForEach(placements.filter { $0.position.page == controller.componentPage || $0.item == active }) { placement in
                        IslandEditableWidget(item: placement.item, size: placement.size, frame: placement.frame(cell: cell),
                                             cell: cell, bounds: geometry.size, editing: controller.editingLayout,
                                             pressured: pressured.contains(placement.item), configuration: controller.layoutConfiguration,
                                             begin: { begin(placement.item) }, change: { point, size, liveSize in
                                                 change(placement.item, point: point, size: size, liveSize: liveSize, cell: cell, bounds: geometry.size)
                                             }, end: { valid in end(valid: valid) },
                                             remove: { controller.setWidgetVisible(placement.item, visible: false) }) {
                            content(placement.item, placement.size)
                        }
                        .zIndex(active == placement.item ? 2 : 0)
                    }
                }
                .coordinateSpace(name: "islandLayout")
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
                .animation(reduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.86, blendDuration: 0),
                           value: placements)
                .animation(reduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.86, blendDuration: 0),
                           value: pressured)
            }
        }
        .onAppear { rebuild() }
        .onChange(of: [controller.layoutColumns, controller.layoutRows]) { _ in rebuild() }
        .onChange(of: controller.layoutConfiguration) { _ in rebuild() }
        .onChange(of: controller.editingLayout) { editing in
            if !editing { active = nil; original = nil; footprint = nil; pressured = []; rebuild() }
        }
    }

    private func layout(_ configuration: IslandConfiguration) -> [IslandWidgetPlacement] {
        let columns = controller.layoutColumns, rows = controller.layoutRows
        var occupied: [Set<Int>] = [[]]
        var result: [IslandWidgetPlacement] = []
        let order = configuration.widgetOrder.filter { !configuration.hiddenWidgets.contains($0) }
        for item in (active.map { [$0] } ?? []) + order.filter({ $0 != active }) {
            let requested = configuration.requestedSize(for: item)
            let size = IslandWidgetSize.allCases.filter { $0.columns <= columns && $0.rows <= rows &&
                $0.columns <= requested.columns && $0.rows <= requested.rows
            }.max { $0.columns * $0.rows < $1.columns * $1.rows }!
            let wanted = configuration.widgetPositions?[item.rawValue]
            let width = item == active ? Int(footprint?.width ?? CGFloat(size.columns)) : size.columns
            let height = item == active ? Int(footprint?.height ?? CGFloat(size.rows)) : size.rows
            while occupied.count <= (wanted?.page ?? 0) { occupied.append([]) }
            func fits(_ page: Int, _ column: Int, _ row: Int) -> Bool {
                column >= 0 && row >= 0 && column + width <= columns && row + height <= rows &&
                (row..<(row + height)).allSatisfy { y in
                    (column..<(column + width)).allSatisfy { !occupied[page].contains(y * columns + $0) }
                }
            }
            var position: IslandWidgetPosition?
            if let wanted, fits(wanted.page, wanted.column, wanted.row) { position = wanted }
            if position == nil {
                let pages = Array(occupied.indices).sorted {
                    abs($0 - (wanted?.page ?? 0)) < abs($1 - (wanted?.page ?? 0))
                }
                for page in pages {
                    let cells = (0..<(columns * rows)).sorted {
                        let x = wanted?.column ?? 0, y = wanted?.row ?? 0
                        return abs($0 % columns - x) + abs($0 / columns - y) <
                               abs($1 % columns - x) + abs($1 / columns - y)
                    }
                    if let index = cells.first(where: { fits(page, $0 % columns, $0 / columns) }) {
                        position = .init(page: page, column: index % columns, row: index / columns); break
                    }
                }
            }
            if position == nil {
                occupied.append([])
                position = .init(page: occupied.count - 1, column: 0, row: 0)
            }
            let place = position!
            for y in place.row..<(place.row + height) {
                for x in place.column..<(place.column + width) { occupied[place.page].insert(y * columns + x) }
            }
            result.append(.init(item: item, size: size, position: place))
        }
        return result
    }

    private func rebuild() {
        let next = layout(controller.layoutConfiguration)
        if active != nil {
            pressured.formUnion(next.filter { item in
                placements.contains { $0.item == item.item && $0.position != item.position }
            }.map(\.item).filter { $0 != active })
        }
        placements = next
        controller.setComponentPageCount((next.map { $0.position.page }.max() ?? 0) + 1)
    }

    private func begin(_ item: IslandWidget) {
        active = item
        var next = controller.layoutConfiguration
        if !temporaryLayout || next.widgetPositions == nil {
            next.widgetPositions = Dictionary(uniqueKeysWithValues: placements.map { ($0.item.rawValue, $0.position) })
        }
        original = next
        controller.beginInteraction()
        controller.updateLayout(next)
    }

    private func change(_ item: IslandWidget, point: CGPoint, size: IslandWidgetSize?, liveSize: CGSize?, cell: CGSize, bounds: CGSize) {
        guard CGRect(origin: .zero, size: bounds).contains(point) else { return }
        var next = controller.layoutConfiguration
        let span = size ?? placements.first { $0.item == item }!.size
        let occupied = liveSize.map {
            CGSize(width: min(CGFloat(controller.layoutColumns), ceil(($0.width + 8) / (cell.width + 8))),
                   height: min(CGFloat(controller.layoutRows), ceil(($0.height + 8) / (cell.height + 8))))
        }
        let previous = next.widgetPositions?[item.rawValue]
        let previousSize = next.size(for: item)
        let x = point.x / (cell.width + 8), y = point.y / (cell.height + 8)
        let column = previous.map { abs(x - CGFloat($0.column)) < 0.62 ? $0.column : Int(x.rounded()) } ?? Int(x.rounded())
        let row = previous.map { abs(y - CGFloat($0.row)) < 0.62 ? $0.row : Int(y.rounded()) } ?? Int(y.rounded())
        let place = IslandWidgetPosition(page: controller.componentPage,
            column: min(max(0, column), controller.layoutColumns - Int(occupied?.width ?? CGFloat(span.columns))),
            row: min(max(0, row), controller.layoutRows - Int(occupied?.height ?? CGFloat(span.rows))))
        if let size { next.widgetSizes[item.rawValue] = size }
        next.widgetPositions?[item.rawValue] = place
        let crossedCell = occupied != footprint
        footprint = occupied
        if next != controller.layoutConfiguration {
            controller.updateLayout(next)
            if !controller.previewOnly {
                if let size, size != previousSize { HapticFeedback.perform(.gridResize) }
                else if size == nil, previous != place { HapticFeedback.perform(.gridMove) }
            }
        }
        else if crossedCell { rebuild() }
    }

    private func end(valid: Bool) {
        footprint = nil
        if valid {
            rebuild()
            var next = controller.layoutConfiguration
            if !temporaryLayout {
                next.widgetPositions = Dictionary(uniqueKeysWithValues: placements.map { ($0.item.rawValue, $0.position) })
            }
            let visible = placements.sorted {
                ($0.position.page, $0.position.row, $0.position.column) < ($1.position.page, $1.position.row, $1.position.column)
            }.map(\.item)
            if !temporaryLayout { next.widgetOrder = visible + next.widgetOrder.filter { next.hiddenWidgets.contains($0) } }
            controller.updateLayout(next)
        } else if let original { controller.updateLayout(original) }
        active = nil; original = nil; pressured = []
        rebuild()
        // 编辑模式保持展开，直到完成或取消；不在每次放下后启动收回计时。
    }

    private var temporaryLayout: Bool {
        controller.layoutColumns < controller.layoutConfiguration.columns || controller.layoutRows < controller.layoutConfiguration.rows
    }
}

private struct IslandEditableWidget<Content: View>: View {
    let item: IslandWidget
    let size: IslandWidgetSize
    let frame: CGRect
    let cell: CGSize
    let bounds: CGSize
    let editing: Bool
    let pressured: Bool
    let configuration: IslandConfiguration
    let begin: () -> Void
    let change: (CGPoint, IslandWidgetSize?, CGSize?) -> Void
    let end: (Bool) -> Void
    let remove: () -> Void
    @ViewBuilder var content: () -> Content
    @Stored private var origin: CGRect?
    @Stored private var translation = CGSize.zero
    @Stored private var resizing = false
    @Stored private var candidate: IslandWidgetSize?
    @FocusState private var moveFocused: Bool
    @FocusState private var resizeFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var liveSize: CGSize {
        if resizing, let origin {
            return CGSize(width: min(max(cell.width, origin.width + translation.width), bounds.width),
                          height: min(max(cell.height, origin.height + translation.height), bounds.height))
        }
        return frame.size
    }
    private var liveOrigin: CGPoint {
        guard let origin else { return frame.origin }
        return resizing ? CGPoint(x: min(origin.minX, bounds.width - liveSize.width), y: min(origin.minY, bounds.height - liveSize.height)) :
            CGPoint(x: origin.minX + translation.width, y: origin.minY + translation.height)
    }

    var body: some View {
        content()
            .frame(width: liveSize.width - (pressured ? 4 : 0), height: liveSize.height - (pressured ? 2 : 0))
            .disabled(editing)
            .allowsHitTesting(!editing)
            .frame(width: liveSize.width, height: liveSize.height)
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: IslandLayout.cardRadius)
                        .strokeBorder(configuration.color(for: item).opacity(origin == nil && !moveFocused && !resizeFocused ? 0.4 : 1),
                                      lineWidth: origin == nil && !moveFocused && !resizeFocused ? 1 : 2)
                        .allowsHitTesting(false)
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("islandLayout"))
                            .onChanged { value in
                                if origin == nil { origin = frame; resizing = false; begin() }
                                translation = value.translation
                                change(liveOrigin, nil, nil)
                            }
                            .onEnded { value in
                                end(CGRect(origin: .zero, size: bounds).contains(value.location))
                                settle()
                            })
                        .accessibilityLabel("移动\(item.title)")
                        .focusable()
                        .focused($moveFocused)
                        .onMoveCommand { direction in
                            begin()
                            var point = frame.origin
                            if direction == .left { point.x -= cell.width + 8 }
                            if direction == .right { point.x += cell.width + 8 }
                            if direction == .up { point.y -= cell.height + 8 }
                            if direction == .down { point.y += cell.height + 8 }
                            change(point, nil, nil); end(true)
                        }
                }
            }
            .overlay(alignment: .topLeading) {
                if editing {
                    Button(action: remove) { Image(systemName: "minus.circle.fill").font(.system(size: 18)) }
                        .buttonStyle(IslandButtonStyle(help: "移出首页，功能仍在全部功能中"))
                        .frame(width: 28, height: 28).accessibilityLabel("移出首页：\(item.title)")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if editing {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(resizing || resizeFocused ? configuration.color(for: item) : .secondary)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .onHover { hover in
                            if hover {
                                if #available(macOS 15.0, *) { NSCursor.frameResize(position: .bottomRight, directions: .all).push() }
                                else { NSCursor.crosshair.push() }
                            } else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("islandLayout"))
                            .onChanged { value in
                                if origin == nil { origin = frame; resizing = true; candidate = size; begin() }
                                translation = value.translation
                                let next = choices.min { distance($0) < distance($1) }!
                                if next != candidate && distance(next) + 0.12 < distance(candidate!) {
                                    candidate = next
                                }
                                change(liveOrigin, candidate, liveSize)
                            }
                            .onEnded { value in
                                let valid = CGRect(origin: .zero, size: bounds).contains(value.location)
                                if valid {
                                    let next = choices.min { distance($0) < distance($1) }!
                                    change(liveOrigin, next, liveSize)
                                }
                                end(valid); settle()
                            })
                        .accessibilityLabel("调整\(item.title)尺寸")
                        .focusable()
                        .focused($resizeFocused)
                        .accessibilityValue(candidate?.rawValue ?? size.rawValue)
                        .onMoveCommand { direction in
                            adjustSize(direction == .right || direction == .up ? 1 : -1)
                        }
                        .accessibilityAdjustableAction { direction in
                            adjustSize(direction == .increment ? 1 : -1)
                        }
                        .help("聚焦后按方向键调整尺寸")
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if resizing { Text(candidate?.rawValue ?? size.rawValue).font(.system(size: 10)).padding(6).background(.black.opacity(0.7)) }
            }
            .offset(x: liveOrigin.x, y: liveOrigin.y)
            .transaction { if origin != nil { $0.animation = nil } }
            .onChange(of: editing) { if !$0 { origin = nil; translation = .zero; resizing = false; candidate = nil } }
    }

    private func settle() {
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.86, blendDuration: 0)) {
            origin = nil; translation = .zero; resizing = false; candidate = nil
        }
    }

    private func adjustSize(_ step: Int) {
        let sizes = choices.sorted { $0.columns * $0.rows < $1.columns * $1.rows }
        let index = sizes.firstIndex(of: size)!
        let next = min(max(0, index + step), sizes.count - 1)
        begin(); change(frame.origin, sizes[next], nil); end(true)
    }

    private var choices: [IslandWidgetSize] {
        IslandWidgetSize.allCases.filter {
            CGFloat($0.columns) * (cell.width + 8) - 8 <= bounds.width + 1 &&
            CGFloat($0.rows) * (cell.height + 8) - 8 <= bounds.height + 1
        }
    }

    private func distance(_ size: IslandWidgetSize) -> CGFloat {
        let dx = (liveSize.width + 8) / (cell.width + 8) - CGFloat(size.columns)
        let dy = (liveSize.height + 8) / (cell.height + 8) - CGFloat(size.rows)
        return dx * dx + dy * dy
    }
}
