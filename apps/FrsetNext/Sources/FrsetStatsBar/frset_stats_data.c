// frset_stats_data.c — 采集层实现
// SMC：80 字节内核结构（实证布局）；CPU/内存/网络/磁盘：mach/sysctl/IOKit

#include "frset_stats_data.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/mount.h>
#include <signal.h>          // v84：frset_kill_bundle 的 kill/SIGTERM/SIGKILL
#include <unistd.h>          // v84：getpid
#include <pthread.h>         // v86：frset_net_top 后台采样线程
#include <time.h>            // v86：clock_gettime（nettop 差分）
#include <libproc.h>         // v86：proc_name / proc_pidpath / proc_listallpids
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <arpa/inet.h>
#include <sys/param.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/ps/IOPowerSources.h>

// ============ SMC ============

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } PLimit_t;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } KeyInfo_t;
typedef struct {
    uint32_t  key;
    Vers_t    vers;
    PLimit_t  pLimit;
    KeyInfo_t keyInfo;
    uint8_t   result;
    uint8_t   status;
    uint8_t   data8;
    uint32_t  data32;
    uint8_t   bytes[32];
} SMCKeyData_t;

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_READ_INDEX    8
#define SMC_CMD_READ_KEYINFO  9

static io_connect_t g_conn = 0;

static kern_return_t smc_raw(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData_t), out, &outSize);
}

static uint32_t str2key(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8)  |  (uint32_t)(uint8_t)s[3];
}
static void key2str(uint32_t k, char *out) {
    out[0] = (k >> 24) & 0xff; out[1] = (k >> 16) & 0xff;
    out[2] = (k >> 8) & 0xff;  out[3] = k & 0xff; out[4] = 0;
}

static int smc_keyinfo(uint32_t key, SMCKeyData_t *info) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key; in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_raw(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *info = out;
    return 0;
}

static int smc_read(uint32_t key, uint8_t *buf, uint32_t *size, uint32_t *type) {
    SMCKeyData_t info;
    if (smc_keyinfo(key, &info) != 0) return -1;
    SMCKeyData_t in = {0}, out = {0};
    in.key = key; in.data8 = SMC_CMD_READ_BYTES;
    in.keyInfo = info.keyInfo;
    if (smc_raw(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    uint32_t n = info.keyInfo.dataSize; if (n > 32) n = 32;
    memcpy(buf, out.bytes, n);
    if (size) *size = n;
    if (type) *type = info.keyInfo.dataType;
    return 0;
}

static double parse_value(uint32_t type, const uint8_t *b, uint32_t n) {
    char t[5]; key2str(type, t);
    if (!strcmp(t, "flt ") && n >= 4) { float f; memcpy(&f, b, 4); return f; }   // 小端（M 系列实证）
    if (!strcmp(t, "sp78") && n >= 2) { int16_t v=(int16_t)((b[0]<<8)|b[1]); return v/256.0; }
    if (!strcmp(t, "fpe2") && n >= 2) return ((b[0] << 6) + (b[1] >> 2));
    if (!strcmp(t, "ui8 ") && n >= 1) return b[0];
    if (!strcmp(t, "ui16") && n >= 2) return (b[0]<<8)|b[1];
    if (!strcmp(t, "ui32") && n >= 4) return (double)(((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|((uint32_t)b[2]<<8)|b[3]);
    if (!strcmp(t, "sp5a") && n >= 2) { int16_t v=(int16_t)((b[0]<<8)|b[1]); return v/1024.0; }
    if (!strcmp(t, "sp87") && n >= 2) { int16_t v=(int16_t)((b[0]<<8)|b[1]); return v/128.0; }
    if (!strcmp(t, "fp88") && n >= 2) return ((b[0] << 8) | b[1]) / 256.0;
    if (!strcmp(t, "fpa4") && n >= 2) return ((b[0] << 8) | b[1]) / 16.0;
    return -9999;
}

int frset_smc_open(void) {
    if (g_conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    return r == KERN_SUCCESS ? 0 : -1;
}

void frset_smc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
}

static int categorize(const char *k) {
    if (k[0] == 'T' && strcmp(k, "TYPE")) return 0;
    if (k[0] == 'F') return 1;
    if (k[0] == 'V') return 2;
    if (k[0] == 'I') return 3;
    if (k[0] == 'P') return 4;
    if (k[0] == 'B') return 5;
    return -1;
}

static int plausible(int cat, double v, const char *t) {
    // 类型白名单
    if (strcmp(t,"flt ") && strcmp(t,"sp78") && strcmp(t,"fpe2") && strcmp(t,"fp88") &&
        strcmp(t,"fpa4") && strcmp(t,"ui8 ") && strcmp(t,"ui16") && strcmp(t,"sp5a") && strcmp(t,"sp87")) return 0;
    switch (cat) {
        case 0: return v > 0.5 && v < 130;
        case 1: return v > 0 && v < 20000;
        case 2: return v > 0 && v < 100;
        case 3: return v >= 0 && v < 100;
        case 4: return v >= 0 && v < 1000;
        case 5: return v >= 0 && v < 30000;
    }
    return 0;
}

int frset_smc_scan(frset_sensor_t *out, int max_count) {
    if (!g_conn && frset_smc_open() != 0) return 0;
    uint8_t buf[32]; uint32_t size = 0, type = 0;
    if (smc_read(str2key("#KEY"), buf, &size, &type) != 0) return 0;
    uint32_t total = ((uint32_t)buf[0]<<24)|((uint32_t)buf[1]<<16)|((uint32_t)buf[2]<<8)|buf[3];
    int count = 0;
    for (uint32_t i = 0; i < total && i < 4096; i++) {
        SMCKeyData_t in = {0}, o = {0};
        in.data8 = SMC_CMD_READ_INDEX; in.data32 = i;
        if (smc_raw(&in, &o) != KERN_SUCCESS || o.result != 0) continue;
        char k[5]; key2str(o.key, k);
        int cat = categorize(k);
        if (cat < 0) continue;
        uint8_t vb[32]; uint32_t vs = 0, vt = 0;
        if (smc_read(o.key, vb, &vs, &vt) != 0) continue;
        double v = parse_value(vt, vb, vs);
        char ts[5]; key2str(vt, ts);
        if (!plausible(cat, v, ts)) continue;
        if (out && count < max_count) {
            memcpy(out[count].key, k, 5);
            out[count].value = v;
            out[count].category = cat;
        }
        count++;
    }
    return count;
}

// ============ CPU ============

static struct { uint32_t user, system, idle, nice; } g_prev_cpu[32];
static int g_prev_valid = 0;

void frset_cpu_sample(frset_cpu_t *out) {
    memset(out, 0, sizeof(*out));
    natural_t cpuCount = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t infoCount = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) != KERN_SUCCESS)
        return;
    int n = cpuCount < 32 ? cpuCount : 32;
    double used_all = 0, total_all = 0, tUser = 0, tSys = 0, tIdle = 0;
    for (int i = 0; i < n; i++) {
        int base = i * CPU_STATE_MAX;
        uint32_t u = (uint32_t)info[base + CPU_STATE_USER];
        uint32_t s = (uint32_t)info[base + CPU_STATE_SYSTEM];
        uint32_t id = (uint32_t)info[base + CPU_STATE_IDLE];
        uint32_t ni = (uint32_t)info[base + CPU_STATE_NICE];
        if (g_prev_valid && i < 32) {
            double du = (double)(u - g_prev_cpu[i].user);
            double ds = (double)(s - g_prev_cpu[i].system);
            double di = (double)(id - g_prev_cpu[i].idle);
            double dn = (double)(ni - g_prev_cpu[i].nice);
            double used = du + ds + dn, all = used + di;
            if (all > 0) {
                out->per_core[i] = used / all;
                used_all += used; total_all += all;
                tUser += du; tSys += ds; tIdle += di;
            }
        }
        g_prev_cpu[i].user = u; g_prev_cpu[i].system = s;
        g_prev_cpu[i].idle = id; g_prev_cpu[i].nice = ni;
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, infoCount * sizeof(integer_t));
    g_prev_valid = 1;
    out->core_count = n;
    if (total_all > 0) {
        out->usage = used_all / total_all;
        out->user = tUser / total_all;
        out->system = tSys / total_all;
        out->idle = tIdle / total_all;
    }
}

void frset_loadavg(double *l1, double *l5, double *l15) {
    struct loadavg la;
    size_t len = sizeof(la);
    if (sysctlbyname("vm.loadavg", &la, &len, NULL, 0) == 0) {
        double scale = (double)la.fscale;
        if (l1) *l1 = (double)la.ldavg[0] / scale;
        if (l5) *l5 = (double)la.ldavg[1] / scale;
        if (l15) *l15 = (double)la.ldavg[2] / scale;
    }
}

// ============ 内存 ============

void frset_mem_sample(frset_mem_t *out) {
    memset(out, 0, sizeof(*out));
    {
        size_t tlen = sizeof(out->total);
        sysctlbyname("hw.memsize", &out->total, &tlen, NULL, 0);
    }
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &cnt) == KERN_SUCCESS) {
        uint64_t pageSize = vm_kernel_page_size;
        uint64_t active = (uint64_t)vm.active_count * pageSize;
        uint64_t wired = (uint64_t)vm.wire_count * pageSize;
        uint64_t comp = (uint64_t)vm.compressor_page_count * pageSize;
        out->used = active + wired + comp;
        out->compressed = comp;
        out->wired = wired;
    }
    uint64_t swapUsed = 0, swapTotal = 0;
    {
        int mib[2] = {CTL_VM, VM_SWAPUSAGE};
        struct xsw_usage xsu = {0};
        size_t len = sizeof(xsu);
        if (sysctl(mib, 2, &xsu, &len, NULL, 0) == 0) {
            swapUsed = xsu.xsu_used; swapTotal = xsu.xsu_total;
        }
    }
    out->swap_used = swapUsed; out->swap_total = swapTotal;
}

