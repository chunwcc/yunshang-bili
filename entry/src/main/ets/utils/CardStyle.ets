import { alphaHexFromPercent } from './ThemeColor';

/**
 * 卡片外观解析（跟随「个性化 → 卡片样式」选项）
 *
 * ⭐ 抽到 utils 的原因：动态页 / UP 空间页 / 动态详情页都要按**同一套规则**算卡片底色与描边，
 *    各写一份曾出现"换了卡片样式或主题色后某一页不跟随"（本工程"同款外观多副本"的老毛病）。
 *
 * 规则（与动态页原有实现一致，勿改语义）：
 *  - 透明样式：亮色 = 白底 + 透明度；暗色 = 黑底 + 透明度
 *  - 实心样式：亮色 #E8E8E8 / 暗色 #2C2C2C
 *  - 描边：实心样式无描边；透明样式按「跟随主题色」用主题色 + 透明度，否则白色 + 透明度
 */
export function cardItemBg(isDark: boolean, transparent: boolean, bgOpacity: number): string {
  if (transparent) {
    return isDark ? `rgba(0,0,0,${bgOpacity / 100})` : `rgba(255,255,255,${bgOpacity / 100})`;
  }
  return isDark ? '#2C2C2C' : '#E8E8E8';
}

export function cardItemBorder(isDark: boolean, transparent: boolean,
  borderOpacity: number, followTheme: boolean, themeColor: string): string {
  if (!transparent) {
    return 'rgba(0,0,0,0)';
  }
  if (followTheme) {
    // ⚠️ ArkUI 颜色串 alpha 在前
    return '#' + alphaHexFromPercent(borderOpacity) + themeColor.slice(1);
  }
  return isDark ? `rgba(255,255,255,${borderOpacity / 100})` : 'rgba(255,255,255,0.25)';
}
