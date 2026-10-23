#include "video_render.h"

#include <string>
#include <vector>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES3/gl32.h>
// OH_NativeImage 需要 external OES 扩展常量
#ifndef GL_TEXTURE_EXTERNAL_OES
#define GL_TEXTURE_EXTERNAL_OES 0x8D65
#endif
#include <native_image/native_image.h>
#include <native_window/external_window.h>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "VideoRender"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

// ══════════════════════════════════════════════
// 全局状态（单例模式，简化 NAPI 桥接）
// ══════════════════════════════════════════════

static struct {
    // EGL 对象
    EGLDisplay eglDisplay = EGL_NO_DISPLAY;
    EGLConfig  eglConfig  = nullptr;
    EGLSurface eglSurface = EGL_NO_SURFACE;
    EGLContext eglContext = EGL_NO_CONTEXT;

    // NativeImage
    OH_NativeImage* nativeImage = nullptr;
    uint64_t        nativeSurfaceId = 0;
    GLuint          oesTextureId = 0;

    // 着色器
    GLuint program = 0;

    // 当前风格
    int currentStyle = 0;

    // 窗口尺寸
    int windowWidth  = 0;
    int windowHeight = 0;

    // 全屏四边形 VAO/VBO
    GLuint vao = 0;
    GLuint vbo = 0;

    // 是否已初始化
    bool initialized = false;
} g_render;

// ══════════════════════════════════════════════
// 着色器源码（来自 shader_sources.h）
// ══════════════════════════════════════════════

#include "shader_sources.h"

// ══════════════════════════════════════════════
// 内部工具函数
// ══════════════════════════════════════════════

static GLuint CompileShader(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    if (!shader) return 0;
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        char info[512];
        glGetShaderInfoLog(shader, sizeof(info), nullptr, info);
        LOGE("Shader compile error (%s): %s",
             type == GL_VERTEX_SHADER ? "vertex" : "fragment", info);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static GLuint CreateProgram(const char* vertSrc, const char* fragSrc) {
    GLuint vs = CompileShader(GL_VERTEX_SHADER, vertSrc);
    GLuint fs = CompileShader(GL_FRAGMENT_SHADER, fragSrc);
    if (!vs || !fs) {
        glDeleteShader(vs);
        glDeleteShader(fs);
        return 0;
    }
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    GLint linked = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &linked);
    if (!linked) {
        char info[512];
        glGetProgramInfoLog(prog, sizeof(info), nullptr, info);
        LOGE("Program link error: %s", info);
        glDeleteProgram(prog);
        prog = 0;
    }
    glDeleteShader(vs);
    glDeleteShader(fs);
    return prog;
}

// 创建全屏四边形 VBO/VAO
static void SetupQuad(GLuint* vao, GLuint* vbo) {
    const float vertices[] = {
        -1.0f, -1.0f,  0.0f, 0.0f,
         1.0f, -1.0f,  1.0f, 0.0f,
        -1.0f,  1.0f,  0.0f, 1.0f,
         1.0f,  1.0f,  1.0f, 1.0f,
    };
    glGenVertexArrays(1, vao);
    glGenBuffers(1, vbo);
    glBindVertexArray(*vao);
    glBindBuffer(GL_ARRAY_BUFFER, *vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          (void*)(2 * sizeof(float)));
    glEnableVertexAttribArray(1);
    glBindVertexArray(0);
}

// ══════════════════════════════════════════════
// 公开 API 实现
// ══════════════════════════════════════════════

