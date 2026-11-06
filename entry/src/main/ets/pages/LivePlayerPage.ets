// LivePlayerPage.ets — 直播播放页（使用 Video 组件）
import { window, display, KeyboardAvoidMode, Animator, AnimatorResult, curves } from '@kit.ArkUI';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { audio } from '@kit.AudioKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { media } from '@kit.MediaKit';
import { getLiveRoomInfo, getLiveStreamUrl, getLiveQualityLabel, invalidateCachedStreamUrl, getRoomPlayInfo, QualityDescription, getLiveRoomH5Info, LiveRoomH5Info } from '../api/LiveApi';
import { LiveViewHelper } from '../services/LiveViewHelper';
import { BusinessError } from '@kit.BasicServicesKit';
import { VibrateUtils } from '../utils/VibrateUtils';
import { LiveDanmakuClient } from '../services/LiveDanmakuClient';
import { LiveDanmakuController } from '../services/LiveDanmakuController';
import { LiveMessage, LiveMsgType } from '../model/LiveMessage';
import { sendLiveDanmaku } from '../api/LiveDanmakuApi';
import { extractSessdataFromCookie } from '../api/FeedbackService';
import { ChatEmote, ChatTextSegment, ChatEmoteItem, ChatEmotePackage } from '../utils/ChatEmote';
import { themeRgba } from '../utils/ThemeColor';
import { HdsCircleBackButton } from '../components/infra/HdsCircleBackButton';
import { HdsGlassBar } from '../components/infra/HdsGlassBar';
import { MaterialUtil } from '../utils/MaterialUtil';

interface QualityOption {
  qn: number;
  label: string;
}

/** 视频画面在窗口中的显示矩形（vp） */
interface VideoRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

@Entry
@Component
struct LivePlayerPage {
  // ========== 直播状态 ==========
  @State roomId: number = 0;
  @State title: string = '';
  @State online: number = 0;
  @State uname: string = '';
  @State roomCover: string = ''; // 直播间封面（实况窗/通知中心媒体封面）
  /** 主播头像 */
  @State upFace: string = '';
  /** 主播胶囊玻璃宽度（按昵称实测宽度算，HdsGlassBar 只吃具体数值） */
  @State anchorBarW: number = 120;
  /** 直播间主题背景（H5 room_info.app_background，铺在视频黑边后面） */
  @State appBg: string = '';
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State retryCount: number = 0;
  @State currentQn: number = 0;  // 0=未设置，从API获取后选择最高画质
  @State showQualityPicker: boolean = false;

  // ========== 响应式窗口尺寸（唯一真源，替代 display 快照） ==========
  @State winW: number = 0;              // 窗口宽（vp）
  @State winH: number = 0;              // 窗口高（vp）
  @State isLandscape: boolean = false;  // 窗口是否横屏
  @State streamAR: number = 16 / 9;     // 直播流宽高比（来自 API / videoSizeChange）

  // ========== Video 组件状态 ==========
  @State videoSrc: string = '';
  @State videoSrcVersion: number = 0;  // 强制重建 Video 用
  private av: media.AVPlayer | null = null; // AVPlayer 播放器（支持后台续播）
  private xc: XComponentController = new XComponentController(); // 视频渲染表面
  private surfaceId_: string = '';
  @State ratioMode: string = 'fit'; // 画面比例：fit=适应 / crop=裁剪 / fill=拉伸

  // ========== 动态画质列表（从API获取，只显示此直播间有的画质） ==========
  @State availableQualities: QualityOption[] = [];

  // ========== VideoControls 绑定状态 ==========
  @State isPlaying: boolean = true;
  @State currentTime: number = 0;
  @State duration: number = 0;
  @State isControlsVisible: boolean = true;
  @State isMuted: boolean = false;
  @State playbackRate: number = 1.0;
  @State showGestureHint: boolean = false;
  @State gestureHintMainText: string = '';
  @State gestureHintProgress: number = 0;
  @State gestureHintType: string = '';
  @State showBottomHint: boolean = false;
  @State bottomHintImage: ResourceStr | undefined = undefined;
  @State bottomHintText: string = '';
  @State isBackgroundPlayback: boolean = false;

  // ========== 直播弹幕 / 聊天 ==========
  @State liveMessages: LiveMessage[] = [];
  @State danmakuOn: boolean = true;
  @State chatOpen: boolean = false;        // 仅横屏：右侧聊天浮层
  @State chatInput: string = '';
  @State chatSending: boolean = false;
  @State wsState: string = 'idle';         // connecting / open / reconnecting / closed
  /** 表情表是否已就绪（就绪后重建聊天列表，把 [喝彩] 之类替换成表情图） */
  @State emoteReady: boolean = false;
  /** 表情面板是否展开（逻辑开关） */
  @State showEmote: boolean = false;
  /** 表情面板动画高度（0=收起；Animator 逐帧驱动，列表同步让位） */
  @State emoteH: number = 0;
  /** 表情面板走 bindPopup + systemMaterial（真材质设备），老机退回页内圆角卡片 */
  private emoteUsePopup: boolean = MaterialUtil.available();
  private emoteAnimator: AnimatorResult | null = null;
  /** 当前选中的表情分类 */
  @State emotePkgIdx: number = 0;
  /** 聊天输入：富文本（表情以图片 span 插入，发送时还原成 [xx]） */
  private chatInputCtl: RichEditorController = new RichEditorController();
  @State chatHasContent: boolean = false;
  @State fsMode: boolean = false;          // 竖屏全屏：隐藏聊天，视频铺满窗口
  private danmakuClient: LiveDanmakuClient | null = null;
  private danmakuCtl: LiveDanmakuController | null = null;
  private danmakuCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private chatScroller: Scroller = new Scroller();
  /** 弹幕画布尺寸防抖（切比例/全屏动画期间避免逐帧重建轨道） */
  private danmakuResizeW: number = 0;
  private danmakuResizeH: number = 0;
  private danmakuResizeTimer: number = -1;
  private sendCooldownUntil: number = 0;
  private gestureBlocked_: boolean = false;
  // 亮度/音量起始值
  @State sv: number = 1; // start volume (0-1)
  @State sb: number = 1; // start brightness (0-1)
  @State vol: number = 1;
  @State bri: number = 1;
  // 安全区域（px→vp 转换后）
  @State safeTop: number = 44;
  @State safeBottom: number = 24;
  @State safeLeft: number = 0;
  @State safeRight: number = 0;

  private maxRetries: number = 8;
  private controlsTimer: number = -1;
  private retryTimer: number = -1;
  /** ⭐ 设备媒体音量最大档位（readSystemVolume 时刷新） */
  private maxVol_: number = 15
  /** ⭐ AudioVolumeManager 实例（供 streamVolumeChange 监听/注销） */
  private volMgr_: audio.AudioVolumeManager | null = null
  /** ⭐ 是否已注册系统音量变化监听 */
  private volListening_: boolean = false
  private mw: window.Window | undefined = undefined;  // 主窗口，用于控制系统栏

  // 记录播放开始时间，用于过滤启动时的非致命错误（如 live-stream loop 801）
  private playbackStartMs: number = 0;

  // ========== 屏幕旋转 ==========
  @State rotationMode: string = 'auto';  // 'auto' | 'portrait' | 'landscape'

  // ========== 卡片样式 ==========
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = false;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 40;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1.5;
  @StorageLink('cardCustomColor') cardCustomColor: string = '';
  @StorageLink('cardStyleLiveQuality') cardStyleLiveQuality: boolean = true;
  @StorageLink('bgp') bgp: boolean = false; // 后台播放开关（与普通播放器共用持久化 key）

  /** 当前窗口是否为横屏（由 onAreaChange 维护，旋转后自动更新） */
  private isWindowLandscape(): boolean {
    return this.winW > this.winH;
  }

  // ========== 手势状态（onVT 风格） ==========
  private sx_: number = 0; private sy_: number = 0;
  private gm_: string = '';         // 手势模式: '' | 'volume' | 'brightness'
  private ml_: boolean = false;     // 是否已移动（区分点击）
  private la_: boolean = false;     // 长按激活（直播无长按，保留占位）
  private dt_: number = -1;        // 双击定时器
  private dtp_: boolean = false;    // 是否双击
  private lt_: number = -1;        // 长按定时器
  private gt_: number = -1;        // 手势提示隐藏定时器
  private lastHapticPct_: number = -1;

  // ==================== 画面比例 + 重置直播 ====================

  /**
   * 在给定区域里按 streamAR 计算「视频显示矩形」。
   * fit=适应（contain，留黑边）/ crop=裁剪（cover，裁掉超出部分）/ fill=拉伸（撑满，变形）
   */
  private fitRect(x: number, y: number, w: number, h: number): VideoRect {
    const ar: number = this.streamAR > 0 ? this.streamAR : 16 / 9;
    let vw: number = w;
    let vh: number = h;
    if (this.ratioMode !== 'fill') {
      const scale: number = this.ratioMode === 'crop'
        ? Math.max(w / ar, h)
        : Math.min(w / ar, h);
      vw = ar * scale;
      vh = scale;
    }
    return { x: x + (w - vw) / 2, y: y + (h - vh) / 2, w: vw, h: vh };
  }

  /**
   * 聊天输入栏底部留白：底部系统手势区会吞掉贴底约 50vp 的点击
   * （实测输入框 [1986,2084] 内点击无法聚焦），所以留 60vp。
   */
  private chatBottomPad(): number {
    return 12;
  }

  /** 竖屏聊天输入栏高度（含底部安全区） */
  private chatInputH(): number {
    return 52 + this.chatBottomPad();
  }

  /**
   * 横屏悬浮输入框距底：底部系统手势区会吞掉贴底点击，
   * 40vp 是 Dock 实测可点的最小留白（比竖屏常驻输入栏省 20vp）。
   */
  private chatFloatPad(): number {
    return 12;
  }

  /** 开/关表情面板（展开时收起键盘，避免输入法把面板顶掉） */
  /** 顶栏距屏幕上沿的间距：竖屏让开状态栏，横屏系统栏已隐藏 → 直接 12 */
  private topBarPad(): number {
    return this.isLandscape ? 12 : this.safeTop + 12;
  }

  /** 输入行总宽（玻璃胶囊 + 发送圆钮） */
  private chatInputW(): number {
    if (this.isLandscape) {
      return Math.max(140, this.chatPanelW() - 20);
    }
    return Math.max(160, this.winW - 24);
  }

  /** 输入胶囊玻璃宽度：总宽减去发送圆钮（48 容器 + 8 间距）与自身容器余量 4 */
  private chatInputPillW(): number {
    return Math.max(120, this.chatInputW() - 54);
  }

  /** 发送：独立沉浸光感圆钮（胶囊右侧） */
  @Builder
  chatSendCircle() {
    Stack({ alignContent: Alignment.Center }) {
      HdsGlassBar({
        barWidth: 44,
        barHeight: 44,
        contentPadding: 1,
        barBottomMargin: 1,
        hitThrough: true,
        lightColor: '#66FFFFFF'
      })
      Row() {
        Image($r('app.media.send_out'))
          .width(20).height(20)
          .fillColor(this.chatHasContent ? this.customThemeColor : 'rgba(255,255,255,0.3)')
      }
      .width(44).height(44)
      .justifyContent(FlexAlign.Center)
      .borderRadius(22)
      .hitTestBehavior(HitTestMode.Block)
      .onClick(() => {
        this.sendChat();
      })
    }
  }

  /** 表情面板展开高度（内容：tabs 40 + 网格 138 + 内边距 12 + 外边距 6） */
  private emotePanelH(): number {
    return 196;
  }

  private toggleEmotePanel(): void {
    this.tick(10);
    const open: boolean = !this.showEmote;
    this.showEmote = open;
    if (open) {
      try {
        this.getUIContext().getFocusController().clearFocus();
      } catch (_e) {}
    }
    if (this.emoteUsePopup) {
      // 弹层自带出入场动画与系统材质，页内面板保持收起
      this.emoteH = 0;
      return;
    }
    this.animateEmoteH(open ? this.emotePanelH() : 0);
  }

  /** 表情面板弹层选项：Top 方向浮在输入框上方，点外部自动收起 */
  private emotePopupOpts(): CustomPopupOptions {
    const opts: CustomPopupOptions = {
      builder: (): void => { this.emotePopupBuilder(); },
      placement: Placement.Top,
      offset: { x: 0, y: -8 },
      enableArrow: false,
      autoCancel: true,
      mask: false,
      radius: 22,
      onStateChange: (e) => {
        if (!e.isVisible) {
          this.showEmote = false;
        }
      }
    } as CustomPopupOptions;
    if (this.emoteUsePopup) {
      opts.colorMode = AnchoredColorMode.FOLLOW_TARGET;
      opts.systemMaterial = MaterialUtil.emoteMaterial();
    }
    return opts;
  }

