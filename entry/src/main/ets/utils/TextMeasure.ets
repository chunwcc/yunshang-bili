import { UIContext } from '@kit.ArkUI';

/**
 * ⭐ 按真实容器宽度测量文本行数
 * 用 measureTextSize 的 px 高度比值（整段测量高度 ÷ 单行高度），
 * 不受 vp/px 换算、系统字体缩放影响；测量失败时保守返回 1（不显示展开按钮）
 */
export function measureTextLines(uiContext: UIContext, text: string, widthVp: number, fontSizeVp: number): number {
  try {
    const m = uiContext.getMeasureUtils();
    const singleH = m.measureTextSize({ textContent: '汉', fontSize: fontSizeVp }).height as number;
    if (singleH <= 0) {
      return 1;
    }
    const fullH = m.measureTextSize({ textContent: text, fontSize: fontSizeVp, constraintWidth: widthVp }).height as number;
    if (fullH <= 0) {
      return 1;
    }
    // ⭐ 减 0.15 行阈值：浮点误差下刚好 8 行不会误判为 9 行
    return Math.max(1, Math.ceil(fullH / singleH - 0.15));
  } catch (_) {
    return 1;
  }
}
