import { promptAction, LengthMetrics, display, window, curves, mediaquery } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { hdsMaterial } from '@hms.hds.hdsMaterial';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { motion } from '@kit.MultimodalAwarenessKit';
import { VibrateUtils } from '../utils/VibrateUtils';
import { HdsMiniBarButton } from '../components/infra/HdsMiniBarButton';
import { logInfo, logWarn, logError } from '../utils/Logger';
import {
  getDynamicDetail, getDynComments, getDynCommentReplies, addDynComment, setDynCommentLike, setDynamicLike,
  getFollowStatus, modifyFollow, uploadCommentImage,
  SpaceDynamicItem, CommentItem, CommentLikeResult, AddCommentResult
} from '../api/BilibiliApi';
import { ObservableComment } from '../model/ObservableComment';
import { ObservableDynLike } from '../model/ObservableDynLike';
import { DynamicCardBody } from '../components/DynamicCardBody';
import { DynLikePill } from '../components/DynLikePill';
import { CommentItemComponent } from '../components/CommentItemComponent';
import { CommentInputBar, CommentImageDraft, CommentInputBarCtrl } from '../components/CommentInputBar';
import { FullImagePreview } from '../components/FullImagePreview';
import { fmtCount } from '../utils/NumberFormat';
import { fmtRelativeTime } from '../utils/TimeFormat';
import { resizeImageUrl } from '../utils/ImageUrl';
import { cardItemBg, cardItemBorder } from '../utils/CardStyle';
import { themeHexAlpha } from '../utils/ThemeColor';
import { MaterialUtil } from '../utils/MaterialUtil';

/**
 * HdsNavigation（MINI 模式）标题栏高度（vp）。
 *
 * ⚠️ 实测（2026-09-18，uitest dumpLayout）：`TitleBar` 与 `NavBarContent` 的 top **完全相同**
 *    （本机均为 y=117px，标题栏自身高 143px = 56vp）—— 即**框架不会为标题栏让位**，
 *    内容区是从标题栏底边那一行开始画的，第一屏会被毛玻璃标题栏盖住 56vp。
 *    ⇒ 用 HdsNavigation 承载内容的页面，必须自己给滚动内容留出这段高度；
 *      滚动后内容从标题栏底下滑过（毛玻璃）才是预期效果。
 */
const TITLE_BAR_H_VP: number = 56;

/**
 * ⚠️ 为什么留白还要再加一次"状态栏高度"（2026-09-18 实测，`uitest dumpLayout` 定量）：
 *   `HdsNavigation` 的内容区（`NavBarContent`）在 `expandSafeArea` 下**按窗口坐标布局**，
 *   而它的可见起点是 y=117px（状态栏下沿）⇒ 内容被整体**上移了正好一个状态栏高度**。
 *   实测：作者行 top=221px，而标题栏下沿在 260px ⇒ 首屏被毛玻璃标题栏压住；
 *   同时"打开时信息流突然向上位移"也是这一下（首帧按正确坐标画，随后被这个偏移推上去）。
 *   排查旁证：`Scroller.currentOffset()` 全程为 0（我加的偏移日志一次都没打），所以**不是滚动偏移**。
 *   ⇒ 留白 = 标题栏 56 + 状态栏高度（运行时取 avoidArea）+ 8 呼吸，两端才对得上。
 */
const TOP_EXTRA_GAP_VP: number = 32;

/**
 * 内容"应该"落在哪：**从屏幕顶算**的绝对 vp 数（不是相对状态栏）。
 *
 * ⚠️ 为什么用绝对坐标：`mainWindow.getWindowAvoidArea(TYPE_SYSTEM)` 在这个页面上实测拿到 0
 *    （日志：`目标=90.0vp` 而真实状态栏是 46.8vp）⇒ 任何"状态栏高度 + X"的公式都会偏。
 *    而 `getRectangleById().windowOffset.y` 本身就是**相对屏幕顶**的 px，两者同一坐标系，最稳。
 *
 * ⚠️ 关键实测（`uitest dumpLayout`，本机）：标题栏区域不止标题栏自己 ——
 *   `TitleBar [0,117][1320,260]`（高 56vp）之下还有一条 **`MaskBlur` 渐变模糊带，一直延伸到 342px**，
 *   即模糊带比标题栏还低 82px（≈33vp）。首屏内容只要顶边 < 342px，**卡片上沿和它的圆角就会被这条
 *   模糊带吃掉**（用户看到的就是"还是被渐变模糊遮挡 + 卡片圆角不对"）。
 *   ⇒ 内容顶必须 ≥ 状态栏底 + 90vp（56 标题栏 + 34 模糊带）。
 */
const CONTENT_TOP_TARGET_VP: number = 118;

/**
 * 内容渲染延迟（ms）：布局稳定后再显示正文。
 *
 * ⚠️ 为什么需要它：`HdsNavigation` 对内容区做的那次偏移（见上）**发生在首帧之后**，
 *    即使留白给对，用户仍能看到"打开瞬间内容往上跳一下"（首帧一个位置、下一帧另一个位置）。
 *    与其去猜它什么时候动，不如**先不画内容**：这一小段延迟里页面显示"加载中"，
 *    等布局落定后再一次性渲染 —— 用户感知是"页面出来 → 内容跟上"，不再有跳变。
 *    170ms 是实测够用的值（转场 600ms，肉眼看不出这段空档）。
 */
const CONTENT_SHOW_DELAY_MS: number = 170;

/** 二级回复每页条数。
 *  ⚠️ 必须是 **20**：实测请求 `ps=30` 服务端只返回 20（`[getCommentReplies] 返回20条`），
 *     若按 30 推算页码会算错 —— `已加载20 / 30 = 0` ⇒ 又去请求第 1 页，去重后零新增，
 *     用户看到的就是"点了展开更多回复没反应"。 */
const REPLY_PAGE_SIZE: number = 20;

/**
 * 滚动偏移超过该值（vp）才显示"回到顶部"按钮（与搜索页 / 观看历史页同一阈值，三页观感一致）。
 * ⚠️ 回调里只在**值真的变了**时才写 `showBackToTop`：onWillScroll 每帧都会调，
 *    无条件写状态会让整页每帧都标记脏（本页是长列表 + 毛玻璃标题栏，白白丢帧）。
 */
const BACK_TO_TOP_THRESHOLD_VP: number = 300;

/**
 * 动态详情页
 *
 * 版式：
 *   内容卡（作者行 + 关注 + 正文 + 图片 + 媒体条 + 统计行）
 *   → 评论头（数量 + 排序切换）→ 评论列表（复用播放页的 CommentItemComponent）
 *   → 加载更多 → 底部悬浮输入胶囊（无遮罩、不自动弹键盘）
 *
 * ⚠️ 卡片外观一律走 components/DynamicCardBody（与动态页同一份），不要在本页另写一套；
 *
 * 数据：`getDynamicDetail` + `getDynComments`；
 *  ⚠️ 评论区定位必须用 item 的 `commentType`/`commentIdStr`（视频类动态的评论挂在稿件上，
 *     直接用 17 + 动态 id 会 -404）；列表页已拿到 item 时会通过路由 preload 先渲染，避免白屏。
 */