// ============ 网络 ============

void frset_net_sample(frset_net_t *out) {
    memset(out, 0, sizeof(*out));
    static uint64_t prev_in = 0, prev_out = 0;
    static double prev_t = 0;
    uint64_t in = 0, o = 0;
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) == 0) {
        for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
            if (!p->ifa_data || !p->ifa_addr) continue;
            if (p->ifa_addr->sa_family != AF_LINK) continue;
            const char *name = p->ifa_name;
            if (!strncmp(name, "lo", 2) || !strncmp(name, "utun", 4) ||
                !strncmp(name, "bridge", 6) || !strncmp(name, "awdl", 4) || !strncmp(name, "llw", 3)) continue;
            struct if_data *d = (struct if_data *)p->ifa_data;
            in += d->ifi_ibytes; o += d->ifi_obytes;
        }
        freeifaddrs(ifa);
    }
    double now = CFAbsoluteTimeGetCurrent() + 978307200.0;
    if (prev_t > 0 && now > prev_t) {
        double dt = now - prev_t;
        if (dt > 0.1) {
            /* v183（真机实测的「16384 PB/s」）：网卡集合会变（插拔网卡/唤醒重建
               utun/bridge 之外的新接口、驱动计数器重置），总数一旦变小，
               `in - prev_in` 作为 uint64 会下溢成接近 2^64 —— 曲线量程当场被毁。
               计数器回退一律按 0 处理，绝不让下溢变成天文数字。 */
            uint64_t d_in  = in >= prev_in  ? (in - prev_in)  : 0;
            uint64_t d_out = o  >= prev_out ? (o  - prev_out) : 0;
            out->down_bps = (uint64_t)((double)d_in / dt);
            out->up_bps   = (uint64_t)((double)d_out / dt);
        }
    }
    out->total_up = o; out->total_down = in;
    prev_in = in; prev_out = o; prev_t = now;
}

// ============ 磁盘 ============

void frset_disk_sample(frset_disk_t *out) {
    memset(out, 0, sizeof(*out));
    static uint64_t prev_r = 0, prev_w = 0;
    static double prev_t = 0;
    uint64_t r = 0, w = 0;
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS) {
        io_registry_entry_t svc;
        while ((svc = IOIteratorNext(iter))) {
            CFMutableDictionaryRef props = NULL;
            if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
                CFDictionaryRef stat = CFDictionaryGetValue(props, CFSTR("Statistics"));
                if (stat) {
                    CFNumberRef n = CFDictionaryGetValue(stat, CFSTR("Bytes (Read)"));
                    if (n) { int64_t v = 0; CFNumberGetValue(n, kCFNumberSInt64Type, &v); r += v; }
                    n = CFDictionaryGetValue(stat, CFSTR("Bytes (Write)"));
                    if (n) { int64_t v = 0; CFNumberGetValue(n, kCFNumberSInt64Type, &v); w += v; }
                }
                CFRelease(props);
            }
            IOObjectRelease(svc);
        }
        IOObjectRelease(iter);
    }
    double now = CFAbsoluteTimeGetCurrent() + 978307200.0;
    if (prev_t > 0 && now > prev_t) {
        double dt = now - prev_t;
        if (dt > 0.1) {
            /* v183：同网络——磁盘计数回退（热插拔/IOKit 重枚举）时 uint64 下溢
               会给出天文数字，钳到 0。 */
            uint64_t d_r = r >= prev_r ? (r - prev_r) : 0;
            uint64_t d_w = w >= prev_w ? (w - prev_w) : 0;
            out->read_bps  = (uint64_t)((double)d_r / dt);
            out->write_bps = (uint64_t)((double)d_w / dt);
        }
    }
    prev_r = r; prev_w = w; prev_t = now;
}

// ============ 格式化 ============


// ============ v4 追加：电池（IORegistry AppleSmartBattery） ============

/* v126（性能审计 F1723）：缓存 AppleSmartBattery 的 io_service_t 句柄——
   原先每秒调 IOServiceGetMatchingService 做一次完整 IOKit 注册表匹配（~100µs），
   电池服务句柄在进程生命周期内稳定不变，缓存后只在句柄失效时重取。 */
static io_service_t g_battSvc = 0;

