// frset_stats_data.h — 注入版采集层（C，无 Swift 依赖）
// SMC 采集移植自已验证的 smc_probe.c；系统数据用 sysctl/host_statistics

#ifndef FRSET_STATS_DATA_H
#define FRSET_STATS_DATA_H

#include <stdint.h>
#include <stddef.h>   // v25：size_t（frset_gpu_model 的参数用）

// ---- SMC ----
typedef struct {
    char key[5];
    double value;
    int category;   // 0=温度 1=风扇 2=电压 3=电流 4=功耗 5=电池
} frset_sensor_t;

/// 打开 AppleSMC。返回 0=成功。
int frset_smc_open(void);
void frset_smc_close(void);
/// 枚举全部传感器（返回数量；out 可为 NULL 探测数量）
int frset_smc_scan(frset_sensor_t *out, int max_count);

// ---- CPU ----
typedef struct {
    double usage;      // 0..1
    double system, user, idle;
    double per_core[32];
    int core_count;
} frset_cpu_t;

typedef struct {
    uint64_t total;
    uint64_t used;
    uint64_t compressed;
    uint64_t wired;   // v17：联动内存（wire_count）
    uint64_t swap_used;
    uint64_t swap_total;
} frset_mem_t;

typedef struct {
    uint64_t up_bps, down_bps;
    uint64_t total_up, total_down;
} frset_net_t;

typedef struct {
    uint64_t read_bps, write_bps;
} frset_disk_t;

void frset_cpu_sample(frset_cpu_t *out);   // 需周期调用（内部差分）
void frset_loadavg(double *l1, double *l5, double *l15);
void frset_mem_sample(frset_mem_t *out);
void frset_net_sample(frset_net_t *out);
void frset_disk_sample(frset_disk_t *out);

// ---- 格式化工具 ----
void frset_fmt_bytes(uint64_t v, char *buf, int buflen);
void frset_fmt_rate(uint64_t v, char *buf, int buflen);

#endif

// ============ v4 追加 ============

typedef struct {
    int present;            // 1=有电池
    int percent;            // 0..100
    int is_charging;        // 是否在充电
    int external_connected; // 是否接电源
    int fully_charged;      // 是否充满
    int cycle_count;        // 循环次数
    int design_capacity;    // 设计容量 mAh
    int max_capacity;       // 当前最大容量 mAh
    int current_capacity;   // 当前电量 mAh
    double temperature;     // 电池温度 °C（可能无效）
    double voltage_mv;      // v17：电压 mV
    double amperage_ma;     // v17：电流 mA（正=充电/输入）
    // v27 追加：电源适配器段（对照官方 Modules/Battery/readers.swift）
    double adapter_power_w;     // 适配器功率 W（SMC PDTR）
    double battery_power_w;     // 电池功率 W（ARM: SMC PPBR；否则 电压×电流/1000）
    double adapter_voltage_v;   // 适配器电压 V（IORegistry AdapterDetails/1000）
    double adapter_watts;       // 适配器标称功率 W（IOPSCopyExternalPowerAdapterDetails）
    double charging_current_ma; // 充电电流 mA（ChargerData）
    double charging_voltage_v;  // 充电电压 V（ChargerData/1000）
} frset_battery_t;

void frset_battery_sample(frset_battery_t *out);
void frset_disk_capacity(uint64_t *total, uint64_t *freeb);
void frset_net_ip(char *buf, int buflen);
double frset_battery_remaining_sec(void);   // IOPS 剩余估算秒数（-1=计算中，-2=无限/接电源）

// ============ v17 追加：进程排行 / 运行时间 / 内存压力 / GPU / 风扇 ============

typedef struct {
    int pid;
    char name[64];
    char path[512];
    double cpu;      // 单核百分比（100 = 单核满载）
    double mem;      // footprint 字节
    double disk_r;   // B/s
    double disk_w;   // B/s
} frset_proc_t;

/// 进程排行（kind：0=CPU 1=内存 2=磁盘）。需 ~1..2s 周期调用（内部差分）。
int frset_proc_top(int kind, frset_proc_t *out, int max);

