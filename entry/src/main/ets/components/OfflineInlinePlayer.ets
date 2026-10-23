// OfflineInlinePlayer.ets - 离线缓存页内嵌播放器
// 点击已完成缓存条目后原位展开播放（DASH 双流：video.m4s + audio.m4s）
// 独立的本地 AVPlayer 实例，与 PlayerService 全局播放器互不干扰
import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { preferences } from '@kit.ArkData';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { VibrateUtils } from '../utils/VibrateUtils';

/**
 * 离线缓存页内嵌播放器组件
 * 内部持有独立的视频/音频 AVPlayer，aboutToDisappear 时自动释放
 */
@Component
export struct OfflineInlinePlayer {
  /** 本地视频文件绝对路径（video.m4s / FLV 完整流） */
  @Prop videoPath: string = ''
  /** 本地音频文件绝对路径（DASH 分离流，仅分离时存在） */
  @Prop audioPath: string = ''
  /** 视频标识（历史进度记录用） */
  @Prop bvid: string = ''
  /** 视频 cid（历史进度记录用） */
  @Prop cid: number = 0
  /** 父组件请求进入内置全屏的信号（递增触发 @Watch，收起按钮旁的全屏按钮使用） */
  @Prop @Watch('onFullscreenRequest') fullscreenRequest: number = 0
  /** 关闭回调（父组件收起播放器） */
  onClose?: () => void

  // ⭐ 内置全屏（同一 AVPlayer 重绑 surface，无需跳转页面）
  @State isFullscreen: boolean = false
  private fsXc: XComponentController = new XComponentController()
  private mw: window.Window | null = null

  private av: media.AVPlayer | null = null
  private avAudio: media.AVPlayer | null = null
  private vFd: fs.File | null = null
  private aFd: fs.File | null = null
  private xc: XComponentController = new XComponentController()
  private surfaceId_: string = ''
  private initStarted_: boolean = false
  // ⭐ 声画同步（DASH 双流差距检测与追赶）
  private syncTimer_: number = -1
  private isSpeed2x_: boolean = false
  private isSpeedFixIn2xPhase_: boolean = false
  private lastSyncSeekTime_: number = 0
  private syncSeekCooldownMs_: number = 5000
  // ⭐ seek 完成 Promise 的 resolve（等待双播放器 seekDone 对齐）
  private videoSeekResolve_: (() => void) | null = null
  private audioSeekResolve_: (() => void) | null = null

  @State playing: boolean = false
  @State loading: boolean = true
  @State currentTime: number = 0
  @State duration: number = 0
  // 视频宽高比（宽/高）：横屏 16/9，竖屏 9/16，prepared 后按实际帧尺寸更新
  @State videoAspect: number = 16 / 9
  @State err: string = ''
  // 控制栏显隐（单击画面切换；双击暂停/继续）——展开时默认隐藏，单击画面唤出
  @State controlsVisible: boolean = false
  // ⭐ 展开高度模式：true=限高（屏高 55%，竖屏视频不占满）；false=全高（宽/宽高比）
  @State limitedHeight: boolean = true
  // ⭐ 缩放模式（与完整播放器一致：auto/fill/stretch/fitWidth/fitHeight）
  @State sm: string = 'auto'
  // ⭐ 音量/静音/亮度（手势调节，与完整播放器共享 globalVolume/globalMuted）
  @State vol: number = 0.8
  @State mute: boolean = false
  @State bri: number = 0.5
  // ⭐ 手势状态（参考 VideoPlayerPage onVT/onTD/onTM 系列）
  private sx_: number = 0
  private sy_: number = 0
  private st_: number = 0
  private sv_: number = 0
  private sb_: number = 0
  private gm_: string = ''          // '' / 'seek' / 'volume' / 'brightness'
  private ml_: boolean = false      // 是否已移动（区分点击与滑动）
  private sk_2: boolean = false     // 手势 seek 中标记
  // ⭐ 进度条拖动状态机（与 VideoPlayerPage/VideoControls 对齐）
  private sliderDragging_: boolean = false  // 进度条拖动中：冻结 timeUpdate 回写，避免滑块被播放位置拽回
  private seekInFlight_: boolean = false    // seek 进行中：last-wins 合并，避免并发 seek 打乱双流对齐
  private pendingSeekSec_: number = -1      // seek 期间收到的最新目标，结束后补提交
  private lastSeekBarCommitV_: number = -1  // 本次手势已提交的目标（Click/End 连续上报去重）
  private lastSeekHapticPct_: number = -1   // 手势 seek 档位震动（每 10% 一次）
  private screenH_: number = 0      // 屏幕高度 vp（手势灵敏度）
  private maxVol_: number = 15      // 系统媒体音量最大档位
  private ghTimer_: number = -1     // 手势提示隐藏计时器
  // 手势提示 UI（与完整播放器 sGH 一致：居中文字 + 进度条，800ms 自动隐藏）
  @State ghShow: boolean = false
  @State ghText: string = ''
  @State ghProgress: number = -1
  // 容器宽度 vp（手势 seek 灵敏度）
  private containerW_: number = 0
  private topAreaTouch_: boolean = false
  // 历史进度（离线专用，Preferences 键 offline_progress_{bvid}_{cid}）
  private progressLoaded_: boolean = false

  aboutToAppear(): void {
    // ⭐ 状态记忆：加载缩放模式/音量/静音（与完整播放器共享 Preferences 'VPS' 与 AppStorage）
    this.loadState();
    this.initPlayer();
  }

  aboutToDisappear(): void {
    // ⭐ 退出前保存历史进度
    this.saveProgress();
    this.releaseAll();
  }

