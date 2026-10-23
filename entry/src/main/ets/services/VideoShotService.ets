import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn } from '../utils/Logger';
import { HttpConstants } from '../api/HttpConstants';
import { fetchVideoShot, VideoShotData } from '../api/VideoShotApi';

/** 一次缩略图查询的结果 */
export interface SeekThumbFrame {
  pm: image.PixelMap;
  /** 单元格宽高比（用于按显示高度推算宽度） */
  aspect: number;
}

/** 已解码格子的 LRU 上限（一屏最多显示 1 张，留出前后拖动的余量即可） */
const CELL_LRU_MAX: number = 24;

/**
 * 视频缩略图（videoshot）服务：列表拉取 → 精灵图下载 → **只解目标格** → LRU 缓存
 *
 * 设计要点：
 * 1. **按需下载**：只下载当前拖动位置所在的那一张精灵图，不预下全部
 * 2. **只解一格**：用 `DecodingOptions.desiredRegion` + `CROP_FIRST` 直出单元格
 *    （160×90 ≈ 57KB），而不是把整张 1600×900 解成 RGBA（约 5.8MB）
 * 3. **负缓存**：番剧/直播等没有缩略图的视频只请求一次，之后直接返回 undefined，
 *    否则拖动期间每秒几十次调用会反复打接口
 * 4. **在途去重**：同一 cid/精灵图并发请求只发一次
 */
export class VideoShotService {
  /** cid 级列表缓存（bvid_cid → 数据） */
  private static dataCache: Map<string, VideoShotData> = new Map();
  /** 确认"该视频没有缩略图"的 key（负缓存） */
  private static dataFailed: Set<string> = new Set();
  /** 在途的列表请求（去重） */
  private static dataPending: Map<string, Promise<VideoShotData | undefined>> = new Map();
  /** 精灵图原始字节（一张约 60~250KB；解码前用它反复切格） */
  private static spriteBuf: Map<string, ArrayBuffer> = new Map();
  /** 在途的精灵图下载（去重） */
  private static spritePending: Map<string, Promise<ArrayBuffer | undefined>> = new Map();
  /** 单元格尺寸（url → [宽, 高]） */
  private static cellSize: Map<string, number[]> = new Map();
  /** 已解码的格子（url#cell → PixelMap） */
  private static cellCache: Map<string, image.PixelMap> = new Map();
  /** LRU 顺序（尾部最新） */
  private static cellOrder: string[] = [];
  /** 当前所属视频，用于切集时整体释放 */
  private static ownerKey: string = '';

  private static key(bvid: string, cid: number): string {
    return `${bvid}_${cid}`;
  }

  /**
   * 标记当前视频。切集/换视频时**整体释放**上一集的位图（精灵图很小，重下比留着划算）。
   * 调用方应先清空自己的缩略图引用再调用，避免释放后仍被 UI 引用。
   */
  static setOwner(bvid: string, cid: number): void {
    const k: string = VideoShotService.key(bvid, cid);
    if (k === VideoShotService.ownerKey) return;
    VideoShotService.ownerKey = k;
    VideoShotService.release();
  }

  /** 释放所有位图与缓存（退出播放页 / 换视频时调用） */
  static release(): void {
    VideoShotService.cellCache.forEach((pm: image.PixelMap) => {
      try {
        pm.release();
      } catch (_e) {
      }
    });
    VideoShotService.cellCache.clear();
    VideoShotService.cellOrder = [];
    VideoShotService.spriteBuf.clear();
    VideoShotService.dataCache.clear();
    VideoShotService.dataFailed.clear();
    VideoShotService.cellSize.clear();
    VideoShotService.dataPending.clear();
    VideoShotService.spritePending.clear();
  }

  /** 预取缩略图列表（fire-and-forget；起播后延迟调用，避开起播竞争） */
  static prefetch(bvid: string, cid: number): void {
    if (!bvid || cid <= 0) return;
    VideoShotService.ensureData(bvid, cid).then((d: VideoShotData | undefined) => {
      if (!d) return;
      logInfo(`[VideoShot] 预取完成 cid=${cid} 可用格数=${d.index.length}`);
    }).catch(() => {
    });
  }