void frset_battery_sample(frset_battery_t *out) {
    memset(out, 0, sizeof(*out));
    /* v126：优先复用缓存句柄；句柄无效或属性读取失败时重新匹配 */
    if (!g_battSvc) {
        g_battSvc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    }
    io_service_t svc = g_battSvc;
    if (!svc) { out->present = 0; return; }
    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) != KERN_SUCCESS || !props) {
        /* v126：句柄可能已失效（电池热插拔等），释放并重取一次 */
        if (g_battSvc) { IOObjectRelease(g_battSvc); g_battSvc = 0; }
        svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
        g_battSvc = svc;
        if (!svc) { out->present = 0; return; }
        if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) != KERN_SUCCESS || !props) {
            out->present = 0;
            return;
        }
    }
    {
        int iv; double dv; CFTypeRef cv;
        // v25 关键修复（对照官方 Modules/Battery/readers.swift）：
        //   Apple Silicon 上 "MaxCapacity" 是**百分比**(100)，真实容量在 "AppleRawMaxCapacity"(mAh)，
        //   对应电流容量是 "AppleRawCurrentCapacity"。此前直接用 MaxCapacity → 「最大容量」显示成 100 mAh。
        //   Intel 机型没有 AppleRaw* 键 → 回退到 MaxCapacity（那时它确实是 mAh）。
        int rawMax = 0;
        // ⚠️ 实测（M5 / macOS 26）：根节点**没有** AppleRawMaxCapacity，且 MaxCapacity/CurrentCapacity
        //    都是**百分比(100)**；真实容量在 BatteryData 子字典：
        //    FullChargeCapacity / NominalChargeCapacity（最大容量）、RemainingCapacity（当前容量）、
        //    DesignCapacity（设计容量，本例 4629）。官方 Stats 在 ARM 上读 AppleRawMaxCapacity，
        //    但这台机器的 macOS 版本没有该键 → 必须补 BatteryData 回退链，否则「最大容量」显示成 100 mAh。
        CFDictionaryRef bdd = NULL;
        CFTypeRef bdRef = CFDictionaryGetValue(props, CFSTR("BatteryData"));
        if (bdRef && CFGetTypeID(bdRef) == CFDictionaryGetTypeID()) bdd = (CFDictionaryRef)bdRef;
        cv = CFDictionaryGetValue(props, CFSTR("AppleRawMaxCapacity"));
        if (cv && CFNumberGetValue(cv, kCFNumberIntType, &rawMax) && rawMax > 0) {
            out->max_capacity = rawMax;
            cv = CFDictionaryGetValue(props, CFSTR("AppleRawCurrentCapacity"));
            int rawCur = 0;
            if (cv && CFNumberGetValue(cv, kCFNumberIntType, &rawCur) && rawCur > 0) out->current_capacity = rawCur;
        } else if (bdd) {
            cv = CFDictionaryGetValue(bdd, CFSTR("FullChargeCapacity"));
            if (cv && CFNumberGetValue(cv, kCFNumberIntType, &rawMax) && rawMax > 0) out->max_capacity = rawMax;
            // v260：不要用 NominalChargeCapacity 兜底满充容量。它同时是健康度的
            // 分母，兜底后两者相等、健康度会恒等于 100% —— 制造新的假数据。
            int rawCur = 0;
            cv = CFDictionaryGetValue(bdd, CFSTR("RemainingCapacity"));
            if (cv && CFNumberGetValue(cv, kCFNumberIntType, &rawCur) && rawCur > 0) out->current_capacity = rawCur;
        } else {
            // v260：Apple Silicon 的根 MaxCapacity 常是百分比 100 而不是 mAh；
            // 直接当容量会算出「最大容量 100 mAh / 健康度 2%」这种假数据。
            // 值小于 200 一律判为百分比并丢弃，宁可让 UI 显示「不可用」。
            cv = CFDictionaryGetValue(props, CFSTR("MaxCapacity"));
            if (cv && CFNumberGetValue(cv, kCFNumberIntType, &iv) && iv > 200)
                out->max_capacity = iv;
        }
        // 设计容量：根节点 → BatteryData（官方同路径；本机仅 BatteryData 有）
        cv = CFDictionaryGetValue(props, CFSTR("DesignCapacity"));
        if (cv && CFNumberGetValue(cv, kCFNumberIntType, &iv) && iv > 0) out->design_capacity = iv;
        if (out->design_capacity <= 0 && bdd) {
            cv = CFDictionaryGetValue(bdd, CFSTR("DesignCapacity"));
            if (cv && CFNumberGetValue(cv, kCFNumberIntType, &iv) && iv > 0) out->design_capacity = iv;
        }
        // v260：标称（额定）容量。健康度有两个口径，差得不少（本机 4056/4629=88%
        // 对 4056/4183=97%），只报一个必然被用户当成「不准」——两个都读出来并列显示。
        cv = CFDictionaryGetValue(props, CFSTR("NominalChargeCapacity"));
        if (cv && CFNumberGetValue(cv, kCFNumberIntType, &iv) && iv > 0) out->nominal_capacity = iv;
        if (out->nominal_capacity <= 0 && bdd) {
            cv = CFDictionaryGetValue(bdd, CFSTR("NominalChargeCapacity"));
            if (cv && CFNumberGetValue(cv, kCFNumberIntType, &iv) && iv > 0) out->nominal_capacity = iv;
        }
        cv = CFDictionaryGetValue(props, CFSTR("CycleCount")); if (cv && CFNumberGetValue(cv, kCFNumberIntType, &iv)) out->cycle_count = iv;
        cv = CFDictionaryGetValue(props, CFSTR("Temperature")); if (cv && CFNumberGetValue(cv, kCFNumberDoubleType, &dv)) {
            out->temperature = dv / 100.0;  // 单位 0.01°C
        }
        // v27：温度回退链（官方 getTemperature）：根 Temperature → BatteryData → SMC TB1T/TB2T 均值。
        //   本机根节点无有效温度（实测 0），必须回退，否则电池页「温度」行消失。
        if (out->temperature <= 0) {
            if (bdd) {
                cv = CFDictionaryGetValue(bdd, CFSTR("Temperature"));
                if (cv && CFNumberGetValue(cv, kCFNumberDoubleType, &dv) && dv > 0) out->temperature = dv / 100.0;
            }
        }
        if (out->temperature <= 0) {
            double t1 = frset_smc_read_key("TB1T"), t2 = frset_smc_read_key("TB2T");
            int n = 0; double acc = 0;
            if (t1 == t1 && t1 > 0) { acc += t1; n++; }
            if (t2 == t2 && t2 > 0) { acc += t2; n++; }
            if (n > 0) out->temperature = acc / n;
        }
        CFBooleanRef b;
        b = CFDictionaryGetValue(props, CFSTR("IsCharging"));
        out->is_charging = (b && CFBooleanGetValue(b));
        b = CFDictionaryGetValue(props, CFSTR("ExternalConnected"));
        out->external_connected = (b && CFBooleanGetValue(b));
        b = CFDictionaryGetValue(props, CFSTR("FullyCharged"));
        out->fully_charged = (b && CFBooleanGetValue(b));
        long long ll = 0;
        cv = CFDictionaryGetValue(props, CFSTR("Voltage")); if (cv && CFNumberGetValue(cv, kCFNumberSInt64Type, &ll)) out->voltage_mv = (double)ll;
        cv = CFDictionaryGetValue(props, CFSTR("Amperage")); if (cv && CFNumberGetValue(cv, kCFNumberSInt64Type, &ll)) out->amperage_ma = (double)ll;
        // v27 追加：电源适配器段（对照官方 Modules/Battery/readers.swift:146-175）
        //   AdapterDetails → AdapterVoltage(mV)；ChargerData → ChargingCurrent(mA)/ChargingVoltage(mV)
        CFDictionaryRef ad = NULL;
        cv = CFDictionaryGetValue(props, CFSTR("AdapterDetails"));
        if (cv && CFGetTypeID(cv) == CFDictionaryGetTypeID()) ad = (CFDictionaryRef)cv;
        if (ad) {
            int mv = 0;
            cv = CFDictionaryGetValue(ad, CFSTR("AdapterVoltage"));
            if (cv && CFNumberGetValue(cv, kCFNumberIntType, &mv) && mv > 0) out->adapter_voltage_v = mv / 1000.0;
        }
        CFDictionaryRef cd = NULL;
        cv = CFDictionaryGetValue(props, CFSTR("ChargerData"));
        if (cv && CFGetTypeID(cv) == CFDictionaryGetTypeID()) cd = (CFDictionaryRef)cv;
        if (cd) {
            int ma = 0, mv = 0;
            cv = CFDictionaryGetValue(cd, CFSTR("ChargingCurrent"));
            if (cv && CFNumberGetValue(cv, kCFNumberIntType, &ma)) out->charging_current_ma = ma;
            cv = CFDictionaryGetValue(cd, CFSTR("ChargingVoltage"));
            if (cv && CFNumberGetValue(cv, kCFNumberIntType, &mv) && mv > 0) out->charging_voltage_v = mv / 1000.0;
        }
        // 电池功率：ARM 上官方优先 SMC PPBR，回退 电压×电流；Intel 只有 电压×电流
        out->battery_power_w = (out->voltage_mv / 1000.0) * (out->amperage_ma / 1000.0);
#if defined(__arm64__) || defined(__aarch64__)
        double ppbr = frset_smc_read_key("PPBR");
        if (ppbr == ppbr && ppbr >= 0 && ppbr < 1000) out->battery_power_w = ppbr;
#endif
        // 适配器功率：SMC PDTR（官方同键）；无法读取时回退 ChargerData 的 充电电压×充电电流
        double pdtr = frset_smc_read_key("PDTR");
        if (pdtr == pdtr && pdtr >= 0 && pdtr < 1000) out->adapter_power_w = pdtr;
        else if (out->charging_voltage_v > 0) out->adapter_power_w = out->charging_voltage_v * (out->charging_current_ma / 1000.0);
        // 百分比：优先 CurrentCapacity（本身就是百分比），回退到容量比值
        //   ⚠️ max_capacity 现在可能是 mAh，直接比值会算错，故必须优先用 CurrentCapacity。
        cv = CFDictionaryGetValue(props, CFSTR("CurrentCapacity"));
        if (cv && CFNumberGetValue(cv, kCFNumberIntType, &iv) && iv >= 0) {
            // v260：Apple Silicon 这里是 0...100 的 SoC 百分比；Intel 机型可能给
            // mAh（>100），此时改走容量比值，否则界面会显示「4000%」。
            if (iv <= 100) out->percent = iv;
            else if (out->max_capacity > 0)
                out->percent = (int)(100.0 * (double)out->current_capacity
                                     / (double)out->max_capacity + 0.5);
        } else if (out->max_capacity > 0) {
            out->percent = (int)(100.0 * (double)out->current_capacity
                                 / (double)out->max_capacity + 0.5);
        }
        if (out->percent > 100) out->percent = 100;
        if (out->percent < 0) out->percent = 0;
        out->present = 1;
        CFRelease(props);
    }
    // v27：适配器标称功率（官方 IOPSCopyExternalPowerAdapterDetails → "Watts"）。
    //   未接适配器/无该信息时返回 NULL，保持 0 即可（UI 不显示 " / 0 W"）。
    CFDictionaryRef acd = IOPSCopyExternalPowerAdapterDetails();
    if (acd) {
        int w = 0;
        CFTypeRef wv = CFDictionaryGetValue(acd, CFSTR("Watts"));   // kIOPSPowerAdapterWattsKey
        if (wv && CFNumberGetValue(wv, kCFNumberIntType, &w) && w > 0) out->adapter_watts = w;
        CFRelease(acd);
    }
    /* v126：句柄已缓存在 g_battSvc，此处不再 IOObjectRelease（仅失效时才释放重取） */
}

// ============ v4 追加：磁盘容量（statfs） ============

void frset_disk_capacity(uint64_t *total, uint64_t *freeb) {
    struct statfs sf;
    if (statfs("/", &sf) == 0) {
        if (total) *total = (uint64_t)sf.f_blocks * sf.f_bsize;
        if (freeb) *freeb = (uint64_t)sf.f_bavail * sf.f_bsize;
    } else {
        if (total) *total = 0;
        if (freeb) *freeb = 0;
    }
}

// ============ v4 追加：网络 IPv4（en0） ============

void frset_net_ip(char *buf, int buflen) {
    buf[0] = 0;
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return;
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        if (strcmp(p->ifa_name, "en0") != 0) continue;
        struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
        inet_ntop(AF_INET, &sin->sin_addr, buf, buflen);
        break;
    }
    freeifaddrs(ifa);
}

// ============ v4：续航估算（IOPS） ============

double frset_battery_remaining_sec(void) {
    return IOPSGetTimeRemainingEstimate();   // -1=计算中, -2=无限(接电源)
}

// ============ v17：进程排行 / 运行时间 / 内存压力 / GPU / 风扇 ============

#include <libproc.h>
#include <time.h>


int frset_mem_pressure(void) {
    int level = 0;
    size_t len = sizeof(level);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, NULL, 0) != 0) return 0;
    return level;
}

static double frset_nowsec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* v128（CPU 优化）：FRSET_PROC_CAP 2048 → 512。
   · 内存：g_pPrev[4][CAP]（136B/项）1.06MB → 265KB，cur+score 同步缩小（-220KB），
     合计省约 1MB 静态堆。
   · 截断语义：frset_proc_top 用 proc_listallpids 枚举 pid（返回 n），扫描循环以
     ncur < FRSET_PROC_CAP 为界；进程数 > 512 时**只扫描前 512 个 pid**（枚举序、
     非用量序），Top 表可能漏掉枚举序靠后的进程。Top 表只展示前 N 个
     （readProcList max=8），macOS 常态进程数 300-700，可接受。
   · 边界：cur/score/g_pPrev 所有写入都在 `ncur < FRSET_PROC_CAP` 条件内，不会越界；
     g_pPrevN[k] = ncur（ncur 恒 ≤ CAP）。 */
#define FRSET_PROC_CAP 512

typedef struct {
    int pid;
    uint64_t ut, st, rb, wb;
    double mem, cpu, dr, dw;
    char name[64];
} frset_proc_raw_t;

// v86：每个维度（0=CPU 1=内存 2=磁盘 3=网络）各自保留上一轮快照。
// 原来共用一份：同一 tick 里连续取 CPU/内存/磁盘时，第 2、3 次调用 dt≈0 →
// havePrev=0 → 磁盘读写速率恒为 0（磁盘页进程表全 0 B/s 的根因）。
static frset_proc_raw_t g_pPrev[4][FRSET_PROC_CAP];
static int g_pPrevN[4] = {0, 0, 0, 0};
static double g_pPrevT[4] = {0, 0, 0, 0};

