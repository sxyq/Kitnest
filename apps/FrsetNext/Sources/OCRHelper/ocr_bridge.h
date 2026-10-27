#ifndef FRSET_OCR_HELPER_BRIDGE_H
#define FRSET_OCR_HELPER_BRIDGE_H

// 本地 PP-OCR 识别模型的 C 接口（与主 App 的 FrsetStatsBar.h 同一份实现：
// Sources/FrsetStatsBar/frset_ocr_onnx.m）。
// helper 只链接这一个 .m，所以这里单独放一份最小声明，不去 include 整个 App 的桥接头。

#include <stdint.h>

typedef void *FSPPOCRSession;

FSPPOCRSession FSPPOCRSessionCreate(const char *libPath, const char *modelPath,
                                    char *errBuf, int errCap);
void FSPPOCRSessionDestroy(FSPPOCRSession handle);
float *FSPPOCRRun(FSPPOCRSession handle, const float *input, int64_t height, int64_t width,
                  int64_t *outT, int64_t *outC);
void FSPPOCRFree(float *data);

#endif /* FRSET_OCR_HELPER_BRIDGE_H */
