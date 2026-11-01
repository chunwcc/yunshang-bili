// ThemePersist.ts — 主题模式持久化(基于 @kit.ArkData preferences 同步 API)
// 参考 Hivid 架构: putSync / getSync / flushSync 同步执行，避免异步竞态
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'mdThemeStore';
const KEY_COLOR_MODE: string = 'colorMode';

export type ColorModePref = 'COLOR_MODE_LIGHT' | 'COLOR_MODE_DARK' | 'COLOR_MODE_NOT_SET';
const DEFAULT_PREF: ColorModePref = 'COLOR_MODE_NOT_SET';

export class ThemePersist {
  private static store: preferences.Preferences | undefined = undefined;

  public static init(context: common.Context): void {
    if (ThemePersist.store) {
      return;
    }
    try {
      const options: preferences.Options = { name: STORE_NAME };
      ThemePersist.store = preferences.getPreferencesSync(context, options);
    } catch (err) {
      console.error(`ThemePersist.init failed: ${JSON.stringify(err)}`);
    }
  }

  public static save(mode: ColorModePref): void {
    if (!ThemePersist.store) {
      console.warn('ThemePersist.save: store not initialized');
      return;
    }
    try {
      ThemePersist.store.putSync(KEY_COLOR_MODE, mode);
      ThemePersist.store.flushSync();
    } catch (err) {
      console.error(`ThemePersist.save failed: ${JSON.stringify(err)}`);
    }
  }

  public static load(): ColorModePref {
    if (!ThemePersist.store) {
      return DEFAULT_PREF;
    }
    try {
      const raw: preferences.ValueType = ThemePersist.store.getSync(KEY_COLOR_MODE, DEFAULT_PREF);
      return (raw as ColorModePref) ?? DEFAULT_PREF;
    } catch (err) {
      console.error(`ThemePersist.load failed: ${JSON.stringify(err)}`);
      return DEFAULT_PREF;
    }
  }
}