/* v128（CPU 优化）：共享扫描缓存（200ms）。
   readProcList 同一刷新周期对 kind 0/1/2 连调三次 frset_proc_top，原实现每次都
   proc_listallpids + 全量 proc_pid_rusage/proc_name（3×~500 次系统调用/周期）。
   进程原始计数（ut/st/rb/wb/mem/name）与 kind 无关，缓存一次扫描 200ms 内复用；
   速率仍按各 kind 自己的上一轮快照（g_pPrev[k]）差分，数值口径不变。
   缓存命中时 t 回拨到扫描时刻，保证 dt 与实际采样窗口一致。 */
static frset_proc_raw_t g_scanCache[FRSET_PROC_CAP];
static int    g_scanCacheN = 0;
static double g_scanCacheT = 0;

int frset_proc_top(int kind, frset_proc_t *out, int max) {
    if (!out || max <= 0) return 0;

    int k = (kind >= 0 && kind < 4) ? kind : 0;
    double t = frset_nowsec();

    /* v128：200ms 内复用上一次扫描；否则重新扫描并填缓存 */
    frset_proc_raw_t *src = g_scanCache;
    int nsrc = g_scanCacheN;
    if (!(g_scanCacheT > 0 && t - g_scanCacheT <= 0.2 && nsrc > 0)) {
        nsrc = 0;
        int n = proc_listallpids(NULL, 0);
        if (n <= 0) return 0;
        int cap = n + 64;
        pid_t *pids = malloc(sizeof(pid_t) * (size_t)cap);
        if (!pids) return 0;
        n = proc_listallpids(pids, (int)(sizeof(pid_t) * (size_t)cap));
        if (n <= 0) { free(pids); return 0; }
        /* 每 pid 两次系统调用（proc_pid_rusage + proc_name）；macOS 无廉价的
           「可见进程」过滤口径，只能按枚举序截断（见 FRSET_PROC_CAP 注释）。
           v128：批量收益来自上面的扫描缓存（三次调用共用一次扫描）。 */
        for (int i = 0; i < n && nsrc < FRSET_PROC_CAP; i++) {
            pid_t pid = pids[i];
            if (pid <= 0) continue;
            struct rusage_info_v4 ri;
            memset(&ri, 0, sizeof(ri));
            if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) continue;
            char name[64] = {0};
            if (proc_name(pid, name, sizeof(name)) <= 0 || name[0] == 0) continue;
            frset_proc_raw_t *r = &g_scanCache[nsrc++];
            memset(r, 0, sizeof(*r));
            r->pid = pid;
            r->ut = ri.ri_user_time;
            r->st = ri.ri_system_time;
            r->rb = ri.ri_diskio_bytesread;
            r->wb = ri.ri_diskio_byteswritten;
            r->mem = (double)ri.ri_phys_footprint;
            strncpy(r->name, name, sizeof(r->name) - 1);
        }
        free(pids);
        g_scanCacheN = nsrc;
        g_scanCacheT = t;
    } else {
        t = g_scanCacheT;   /* v128：缓存命中回拨到扫描时刻（dt 口径一致） */
    }

    double dt = (g_pPrevT[k] > 0) ? (t - g_pPrevT[k]) : 0.0;
    int havePrev = (dt > 0.15);

    static frset_proc_raw_t cur[FRSET_PROC_CAP];
    static double score[FRSET_PROC_CAP];
    int ncur = 0;

    for (int i = 0; i < nsrc && ncur < FRSET_PROC_CAP; i++) {
        frset_proc_raw_t r = src[i];
        int pid = r.pid;
        if (havePrev) {
            for (int j = 0; j < g_pPrevN[k]; j++) {
                if (g_pPrev[k][j].pid != pid) continue;
                r.cpu = (((double)(r.ut - g_pPrev[k][j].ut) + (double)(r.st - g_pPrev[k][j].st)) / 1e9 / dt) * 100.0;
                r.dr = (double)(r.rb - g_pPrev[k][j].rb) / dt;
                r.dw = (double)(r.wb - g_pPrev[k][j].wb) / dt;
                break;
            }
        }
        if (r.cpu < 0) r.cpu = 0;
        if (r.dr < 0) r.dr = 0;
        if (r.dw < 0) r.dw = 0;
        score[ncur] = (kind == 0) ? r.cpu : ((kind == 1) ? r.mem : (r.dr + r.dw));
        memcpy(&cur[ncur], &r, sizeof(r));
        ncur++;
    }

    g_pPrevN[k] = (ncur < FRSET_PROC_CAP) ? ncur : FRSET_PROC_CAP;
    for (int i = 0; i < g_pPrevN[k]; i++) {
        g_pPrev[k][i].pid = cur[i].pid; g_pPrev[k][i].ut = cur[i].ut; g_pPrev[k][i].st = cur[i].st;
        g_pPrev[k][i].rb = cur[i].rb; g_pPrev[k][i].wb = cur[i].wb;
    }
    g_pPrevT[k] = t;

    int m = (max < ncur) ? max : ncur;
    for (int i = 0; i < m; i++) {
        int best = -1;
        for (int j = 0; j < ncur; j++) {
            if (score[j] < 0) continue;
            if (best < 0 || score[j] > score[best]) best = j;
        }
        if (best < 0) { m = i; break; }
        frset_proc_raw_t *r = &cur[best];
        memset(&out[i], 0, sizeof(out[i]));
        out[i].pid = r->pid;
        strncpy(out[i].name, r->name, sizeof(out[i].name) - 1);
        out[i].cpu = r->cpu;
        out[i].mem = r->mem;
        out[i].disk_r = r->dr;
        out[i].disk_w = r->dw;
        char pbuf[4096] = {0};
        if (proc_pidpath(r->pid, pbuf, sizeof(pbuf)) > 0) {
            strncpy(out[i].path, pbuf, sizeof(out[i].path) - 1);
        }
        score[best] = -1;
    }
    /* v128：pids 缓冲已在扫描分支内释放（缓存命中时根本没有 pids） */
    return m;
}

// ============ v84：进程按 App 归类（移植自注入版 v30 / WonderBox 口径） ============
//   路径 → bundle：找第一个 ".app/" 子串，取到 ".app" 为止（如
//   /Applications/Google Chrome.app/Contents/Frameworks/.../Helper → "….app"）。
//   无 .app 的进程（CLI/系统守护进程）以完整可执行路径为键保持独立成行。
//   归类意义：Chrome 的 N 个渲染进程只占一行、可整组退出；图标取宿主 App。

static int frset_bundle_of(const char *path, char *out, size_t n) {
    if (!path || !path[0]) return 0;
    const char *p = strstr(path, ".app/");
    if (!p) return 0;
    size_t len = (size_t)(p - path) + 4;   // 含 ".app"
    if (len == 0 || len >= n) return 0;
    memcpy(out, path, len);
    out[len] = 0;
    return 1;
}

int frset_proc_grouped(int kind, frset_proc_grp_t *out, int max) {
    if (!out || max <= 0) return 0;
    static frset_proc_t tmp[256];
    int n = frset_proc_top(kind, tmp, 256);
    if (n <= 0) return 0;

    static frset_proc_grp_t grps[256];
    static int taken[256];
    int ng = 0;
    for (int i = 0; i < n; i++) {
        char bundle[512] = {0};
        int hasBundle = frset_bundle_of(tmp[i].path, bundle, sizeof(bundle));
        const char *key = hasBundle ? bundle : tmp[i].path;
        if (!key[0]) key = tmp[i].name;
        // 查已有组
        int gi = -1;
        for (int j = 0; j < ng; j++) {
            if (strcmp(grps[j].bundle, key) == 0) { gi = j; break; }
        }
        if (gi < 0) {
            if (ng >= 256) continue;
            gi = ng++;
            memset(&grps[gi], 0, sizeof(grps[gi]));
            snprintf(grps[gi].bundle, sizeof(grps[gi].bundle), "%s", key);
            if (hasBundle) {
                const char *slash = strrchr(key, '/');
                const char *base = slash ? slash + 1 : key;
                size_t bl = strlen(base);
                if (bl > 4 && strcmp(base + bl - 4, ".app") == 0) bl -= 4;
                if (bl >= sizeof(grps[gi].name)) bl = sizeof(grps[gi].name) - 1;
                memcpy(grps[gi].name, base, bl);
                grps[gi].name[bl] = 0;
                snprintf(grps[gi].icon_path, sizeof(grps[gi].icon_path), "%s", key);
            } else {
                snprintf(grps[gi].name, sizeof(grps[gi].name), "%s", tmp[i].name);
                snprintf(grps[gi].icon_path, sizeof(grps[gi].icon_path), "%s", tmp[i].path);
            }
        }
        grps[gi].cpu += tmp[i].cpu;
        grps[gi].mem += tmp[i].mem;
        grps[gi].disk_r += tmp[i].disk_r;
        grps[gi].disk_w += tmp[i].disk_w;
        grps[gi].procCount++;
        if (grps[gi].pidCount < 64) grps[gi].pids[grps[gi].pidCount++] = tmp[i].pid;
    }

    memset(taken, 0, sizeof(taken));
    int m = (max < ng) ? max : ng;
    for (int i = 0; i < m; i++) {
        int best = -1;
        for (int j = 0; j < ng; j++) {
            if (taken[j]) continue;
            if (best < 0) { best = j; continue; }
            double sj = (kind == 1) ? grps[j].mem : ((kind == 2) ? (grps[j].disk_r + grps[j].disk_w) : grps[j].cpu);
            double sb = (kind == 1) ? grps[best].mem : ((kind == 2) ? (grps[best].disk_r + grps[best].disk_w) : grps[best].cpu);
            if (sj > sb) best = j;
        }
        if (best < 0) { m = i; break; }
        out[i] = grps[best];
        taken[best] = 1;
    }
    return m;
}

