#ifndef VIDEO_RENDER_H
#define VIDEO_RENDER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 初始化 OpenGL ES 渲染管线
// xcSurfaceId: XComponent 的 surface ID（C 字符串）
// width, height: 显示宽高
// outNativeSurfaceId: 输出参数，返回 NativeImage 的 surfaceId（需至少 32 字节缓冲区）
// 返回值: 0 成功, -1 失败
int VideoRender_Init(const char* xcSurfaceId, int width, int height,
                     uint64_t* outNativeSurfaceId);

// 渲染一帧：从 NativeImage 获取最新帧 → 着色器处理 → SwapBuffers
// 返回值: 0 成功, -1 失败
int VideoRender_RenderFrame(void);

// 切换色彩风格着色器
// style: 0=原图, 1=鲜艳, 2=徕卡, 3=胶片
void VideoRender_SetStyle(int style);

// 释放所有 GL/NativeImage 资源
void VideoRender_Release(void);

#ifdef __cplusplus
}
#endif

#endif // VIDEO_RENDER_H
