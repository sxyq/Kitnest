import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

struct IslandRootView: View {
    @ObservedObject var controller: IslandController
    @ObservedObject private var clipboard = ClipboardManager.shared
    @ObservedObject private var local = LocalTransferStore.shared
    @Stored private var visited: Set<IslandPage> = [.clipboard]
    @Stored private var selectedFiles = Set<String>()
    @Stored private var selectionAnchor: String?
    @Stored private var transferQuery = ""
    private var transferItems: [LocalTransferItem] {
        local.items.filter { transferQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(transferQuery) }
    }

    var body: some View {
        GeometryReader { geometry in
            IslandSurface(configuration: controller.configuration, expanded: controller.expanded,
                          page: $controller.page, notchWidth: controller.notchWidth,
                          notchHeight: controller.notchHeight, height: min(controller.height, geometry.size.height),
                          onCollapse: controller.collapse, onOpen: { controller.expand(takeFocus: true) },
                          onSettings: {
                              controller.collapse(); ServiceLocator.settings?.open(pane: "island")
                          }, onFullWindow: controller.openFullWindow, onReorder: controller.reorder,
                          summary: clipboard.items.first?.displayTitle ?? "Kitnest",
                          detail: local.items.isEmpty ? "" : "\(local.items.count) 个文件") {
                VStack(spacing: 8) {
                    ZStack(alignment: .top) {
                        if visited.contains(.clipboard) {
                            VStack(spacing: 8) {
                                TextField("搜索剪贴板", text: $clipboard.searchText)
                                    .textFieldStyle(.roundedBorder)
                                ClipboardSectionView(isActive: controller.expanded && controller.page == .clipboard)
                            }.opacity(controller.page == .clipboard ? 1 : 0)
                                .allowsHitTesting(controller.page == .clipboard)
                                .accessibilityHidden(controller.page != .clipboard)
                        }
                        if visited.contains(.transfer) {
                            transfer.opacity(controller.page == .transfer ? 1 : 0)
                                .allowsHitTesting(controller.page == .transfer)
                                .accessibilityHidden(controller.page != .transfer)
                        }
                        if visited.contains(.search) {
                            ScrollView { SearchSectionView() }
                                .opacity(controller.page == .search ? 1 : 0)
                                .allowsHitTesting(controller.page == .search)
                                .accessibilityHidden(controller.page != .search)
                        }
                        if visited.contains(.calendar) {
                            CalendarSectionView(isActive: controller.expanded && controller.page == .calendar)
                                .opacity(controller.page == .calendar ? 1 : 0)
                                .allowsHitTesting(controller.page == .calendar)
                                .accessibilityHidden(controller.page != .calendar)
                        }
                        if controller.expanded && controller.page == .media { IslandMediaView() }
                        if controller.configuration.pages.isEmpty {
                            Text("在设置中选择要显示的功能")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    quickActions
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: Binding(
                get: { controller.dropping }, set: controller.targetDrop), perform: controller.acceptDrop)
            .overlay(alignment: .top) {
                if controller.dropping {
                    Label("松开，加入文件中转", systemImage: "tray.and.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                        .padding(14).background(.regularMaterial, in: Capsule())
                        .padding(.top, controller.notchHeight + 40)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: controller.page) { visited.insert($0) }
        .onExitCommand { controller.collapse() }
    }

    private var transfer: some View {
        VStack(spacing: 8) {
            if local.items.count > 4 {
                TextField("搜索文件", text: $transferQuery).textFieldStyle(.roundedBorder)
            }
            if transferItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 28, weight: .light))
                    Text(transferQuery.isEmpty ? "把文件拖到这里，随取随用" : "没有匹配的文件")
                    Text("与主面板中转共用文件；移出只清理暂存项")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                                             count: local.items.count <= 4 ? 4 : 2), spacing: 6) {
                        ForEach(transferItems) { item in
                            LocalCardRowView(item: item, selected: selectedFiles.contains(item.id),
                                isKeyboardPreviewTarget: selectionAnchor == item.id, showsCloud: false,
                                onToggleSelect: { selectFile($0, toggle: true) },
                                onSelect: { selectFile($0) }, onPickOnly: { selectedFiles = [$0] },
                                onRemove: { local.remove($0); selectedFiles.remove($0.id) },
                                sourceWindow: controller.panel, compact: local.items.count > 4)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text(selectedFiles.isEmpty ? "\(local.items.count) 个文件" : "已选 \(selectedFiles.count) 个")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if !selectedFiles.isEmpty {
                    Button("取消") { selectedFiles.removeAll() }
                    Button("复制文件") { copyFiles() }
                        .keyboardShortcut(.return, modifiers: [])
                }
            }.controlSize(.small).frame(height: 24)
            if let error = local.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private func selectFile(_ id: String, toggle: Bool = false) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift), let anchor = transferItems.firstIndex(where: { $0.id == selectionAnchor }),
           let target = transferItems.firstIndex(where: { $0.id == id }) {
            let range = Set(transferItems[min(anchor, target)...max(anchor, target)].map(\.id))
            if flags.contains(.command) { selectedFiles.formUnion(range) }
            else { selectedFiles = range }
        } else if toggle || flags.contains(.command) {
            if !selectedFiles.insert(id).inserted { selectedFiles.remove(id) }
            selectionAnchor = id
        } else { selectedFiles = [id]; selectionAnchor = id }
    }

    private func copyFiles() {
        let urls = local.items.filter { selectedFiles.contains($0.id) }.map(\.stagedURL)
        if let error = clipboard.copyFiles(urls, successMessage: "已复制 \(urls.count) 个文件") {
            Toast.show(error, icon: "exclamationmark.triangle", isWarning: true)
        } else { controller.collapse() }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            Button { controller.collapse(); ScreenshotManager.shared.captureRegion() } label: {
                Label("截图", systemImage: "camera.viewfinder")
            }
            Button { controller.collapse(); ScreenshotManager.shared.captureAndPin() } label: {
                Label("钉图", systemImage: "pin")
            }
            Button {
                controller.collapse()
                if ScreenRecorder.shared.state.isActive { Task { _ = await ScreenRecorder.shared.stop() } }
                else { ScreenRecorder.shared.startRegionRecording() }
            } label: { Label("录屏", systemImage: "record.circle") }
            Spacer(minLength: 0)
        }.font(.system(size: 11)).buttonStyle(IslandButtonStyle()).frame(height: 26)
    }
}

private struct IslandMediaView: View {
    @ObservedObject private var audio = AudioMixerController.shared
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list").font(.system(size: 28, weight: .light))
                VStack(alignment: .leading, spacing: 4) {
                    Text(audio.playingApps.first?.name ?? "没有正在输出的播放器")
                        .font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text("控制系统当前媒体会话").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 24) {
                mediaButton("上一首", icon: "backward.end.fill", key: 18)
                mediaButton("播放或暂停", icon: "playpause.fill", key: 16)
                mediaButton("下一首", icon: "forward.end.fill", key: 17)
            }
            HStack(spacing: 10) {
                Button { audio.outputMuted.toggle() } label: {
                    Image(systemName: audio.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }.help("静音或恢复音量")
                Slider(value: $audio.outputVolume, in: 0...1).accessibilityLabel("系统输出音量")
                Text("\(Int(audio.outputVolume * 100))%")
                    .monospacedDigit().font(.system(size: 11)).frame(width: 36)
            }
            Picker("输出设备", selection: $audio.selectedDevice) {
                ForEach(audio.devices) { Text($0.name).tag(Optional($0.id)) }
            }.controlSize(.small)
        }.padding(.vertical, 10).buttonStyle(IslandButtonStyle())
        .onAppear { audio.startRefreshing() }
        .onDisappear { audio.stopRefreshing() }
    }

    private func mediaButton(_ title: String, icon: String, key: Int) -> some View {
        Button {
            guard AXIsProcessTrusted() else {
                Toast.show("系统媒体控制需要 Kitnest 辅助功能权限", icon: "exclamationmark.triangle", isWarning: true)
                return
            }
            for state in [0xA, 0xB] {
                let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                    subtype: 8, data1: (key << 16) | (state << 8), data2: -1)
                event?.cgEvent?.post(tap: .cghidEventTap)
            }
        } label: { Image(systemName: icon).font(.system(size: 22)).frame(width: 40, height: 40) }
            .help(title).accessibilityLabel(title)
    }
}
