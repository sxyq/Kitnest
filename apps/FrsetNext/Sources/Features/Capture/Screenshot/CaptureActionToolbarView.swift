import AppKit
import SwiftUI

private struct CaptureButtonAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

// MARK: - 框选动作面板内容（v219 三样式）
//
// 上一版的问题（用户实拍指出）：
//   · 「箭头和它的复制就非常怪」——主按钮和 chevron 是两个挨在一起的命中区
//     （HStack spacing 0），左边=执行、右边=展开，框选完手还在鼠标上时最容易点错；
//     chevron 只有 16pt 宽，看起来只是「复制」的装饰。
//   · 「更多」的 primary 是 nil，点它会执行 items.first（贴图）——
//     用户看到「···」，点一下把截图钉在屏幕上，这是猜不到的。
//   · 整个工具条没有任何出现/悬停动画，弹出像贴图。
//
// 这一版：
//   · 没有 chevron。有子项的组，悬停 0.3 秒自动向上浮出子项带；移开 0.22 秒收回。
//   · 没有主执行动作的组（「更多」）点击只展开，绝不替用户执行某个子项。
//   · 三种排布（iconBar / pillBar / primarySplit）由偏好切换，共用同一份分组数据。
//   · 面板整体 0.94→1 缩放 + 淡入（anchor 底部，视觉上从下方"长"出来），关闭时反向。

struct CaptureActionToolbarView: View {

    @ObservedObject var model: CaptureToolbarModel
    @Environment(\.settingsPreviewPersonalization) private var previewPersonalization
    private var windowRadius: CGFloat { (previewPersonalization ?? .shared).cornerRadius }

