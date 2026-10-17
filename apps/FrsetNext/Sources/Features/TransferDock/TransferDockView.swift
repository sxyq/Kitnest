import AppKit
import SwiftUI

// MARK: - 中转站（面板第三页）
//
// 定位：文件暂存与转发——把文件丢上去，在别的设备/场合再取回。
// 版式沿用性能页：12/13pt 字号、14 圆角卡片、细线分隔；不引入新的视觉语言。
//
// 数据来自 TransferDockService（背后是 OPPO 中转站工程的 Python 桥接）。

struct TransferDockView: View {
    @ObservedObject private var service = TransferDockService.shared
    @Stored private var showsLogin = false
    @Stored private var isDropTargeted = false
    @Stored private var hoveredFileID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if service.loggedIn {
                spaceSection
                Divider().opacity(0.5)
                fileList
            } else {
                emptyState
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { service.refresh() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted { dropHint }
        }
        .sheet(isPresented: $showsLogin) {
            TransferDockLoginView(
                onCancel: { showsLogin = false },
                onLoggedIn: {
                    showsLogin = false
                    service.refresh()
                })
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right.square")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("文件中转")
                .font(.system(size: 13, weight: .semibold))
            if service.loggedIn {
                Text("已登录")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())
            }
            Spacer(minLength: 6)
            Button {
                service.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(service.isLoading)
            .help("刷新")

            Button {
                showsLogin = true
            } label: {
                Image(systemName: service.loggedIn ? "person.crop.circle" : "person.crop.circle.badge.plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help(service.loggedIn ? "重新登录" : "登录")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    // MARK: 空间

    private var spaceSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(service.spaceText.isEmpty ? "空间信息读取中…" : service.spaceText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if !service.files.isEmpty {
                    Text("\(service.files.count) 个文件")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: geo.size.width * service.spaceRatio)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 文件列表

    private var fileList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                if service.files.isEmpty && !service.isLoading {
                    Text("还没有文件，拖一个进来试试")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
                ForEach(service.files) { file in
                    row(file)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ file: TransferDockFile) -> some View {
        let hovered = hoveredFileID == file.id
        return HStack(spacing: 10) {
            Image(systemName: iconName(for: file.name))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.sizeText) · \(file.dateText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hovered {
                HStack(spacing: 10) {
                    iconButton("arrow.down.circle", help: "下载") { service.download(file) }
                    iconButton("trash", help: "删除") { service.delete(file) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.02))
        }
        .contentShape(Rectangle())
        .onHover { inside in hoveredFileID = inside ? file.id : nil }
        .onTapGesture(count: 2) { service.download(file) }
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconName(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "webp", "gif", "heic": return "photo"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox"
        case "md", "txt", "json", "xml", "csv": return "doc.text"
        case "swift", "py", "js", "ts", "c", "cpp", "m", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    // MARK: 空态（未登录）

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有登录文件中转")
                .font(.system(size: 13, weight: .medium))
            Text(service.errorMessage ?? "登录一次即可长期使用，之后会自动续期")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 24)
            Button {
                showsLogin = true
            } label: {
                Text("登录 / 重新登录")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            if service.isUploading {
                ProgressView().controlSize(.small)
            }
            Text(statusText)
                .font(.system(size: 10.5))
                .foregroundStyle(service.errorMessage == nil ? .secondary : .primary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                pickAndUpload()
            } label: {
                Text("上传")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!service.loggedIn || service.isUploading)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private var statusText: String {
        if let error = service.errorMessage { return error }
        if !service.statusMessage.isEmpty { return service.statusMessage }
        if let synced = service.lastSyncedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return "上次同步 \(formatter.string(from: synced))"
        }
        return service.loggedIn ? "就绪" : "未登录"
    }

    // MARK: 拖放与选择

    private var dropHint: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.45),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            VStack(spacing: 8) {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
                Text("松手上传到中转站")
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard service.loggedIn, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let direct = item as? URL {
                url = direct
            }
            guard let fileURL = url else { return }
            DispatchQueue.main.async { service.upload(url: fileURL) }
        }
        return true
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "上传"
        if panel.runModal() == .OK, let url = panel.url {
            service.upload(url: url)
        }
    }
}
