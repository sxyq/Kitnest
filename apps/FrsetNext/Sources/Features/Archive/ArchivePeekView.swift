import SwiftUI
import UniformTypeIdentifiers

// MARK: - 归档内嵌预览（v118 初版 / v121 重做：图标网格）
//
// 用户要求（v121）：「展现内部的文件，一个一个的那种文件图标，就是原本这个文件
// 该有什么图标，就一个个去展现」。
//
// 所以这一版把上一版的「小 SF Symbol + 一列文字」换成 **图标网格**：
//   · 每个条目用**系统真实类型图标** —— NSWorkspace.icon(for: UTType)
//     （docx 就是 Word 的图标、pptx 是 PPT 的、xlsx 是表格、apk 是安卓、
//      图片/视频/PDF 各按自己的类型，和 Finder 里看到的一致）；
//   · 目录排在最前，用文件夹图标；
//   · 名字两行截断，下面是大小；
//   · 自适应列（气泡宽度变化时自动 3~5 列），不写死列数以免挤爆。

struct ArchivePeekView: View {

    let path: String
    var maxRows: Int = 36

    @Stored private var entries: [ArchiveEntry] = []
    @Stored private var loading = true
    @Stored private var errorText: String?

    private var totalSize: Int64 { entries.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size } }
    private var packedSize: Int64 { entries.filter { !$0.isDirectory }.reduce(0) { $0 + $1.packedSize } }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("读取归档…").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                }
            } else if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                // 概要行
                HStack(spacing: 6) {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("\(entries.count) 项")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if totalSize > 0 {
                        Text("\(byteText(totalSize)) → \(byteText(packedSize))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    Spacer(minLength: 0)
                }

                // 条目网格：每个文件用自己的类型图标
                LazyVGrid(
                    // v121 调整：气泡内容宽约 340pt，min 62 → 一行 5 个
                    //（原来 min 58 会挤成 7 个，图标和名字都糊在一起）
                    // v121 二次调整：气泡实际是 720×620（不是 420），
                    // min 72 → 一行 9 个，图标 36pt，能把归档内容铺开而不是挤成一条
                    columns: [GridItem(.adaptive(minimum: 84, maximum: 104), spacing: 8)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(previewEntries) { e in
                        ArchiveEntryTile(entry: e, archivePath: path)
                    }
                }
                .padding(6)
                .background(Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))

                if entries.count > previewEntries.count {
                    Text("还有 \(entries.count - previewEntries.count) 项…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var previewEntries: [ArchiveEntry] {
        // 目录优先、再按路径排序，取前 maxRows 条
        let dirs = entries.filter { $0.isDirectory }
        let files = entries.filter { !$0.isDirectory }
        return Array((dirs + files).prefix(maxRows))
    }

    private func load() {
        ArchiveCore.list(url: URL(fileURLWithPath: path)) { list, err in
            loading = false
            errorText = err
            entries = list
        }
    }

    private func byteText(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
    }
}

// MARK: - 单个条目（图标 + 名字 + 大小）

struct ArchiveEntryTile: View {
    let entry: ArchiveEntry
    /// 所属归档路径（用来解出条目内容做缩略图）；空则只显示类型图标
    var archivePath: String = ""
    // v127（ArcZip P1）：尺寸可调——悬停气泡默认 46，归档浏览窗图标视图 64
    var size: CGFloat = 46

    @Stored private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 2) {
            // v123：能出内容的（图片/PDF/Office/文本/视频）显示真实缩略图，
            // 其余仍用类型图标——等价于 ArcZip 的分级解码，只是放在悬停气泡里
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
            } else {
                Image(nsImage: ArchiveFileIcon.icon(for: entry))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.78, height: size * 0.78)
            }
            Text(entry.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
            Text(entry.sizeText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .help(entry.path)
        .onAppear(perform: loadThumbnail)
        // v127 接线（arch-engine P2-3）：不安全路径角标（../ 穿越 / 绝对路径 / 设备名）
        .overlay(alignment: .topTrailing) {
            if entry.isUnsafe {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(2)
                    .help("路径不安全（../ 穿越 / 绝对路径 / 设备名）。穿越与绝对路径解压时拦截跳过，设备名仅警告（v127.1）")
            }
        }
    }

    private func loadThumbnail() {
        guard thumb == nil, !archivePath.isEmpty,
              ArchiveEntryThumbnail.canRender(entry.name) else { return }
        ArchiveEntryThumbnail.load(archive: URL(fileURLWithPath: archivePath),
                                   entry: entry, size: size) { image in
            // v128（内存优化）：包 autoreleasepool——缩略图批量生成循环（LazyVStack
            // 每行 onAppear 触发）的回调在主线程成批执行，临时桥接对象显式 drain
            autoreleasepool {
                if let image { thumb = image }
            }
        }
    }
}

// MARK: - 归档条目的系统类型图标（不依赖文件落盘，带缓存）

enum ArchiveFileIcon {

    // v128（内存优化）：原无界 [String: NSImage] 字典按扩展名无限增长（同款问题
    // NSCache 治理）；换 NSCache<NSString, NSImage> + countLimit=256——扩展名种类
    // 有限，256 足够且自动响应内存压力。NSCache 线程安全，原 NSLock 一并去掉。
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let genericIcon = NSWorkspace.shared.icon(for: .data)

    /// 按扩展名取系统为该类型注册的图标（和 Finder 里一致）
    static func icon(for entry: ArchiveEntry) -> NSImage {
        if entry.isDirectory { return folderIcon }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return genericIcon }

        let key = ext as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let image: NSImage
        if let ut = UTType(filenameExtension: ext) {
            image = NSWorkspace.shared.icon(for: ut)
        } else {
            image = genericIcon
        }

        cache.setObject(image, forKey: key)
        return image
    }
}
