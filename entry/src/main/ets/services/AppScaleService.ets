/**
 * AppScaleService.ets
 * 应用比例调节：读写并应用「跟随系统」与「自定义比例」设置。
 *
 * 实现依据：
 * - ApplicationContext.setFontSizeScale(fontScale)（API 13）：应用内字体缩放，
 *   设置后应用不再跟随系统字体大小变化（引擎默认模式由 AppScope/resources/base/profile/
 *   configuration.json 的 fontSizeScale=followSystem 提供，切换回跟随需重启应用恢复引擎默认）。
 * - WindowStage.setCustomDensity(density, applyToSubWindow)（API 15/20）：应用主窗口自定义显示密度，
 *   density 与 display.densityPixels 同单位（px/vp），-1.0 表示恢复系统显示大小缩放。
 * 本服务只负责 custom 模式的读取与应用；重启（回跟随）由 EntryAbility 的启动逻辑兜底。
 */
import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { logInfo, logError } from '../utils/Logger';

/** 应用比例模式：跟随系统 */
export const SCALE_MODE_SYSTEM: string = 'system';
/** 应用比例模式：自定义 */
export const SCALE_MODE_CUSTOM: string = 'custom';

/** 界面缩放滑杆范围（倍率，1 = 与当前系统显示大小一致） */
export const UI_SCALE_MIN: number = 0.75;
export const UI_SCALE_MAX: number = 1.5;
/** 文字大小滑杆范围（倍率，1 = 标准字号） */
export const FONT_SCALE_MIN: number = 0.8;
export const FONT_SCALE_MAX: number = 1.5;

/** 自定义密度合法范围（与 setCustomDensity 参数一致，-1.0 为恢复系统） */
const DENSITY_MIN: number = 0.5;
const DENSITY_MAX: number = 4.0;

export interface AppScaleConfig {
  mode: string;
  uiScale: number;
  fontScale: number;
}

export class AppScaleService {
  static readonly KEY_MODE: string = 'appScaleMode';
  static readonly KEY_UI_SCALE: string = 'appUiScale';
  static readonly KEY_FONT_SCALE: string = 'appFontScale';
  private static readonly PREFS_NAME: string = 'my_app_settings';

  /** 从偏好读取比例配置（缺失时默认跟随系统、比例 100%） */
  static async loadFromPrefs(context: common.UIAbilityContext): Promise<AppScaleConfig> {
    const pref = await preferences.getPreferences(context, AppScaleService.PREFS_NAME);
    const mode = await pref.get(AppScaleService.KEY_MODE, SCALE_MODE_SYSTEM) as string;
    const uiScale = await pref.get(AppScaleService.KEY_UI_SCALE, 1) as number;
    const fontScale = await pref.get(AppScaleService.KEY_FONT_SCALE, 1) as number;
    return {
      mode: mode === SCALE_MODE_CUSTOM ? SCALE_MODE_CUSTOM : SCALE_MODE_SYSTEM,
      uiScale: AppScaleService.clamp(uiScale, UI_SCALE_MIN, UI_SCALE_MAX),
      fontScale: AppScaleService.clamp(fontScale, FONT_SCALE_MIN, FONT_SCALE_MAX)
    };
  }

  /** 应用自定义比例：先设字体缩放，再设主窗口密度。任一失败返回 false。 */
  static applyCustom(context: common.UIAbilityContext, windowStage: window.WindowStage | null,
    uiScale: number, fontScale: number): boolean {
    let ok = true;
    try {
      const appCtx = context.getApplicationContext() as common.ApplicationContext;
      appCtx.setFontSizeScale(fontScale);
    } catch (e) {
      ok = false;
      logError(`AppScaleService 设置字体缩放失败: ${JSON.stringify(e)}`);
    }
    try {
      if (windowStage) {
        // density 与 display.densityPixels 同单位：按当前系统显示密度 × 用户倍率算出绝对密度
        const sysDensity = display.getDefaultDisplaySync().densityPixels;
        const density = Math.round(AppScaleService.clamp(sysDensity * uiScale, DENSITY_MIN, DENSITY_MAX) * 100) / 100;
        // 第二个参数 applyToSubWindow=true：已创建的子窗同步新密度，避免弹窗/底部页不一致
        windowStage.setCustomDensity(density, true);
      } else {
        logInfo('AppScaleService 未找到 windowStage，跳过界面缩放设置');
      }
    } catch (e) {
      ok = false;
      logError(`AppScaleService 设置界面缩放失败: ${JSON.stringify(e)}`);
    }
    return ok;
  }

  /** 启动时调用：custom 模式则应用；system 模式不动（引擎默认跟随系统） */
  static async applyFromPrefsAtStartup(context: common.UIAbilityContext, windowStage: window.WindowStage): Promise<void> {
    try {
      const cfg = await AppScaleService.loadFromPrefs(context);
      if (cfg.mode === SCALE_MODE_CUSTOM) {
        AppScaleService.applyCustom(context, windowStage, cfg.uiScale, cfg.fontScale);
        logInfo(`AppScaleService 启动已应用自定义比例: 界面=${cfg.uiScale}, 文字=${cfg.fontScale}`);
      } else {
        logInfo('AppScaleService 启动：跟随系统（无自定义比例）');
      }
    } catch (e) {
      logError(`AppScaleService 启动应用失败: ${JSON.stringify(e)}`);
    }
  }

  private static clamp(v: number, min: number, max: number): number {
    return Math.min(max, Math.max(min, v));
  }
}
