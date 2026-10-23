/**
 * OfflineCacheService.ts
 * 离线缓存服务 — 参照 PiliPlus-ohos 的下载实现（DASH 高画质双流 + Range 断点续传）
 *
 * 目录结构：
 * filesDir/offline/{bvid}_{cid}/
 *   ├── entry.json   # 条目元数据
 *   ├── video.m4s    # DASH 视频轨（无 audioUrl 时即 FLV 完整流）
 *   └── audio.m4s    # DASH 音频轨（仅分离流时存在）
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { getVideoPlayUrl, PlayUrlResult } from '../api/BilibiliApi';
import {
  OfflineCacheItem, CacheStatus,
  CACHE_ROOT_DIR, ENTRY_FILE_NAME, VIDEO_FILE_NAME, AUDIO_FILE_NAME, cacheEntryDirName
} from '../model/OfflineCacheItem';
import { logInfo, logWarn, logError } from '../utils/Logger';

/** B站流媒体下载所需请求头 */
function biliStreamHeaders(): Record<string, string> {
  return {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
    'Referer': 'https://www.bilibili.com/'
  };
}

/** 进行中的下载任务（key=bvid_cid → 任务），用于暂停时中断请求 */
interface ActiveTask {
  item: OfflineCacheItem;
  request: http.HttpRequest | null;
}

export class OfflineCacheService {
  private static instance_: OfflineCacheService | null = null;

  static getInstance(): OfflineCacheService {
    if (OfflineCacheService.instance_ === null) {
      OfflineCacheService.instance_ = new OfflineCacheService();
    }
    return OfflineCacheService.instance_;
  }

  private appFilesDir_: string = '';
  // ⭐ 进行中的下载任务（key=bvid_cid → 任务），用于暂停时中断请求
  private activeTasks_: Map<string, ActiveTask> = new Map<string, ActiveTask>();
  // ⭐ 已请求暂停的 key（download 收尾时据此置 PAUSED 状态）
  private pausedKeys_: Set<string> = new Set<string>();

  /** 初始化（在 Ability 启动时调用一次） */
  init(context: common.Context): void {
    this.appFilesDir_ = context.filesDir;
  }

  /** 缓存根目录绝对路径 */
  getCacheRoot(): string {
    return this.appFilesDir_ + '/' + CACHE_ROOT_DIR;
  }

  private entryDir(bvid: string, cid: number): string {
    return this.getCacheRoot() + '/' + cacheEntryDirName(bvid, cid);
  }

  /**
   * 下载一个视频条目（自动区分 DASH 双流 / FLV 单流）
   * @param item 条目（bvid/cid/title/quality 必须已填）
   * @param onProgress 进度回调 (downloadedBytes, totalBytes)
   * @returns 是否成功
   */
  async download(item: OfflineCacheItem, onProgress: (downloaded: number, total: number) => void): Promise<boolean> {
    const taskKey: string = cacheEntryDirName(item.bvid, item.cid);
    // ⭐ 注册进行中任务（暂停时据此中断请求）；myTask 用于收尾时校验仍是本任务，避免误删/误写续传后的新任务
    const myTask: ActiveTask = { item: item, request: null };
    this.activeTasks_.set(taskKey, myTask);
    let playUrl: PlayUrlResult | null = null;
    try {
      playUrl = await getVideoPlayUrl(item.bvid, item.cid, item.quality);
    } catch (e) {
      logError(`[OfflineCache] 获取播放地址失败: ${JSON.stringify(e)}`);
      // ⭐ 仅当仍是本任务时才改写状态（暂停后可能已被续传的新任务接管）
      if (this.activeTasks_.get(taskKey) === myTask) {
        item.status = CacheStatus.FAILED;
        item.updateTime = Date.now();
        this.activeTasks_.delete(taskKey);
      }
      return false;
    }
    if (!playUrl || !playUrl.url) {
      logWarn(`[OfflineCache] 播放地址为空 bvid=${item.bvid}`);
      if (this.activeTasks_.get(taskKey) === myTask) {
        item.status = CacheStatus.FAILED;
        item.updateTime = Date.now();
        this.activeTasks_.delete(taskKey);
      }
      return false;
    }

    const dir = this.entryDir(item.bvid, item.cid);
    // ⭐ 目录已存在（重复缓存/残留）时 mkdirSync 会抛 13900015(File exists)，先检查再创建
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      logError(`[OfflineCache] 创建目录失败: ${JSON.stringify(e)}`);
      if (this.activeTasks_.get(taskKey) === myTask) {
        item.status = CacheStatus.FAILED;
        item.updateTime = Date.now();
        this.saveEntry(item);
        this.activeTasks_.delete(taskKey);
      }
      return false;
    }

