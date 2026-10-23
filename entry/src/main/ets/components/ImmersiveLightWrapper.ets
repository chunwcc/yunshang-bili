// ImmersiveLightWrapper.ets - 沉浸光感包裹组件（API 26 系统材质版）
// 自动检测运行时 API：API 26+ 使用 systemMaterial，否则降级到手动样式
import { uiMaterial, curves } from '@kit.ArkUI';
import { hdsEffect } from '@kit.UIDesignKit';

@ComponentV2
export struct ImmersiveLightWrapper {
  @BuilderParam content: () => void;
  @Param radius: number = 0; // wrapper 圆角
  @Param topRadius: number = -1; // 上圆角（-1=使用radius统一值）
  @Param bottomRadius: number = -1; // 下圆角（-1=使用radius统一值）
  @Param materialStyle: number = 0; // 材质厚度 0=ULTRA_THIN, 1=THIN, 2=REGULAR, 3=THICK, 4=ULTRA_THICK
  @Param lightHeight: number = 100; // 光源高度
  @Param lightColor: ResourceColor = Color.White; // 光源颜色
  @Param lightIntensity: number = 2.5; // 目标光强
  @Param fixedHeight: number = 0; // 固定内容高度（0 = 自适应 wrap；>0 时材质框固定高度，内部内容可滚动）
  @Param enableLight: boolean = true; // 是否启用按压点光源/追光（false = 纯材质胶囊，无光效交互）
  @Param showBorder: boolean = true; // 无光效路径的 1vp 白边描边（默认开以保持胶囊边界可见；面板等场景传 false 关闭）
  @Param enableBlur: boolean = true; // 是否启用降级路径 backdropBlur（false = 不模糊，背后消息透出更清晰）
  @Param fallbackColor: string = ''; // 自定义降级背景色（'' = 按 materialStyle 默认；非空 = 强制用该色，深色背景上保证通透）
  // ⭐ 官方 MaterialUtil 降级配方（Spatialization 示例）：不支持材质时用 backgroundBlurStyle(COMPONENT_THICK)
  //   而非手搓半透明色+backdropBlur。true 时忽略 fallbackColor/enableBlur，底色交由系统材质提供，
  //   colorMode 固定 DARK（播放器提示胶囊为白字，压在亮视频上也需要深色玻璃）。
  @Param useSystemBlurFallback: boolean = false;
  // ⭐ 实验参数（默认 false，不影响任何既有调用方）：true 时无视"内容区不生效"的官方规则，
  //   仍然尝试挂真 ImmersiveMaterial。真机用 hilog 抓 "Material inactive: out of scope" 实证判定——
  //   有日志=材质确实不渲染（回到降级路径）；无日志且胶囊出玻璃感=内容区其实能挂（赚到）。
  @Param trySystemMaterial: boolean = false;
  @Local currentIntensity: number = 0; // 当前光强
  @Local private fingerX: number = 0; // 手指位置
  @Local private fingerY: number = 0; // 手指位置
  // 运行时可用的材质对象（null = API 23 降级）
  @Local private materialObj: uiMaterial.ImmersiveMaterial | null = null;

  aboutToAppear(): void {
    // 7.0+ systemMaterial 官方规则：仅在 Navigation 标题栏/底部 TabBar/弹窗内生效。
    // 默认（trySystemMaterial=false）统一走降级半透明玻璃 —— 本组件大多数调用方在内容区。
    // trySystemMaterial=true（播放器提示胶囊）：仍试挂一次，靠真机日志实证判定（见参数注释）。
    //   applyShadow: false — 关闭系统材质自带阴影，避免出现矩形阴影；
    //   构造失败（低版本 API）静默降级。
    if (this.trySystemMaterial) {
      try {
        this.materialObj = new uiMaterial.ImmersiveMaterial({
          style: this.materialStyle as uiMaterial.ImmersiveStyle,
          applyShadow: false
        });
        return;
      } catch (_) {
        this.materialObj = null;
      }
    }
    this.materialObj = null;
  }

  private get effectiveTopRadius(): number {
    return this.topRadius >= 0 ? this.topRadius : this.radius;
  }

  private get effectiveBottomRadius(): number {
    return this.bottomRadius >= 0 ? this.bottomRadius : this.radius;
  }

  private get effectiveBorderRadius(): BorderRadiuses {
    return { topLeft: this.effectiveTopRadius, topRight: this.effectiveTopRadius, bottomLeft: this.effectiveBottomRadius, bottomRight: this.effectiveBottomRadius };
  }

  // ── API 23 降级：半透明毛玻璃效果 ──
  private get fallbackBgColor(): ResourceColor {
    if (this.fallbackColor !== '') {
      return this.fallbackColor;
    }
    if (this.materialStyle <= 0) {
      return '#12FFFFFF';
    } else if (this.materialStyle <= 2) {
      return '#90000000';
    }
    return '#99000000';
  }

  private get fallbackBlurRadius(): number {
    return this.materialStyle <= 0 ? 12 : 0;
  }

