import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 文件盒 / 暂存架（v127（ArcZip P3）：P3-2）
//
// 菜单栏暂存浮窗：把散落的文件拖进来集中处理，再一次「压缩全部…」。
// 做到了：拖入收集（NSDraggingDestination）/ 8 种颜色 + 背景浓度（右键菜单）/
//        闲置自动收起（简化为闲置 N 秒自动关闭，拖放进行中暂停计时）/
//        剪贴板添加（读 NSPasteboard 文件 URL）/ 来源权限提示（不可读文件标注）/
//        压缩全部 → ArchiveCreateWindowController.show(files:)（只读调用既有创建面板）。
//
// 入口：深链 frsetnext://archive?action=filebox（FrsetNextApp 分流）。
// v127（ArcZip P3）：全局快捷键未做——本工程快捷键集中在 Shortcuts 模块的注册表中，
// 为避免与既有注册点冲突，仅提供深链入口（任务允许的简化项）。
// 不是状态栏项：避免与既有 StatusBarController 的 STATS 合并条冲突（独立 NSPanel）。

// MARK: - 颜色偏好（v127（ArcZip P3）：8 色 + 浓度，右键菜单切换）

enum ArchiveFileBoxTint: Int, CaseIterable, Identifiable {
    case blue, gray, green, lavender, orange, pink, red, yellow

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .blue: return "蓝"
        case .gray: return "灰"
        case .green: return "绿"
        case .lavender: return "淡紫"
        case .orange: return "橙"
        case .pink: return "粉"
        case .red: return "红"
        case .yellow: return "黄"
        }
    }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.24, green: 0.51, blue: 0.96)
        case .gray: return Color(red: 0.55, green: 0.57, blue: 0.60)
        case .green: return Color(red: 0.22, green: 0.72, blue: 0.42)
        case .lavender: return Color(red: 0.66, green: 0.55, blue: 0.96)
        case .orange: return Color(red: 0.98, green: 0.55, blue: 0.18)
        case .pink: return Color(red: 0.96, green: 0.42, blue: 0.66)
        case .red: return Color(red: 0.92, green: 0.30, blue: 0.28)
        case .yellow: return Color(red: 0.96, green: 0.78, blue: 0.22)
        }
    }
}

private enum FileBoxPrefs {
    static let tintKey = "archive.fileBox.tint"
    static let opacityKey = "archive.fileBox.opacity"
    static let idleCloseKey = "archive.fileBox.idleClose"

    static var tint: ArchiveFileBoxTint {
        get { ArchiveFileBoxTint(rawValue: UserDefaults.standard.integer(forKey: tintKey)) ?? .blue }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: tintKey) }
    }

    static var opacity: Double {
        get {
            let v = UserDefaults.standard.double(forKey: opacityKey)
            return v == 0 ? 0.88 : v
        }
        set { UserDefaults.standard.set(newValue, forKey: opacityKey) }
    }

    static var idleClose: Bool {
        get { UserDefaults.standard.object(forKey: idleCloseKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: idleCloseKey) }
    }
}

// MARK: - 模型

struct ArchiveFileBoxItem: Identifiable, Equatable {
    let id: String            // 标准化路径
    let url: URL
    let name: String
    let sizeText: String
    /// v127（ArcZip P3）：来源权限提示——文件当前不可读（TCC/权限拦截）时标注
    let isReadable: Bool
}

final class ArchiveFileBoxModel: ObservableObject {
    @Published var items: [ArchiveFileBoxItem] = []

    // v128（内存优化）：暂存盒上限 64 项——拖入/粘贴无上限时数组只涨不落，
    // 超出丢弃最旧（盒是「待压缩暂存」语义，旧项价值随时间递减）。
    static let maxItems = 64

    /// 追加（按标准化路径去重）
    func add(urls: [URL]) {
        for url in urls {
            let std = url.standardizedFileURL
            let key = std.path
            guard !items.contains(where: { $0.id == key }) else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: std.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            items.append(ArchiveFileBoxItem(
                id: key, url: std, name: std.lastPathComponent,
                sizeText: ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                isReadable: FileManager.default.isReadableFile(atPath: std.path)))
            // v128（内存优化）：超上限丢弃最旧
            if items.count > Self.maxItems {
                items.removeFirst(items.count - Self.maxItems)
            }
        }
    }

