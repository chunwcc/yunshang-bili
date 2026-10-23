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

  // ========== Video 组件状态 ==========
  @State videoSrc: string = '';
  @State videoSrcVersion: number = 0;  // 强制重建 Video 用
  private av: media.AVPlayer | null = null; // AVPlayer 播放器（支持后台续播）
  private xc: XComponentController = new XComponentController(); // 视频渲染表面
  private surfaceId_: string = '';
  @State ratioMode: string = '16:9'; // 画面比例：fill=铺满 / 16:9 / 4:3

  // ========== 动态画质列表（从API获取，只显示此直播间有的画质） ==========
  @State availableQualities: QualityOption[] = [];

  // ========== VideoControls 绑定状态 ==========
  @State isPlaying: boolean = true;
  @State currentTime: number = 0;
  @State duration: number = 0;
  @State isControlsVisible: boolean = true;
  @State isFullscreen: boolean = true;
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
  // 安全区域
  @State safeTop: number = 28;
  @State safeBottom: number = 24;

  private maxRetries: number = 8;
  private controlsTimer: number = -1;
  private retryTimer: number = -1;
  private screenW: number = 720;
  private screenH_: number = 0;  // 屏幕高度(vp)，用于手势灵敏度
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

  /** 当前窗口是否为横屏（基于窗口尺寸，非物理屏幕） */
  private isWindowLandscape(): boolean {
    if (this.mw) {
      try {
        const wp = this.mw.getWindowProperties();
        return wp.windowRect.width > wp.windowRect.height;
      } catch (_e) {}
    }
    try {
      const d = display.getDefaultDisplaySync();
      return d.width > d.height;
    } catch (_e) {
      return false;
    }
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

  private screenWv(): number {
    try {
      const d = display.getDefaultDisplaySync();
      return d.width / d.densityPixels;
    } catch (_e) { return 720; }
  }

  private screenHv(): number {
    try {
      const d = display.getDefaultDisplaySync();
      return d.height / d.densityPixels;
    } catch (_e) { return 405; }
  }

  private videoW(): number {
    const sw = this.screenWv();
    const sh = this.screenHv();
    if (this.ratioMode === 'fill') { return sw; }
    const r = this.ratioMode === '4:3' ? 4 / 3 : 16 / 9;
    return (sw / sh > r) ? sh * r : sw;
  }

  private videoH(): number {
    const sw = this.screenWv();
    const sh = this.screenHv();
    if (this.ratioMode === 'fill') { return sh; }
    const r = this.ratioMode === '4:3' ? 4 / 3 : 16 / 9;
    return (sw / sh > r) ? sh : sw / r;
  }

  /** ⭐ 循环切换画面比例 */
  private cycleAspectRatio(): void {
    if (this.ratioMode === '16:9') { this.ratioMode = '4:3'; }
    else if (this.ratioMode === '4:3') { this.ratioMode = 'fill'; }
    else { this.ratioMode = '16:9'; }
    const label = this.ratioMode === 'fill' ? '铺满' : (this.ratioMode === '4:3' ? '4:3' : '16:9');
    this.showBottomHintTemporarily(`画面比例：${label}`);
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
    const params = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params && params['roomId']) {
      this.roomId = params['roomId'] as number;
      this.initSwipeControl();
      this.getSafeArea();
      this.initPlayback();
    } else {
      this.errorMsg = '缺少房间号';
      this.loading = false;
    }
  }

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
        // 初始化为自动旋转模式
        this.applyRotationMode();
        const top = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        if (top.topRect.height > 0) {
          this.safeTop = top.topRect.height;
        }
        const bottom = w.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        if (bottom.bottomRect.height > 0) {
          this.safeBottom = bottom.bottomRect.height;
        }
        // 进入直播间立即隐藏导航小白条
        try {
          w.setWindowSystemBarEnable([]);
        } catch (_e2) {}
      });
    } catch (_e) {
      // 使用默认值
    }
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
        // 恢复屏幕方向为用户系统默认（自动旋转）
        w.setPreferredOrientation(window.Orientation.AUTO_ROTATION).catch(() => {});
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

  /** ⭐ 后台播放开关（参考普通播放器 VideoControls）：切换持久化标志并给出提示 */
  private toggleBackgroundPlayback(): void {
    this.bgp = !this.bgp;
    AppStorage.set<boolean>('bgp', this.bgp);
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      preferences.getPreferences(ctx, 'my_app_settings').then((pref) => {
        pref.put('bgp', this.bgp);
        pref.flush();
      });
    } catch (e) {
      logError('[LivePlayer] bgp 持久化保存失败', e);
    }
    this.showBottomHintTemporarily(
      this.bgp ? '后台播放已开启' : '后台播放已关闭',
      $r('app.media.headphones_fill')
    );
    // ⭐ 接入媒体会话：开启→建会话（在播时）；关闭→结束会话并暂停（若在后台）
    if (this.bgp) {
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
  }

  private showControlsTemporarily(): void {
    this.isControlsVisible = true;
    if (this.controlsTimer !== -1) clearTimeout(this.controlsTimer);
    this.controlsTimer = setTimeout(() => {
      if (!this.showQualityPicker) {
        this.isControlsVisible = false;
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

  private initSwipeControl(): void {
    try {
      const d = display.getDefaultDisplaySync();
      this.screenW = this.getUIContext().px2vp(d.width);
      this.screenH_ = this.getUIContext().px2vp(d.height);
    } catch (_e) {
      this.screenW = 360;
      this.screenH_ = 720;
    }
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
          const centerX = this.screenW / 2;
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
      const midLow = this.screenH_ * 0.2;
      const midHigh = this.screenH_ * 0.8;
      const inMiddleArea: boolean = tapY >= midLow && tapY <= midHigh;
      if (inMiddleArea) {
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

  build() {
    Stack() {
      // 视频画面层（Stack 居中，画面比例由 ratioMode 决定，黑边填充）
      Stack() {
        if (this.videoSrc) {
          XComponent({ id: 'live_video_xc', type: XComponentType.SURFACE, controller: this.xc })
            .width(this.videoW())
            .height(this.videoH())
        } else {
          // 无视频源时黑色背景
          Column().width('100%').height('100%').backgroundColor('#000000')
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

      // ⭐ 控制栏（内联，不经过自定义组件边界）
      if (!this.loading && this.videoSrc) {
        Column() {
          // 顶栏
          Stack() {
            // 标题绝对居中
            Text(`${this.title}`)
              .fontSize(16).fontColor('#FFFFFF')
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Center)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .maxLines(1)
              .width('100%')
              .padding({ left: 80, right: 80 })

            // 左右控制行（布局流 + 自动高度，避免竖屏右侧超出屏幕）
            Row() {
              // 左：返回 + LIVE
              Row() {
                // 返回按钮（带圆形遮罩）
                Column() {
                  Image($r('app.media.return_453'))
.width(30).height(30).fillColor('#FFFFFF')
                }
                .width(40).height(40)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor('rgba(0,0,0,0.45)')
                .border({ width: 1.5, color: '#FFFFFF' })
                .borderRadius(20)
                .onClick(() => this.goBack())

                // LIVE 标识
                Row({ space: 4 }) {
                  Circle().width(8).height(8).fill('#FF3355')
                  Text('LIVE').fontSize(12).fontColor('#FF3355').fontWeight(FontWeight.Bold)
                  if (this.online > 0) {
                    Text(`${this.online}`).fontSize(12).fontColor('#FF9999')
                  }
                }
                .margin({ left: 8 })
                .alignItems(VerticalAlign.Center)
              }
              .alignItems(VerticalAlign.Center)

              Blank().layoutWeight(1)

              // 右：后台播放 + 画质
              Row({ space: 8 }) {
                // 后台播放按钮（参考普通播放器：图标随状态切换 nosign/headphones）
                Stack() {
                  Button() {
                    Row() {
                      Image($r(this.bgp ? 'app.media.nosign' : 'app.media.headphones_fill'))
                        .width(18).height(18).fillColor('#FFFFFF')
                      Text(this.bgp ? '取消后台' : '后台播放')
                        .fontSize(12).fontColor('#FFFFFF').margin({ left: 4 })
                    }.alignItems(VerticalAlign.Center)
                  }
                  .height(40)
                  .padding({ left: 10, right: 12 })
                  .backgroundColor(Color.Transparent)
                  .borderRadius(0).borderWidth(0)
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                  .onClick(() => {
                    this.toggleBackgroundPlayback();
                    this.showControlsTemporarily();
                  })
                }
                .height(40)
                .backgroundColor('rgba(0,0,0,0.45)')
                .borderRadius(20)
                .border({ width: 1.5, color: '#FFFFFF' })

                // 画质按钮
                Column() {
                  Image($r('app.media.ic_settings_quality'))
                    .width(20).height(20).fillColor('#FFFFFF')
                }
                .width(44).height(44)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .backgroundColor('rgba(0,0,0,0.45)')
                .border({ width: 1.5, color: '#FFFFFF' })
                .borderRadius(22)
                .onClick(() => {
                  this.showQualityPicker = true;
                  this.showControlsTemporarily();
                })
              }
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: this.safeTop + 8, bottom: 8 })
            .alignItems(VerticalAlign.Center)

          }
          .width('100%')

          Blank().layoutWeight(1)

          // 底栏 — 按钮靠左，整体靠下
          Row() {
            // 播放/暂停按钮
            Column() {
              Image(this.isPlaying ? $r('app.media.ic_public_pause') : $r('app.media.ic_public_play'))
                .width(24).height(24).fillColor('#FFFFFF')
            }
            .width(40).height(40)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('rgba(0,0,0,0.45)')
            .border({ width: 1.5, color: '#FFFFFF' })
            .borderRadius(20)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => this.togglePlayPause())

            // 重置直播按钮
            Column() {
              Image($r('app.media.reset_70'))
                .width(36).height(36).fillColor('#FFFFFF')
            }
            .width(40).height(40)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('rgba(0,0,0,0.45)')
            .border({ width: 1.5, color: '#FFFFFF' })
            .borderRadius(20)
            .margin({ left: 12 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => this.resetLive())

            // 旋转锁定按钮（带圆形遮罩）
            Column() {
              Image(this.getRotationIcon())
                .width(24).height(24).fillColor('#FFFFFF')
            }
            .width(40).height(40)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('rgba(0,0,0,0.45)')
            .border({ width: 1.5, color: '#FFFFFF' })
            .borderRadius(20)
            .margin({ left: 12 })
            .onClick(() => this.toggleRotation())

            Blank().layoutWeight(1)

            // 比例按钮（循环切换画面比例）
            Column() {
              Text('比例').fontSize(12).fontColor('#FFFFFF')
            }
            .height(40)
            .padding({ left: 14, right: 14 })
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('rgba(0,0,0,0.45)')
            .border({ width: 1.5, color: '#FFFFFF' })
            .borderRadius(20)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => this.cycleAspectRatio())
          }
          .width('100%').padding({ left: 16, right: 16, bottom: this.safeBottom + 15 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
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

      // 画质小弹窗：系统推荐的小菜单样式（磨砂毛玻璃 + 圆角 + 阴影，锚定画质按钮下方）
      if (this.showQualityPicker) {
        // 透明遮罩 — 点击弹窗外区域关闭
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Block)
          .onClick(() => {
            this.showQualityPicker = false;
            this.showControlsTemporarily();
          })

        // 小菜单
        Column() {
          Row() {
            Text('画质选择').fontSize(14).fontColor($r('app.color.live_quality_text_title')).fontWeight(FontWeight.Bold)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 8 })

          // ⭐ 两列网格 + 分割线
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
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .clip(true)
        .shadow({ radius: 24, color: '#40000000', offsetY: 6 })
        .position({ right: 16, top: 60 })
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
  }
}