  // 追光组件（两路径共享）
  @Builder lightTracker() {
    Stack() {
      Flex()
        .size(this.currentIntensity ? { width: 1, height: 1 } : { width: 0, height: 0 })
        .backgroundColor(Color.Transparent)
        .visualEffect(
          new hdsEffect.HdsEffectBuilder()
            .pointLight({
              options: {
                color: this.lightColor,
                intensity: this.currentIntensity,
                height: this.lightHeight
              }
            })
            .buildEffect()
        )
        .position({ x: this.fingerX, y: this.fingerY })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  // ── API 26+ 渲染路径 ──
  @Builder buildApi26() {
    if (this.enableLight) {
      Stack() {
        this.content()
      }
      // ⭐ fixedHeight>0 时材质框固定高度（内部内容滚动）；0 保持自适应 wrap
      .height(this.fixedHeight > 0 ? this.fixedHeight : 'auto')
      .clip(true)
      .borderRadius(this.effectiveBorderRadius)
      .systemMaterial(this.materialObj)
      // ⭐ 染色层：材质在 backgroundColor 之下，若材质在内容区真渲染了（实验路径），
      //   60% 黑保证白字任何画面可读；若被判定 out of scope 不渲染，这层就是纯深色底（不透明保底）
      .backgroundColor('#99000000')
      .visualEffect(
        new hdsEffect.HdsEffectBuilder().pointLight({
          illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT,
        }).buildEffect()
      )
      .overlay(this.lightTracker())
      .onTouch((event: TouchEvent) => {
        this.handleTouch(event);
      })
    } else {
      Stack() {
        this.content()
      }
      .height(this.fixedHeight > 0 ? this.fixedHeight : 'auto')
      .clip(true)
      .borderRadius(this.effectiveBorderRadius)
      .systemMaterial(this.materialObj)
      .backgroundColor('#99000000')
      .border({ width: this.showBorder ? 1.5 : 0, color: '#33FFFFFF' })
    }
  }

  // ── API 23 降级路径 ──
  @Builder buildFallback() {
    if (this.enableLight) {
      Stack() {
        this.content()
      }
      .height(this.fixedHeight > 0 ? this.fixedHeight : 'auto')
      .clip(true)
      .borderRadius(this.effectiveBorderRadius)
      .shadow({ radius: 36, color: '#10000000' })
      // ⭐ 暗色染色：COMPONENT_THICK 是"内容自适应"玻璃（亮画面→浅玻璃、暗画面→深玻璃，
      //   真机 2026-09-23 实测），需要压一层黑保白字可读。60% 会把玻璃感盖死，40% 是
      //   "玻璃感可见 + 白字可读"的平衡点（浅画面上白玻璃被压成中灰、深画面本来就是深玻璃）
      .backgroundColor(this.useSystemBlurFallback ? '#66000000' : this.fallbackBgColor)
      .backgroundBlurStyle(this.useSystemBlurFallback ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE,
        { colorMode: ThemeColorMode.DARK })
      .border({ width: this.showBorder ? 1.5 : 0, color: '#33FFFFFF' })
      .backdropBlur(this.useSystemBlurFallback ? 0 : (this.enableBlur ? this.fallbackBlurRadius : 0))
      .visualEffect(
        new hdsEffect.HdsEffectBuilder().pointLight({
          illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT,
        }).buildEffect()
      )
      .overlay(this.lightTracker())
      .onTouch((event: TouchEvent) => {
        this.handleTouch(event);
      })
    } else {
      Stack() {
        this.content()
      }
      .height(this.fixedHeight > 0 ? this.fixedHeight : 'auto')
      .clip(true)
      .borderRadius(this.effectiveBorderRadius)
      .shadow({ radius: 36, color: '#10000000' })
      .backgroundColor(this.useSystemBlurFallback ? '#66000000' : this.fallbackBgColor)
      .backgroundBlurStyle(this.useSystemBlurFallback ? BlurStyle.COMPONENT_THICK : BlurStyle.NONE,
        { colorMode: ThemeColorMode.DARK })
      .border({ width: this.showBorder ? 1.5 : 0, color: '#33FFFFFF' })
      .backdropBlur(this.useSystemBlurFallback ? 0 : (this.enableBlur ? this.fallbackBlurRadius : 0))
    }
  }

  // 触控处理共享逻辑
  private handleTouch(event: TouchEvent): void {
    const da: boolean = AppStorage.get<boolean>('da') ?? false;
    if (event.type === TouchType.Down) {
      if (da) {
        this.currentIntensity = this.lightIntensity;
      } else {
        this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseIn }, () => {
          this.currentIntensity = this.lightIntensity;
        })
      }
      this.fingerX = event.touches[0].x;
      this.fingerY = event.touches[0].y;
    } else if (event.type === TouchType.Move) {
      if (da) {
        this.fingerX = event.touches[0].x;
        this.fingerY = event.touches[0].y;
      } else {
        this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion(0.5, 0.5) }, () => {
          this.fingerX = event.touches[0].x;
          this.fingerY = event.touches[0].y;
        })
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (da) {
        this.currentIntensity = 0;
      } else {
        this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
          this.currentIntensity = 0;
        })
      }
    }
  }

  build() {
    if (this.materialObj !== null) {
      this.buildApi26();
    } else {
      this.buildFallback();
    }
  }
}
