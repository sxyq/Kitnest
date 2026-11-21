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
#include <pthread.h>
#include <math.h>
#include <sys/sysctl.h>

extern CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
extern CFTypeRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(CFTypeRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int);

// macmon src/clpc.rs（macOS 27.2）：聚合计数器包含各芯片全部核心/芯粒。
// 旧 Energy Model 在 27 上停止更新；按实际 CLPC 驱动选择，绝不以利用率估算瓦数。
static const struct { const char *bundle; uint32_t keys[6]; } powerDrivers[] = {
    {"com.apple.driver.AppleT6000CLPCv3", {0x47479059,0x4519bf1e,0x9aaa17f8,0xd6ca0cfb,0x05cac729,0x3c7af4b5}},
    {"com.apple.driver.AppleT6002CLPC", {0xb501816b,0x9e2c3e8b,0x14d5a574,0x76704b08,0x2d7b7fb2,0xe16c1380}},
    {"com.apple.driver.AppleT6020CLPC", {0xe301cd75,0x8f34cc7a,0x7415fb0f,0x26244bb6,0x5f31a20f,0x9877104c}},
    {"com.apple.driver.AppleT6022CLPC", {0x76f5fd21,0x90624499,0x3c097307,0xe8f2ddf9,0xfa865a91,0xef56ddf3}},
    {"com.apple.driver.AppleT6030CLPC", {0xbe03a01a,0x472d6c9c,0xb8990c38,0x23809c0f,0xb5944c6a,0xd9ac8450}},
    {"com.apple.driver.AppleT6031CLPC", {0xd81e0084,0x1085f98b,0x313a3be1,0x65ff699d,0x10cb1f6a,0xfc3fce99}},
    {"com.apple.driver.AppleT6032CLPC", {0xf4a21308,0x85e80513,0x63dc8e25,0x63dcaae5,0x8cc13c13,0xfaa8ecc3}},
    {"com.apple.driver.AppleT6041CLPC", {0x263cf1f0,0x22e4cf59,0x7849fb5c,0xfe932624,0x8fc8575c,0xf70848a3}},
    {"com.apple.driver.AppleT6050CLPC", {0xd3ab60bb,0x27cd4ce5,0x8c0f1c59,0xf3c81737,0x3d89affa,0x958cfda5}},
    {"com.apple.driver.AppleT6050dCLPC", {0x18b3010e,0xedeca11a,0x188bd883,0xa33196f9,0x0b3c717e,0x9ee79a95}},
    {"com.apple.driver.AppleT8103CLPCv3", {0x2cdd31f2,0x21becf42,0x0667fb81,0xc0c20839,0x31d3e1e7,0xd6858d06}},
    {"com.apple.driver.AppleT8112CLPC", {0xb5435137,0x638d9d52,0xea089c36,0x8b6e0faa,0x9a6e145a,0x824bcad4}},
    {"com.apple.driver.AppleT8122CLPC", {0x54b51c99,0xce2dd9dc,0x960afe2f,0x0b9641d3,0x0d802b66,0x9709cb31}},
    {"com.apple.driver.AppleT8132CLPC", {0x4a854d94,0x3b3e3b79,0x1ff4a9ec,0x9a44d225,0xe34048d2,0x6ab990d0}},
    {"com.apple.driver.AppleT8140CLPC", {0x9bf54436,0xef70589c,0x569d941b,0x035f5005,0x53442391,0x7f14616c}},
    {"com.apple.driver.AppleT8142CLPC", {0x43708744,0x6a010933,0xbc5efdf0,0xe13633aa,0x2b8d7fec,0xa65ab9a8}},
    {"com.apple.driver.AppleT8152CLPC", {0x485d4bfc,0x11784654,0x9380c6bb,0xe17c13bf,0x4e80dc41,0xf6ed063b}}
};
static CFTypeRef powerSubscription;
static CFMutableDictionaryRef powerChannels;
static CFDictionaryRef powerPrevious;
static double powerPreviousTime, powerSampleTime;
static pthread_mutex_t powerLock = PTHREAD_MUTEX_INITIALIZER;
static frset_power_t powerSnapshot;

static int powerDomain(NSString *name) {
    if ([name hasSuffix:@"CPU Energy"]) return 0;
    NSUInteger index = [@[@"GPU Energy", @"ANE", @"DRAM", @"DCS", @"Package Energy"] indexOfObject:name];
    return index == NSNotFound ? -1 : (int)index + 1;
}

