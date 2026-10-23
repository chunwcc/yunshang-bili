/**
 * 主题色派生工具
 *
 * ⭐ 统一实现：卡片、正文话题胶囊、点赞胶囊都要用"主题色 + 透明度"，
 *    各页各写一份 hex 解析迟早会出现"同一个主题色渲出来的底色不一样"。
 */

/** 主题色 + 0~1 透明度 → `rgba(r,g,b,a)`（用于 backgroundColor 等） */
export function themeRgba(color: string, alpha: number): string {
  const hex = color.replace('#', '');
  const r = parseInt(hex.substring(0, 2), 16);
  const g = parseInt(hex.substring(2, 4), 16);
  const b = parseInt(hex.substring(4, 6), 16);
  return `rgba(${r},${g},${b},${alpha})`;
}

/** 透明度百分比(0~100) → 两位 hex alpha（ArkUI 的 #AARRGGBB 里 alpha 在前） */
export function alphaHexFromPercent(opacityPercent: number): string {
  const val = Math.round(opacityPercent / 100 * 255);
  let hex = val.toString(16);
  if (hex.length === 1) hex = '0' + hex;
  return hex;
}

/**
 * 主题色 + 透明度百分比 → ArkUI 的 `#AARRGGBB`
 * ⚠️ ArkUI 颜色串是 **alpha 在前**（与 CSS 的 #RRGGBBAA 相反），所以 alpha 拼在开头。
 */
export function themeHexAlpha(color: string, opacityPercent: number): string {
  return '#' + alphaHexFromPercent(opacityPercent) + color.slice(1);
}
