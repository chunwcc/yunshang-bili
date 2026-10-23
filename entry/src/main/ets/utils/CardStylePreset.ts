// CardStylePreset.ts - 卡片样式预设：内置 + 用户自定义（命名保存）
// v2：每个预设含 light/dark 两套独立档，应用时按当前模式取档。

import { preferences } from '@kit.ArkData';
import { CARD_STYLE_MODE_KEYS, cardStyleModeArchiveKey } from './CardStyleMode';

export type PresetValues = Record<string, number | string | boolean>;

export interface ModePresetValues {
  light: PresetValues;
  dark: PresetValues;
}

export interface StylePresetData {
  name: string;
  builtin: boolean;
  /** 预设图标（媒体资源名，内置预设可用） */
  icon?: string;
  values: ModePresetValues;
}

/** v1（单档）迁移为 v2（双档） */
function normalizePreset(raw: StylePresetData | { name: string; builtin: boolean; values: PresetValues }): StylePresetData {
  const v = raw.values as unknown as PresetValues | ModePresetValues;
  if (v && ('light' in v || 'dark' in v)) {
    const mv = v as ModePresetValues;
    return {
      name: raw.name,
      builtin: raw.builtin,
      values: { light: mv.light ?? {}, dark: mv.dark ?? {} }
    } as StylePresetData;
  }
  const single = v as PresetValues;
  return {
    name: raw.name,
    builtin: raw.builtin,
    values: { light: single, dark: single }
  } as StylePresetData;
}

function parsePresetList(json: string): StylePresetData[] {
  try {
    const raw = JSON.parse(json) as StylePresetData[];
    return raw.map(normalizePreset);
  } catch (e) {
    return [];
  }
}

/** 内置预设（深浅两档一致的基础版） */
/** 推荐预设（give_the_thumbs_up 图标）：取自用户「我的」双档快照 */
const RECOMMENDED_VALUES: ModePresetValues = {
  light: {
    cardTransparentStyle: true, cardTransparentStyleVideo: true,
    cardBorderOpacity: 15, cardBgOpacity: 45, cardBorderWidth: 1,
    cardBorderFollowTheme: false, cardBorderFollowPlayCount: false,
    cardCapsuleShow: true, cardCapsuleFollowTheme: true, cardCapsuleSize: 12,
    cardCapsuleRadius: 13, cardCapsuleColor: '',
    cardPlayCountShow: true, cardPlayCountIcon: true, cardPlayCountSize: 12,
    cardPlayCountColorMode: 'level', cardPlayCountColor: '#63e69e', cardCustomColor: '',
    cardListBorderRadius: 24, cardListMargin: 8,
    playerFollowTheme: true, cardBorderRadius: 30, cardMargin: 8,
    cardBgBlurAmount: 150, cardBgDarkness: 50
  },
  dark: {
    cardTransparentStyle: true, cardTransparentStyleVideo: true,
    cardBorderOpacity: 15, cardBgOpacity: 45, cardBorderWidth: 1,
    cardBorderFollowTheme: false, cardBorderFollowPlayCount: false,
    cardCapsuleShow: true, cardCapsuleFollowTheme: true, cardCapsuleSize: 12,
    cardCapsuleRadius: 20, cardCapsuleColor: '',
    cardPlayCountShow: true, cardPlayCountIcon: true, cardPlayCountSize: 12,
    cardPlayCountColorMode: 'level', cardPlayCountColor: '#63e69e', cardCustomColor: '',
    cardListBorderRadius: 24, cardListMargin: 8,
    playerFollowTheme: true, cardBorderRadius: 30, cardMargin: 8,
    cardBgBlurAmount: 150, cardBgDarkness: 50
  }
};

export function getBuiltinPresets(): StylePresetData[] {
  const std = defaultValues('标准');
  const viv = defaultValues('灵动');
  const min = defaultValues('极简');
  return [
    { name: '推荐', builtin: true, icon: 'give_the_thumbs_up', values: RECOMMENDED_VALUES } as StylePresetData,
    { name: '灵动', builtin: true, values: viv } as StylePresetData,
    { name: '标准', builtin: true, values: std } as StylePresetData,
    { name: '极简', builtin: true, values: min } as StylePresetData
  ];
}