  /** 弹层内容：与页内面板同一套内容（材质/圆角由弹层负责） */
  @Builder
  emotePopupBuilder() {
    Column() {
      this.chatEmotePanel()
    }
    .width(this.chatInputW())
    .height(this.emotePanelH())
    .borderRadius(22)
    .clip(true)
  }

  /** 逐帧驱动 emoteH（与评论输入栏同款，避免与键盘/布局动画打架） */
  private animateEmoteH(to: number): void {
    if (this.emoteAnimator) {
      this.emoteAnimator.cancel();
      this.emoteAnimator = null;
    }
    const from: number = this.emoteH;
    if (Math.abs(to - from) < 0.5) {
      this.emoteH = to;
      return;
    }
    this.emoteAnimator = Animator.create({
      duration: 220,
      easing: 'ease-in-out',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: 1,
      begin: 0,
      end: 1
    });
    this.emoteAnimator.onframe = (p: number) => {
      this.emoteH = from + (to - from) * p;
    };
    this.emoteAnimator.onfinish = () => {
      this.emoteH = to;
      this.emoteAnimator = null;
    };
    this.emoteAnimator.oncancel = () => {
      this.emoteAnimator = null;
    };
    this.emoteAnimator.play();
  }

  /** 按昵称实测宽度算主播胶囊宽度（左距 5 + 头像 28 + 间距 7 + 文本 + 右距 14） */
  private updateAnchorBarW(): void {
    const name: string = this.uname || '主播';
    let textW: number = name.length * 13;
    try {
      const size = this.getUIContext().getMeasureUtils().measureTextSize({
        textContent: name,
        fontSize: 13
      });
      const w: number = this.getUIContext().px2vp(size.width as number);
      if (w > 0) {
        textW = w;
      }
    } catch (_e) {}
    textW = Math.min(170, Math.max(26, textW));
    this.anchorBarW = 5 + 28 + 7 + textW + 14;
  }

  /** 表情按 3 行切列（横滑用） */
  private emoteColumns(): ChatEmoteItem[][] {
    const list: ChatEmoteItem[] = this.currentEmoteList();
    const cols: ChatEmoteItem[][] = [];
    for (let i = 0; i < list.length; i += 3) {
      cols.push(list.slice(i, i + 3));
    }
    return cols;
  }

  /** 当前分类下的表情列表 */
  private currentEmoteList(): ChatEmoteItem[] {
    const pkgs: ChatEmotePackage[] = ChatEmote.getPackages();
    if (this.emotePkgIdx < 0 || this.emotePkgIdx >= pkgs.length) {
      return [];
    }
    return pkgs[this.emotePkgIdx].emotes;
  }

  /** 横屏聊天栏宽度 */
  private chatPanelW(): number {
    const w: number = Math.min(320, this.winW * 0.34);
    return Math.max(220, w);
  }

  /** 横屏是否处于「视频左 + 聊天右」分栏 */
  private chatSplit(): boolean {
    return this.isLandscape && this.chatOpen && !this.fsMode;
  }

  /** 分栏时上下胶囊要额外右缩的量（避开聊天栏） */
  private chatSplitInset(): number {
    return this.chatSplit() ? this.chatPanelW() : 0;
  }

  /**
   * ⭐ 视频区域（裁切容器）：
   *   横屏分栏 = 左侧（整宽 - 聊天栏）；横屏全屏/收起聊天 = 整窗；
   *   竖屏 = 顶栏下方、按 streamAR 限高（16:9 约 291vp，9:16 约 432vp）。
   */
  private videoAreaRect(): VideoRect {
    if (this.winW <= 0 || this.winH <= 0) {
      return { x: 0, y: 0, w: 1, h: 1 };
    }
    if (this.fsMode) {
      return { x: 0, y: 0, w: this.winW, h: this.winH };
    }
    // 统一屏幕边距 12vp（与评论区/输入框左右边距对齐）
    const gap: number = 12;
    if (this.isLandscape) {
      return {
        x: gap,
        y: gap,
        w: Math.max(120, this.winW - this.chatSplitInset() - gap * 2),
        h: this.winH - gap * 2
      };
    }
    // 顶栏浮在画面上，但视频仍要避开状态栏：从安全区下方 12vp 起
    const top: number = this.safeTop + 12;
    const ar: number = this.streamAR > 0 ? this.streamAR : 16 / 9;
    const fitH: number = Math.min((this.winW - gap * 2) / ar, this.winH * 0.52);
    return { x: gap, y: top, w: this.winW - gap * 2, h: Math.max(120, fitH) };
  }

  /** ⭐ 视频显示矩形：旋转/切画质/换比例都由它派生，不再读 display 快照 */
  private videoRect(): VideoRect {
    if (this.winW <= 0 || this.winH <= 0) {
      return { x: 0, y: 0, w: 1, h: 1 };
    }
    const a: VideoRect = this.videoAreaRect();
    return this.fitRect(a.x, a.y, a.w, a.h);
  }

  /** 竖屏聊天区顶部（视频区域下沿） */
  private portraitChatTop(): number {
    const a: VideoRect = this.videoAreaRect();
    return a.y + a.h;
  }

  /**
   * ⭐ 视频矩形与「视频区域」的可见交集。
   *   crop 模式下视频会比区域大（被裁），四角按钮必须贴可见边缘，
   *   否则会跟着视频矩形跑到屏幕外。
   */
  private videoOverlayRect(): VideoRect {
    const r: VideoRect = this.videoRect();
    const a: VideoRect = this.videoAreaRect();
    const x: number = Math.max(a.x, r.x);
    const y: number = Math.max(a.y, r.y);
    const right: number = Math.min(a.x + a.w, r.x + r.w);
    const bottom: number = Math.min(a.y + a.h, r.y + r.h);
    return { x, y, w: Math.max(1, right - x), h: Math.max(1, bottom - y) };
  }

  /** 弹幕画布：覆盖可见视频区（分栏时视频区域本身已排除聊天栏） */
  private danmakuRect(): VideoRect {
    return this.videoOverlayRect();
  }

  /** 触摸点是否落在「视频区域」内（含黑边） */
  private isPointInVideoArea(x: number, y: number): boolean {
    const r: VideoRect = this.videoAreaRect();
    return x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h;
  }

  /** 触摸是否落在聊天区（聊天滚动不能被亮度/音量手势抢走） */
  private isInChatArea(x: number, y: number): boolean {
    if (this.isLandscape) {
      return this.chatSplit() && x >= this.winW - this.chatPanelW();
    }
    return y >= this.portraitChatTop();
  }

  /** 优先用接口返回的档位名（杜比/4K/2K...），静态表兜底 */
  private qualityLabel(): string {
    for (let i = 0; i < this.availableQualities.length; i++) {
      if (this.availableQualities[i].qn === this.currentQn) {
        return this.availableQualities[i].label;
      }
    }
    return getLiveQualityLabel(this.currentQn);
  }

  private ratioLabel(): string {
    if (this.ratioMode === 'crop') { return '裁剪'; }
    if (this.ratioMode === 'fill') { return '拉伸'; }
    return '适应';
  }

