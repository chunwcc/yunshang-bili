/**
 * 时间格式化（相对时间）
 *
 * ⭐ 统一实现：动态页/UP 空间页/动态详情页都要显示"x分钟前"，
 *    各写一份会出现同一时间戳在不同页面显示不一致。
 */
export function fmtRelativeTime(ts: number): string {
  if (ts <= 0) return '';
  const now = Math.floor(Date.now() / 1000);
  const diff = now - ts;
  if (diff < 60) return '刚刚';
  if (diff < 3600) return `${Math.floor(diff / 60)}分钟前`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}小时前`;
  if (diff < 2592000) return `${Math.floor(diff / 86400)}天前`;
  if (diff < 31536000) return `${Math.floor(diff / 2592000)}个月前`;
  return `${Math.floor(diff / 31536000)}年前`;
}
