import SwiftUI

// MARK: - 设置窗口通用 UI 组件
// 对齐 Frset 视觉：左侧图标 + 标题/副标题 + 右侧控件；圆角卡片分组。

/// 通用设置行：左侧可选图标 + 标题/副标题，右侧任意控件
struct SettingsRow<Trailing: View>: View {
    let icon: String?
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(icon: String? = nil, title: String, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = icon; self.title = title; self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Theme.accent.opacity(0.12))
                    .cornerRadius(Theme.smallRadius)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 6)
    }
}

/// 分组标题（分节头）
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        // v273：title 为空时不画标题行——二级页的页头已经有大标题，
        // 段内再写一遍同名的会形成「标题下又一个同名标题」的重复。
        VStack(alignment: .leading, spacing: title.isEmpty ? 0 : 8) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }
}

/// 圆角卡片容器（分组内容底板）
struct SettingsGroupBox<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: Theme.cornerRadius)
    }
}

/// 分隔线（行与行之间）
struct SettingsDivider: View {
    var body: some View {
        Divider()
            .opacity(0.6)
            .padding(.leading, 38)
    }
}

// MARK: - 可视化选项卡片（v234）
//
// 对齐 1Capture 设置里的「拖放架」四选一：**预览图 + 文字**，选中用强调色描边。
// 比下拉框贵一点地方，但外观类设置（钉图描边、主题、布局）用户必须"看见"才能选。

struct VisualOptionCard<Preview: View>: View {
    let title: String
    /// 预览尺寸：默认 104×66；四张卡片并排放进「标签列 + 内容」的行里时需要收窄
    let previewSize: CGSize
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var preview: () -> Preview

    init(title: String,
         previewSize: CGSize = CGSize(width: 104, height: 66),
         selected: Bool,
         action: @escaping () -> Void,
         @ViewBuilder preview: @escaping () -> Preview) {
        self.title = title
        self.previewSize = previewSize
        self.selected = selected
        self.action = action
        self.preview = preview
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                preview()
                    .frame(width: previewSize.width, height: previewSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.12),
                                          lineWidth: selected ? 2 : 0.8)
                    )
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Color.primary.opacity(0.82))
            }
            .padding(7)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.10) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
