/**
 * VibrateUtils.ts
 * 震动反馈统一封装 — 检查全局开关 vibrateEnabled（个性化设置控制）
 */
import { vibrator } from '@kit.SensorServiceKit';

export class VibrateUtils {
  /** 时长震动 — 检查全局开关 */
  static vibrateTime(duration: number): void {
    try {
      const enabled = AppStorage.get<boolean>('vibrateEnabled') ?? true;
      if (!enabled) return;
      vibrator.startVibration({ type: 'time', duration: duration }, { id: 0, usage: 'physicalFeedback' });
    } catch (_) {}
  }

  /** 预设震动效果 — 检查全局开关 */
  static vibratePreset(effectId: string): void {
    try {
      const enabled = AppStorage.get<boolean>('vibrateEnabled') ?? true;
      if (!enabled) return;
      vibrator.startVibration({ type: 'preset', effectId: effectId }, { usage: 'unknown' });
    } catch (_) {}
  }
}