int VideoRender_Init(const char* xcSurfaceId, int width, int height,
                     uint64_t* outNativeSurfaceId) {
    if (g_render.initialized) {
        LOGI("Already initialized, reconfiguring...");
        VideoRender_Release();
    }

    g_render.windowWidth  = width;
    g_render.windowHeight = height;

    LOGI("Init start: xcSurface=%s, size=%dx%d", xcSurfaceId, width, height);

    // ── 1. 解析 XComponent surfaceId 并创建 NativeWindow ──
    uint64_t xcIdNum = 0;
    if (xcSurfaceId) {
        xcIdNum = std::stoull(xcSurfaceId);
    }
    if (xcIdNum == 0) {
        LOGE("Invalid XComponent surfaceId");
        return -1;
    }

    OHNativeWindow* nativeWindow = nullptr;
    int32_t retWin = OH_NativeWindow_CreateNativeWindowFromSurfaceId(xcIdNum, &nativeWindow);
    if (retWin != 0 || !nativeWindow) {
        LOGE("Failed to create NativeWindow from surfaceId, ret=%d", retWin);
        return -1;
    }

    // ── 2. EGL 初始化 ──
    g_render.eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_render.eglDisplay == EGL_NO_DISPLAY) {
        LOGE("eglGetDisplay failed");
        return -1;
    }

    EGLint major, minor;
    if (!eglInitialize(g_render.eglDisplay, &major, &minor)) {
        LOGE("eglInitialize failed");
        return -1;
    }

    const EGLint attrs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 16,
        EGL_STENCIL_SIZE, 8,
        EGL_NONE,
    };
    EGLint numConfig = 0;
    if (!eglChooseConfig(g_render.eglDisplay, attrs, &g_render.eglConfig,
                         1, &numConfig) || numConfig == 0) {
        LOGE("eglChooseConfig failed");
        return -1;
    }

    g_render.eglSurface = eglCreateWindowSurface(
        g_render.eglDisplay, g_render.eglConfig,
        reinterpret_cast<EGLNativeWindowType>(nativeWindow), nullptr);
    if (g_render.eglSurface == EGL_NO_SURFACE) {
        LOGE("eglCreateWindowSurface failed");
        return -1;
    }

    const EGLint ctxAttrs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE,
    };
    g_render.eglContext = eglCreateContext(
        g_render.eglDisplay, g_render.eglConfig,
        EGL_NO_CONTEXT, ctxAttrs);
    if (g_render.eglContext == EGL_NO_CONTEXT) {
        LOGE("eglCreateContext failed");
        return -1;
    }

    eglMakeCurrent(g_render.eglDisplay, g_render.eglSurface,
                   g_render.eglSurface, g_render.eglContext);

    LOGI("EGL initialized: %dx%d, GL version: %s", width, height,
         glGetString(GL_VERSION));

    // ── 3. 创建 OES 纹理（先创建纹理再创建 NativeImage）──
    glGenTextures(1, &g_render.oesTextureId);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, g_render.oesTextureId);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);

    // ── 4. 创建 OH_NativeImage 并关联纹理（生产端：AVPlayer 写入帧）──
    // textureTarget 必须是 GL_TEXTURE_EXTERNAL_OES
    // 传入 oesTextureId 直接关联纹理，NativeImage 内部创建 EGLImage，
    // 绑定后 OES 纹理自动反映最新帧内容（不依赖 UpdateSurfaceImage）
    g_render.nativeImage = OH_NativeImage_Create(g_render.oesTextureId,
                                                  GL_TEXTURE_EXTERNAL_OES);
    if (!g_render.nativeImage) {
        LOGE("OH_NativeImage_Create failed");
        return -1;
    }

    // 获取 NativeImage 的 surfaceId（给 AVPlayer）
    OH_NativeImage_GetSurfaceId(g_render.nativeImage, &g_render.nativeSurfaceId);

    // ── 5. 编译初始着色器（原图直通）──
    g_render.program = CreateProgram(VERTEX_SHADER_SRC, FRAG_ORIGINAL);
    if (!g_render.program) {
        LOGE("Failed to create shader program");
        return -1;
    }

    // ── 6. 设置全屏四边形 ──
    SetupQuad(&g_render.vao, &g_render.vbo);

    // ── 7. 设置视口 ──
    glViewport(0, 0, width, height);

    // ── 8. 创建 EGL Image = 绑定 OES 纹理到 NativeImage（关键！Create 不创建 EGLImage）──
    int ret = OH_NativeImage_AttachContext(g_render.nativeImage,
                                           g_render.oesTextureId);
    if (ret != 0) {
        LOGE("OH_NativeImage_AttachContext failed: %d", ret);
        return -1;
    }

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);

    // ── 9. 输出 NativeSurfaceId ──
    if (outNativeSurfaceId) {
        *outNativeSurfaceId = g_render.nativeSurfaceId;
    }

    g_render.initialized = true;
    LOGI("VideoRender_Init success, nativeSurfaceId=%llu", g_render.nativeSurfaceId);
    return 0;
}

