/**
 * FloatingVideoButton.ets
 * 全局可复用的悬浮视频播放按钮组件
 * 当视频被最小化到悬浮窗时，在页面右下角显示一个圆形播放按钮
 * 点击后重新进入视频播放页并恢复播放进度
 */
import { router } from '@kit.ArkUI';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { VibrateUtils } from '../utils/VibrateUtils';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { media } from '@kit.MediaKit';
import { PlayerService } from '../services/PlayerService';
import { LiveViewHelper } from '../services/LiveViewHelper';
import FormUtils from '../utils/FormUtils';

interface MinimizedVideoState {
  bvid: string;
  cid: number;
  title: string;
  cover: string;
  currentTime: number;
  duration: number;
  isPlaying: boolean;
  quality: number;
  qualityLabel: string;
  volume: number;
  mute: boolean;
}

@Component
export struct FloatingVideoButton {
  @StorageLink('videoMinimized') videoMinimized: boolean = false;
  @StorageLink('navIndicatorHeight') navIndicatorHeight: number = 0;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @State contentX: number = 200;
  @State contentY: number = 0;
  @State contentOpacity: number = 0;
  @State rotationAngle: number = 0;
  @State longPressPulse: number = 1;
  @State isPlaying: boolean = true;
  @State capsulePlayState: boolean = true;
  private rotationTimer_: number = -1;
  private prevMinimized_: boolean = false;
  private animating_: boolean = false;
  private animatingIn_: boolean = false;
  private isDragging_: boolean = false;
  private longPressTriggered_: boolean = false;
  /** 通知栏进度更新计数器（每 10 个 tick ≈ 1 秒更新一次） */
  private lvProgressTick_: number = 0;
  private wasOverThreshold_: boolean = false;
  private wasOverYThreshold_: boolean = false;
  private dominantDir_: string = 'none';
  private touchStartWX_: number = 0;
  private touchStartWY_: number = 0;
  private lastWX_: number = 0;
  private lastWY_: number = 0;
  /** 离屏 XComponent 控制器（浮窗时给视频解码器渲染目标，避免停滞） */
  private offscreenXc_: XComponentController = new XComponentController();
  /** 垂直回弹动画中，隐藏胶囊避免回弹时显示颜色 */
  private hideVerticalCapsule: boolean = false;
  /** 后台播放开关（从 AppStorage 自动同步控制栏状态） */
  @StorageLink('bgp') bgp: boolean = false;
  @StorageLink('da') da: boolean = false;

  aboutToAppear(): void {
    this.startRotation();
    // @StorageLink 自动同步 AppStorage('bgp')，无需手动读取
    // 从 PlayerService 读取同步播放状态
    const ps = PlayerService.getInstance();
    if (ps.hasActivePlayer) {
      this.isPlaying = ps.playbackState === 'playing';
      this.capsulePlayState = this.isPlaying;
      logInfo(`[FloatingVideoButton] 初始播放状态: ${this.isPlaying} (playbackState=${ps.playbackState})`);
    }
    // 注册通知栏媒体控制回调（浮窗状态时响应系统通知栏的播放/暂停/拖动）
    this.registerLiveViewHandlers();
  }

  aboutToDisappear(): void {
    this.stopRotation();
    // 兜底：动画完成前页面销毁，强制清理 AppStorage 状态
    if (this.animating_) {
      AppStorage.set('videoMinimized', false);
      AppStorage.set('minimizedVideoState', '');
    }
    // 清除通知栏控制回调（避免 dangling 引用）
    LiveViewHelper.setControlHandlers({});
  }

  private startRotation(): void {
    this.stopRotation();
    const TICK = 33;
    this.rotationTimer_ = setInterval(() => {
      const speed = AppStorage.get<number>('floatBtnRotationSpeed') ?? 8;
      const STEP = speed * (TICK / 100);
      this.rotationAngle = (this.rotationAngle + STEP) % 360;
      // 同步播放状态（解决 router 缓存页面不触发 aboutToAppear 的问题）
      this.syncPlaybackState();
      // 检测最小化状态变化来触发浮窗动画
      this.checkMinimizedChange();
      // ⭐ 浮窗期间将视频播放器绑定到离屏 Surface，避免解码器停滞
      this.applyOffscreenSurface();
      // ⭐ 每 1 秒更新通知栏进度条（浮窗时 VideoPlayerPage 已销毁，其 5s 定时器不工作）
      this.lvProgressTick_++;
      if (this.lvProgressTick_ >= 10) {
        this.lvProgressTick_ = 0;
        this.updateNotificationProgress();
      }
    }, TICK);
  }

