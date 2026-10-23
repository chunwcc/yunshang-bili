#include <napi/native_api.h>
#include <string>
#include "video_render.h"

// ══════════════════════════════════════════════
// NAPI 导出函数
// ══════════════════════════════════════════════

// initGL(xcSurfaceId: string, width: number, height: number): string
// 初始化 GL 渲染管线，内部创建 NativeImage，返回其 surfaceId（给 AVPlayer 绑定）
static napi_value InitGL(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 3) {
        napi_throw_error(env, nullptr, "initGL requires 3 arguments");
        return nullptr;
    }

    // 解析 xcSurfaceId
    char xcBuf[64] = { 0 };
    size_t xcLen = 0;
    napi_get_value_string_utf8(env, args[0], xcBuf, sizeof(xcBuf), &xcLen);

    // 解析宽高
    int32_t width = 0, height = 0;
    napi_get_value_int32(env, args[1], &width);
    napi_get_value_int32(env, args[2], &height);

    // 调用渲染器初始化（内部创建 NativeImage）
    uint64_t nativeSurfaceId = 0;
    int ret = VideoRender_Init(xcBuf, width, height, &nativeSurfaceId);
    if (ret != 0) {
        napi_throw_error(env, nullptr, "initGL failed");
        return nullptr;
    }

    // 将 nativeSurfaceId（uint64）转成字符串返回给 ArkTS
    std::string idStr = std::to_string(nativeSurfaceId);
    napi_value result = nullptr;
    napi_create_string_utf8(env, idStr.c_str(), idStr.size(), &result);
    return result;
}

// setStyle(mode: string): void
static napi_value SetStyle(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char buf[32] = { 0 };
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], buf, sizeof(buf), &len);

    int style = 0;
    if      (strcmp(buf, "original") == 0) style = 0;
    else if (strcmp(buf, "vivid") == 0)    style = 1;
    else if (strcmp(buf, "leica") == 0)    style = 2;
    else if (strcmp(buf, "film") == 0)     style = 3;

    VideoRender_SetStyle(style);
    return nullptr;
}

// renderFrame(): void
static napi_value RenderFrame(napi_env env, napi_callback_info info)
{
    VideoRender_RenderFrame();
    return nullptr;
}

// releaseGL(): void
static napi_value ReleaseGL(napi_env env, napi_callback_info info)
{
    VideoRender_Release();
    return nullptr;
}

// ══════════════════════════════════════════════
// 模块注册
// ══════════════════════════════════════════════

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "initGL",      nullptr, InitGL,      nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setStyle",    nullptr, SetStyle,    nullptr, nullptr, nullptr, napi_default, nullptr },
        { "renderFrame", nullptr, RenderFrame, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "releaseGL",   nullptr, ReleaseGL,   nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module videoFilterModule = {
    .nm_version     = 1,
    .nm_flags       = 0,
    .nm_filename    = nullptr,
    .nm_register_func = Init,
    .nm_modname     = "video_filter",
    .nm_priv        = ((void*)0),
    .reserved       = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterVideoFilterModule(void)
{
    napi_module_register(&videoFilterModule);
}
