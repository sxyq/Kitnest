// frset_sensor_names.c - SMC 传感器 key 到人类可读名
// 来源：官方 Stats Modules/Sensors/values.swift 的 SensorsList（v27 提取，212 项去重）
//   key 中的 % 为单字符通配（如 TA%P 匹配 TA0P/TA1P/TA2P）
//   group: 0=sensor 1=CPU 2=GPU 3=system ｜ type: 0=温度 1=电压 2=电流 3=功率 4=能耗 5=风扇 ｜ avg=官方 average 标记
//   ⚠️ v27b：新增 type/avg 两列（计算项 Average/Hottest CPU/GPU 需要官方同口径筛选）
#include <stddef.h>   // NULL
#include "frset_sensor_names.h"

typedef struct { const char *key; const char *name; int group; int type; int avg; } fsn_entry_t;
static const fsn_entry_t kFSNames[] = {
    {"TA%P", "环境温度 %", 0, 0, 0},
    {"Th%H", "热管温度 %", 0, 0, 0},
    {"TZ%C", "热区温度 %", 0, 0, 0},
    {"TC0D", "CPU 二极管温度", 1, 0, 0},
    {"TC0E", "CPU 二极管温度（虚拟）", 1, 0, 0},
    {"TC0F", "CPU 二极管温度（滤波）", 1, 0, 0},
    {"TC0H", "CPU 散热器温度", 1, 0, 0},
    {"TC0P", "CPU 近似温度", 1, 0, 0},
    {"TCAD", "CPU 封装温度", 1, 0, 0},
    {"TCAC", "CPU A 核温度", 1, 0, 1},
    {"TCBC", "CPU B 核温度", 1, 0, 1},
    {"TCAH", "CPU A 散热器温度", 1, 0, 0},
    {"TCBH", "CPU B 散热器温度", 1, 0, 0},
    {"TC%c", "CPU 核 % 温度", 1, 0, 1},
    {"TC%C", "CPU 核 % 温度", 1, 0, 1},
    {"TCGC", "GPU 核显温度", 2, 0, 0},
    {"TG0D", "GPU 二极管温度", 2, 0, 0},
    {"TGDD", "GPU Radeon 温度", 2, 0, 0},
    {"TG0H", "GPU 散热器温度", 2, 0, 0},
    {"TG0P", "GPU 近似温度", 2, 0, 0},
    {"Tm0P", "主板温度", 3, 0, 0},
    {"Tp0P", "电源板温度", 3, 0, 0},
    {"TB1T", "电池温度", 3, 0, 0},
    {"TW0P", "无线网卡温度", 3, 0, 0},
    {"TL0P", "屏幕温度", 3, 0, 0},
    {"TI%P", "雷雳接口温度 %", 3, 0, 0},
    {"TH%A", "硬盘温度 %（A）", 3, 0, 0},
    {"TH%B", "硬盘温度 %（B）", 3, 0, 0},
    {"TH%C", "硬盘温度 %（C）", 3, 0, 0},
    {"TTLD", "左侧雷雳温度", 3, 0, 0},
    {"TTRD", "右侧雷雳温度", 3, 0, 0},
    {"TN0D", "北桥二极管温度", 3, 0, 0},
    {"TN0H", "北桥散热器温度", 3, 0, 0},
    {"TN0P", "北桥近似温度", 3, 0, 0},
    {"TMA1", "内存槽 A1 温度", 3, 0, 0},
    {"TMA2", "内存槽 A2 温度", 3, 0, 0},
    {"TMA3", "内存槽 A3 温度", 3, 0, 0},
    {"TMA4", "内存槽 A4 温度", 3, 0, 0},
    {"TMB1", "内存槽 B1 温度", 3, 0, 0},
    {"TMB2", "内存槽 B2 温度", 3, 0, 0},
    {"TMB3", "内存槽 B3 温度", 3, 0, 0},
    {"TMB4", "内存槽 B4 温度", 3, 0, 0},
    {"Tp09", "CPU 能效核 1 温度", 1, 0, 1},
    {"Tp0T", "CPU 能效核 2 温度", 1, 0, 1},
    {"Tp01", "CPU 性能核 1 温度", 1, 0, 1},
    {"Tp05", "CPU 性能核 2 温度", 1, 0, 1},
    {"Tp0D", "CPU 性能核 3 温度", 1, 0, 1},
    {"Tp0H", "CPU 性能核 4 温度", 1, 0, 1},
    {"Tp0L", "CPU 性能核 5 温度", 1, 0, 1},
    {"Tp0X", "CPU 性能核 7 温度", 1, 0, 1},
    {"Tp0b", "CPU 性能核 8 温度", 1, 0, 1},
    {"Tg05", "GPU 1 温度", 2, 0, 1},
    {"Tg0D", "GPU 2 温度", 2, 0, 1},
    {"Tg0L", "GPU 3 温度", 2, 0, 1},
    {"Tg0T", "GPU 4 温度", 2, 0, 1},
    {"Tm02", "内存温度 1", 0, 0, 0},
    {"Tm06", "内存温度 2", 0, 0, 0},
    {"Tm08", "内存温度 3", 0, 0, 0},
    {"Tm09", "内存温度 4", 0, 0, 0},
    {"Tp1h", "CPU 能效核 1 温度", 1, 0, 1},
    {"Tp1t", "CPU 能效核 2 温度", 1, 0, 1},
    {"Tp1p", "CPU 能效核 3 温度", 1, 0, 1},
    {"Tp1l", "CPU 能效核 4 温度", 1, 0, 1},
    {"Tp0f", "CPU 性能核 7 温度", 1, 0, 1},
    {"Tp0j", "CPU 性能核 8 温度", 1, 0, 1},
    {"Tg0f", "GPU 1 温度", 2, 0, 1},
    {"Tg0j", "GPU 2 温度", 2, 0, 1},
    {"Te05", "CPU 能效核 1 温度", 1, 0, 1},
    {"Te0L", "CPU 能效核 2 温度", 1, 0, 1},
    {"Te0P", "CPU 能效核 3 温度", 1, 0, 1},
    {"Te0S", "CPU 能效核 4 温度", 1, 0, 1},
    {"Tf04", "CPU 性能核 1 温度", 1, 0, 1},
    {"Tf09", "CPU 性能核 2 温度", 1, 0, 1},
    {"Tf0A", "CPU 性能核 3 温度", 1, 0, 1},
    {"Tf0B", "CPU 性能核 4 温度", 1, 0, 1},
    {"Tf0D", "CPU 性能核 5 温度", 1, 0, 1},
    {"Tf0E", "CPU 性能核 6 温度", 1, 0, 1},
    {"Tf44", "CPU 性能核 7 温度", 1, 0, 1},
    {"Tf49", "CPU 性能核 8 温度", 1, 0, 1},
    {"Tf4A", "CPU 性能核 9 温度", 1, 0, 1},
    {"Tf4B", "CPU 性能核 10 温度", 1, 0, 1},
    {"Tf4D", "CPU 性能核 11 温度", 1, 0, 1},
    {"Tf4E", "CPU 性能核 12 温度", 1, 0, 1},
    {"Tf14", "GPU 1 温度", 2, 0, 1},
    {"Tf18", "GPU 2 温度", 2, 0, 1},
    {"Tf19", "GPU 3 温度", 2, 0, 1},
    {"Tf1A", "GPU 4 温度", 2, 0, 1},
    {"Tf24", "GPU 5 温度", 2, 0, 1},
    {"Tf28", "GPU 6 温度", 2, 0, 1},
    {"Tf29", "GPU 7 温度", 2, 0, 1},
    {"Tf2A", "GPU 8 温度", 2, 0, 1},
    {"Te09", "CPU 能效核 3 温度", 1, 0, 1},
    {"Te0H", "CPU 能效核 4 温度", 1, 0, 1},
    {"Tp0V", "CPU 性能核 5 温度", 1, 0, 1},
    {"Tp0Y", "CPU 性能核 6 温度", 1, 0, 1},
    {"Tp0e", "CPU 性能核 8 温度", 1, 0, 1},
    {"Tg0G", "GPU 1 温度", 2, 0, 1},
    {"Tg0H", "GPU 2 温度", 2, 0, 1},
    {"Tg1U", "GPU 1 温度", 2, 0, 1},
    {"Tg1k", "GPU 2 温度", 2, 0, 1},
    {"Tg0K", "GPU 3 温度", 2, 0, 1},
    {"Tg0d", "GPU 5 温度", 2, 0, 1},
    {"Tg0e", "GPU 6 温度", 2, 0, 1},
    {"Tg0k", "GPU 8 温度", 2, 0, 1},
    {"Tm0p", "内存近似温度 1", 0, 0, 0},
    {"Tm1p", "内存近似温度 2", 0, 0, 0},
    {"Tm2p", "内存近似温度 3", 0, 0, 0},
    {"Tp00", "CPU 超级核 1 温度", 1, 0, 1},
    {"Tp04", "CPU 超级核 2 温度", 1, 0, 1},
    {"Tp08", "CPU 超级核 3 温度", 1, 0, 1},
    {"Tp0C", "CPU 超级核 4 温度", 1, 0, 1},
    {"Tp0G", "CPU 超级核 5 温度", 1, 0, 1},
    {"Tp0K", "CPU 超级核 6 温度", 1, 0, 1},
    {"Tp0O", "CPU 性能核 1 温度", 1, 0, 1},
    {"Tp0R", "CPU 性能核 2 温度", 1, 0, 1},
    {"Tp0U", "CPU 性能核 3 温度", 1, 0, 1},
    {"Tp0a", "CPU 性能核 5 温度", 1, 0, 1},
    {"Tp0d", "CPU 性能核 6 温度", 1, 0, 1},
    {"Tp0g", "CPU 性能核 7 温度", 1, 0, 1},
    {"Tp0m", "CPU 性能核 9 温度", 1, 0, 1},
    {"Tp0p", "CPU 性能核 10 温度", 1, 0, 1},
    {"Tp0u", "CPU 性能核 11 温度", 1, 0, 1},
    {"Tp0y", "CPU 性能核 12 温度", 1, 0, 1},
    {"Tg0U", "GPU 1 温度", 2, 0, 1},
    {"Tg0X", "GPU 2 温度", 2, 0, 1},
    {"Tg0g", "GPU 4 温度", 2, 0, 1},
    {"Tg1Y", "GPU 6 温度", 2, 0, 1},
    {"Tg1c", "GPU 7 温度", 2, 0, 1},
    {"Tg1g", "GPU 8 温度", 2, 0, 1},
    {"Tp07", "CPU 超级核 4 温度", 1, 0, 1},
    {"Tp0I", "CPU 性能核 3 温度", 1, 0, 1},
    {"Tp0E", "CPU 性能核 5 温度", 1, 0, 1},
    {"Te07", "CPU 能效核 1 温度", 1, 0, 1},
    {"Te08", "CPU 能效核 2 温度", 1, 0, 1},
    {"Te0c", "CPU 能效核 4 温度", 1, 0, 1},
    {"Te0h", "CPU 能效核 5 温度", 1, 0, 1},
    {"Te0i", "CPU 能效核 6 温度", 1, 0, 1},
    {"Tg1e", "GPU 1 温度", 2, 0, 1},
    {"Tg0c", "GPU 3 温度", 2, 0, 1},
    {"Tg0b", "GPU 4 温度", 2, 0, 1},
    {"Tg1d", "GPU 6 温度", 2, 0, 1},
    {"Tg07", "GPU 7 温度", 2, 0, 1},
    {"Tg1f", "GPU 8 温度", 2, 0, 1},
    {"Tg09", "GPU 9 温度", 2, 0, 1},
    {"Tg0a", "GPU 10 温度", 2, 0, 1},
    {"Tg1h", "GPU 12 温度", 2, 0, 1},
    {"TaLP", "左侧气流温度", 0, 0, 0},
    {"TaRF", "右侧气流温度", 0, 0, 0},
    {"TH0x", "固态硬盘温度", 3, 0, 0},
    {"TB2T", "电池温度 2", 3, 0, 0},
    {"VCAC", "CPU IA 电压", 1, 1, 0},
    {"VCSC", "CPU 系统代理电压", 1, 1, 0},
    {"VC%C", "CPU 核 % 电压", 1, 1, 0},
    {"VCTC", "GPU 核显电压", 2, 1, 0},
    {"VG0C", "GPU 电压", 2, 1, 0},
    {"VM0R", "内存电压", 3, 1, 0},
    {"Vb0R", "CMOS 电压", 3, 1, 0},
    {"VD0R", "直流输入电压", 0, 1, 0},
    {"VP0R", "12V 供电电压", 0, 1, 0},
    {"Vp0C", "12V VCC 电压", 0, 1, 0},
    {"VV2S", "3V 电压", 0, 1, 0},
    {"VR3R", "3.3V 电压", 0, 1, 0},
    {"VV1S", "5V 电压", 0, 1, 0},
    {"VV9S", "12V 电压", 0, 1, 0},
    {"VeES", "PCI 12V 电压", 0, 1, 0},
    {"IC0R", "CPU 高侧电流", 0, 2, 0},
    {"IG0R", "GPU 高侧电流", 0, 2, 0},
    {"ID0R", "直流输入电流", 0, 2, 0},
    {"IBAC", "电池电流", 0, 2, 0},
    {"IDBR", "背光电流", 0, 2, 0},
    {"IU1R", "左侧雷雳电流", 0, 2, 0},
    {"IU2R", "右侧雷雳电流", 0, 2, 0},
    {"PC0C", "CPU 核心功耗", 1, 3, 0},
    {"PCAB", "CPU A 核功耗", 1, 3, 0},
    {"PCAC", "CPU A 核功耗（PCAC）", 1, 3, 0},
    {"PCBB", "CPU B 核功耗", 1, 3, 0},
    {"PCBC", "CPU B 核功耗（PCBC）", 1, 3, 0},
    {"PCAM", "CPU 核心功耗（IMON）", 1, 3, 0},
    {"PCPC", "CPU 整体功耗", 1, 3, 0},
    {"PCTR", "CPU 总功耗", 1, 3, 0},
    {"PCPT", "CPU 整体功耗（累计）", 1, 3, 0},
    {"PCPR", "CPU 整体功耗（SMC）", 1, 3, 0},
    {"PC0R", "CPU 计算高侧功耗", 1, 3, 0},
    {"PC0G", "CPU 核显功耗", 1, 3, 0},
    {"PCEC", "CPU EDRAM 功耗", 1, 3, 0},
    {"PCPG", "GPU 核显功耗", 2, 3, 0},
    {"PG0C", "GPU 功耗", 2, 3, 0},
    {"PG0R", "GPU 1 功耗", 2, 3, 0},
    {"PG1R", "GPU 2 功耗", 2, 3, 0},
    {"PCGC", "Intel GPU 功耗", 2, 3, 0},
    {"PCGM", "Intel GPU 功耗（IMON）", 2, 3, 0},
    {"PC3C", "内存功耗", 0, 3, 0},
    {"PPBR", "电池功耗", 0, 3, 0},
    {"PDTR", "直流输入功耗", 0, 3, 0},
    {"PMTR", "内存总功耗", 0, 3, 0},
    {"PSTR", "系统总功耗", 0, 3, 0},
    {"PN0C", "北桥功耗", 3, 3, 0},
    {"PU1R", "左侧雷雳功耗", 0, 3, 0},
    {"PU2R", "右侧雷雳功耗", 0, 3, 0},
    {"PDBR", "背光供电功耗", 0, 3, 0},
    {"PBwo", "屏幕背光功耗", 0, 3, 0},
    // ---- v133：Apple Silicon 键补录（M5 代）----
    // 来源与置信度：
    //   [Asahi]  Asahi Linux macsmc-hwmon 内核驱动标注（权威）
    //   [iSMC]   dkorunic/iSMC temp.txt（社区广泛采用）
    //   [M5实测] sebhildebrandt/macos-smc docs/smc-keys.md（M5 Max 实测报告）
    //   [本机差分] 本机 M5 负载差分 + V×I=P 交叉验证（VP0b×IP0b=PP0b 等精确吻合）
    {"PHPC", "热管功率（SoC 散热估算）", 0, 3, 0},   // [Asahi] heatpipe power
    {"PMVR", "3.8V 轨功率", 0, 3, 0},                 // [Asahi] 3.8V rail power
    {"PMVC", "3.8V 轨功率", 0, 3, 0},                 // [本机差分] VMVC 3.786V × IMVC 2.800A = 10.60 ≈ 10.591 ✓
    {"PZC0", "CPU 负载功率域 ZC0（未定名）", 0, 3, 0}, // [M5实测][本机差分] 随 CPU 负载强响应，含义社区未定名
    {"PZC1", "CPU 负载功率域 ZC1（未定名）", 0, 3, 0}, // 同上（本机 6 核负载 +1.9W）
    {"PHPS", "CPU 负载功率域 HPS（未定名）", 0, 3, 0}, // [M5实测] 随 CPU 负载强响应
    {"PPSM", "CPU 负载功率域 PSM（未定名）", 0, 3, 0}, // [M5实测] 随 CPU 负载强响应
    {"VMVC", "3.8V 轨电压", 0, 1, 0},                 // [本机差分] 实测 3.786V（≈3.8V 标称）
    {"IMVC", "3.8V 轨电流", 0, 2, 0},                 // [本机差分] 实测 2.800A
    {"TCMb", "CPU 裸片平均温度", 1, 0, 0},            // [iSMC] CPU die average（本机负载期 78-96°C）
    {"TB0T", "电池温度", 0, 0, 0},                    // [Asahi] TB*=battery（本机 35.4°C 合理）
    {"TCHP", "充电器温度", 0, 0, 0},                  // [Asahi] charger temperature（本机 49.8°C 合理）
    {"TH0T", "固态硬盘温度", 0, 0, 0},                // [Asahi] TH0x=SSD/NAND（本机 51.5°C 合理）
    {"TMVR", "3.8V 轨温度", 0, 0, 0},                 // MVR 族（与 PMVR 同族；本机 51.7°C 合理）
    {"pACC MTR Temp Sensor%", "CPU 性能核 % 温度", 1, 0, 0},
    {"eACC MTR Temp Sensor%", "CPU 能效核 % 温度", 1, 0, 0},
    {"GPU MTR Temp Sensor%", "GPU 核 % 温度", 2, 0, 0},
    {"SOC MTR Temp Sensor%", "SOC % 温度", 0, 0, 0},
    {"ANE MTR Temp Sensor%", "神经网络引擎 % 温度", 0, 0, 0},
    {"ISP MTR Temp Sensor%", "图像信号处理器 % 温度", 0, 0, 0},
    {"PMGR SOC Die Temp Sensor%", "电源管理器裸片 % 温度", 0, 0, 0},
    {"PMU tdev%", "电源管理单元 % 温度", 0, 0, 0},
    {"PMU tdie%", "电源管理单元裸片 % 温度", 0, 0, 0},
    {"gas gauge battery", "电池温度", 0, 0, 0},
    {"NAND CH% temp", "硬盘 % 温度", 2, 0, 0},
};
static const int kFSNamesN = (int)(sizeof(kFSNames) / sizeof(kFSNames[0]));

