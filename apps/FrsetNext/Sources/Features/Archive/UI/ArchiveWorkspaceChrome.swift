import AppKit
import PDFKit
import SwiftUI

// ArcZip 1.2.5 工作区外观对齐（2026-11-23）
//
// 取证来源：AppearanceLight.png / AppearanceDark.png / OnboardingMiniWindow.png（官方截图）、
// zh-Hans 本地化 1677 条、二进制 SwiftUI 类型名与字段名
// （WorkspaceViewModeControl / WorkspaceDirectoryBar / InspectorPreviewCanvas /
//   InspectorMetadataRow / _workspaceViewMode / inspectorPreviewEntryID …）。
//
// 视觉口径（截图取样，非猜）：
//   强调紫 #844EFC；新增按钮绿 #00A650；选中行用系统蓝（截到 #2A60D8）；
//   窗口面 #FFFFFF / 暗 #1C1C1E；检查器面板 #F7F6FA / 暗 #202022；发丝线 primary 8%。
// 结构口径：标题行与工具控件同排（红绿灯右侧标题、右侧圆钮组），
//   下一行是「路径胶囊」（‹ › ↑ │ 面包屑），内容区右侧是检查器（详情 + 预览）。

// MARK: - 视图模式

enum ArchiveViewMode: String, CaseIterable, Identifiable {
    case icons, list, columns

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icons: return "图标"
        case .list: return "列表"
        case .columns: return "分栏"
        }
    }

    var symbol: String {
        switch self {
        case .icons: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        }
    }
}

// MARK: - 圆形工具钮（截图：白底细边 28pt；主操作实心）

struct ArchiveCircleButton: View {
    enum Kind { case plain, accent, green }

    let symbol: String
    var kind: Kind = .plain
    var size: CGFloat = 28
    var help: String = ""
    var action: () -> Void

    @Stored private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(background)
                .overlay {
                    Circle().strokeBorder(border, lineWidth: kind == .plain ? 1 : 0)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var foreground: Color {
        switch kind {
        case .plain: return hovering ? .primary : .secondary
        case .accent, .green: return .white
        }
    }

    private var background: some View {
        Circle().fill(fill)
    }

    private var fill: Color {
        switch kind {
        case .plain:
            if colorScheme == .dark {
                return Color.white.opacity(hovering ? 0.13 : 0.07)
            }
            return hovering ? Theme.insetFill : Theme.cardFill
        case .accent:
            return Theme.accent
        case .green:
            return Color(red: 0x00 / 255, green: 0xA6 / 255, blue: 0x50 / 255)
        }
    }

    private var border: Color {
        guard kind == .plain else { return .clear }
        return colorScheme == .dark ? Color.white.opacity(0.12) : Theme.hairlineColor
    }
}

// MARK: - 视图模式分段（截图：胶囊底 + 选中项实心紫圆）

struct ArchiveViewModeControl: View {
    @Binding var mode: ArchiveViewMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ArchiveViewMode.allCases) { item in
                Button { mode = item } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(mode == item ? Color.white : Color.secondary)
                        .frame(width: 30, height: 24)
                        .background {
                            if mode == item {
                                Circle().fill(Theme.accent)
                                    .frame(width: 24, height: 24)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 30)
        .background(Capsule().fill(Theme.cardFill))
        .overlay { Capsule().strokeBorder(Theme.hairlineColor, lineWidth: 1) }
    }
}

// MARK: - 标题行（红绿灯右侧标题；右侧控件组）

struct ArchiveTitleBar: View {
    let title: String
    let dirty: Bool
    @Binding var searchText: String
    @Binding var mode: ArchiveViewMode
    var searchPlaceholder: String = "搜索"
    /// v290：渐进索引未完成时禁用搜索（ArcZip preliminary_help 口径）
    var searchDisabled: Bool = false
    var onSave: () -> Void
    var onDelete: () -> Void
    var canDelete: Bool
    var canSave: Bool

    @Stored private var searchExpanded = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
            if dirty {
                Circle().fill(Color.orange).frame(width: 5, height: 5)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            Spacer(minLength: 8)

            if searchExpanded {
                TextField(searchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .disabled(searchDisabled)
                    .help(searchDisabled ? "请等待文件列表读取完成，再搜索。" : "")
                    .frame(width: 150)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(Theme.cardFill))
                    .overlay { Capsule().strokeBorder(Theme.hairlineColor, lineWidth: 1) }
                    .onSubmit { searchExpanded = false }
            }

            ArchiveViewModeControl(mode: $mode)

            ArchiveCircleButton(symbol: "trash", help: "删除所选项目") { onDelete() }
                .opacity(canDelete ? 1 : 0.4)
                .disabled(!canDelete)

            ArchiveCircleButton(symbol: "square.and.arrow.down", kind: .green, help: "保存修改") {
                onSave()
            }
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.55)

