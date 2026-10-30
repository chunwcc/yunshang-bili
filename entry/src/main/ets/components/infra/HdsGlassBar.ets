import { hdsMaterial, HdsTabs } from '@kit.UIDesignKit';

/**
 * HdsGlassBar —— 沉浸光感「玻璃底板」通用件（照 yunjianBJ 的 HdsGlassBar 移植）
 *
 * 三层结构缺一不可（详见 yunjianBJ/docs/底栏胶囊与滑动高光实现.md）：
 *   ① 容器比玻璃大一圈：size = bar + contentPadding * 4 + padding(contentPadding)
 *      ⇒ 玻璃四周有"浮起来"的空间，边缘高光/阴影不被裁；
 *   ② 玻璃由 HdsTabs 浮动栏系统自绘（barFloatingStyle.systemMaterialEffect），
 *      尺寸只由 barWidth/barHeight 决定；
 *   ③ 浮栏贴 Tabs 底部绘制，barBottomMargin 把玻璃抬回容器中心。
 *
 * 用法：
 *   HdsGlassBar({ barWidth: 168, barHeight: 40, contentPadding: 4, hitThrough: true }) { ... }
 *   hitThrough=true 时整棵子树退出命中 ⇒ 调用方在玻璃上方叠自己的按钮（多按钮胶囊必须这样，
 *   因为 HdsTabs 的 onTabBarClick 只有"整条"一个回调）。
 *
 * ⛔ 硬约束：
 *   · barWidth/barHeight 必须是具体数值；
 *   · gradientMask.maskColor 必须显式透明（省略=黑色遮罩）；
 *   · HdsTabs 不设 .height()（高度由外层 Row 撑开）；
 *   · 外层不要 clip / borderRadius（会把玻璃边缘与光效一起裁掉）。
 */
@ComponentV2
export struct HdsGlassBar {
  /** 玻璃宽度（vp），必须具体数值 */
  @Param barWidth: number = 50;
  /** 玻璃高度（vp），必须具体数值 */
  @Param barHeight: number = 50;
  /** 容器外围余量：容器 = bar + contentPadding * 4 */
  @Param contentPadding: number = 4;
  /** 浮栏距 Tabs 底部；默认 = contentPadding ⇒ 玻璃回到容器中心 */
  @Param barBottomMargin: number = 4;
  /** 材质类型 */
  @Param materialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.IMMERSIVE;
  /** 材质档位 */
  @Param materialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;
  /** 系统光色（按压光/边缘高光） */
  @Param lightColor: ResourceColor = '#66FFFFFF';
  /** true = 玻璃层退出命中，调用方在玻璃上方叠内容/按钮 */
  @Param hitThrough: boolean = true;
  /** 整条玻璃的点击（仅 hitThrough=false 时生效） */
  @Param onButtonClick: (() => void) | undefined = undefined;

  @Builder
  emptyContent() {
    // 透明占位：让 HdsTabs 的浮动栏始终有内容可画，玻璃底板才会渲染。
    // 多按钮胶囊由调用方在玻璃上方自绘内容与触摸。
    Row().width('100%').height('100%')
  }

  /** 内容槽位：画在 tabBar 里（需要跟随系统形变时用；多按钮场景建议留空、上层自绘） */
  @BuilderParam content: () => void = this.emptyContent;

  build() {
    Row() {
      HdsTabs() {
        TabContent()
          .tabBar(this.content())
      }
      .barWidth(this.barWidth)
      .barHeight(this.barHeight)
      .width(this.barWidth)
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .barFloatingStyle({
        // ⛔ 必须显式透明：省略会渲染成黑色遮罩
        gradientMask: { maskColor: Color.Transparent },
        // ⭐ 三档宽度全部钉死 = barWidth：否则系统按默认分档（约 356 封顶）画玻璃，
        //    长胶囊（底部 416）会被截短、内容右溢、整体不居中（用户实测反馈）。
        barWidth: {
          smallWidth: this.barWidth,
          mediumWidth: this.barWidth,
          largeWidth: this.barWidth
        },
        barSideMargin: 0,
        barBottomMargin: this.barBottomMargin,
        lightColor: this.lightColor,
        systemMaterialEffect: {
          materialType: this.materialType,
          materialLevel: this.materialLevel
        }
      })
      .onTabBarClick((): void => {
        if (this.onButtonClick !== undefined) {
          this.onButtonClick();
        }
      })
      .clip(false)
      .hitTestBehavior(this.hitThrough ? HitTestMode.None : HitTestMode.Default)
    }
    .size({ width: this.barWidth + this.contentPadding * 4, height: this.barHeight + this.contentPadding * 4 })
    .padding(this.contentPadding)
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(this.hitThrough ? HitTestMode.None : HitTestMode.Default)
  }
}