function defaultValues(kind: string): ModePresetValues {
  let v: PresetValues;
  if (kind === '灵动') {
    // 参数取自用户修改版「灵动」（双档）
    return {
      light: {
        cardTransparentStyle: true, cardTransparentStyleVideo: true,
        cardBorderOpacity: 70, cardBgOpacity: 55, cardBorderWidth: 1,
        cardBorderFollowTheme: true, cardBorderFollowPlayCount: true,
        cardCapsuleShow: true, cardCapsuleFollowTheme: true, cardCapsuleSize: 12,
        cardCapsuleRadius: 20, cardCapsuleColor: '',
        cardPlayCountShow: true, cardPlayCountIcon: true, cardPlayCountSize: 12,
        cardPlayCountColorMode: 'theme', cardPlayCountColor: '', cardCustomColor: '',
        cardListBorderRadius: 26, cardListMargin: 10,
        playerFollowTheme: true, cardBorderRadius: 30, cardMargin: 12,
        cardBgBlurAmount: 16, cardBgDarkness: 55
      },
      dark: {
        cardTransparentStyle: true, cardTransparentStyleVideo: true,
        cardBorderOpacity: 45, cardBgOpacity: 55, cardBorderWidth: 2,
        cardBorderFollowTheme: true, cardBorderFollowPlayCount: true,
        cardCapsuleShow: true, cardCapsuleFollowTheme: true, cardCapsuleSize: 12,
        cardCapsuleRadius: 8, cardCapsuleColor: '',
        cardPlayCountShow: true, cardPlayCountIcon: true, cardPlayCountSize: 12,
        cardPlayCountColorMode: 'theme', cardPlayCountColor: '', cardCustomColor: '',
        cardListBorderRadius: 14, cardListMargin: 14,
        playerFollowTheme: true, cardBorderRadius: 24, cardMargin: 14,
        cardBgBlurAmount: 32, cardBgDarkness: 55
      }
    } as ModePresetValues;
  } else if (kind === '极简') {
    // 参数取自用户自定义预设「1」（双档）
    return {
      light: {
        cardTransparentStyle: false, cardTransparentStyleVideo: false,
        cardBorderOpacity: 10, cardBgOpacity: 5, cardBorderWidth: 0.5,
        cardBorderFollowTheme: false, cardBorderFollowPlayCount: false,
        cardCapsuleShow: false, cardCapsuleFollowTheme: false, cardCapsuleSize: 10,
        cardCapsuleRadius: 4, cardCapsuleColor: '',
        cardPlayCountShow: true, cardPlayCountIcon: false, cardPlayCountSize: 11,
        cardPlayCountColorMode: 'mono', cardPlayCountColor: '', cardCustomColor: '',
        cardListBorderRadius: 8, cardListMargin: 8,
        playerFollowTheme: false, cardBorderRadius: 12, cardMargin: 8,
        cardBgBlurAmount: 0, cardBgDarkness: 50
      },
      dark: {
        cardTransparentStyle: false, cardTransparentStyleVideo: false,
        cardBorderOpacity: 12, cardBgOpacity: 80, cardBorderWidth: 1,
        cardBorderFollowTheme: true, cardBorderFollowPlayCount: false,
        cardCapsuleShow: true, cardCapsuleFollowTheme: false, cardCapsuleSize: 10,
        cardCapsuleRadius: 4, cardCapsuleColor: '',
        cardPlayCountShow: true, cardPlayCountIcon: true, cardPlayCountSize: 11,
        cardPlayCountColorMode: 'mono', cardPlayCountColor: '', cardCustomColor: '',
        cardListBorderRadius: 8, cardListMargin: 8,
        playerFollowTheme: false, cardBorderRadius: 12, cardMargin: 8,
        cardBgBlurAmount: 0, cardBgDarkness: 50
      }
    } as ModePresetValues;
  } else {
    v = {
      cardTransparentStyle: true, cardTransparentStyleVideo: true,
      cardBorderOpacity: 25, cardBgOpacity: 70, cardBorderWidth: 1,
      cardBorderFollowTheme: true, cardBorderFollowPlayCount: false,
      cardCapsuleShow: true, cardCapsuleFollowTheme: false, cardCapsuleSize: 12,
      cardCapsuleRadius: 7, cardCapsuleColor: '',
      cardPlayCountShow: true, cardPlayCountIcon: true, cardPlayCountSize: 12,
      cardPlayCountColorMode: 'level', cardPlayCountColor: '', cardCustomColor: '',
      cardListBorderRadius: 12, cardListMargin: 12,
      playerFollowTheme: true, cardBorderRadius: 30, cardMargin: 12,
      cardBgBlurAmount: 24, cardBgDarkness: 50
    };
  }
  return { light: v, dark: v };
}

