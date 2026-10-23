// CardStyleMode.ts - 卡片样式「深浅色独立」档案：深/浅模式各存一份，切换时自动装载
// 参考 WallpaperTheme 深浅色双档案思路（wallpaperLight/wallpaperDark）。

import { preferences } from '@kit.ArkData';

/** 进入模式档案的样式键（风格相关，功能开关不入档） */
export const CARD_STYLE_MODE_KEYS: string[] = [
  'cardTransparentStyle',
  'cardTransparentStyleVideo',
  'cardBorderOpacity',
  'cardBgOpacity',
  'cardBorderWidth',
  'cardBorderFollowTheme',
  'cardBorderFollowPlayCount',
  'cardCapsuleShow',
  'cardCapsuleFollowTheme',
  'cardCapsuleSize',
  'cardCapsuleRadius',
  'cardCapsuleColor',
  'cardPlayCountShow',
  'cardPlayCountIcon',
  'cardPlayCountSize',
  'cardPlayCountColorMode',
  'cardPlayCountColor',
  'cardCustomColor',
  'cardListBorderRadius',
  'cardListMargin',
  'playerFollowTheme',
  'cardBorderRadius',
  'cardMargin',
  'cardBgBlurAmount',
  'cardBgDarkness',
  // ⭐ 播放页背景（深浅色独立同样生效：封面/纯色/自定义壁纸及其模糊/明暗）。
  //    cardBgBlurAmount/cardBgDarkness 是「封面模式」的模糊/明暗，
  //    videoBgCustomWallpaperBlur/Darkness 是「壁纸模式」的（设置页滑块双写同步），
  //    必须成对入档，否则切模式后壁纸模式的模糊/明暗停留在另一模式的值。
  'videoBgMode',
  'videoBgColor',
  'videoBgCustomWallpaper',
  'videoBgCustomWallpaperBlur',
  'videoBgCustomWallpaperDarkness'
];

export function cardStyleModeArchiveKey(dark: boolean): string {
  return dark ? 'cardStyleModeDark' : 'cardStyleModeLight';
}

/** 把当前激活值整体写入当前模式的档案（AppStorage 为值来源） */
export async function persistCardStyleModeArchive(pref: preferences.Preferences, dark: boolean): Promise<void> {
  try {
    const obj: Record<string, number | string | boolean> = {};
    for (const k of CARD_STYLE_MODE_KEYS) {
      const v = AppStorage.get<number | string | boolean>(k);
      if (v !== undefined) {
        obj[k] = v;
      }
    }
    await pref.put(cardStyleModeArchiveKey(dark), JSON.stringify(obj));
    await pref.flush();
  } catch (e) {
    // 归档失败不影响主流程（下次修改会重写）
  }
}

/** 装载某模式的档案到激活键；无档案时保持当前值 */
export async function applyCardStyleModeArchive(pref: preferences.Preferences, dark: boolean): Promise<void> {
  try {
    const json = await pref.get(cardStyleModeArchiveKey(dark), '') as string;
    if (!json) return;
    const obj = JSON.parse(json) as Record<string, number | string | boolean>;
    for (const k of CARD_STYLE_MODE_KEYS) {
      const v = obj[k];
      if (v !== undefined && v !== null) {
        AppStorage.set(k, v);
      }
    }
  } catch (e) {
    // 档案损坏时静默跳过
  }
}
