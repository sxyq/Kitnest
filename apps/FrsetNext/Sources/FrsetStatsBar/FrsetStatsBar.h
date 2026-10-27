// FrsetStatsBar.h — 桥接头：把 ObjC/C 部件引擎与数据层暴露给 Swift
// ============================================================================
// 用法（Swift 侧）：import FrsetStatsBar 后直接调用：
//   · FSStatsTickStart() / FSStatsTickStop()          引擎启停
//   · FSStatsSetOpenMonitorHandler { module in ... }  点击部件 → 打开监测页
//   · FSBarSettingsOpen()                             打开 Stats 风格部件设置窗
//   · frset_gpu_usage / frset_disk_smart / frset_net_top / frset_conn_sample …
//      监测面板的深层数据（GPU/NVMe SMART/高占用进程/网络连通性）
//
// 配置存储：~/Library/Application Support/FrsetStats/widgets.plist
// （与注入版共用同一文件 → 自动继承用户现有配置；首启无文件时从
//   eu.exelban.Stats 偏好导入，键名与 Stats 完全一致）
// ============================================================================
#ifndef FRSET_STATS_BAR_H
#define FRSET_STATS_BAR_H

#import <Cocoa/Cocoa.h>

// 部件引擎（设置存储 / 12 种形态绘制 / 状态项管理 / 合并条）
#import "frset_barwidgets.h"
// 数据采集层（C：SMC / CPU / 内存 / 网络 / 磁盘 / 电池 / GPU / SMART / 连通性）
#import "frset_stats_data.h"
// 传感器官方名表（212 项 key→名/分组/类型）
#import "frset_sensor_names.h"
// 录屏（SCStream + AVAssetWriter；设置小窗 / 计时窗 / 区域框选，行为同注入版）
#import "frset_recorder.h"

// 采样 tick 生命周期（frset_stats_tick.m）
void FSStatsTickStart(void);
void FSStatsTickStop(void);

// 点击部件回调桥：module = CPU0 内存1 GPU2 磁盘3 网络4 传感器5 电池6
typedef void (*FSBarOpenMonitorFn)(int module);
void FSStatsSetOpenMonitorHandler(FSBarOpenMonitorFn fn);

// 合并条状态项按钮（popover 锚点；引擎未建项时为 nil）
NSStatusBarButton *FSBarMergedButton(void);

// v32/v34 移植（注入版）：奔跑小猫主图标开关（设置窗「菜单栏图标 · 小猫」用）
BOOL FSRunCatIconEnabled(void);
void FSRunCatIconSetEnabled(BOOL on);

// v30：宽度变化后的保邻看守（tick 每 2s 调；引擎内部 quiet 时不动作）
void FSBarKeepAdjacentTick(void);

// v30：注册重建版主图标项（位置校准/保邻的参照物；重建版无原生项，主项由 Swift 自建）
void FSBarSetMainItem(NSStatusItem *item);

// v30：接收 Swift 下发的屏幕口径空隙（主图标内容左缘 - 合并条内容右缘，>0=有空隙；-1=无数据）
void FSBarSetScreenGap(double gap);

// v30 排障：合并条状态项访问器（坐标探针用；引擎未建项时为 nil）
NSStatusItem *FSBarMergedItem(void);

// 最近一次点击的菜单栏锚点（屏幕坐标；引擎记录，注入版同源）
NSRect FSBarLastAnchorScreenRect(void);

// ---- Swift 侧深数据访问辅助（C 数组成员/元组友好）----
const char *FSStatsProcName(const void *proc);      // frset_proc_t* → name
const char *FSStatsProcPath(const void *proc);      // frset_proc_t* → path（v86）
const char *FSStatsSensorKey(const void *sensor);   // frset_sensor_t* → key
int FSStatsConnHistoryAt(const void *conn, int i);  // frset_conn_t* → history[i]（1/0/-1）
const char *FSStatsRootFileSystem(void);            // 根卷文件系统（statfs，如 "apfs"）

// ---- 本地 PP-OCR 识别模型（ONNX Runtime；离线中文 OCR，缺模型时静默降级回 Vision）----
typedef void *FSPPOCRSession;
FSPPOCRSession FSPPOCRSessionCreate(const char *libPath, const char *modelPath, char *errBuf, int errCap);
void FSPPOCRSessionDestroy(FSPPOCRSession handle);
float *FSPPOCRRun(FSPPOCRSession handle, const float *input, int64_t height, int64_t width,
                   int64_t *outT, int64_t *outC);
void FSPPOCRFree(float *data);

#endif /* FRSET_STATS_BAR_H */
