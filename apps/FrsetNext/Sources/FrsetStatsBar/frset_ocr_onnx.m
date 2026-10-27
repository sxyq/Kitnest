//
//  frset_ocr_onnx.m —— 本地 PP-OCR 识别模型（ONNX Runtime）封装
//
//  用途：给截图 OCR 提供**离线中文识别**能力（PaddleOCR PP-OCRv4 mobile rec，
//  与 ZTools 使用的本地 PaddleOCR 同源）。Apple Vision 负责"在哪"（文本行检测），
//  这里负责"是什么"（逐行识别），两者互补。
//
//  为什么用 dlopen 而不是直接链接：
//    · 构建脚本只编译 Sources/FrsetStatsBar 下的 .c/.m 并交给 swiftc 链接，
//      不想为一个可选依赖去改链接参数；
//    · 运行时加载允许"模型/运行库缺失时静默降级回 Vision"（本地 OCR 是增强项，
//      不是硬依赖）。
//
//  线程安全：会话创建/推理均在调用方线程串行执行（OCR 已在后台队列）。

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "onnxruntime_c_api.h"

typedef void *FSPPOCRSession;

/// 创建会话：libPath = libonnxruntime.dylib 路径，modelPath = .onnx 路径
/// 失败返回 NULL，并把原因写入 errBuf。
FSPPOCRSession FSPPOCRSessionCreate(const char *libPath, const char *modelPath,
                                    char *errBuf, int errCap) {
    if (errBuf && errCap > 0) errBuf[0] = '\0';
    if (!libPath || !modelPath) {
        if (errBuf && errCap > 0) snprintf(errBuf, (size_t)errCap, "invalid path");
        return NULL;
    }
    // 关遥测必须**在 dlopen 之前**用环境变量——ORT 在库初始化时就读它，
    // 之后调 DisableTelemetryEvents 只能关事件、关不掉已经建好的 1DS 上报通道。
    // 不关的后果：每次推理都往
    //   ~/Library/Application Support/Microsoft/DeveloperTools/.onnxruntime/onnxruntime.db
    // 写 WAL（实测 +1~2KB/次，还会留一个 deviceid 标识文件）。本地 OCR 不需要这些。
    setenv("ORT_DISABLE_TELEMETRY", "1", 1);
    void *lib = dlopen(libPath, RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        if (errBuf && errCap > 0) snprintf(errBuf, (size_t)errCap, "dlopen: %s", dlerror());
        return NULL;
    }
    const OrtApiBase *(*getBase)(void) = (const OrtApiBase *(*)(void))dlsym(lib, "OrtGetApiBase");
    if (!getBase) {
        if (errBuf && errCap > 0) snprintf(errBuf, (size_t)errCap, "OrtGetApiBase symbol missing");
        dlclose(lib);
        return NULL;
    }
    const OrtApi *api = getBase()->GetApi(ORT_API_VERSION);
    if (!api) {
        if (errBuf && errCap > 0) snprintf(errBuf, (size_t)errCap, "OrtGetApi version mismatch");
        dlclose(lib);
        return NULL;
    }
    OrtEnv *env = NULL;
    OrtSessionOptions *opts = NULL;
    OrtSession *session = NULL;
    OrtStatus *st = api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "frset-ocr", &env);
    if (st) {
        if (errBuf && errCap > 0) snprintf(errBuf, (size_t)errCap, "%s", api->GetErrorMessage(st));
        api->ReleaseStatus(st);
        dlclose(lib);
        return NULL;
    }
    // 关掉 ONNX Runtime 的遥测事件：默认开启，会在
    // ~/Library/Application Support/Microsoft/DeveloperTools/.onnxruntime/ 建 SQLite 库
    // 并在**每次推理**时写 WAL（实测每次识别 +1~2KB，只增不减）。本地 OCR 不需要它。
    {
        OrtStatus *ts = api->DisableTelemetryEvents(env);
        if (ts) api->ReleaseStatus(ts);
    }
    st = api->CreateSessionOptions(&opts);
    if (!st && opts) {
        OrtStatus *t2 = api->SetIntraOpNumThreads(opts, 2);
        if (t2) api->ReleaseStatus(t2);
    }
    if (st) {
        if (errBuf && errCap > 0) snprintf(errBuf, (size_t)errCap, "%s", api->GetErrorMessage(st));
        api->ReleaseStatus(st);
        api->ReleaseEnv(env);
        dlclose(lib);
        return NULL;
    }
    st = api->CreateSession(env, modelPath, opts, &session);
    if (st) {
        if (errBuf && errCap > 0) snprintf(errBuf, (size_t)errCap, "%s", api->GetErrorMessage(st));
        api->ReleaseStatus(st);
        api->ReleaseSessionOptions(opts);
        api->ReleaseEnv(env);
        dlclose(lib);
        return NULL;
    }

    // 会话上下文：api / env / session / options / lib
    typedef struct {
        const OrtApi *api;
        OrtEnv *env;
        OrtSession *session;
        OrtSessionOptions *opts;
        void *lib;
    } Ctx;
    Ctx *ctx = (Ctx *)calloc(1, sizeof(Ctx));
    ctx->api = api;
    ctx->env = env;
    ctx->session = session;
    ctx->opts = opts;
    ctx->lib = lib;
    return (FSPPOCRSession)ctx;
}

