// frset_stats_tick.m — 重建版采样 tick（2026-10-16，从注入版 frset_stats_inject.m 提取）
// ============================================================================
// 本文件替代注入版的「FSStatsView.tick + 注入入口」：
//   · C 数据层采样 → g_snap（部件引擎的唯一数据源，引擎只读 g_snap）
//   · 引擎所需的两个注入层回调：
//       FSBarOpenMonitor(int module)  —— Swift 侧注册 block，点击部件时打开监测面板对应页
//       FSBarCopySensorKeys(...)      —— 设置界面传感器选择用（直接读 SMC 扫描结果）
//   · 生命周期：FSStatsTickStart() / FSStatsTickStop()
//
// 不包含（重建版不需要）：
//   · 注入入口/方法交换/hook（constructor、orderFront/constrainFrameRect 等）
//   · 监测面板绘制（重建版为 SwiftUI：MonitorCenterView / MonitorDetailView；
//     需要 GPU/SMART/nettop/连通性等更深数据时，Swift 经桥接头直接调
//     frset_stats_data.h 的 C API——frset_gpu_usage / frset_disk_smart /
//     frset_net_top / frset_conn_sample / frset_smc_scan 等）
//
// 数据流（与注入版一致）：
//   NSTimer 0.5s → frset_*_sample() → g_snap → FSBarSystemTick() → 部件按
//   各模块 updateInterval 刷新（引擎内部节流）
// ============================================================================
#import <Cocoa/Cocoa.h>
#include <sys/mount.h>          // statfs：根卷文件系统类型（FSStatsRootFileSystem）
#import "frset_barwidgets.h"
#import "frset_stats_data.h"

// v30：保邻看守（frset_barwidgets.m 实现；桥接头 FrsetStatsBar.h 亦声明）
void FSBarKeepAdjacentTick(void);

#define kSampleInterval 0.5

// ---- 采样状态（对应注入版 FSStatsView 的 ivars，只留 tick 需要的）----
static frset_cpu_t     s_cpu;
static frset_mem_t     s_mem;
static frset_net_t     s_net;
static frset_disk_t    s_disk;
static frset_battery_t s_batt;
static frset_sensor_t  s_sensors[600];
static int             s_sensorCount = 0;
static int             s_tickCount = 0;
static uint64_t        s_diskTotal = 0, s_diskFree = 0;

static NSTimer *s_tickTimer = nil;

// ---- FSBarOpenMonitor 的 Swift 桥（点击部件 → 打开监测面板对应页）----
typedef void (*FSBarOpenMonitorFn)(int module);
static FSBarOpenMonitorFn s_openMonitorFn = NULL;

/// Swift 侧注册：引擎点击部件时回调（module：CPU0 内存1 GPU2 磁盘3 网络4 传感器5 电池6）
void FSStatsSetOpenMonitorHandler(FSBarOpenMonitorFn fn) { s_openMonitorFn = fn; }

void FSBarOpenMonitor(int module) {
    if (s_openMonitorFn) {
        s_openMonitorFn(module);
    } else {
        NSLog(@"[FrsetStatsBar] FSBarOpenMonitor(%d) 无处理器（Swift 未注册）", module);
    }
}

/// v24：最近一次点击的菜单栏锚点——由引擎内部记录（g_anchorScreen，
/// 实现见 frset_barwidgets.m），本文件不重复定义。
/// 设置界面传感器选择：返回 SMC 扫描到的传感器 key/value（按扫描序）
int FSBarCopySensorKeys(char keys[][8], double *values, int max) {
    if (s_sensorCount <= 0) s_sensorCount = frset_smc_scan(s_sensors, 600);
    int n = s_sensorCount < max ? s_sensorCount : max;
    for (int i = 0; i < n; i++) {
        memcpy(keys[i], s_sensors[i].key, 8);
        if (values) values[i] = s_sensors[i].value;
    }
    return n;
}

// ---- v14 诊断接口（引擎声明、注入层实现；重建版保留空实现以满足链接）----
int FSBarDebugCurrentModule(void) { return -1; }

// ============ 辅助：收集并排序温度传感器（降序，可选前缀过滤）============
// （与注入版 collectTemps 逐行一致：category==0 且 key 前缀匹配 TV/TG）
static int collectTemps(frset_sensor_t *src, int n, frset_sensor_t *out, int maxOut,
                        const char *pfx1, const char *pfx2) {
    int cnt = 0;
    for (int i = 0; i < n && cnt < maxOut; i++) {
        if (src[i].category != 0) continue;
        if (pfx1 && strncmp(src[i].key, pfx1, strlen(pfx1)) != 0 &&
            (!pfx2 || strncmp(src[i].key, pfx2, strlen(pfx2)) != 0)) continue;
        int j = cnt;
        while (j > 0 && out[j-1].value < src[i].value) { out[j] = out[j-1]; j--; }
        out[j] = src[i];
        cnt++;
    }
    return cnt;
}