@Entry
@Component({ freezeWhenInactive: true })
struct DynamicDetailPage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('biliCookie') biliCookie: string = '';
  @StorageLink('wallpaper') wallpaper: string = 'default';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 15;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = true;

  /** 状态栏高度（vp，运行时取 avoidArea）：顶部留白要把它补回来，见 TOP_EXTRA_GAP_VP 注释 */
  @State statusBarVp_: number = 0;
  /** 布局稳定后才渲染正文（消除"打开时内容跳一下"，见 CONTENT_SHOW_DELAY_MS） */
  @State contentReady_: boolean = false;
  /**
   * 内容是否已淡入。
   * 顺序：`contentReady_`（渲染但**透明**）→ 量坐标并修正顶部留白 → 再淡入。
   * 这样"位置校正"发生在不可见时，用户看到的是"内容在原位淡入"，而不是"先出现在一个位置再跳一下"。
   */
  @State contentShown_: boolean = false;
  /**
   * 顶部留白（vp）。**由实测坐标自适应修正**，不靠公式猜：
   * 框架在 `HdsNavigation` 内容区里会把内容整体上移约一个状态栏高度（实测恒定 114px），
   * 且这个量在不同设备/版本上未必一致 ⇒ 渲染后用 `getRectangleById` 量出内容卡实际位置，
   * 不够就往里加（见 correctTopGap）。
   */
  @State topGap_: number = TITLE_BAR_H_VP + TOP_EXTRA_GAP_VP;
  @State item: SpaceDynamicItem | null = null;
  @State loading: boolean = true;
  @State err: string = '';

  // ── 评论 ──
  @State comments: ObservableComment[] = [];
  @State commentsCursor: number = 0;
  @State commentsHasMore: boolean = false;
  @State commentsLoading: boolean = false;
  @State commentsLoaded: boolean = false;
  /** 排序：3=按热度(默认) / 2=按时间 —— 对应评论接口的 mode */
  @State commentsSort: number = 3;
  /** 二级回复版本：气泡组件靠 @Prop 变化重算"展开 N 条"文案 */
  @State repliesVersion: number = 0;

  // ── 回复输入 ──
  /** 底部输入区是否展开（收起时只显示悬浮胶囊；展开也**不自动聚焦**，见 commentEntryInner 注释） */
  @State replyRoot: number = 0;
  @State replyParent: number = 0;
  @State replyTargetName: string = '';

  // ── 关注 ──
  @State following: boolean = false;
  @State followLoaded: boolean = false;
  private followBusy_: boolean = false;

  // ── 图片预览 ──
  @State @Watch('onPreviewToggle') showPreview: boolean = false;
  @State previewUrls: string[] = [];
  @State previewIndex: number = 0;
  @State previewOriginX: number = 0;
  @State previewOriginY: number = 0;
  @State previewOriginW: number = 0;
  @State previewOriginH: number = 0;

  /**
   * ⭐ 点赞状态必须是**状态变量**才能传给子组件的 @ObjectLink（编译器会拒绝普通私有字段）；
   *    改字段只通知绑定它的组件，页面其余部分不重建。
   */
  @State likeState_: ObservableDynLike = new ObservableDynLike(false, 0);
  private liking_: boolean = false;
  private dynId_: string = '';
  private scroller: Scroller = new Scroller();
  private screenW: number = 0;
  private screenH: number = 0;

  // ══════ 评论入口：常驻半模态 sheet（外层沉浸光感） ══════
  /**
   * ⭐ 入口 sheet 显隐：**常驻显示**。
   *    页面被盖住（onPageHide）/ 图片预览全屏时收掉，恢复时再打开。
   */
  @State entrySheetOn: boolean = true;
  /**
   * ⭐ 是否把入口搬进半模态 sheet：只有真材质设备（API 26+）才走这条路。
   *    老机（6.1 / API 24）保持页内渲染 —— `SheetOptions.systemMaterial` 是 26.0.0 新字段，
   *    老系统解析到会打挂整棵子树（见红线）。老机走 else 分支时**不会解析这个字段**。
   */
  private entryUseSheet: boolean = MaterialUtil.available();
  /**
   * ⚠️ 返回语义防重入时间窗：官方把"我们自己发起的 `router.back()`"也会当成 `PRESS_BACK`
   *    打回同一个回调 ⇒ 不做守卫会连退两级（本页 → 上一页 → 更上一页）。
   */
  private ovBackTs_: number = 0;
  /**
   * ⭐ 评论输入栏控制器：表情面板展开时，侧滑返回/返回键应**先收起面板**而不是退页。
   *    （面板是否展开的真值在 CommentInputBar 内部，故用控制器问它，见 CommentInputBarCtrl）
   */
  private entryEmoteCtrl: CommentInputBarCtrl = new CommentInputBarCtrl();

  // ══════ 回到顶部悬浮按钮（形态与交互复刻搜索页，位置独立持久化） ══════
  @StorageLink('smartGripEnabled') smartGripEnabled: boolean = true;
  @StorageLink('floatBtnFollowTheme') floatBtnFollowTheme: boolean = true;
  @StorageLink('da') da: boolean = false;
  /** 按钮距屏幕底的距离（vp）—— 拖动即时改它，松手后落盘 */
  @StorageLink('dynDetailFloatBtnY') dynDetailFloatBtnY: number = 120;
  /** 单按钮形态下吸附在哪一侧：'left' / 'right' */
  @StorageLink('dynDetailFloatBtnSide') dynDetailFloatBtnSide: string = 'right';
  /** 滚动是否超过阈值（决定按钮显示；见 BACK_TO_TOP_THRESHOLD_VP） */
  @State showBackToTop: boolean = false;
  /** 点击时"缩一下再弹回"的缩放系数 */
  @State private btnScale: number = 1;
  /** 拖动中（此时要关掉 position 上的过渡动画，否则按钮追不上手指） */
  @State private isDragging: boolean = false;
  @State private dragStartY: number = 0;
  @State private dragOffsetX: number = 0;
  /** 可拖范围的上下限：按钮距顶至少留 80vp（横屏矮，上限要跟着变小） */
  @State private maxFloatBtnBottom: number = 592;
  /** 智感握姿：1=左手 2=右手 16=未知（motion.HoldingHandStatus） */
  @State private hand: number = 16;
  @State private smartGripLeft: number = -1;
  @State private smartGripRight: number = 32;
  @State isLandscape: boolean = false;
  private gripSafeAreaLeft: number = 24;
  private gripSafeAreaRight: number = 24;
  private gripListenersInitialized: boolean = false;
  /** 握持回调的引用：`motion.off` 只摘自己这一个，不用裸 off（那会连带删掉其它页面的监听） */
  private gripCallback_: ((data: number) => void) | null = null;
  private landscapeListener: mediaquery.MediaQueryListener | null = null;
  private touchStartWX: number = 0;
  private touchStartWY: number = 0;
  private touchMoved: boolean = false;

  aboutToAppear(): void {
    try {
      const d = display.getDefaultDisplaySync();
      this.screenW = this.getUIContext().px2vp(d.width);
      this.screenH = this.getUIContext().px2vp(d.height);
    } catch (_e) {
      this.screenW = 360;
      this.screenH = 780;
    }
    // 状态栏高度（px → vp）：NavBarContent 会少算这一段，留白里补回来
    try {
      const mw: window.Window | undefined = AppStorage.get<window.Window>('mainWindow');
      if (mw) {
        const area: window.AvoidArea = mw.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        this.statusBarVp_ = this.getUIContext().px2vp(area.topRect.height);
      }
    } catch (_e) {
      this.statusBarVp_ = 0;
    }
    this.topGap_ = TITLE_BAR_H_VP + this.statusBarVp_ + TOP_EXTRA_GAP_VP;
    // 回到顶部按钮：智感握姿（决定按钮贴哪一侧）+ 横竖屏（决定按钮形态与可拖范围）
    this.initSmartGrip();
    this.initOrientation();
    // 入口 sheet 盖在页面之上 ⇒ 回顶按钮下限抬高；历史落盘的位置可能低于新下限，这里夹一次
    this.dynDetailFloatBtnY = Math.max(this.floatBtnMinBottom(),
      Math.min(this.maxFloatBtnBottom, this.dynDetailFloatBtnY));
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (!params) {
      this.err = '参数缺失';
      this.loading = false;
      return;
    }
    const idParam = params['dynIdStr'];
    this.dynId_ = typeof idParam === 'string' ? idParam : '';
    const preload = params['preload'] as SpaceDynamicItem | undefined;
    if (preload) {
      this.applyItem(preload);
      this.loading = false;
      this.loadFollowStatus();
    }
    if (!this.dynId_) {
      this.err = '动态 id 缺失';
      this.loading = false;
      return;
    }
    this.loadDetail();
    this.loadComments(true);
    // 布局稳定后再渲染正文（见 CONTENT_SHOW_DELAY_MS 注释）：
    //   → 先透明渲染，量出实际位置并校正留白，最后才淡入。校正过程用户看不到。
    setTimeout(() => {
      this.contentReady_ = true;
      setTimeout(() => {
        this.correctTopGap('首次');
        setTimeout(() => {
          this.correctTopGap('复校');
          animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
            this.contentShown_ = true;
          });
        }, 130);
      }, 80);
    }, CONTENT_SHOW_DELAY_MS);
  }


  aboutToDisappear(): void {
    // ⭐ 精确摘掉自己注册的握持监听：`motion.off(type, callback)` 只删这一个回调。
    //    ⚠️ 不要用不带 callback 的 `motion.off(type)` —— 那会把**其它页面**注册的监听一起删掉，
    //       而它们的 `gripListenersInitialized` 已是 true，不会再补注册 ⇒ 那些页面的智感握姿静默失效。
    if (this.gripCallback_) {
      try { motion.off('holdingHandChanged', this.gripCallback_); } catch (_e) { }
      this.gripCallback_ = null;
    }
    if (this.landscapeListener) {
      this.landscapeListener.off('change');
      this.landscapeListener = null;
    }
  }

  // ═══════════════════════════════════════════
  // 评论入口常驻半模态 sheet（外层沉浸光感）
  // ═══════════════════════════════════════════

  /**
   * ⭐⭐ 入口承载 = **常驻半模态 sheet**（与「回复 / 发弹幕」同一条材质通道）。
   *
   * 为什么必须是 sheet 而不是 popup：半模态自带 `keyboardAvoidMode`（API 13 起）
   * **会跟着键盘抬起**；popup（浮层）在 Overlay 层、没有页面级键盘避让
   * ⇒ 实测点输入框时会被键盘盖住。sheet 是唯一能同时满足
   * **真材质 + 跟随键盘 + 贴底 + 顶部圆角/底部贴边**的通道。
   *
   * ⚠️ 半模态的默认行为每一条都和"常驻"冲突，必须逐条关掉：
   *    · 默认半透明蒙层（页面变暗）      → `maskColor: Color.Transparent`
   *    · 默认点面板外就收起              → `enableOutsideInteractive: true`（页面照常可点可滚）
   *    · 默认顶部拖拽条 + 可下滑收起      → `dragBar: false`；下滑/返回一律在 `onWillDismiss` 里拦
   *    · 默认按返回键关闭                → `onWillDismiss` 分级处理（见下），带 800ms 防重入
   *    · 挂在**窗口 Overlay 层**（页面被盖住时会飘到下一页）→ `onPageHide/onPageShow` 收放
   *
   * ⭐ **返回键/侧滑返回的语义是分级的**（对齐系统"先关临时层、再退页"的直觉）：
   *    ① 表情面板展开 → **只收面板**，不退页（`entryEmoteCtrl.collapseEmote()` 返回 true 时吞掉本次返回）；
   *    ② 面板已收起 → 把返回转交页面（`router.back()`），并由 `entrySheetOn` 收起常驻 sheet。
   *    ⚠️ 官方文档：`onWillDismiss` 注册后弹层**不会自动关**，要关必须自己调 `action.dismiss()`；
   *       侧拉关闭含「侧滑（左右滑）/ 三键 back / ESC」，都会以 `DismissReason.PRESS_BACK` 打进来。
   *
   * ⚠️ `systemMaterial` 是 26.0.0 字段，必须在**能力探测通过后动态补挂**到 options 上，
   *    不能写死在字面量里（老机解析到会打挂整棵子树）。
   */
  private entrySheetOpts(): SheetOptions {
    const o: SheetOptions = {
      // 高度随内容长高：表情面板展开时 sheet 跟着长（与发弹幕同一机制）
      height: SheetSize.FIT_CONTENT,
      // 材质层在 backgroundColor 之下 ⇒ 不透明底会把玻璃整层盖住（硬要求①）
      backgroundColor: Color.Transparent,
      dragBar: false,
      showClose: false,
      maskColor: Color.Transparent,
      enableOutsideInteractive: true,
      keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL
    } as SheetOptions;
    if (this.entryUseSheet) {
      o.systemMaterial = MaterialUtil.sheetMaterial();
    }
    o.onWillDismiss = (a: DismissSheetAction): void => {
      if (a.reason === DismissReason.PRESS_BACK) {
        // ⭐ ① 表情面板展开 ⇒ 只收面板，吞掉本次返回（不退页）
        if (this.entryEmoteCtrl.collapseEmote()) { return; }
        // ⭐ ② 面板已收起 ⇒ 把返回转交页面
        const now = Date.now();
        if (now - this.ovBackTs_ < 800) { return; }
        this.ovBackTs_ = now;
        this.entrySheetOn = false;
        try {
          this.getUIContext().getRouter().back();
        } catch (_e) { }
      }
      // ⛔ 其它原因（下滑 / 点外部）**不调 `a.dismiss()`** ⇒ 面板保持常驻、不关闭
    };
    return o;
  }

  /**
   * ⚠️ sheet 画在**窗口 Overlay 层**（在页面所有内容之上）⇒ 页面被盖住时必须主动收掉，
   *    否则会浮在下一个页面上。页面重新可见时再恢复。
   */
  onPageHide(): void {
    if (this.entryUseSheet && this.entrySheetOn) {
      this.entrySheetOn = false;
    }
  }

  onPageShow(): void {
    if (this.entryUseSheet && !this.entrySheetOn) {
      this.entrySheetOn = true;
    }
  }

  /**
   * ⭐ 返回键/右滑返回：**老设备兜底**。
   *    新设备入口跑在常驻 sheet 里，返回事件由 sheet 的 `onWillDismiss` 消费
   *    （此时本回调根本不会触发）；老设备是页内渲染，没有弹层拦返回 ⇒ 在这里做同一件事：
   *    表情面板展开时先收面板、不退页。
   */
  onBackPress(): boolean {
    return this.entryEmoteCtrl.collapseEmote();
  }

  /**
   * ⚠️ 图片预览是全屏层，而常驻 sheet 在 Overlay 层**之上** ⇒ 预览期间会把输入条压在图片上。
   *    所以预览打开时收掉、退出时恢复。
   */
  onPreviewToggle(): void {
    if (!this.entryUseSheet) { return; }
    this.entrySheetOn = !this.showPreview;
  }

  /**
   * 悬浮回顶按钮的"距底下限"：入口 sheet 盖在页面之上（按钮**盖不过它**）⇒
   * 按钮不得被拖进入口区域，否则会被整块遮住、既看不见也点不到。
   */
  private floatBtnMinBottom(): number {
    return this.entryUseSheet ? 88 : 20;
  }

  // ═══════════════════════════════════════════
  // 回到顶部悬浮按钮（复刻搜索页：沉浸光感 + 智感握姿 + 拖动改位置 + 落盘记忆）
  // ═══════════════════════════════════════════

  /** 统一触觉反馈（15ms 短震，受"触感反馈"总开关控制，与搜索页一致） */
  private triggerHaptic(): void {
    VibrateUtils.vibrateTime(15);
  }

  /**
   * 智感握姿：左手握持 → 按钮贴左边缘，右手/未知 → 贴右边缘。
   * ⚠️ 两个 side 的值**任何时候都要有效**：position 从"有值→无值"会触发一次平移动画
   *    （表现为按钮从屏幕中间横着飞过去），所以这里两边一起算。
   */
  private recalcSmartGripPosition(): void {
    this.smartGripLeft = this.gripSafeAreaLeft + 16;
    this.smartGripRight = this.gripSafeAreaRight + 8;
  }

  /**
   * 注册智感握姿监听（只能注册一次；失败静默 —— 部分机型/模拟器不支持该能力）。
   * ⚠️ 回调里必须判断"值真的变了"，否则握持状态每次上报都会写 @State（整页重排）。
   */
  private initSmartGrip(): void {
    if (this.gripListenersInitialized) return;
    try {
      const cb = (data: number): void => {
        if (data !== this.hand && (data === 1 || data === 2)) {
          this.hand = data;
          this.recalcSmartGripPosition();
        }
      };
      this.gripCallback_ = cb;
      motion.on('holdingHandChanged', cb);
      this.gripListenersInitialized = true;
    } catch (e) {
      logWarn('[DynamicDetail] 初始化智感握姿失败:', e);
    }
  }

  /**
   * 横竖屏监听：竖屏 + 智感握姿开 ⇒ 左右两个按钮；否则（关/横屏）⇒ 单个可换边按钮。
   * 同时维护可拖范围上限（横屏窗口矮，沿用搜索页的 392/592）。
   */
  private initOrientation(): void {
    try {
      const mq = this.getUIContext().getMediaQuery();
      this.landscapeListener = mq.matchMediaSync('(orientation: landscape)');
      this.isLandscape = this.landscapeListener.matches;
      this.maxFloatBtnBottom = this.isLandscape ? 392 : 592;
      this.landscapeListener.on('change', (result: mediaquery.MediaQueryResult) => {
        this.isLandscape = result.matches;
        this.maxFloatBtnBottom = result.matches ? 392 : 592;
      });
    } catch (e) {
      logWarn('[DynamicDetail] 初始化方向监听失败:', e);
    }
  }

  /** 点击回到顶部：触觉反馈 + 缩一下再弹回（与搜索页同一套曲线）+ 列表回顶 */
  private handleBackToTopClick(): void {
    this.triggerHaptic();
    animateTo({ duration: 100, curve: Curve.FastOutLinearIn }, () => {
      this.btnScale = 0.8;
    });
    setTimeout(() => {
      animateTo({ duration: 300, curve: curves.springMotion(0.4, 0.8) }, () => {
        this.btnScale = 1;
      });
    }, 100);
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300, curve: Curve.EaseOut } });
  }

  /**
   * 悬浮按钮的触摸统一入口：**拖动改位置** 与 **点击回顶** 靠"有没有移动过"区分。
   * @param snapSide 是否允许左右吸附换边（只有"单按钮"形态需要；
   *                 智感握姿的左右两个按钮各自钉死在一边，只允许上下拖）
   *
   * ⚠️ 拖动中只改 position 的数值、并把 `.animation` 关掉（见 isDragging），否则动画会拖慢跟手；
   *    `bottom` 是"距屏幕底"⇒ 手指上移（windowY 变小）时要**增大** bottom，故取 −offY。
   */
  private handleFloatBtnTouch(event: TouchEvent, snapSide: boolean): void {
    if (event.type === TouchType.Down) {
      this.touchStartWX = event.touches[0].windowX;
      this.touchStartWY = event.touches[0].windowY;
      this.dragStartY = this.dynDetailFloatBtnY;
      this.dragOffsetX = 0;
      this.touchMoved = false;
      this.isDragging = true;
    } else if (event.type === TouchType.Move) {
      const offYpx: number = event.touches[0].windowY - this.touchStartWY;
      const offXpx: number = event.touches[0].windowX - this.touchStartWX;
      if (Math.abs(offYpx) > 5 || (snapSide && Math.abs(offXpx) > 5)) {
        this.touchMoved = true;
      }
      const offYVp: number = Math.round(this.getUIContext().px2vp(offYpx));
      this.dynDetailFloatBtnY = Math.max(this.floatBtnMinBottom(),
        Math.min(this.maxFloatBtnBottom, this.dragStartY - offYVp));
      if (snapSide) {
        this.dragOffsetX = Math.round(this.getUIContext().px2vp(offXpx));
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.isDragging = false;
      if (this.touchMoved) {
        // 拖过 = 改位置（不触发回顶）
        if (snapSide) {
          const totalOffsetX: number = this.dragOffsetX;
          let newSide: string = this.dynDetailFloatBtnSide;
          let sideChanged: boolean = false;
          if (totalOffsetX < -60) {
            newSide = 'left';
            sideChanged = true;
          } else if (totalOffsetX > 60) {
            newSide = 'right';
            sideChanged = true;
          }
          animateTo({ duration: 300, curve: Curve.Ease }, () => {
            this.dragOffsetX = 0;
            if (sideChanged) {
              this.dynDetailFloatBtnSide = newSide;
            }
          });
        }
        // @StorageLink 已经是双向同步，这里只需落盘（下次冷启动由 Index 读回 AppStorage）
        this.saveFloatBtnPrefs();
      } else {
        this.dragOffsetX = 0;
        if (event.type === TouchType.Up) {
          this.handleBackToTopClick();
        }
      }
    }
  }

  /** 把按钮位置落盘（与搜索页/历史页共用同一个 preferences 文件、各自的 key） */
  private async saveFloatBtnPrefs(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('dynDetailFloatBtnSide', this.dynDetailFloatBtnSide);
      await pref.put('dynDetailFloatBtnY', this.dynDetailFloatBtnY);
      await pref.flush();
    } catch (e) {
      logError('保存动态详情页悬浮按钮位置失败', e);
    }
  }

  // ────────────── 数据 ──────────────

  /**
   * 用实测坐标把内容顶推到"标题栏 + 渐变模糊带"之下。
   * ⚠️ 为什么要自适应而不是写死公式：框架对 `HdsNavigation` 内容区的那次上移（实测 114px ≈ 状态栏高度）
   *    是**未文档化的行为**，写死数字在别的设备/版本上就会偏；这里量出实际位置再补差额，一次到位。
   */
  private correctTopGap(tag: string): void {
    try {
      const info = this.getUIContext().getComponentUtils().getRectangleById('dd_card');
      const cardTop: number = this.getUIContext().px2vp(info.windowOffset.y);
      const want: number = CONTENT_TOP_TARGET_VP;
      const delta: number = want - cardTop;
      if (delta > 2) {
        this.topGap_ = this.topGap_ + delta + 6;
        logInfo(`[DynamicDetail] ${tag} 内容顶=${cardTop.toFixed(1)}vp 目标=${want.toFixed(1)}vp → 留白调到 ${this.topGap_.toFixed(1)}vp`);
      }
    } catch (_e) {
      // 取不到矩形就保持当前留白
    }
  }

  /** 落地一条动态：同步点赞状态（@ObjectLink 需要长期同一个实例，所以只改字段不换对象） */
  private applyItem(it: SpaceDynamicItem): void {
    this.item = it;
    this.likeState_.liked = it.liked;
    this.likeState_.count = it.likeCount;

  }

  private async loadDetail(): Promise<void> {
    const it: SpaceDynamicItem | null = await getDynamicDetail(this.dynId_);
    if (it) {
      this.applyItem(it);
      this.err = '';
      this.loadFollowStatus();
    } else if (!this.item) {
      this.err = '加载失败，请返回重试';
    }
    this.loading = false;
  }

  private async loadFollowStatus(): Promise<void> {
    const it = this.item;
    if (!it || it.authorMid <= 0 || this.followLoaded) return;
    try {
      this.following = await getFollowStatus(it.authorMid);
      this.followLoaded = true;
    } catch (e) {
      logWarn(`[DynamicDetail] 关注状态查询失败: ${e}`);
    }
  }

  // ────────────── 评论 ──────────────

  private async loadComments(reset: boolean): Promise<void> {
    if (this.commentsLoading) return;
    if (!reset && !this.commentsHasMore) return;
    const it = this.item;
    const oid: string = it ? it.commentIdStr : this.dynId_;
    const ctype: number = it ? it.commentType : 17;
    if (!oid) return;
    this.commentsLoading = true;
    try {
      const cursor: number = reset ? 0 : this.commentsCursor;
      const res = await getDynComments(oid, cursor, 20, this.commentsSort, ctype);
      if (!res) {
        if (reset) this.commentsLoaded = true;
        return;
      }
      const list: ObservableComment[] = [];
      for (const c of res.comments) {
        list.push(ObservableComment.from(c));
      }
      this.comments = reset ? list : [...this.comments, ...list];
      this.commentsCursor = res.nextCursor;
      this.commentsHasMore = !res.isEnd && res.nextCursor > 0;
      this.commentsLoaded = true;
      this.repliesVersion++;
      logInfo(`[DynamicDetail] 评论: ${list.length} 条, hasMore=${this.commentsHasMore}, sort=${this.commentsSort}`);
    } catch (e) {
      logError(`[DynamicDetail] loadComments 异常: ${e}`);
    } finally {
      this.commentsLoading = false;
    }
  }

  /** 切换排序：重置列表重新拉（光标分页不能混用两种排序） */
  private switchSort(mode: number): void {
    if (this.commentsSort === mode) return;
    this.commentsSort = mode;
    this.comments = [];
    this.commentsCursor = 0;
    this.commentsHasMore = false;
    this.commentsLoaded = false;
    this.loadComments(true);
  }

  /**
   * 判断二级回复是否还有下一页（三条终止条件，任一命中即"没有了"）：
   *  1. **本页不满**（received < 页大小）⇒ 到底了（分页通用规则）；
   *  2. **本页没有任何新增**（added ≤ 0）⇒ 到底了
   *     ⚠️ 服务端偶尔会返回与前面重复的条目（置顶/热门重合），去重后可能零新增，
   *        只按"满页"判断就会让按钮赖着不走（用户："怎么点击无法展开了？"——其实早加载完了）；
   *  3. **已达总数**（rcount > 0 且已加载 ≥ rcount）⇒ 到底了。
   * ⚠️ 第 3 条只在 rcount 可信时生效：B 站的 rcount 有时偏大（含已删/折叠），
   *    所以不能反过来"只信 rcount"，要靠下面两个条件兜住。
   */
  private hasMoreReplies(c: ObservableComment, received: number, added: number): boolean {
    if (received < REPLY_PAGE_SIZE) return false;
    if (added <= 0) return false;
    if (c.rcount > 0 && c.replies.length >= c.rcount) return false;
    return true;
  }

  /**
   * 展开/收起二级回复。
   *
   * ⚠️ 展开时**必须总是请求第一页**，不能因为"评论列表自带了几条回复"就直接展开 ——
   *    列表接口只带前 2 条，直接展开的话用户只看到 2 条，而且 `rcount(7) > 已加载(2)` 会让
   *    "展开更多回复"一直挂着（用户反馈："展开后还是会显示展开更多回复，和视频页评论区不一样"）。
   *    视频页评论区就是"点开即拉第一页"，这里对齐它。
   */
  private async toggleReplies(c: ObservableComment): Promise<void> {
    if (c.expanded) {
      c.expanded = false;
      this.repliesVersion++;
      return;
    }
    c.loadingReplies = true;
    this.repliesVersion++;
    try {
      const it = this.item;
      const oid: string = it ? it.commentIdStr : this.dynId_;
      const ctype: number = it ? it.commentType : 17;
      const replies: CommentItem[] | null = await getDynCommentReplies(oid, c.rpid, 1, REPLY_PAGE_SIZE, ctype);
      const got: number = replies ? replies.length : 0;
      const before: number = c.replies.length;
      if (got > 0) {
        // 以服务端第一页为准（列表自带的那几条会被去重合并进来）
        c.updateReplies(replies ?? []);
      }
      const added: number = c.replies.length - before;
      logInfo(`[DynamicDetail] 展开回复: root=${c.rpid} 返回=${got} 新增=${added} 已加载=${c.replies.length} 总数=${c.rcount}`);
      c.replyPage = 1;
      c.hasMoreReplies = this.hasMoreReplies(c, got, added);
      c.expanded = true;
    } catch (e) {
      logWarn(`[DynamicDetail] toggleReplies 异常: ${e}`);
      c.expanded = true;   // 接口异常也让用户看到列表自带的那几条，不要"点了没反应"
    } finally {
      c.loadingReplies = false;
      this.repliesVersion++;
    }
  }

  /**
   * 加载更多二级回复（点开评论展开区里的「展开更多回复」）
   * ⚠️ 本页原先**没有传 onLoadMoreReplies** ⇒ 该按钮点了完全没反应（2026-09-18 用户报"展开更多回复无法展开"）。
   *    展开逻辑与第一页加载同源：都用 item 的 commentType/commentIdStr。
   */
  private async loadMoreReplies(c: ObservableComment): Promise<void> {
    if (c.loadingReplies) return;
    c.loadingReplies = true;
    this.repliesVersion++;
    try {
      const it = this.item;
      const oid: string = it ? it.commentIdStr : this.dynId_;
      const ctype: number = it ? it.commentType : 17;
      // 页码由 `replyPage` 推进：展开时（toggleReplies）总是先请求第 1 页并把 replyPage 置 1，
      // 所以这里 +1 就是真正的"下一页"。
      // ⚠️ 别再按"已加载条数 / 页大小"算：接口的页大小可能被服务端改写（实测 ps=30 只回 20），
      //    一算错就会去重请求同一页 ⇒ 现象是"点了没反应"（2026-09-18 连续踩两次）。
      const nextPage: number = (c.replyPage > 0 ? c.replyPage : 0) + 1;
      logInfo(`[DynamicDetail] 展开更多回复: oid=${oid} type=${ctype} root=${c.rpid} pn=${nextPage} 已加载=${c.replies.length} 总数=${c.rcount}`);
      const more: CommentItem[] | null = await getDynCommentReplies(oid, c.rpid, nextPage, REPLY_PAGE_SIZE, ctype);
      const list: CommentItem[] = more ?? [];
      const before: number = c.replies.length;
      if (list.length > 0) {
        // updateReplies 是"新 + 旧 去重合并"，正好用来追加下一页
        c.updateReplies(list);
        c.replyPage = nextPage;
      }
      const added: number = c.replies.length - before;
      logInfo(`[DynamicDetail] 加载下一页回复: pn=${nextPage} 返回=${list.length} 新增=${added} 已加载=${c.replies.length} 总数=${c.rcount}`);
      c.hasMoreReplies = this.hasMoreReplies(c, list.length, added);
    } catch (e) {
      logWarn(`[DynamicDetail] loadMoreReplies 异常: ${e}`);
    } finally {
      c.loadingReplies = false;
      this.repliesVersion++;
    }
  }

  /** 评论点赞（乐观更新 + 失败回滚） */
  private async likeComment(c: ObservableComment): Promise<void> {
    if (!this.hasLogin()) {
      promptAction.showToast({ message: '登录后才能点赞', duration: 1500 });
      this.getUIContext().getRouter().pushUrl({ url: 'pages/QrCodeLoginPage' }).catch(() => {});
      return;
    }
    const it = this.item;
    const oid: string = it ? it.commentIdStr : this.dynId_;
    const ctype: number = it ? it.commentType : 17;
    const target: boolean = c.action !== 1;
    const prevAction: number = c.action;
    const prevLike: number = c.like;
    c.action = target ? 1 : 0;
    c.like = Math.max(0, prevLike + (target ? 1 : -1));
    this.repliesVersion++;
    try {
      const res: CommentLikeResult = await setDynCommentLike(oid, c.rpid, target, ctype);
      if (!res.ok) {
        c.action = prevAction;
        c.like = prevLike;
        this.repliesVersion++;
        promptAction.showToast({ message: res.message, duration: 1800 });
      }
    } catch (e) {
      c.action = prevAction;
      c.like = prevLike;
      this.repliesVersion++;
      logWarn(`[DynamicDetail] likeComment 异常: ${e}`);
    }
  }

  /** 设置输入条目标（点击某条评论的「回复」） */
  private setReplyTarget(c: ObservableComment, rootRpid: number): void {
    this.replyRoot = rootRpid;
    this.replyParent = c.rpid;
    this.replyTargetName = c.member?.uname ?? '';
  }

  /** 发评论 / 回复（输入条回调）；返回 true 表示成功（输入条自行清空） */
  private async submitComment(content: string, pictures: CommentImageDraft[]): Promise<boolean> {
    if (!this.hasLogin()) {
      promptAction.showToast({ message: '登录后才能发评论', duration: 1500 });
      this.getUIContext().getRouter().pushUrl({ url: 'pages/QrCodeLoginPage' }).catch(() => {});
      return false;
    }
    const it = this.item;
    const oid: string = it ? it.commentIdStr : this.dynId_;
    const ctype: number = it ? it.commentType : 17;
    const text: string = content.trim();
    if (!text && pictures.length === 0) {
      promptAction.showToast({ message: '说点什么吧', duration: 1500 });
      return false;
    }
    // 图片：与视频评论一致，先上传换成 pictures json（沿用现有上传接口）
    let picturesJson: string | undefined = undefined;
    if (pictures.length > 0) {
      try {
        picturesJson = await this.uploadPictures(pictures);
        if (!picturesJson) {
          promptAction.showToast({ message: '图片上传失败', duration: 1800 });
          return false;
        }
      } catch (e) {
        logWarn(`[DynamicDetail] 图片上传异常: ${e}`);
        promptAction.showToast({ message: '图片上传失败', duration: 1800 });
        return false;
      }
    }
    try {
      const res: AddCommentResult = await addDynComment(oid, text, this.replyRoot, this.replyParent, picturesJson, ctype);
      if (!res.ok) {
        promptAction.showToast({ message: res.message || '发送失败，请稍后再试', duration: 2000 });
        return false;
      }
      promptAction.showToast({ message: this.replyRoot > 0 ? '回复成功' : '评论成功' });
      this.replyRoot = 0;
      this.replyParent = 0;
      this.replyTargetName = '';
      // 重新拉第一页（保证新评论的 rpid/楼层与服务端一致）
      this.comments = [];
      this.commentsCursor = 0;
      this.commentsHasMore = false;
      this.loadComments(true);
      return true;
    } catch (e) {
      logError(`[DynamicDetail] addDynComment 异常: ${e}`);
      promptAction.showToast({ message: '发送失败，请稍后再试', duration: 2000 });
      return false;
    }
  }

  /** 上传评论图片：与视频评论走同一套（逐张上传换 URL，再拼 pictures json） */
  private async uploadPictures(drafts: CommentImageDraft[]): Promise<string> {
    const imgs: string[] = [];
    for (const d of drafts) {
      const up = await uploadCommentImage(d.path, d.mime, d.ext);
      if (!up || !up.url) return '';
      imgs.push(JSON.stringify({ img_src: up.url, img_width: up.width, img_height: up.height }));
    }
    return '[' + imgs.join(',') + ']';
  }

  // ────────────── 互动 ──────────────

  private hasLogin(): boolean {
    return (this.biliCookie ?? '').includes('SESSDATA');
  }

  private async toggleLike(): Promise<void> {
    const it = this.item;
    if (!it) return;
    if (!this.hasLogin()) {
      promptAction.showToast({ message: '登录后才能点赞', duration: 1500 });
      this.getUIContext().getRouter().pushUrl({ url: 'pages/QrCodeLoginPage' }).catch(() => {});
      return;
    }
    if (this.liking_) return;
    this.liking_ = true;
    const st = this.likeState_;
    const target: boolean = !st.liked;
    const prevLiked: boolean = st.liked;
    const prevCount: number = st.count;
    st.liked = target;
    st.count = Math.max(0, prevCount + (target ? 1 : -1));
    try {
      const res: CommentLikeResult = await setDynamicLike(it.idStr, target);
      if (!res.ok) {
        st.liked = prevLiked;
        st.count = prevCount;
        promptAction.showToast({ message: res.message, duration: 1800 });
      } else {
        it.liked = target;
        it.likeCount = st.count;
      }
    } catch (e) {
      st.liked = prevLiked;
      st.count = prevCount;
      promptAction.showToast({ message: '点赞失败，请稍后重试', duration: 1800 });
    } finally {
      this.liking_ = false;
    }
  }

  private async toggleFollow(): Promise<void> {
    const it = this.item;
    if (!it || it.authorMid <= 0) return;
    if (!this.hasLogin()) {
      promptAction.showToast({ message: '登录后才能关注', duration: 1500 });
      this.getUIContext().getRouter().pushUrl({ url: 'pages/QrCodeLoginPage' }).catch(() => {});
      return;
    }
    if (this.followBusy_) return;
    this.followBusy_ = true;
    const target: boolean = !this.following;
    this.following = target;
    try {
      const ok: boolean = await modifyFollow(it.authorMid, target ? 1 : 2);
      if (!ok) {
        this.following = !target;
        promptAction.showToast({ message: '操作失败，请稍后再试', duration: 1800 });
      } else {
        promptAction.showToast({ message: target ? '已关注' : '已取消关注' });
      }
    } catch (e) {
      this.following = !target;
      logWarn(`[DynamicDetail] toggleFollow 异常: ${e}`);
    } finally {
      this.followBusy_ = false;
    }
  }

  // ────────────── 跳转 ──────────────

  private openUpSpace(): void {
    const it = this.item;
    if (!it || !it.authorName) return;
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UpSpacePage',
      params: { mid: it.authorMid, upName: it.authorName, upFace: it.authorFace }
    }).catch(() => {});
  }




  // ────────────── UI ──────────────

  @Builder
  wallpaperDarknessLayer() {
    if (this.wallpaperDarkness < 50) {
      Column()
        .width('100%').height('100%')
        .backgroundColor(`rgba(0, 0, 0, ${(50 - this.wallpaperDarkness) / 50})`)
    } else if (this.wallpaperDarkness > 50) {
      Column()
        .width('100%').height('100%')
        .backgroundColor(`rgba(255, 255, 255, ${(this.wallpaperDarkness - 50) / 50})`)
    }
  }

  private getCardBg(): string {
    return cardItemBg(this.isDarkMode, this.cardTransparentStyle, this.cardBgOpacity);
  }

  private getCardBorderColor(): string {
    return cardItemBorder(this.isDarkMode, this.cardTransparentStyle,
      this.cardBorderOpacity, this.cardBorderFollowTheme, this.customThemeColor);
  }

  /** 作者行（头像 + 昵称 + 时间 + 关注） */
  @Builder
  authorRow(it: SpaceDynamicItem) {
    Row() {
      Image(resizeImageUrl(it.authorFace, 120))
        .width(32).height(32)
        .borderRadius(16)
        .objectFit(ImageFit.Cover)
        .backgroundColor('#E8E8E8')
        .onClick(() => { this.openUpSpace(); })
      Column() {
        Text(it.authorName)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .maxLines(1)
        Text(fmtRelativeTime(it.pubTs))
          .fontSize(11)
          .fontColor(this.isDarkMode ? '#999999' : '#888888')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 9 })
      .onClick(() => { this.openUpSpace(); })

      if (it.authorMid > 0) {
        Text(this.following ? '已关注' : '关注')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.following ? (this.isDarkMode ? '#CCCCCC' : '#666666') : this.customThemeColor)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(14)
          .border({
            width: 0.8,
            color: this.following ? (this.isDarkMode ? 'rgba(255,255,255,0.25)' : 'rgba(0,0,0,0.15)')
              : themeHexAlpha(this.customThemeColor, 55)
          })
          .backgroundColor(this.following ? Color.Transparent : themeHexAlpha(this.customThemeColor, 10))
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => { this.toggleFollow(); })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 内容卡：作者行 + 共用卡片主体（正文/图片/视频/番剧外观与动态页完全一致） */
  @Builder
  contentCard(it: SpaceDynamicItem) {
    Column() {
      this.authorRow(it)
      DynamicCardBody({
        item: it,
        like: this.likeState_,
        onToggleLike: () => { this.toggleLike(); },
        // 详情页不传 onTapSelf：卡片本体点了不做事（这里就是详情页）
        onPreview: (urls: string[], thumbIds: string[], index: number,
          ox: number, oy: number, ow: number, oh: number) => {
          this.previewUrls = urls;
          this.previewIndex = index;
          this.previewOriginX = ox;
          this.previewOriginY = oy;
          this.previewOriginW = ow;
          this.previewOriginH = oh;
          this.showPreview = true;
        }
      })
        .margin({ top: 12 })
        .width('100%')

      // 统计行（与动态页同款：视频卡内部已含播放/弹幕/点赞，故仅非视频卡显示）
      if (!it.video) {
        Row({ space: 16 }) {
          DynLikePill({
            like: this.likeState_,
            onToggle: () => { this.toggleLike(); }
          })
          Row({ space: 4 }) {
            Image($r('app.media.share_zf'))
              .width(16).height(16)
              .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            Text(fmtCount(it.forwardCount)).fontSize(11).fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
          }
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(16)
          .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)')
          .alignItems(VerticalAlign.Center)

          Row({ space: 4 }) {
            Image($r('app.media.message_on_message'))
              .width(16).height(16)
              .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            Text(fmtCount(it.commentCount)).fontSize(11).fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
          }
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(16)
          .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 14 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    // 圆角跟随"卡片样式"设置（与动态页 cardListBorderRadius 同一个值，两页才一致）
    .borderRadius(this.cardListBorderRadius)
    .backgroundColor(this.getCardBg())
    .border({ width: this.cardBorderWidth, color: this.getCardBorderColor() })
    // 与动态页卡片同款投影（此前详情页漏了，同一张卡在两个页面观感不一致）
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 2 })
    .margin({ top: 10 })
  }

  /** 评论头：数量 + 排序切换 */
  @Builder
  commentsHeader(it: SpaceDynamicItem) {
    Row({ space: 8 }) {
      Text(`评论 ${fmtCount(it.commentCount)}`)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
      Blank()
      Text('按热度')
        .fontSize(12)
        .fontColor(this.commentsSort === 3 ? this.customThemeColor : (this.isDarkMode ? '#999999' : '#888888'))
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .borderRadius(12)
        .backgroundColor(this.commentsSort === 3 ? themeHexAlpha(this.customThemeColor, 12) : Color.Transparent)
        .onClick(() => { this.switchSort(3); })
      Text('按时间')
        .fontSize(12)
        .fontColor(this.commentsSort === 2 ? this.customThemeColor : (this.isDarkMode ? '#999999' : '#888888'))
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .borderRadius(12)
        .backgroundColor(this.commentsSort === 2 ? themeHexAlpha(this.customThemeColor, 12) : Color.Transparent)
        .onClick(() => { this.switchSort(2); })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 18, bottom: 4 })
  }

  /** 评论区：气泡列表 + 二级回复缩进 + 加载更多 */
  @Builder
  commentsArea(it: SpaceDynamicItem) {
    Column() {
      if (this.comments.length === 0) {
        Column() {
          if (this.commentsLoading || !this.commentsLoaded) {
            LoadingProgress().width(24).height(24).color(this.customThemeColor)
          } else {
            Text('还没有评论，来说点什么吧')
              .fontSize(13)
              .fontColor(this.isDarkMode ? '#888888' : '#999999')
          }
        }
        .width('100%')
        .padding({ top: 28, bottom: 28 })
        .alignItems(HorizontalAlign.Center)
      } else {
        // ⚠️ 左右边距只能给一处：本容器 12 内边距 + 组件自带 margin 传 0。
        //    若两边都给（组件 width('100%') + 自带 margin 12），总宽会超出容器 24 ⇒ 右侧被裁
        //    （"评论左右边距不一样"的坑，2026-09-18 两次踩到）
        Column() {
          ForEach(this.comments, (c: ObservableComment) => {
            Column() {
              CommentItemComponent({
                comment: c,
                isLast: false,
                videoDetail: null,
                isExpanded: c.expanded,
                repliesVersion: this.repliesVersion,
                cardMarginVp: 0,
                onExpandComment: (target: ObservableComment) => { this.toggleReplies(target); },
                onCollapseComment: () => { this.toggleReplies(c); },
                onLoadMoreReplies: (target: ObservableComment) => { this.loadMoreReplies(target); },
                onReplyTap: (root: number, parent: number, name: string) => {
                  this.replyRoot = root;
                  this.replyParent = parent;
                  this.replyTargetName = name;
                            }
              })
            }
            .width('100%')
            // ⭐ key 用稳定的 rpid：回复列表/展开状态由 @ObjectLink（@Track 字段）自己刷新，
            //    把 repliesVersion 拼进 key 会让每次"展开/点赞"都销毁重建整条评论 ⇒ 头像闪
          }, (c: ObservableComment) => `${c.rpid}`)
        }
        .width('100%')
        .padding({ left: 12, right: 12 })
      }

      if (this.commentsHasMore || this.commentsLoading) {
        Row() {
          if (this.commentsLoading) {
            LoadingProgress().width(18).height(18).color(this.customThemeColor)
          } else {
            Text('加载更多评论')
              .fontSize(13)
              .fontColor(this.customThemeColor)
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 14, bottom: 20 })
        .onClick(() => { this.loadComments(false); })
      } else if (this.comments.length > 0) {
        Text('没有更多评论了')
          .fontSize(12)
          .fontColor(this.isDarkMode ? '#777777' : '#AAAAAA')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 14, bottom: 20 })
      }
    }
    .width('100%')
  }

  /**
   * 底部常驻输入条（按用户要求：**一直展开，不要胶囊态、不要收起按钮**）。
   * ⚠️ `autoFocus: false` 保持：常驻输入框**不主动拉输入法**，用户自己点输入框才弹键盘，
   *    否则一进详情页就被键盘顶掉半屏。回复某人时只把 placeholder 换成「回复 @xxx：」，
   *    不再另起一行标题，保持"只有输入框"。
   *
   * ⭐⭐ 两种承载方式**共用同一份内容**（红线 9：不许留两份副本漂移）：
   *    · 真材质设备 → `commentEntryInner(true)`：内容跑在**常驻半模态 sheet** 里，
   *      与「回复 / 发弹幕」同一条材质通道 ⇒ 真沉浸光感 + 跟随键盘 + 贴底 + 顶部圆角；
   *    · 老设备（无 26.0.0 材质）→ `commentEntryInner(false)`：页内渲染 + 系统磨砂玻璃，
   *      位置/圆角/键盘避让与原实现完全一致（零回归）。
   *   ⚠️ 页内通道必须**把不透明度降下来**磨砂才看得见 —— 原来的 `0.96/0.97` 近不透明底
   *      等于把磨砂整层盖住（这就是此前"看不出玻璃"的真正原因，不是缺材质）。
   */
  @Builder
  commentEntryInner(inSheet: boolean) {
    Column() {
      CommentInputBar({
        ctrl: this.entryEmoteCtrl,
        placeholder: this.replyRoot > 0 ? `回复 @${this.replyTargetName}：` : '说点什么…',
        showImageButton: this.replyRoot === 0,
        autoFocus: false,
        onSend: (content: string, pictures: CommentImageDraft[]) => {
          return this.submitComment(content, pictures);
        }
      })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    // sheet 通道：形状归面板（顶部圆角 + 贴底，与发弹幕同款），内容层不再画描边
    .borderRadius(inSheet ? { topLeft: 20, topRight: 20 } : 16)
    // ⚠️ 材质层在 backgroundColor **之下** ⇒ sheet 挂材质时底色必须全透明（硬要求①）
    .backgroundColor(inSheet
      ? Color.Transparent
      : (this.isDarkMode ? 'rgba(28,28,30,0.55)' : 'rgba(255,255,255,0.55)'))
    // ⛔ 挂了材质就**绝不能再叠模糊**（硬要求③）⇒ sheet 通道置 NONE；
    //    页内通道没有材质，用官方降级配方 COMPONENT_THICK 兑出玻璃观感
    .backgroundBlurStyle(inSheet ? BlurStyle.NONE : BlurStyle.COMPONENT_THICK,
      { colorMode: this.isDarkMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT })
    .border({
      width: inSheet ? 0 : 0.5,
      color: this.isDarkMode ? 'rgba(255,255,255,0.14)' : 'rgba(0,0,0,0.08)'
    })
  }

  /**
   * 回到顶部悬浮按钮（浮在内容之上、不占文档流）。
   *
   * ⭐ 与搜索页同款三形态：
   *   · 智感握姿开 + 竖屏 → 左右各一个按钮，各自钉在一边（只允许上下拖），
   *     只有"当前握持手"那一侧可见（左手 → 左边那个；右手/未知 → 右边那个）；
   *   · 智感握姿关 / 横屏 → 单个按钮，可上下拖 + 左右拖够 60vp 吸附换边（位置落盘）。
   *
   * ⚠️ 定位只用 Edges 字段（bottom + left/right）：`position` 一旦混入 Position 的 x/y，
   *    另一个字段会被**静默忽略**（本页底部输入胶囊就踩过：`{x:0, bottom:0}` 直接落到屏幕顶）。
   * ⚠️ 触摸必须由自己的 Block 层接管：HdsTabs 的 TabBar（沉浸光感按钮本体）会自己消费事件，
   *    直接给它挂 onTouch 收不到回调。
   * ⚠️ 这里刻意不抽成"带参数的 @Builder"：@Builder 按值传参在部分版本上不会因参数变化刷新，
   *    而"显示/隐藏"恰好是最需要实时的那一项；状态都直接写在 this 上，保证每次都重新求值。
   */
  @Builder
  backToTopButton() {
    if (this.smartGripEnabled && !this.isLandscape) {
      // ── 左按钮：左手握持时显示 ──
      Stack() {
        HdsMiniBarButton({
          barWidth: 48,
          barHeight: 48,
          contentPadding: 0,
          containerSize: { width: 48, height: 48 },
          barBottomMargin: 0,
          barOverlap: true,
          barPosition: BarPosition.End
        }) {
          Image($r('app.media.chevron_down'))
            .width(20).height(20)
            .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : (this.isDarkMode ? Color.White : Color.Black))
            .rotate({ angle: 180 })
        }
        Column()
          .width(48).height(48)
          .hitTestBehavior(HitTestMode.Block)
          .onTouch((event: TouchEvent) => { this.handleFloatBtnTouch(event, false); })
      }
      .width(48).height(48)
      .position({ bottom: this.dynDetailFloatBtnY, left: this.smartGripLeft })
      .opacity(this.hand === 1 && this.showBackToTop ? 1 : 0)
      .translate({ x: this.hand === 1 && this.showBackToTop ? 0 : -20 })
      .scale({ x: this.showBackToTop ? this.btnScale : 0, y: this.showBackToTop ? this.btnScale : 0 })
      .hitTestBehavior(this.hand === 1 && this.showBackToTop ? HitTestMode.Default : HitTestMode.None)
      .animation(this.da || this.isDragging ? { duration: 0 } : {
        duration: 300,
        curve: curves.springMotion(0.3, 0.4)
      })

      // ── 右按钮：右手 / 未知握持时显示 ──
      Stack() {
        HdsMiniBarButton({
          barWidth: 48,
          barHeight: 48,
          contentPadding: 0,
          containerSize: { width: 48, height: 48 },
          barBottomMargin: 0,
          barOverlap: true,
          barPosition: BarPosition.End
        }) {
          Image($r('app.media.chevron_down'))
            .width(20).height(20)
            .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : (this.isDarkMode ? Color.White : Color.Black))
            .rotate({ angle: 180 })
        }
        Column()
          .width(48).height(48)
          .hitTestBehavior(HitTestMode.Block)
          .onTouch((event: TouchEvent) => { this.handleFloatBtnTouch(event, false); })
      }
      .width(48).height(48)
      .position({ bottom: this.dynDetailFloatBtnY, right: this.smartGripRight })
      .opacity(this.hand !== 1 && this.showBackToTop ? 1 : 0)
      .translate({ x: this.hand !== 1 && this.showBackToTop ? 0 : 20 })
      .scale({ x: this.showBackToTop ? this.btnScale : 0, y: this.showBackToTop ? this.btnScale : 0 })
      .hitTestBehavior(this.hand !== 1 && this.showBackToTop ? HitTestMode.Default : HitTestMode.None)
      .animation(this.da || this.isDragging ? { duration: 0 } : {
        duration: 300,
        curve: curves.springMotion(0.3, 0.4)
      })
    } else {
      // ── 单按钮（智感握姿关闭 / 横屏）：可上下拖，也能左右拖够 60vp 换边 ──
      Stack() {
        HdsMiniBarButton({
          barWidth: 48,
          barHeight: 48,
          contentPadding: 0,
          containerSize: { width: 48, height: 48 },
          barBottomMargin: 0,
          barOverlap: true,
          barPosition: BarPosition.End
        }) {
          Image($r('app.media.chevron_down'))
            .width(20).height(20)
            .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : (this.isDarkMode ? Color.White : Color.Black))
            .rotate({ angle: 180 })
        }
        Column()
          .width(48).height(48)
          .hitTestBehavior(HitTestMode.Block)
          .onTouch((event: TouchEvent) => { this.handleFloatBtnTouch(event, true); })
      }
      .width(48).height(48)
      .position(this.dynDetailFloatBtnSide === 'left'
        ? { bottom: this.dynDetailFloatBtnY, left: 32 }
        : { bottom: this.dynDetailFloatBtnY, right: 32 })
      .opacity(this.showBackToTop ? 1 : 0)
      .scale({ x: this.showBackToTop ? this.btnScale : 0, y: this.showBackToTop ? this.btnScale : 0 })
      .hitTestBehavior(this.showBackToTop ? HitTestMode.Default : HitTestMode.None)
      .animation(this.da || this.isDragging ? { duration: 0 } : {
        duration: 300,
        curve: Curve.Ease
      })
      .translate({ x: this.dragOffsetX })
    }
  }

  build() {
    Stack() {
      // ── 背景（与其它页面同一套壁纸逻辑）──
      if (this.wallpaper === 'builtin') {
        Stack() {
          Image(this.isDarkMode ? $r('app.media.wallpaper_shen') : $r('app.media.wallpaper_qian'))
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
          this.wallpaperDarknessLayer()
        }
        .width('100%').height('100%')
      } else if (this.wallpaper === 'custom' && this.customWallpaper) {
        Stack() {
          Image('file://' + this.customWallpaper)
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
            .blur(this.wallpaperBlur)
          this.wallpaperDarknessLayer()
        }
        .width('100%').height('100%')
      } else {
        Stack() {
          Column()
            .width('100%').height('100%')
            .backgroundColor(this.isDarkMode ? '#1A1A1A' : '#F5F6F7')
          this.wallpaperDarknessLayer()
        }
        .width('100%').height('100%')
      }

      // ── 内容 ──
      HdsNavigation() {
        Column() {
          Scroll(this.scroller) {
            Column() {
              if (this.item && this.contentReady_) {
                Column() {
                  Column() { this.contentCard(this.item) }
                    .width('100%')
                    .padding({ left: 12, right: 12 })
                    // 供 correctTopGap 实测内容卡实际位置
                    .id('dd_card')
                  Column() { this.commentsHeader(this.item) }
                    .width('100%')
                    .padding({ left: 12, right: 12 })
                  this.commentsArea(this.item)
                }
                .width('100%')
                // 淡入 + 轻微上浮（位置已在校正后固定，所以看不到位移）
                .opacity(this.contentShown_ ? 1 : 0)
                .translate({ y: this.contentShown_ ? 0 : 12 })
              } else if (this.item) {
                // ⚠️ 已有数据、只是还没到"布局稳定后显示"的时机（contentReady_ 还没置真）：
                //    这里必须**什么都不显示**。原先落到下面的 else，于是先闪一下
                //    "加载失败 / 点击重试"再出现正文（用户反馈"不太好看"）。
                Column().width('100%').height(1)
              } else if (this.err) {
                Column() {
                  Text(this.err)
                    .fontSize(13).fontColor('#999999')
                  Text('点击重试')
                    .fontSize(13).fontColor(this.customThemeColor)
                    .margin({ top: 10 })
                    .onClick(() => { this.loading = true; this.loadDetail(); this.loadComments(true); })
                }
                .width('100%')
                .padding({ top: 60 })
                .alignItems(HorizontalAlign.Center)
              } else {
                Column() {
                  LoadingProgress().width(28).height(28).color(this.customThemeColor)
                  Text('加载中...').fontSize(13).fontColor('#999999').margin({ top: 10 })
                }
                .width('100%')
                .padding({ top: 60 })
                .alignItems(HorizontalAlign.Center)
              }
            }
            .width('100%')
            // 顶部先让出标题栏高度：HdsNavigation 的内容区与标题栏重叠（见文件头 TITLE_BAR_H_VP 注释），
            // 不留白的话第一屏内容卡会被毛玻璃标题栏压住
            // 底部固定给常驻输入条留位（输入条高约 60vp + 呼吸）
            .padding({ top: this.topGap_, bottom: 92 })
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          // ⭐ 上滑超过阈值 → 显示回到顶部按钮（只在值变化时写状态，见 BACK_TO_TOP_THRESHOLD_VP 注释）
          .onWillScroll(() => {
            const want: boolean = Math.abs(this.scroller.currentOffset().yOffset) > BACK_TO_TOP_THRESHOLD_VP;
            if (want !== this.showBackToTop) {
              this.showBackToTop = want;
            }
          })

        }
        .width('100%')
        .height('100%')
      }
      // ★ 顶栏毛玻璃（与聊天页同款）：标题栏自身避开安全区 + 常驻系统材质模糊
      .titleBar({
        avoidLayoutSafeArea: true,
        padding: { start: LengthMetrics.vp(16), end: LengthMetrics.vp(16) },
        style: {
          scrollEffectOpts: {
            enableScrollEffect: true,
            scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
            blurEffectiveStartOffset: LengthMetrics.vp(0),
            blurEffectiveEndOffset: LengthMetrics.vp(20)
          },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          },
          originalStyle: {
            backgroundStyle: {
              backgroundColor: 'transparent',
              blurRadius: 20
            },
            contentStyle: {
              titleStyle: {
                mainTitleColor: this.isDarkMode ? '#FFFFFF' : '#000000'
              }
            }
          },
          scrollEffectStyle: {
            backgroundStyle: {
              backgroundColor: 'transparent',
              blurRadius: 20
            },
            contentStyle: {
              titleStyle: {
                mainTitleColor: this.isDarkMode ? '#FFFFFF' : '#000000'
              }
            }
          }
        },
        content: {
          title: {
            mainTitle: '动态详情'
          }
        }
      })
      .titleMode(HdsNavigationTitleMode.MINI)
      .hideBackButton(false)
      .mode(NavigationMode.Stack)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .width('100%')
      .height('100%')

      // 悬浮评论入口（贴屏底、无遮罩、不占文档流）
      // ⚠️ 不要写 `.position({ x: 0, bottom: 0 })`：Position 只有 x/y 两个字段，
      //    `bottom` 会被静默忽略 ⇒ 组件落到 y = 0（**屏幕最顶部**）。用"全屏 Column + 底部对齐"代替。
      //    hitTestBehavior(Transparent)：胶囊之外区域的触摸照旧透给下面的列表。
      // ⭐ 外层沉浸光感（2026-09-24 定稿·三）：真材质设备把内容挂进**常驻半模态 sheet**
      //    —— 与「回复 / 发弹幕」同一条材质通道，因此**能跟键盘抬起**（sheet 的 keyboardAvoidMode）。
      //    ⚠️ 曾试过常驻 `bindPopup`（浮层）：它没有页面级键盘避让，点输入框会被键盘**盖住**，
      //       且浮层只能给单一 radius（四角同值）、还悬浮在屏幕底上方 ⇒ 形状/位置都不对。已放弃。
      //    ⚠️ 内容区自己的 `.systemMaterial()` 官方不生效（`Material inactive: out of scope`），
      //       内容区唯一例外是借 `HdsTabs` 浮动栏，但它是自绘**胶囊**、尺寸必须写死，
      //       会把页内生长的表情面板裁掉 ⇒ 对"贴底 + 可生长"的输入条不成立。
      Column() {
        Blank()
        if (this.entryUseSheet) {
          // 1vp 透明挂载点：sheet 画在窗口 Overlay 层，挂载点自身不参与命中
          Column()
            .width(1)
            .height(1)
            .hitTestBehavior(HitTestMode.None)
            .bindSheet($$this.entrySheetOn, this.commentEntryInner(true), this.entrySheetOpts())
        } else {
          // 老设备（无 26.0.0 材质）：页内渲染 + 系统磨砂，位置/圆角/键盘避让零回归
          this.commentEntryInner(false)
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)

      // ── 回到顶部悬浮按钮（上滑超过阈值才出现，见 BACK_TO_TOP_THRESHOLD_VP）──
      //    ⚠️ 入口走 sheet 时按钮**盖不过它**（sheet 在页面内容之上）⇒ 已把按钮的距底下限
      //       抬到 floatBtnMinBottom()，禁止拖进入口区域。
      this.backToTopButton()

      // 图片预览（起点矩形传 0 → 组件内部退化为中心缩放）
      FullImagePreview({
        isShow: $showPreview,
        previewUrls: this.previewUrls,
        thumbIds: [],
        initialIndex: this.previewIndex,
        originX: $previewOriginX,
        originY: $previewOriginY,
        originW: $previewOriginW,
        originH: $previewOriginH,
        immersiveMode: false
      })
    }
    .width('100%')
    .height('100%')
  }
}