static void startPowerReport(void) {
    NSMutableArray *channels = [NSMutableArray array];
    char version[32]; size_t len = sizeof(version);
    sysctlbyname("kern.osproductversion", version, &len, NULL, 0);
    if (atoi(version) == 27) {
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleCLPC"));
        if (service) {
            uint64_t driver = 0; IORegistryEntryGetRegistryEntryID(service, &driver);
            NSString *bundle = CFBridgingRelease(IORegistryEntryCreateCFProperty(service, CFSTR("CFBundleIdentifier"), kCFAllocatorDefault, 0));
            IOObjectRelease(service);
            for (int m = 0; m < sizeof(powerDrivers)/sizeof(powerDrivers[0]); m++) {
                if (![bundle isEqualToString:@(powerDrivers[m].bundle)]) continue;
                const uint32_t indices[] = {16,25,24,26,27,9};
                NSArray *names = @[@"CPU Energy",@"GPU Energy",@"ANE",@"DRAM",@"DCS",@"Package Energy"];
                for (int i = 0; i < 6; i++) {
                    uint64_t id = ((uint64_t)indices[i] << 32) | powerDrivers[m].keys[i];
                    [channels addObject:[@{@"DriverID":@(driver), @"DriverName":@"AppleCLPC",
                        @"IOReportGroupName":@"CLPC", @"IOReportSubGroupName":@"Energy Counters",
                        @"IOReportChannelInfo":@{@"IOReportChannelUnit":@((3ULL<<56)|(118ULL<<32))},
                        @"LegendChannel":@[@(id),@((1ULL<<32)|(2ULL<<16)|1),names[i]]} mutableCopy]];
                }
                break;
            }
        }
    } else {
        NSDictionary *all = CFBridgingRelease(IOReportCopyAllChannels(0, 0));
        NSArray *items = all[@"IOReportChannels"];
        BOOL aggregateCPU = NO;
        for (NSDictionary *item in items) {
            CFDictionaryRef ref = (__bridge CFDictionaryRef)item;
            if ([(__bridge NSString *)IOReportChannelGetGroup(ref) isEqualToString:@"Energy Model"] &&
                [(__bridge NSString *)IOReportChannelGetChannelName(ref) isEqualToString:@"CPU Energy"]) aggregateCPU = YES;
        }
        for (NSDictionary *item in items) {
            CFDictionaryRef ref = (__bridge CFDictionaryRef)item;
            NSString *name = (__bridge NSString *)IOReportChannelGetChannelName(ref);
            int domain = powerDomain(name);
            if (![(__bridge NSString *)IOReportChannelGetGroup(ref) isEqualToString:@"Energy Model"] || domain < 0 || domain > 5) continue;
            if (domain == 0 && aggregateCPU && ![name isEqualToString:@"CPU Energy"]) continue;
            [channels addObject:[item mutableCopy]];
        }
    }
    if (!channels.count) return;
    NSMutableDictionary *selected = [@{@"IOReportChannels":channels} mutableCopy];
    powerSubscription = IOReportCreateSubscription(NULL, (__bridge CFMutableDictionaryRef)selected, &powerChannels, 0, NULL);
}

void frset_power_sample(frset_power_t *out) {
    pthread_mutex_lock(&powerLock);
    double now = NSProcessInfo.processInfo.systemUptime;
    if (powerSampleTime == 0 || now - powerSampleTime >= 1) {
        double values[6] = {NAN,NAN,NAN,NAN,NAN,NAN};
        if (powerSampleTime == 0) startPowerReport();
        if (powerSubscription) {
            CFDictionaryRef next = IOReportCreateSamples(powerSubscription, powerChannels, NULL);
            if (next && powerPrevious) {
                NSDictionary *delta = CFBridgingRelease(IOReportCreateSamplesDelta(powerPrevious, next, NULL));
                for (NSDictionary *item in delta[@"IOReportChannels"]) {
                    CFDictionaryRef ref = (__bridge CFDictionaryRef)item;
                    int domain = powerDomain((__bridge NSString *)IOReportChannelGetChannelName(ref));
                    NSString *unit = (__bridge NSString *)IOReportChannelGetUnitLabel(ref);
                    double scale = [unit isEqualToString:@"nJ"] ? 1e9 : [unit isEqualToString:@"uJ"] ? 1e6 : [unit isEqualToString:@"mJ"] ? 1e3 : NAN;
                    int64_t energy = IOReportSimpleGetIntegerValue(ref, 0);
                    if (domain < 0 || domain > 5 || !isfinite(scale) || energy < 0) continue;
                    double watts = energy / scale / (now - powerPreviousTime);
                    values[domain] = isnan(values[domain]) ? watts : values[domain] + watts;
                }
            }
            if (powerPrevious) CFRelease(powerPrevious);
            powerPrevious = next; powerPreviousTime = now;
        }
        powerSnapshot = (frset_power_t){frset_smc_read_key("PSTR"), frset_smc_read_key("PDTR"),
            values[0],values[1],values[2],values[3],values[4],values[5]};
        powerSampleTime = now;
    }
    *out = powerSnapshot;
    pthread_mutex_unlock(&powerLock);
}