int frset_kill_bundle(const char *bundle, int force) {
    if (!bundle || !bundle[0]) return 0;
    int me = getpid();
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return 0;
    int cap = n + 64;
    pid_t *pids = malloc(sizeof(pid_t) * (size_t)cap);
    if (!pids) return 0;
    n = proc_listallpids(pids, (int)(sizeof(pid_t) * (size_t)cap));
    if (n <= 0) { free(pids); return 0; }
    size_t blen = strlen(bundle);
    int killed = 0;
    for (int i = 0; i < n; i++) {
        pid_t pid = pids[i];
        if (pid <= 0 || pid == me) continue;   // 跳过自身（防「退出 Frset 面板自爆」）
        char pbuf[4096] = {0};
        if (proc_pidpath(pid, pbuf, sizeof(pbuf)) <= 0) continue;
        int match = (strcmp(pbuf, bundle) == 0) ||
                    (strncmp(pbuf, bundle, blen) == 0 && pbuf[blen] == '/');
        if (!match) continue;
        if (kill(pid, force ? SIGKILL : SIGTERM) == 0) killed++;
    }
    free(pids);
    return killed;
}


int frset_gpu_usage(double *device, double *renderer, double *tiler) {
    // 输出先清零：某些芯片/系统版本缺个别键（如 Tiler Utilization %），
    // 不清零会把调用方未初始化的内存当读数用（v44 修复）
    if (device) *device = 0;
    if (renderer) *renderer = 0;
    if (tiler) *tiler = 0;
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) != KERN_SUCCESS) return -1;
    io_registry_entry_t svc;
    int found = 0;
    while ((svc = IOIteratorNext(iter))) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            CFDictionaryRef stats = CFDictionaryGetValue(props, CFSTR("PerformanceStatistics"));
            if (stats) {
                int v = 0;
                CFNumberRef n = CFDictionaryGetValue(stats, CFSTR("Device Utilization %"));
                if (n && CFNumberGetValue(n, kCFNumberIntType, &v)) { if (device) *device = (double)v / 100.0; found = 1; }
                n = CFDictionaryGetValue(stats, CFSTR("Renderer Utilization %"));
                if (n && CFNumberGetValue(n, kCFNumberIntType, &v)) { if (renderer) *renderer = (double)v / 100.0; }
                n = CFDictionaryGetValue(stats, CFSTR("Tiler Utilization %"));
                if (n && CFNumberGetValue(n, kCFNumberIntType, &v)) { if (tiler) *tiler = (double)v / 100.0; }
            }
            CFRelease(props);
        }
        IOObjectRelease(svc);
        if (found) break;
    }
    IOObjectRelease(iter);
    return found ? 0 : -1;
}

// v25：GPU 型号 —— 读 IOAccelerator 的 "model" 键（可能是 CFData 或 CFString）
//   官方 Stats 的 GPU "Model" 行同源（Modules/GPU/popup.swift）。
//   此前我方误用 CPU 品牌串（machdep.cpu.brand_string）→ 显示成 CPU 型号，属明显错误。
int frset_gpu_model(char *buf, size_t n) {
    if (!buf || n < 2) return -1;
    buf[0] = 0;
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) != KERN_SUCCESS) return -1;
    io_registry_entry_t svc;
    int ok = 0;
    while ((svc = IOIteratorNext(iter))) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            CFTypeRef m = CFDictionaryGetValue(props, CFSTR("model"));
            if (m) {
                if (CFGetTypeID(m) == CFDataGetTypeID()) {
                    CFDataRef d = (CFDataRef)m;
                    CFIndex len = CFDataGetLength(d);
                    if (len > 0 && (size_t)len < n) {
                        memcpy(buf, CFDataGetBytePtr(d), (size_t)len);
                        buf[len] = 0;
                        ok = 1;
                    }
                } else if (CFGetTypeID(m) == CFStringGetTypeID()) {
                    if (CFStringGetCString((CFStringRef)m, buf, n, kCFStringEncodingUTF8)) ok = 1;
                }
            }
            CFRelease(props);
        }
        IOObjectRelease(svc);
        if (ok) break;
    }
    IOObjectRelease(iter);
    return ok ? 0 : -1;
}

// ============ v27：CPU 集群拓扑与分集群占用 ============
// 官方 Modules/CPU/popup.swift：Details 有 Efficiency/Performance/Super cores 行，
//   ColumnChartView 按核心类型分色。拓扑来源：
//   Apple Silicon —— sysctl hw.perflevelN.logicalcpu（N=0 在 M4+ 是 Super、M1~M3 是 Performance）
//   Intel —— 无 perflevel 概念 → 返回 -1，调用方据此隐藏这些行。
// ⚠️ 假设：host_processor_info 的返回顺序为「先 perflevel0、再 perflevel1、再 perflevel2」
//   （Apple Silicon 上普遍成立：前 N 个为高性能核）。
int frset_cpu_clusters(int *superOut, int *effOut, int *medOut) {
    int s = 0, e = 0, m = 0;
    size_t len = sizeof(int);
    if (sysctlbyname("hw.perflevel0.logicalcpu", &s, &len, NULL, 0) != 0 || s <= 0) return -1;
    len = sizeof(int);
    sysctlbyname("hw.perflevel1.logicalcpu", &e, &len, NULL, 0);
    len = sizeof(int);
    sysctlbyname("hw.perflevel2.logicalcpu", &m, &len, NULL, 0);
    if (superOut) *superOut = s;
    if (effOut) *effOut = e;
    if (medOut) *medOut = m;
    return 0;
}

// 按集群统计占用（per_core 按集群顺序排列）；无该集群返回 -1
void frset_cpu_cluster_usage(const frset_cpu_t *cpu, int scpu, int ecpu, int mcpu,
                             double *sUsage, double *eUsage, double *mUsage) {
    int i = 0; double acc = 0; int n = 0;
    for (; i < scpu && i < cpu->core_count; i++) { acc += cpu->per_core[i]; n++; }
    if (sUsage) *sUsage = n ? acc / n : -1;
    acc = 0; n = 0;
    for (; i < scpu + ecpu && i < cpu->core_count; i++) { acc += cpu->per_core[i]; n++; }
    if (eUsage) *eUsage = n ? acc / n : -1;
    acc = 0; n = 0;
    for (; i < scpu + ecpu + mcpu && i < cpu->core_count; i++) { acc += cpu->per_core[i]; n++; }
    if (mUsage) *mUsage = n ? acc / n : -1;
}

double frset_smc_read_fan(int idx) {
    if (!g_conn) { if (frset_smc_open() != 0) return -1; }
    char key[5];
    snprintf(key, sizeof(key), "F%dAc", idx);
    SMCKeyData_t info;
    memset(&info, 0, sizeof(info));
    if (smc_keyinfo(str2key(key), &info) != 0) return -1;
    uint8_t buf[32];
    memset(buf, 0, sizeof(buf));
    uint32_t size = 0, type = 0;
    if (smc_read(str2key(key), buf, &size, &type) != 0) return -1;
    double v = parse_value(type, buf, size);
    if (v <= 0 || v > 20000) return -1;
    return v;
}

// v27：通用 SMC 单键读取（PDTR=适配器功率 W、PPBR=电池功率 W 等）。失败/无键返回 NAN。
double frset_smc_read_key(const char *key) {
    if (!key || !key[0]) return NAN;
    if (!g_conn) { if (frset_smc_open() != 0) return NAN; }
    uint8_t buf[32];
    memset(buf, 0, sizeof(buf));
    uint32_t size = 0, type = 0;
    if (smc_read(str2key(key), buf, &size, &type) != 0) return NAN;
    double v = parse_value(type, buf, size);
    if (v <= -9998) return NAN;   // 未识别的类型
    return v;
}

// v27：SMC 字符串键（如 F0ID，类型 "ch8*"）。返回 0=成功。
int frset_smc_read_string(const char *key, char *buf, int buflen) {
    if (!key || !key[0] || !buf || buflen <= 1) return -1;
    buf[0] = 0;
    if (!g_conn) { if (frset_smc_open() != 0) return -1; }
    uint8_t raw[32];
    memset(raw, 0, sizeof(raw));
    uint32_t size = 0, type = 0;
    if (smc_read(str2key(key), raw, &size, &type) != 0) return -1;
    char t[5]; key2str(type, t);
    if (strcmp(t, "ch8*") != 0) return -1;
    int n = (int)size; if (n > buflen - 1) n = buflen - 1;
    memcpy(buf, raw, n);
    buf[n] = 0;
    // 去掉首尾空白/不可见字符
    int i = 0; while (i < n && (buf[i] == ' ' || buf[i] == 0)) i++;
    if (i > 0) memmove(buf, buf + i, n - i + 1);
    int len = (int)strlen(buf);
    while (len > 0 && (buf[len-1] == ' ' || (unsigned char)buf[len-1] < 0x20)) buf[--len] = 0;
    return 0;
}

// v27：风扇数量（官方 loadFans 的 count 来源 FNum）。FNum 无效时探测 F0Ac..F3Ac。
int frset_fan_count(void) {
    double fnum = frset_smc_read_key("FNum");
    if (fnum == fnum && fnum >= 0 && fnum < 16) return (int)fnum;
    int n = 0;
    for (int i = 0; i < 4; i++) {
        double v = frset_smc_read_fan(i);
        if (v >= 0 && v < 20000) n = i + 1;
    }
    return n;
}