            ArchiveCircleButton(symbol: "magnifyingglass", help: searchExpanded ? "收起搜索" : "搜索") {
                withAnimation(.easeOut(duration: 0.16)) {
                    searchExpanded.toggle()
                    if searchExpanded { searchFocused = true } else { searchText = "" }
                }
            }
        }
        .padding(.leading, 92)     // 让开红绿灯（原生三钮宽约 68pt + 边距）
        .padding(.trailing, 16)
        .frame(height: 46)
    }
}

// MARK: - 路径胶囊（‹ › ↑ │ 面包屑）

struct ArchivePathBar: View {
    @Environment(\.colorScheme) private var colorScheme

    let crumbs: [(name: String, path: String)]
    let currentPath: String
    var canGoBack: Bool
    var canGoForward: Bool
    var onBack: () -> Void
    var onForward: () -> Void
    var onUp: () -> Void
    var onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            navButton("chevron.left", enabled: canGoBack, action: onBack)
            navButton("chevron.right", enabled: canGoForward, action: onForward)
            navButton("arrow.up", enabled: !currentPath.isEmpty, action: onUp)

            Rectangle()
                .fill(Theme.hairlineColor)
                .frame(width: 1, height: 14)
                .padding(.horizontal, 6)

            if crumbs.count <= 4 {
                crumbRow
            } else {
                ScrollView(.horizontal, showsIndicators: false) { crumbRow }
                    .frame(maxWidth: 460)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(Capsule().fill(colorScheme == .dark
                                   ? Color.white.opacity(0.07) : Theme.cardFill))
        .overlay {
            Capsule().strokeBorder(colorScheme == .dark
                                   ? Color.white.opacity(0.12) : Theme.hairlineColor, lineWidth: 1)
        }
        .padding(.leading, 92)
        .padding(.trailing, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var crumbRow: some View {
        HStack(spacing: 4) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Button { onSelect(crumb.path) } label: {
                    HStack(spacing: 4) {
                        if index == 0 {
                            Image(systemName: "archivebox")
                                .font(.system(size: 9))
                        }
                        Text(crumb.name)
                            .font(.system(size: 11, weight: index == crumbs.count - 1 ? .medium : .regular))
                    }
                    .foregroundStyle(index == crumbs.count - 1 ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background {
                        if index == crumbs.count - 1 {
                            Capsule().fill(Theme.insetFill)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(enabled ? Color.secondary : Theme.tertiaryText.opacity(0.5))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - 空态卡（截图：虚线圆角框 + 图标 + 标题 + 说明）

struct ArchiveEmptyDropCard: View {
    var title: String = "添加文件到压缩包"
    var detail: String = "点击添加文件，或直接将文件拖拽到这里"
    var action: () -> Void

    @Stored private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                            .offset(x: 4, y: 4)
                    }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .frame(width: 320, height: 150)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(hovering ? Theme.insetFill.opacity(0.6) : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(
                        Theme.tertiaryText.opacity(hovering ? 0.55 : 0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 检查器（右侧「压缩包详情 / 文件详情」）

/// 检查器内容（与模型解耦：窗口把 model 映射成这个结构，视图只管画）
struct ArchiveInspectorContent {
    enum Kind { case archive, entry, multi }
    enum Preview {
        case none
        case symbol(String)
        case text(String)
        case image(NSImage)
        case pdf(PDFDocument)
        case placeholder(String)
        case unsupported
    }

    var kind: Kind
    var headerTitle: String
    var name: String
    var subtitle: String
    var rows: [(String, String)]
    var preview: Preview
    var canOpenExternally: Bool

    static let empty = ArchiveInspectorContent(
        kind: .archive, headerTitle: "压缩包详情", name: "", subtitle: "",
        rows: [], preview: .none, canOpenExternally: false
    )
}

struct ArchiveInspectorPanel: View {
    var content: ArchiveInspectorContent
    var onOpenExternally: () -> Void = {}
    var onExpandPreview: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(content.headerTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 38)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if content.kind == .archive {
                        ArchiveGlyph(size: 104)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 14)
                            .padding(.bottom, 16)
                    } else {
                        previewCanvas { previewContent }
                            .padding(.top, 4)
                            .padding(.bottom, 14)
                    }

                    Text(content.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(content.kind == .archive ? .center : .leading)
                        .frame(maxWidth: .infinity,
                               alignment: content.kind == .archive ? .center : .leading)

                    Text(content.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity,
                               alignment: content.kind == .archive ? .center : .leading)
                        .padding(.top, 3)
                        .padding(.bottom, 14)

                    ForEach(Array(content.rows.enumerated()), id: \.offset) { _, row in
                        metadata(row.0, row.1)
                    }

                    if content.canOpenExternally {
                        Button(action: onOpenExternally) {
                            Label("用默认应用打开", systemImage: "arrow.up.forward.app")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 272)
        .clipped()
        .background(panelFill)
        .overlay(alignment: .topLeading) {
            UnevenRoundedRectangle(topLeadingRadius: 14,
                                   bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0,
                                   topTrailingRadius: 0,
                                   style: .continuous)
                .strokeBorder(Theme.hairlineColor, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var panelFill: Color {
        colorScheme == .dark
            ? Color(red: 0.129, green: 0.129, blue: 0.141)
            : Color(red: 0.965, green: 0.957, blue: 0.985)
    }

    private func previewCanvas<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Button {
            if contentHasPreview { onExpandPreview() }
        } label: {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: self.content.kind == .archive ? 150 : 176)
                .background(Theme.insetFill)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.hairlineColor, lineWidth: 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    if contentHasPreview {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(Circle().fill(Theme.cardFill))
                            .padding(8)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(contentHasPreview ? "展开预览（空格）" : "")
    }

    private var contentHasPreview: Bool {
        switch content.preview {
        case .none, .unsupported: return false
        default: return true
        }
    }

    @ViewBuilder private var previewContent: some View {
        switch content.preview {
        case .none:
            if content.kind == .archive {
                ArchiveGlyph(size: 84).padding(.vertical, -18)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary)
            }
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
        case .text(let text):
            ScrollView {
                Text(String(text.prefix(1200)))
                    .font(.system(size: 6.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(6)
        case .pdf(let doc):
            PDFThumbnailView(document: doc)
        case .placeholder(let symbol):
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
        case .unsupported:
            Image(systemName: "eye.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func metadata(_ key: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(key)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 58, alignment: .leading)
                Text(value)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            Rectangle().fill(Theme.hairlineColor).frame(height: 1)
        }
    }
}

// MARK: - 压缩包图标（矢量近似：紫色渐变文档 + 折角 + 拉链）

struct ArchiveGlyph: View {
    var size: CGFloat = 64

    private var w: CGFloat { size * 0.78 }
    private var h: CGFloat { size }
    private var fold: CGFloat { w * 0.30 }
    private var accent: Color { Color(red: 0.529, green: 0.306, blue: 0.988) }
    private var light: Color { Color(red: 0.667, green: 0.533, blue: 0.980) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            documentShape
                .fill(
                    LinearGradient(colors: [light, accent],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay {
                    documentShape
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: accent.opacity(0.30), radius: size * 0.09, y: size * 0.045)

            // 折角
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: fold, y: 0))
                p.addLine(to: CGPoint(x: 0, y: fold))
                p.closeSubpath()
            }
            .fill(light.opacity(0.92))
            .frame(width: fold, height: fold)

            // 拉链：白色竖条 + 紫色齿
            VStack(spacing: h * 0.022) {
                ForEach(0..<7, id: \.self) { _ in
                    Capsule()
                        .fill(accent.opacity(0.90))
                        .frame(width: w * 0.115, height: h * 0.028)
                }
            }
            .frame(width: w * 0.20, height: h * 0.52)
            .background(
                RoundedRectangle(cornerRadius: w * 0.035, style: .continuous)
                    .fill(Color.white.opacity(0.95))
            )
            .padding(.top, h * 0.16)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(width: w, height: h)
    }

    private var documentShape: Path {
        Path { p in
            let r = w * 0.10
            p.move(to: CGPoint(x: 0, y: r))
            p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w - fold, y: 0))
            p.addLine(to: CGPoint(x: w, y: fold))
            p.addLine(to: CGPoint(x: w, y: h - r))
            p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: r, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
            p.closeSubpath()
        }
    }
}

// MARK: - PDF 首页缩略

private struct PDFThumbnailView: View {
    let document: PDFDocument?
    @Stored private var image: NSImage?

    init(document: PDFDocument) {
        self.document = document
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(8)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear {
            guard image == nil, let page = document?.page(at: 0) else { return }
            let bounds = page.bounds(for: .mediaBox)
            let target = NSSize(width: 320, height: 320 * bounds.height / max(bounds.width, 1))
            image = page.thumbnail(of: target, for: .mediaBox)
        }
    }
}

// MARK: - 格式描述（检查器文案）

enum ArchiveFormat {
    static func describe(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return "ZIP 压缩包" }
        if name.hasSuffix(".7z") { return "7Z 压缩包" }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "TAR.GZ 压缩包" }
        if name.hasSuffix(".tar") { return "TAR 压缩包" }
        if name.hasSuffix(".rar") { return "RAR 压缩包" }
        if name.hasSuffix(".dmg") { return "磁盘映像" }
        if name.hasSuffix(".iso") { return "ISO 磁盘映像" }
        return "压缩包"
    }

    static func fileType(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "文件" : "\(ext) 文件"
    }

    static func symbol(_ name: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp": return "photo"
        case "mp4", "mov", "m4v", "mkv", "avi": return "film"
        case "mp3", "m4a", "wav", "flac", "aac": return "music.note"
        case "pdf": return "doc.richtext"
        case "txt", "md", "json", "swift", "py", "js", "ts", "html", "css", "xml", "yml", "yaml":
            return "doc.text"
        case "doc", "docx", "pages", "rtf": return "doc.text"
        case "xls", "xlsx", "numbers", "csv": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        case "app": return "app"
        default: return "doc"
        }
    }
}