int VideoRender_RenderFrame(void) {
    if (!g_render.initialized) {
        return -1;
    }

    // ── 0. 确保 EGL 上下文当前 ──
    eglMakeCurrent(g_render.eglDisplay, g_render.eglSurface,
                   g_render.eglSurface, g_render.eglContext);

    // ── 1. 绑定 OES 纹理（EGL external image 自动包含最新帧）──
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, g_render.oesTextureId);

    // ── 2. 渲染 ──
    glClear(GL_COLOR_BUFFER_BIT);

    glUseProgram(g_render.program);

    // 设置 uniforms（各风格所需的参数）
    GLint resLoc = glGetUniformLocation(g_render.program, "uResolution");
    if (resLoc >= 0) {
        glUniform2f(resLoc, (float)g_render.windowWidth, (float)g_render.windowHeight);
    }
    GLint timeLoc = glGetUniformLocation(g_render.program, "uTime");
    if (timeLoc >= 0) {
        static float s_time = 0.0f;
        s_time += 0.016f;
        glUniform1f(timeLoc, s_time);
    }

    glBindTexture(GL_TEXTURE_EXTERNAL_OES, g_render.oesTextureId);

    glBindVertexArray(g_render.vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);

    // ── 3. SwapBuffers ──
    eglSwapBuffers(g_render.eglDisplay, g_render.eglSurface);

    return 0;
}

void VideoRender_SetStyle(int style) {
    if (!g_render.initialized) return;
    if (style < 0 || style > 3) return;
    if (style == g_render.currentStyle) return;

    g_render.currentStyle = style;
    LOGI("Set style: %d", style);

    eglMakeCurrent(g_render.eglDisplay, g_render.eglSurface,
                   g_render.eglSurface, g_render.eglContext);

    if (g_render.program) {
        glDeleteProgram(g_render.program);
        g_render.program = 0;
    }

    g_render.program = CreateProgram(VERTEX_SHADER_SRC, FRAG_SOURCES[style]);
    if (!g_render.program) {
        LOGE("Failed to compile shader for style %d, falling back to original", style);
        g_render.program = CreateProgram(VERTEX_SHADER_SRC, FRAG_ORIGINAL);
        g_render.currentStyle = 0;
    }
}

void VideoRender_Release(void) {
    if (!g_render.initialized) return;

    LOGI("VideoRender_Release");

    eglMakeCurrent(g_render.eglDisplay, g_render.eglSurface,
                   g_render.eglSurface, g_render.eglContext);

    if (g_render.program) {
        glDeleteProgram(g_render.program);
        g_render.program = 0;
    }
    if (g_render.oesTextureId) {
        glDeleteTextures(1, &g_render.oesTextureId);
        g_render.oesTextureId = 0;
    }
    if (g_render.vao) {
        glDeleteVertexArrays(1, &g_render.vao);
        g_render.vao = 0;
    }
    if (g_render.vbo) {
        glDeleteBuffers(1, &g_render.vbo);
        g_render.vbo = 0;
    }
    if (g_render.nativeImage) {
        OH_NativeImage_DetachContext(g_render.nativeImage);
        OH_NativeImage_Destroy(&g_render.nativeImage);
        g_render.nativeImage = nullptr;
        g_render.nativeSurfaceId = 0;
    }

    if (g_render.eglDisplay != EGL_NO_DISPLAY) {
        eglMakeCurrent(g_render.eglDisplay, EGL_NO_SURFACE,
                       EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (g_render.eglContext != EGL_NO_CONTEXT) {
            eglDestroyContext(g_render.eglDisplay, g_render.eglContext);
            g_render.eglContext = EGL_NO_CONTEXT;
        }
        if (g_render.eglSurface != EGL_NO_SURFACE) {
            eglDestroySurface(g_render.eglDisplay, g_render.eglSurface);
            g_render.eglSurface = EGL_NO_SURFACE;
        }
        eglTerminate(g_render.eglDisplay);
        g_render.eglDisplay = EGL_NO_DISPLAY;
    }

    g_render.initialized = false;
    LOGI("VideoRender_Release done");
}