  /**
   * 从 PlayerService 同步播放状态
   * router 缓存页面回到前台时不触发 aboutToAppear，通过定时器补偿
   */
  private syncPlaybackState(): void {
    const ps = PlayerService.getInstance();
    if (!ps.hasActivePlayer) {
      return;
    }
    // 从 AVPlayer 实际状态判断是否正在播放，仅更新本地 UI 状态
    // 不改写 ps.playbackState，避免 AVSession 播放回调的守卫逻辑失效导致自动播放
    let rawPlaying: boolean | null = null;
    if (ps.videoPlayer) {
      try {
        rawPlaying = ps.videoPlayer.state === 'playing';
      } catch (_e) {}
    }
    if (rawPlaying === null && ps.audioPlayer) {
      try {
        rawPlaying = ps.audioPlayer.state === 'playing';
      } catch (_e) {}
    }
    const expected = rawPlaying !== null ? rawPlaying : (ps.playbackState === 'playing');
    if (expected !== this.isPlaying) {
      this.isPlaying = expected;
      logInfo(`[FloatingVideoButton] 同步播放状态: isPlaying=${expected} (raw=${rawPlaying}, stored=${ps.playbackState})`);
    }
    // 始终同步胶囊播放状态（与 isPlaying 独立，避免 animateTo 插值问题）
    if (this.contentY >= 0) {
      this.capsulePlayState = expected;
    }
  }

  /**
   * 更新通知栏播放进度（浮窗时定时调用）
   * 读取音频播放器的实时位置（浮窗期间音频连续播放），同步到 AVSession 通知栏
   */
  private updateNotificationProgress(): void {
    const ps = PlayerService.getInstance();
    if (!ps.hasActivePlayer) {
      return;
    }
    // 优先用音频播放器的 currentTime（浮窗期间音频连续播放，位置准确）
    let currentTimeMs: number = 0;
    if (ps.audioPlayer) {
      try {
        currentTimeMs = ps.audioPlayer.currentTime;
      } catch (_e) {
        currentTimeMs = 0;
      }
    }
    if (currentTimeMs <= 0 && ps.videoPlayer) {
      try {
        currentTimeMs = ps.videoPlayer.currentTime;
      } catch (_e) {
        currentTimeMs = 0;
      }
    }
    // 转成秒
    const currentTimeSec = currentTimeMs / 1000;
    LiveViewHelper.updateProgress(currentTimeSec);
    // ⭐ 同步推送进度到桌面播控卡片
    const durationSec = (ps.playerState?.duration || 0);
    const isPlay = ps.playbackState === 'playing';
    const ctx = this.getUIContext().getHostContext() as Context;
    FormUtils.updateCardProgress(ctx, currentTimeSec, durationSec, isPlay);
  }

  /**
   * 检测 videoMinimized 变化，触发进出动画
   */
  private checkMinimizedChange(): void {
    if (this.videoMinimized && !this.prevMinimized_ && !this.animating_) {
      logInfo('[FloatingVideoButton] 检测到 minimize 变化，触发 animateIn');
      // 重新注册通知栏控制回调（VideoPlayerPage 销毁时可能已清空）
      this.registerLiveViewHandlers();
      this.animating_ = true;
      this.animateIn();
    } else if (!this.videoMinimized && this.prevMinimized_) {
      // 状态已变为隐藏，不做特殊处理（animateOut 由 resumeFromFloating 主动触发）
    }
    this.prevMinimized_ = this.videoMinimized;
  }

