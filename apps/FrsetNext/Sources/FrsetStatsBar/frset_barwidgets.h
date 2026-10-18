// frset_barwidgets.h — 状态栏部件系统（Stats SWidget 复刻）公共接口
// ============================================================================
// 架构（v10）：
//   frset_stats_inject.m   注入入口 + 监测面板；负责：采样 → g_snap、状态项捕获、
//                          提供 FSBarOpenMonitor()（打开面板并直达模块）
//   frset_barwidgets.m     部件引擎：设置存储（widgets.plist ↔ Stats 键名互通）、
//                          部件视图（12 种形态绘制）、状态项管理（原生接管 + 自建增删）
//   frset_barsettings.m    Stats 风格设置窗口（模块工具栏 + 部件列表 + 逐部件设置）
//
// 数据流：FSStatsView.tick（0.5s）→ g_snap → FSBarSystemTick（0.5s）
//         → 按各模块 updateInterval 刷新部件 → 部件视图重绘
// ============================================================================
#ifndef FRSET_BARWIDGETS_H
#define FRSET_BARWIDGETS_H

#import <Cocoa/Cocoa.h>

// ---- 面板采样快照（由 frset_stats_inject.m 的 FSStatsView.tick 持续填充）----
typedef struct {
    int valid;
    double cpuUsage, cpuSystem, cpuUser, cpuIdle;
    double coreUsage[32]; int coreCount;
    double ramRatio;            // used/total
    double ramAppRatio;         // (used-compressed)/total 近似
    double ramCompRatio;        // compressed/total
    double ramWireRatio;        // (total-used)/total 近似为自由
    double ramUsedBytes, ramTotalBytes;
    double diskUsedRatio;
    double diskReadBps, diskWriteBps;
    double diskTotalBytes, diskFreeBytes;
    double netDownBps, netUpBps;
    int batteryPresent, batteryCharging; double batteryPercent; double batteryRemainMin;
    double gpuTemp;             // GPU 相关温度（TV*/TG* 最大值，0=无）
    double sensorValue;         // 用户选定传感器（默认 PPBR）当前值
    char sensorKey[8];
    double load1, load5, load15;
} FSSnap;

extern FSSnap g_snap;

// ---- 生命周期 ----
/// 注入构造器调用一次（内部启动 0.5s 轮询；g_statusItems 由 inject 传入用于接管原生项）
void FSBarSystemStart(NSMutableArray *statusItems);
/// inject 主轮询每 0.5s 调用（内部自行管理节奏与自愈）
void FSBarSystemTick(void);
/// 打开部件设置窗口（监测面板页脚齿轮调用）
/// v54：改为深链到 App 设置窗口的「性能监测 → 部件设置」页
void FSBarSettingsOpen(void);
/// 设置变更后重建部件（供设置窗口调用）
void FSBarReloadFromStore(void);

// ---- 设置 API（设置窗口 / 注入层共用；键名与 Stats 完全一致） ----
NSArray<NSString *> *FSBarAllModules(void);
NSArray<NSString *> *FSBarFormsForModule(NSString *module);
NSString *FSBarFormName(NSString *form);
NSString *FSBarModuleName(NSString *module);
NSArray<NSString *> *FSBarEnabledForms(NSString *module);
void FSBarSetEnabledForms(NSString *module, NSArray<NSString *> *forms);
id FSBarCfgRaw(NSString *module, NSString *form, NSString *key);
void FSBarCfgSet(NSString *module, NSString *form, NSString *key, id value);
BOOL FSBarCfgBool(NSString *module, NSString *form, NSString *key, BOOL def);
NSString *FSBarCfgStr(NSString *module, NSString *form, NSString *key, NSString *def);
int FSBarCfgInt(NSString *module, NSString *form, NSString *key, int def);
NSArray<NSString *> *FSBarColorKeys(void);
NSString *FSBarColorName(NSString *key);
void FSBarSaveStore(void);
void FSBarResetFromStats(void);     // 重置并重新从 eu.exelban.Stats 导入
void FSBarResetToDefaults(void);    // 恢复出厂默认

// ---- v11：全局键（CombinedModules 系列；设置窗口读写用） ----
id FSBarGlobalRaw(NSString *key);
void FSBarGlobalSet(NSString *key, id value);
BOOL FSBarMergedEnabled(void);      // 合并显示（默认 YES，对齐 Stats CombinedModules）
BOOL FSBarMergedSeparator(void);    // 模块间 1pt 分隔线（默认 YES）
CGFloat FSBarMergedSpacing(void);   // 模块间距（"none"=0；1..8）

// ---- 由 inject 实现（部件引擎回调）----
/// 打开监测面板并直达模块（模块索引同面板：CPU0 内存1 GPU2 磁盘3 网络4 传感器5 电池6）
void FSBarOpenMonitor(int module);
/// v24：最近一次点击的菜单栏锚点（屏幕坐标，1×1 矩形；无点击时为 0 矩形）
/// 注入层 FSPreparePanelForDisplay 据此把面板对齐到"图标位置"展开
NSRect FSBarLastAnchorScreenRect(void);
/// v24 调试验证：直接设置锚点 x（用于验证"按图标位置展开"）
void FSBarSetDebugAnchorX(CGFloat x);
/// 拷贝温度传感器 key 列表（返回数量；keys 每项 8 字节；values 可 NULL）——设置界面传感器选择用
int FSBarCopySensorKeys(char keys[][8], double *values, int max);
/// v55：传感器 key 列表（NSArray 版，Swift 设置页用）
NSArray<NSString *> *FSBarSensorKeysList(void);

// ---- v15：设置界面支持 ----
NSString *FSBarModuleSymbol(NSString *module);                          // 模块 SF Symbol 名
NSImage *FSBarRenderFormPreview(NSString *module, NSString *form, BOOL dark);   // 部件预览图渲染

// ---- v14：点击链路诊断（FRSET_CLICKCHK=1 时由注入层触发一次；生产环境不触发）----
BOOL FSBarDebugMergedReady(void);
void FSBarDebugClickProbe(void);
/// 由 inject 实现：当前监测页模块索引（诊断用；无面板时 -1）
int FSBarDebugCurrentModule(void);

// ---- v17：弹窗复刻 & 菜单位置支持 ----
NSColor *FSBarColorFor(NSString *key, BOOL dark, double value);   // Stats SColor 解析（全表 + custom）
void FSBarDebugPosProbe(void);                                    // 菜单位置探针（FRSET_POSCHK=1）
void FSBarSettingsOpenModule(NSString *module);                   // 打开设置并切到指定模块页

// ---- v18：反相信号探针（FRSET_APPEARCHK=1；打印各层 appearance 验证 FSBarDark 判定源）----
void FSBarDebugAppearanceProbe(void);
/// 引擎日志落盘（跨文件探针复用：OPENCHK/APPEARCHK 等）
void FSBarLog(NSString *fmt, ...);
/// v18：关闭面板（OPENCHK 探针用；面板未开时无操作）
void FSBarDebugClosePanelIfNeeded(void);

#endif
