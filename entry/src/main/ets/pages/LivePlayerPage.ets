// LivePlayerPage.ets — 直播播放页（使用 Video 组件）
import { window, display } from '@kit.ArkUI';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { audio } from '@kit.AudioKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { media } from '@kit.MediaKit';
import { getLiveRoomInfo, getLiveStreamUrl, getLiveQualityLabel, invalidateCachedStreamUrl, getRoomPlayInfo, QualityDescription } from '../api/LiveApi';
import { LiveViewHelper } from '../services/LiveViewHelper';
import { BusinessError } from '@kit.BasicServicesKit';
import { VibrateUtils } from '../utils/VibrateUtils';

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
  @State isDanmakuEnabled: boolean = false;
  @State isBackgroundPlayback: boolean = false;
  // 亮度/音量起始值
  @State sv: number = 1; // start volume (0-1)
  @State sb: number = 1; // start brightness (0-1)
  @State vol: number = 1;
  @State bri: number = 1;
  // 安全区域（px→vp 转换后）
  @State safeTop: number = 28;
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

  /** ⭐ 视频显示矩形：旋转/切画质/换比例都由它派生，不再读 display 快照 */
  private videoRect(): VideoRect {
    if (this.winW <= 0 || this.winH <= 0) {
      return { x: 0, y: 0, w: 1, h: 1 };
    }
    return this.fitRect(0, 0, this.winW, this.winH);
  }

  /**
   * ⭐ 视频矩形与窗口的可见交集。
   *   crop 模式下视频会比窗口大（被裁），四角按钮必须贴可见边缘，
   *   否则会跟着视频矩形跑到屏幕外。
   */
  private videoOverlayRect(): VideoRect {
    const r: VideoRect = this.videoRect();
    const x: number = Math.max(0, r.x);
    const y: number = Math.max(0, r.y);
    const right: number = Math.min(this.winW, r.x + r.w);
    const bottom: number = Math.min(this.winH, r.y + r.h);
    return { x, y, w: Math.max(1, right - x), h: Math.max(1, bottom - y) };
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
    if (this.ratioMode === 'fit') { this.ratioMode = 'crop'; }
    else if (this.ratioMode === 'crop') { this.ratioMode = 'fill'; }
    else { this.ratioMode = 'fit'; }
    this.showBottomHintTemporarily(`画面比例：${this.ratioLabel()}`);
    this.showControlsTemporarily();
  }

  /** ⭐ 重置直播：释放播放器并强制重新拉流 */
  private resetLive(): void {
    this.showBottomHintTemporarily('已重置直播');
    this.releasePlayer();
    this.showControlsTemporarily();
    this.startPlay(true);
  }

  /** ⭐ 播放/暂停切换 */
  private togglePlayPause(): void {
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

  aboutToAppear() {
    // ⭐ 注册系统音量变化监听（音量键调节时同步 app 内滑块/手势起点）
    this.registerVolumeListener();
    // ⭐ 首帧前的窗口尺寸估算（真正的尺寸由根节点 onAreaChange 接管）
    this.initWindowSize();
    // ⭐ 继承全局旋转锁，不再无条件放开自动旋转
    const lock: string = AppStorage.get<string>('screenOrientationLock') ?? '自动旋转';
    this.rotationMode = lock === '锁定竖屏' ? 'portrait' : (lock === '锁定横屏' ? 'landscape' : 'auto');
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params && params['roomId']) {
      this.roomId = params['roomId'] as number;
      this.getSafeArea();
      this.initPlayback();
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
      this.safeTop = Math.max(0, ui.px2vp(sys.topRect.height));
      this.safeLeft = Math.max(0, ui.px2vp(sys.leftRect.width));
      this.safeRight = Math.max(0, ui.px2vp(sys.rightRect.width));
      this.safeBottom = Math.max(0, ui.px2vp(nav.bottomRect.height));
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

      const info = await getLiveRoomInfo(this.roomId);
      if (info) {
        this.title = info.title;
        this.online = info.online;
        this.uname = info.uname;
        this.roomCover = info.face || info.keyframe || ''; // 封面优先 user_cover，其次 keyframe
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
    if (this.retryCount < this.maxRetries) {
      this.retryCount++;
      this.loading = true;
      this.errorMsg = '';
      const shouldRefresh: boolean = this.retryCount > 2;
      if (shouldRefresh) {
        invalidateCachedStreamUrl(this.roomId);
      }
      // 重试超过 3 次后尝试降画质
      if (this.retryCount >= 3 && this.availableQualities.length > 0) {
        this.downgradeQuality();
      }
      if (this.retryTimer !== -1) clearTimeout(this.retryTimer);
      this.retryTimer = setTimeout(() => {
        this.retryTimer = -1;
        this.startPlay(shouldRefresh);
      }, 1000);
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
    return Math.max(40, this.safeBottom + 12);
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
    }, 4000);
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
    this.sv = this.vol;
    this.sb = this.bri;
    this.ml_ = false;
    this.la_ = false;
    this.dtp_ = false;

    // 双击检测
    if (this.dt_ !== -1) {
      clearTimeout(this.dt_);
      this.dt_ = -1;
      this.dtp_ = true;
      return;
    }

    this.dt_ = setTimeout(() => {
      this.dt_ = -1;
    }, 300);

    // 长按定时器
    this.lt_ = setTimeout(() => {
      if (!this.ml_) {
        this.la_ = true;
      }
    }, 500);
  }

  private onTM(e: TouchEvent): void {
    if (e.touches.length === 0) return;
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
          // 垂直滑动：左30% = 亮度，右70% = 音量
          const centerX = (this.winW > 0 ? this.winW : 360) / 2;
          if (t.windowX < centerX) {
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

    // 单击切换控制栏显隐（只在画面中部点击时切换，不影响顶部/底部按钮区域）
    if (!this.dtp_ && !wasMoved && !wasLongPress) {
      const tapY = this.sy_;
      const hNow: number = this.winH > 0 ? this.winH : 780;
      const midLow = hNow * 0.2;
      const midHigh = hNow * 0.8;
      const inMiddleArea: boolean = tapY >= midLow && tapY <= midHigh;
      if (inMiddleArea) {
        this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
          this.isControlsVisible = !this.isControlsVisible;
        });
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
    }
    this.gm_ = '';
    this.ml_ = false;
  }

  private onTC(): void {
    if (this.lt_ !== -1) { clearTimeout(this.lt_); this.lt_ = -1; }
    this.la_ = false;
    this.gm_ = '';
    this.ml_ = false;
  }

  // ==================== 屏幕旋转控制 ====================

  /** 切换旋转模式：自动旋转 ↔ 锁定当前方向 */
  private toggleRotation(): void {
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

  // ==================== build ====================

  /** 顶栏：返回 + LIVE/在线 + 标题（横竖屏共用，安全区已转 vp） */
  @Builder
  buildTopBar() {
    Row({ space: 10 }) {
      // 返回：与其它选项同一套毛玻璃材质 / 42vp 高度
      Column() {
        Image($r('app.media.return_453'))
          .width(20).height(20).fillColor('#FFFFFF')
      }
      .width(42).height(42)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('rgba(15,16,21,0.82)')
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
      .border({ width: 1, color: 'rgba(255,255,255,0.10)' })
      .borderRadius(21)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .hitTestBehavior(HitTestMode.Block)
      .onClick(() => this.goBack())

      Row({ space: 4 }) {
        Circle().width(6).height(6).fill('#FF3355')
        Text('LIVE').fontSize(12).fontColor('#FF3355').fontWeight(FontWeight.Bold)
        if (this.online > 0) {
          Text(`${this.online}`).fontSize(11.5).fontColor('rgba(255,255,255,0.72)')
        }
      }
      .alignItems(VerticalAlign.Center)

      Text(this.title)
        .fontSize(14)
        .fontColor('#FFFFFF')
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      // 右上：画质 + 后台播放（胶囊）
      Row() {
        this.dockQualityBtn()
        this.bgpBtn()
      }
      .height(42)
      .padding({ left: 4, right: 4 })
      .backgroundColor('rgba(15,16,21,0.82)')
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
      .border({ width: 1, color: 'rgba(255,255,255,0.10)' })
      .borderRadius(21)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(this.safeTop + 52)
    .padding({ left: 16, right: 16, top: this.safeTop + 8 })
    .alignItems(VerticalAlign.Center)
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [['rgba(0,0,0,0.55)', 0.0], ['rgba(0,0,0,0)', 1.0]]
    })
    .position({ x: 0, y: 0 })
    .translate({ y: this.isControlsVisible ? 0 : -8 })
  }

  /** Dock 图标按钮（方案 B 的基础单元） */
  @Builder
  dockIconBtn(icon: Resource, highlighted: boolean, onTap: () => void) {
    Row() {
      Image(icon)
        .width(18).height(18)
        .fillColor(highlighted ? '#8BE0FF' : '#FFFFFF')
    }
    .width(34).height(34)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(highlighted ? '#2E00AEEC' : '#00000000')
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
    Row({ space: 6 }) {
      Image($r('app.media.chicun')).width(18).height(18).fillColor('#FFFFFF')
      Text(this.ratioLabel()).fontSize(12.5).fontColor('#FFFFFF').maxLines(1)
    }
    .height(34)
    .padding({ left: 9, right: 9 })
    .borderRadius(17)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => this.cycleAspectRatio())
  }

  @Builder
  dockQualityBtn() {
    Row({ space: 6 }) {
      Image($r('app.media.hd_24px_rounded')).width(18).height(18).fillColor('#FFFFFF')
      Text(this.qualityLabel()).fontSize(12.5).fontColor('#FFFFFF').maxLines(1)
    }
    .height(34)
    .padding({ left: 9, right: 9 })
    .borderRadius(17)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => this.openQualityPicker())
  }

  /** 旋转锁定：表面按钮（自由 ↔ 锁定），竖横屏共用 */
  @Builder
  lockBtn() {
    Row({ space: 6 }) {
      Image(this.rotationLockIcon()).width(17).height(17).fillColor('#FFFFFF')
      Text(this.rotationMode === 'auto' ? '自由' : '锁定')
        .fontSize(12.5).fontColor('#FFFFFF').maxLines(1)
    }
    .height(34)
    .padding({ left: 9, right: 9 })
    .borderRadius(17)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => this.toggleRotation())
  }

  /** 后台播放：右上角胶囊里的开关态按钮 */
  @Builder
  bgpBtn() {
    Row({ space: 6 }) {
      Image($r('app.media.headphones_fill'))
        .width(17).height(17)
        .fillColor(this.bgp ? '#8BE0FF' : '#FFFFFF')
      Text('后台')
        .fontSize(12.5)
        .fontColor(this.bgp ? '#8BE0FF' : '#FFFFFF')
        .maxLines(1)
    }
    .height(34)
    .padding({ left: 9, right: 9 })
    .backgroundColor(this.bgp ? '#2E00AEEC' : '#00000000')
    .borderRadius(17)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .hitTestBehavior(HitTestMode.Block)
    .onClick(() => this.setBackgroundPlayback(!this.bgp))
  }

  /** 横屏：左右两个胶囊（中间留空，露出更多画面） */
  @Builder
  buildLandscapeDock() {
    Row() {
      // 左胶囊：播放 / 刷新
      Row() {
        this.dockPlayBtn()
        this.dockIconBtn($r('app.media.reset_70'), false, () => this.resetLive())
      }
      .height(42)
      .padding({ left: 4, right: 4 })
      .backgroundColor('rgba(15,16,21,0.82)')
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
      .border({ width: 1, color: 'rgba(255,255,255,0.10)' })
      .borderRadius(21)
      .alignItems(VerticalAlign.Center)

      Blank()

      // 右胶囊：比例 + 旋转锁定
      Row() {
        this.dockRatioBtn()
        this.lockBtn()
      }
      .height(42)
      .padding({ left: 4, right: 4 })
      .backgroundColor('rgba(15,16,21,0.82)')
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
      .border({ width: 1, color: 'rgba(255,255,255,0.10)' })
      .borderRadius(21)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(42)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
    .position({ x: 0, y: this.winH - 42 - this.dockBottomPad() })
    .translate({ y: this.isControlsVisible ? 0 : 8 })
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
        Row({ space: 2 }) {
          this.dockPlayBtn()
          this.dockIconBtn($r('app.media.reset_70'), false, () => this.resetLive())
        }
        .padding(4)
        .backgroundColor('rgba(15,16,21,0.82)')
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
        .border({ width: 1, color: 'rgba(255,255,255,0.10)' })
        .borderRadius(21)

        Blank()

        Row({ space: 2 }) {
          this.dockRatioBtn()
          this.lockBtn()
        }
        .padding(4)
        .backgroundColor('rgba(15,16,21,0.82)')
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK })
        .border({ width: 1, color: 'rgba(255,255,255,0.10)' })
        .borderRadius(21)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .translate({ y: this.isControlsVisible ? 0 : 8 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 10, right: 10, bottom: 10 })
    .position({ x: this.videoOverlayRect().x, y: this.videoOverlayRect().y })
    .width(this.videoOverlayRect().w)
    .height(this.videoOverlayRect().h)
  }

  build() {
    Stack() {
      // ⭐ 视频层：XComponent 常驻，旋转只改几何不重建
      Stack() {
        if (this.videoSrc) {
          XComponent({ id: 'live_video_xc', type: XComponentType.SURFACE, controller: this.xc })
            .width(this.videoRect().w)
            .height(this.videoRect().h)
            .position({ x: this.videoRect().x, y: this.videoRect().y })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')

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
          Text('点击返回').fontSize(14).fontColor('#007DFF').margin({ top: 24 })
            .onClick(() => this.goBack())
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.7)')
      }

      // ⭐ 控制层：竖屏四角落位 / 横屏分段 Dock 共用同一个常驻层
      if (!this.loading && this.videoSrc) {
        Stack() {
          if (!this.isLandscape) {
            this.buildPortraitControls()
          }
          this.buildTopBar()
          if (this.isLandscape) {
            this.buildLandscapeDock()
          }
        }
        .width('100%')
        .height('100%')
        .opacity(this.isControlsVisible ? 1 : 0)
        .hitTestBehavior(this.isControlsVisible ? HitTestMode.Default : HitTestMode.None)
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
                    Text('✓').fontSize(12).fontColor('#00AEEC').margin({ right: 4 })
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
                      Text('✓').fontSize(12).fontColor('#00AEEC').margin({ right: 4 })
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
    .onTouch(this.onVT)
    .onAreaChange(this.onRootArea)
  }
}