// ============ v27：网络连通性（对照官方 Net/readers.swift ConnectivityReader） ============
// 实现要点与官方对齐：
//   · 探测目标 1.1.1.1（官方默认 ICMPHost），SOCK_DGRAM/IPPROTO_ICMP（免 root）
//   · 1s 一个来回；latency = RTT(ms)；jitter = |lat-prev| 的 EMA(1/16)（官方同式）
//   · 显示值 = 最近 90 样本均值（官方 latency/jitter 数组长度 90）
//   · 连通性历史 = 90 个状态样本（官方 GridChartView 30×3 网格）
//   · 载荷用 CLOCK_MONOTONIC 时间戳做指纹（官方用 UUID），回包需匹配 id/seq/指纹

#include <pthread.h>
#include <unistd.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/ip.h>

static frset_conn_t g_netConn = { -1, 0, 0, 0, 0, {0}, 0 };
static pthread_mutex_t g_netConnMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_t g_netConnThread;
static int g_netConnThreadStarted = 0;
/* v128（CPU 优化）：连通性探测可暂停。conn 历史（90 格）只被监测面板网络页消费，
   面板不可见时 1 包/秒的 ICMP 探测没有观众——置 0 后线程空转不发送，恢复后历史
   继续累积（暂停期间没有样本，与「未探测」语义一致）。 */
static volatile int g_netConnActive = 1;

void frset_conn_set_active(int active) {
    g_netConnActive = active ? 1 : 0;
}

static uint16_t frset_icmp_checksum(const uint8_t *d, size_t n) {
    uint32_t sum = 0;
    for (size_t i = 0; i + 1 < n; i += 2) sum += ((uint32_t)d[i] << 8) | d[i + 1];
    if (n & 1) sum += (uint32_t)d[n - 1] << 8;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)(~sum & 0xffff);
}

static void frset_conn_push(frset_conn_t *c, int status, double lat, double jit) {
    // 状态历史（90 滚动）
    if (c->history_count < 90) c->history[c->history_count++] = status;
    else { memmove(c->history, c->history + 1, 89 * sizeof(int)); c->history[89] = status; }
    c->status = status;
    if (lat >= 0) c->latency_ms = lat;
    if (jit >= 0) c->jitter_ms = jit;
    // 均值：由 history 同步维护的 lat/jit 环外置——这里直接用 status 数组长度近似 90 窗口，
    //       真正的 lat/jit 均值在线程里另算（见 frset_conn_thread）。
}

static void *frset_conn_thread(void *arg) {
    (void)arg;
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (sock < 0) return NULL;
    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = 0;
    if (inet_pton(AF_INET, "1.1.1.1", &dst.sin_addr) != 1) { close(sock); return NULL; }

    const uint16_t id = (uint16_t)(getpid() & 0xffff);
    uint16_t seq = 0;
    double prevLat = -1, jitter = 0;
    double latRing[90] = {0}, jitRing[90] = {0};
    int ringN = 0, ringHead = 0;   /* v126：环形缓冲写位置 */
    /* v126（性能审计 F1741）：增量式均值——原实现每秒 O(90) 遍历环求和，
       改为维护运行和，推入/淘汰时 O(1) 更新。 */
    double latSum = 0, jitSum = 0;

    for (;;) {
        /* v128（CPU 优化）：面板不可见（frset_conn_set_active(0)）时暂停发包，
           线程只低频空转；可见性恢复后下一拍立即继续探测。 */
        if (!g_netConnActive) { usleep(500000); continue; }
        seq++;
        uint8_t pkt[8 + 16];
        memset(pkt, 0, sizeof(pkt));
        pkt[0] = 8; pkt[1] = 0;                       // echo request
        pkt[4] = (uint8_t)(id >> 8); pkt[5] = (uint8_t)(id & 0xff);
        pkt[6] = (uint8_t)(seq >> 8); pkt[7] = (uint8_t)(seq & 0xff);
        /* v126（性能审计 F1741）：合并指纹与 RTT 起点为一次 clock_gettime——
           原先 ts（指纹）和 t0（RTT）两次调用相隔仅微秒级，省 1 次 syscall/秒。 */
        struct timespec t0;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        memcpy(pkt + 8, &t0, sizeof(t0));             // 指纹：发送时刻（兼 RTT 起点）
        uint16_t cks = frset_icmp_checksum(pkt, sizeof(pkt));
        pkt[2] = (uint8_t)(cks >> 8); pkt[3] = (uint8_t)(cks & 0xff);

        if (sendto(sock, pkt, sizeof(pkt), 0, (struct sockaddr *)&dst, sizeof(dst)) < 0) {
            usleep(1000000);
            continue;
        }

        // 等待回包：最长 1s（与发送间隔一致，官方 socket 超时 5s 但 isPinging 防重叠）
        int got = 0;
        double lat = -1;
        struct timespec dl = t0;
        dl.tv_nsec += 1000000000L;
        if (dl.tv_nsec >= 1000000000L) { dl.tv_nsec -= 1000000000L; dl.tv_sec += 1; }
        for (;;) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(sock, &rfds);
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long remainMs = (long)((dl.tv_sec - now.tv_sec) * 1000 + (dl.tv_nsec - now.tv_nsec) / 1000000);
            if (remainMs <= 0) break;
            struct timeval tv;
            tv.tv_sec = remainMs / 1000;
            tv.tv_usec = (remainMs % 1000) * 1000;
            int r = select(sock + 1, &rfds, NULL, NULL, &tv);
            if (r <= 0) break;
            uint8_t rbuf[128];
            ssize_t n = recv(sock, rbuf, sizeof(rbuf), 0);
            if (n < 20) continue;
            // 解析 IPv4 头（官方 icmpHeaderOffset：版本 0x40 且协议 IPPROTO_ICMP）
            int ihl = (rbuf[0] & 0x0f) * 4;
            if (ihl < 20 || (rbuf[0] & 0xf0) != 0x40) continue;
            if (rbuf[9] != IPPROTO_ICMP) continue;
            if (n < ihl + 8 + 16) continue;
            const uint8_t *ic = rbuf + ihl;
            if (ic[0] != 0 || ic[1] != 0) continue;                 // echo reply
            if (ic[4] != pkt[4] || ic[5] != pkt[5]) continue;       // id
            if (ic[6] != pkt[6] || ic[7] != pkt[7]) continue;       // seq
            if (memcmp(ic + 8, pkt + 8, 16) != 0) continue;         // 指纹
            struct timespec t1;
            clock_gettime(CLOCK_MONOTONIC, &t1);
            lat = (double)(t1.tv_sec - t0.tv_sec) * 1000.0 + (double)(t1.tv_nsec - t0.tv_nsec) / 1e6;
            got = 1;
            break;
        }

        // 抖动 EMA（官方同式：首个差值直接赋值，之后 jitter += (d - jitter)/16）
        if (got) {
            if (prevLat >= 0) {
                double d = fabs(lat - prevLat);
                jitter += (d - jitter) / 16.0;
            }
            prevLat = lat;
        }

        // 推入 90 样本环 + 状态历史（官方无论是否连通都追加当前值）
        double pushLat = got ? lat : (prevLat >= 0 ? prevLat : 0);
        double pushJit = jitter;
        /* v126（性能审计 F1741）：环形缓冲 + 增量均值。原实现每秒 memmove 720B×2
           搬移数组 + O(90) 遍历求均值，改为 head 索引循环写 + 运行和 O(1) 更新。 */
        if (ringN < 90) {
            latRing[ringHead] = pushLat; jitRing[ringHead] = pushJit;
            latSum += pushLat; jitSum += pushJit;
            ringHead = (ringHead + 1) % 90;
            ringN++;
        } else {
            latSum += pushLat - latRing[ringHead];
            jitSum += pushJit - jitRing[ringHead];
            latRing[ringHead] = pushLat; jitRing[ringHead] = pushJit;
            ringHead = (ringHead + 1) % 90;
        }
        double avgLat = ringN ? latSum / ringN : 0;
        double avgJit = ringN ? jitSum / ringN : 0;

        pthread_mutex_lock(&g_netConnMutex);
        frset_conn_push(&g_netConn, got ? 1 : 0, got ? lat : -1, jitter);
        g_netConn.avg_latency_ms = avgLat;
        g_netConn.avg_jitter_ms = avgJit;
        pthread_mutex_unlock(&g_netConnMutex);

        // 补齐 1s 周期
        struct timespec t2;
        clock_gettime(CLOCK_MONOTONIC, &t2);
        long usedMs = (long)((t2.tv_sec - t0.tv_sec) * 1000 + (t2.tv_nsec - t0.tv_nsec) / 1e6);
        if (usedMs < 1000) usleep((useconds_t)((1000 - usedMs) * 1000));
    }
    close(sock);
    return NULL;
}

void frset_conn_start(void) {
    if (g_netConnThreadStarted) return;
    g_netConnThreadStarted = 1;
    pthread_create(&g_netConnThread, NULL, frset_conn_thread, NULL);
    pthread_detach(g_netConnThread);
}

void frset_conn_sample(frset_conn_t *out) {
    frset_conn_start();
    if (!out) return;
    pthread_mutex_lock(&g_netConnMutex);
    *out = g_netConn;
    pthread_mutex_unlock(&g_netConnMutex);
}