  /**
   * 浮窗期间将视频播放器绑定到离屏 XComponent Surface
   * 让解码器始终有渲染目标，避免 Surface 断开 → 解码停滞 → 恢复时追赶
   * 当 PlayerService 持有播放器（最小化），且离屏 surfaceId 就绪时生效
   */
  private applyOffscreenSurface(): void {
    const ps = PlayerService.getInstance();
    if (!ps.hasActivePlayer || !ps.videoPlayer) {
      return;
    }
    const sid: string = this.offscreenXc_.getXComponentSurfaceId();
    if (!sid) {
      return; // XComponent 尚未加载
    }
    try {
      ps.videoPlayer.surfaceId = sid;
    } catch (e) {
      // 跨线程访问 AVPlayer 可能失败，静默
    }
  }

  private stopRotation(): void {
    if (this.rotationTimer_ !== -1) {
      clearInterval(this.rotationTimer_);
      this.rotationTimer_ = -1;
    }
  }

  /**
   * 浮窗出现动画：从右侧滑入 + 回弹
   */
  private animateIn(): void {
    this.contentX = 200;
    this.contentY = 0;
    this.contentOpacity = 0;
    this.animating_ = true;
    this.animatingIn_ = true;
    if (this.da) {
      // 关闭动画时：直接跳转到最终状态
      this.contentX = 0;
      this.contentOpacity = 1;
      this.animating_ = false;
      this.animatingIn_ = false;
    } else {
      // 第一段：快速滑入到过冲位置
      animateTo({ curve: Curve.FastOutSlowIn, duration: 300 }, () => {
        this.contentX = -10;
        this.contentOpacity = 1;
      });
      // 第二段：回弹到最终位置
      setTimeout(() => {
        animateTo({ curve: Curve.Friction, duration: 200 }, () => {
          this.contentX = 0;
        });
        this.animating_ = false;
        this.animatingIn_ = false;
      }, 300);
    }
  }

  /**
   * 浮窗消失动画：向右滑出
   */
  private animateOut(callback?: () => void): void {
    if (this.da) {
      this.contentX = 200;
      this.contentY = 0;
      this.contentOpacity = 0;
      this.animating_ = false;
      if (callback) callback();
    } else {
      animateTo({ curve: Curve.FastOutSlowIn, duration: 300 }, () => {
        this.contentX = 200;
        this.contentY = 0;
        this.contentOpacity = 0;
      });
      setTimeout(() => {
        this.animating_ = false;
        if (callback) callback();
      }, 350);
    }
  }

  /**
   * 获取封面 URL（优先 PlayerService，降级 AppStorage）
   */
  private getCoverUrl(): string {
    const ps = PlayerService.getInstance();
    if (ps.hasActivePlayer && ps.playerState && ps.playerState.cover) {
      return ps.playerState.cover;
    }
    const savedStateStr = AppStorage.get<string>('minimizedVideoState') ?? '';
    if (savedStateStr) {
      try {
        const savedState: MinimizedVideoState = JSON.parse(savedStateStr) as MinimizedVideoState;
        if (savedState.cover) return savedState.cover;
      } catch (e) {}
    }
    return '';
  }

  /**
   * 获取封面 URL 并打日志（调试用）
   */
  private getAndLogCover(): string {
    const url = this.getCoverUrl();
    logInfo(`[FloatingVideoButton] getCoverUrl='${url ? url.substring(0, 50) + '...' : '(empty)'}', videoMinimized=${this.videoMinimized}, contentOpacity=${this.contentOpacity}`);
    return url;
  }

