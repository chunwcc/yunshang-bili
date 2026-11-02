/**
 * HdsCircleBackButton —— 沉浸光感圆形返回按钮
 * 基于 HdsMiniBarButton（HdsTabs 系统材质通道）：barWidth == barHeight 时胶囊退化成正圆。
 *
 * ⚠️ 材质必须探测：设备不支持 IMMERSIVE 时降级 ADAPTIVE，否则系统资源解析失败会闪一下。
 *    （同 WhisperChatView 的 customMaterialType 探测逻辑）
 */
import { hdsMaterial } from '@kit.UIDesignKit';
import { HdsMiniBarButton } from './HdsMiniBarButton';
import { logInfo, logWarn } from '../../utils/Logger';

@ComponentV2
export struct HdsCircleBackButton {
  @Param buttonSize: number = 36;
  @Param iconSize: number = 20;
  @Param isDarkMode: boolean = false;
  @Param onBack: (() => void) | undefined = undefined;

  @Local materialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.ADAPTIVE;
  @Local materialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;

  aboutToAppear(): void {
    try {
      const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      if (types && types.includes(hdsMaterial.MaterialType.IMMERSIVE)) {
        this.materialType = hdsMaterial.MaterialType.IMMERSIVE;
      }
      logInfo(`[HdsCircleBackButton] 材质类型: ${this.materialType}`);
    } catch (e) {
      this.materialType = hdsMaterial.MaterialType.ADAPTIVE;
      logWarn(`[HdsCircleBackButton] 材质探测失败，降级 ADAPTIVE: ${e}`);
    }
  }

  build() {
    // Stack 包裹：@BuilderParam 尾随闭包组件不能直接链式挂通用属性
    Stack({ alignContent: Alignment.Center }) {
      HdsMiniBarButton({
        barWidth: this.buttonSize,
        barHeight: this.buttonSize,
        contentPadding: 4,
        materialType: this.materialType,
        materialLevel: this.materialLevel,
        barOverlap: true,
        barPosition: BarPosition.End,
        onButtonClick: (): void => {
          if (this.onBack) {
            this.onBack();
          }
        }
      }) {
        Image($r('app.media.ic_public_arrow_left_filled'))
          .width(this.iconSize)
          .height(this.iconSize)
          .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
      }
    }
    // 外层不裁剪，避免光效被裁掉（与 HomePage 导航胶囊一致）
    .clip(false)
  }
}