    /// v127（ArcZip P3）：从剪贴板添加文件 URL
    func addFromPasteboard() {
        let pb = NSPasteboard.general
        let urls = pb.readObjects(forClasses: [NSURL.self],
                                  options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty {
            Toast.show("剪贴板里没有文件", icon: "doc.on.clipboard", isWarning: true)
            return
        }
        add(urls: urls)
        Toast.show("已从剪贴板添加 \(urls.count) 个文件", icon: "doc.on.clipboard")
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
    }

    func clear() {
        items.removeAll()
    }

    /// v127（ArcZip P3）：压缩全部 → 交给既有创建压缩包面板（预设/分卷/密码都在那边）
    func compressAll() {
        guard !items.isEmpty else {
            Toast.show("文件盒是空的，先拖入文件", icon: "archivebox", isWarning: true)
            return
        }
        ArchiveCreateWindowController.show(files: items.map { $0.url })
    }

    /// 来源权限提示汇总
    var unreadableCount: Int { items.filter { !$0.isReadable }.count }
}

// MARK: - 浮窗内容

struct ArchiveFileBoxView: View {
    @ObservedObject var model: ArchiveFileBoxModel
    /// v127（ArcZip P3）：@Stored 偏好（8 色 + 浓度），onChange 落盘 UserDefaults
    @Stored private var tint: ArchiveFileBoxTint = FileBoxPrefs.tint
    @Stored private var opacity: Double = FileBoxPrefs.opacity
    @Stored private var idleClose: Bool = FileBoxPrefs.idleClose
    /// 任意交互回调（重置闲置计时）
    var onActivity: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if model.items.isEmpty {
                emptyHint
            } else {
                fileList
            }
            if model.unreadableCount > 0 {
                permissionHint
            }
        }
        .frame(width: 300, height: 360)
        .background(tint.color.opacity(0.10 * (opacity / 0.88)))
        .contextMenu { menu }
        .onChange(of: tint) { FileBoxPrefs.tint = $0; onActivity() }
        .onChange(of: opacity) { FileBoxPrefs.opacity = $0; onActivity() }
        .onChange(of: idleClose) { FileBoxPrefs.idleClose = $0; onActivity() }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(tint.color)
            Text("文件盒")
                .font(.system(size: 11, weight: .semibold))
            Text("\(model.items.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            miniButton("plus", help: "从剪贴板添加") { model.addFromPasteboard() }
            miniButton("trash", help: "清空") { model.clear() }
            miniButton("xmark", help: "关闭") {
                NSApp.keyWindow?.close()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    // MARK: 列表

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.items) { item in
                    row(item)
                }
            }
            .padding(4)
        }
    }

    private func row(_ item: ArchiveFileBoxItem) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: icon(for: item.name))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.sizeText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            if !item.isReadable {
                // v127（ArcZip P3）：来源权限提示——不可读文件标注原因
                Image(systemName: "lock.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("无法读取：可能被「文件与文件夹」权限拦截，或文件已被移走")
            }
            miniButton("minus.circle", help: "移出") { model.remove(id: item.id) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .help(item.url.path)
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc.on.clipboard")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("把文件拖进来集中处理")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("或点「+」从剪贴板添加")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text("\(model.unreadableCount) 个文件不可读，压缩前请检查权限（系统设置 → 隐私与安全性 → 文件与文件夹）")
                .font(.system(size: 11))
                .lineLimit(2)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: 右键菜单（颜色 / 浓度 / 闲置行为）

    private var menu: some View {
        Group {
            Section("颜色") {
                ForEach(ArchiveFileBoxTint.allCases) { t in
                    Button {
                        tint = t
                    } label: {
                        HStack {
                            Text(t.name)
                            if tint == t { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Section("背景浓度") {
                Slider(value: $opacity, in: 0.35...1.0) { _ in
                    onActivity()
                }
                Text("浓度 \(Int(opacity * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Section("闲置行为") {
                Toggle("闲置 30 秒后自动关闭", isOn: $idleClose)
            }
        }
    }

    // MARK: 小件

    private func miniButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: { onActivity(); action() }) {
            Image(systemName: name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func icon(for name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        let ut = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        return NSWorkspace.shared.icon(for: ut ?? .data)
    }
}

// v127（ArcZip P3）：底部「压缩全部…」挂在 ArchiveFileBoxWindow.buildContent 的窗口层，
// 不在 ArchiveFileBoxView 内（避免与右键菜单争焦点区域）。

// MARK: - 浮窗（NSPanel：无标题栏、圆角、可拖动、拖入文件）

public final class ArchiveFileBoxWindow: NSPanel, NSDraggingDestination {

    // v127（ArcZip P3）：单例——文件盒全局只有一份
    public private(set) static var shared: ArchiveFileBoxWindow?

    public static func show() {
        if let existing = shared {
            existing.makeKeyAndOrderFront(nil)
            existing.restartIdleTimer()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = ArchiveFileBoxWindow()
        shared = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let model = ArchiveFileBoxModel()
    /// v127（ArcZip P3）：闲置计时（拖放进行中暂停，交互重置）
    private var idleTimer: Timer?
    private var dragInProgress = false

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true   // 无标题栏窗口可直接拖动
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // v127（ArcZip P3）：接受拖入的文件 URL
        registerForDraggedTypes([.fileURL])
        buildContent()
        restartIdleTimer()
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    private func buildContent() {
        let model = self.model
        let view = VStack(spacing: 0) {
            ArchiveFileBoxView(model: model) { [weak self] in
                self?.restartIdleTimer()
            }
            Divider()
            // v127（ArcZip P3）：底部「压缩全部…」
            HStack {
                Button("压缩全部…") { model.compressAll() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true
        contentView = hosting
    }

    // MARK: 闲置自动收起（v127（ArcZip P3）：简化为闲置 N 秒自动关闭）

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        guard FileBoxPrefs.idleClose else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, !self.dragInProgress else { return }
            self.orderOut(nil)
        }
    }

    // MARK: NSDraggingDestination（拖入文件）

    public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragInProgress = true
        idleTimer?.invalidate()      // v127（ArcZip P3）：拖放时暂停计时
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true])
            ? .copy : []
    }

    public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    public func draggingExited(_ sender: NSDraggingInfo?) {
        dragInProgress = false
        restartIdleTimer()
    }

    public func draggingEnded(_ sender: NSDraggingInfo) {
        dragInProgress = false
        restartIdleTimer()
    }

    public func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        model.add(urls: urls)
        restartIdleTimer()
        return true
    }

    // MARK: 关闭时清单例

    public override func close() {
        idleTimer?.invalidate()
        Self.shared = nil
        super.close()
    }
}

// MARK: - 拖入目标（view 层补充：NSPanel 面积有限，整窗拖入即可）

// v127（ArcZip P3）：说明——拖入直接由 ArchiveFileBoxWindow（NSDraggingDestination）接收，
// SwiftUI 内容无需再挂 .onDrop，避免两套拖入路径互相抢事件。