  /**
   * 从悬浮按钮恢复视频播放
   */
  private resumeFromFloating(): void {
    if (this.animating_) return;

    // 读取导航数据
    let bvid = '';
    let cid = 0;
    let title = '';
    let cover = '';
    let ct = 0;

    const ps = PlayerService.getInstance();
    if (ps.hasActivePlayer && ps.playerState) {
      const savedState = ps.playerState;
      logInfo(`[FloatingVideoButton] 从 PlayerService 恢复: ${savedState.title}`);
      bvid = savedState.bvid;
      cid = savedState.cid;
      title = savedState.title;
      cover = savedState.cover;
      ct = savedState.currentTime;
    } else {
      const savedStateStr = AppStorage.get<string>('minimizedVideoState') ?? '';
      if (!savedStateStr) {
        logWarn('[FloatingVideoButton] 无保存状态');
        return;
      }
      try {
        const savedState: MinimizedVideoState = JSON.parse(savedStateStr) as MinimizedVideoState;
        if (!savedState.bvid) {
          logWarn('[FloatingVideoButton] 保存状态中缺少bvid');
          return;
        }
        bvid = savedState.bvid;
        cid = savedState.cid;
        title = savedState.title;
        cover = savedState.cover;
        ct = savedState.currentTime;
      } catch (e) {
        logError(`[FloatingVideoButton] 解析保存状态异常: ${e}`);
        return;
      }
    }

    // 向右滑出动画，完成后清理并导航
    this.animating_ = true;
    this.animateOut(() => {
      AppStorage.set('videoMinimized', false);
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/VideoPlayerPage',
        params: { bvid, cid, title, coverUrl: cover, initialProgress: ct }
      }).then(() => {
        logInfo('[FloatingVideoButton] 跳转播放页成功');
      }).catch((err: Error) => {
        logError(`[FloatingVideoButton] 跳转播放页失败: ${err.message}`);
      });
    });
  }

  /**
   * 上滑切换播放/暂停
   */
  private togglePlayPause(): void {
    const ps = PlayerService.getInstance();
    if (!ps.hasActivePlayer || !ps.videoPlayer) {
      logWarn('[FloatingVideoButton] 无活跃播放器');
      return;
    }
    if (this.isPlaying) {
      ps.videoPlayer.pause();
      ps.audioPlayer?.pause();
      this.isPlaying = false;
      this.capsulePlayState = false;
      ps.playbackState = 'paused';
      logInfo('[FloatingVideoButton] 已暂停');
      this.getUIContext().getPromptAction().showToast({ message: '已暂停', duration: 1000 });
    } else {
      ps.videoPlayer.play();
      ps.audioPlayer?.play();
      this.isPlaying = true;
      this.capsulePlayState = true;
      ps.playbackState = 'playing';
      logInfo('[FloatingVideoButton] 已播放');
      this.getUIContext().getPromptAction().showToast({ message: '已播放', duration: 1000 });
    }
    // 竖滑结束后回弹 Y 位置（回弹动画中隐藏胶囊，避免过冲阶段闪现颜色）
    this.hideVerticalCapsule = true;
    if (this.da) {
      this.contentY = 0;
      this.hideVerticalCapsule = false;
    } else {
      animateTo({ curve: Curve.Friction, duration: 150, onFinish: () => {
        this.hideVerticalCapsule = false;
      } }, () => {
        this.contentY = 0;
      });
    }
    try {
      VibrateUtils.vibrateTime(15);
    } catch (e) {
      logWarn(`震动失败: ${e}`);
    }
  }

  /**
   * 水平拖动结束：超过阈值关闭视频并释放播放器，不足回弹
   */
  private handleDragEnd(): void {
    this.isDragging_ = false;
    if (this.contentX <= -70) {
      // 超过阈值：关闭视频
      logInfo('[FloatingVideoButton] 拖动超过阈值，关闭视频');
      this.closeFloating();
    } else {
      // 回弹到原位
      if (this.da) {
        this.contentX = 0;
        this.contentY = 0;
      } else {
        animateTo({ curve: Curve.Friction, duration: 200 }, () => {
          this.contentX = 0;
          this.contentY = 0;
        });
      }
    }
  }

  /**
   * 关闭浮窗：向右滑出动画 → 释放播放器 → 清理状态
   */
  private closeFloating(): void {
    if (this.animating_) return;
    this.animating_ = true;

    // 先向右滑出动画
    if (this.da) {
      this.contentX = 200;
      this.contentY = 0;
      this.contentOpacity = 0;
    } else {
      animateTo({ curve: Curve.FastOutSlowIn, duration: 300 }, () => {
        this.contentX = 200;
        this.contentY = 0;
        this.contentOpacity = 0;
      });
    }

    // 动画完成后释放播放器并清理状态（禁用动画时也延迟一点确保状态更新）
    setTimeout(() => {
      AppStorage.set('videoMinimized', false);
      AppStorage.set('minimizedVideoState', '');
      const ps = PlayerService.getInstance();
      ps.release();
      this.animating_ = false;

      logInfo('[FloatingVideoButton] 视频已关闭');
      this.getUIContext().getPromptAction().showToast({ message: '已关闭视频', duration: 1500 });
    }, 350);
  }

  /**
   * 计算底部偏移量
   */
  private getBottomOffset(): number {
    return 60 + this.navIndicatorHeight;
  }

  /**
   * 计算右侧偏移量
   */
  private getRightOffset(): number {
    return 60;
  }

  /**
   * 长按切换后台播放开关（与控制栏耳机按钮同步）
   */
  private toggleBackgroundPlayback(): void {
    this.bgp = !this.bgp;
    // 显式同步 AppStorage（确保跨组件即时可见）
    AppStorage.set<boolean>('bgp', this.bgp);
    // 持久化到 Preferences（进程重启后仍保留）
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      preferences.getPreferences(context, 'my_app_settings').then((pref: preferences.Preferences) => {
        pref.put('bgp', this.bgp);
        pref.flush();
      });
    } catch (e) {
      logWarn(`[FloatingVideoButton] 持久化 bgp 失败: ${e}`);
    }

    // ★ 即时生效：根据 bgp 切换 LiveView（后台任务/媒体会话）
    //    浮窗时 VideoPlayerPage 已销毁，若仅存 AppStorage 标志位不会触发行为变化
    const ps = PlayerService.getInstance();
    if (this.bgp) {
      // 开启后台播放：若 LiveView 已结束则用 PlayerService 数据重新创建
      if (!LiveViewHelper.active && ps.hasActivePlayer && ps.playerState) {
        const st = ps.playerState;
        LiveViewHelper.create(
          this.getUIContext().getHostContext() as common.UIAbilityContext,
          st.title,
          st.cover,
          st.bvid,
          st.duration,
          '',
        ).then(() => {
          logInfo('[FloatingVideoButton] bgp→true：已重新创建 LiveView');
        });
      }
    } else {
      // 关闭后台播放：结束 LiveView，停止后台任务和媒体会话
      if (LiveViewHelper.active) {
        LiveViewHelper.end();
        logInfo('[FloatingVideoButton] bgp→false：已结束 LiveView');
      }
      // 若应用在后台，立即暂停播放
      const appBg = AppStorage.get<boolean>('appInBackground') ?? false;
      if (appBg && ps.hasActivePlayer) {
        ps.pause();
        this.isPlaying = false;
        this.capsulePlayState = false;
        logInfo('[FloatingVideoButton] bgp→false：应用在后台，已暂停播放');
      }
    }

    const msg = this.bgp ? '后台播放已开启' : '后台播放已关闭';
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1500 });
    logInfo(`[FloatingVideoButton] 后台播放: ${this.bgp}`);
  }

  /**
   * 注册通知栏媒体控制回调
   * 浮窗/后台状态时，响应用户在系统通知栏/锁屏媒体卡片的播放/暂停/进度拖动操作
   */
  private registerLiveViewHandlers(): void {
    LiveViewHelper.setControlHandlers({
      play: () => {
        const ps = PlayerService.getInstance();
        if (ps.hasActivePlayer && ps.playbackState !== 'playing') {
          ps.play();
          LiveViewHelper.updatePlayState(true);
          this.isPlaying = true;
          this.capsulePlayState = true;
        }
      },
      pause: () => {
        const ps = PlayerService.getInstance();
        if (ps.hasActivePlayer && ps.playbackState !== 'paused') {
          ps.pause();
          LiveViewHelper.updatePlayState(false);
          this.isPlaying = false;
          this.capsulePlayState = false;
        }
      },
      seek: (time: number) => {
        const ps = PlayerService.getInstance();
        if (!ps.hasActivePlayer) {
          return;
        }
        // time 来自 AVSession 是毫秒，AVPlayer.seek() 也是毫秒，直接传
        // 双播放器都需要 seek（视频 + 分轨音频）
        if (ps.videoPlayer) {
          try {
            ps.videoPlayer.seek(time, media.SeekMode.SEEK_PREV_SYNC);
          } catch (e) {
            logError('[FloatingVideoButton] seek videoPlayer error:', e);
          }
        }
        if (ps.audioPlayer) {
          try {
            ps.audioPlayer.seek(time, media.SeekMode.SEEK_PREV_SYNC);
          } catch (e) {
            logError('[FloatingVideoButton] seek audioPlayer error:', e);
          }
        }
        if (ps.playerState) {
          // playerState.currentTime 用秒存储
          ps.playerState.currentTime = time / 1000;
        }
        // 立即同步通知栏进度条
        const currentTimeSec = time / 1000;
        LiveViewHelper.updateProgress(currentTimeSec);
      },
    });
  }

  build() {
    Stack() {
      // ── 离屏 XComponent（浮窗时给视频解码器渲染目标，避免停滞）──
      // position 相对父 Stack（被 position{right,bottom} 锚定在屏幕内）计算，-200vp 会落回屏内，
      // 1vp Surface 无内容时渲染成黑点；需足够大的负值保证任何屏幕尺寸/方向下都出屏
      XComponent({ id: 'offscreen_xc', type: 'surface', libraryname: '', controller: this.offscreenXc_ })
        .width(1).height(1).position({ x: -2000, y: -2000 })

      // ── 水平胶囊遮罩（横滑向左时，从按钮右侧露出）──
      if (this.videoMinimized && this.contentX < 0 && !this.animatingIn_) {
        Row() {
          Image($r('app.media.xmark'))
            .width(20).height(20)
            .fillColor(Color.White)
            .opacity(0.9)
        }
        .width(Math.min(Math.abs(this.contentX), 120))
        .height(56)
        .borderRadius(28)
        .backgroundColor(this.contentX <= -70 ? 'rgba(200,50,50,0.85)' : (this.isDarkMode ? 'rgba(80,80,80,0.85)' : 'rgba(200,200,200,0.85)'))
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      }

      // ── 垂直胶囊遮罩（上滑时，从按钮下方露出，回弹动画中隐藏）──
      if (this.videoMinimized && this.contentY < 0 && !this.hideVerticalCapsule) {
        Row() {
          Image(this.capsulePlayState ? $r('app.media.ic_public_pause') : $r('app.media.ic_publi_play'))
            .width(18).height(18)
            .fillColor(Color.White)
            .opacity(0.9)
        }
        .width(56)
        .height(Math.min(Math.abs(this.contentY), 120))
        .borderRadius(28)
        .backgroundColor(
          this.contentY <= -70
            ? (this.capsulePlayState ? 'rgba(220,180,0,0.85)' : 'rgba(50,180,50,0.85)')
            : (this.isDarkMode ? 'rgba(80,80,80,0.85)' : 'rgba(200,200,200,0.85)')
        )
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      }

      // ── 浮窗按钮（上层，可拖动）──
      if (this.videoMinimized) {
        Stack() {
          if (this.getAndLogCover()) {
            Image(this.getAndLogCover())
              .width(56).height(56).borderRadius(28).objectFit(ImageFit.Cover)
              .rotate({ angle: this.isPlaying ? this.rotationAngle : 0 })
          } else {
            Column()
              .width(56).height(56).borderRadius(28)
              .backgroundColor(this.isDarkMode ? '#E6101010' : '#E6F0F0F0')
              .backdropBlur(12)
          }
          Column()
            .width(56).height(56).borderRadius(28)
            .backgroundColor('#40000000')
          Image(this.isPlaying ? $r('app.media.play_fill') : $r('app.media.ic_public_pause'))
            .width(20).height(20).fillColor(Color.White).opacity(0.7)
          if (this.bgp) {
            Image($r('app.media.headphones_fill'))
              .width(14).height(14)
              .fillColor(this.customThemeColor)
              .position({ bottom: 0, right: 0 })
              .opacity(0.9)
          }
        }
        .width(56).height(56).borderRadius(28)
        .shadow({ radius: 8, color: '#40000000', offsetY: 4 })
        .hitTestBehavior(HitTestMode.Block)
        .translate({ x: this.contentX, y: this.contentY })
        .opacity(this.contentOpacity)
        .scale({ x: this.longPressPulse, y: this.longPressPulse })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.touchStartWX_ = event.touches[0].windowX;
            this.touchStartWY_ = event.touches[0].windowY;
            this.lastWX_ = this.touchStartWX_;
            this.lastWY_ = this.touchStartWY_;
            this.isDragging_ = true;
            this.longPressTriggered_ = false;
            this.wasOverThreshold_ = false;
            this.wasOverYThreshold_ = false;
            this.dominantDir_ = 'none';
            logInfo('[FloatingVideoButton] touch down');
          } else if (event.type === TouchType.Move) {
            const wx = event.touches[0].windowX;
            const wy = event.touches[0].windowY;
            const offX = wx - this.touchStartWX_;
            const offY = wy - this.touchStartWY_;

            if (this.dominantDir_ === 'none') {
              if (Math.abs(offX) > 15 || Math.abs(offY) > 15) {
                this.dominantDir_ = Math.abs(offX) > Math.abs(offY) ? 'h' : 'v';
                logInfo(`[FloatingVideoButton] 方向锁定: ${this.dominantDir_}, offX=${offX}, offY=${offY}`);
              }
            }

            if (this.dominantDir_ === 'h') {
              const xvp = this.getUIContext().px2vp(offX);
              if (xvp < 0) {
                this.contentX = xvp;
              }
              const nowOver = xvp <= -70;
              if (nowOver !== this.wasOverThreshold_) {
                this.wasOverThreshold_ = nowOver;
                try {
                  VibrateUtils.vibrateTime(nowOver ? 30 : 15);
                } catch (e) {
                  logWarn(`震动失败: ${e}`);
                }
              }
            } else if (this.dominantDir_ === 'v') {
              const yvp = this.getUIContext().px2vp(offY);
              this.contentY = yvp;
              const nowYOver = yvp <= -70;
              if (nowYOver !== this.wasOverYThreshold_) {
                this.wasOverYThreshold_ = nowYOver;
                try {
                  VibrateUtils.vibrateTime(nowYOver ? 30 : 15);
                } catch (e) {
                  logWarn(`震动失败: ${e}`);
                }
              }
            }
            this.lastWX_ = wx;
            this.lastWY_ = wy;
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            const finalX = this.lastWX_ - this.touchStartWX_;
            const finalY = this.lastWY_ - this.touchStartWY_;
            logInfo(`[FloatingVideoButton] touchEnd: dir=${this.dominantDir_}, finalX=${finalX}, finalY=${finalY}`);

            if (this.dominantDir_ === 'none' && event.type === TouchType.Up && !this.longPressTriggered_) {
              this.resumeFromFloating();
            } else if (this.dominantDir_ === 'v' && this.getUIContext().px2vp(finalY) <= -70) {
              logInfo('[FloatingVideoButton] → 上滑，调用 togglePlayPause');
              this.togglePlayPause();
            } else {
              this.handleDragEnd();
            }
            this.isDragging_ = false;
          }
        })
        .priorityGesture(
          LongPressGesture({ duration: 500 })
            .onAction(() => {
              this.longPressTriggered_ = true;
              VibrateUtils.vibrateTime(20);
              if (this.da) {
                this.longPressPulse = 1.2;
                this.longPressPulse = 1;
              } else {
                animateTo({ duration: 200, curve: Curve.Friction }, () => {
                  this.longPressPulse = 1.2;
                });
                setTimeout(() => {
                  animateTo({ duration: 350, curve: Curve.EaseOut }, () => {
                    this.longPressPulse = 1;
                  });
                }, 200);
              }
              this.toggleBackgroundPlayback();
            })
        )
      }

    }
    .align(Alignment.Bottom)
    .position({ bottom: this.getBottomOffset(), right: this.getRightOffset() })
    .zIndex(999)
  }
}
