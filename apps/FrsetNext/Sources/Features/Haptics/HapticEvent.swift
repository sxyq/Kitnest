import AppKit

/// 真实业务事件（18 类）。
///
/// `rawValue` 会写进用户配置（`disabledEvents`）；旧配置中的已移除事件会被忽略。
/// 这里只描述「发生了什么」，不涉及任何设备调用；节奏与强弱由 `HapticPatternClass` 决定。
enum HapticEvent: String, Codable, CaseIterable, Sendable {
    case gridMove, gridResize, layoutSaved, copy, screenshot, ocr
    case recordingStarted, recordingSaved
    case airDropCompleted = "transferCompleted"
    case downloadCompleted, transferFailed
    case aiCompleted, searchCompleted, deviceConnected, deviceDisconnected, operationFailed
    case mediaPlayPause, volumeBoundary
}

/// 反馈类型：决定节奏（单次 / 双次）、强弱上限与去重窗口。
///
/// 硬件只有三档波形（3 轻 / 4 中 / 6 重），所以这里刻意只分四类，
/// 不做「18 个事件 18 种波形」——那既做不到，也会让手感变得不可预期。
enum HapticPatternClass: Sendable {
    /// 高频边界事件：网格吸附、尺寸切档、音量到边界等。单次、强度封顶「中」。
    case boundary
    /// 一次性操作成功：复制、截图、OCR、下载完成等。单次。
    case success
    /// 重要任务完成：录制保存、AI 回复完成。双次，间隔略长。
    case milestone
    /// 失败与异常：操作失败、下载失败。双次、间隔更短，强度不低于「中」。
    case failure
}

extension HapticEvent {
    var patternClass: HapticPatternClass {
        switch self {
        case .gridMove, .gridResize, .mediaPlayPause, .volumeBoundary:
            return .boundary
        case .copy, .screenshot, .ocr, .recordingStarted, .layoutSaved,
             .airDropCompleted, .downloadCompleted, .searchCompleted, .deviceConnected, .deviceDisconnected:
            return .success
        case .recordingSaved, .aiCompleted:
            return .milestone
        case .operationFailed, .transferFailed:
            return .failure
        }
    }

    /// 设置页与日志用；不参与持久化。
    var settingTitle: String {
        switch self {
        case .gridMove: return "网格吸附"
        case .gridResize: return "组件尺寸切档"
        case .layoutSaved: return "布局保存成功"
        case .copy: return "主动复制成功"
        case .screenshot: return "截图完成"
        case .ocr: return "文字识别完成"
        case .recordingStarted: return "录制开始"
        case .recordingSaved: return "录制保存完成"
        case .airDropCompleted: return "隔空投送完成"
        case .downloadCompleted: return "下载完成"
        case .transferFailed: return "隔空投送或下载失败"
        case .aiCompleted: return "AI 输出完成"
        case .searchCompleted: return "搜索完成"
        case .deviceConnected: return "设备接入"
        case .deviceDisconnected: return "设备断开"
        case .operationFailed: return "操作失败"
        case .mediaPlayPause: return "播放/暂停"
        case .volumeBoundary: return "音量到边界"
        }
    }

    var settingDetail: String {
        switch self {
        case .gridMove: return "组件进入新的网格位置"
        case .gridResize: return "组件切换到另一种网格尺寸"
        case .layoutSaved: return "点击完成并成功保存布局"
        case .copy: return "点击复制或使用复制快捷键"
        case .screenshot: return "截图完成并可供使用"
        case .ocr: return "OCR 识别结果准备完成"
        case .recordingStarted: return "录制正式开始"
        case .recordingSaved: return "录制文件成功保存"
        case .airDropCompleted: return "通过系统隔空投送发送文件"
        case .downloadCompleted: return "下载文件成功保存"
        case .transferFailed: return "隔空投送失败或下载中断"
        case .aiCompleted: return "模型生成结束并出现完整回复"
        case .searchCompleted: return "搜索结果准备完成"
        case .deviceConnected: return "设备成功建立连接"
        case .deviceDisconnected: return "已连接设备断开连接"
        case .operationFailed: return "操作失败、权限不足或系统拒绝"
        case .mediaPlayPause: return "主动切换媒体播放状态"
        case .volumeBoundary: return "音量到达最小值或最大值"
        }
    }

    /// 设置页分组（顺序即展示顺序）。
    static let settingGroups: [(title: String, events: [HapticEvent])] = [
        ("布局与复制", [.gridMove, .gridResize, .layoutSaved, .copy]),
        ("截图与录制", [.screenshot, .ocr, .recordingStarted, .recordingSaved]),
        ("文件与下载", [.airDropCompleted, .downloadCompleted, .transferFailed]),
        ("AI、搜索与设备", [.aiCompleted, .searchCompleted, .deviceConnected, .deviceDisconnected]),
        ("提醒与媒体", [.operationFailed, .mediaPlayPause, .volumeBoundary])
    ]
}