// ============ tick：采样 → g_snap（逻辑与注入版 FSStatsView.tick 一致）============
static void statsTick(void) {
    s_tickCount++;
    frset_cpu_sample(&s_cpu);
    frset_mem_sample(&s_mem);
    frset_net_sample(&s_net);
    frset_disk_sample(&s_disk);
    if (s_tickCount % 2 == 0) frset_battery_sample(&s_batt);   // 1s（省 IORegistry 开销）
    frset_loadavg(&g_snap.load1, &g_snap.load5, &g_snap.load15);
    frset_disk_capacity(&s_diskTotal, &s_diskFree);
    if (s_tickCount % 12 == 1) s_sensorCount = frset_smc_scan(s_sensors, 600);  // 6s

    double ramNow = s_mem.total ? (double)s_mem.used / s_mem.total : 0;
    g_snap.valid = 1;
    g_snap.cpuUsage = s_cpu.usage; g_snap.cpuSystem = s_cpu.system;
    g_snap.cpuUser = s_cpu.user;   g_snap.cpuIdle = s_cpu.idle;
    for (int i = 0; i < s_cpu.core_count && i < 32; i++) g_snap.coreUsage[i] = s_cpu.per_core[i];
    g_snap.coreCount = s_cpu.core_count;
    g_snap.ramRatio = ramNow;
    double compRatio = s_mem.total ? (double)s_mem.compressed / (double)s_mem.total : 0;
    g_snap.ramCompRatio = compRatio;
    g_snap.ramAppRatio = MAX(0, ramNow - compRatio);
    g_snap.ramWireRatio = MAX(0, 1 - ramNow);
    g_snap.ramUsedBytes = (double)s_mem.used;
    g_snap.ramTotalBytes = (double)s_mem.total;
    g_snap.diskUsedRatio = s_diskTotal ? (double)(s_diskTotal - s_diskFree) / (double)s_diskTotal : 0;
    g_snap.diskTotalBytes = (double)s_diskTotal; g_snap.diskFreeBytes = (double)s_diskFree;
    g_snap.diskReadBps = (double)s_disk.read_bps; g_snap.diskWriteBps = (double)s_disk.write_bps;
    g_snap.netDownBps = (double)s_net.down_bps;   g_snap.netUpBps = (double)s_net.up_bps;
    g_snap.batteryPresent = s_batt.present; g_snap.batteryCharging = s_batt.is_charging;
    g_snap.batteryPercent = (double)s_batt.percent;
    {
        double rem = frset_battery_remaining_sec();
        g_snap.batteryRemainMin = rem > 0 ? rem / 60.0 : -1;
    }
    {
        frset_sensor_t tb[100];
        int tn = collectTemps(s_sensors, s_sensorCount, tb, 100, "TV", "TG");
        g_snap.gpuTemp = tn > 0 ? tb[0].value : 0;
    }
    {
        NSString *sk = FSBarCfgStr(@"Sensors", nil, @"sensor", @"PPBR");
        strncpy(g_snap.sensorKey, sk.UTF8String ?: "PPBR", 7);
        g_snap.sensorKey[7] = 0;
        g_snap.sensorValue = 0;
        for (int i = 0; i < s_sensorCount; i++) {
            if (strcmp(s_sensors[i].key, g_snap.sensorKey) == 0) { g_snap.sensorValue = s_sensors[i].value; break; }
        }
    }
}

// ============ 生命周期 ============

/// 启动：SMC + 连通性探测 + 采样定时器 + 部件引擎。
/// statusItems 传空数组——重建版没有「原生监控项」需要接管，所有模块走自建项/
/// 合并条路径（与注入版「原生项全隐藏、合并条呈现」的最终观感一致）。
void FSStatsTickStart(void) {
    if (s_tickTimer) return;
    frset_smc_open();
    frset_conn_start();          // Net 面板连通性历史（ICMP 后台线程，幂等）
    statsTick();                 // 立即采一次，避免首帧空值
    s_tickTimer = [NSTimer timerWithTimeInterval:kSampleInterval repeats:YES block:^(NSTimer *t) {
        statsTick();
        FSBarSystemTick();
        // v30：保邻看守每 tick（0.5s）调——与 length 重排（网速数值变化）同频，
        // frame 修正后最多半个采样周期被覆盖，视觉空隙最小化
        FSBarKeepAdjacentTick();
    }];
    [[NSRunLoop mainRunLoop] addTimer:s_tickTimer forMode:NSRunLoopCommonModes];
    FSBarSystemStart([NSMutableArray array]);
    NSLog(@"[FrsetStatsBar] 采样 tick 启动（%.1fs）+ 部件引擎", kSampleInterval);
}

void FSStatsTickStop(void) {
    if (s_tickTimer) { [s_tickTimer invalidate]; s_tickTimer = nil; }
    frset_smc_close();
    NSLog(@"[FrsetStatsBar] 采样 tick 停止");
}

// ============ Swift 侧深数据访问辅助 ============
// C 数组成员（char name[64] / int history[90]）导入 Swift 侧是元组，跨语言取值
// 经这层薄包装（供监测面板的深数据展示：进程名/传感器 key/连通性历史网格）。
const char *FSStatsProcName(const void *p) {
    return ((const frset_proc_t *)p)->name;
}

const char *FSStatsSensorKey(const void *s) {
    return ((const frset_sensor_t *)s)->key;
}

int FSStatsConnHistoryAt(const void *c, int i) {
    const frset_conn_t *x = (const frset_conn_t *)c;
    return (i >= 0 && i < 90) ? x->history[i] : -1;
}

// 根卷文件系统类型（statfs f_fstypename，官方 Disk 模块同源；返回静态缓冲）
const char *FSStatsRootFileSystem(void) {
    static char buf[32];
    struct statfs st;
    if (statfs("/", &st) != 0) { buf[0] = 0; return buf; }
    snprintf(buf, sizeof(buf), "%s", st.f_fstypename);
    return buf;
}
