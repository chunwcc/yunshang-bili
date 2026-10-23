// PlayCountStyle.ts - 播放量显示样式：格式化 + 颜色（由「卡片样式 → 播放量自定义」设置驱动）

/** 播放量文本：万/亿缩写（unitMode='wanYi'，默认）或完整数字（'full'） */
export function formatPlayCountText(count: number, unitMode: string): string {
  if (unitMode === 'full') return String(count);
  if (count >= 100000000) {
    const s = (count / 100000000).toFixed(1);
    return (s.endsWith('.0') ? s.slice(0, -2) : s) + '亿';
  }
  if (count >= 10000) {
    const s = (count / 10000).toFixed(1);
    return (s.endsWith('.0') ? s.slice(0, -2) : s) + '万';
  }
  return String(count);
}

/**
 * 播放量颜色：
 * mode='custom' → 自定义色（cardPlayCountColor）；'theme' → 主题色；'mono' → 黑/白（随深浅色模式）；
 * 其他（'level'，默认）→ 按播放量档位变色（与原逻辑一致）
 */
export function getPlayCountDisplayColor(count: number, mode: string, custom: string, themeColor: string,
  dark: boolean): string {
  if (mode === 'custom') return custom !== '' ? custom : '#999999';
  if (mode === 'theme') return themeColor;
  if (mode === 'mono') return dark ? '#FFFFFF' : '#000000';
  if (count >= 10000000) return '#FF0000';
  if (count >= 3000000) return '#C2185B';
  if (count >= 1000000) return '#E65100';
  if (count >= 500000) return '#FF8C00';
  if (count >= 100000) return '#FFB800';
  if (count >= 50000) return '#4A90D9';
  return '#999999';
}
