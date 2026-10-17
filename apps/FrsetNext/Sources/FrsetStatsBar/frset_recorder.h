// frset_recorder.h — 录屏（ScreenCaptureKit + AVAssetWriter）
//
// 移植自逆向版注入层 frset_recorder.m（v47–v62，原样编译，行为一致）：
//   入口链：截图菜单「录屏」→ 录屏设置小窗（毛玻璃）→ 开始录制 → 计时窗 → 停止
//   设置项：帧率 / 分辨率 / 区域（整屏 or 拖拽选区）/ 声音（无·系统音·麦克风·系统+麦克）/
//           格式（MOV·MP4）/ 保存目录（默认影片，可改）
//   管线：SCStream(display filter + sourceRect) → CMSampleBuffer → AVAssetWriter(H.264 + AAC)
//   参数持久化：widgets.plist（键 "Recorder_*"，与注入版共用同一文件）
#import <Cocoa/Cocoa.h>

void FSScreenRecOpenSettings(void);       // 打开录屏设置小窗（菜单「录屏」调用）
void FSScreenRecCloseSettings(void);      // 关闭设置小窗
void FSScreenRecBeginFromSettings(void);  // 按当前设置开始录制（设置窗「开始录制」调用）
void FSScreenRecStart(void);              // 直接开录（默认设置）
void FSScreenRecStop(void);               // 停止并收尾（计时窗「停止」调用）
BOOL FSScreenRecIsRunning(void);          // 录中（含启动中）
BOOL FSRegionOverlayIsActive(void);       // 区域框选进行中（供浮动层让路）
