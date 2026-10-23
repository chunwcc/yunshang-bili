import { ItemRestriction, SegmentButton, SegmentButtonOptions, SegmentButtonTextItem } from '@kit.ArkUI';
import { hdsMaterial } from '@kit.UIDesignKit';
import { HdsMiniBarButton } from './infra/HdsMiniBarButton';
import { getHdsMaterialLevelRaw } from './infra/MaterialLevel';

/**
 * HdsTitleBarSegment 标题栏分段选择器组件
 *
 * 基于 SegmentButton + HdsMiniBarButton 实现「沉浸光感材质 + 分段切换」效果。
 *
 * 双渲染路径：
 *   - 实验路径（experimentalComponents && api23）：把 SegmentButton 嵌进
 *     HdsMiniBarButton 材质容器，呈现沉浸光感毛玻璃质感。
 *   - 默认路径：直接平铺 SegmentButton，用系统色做底。
 *
 * 来源参考：DeadlinerNEXT/DeadlinerNEXT（HdsTitleBarSegment）
 * 适配本项目：V1 状态管理、单引号、显式类型、2 空格缩进。
 */
@Component
export struct HdsTitleBarSegment {
  /**
   * 分段项数据，必传。
   * ItemRestriction 是长度 2-3 的元组，对应 2-3 个分段按钮。
   */
  @Require buttons: ItemRestriction<SegmentButtonTextItem>;

  /**
   * 当前选中项索引数组（SegmentButton 的 tab 模式要求传数组）。
   * 走 AppStorage 中转同步：ComponentContent 路径不支持 @Link 双向绑定，
   * 改用 @StorageLink 让父级 Index 与本组件通过 AppStorage('titleSegmentIndex') 同步。
   */
  @StorageLink('titleSegmentIndex') selectedIndexes: number[] = [0];

  /**
   * 字号缩放上限，透传给 SegmentButton 做无障碍大字号。
   * @default 2
   */
  @Prop maxFontScale: number = 2;

  /**
   * 默认路径下分段按钮的高度。
   * @default 48
   */
  @Prop segmentHeight: number = 48;

  /**
   * 默认路径下分段按钮的宽度。
   * @default '100%'
   */
  @Prop normalWidth: Length = '100%';

  /**
   * 实验路径下分段按钮容器的宽度。
   * @default '100%'
   */
  @Prop experimentalWidth: Length = '100%';

  /**
   * 实验路径下材质容器的高度。
   * @default 52
   */
  @Prop experimentalHeight: number = 52;

  /**
   * 实验路径下实际测得的容器宽度（onAreaChange 回写）。
   */
  @State measuredWidth: number = 0;

  /**
   * 是否开启实验组件，从 AppStorage 读取。
   * @default true
   */
  @StorageLink('experimentalComponents') experimentalComponents: boolean = true;

  /**
   * 设备/系统是否支持 API 23 新特性，从 AppStorage 读取。
   * @default false
   */
  @StorageProp('api23') api23: boolean = false;

  /**
   * 用户自定义背景图路径，有图时叠加模糊。
   * @default ''
   */
  @StorageProp('customBackgroundImage') customBg: string = '';

  /**
   * 沉浸材质等级字符串，由父组件或设置页写入 AppStorage。
   * @default 'EXQUISITE'
   */
  @StorageProp('api23MaterialLevel') materialLevel: string = 'EXQUISITE';

  /**
   * 构造默认路径的 SegmentButton 配置。
   * 有自定义底图且支持 API 23 时，叠加 Thin 模糊；否则 NONE。
   * @returns SegmentButtonOptions 实例
   */
  private buildDefaultOptions(): SegmentButtonOptions {
    const blurStyle: BlurStyle = (!!this.customBg && this.api23) ? BlurStyle.Thin : BlurStyle.NONE;
    return SegmentButtonOptions.tab({
      buttons: this.buttons,
      backgroundBlurStyle: blurStyle,
      selectedBackgroundColor: $r('sys.color.segment_button_v2_tab_selected_item_background'),
      backgroundColor: $r('sys.color.comp_background_tertiary'),
      buttonPadding: 10
    });
  }

  /**
   * 构造实验路径的 SegmentButton 配置。
   * 实验路径下不使用 SegmentButton 自身的模糊，由 HdsMiniBarButton 统一提供材质。
   * @returns SegmentButtonOptions 实例
   */
  private buildExperimentalOptions(): SegmentButtonOptions {
    return SegmentButtonOptions.tab({
      buttons: this.buttons,
      backgroundBlurStyle: BlurStyle.NONE,
      selectedBackgroundColor: $r('sys.color.segment_button_v2_tab_selected_item_background'),
      backgroundColor: Color.Transparent,
      buttonPadding: 10
    });
  }

  /**
   * 计算实验路径下材质容器的宽度。
   * 已测量到真实宽度时优先用真实值；否则用「每按钮 84vp + 10vp 内边距」估算。
   * @returns 容器宽度（vp）
   */
  private resolveExperimentalBarWidth(): number {
    if (this.measuredWidth > 0) {
      return this.measuredWidth;
    }
    return 10 + this.buttons.length * 84;
  }

  /**
   * 渲染 SegmentButton 主体。
   * 两条路径共用此 builder，仅 SegmentButtonOptions 不同。
   * @param options SegmentButton 配置
   */
  @Builder
  private segmentContent(options: SegmentButtonOptions) {
    SegmentButton({
      options: options,
      selectedIndexes: $selectedIndexes,
      maxFontScale: this.maxFontScale
    })
      .width('100%')
      .height(this.segmentHeight)
  }

  /**
   * 组件主构建函数。
   * 根据 experimentalComponents && api23 决定走实验路径还是默认路径。
   */
  build() {
    if (this.experimentalComponents && this.api23) {
      // 实验路径：SegmentButton 嵌入沉浸光感材质容器
      Stack({ alignContent: Alignment.Center }) {
        HdsMiniBarButton({
          barWidth: this.resolveExperimentalBarWidth(),
          barHeight: this.experimentalHeight,
          materialLevel: getHdsMaterialLevelRaw(this.materialLevel)
        }) {
          this.segmentContent(this.buildExperimentalOptions())
        }
      }
      .width(this.experimentalWidth)
      .height(this.experimentalHeight)
      .onAreaChange((_, area) => {
        if (typeof area.width === 'number' && area.width > 0) {
          this.measuredWidth = area.width;
        }
      })
      .margin({ top: -8 })
    } else {
      // 默认路径：直接平铺 SegmentButton
      Stack({ alignContent: Alignment.Center }) {
        this.segmentContent(this.buildDefaultOptions())
      }
      .width(this.normalWidth)
      .height(this.segmentHeight)
    }
  }
}