    const videoPath = dir + '/' + VIDEO_FILE_NAME;
    const audioPath = dir + '/' + AUDIO_FILE_NAME;
    item.status = CacheStatus.DOWNLOADING;
    item.videoPath = videoPath;
    item.updateTime = Date.now();
    // ⭐ 下载开始即落盘元数据：缓存列表才能立即显示"下载中"条目
    this.saveEntry(item);
    // 进度节流保存时间戳（≥500ms 写一次 entry.json，避免频繁落盘）
    let lastSaveTs: number = 0;

    let videoOk = false;
    try {
      videoOk = await this.downloadOne(playUrl.url, videoPath, taskKey, (d: number, t: number) => {
        item.downloadedBytes = d;
        item.totalBytes = t;
        item.updateTime = Date.now();
        onProgress(d, t);
        const now = Date.now();
        if (now - lastSaveTs >= 500) {
          lastSaveTs = now;
          this.saveEntry(item);
        }
      });
    } catch (e) {
      logError(`[OfflineCache] 视频下载异常: ${JSON.stringify(e)}`);
    }

    // DASH 分离音频轨
    let audioOk = true;
    if (playUrl.audioUrl && !this.pausedKeys_.has(taskKey)) {
      try {
        audioOk = await this.downloadOne(playUrl.audioUrl, audioPath, taskKey, (d: number, t: number) => {
          // 音频轨进度并入总量显示（约 +20% 权重，简单估算）
          const baseTotal = item.totalBytes > 0 ? item.totalBytes : 1;
          item.downloadedBytes = baseTotal + d;
          item.totalBytes = baseTotal + t;
          item.updateTime = Date.now();
          onProgress(item.downloadedBytes, item.totalBytes);
          const now = Date.now();
          if (now - lastSaveTs >= 500) {
            lastSaveTs = now;
            this.saveEntry(item);
          }
        });
      } catch (e) {
        logError(`[OfflineCache] 音频下载异常: ${JSON.stringify(e)}`);
        audioOk = false;
      }
    }

    // ⭐ 用户暂停：置 PAUSED（可续传），不视为失败
    if (this.pausedKeys_.has(taskKey)) {
      this.pausedKeys_.delete(taskKey);
      // 仅当仍是本任务时才落盘状态（暂停后已被续传的新任务接管时不改写）
      if (this.activeTasks_.get(taskKey) === myTask) {
        item.status = CacheStatus.PAUSED;
        item.updateTime = Date.now();
        this.saveEntry(item);
        this.activeTasks_.delete(taskKey);
      }
      return false;
    }

