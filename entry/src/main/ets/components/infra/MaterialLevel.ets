import { hdsMaterial } from '@kit.UIDesignKit';

/**
 * 材质等级字符串 → hdsMaterial.MaterialLevel 枚举转换
 *
 * 用于把 AppStorage 里存的字符串型材质等级（如 'EXQUISITE'）
 * 转成 HdsMiniBarButton 需要的 hdsMaterial.MaterialLevel 枚举。
 *
 * SDK 枚举真值（@hms.hds.hdsMaterial.d.ets, since 6.1.0(23)）：
 *   EXQUISITE = 0
 *   GENTLE    = 1
 *   SMOOTH    = 2
 *   ADAPTIVE  = 10
 */

/**
 * 把材质等级字符串转成 hdsMaterial.MaterialLevel 枚举。
 * 不识别的字符串回退到 ADAPTIVE（跟随系统）。
 *
 * @param level 材质等级字符串，如 'EXQUISITE' / 'GENTLE' / 'SMOOTH' / 'ADAPTIVE'
 * @returns 对应的 hdsMaterial.MaterialLevel 枚举值
 */
export function getHdsMaterialLevelRaw(level: string): hdsMaterial.MaterialLevel {
  switch (level) {
    case 'EXQUISITE':
      return hdsMaterial.MaterialLevel.EXQUISITE;
    case 'GENTLE':
      return hdsMaterial.MaterialLevel.GENTLE;
    case 'SMOOTH':
      return hdsMaterial.MaterialLevel.SMOOTH;
    case 'ADAPTIVE':
      return hdsMaterial.MaterialLevel.ADAPTIVE;
    default:
      return hdsMaterial.MaterialLevel.ADAPTIVE;
  }
}
