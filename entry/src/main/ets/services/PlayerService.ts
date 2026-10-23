/**
 * PlayerService.ts
 * 全局 AVPlayer 单例 — 按官方 MusicCard 模式简化
 *
 * 卡片更新逻辑改为：
 * 1. 播放状态变化时 → 写入 AppStorage → FormUtils.updatePlayControlCards()
 * 2. EntryAbility 已注册 callee 响应卡片 call 事件
 */
import { media } from '@kit.MediaKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { common } from '@kit.AbilityKit';
import FormUtils from '../utils/FormUtils';

/**
 * ⭐ DASH 链路桥句柄（PlayerService 只做托管传递，不直接实现）。
 * 真实实现是 DashPlayerBridge.ets；此处用接口避免 .ts 引用 .ets 的禁令。
 * DashPlayerBridge 需实现本接口（stop = 停止整个链路）。
 */
export interface DashServerHandle {
  stop(): Promise<void>;
}

/** 最小化时保存的播放状态快照 */
export interface MinimizedPlayerState {
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
  isLandscapeVertical: boolean;
  videoAspectRatio: number;
  /** ⭐ 分集 aid（PGC 评论 oid 用；恢复播放页时补详情/评论加载） */
  aid: number;
  /** ⭐ PGC 分集 id（恢复播放页时校验 isPgc_/补详情） */
  epId: number;
  /** ⭐ PGC 季 id */
  seasonId: number;
}

export class PlayerService {
  private static instance: PlayerService = new PlayerService();
  private static appContext_: common.Context | null = null;

  static setAppContext(ctx: common.Context): void {
    PlayerService.appContext_ = ctx;
  }

  static getAppContext(): common.Context | null {
    return PlayerService.appContext_;
  }

  videoPlayer: media.AVPlayer | null = null;
  audioPlayer: media.AVPlayer | null = null;
  playerState: MinimizedPlayerState | null = null;
  hasActivePlayer: boolean = false;
  playbackState: string = 'paused';
  /** ⭐ DASH 转播站服务（播放器移交时一并托管，浮窗/恢复复用） */
  private dashServer_: DashServerHandle | null = null;

  static getInstance(): PlayerService {
    return PlayerService.instance;
  }

  /** 托管/移交转播站 */
  setDashServer(s: DashServerHandle | null): void {
    this.dashServer_ = s;
  }

  /** 取回转播站（页面恢复接管时用） */
  takeDashServer(): DashServerHandle | null {
    const s = this.dashServer_;
    this.dashServer_ = null;
    return s;
  }

  getDashServer(): DashServerHandle | null {
    return this.dashServer_;
  }

  /** 同步播放状态到 AppStorage（供卡片 call 响应时读取） */
  private syncToAppStorage(): void {
    const title = this.playerState?.title || 'Bilibili';
    const cover = this.playerState?.cover || '';
    const ct = this.playerState?.currentTime || 0;
    const dur = this.playerState?.duration || 0;
    AppStorage.set('cardIsPlay', this.playbackState === 'playing');
    AppStorage.set('cardTitle', title);
    AppStorage.set('cardCover', cover);
    AppStorage.set('cardCurrentTime', ct);
    AppStorage.set('cardDuration', dur);
    AppStorage.set('cardHasPlayer', this.hasActivePlayer);
  }

  /** 向桌面卡片推送更新 */
  private notifyCards(): void {
    this.syncToAppStorage();
    const ctx = PlayerService.getAppContext();
    if (!ctx) {
      return;
    }
    const title = this.playerState?.title || 'Bilibili';
    const cover = this.playerState?.cover || '';
    const ct = this.playerState?.currentTime || 0;
    const dur = this.playerState?.duration || 0;
    FormUtils.updatePlayControlCards(
      ctx, this.playbackState === 'playing', title, cover, ct, dur, this.hasActivePlayer
    );
  }

  takeoverPlayer(
    video: media.AVPlayer | null,
    audio: media.AVPlayer | null,
    state: MinimizedPlayerState
  ): void {
    this.videoPlayer = video;
    this.audioPlayer = audio;
    this.playerState = state;
    this.hasActivePlayer = true;
    this.playbackState = state.isPlaying ? 'playing' : 'paused';
    this.notifyCards();
  }

  release(): void {
    if (this.videoPlayer) {
      try { this.videoPlayer.release(); } catch (e) {
        logError('[PlayerService] release videoPlayer error:', e);
      }
      this.videoPlayer = null;
    }
    if (this.audioPlayer) {
      try { this.audioPlayer.release(); } catch (e) {
        logError('[PlayerService] release audioPlayer error:', e);
      }
      this.audioPlayer = null;
    }
    // ⭐ DASH 转播站服务一并停止（如切到不同视频）
    if (this.dashServer_) {
      this.dashServer_.stop();
      this.dashServer_ = null;
    }
    this.playerState = null;
    this.hasActivePlayer = false;
    this.notifyCards();
  }

  play(): void {
    if (this.videoPlayer) {
      try { this.videoPlayer.play(); } catch (e) { logError('[PlayerService] play video error:', e); }
    }
    if (this.audioPlayer) {
      try { this.audioPlayer.play(); } catch (e) { logError('[PlayerService] play audio error:', e); }
    }
    this.playbackState = 'playing';
    this.notifyCards();
  }

  pause(): void {
    if (this.videoPlayer) {
      try { this.videoPlayer.pause(); } catch (e) { logError('[PlayerService] pause video error:', e); }
    }
    if (this.audioPlayer) {
      try { this.audioPlayer.pause(); } catch (e) { logError('[PlayerService] pause audio error:', e); }
    }
    this.playbackState = 'paused';
    this.notifyCards();
  }

  reset(): void {
    this.release();
  }
}
