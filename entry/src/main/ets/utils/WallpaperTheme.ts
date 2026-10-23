// WallpaperTheme.ts — 深色/浅色模式独立壁纸：激活键 + 两套存档键
// 激活键 = 消费页读取的现有键（wallpaper/customWallpaper/wallpaperColor/wallpaperBlur/wallpaperDarkness），消费页零改动
// 存档键 = 各模式独立保存（wallpaperLight*/wallpaperDark*），切换模式/编辑时装载/持久化
import { preferences } from '@kit.ArkData';
import { logError } from './Logger';

const ACTIVE_KEYS: string[] = ['wallpaper', 'customWallpaper', 'wallpaperColor', 'wallpaperBlur', 'wallpaperDarkness'];
const LIGHT_KEYS: string[] = ['wallpaperLight', 'customWallpaperLight', 'wallpaperColorLight', 'wallpaperBlurLight', 'wallpaperDarknessLight'];
const DARK_KEYS: string[] = ['wallpaperDark', 'customWallpaperDark', 'wallpaperColorDark', 'wallpaperBlurDark', 'wallpaperDarknessDark'];

function keysFor(dark: boolean): string[] {
  return dark ? DARK_KEYS : LIGHT_KEYS;
}

function defaultFor(index: number): string | number {
  if (index === 0) return 'builtin';
  if (index === 1) return '';
  if (index === 2) return '#007DFF';
  if (index === 3) return 0;
  return 50;
}

/**
 * 把某模式的存档值装载为激活值（消费页读激活键，切换模式后自动生效）
 */
export function applyWallpaperMode(dark: boolean): void {
  const ks: string[] = keysFor(dark);
  for (let i = 0; i < ACTIVE_KEYS.length; i++) {
    const v = AppStorage.get<string | number>(ks[i]);
    if (v !== undefined) {
      AppStorage.set(ACTIVE_KEYS[i], v);
    }
  }
}

/**
 * 把当前激活值持久化到某模式存档（AppStorage + Preferences）
 * 失败时记录日志但不抛出（存档缺失时 applyWallpaperMode 会跳过，激活键仍有兜底值）
 */
export async function persistWallpaperMode(dark: boolean, pref: preferences.Preferences): Promise<void> {
  try {
    const ks: string[] = keysFor(dark);
    for (let i = 0; i < ACTIVE_KEYS.length; i++) {
      const v = AppStorage.get<string | number>(ACTIVE_KEYS[i]);
      if (v !== undefined) {
        AppStorage.set(ks[i], v);
        await pref.put(ks[i], v);
      }
    }
    await pref.flush();
  } catch (err) {
    logError(`持久化壁纸模式存档失败: ${err}`);
  }
}

/**
 * 启动时：从 Preferences 加载两套存档（缺失回退激活键值并回填），再装载当前模式到激活键
 */
export async function loadWallpaperModes(pref: preferences.Preferences, dark: boolean): Promise<void> {
  try {
    const all: string[][] = [LIGHT_KEYS, DARK_KEYS];
    for (let s = 0; s < all.length; s++) {
      for (let i = 0; i < all[s].length; i++) {
        const has: boolean = await pref.has(all[s][i]);
        let v: string | number;
        if (has) {
          v = await pref.get(all[s][i], '') as string | number;
        } else {
          v = AppStorage.get<string | number>(ACTIVE_KEYS[i]) ?? defaultFor(i);
          await pref.put(all[s][i], v);
        }
        AppStorage.setOrCreate(all[s][i], v);
      }
    }
    await pref.flush();
    applyWallpaperMode(dark);
  } catch (err) {
    logError(`加载壁纸模式存档失败: ${err}`);
  }
}