// 单字符通配：模板 t（含 % 通配）对 key k 全串匹配（长度相等，仅 % 位任意）
static int fsnKeyMatch(const char *t, const char *k) {
    size_t n = 0;
    for (; t[n] && k[n]; n++) {
        if (t[n] == '%') continue;
        if (t[n] != k[n]) return 0;
    }
    return t[n] == 0 && k[n] == 0;
}

const char *frset_sensor_name(const char *key, int *groupOut) {
    if (!key) return NULL;
    for (int i = 0; i < kFSNamesN; i++) {
        if (fsnKeyMatch(kFSNames[i].key, key)) {
            if (groupOut) *groupOut = kFSNames[i].group;
            return kFSNames[i].name;
        }
    }
    return NULL;
}

// v27b：官方 average 标记（计算项筛选用；未收录 key 返回 0）
int frset_sensor_average(const char *key) {
    if (!key) return 0;
    for (int i = 0; i < kFSNamesN; i++) {
        if (fsnKeyMatch(kFSNames[i].key, key)) return kFSNames[i].avg;
    }
    return 0;
}

// v27b：官方 type（0=温度 1=电压 2=电流 3=功率 4=能耗 5=风扇；未收录返回 -1）
int frset_sensor_type(const char *key) {
    if (!key) return -1;
    for (int i = 0; i < kFSNamesN; i++) {
        if (fsnKeyMatch(kFSNames[i].key, key)) return kFSNames[i].type;
    }
    return -1;
}

// v27b：官方 group（0=sensor 1=CPU 2=GPU 3=system；未收录返回 -1）
int frset_sensor_group(const char *key) {
    if (!key) return -1;
    for (int i = 0; i < kFSNamesN; i++) {
        if (fsnKeyMatch(kFSNames[i].key, key)) return kFSNames[i].group;
    }
    return -1;
}

