import { hdsMaterial, HdsTabs, HdsBarStyle } from '@kit.UIDesignKit';

/**
 * HdsMaterialPill 沉浸光感提示胶囊（miniBar 实验版）
 *
 * 原理：借 HdsTabs 浮动 TabBar 的 barFloatingStyle.systemMaterialEffect 在「内容区」
 * 拿到真系统材质。普通组件的 .systemMaterial() 属性在内容区不生效
 * （hilog 实锤 "Material inactive: out of scope"，2026-09-23），而 HdsTabs 浮动栏本身就是
 * 内容区组件、材质可用 —— 悬浮缩小钮 HdsMiniBarButton 就是同款实现（真机已验证）。
 *
 * ⭐ 形状实验（2026-09-23）：单 TabContent 的普通浮动栏渲染成圆形底板（宽≈高时明显），
 *   App 侧不可控。本轮改走 miniBar 显式配置：
 *   - miniBarWidth 三档钉死 pillWidth（若 miniBar 底板随宽度变长条 → 真材质+矩形兼得）
 *   - miniBarStyle EXPAND（尝试常驻展开态）
 *   - enableMiniBarClip false（避免 builder 内容被裁进圆形底板）
 *   实验判定：真机看底板形状——长条矩形 = 成功；仍是圆 = 此路不通，回退系统磨砂。
 *
 * 使用约束（照抄 HdsMiniBarButton 的坑）：
 * - pillWidth/pillHeight 必须传具体数值（HdsTabs barWidth/barHeight 不支持自适应）
 * - IMMERSIVE 材质必须显式配 gradientMask，省略会渲染成黑色遮罩（红线 13）
 */
@ComponentV2
export struct HdsMaterialPill {
  /** 胶囊宽（vp），必须具体数值 */
  @Param pillWidth: number = 112;

  /** 胶囊高（vp），必须具体数值 */
  @Param pillHeight: number = 48;

  /** 默认空内容（避免 BuilderParam 未初始化告警） */
  @Builder
  emptyContent() {
  }

  /** 内容槽位 */
  @BuilderParam content: () => void = this.emptyContent;

  /** miniBarBuilder 需要 CustomBuilder 类型，用箭头函数包一层 @BuilderParam */
  private miniBarContent: CustomBuilder = (): void => {
    this.content();
  };

  build() {
    HdsTabs() {
      TabContent()
        .tabBar(this.content())
    }
    .barWidth(this.pillWidth)
    .barHeight(this.pillHeight)
    .width(this.pillWidth)
    .height(this.pillHeight)
    .barOverlap(true)
    .barPosition(BarPosition.End)
    .barFloatingStyle({
      // 三档全钉死：浮动栏按 Tabs 自身宽度分档选宽，不钉会被默认值钳成圆球
      barWidth: {
        smallWidth: this.pillWidth,
        mediumWidth: this.pillWidth,
        largeWidth: this.pillWidth
      },
      barSideMargin: 0,
      gradientMask: { maskColor: Color.Transparent },
      barBottomMargin: 0,
      // ⭐ miniBar 实验配置：尝试让真材质底板变长条矩形
      miniBar: {
        miniBarBuilder: this.miniBarContent,
        miniBarWidth: {
          smallWidth: this.pillWidth,
          mediumWidth: this.pillWidth,
          largeWidth: this.pillWidth
        },
        miniBarStyle: HdsBarStyle.EXPAND,
        enableMiniBarClip: false,
        enableMiniBarBackground: true
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    .clip(false)
  }
}
