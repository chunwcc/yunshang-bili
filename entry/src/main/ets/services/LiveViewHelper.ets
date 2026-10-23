/**
 * LiveViewHelper.ets
 * 媒体会话辅助服务 —— AVSession 版 + 后台长时任务
 * 通过系统媒体会话 AVSession + 后台任务在通知栏/锁屏显示播放控制
 *
 * 使用方式：
 *   1. 视频开始时: LiveViewHelper.create(context, title, cover, bvid, durationSec, artist)
 *   2. 进度变化时: LiveViewHelper.updateProgress(currentSec)
 *   3. 暂停/恢复时: LiveViewHelper.updatePlayState(isPlaying)
 *   4. 页面离开时: LiveViewHelper.end()
 */
import avSession from '@ohos.multimedia.avsession';
import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';
import common from '@ohos.app.ability.common';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.wantAgent';
/** 本地 Want 类型，替代 @ohos.app.ability.Want 避免原生模块加载失败 */
interface Want {
  bundleName?: string;
  abilityName?: string;
  uri?: string;
  parameters?: Record<string, Object>;
}

/** 媒体控制回调接口 */
interface MediaControlHandlers {
  play?: () => void;
  pause?: () => void;
  seek?: (time: number) => void;
}

/** 媒体会话管理类 */
export class LiveViewHelper {
  private static session_: avSession.AVSession | null = null;
  private static isActive_: boolean = false;
  private static context_: common.BaseContext | null = null;
  /** 媒体控制回调（由 VideoPlayerPage 注册，响应通知栏的播放/暂停等操作） */
  private static onPlay_: (() => void) | null = null;
  private static onPause_: (() => void) | null = null;
  private static onSeek_: ((time: number) => void) | null = null;
  /** 缓存的总时长（毫秒）和当前位置（毫秒），供 updatePlayState 保留进度 */
  private static lastDurationMs_: number = 0;
  private static lastPositionMs_: number = 0;

  /** 当前是否活跃 */
  static get active(): boolean {
    return LiveViewHelper.isActive_;
  }

  /**
   * 注册媒体控制回调（在 create 之前调用）
   * @param handlers.play  通知栏点击播放时的回调
   * @param handlers.pause 通知栏点击暂停时的回调
   * @param handlers.seek  通知栏拖动进度条时的回调
   */
  static setControlHandlers(handlers: MediaControlHandlers): void {
    LiveViewHelper.onPlay_ = handlers.play ?? null;
    LiveViewHelper.onPause_ = handlers.pause ?? null;
    LiveViewHelper.onSeek_ = handlers.seek ?? null;
  }

  /** ✨ 创建/更新媒体会话 + 启动后台长时任务 */
  static async create(
    context: common.BaseContext,
    title: string,
    coverUrl: string,
    bvid: string,
    durationSec: number,
    artist: string = '',
  ): Promise<void> {
    // 保存 context 供后续使用
    LiveViewHelper.context_ = context;
    // 缓存总时长
    LiveViewHelper.lastDurationMs_ = durationSec * 1000;

    try {
      // 0. 提前创建 WantAgent（点击通知时跳回应用）
      const agent: object = await LiveViewHelper.createWantAgent_(context);

      // 1. 创建/获取 AVSession
      if (!LiveViewHelper.session_) {
        LiveViewHelper.session_ = await avSession.createAVSession(
          context, 'B站视频播放', 'audio',
        );
      }

      // 2. 设置元数据
      const metadata: avSession.AVMetadata = {
        assetId: bvid,
        title: title,
        artist: artist,
        duration: durationSec * 1000,
        mediaImage: coverUrl,
      };
      await LiveViewHelper.session_.setAVMetadata(metadata);

      // 3. 设置播放状态（初始为播放中）
      const pos: avSession.PlaybackPosition = {
        elapsedTime: 0,
        updateTime: Date.now(),
      };
      const playbackState: avSession.AVPlaybackState = {
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
        position: pos,
        duration: LiveViewHelper.lastDurationMs_,
        bufferedTime: 0,
      };
      await LiveViewHelper.session_.setAVPlaybackState(playbackState);

      // 4. 注册媒体控制回调（必须注册系统才显示媒体控制卡片）
      LiveViewHelper.registerSessionCallbacks_();

      // 5. 激活会话（必须 await，否则系统无法正确注册媒体通知）
      await LiveViewHelper.session_.activate();
      LiveViewHelper.isActive_ = true;

      // 6. 设置通知跳转行为（点击媒体通知时返回播放页）
      await LiveViewHelper.session_.setLaunchAbility(agent);

      // 7. 启动后台长时任务（保证退出页面后进程不被杀死）
      await LiveViewHelper.startBackgroundTask_(agent);

      logInfo('[LiveView] 媒体会话 + 后台任务已启动');
    } catch (err) {
      logWarn('[LiveView] 创建媒体会话失败:', errMsg(err));
    }
  }