    if (videoOk && audioOk && this.activeTasks_.get(taskKey) === myTask) {
      item.status = CacheStatus.COMPLETED;
      item.audioPath = playUrl.audioUrl ? audioPath : '';
      item.qualityLabel = playUrl.actualQn > 0 ? `${playUrl.actualQn}P` : item.qualityLabel;
      // ⭐ 完成时用实际文件大小刷新（Content-Length 解析可能缺失/偏差，DASH 双流需相加）
      let realBytes = 0;
      try {
        if (fs.accessSync(videoPath)) {
          realBytes += fs.statSync(videoPath).size;
        }
        if (playUrl.audioUrl && fs.accessSync(audioPath)) {
          realBytes += fs.statSync(audioPath).size;
        }
      } catch (e) {
        logWarn(`[OfflineCache] 统计实际大小失败: ${JSON.stringify(e)}`);
      }
      if (realBytes > 0) {
        item.downloadedBytes = realBytes;
        item.totalBytes = realBytes;
      }
      item.updateTime = Date.now();
      this.saveEntry(item);
      logInfo(`[OfflineCache] 缓存完成: ${item.title}`);
      this.activeTasks_.delete(taskKey);
      return true;
    }
    // ⭐ 失败也落盘（仅当仍是本任务，避免旧协程覆盖续传后新任务的状态）
    if (this.activeTasks_.get(taskKey) === myTask) {
      item.status = CacheStatus.FAILED;
      item.updateTime = Date.now();
      this.saveEntry(item);
      this.activeTasks_.delete(taskKey);
    }
    return false;
  }

  /**
   * 下载单个 URL 到本地文件，支持断点续传（Range）与暂停中断
   * @param taskKey bvid_cid（用于注册/查询任务与暂停标志）
   * @returns 是否成功
   */
  private async downloadOne(url: string, destPath: string, taskKey: string, onProgress: (downloaded: number, total: number) => void): Promise<boolean> {
    // 已有文件大小（续传起点）
    let existing = 0;
    try {
      if (fs.accessSync(destPath)) {
        const st = fs.statSync(destPath);
        existing = st.size;
      }
    } catch (e) {
      existing = 0;
    }

    const httpRequest = http.createHttp();
    // ⭐ 记录请求引用到任务，pause() 时 destroy 中断
    const task = this.activeTasks_.get(taskKey);
    if (task) {
      task.request = httpRequest;
    }
    let received = existing;

    const headers: Record<string, string> = biliStreamHeaders();
    if (existing > 0) {
      headers['Range'] = `bytes=${existing}-`;
    }

    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 60000
    };

    // ⭐ 本次流的总大小：优先由 Content-Length 解析，dataReceive 沿用（不再覆盖为 0）
    let totalBytes: number = 0;

    // ⭐ 首次响应头：解析 Content-Length 作为总大小（实时进度条需要）
    httpRequest.on('headersReceive', (header: Object) => {
      try {
        const h = header as Record<string, Object>;
        const lenStr = h['content-length'] as string;
        if (lenStr) {
          const len = parseInt(lenStr, 10);
          if (len > 0) {
            totalBytes = existing + len;
            onProgress(received, totalBytes);
          }
        }
      } catch (e) {
        // 头部解析失败不阻塞
      }
    });

    // 流式写入：dataReceive 回调逐块落盘；暂停标志存在则中断
    httpRequest.on('dataReceive', (data: ArrayBuffer) => {
      // ⭐ 暂停：中断请求，停止写入
      if (this.pausedKeys_.has(taskKey)) {
        try { httpRequest.destroy(); } catch (e) { }
        return;
      }
      try {
        const fd = fs.openSync(destPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
        fs.writeSync(fd.fd, data, { offset: received });
        fs.closeSync(fd);
        received += data.byteLength;
        onProgress(received, totalBytes);
      } catch (e) {
        logError(`[OfflineCache] 写盘失败: ${JSON.stringify(e)}`);
      }
    });

    let code = -1;
    try {
      code = await httpRequest.requestInStream(url, options);
    } catch (e) {
      logError(`[OfflineCache] 请求异常: ${JSON.stringify(e)}`);
      httpRequest.destroy();
      return false;
    }

    // 200 或 206(Partial Content) 均视为成功；暂停中断时返回 false
    if (code !== http.ResponseCode.OK && code !== 206) {
      if (!this.pausedKeys_.has(taskKey)) {
        logWarn(`[OfflineCache] HTTP ${code} for ${url.slice(0, 80)}`);
      }
      httpRequest.destroy();
      return false;
    }

    // 读取 Content-Length 更新总量
    let total = 0;
    try {
      const st = fs.statSync(destPath);
      total = st.size;
    } catch (e) {
      total = received;
    }
    onProgress(received, total);
    httpRequest.destroy();
    return true;
  }

  /** 保存条目元数据到 entry.json */
  private saveEntry(item: OfflineCacheItem): void {
    try {
      const filePath = this.entryDir(item.bvid, item.cid) + '/' + ENTRY_FILE_NAME;
      const content = JSON.stringify(item);
      const fd = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(fd.fd, content);
      fs.closeSync(fd);
    } catch (e) {
      logError(`[OfflineCache] 保存元数据失败: ${JSON.stringify(e)}`);
    }
  }

  /** 是否正在下载该视频 */
  isDownloading(bvid: string, cid: number): boolean {
    return this.activeTasks_.has(cacheEntryDirName(bvid, cid));
  }

  /** 暂停下载（中断当前请求，进度保留，可续传） */
  pause(bvid: string, cid: number): void {
    const taskKey: string = cacheEntryDirName(bvid, cid);
    this.pausedKeys_.add(taskKey);
    const task = this.activeTasks_.get(taskKey);
    if (task && task.request) {
      try { task.request.destroy(); } catch (e) { }
    }
    // ⭐ 立即移出进行中任务：requestInStream 在 destroy 后可能迟迟不 settle，
    // 若等 download() 协程收尾清理会永久残留，导致 resume() 永远命中"已在下载中"→ 只弹"继续下载失败"
    this.activeTasks_.delete(taskKey);
    // 同步落盘 PAUSED 状态（即便 dataReceive 中断回调稍后才触发）
    const items = this.listCached();
    for (let i = 0; i < items.length; i++) {
      if (items[i].bvid === bvid && items[i].cid === cid && items[i].status === CacheStatus.DOWNLOADING) {
        items[i].status = CacheStatus.PAUSED;
        items[i].updateTime = Date.now();
        this.saveEntry(items[i]);
        break;
      }
    }
  }

  /**
   * 继续下载（读取已保存条目，从断点续传）
   * @param onDone 下载结束回调（true=已完成，false=被暂停或失败）
   * @returns 是否成功启动
   */
  resume(bvid: string, cid: number, onDone?: (ok: boolean) => void): boolean {
    const taskKey: string = cacheEntryDirName(bvid, cid);
    if (this.activeTasks_.has(taskKey)) {
      return false; // 已在下载中
    }
    this.pausedKeys_.delete(taskKey);
    const items = this.listCached();
    let target: OfflineCacheItem | null = null;
    for (let i = 0; i < items.length; i++) {
      if (items[i].bvid === bvid && items[i].cid === cid) {
        target = items[i];
        break;
      }
    }
    if (!target) return false;
    // ⭐ 启动续传（不阻塞等待下载完成），结束后通过 onDone 回调通知调用方
    this.runDownload(target, onDone);
    return true;
  }

  /** 后台执行下载，结束时回调（true=完成，false=暂停/失败） */
  private async runDownload(target: OfflineCacheItem, onDone?: (ok: boolean) => void): Promise<void> {
    let ok = false;
    try {
      ok = await this.download(target, (d: number, t: number) => {
        logInfo(`[OfflineCache] 续传 ${target.title} ${d}/${t}`);
      });
    } catch (e) {
      logError(`[OfflineCache] 续传异常: ${JSON.stringify(e)}`);
    }
    if (onDone) {
      onDone(ok);
    }
  }

  /** 读取所有缓存条目（扫描目录 + entry.json） */
  listCached(): OfflineCacheItem[] {
    const result: OfflineCacheItem[] = [];
    try {
      fs.accessSync(this.getCacheRoot());
    } catch (e) {
      return result;
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(this.getCacheRoot());
    } catch (e) {
      return result;
    }
    for (let i = 0; i < names.length; i++) {
      const entryPath = this.getCacheRoot() + '/' + names[i] + '/' + ENTRY_FILE_NAME;
      try {
        if (!fs.accessSync(entryPath)) continue;
        const content = fs.readTextSync(entryPath);
        const parsed: OfflineCacheItem = JSON.parse(content) as OfflineCacheItem;
        if (parsed && parsed.bvid) {
          result.push(parsed);
        }
      } catch (e) {
        // 单个条目损坏不影响其他
      }
    }
    result.sort((a: OfflineCacheItem, b: OfflineCacheItem) => b.updateTime - a.updateTime);
    return result;
  }

  /** 读取单个缓存条目（不存在返回 null），用于区分「被暂停」与「失败」 */
  getCachedItem(bvid: string, cid: number): OfflineCacheItem | null {
    const items = this.listCached();
    for (let i = 0; i < items.length; i++) {
      if (items[i].bvid === bvid && items[i].cid === cid) {
        return items[i];
      }
    }
    return null;
  }

  /** 删除缓存条目 */
  removeCache(bvid: string, cid: number): boolean {
    const taskKey: string = cacheEntryDirName(bvid, cid);
    // ⭐ 先中断进行中的下载任务（否则 dataReceive 会用 CREATE 模式复活文件，删除失败）
    const task = this.activeTasks_.get(taskKey);
    if (task && task.request) {
      try { task.request.destroy(); } catch (e) { }
    }
    this.activeTasks_.delete(taskKey);
    this.pausedKeys_.delete(taskKey);

    const dir = this.entryDir(bvid, cid);
    // ⭐ 最多重试 3 轮：删除目录下所有文件后删除目录；有文件删除失败则下轮再试
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        let names: string[] = [];
        try {
          names = fs.listFileSync(dir);
        } catch (e) {
          // 目录已不存在 → 删除成功
          return true;
        }
        if (names.length === 0) {
          // 已清空，尝试删目录
          try {
            fs.rmdirSync(dir);
          } catch (e) {
            // 目录删除失败（可能仍有并发残留），下一轮再试
          }
          return true;
        }
        let allDeleted = true;
        for (let i = 0; i < names.length; i++) {
          try {
            fs.unlinkSync(dir + '/' + names[i]);
          } catch (e) {
            allDeleted = false; // 单文件删除失败，下一轮重试
          }
        }
        if (allDeleted) {
          try {
            fs.rmdirSync(dir);
            return true;
          } catch (e) {
            // 目录删除失败，下一轮再试
          }
        }
      } catch (e) {
        // 目录级异常，下一轮再试
      }
    }
    logError(`[OfflineCache] 删除不彻底（重试3轮后仍有残留）: ${bvid}_${cid}`);
    return false;
  }
}
