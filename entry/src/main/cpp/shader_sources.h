#ifndef SHADER_SOURCES_H
#define SHADER_SOURCES_H

// ══════════════════════════════════════════════
// 顶点着色器（唯一，所有风格共用）
// ══════════════════════════════════════════════
static const char* VERTEX_SHADER_SRC =
    "#version 300 es\n"
    "layout(location = 0) in vec4 aPos;\n"
    "layout(location = 1) in vec2 aTexCoord;\n"
    "out vec2 vTexCoord;\n"
    "void main() {\n"
    "    gl_Position = aPos;\n"
    "    vTexCoord = aTexCoord;\n"
    "}\n";

// ══════════════════════════════════════════════
// 片段着色器 — 原图（直通）
// ══════════════════════════════════════════════
static const char* FRAG_ORIGINAL =
    "#version 300 es\n"
    "#extension GL_OES_EGL_image_external_essl3 : require\n"
    "precision mediump float;\n"
    "in vec2 vTexCoord;\n"
    "out vec4 fragColor;\n"
    "uniform samplerExternalOES uTexture;\n"
    "void main() {\n"
    "    fragColor = texture(uTexture, vTexCoord);\n"
    "}\n";

// ══════════════════════════════════════════════
// 片段着色器 — 鲜艳（提升饱和度 + 对比度）
// ══════════════════════════════════════════════
static const char* FRAG_VIVID =
    "#version 300 es\n"
    "#extension GL_OES_EGL_image_external_essl3 : require\n"
    "precision mediump float;\n"
    "in vec2 vTexCoord;\n"
    "out vec4 fragColor;\n"
    "uniform samplerExternalOES uTexture;\n"
    "void main() {\n"
    "    vec4 c = texture(uTexture, vTexCoord);\n"
    "    // 饱和度增强 (1.4x)\n"
    "    float l = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;\n"
    "    vec3 saturated = mix(vec3(l), c.rgb, 1.4);\n"
    "    // 对比度增强 (1.15x)\n"
    "    vec3 contrast = (saturated - 0.5) * 1.15 + 0.5;\n"
    "    fragColor = vec4(clamp(contrast, 0.0, 1.0), c.a);\n"
    "}\n";

// ══════════════════════════════════════════════
// 片段着色器 — 徕卡（暖色 + 高对比 + 暗角）
// ══════════════════════════════════════════════
static const char* FRAG_LEICA =
    "#version 300 es\n"
    "#extension GL_OES_EGL_image_external_essl3 : require\n"
    "precision mediump float;\n"
    "in vec2 vTexCoord;\n"
    "out vec4 fragColor;\n"
    "uniform samplerExternalOES uTexture;\n"
    "uniform vec2 uResolution;\n"
    "void main() {\n"
    "    vec4 c = texture(uTexture, vTexCoord);\n"
    "    // 暖色调偏移 (R+0.04, B-0.03)\n"
    "    vec3 warm = c.rgb + vec3(0.04, 0.01, -0.03);\n"
    "    // 对比度增强 (1.2x)\n"
    "    vec3 contrast = (warm - 0.5) * 1.2 + 0.5;\n"
    "    // 暗角：基于像素到中心的距离\n"
    "    vec2 uv = vTexCoord - 0.5;\n"
    "    float dist = length(uv);\n"
    "    float vignette = 1.0 - smoothstep(0.3, 0.7, dist);\n"
    "    vignette = mix(0.65, 1.0, vignette);\n"
    "    fragColor = vec4(clamp(contrast * vignette, 0.0, 1.0), c.a);\n"
    "}\n";

// ══════════════════════════════════════════════
// 片段着色器 — 胶片（褪色 + 暗部提亮 + 颗粒）
// ══════════════════════════════════════════════
static const char* FRAG_FILM =
    "#version 300 es\n"
    "#extension GL_OES_EGL_image_external_essl3 : require\n"
    "precision mediump float;\n"
    "in vec2 vTexCoord;\n"
    "out vec4 fragColor;\n"
    "uniform samplerExternalOES uTexture;\n"
    "uniform float uTime;\n"
    "highp float rand(vec2 co) {\n"
    "    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);\n"
    "}\n"
    "void main() {\n"
    "    vec4 c = texture(uTexture, vTexCoord);\n"
    "    // 褪色：降低饱和 + 暗部提亮\n"
    "    float l = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;\n"
    "    vec3 desat = mix(c.rgb, vec3(l), 0.35);\n"
    "    vec3 fade = desat + vec3(0.06);\n"
    "    // 轻微颗粒感\n"
    "    float grain = (rand(vTexCoord + uTime) - 0.5) * 0.05;\n"
    "    fragColor = vec4(clamp(fade + grain, 0.0, 1.0), c.a);\n"
    "}\n";

// ══════════════════════════════════════════════
// 着色器源码表（按风格索引 0~3）
// ══════════════════════════════════════════════
static const char* FRAG_SOURCES[] = {
    FRAG_ORIGINAL,  // 0: original
    FRAG_VIVID,     // 1: vivid
    FRAG_LEICA,     // 2: leica
    FRAG_FILM,      // 3: film
};

#endif // SHADER_SOURCES_H
