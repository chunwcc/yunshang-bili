// FullImagePreview.ets — 通用全屏图片预览组件（抽取自 CommentContentRenderer）
// 未缩放：Swiper 左右滑动 + PinchGesture 双指缩放 + TapGesture 单击关闭
// 缩放中：Tap(Exclusive) 关闭 + Pan/Pinch(Parallel) 平移/缩放，左上角 minimap 缩略图导航 + 视口指示器
// 用法：
//   FullImagePreview({ isShow: $$this.showPreview, previewUrls: this.previewImageUrls, initialIndex: this.previewIndex })
import { curves, window, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { logWarn } from '../utils/Logger';

/**
 * 通用全屏图片预览
 * @param isShow 是否显示（@Link 双向绑定，父组件用 $$this.xxx 传入）
 * @param previewUrls 预览图片 URL 列表（原图）
 * @param initialIndex 打开时初始显示第几张（0 起）
 */
@Component
export struct FullImagePreview {
  /** @Watch 必须叠加在状态变量上（不能装饰方法）：打开时回调 onShowChange 重置状态 */
  @Link @Watch('onShowChange') isShow: boolean;
  @Prop previewUrls: string[];
  /** ⭐ 每张预览图对应的缩略图组件 id（与 previewUrls 对齐）：滑动切图后关闭时按当前 previewIndex 重新捕获飞回矩形 */
  @Prop thumbIds: string[] = [];
  /** ⭐ initialIndex 变化时回调 onInitialIndexChange：预览已开（isShow=true）时同步索引，避免快速连续点击显示旧图 */
  @Prop @Watch('onInitialIndexChange') initialIndex: number = 0;
  /** ⭐ 起点矩形（缩略图相对窗口的 vp 坐标与尺寸，用于一镜到底飞入飞回；全 0 时退化为中心缩放）
   *    ⚠️ 用 @Link 而非 @Prop：@Watch('isShow') 回调触发时 @Prop 可能尚未更新到新值（读到上一次的矩形），
   *      @Link 为引用传递，回调中读到的是父组件最新值 */
  @Link originX: number;
  @Link originY: number;
  @Link originW: number;
  @Link originH: number;

  /** ⭐ 沉浸式全屏页面（横屏/全屏布局，状态栏应一直隐藏）：true 时预览关闭不恢复状态栏（保持隐藏） */
  @Prop immersiveMode: boolean = false;

  /** 当前预览的图片索引（@Watch：页码变化时播放淡入上移动画） */
  @State @Watch('onPreviewIndexChange') previewIndex: number = 0;
  /** 图片缩放倍数（1.0=原始，8.0=最大） */
  @State zoomScale: number = 1.0;
  /** 手势开始时保存的缩放倍数 */
  private zoomScaleStart: number = 1.0;
  /** 图片平移偏移量（缩放后拖动用） */
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  /** 手势开始时保存的偏移量 */
  private panStartX: number = 0;
  private panStartY: number = 0;
  /** 当前手势累积位移（用于方向判断） */
  private gestureDeltaX: number = 0;
  private gestureDeltaY: number = 0;
  /** 预览区域实际尺寸（用于计算拖动边界） */
  @State viewWidth: number = 360;
  @State viewHeight: number = 780;
  /** 图片入场/退场缩放（一镜到底：打开时从起点矩形飞到全屏，收起时飞回；背景保持全屏不缩放） */
  @State previewImgScale: number = 1.0;
  /** 一镜到底：飞入/飞回 X 偏移（起点矩形中心 → 全屏中心） */
  @State flyOffsetX: number = 0;
  /** 一镜到底：飞入/飞回 Y 偏移 */
  @State flyOffsetY: number = 0;
  /** 一镜到底：飞入/飞回缩放（起点尺寸 → 全屏） */
  @State flyScale: number = 1.0;
  /** 一镜到底：图片是否已启动飞入（防多 Image onComplete 重复触发；每次打开重置） */
  @State flyInStarted: boolean = false;
  /** 预览图片是否已解码完成（未完成时显示加载指示器，避免解码期间空白像卡住） */
  @State previewImgLoaded: boolean = false;
  /** 滚轮计数器：上一页码（用于旧数字滚出） */
  @State lastPageIndex: number = 0;
  /** 滚轮计数器：新数字滚入偏移（20→0） */
  @State newNumOffsetY: number = 0;
  /** 滚轮计数器：新数字不透明度（0→1） */
  @State newNumOpacity: number = 1.0;
  /** 滚轮计数器：旧数字滚出偏移（0→-20） */
  @State oldNumOffsetY: number = 0;
  /** 滚轮计数器：旧数字不透明度（1→0） */
  @State oldNumOpacity: number = 0;

  /** 页码变化时播放滚轮动画：新数字从下方滚入 + 旧数字向上滚出 */
  onPreviewIndexChange(_propName: string): void {
    this.newNumOffsetY = 20;
    this.newNumOpacity = 0;
    this.oldNumOffsetY = 0;
    this.oldNumOpacity = 1;
    animateTo({
      duration: 250,
      curve: Curve.EaseInOut,
      onFinish: () => {
        // 动画结束才更新旧值，避免旧数字中途变新值造成重影
        this.lastPageIndex = this.previewIndex;
        this.oldNumOpacity = 0;
      }
    }, () => {
      this.newNumOffsetY = 0;
      this.newNumOpacity = 1;
      this.oldNumOffsetY = -20;
      this.oldNumOpacity = 0;
    });
  }

  /** 打开时重置状态（同步初始索引；由 @Link @Watch 在 isShow 变化时调用） */
  onShowChange(_propName: string): void {
    if (this.isShow) {
      // ⭐ 预览打开：隐藏状态栏（沉浸式全屏），关闭时恢复
      this.setSystemBarsVisible(false);
      this.previewIndex = this.initialIndex;
      this.zoomScale = 1.0;
      this.offsetX = 0;
      this.offsetY = 0;
      // ⭐ 一镜到底飞入动画在图片 onComplete（解码完成、可显示）时启动：
      //   原图解码可能慢于动画（日志实证 ~400ms vs 动画 ~300ms），若动画先跑完，
      //   图片解码完成后以全屏突然出现；onComplete 保证图片可见时才开始飞入
      this.flyInStarted = false;
      this.previewImgLoaded = false;
    } else {
      // ⭐ 预览关闭：沉浸式页面重新隐藏状态栏（setSystemBarsVisible(false)——防旋转/系统重置后状态栏显示，
      //   ⚠️ 仅"不恢复"不够，旋转后系统会把状态栏重置为显示）；非沉浸式恢复状态栏
      this.setSystemBarsVisible(!this.immersiveMode);
      this.flyInStarted = false;
      // 收起：图片从全屏（0/0/1.0）飞回缩略图矩形起点（配合 contentCover 淡出）
      const o = this.calcFlyOrigin();
      animateTo({ curve: curves.interpolatingSpring(0, 1, 228, 22) }, () => {
        this.flyOffsetX = o[0];
        this.flyOffsetY = o[1];
        this.flyScale = o[2];
      });
    }
  }

  /** 图片解码完成（可显示）后调用：隐藏加载指示器、从缩略图矩形起点飞入全屏；防重复触发 */
  private playFlyIn(): void {
    if (this.flyInStarted) return;
    this.flyInStarted = true;
    this.previewImgLoaded = true;
    const o = this.calcFlyOrigin();
    this.flyOffsetX = o[0];
    this.flyOffsetY = o[1];
    this.flyScale = o[2];
    animateTo({ curve: curves.interpolatingSpring(0, 1, 228, 22) }, () => {
      this.flyOffsetX = 0;
      this.flyOffsetY = 0;
      this.flyScale = 1.0;
    });
  }

  /** 计算图片起点（缩略图矩形中心→全屏中心偏移 + 尺寸缩放）；返回 [offX, offY, scale]，无起点矩形时退化为 0.6 中心缩放 */
  private calcFlyOrigin(): number[] {
    const vw = this.viewWidth - 32;
    const vh = this.viewHeight - 32;
    // ⭐ 滑动切图后按当前 previewIndex 重新捕获对应缩略图矩形（飞回当前显示图的位置，而非点击时那张）
    let ox = this.originX;
    let oy = this.originY;
    let ow = this.originW;
    let oh = this.originH;
    const thumbId = this.thumbIds.length > 0 ? this.thumbIds[this.previewIndex] : '';
    if (thumbId) {
      try {
        const info = this.getUIContext().getComponentUtils().getRectangleById(thumbId);
        ox = this.getUIContext().px2vp(info.windowOffset.x);
        oy = this.getUIContext().px2vp(info.windowOffset.y);
        ow = this.getUIContext().px2vp(info.size.width);
        oh = this.getUIContext().px2vp(info.size.height);
      } catch (e) {
        // 捕获失败时回退点击时记录的起点矩形
      }
    }
    let offX = 0;
    let offY = 0;
    let scale = 0.6;
    if (ow > 0 && oh > 0) {
      scale = Math.min(ow / vw, oh / vh);
      offX = (ox + ow / 2) - this.viewWidth / 2;
      offY = (oy + oh / 2) - this.viewHeight / 2;
    }
    return [offX, offY, scale];
  }

  /** 预览打开/关闭时隐藏/恢复系统状态栏（仿 VideoPlayerPage.manageSB） */
  private async setSystemBarsVisible(visible: boolean): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      const win: window.Window = await window.getLastWindow(context);
      // ⭐ 横屏时状态栏本就应隐藏：即使请求恢复也保持隐藏，避免横屏布局显示状态栏
      const d = display.getDefaultDisplaySync();
      const isLandscape = d.width > d.height;
      if (visible && !isLandscape) {
        win.setWindowSystemBarEnable(['status', 'navigation']);
      } else {
        win.setWindowSystemBarEnable([]);
      }
    } catch (e) {
      logWarn(`[FullImagePreview] 设置状态栏失败: ${e}`);
    }
  }

  /** initialIndex 变化（快速连续点击不同图）且预览已开时同步索引与缩放状态 */
  onInitialIndexChange(_propName: string): void {
    if (this.isShow) {
      this.previewIndex = this.initialIndex;
      this.zoomScale = 1.0;
      this.offsetX = 0;
      this.offsetY = 0;
    }
  }

  // 缩略图导航参数
  get miniW(): number { return 50; }
  get miniH(): number { return 50; }
  get miniVw(): number { return this.viewWidth - 32; }
  get miniVh(): number { return this.viewHeight - 32; }
  get miniRectW(): number { return this.miniW / this.zoomScale; }
  get miniRectH(): number { return this.miniH / this.zoomScale; }
  get miniRectX(): number {
    let raw = this.miniW * (0.5 - 0.5 / this.zoomScale - this.offsetX / (this.miniVw * this.zoomScale));
    return Math.max(0, Math.min(this.miniW - this.miniRectW, raw));
  }
  get miniRectY(): number {
    let raw = this.miniH * (0.5 - 0.5 / this.zoomScale - this.offsetY / (this.miniVh * this.zoomScale));
    return Math.max(0, Math.min(this.miniH - this.miniRectH, raw));
  }

  build() {
    // ⚠️ 主体必须是零尺寸且不拦截触摸（HitTestMode.None）：
    // 此前 width('100%')/height('100%') 的全屏透明占位会拦截动态页点击/滑动（点击图片无效、滑动滑出动态页）。
    // bindContentCover 是全屏覆盖层，与宿主尺寸无关，零尺寸宿主不影响预览显示。
    Stack() {
      Column()
        .width(0)
        .height(0)
        .hitTestBehavior(HitTestMode.None)
    }
    .width(0)
    .height(0)
    .hitTestBehavior(HitTestMode.None)
    // ⭐ 背景保持全屏静止（transition 仅 opacity 淡入淡出），图片缩放由 previewImgScale 单独驱动
    .bindContentCover($$this.isShow, this.previewBuilder(), {
      transition: TransitionEffect.asymmetric(
        TransitionEffect.opacity(0)
          .animation({ curve: curves.interpolatingSpring(0, 1, 228, 22) }),
        TransitionEffect.opacity(0)
          .animation({ curve: curves.interpolatingSpring(0, 1, 228, 22) })
      )
    })
  }

  @Builder
  minimapBuilder() {
    Stack() {
      Image(this.previewUrls[this.previewIndex])
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
      // 视口指示器（白色边框 + 半透明填充）
      Stack()
        .width(this.miniRectW)
        .height(this.miniRectH)
        .position({ x: this.miniRectX, y: this.miniRectY })
        .border({ width: 1.5, color: Color.White })
        .backgroundColor('rgba(255,255,255,0.1)')
    }
    .width(this.miniW)
    .height(this.miniH)
    .backgroundColor('rgba(0,0,0,0.65)')
    .borderRadius(4)
    .clip(true)
    .alignContent(Alignment.Center)
    .position({ top: 60, left: 10 })
    .border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
  }

  @Builder
  previewBuilder() {
    Stack() {
      // 深色半透明背景 + 轻微高斯模糊（backdropBlur 模糊背后页面，提升层次感）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.72)')
        .backdropBlur(20)

      // ⭐ 图片解码期间显示加载指示器（避免空白像卡住；解码完成 onComplete → playFlyIn 隐藏）
      if (!this.previewImgLoaded) {
        LoadingProgress()
          .width(36)
          .height(36)
          .color(Color.White)
          .align(Alignment.Center)
      }

      // ========== 未缩放：Swiper + PinchGesture + TapGesture ==========
      // ⚠️ Swiper/单 Image 两个节点常驻，用 visibility 切显隐而非 if/else 切换子树：
      //    if/else 会在缩放跨越 1.0 阈值时销毁重建 Image 节点导致重新解码（闪烁）
      Swiper() {
        ForEach(this.previewUrls, (url: string) => {
          Image(url)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
            .padding(16)
            .clip(true)
            .borderRadius(12)
            .scale({ x: this.previewImgScale * this.flyScale, y: this.previewImgScale * this.flyScale })
            .offset({ x: this.flyOffsetX, y: this.flyOffsetY })
            // ⭐ 图片解码完成（可显示）才启动飞入动画，避免动画跑完后图片突然出现
            //   ⚠️ setTimeout 延迟：onComplete 可能在 build 渲染期间触发，直接改 @State 会被 ArkUI 拒绝
            //     （日志 FIX THIS APPLICATION ERROR: State variable has changed during render → 动画/指示器错乱）
            .onComplete(() => {
              setTimeout(() => {
                this.playFlyIn();
              }, 0);
            })
            .priorityGesture(
              GestureGroup(GestureMode.Exclusive,
                TapGesture({ count: 1 }).onAction(() => {
                  this.isShow = false
                }),
                PinchGesture({ fingers: 2 })
                  .onActionStart(() => {
                    this.zoomScaleStart = this.zoomScale
                  })
                  .onActionUpdate((event: PinchGestureEvent) => {
                    this.zoomScale = Math.max(1.0, Math.min(8.0,
                      this.zoomScaleStart * event.scale))
                  })
              )
            )
        }, (url: string) => url)
      }
      .index(this.previewIndex)
      // ⭐ 预加载相邻页图片（切图时不用重新下载，减少空白闪烁；cachedCount API 实证可用）
      .cachedCount(1)
      .onChange((index: number) => {
        this.previewIndex = index
        this.zoomScale = 1.0
        this.offsetX = 0
        this.offsetY = 0
      })
      .indicator(false)
      .width('100%')
      .height('100%')
      .visibility(this.zoomScale <= 1.0 ? Visibility.Visible : Visibility.Hidden)

      // ========== 缩放中：Tap(Exclusive) + Pan/Pinch(Parallel) ==========
      Image(this.previewUrls[this.previewIndex])
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Contain)
        .padding(16)
        .clip(true)
        .borderRadius(12)
        .scale({ x: this.zoomScale * this.previewImgScale * this.flyScale, y: this.zoomScale * this.previewImgScale * this.flyScale })
        .offset({ x: this.offsetX + this.flyOffsetX, y: this.offsetY + this.flyOffsetY })
        // ⭐ 图片解码完成（可显示）才启动飞入动画，避免动画跑完后图片突然出现
        //   ⚠️ setTimeout 延迟：onComplete 可能在 build 渲染期间触发，直接改 @State 会被 ArkUI 拒绝
        //     （日志 FIX THIS APPLICATION ERROR: State variable has changed during render → 动画/指示器错乱）
        .onComplete(() => {
          setTimeout(() => {
            this.playFlyIn();
          }, 0);
        })
        .priorityGesture(
          GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 1 }).onAction(() => {
              this.isShow = false
            }),
            GestureGroup(GestureMode.Parallel,
              PanGesture({ distance: 1 })
                .onActionStart(() => {
                  this.panStartX = this.offsetX
                  this.panStartY = this.offsetY
                  this.gestureDeltaX = 0
                  this.gestureDeltaY = 0
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.gestureDeltaX = event.offsetX
                  this.gestureDeltaY = event.offsetY
                  const viewW = this.viewWidth - 32
                  const viewH = this.viewHeight - 32
                  const maxOffsetX = (this.zoomScale - 1) * viewW / 2
                  const maxOffsetY = (this.zoomScale - 1) * viewH / 2
                  let newX = this.panStartX + this.gestureDeltaX * this.zoomScale
                  let newY = this.panStartY + this.gestureDeltaY * this.zoomScale
                  newX = Math.max(-maxOffsetX, Math.min(maxOffsetX, newX))
                  newY = Math.max(-maxOffsetY, Math.min(maxOffsetY, newY))
                  this.offsetX = newX
                  this.offsetY = newY
                })
                .onActionEnd(() => {
                  if (Math.abs(this.gestureDeltaX) > Math.abs(this.gestureDeltaY) * 1.5
                      && Math.abs(this.gestureDeltaX) > 60) {
                    if (this.gestureDeltaX < 0 && this.previewIndex < this.previewUrls.length - 1) {
                      this.previewIndex++
                    } else if (this.gestureDeltaX > 0 && this.previewIndex > 0) {
                      this.previewIndex--
                    }
                    this.offsetX = 0
                    this.offsetY = 0
                    this.zoomScale = 1.0
                  } else {
                    this.offsetX = 0
                  }
                }),
              PinchGesture({ fingers: 2 })
                .onActionStart(() => {
                  this.zoomScaleStart = this.zoomScale
                })
                .onActionUpdate((event: PinchGestureEvent) => {
                  this.zoomScale = Math.max(1.0, Math.min(8.0,
                    this.zoomScaleStart * event.scale))
                  if (this.zoomScale <= 1.05) {
                    this.zoomScale = 1.0
                    this.offsetX = 0
                    this.offsetY = 0
                  }
                })
            )
          )
        )
        .visibility(this.zoomScale > 1.0 ? Visibility.Visible : Visibility.Hidden)

      // 放大时左上角显示缩略图导航 + 视口指示器（出现/隐藏带淡入缩放过渡）
      if (this.zoomScale > 1.0) {
        Stack() {
          Image(this.previewUrls[this.previewIndex])
            .width(100)
            .height(100)
            .objectFit(ImageFit.Contain)
          // 视口指示器（白色边框）
          Stack()
            .width(100 / this.zoomScale)
            .height(100 / this.zoomScale)
            .position({
              x: Math.max(0, Math.min(100 - 100 / this.zoomScale,
                100 * (0.5 - 0.5 / this.zoomScale - this.offsetX / ((this.viewWidth - 32) * this.zoomScale)))),
              y: Math.max(0, Math.min(100 - 100 / this.zoomScale,
                100 * (0.5 - 0.5 / this.zoomScale - this.offsetY / ((this.viewHeight - 32) * this.zoomScale))))
            })
            .border({ width: 1, color: Color.White })
            .backgroundColor('rgba(255,255,255,0.08)')
        }
        .width(100)
        .height(100)
        .backgroundColor('rgba(0,0,0,0.65)')
        .borderRadius(6)
        .clip(true)
        .position({ top: 60, left: 10 })
        .border({ width: 0.5, color: 'rgba(255,255,255,0.25)' })
        // ⭐ 出现/隐藏过渡：淡入 + 轻微放大（消失时反向）
        .transition(
          TransitionEffect.opacity(0)
            .combine(TransitionEffect.scale({ x: 0.8, y: 0.8 }))
            .animation({ duration: 200, curve: Curve.EaseOut })
        )
      }

      // 页码指示器（顶部居中，如 1/9；未缩放时显示；滚轮计数器：新数字滚入 + 旧数字滚出，/总数静态）
      if (this.previewUrls.length > 1 && this.zoomScale <= 1.0) {
        Row() {
          // ⭐ 固定高度窗口 + clip：滚轮效果（数字在窗口内上下滚动，超出裁剪）
          Stack() {
            // 新数字：从下方滚入 + 淡入
            Text(`${this.previewIndex + 1}`)
              .fontSize(14)
              .fontColor(Color.White)
              .textShadow({ radius: 2, color: '#99000000', offsetX: 0, offsetY: 1 })
              .opacity(this.newNumOpacity)
              .translate({ y: this.newNumOffsetY })
            // 旧数字：向上滚出 + 淡出（动画结束后隐藏）
            if (this.oldNumOpacity > 0) {
              Text(`${this.lastPageIndex + 1}`)
                .fontSize(14)
                .fontColor(Color.White)
                .textShadow({ radius: 2, color: '#99000000', offsetX: 0, offsetY: 1 })
                .opacity(this.oldNumOpacity)
                .translate({ y: this.oldNumOffsetY })
            }
          }
          .height(20)
          .clip(true)
          Text(`/${this.previewUrls.length}`)
            .fontSize(14)
            .fontColor(Color.White)
            .textShadow({ radius: 2, color: '#99000000', offsetX: 0, offsetY: 1 })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .position({ top: 44 })
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.viewWidth = newValue.width as number
      this.viewHeight = newValue.height as number
    })
  }
}
