// frset_sensor_names.h - SMC 传感器 key 到人类可读名（对齐官方 Stats SensorsList）
#ifndef FRSET_SENSOR_NAMES_H
#define FRSET_SENSOR_NAMES_H

#ifdef __cplusplus
extern "C" {
#endif

const char *frset_sensor_name(const char *key, int *groupOut);
int frset_sensor_names_count(void);
// v27b：官方 SensorsList 的元数据（计算项 Average/Hottest 用；未收录 key 返回 -1/0）
int frset_sensor_average(const char *key);   // 0/1（官方 average 标记）
int frset_sensor_type(const char *key);      // 0=温度 1=电压 2=电流 3=功率 4=能耗 5=风扇；未收录 -1
int frset_sensor_group(const char *key);     // 0=sensor 1=CPU 2=GPU 3=system；未收录 -1

#ifdef __cplusplus
}
#endif

#endif