  /**
   * 取目标秒数对应的缩略图。
   * 返回 undefined 表示"暂时没有"（没数据 / 还在下载 / 该视频不支持），
   * 调用方应**沿用上一张**而不是清空，避免拖动时闪白。
   */
  static async getFrame(bvid: string, cid: number, sec: number): Promise<SeekThumbFrame | undefined> {
    if (!bvid || cid <= 0 || sec < 0) return undefined;
    const data: VideoShotData | undefined = await VideoShotService.ensureData(bvid, cid);
    if (!data) return undefined;

    const cell: number = VideoShotService.findCell(data.index, sec);
    const per: number = data.imgXLen * data.imgYLen;
    const page: number = Math.max(0, Math.min(data.image.length - 1, Math.floor(cell / per)));
    const align: number = cell % per;
    const col: number = align % data.imgXLen;
    const row: number = Math.floor(align / data.imgXLen);
    const url: string = data.image[page];
    const cacheKey: string = `${url}#${cell}`;

    const hit: image.PixelMap | undefined = VideoShotService.cellCache.get(cacheKey);
    if (hit) {
      const size: number[] = VideoShotService.cellSize.get(url) ?? [data.imgXSize, data.imgYSize];
      return { pm: hit, aspect: VideoShotService.aspectOf(size) };
    }

    const buf: ArrayBuffer | undefined = await VideoShotService.ensureSprite(url);
    if (!buf) return undefined;
    const size: number[] = await VideoShotService.resolveCellSize(buf, url, data);
    const pm: image.PixelMap | undefined =
      await VideoShotService.decodeCell(buf, col, row, size[0], size[1]);
    if (!pm) return undefined;
    VideoShotService.putCell(cacheKey, pm);
    return { pm, aspect: VideoShotService.aspectOf(size) };
  }

  private static aspectOf(size: number[]): number {
    const cw: number = size[0];
    const ch: number = size[1];
    return (cw > 0 && ch > 0) ? cw / ch : 16 / 9;
  }