// ============ v27：NVMe SMART（对照官方 Modules/Disk/readers.swift:609-671） ============
// 路径：IOBSDNameMatching("disk0") → 上溯 IOBlockStorageDevice → 检查 "NVMe SMART Capable"
//   → IOCreatePlugInInterfaceForService(kIONVMeSMARTUserClientTypeID)
//   → QueryInterface(kIONVMeSMARTInterfaceID) → SMARTReadData。
// 结构体与 UUID 不在公开 SDK 中，按官方 header.h / readers.swift 定义（字节一致）。

#include <IOKit/IOCFPlugIn.h>

struct frset_nvme_smart_log {
    uint8_t  critical_warning;
    uint8_t  temperature[2];
    uint8_t  avail_spare;
    uint8_t  spare_thresh;
    uint8_t  percent_used;
    uint8_t  rsvd6[26];
    uint8_t  data_units_read[16];
    uint8_t  data_units_written[16];
    uint8_t  host_reads[16];
    uint8_t  host_writes[16];
    uint8_t  ctrl_busy_time[16];
    uint32_t power_cycles[4];
    uint32_t power_on_hours[4];
    uint32_t unsafe_shutdowns[4];
    uint32_t media_errors[4];
    uint8_t  num_err_log_entries[16];
    uint32_t warning_temp_time;
    uint32_t critical_comp_time;
    uint16_t temp_sensor[8];
    uint32_t thm_temp1_trans_count;
    uint32_t thm_temp2_trans_count;
    uint32_t thm_temp1_total_time;
    uint32_t thm_temp2_total_time;
    uint8_t  rsvd232[280];
};

typedef struct frset_ionvme_smart_interface {
    IUNKNOWN_C_GUTS;
    UInt16 version;
    UInt16 revision;
    IOReturn (*SMARTReadData)(void *interface, struct frset_nvme_smart_log *data);
} frset_ionvme_smart_interface;

static io_registry_entry_t frset_block_storage_device(const char *bsd) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd));
    if (!svc) return 0;
    io_registry_entry_t cur = svc;
    for (int g = 0; g < 16 && IOObjectConformsTo(cur, "IOBlockStorageDevice") == 0; g++) {
        io_registry_entry_t parent = 0;
        if (IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent) != KERN_SUCCESS) { IOObjectRelease(cur); return 0; }
        IOObjectRelease(cur);
        cur = parent;
    }
    if (IOObjectConformsTo(cur, "IOBlockStorageDevice") == 0) { IOObjectRelease(cur); return 0; }
    return cur;
}

// 内部 30s 缓存（官方 Disk_updateSMARTInterval 默认 30；SMARTReadData 是真实硬件查询，勿每秒调用）
int frset_disk_smart(frset_smart_t *out) {
    static frset_smart_t cache;
    static time_t lastRead = 0;
    time_t now = time(NULL);
    if (out == NULL) return -1;
    if (lastRead != 0 && now - lastRead < 30) {
        *out = cache;
        return cache.available ? 0 : -1;
    }
    memset(&cache, 0, sizeof(cache));
    lastRead = now;

    io_registry_entry_t dev = frset_block_storage_device("disk0");
    if (!dev) { *out = cache; return -1; }
    CFTypeRef cap = IORegistryEntryCreateCFProperty(dev, CFSTR("NVMe SMART Capable"), kCFAllocatorDefault, 0);
    int capable = cap && CFGetTypeID(cap) == CFBooleanGetTypeID() && CFBooleanGetValue(cap);
    if (cap) CFRelease(cap);
    if (!capable) { IOObjectRelease(dev); *out = cache; return -1; }

    CFUUIDRef ucType = CFUUIDCreateFromString(NULL, CFSTR("AA0FA6F9-C2D6-457F-B10B-59A13253292F"));
    CFUUIDRef ifType = CFUUIDCreateFromString(NULL, CFSTR("CCD1DB19-FD9A-4DAF-BF95-12454B230AB6"));
    CFUUIDRef iocfType = CFUUIDCreateFromString(NULL, CFSTR("C244E858-109C-11D4-91D4-0050E4C6426F"));
    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(dev, ucType, iocfType, &plug, &score);
    if (kr == KERN_SUCCESS && plug) {
        frset_ionvme_smart_interface **smart = NULL;
        HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(ifType), (LPVOID *)&smart);
        if (hr == S_OK && smart) {
            struct frset_nvme_smart_log log;
            memset(&log, 0, sizeof(log));
            if ((*smart)->SMARTReadData(smart, &log) == KERN_SUCCESS) {
                uint16_t kelvin = 0;
                memcpy(&kelvin, log.temperature, 2);   // LE（官方 [.1,.0] + bigEndian 反转为等效 LE）
                cache.temperature_c = kelvin > 273 ? (int)kelvin - 273 : 0;
                cache.life = log.percent_used <= 100 ? 100 - log.percent_used : 0;
                cache.available_spare = log.avail_spare;
                cache.spare_threshold = log.spare_thresh;
                cache.critical_warning = log.critical_warning;
                uint32_t v = 0;
                memcpy(&v, log.power_cycles, 4);     cache.power_cycles = (int)v;
                memcpy(&v, log.power_on_hours, 4);   cache.power_on_hours = (int)v;
                memcpy(&v, log.unsafe_shutdowns, 4); cache.unsafe_shutdowns = (int)v;
                memcpy(&v, log.media_errors, 4);     cache.media_errors = v;
                unsigned long long units = 0;
                memcpy(&units, log.data_units_read, 8);    cache.total_read = units * 512000ULL;    // 512B × 1000
                memcpy(&units, log.data_units_written, 8); cache.total_written = units * 512000ULL;
                cache.available = 1;
            }
            (*plug)->Release(plug);
        }
        IODestroyPlugInInterface(plug);
    }
    CFRelease(ucType); CFRelease(ifType); CFRelease(iocfType);
    IOObjectRelease(dev);
    *out = cache;
    return cache.available ? 0 : -1;
}

int frset_disk_model(char *buf, int n) {
    if (!buf || n <= 1) return -1;
    buf[0] = 0;
    io_registry_entry_t dev = frset_block_storage_device("disk0");
    if (!dev) return -1;
    int ok = -1;
    CFTypeRef dc = IORegistryEntryCreateCFProperty(dev, CFSTR("Device Characteristics"), kCFAllocatorDefault, 0);
    if (dc && CFGetTypeID(dc) == CFDictionaryGetTypeID()) {
        CFTypeRef pn = CFDictionaryGetValue((CFDictionaryRef)dc, CFSTR("Product Name"));
        if (pn && CFGetTypeID(pn) == CFStringGetTypeID())
            ok = CFStringGetCString((CFStringRef)pn, buf, n, kCFStringEncodingUTF8) ? 0 : -1;
    }
    if (dc) CFRelease(dc);
    IOObjectRelease(dev);
    return ok;
}

int frset_disk_interconnect(char *buf, int n) {
    if (!buf || n <= 1) return -1;
    buf[0] = 0;
    io_registry_entry_t dev = frset_block_storage_device("disk0");
    if (!dev) return -1;
    int ok = -1;
    CFTypeRef pc = IORegistryEntryCreateCFProperty(dev, CFSTR("Protocol Characteristics"), kCFAllocatorDefault, 0);
    if (pc && CFGetTypeID(pc) == CFDictionaryGetTypeID()) {
        CFTypeRef pi = CFDictionaryGetValue((CFDictionaryRef)pc, CFSTR("Physical Interconnect"));
        if (pi && CFGetTypeID(pi) == CFStringGetTypeID())
            ok = CFStringGetCString((CFStringRef)pi, buf, n, kCFStringEncodingUTF8) ? 0 : -1;
    }
    if (pc) CFRelease(pc);
    IOObjectRelease(dev);
    return ok;
}

// ============ v27：Net Top processes（对照官方 Modules/Net/readers.swift:850-930） ============
// 官方：/usr/bin/nettop -P -L 1 -n -k ...（一次采样约 1s）→ CSV 解析（name.pid,rx,tx）
//   → 与上次读数差分 = 区间字节数。因采样耗时 1s，放后台线程（每 5s 一轮），UI 只读缓存。
// 名称：nettop 会把进程名截断到 15 字符 → 用 proc_name(pid) 取全名，proc_pidpath 取路径（图标）。

static frset_proc_t g_netTop[16];
static int g_netTopN = 0;
static pthread_mutex_t g_netTopMutex = PTHREAD_MUTEX_INITIALIZER;
static int g_netTopStarted = 0;
/* v128（CPU 优化）：nettop 轮询可暂停。每轮 popen("/usr/bin/nettop") 要创建子进程
   并实测 ~1s 采样，是后台常驻开销的大头；消费者只有面板的网络占用进程表，
   不可见时暂停轮询（frset_net_top_set_active(0)），可见时恢复 5s 一轮。 */
static volatile int g_netTopActive = 1;

void frset_net_top_set_active(int active) {
    g_netTopActive = active ? 1 : 0;
}