/** 当前激活 18 键快照 */
export function buildStyleSnapshot(): PresetValues {
  const obj: PresetValues = {};
  for (const k of CARD_STYLE_MODE_KEYS) {
    const v = AppStorage.get<number | string | boolean>(k);
    if (v !== undefined) {
      obj[k] = v;
    }
  }
  return obj;
}

/** 读取某模式档案（无则 null） */
async function readModeArchive(pref: preferences.Preferences, dark: boolean): Promise<PresetValues | null> {
  try {
    const json = await pref.get(cardStyleModeArchiveKey(dark), '') as string;
    if (!json) return null;
    return JSON.parse(json) as PresetValues;
  } catch (e) {
    return null;
  }
}

/** 构建双档：当前模式=当前激活值；另一模式=其档案（无则复制当前档） */
export async function buildModePairSnapshot(pref: preferences.Preferences,
  currentDark: boolean): Promise<ModePresetValues> {
  const cur = buildStyleSnapshot();
  const other = await readModeArchive(pref, !currentDark);
  return currentDark
    ? { dark: cur, light: other !== null ? other : cur }
    : { light: cur, dark: other !== null ? other : cur };
}

const CUSTOM_PRESETS_STORE_KEY: string = 'cardStyleCustomPresets';
const BUILTIN_EDITS_STORE_KEY: string = 'cardStylePresetEdits';

/** 加载用户自定义预设列表 */
export async function loadCustomPresets(pref: preferences.Preferences): Promise<StylePresetData[]> {
  const json = await pref.get(CUSTOM_PRESETS_STORE_KEY, '[]') as string;
  return parsePresetList(json);
}

/** 保存用户预设（同名覆盖），并返回新列表 */
export async function saveCustomPreset(pref: preferences.Preferences,
  name: string, pair: ModePresetValues): Promise<StylePresetData[]> {
  const list = await loadCustomPresets(pref);
  const filtered = list.filter((p: StylePresetData) => p.name !== name);
  filtered.push({ name: name, builtin: false, values: pair } as StylePresetData);
  await pref.put(CUSTOM_PRESETS_STORE_KEY, JSON.stringify(filtered));
  await pref.flush();
  return filtered;
}

/** 删除用户预设，并返回新列表 */
export async function deleteCustomPreset(pref: preferences.Preferences,
  name: string): Promise<StylePresetData[]> {
  const list = await loadCustomPresets(pref);
  const filtered = list.filter((p: StylePresetData) => p.name !== name);
  await pref.put(CUSTOM_PRESETS_STORE_KEY, JSON.stringify(filtered));
  await pref.flush();
  return filtered;
}

/** 加载内置预设修改覆盖 */
export async function loadBuiltinEdits(pref: preferences.Preferences): Promise<StylePresetData[]> {
  const json = await pref.get(BUILTIN_EDITS_STORE_KEY, '[]') as string;
  return parsePresetList(json);
}

/** 用（当前+另一模式）覆盖内置预设 */
export async function saveBuiltinEdit(pref: preferences.Preferences,
  name: string, pair: ModePresetValues): Promise<StylePresetData[]> {
  const list = await loadBuiltinEdits(pref);
  const filtered = list.filter((p: StylePresetData) => p.name !== name);
  filtered.push({ name: name, builtin: true, values: pair } as StylePresetData);
  await pref.put(BUILTIN_EDITS_STORE_KEY, JSON.stringify(filtered));
  await pref.flush();
  return filtered;
}

/** 恢复内置预设默认 */
export async function restoreBuiltinDefault(pref: preferences.Preferences,
  name: string): Promise<StylePresetData[]> {
  const list = await loadBuiltinEdits(pref);
  const filtered = list.filter((p: StylePresetData) => p.name !== name);
  await pref.put(BUILTIN_EDITS_STORE_KEY, JSON.stringify(filtered));
  await pref.flush();
  return filtered;
}

/** 把预设的「某模式档」直接写入该模式档案（供应用预设时同步另一模式） */
export async function applyPresetModeArchive(pref: preferences.Preferences,
  dark: boolean, values: PresetValues): Promise<void> {
  try {
    await pref.put(cardStyleModeArchiveKey(dark), JSON.stringify(values));
    await pref.flush();
  } catch (e) {
    // 静默
  }
}