// v30：保邻看守（frset_barwidgets.m 实现；桥接头 FrsetStatsBar.h 亦声明）

#define kSampleInterval 0.5

// ---- 采样状态（对应注入版 FSStatsView 的 ivars，只留 tick 需要的）----
static frset_cpu_t     s_cpu;
static pthread_mutex_t s_cpuLock = PTHREAD_MUTEX_INITIALIZER;
static BOOL            s_hasCPU;
static frset_mem_t     s_mem;
static frset_net_t     s_net;
static frset_disk_t    s_disk;
static frset_battery_t s_batt;
// v49 性能修复：SMC 全量扫描（600 键，sample 实测单次 ~150ms）移出主线程。
// 主线程每 6s 的这一次扫描是菜单栏/UI 周期性尖峰卡顿的元凶。改为后台线程扫描
// s_bgSensors，经 release/acquire 发布到 s_sensorCountA；主线程每 tick 只读快照。
// 数据发布后不可变（后台只在扫描完成时整块覆盖），主线程无锁读取不撕裂。
#include <stdatomic.h>
static frset_sensor_t  s_sensors[600];
static _Atomic int     s_sensorCountA = 0;
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
    // v49：懒扫描保留（设置页低频操作），计数改走原子发布
    if (atomic_load_explicit(&s_sensorCountA, memory_order_acquire) <= 0) {
        frset_sensor_t tmp[600];
        int n = frset_smc_scan(tmp, 600);
        if (n > 0) {
            memcpy(s_sensors, tmp, (size_t)n * sizeof(frset_sensor_t));
            atomic_store_explicit(&s_sensorCountA, n, memory_order_release);
        }
    }
    int n = atomic_load_explicit(&s_sensorCountA, memory_order_acquire);
    // v88（2026-10-20 用户实证「BDAT 显示 5388°」）：温度模块的传感器选择器
    // 只列**温度类**键（category==0，即 T*）；此前把全部扫描键（含 B*/V*/P* 的
    // 电池数据/电压/功率）都塞进选项，选中后又被当温度打「°」，数据就错了。
    int cnt = 0;
    for (int i = 0; i < n && cnt < max; i++) {
        if (s_sensors[i].category != 0) continue;
        memcpy(keys[cnt], s_sensors[i].key, 8);
        if (values) values[cnt] = s_sensors[i].value;
        cnt++;
    }
    return cnt;
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
// CPU 集群详情与菜单栏共用一帧。菜单栏停用时，详情沿用原来的直接采样。
void FSStatsReadCPU(frset_cpu_t *out) {
    pthread_mutex_lock(&s_cpuLock);
    if (s_hasCPU) *out = s_cpu;
    else frset_cpu_sample(out);
    pthread_mutex_unlock(&s_cpuLock);
}