    /// 鼠标当前停留的组（延迟展开时用它判断鼠标是否还在原处）
    @Stored private var hovered: String? = nil
    /// 当前展开子项的组（nil = 未展开）
    @Stored private var expanded: String? = nil
    /// 子项列表内悬停的项（与 hovered 分开：hovered 只表示「哪个组被悬停」）
    @Stored private var hoveredItem: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barHeight: CGFloat = 56

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // 预览区吸收剩余高度，工具条永远贴底——否则窗口比内容高时
                // VStack 会整体居中，工具条悬在半空
                previewSection
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        hovered = nil
                        hoveredItem = nil
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { expanded = nil }
                    }
                Divider().opacity(0.4)
                bar.frame(height: barHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlayPreferenceValue(CaptureButtonAnchorKey.self) { anchors in
            GeometryReader { geo in
                if let group = expandedGroup, let anchor = anchors[group.id] {
                    let button = geo[anchor]
                    // 浮层正对触发按钮；仅靠近两端时向内让位，保留 12pt 边距。
                    let left = min(max(button.midX - 84, 12), geo.size.width - 180)
                    submenu(group)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                        .padding(.bottom, geo.size.height - button.minY + 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .offset(x: left)
                }
            }
        }
        .background(GlassSurface(cornerRadius: windowRadius))
        .overlay(
            RoundedRectangle(cornerRadius: windowRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        // 出现/消失动画放在窗口层（alphaValue + 位置），不在视图层做 opacity——
        // 视图层一旦以 opacity 0 安装，NSHostingView 首次合成会停在透明态。
        .onHover { inside in
            if !inside { handleHover(false, group: nil) }
        }
        // 面板是单例，上一次的悬停/展开会残留到下一次框选——每次 present 清一次
        .onChange(of: model.presentToken) { _ in
            hovered = nil
            hoveredItem = nil
            expanded = model.debugExpand
        }
    }

    // MARK: 预览

    private var previewSection: some View {
        Group {
            if let image = model.preview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 340, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
                    .padding(10)
                    // 预览图可直接拖到其他 App / AI 工具
                    .onDrag { NSItemProvider(object: image) }
                    .help("拖到其他 App 可直接使用这张图")
            }
        }
    }

    // MARK: 工具条（按样式分支）

    @ViewBuilder
    private var bar: some View {
        switch model.style {
        case .iconBar:      iconBar
        case .pillBar:      pillBar
        case .primarySplit: primarySplitBar
        }
    }

    /// A · 图标条：30pt 方块，只有图标；有子项的右下角一个 3.5pt 小点
    private var iconBar: some View {
        HStack(spacing: 10) {
            ForEach(CaptureActionChain.groups) { group in
                iconCell(group)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// B · 药丸条：图标 + 文字，默认动作实心
    private var pillBar: some View {
        HStack(spacing: 6) {
            ForEach(CaptureActionChain.groups) { group in
                pillCell(group)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
    }

    /// C · 主次分离：左侧默认动作大按钮，竖线，右侧次要图标
    private var primarySplitBar: some View {
        HStack(spacing: 10) {
            if let tool = primaryTool {
                Button {
                    model.onPick?(tool.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 12, weight: .medium))
                        Text(tool.title)
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(Theme.accent)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityHint("回车执行：\(tool.title)")
                .anchorPreference(key: CaptureButtonAnchorKey.self, value: .bounds) { anchor in
                    primaryGroup.map { [$0.id: anchor] } ?? [:]
                }
                // 大按钮也挂着它所在组的子项：默认动作被设成「保存」时，
                // 「复制」就退到这里的悬停浮层里，不会丢入口
                .onHover { inside in
                    if let group = primaryGroup { handleHover(inside, group: group) }
                }
            }

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 0.5, height: 20)

            HStack(spacing: 9) {
                ForEach(secondaryGroups) { group in
                    iconCell(group)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    // MARK: 单元

    private func iconCell(_ group: CaptureActionGroup) -> some View {
        let on = isDefault(group)
        let active = hovered == group.id || expanded == group.id
        return Button {
            activate(group)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(on ? Theme.accent
                          : (active ? Color.primary.opacity(0.08) : Color.clear))
                Image(systemName: primaryTool(group)?.systemImage ?? group.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(on ? Color.white : Color.primary.opacity(0.72))
            }
            .frame(width: 30, height: 30)
            .overlay(alignment: .bottomTrailing) {
                if !menuItems(group).isEmpty {
                    Circle()
                        .fill(on ? Color.white.opacity(0.8) : Color.primary.opacity(0.26))
                        .frame(width: 3.5, height: 3.5)
                        .offset(x: -3, y: -3)
                }
            }
            .scaleEffect(active ? 1.05 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(primaryTool(group)?.title ?? group.title)
        .accessibilityHint(helpText(group))
        .anchorPreference(key: CaptureButtonAnchorKey.self, value: .bounds) { [group.id: $0] }
        .onHover { handleHover($0, group: group) }
    }

    private func pillCell(_ group: CaptureActionGroup) -> some View {
        let on = isDefault(group)
        let active = hovered == group.id || expanded == group.id
        return Button {
            activate(group)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: group.systemImage)
                    .font(.system(size: 10.5, weight: .medium))
                Text(primaryTool(group)?.title ?? group.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.78))
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(on ? Theme.accent
                          : Color.primary.opacity(active ? 0.10 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(on ? Color.clear : Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityHint(helpText(group))
        .anchorPreference(key: CaptureButtonAnchorKey.self, value: .bounds) { [group.id: $0] }
        .onHover { handleHover($0, group: group) }
    }

    // MARK: 子项浮层

    private func submenu(_ group: CaptureActionGroup) -> some View {
        // v263：从横排小胶囊改成竖排列表。
        // 钉住一组有 5 个选项（经典 / 无边框 / 卡片 / 强调 / 挂到图帘），
        // 横排会超出面板宽度被裁掉；竖排一行一个形态，也正好对上
        // 用户说的「一个形态一个选项」。
        VStack(spacing: 0) {
            // 组名做小标题：竖排列表离触发图标有一段距离，没有标题会分不清是谁的子项
            Text(group.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.top, 2)
                .padding(.bottom, 4)
            if menuItems(group).isEmpty {
                Text(helpText(group))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
            }
            ForEach(menuItems(group), id: \.self) { id in
                if let tool = CaptureActionChain.tool(id: id) {
                    if id == "pinClassic" || id == "curtain" {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 0.5)
                            .padding(.vertical, 3)
                    }
                    Button {
                        model.onPick?(id)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: tool.systemImage)
                                .font(.system(size: 11))
                                .frame(width: 16)
                            Text(tool.title)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .fill(hoveredItem == id ? Color.primary.opacity(0.07) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .onHover { inside in
                        hoveredItem = inside ? id : (hoveredItem == id ? nil : hoveredItem)
                    }
                }
            }
        }
        .padding(5)
        .frame(width: 168)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .onHover { handleHover($0, group: group) }
    }

    // MARK: 动作

    /// 点击一个组：有主执行动作就执行；没有（「更多」）只展开，绝不代用户选
    private func activate(_ group: CaptureActionGroup) {
        if let id = primaryID(group) {
            model.onPick?(id)
        } else {
            toggle(group)
        }
    }

    private func toggle(_ group: CaptureActionGroup) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.85)) {
            expanded = (expanded == group.id) ? nil : group.id
        }
    }

    private func handleHover(_ inside: Bool, group: CaptureActionGroup?) {
        guard inside, let group else {
            hovered = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                guard hovered == nil else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { expanded = nil }
            }
            return
        }
        hovered = group.id
        guard expanded != group.id else { return }
        let id = group.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            // 鼠标已移走 / 已经展开过就别再弹
            guard hovered == id, expanded != id else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
                expanded = id
            }
        }
    }

    // MARK: 派生

    private var expandedGroup: CaptureActionGroup? {
        guard let id = expanded else { return nil }
        return CaptureActionChain.groups.first { $0.id == id }
    }

    private var primaryTool: CaptureActionTool? {
        if let id = CaptureActionChain.groups.first?.primary {
            return CaptureActionChain.tool(id: id)
        }
        return nil
    }

    /// 组的主执行动作：**固定是组自己的 primary**
    ///
    /// 用户明确要求「默认按钮是复制，保存是复制里面的二级」——
    /// 默认动作落在子项里时不要把主按钮换掉。高亮仍标在默认动作所在的组，
    /// 回车执行的是那个默认动作。
    private func primaryID(_ group: CaptureActionGroup) -> String? {
        group.primary
    }

    private func primaryTool(_ group: CaptureActionGroup) -> CaptureActionTool? {
        primaryID(group).flatMap { CaptureActionChain.tool(id: $0) }
    }

    /// 二级菜单项（组的 items 原样，不再把主动作塞回来）
    private func menuItems(_ group: CaptureActionGroup) -> [String] {
        group.items
    }

    /// 右侧次要图标：排除已经由左侧大按钮承担的那个组
    private var secondaryGroups: [CaptureActionGroup] {
        let dg = primaryGroup?.id
        return CaptureActionChain.groups.filter { $0.id != dg }
    }

    /// 左侧按钮显示复制，其提示与右侧排除项均按这个实际按钮分组。
    private var primaryGroup: CaptureActionGroup? {
        CaptureActionChain.groups.first
    }

    private func isDefault(_ group: CaptureActionGroup) -> Bool {
        guard let id = model.defaultToolID else { return false }
        // 默认动作可能是组内子项（常见：默认=保存，而「保存」在「复制」组里），
        // 也算这一组——否则工具条上一个高亮都没有，用户看不出回车会做什么。
        return group.primary == id || group.items.contains(id)
    }

    private func helpText(_ group: CaptureActionGroup) -> String {
        if group.primary == "recentCopy" { return "选择近期记录，一次复制" }
        if group.primary == "longShot" { return "在选区内滚动，连续拼接长截图" }
        let title = primaryTool(group)?.title ?? group.title
        return menuItems(group).isEmpty ? title : "\(title)（悬停看更多）"
    }
}
