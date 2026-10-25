import AppKit
import Combine
import Foundation

// MARK: - 归档编辑撤销/重做栈（v127（ArcZip P0/P1）：ArcZip「编辑撤销/重做」ChangeSet 同款思路）
//
// 每次**修改前**捕获可逆信息，形成一条 `ArchiveChange`：
//   · 删除前  → extractEntryToTemp 备份内容（目录展开为其中每个文件），undo=按原路径写回
//   · 添加前  → 复制新增文件到临时目录，undo=removeEntries
//   · 重命名前 → 记旧/新包内完整路径，undo=再 rename 回去
//   · 保存草稿前 → 记旧文本，undo=写回旧文本
//
// 一条 change 自身携带**双向**数据：undo() 执行逆操作后把同一条放回 redo 栈，
// redo() 再执行正向操作——和 NSUndoManager 的「注册补偿操作」等价，但显式建模。
// 备份文件放临时目录（随包生命周期），超大条目（>48MB）不备份、该项不可撤销。

/// 一次可逆的归档编辑
public enum ArchiveChange {

    /// 可写回的内容快照（path = 归档内路径；tempURL = 本地备份）
    public struct Snapshot {
        public let path: String
        public let tempURL: URL
        public init(path: String, tempURL: URL) {
            self.path = path
            self.tempURL = tempURL
        }
    }

    /// 删除（undo=写回 / redo=按原根路径再删——目录删的是子树，不能只删快照里的文件）
    case delete(items: [Snapshot], roots: [String])
    /// 添加（undo=删掉新增 / redo=再写回）
    case add(items: [Snapshot])
    /// 重命名（from/to = 归档内完整路径；undo=改回 / redo=改去）
    case rename(from: String, to: String)
    /// 文本条目修改（undo=写回旧文本 / redo=写回新文本）
    case editText(path: String, oldText: String, newText: String)

    /// 「撤销 %@」里的动作名（ArcZip edit.undo 菜单标题同款语义）
    public var label: String {
        switch self {
        case .delete(_, let roots):
            if roots.count == 1, let first = roots.first {
                return "删除 \((first as NSString).lastPathComponent)"
            }
            return "删除 \(roots.count) 项"
        case .add(let items):
            if let first = items.first, items.count == 1 { return "添加 \((first.path as NSString).lastPathComponent)" }
            return "添加 \(items.count) 项"
        case .rename(let from, _):
            return "重命名 \((from as NSString).lastPathComponent)"
        case .editText(let path, _, _):
            return "修改 \((path as NSString).lastPathComponent)"
        }
    }
}

/// 撤销/重做栈：持有归档 URL，undo()/redo() 直接把变更施加回归档
public final class ArchiveUndoStack: ObservableObject {

    /// 「撤销 %@」按钮/菜单用：可撤销、可重做、动作名
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    @Published public private(set) var undoLabel = ""
    @Published public private(set) var redoLabel = ""

    private let url: URL
    private var undoItems: [ArchiveChange] = []
    private var redoItems: [ArchiveChange] = []
    /// 施加变更是异步的，进行中忽略新的 undo/redo 请求（防双击弹栈错位）
    private var busy = false
    /// undo/redo 完成后回调（模型里负责 reload()）
    public var onApplied: (() -> Void)?

    public init(url: URL) {
        self.url = url
    }

    /// 记录一次新修改（清空重做历史）
    public func push(_ change: ArchiveChange) {
        undoItems.append(change)
        redoItems.removeAll()
        refresh()
    }

    public func undo() {
        guard !busy, let change = undoItems.last else { return }
        busy = true
        apply(change, undo: true) { [weak self] ok, msg in
            guard let self else { return }
            self.busy = false
            if ok {
                self.undoItems.removeLast()
                self.redoItems.append(change)
                self.refresh()
                Toast.show("已撤销：\(change.label)", icon: "arrow.uturn.backward")
                self.onApplied?()
            } else {
                Toast.show("撤销失败：\(msg)", icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }

    public func redo() {
        guard !busy, let change = redoItems.last else { return }
        busy = true
        apply(change, undo: false) { [weak self] ok, msg in
            guard let self else { return }
            self.busy = false
            if ok {
                self.redoItems.removeLast()
                self.undoItems.append(change)
                self.refresh()
                Toast.show("已重做：\(change.label)", icon: "arrow.uturn.right")
                self.onApplied?()
            } else {
                Toast.show("重做失败：\(msg)", icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }

    private func refresh() {
        canUndo = !undoItems.isEmpty
        canRedo = !redoItems.isEmpty
        undoLabel = undoItems.last?.label ?? ""
        redoLabel = redoItems.last?.label ?? ""
    }

    // MARK: 施加变更（undo = 逆操作，redo = 正操作）

    private func apply(_ change: ArchiveChange, undo: Bool, completion: @escaping (Bool, String) -> Void) {
        switch change {
        case .delete(let items, let roots):
            if undo {
                restore(items, 0, completion)
            } else {
                remove(roots, completion)
            }
        case .add(let items):
            if undo {
                remove(items.map { $0.path }, completion)
            } else {
                restore(items, 0, completion)
            }
        case .rename(let from, let to):
            // 当前包内路径：撤销时条目在 to，重做时在 from
            let current = undo ? to : from
            let target = undo ? from : to
            ArchiveCore.renameEntry(url: url, entryPath: current,
                                    newName: (target as NSString).lastPathComponent) { ok, msg in
                completion(ok, msg)
            }
        case .editText(let path, let oldText, let newText):
            writeText(path: path, text: undo ? oldText : newText, completion: completion)
        }
    }

    /// 按原路径逐个写回快照（7zz a 原地补条目；目录条目会随文件路径自动重建）
    private func restore(_ items: [ArchiveChange.Snapshot], _ index: Int,
                         _ completion: @escaping (Bool, String) -> Void) {
        guard index < items.count else {
            completion(true, "已恢复 \(items.count) 项")
            return
        }
        let item = items[index]
        ArchiveCore.updateEntry(url: url, entryPath: item.path, localFile: item.tempURL) { ok, msg in
            if ok {
                self.restore(items, index + 1, completion)
            } else {
                completion(false, msg)
            }
        }
    }

    private func remove(_ paths: [String], _ completion: @escaping (Bool, String) -> Void) {
        guard !paths.isEmpty else {
            completion(true, "没有可删除的条目")
            return
        }
        ArchiveCore.removeEntries(url: url, entryPaths: paths) { ok, msg in
            completion(ok, msg)
        }
    }

    /// 把一段文本写回归档内指定路径（编辑撤销/重做用）
    private func writeText(path: String, text: String, completion: @escaping (Bool, String) -> Void) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("frset-undo-\(UUID().uuidString)-\((path as NSString).lastPathComponent)")
        do {
            try text.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            completion(false, "写入临时文件失败：\(error.localizedDescription)")
            return
        }
        ArchiveCore.updateEntry(url: url, entryPath: path, localFile: tmp) { ok, msg in
            try? FileManager.default.removeItem(at: tmp)
            completion(ok, msg)
        }
    }
}
