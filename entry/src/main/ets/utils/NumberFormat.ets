/**
 * 计数格式化（万 / 千）
 *
 * ⭐ 只保留这一份实现：动态页的卡片统计行与点赞胶囊组件都要用同一个数字格式，
 *    各写一份迟早会出现"同一数字在两处显示不一样"（本工程已有多次"同款外观多副本"返工）。
 */
export function fmtCount(n: number): string {
  if (n >= 10000) return (n / 10000).toFixed(1) + '万';
  if (n >= 1000) return (n / 1000).toFixed(1) + '千';
  return n.toString();
}
