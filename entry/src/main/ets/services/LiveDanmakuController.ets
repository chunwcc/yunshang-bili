/**
 * LiveDanmakuController.ets — 直播实时弹幕渲染控制器
 *
 * 复用点播的 DanmakuRenderer / DanmakuTrackManager，
 * 但不使用 DanmakuController（它绑定 cid/分段/时间轴）。
 *
 * 时钟：页面内单调递增（ms）。滚动弹幕只吃 dt；顶/底弹幕用 clock - item.time 淡入淡出。
 */
import { DanmakuRenderer } from './DanmakuRenderer';
import { DanmakuTrackManager } from './DanmakuTrackManager';
import { DanmakuConfig, DanmakuItem, DanmakuType } from '../model/DanmakuItem';
import { LiveMessage } from '../model/LiveMessage';
import { logError, logInfo } from '../utils/Logger';

const MAX_VISIBLE: number = 120;
const BUFFER_MAX: number = 30;
const RESEED_COUNT: number = 15;

export class LiveDanmakuController {
  private config: DanmakuConfig;
  private renderer: DanmakuRenderer;
  private tracks: DanmakuTrackManager;
  private visible: DanmakuItem[] = [];
  private buffer: LiveMessage[] = [];
  private clock: number = 0;
  private lastTs: number = 0;
  private timer: number = -1;
  private active: boolean = false;
  private enabled: boolean = true;
  private hasContext: boolean = false;
  private w: number = 0;
  private h: number = 0;
  private droppedCount: number = 0;

  constructor(config?: DanmakuConfig) {
    this.config = config ? config : new DanmakuConfig();
    this.renderer = new DanmakuRenderer(this.config);
    this.tracks = new DanmakuTrackManager(this.config);
  }

  setContext(ctx: CanvasRenderingContext2D): void {
    this.renderer.setContext(ctx);
    this.hasContext = true;
  }

  /** 画布尺寸变化：旋转 / 切比例 / 聊天面板开合 */
  setSize(w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    if (Math.abs(w - this.w) < 1 && Math.abs(h - this.h) < 1) {
      return;
    }
    const first: boolean = this.w <= 0 || this.h <= 0;
    this.w = w;
    this.h = h;
    this.renderer.setSize(w, h);
    if (first) {
      this.tracks.initialize(w, h);
      logInfo(`[LiveDanmaku] 画布初始化 ${w.toFixed(0)}x${h.toFixed(0)}`);
    } else {
      // 保留轨道占用信息（initialize 会清空 lastItem，导致新弹幕与在飞弹幕重叠）
      this.tracks.updateGeometry(w, h);
      this.reseed();
      logInfo(`[LiveDanmaku] 画布尺寸更新 ${w.toFixed(0)}x${h.toFixed(0)}，重播 ${Math.min(RESEED_COUNT, this.buffer.length)} 条`);
    }
  }

  setEnabled(on: boolean): void {
    this.enabled = on;
    if (!on) {
      this.stop();
      this.visible.length = 0;
      return;
    }
    if (this.hasContext && this.w > 0 && this.h > 0) {
      this.clock += 1;
      this.reseed();
      this.start();
    }
  }

  push(msg: LiveMessage): void {
    if (!this.enabled || !this.hasContext || this.w <= 0 || this.h <= 0) {
      return;
    }
    if (!msg.text) {
      return;
    }
    this.buffer.push(msg);
    if (this.buffer.length > BUFFER_MAX) {
      this.buffer.shift();
    }
    this.pushItem(msg);
  }

  start(): void {
    if (this.active || !this.enabled || !this.hasContext) {
      return;
    }
    this.active = true;
    this.lastTs = 0;
    this.timer = setTimeout(this.frame, 16);
  }

  stop(): void {
    this.active = false;
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.renderer.clear();
  }

  destroy(): void {
    this.stop();
    this.visible.length = 0;
    this.buffer.length = 0;
    this.hasContext = false;
  }

  // ==================== 内部 ====================

  private pushItem(msg: LiveMessage): void {
    if (this.visible.length >= MAX_VISIBLE) {
      this.droppedCount++;
      return;
    }
    const item = new DanmakuItem({ content: msg.text, color: msg.color, time: this.clock });
    item.type = this.mapType(msg.mode);
    // 与 DanmakuController 一致：先归一化字号，再用真实宽度写回（widthFontSize 必须同步）
    this.tracks.normalizeFontSize(item);
    const measured: number = this.renderer.measureWidth(item.content, item.fontSize);
    if (measured > 0) {
      item.width = measured;
      item.widthFontSize = item.fontSize;
    }
    const track: number = this.tracks.assignTrack(item, this.clock);
    if (track < 0) {
      // 放不下就直接丢弃；留在列表里会被画到左上角
      this.droppedCount++;
      return;
    }
    this.visible.push(item);
  }

  private mapType(liveMode: number): DanmakuType {
    if (liveMode === 5) {
      return DanmakuType.TOP;
    }
    if (liveMode === 4) {
      return DanmakuType.BOTTOM;
    }
    return DanmakuType.ROLL;
  }

  /** 尺寸变化后用最近的消息重新入轨，避免旋转后空屏 */
  private reseed(): void {
    this.visible.length = 0;
    const start: number = Math.max(0, this.buffer.length - RESEED_COUNT);
    for (let i = start; i < this.buffer.length; i++) {
      this.pushItem(this.buffer[i]);
    }
    if (this.visible.length === 0) {
      this.renderer.clear();
    }
  }

  private frame = (): void => {
    this.timer = -1;
    if (!this.active) {
      return;
    }
    try {
      const now: number = Date.now();
      let dt: number = this.lastTs > 0 ? now - this.lastTs : 16;
      if (dt < 0) {
        dt = 16;
      }
      if (dt > 200) {
        dt = 200;
      }
      this.lastTs = now;
      this.clock += dt;
      this.renderer.render(this.visible, this.clock, dt);
      if (this.visible.length > 0) {
        // ⭐ 原地压缩：飞出屏幕的弹幕（renderer 已置 visible=false）直接释放。
        //    旧实现每帧都 new 一个数组，60fps 下是持续的 GC 压力。
        let write: number = 0;
        for (let i = 0; i < this.visible.length; i++) {
          const it = this.visible[i];
          if (it.visible && !it.dropped) {
            this.visible[write] = it;
            write++;
          }
        }
        this.visible.length = write;
      }
    } catch (e) {
      logError(`[LiveDanmaku] 渲染异常: ${e}`);
    } finally {
      if (this.active) {
        this.timer = setTimeout(this.frame, this.visible.length > 0 ? 16 : 80);
      }
    }
  };
}