static void *frset_net_top_thread(void *arg) {
    (void)arg;
    struct { int pid; unsigned long long rx, tx; } prev[256];
    int prevN = 0;
    struct timespec prevT;
    clock_gettime(CLOCK_MONOTONIC, &prevT);
    int firstRound = 1;

    for (;;) {
        /* v128（CPU 优化）：不可见时不 popen nettop，只低频空转等待恢复 */
        if (!g_netTopActive) { sleep(1); continue; }
        struct { int pid; char name[64]; unsigned long long rx, tx; } cur[256];
        int curN = 0;
        FILE *fp = popen("/usr/bin/nettop -P -L 1 -n -k time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch 2>/dev/null", "r");
        if (fp) {
            char line[1024];
            int first = 1;
            while (fgets(line, sizeof(line), fp) && curN < 256) {
                if (first) { first = 0; continue; }   // 表头 ",bytes_in,bytes_out,"
                char *c1 = strchr(line, ',');
                if (!c1) continue;
                *c1 = 0;
                char *c2 = strchr(c1 + 1, ',');
                if (!c2) continue;
                *c2 = 0;
                char *c3 = strchr(c2 + 1, ',');
                if (c3) *c3 = 0;
                int pid = 0;
                char *dot = strrchr(line, '.');
                if (dot) { pid = atoi(dot + 1); *dot = 0; }
                cur[curN].pid = pid;
                snprintf(cur[curN].name, sizeof(cur[curN].name), "%s", line);
                cur[curN].rx = strtoull(c1 + 1, NULL, 10);
                cur[curN].tx = strtoull(c2 + 1, NULL, 10);
                curN++;
            }
            pclose(fp);

            if (!firstRound) {
                struct timespec now;
                clock_gettime(CLOCK_MONOTONIC, &now);
                double dt = (double)(now.tv_sec - prevT.tv_sec) + (double)(now.tv_nsec - prevT.tv_nsec) / 1e9;
                if (dt < 0.5) dt = 0.5;
                frset_proc_t top[16];
                int topN = 0;
                for (int i = 0; i < curN; i++) {
                    unsigned long long prx = 0, ptx = 0;
                    for (int k = 0; k < prevN; k++) {
                        if (prev[k].pid == cur[i].pid) { prx = prev[k].rx; ptx = prev[k].tx; break; }
                    }
                    double drx = cur[i].rx > prx ? (double)(cur[i].rx - prx) / dt : 0;   // 计数清零→0（官方同）
                    double dtx = cur[i].tx > ptx ? (double)(cur[i].tx - ptx) / dt : 0;
                    if (drx < 1 && dtx < 1) continue;
                    if (topN >= 16) break;
                    frset_proc_t *e = &top[topN++];
                    memset(e, 0, sizeof(*e));
                    e->pid = cur[i].pid;
                    // 全名：proc_name 优先（nettop 截断 15 字符），路径用于图标（其它页同款渲染）
                    // v86 修复：proc_pidpath 的缓冲区必须 ≥ PROC_PIDPATHINFO_MAXSIZE(4096)，
                    // 之前用 512 时**恒定返回 0**（路径空 → 网络页图标/归类全失效）。
                    char nb[64] = {0};
                    char pb[4096] = {0};
                    if (cur[i].pid > 0) {
                        if (proc_name(cur[i].pid, nb, sizeof(nb)) <= 0 || !nb[0])
                            snprintf(nb, sizeof(nb), "%s", cur[i].name);
                        if (proc_pidpath(cur[i].pid, pb, sizeof(pb)) <= 0) pb[0] = 0;
                    } else {
                        snprintf(nb, sizeof(nb), "%s", cur[i].name);
                    }
                    snprintf(e->name, sizeof(e->name), "%s", nb);
                    snprintf(e->path, sizeof(e->path), "%s", pb);
                    e->disk_r = drx;   // 复用字段：disk_r=下载 B/s，disk_w=上传 B/s
                    e->disk_w = dtx;
                }
                // 按 max(下载,上传) 降序（官方同）
                for (int a = 0; a < topN; a++)
                    for (int b = a + 1; b < topN; b++) {
                        double ma = top[a].disk_r > top[a].disk_w ? top[a].disk_r : top[a].disk_w;
                        double mb = top[b].disk_r > top[b].disk_w ? top[b].disk_r : top[b].disk_w;
                        if (mb > ma) { frset_proc_t t = top[a]; top[a] = top[b]; top[b] = t; }
                    }
                pthread_mutex_lock(&g_netTopMutex);
                g_netTopN = topN;
                memcpy(g_netTop, top, sizeof(frset_proc_t) * topN);
                pthread_mutex_unlock(&g_netTopMutex);
            }

            prevN = 0;
            for (int i = 0; i < curN && prevN < 256; i++) {
                prev[prevN].pid = cur[i].pid;
                prev[prevN].rx = cur[i].rx;
                prev[prevN].tx = cur[i].tx;
                prevN++;
            }
            prevT = (struct timespec){0};
            clock_gettime(CLOCK_MONOTONIC, &prevT);
            firstRound = 0;
        }
        sleep(5);   // 官方轮询间隔即进程读取周期；nettop 采样 1s + 5s 间隔对 CPU 足够友好
    }
    return NULL;
}

int frset_net_top(frset_proc_t *out, int max) {
    if (!g_netTopStarted) { g_netTopStarted = 1; pthread_t t; pthread_create(&t, NULL, frset_net_top_thread, NULL); pthread_detach(t); }
    if (!out || max <= 0) return 0;
    pthread_mutex_lock(&g_netTopMutex);
    int n = g_netTopN < max ? g_netTopN : max;
    memcpy(out, g_netTop, sizeof(frset_proc_t) * n);
    pthread_mutex_unlock(&g_netTopMutex);
    return n;
}

// ============ v178：CPU 能耗排行（电池页「CPU 能耗影响」） ============
//
// 口径：proc_pid_rusage(RUSAGE_INFO_V6) 的 ri_energy_nj（纳焦），对同一 pid
// 两帧差分 → 瓦。首次调用只建基线（否则差分会把「进程启动至今的累计能耗」
// 当成这一秒的功率，出现几万瓦的假峰值）。
//
// 为什么不用 rusage_info_v4：本机 SDK（macOS 27）里 v4 只有
// ri_billed_energy / ri_serviced_energy，实测恒为 0；能耗在 v6 才稳定可读。
// 旧内核上 V6 调用失败 → 返回 -1，Swift 侧整体回退成 CPU 活跃度口径，
// 两种量纲绝不混排。

typedef struct {
    int pid;
    uint64_t nj;
} frset_energy_raw_t;

static frset_energy_raw_t g_ePrev[FRSET_PROC_CAP];
static int    g_ePrevN = 0;
static double g_ePrevT = 0;

int frset_proc_energy_pids(frset_energy_pid_t *out, int max, double *elapsedSec) {
    if (elapsedSec) *elapsedSec = 0;
    if (!out || max <= 0) return 0;

    double t = frset_nowsec();

    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return 0;
    int cap = n + 64;
    pid_t *pids = malloc(sizeof(pid_t) * (size_t)cap);
    if (!pids) return 0;
    n = proc_listallpids(pids, (int)(sizeof(pid_t) * (size_t)cap));
    if (n <= 0) { free(pids); return 0; }

    static frset_energy_raw_t cur[FRSET_PROC_CAP];
    int ncur = 0, v6ok = 0;
    for (int i = 0; i < n && ncur < FRSET_PROC_CAP; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        struct rusage_info_v6 ri;
        memset(&ri, 0, sizeof(ri));
        if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) continue;
        v6ok = 1;
        cur[ncur].pid = pid;
        cur[ncur].nj = ri.ri_energy_nj;
        ncur++;
    }
    free(pids);
    if (!v6ok) return -1;   /* 旧内核：让调用方回退 */

    int ready = (g_ePrevT > 0 && (t - g_ePrevT) >= 0.5 && g_ePrevN > 0);
    double dt = ready ? (t - g_ePrevT) : 0.0;
    int m = 0;

    if (ready) {
        static frset_energy_pid_t rows[FRSET_PROC_CAP];
        static double score[FRSET_PROC_CAP];
        int nr = 0;
        for (int i = 0; i < ncur && nr < FRSET_PROC_CAP; i++) {
            uint64_t prev = 0; int found = 0;
            for (int j = 0; j < g_ePrevN; j++) {
                if (g_ePrev[j].pid == cur[i].pid) { prev = g_ePrev[j].nj; found = 1; break; }
            }
            /* 新进程（无基线）或计数回退（pid 复用 / 唤醒后清零）→ 本轮不计 */
            if (!found || cur[i].nj <= prev) continue;
            double watts = (double)(cur[i].nj - prev) / 1e9 / dt;
            if (watts <= 0.00005) continue;   /* 50 µW 以下视为噪声 */
            memset(&rows[nr], 0, sizeof(rows[nr]));
            rows[nr].pid = cur[i].pid;
            rows[nr].watts = watts;
            if (proc_name(cur[i].pid, rows[nr].name, sizeof(rows[nr].name)) <= 0) continue;
            if (!rows[nr].name[0]) continue;
            /* ⚠️ proc_pidpath 的缓冲必须 ≥ PROC_PIDPATHINFO_MAXSIZE(4096)：
               给 512 时即使真实路径只有 50 字节，内核也直接返回 0 并置 errno=ENOMEM
               （实测 macOS 27：rc=0 errno=12）。这与 frset_proc_top 里用 4096
               局部缓冲是同一原因；写进结构体前再截断到 512。 */
            {
                char fullPath[PROC_PIDPATHINFO_MAXSIZE] = {0};
                if (proc_pidpath(cur[i].pid, fullPath, sizeof(fullPath)) > 0 && fullPath[0]) {
                    strncpy(rows[nr].path, fullPath, sizeof(rows[nr].path) - 1);
                }
            }
            score[nr] = watts;
            nr++;
        }
        int take = (max < nr) ? max : nr;
        for (int i = 0; i < take; i++) {
            int best = -1;
            for (int j = 0; j < nr; j++) {
                if (score[j] < 0) continue;
                if (best < 0 || score[j] > score[best]) best = j;
            }
            if (best < 0) { take = i; break; }
            out[i] = rows[best];
            score[best] = -1;
        }
        m = take;
        if (elapsedSec) *elapsedSec = dt;
    }

    g_ePrevN = ncur;
    for (int i = 0; i < ncur; i++) g_ePrev[i] = cur[i];
    g_ePrevT = t;
    return m;
}