  /** 加载状态记忆：缩放模式（Preferences 'VPS'.sm）+ 音量/静音（AppStorage globalVolume/globalMuted） */
  private loadState(): void {
    try {
      const sm = AppStorage.get<string>('playerScaleMode');
      if (sm) this.sm = sm;
      const gv = AppStorage.get<number>('globalVolume');
      if (gv !== undefined) this.vol = gv;
      const gm = AppStorage.get<boolean>('globalMuted');
      if (gm !== undefined) this.mute = gm;
    } catch (e) { }
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context;
      preferences.getPreferences(ctx, 'VPS').then((pf) => {
        pf.get('sm', 'auto').then((saved: preferences.ValueType) => {
          if (typeof saved === 'string' && saved) {
            this.sm = saved;
            AppStorage.setOrCreate<string>('playerScaleMode', saved);
          }
        }).catch(() => { });
      }).catch(() => { });
    } catch (e) { }
  }

  /** XComponent surface 就绪回调 */
  private onXCLoad(): void {
    this.surfaceId_ = this.xc.getXComponentSurfaceId();
    this.initPlayer();
  }

  /**
   * 初始化播放器（幂等）：等待 surfaceId 就绪 → 创建 AVPlayer → fdSrc
   * 用 fdSrc 属性，兼容 API 24/26；createMediaSourceWithUrl/Fd 均不跨版本通用
   */
  private async initPlayer(): Promise<void> {
    if (this.initStarted_ || !this.videoPath) return;
    if (!this.surfaceId_) {
      const id = this.xc.getXComponentSurfaceId();
      if (!id) {
        // ⭐ build 完成后 surface 才就绪，延迟重试（参考 resumeFromMinimized 300ms 模式）
        setTimeout(() => { this.initPlayer(); }, 300);
        return;
      }
      this.surfaceId_ = id;
    }
    this.initStarted_ = true;
    try {
      logInfo(`[OfflineInlinePlayer] 初始化: ${this.videoPath}`);
      this.av = await media.createAVPlayer();
      if (!this.av) throw new Error('no player');
      this.setupL();
      this.vFd = fs.openSync(this.videoPath, fs.OpenMode.READ_ONLY);
      const vFd: media.AVFileDescriptor = { fd: this.vFd.fd, offset: 0 };
      this.av.fdSrc = vFd;
      if (this.audioPath) {
        this.avAudio = await media.createAVPlayer();
        if (this.avAudio) {
          this.setupAudioL();
          this.aFd = fs.openSync(this.audioPath, fs.OpenMode.READ_ONLY);
          const aFd: media.AVFileDescriptor = { fd: this.aFd.fd, offset: 0 };
          this.avAudio.fdSrc = aFd;
        }
      }
    } catch (e) {
      logError(`[OfflineInlinePlayer] 初始化失败: ${JSON.stringify(e)}`);
      this.err = '播放器初始化失败';
      this.loading = false;
      this.releaseAll();
    }
  }

  /** 视频播放器状态监听 */
  private setupL(): void {
    if (!this.av) return;
    this.av.on('stateChange', async (st: string) => {
      switch (st) {
        case 'initialized':
          if (this.surfaceId_) {
            this.av!.surfaceId = this.surfaceId_;
            await this.av!.prepare();
          } else {
            logWarn('[OfflineInlinePlayer] initialized 但 surfaceId 未就绪，延迟重试');
            setTimeout(async () => {
              const retryId = this.xc.getXComponentSurfaceId();
              if (retryId && this.av && this.av.state === 'initialized') {
                this.surfaceId_ = retryId;
                this.av.surfaceId = retryId;
                await this.av.prepare();
              }
            }, 300);
          }
          break;
        case 'prepared':
          this.loading = false;
          this.duration = (this.av?.duration || 0) / 1000;
          try { this.av?.setVolume(1.0); } catch (e) { }
          // ⭐ 应用记忆的静音状态（与完整播放器一致：播放器增益 1.0，音量由系统控制）
          if (this.mute) this.setSystemVolume(0);
          // ⭐ 根据用户选择的缩放模式动态设置 videoScaleType（与完整播放器一致）
          try {
            this.av!.videoScaleType = this.getVideoScaleType();
          } catch (e) { }
          // ⭐ 恢复历史进度（离线播放记忆上次观看位置）
          this.applySavedProgress();
          await this.av?.play();
          // 音频已就绪则同步播放
          if (this.avAudio && (this.avAudio.state === 'prepared' || this.avAudio.state === 'paused')) {
            await this.avAudio.play();
          }
          this.playing = true;
          // ⭐ 启动声画同步检测（DASH 双流差距检测与追赶）
          this.startSpeedSync();
          break;
        case 'completed':
          this.playing = false;
          break;
        case 'error':
          this.err = '播放失败';
          this.loading = false;
          break;
      }
    });
    this.av.on('timeUpdate', (t: number) => {
      // ⭐ 拖动进度条中 / seek 收敛期不回写 currentTime：
      //   Slider 的 value 就是 currentTime，手指拖到 A、播放器立刻写回 B、下一帧 Slider 再写回 A，
      //   滑块与手指互相争夺（表现为"拖不动 / 黏手 / 回弹"）。
      //   seek 刚发出时 timeUpdate 仍带旧位置，回写同样会把滑块弹回起点。
      if (this.sliderDragging_ || this.seekInFlight_) return;
      this.currentTime = t / 1000;
      // ⭐ 历史进度：每 5 秒节流保存一次（Preference 写入较慢，节流避免高频 flush）
      if (Math.floor(this.currentTime) % 5 === 0) {
        this.saveProgress();
      }
    });
    // ⭐ 注册 seekDone 回调，用于同步等待 seek 完成（双播放器对齐）
    this.av.on('seekDone', (_pos: number) => {
      if (this.videoSeekResolve_) {
        this.videoSeekResolve_();
        this.videoSeekResolve_ = null;
      }
    });
    this.av.on('videoSizeChange', (w: number, h: number) => {
      logInfo(`[OfflineInlinePlayer] videoSizeChange: ${w}x${h}`);
      if (w > 0 && h > 0) {
        this.videoAspect = w / h;
        // ⭐ 全屏状态下获取实际尺寸后更新方向（右滑直接全屏时 videoAspect 还未就绪）
        if (this.isFullscreen && this.mw) {
          this.mw.setPreferredOrientation(
            w >= h ? window.Orientation.AUTO_ROTATION_LANDSCAPE
                   : window.Orientation.AUTO_ROTATION_PORTRAIT
          );
        }
      }
    });
    this.av.on('error', (e: BusinessError) => {
      logWarn(`[OfflineInlinePlayer] 视频播放错误: code=${e.code}, message=${e.message}`);
      if (e.code !== 5400102) {
        this.err = `播放错误:${e.message}`;
        this.loading = false;
      }
    });
  }

  /** 音频播放器状态监听（不绑定 surface） */
  private setupAudioL(): void {
    if (!this.avAudio) return;
    this.avAudio.on('stateChange', async (st: string) => {
      if (st === 'initialized') {
        await this.avAudio?.prepare();
      } else if (st === 'prepared') {
        try { this.avAudio?.setVolume(1.0); } catch (e) { }
        // 视频已播放时音频立即跟上
        if (this.playing && (this.avAudio?.state === 'prepared' || this.avAudio?.state === 'paused')) {
          await this.avAudio.play();
        }
      }
    });
    this.avAudio.on('error', (e: BusinessError) => {
      logWarn(`[OfflineInlinePlayer] 音频播放错误: code=${e.code}, message=${e.message}`);
    });
    // ⭐ 注册 seekDone 回调，用于同步等待 seek 完成（双播放器对齐）
    this.avAudio.on('seekDone', (_pos: number) => {
      if (this.audioSeekResolve_) {
        this.audioSeekResolve_();
        this.audioSeekResolve_ = null;
      }
    });
  }

  /** 单击：切换控制栏显隐 */
  private toggleControls(): void {
    this.controlsVisible = !this.controlsVisible;
  }

  /** 暂停/继续（双播放器同步） */
  private togglePlay(): void {
    if (!this.av) return;
    try {
      if (this.playing) {
        this.av.pause();
        if (this.avAudio) this.avAudio.pause();
        this.playing = false;
        // 暂停时停止声画同步检测
        this.cancelSpeedSync();
      } else {
        // 播放到结尾后重播：先归零
        if (this.av.state === 'completed') {
          this.av.seek(0);
          if (this.avAudio) this.avAudio.seek(0);
          this.currentTime = 0;
        }
        this.av.play();
        const aState: string = this.avAudio ? this.avAudio.state : '';
        if (this.avAudio && (aState === 'prepared' || aState === 'paused' || aState === 'completed')) {
          this.avAudio.play();
        }
        this.playing = true;
        // ⭐ 恢复播放后重新启动声画同步检测
        this.startSpeedSync();
      }
    } catch (e) {
      logWarn(`[OfflineInlinePlayer] togglePlay 异常: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 进度拖动 seek（双播放器同步）
   * 等待两个 seekDone 回调完成后再继续，避免双流 seek 耗时不同导致音画错位
   *
   * ⭐ 三轮加固（对照 VideoPlayerPage.seek）：
   *  1) **超时兜底**：原实现 `Promise.race([..., timeout])` 里 timeout 走的是"成功"分支，
   *     若某一路 seekDone 永远不来，会一直 await 到 2s；若监听未注册则 resolve 永远为 null ⇒ 永久挂起。
   *  2) **last-wins**：拖动过程中连发多次 seekTo，旧实现每次都会新建 resolve 并覆盖成员变量，
   *     前一次的 Promise 再也没人 resolve（悬挂），且多路 seek 并发落盘会打乱双流对齐。
   *     现改为：seek 进行中只记录最新目标，结束后补提交一次。
   *  3) **精确落点**：默认 SeekMode 是 SEEK_PREV_SYNC（回退到前一关键帧），
   *     长 GOP 视频会明显"跳不到位"，改用 SEEK_CLOSEST。
   * @param sec 目标秒数
   * @param interactive 是否用户交互触发（交互时首帧等待缩短，手感优先）
   */
  private async seekTo(sec: number, interactive: boolean = false): Promise<void> {
    this.currentTime = sec;   // 立即回显，UI 不等待解码
    if (!this.av) return;
    // ⭐ last-wins：已在 seek 中则只记录最新目标，由 finally 补提交
    if (this.seekInFlight_) {
      this.pendingSeekSec_ = sec;
      return;
    }
    this.seekInFlight_ = true;
    try {
      // 创建等待 seekDone 的 Promise（参照 VideoPlayerPage 的 seek 同步等待模式）
      const videoSeekDone = new Promise<void>(resolve => { this.videoSeekResolve_ = resolve; });
      const audioSeekDone = this.avAudio
        ? new Promise<void>(resolve => { this.audioSeekResolve_ = resolve; })
        : Promise.resolve();
      // 执行 seek 操作：优先 SEEK_CLOSEST（精确落到目标帧），老接口不支持时回退默认模式
      try {
        this.av.seek(sec * 1000, media.SeekMode.SEEK_CLOSEST);
        if (this.avAudio) {
          this.avAudio.seek(sec * 1000, media.SeekMode.SEEK_CLOSEST);
        }
      } catch (e) {
        this.av.seek(sec * 1000);
        if (this.avAudio) {
          this.avAudio.seek(sec * 1000);
        }
      }
      // ⭐ 超时兜底：交互路径 900ms（离线本地文件首帧很快），恢复历史进度 2s
      await Promise.race([
        Promise.all([videoSeekDone, audioSeekDone]),
        this.delaySec_(interactive ? 900 : 2000)
      ]);
      // seek 完成后：停止正在进行的 2x 追赶（位置已重置），若在播放则重启同步检测
      this.cancelSpeedSync();
      if (this.playing) {
        this.startSpeedSync();
      }
    } catch (e) {
      logWarn(`[OfflineInlinePlayer] seek 异常: ${JSON.stringify(e)}`);
    } finally {
      // ⭐ 无论成功/超时/异常都要摘掉 resolve，否则残留的 resolver 会被下一次 seekDone 误触发
      this.videoSeekResolve_ = null;
      this.audioSeekResolve_ = null;
      this.seekInFlight_ = false;
      const pending = this.pendingSeekSec_;
      this.pendingSeekSec_ = -1;
      if (pending >= 0) {
        // 拖动期间攒下的最后一次目标，补提交（下一轮事件循环，避免递归过深）
        setTimeout(() => { this.seekTo(pending, interactive); }, 0);
      }
    }
  }

  /** setTimeout 版延时（Promise.race 超时兜底用） */
  private delaySec_(ms: number): Promise<void> {
    return new Promise<void>(resolve => { setTimeout(resolve, ms); });
  }

  /** 档位触觉反馈（与完整播放器 fireHaptic 对齐） */
  private fireHaptic_(durationMs: number = 10): void {
    try {
      VibrateUtils.vibrateTime(durationMs);
    } catch (e) { }
  }

  /**
   * 进度条拖动状态机（两个 Slider 共用）
   * 旧实现 `.onChange((v) => this.seekTo(v))` 会在 **Moving** 阶段也提交 seek：
   * 拖动 1 秒可产生几十次 seek，每次都 await 双 seekDone（最长 2s 超时），
   * 声画同步的 `cancelSpeedSync/startSpeedSync` 被抛来抛去，长视频拖动直接卡住。
   * 现按 SliderChangeMode 分流：
   *  - Begin / Moving：只更新显示 + 冻结 timeUpdate 回写，一次 seek 都不发
   *  - End / Click：提交**一次**真实 seek
   */
  private onSeekBarChange_(v: number, mode: SliderChangeMode): void {
    // ⭐ 与完整播放器一致：拖动/点击进度条时也给「时间 + 小进度条」提示
    //   （拖动中每条上报都会续期，松手后 800ms 自动淡出；时长未知时不弹）
    if (this.duration > 0) {
      this.showGestureHint(this.formatTime(Math.round(v)), v / this.duration);
    }
    if (mode === SliderChangeMode.Begin) {
      this.sliderDragging_ = true;
      this.cancelSpeedSync();   // 拖动期停声画追赶，避免和 seek 抢解码器
      return;
    }
    if (mode === SliderChangeMode.Moving) {
      this.sliderDragging_ = true;
      this.currentTime = v;
      return;
    }
    // End / Click：提交
    this.sliderDragging_ = false;
    if (this.duration <= 0) {
      // 时长未知不提交（避免 seek 到 0），但必须把拖动期暂停的声画追赶恢复回来
      if (this.playing) this.startSpeedSync();
      return;
    }
    this.seekTo(v, true);
  }

  /** 拖动被系统中断（来电/多任务/父容器抢事件）时不会回调 onChange End，这里兜底解冻并提交 */
  private onSeekBarTouch_(e: TouchEvent): void {
    if (e.type === TouchType.Cancel && this.sliderDragging_) {
      this.sliderDragging_ = false;
      if (this.duration > 0) {
        this.seekTo(this.currentTime, true);
      } else if (this.playing) {
        this.startSpeedSync();
      }
    }
  }

  /**
   * 根据当前缩放模式获取对应的 VideoScaleType（与 VideoPlayerPage.getVideoScaleType 一致）
   */
  private getVideoScaleType(): media.VideoScaleType {
    switch (this.sm) {
      case 'stretch':
        // 拉伸模式：强制拉伸视频至窗口大小，不保持宽高比
        return media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
      case 'fill':
      case 'fitHeight':
        // 填充模式/等高模式：保持宽高比，裁剪填充
        return media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP;
      case 'auto':
      case 'fitWidth':
      default:
        // 自动模式/等宽模式：保持宽高比，可能留黑边
        return media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
    }
  }

  /** 切换缩放模式（auto → fill → stretch 循环）并持久化，与完整播放器共享 Preferences 键 'sm' */
  private cycleScaleMode(): void {
    const modes: string[] = ['auto', 'fill', 'stretch'];
    const curIdx: number = modes.indexOf(this.sm);
    this.sm = modes[(curIdx + 1) % modes.length];
    try {
      if (this.av) this.av.videoScaleType = this.getVideoScaleType();
    } catch (e) { }
    // ⭐ 状态记忆：持久化到 Preferences 'VPS'（与 VideoPlayerPage.loadSM/saveSM 同键）
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context;
      preferences.getPreferences(ctx, 'VPS').then((pf) => {
        pf.put('sm', this.sm).then(() => { pf.flush(); });
      }).catch(() => { });
    } catch (e) { }
  }

  /** 缩放模式显示文案（与完整播放器比例按钮一致） */
  private scaleModeLabel(): string {
    switch (this.sm) {
      case 'fill':
        return '填充';
      case 'stretch':
        return '拉伸';
      case 'auto':
      default:
        return '适应';
    }
  }

  /**
   * 恢复历史进度（离线播放记忆）：从 Preferences 读取 offline_progress_{bvid}_{cid}
   * prepared 后调用，seek 到上次位置
   */
  private applySavedProgress(): void {
    if (this.progressLoaded_ || !this.bvid || this.duration <= 0) return;
    this.progressLoaded_ = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context;
      preferences.getPreferences(ctx, 'VPS').then((pf) => {
        pf.get(`offline_progress_${this.bvid}_${this.cid}`, 0).then((saved: preferences.ValueType) => {
          const sec: number = Number(saved);
          if (sec > 5 && sec < this.duration - 5) {
            logInfo(`[OfflineInlinePlayer] 恢复历史进度: ${sec}s`);
            this.seekTo(sec);
          }
        }).catch(() => { });
      }).catch(() => { });
    } catch (e) { }
  }

  /** 保存历史进度（timeUpdate 周期调用，节流由调用侧控制） */
  private saveProgress(): void {
    if (!this.bvid || this.currentTime <= 5) return;
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context;
      preferences.getPreferences(ctx, 'VPS').then((pf) => {
        pf.put(`offline_progress_${this.bvid}_${this.cid}`, Math.floor(this.currentTime)).then(() => { pf.flush(); });
      }).catch(() => { });
    } catch (e) { }
  }

  /**
   * 速率值 → PlaybackSpeed 枚举索引映射（同步追赶用）
   * AVPlaybackSpeed: 0=0.75x, 1=1.0x, 2=1.25x, 3=1.75x, 4=2.0x, 5=0.5x, 6=1.5x, 7=3.0x
   */
  private rateToSpeedIdx(rate: number): number {
    if (rate <= 0.625) return 5;  // 0.5x
    if (rate <= 0.875) return 0;  // 0.75x
    if (rate <= 1.125) return 1;  // 1.0x
    if (rate <= 1.375) return 2;  // 1.25x
    if (rate <= 1.625) return 6;  // 1.5x
    if (rate <= 1.875) return 3;  // 1.75x
    if (rate <= 2.5) return 4;    // 2.0x
    return 7;                     // 3.0x
  }

  /** 启动声画同步检测（播放开始时调用，每 5s 检查一次） */
  private startSpeedSync(): void {
    this.cancelSpeedSync();
    this.syncTimer_ = setInterval(() => { this.checkAndSyncSpeed(); }, 5000);
  }

  /** 停止声画同步检测并恢复 1x */
  private cancelSpeedSync(): void {
    if (this.syncTimer_ !== -1) {
      clearInterval(this.syncTimer_);
      this.syncTimer_ = -1;
    }
    if (this.isSpeed2x_) {
      try { this.av?.setSpeed(this.rateToSpeedIdx(1.0)); } catch (e) { }
      this.isSpeed2x_ = false;
      this.isSpeedFixIn2xPhase_ = false;
    }
  }

  /**
   * 检查声画同步状态（参考 VideoPlayerPage.checkAndSyncSpeed 精简版）
   * diffMs = 音频位置 - 视频位置；正数=视频落后，负数=音频落后
   */
  private checkAndSyncSpeed(): void {
    if (!this.av || !this.avAudio) return;
    if (this.av.state === 'released' || this.avAudio.state === 'released') return;
    if (!this.playing) {
      this.cancelSpeedSync();
      return;
    }
    let videoPos: number = 0;
    let audioPos: number = 0;
    try { videoPos = this.av.currentTime; } catch (e) { }
    try { audioPos = this.avAudio.currentTime; } catch (e) { }
    if (videoPos <= 0 || audioPos <= 0) return;

    const diffMs: number = audioPos - videoPos;

    // ✅ 已同步（差距 < 300ms），恢复 1x
    if (Math.abs(diffMs) < 300) {
      if (this.isSpeed2x_) {
        try { this.av.setSpeed(this.rateToSpeedIdx(1.0)); } catch (e) { }
        this.isSpeed2x_ = false;
        this.isSpeedFixIn2xPhase_ = false;
      }
      return;
    }

    // 2x 追赶阶段：坚持 2x 直到追平，不中途切换为 seek
    if (this.isSpeedFixIn2xPhase_) {
      if (!this.isSpeed2x_) {
        try { this.av.setSpeed(this.rateToSpeedIdx(2.0)); } catch (e) { }
        this.isSpeed2x_ = true;
      }
      return;
    }

    // ⭐ 音频落后视频（diffMs < 0）：seek 音频前进追视频（音频 seek 开销远小于视频）
    if (diffMs < -3000 && (Date.now() - this.lastSyncSeekTime_) > this.syncSeekCooldownMs_) {
      const audioSeekTarget: number = Math.max(1000, videoPos - 500);
      try {
        this.avAudio?.seek(audioSeekTarget, media.SeekMode.SEEK_PREV_SYNC);
        this.lastSyncSeekTime_ = Date.now();
      } catch (e) { }
      return;
    }

    // 视频落后音频 > 3s 且 seek 冷却期已过 → 视频 seek
    if (diffMs > 3000 && (Date.now() - this.lastSyncSeekTime_) > this.syncSeekCooldownMs_) {
      const seekTarget: number = Math.max(1000, audioPos - 500);
      try {
        this.av.seek(seekTarget, media.SeekMode.SEEK_PREV_SYNC);
        this.lastSyncSeekTime_ = Date.now();
      } catch (e) { }
      return;
    }

    // 差距 > 1s 且不在 2x 阶段 → 启动 2x 追赶（仅视频落后音频时，音频 2x 会变调）
    if (diffMs > 1000 && !this.isSpeed2x_) {
      try { this.av.setSpeed(this.rateToSpeedIdx(2.0)); } catch (e) { }
      this.isSpeed2x_ = true;
      this.isSpeedFixIn2xPhase_ = true;
    }
  }

  /** 释放播放器与文件 fd（组件销毁时调用） */
  private releaseAll(): void {
    this.cancelSpeedSync();
    try {
      if (this.av) {
        this.av.off('stateChange');
        this.av.off('timeUpdate');
        this.av.off('seekDone');
        this.av.off('error');
        this.av.off('videoSizeChange');
        this.av.release();
        this.av = null;
      }
      if (this.avAudio) {
        this.avAudio.off('stateChange');
        this.avAudio.off('seekDone');
        this.avAudio.off('error');
        this.avAudio.release();
        this.avAudio = null;
      }
    } catch (e) {
      logWarn(`[OfflineInlinePlayer] 释放播放器异常: ${JSON.stringify(e)}`);
    }
    if (this.vFd) {
      try { fs.closeSync(this.vFd); } catch (e) { }
      this.vFd = null;
    }
    if (this.aFd) {
      try { fs.closeSync(this.aFd); } catch (e) { }
      this.aFd = null;
    }
  }

  /**
   * 进入内置全屏：旋转横屏 + 隐藏系统栏 + 全屏 surface 重绑
   * 复用同一 AVPlayer（surfaceId 重新指向全屏 XComponent），不产生第二个播放器
   */
  private async enterFullscreen(): Promise<void> {
    if (this.isFullscreen) return;
    try {
      await this.initWindow_();
      if (this.mw) {
        // 进入横屏全屏播放状态（视频横屏时横屏，竖屏视频保持竖屏全屏）
        await this.mw.enableLandscapeMultiWindow();
        await this.mw.setPreferredOrientation(
          this.videoAspect >= 1 ? window.Orientation.AUTO_ROTATION_LANDSCAPE
                                : window.Orientation.AUTO_ROTATION_PORTRAIT
        );
        this.mw.setWindowSystemBarEnable([]);
      }
      this.isFullscreen = true;
      // surface 重绑由全屏 XComponent 的 onLoad 触发（onFsXCLoad）
    } catch (e) {
      logWarn(`[OfflineInlinePlayer] 进入全屏失败: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 退出内置全屏（按钮触发）
   * 只需置 false 关闭全屏层；恢复方向/系统栏/surface 统一由 onDisappear 处理
   * （系统返回键关闭时 $$ 直接置 false，同样会触发 onDisappear，不会遗漏）
   */
  private exitFullscreen(): void {
    if (!this.isFullscreen) return;
    this.isFullscreen = false;
  }

  /**
   * 全屏层关闭回调（onDisappear）：无论按钮/系统返回键/$$ 置 false 关闭都会触发
   * 恢复屏幕方向与系统栏 + surface 重绑回内嵌 XComponent
   */
  private onFullscreenDisappear(): void {
    this.restoreWindowAfterFullscreen();
    // 等全屏 XComponent 销毁后再把 surface 绑回内嵌 XComponent
    setTimeout(() => { this.rebindToInlineSurface(); }, 200);
  }

  /** 恢复屏幕方向（按用户 screenOrientationLock 设置）与系统栏 */
  private async restoreWindowAfterFullscreen(): Promise<void> {
    try {
      if (this.mw) {
        await this.mw.disableLandscapeMultiWindow();
        // ⭐ 恢复屏幕方向：按用户设置恢复，否则会停留在横屏无法自由旋转
        const lock = AppStorage.get<string>('screenOrientationLock') ?? '自动旋转';
        let orientation: window.Orientation;
        switch (lock) {
          case '锁定竖屏':
            orientation = window.Orientation.PORTRAIT;
            break;
          case '锁定横屏':
            orientation = window.Orientation.AUTO_ROTATION_LANDSCAPE;
            break;
          default:
            orientation = window.Orientation.AUTO_ROTATION;
            break;
        }
        await this.mw.setPreferredOrientation(orientation);
        this.mw.setWindowSystemBarEnable(['status', 'navigation']);
      }
    } catch (e) {
      logWarn(`[OfflineInlinePlayer] 退出全屏恢复失败: ${JSON.stringify(e)}`);
    }
  }

  /** 获取窗口实例（惰性） */
  private async initWindow_(): Promise<void> {
    if (this.mw) return;
    try {
      this.mw = await window.getLastWindow(this.getUIContext().getHostContext() as common.Context);
    } catch (e) {
      logWarn(`[OfflineInlinePlayer] 获取窗口失败: ${JSON.stringify(e)}`);
    }
  }

  /** 全屏 XComponent surface 就绪：把 AVPlayer surfaceId 重绑到全屏 */
  private onFsXCLoad(): void {
    const fsId = this.fsXc.getXComponentSurfaceId();
    if (!fsId || !this.av || this.av.state === 'released') return;
    try {
      this.av.surfaceId = fsId;
      logInfo(`[OfflineInlinePlayer] 全屏 surface 绑定: ${fsId}`);
    } catch (e) {
      logWarn(`[OfflineInlinePlayer] 全屏 surface 绑定失败: ${JSON.stringify(e)}`);
    }
  }

  /** 把 AVPlayer surfaceId 重绑回内嵌 XComponent（退出全屏后） */
  private rebindToInlineSurface(): void {
    if (!this.av || this.av.state === 'released') return;
    const inlineId = this.xc.getXComponentSurfaceId();
    if (!inlineId) return;
    try {
      this.av.surfaceId = inlineId;
      logInfo(`[OfflineInlinePlayer] 恢复内嵌 surface 绑定: ${inlineId}`);
    } catch (e) {
      logWarn(`[OfflineInlinePlayer] 恢复内嵌 surface 失败: ${JSON.stringify(e)}`);
    }
  }

  /** 设置系统媒体音量（档位动态获取，与 VideoPlayerPage.setSystemVolume 一致） */
  private setSystemVolume(vol: number): void {
    try {
      const v: number = Math.round(vol * this.maxVol_);
      audio.getAudioManager().setVolume(audio.AudioVolumeType.MEDIA, v);
    } catch (e) { }
  }

  /** 手势提示（与完整播放器 sGH 一致，800ms 自动隐藏） */
  private showGestureHint(text: string, progress: number): void {
    this.ghText = text;
    this.ghProgress = progress;
    this.ghShow = true;
    if (this.ghTimer_ !== -1) {
      clearTimeout(this.ghTimer_);
      this.ghTimer_ = -1;
    }
    this.ghTimer_ = setTimeout(() => {
      this.ghShow = false;
      this.ghTimer_ = -1;
    }, 800);
  }

  /** 触摸入口：Down 记录起点；Move 判定并调节（点击类交给 TapGesture） */
  private onVT = (e: TouchEvent): void => {
    switch (e.type) {
      case TouchType.Down:
        this.onTD(e);
        break;
      case TouchType.Move:
        if (this.topAreaTouch_) return;
        this.onTM(e);
        break;
      case TouchType.Up:
        if (this.topAreaTouch_) { this.topAreaTouch_ = false; return; }
        this.onTU(e);
        break;
      case TouchType.Cancel:
        if (this.topAreaTouch_) { this.topAreaTouch_ = false; return; }
        this.onTC();
        break;
    }
  }

  private onTD(e: TouchEvent): void {
    if (e.touches.length === 0) return;
    const t = e.touches[0];
    // 全屏时顶部状态栏区域跳过播放器手势（避免与系统下拉冲突，与完整播放器一致）
    if (this.isFullscreen && t.windowY < 60) {
      this.topAreaTouch_ = true;
      return;
    }
    this.sx_ = t.windowX;
    this.sy_ = t.windowY;
    this.st_ = this.currentTime;
    this.sv_ = this.vol;
    this.sb_ = this.bri;
    this.ml_ = false;
    this.gm_ = '';
    // 惰性获取屏幕尺寸（手势灵敏度）
    if (this.containerW_ <= 0) {
      try {
        const d = display.getDefaultDisplaySync();
        this.containerW_ = this.getUIContext().px2vp(d.width);
        this.screenH_ = this.getUIContext().px2vp(d.height);
      } catch (e) { }
    }
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
    }
    if (!this.ml_) return;
    if (this.gm_ === '') {
      // ⭐ 非全屏（内嵌小窗）：任何方向滑动都不拦截（包括左右 seek），全部让位 List 滚动
      if (!this.isFullscreen) return;
      // 全屏：水平主导 → seek；垂直主导 → 左半屏亮度 / 右半屏音量
      if (adx >= ady * 0.8) {
        this.gm_ = 'seek';
        this.lastSeekHapticPct_ = -1;   // 进入 seek 手势时重置档位，首个 10% 档位立刻有反馈
      } else {
        if (t.windowX < this.containerW_ / 2) {
          this.gm_ = 'brightness';
        } else {
          this.gm_ = 'volume';
        }
      }
    }
    if (this.gm_ === 'seek') {
      // ⭐ 时长未知（加载中 / 直播）时不能按比例换算：原先 nt 恒等于按下位置，
      //   却照样弹手势提示，看起来"拖了没反应"
      if (this.duration <= 0) return;
      // ⭐ 灵敏度按时长自适应：原先固定 duration * 0.3 —— 10 分钟视频整屏宽滑 = 3 分钟，
      //   1vp ≈ 0.9 秒，想微调 2 秒物理上做不到；2 小时视频整屏滑 = 36 分钟更失控。
      //   分母继续用 containerW_（seek 手势只在内嵌全屏层生效，此时 XComponent 宽 = 屏宽，与手势落点同源）
      const secPerScreen = this.duration <= 600 ? this.duration * 0.5
        : (this.duration <= 3600 ? this.duration * 0.3 : Math.max(this.duration * 0.12, 600));
      const baseW = Math.max(1, this.containerW_);
      let nt = this.st_ + (dx / baseW) * secPerScreen;
      nt = Math.min(Math.max(nt, 0), this.duration);
      this.currentTime = nt;
      this.sk_2 = true;
      // ⭐ 档位震动：与音量/亮度"每跨越 10% 震一次"的手感对齐（原先 seek 全程零触觉反馈）
      const seekPct = Math.round(nt / this.duration * 100);
      if (this.lastSeekHapticPct_ === -1 || Math.abs(seekPct - this.lastSeekHapticPct_) >= 10) {
        this.fireHaptic_(10);
        this.lastSeekHapticPct_ = seekPct;
      }
      this.showGestureHint(this.formatTime(Math.round(nt)), nt / this.duration);
    } else if (this.gm_ === 'volume') {
      const volSensitivity = this.screenH_ > 0 ? this.screenH_ * 0.7 : 700;
      let v = this.sv_ + dy / volSensitivity;
      v = Math.min(1, Math.max(0, v));
      this.vol = v;
      this.setSystemVolume(v);
      this.mute = (v === 0);
      AppStorage.setOrCreate('globalVolume', this.vol);
      AppStorage.setOrCreate('globalMuted', this.mute);
      this.showGestureHint(`${Math.round(v * 100)}%`, v);
    } else if (this.gm_ === 'brightness') {
      const briSensitivity = this.screenH_ > 0 ? this.screenH_ * 0.7 : 700;
      let b = this.sb_ + dy / briSensitivity;
      b = Math.min(1, Math.max(0, b));
      this.bri = b;
      try {
        if (this.mw) this.mw.setWindowBrightness(b);
      } catch (e) { }
      this.showGestureHint(`${Math.round(b * 100)}%`, b);
    }
  }

  private onTU(_e: TouchEvent): void {
    // 滑动 seek 结束：提交真实 seek（等待双 seekDone 对齐）
    if (this.sk_2) {
      this.sk_2 = false;
      // ⭐ interactive=true：交互路径用更短的 seekDone 等待窗口，避免松手后要等满 2 秒才恢复同步检测
      this.seekTo(this.currentTime, true);
    }
    this.gm_ = '';
    this.ml_ = false;
    this.lastSeekHapticPct_ = -1;
  }

  private onTC(): void {
    this.gm_ = '';
    this.ml_ = false;
    this.sk_2 = false;
    if (this.ghTimer_ !== -1) {
      clearTimeout(this.ghTimer_);
      this.ghTimer_ = -1;
    }
    this.ghShow = false;
  }

  /** 时间格式化 mm:ss */
  private formatTime(sec: number): string {
    const s = Math.max(0, Math.floor(sec));
    const m = Math.floor(s / 60);
    const r = s % 60;
    return `${m}:${r < 10 ? '0' + r : r}`;
  }

  /** 当前是否横屏（屏宽 > 屏高） */
  private isLandscapeNow(): boolean {
    return this.containerW_ > this.screenH_;
  }

  /**
   * 展开高度：限高模式 = min(容器宽/宽高比, 屏高×55%)，竖屏视频不再占满；
   * 全高模式 = 容器宽/宽高比（视频宽高比自适应）
   * 容器宽：横屏两列时用列宽（(屏宽-40)/2），竖屏时整行宽
   */
  private expandedHeight(): number {
    if (this.containerW_ <= 0 || this.screenH_ <= 0) {
      try {
        const d = display.getDefaultDisplaySync();
        this.containerW_ = this.getUIContext().px2vp(d.width);
        this.screenH_ = this.getUIContext().px2vp(d.height);
      } catch (e) { }
    }
    const isLs = this.isLandscapeNow();
    const w = this.containerW_ > 0
      ? (isLs ? (this.containerW_ - 40) / 2 : this.containerW_)
      : 360;
    const fullH = w / this.videoAspect;
    if (!this.limitedHeight) return fullH;
    const maxH = (this.screenH_ > 0 ? this.screenH_ : 800) * 0.55;
    return Math.min(fullH, maxH);
  }

  /**
   * 视频容器宽度：横屏时 = 高度×宽高比（自适应无黑边，横屏视频=列宽、竖屏视频收窄居中）；
   * 竖屏时整行 100%
   */
  private videoWidth(): number | string {
    if (!this.isLandscapeNow()) return '100%';
    return this.expandedHeight() * this.videoAspect;
  }

  /** 切换全高/限高模式 */
  private toggleHeightMode(): void {
    this.limitedHeight = !this.limitedHeight;
  }

  /** @Watch 回调：父组件点击外部全屏按钮 → 触发内置全屏 */
  private onFullscreenRequest(): void {
    if (this.fullscreenRequest > 0 && !this.isFullscreen) {
      this.enterFullscreen();
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 视频画面：宽度横屏时自适应视频比例（无黑边），竖屏整行；高度按 expandedHeight
      XComponent({ id: 'offline_inline_xc', type: XComponentType.SURFACE, controller: this.xc })
        .onLoad(() => { this.onXCLoad(); })
        .width(this.videoWidth())
        .height(this.expandedHeight())
        .backgroundColor(Color.Black)
        .clip(true)
        // ⭐ 滑动调节手势（左右进度/上下亮度音量）；点击类由下方 TapGesture 处理
        .onTouch(this.onVT)
        // ⭐ 单击切换控制栏显隐，双击暂停/继续（Exclusive 互斥，双击不会误触单击）
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 2 }).onAction(() => { this.togglePlay(); }),
            TapGesture({ count: 1 }).onAction(() => { this.toggleControls(); })
          )
        )

      // 加载中（无背景不参与命中，点击穿透到 XComponent）
      if (this.loading) {
        Row() {
          LoadingProgress()
            .width(36).height(36)
            .color(Color.White)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
      }

      // ⭐ 手势提示（与完整播放器一致：居中文字 + 进度条，800ms 自动隐藏；无背景不拦截触摸）
      if (this.ghShow) {
        Column({ space: 8 }) {
          Text(this.ghText)
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
          if (this.ghProgress >= 0) {
            Progress({ value: this.ghProgress, total: 1, type: ProgressType.Linear })
              .width(160).height(4)
              .color('#FF8A00')
              .backgroundColor('#66FFFFFF')
          }
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      // 播放失败提示
      if (this.err !== '') {
        Column({ space: 12 }) {
          Text(this.err)
            .fontSize(14)
            .fontColor(Color.White)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
      }

      // 底部控制层（单击画面可隐藏/显示，按钮样式对齐完整播放器 VideoControls）
      if (this.controlsVisible) {
        Column() {
          Slider({
            value: this.currentTime,
            min: 0,
            max: this.duration > 0 ? this.duration : 100,
            style: SliderStyle.OutSet
          })
            // ⭐ 拖动状态机：Moving 只回显、End/Click 才提交一次 seek（原先每个 onChange 都 seekTo）
            .onChange((v: number, mode: SliderChangeMode) => { this.onSeekBarChange_(v, mode); })
            // ⭐ 系统中断拖动（来电/多任务）不会回调 onChange End，这里兜底解冻并提交
            .onTouch((e: TouchEvent) => { this.onSeekBarTouch_(e); })
            // ⭐ 触摸热区：Slider 不支持 responseRegion，只能靠自身布局盒高度撑开（原先沿用默认高度）
            .height(44)
            .trackColor('#66FFFFFF')
            .selectedColor(Color.White)
            .blockColor(Color.White)
          Row() {
            // 播放/暂停（40×40 半透明圆底，对齐 VideoControls）
            Column() {
              Image(this.playing ? $r('app.media.ic_public_pause') : $r('app.media.ic_public_play'))
                .width(24).height(24)
                .fillColor(Color.White)
            }
            .width(40).height(40)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#90000000')
            .borderRadius(20)
            .onClick(() => { this.togglePlay(); })

            // 比例/缩放模式（auto → fill → stretch 循环，对齐完整播放器 showScaleOptions 入口）
            Column() {
              Text(this.scaleModeLabel())
                .fontSize(12)
                .fontColor(Color.White)
            }
            .width(40).height(40)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#90000000')
            .borderRadius(20)
            .margin({ left: 8 })
            .onClick(() => { this.cycleScaleMode(); })

            // ⭐ 全高/限高切换（展开高度模式：限高 55% 屏高 / 全高自适应）
            Column() {
              Text(this.limitedHeight ? '全高' : '限高')
                .fontSize(12)
                .fontColor(Color.White)
            }
            .width(40).height(40)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#90000000')
            .borderRadius(20)
            .margin({ left: 8 })
            .onClick(() => { this.toggleHeightMode(); })

            Text(`${this.formatTime(this.currentTime)} / ${this.formatTime(this.duration)}`)
              .fontSize(12)
              .fontColor(Color.White)
              .margin({ left: 12 })
            Blank()
            // 全屏（内置全屏：同一 AVPlayer 重绑 surface + 横屏）
            Column() {
              Image($r('app.media.full_screen_fill'))
                .width(24).height(24)
                .fillColor(Color.White)
            }
            .width(40).height(40)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#90000000')
            .borderRadius(20)
            .onClick(() => { this.enterFullscreen(); })
          }
          .width('100%')
        }
        .width('100%')
        .position({ bottom: 0 })
        .padding({ left: 12, right: 12, top: 20, bottom: 8 })
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [['#00000000', 0], ['#CC000000', 1]]
        })
      }
    }
    .width('100%')
    .clip(true)
    .borderRadius(8)
    // ⭐ 内置全屏：同一 AVPlayer 重绑 surface 到全屏 XComponent（无需跳转页面）
    // onDisappear 兜底：系统返回键/$$ 置 false 关闭全屏层时同样恢复方向与 surface
    .bindContentCover($$this.isFullscreen, this.fullscreenBuilder(), {
      onDisappear: () => { this.onFullscreenDisappear(); }
    })
  }

  /** 全屏层：全屏 XComponent + 控制层（复用同一 AVPlayer，surface 已重绑） */
  @Builder
  fullscreenBuilder() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 全屏视频画面
      XComponent({ id: 'offline_inline_xc_fs', type: XComponentType.SURFACE, controller: this.fsXc })
        .onLoad(() => { this.onFsXCLoad(); })
        .width('100%').height('100%')
        .backgroundColor(Color.Black)
        .clip(true)
        // ⭐ 滑动调节手势（左右进度/上下亮度音量）
        .onTouch(this.onVT)
        // ⭐ 单击切换控制栏显隐，双击暂停/继续
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 2 }).onAction(() => { this.togglePlay(); }),
            TapGesture({ count: 1 }).onAction(() => { this.toggleControls(); })
          )
        )

      // 加载中
      if (this.loading) {
        Row() {
          LoadingProgress()
            .width(36).height(36)
            .color(Color.White)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
      }

      // ⭐ 手势提示（居中文字 + 进度条，无背景不拦截触摸）
      if (this.ghShow) {
        Column({ space: 8 }) {
          Text(this.ghText)
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
          if (this.ghProgress >= 0) {
            Progress({ value: this.ghProgress, total: 1, type: ProgressType.Linear })
              .width(160).height(4)
              .color('#FF8A00')
              .backgroundColor('#66FFFFFF')
          }
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      // 播放失败提示
      if (this.err !== '') {
        Column({ space: 12 }) {
          Text(this.err)
            .fontSize(14)
            .fontColor(Color.White)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center)
      }

      // 左上角退出全屏按钮（常驻）
      Text('×')
        .fontSize(20)
        .fontColor(Color.White)
        .width(32).height(32)
        .textAlign(TextAlign.Center)
        .backgroundColor('#66000000')
        .borderRadius(16)
        .position({ top: 8, left: 8 })
        .onClick(() => { this.exitFullscreen(); })

      // 底部控制层
      if (this.controlsVisible) {
        Column() {
          Slider({
            value: this.currentTime,
            min: 0,
            max: this.duration > 0 ? this.duration : 100,
            style: SliderStyle.OutSet
          })
            // ⭐ 拖动状态机（与内嵌竖屏控制栏同一套）：Moving 只回显、End/Click 才提交
            .onChange((v: number, mode: SliderChangeMode) => { this.onSeekBarChange_(v, mode); })
            .onTouch((e: TouchEvent) => { this.onSeekBarTouch_(e); })
            .height(44)
            .blockColor(Color.White)
            .selectedColor(Color.White)
            .trackColor('#66FFFFFF')
          Row() {
            // 播放/暂停（40×40 半透明圆底，对齐 VideoControls）
            Column() {
              Image(this.playing ? $r('app.media.ic_public_pause') : $r('app.media.ic_public_play'))
                .width(24).height(24)
                .fillColor(Color.White)
            }
            .width(40).height(40)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#90000000')
            .borderRadius(20)
            .onClick(() => { this.togglePlay(); })

            // 比例/缩放模式
            Column() {
              Text(this.scaleModeLabel())
                .fontSize(12)
                .fontColor(Color.White)
            }
            .width(40).height(40)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#90000000')
            .borderRadius(20)
            .margin({ left: 8 })
            .onClick(() => { this.cycleScaleMode(); })

            Text(`${this.formatTime(this.currentTime)} / ${this.formatTime(this.duration)}`)
              .fontSize(12)
              .fontColor(Color.White)
              .margin({ left: 12 })
            Blank()
            // 退出全屏
            Column() {
              Image($r('app.media.return_453'))
                .width(30).height(30)
                .fillColor(Color.White)
            }
            .width(40).height(40)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#90000000')
            .borderRadius(20)
            .onClick(() => { this.exitFullscreen(); })
          }
          .width('100%')
        }
        .width('100%')
        .position({ bottom: 0 })
        .padding({ left: 12, right: 12, top: 20, bottom: 8 })
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [['#00000000', 0], ['#CC000000', 1]]
        })
      }
    }
    .width('100%').height('100%')
    .backgroundColor(Color.Black)
  }
}