static void statsTick(void) {
    s_tickCount++;
    pthread_mutex_lock(&s_cpuLock);
    frset_cpu_sample(&s_cpu);
    s_hasCPU = s_cpu.core_count > 0;
    pthread_mutex_unlock(&s_cpuLock);
    frset_mem_sample(&s_mem);
    /* v128（CPU 优化）：网络/磁盘/电池降为 1s 采样（0.5s tick 的隔拍执行）。
       状态栏主显示是 CPU/内存（保持 0.5s）；这三项是次要读数，1s 采样与部件默认
       updateInterval=1s 一致，观感无差。速率本身是差分均值，间隔放宽只是把平均
       窗口从 0.5s 变成 1s。s_net/s_disk/s_batt 保留上一轮读数，g_snap 每 tick 照常
       拷贝（隔拍之间数值不变，部件按自身间隔读 g_snap 不受影响）。 */
    if (s_tickCount % 2 == 1) {
        /* 奇数拍执行：FSStatsTickStart 的立即首采（count=1）就带上这三项，
           避免启动后第一秒电池/网速显示 0（v128 配套） */
        frset_net_sample(&s_net);
        frset_disk_sample(&s_disk);
        frset_battery_sample(&s_batt);   // 1s（省 IORegistry 开销）
        frset_power_sample(&g_snap.power);
    }
    frset_loadavg(&g_snap.load1, &g_snap.load5, &g_snap.load15);
    /* v126（性能审计 F1723 配套）：statfs 磁盘容量改为 30s 缓存——原先每 0.5s
       调 frset_disk_capacity（statfs 系统调用），磁盘容量分钟级才变，削减 96% syscall。 */
    if (s_tickCount % 60 == 1) frset_disk_capacity(&s_diskTotal, &s_diskFree);
    if (s_tickCount % 12 == 1) {
        // v49 性能修复：SMC 全量扫描（~150ms）放后台线程，主线程零尖峰。
        // g_conn 已在 FSStatsTickStart 主线程打开，之后只读（IOKit 驱动侧串行化），跨线程安全。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            frset_sensor_t tmp[600];
            int n = frset_smc_scan(tmp, 600);
            if (n > 0) {
                memcpy(s_sensors, tmp, (size_t)n * sizeof(frset_sensor_t));
                atomic_store_explicit(&s_sensorCountA, n, memory_order_release);
            }
        });
    }

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
        // v49：后台扫描发布计数（acquire 与后台 release 配对，保证数组可见性）
        int sensorCount = atomic_load_explicit(&s_sensorCountA, memory_order_acquire);
        frset_sensor_t tb[100];
        int tn = collectTemps(s_sensors, sensorCount, tb, 100, "TV", "TG");
        g_snap.gpuTemp = tn > 0 ? tb[0].value : 0;
    }
    {
        // v88（2026-10-20 用户实证「BDAT 显示 5388°」）：温度模块的取值同样只认
        // 温度类键（category==0）；配置的键不存在/不是温度时回退「当前最热温度」，
        // 不再把电池数据（B*）等非温度值当摄氏度展示。
        int sensorCount = atomic_load_explicit(&s_sensorCountA, memory_order_acquire);
        NSString *sk = FSBarCfgStr(@"Sensors", nil, @"sensor", @"PPBR");
        strncpy(g_snap.sensorKey, sk.UTF8String ?: "PPBR", 7);
        g_snap.sensorKey[7] = 0;
        g_snap.sensorValue = 0;
        int found = 0;
        for (int i = 0; i < sensorCount; i++) {
            if (strcmp(s_sensors[i].key, g_snap.sensorKey) == 0 && s_sensors[i].category == 0) {
                g_snap.sensorValue = s_sensors[i].value; found = 1; break;
            }
        }
        if (!found) {
            double best = -9999; const char *bestKey = NULL;
            for (int i = 0; i < sensorCount; i++) {
                if (s_sensors[i].category != 0) continue;
                if (s_sensors[i].value > best) { best = s_sensors[i].value; bestKey = s_sensors[i].key; }
            }
            if (bestKey) {
                strncpy(g_snap.sensorKey, bestKey, 7); g_snap.sensorKey[7] = 0;
                g_snap.sensorValue = best;
            }
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
        /* v128（CPU 优化）：tick 体包 @autoreleasepool——C 引擎→ObjC/Swift 的桥接
           （FSBarCfgStr 的 NSString、FSBarSystemTick 内部的字典/数组）产生 autorelease
           对象，靠 runloop 周期性回收不及时，长期累积推高常驻堆；显式池化保证每次
           tick 结束即释放（63MB 小堆的主嫌之一）。 */
        @autoreleasepool {
            statsTick();
            FSBarSystemTick();
            // v30：保邻看守每 tick（0.5s）调——与 length 重排（网速数值变化）同频，
            // frame 修正后最多半个采样周期被覆盖，视觉空隙最小化
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:s_tickTimer forMode:NSRunLoopCommonModes];
    FSBarSystemStart([NSMutableArray array]);
    NSLog(@"[FrsetStatsBar] 采样 tick 启动（%.1fs）+ 部件引擎", kSampleInterval);
}

void FSStatsTickStop(void) {
    if (s_tickTimer) { [s_tickTimer invalidate]; s_tickTimer = nil; }
    pthread_mutex_lock(&s_cpuLock);
    s_hasCPU = NO;
    pthread_mutex_unlock(&s_cpuLock);
    frset_smc_close();
    NSLog(@"[FrsetStatsBar] 采样 tick 停止");
}

// ============ Swift 侧深数据访问辅助 ============
// C 数组成员（char name[64] / int history[90]）导入 Swift 侧是元组，跨语言取值
// 经这层薄包装（供监测面板的深数据展示：进程名/传感器 key/连通性历史网格）。
const char *FSStatsProcName(const void *p) {
    return ((const frset_proc_t *)p)->name;
}

// v86：进程可执行路径（归类键与图标来源）——Swift 侧按 ".app/" 前缀取宿主 bundle，
// 是「归类正确 + 图标正确」的唯一可靠依据（按进程名猜测会误合并/误配图标）。
const char *FSStatsProcPath(const void *p) {
    return ((const frset_proc_t *)p)->path;
}

// v178：CPU 能耗行（电池页「CPU 能耗影响」）——Swift 侧取 path 做 .app 归类、
// 取 name 做显示名；固定长度数组成员不能直接给 Swift，只能走薄包装。
const char *FSEnergyPath(const void *e) {
    return ((const frset_energy_pid_t *)e)->path;
}

const char *FSEnergyName(const void *e) {
    return ((const frset_energy_pid_t *)e)->name;
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
