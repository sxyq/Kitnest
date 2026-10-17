// frset_runcat_frames.h — 奔跑小猫帧资源接口
// 猫帧来源：RunCat Neo（https://github.com/runcat-dev/RunCatNeo，Apache License 2.0）
//   5 帧循环 · 56×36 PNG 字节 · 黑白双版（浅色菜单栏→黑猫 / 深色→白猫）
#ifndef FRSET_RUNCAT_FRAMES_H
#define FRSET_RUNCAT_FRAMES_H

#ifdef __cplusplus
extern "C" {
#endif

/// 取第 idx 帧（0..4）的 PNG 字节；whiteVariant=1 取白色版。返回数据指针，*outLen 为长度。
const unsigned char *frset_runcat_frame(int idx, int whiteVariant, unsigned int *outLen);
int frset_runcat_frame_count(void);

#ifdef __cplusplus
}
#endif

#endif
