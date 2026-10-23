import { CommentContent, CommentPicture } from '../api/BilibiliApi';
import { curves, window, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { logWarn } from '../utils/Logger';

function resizeImageUrl(url: string, width: number): string {
  if (!url || !url.includes('hdslb.com')) {
    return url;
  }
  // ⚠️ 原实现 `!url.includes('@')`：URL 已带后缀（评论图常见 `@880w_880h_1c.webp`）时**整段跳过压缩**，
  //    原图被整张解码（实测 2560x1440 / 4254x4255 单张解码 130ms）→ 先剥旧后缀再挂显示尺寸
  const at: number = url.indexOf('@');
  const base: string = (at > url.lastIndexOf('/') && url.indexOf('?') < 0) ? url.substring(0, at) : url;
  return base + `@${width}w`;
}

interface MessageSegment {
  text: string;
  isEmote: boolean;
  url?: string;
}

/**
 * 评论内容渲染组件
 * 支持：
 * 1. 表情图片渲染（替换 [doge] 等表情文本）
 * 2. 评论配图渲染（点击图片全屏预览）
 */
@Component
export struct CommentContentRenderer {
  @Prop content: CommentContent | null = null;
  @Prop fontSize: number = 13;
  @Prop textColor: ResourceColor = Color.White;
  @Prop maxLines: number = 999;
  @Prop isCenter: boolean = false;
  /** ⭐ 缩略图组件 id 唯一前缀（评论 rpid 等）：多评论实例下避免 getRectangleById 取错缩略图矩形 */
  @Prop thumbIdPrefix: string = '';
  /**
   * ⭐ 单图的"适配框"（内容可用宽 / 高度上限，vp）。任一为 0 = 不启用（默认；动态页/详情页不变）。
   *
   * 语义是**按比例缩进框里**，不是裁切：
   *   高度(按原比例) ≤ 上限 → 原样铺满整宽，小图/横图完全不变；
   *   超过上限            → 高度取上限、宽度按比例缩并居中，**整张图仍完整可见**，不裁切、不加胶囊。
   *
   * 为什么要它：判定"超长图"的阈值是 h/w > 16/9，于是 1:1 / 4:5 / 3:4 这些最常见的手机照片全落在
   * "普通图"档、按原比例铺满整宽 —— 1:1 就约一个屏宽高，3:4 接近 480vp。
   *
   * ⚠️ 实现取巧：本组件图片尺寸由 `.aspectRatio(原图比例)` 决定，高度 = 宽 ÷ 比例，
   *    所以"限制高度"只需限制**宽度**（高度会自动跟着缩），不必写两套尺寸表达式。
   */
  @Prop picBoxW: number = 0;
  /** 单图高度上限（vp）；与 picBoxW 同时 > 0 才生效 */
  @Prop picBoxH: number = 0;
  @StorageLink('cardBorderRadius') cardBorderRadius: number = 20;

  /** 是否显示全屏图片预览（@State 局部状态，每个实例独立；@Watch 在变化时驱动图片入场/退场缩放） */
  @State @Watch('onShowPreviewChange') showPreview: boolean = false;
  /** 所有预览图片 URL 列表 */
  @State previewImageUrls: string[] = [];
  /** 当前预览的图片索引（@Watch：页码变化时播放淡入上移动画） */
  @State @Watch('onPreviewIndexChange') previewIndex: number = 0;
  /** 图片缩放倍数（1.0=原始，3.0=最大） */
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
  /** ⭐ Swiper 控制器：bindContentCover content 不每次重建，Swiper .index() 仅初始化生效；
   *  后续打开预览时需 swiperController.show() 强制跳转到点击的图片，否则显示上次浏览的页码 */
  private swiperController: SwiperController = new SwiperController();
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
  /** 一镜到底起点矩形（点击的缩略图相对窗口的 vp 坐标/尺寸；点击时由 getRectangleById 填充） */
  @State previewOriginX: number = 0;
  @State previewOriginY: number = 0;
  @State previewOriginW: number = 0;
  @State previewOriginH: number = 0;
  /** ⭐ 每张预览图对应的缩略图组件 id（与 previewImageUrls 对齐）：滑动切图后关闭时按当前 previewIndex 重新捕获飞回矩形 */
  @State previewThumbIds: string[] = [];
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

  /** showPreview 变化时驱动图片缩放（背景保持全屏静止，只图片一镜到底） */
  onShowPreviewChange(_propName: string): void {
    if (this.showPreview) {
      // ⭐ 预览打开：隐藏状态栏（沉浸式全屏），关闭时恢复
      this.setSystemBarsVisible(false);
      // ⭐ @Reusable 复用可能残留上一条评论预览的缩放/平移状态：每次打开重置为未缩放
      this.zoomScale = 1.0;
      this.offsetX = 0;
      this.offsetY = 0;
      // ⭐ 一镜到底飞入动画在图片 onComplete（解码完成、可显示）时启动：
      //   原图解码可能慢于动画（日志实证 ~400ms vs 动画 ~300ms），若动画先跑完，
      //   图片解码完成后以全屏突然出现；onComplete 保证图片可见时才开始飞入
      this.flyInStarted = false;
      this.previewImgLoaded = false;
      // ⭐ 强制 Swiper 跳转到点击的图片：bindContentCover content 不每次重建，
      //   Swiper .index() 仅初始化生效，后续打开需 show() 才能跳到正确页码
      setTimeout(() => { this.swiperController.changeIndex(this.previewIndex, false); }, 0);
    } else {
      // ⭐ 预览关闭：恢复状态栏
      this.setSystemBarsVisible(true);
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
    let ox = this.previewOriginX;
    let oy = this.previewOriginY;
    let ow = this.previewOriginW;
    let oh = this.previewOriginH;
    const thumbId = this.previewThumbIds.length > 0 ? this.previewThumbIds[this.previewIndex] : '';
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

  /** 通过组件 id 获取缩略图相对窗口矩形并转 vp；失败时置 0（退回中心缩放） */
  private captureThumbRect(thumbId: string): void {
    try {
      const info = this.getUIContext().getComponentUtils().getRectangleById(thumbId);
      this.previewOriginX = this.getUIContext().px2vp(info.windowOffset.x);
      this.previewOriginY = this.getUIContext().px2vp(info.windowOffset.y);
      this.previewOriginW = this.getUIContext().px2vp(info.size.width);
      this.previewOriginH = this.getUIContext().px2vp(info.size.height);
    } catch (e) {
      this.previewOriginX = 0;
      this.previewOriginY = 0;
      this.previewOriginW = 0;
      this.previewOriginH = 0;
    }
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
      logWarn(`[CommentContentRenderer] 设置状态栏失败: ${e}`);
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

  aboutToAppear(): void {
  }

  build() {
    Column() {
      if (this.content?.message) {
        this.renderMessageWithEmotes()
      }

      // 渲染评论配图
      if (this.content?.pictures && this.content.pictures.length > 0) {
        this.renderPictures()
      }
    }
    .width('100%')
    .alignItems(this.isCenter ? HorizontalAlign.Center : HorizontalAlign.Start)
    // 全屏图片预览（@StorageProp 持久化，旋转屏幕后自动恢复）
    // ⭐ 背景保持全屏静止（transition 仅 opacity 淡入淡出），图片缩放由 previewImgScale 单独驱动
    .bindContentCover($$this.showPreview, this.imagePreviewBuilder(), {
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
      Image(this.previewImageUrls[this.previewIndex])
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
  imagePreviewBuilder() {
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
      Swiper(this.swiperController) {
        ForEach(this.previewImageUrls, (url: string) => {
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
                  this.showPreview = false
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
      Image(this.previewImageUrls[this.previewIndex])
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
              this.showPreview = false
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
                    if (this.gestureDeltaX < 0 && this.previewIndex < this.previewImageUrls.length - 1) {
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
          Image(this.previewImageUrls[this.previewIndex])
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
      if (this.previewImageUrls.length > 1 && this.zoomScale <= 1.0) {
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
          Text(`/${this.previewImageUrls.length}`)
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

  @Builder
  renderMessageWithEmotes() {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, justifyContent: this.isCenter ? FlexAlign.Center : FlexAlign.Start }) {
      ForEach(this.parseMessageSegments(), (seg: MessageSegment, index: number) => {
        if (seg.isEmote && seg.url) {
          Image(seg.url)
            .width(20)
            .height(20)
            .margin({ left: 2, right: 2 })
            .objectFit(ImageFit.Contain)
        } else {
          Text(seg.text)
            .fontSize(this.fontSize)
            .fontColor(this.textColor)
            .textAlign(this.isCenter ? TextAlign.Center : TextAlign.Start)
            .maxLines(this.maxLines)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }, (seg: MessageSegment, index: number) => `seg_${index}_${seg.isEmote ? (seg.url ?? '') : seg.text}`)
    }
    .width('100%')
  }

  /** 是否为超长图（高/宽 > 16:9）：单图时用 3:4 竖版展示并显示「长图」标识 */
  private isTallPicture(pic: CommentPicture): boolean {
    return pic.img_width > 0 && pic.img_height > 0 && pic.img_height / pic.img_width > 16 / 9;
  }

  /** 原图宽高比（宽/高）：超长图按原比例撑高后，由外层容器裁剪出顶部区域 */
  private originalPictureRatio(pic: CommentPicture): number {
    if (pic.img_width > 0 && pic.img_height > 0) return pic.img_width / pic.img_height;
    return 1;
  }

  /** 单图宽高比：普通图按原比例完整显示；超长图（高/宽 > 16:9）用 3:4 竖版展示 */
  private singlePictureRatio(pic: CommentPicture): number {
    if (this.isTallPicture(pic)) return 3 / 4;
    if (pic.img_width > 0 && pic.img_height > 0) return pic.img_width / pic.img_height;
    return 16 / 9;
  }
  /**
   * ⭐ 单图宽度：启用适配框时取 `min(可用宽, 高度上限 × 原图比例)`（高度由 aspectRatio 自动跟着缩），
   * 未启用时维持原来的铺满整宽。
   */
  private singlePicWidth(pic: CommentPicture): number | string {
    if (this.picBoxW <= 0 || this.picBoxH <= 0) return '100%';
    const r = this.originalPictureRatio(pic);
    const raw = (pic.img_width > 0 && pic.img_height > 0) ? Math.max(0.05, r) : 16 / 9;
    return Math.min(this.picBoxW, this.picBoxH * raw);
  }


  /**
   * 单图（动态页同款）：普通图按原比例完整显示；超长图用 3:4 竖版 + 顶部对齐裁剪 + 底部「长图」胶囊
   * 顶部对齐实现：内层 Image 按原图比例撑高，外层 Stack 固定 3:4 并 clip + alignContent(Top) 裁剪出顶部
   */
  @Builder
  renderSinglePicture(pic: CommentPicture) {
    Stack() {
      // 缩略图（按原图比例撑高）
      Image(resizeImageUrl(pic.img_src, 512))
        .width('100%')
        .aspectRatio(this.originalPictureRatio(pic))
        .objectFit(ImageFit.Cover)
      // 超长图底部「长图」胶囊（点击穿透，不拦截图片点击）
      if (this.isTallPicture(pic)) {
        Column() {
          Blank()
          Text('长图')
            .fontSize(13)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Medium)
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
            .borderRadius(14)
            .backgroundColor('rgba(0, 0, 0, 0.45)')
            .margin({ bottom: 10 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    // ⭐ 播放页竖屏评论区：按适配框缩（见 picBoxW 注释）；未启用时仍是铺满整宽
    .width(this.singlePicWidth(pic))
    .aspectRatio(this.singlePictureRatio(pic))
    .alignContent(Alignment.Top)
    .margin({ top: 8 })
    .clip(true)
    .borderRadius(Math.round(this.cardBorderRadius * 0.4))
    // 点击图片全屏预览（一镜到底从该缩略图矩形飞入）
    .id(`comment_thumb_${this.thumbIdPrefix}_0`)
    .onClick(() => {
      const pics = this.content?.pictures ?? []
      this.previewImageUrls = pics.map(p => resizeImageUrl(p.img_src, 1600))
      // ⭐ 记录每张预览图对应的缩略图 id（与 previewImageUrls 对齐）：滑动切图后关闭时飞回当前图位置
      const thumbIds: string[] = []
      for (let i = 0; i < pics.length; i++) {
        thumbIds.push(`comment_thumb_${this.thumbIdPrefix}_${i}`)
      }
      this.previewThumbIds = thumbIds
      this.previewIndex = 0
      // ⭐ 一镜到底：记录点击的缩略图矩形（相对窗口 px → vp），全 0 时退化为中心缩放
      this.captureThumbRect(`comment_thumb_${this.thumbIdPrefix}_0`)
      this.showPreview = true
    })
  }

  @Builder
  renderPictures() {
    if ((this.content?.pictures?.length ?? 0) === 1) {
      this.renderSinglePicture((this.content?.pictures ?? [])[0])
    } else {
      Row() {
        ForEach(this.content?.pictures?.slice(0, 3) ?? [], (pic: CommentPicture, index: number) => {
          Stack() {
            // 缩略图
            Image(resizeImageUrl(pic.img_src, 512))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .borderRadius(Math.round(this.cardBorderRadius * 0.4))

            // 第3张 + 还有更多 → 灰色蒙层 + plus图标
            if (index === 2 && (this.content?.pictures?.length ?? 0) > 3) {
              Column() {
                Image($r('app.media.plus'))
                  .width(24)
                  .height(24)
                  .fillColor(Color.White)
                Text(`+${(this.content?.pictures?.length ?? 0) - 3}`)
                  .fontSize(13)
                  .fontColor(Color.White)
                  .fontWeight(FontWeight.Bold)
                  .margin({ top: 2 })
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .backgroundColor('rgba(0, 0, 0, 0.55)')
              .borderRadius(Math.round(this.cardBorderRadius * 0.4))
            }
          }
          .layoutWeight(1)
          .aspectRatio(1)
          .margin({
            right: index < 2 ? 6 : 0,
            top: 8
          })
          .clip(true)
          .borderRadius(Math.round(this.cardBorderRadius * 0.4))
          // 点击图片全屏预览（左右滑动切换；一镜到底从该缩略图矩形飞入）
          .id(`comment_thumb_${this.thumbIdPrefix}_${index}`)
          .onClick(() => {
            const pics = this.content?.pictures ?? []
            this.previewImageUrls = pics.map(p => resizeImageUrl(p.img_src, 1600))
            // ⭐ 记录每张预览图对应的缩略图 id（与 previewImageUrls 对齐）：滑动切图后关闭时飞回当前图位置
            const thumbIds: string[] = []
            for (let i = 0; i < pics.length; i++) {
              thumbIds.push(`comment_thumb_${this.thumbIdPrefix}_${i}`)
            }
            this.previewThumbIds = thumbIds
            this.previewIndex = index
            // ⭐ 一镜到底：记录点击的缩略图矩形（相对窗口 px → vp），全 0 时退化为中心缩放
            this.captureThumbRect(`comment_thumb_${this.thumbIdPrefix}_${index}`)
            this.showPreview = true
          })
        }, (pic: CommentPicture, index: number) => `thumb_${this.thumbIdPrefix}_${index}_${resizeImageUrl(pic.img_src, 512)}`)
      }
      .width('100%')
    }
  }

  /**
   * 解析消息文本，将表情文本分割为文字段和表情段
   */
  parseMessageSegments(): MessageSegment[] {
    const message = this.content?.message ?? '';
    const emote = this.content?.emote;

    if (!emote || Object.keys(emote).length === 0) {
      return [{ text: message, isEmote: false }];
    }

    // 构建正则匹配所有表情key（转义特殊字符）
    const emoteKeys = Object.keys(emote);
    const sortedKeys = emoteKeys.sort((a, b) => b.length - a.length); // 长key优先匹配
    const escapedKeys = sortedKeys.map(k => k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
    const pattern = escapedKeys.join('|');

    if (!pattern) {
      return [{ text: message, isEmote: false }];
    }

    const segments: MessageSegment[] = [];
    const regex = new RegExp(`(${pattern})`, 'g');
    let lastIndex = 0;
    let match: RegExpExecArray | null;

    while ((match = regex.exec(message)) !== null) {
      // 表情前的文本
      if (match.index > lastIndex) {
        segments.push({ text: message.substring(lastIndex, match.index), isEmote: false });
      }
      // 表情
      const emoteItem = emote[match[0]];
      segments.push({
        text: match[0],
        isEmote: true,
        url: emoteItem?.url
      });
      lastIndex = regex.lastIndex;
    }

    // 剩余文本
    if (lastIndex < message.length) {
      segments.push({ text: message.substring(lastIndex), isEmote: false });
    }

    return segments.length > 0 ? segments : [{ text: message, isEmote: false }];
  }
}