  /** 创建 WantAgent（点击通知时跳回应用界面） */
  private static async createWantAgent_(context: common.BaseContext): Promise<object> {
    const uiContext = context as common.UIAbilityContext;
    const want: Want = {
      bundleName: uiContext.abilityInfo.bundleName,
      abilityName: uiContext.abilityInfo.name,
    };
    return await wantAgent.getWantAgent({
      wants: [want],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
    });
  }

  /** 是否已注册过 session 回调（防止重复注册导致一次操作触发 N 次） */
  private static callbacksRegistered_: boolean = false;

  /** 🎮 注册媒体控制回调（告知系统本会话支持播放/暂停/拖动等操作） */
  private static registerSessionCallbacks_(): void {
    const session = LiveViewHelper.session_;
    if (!session) {
      return;
    }

    // ⭐ 防止重复注册——AVSession 的 on() 是追加监听，不是替换
    if (LiveViewHelper.callbacksRegistered_) {
      return;
    }

    try {
      // 系统需要这些回调注册后，才会在通知栏显示媒体控制卡片
      session.on('play', () => {
        logInfo('[LiveView] 通知栏-播放');
        LiveViewHelper.onPlay_?.();
      });
      session.on('pause', () => {
        logInfo('[LiveView] 通知栏-暂停');
        LiveViewHelper.onPause_?.();
      });
      session.on('stop', () => {
        logInfo('[LiveView] 通知栏-停止');
        LiveViewHelper.onPause_?.();
      });
      session.on('seek', (time: number) => {
        logInfo('[LiveView] 通知栏-拖动:', time);
        LiveViewHelper.onSeek_?.(time);
      });
      LiveViewHelper.callbacksRegistered_ = true;
      logInfo('[LiveView] 媒体控制回调已注册');
    } catch (err) {
      logWarn('[LiveView] 注册媒体控制回调失败:', errMsg(err));
    }
  }

  /** 🚀 启动后台长时任务 */
  private static async startBackgroundTask_(agent: object): Promise<void> {
    if (!LiveViewHelper.context_) {
      return;
    }
    try {
      await backgroundTaskManager.startBackgroundRunning(
        LiveViewHelper.context_,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent,
      );
      logInfo('[LiveView] 后台长时任务已启动');
    } catch (err) {
      logWarn('[LiveView] 启动后台任务失败:', errMsg(err), 'code:', err.code, 'msg:', err.message);
    }
  }

  /** ⏱ 更新播放进度 */
  static updateProgress(currentTimeSec: number): void {
    if (!LiveViewHelper.isActive_ || !LiveViewHelper.session_) {
      return;
    }
    try {
      const posMs = currentTimeSec * 1000;
      LiveViewHelper.lastPositionMs_ = posMs;
      const pos: avSession.PlaybackPosition = {
        elapsedTime: posMs,
        updateTime: Date.now(),
      };
      const playbackState: avSession.AVPlaybackState = {
        position: pos,
        duration: LiveViewHelper.lastDurationMs_,
        bufferedTime: 0,
      };
      LiveViewHelper.session_.setAVPlaybackState(playbackState);
    } catch (err) {
      logWarn('[LiveView] 更新播放进度失败:', errMsg(err));
    }
  }

  /** ▶️⏸ 更新播放状态 */
  static updatePlayState(isPlaying: boolean): void {
    if (!LiveViewHelper.isActive_ || !LiveViewHelper.session_) {
      return;
    }
    try {
      const playbackState: avSession.AVPlaybackState = {
        state: isPlaying
          ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        position: {
          elapsedTime: LiveViewHelper.lastPositionMs_,
          updateTime: Date.now(),
        },
        duration: LiveViewHelper.lastDurationMs_,
        bufferedTime: 0,
      };
      LiveViewHelper.session_.setAVPlaybackState(playbackState);
    } catch (err) {
      logWarn('[LiveView] 更新播放状态失败:', errMsg(err));
    }
  }

  /** 🛑 结束媒体会话 + 停止后台长时任务 */
  static end(): void {
    // 停止后台长时任务
    if (LiveViewHelper.context_) {
      try {
        backgroundTaskManager.stopBackgroundRunning(LiveViewHelper.context_);
        logInfo('[LiveView] 后台任务已停止');
      } catch (err) {
        logWarn('[LiveView] 停止后台任务失败:', errMsg(err));
      }
      LiveViewHelper.context_ = null;
    }

    // 销毁媒体会话
    if (!LiveViewHelper.session_) {
      return;
    }
    try {
      LiveViewHelper.session_.deactivate();
      LiveViewHelper.session_.destroy();
    } catch (err) {
      logWarn('[LiveView] 结束媒体会话失败:', errMsg(err));
    }
    LiveViewHelper.session_ = null;
    LiveViewHelper.isActive_ = false;
    // ⭐ 重置回调注册标记，下次 create 重新注册
    LiveViewHelper.callbacksRegistered_ = false;
    logInfo('[LiveView] 媒体会话已结束');
  }
}