  /** ⭐ 循环切换：适应 → 裁剪 → 拉伸 */
  private cycleAspectRatio(): void {
    this.tick(10);
    // 视频矩形由 ratioMode 派生，用 animateTo 包住切换才有点播那边"自然变形"的观感
    this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
      if (this.ratioMode === 'fit') {
        this.ratioMode = 'crop';
      } else if (this.ratioMode === 'crop') {
        this.ratioMode = 'fill';
      } else {
        this.ratioMode = 'fit';
      }
    });
    this.showBottomHintTemporarily(`画面比例：${this.ratioLabel()}`);
    this.showControlsTemporarily();
  }

  /** ⭐ 重置直播：释放播放器并强制重新拉流 */
  private resetLive(): void {
    this.tick(14);
    this.showBottomHintTemporarily('已重置直播');
    this.releasePlayer();
    this.showControlsTemporarily();
    this.startPlay(true);
  }

  /** ⭐ 播放/暂停切换 */
  private togglePlayPause(): void {
    this.tick(12);
    try {
      if (this.av) {
        if (this.av.state === 'playing') {
          this.av.pause();
        } else {
          this.av.play();
        }
      }
      this.showControlsTemporarily();
    } catch (_e) {}
  }

  /** 全屏时返回/侧滑：先退全屏，不退出直播间 */
  onBackPress(): boolean {
    if (this.fsMode) {
      this.setFullscreen(false);
      return true;
    }
    return false;
  }

  aboutToAppear() {
    // ⭐ 注册系统音量变化监听（音量键调节时同步 app 内滑块/手势起点）
    this.registerVolumeListener();
    // 聊天输入框：键盘弹出时压缩页面，输入栏始终可见
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    } catch (_e0) {}
    // ⭐ 首帧前的窗口尺寸估算（真正的尺寸由根节点 onAreaChange 接管）
    this.initWindowSize();
    // ⭐ 继承全局旋转锁，不再无条件放开自动旋转
    const lock: string = AppStorage.get<string>('screenOrientationLock') ?? '自动旋转';
    this.rotationMode = lock === '锁定竖屏' ? 'portrait' : (lock === '锁定横屏' ? 'landscape' : 'auto');
    // 横屏默认显示聊天栏（方案 2 分栏）
    this.chatOpen = this.isLandscape;
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params && params['roomId']) {
      this.roomId = params['roomId'] as number;
      this.getSafeArea();
      this.initPlayback();
      this.initLiveChat();
      // 表情表：聊天里的 [喝彩]/[大哭] 需要映射成图片；失败不影响文字显示
      ChatEmote.waitForLoaded(5).then((ok: boolean) => {
        if (ok) {
          this.emoteReady = true;
        }
      }).catch(() => {});
    } else {
      this.errorMsg = '缺少房间号';
      this.loading = false;
    }
  }

  /** ⭐ 首帧窗口尺寸（vp）；后续以 onAreaChange 为准 */
  private initWindowSize(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const ui = this.getUIContext();
      this.winW = ui.px2vp(d.width);
      this.winH = ui.px2vp(d.height);
      this.isLandscape = this.winW > this.winH;
    } catch (_e) {
      this.winW = 360;
      this.winH = 780;
    }
  }

  /**
   * ⭐ 根节点尺寸变化（旋转/分屏/折叠）→ 更新唯一真源。
   *    onAreaChange 在布局阶段回调，@State 更新必须延后到本帧结束。
   */
  private onRootArea = (o: Area, n: Area): void => {
    const w: number = n.width as number;
    const h: number = n.height as number;
    if (w <= 0 || h <= 0) { return; }
    if (Math.abs(w - this.winW) < 1 && Math.abs(h - this.winH) < 1) { return; }
    setTimeout(() => {
      const wasLandscape: boolean = this.isLandscape;
      this.winW = w;
      this.winH = h;
      this.isLandscape = w > h;
      if (wasLandscape !== this.isLandscape) {
        // 旋转时关掉浮层，避免旧位置的菜单停在半空
        this.showQualityPicker = false;
        this.isControlsVisible = true;
        // ⭐ 聊天栏跟随方向：竖屏 → 横屏必须自动展开（否则只剩视频、评论区不出现）；
        //    横屏 → 竖屏收起，避免竖屏残留右侧分栏。
        this.chatOpen = this.isLandscape;
        // ⚠️ 不再在这里退出全屏：全屏时按视频比例转屏是预期行为，退出全屏会打断它

        // 旋转后系统栏可能被系统恢复，重新进入沉浸式并补读安全区
        this.mw?.setWindowSystemBarEnable([]).catch(() => {});
        setTimeout(() => {
          this.mw?.setWindowSystemBarEnable([]).catch(() => {});
          this.refreshSafeArea();
        }, 320);
        logInfo(`[LivePlayer] 窗口旋转: ${w.toFixed(0)}x${h.toFixed(0)}, 横屏=${this.isLandscape}`);
      }
      this.refreshSafeArea();
      // 系统旋转动画约 460ms，avoid area 稳定后再补读一次
      if (wasLandscape !== this.isLandscape) {
        setTimeout(() => { this.refreshSafeArea(); }, 260);
      }
    }, 0);
  };

  /**
   * 初始化播放：先获取画质信息选最高画质，再开始播放
   */
  private async initPlayback(): Promise<void> {
    await this.fetchQualityInfo();
    this.startPlay();
  }

  private getSafeArea(): void {
    try {
      window.getLastWindow(this.getUIContext().getHostContext() as common.UIAbilityContext).then((w: window.Window) => {
        this.mw = w;
        // ⭐ 窗口就绪后按当前播放状态补设屏幕常亮：
        //    startPlay 是异步的（先取画质再拉流），可能早于这里拿到窗口，
        //    而 onVideoStart 里那次调用会因 mw 还是 undefined 而被静默丢弃。
        this.updateKeepScreen();
        // 应用旋转模式（已继承全局锁定）
        this.applyRotationMode();
        // ⭐ 安全区必须转成 vp：getWindowAvoidArea 返回的是 px，
        //    之前直接当 vp 用，导致顶栏被推下 ~200px（横屏尤其明显）
        this.refreshSafeArea();
        // 进入直播间立即隐藏导航小白条
        try {
          w.setWindowSystemBarEnable([]);
        } catch (_e2) {}
      });
    } catch (_e) {
      // 使用默认值
    }
  }

  /** ⭐ 重新读取安全区并转 vp；旋转后必须重读，否则控件会钻到刘海/导航条下 */
  private refreshSafeArea(): void {
    if (!this.mw) { return; }
    try {
      const sys: window.AvoidArea = this.mw.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav: window.AvoidArea = this.mw.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const ui = this.getUIContext();
      // ⚠️ 沉浸式切换瞬间 avoid area 可能为 0；不要用 0 覆盖已有的有效值，
      //    否则顶栏会钻到状态栏下面（竖屏实测）
      const top: number = ui.px2vp(sys.topRect.height);
      const bottom: number = ui.px2vp(nav.bottomRect.height);
      const left: number = ui.px2vp(sys.leftRect.width);
      const right: number = ui.px2vp(sys.rightRect.width);
      if (top > 0) this.safeTop = top;
      if (bottom > 0) this.safeBottom = bottom;
      if (left > 0) this.safeLeft = left;
      if (right > 0) this.safeRight = right;
      logInfo(`[LivePlayer] 安全区(vp): top=${this.safeTop.toFixed(1)} bottom=${this.safeBottom.toFixed(1)} L=${this.safeLeft.toFixed(1)} R=${this.safeRight.toFixed(1)}`);
    } catch (_e) {}
  }

  /**
   * 从API获取直播间可用画质列表，替换默认列表（只显示此直播间有的画质）
   */
  private async fetchQualityInfo(): Promise<void> {
    try {
      const info = await getRoomPlayInfo(this.roomId);
      if (info && info.qualities.length > 0) {
        // B站返回的画质排序：从高到低
        const sorted: QualityOption[] = info.qualities.map((q: QualityDescription) => ({
          qn: q.qn,
          label: q.desc
        }) as QualityOption);
        // 替换为API返回的列表（只显示此直播间有的画质）
        this.availableQualities = sorted;
        // 自动选择最高画质（列表第一项）
        if (sorted[0].qn !== this.currentQn) {
          this.currentQn = sorted[0].qn;
          logInfo(`[LivePlayer] 动态获取画质列表: ${JSON.stringify(sorted)}, 自动选择最高画质: ${sorted[0].label}(${sorted[0].qn})`);
        }
      } else {
        logWarn('[LivePlayer] API返回的画质列表为空，使用用户手动选择');
      }
    } catch (_e) {
      logWarn(`[LivePlayer] 获取画质列表失败，将由startPlay使用默认兜底画质: ${_e}`);
    }
  }

  aboutToDisappear() {
    if (this.danmakuResizeTimer !== -1) {
      clearTimeout(this.danmakuResizeTimer);
      this.danmakuResizeTimer = -1;
    }
    if (this.emoteAnimator) {
      this.emoteAnimator.cancel();
      this.emoteAnimator = null;
    }
    this.closeLiveChat();
    // ⭐ 注销系统音量变化监听
    this.unregisterVolumeListener();
    // ⭐ 结束后台媒体会话（返回即停；切后台续播由 onPageHide 处理）
    LiveViewHelper.end();
    this.releasePlayer();
    clearTimeout(this.controlsTimer);
    clearTimeout(this.retryTimer);
    clearTimeout(this.gt_);
    clearTimeout(this.dt_);
    clearTimeout(this.lt_);
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(ctx).then((w: window.Window) => {
        w.setWindowBrightness(-1);
        // ⭐ 离开直播间：释放屏幕常亮（防止"页面已销毁但常亮没关"导致一直不熄屏）
        w.setWindowKeepScreenOn(false).catch(() => {});
        // 离开时恢复导航小白条（横屏时保持状态栏隐藏）
        const isLandscape: boolean = AppStorage.get<boolean>('isLandscape') ?? false;
        const hideSb: boolean = AppStorage.get<boolean>('hideStatusBar') ?? false;
        if (isLandscape || hideSb) {
          w.setWindowSystemBarEnable(['navigation']);
        } else {
          w.setWindowSystemBarEnable(['status', 'navigation']);
        }
        // ⭐ 退出时恢复「全局旋转锁」，而不是无条件放开自动旋转
        //    （用户可能在设置里选了锁定竖屏/横屏）
        const lock: string = AppStorage.get<string>('screenOrientationLock') ?? '自动旋转';
        let restore: window.Orientation = window.Orientation.AUTO_ROTATION;
        if (lock === '锁定竖屏') { restore = window.Orientation.PORTRAIT; }
        else if (lock === '锁定横屏') { restore = window.Orientation.AUTO_ROTATION_LANDSCAPE; }
        w.setPreferredOrientation(restore).catch(() => {});
      });
    } catch (_e) {}
  }

  /** ⭐ 页面隐藏（切后台/跳转）：后台播放开启则保持播放，否则暂停 */
  onPageHide(): void {
    // 弹幕渲染暂停（WS 保持连接，回前台继续）
    this.danmakuCtl?.stop();
    // ⭐ 页面隐藏即释放屏幕常亮（切后台/跳页时屏幕应能正常锁屏）
    //    ⚠️ 必须放在下面的 return 之前，否则"播放器还没建好"时提前返回会漏掉释放
    this.mw?.setWindowKeepScreenOn(false).catch(() => {});
    if (!this.av) { return; }
    if (this.bgp) {
      logInfo('[LivePlayer] onPageHide → 后台播放模式，保持播放');
      if (!LiveViewHelper.active) { this.setupLiveView_(); }
      return;
    }
    try { this.av.pause(); } catch (_) {}
    LiveViewHelper.updatePlayState(false);
  }

  /** ⭐ 页面显示（回前台/返回）：若曾被暂停则恢复（直播无暂停按钮，避免呆住） */
  onPageShow(): void {
    if (this.danmakuOn) {
      this.danmakuCtl?.start();
    }
    try {
      if (this.av && this.av.state === 'paused') { this.av.play(); }
    } catch (_) {}
    // ⭐ 回到直播间：恢复屏幕常亮。
    //    这里必须显式补设 —— onPageHide 已经把常亮关掉了，而"后台播放"模式下
    //    播放从未中断，也就不会有 stateChange('playing') 去触发 onVideoStart。
    this.updateKeepScreen();
  }

  // ==================== 播放器逻辑（基于 media.AVPlayer） ====================

  private async startPlay(forceRefresh: boolean = false): Promise<void> {
    try {
      // 读取当前系统音量，确保手势滑块从真实音量开始
      this.readSystemVolume();
      this.isMuted = AppStorage.get<boolean>('globalMuted') ?? false;
      // 如果currentQn未设置（API获取失败等情况），使用超清兜底
      if (this.currentQn <= 0) {
        this.currentQn = 250;
      }

      // H5 房间信息（背景壁纸 + 主播头像/昵称）与房间信息并行，失败不影响播放
      getLiveRoomH5Info(this.roomId).then((h5: LiveRoomH5Info) => {
        if (h5.appBackground) {
          this.appBg = h5.appBackground;
        }
        if (h5.anchorName) {
          this.uname = h5.anchorName;
          this.updateAnchorBarW();
        }
        if (h5.anchorFace) {
          this.upFace = h5.anchorFace;
        }
      }).catch(() => {});
      const info = await getLiveRoomInfo(this.roomId);
      if (info) {
        this.title = info.title;
        this.online = info.online;
        this.uname = info.uname;
        this.roomCover = info.keyframe || info.face || ''; // 媒体封面优先 keyframe（face 现在是主播头像）
        this.upFace = info.face || '';
        if (info.liveStatus !== 1) {
          this.errorMsg = '主播未开播';
          this.loading = false;
          return;
        }
      }

      const streamResult = await getLiveStreamUrl(this.roomId, this.currentQn, forceRefresh);
      if (!streamResult || !streamResult.url) {
        this.errorMsg = '获取直播流地址失败';
        this.loading = false;
        return;
      }

      // ⭐ 起播前先拿到流分辨率，避免竖屏源被按 16:9 摆错
      if (streamResult.videoWidth && streamResult.videoHeight
        && streamResult.videoWidth > 0 && streamResult.videoHeight > 0) {
        const ar: number = streamResult.videoWidth / streamResult.videoHeight;
        if (ar > 0.2 && ar < 5) {
          this.streamAR = ar;
        }
      }

      this.loading = true;
      this.errorMsg = '';
      this.playbackStartMs = Date.now();
      this.videoSrc = streamResult.url;
      this.videoSrcVersion++;
      await this.setupAVPlayer(streamResult.url);
    } catch (e) {
      logError(`[LivePlayer] startPlay异常: ${e}`);
      this.handlePlayError();
    }
  }

  private onVideoPrepared(): void {
    this.loading = false;
    this.errorMsg = '';
    this.retryCount = 0;
    // AVPlayer 音量随系统媒体音量
  }

  /**
   * ⭐ 屏幕常亮：播放中保持屏幕不自动休眠（AVPlayer 不会自动阻止系统休眠，必须显式调用）
   *    之前直播间漏了这一步 → 播放中会跟随系统"休眠时间"自动熄屏锁屏。
   *    play=true 时开启；暂停 / 页面隐藏 / 离开页面时释放。
   *    ⚠️ this.mw 是**异步**拿到的（getSafeArea），播放状态可能先于窗口就绪 →
   *       窗口就绪后必须补调一次（见 getSafeArea），否则首次进入直播间不生效。
   */
  private updateKeepScreen(): void {
    this.mw?.setWindowKeepScreenOn(this.isPlaying).catch(() => {});
  }

  private onVideoStart(): void {
    this.loading = false;
    this.retryCount = 0;
    this.isPlaying = true;
    // ⭐ 开播 → 屏幕常亮
    this.updateKeepScreen();
    this.playbackStartMs = Date.now();
    // 初始保持控制栏可见，等用户第一次点击后再进入自动隐藏模式
    this.isControlsVisible = true;
    if (this.controlsTimer !== -1) {
      clearTimeout(this.controlsTimer);
      this.controlsTimer = -1;
    }
    // ⭐ 同步媒体会话播放状态（通知/实况窗）：否则状态停在初始"播放中"，
    //    用户点暂停实际是让已暂停的播放器再 pause（invalid operation），控制无效
    LiveViewHelper.updatePlayState(true);
  }

  private onVideoPause(): void {
    this.isPlaying = false;
    // ⭐ 暂停 → 释放屏幕常亮（用户主动暂停后允许系统正常熄屏）
    this.updateKeepScreen();
    // ⭐ 同步媒体会话播放状态为暂停
    LiveViewHelper.updatePlayState(false);
  }

  private onVideoError(): void {
    const elapsed: number = Date.now() - this.playbackStartMs;
    // 播放启动后 3s 内的 onError 通常是直播流不支持循环设置(errorCode=801)，
    // 这是非致命警告，播放器实际仍在正常渲染画面。忽略它避免 stop→retry 死循环。
    if (elapsed < 3000) {
      logWarn(`[LivePlayer] 忽略启动后${elapsed}ms内的非致命错误（直播流 loop 设置不支持）`);
      return;
    }
    logError(`[LivePlayer] AVPlayer 错误（播放${elapsed}ms后）`);
    this.releasePlayer();
    this.handlePlayError();
  }

  private handlePlayError(): void {
    // ⭐ 直播 HLS 报 404 / IO Resource Not Found 基本都是 m3u8 里**已过期的分段**。
    //    旧实现要 retryCount > 2 才作废缓存 ⇒ 前两次拿同一个坏地址重试，白等 2 秒多。
    //    现在任何播放错误都先作废流地址，第一次重试就用新地址，恢复从 ~4.2s 降到 ~1.5s。
    invalidateCachedStreamUrl(this.roomId);
    if (this.retryCount < this.maxRetries) {
      this.retryCount++;
      this.loading = true;
      this.errorMsg = '';
      // 重试超过 3 次后尝试降画质
      if (this.retryCount >= 3 && this.availableQualities.length > 0) {
        this.downgradeQuality();
      }
      const delay: number = this.retryCount === 1 ? 300 : 1000;
      if (this.retryTimer !== -1) clearTimeout(this.retryTimer);
      this.retryTimer = setTimeout(() => {
        this.retryTimer = -1;
        this.startPlay(true);
      }, delay);
    } else {
      this.retryCount = 0;
      this.loading = true;
      this.errorMsg = '';
      invalidateCachedStreamUrl(this.roomId);
      // 最大重试后降画质，防止死循环
      this.downgradeQuality();
      if (this.retryTimer !== -1) clearTimeout(this.retryTimer);
      this.retryTimer = setTimeout(() => {
        this.retryTimer = -1;
        this.startPlay(true);
      }, 2000);
    }
  }

  /** 降画质：从当前画质降到下一个更低画质 */
  private downgradeQuality(): void {
    if (this.availableQualities.length === 0) {
      return;
    }
    const currentIdx: number = this.availableQualities.findIndex((q: QualityOption) => q.qn === this.currentQn);
    if (currentIdx < this.availableQualities.length - 1) {
      const nextQn: number = this.availableQualities[currentIdx + 1].qn;
      logInfo(`[LivePlayer] 降画质: ${getLiveQualityLabel(this.currentQn)}(${this.currentQn}) → ${getLiveQualityLabel(nextQn)}(${nextQn})`);
      this.currentQn = nextQn;
      invalidateCachedStreamUrl(this.roomId);
    } else {
      logInfo(`[LivePlayer] 已是最低画质，不再降级`);
    }
  }

  /** 释放播放器资源 */
  private releasePlayer(): void {
    this.releaseAVPlayer();
    this.videoSrc = '';
  }

  private async releaseAVPlayer(): Promise<void> {
    const av = this.av;
    this.av = null;
    if (!av) { return; }
    try {
      av.off('stateChange');
      av.off('error');
      av.off('videoSizeChange');
      if (av.state !== 'released') { await av.release(); }
    } catch (_e) {}
  }

  /** ⭐ 创建 AVPlayer（HLS 主流；极端 FLV 可能不支持，交由错误重试链处理） */
  private async setupAVPlayer(url: string): Promise<void> {
    if (this.av) { await this.releaseAVPlayer(); }
    if (url.toLowerCase().includes('.flv')) {
      logWarn('[LivePlayer] 该直播流为 FLV，AVPlayer 可能不支持，仅尝试播放');
    }
    const av: media.AVPlayer = await media.createAVPlayer();
    this.av = av;
    av.on('error', (err: BusinessError) => {
      logError(`[LivePlayer] AVPlayer error: ${err?.message ?? err}`);
      this.onVideoError();
    });
    // ⭐ 真实分辨率（切流/切画质都会回调）→ 驱动视频矩形，竖屏源不再被按 16:9 处理
    av.on('videoSizeChange', (w: number, h: number) => {
      if (w > 0 && h > 0) {
        const ar: number = w / h;
        if (ar > 0.2 && ar < 5) {
          this.streamAR = ar;
          logInfo(`[LivePlayer] 视频尺寸: ${w}x${h} → AR=${ar.toFixed(3)}`);
        }
      }
    });
    av.on('stateChange', async (st: string) => {
      try {
        if (st === 'initialized') {
          const sid: string = await this.ensureSurfaceId_();
          if (sid) { av.surfaceId = sid; }
          await av.prepare();
        } else if (st === 'prepared') {
          this.onVideoPrepared();
          await av.play();
          this.setupLiveView_();
        } else if (st === 'playing') {
          this.onVideoStart();
        } else if (st === 'paused') {
          this.onVideoPause();
        }
      } catch (e) {
        logError(`[LivePlayer] AVPlayer stateChange(${st})异常: ${e}`);
      }
    });
    const src = media.createMediaSourceWithUrl(url, {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Referer': 'https://www.bilibili.com/'
    });
    await av.setMediaSource(src);
    logInfo(`[LivePlayer] AVPlayer 准备播放: ${url.substring(0, 100)}...`);
  }

  /** ⭐ 获取 XComponent 表面 id（XComponent 构建就绪前可能为空，短时重试） */
  private async ensureSurfaceId_(): Promise<string> {
    for (let i = 0; i < 5; i++) {
      const sid: string = this.xc.getXComponentSurfaceId();
      if (sid) { this.surfaceId_ = sid; return sid; }
      await new Promise<void>((r) => setTimeout(r, 30));
    }
    return this.surfaceId_;
  }

  /** ⭐ 建立媒体会话 + 后台长时任务（通知栏/锁屏控制卡） */
  private setupLiveView_(): void {
    LiveViewHelper.setControlHandlers({
      play: () => {
        try {
          const av = this.av;
          if (av && av.state !== 'playing') { av.play(); }
        } catch (_) {}
      },
      pause: () => {
        try {
          const av = this.av;
          if (av && av.state !== 'paused') { av.pause(); }
        } catch (_) {}
      },
      seek: (_t: number) => { /* 直播无进度，忽略 */ }
    });
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context;
      void LiveViewHelper.create(ctx, this.title, this.roomCover, String(this.roomId), 0, this.uname);
    } catch (_) {}
  }

  /** 切换画质 */
  private switchQuality(qn: number): void {
    this.tick(10);
    this.currentQn = qn;
    this.loading = true;
    this.errorMsg = '';
    this.showQualityPicker = false;
    this.retryCount = 0;
    this.releasePlayer();
    invalidateCachedStreamUrl(this.roomId);
    this.startPlay(true);
  }

  private goBack(): void {
    this.releasePlayer();
    this.getUIContext().getRouter().back();
  }

  private qualityGroups(): QualityOption[][] {
    const rows: QualityOption[][] = [];
    for (let i = 0; i < this.availableQualities.length; i += 2) {
      rows.push(this.availableQualities.slice(i, i + 2));
    }
    return rows;
  }

  private setBackgroundPlayback(on: boolean): void {
    if (this.bgp === on) { return; }
    this.tick(10);
    this.bgp = on;
    AppStorage.set<boolean>('bgp', on);
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      preferences.getPreferences(ctx, 'my_app_settings').then((pref) => {
        pref.put('bgp', on);
        pref.flush();
      });
    } catch (e) {
      logError('[LivePlayer] bgp 持久化保存失败', e);
    }
    this.showBottomHintTemporarily(
      on ? '后台播放已开启' : '后台播放已关闭',
      $r('app.media.headphones_fill')
    );
    // ⭐ 接入媒体会话：开启→建会话（在播时）；关闭→结束会话并暂停（若在后台）
    if (on) {
      if (this.av && (this.av.state === 'playing' || this.av.state === 'prepared')) {
        this.setupLiveView_();
      }
    } else {
      LiveViewHelper.end();
      const appBg: boolean = AppStorage.get<boolean>('appInBackground') ?? false;
      if (appBg && this.av && this.av.state === 'playing') {
        try { this.av.pause(); } catch (_) {}
      }
    }
    this.showControlsTemporarily();
  }

  // ==================== 选项菜单 ====================

  private openQualityPicker(): void {
    this.tick(10);
    this.showQualityPicker = true;
    this.holdControls();
  }

  /** ⭐ 菜单打开期间冻结自动隐藏计时器，否则 4s 后控制层会连同菜单背景一起消失 */
  private holdControls(): void {
    if (this.controlsTimer !== -1) {
      clearTimeout(this.controlsTimer);
      this.controlsTimer = -1;
    }
    this.isControlsVisible = true;
  }

  /**
   * ⚠️ 项目里这两个 SVG 的**文件名与图形相反**（实测）：
   *    ic_public_lock.svg   → 画的是「开锁」
   *    ic_public_unlock.svg → 画的是「闭锁」
   * 所以 auto（不锁）用 lock 文件，锁定态用 unlock 文件。
   */
  private rotationLockIcon(): Resource {
    return this.rotationMode === 'auto'
      ? $r('app.media.ic_public_lock')
      : $r('app.media.ic_public_unlock');
  }

  /**
   * ⭐ 底部手势区（即使导航条已隐藏）会吞掉贴底约 35~40vp 内的点击：
   *    实测 y=1240px 的暂停按钮点不动，抬到 y=1205px 就正常。
   *    所以 Dock 必须离屏幕底部至少 40vp。
   */
  private dockBottomPad(): number {
    return 12;
  }

  private qualityMenuX(): number {
    return Math.max(8, this.winW - 12 - 216);
  }

  /** 画质胶囊在顶栏右侧，菜单直接从顶栏下方展开 */
  private qualityMenuY(): number {
    return Math.max(8, this.safeTop + 52 + 4);
  }

  private showControlsTemporarily(): void {
    this.isControlsVisible = true;
    if (this.controlsTimer !== -1) clearTimeout(this.controlsTimer);
    this.controlsTimer = setTimeout(() => {
      if (!this.showQualityPicker) {
        // ⭐ 显隐是 opacity 状态变化，不是挂载/卸载，transition 不会触发；
        //    用 animateTo 包裹状态变更，控制栏才有淡出动画
        this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
          this.isControlsVisible = false;
        });
      }
    }, 10000);
  }

  private showBottomHintTemporarily(txt: string, img?: ResourceStr): void {
    this.bottomHintText = txt;
    this.bottomHintImage = img;
    this.showBottomHint = true;
    setTimeout(() => { this.showBottomHint = false; }, 2000);
  }

  private setSystemVolume(vol: number): void {
    // 设置系统媒体音量：档位范围动态获取，不硬编码 15（设备档位不同会导致实际音量偏小）
    try {
      const v: number = Math.round(vol * this.maxVol_);
      audio.getAudioManager().setVolume(audio.AudioVolumeType.MEDIA, v);
    } catch (_e) {}
  }

  private async readSystemVolume(): Promise<void> {
    try {
      const mgr = audio.getAudioManager().getVolumeManager();
      const maxVol: number = mgr.getMaxVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
      this.maxVol_ = maxVol > 0 ? maxVol : 15;
      const sysVol: number = mgr.getVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
      this.vol = maxVol > 0 ? Math.min(1, Math.max(0, sysVol / maxVol)) : 0.7;
      this.sv = this.vol;
      AppStorage.setOrCreate('globalVolume', this.vol);
    } catch (_e) {
      this.vol = AppStorage.get<number>('globalVolume') ?? 0.7;
    }
  }

  /** ⭐ 注册系统音量变化监听（音量键调节时同步 app 内滑块/手势起点） */
  private registerVolumeListener(): void {
    try {
      const mgr = audio.getAudioManager().getVolumeManager();
      this.volMgr_ = mgr;
      if (this.volListening_) return;
      // 注：本机 SDK 中 streamVolumeChange 的签名与官方文档示例不一致，改用编译确认存在的 volumeChange
      mgr.on('volumeChange', (ev: audio.VolumeEvent) => {
        // 不依赖事件字段（避免版本差异），直接重读系统音量同步 UI
        try {
          if (this.maxVol_ > 0 && this.gm_ !== 'volume') {
            // ⭐ 音量滑动手势进行中不重读/重置基准 sv：否则每次 move 都用总位移 dy 从已调整的基准叠加，
            //    越滑越快（轻滑即满/0）。手势由 onTM 的 sv+dy 全权控制；手势外（音量键/结束）才同步
            const sysVol: number = this.volMgr_?.getVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC) ?? 0;
            this.vol = Math.min(1, Math.max(0, sysVol / this.maxVol_));
            this.sv = this.vol;
            AppStorage.setOrCreate('globalVolume', this.vol);
          }
        } catch (_e2) {}
      });
      this.volListening_ = true;
    } catch (_e) {}
  }

  /** ⭐ 注销系统音量变化监听 */
  private unregisterVolumeListener(): void {
    try {
      if (this.volMgr_ && this.volListening_) {
        this.volMgr_.off('volumeChange');
        this.volListening_ = false;
      }
    } catch (_e) {}
  }

  // ==================== 手势系统（onVT 风格） ====================

  // ── 卡片样式辅助 ──
  private opacityToHexAlpha(opacity: number): string {
    const clamped = Math.max(0, Math.min(100, opacity));
    const hex = Math.round(clamped / 100 * 255).toString(16).toUpperCase();
    return hex.length < 2 ? '0' + hex : hex;
  }

  private sGH(txt: string, progress: number = -1, type: string = ''): void {
    this.gestureHintMainText = txt;
    this.showGestureHint = true;
    this.gestureHintProgress = progress;
    this.gestureHintType = type;
    if (this.gt_ !== -1) clearTimeout(this.gt_);
    this.gt_ = setTimeout(() => {
      this.showGestureHint = false;
      this.gt_ = -1;
    }, 1500);
  }

  private triggerHaptic(): void {
    VibrateUtils.vibratePreset('haptic.notification.trigger');
  }

  /** 轻触反馈（10ms）：按钮点按、面板开合这类高频操作用 */
  private tick(ms: number = 10): void {
    try {
      VibrateUtils.vibrateTime(ms);
    } catch (_e) {}
  }

  private fireHaptic(duration: number): void {
    VibrateUtils.vibrateTime(duration);
  }

  private onVT = (e: TouchEvent) => {
    switch (e.type) {
      case TouchType.Down:
        this.onTD(e);
        break;
      case TouchType.Move:
        this.onTM(e);
        break;
      case TouchType.Up:
        this.onTU(e);
        break;
      case TouchType.Cancel:
        this.onTC();
        break;
    }
  }

  private onTD(e: TouchEvent): void {
    logInfo(`[LivePlayer] onTD: type=${e.type} pos=(${e.touches[0].windowX.toFixed(0)},${e.touches[0].windowY.toFixed(0)})`);
    const t = e.touches[0];
    this.sx_ = t.windowX;
    this.sy_ = t.windowY;
    // 聊天区（列表/输入框）内的触摸不参与亮度/音量手势
    this.gestureBlocked_ = this.isInChatArea(t.windowX, t.windowY);
    this.sv = this.vol;
    this.sb = this.bri;
    this.ml_ = false;
    this.la_ = false;
    this.dtp_ = false;

    // 长按定时器
    this.lt_ = setTimeout(() => {
      if (!this.ml_) {
        this.la_ = true;
      }
    }, 500);
  }

  private onTM(e: TouchEvent): void {
    if (e.touches.length === 0 || this.gestureBlocked_) return;
    const t = e.touches[0];
    const dx = t.windowX - this.sx_;
    const dy = this.sy_ - t.windowY;
    const adx = Math.abs(dx);
    const ady = Math.abs(dy);
    if (adx > 10 || ady > 10) {
      this.ml_ = true;
      if (this.lt_ !== -1) { clearTimeout(this.lt_); this.lt_ = -1; }
    }
    if (this.la_) return;
    if (this.gm_ === '') {
      if (adx > 25 || ady > 25) {
        if (ady > adx) {
          // 垂直滑动：**按视频区域**左右对半分（左=亮度，右=音量）。
          // ⚠️ 不能用 winW/2：横屏分栏时视频区只到 winW-chatPanelW，
          //    按屏宽切会让音量区只剩 100 多 vp（用户实测"音量区域太小"）。
          const area: VideoRect = this.videoAreaRect();
          const splitX: number = area.x + area.w / 2;
          if (t.windowX < splitX) {
            this.gm_ = 'brightness';
          } else {
            this.gm_ = 'volume';
          }
        }
      }
    }
    if (this.gm_ === 'volume') {
      const volSensitivity: number = 400;
      let v = this.sv + dy / volSensitivity;
      v = Math.min(1, Math.max(0, v));
      this.vol = v;
      AppStorage.setOrCreate('globalVolume', v);
      this.setSystemVolume(v);
      this.sGH(`${Math.round(v * 100)}%`, v, 'volume');
      const volPct = Math.round(v * 100);
      if (this.lastHapticPct_ === -1 || Math.abs(volPct - this.lastHapticPct_) >= 10) {
        this.fireHaptic(12);
        this.lastHapticPct_ = volPct;
      }
    } else if (this.gm_ === 'brightness') {
      const briSensitivity: number = 400;
      let b = this.sb + dy / briSensitivity;
      b = Math.min(1, Math.max(0, b));
      this.bri = b;
      window.getLastWindow(this.getUIContext().getHostContext() as common.UIAbilityContext).then((w: window.Window) => {
        w.setWindowBrightness(b);
      });
      this.sGH(`${Math.round(b * 100)}%`, b, 'brightness');
      const briPct = Math.round(b * 100);
      if (this.lastHapticPct_ === -1 || Math.abs(briPct - this.lastHapticPct_) >= 10) {
        this.fireHaptic(12);
        this.lastHapticPct_ = briPct;
      }
    }
  }

  private onTU(e: TouchEvent): void {
    const wasLongPress = this.la_;
    const wasMoved = this.ml_;

    if (this.lt_ !== -1) { clearTimeout(this.lt_); this.lt_ = -1; }
    this.la_ = false;

    // 单击切换控制栏显隐：只在「视频显示区」内生效，聊天区不响应
    // ⚠️ 点击判定用 24vp（手势判定从 25vp 才启动）；原先用 10vp 会留下
    //    10~25vp 的死区 —— 手指轻点带一点位移就什么都不触发（真机实测）
    const u = e.touches.length > 0 ? e.touches[0] : null;
    const ux: number = u ? u.windowX : this.sx_;
    const uy: number = u ? u.windowY : this.sy_;
    const movedFar: boolean = Math.abs(ux - this.sx_) > 24 || Math.abs(uy - this.sy_) > 24;
    // ⚠️ 判定用「视频区域」而不是「视频显示矩形」：
    //    竖屏看 9:16 流时显示矩形只有屏宽的一小条，用显示矩形会让两侧黑边全部点不动
    //    （真机反馈「竖屏手势有问题」就是这个）；黑边同样属于视频区，点击应能呼出控制栏。
    // ⚠️ 不再叠加「矩形判定」：触摸能走到这一层，本身就已经不在聊天面板内
    //    （聊天栏 zIndex 更高，会先消费）。之前用 videoAreaRect 二次判定，
    //    只要 winW/winH 或安全区有一帧是旧的，点击就会被判到区外 → 「点了没反应」。
    if (!this.dtp_ && !movedFar && !wasLongPress && !this.gestureBlocked_ && this.gm_ === '') {
      this.isControlsVisible = !this.isControlsVisible;
      if (this.isControlsVisible) {
        this.showControlsTemporarily();
      } else {
        // 手动隐藏时清除自动隐藏计时器
        if (this.controlsTimer !== -1) {
          clearTimeout(this.controlsTimer);
          this.controlsTimer = -1;
        }
      }
    }
    this.gm_ = '';
    this.ml_ = false;
    this.gestureBlocked_ = false;
  }

  private onTC(): void {
    if (this.lt_ !== -1) { clearTimeout(this.lt_); this.lt_ = -1; }
    this.la_ = false;
    this.gm_ = '';
    this.ml_ = false;
    this.gestureBlocked_ = false;
  }

  // ==================== 屏幕旋转控制 ====================

  /** 切换旋转模式：自动旋转 ↔ 锁定当前方向 */
  private toggleRotation(): void {
    this.tick(12);
    if (this.rotationMode === 'auto') {
      // 锁定到当前物理方向
      this.rotationMode = this.isWindowLandscape() ? 'landscape' : 'portrait';
    } else {
      // 恢复自动旋转
      this.rotationMode = 'auto';
    }
    this.applyRotationMode();
    // Toast 提示
    const modeText: string = this.rotationMode === 'auto' ? '自动旋转' : '锁定方向';
    try {
      this.getUIContext().getPromptAction().showToast({ message: modeText, duration: 1500 });
    } catch (_e) {}
    // 触觉反馈
    try {
      VibrateUtils.vibratePreset('haptic.notification.trigger');
    } catch (_e) {}
  }

  /** 应用当前旋转模式到窗口 */
  private async applyRotationMode(): Promise<void> {
    if (!this.mw) return;
    try {
      let orientation: window.Orientation;
      if (this.rotationMode === 'auto') {
        orientation = window.Orientation.AUTO_ROTATION;
      } else if (this.rotationMode === 'portrait') {
        orientation = window.Orientation.PORTRAIT;
      } else {
        // ⭐ 用 AUTO_ROTATION_LANDSCAPE 而不是 LANDSCAPE：
        //    锁定横屏后仍允许在「左横/右横」两个方向间随重力翻转
        orientation = window.Orientation.AUTO_ROTATION_LANDSCAPE;
      }
      await this.mw.setPreferredOrientation(orientation);
    } catch (_e) {
      logError(`[LivePlayer] 旋转模式应用失败: ${_e}`);
    }
  }

  /** 获取旋转模式图标 */
  private getRotationIcon(): Resource {
    switch (this.rotationMode) {
      case 'portrait':
        return $r('app.media.rectangle_portrait_rotate');
      case 'landscape':
        return $r('app.media.rectangle_rotate');
      case 'auto':
      default:
        return $r('app.media.arrow_counterclockwise');
    }
  }

  // ==================== 直播弹幕 / 聊天 ====================

  private initLiveChat(): void {
    if (this.roomId <= 0) {
      return;
    }
    if (!this.danmakuCtl) {
      this.danmakuCtl = new LiveDanmakuController();
      this.danmakuCtl.setEnabled(this.danmakuOn);
    }
    if (!this.danmakuClient) {
      const client = new LiveDanmakuClient();
      this.danmakuClient = client;
      client.connect(
        this.roomId,
        (msg: LiveMessage) => this.onLiveMessage(msg),
        (online: number) => {
          if (online > 0) {
            this.online = online;
          }
        },
        (state: string) => {
          this.wsState = state;
        }
      ).catch((e: Error) => {
        logError(`[LivePlayer] 弹幕连接失败: ${e}`);
      });
    }
  }

  private closeLiveChat(): void {
    if (this.danmakuClient) {
      this.danmakuClient.close();
      this.danmakuClient = null;
    }
    if (this.danmakuCtl) {
      this.danmakuCtl.destroy();
      this.danmakuCtl = null;
    }
    this.liveMessages = [];
  }

  private onLiveMessage(msg: LiveMessage): void {
    if (msg.type === LiveMsgType.DANMAKU && this.danmakuOn) {
      this.danmakuCtl?.push(msg);
    }
    const next: LiveMessage[] = this.liveMessages.slice();
    next.push(msg);
    // 只保留最近 25 条（原来 100 行全部参与布局，Scroll+Column 非懒加载时开销明显）。
    // 仍按批裁剪：攒到 35 条再一次性丢到 25，避免到上限后每条新消息都动一次数组。
    if (next.length > 35) {
      next.splice(0, next.length - 25);
    }
    this.liveMessages = next;
    this.scrollChatToBottom();
  }

  private scrollChatToBottom(): void {
    setTimeout(() => {
      try {
        this.chatScroller.scrollEdge(Edge.Bottom);
      } catch (_e) {}
    }, 40);
  }

  private toggleDanmaku(): void {
    this.tick(10);
    this.danmakuOn = !this.danmakuOn;
    if (this.danmakuCtl) {
      this.danmakuCtl.setEnabled(this.danmakuOn);
    }
    if (this.danmakuOn) {
      this.danmakuCtl?.start();
    }
    this.showBottomHintTemporarily(this.danmakuOn ? '弹幕已开启' : '弹幕已关闭');
    this.showControlsTemporarily();
  }

  /** 进/出全屏的唯一入口：切状态 + 按视频比例转屏 / 退出时恢复旋转策略 */
  private setFullscreen(on: boolean): void {
    if (this.fsMode === on) {
      return;
    }
    // 视频区域/圆角/内边距都从 fsMode 派生，一次 animateTo 全部补间（~300ms 弹簧）
    this.getUIContext().animateTo({
      duration: 300,
      curve: curves.springMotion(0.42, 0.9)
    }, () => {
      this.fsMode = on;
    });
    this.applyFullscreenOrientation();
    this.isControlsVisible = true;
    this.showControlsTemporarily();
  }

  private toggleFullscreen(): void {
    this.tick(12);
    this.setFullscreen(!this.fsMode);
  }

  /**
   * 全屏按视频比例转屏（B 站行为）：
   *  - 横流（ar >= 1）→ 全屏横屏；竖流 → 全屏竖屏；
   *  - 用户手动锁过方向时不强制转向，以锁定为准；
   *  - 退出全屏恢复 rotationMode（自动/锁定）。
   */
  private async applyFullscreenOrientation(): Promise<void> {
    if (!this.mw) {
      return;
    }
    try {
      if (this.rotationMode !== 'auto' || !this.fsMode) {
        await this.applyRotationMode();
        return;
      }
      const ar: number = this.streamAR > 0 ? this.streamAR : 16 / 9;
      const orientation: window.Orientation = ar >= 1
        ? window.Orientation.AUTO_ROTATION_LANDSCAPE
        : window.Orientation.PORTRAIT;
      await this.mw.setPreferredOrientation(orientation);
      logInfo(`[LivePlayer] 全屏按视频比例转屏: ar=${ar.toFixed(2)} → ${ar >= 1 ? '横屏' : '竖屏'}`);
    } catch (_e) {
      logError(`[LivePlayer] 全屏转屏失败: ${_e}`);
    }
  }

  private toggleChat(): void {
    if (this.isLandscape && this.fsMode) {
      // 全屏状态点聊天：退出全屏并恢复分栏
      this.setFullscreen(false);
      this.chatOpen = true;
    } else {
      this.chatOpen = !this.chatOpen;
    }
    if (this.chatOpen) {
      this.scrollChatToBottom();
    }
    this.showControlsTemporarily();
  }

  private onDanmakuReady(): void {
    if (!this.danmakuCtl) {
      return;
    }
    this.danmakuCtl.setContext(this.danmakuCtx);
    const w: number = this.danmakuCtx.width;
    const h: number = this.danmakuCtx.height;
    if (w > 0 && h > 0) {
      this.danmakuCtl.setSize(w, h);
    } else {
      const r: VideoRect = this.danmakuRect();
      this.danmakuCtl.setSize(r.w, r.h);
    }
    if (this.danmakuOn) {
      this.danmakuCtl.start();
    }
  }

  /** 富文本 → 发送文本：文字直取，图片还原成 [xx] */
  private chatContentText(): string {
    let content: string = '';
    let spans: RichEditorSpan[] = [];
    try {
      spans = this.chatInputCtl.getSpans();
    } catch (_e) {
      return '';
    }
    for (let i = 0; i < spans.length; i++) {
      const span = spans[i];
      const textSpan = span as RichEditorTextSpanResult;
      if (textSpan.value) {
        content += textSpan.value;
      } else {
        const imgSpan = span as RichEditorImageSpanResult;
        content += ChatEmote.getTextByUrl(imgSpan.valueResourceStr as string) || '';
      }
    }
    return content;
  }

  /** 清空富文本输入框 */
  private clearChatInput(): void {
    try {
      const caret: number = this.chatInputCtl.getCaretOffset();
      if (caret > 0) {
        this.chatInputCtl.deleteSpans({ start: 0, end: caret });
      }
      this.chatInputCtl.setCaretOffset(0);
    } catch (_e) {}
    this.chatInput = '';
    this.chatHasContent = false;
  }

  /** 插入表情图片 */
  private insertChatEmote(emote: ChatEmoteItem): void {
    try {
      this.chatInputCtl.addImageSpan(emote.url, {
        offset: this.chatInputCtl.getCaretOffset(),
        imageStyle: { size: [22, 22] }
      });
    } catch (_e) {}
    this.chatHasContent = true;
  }

  private async sendChat(): Promise<void> {
    const text: string = this.chatContentText().trim();
    if (!text || this.chatSending) {
      return;
    }
    if (Date.now() < this.sendCooldownUntil) {
      this.showToast('发送太快，稍后再试');
      return;
    }
    const cookie: string = AppStorage.get<string>('biliCookie') ?? '';
    if (!extractSessdataFromCookie(cookie)) {
      this.showToast('请先登录后再发送');
      return;
    }
    this.chatSending = true;
    try {
      const res = await sendLiveDanmaku(this.roomId, text);
      if (res.ok) {
        this.triggerHaptic();
        this.clearChatInput();
        this.sendCooldownUntil = Date.now() + 2000;
        const msg = new LiveMessage(LiveMsgType.DANMAKU);
        msg.uname = '我';
        msg.text = text;
        msg.self = true;
        this.onLiveMessage(msg);
        try {
          this.getUIContext().getFocusController().clearFocus();
        } catch (_e) {}
      } else {
        this.showToast(res.message || '发送失败');
      }
    } finally {
      this.chatSending = false;
    }
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 1500 });
    } catch (_e) {}
  }

  // ==================== build ====================

  /** 顶栏：返回 + LIVE/在线 + 标题（横竖屏共用，安全区已转 vp） */
  @Builder
  buildTopBar() {
    Row({ space: 2 }) {
      // 返回：沉浸光感圆钮（与右侧胶囊同高：40 玻璃 + 1cp = 44 容器，保证在同一水平线）
      Stack({ alignContent: Alignment.Center }) {
        HdsGlassBar({
          barWidth: 44,
          barHeight: 44,
          contentPadding: 1,
          barBottomMargin: 1,
          hitThrough: true,
          lightColor: this.customThemeColor
        })
        Row() {
          Image($r('app.media.return_453'))
            .width(20).height(20)
            .fillColor('#FFFFFF')
        }
        .width(44).height(44)
        .justifyContent(FlexAlign.Center)
        .borderRadius(22)
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => this.goBack())
      }

      // 主播头像 + 名称（沉浸光感胶囊：玻璃由 HdsTabs 系统材质绘制，内容叠在上面）
      Stack({ alignContent: Alignment.Center }) {
        HdsGlassBar({
          barWidth: this.anchorBarW,
          barHeight: 44,
          contentPadding: 1,
          barBottomMargin: 1,
          hitThrough: true,
          lightColor: this.customThemeColor
        })
        Row({ space: 7 }) {
          if (this.upFace) {
            Image(this.upFace)
              .width(28).height(28)
              .borderRadius(14)
              .objectFit(ImageFit.Cover)
          } else {
            Circle().width(28).height(28).fill('rgba(255,255,255,0.18)')
          }
          Text(this.uname || '主播')
            .fontSize(13)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 170 })
        }
        .width(this.anchorBarW)
        .height(44)
        .padding({ left: 5, right: 14 })
        .alignItems(VerticalAlign.Center)
      }

      Blank()

      // 右上：画质 + 后台播放（沉浸光感胶囊）
      Stack({ alignContent: Alignment.Center }) {
        HdsGlassBar({
          barWidth: 76,
          barHeight: 44,
          contentPadding: 1,
          barBottomMargin: 1,
          hitThrough: true,
          lightColor: this.customThemeColor
        })
        Row() {
          this.dockQualityBtn()
          this.bgpBtn()
        }
        .width(76)
        .height(44)
        .padding({ left: 4, right: 4 })
        .alignItems(VerticalAlign.Center)
      }
      .margin({ right: this.chatSplitInset() })
    }
    .width('100%')
    .height(this.topBarPad() + 48)
    .padding({ left: 10, right: 10, top: this.topBarPad() })
    .alignItems(VerticalAlign.Center)
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [['rgba(0,0,0,0.55)', 0.0], ['rgba(0,0,0,0)', 1.0]]
    })
    .position({ x: 0, y: 0 })
    // 出现时自上而下落位、收起时向上移出（位移交给 transition，这里不再用 translate 叠加）
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: -10 }))
        .animation({ duration: 220, curve: Curve.EaseOut }),
      TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ y: -10 }))
        .animation({ duration: 160, curve: Curve.EaseIn })
    ))
  }

  /** Dock 图标按钮（方案 B 的基础单元） */
  @Builder
  dockIconBtn(icon: Resource, highlighted: boolean, onTap: () => void) {
    Row() {
      Image(icon)
        .width(18).height(18)
        .fillColor(highlighted ? this.customThemeColor : '#FFFFFF')
    }
    .width(34).height(34)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(highlighted ? 'rgba(255,255,255,0.18)' : '#00000000')
    .borderRadius(17)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .hitTestBehavior(HitTestMode.Block)
    .onClick(onTap)
  }

  /**
   * ⚠️ @Builder 的参数是**按值传递**：把 this.isPlaying / this.ratioLabel() 当参数传进来，
   *    状态变化后按钮不会更新（实测 Dock 的「适应」会一直停在首帧）。
   *    所以动态按钮一律做成无参 Builder，直接在内部读状态。
   */
  @Builder
  dockPlayBtn() {
    Row() {
      Image(this.isPlaying ? $r('app.media.ic_public_pause') : $r('app.media.ic_public_play'))
        .width(18).height(18).fillColor('#FFFFFF')
    }
    .width(34).height(34)
    .justifyContent(FlexAlign.Center)
    .borderRadius(17)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => this.togglePlayPause())
  }

  @Builder
  dockRatioBtn() {
    Row() {
      Image($r('app.media.chicun')).width(18).height(18).fillColor('#FFFFFF')
    }
    .width(34)
    .height(34)
    .justifyContent(FlexAlign.Center)
    .borderRadius(17)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => this.cycleAspectRatio())
  }

  @Builder
  dockQualityBtn() {
    Row() {
      Image($r('app.media.hd_24px_rounded')).width(18).height(18).fillColor('#FFFFFF')
    }
    .width(34)
    .height(34)
    .justifyContent(FlexAlign.Center)
    .borderRadius(17)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => this.openQualityPicker())
  }

  /** 旋转锁定：表面按钮（自由 ↔ 锁定），竖横屏共用；只显示图标 */
  @Builder
  lockBtn() {
    Row() {
      Image(this.rotationLockIcon())
        .width(18).height(18)
        .fillColor('#FFFFFF')
    }
    .width(34)
    .height(34)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.rotationMode === 'auto' ? '#00000000' : 'rgba(255,255,255,0.18)')
    .borderRadius(17)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => this.toggleRotation())
  }

  /** 后台播放：右上角胶囊里的开关态按钮；只显示图标 */
  @Builder
  bgpBtn() {
    Row() {
      Image($r('app.media.headphones_fill'))
        .width(18).height(18)
        .fillColor(this.bgp ? '#FFFFFF' : 'rgba(255,255,255,0.3)')
    }
    .width(34)
    .height(34)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#00000000')
    .borderRadius(17)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => this.setBackgroundPlayback(!this.bgp))
  }

  /** 横屏：左右两个胶囊（中间留空，露出更多画面） */
  @Builder
  buildLandscapeDock() {
    Row() {
      // 左胶囊：播放 / 刷新 / 弹幕（沉浸光感玻璃）
      Stack({ alignContent: Alignment.Center }) {
        HdsGlassBar({
          barWidth: 110,
          barHeight: 44,
          contentPadding: 1,
          barBottomMargin: 1,
          hitThrough: true,
          lightColor: this.customThemeColor
        })
        Row() {
          this.dockPlayBtn()
          this.dockIconBtn($r('app.media.StreamlinePlumpRotateLeftSolid'), false, () => this.resetLive())
          this.danmakuBtn()
        }
        .width(110)
        .height(44)
        .padding({ left: 4, right: 4 })
        .alignItems(VerticalAlign.Center)
      }

      Blank()

      // 右胶囊：比例 / 旋转锁定 / 全屏（沉浸光感玻璃）
      Stack({ alignContent: Alignment.Center }) {
        HdsGlassBar({
          barWidth: 110,
          barHeight: 44,
          contentPadding: 1,
          barBottomMargin: 1,
          hitThrough: true,
          lightColor: this.customThemeColor
        })
        Row() {
          this.dockRatioBtn()
          this.lockBtn()
          this.fsBtn()
        }
        .width(110)
        .height(44)
        .padding({ left: 4, right: 4 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 10, right: 10 + this.chatSplitInset() })
    .alignItems(VerticalAlign.Center)
    .position({ x: 0, y: this.winH - 48 - this.dockBottomPad() })
  }

  /** 竖屏：选项压到视频显示区四角（方案 B 竖屏落位） */
  @Builder
  buildPortraitControls() {
    // ⚠️ 不用 Stack + align：实测该组合在本页不生效，三个控件会全堆到视频中心。
    //    改用 Column + Blank 的常规流式布局，位置只由 padding / Blank 决定。
    Column() {
      Blank()

      // 底部：播放/刷新在左，比例/旋转锁在右
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          HdsGlassBar({
            barWidth: 114,
            barHeight: 44,
            contentPadding: 1,
            barBottomMargin: 1,
            hitThrough: true,
            lightColor: this.customThemeColor
          })
          Row({ space: 2 }) {
            this.dockPlayBtn()
            this.dockIconBtn($r('app.media.StreamlinePlumpRotateLeftSolid'), false, () => this.resetLive())
            this.danmakuBtn()
          }
          .width(114)
          .height(44)
          .padding(4)
          .alignItems(VerticalAlign.Center)
        }

        Blank()

        Stack({ alignContent: Alignment.Center }) {
          HdsGlassBar({
            barWidth: 114,
            barHeight: 44,
            contentPadding: 1,
            barBottomMargin: 1,
            hitThrough: true,
            lightColor: this.customThemeColor
          })
          Row({ space: 2 }) {
            this.dockRatioBtn()
            this.lockBtn()
            this.fsBtn()
          }
          .width(114)
          .height(44)
          .padding(4)
          .alignItems(VerticalAlign.Center)
        }
      }
      // 玻璃比容器内缩 2vp：容器加宽 4 并左移 2，让两枚胶囊的**玻璃边**落到 12 / winW-12，
      // 与视频区、评论区、输入胶囊同一条竖线
      .width(this.videoAreaRect().w + 4)
      .translate({ x: -2 })
      .alignItems(VerticalAlign.Bottom)
      }
    .width('100%')
    .height('100%')
    .padding({ left: 0, right: 0, bottom: 0 })
    // ⚠️ 必须是 Start：Column 默认水平居中，会把"加宽 4vp 的行"居中溢出，
    //    再叠加 translate(-2) 就变成左边 10 / 右边 12（用户反馈左右边距不一致）
    .alignItems(HorizontalAlign.Start)
    // ⚠️ 用「视频区域」整宽，不用 videoOverlayRect()：
    //    竖屏看 9:16 流时显示矩形只有 243vp 宽，而左右两颗胶囊合计约 272vp，
    //    塞进去会互相重叠（真机反馈「竖屏控制栏位置有问题」）。黑边也属于视频区。
    .position({ x: this.videoAreaRect().x, y: this.videoAreaRect().y })
    .width(this.videoAreaRect().w)
    .height(this.videoAreaRect().h)
  }

  // ==================== 直播聊天 UI ====================

  @Builder
  danmakuBtn() {
    Row() {
      Image($r('app.media.chat_bubble_text_square_solid'))
        .width(18).height(18)
        .fillColor(this.danmakuOn ? '#FFFFFF' : 'rgba(255,255,255,0.3)')
    }
    .width(34)
    .height(34)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#00000000')
    .borderRadius(17)
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => this.toggleDanmaku())
  }

  @Builder
  chatBtn() {
    Row() {
      Image($r('app.media.message_on_message'))
        .width(18).height(18)
        .fillColor('#FFFFFF')
    }
    .width(34)
    .height(34)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.chatOpen ? 'rgba(255,255,255,0.18)' : '#00000000')
    .borderRadius(17)
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => this.toggleChat())
  }

  @Builder
  fsBtn() {
    Row() {
      Image(this.fsMode ? $r('app.media.reduce_31') : $r('app.media.full_screen_32'))
        .width(17).height(17).fillColor('#FFFFFF')
    }
    .width(34).height(34)
    .justifyContent(FlexAlign.Center)
    .borderRadius(17)
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => this.toggleFullscreen())
  }

  @Builder
  chatRow(m: LiveMessage) {
    if (m.type === LiveMsgType.GIFT) {
      Text(m.text)
        .fontSize(13)
        .fontColor('#FFC98A')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    } else if (m.type === LiveMsgType.SUPER_CHAT) {
      Column({ space: 3 }) {
        Text(`SC ¥${m.price} · ${m.uname}`)
          .fontSize(10)
          .fontColor('#FF9B6A')
        Text(m.text)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding(8)
      .backgroundColor('rgba(255,122,69,0.12)')
      .border({ width: { left: 3 }, color: '#FF7A45' })
      .borderRadius(6)
      .alignItems(HorizontalAlign.Start)
    } else if (m.type === LiveMsgType.SYSTEM) {
      Text(m.text)
        .fontSize(12)
        .fontColor('rgba(255,255,255,0.45)')
        .maxLines(2)
        .width('100%')
    } else {
      Row({ space: 4 }) {
        if (m.medalName) {
          Text(m.medalName)
            .fontSize(10.5)
            .fontColor('#FF6699')
            .maxLines(1)
            .padding({ left: 4, right: 4 })
            .border({ width: 1, color: 'rgba(255,102,153,0.35)' })
            .borderRadius(3)
        }
        Text() {
          Span(`${m.uname}：`).fontColor('#FF8CAE')
          // ⭐ [喝彩] / [大哭] / [doge] 这类表情标记还原成表情图（与私信/评论同一套表情表）
          ForEach(ChatEmote.parse(m.text), (seg: ChatTextSegment, index: number) => {
            if (seg.emoteUrl) {
              ImageSpan(seg.emoteUrl)
                .width(20)
                .height(20)
                .objectFit(ImageFit.Contain)
                .verticalAlign(ImageSpanAlignment.CENTER)
            } else {
              Span(seg.text).fontColor(m.self ? '#FFB3CC' : '#FFFFFF')
            }
          }, (seg: ChatTextSegment, index: number) => `seg_${index}_${seg.emoteUrl ? 1 : 0}`)
        }
        .fontSize(14)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textShadow({ radius: 2, color: 'rgba(0,0,0,0.55)', offsetX: 0, offsetY: 1 })
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
  }

  /**
   * 聊天列表（竖屏 / 横屏共用）
   * 高度由父容器决定；横屏底部要多留一截，避免最后几条被悬浮输入框压住。
   */
  @Builder
  chatList() {
    Scroll(this.chatScroller) {
      Column({ space: 6 }) {
        ForEach(this.liveMessages, (m: LiveMessage, index: number) => {
          this.chatRow(m)
        }, (m: LiveMessage, index: number) => `${m.seq}_${this.emoteReady ? 1 : 0}`)
      }
      .width('100%')
      // ⚠️ 必须占满视口：消息少时 scrollEdge(Edge.Bottom) 会把内容整体下推
      //    （未满屏时对齐"内容底 → 视口底"），表现为列表悬在面板中间、上下各一大片空白。
      .constraintSize({ minHeight: '100%' })
      .padding({ left: 12, right: 12, top: 8, bottom: this.isLandscape ? 78 : 76 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  /**
   * 输入胶囊：输入框 + 发送按钮**一起**包进同一颗沉浸光感材质里（横竖屏共用）。
   * h 为胶囊高度，圆角取 h/2。
   */
  @Builder
  chatInputCapsule(h: number) {
    Stack({ alignContent: Alignment.Center }) {
      HdsGlassBar({
        barWidth: this.chatInputPillW(),
        barHeight: h,
        contentPadding: 1,
        barBottomMargin: 1,
        hitThrough: true,
        lightColor: this.customThemeColor
      })
      Row({ space: 4 }) {
      // 表情按钮：开/关表情面板（同时收起键盘，否则面板会被输入法挤掉）
      Row() {
        Image($r('app.media.expression'))
          .width(22).height(22)
          .fillColor(this.showEmote ? this.customThemeColor : '#FFFFFF')
      }
      .width(34).height(34)
      .justifyContent(FlexAlign.Center)
      .borderRadius(17)
      .margin({ left: 5 })
      .hitTestBehavior(HitTestMode.Block)
      .onClick(() => {
        this.toggleEmotePanel();
      })

      Stack() {
        RichEditor({ controller: this.chatInputCtl })
          .key('liveChatInput')
          .width('100%')
          .height(h)
          .backgroundColor(Color.Transparent)
          .caretColor(this.customThemeColor)
          .padding({ left: 6, right: 6 })
          .onDidChange(() => {
            this.chatHasContent = this.chatInputCtl.getSpans().length > 0;
          })
        if (!this.chatHasContent) {
          Row() {
            Text('说点什么…').fontSize(13).fontColor('rgba(255,255,255,0.45)')
          }
          .width('100%')
          .height('100%')
          .padding({ left: 8 })
          .alignItems(VerticalAlign.Center)
          .hitTestBehavior(HitTestMode.None)
        }
        // 透明聚焦层：只盖住输入区（不能盖发送键），点它直接 requestFocus(key)，
        // 绕开 TextInput 自身聚焦被吞的情况
        Row()
          .width('100%')
          .height('100%')
          .backgroundColor('#00000000')
          .hitTestBehavior(HitTestMode.Block)
          .onClick(() => {
            this.showEmote = false;
            this.animateEmoteH(0);
            // 延迟 120ms 再聚焦：让本次触摸的默认焦点处理先结束，
            // 否则会出现「聚焦→立刻失焦→键盘闪退」（真机实测）
            setTimeout(() => {
              try {
                this.getUIContext().getFocusController().requestFocus('liveChatInput');
              } catch (_e) {}
            }, 120);
          })
      }
      .layoutWeight(1)
      .height(h)

      }
      .width(this.chatInputPillW())
      .height(h)
      .padding({ left: 2, right: 2 })
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  chatSendBtn(size: number) {
    Row() {
      Image($r('app.media.send_out'))
        .width(size * 0.46)
        .height(size * 0.46)
        .fillColor('#FFFFFF')
    }
    .width(size).height(size)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.chatSending ? themeRgba(this.customThemeColor, 0.45) : this.customThemeColor)
    .borderRadius(size / 2)
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => {
      this.sendChat();
    })
  }

  /** 竖屏：贴底输入胶囊（键盘弹出时整体上移） */
  @Builder
  chatInputBar() {
    Row({ space: 2 }) {
      this.chatInputCapsule(44)
      this.chatSendCircle()
    }
    .width('100%')
    .height(this.chatInputH())
    .padding({ left: 10, right: 10, bottom: this.chatBottomPad() })
    .alignItems(VerticalAlign.Center)
    .bindPopup(this.emoteUsePopup && this.showEmote, this.emotePopupOpts())
  }

  /** 横屏：悬浮输入胶囊（不占布局高度，列表可以从上到下铺满） */
  @Builder
  chatInputFloat() {
    Row({ space: 2 }) {
      this.chatInputCapsule(44)
      this.chatSendCircle()
    }
    .width('100%')
    .padding({ left: 10, right: 10 })
    .margin({ bottom: this.chatFloatPad() })
    .alignItems(VerticalAlign.Center)
    .bindPopup(this.emoteUsePopup && this.showEmote, this.emotePopupOpts())
  }

  /** 连接中的轻提示（不占高度，覆盖在列表顶部） */
  @Builder
  chatConnTip() {
    Row() {
      Text(this.wsState === 'connecting' ? '连接中…' : '重连中…')
        .fontSize(10)
        .fontColor('rgba(255,255,255,0.55)')
        .height(20)
        .padding({ left: 9, right: 9 })
        .backgroundColor('rgba(0,0,0,0.45)')
        .borderRadius(10)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .position({ x: 0, y: 8 })
    .hitTestBehavior(HitTestMode.None)
  }

  /** 表情面板：分类 tab + 表情网格（点击追加 [xx] 到输入框） */
  @Builder
  chatEmotePanel() {
    Column() {
      Column() {
      if (!this.emoteReady || ChatEmote.getPackages().length === 0) {
        Row() {
          Text('表情加载中…').fontSize(12).fontColor('rgba(255,255,255,0.5)')
        }
        .width('100%').height(150).justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Row({ space: 6 }) {
            ForEach(ChatEmote.getPackages(), (pkg: ChatEmotePackage, idx: number) => {
              Column() {
                if (pkg.url) {
                  Image(pkg.url).width(24).height(24).objectFit(ImageFit.Contain)
                } else {
                  Text(pkg.name).fontSize(11).fontColor('#FFFFFF')
                }
              }
              .width(36).height(36)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .backgroundColor(idx === this.emotePkgIdx
                ? themeRgba(this.customThemeColor, 0.28)
                : 'rgba(255,255,255,0.08)')
              .borderRadius(9)
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => {
                this.tick(8);
                this.emotePkgIdx = idx;
              })
            }, (pkg: ChatEmotePackage) => pkg.id.toString())
          }
          .padding({ left: 10, right: 10 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(40)

        Scroll() {
          Row({ space: 4 }) {
            ForEach(this.emoteColumns(), (col: ChatEmoteItem[], ci: number) => {
              Column({ space: 4 }) {
                ForEach(col, (emote: ChatEmoteItem) => {
                  Column() {
                    Image(emote.url).width(34).height(34).objectFit(ImageFit.Contain)
                  }
                  .width(42)
                  .height(42)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(HorizontalAlign.Center)
                  .onClick(() => {
                    this.tick(8);
                    this.insertChatEmote(emote);
                  })
                }, (emote: ChatEmoteItem) => emote.text)
              }
              .alignItems(HorizontalAlign.Center)
            }, (col: ChatEmoteItem[], ci: number) => `emote_col_${this.emotePkgIdx}_${ci}`)
          }
          .padding({ left: 10, right: 10 })
          .alignItems(VerticalAlign.Top)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .height(138)
      }
      }
      .width('100%')
      .padding({ top: 6, bottom: 6 })
      // 真材质设备走弹层（底色由系统材质负责）；老机才画圆角卡片
      .backgroundColor(this.emoteUsePopup ? Color.Transparent : 'rgba(18,20,26,0.92)')
      .borderRadius(16)
      .border({ width: this.emoteUsePopup ? 0 : 1, color: 'rgba(255,255,255,0.10)' })
      .clip(true)
    }
    .width('100%')
    .padding({ left: 8, right: 8, bottom: 6 })
  }

  /** 页面背景：有自定义背景用背景；否则用封面做毛玻璃 + 自下而上的深色渐变 */
  @Builder
  livePageBg() {
    if (this.appBg) {
      Image(this.appBg)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .hitTestBehavior(HitTestMode.None)
    } else if (this.roomCover) {
      Stack() {
        Image(this.roomCover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(36)
        // 底深顶透：保证底部评论/输入框区域文字可读
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: [
              ['rgba(0,0,0,0.20)', 0.0],
              ['rgba(0,0,0,0.55)', 0.55],
              ['rgba(0,0,0,0.85)', 1.0]
            ]
          })
      }
      .width('100%')
      .height('100%')
      .clip(true)
      .hitTestBehavior(HitTestMode.None)
    }
  }

  build() {
    Stack() {
      // ⭐ 直播间背景：优先 H5 的 app_background；
      //    没有的话用直播间封面 + 毛玻璃 + 底深顶透的渐变兜底（普通房间大多没配背景）
      if (!this.fsMode) {
        this.livePageBg()
      }

      // ⭐ 视频层：XComponent 常驻，旋转只改几何不重建
      //    外层按「视频区域」裁切：竖屏视频只出现在顶栏下方，不会盖住聊天区
      Stack() {
        if (this.videoSrc) {
          XComponent({ id: 'live_video_xc', type: XComponentType.TEXTURE, controller: this.xc })
            .width(this.videoRect().w)
            .height(this.videoRect().h)
            // 圆角必须加在画面本体上：容器只裁「视频区域」，画面在区域内留黑边时四角还是直角
            .borderRadius(this.fsMode ? 0 : 16)
            .position({
              x: this.videoRect().x - this.videoAreaRect().x,
              y: this.videoRect().y - this.videoAreaRect().y
            })
        }
      }
      .width(this.videoAreaRect().w)
      .height(this.videoAreaRect().h)
      .position({ x: this.videoAreaRect().x, y: this.videoAreaRect().y })
      // 透明：让直播间背景透到视频两侧的黑边里
      .backgroundColor(Color.Transparent)
      // 播放区域小圆角（全屏时贴边，不加）
      .borderRadius(this.fsMode ? 0 : 16)
      .clip(true)

      // 直播弹幕层（不挡手势；开关切换时重建 Canvas）
      if (this.videoSrc && this.danmakuOn) {
        Canvas(this.danmakuCtx)
          .width(this.danmakuRect().w)
          .height(this.danmakuRect().h)
          .position({ x: this.danmakuRect().x, y: this.danmakuRect().y })
          .hitTestBehavior(HitTestMode.None)
          .onReady(() => {
            this.onDanmakuReady();
          })
          .onAreaChange((o: Area, n: Area) => {
            const w: number = n.width as number;
            const h: number = n.height as number;
            if (w > 0 && h > 0) {
              // ⭐ 防抖：切比例/全屏是 260ms 动画，期间 area 每帧都变，
              //    直接 setSize 会每帧 updateGeometry + 重播弹幕（画面会闪）。
              //    只在尺寸稳定后再应用一次。
              this.danmakuResizeW = w;
              this.danmakuResizeH = h;
              if (this.danmakuResizeTimer !== -1) {
                clearTimeout(this.danmakuResizeTimer);
              }
              this.danmakuResizeTimer = setTimeout(() => {
                this.danmakuResizeTimer = -1;
                if (this.danmakuResizeW > 0 && this.danmakuResizeH > 0) {
                  this.danmakuCtl?.setSize(this.danmakuResizeW, this.danmakuResizeH);
                }
              }, 140);
            }
          })
      }

      // ⭐ 手势层：铺满整屏、位于视频/弹幕之上、控制层与聊天面板之下
      //    （控件自己会消费点击；空白处的点击落到这一层）
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor('#00000000')
        .hitTestBehavior(HitTestMode.Block)
        .onTouch(this.onVT)

      // 加载中
      if (this.loading) {
        Column() {
          LoadingProgress().width(48).height(48).color('#FFFFFF')
          Text('加载直播...').fontSize(14).fontColor('#CCCCCC').margin({ top: 16 })
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.7)')
      }

      // 错误提示（仅当无视频源时显示）
      if (this.errorMsg && !this.videoSrc) {
        Column() {
          Text('⚠️').fontSize(48).fontColor('#FF6600')
          Text(this.errorMsg).fontSize(14).fontColor('#CCCCCC').margin({ top: 16 })
          Text('点击返回').fontSize(14).fontColor(this.customThemeColor).margin({ top: 24 })
            .onClick(() => this.goBack())
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.7)')
      }

      // ⭐ 控制层：竖屏四角落位 / 横屏分段 Dock 共用同一个常驻层
      // ⚠️ 用**条件渲染**而不是 opacity：真机上 opacity 从 1 回到 1 的路径偶发不刷新
      //    （自动隐藏后再次点按，状态已是 visible=true 但画面仍停在 opacity 0）。
      //    条件渲染每次显隐都重建，不依赖属性动画。
      // 顶部控制栏（单独条件渲染）：出现时从上方落下、收起时向上移出
      if (!this.loading && this.videoSrc && this.isControlsVisible) {
        this.buildTopBar()
      }

      // 底部控制栏 / 分段 Dock：出现时从下方升起、收起时向下移出
      if (!this.loading && this.videoSrc && this.isControlsVisible) {
        Stack() {
          if (!this.isLandscape) {
            this.buildPortraitControls()
          }
          if (this.isLandscape) {
            this.buildLandscapeDock()
          }
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 10 }))
            .animation({ duration: 220, curve: Curve.EaseOut }),
          TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 10 }))
            .animation({ duration: 160, curve: Curve.EaseIn })
        ))
      }

      // ⭐ 竖屏聊天区：视频下沿 → 屏幕底部，输入栏常驻（无标题，列表直接铺满）
      if (!this.isLandscape && !this.fsMode && this.videoSrc && !this.loading) {
        Stack({ alignContent: Alignment.Bottom }) {
          Stack({ alignContent: Alignment.TopStart }) {
            this.chatList()
            if (this.wsState === 'connecting' || this.wsState === 'reconnecting') {
              this.chatConnTip()
            }
          }
          .width('100%')
          .height('100%')

          Column() {
            if (this.emoteH > 0) {
              Column() {
                this.chatEmotePanel()
              }
              .width('100%')
              .height(this.emoteH)
              .clip(true)
              .alignItems(HorizontalAlign.Start)
            }
            this.chatInputBar()
          }
          .width('100%')
          // 覆盖在列表上：自身与子节点正常响应，同时允许下层的 Scroll 接住滑动
          .hitTestBehavior(HitTestMode.Transparent)
        }
        .width('100%')
        .height(this.winH - this.portraitChatTop())
        .position({ x: 0, y: this.portraitChatTop() })
        // 透明：让直播间背景（壁纸）透过评论区显示
        .backgroundColor(Color.Transparent)
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ y: 24 }))
          .animation({ duration: 240, curve: Curve.EaseInOut }))
        .zIndex(10)
      }

      // ⭐ 横屏分栏：右侧聊天栏（默认展开，无标题、悬浮输入框）；全屏 / 收起聊天时让位给视频
      if (this.isLandscape && this.chatOpen && !this.fsMode && this.videoSrc && !this.loading) {
        Stack({ alignContent: Alignment.Bottom }) {
          this.chatList()

          if (this.wsState === 'connecting' || this.wsState === 'reconnecting') {
            this.chatConnTip()
          }

          Column() {
            if (this.emoteH > 0) {
              Column() {
                this.chatEmotePanel()
              }
              .width('100%')
              .height(this.emoteH)
              .clip(true)
              .alignItems(HorizontalAlign.Start)
            }
            this.chatInputFloat()
          }
          .width('100%')
        }
        .width(this.chatPanelW())
        .height(this.winH)
        // ⭐ 聊天列表贴面板顶端开始（横屏系统栏已隐藏，safeTop 只是挖孔避让，留 4vp 即可），
        //    否则顶部会空出一条 40+vp 的"无内容带"（用户反馈）
        .padding({ top: 4 })
        .position({ x: this.winW - this.chatPanelW(), y: 0 })
        // 透明：让直播间背景（壁纸）透出来
        .backgroundColor(Color.Transparent)
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({ x: 48 }))
          .animation({ duration: 240, curve: Curve.EaseInOut }))
        .zIndex(10)
      }

      // 手势提示
      if (this.showGestureHint) {
        Column({ space: 8 }) {
          Image(this.gestureHintType === 'volume' ? $r('app.media.volume_114') : $r('app.media.brightness_low7'))
            .width(30).height(30).fillColor('#FFFFFF')
          Text(this.gestureHintMainText).fontSize(16).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
        }
        .width(80).height(80)
        .backgroundColor('rgba(0,0,0,0.6)').borderRadius(16)
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        .position({ x: '50%', y: '50%' }).translate({ x: -40, y: -40 })
        .transition(TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.9, y: 0.9 }))
          .animation({ duration: 140, curve: Curve.EaseOut }))
        .zIndex(10)
      }

      // 底部提示（比例/后台播放等轻提示）
      if (this.showBottomHint) {
        Row() {
          Row({ space: 6 }) {
            if (this.bottomHintImage !== undefined) {
              Image(this.bottomHintImage as ResourceStr).width(16).height(16).fillColor('#FFFFFF')
            }
            Text(this.bottomHintText).fontSize(12).fontColor('#FFFFFF').maxLines(1)
          }
          .height(34)
          .padding({ left: 12, right: 14 })
          .backgroundColor('rgba(0,0,0,0.66)')
          .borderRadius(17)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .position({
          x: 0,
          y: this.winH - (this.isLandscape ? 72 : Math.max(16, this.safeBottom + 12)) - 34
        })
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 10 }))
            .animation({ duration: 180, curve: Curve.EaseOut }),
          TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 6 }))
            .animation({ duration: 140, curve: Curve.EaseIn })
        ))
        .zIndex(20)
      }

      // 画质菜单（横屏在 Dock 上方 / 竖屏在画质胶囊下方）
      if (this.showQualityPicker) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Block)
          .onClick(() => {
            this.showQualityPicker = false;
            this.showControlsTemporarily();
          })

        Column() {
          Row() {
            Text('画质选择').fontSize(14).fontColor($r('app.color.live_quality_text_title')).fontWeight(FontWeight.Bold)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 8 })

          ForEach(this.qualityGroups(), (group: QualityOption[], gi: number) => {
            Column() {
              Row() {
                Row() {
                  if (group[0].qn === this.currentQn) {
                    Text('✓').fontSize(12).fontColor(this.customThemeColor).margin({ right: 4 })
                  }
                  Text(group[0].label).fontSize(14)
                    .fontColor(group[0].qn === this.currentQn ? $r('app.color.live_quality_text_selected') : $r('app.color.live_quality_text_unselected'))
                    .fontWeight(group[0].qn === this.currentQn ? FontWeight.Medium : FontWeight.Regular)
                }
                .layoutWeight(1)
                .height(44)
                .justifyContent(FlexAlign.Center)
                .backgroundColor(group[0].qn === this.currentQn ? 'rgba(0,174,236,0.14)' : 'transparent')
                .onClick(() => {
                  if (group[0].qn !== this.currentQn) { this.switchQuality(group[0].qn); }
                  else { this.showQualityPicker = false; }
                })

                if (group.length > 1) {
                  Divider().vertical(true).height(44).color('rgba(255,255,255,0.12)')
                  Row() {
                    if (group[1].qn === this.currentQn) {
                      Text('✓').fontSize(12).fontColor(this.customThemeColor).margin({ right: 4 })
                    }
                    Text(group[1].label).fontSize(14)
                      .fontColor(group[1].qn === this.currentQn ? $r('app.color.live_quality_text_selected') : $r('app.color.live_quality_text_unselected'))
                      .fontWeight(group[1].qn === this.currentQn ? FontWeight.Medium : FontWeight.Regular)
                  }
                  .layoutWeight(1)
                  .height(44)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor(group[1].qn === this.currentQn ? 'rgba(0,174,236,0.14)' : 'transparent')
                  .onClick(() => {
                    if (group[1].qn !== this.currentQn) { this.switchQuality(group[1].qn); }
                    else { this.showQualityPicker = false; }
                  })
                }
              }
              .width('100%')
              .height(44)
              .alignItems(VerticalAlign.Center)

              if (gi < this.qualityGroups().length - 1) {
                Divider().color('rgba(255,255,255,0.12)')
              }
            }
            .width('100%')
          }, (group: QualityOption[]) => group.map((g: QualityOption) => g.qn).join('_'))
        }
        .width(216)
        .borderRadius(14)
        .backgroundColor(Color.Transparent)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
        .clip(true)
        .shadow({ radius: 24, color: '#40000000', offsetY: 6 })
        .position({ x: this.qualityMenuX(), y: this.qualityMenuY() })
        .zIndex(30)
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.scale({ x: 0.9, y: 0.9, centerX: '100%', centerY: '0%' })
            .combine(TransitionEffect.opacity(0))
            .animation({ duration: 220, curve: Curve.FastOutSlowIn }),
          TransitionEffect.opacity(0).animation({ duration: 180, curve: Curve.EaseIn })
        ))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .clip(true)
    .onAreaChange(this.onRootArea)
  }
}
