/**
 * 图片 URL 追加压缩参数（hdslb 图床）：列表/卡片加载缩略图，避免直接解码原图（内存峰值 + 卡顿）
 * 原图仅全屏预览时使用。
 *
 * ⚠️ 关键实现细节（勿退回 `!url.includes('@')` 的判断）：
 *   接口返回的图片 URL 经常自带 `@880w_880h_1c.webp`，若见到 '@' 就整段跳过压缩，
 *   等于把原图整张解码（实测单张 4254×4255 / 解码 130ms）。
 *   正确做法：**剥掉旧后缀再挂显示尺寸**，且只在 '@' 位于最后一个 '/' 之后（确实是文件名后缀）时才剥。
 *
 * ⭐ 本文件是唯一实现：动态页/详情页/评论渲染等**多处**都要用同一个压缩策略，
 *    各页各写一份会出现"某页漏了压缩→某一处又变成原图解码"的返工。
 */
export function resizeImageUrl(url: string, width: number): string {
  if (!url) return '';
  const full: string = url.startsWith('//') ? `https:${url}` : url;
  if (!full.includes('hdslb.com')) return full;
  const at: number = full.indexOf('@');
  const hasSuffix: boolean = at > full.lastIndexOf('/') && full.indexOf('?') < 0;
  const base: string = hasSuffix ? full.substring(0, at) : full;
  return base + `@${width}w`;
}