  /**
   * 二分查找"起始秒数 ≤ sec 的最后一格"。
   * `index` 升序且开头可能有重复的 0，取最后一个满足条件的下标才是正确格子。
   * （参考实现用 `count(index<=t) - 2`，在有重复 0 的列表上会稳定退到更早一帧，这里不采用）
   * 每次 Move 都会调用，所以用 O(log n) 而不是线性扫描。
   */
  private static findCell(index: number[], sec: number): number {
    let lo: number = 0;
    let hi: number = index.length - 1;
    let ans: number = 0;
    while (lo <= hi) {
      const mid: number = Math.floor((lo + hi) / 2);
      if (index[mid] <= sec) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  private static async ensureData(bvid: string, cid: number): Promise<VideoShotData | undefined> {
    const k: string = VideoShotService.key(bvid, cid);
    const hit: VideoShotData | undefined = VideoShotService.dataCache.get(k);
    if (hit) return hit;
    if (VideoShotService.dataFailed.has(k)) return undefined; // 负缓存：不再重复请求
    let pending: Promise<VideoShotData | undefined> | undefined = VideoShotService.dataPending.get(k);
    if (!pending) {
      pending = fetchVideoShot(bvid, cid);
      VideoShotService.dataPending.set(k, pending);
    }
    let data: VideoShotData | undefined = undefined;
    try {
      data = await pending;
    } catch (_e) {
      data = undefined;
    } finally {
      VideoShotService.dataPending.delete(k);
    }
    if (data) {
      VideoShotService.dataCache.set(k, data);
    } else {
      VideoShotService.dataFailed.add(k);
    }
    return data;
  }

  private static async ensureSprite(url: string): Promise<ArrayBuffer | undefined> {
    const hit: ArrayBuffer | undefined = VideoShotService.spriteBuf.get(url);
    if (hit) return hit;
    let pending: Promise<ArrayBuffer | undefined> | undefined = VideoShotService.spritePending.get(url);
    if (!pending) {
      pending = VideoShotService.downloadSprite(url);
      VideoShotService.spritePending.set(url, pending);
    }
    let buf: ArrayBuffer | undefined = undefined;
    try {
      buf = await pending;
    } catch (_e) {
      buf = undefined;
    } finally {
      VideoShotService.spritePending.delete(url);
    }
    if (buf) VideoShotService.spriteBuf.set(url, buf);
    return buf;
  }

  /**
   * 下载精灵图。
   * ⚠️ 与 `utils/ImageCache.ts` 的 `predecodeImage` 不同：**不在这里解码** ——
   *    精灵图要按格子切，整张解码是 5.8MB，切成 160×90 才是 57KB。
   */
  private static async downloadSprite(url: string): Promise<ArrayBuffer | undefined> {
    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': HttpConstants.USER_AGENT_WEB,
          // 实测精灵图没有防盗链（不带 Referer 也是 200），带上更保险
          'Referer': 'https://www.bilibili.com/'
        },
        connectTimeout: 8000,
        readTimeout: 15000,
        usingProtocol: http.HttpProtocol.HTTP1_1
      });
      if (resp.responseCode !== 200 || !resp.result) {
        logWarn(`[VideoShot] 精灵图 HTTP ${resp.responseCode}`);
        return undefined;
      }
      return resp.result as ArrayBuffer;
    } catch (e) {
      logWarn(`[VideoShot] 精灵图下载异常: ${JSON.stringify(e)}`);
      return undefined;
    } finally {
      httpRequest.destroy();
    }
  }

  /** 单元格尺寸：优先用接口声明的；接口给 0 时按"整图 ÷ 网格数"推导（只探一次） */
  private static async resolveCellSize(buf: ArrayBuffer, url: string,
                                       data: VideoShotData): Promise<number[]> {
    const cached: number[] | undefined = VideoShotService.cellSize.get(url);
    if (cached) return cached;
    let cw: number = data.imgXSize;
    let ch: number = data.imgYSize;
    if (cw <= 0 || ch <= 0) {
      const src: image.ImageSource | undefined = image.createImageSource(buf);
      if (src) {
        try {
          const info: image.ImageInfo = await src.getImageInfo();
          cw = Math.floor(info.size.width / data.imgXLen);
          ch = Math.floor(info.size.height / data.imgYLen);
        } catch (_e) {
        } finally {
          src.release();
        }
      }
    }
    if (cw <= 0 || ch <= 0) {
      // 最后兜底（实测标准值：160×90）
      cw = 160;
      ch = 90;
    }
    const r: number[] = [cw, ch];
    VideoShotService.cellSize.set(url, r);
    return r;
  }

  /**
   * **只解目标格**：`desiredRegion` 指定切哪一格，`CROP_FIRST` 保证"先裁后缩"的顺序确定。
   * 内存差别很大：单元格 160×90 RGBA ≈ 57KB，整张精灵图 1600×900 ≈ 5.8MB。
   */
  private static async decodeCell(buf: ArrayBuffer, col: number, row: number,
                                  cw: number, ch: number): Promise<image.PixelMap | undefined> {
    const src: image.ImageSource | undefined = image.createImageSource(buf);
    if (!src) return undefined;
    try {
      const opts: image.DecodingOptions = {
        desiredRegion: { x: col * cw, y: row * ch, size: { width: cw, height: ch } },
        desiredSize: { width: cw, height: ch },
        cropAndScaleStrategy: image.CropAndScaleStrategy.CROP_FIRST
      };
      return await src.createPixelMap(opts);
    } catch (e) {
      logWarn(`[VideoShot] 切格失败 col=${col} row=${row}: ${JSON.stringify(e)}`);
      return undefined;
    } finally {
      src.release();
    }
  }

  private static putCell(key: string, pm: image.PixelMap): void {
    VideoShotService.cellCache.set(key, pm);
    VideoShotService.cellOrder.push(key);
    while (VideoShotService.cellOrder.length > CELL_LRU_MAX) {
      const old: string | undefined = VideoShotService.cellOrder.shift();
      // 保护"当前这一张"：它永远是最后 push 进来的
      if (!old || old === key) continue;
      const oldPm: image.PixelMap | undefined = VideoShotService.cellCache.get(old);
      if (oldPm) {
        try {
          oldPm.release();
        } catch (_e) {
        }
      }
      VideoShotService.cellCache.delete(old);
    }
  }
}
