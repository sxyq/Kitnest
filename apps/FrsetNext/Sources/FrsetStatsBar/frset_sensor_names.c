// frset_sensor_names.c - SMC 传感器 key 到人类可读名
// 来源：官方 Stats Modules/Sensors/values.swift 的 SensorsList（v27 提取，212 项去重）
//   key 中的 % 为单字符通配（如 TA%P 匹配 TA0P/TA1P/TA2P）
//   group: 0=sensor 1=CPU 2=GPU 3=system ｜ type: 0=温度 1=电压 2=电流 3=功率 4=能耗 5=风扇 ｜ avg=官方 average 标记
//   ⚠️ v27b：新增 type/avg 两列（计算项 Average/Hottest CPU/GPU 需要官方同口径筛选）
#include <stddef.h>   // NULL
#include "frset_sensor_names.h"

typedef struct { const char *key; const char *name; int group; int type; int avg; } fsn_entry_t;
static const fsn_entry_t kFSNames[] = {
    {"TA%P", "Ambient %", 0, 0, 0},
    {"Th%H", "Heatpipe %", 0, 0, 0},
    {"TZ%C", "Thermal zone %", 0, 0, 0},
    {"TC0D", "CPU diode", 1, 0, 0},
    {"TC0E", "CPU diode virtual", 1, 0, 0},
    {"TC0F", "CPU diode filtered", 1, 0, 0},
    {"TC0H", "CPU heatsink", 1, 0, 0},
    {"TC0P", "CPU proximity", 1, 0, 0},
    {"TCAD", "CPU package", 1, 0, 0},
    {"TCAC", "CPU A core die", 1, 0, 1},
    {"TCBC", "CPU B core die", 1, 0, 1},
    {"TCAH", "CPU A heatsink", 1, 0, 0},
    {"TCBH", "CPU B heatsink", 1, 0, 0},
    {"TC%c", "CPU core %", 1, 0, 1},
    {"TC%C", "CPU Core %", 1, 0, 1},
    {"TCGC", "GPU Intel Graphics", 2, 0, 0},
    {"TG0D", "GPU diode", 2, 0, 0},
    {"TGDD", "GPU AMD Radeon", 2, 0, 0},
    {"TG0H", "GPU heatsink", 2, 0, 0},
    {"TG0P", "GPU proximity", 2, 0, 0},
    {"Tm0P", "Mainboard", 3, 0, 0},
    {"Tp0P", "Powerboard", 3, 0, 0},
    {"TB1T", "Battery", 3, 0, 0},
    {"TW0P", "Airport", 3, 0, 0},
    {"TL0P", "Display", 3, 0, 0},
    {"TI%P", "Thunderbolt %", 3, 0, 0},
    {"TH%A", "Disk % (A)", 3, 0, 0},
    {"TH%B", "Disk % (B)", 3, 0, 0},
    {"TH%C", "Disk % (C)", 3, 0, 0},
    {"TTLD", "Thunderbolt left", 3, 0, 0},
    {"TTRD", "Thunderbolt right", 3, 0, 0},
    {"TN0D", "Northbridge diode", 3, 0, 0},
    {"TN0H", "Northbridge heatsink", 3, 0, 0},
    {"TN0P", "Northbridge proximity", 3, 0, 0},
    {"TMA1", "Memory riser A slot 1", 3, 0, 0},
    {"TMA2", "Memory riser A slot 2", 3, 0, 0},
    {"TMA3", "Memory riser A slot 3", 3, 0, 0},
    {"TMA4", "Memory riser A slot 4", 3, 0, 0},
    {"TMB1", "Memory riser B slot 1", 3, 0, 0},
    {"TMB2", "Memory riser B slot 2", 3, 0, 0},
    {"TMB3", "Memory riser B slot 3", 3, 0, 0},
    {"TMB4", "Memory riser B slot 4", 3, 0, 0},
    {"Tp09", "CPU efficiency core 1", 1, 0, 1},
    {"Tp0T", "CPU efficiency core 2", 1, 0, 1},
    {"Tp01", "CPU performance core 1", 1, 0, 1},
    {"Tp05", "CPU performance core 2", 1, 0, 1},
    {"Tp0D", "CPU performance core 3", 1, 0, 1},
    {"Tp0H", "CPU performance core 4", 1, 0, 1},
    {"Tp0L", "CPU performance core 5", 1, 0, 1},
    {"Tp0X", "CPU performance core 7", 1, 0, 1},
    {"Tp0b", "CPU performance core 8", 1, 0, 1},
    {"Tg05", "GPU 1", 2, 0, 1},
    {"Tg0D", "GPU 2", 2, 0, 1},
    {"Tg0L", "GPU 3", 2, 0, 1},
    {"Tg0T", "GPU 4", 2, 0, 1},
    {"Tm02", "Memory 1", 0, 0, 0},
    {"Tm06", "Memory 2", 0, 0, 0},
    {"Tm08", "Memory 3", 0, 0, 0},
    {"Tm09", "Memory 4", 0, 0, 0},
    {"Tp1h", "CPU efficiency core 1", 1, 0, 1},
    {"Tp1t", "CPU efficiency core 2", 1, 0, 1},
    {"Tp1p", "CPU efficiency core 3", 1, 0, 1},
    {"Tp1l", "CPU efficiency core 4", 1, 0, 1},
    {"Tp0f", "CPU performance core 7", 1, 0, 1},
    {"Tp0j", "CPU performance core 8", 1, 0, 1},
    {"Tg0f", "GPU 1", 2, 0, 1},
    {"Tg0j", "GPU 2", 2, 0, 1},
    {"Te05", "CPU efficiency core 1", 1, 0, 1},
    {"Te0L", "CPU efficiency core 2", 1, 0, 1},
    {"Te0P", "CPU efficiency core 3", 1, 0, 1},
    {"Te0S", "CPU efficiency core 4", 1, 0, 1},
    {"Tf04", "CPU performance core 1", 1, 0, 1},
    {"Tf09", "CPU performance core 2", 1, 0, 1},
    {"Tf0A", "CPU performance core 3", 1, 0, 1},
    {"Tf0B", "CPU performance core 4", 1, 0, 1},
    {"Tf0D", "CPU performance core 5", 1, 0, 1},
    {"Tf0E", "CPU performance core 6", 1, 0, 1},
    {"Tf44", "CPU performance core 7", 1, 0, 1},
    {"Tf49", "CPU performance core 8", 1, 0, 1},
    {"Tf4A", "CPU performance core 9", 1, 0, 1},
    {"Tf4B", "CPU performance core 10", 1, 0, 1},
    {"Tf4D", "CPU performance core 11", 1, 0, 1},
    {"Tf4E", "CPU performance core 12", 1, 0, 1},
    {"Tf14", "GPU 1", 2, 0, 1},
    {"Tf18", "GPU 2", 2, 0, 1},
    {"Tf19", "GPU 3", 2, 0, 1},
    {"Tf1A", "GPU 4", 2, 0, 1},
    {"Tf24", "GPU 5", 2, 0, 1},
    {"Tf28", "GPU 6", 2, 0, 1},
    {"Tf29", "GPU 7", 2, 0, 1},
    {"Tf2A", "GPU 8", 2, 0, 1},
    {"Te09", "CPU efficiency core 3", 1, 0, 1},
    {"Te0H", "CPU efficiency core 4", 1, 0, 1},
    {"Tp0V", "CPU performance core 5", 1, 0, 1},
    {"Tp0Y", "CPU performance core 6", 1, 0, 1},
    {"Tp0e", "CPU performance core 8", 1, 0, 1},
    {"Tg0G", "GPU 1", 2, 0, 1},
    {"Tg0H", "GPU 2", 2, 0, 1},
    {"Tg1U", "GPU 1", 2, 0, 1},
    {"Tg1k", "GPU 2", 2, 0, 1},
    {"Tg0K", "GPU 3", 2, 0, 1},
    {"Tg0d", "GPU 5", 2, 0, 1},
    {"Tg0e", "GPU 6", 2, 0, 1},
    {"Tg0k", "GPU 8", 2, 0, 1},
    {"Tm0p", "Memory Proximity 1", 0, 0, 0},
    {"Tm1p", "Memory Proximity 2", 0, 0, 0},
    {"Tm2p", "Memory Proximity 3", 0, 0, 0},
    {"Tp00", "CPU super core 1", 1, 0, 1},
    {"Tp04", "CPU super core 2", 1, 0, 1},
    {"Tp08", "CPU super core 3", 1, 0, 1},
    {"Tp0C", "CPU super core 4", 1, 0, 1},
    {"Tp0G", "CPU super core 5", 1, 0, 1},
    {"Tp0K", "CPU super core 6", 1, 0, 1},
    {"Tp0O", "CPU performance core 1", 1, 0, 1},
    {"Tp0R", "CPU performance core 2", 1, 0, 1},
    {"Tp0U", "CPU performance core 3", 1, 0, 1},
    {"Tp0a", "CPU performance core 5", 1, 0, 1},
    {"Tp0d", "CPU performance core 6", 1, 0, 1},
    {"Tp0g", "CPU performance core 7", 1, 0, 1},
    {"Tp0m", "CPU performance core 9", 1, 0, 1},
    {"Tp0p", "CPU performance core 10", 1, 0, 1},
    {"Tp0u", "CPU performance core 11", 1, 0, 1},
    {"Tp0y", "CPU performance core 12", 1, 0, 1},
    {"Tg0U", "GPU 1", 2, 0, 1},
    {"Tg0X", "GPU 2", 2, 0, 1},
    {"Tg0g", "GPU 4", 2, 0, 1},
    {"Tg1Y", "GPU 6", 2, 0, 1},
    {"Tg1c", "GPU 7", 2, 0, 1},
    {"Tg1g", "GPU 8", 2, 0, 1},
    {"Tp07", "CPU super core 4", 1, 0, 1},
    {"Tp0I", "CPU performance core 3", 1, 0, 1},
    {"Tp0E", "CPU performance core 5", 1, 0, 1},
    {"Te07", "CPU efficiency core 1", 1, 0, 1},
    {"Te08", "CPU efficiency core 2", 1, 0, 1},
    {"Te0c", "CPU efficiency core 4", 1, 0, 1},
    {"Te0h", "CPU efficiency core 5", 1, 0, 1},
    {"Te0i", "CPU efficiency core 6", 1, 0, 1},
    {"Tg1e", "GPU 1", 2, 0, 1},
    {"Tg0c", "GPU 3", 2, 0, 1},
    {"Tg0b", "GPU 4", 2, 0, 1},
    {"Tg1d", "GPU 6", 2, 0, 1},
    {"Tg07", "GPU 7", 2, 0, 1},
    {"Tg1f", "GPU 8", 2, 0, 1},
    {"Tg09", "GPU 9", 2, 0, 1},
    {"Tg0a", "GPU 10", 2, 0, 1},
    {"Tg1h", "GPU 12", 2, 0, 1},
    {"TaLP", "Airflow left", 0, 0, 0},
    {"TaRF", "Airflow right", 0, 0, 0},
    {"TH0x", "NAND", 3, 0, 0},
    {"TB2T", "Battery 2", 3, 0, 0},
    {"VCAC", "CPU IA", 1, 1, 0},
    {"VCSC", "CPU System Agent", 1, 1, 0},
    {"VC%C", "CPU Core %", 1, 1, 0},
    {"VCTC", "GPU Intel Graphics", 2, 1, 0},
    {"VG0C", "GPU", 2, 1, 0},
    {"VM0R", "Memory", 3, 1, 0},
    {"Vb0R", "CMOS", 3, 1, 0},
    {"VD0R", "DC In", 0, 1, 0},
    {"VP0R", "12V rail", 0, 1, 0},
    {"Vp0C", "12V vcc", 0, 1, 0},
    {"VV2S", "3V", 0, 1, 0},
    {"VR3R", "3.3V", 0, 1, 0},
    {"VV1S", "5V", 0, 1, 0},
    {"VV9S", "12V", 0, 1, 0},
    {"VeES", "PCI 12V", 0, 1, 0},
    {"IC0R", "CPU High side", 0, 2, 0},
    {"IG0R", "GPU High side", 0, 2, 0},
    {"ID0R", "DC In", 0, 2, 0},
    {"IBAC", "Battery", 0, 2, 0},
    {"IDBR", "Brightness", 0, 2, 0},
    {"IU1R", "Thunderbolt Left", 0, 2, 0},
    {"IU2R", "Thunderbolt Right", 0, 2, 0},
    {"PC0C", "CPU Core", 1, 3, 0},
    {"PCAB", "CPU A core power (PCAB)", 1, 3, 0},
    {"PCAC", "CPU A core power (PCAC)", 1, 3, 0},
    {"PCBB", "CPU B core power (PCBB)", 1, 3, 0},
    {"PCBC", "CPU B core power (PCBC)", 1, 3, 0},
    {"PCAM", "CPU Core (IMON)", 1, 3, 0},
    {"PCPC", "CPU Package", 1, 3, 0},
    {"PCTR", "CPU Total", 1, 3, 0},
    {"PCPT", "CPU Package total", 1, 3, 0},
    {"PCPR", "CPU Package total (SMC)", 1, 3, 0},
    {"PC0R", "CPU Computing high side", 1, 3, 0},
    {"PC0G", "CPU GFX", 1, 3, 0},
    {"PCEC", "CPU VccEDRAM", 1, 3, 0},
    {"PCPG", "GPU Intel Graphics", 2, 3, 0},
    {"PG0C", "GPU", 2, 3, 0},
    {"PG0R", "GPU 1", 2, 3, 0},
    {"PG1R", "GPU 2", 2, 3, 0},
    {"PCGC", "Intel GPU", 2, 3, 0},
    {"PCGM", "Intel GPU (IMON)", 2, 3, 0},
    {"PC3C", "RAM", 0, 3, 0},
    {"PPBR", "Battery", 0, 3, 0},
    {"PDTR", "DC In", 0, 3, 0},
    {"PMTR", "Memory Total", 0, 3, 0},
    {"PSTR", "System Total", 0, 3, 0},
    {"PN0C", "Northbridge", 3, 3, 0},
    {"PU1R", "Thunderbolt Left", 0, 3, 0},
    {"PU2R", "Thunderbolt Right", 0, 3, 0},
    {"PDBR", "Power Delivery Brightness", 0, 3, 0},
    {"PBwo", "Display Backlight", 0, 3, 0},
    {"pACC MTR Temp Sensor%", "CPU performance core %", 1, 0, 0},
    {"eACC MTR Temp Sensor%", "CPU efficiency core %", 1, 0, 0},
    {"GPU MTR Temp Sensor%", "GPU core %", 2, 0, 0},
    {"SOC MTR Temp Sensor%", "SOC core %", 0, 0, 0},
    {"ANE MTR Temp Sensor%", "Neural engine %", 0, 0, 0},
    {"ISP MTR Temp Sensor%", "Image Signal Processor %", 0, 0, 0},
    {"PMGR SOC Die Temp Sensor%", "Power manager die %", 0, 0, 0},
    {"PMU tdev%", "Power management unit dev %", 0, 0, 0},
    {"PMU tdie%", "Power management unit die %", 0, 0, 0},
    {"gas gauge battery", "Battery", 0, 0, 0},
    {"NAND CH% temp", "Disk %s", 2, 0, 0},
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

int frset_sensor_names_count(void) { return kFSNamesN; }
