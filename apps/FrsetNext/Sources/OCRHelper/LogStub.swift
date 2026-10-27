import Foundation

/// 日志桩：helper 只复用 PPOCROCR.swift 的识别实现，不链接 App 的 Log。
/// 信息级丢掉（谁也不想在 stderr 里刷正常路径），告警/错误写 stderr 便于排障。
enum Log {
    static func debug(_ category: String, _ message: String) {}
    static func info(_ category: String, _ message: String) {}
    static func warn(_ category: String, _ message: String) {
        FileHandle.standardError.write(Data("[warn][\(category)] \(message)\n".utf8))
    }
    static func error(_ category: String, _ message: String) {
        FileHandle.standardError.write(Data("[error][\(category)] \(message)\n".utf8))
    }
}