void FSPPOCRSessionDestroy(FSPPOCRSession handle) {
    if (!handle) return;
    typedef struct {
        const OrtApi *api;
        OrtEnv *env;
        OrtSession *session;
        OrtSessionOptions *opts;
        void *lib;
    } Ctx;
    Ctx *ctx = (Ctx *)handle;
    if (ctx->session) ctx->api->ReleaseSession(ctx->session);
    if (ctx->opts) ctx->api->ReleaseSessionOptions(ctx->opts);
    if (ctx->env) ctx->api->ReleaseEnv(ctx->env);
    if (ctx->lib) dlclose(ctx->lib);
    free(ctx);
}

/// 推理：input 为 CHW 排列的 float32（1×3×H×W），返回 malloc 的 T×C 原始输出，
/// 调用方用 FSPPOCRFree 释放。outT/outC 返回时间步与字典维度。
float *FSPPOCRRun(FSPPOCRSession handle, const float *input, int64_t height, int64_t width,
                   int64_t *outT, int64_t *outC) {
    if (!handle || !input || height <= 0 || width <= 0) return NULL;
    typedef struct {
        const OrtApi *api;
        OrtEnv *env;
        OrtSession *session;
        OrtSessionOptions *opts;
        void *lib;
    } Ctx;
    Ctx *ctx = (Ctx *)handle;
    const OrtApi *api = ctx->api;

    OrtMemoryInfo *memInfo = NULL;
    OrtStatus *st = api->CreateCpuMemoryInfo(OrtDeviceAllocator, OrtMemTypeDefault, &memInfo);
    if (st) { api->ReleaseStatus(st); return NULL; }

    int64_t dims[4] = {1, 3, height, width};
    OrtValue *inputTensor = NULL;
    st = api->CreateTensorWithDataAsOrtValue(memInfo, (void *)input,
                                             (size_t)(height * width * 3 * sizeof(float)),
                                             dims, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &inputTensor);
    if (st) { api->ReleaseStatus(st); api->ReleaseMemoryInfo(memInfo); return NULL; }

    // 取模型真实的输入/输出名（不同导出版本名字不一样，不能写死）
    OrtAllocator *allocator = NULL;
    api->GetAllocatorWithDefaultOptions(&allocator);
    char *inName = NULL, *outName = NULL;
    // 名字可能来自 ORT 分配器，也可能是下面的字面量兜底——只有前者能 AllocatorFree，
    // 否则等于 free 一个字符串常量（堆损坏，实测概率性崩溃）。
    int inOwned = 0, outOwned = 0;
    st = api->SessionGetInputName(ctx->session, 0, allocator, &inName);
    if (st) { api->ReleaseStatus(st); inName = NULL; }
    else if (inName) { inOwned = 1; }
    st = api->SessionGetOutputName(ctx->session, 0, allocator, &outName);
    if (st) { api->ReleaseStatus(st); outName = NULL; }
    else if (outName) { outOwned = 1; }
    if (!inName) inName = (char *)"x";
    if (!outName) outName = (char *)"output";

    const char *inputNames[1] = { inName };
    const char *outputNames[1] = { outName };
    OrtValue *outputTensor = NULL;
    st = api->Run(ctx->session, NULL, inputNames, (const OrtValue *const *)&inputTensor, 1,
                  outputNames, 1, &outputTensor);
    if (st) {
        api->ReleaseStatus(st);
        api->ReleaseValue(inputTensor);
        api->ReleaseMemoryInfo(memInfo);
        if (allocator && inOwned) api->AllocatorFree(allocator, inName);
        if (allocator && outOwned) api->AllocatorFree(allocator, outName);
        return NULL;
    }

    OrtTensorTypeAndShapeInfo *info = NULL;
    st = api->GetTensorTypeAndShape(outputTensor, &info);
    if (st) {
        api->ReleaseStatus(st);
        api->ReleaseValue(outputTensor);
        api->ReleaseValue(inputTensor);
        api->ReleaseMemoryInfo(memInfo);
        if (allocator && inOwned) api->AllocatorFree(allocator, inName);
        if (allocator && outOwned) api->AllocatorFree(allocator, outName);
        return NULL;
    }
    size_t dimCount = 0;
    api->GetDimensionsCount(info, &dimCount);
    int64_t t = 0, c = 0;
    if (dimCount >= 2) {
        int64_t d[8] = {0};
        api->GetDimensions(info, d, 8);
        t = d[dimCount - 2];
        c = d[dimCount - 1];
    }
    api->ReleaseTensorTypeAndShapeInfo(info);

    float *src = NULL;
    st = api->GetTensorMutableData(outputTensor, (void **)&src);
    float *copy = NULL;
    if (!st && src && t > 0 && c > 0) {
        copy = (float *)malloc((size_t)(t * c * sizeof(float)));
        if (copy) memcpy(copy, src, (size_t)(t * c * sizeof(float)));
    }
    if (st) api->ReleaseStatus(st);

    api->ReleaseValue(outputTensor);
    api->ReleaseValue(inputTensor);
    api->ReleaseMemoryInfo(memInfo);
    if (allocator) {
        if (inOwned) api->AllocatorFree(allocator, inName);
        if (outOwned) api->AllocatorFree(allocator, outName);
    }
    if (outT) *outT = t;
    if (outC) *outC = c;
    return copy;
}

void FSPPOCRFree(float *data) {
    if (data) free(data);
}