double frset_uptime(void);            // 系统运行秒数
int frset_mem_pressure(void);         // kern.memorystatus_vm_pressure_level（1=正常 2=警告 4=严重 0=未知）
/// GPU 利用率（IOAccelerator PerformanceStatistics）；返回 0=成功，比值 0..1
int frset_gpu_usage(double *device, double *renderer, double *tiler);
/// v25：GPU 型号（IOAccelerator "model"）；返回 0=成功，型号写入 buf
int frset_gpu_model(char *buf, size_t n);
/// v27：CPU 集群拓扑 —— Apple Silicon 读 sysctl hw.perflevelN.logicalcpu（返回 0=成功）
///   本机 M5：Super 4 + Efficiency 6；Intel 无 perflevel → 返回 -1（调用方隐藏集群行）
int frset_cpu_clusters(int *superOut, int *effOut, int *medOut);
/// v27：按集群统计占用（per_core 按集群顺序排列）；无该集群返回 -1
void frset_cpu_cluster_usage(const frset_cpu_t *cpu, int scpu, int ecpu, int mcpu,
                             double *sUsage, double *eUsage, double *mUsage);
/// 风扇转速（SMC F0Ac/F1Ac/F2Ac）；返回 RPM，<0=无
double frset_smc_read_fan(int idx);
/// v27：读取任意 SMC 单键（如 PDTR 适配器功率 / PPBR 电池功率）；失败返回 NAN
double frset_smc_read_key(const char *key);
/// v27：读取 SMC 字符串键（如 F0ID 风扇名，类型 ch8*）；返回 0=成功
int frset_smc_read_string(const char *key, char *buf, int buflen);
/// v27：风扇数量（官方 FNum；无效时探测 F0Ac..F3Ac，0=无风扇）
int frset_fan_count(void);

// ---- v27：NVMe SMART（对照官方 Modules/Disk/readers.swift getNVMeSMART） ----
typedef struct {
    int available;                        // 1=可读
    int temperature_c;                    // NVMe 复合温度（K-273）
    int life;                             // 100 - percent_used
    int power_cycles;
    int power_on_hours;
    int critical_warning;                 // 位掩码
    int available_spare;                  // %
    int spare_threshold;                  // %
    int unsafe_shutdowns;
    unsigned long long media_errors;
    unsigned long long total_read;        // 字节（data units × 512000）
    unsigned long long total_written;
} frset_smart_t;

/// 读取 disk0 的 NVMe SMART（内部 30s 缓存；官方 updateSMARTInterval 默认 30s）。返回 0=成功
int frset_disk_smart(frset_smart_t *out);
/// v27：磁盘型号（IORegistry Device Characteristics → Product Name，如 "APPLE SSD AP0512Z"）；返回 0=成功
int frset_disk_model(char *buf, int n);
/// v27：连接类型（Protocol Characteristics → Physical Interconnect，如 "Apple Fabric"）；返回 0=成功
int frset_disk_interconnect(char *buf, int n);
/// v27：Net 高占用进程（官方 nettop -P -L 1 -n 差分；down_bps/up_bps 复用 disk_r/disk_w 字段）。
///   后台线程每 5s 采样一次；本函数非阻塞读缓存，返回条数（首轮约 6s 后有数据）
int frset_net_top(frset_proc_t *out, int max);

// ---- v27：网络连通性（对照官方 Net/readers.swift ConnectivityReader：ICMP echo → 1.1.1.1，
//      1s 间隔；latency=RTT；jitter=|lat-prev| 的 EMA(1/16)；显示值为最近 90 样本均值） ----
typedef struct {
    int status;              // 1=连通 0=不通 -1=未探测
    double latency_ms;       // 当前 RTT ms
    double jitter_ms;        // 当前抖动 ms（EMA）
    double avg_latency_ms;   // 最近 90 样本延迟均值（官方显示值）
    double avg_jitter_ms;    // 最近 90 样本抖动均值
    int history[90];         // 1/0/-1，[0]最旧 [count-1]最新（连通性历史 30×3 网格）
    int history_count;
} frset_conn_t;

/// 启动后台探测线程（幂等；首次调用即启动，1 包/秒，常驻）
void frset_conn_start(void);
/// 取连通性快照（线程安全）
void frset_conn_sample(frset_conn_t *out);
