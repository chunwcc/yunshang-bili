import { media } from '@kit.MediaKit';
import { http } from '@kit.NetworkKit';
import { HashMap } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = '[DashMediaLoader]';

export interface DashLoaderConfig {
  mpdXml: string;
  videoUrl: string;
  audioUrl: string;
  referer: string;
  userAgent: string;
  cookie: string;
  /** ⭐ 已知全量大小（playurl 返回）：open 时同步回 header，避免与 fetchRemoteSize 竞态 */
  videoContentLength?: number;
  audioContentLength?: number;
  /** ⭐ SegmentTemplate 虚拟分段：sidx 解析出的子段（fileOffset 是真实 m4s 内字节起点） */
  videoSegments?: Array<SegmentRange>;
  audioSegments?: Array<SegmentRange>;
  /** ⭐ init 段字节长度（0-initRange 末端的字节数） */
  videoInitSize?: number;
  audioInitSize?: number;
}

export interface SegmentRange {
  /** 子段在真实 m4s 文件内的字节起点 */
  fileOffset: number;
  /** 子段字节长度 */
  size: number;
}

interface ActiveRequest {
  url: string;
  request: media.MediaSourceLoadingRequest;
  totalSize: number;
  offset: number;
  done: boolean;
  /** ⭐ 合成数据源（MPD）：read 回调从该 buffer 按 offset 切片推送，不走网络 */
  inlineData?: ArrayBuffer;
  /** ⭐ 虚拟分段映射：请求对应真实 m4s 文件的字节起点（0=init/整文件） */
  segStart: number;
}

export class DashMediaLoader {
  private config: DashLoaderConfig | null = null;
  private requests: HashMap<number, ActiveRequest> = new HashMap();
  private nextUuid: number = 1;
  private httpTasks: HashMap<number, http.HttpRequest> = new HashMap();

  constructor() {}

  setConfig(config: DashLoaderConfig): void {
    this.config = config;
  }

  getLoader(): media.MediaSourceLoader {
    const self = this;
    const loader: media.MediaSourceLoader = {
      open: (request: media.MediaSourceLoadingRequest): number => {
        return self.handleOpen(request);
      },
      read: (uuid: number, requestedOffset: number, requestedLength: number): void => {
        self.handleRead(uuid, requestedOffset, requestedLength);
      },
      close: (uuid: number): void => {
        self.handleClose(uuid);
      }
    };
    return loader;
  }

  destroy(): void {
    this.requests.clear();
    this.httpTasks.clear();
    this.config = null;
  }

  private handleOpen(request: media.MediaSourceLoadingRequest): number {
    if (!this.config) {
      console.error(`${TAG} no config`);
      return -1;
    }

    const url = request.url;
    const uuid = this.nextUuid;
    this.nextUuid += 1;
    console.info(`${TAG} open: url=${url}, uuid=${uuid}`);

    if (url.endsWith('.mpd') || url.endsWith('/manifest.mpd') || url.indexOf('manifest.mpd') >= 0) {
      // ⭐ MPD 是合成数据源：open 只注册资源（读回调按 offset 推送），
      //    实测 AVPlayer 期望 read 驱动数据而非 open 一次性 push
      const mpdBytes = this.strToArrayBuffer(this.config.mpdXml);
      const activeReq: ActiveRequest = {
        url: url,
        request: request,
        totalSize: mpdBytes.byteLength,
        offset: 0,
        done: false,
        inlineData: mpdBytes,
        segStart: 0
      };
      this.requests.set(uuid, activeReq);
      request.respondHeader(uuid, {
        'Content-Type': 'application/dash+xml',
        'content-length': String(mpdBytes.byteLength)
      });
      return uuid;
    }

    // ⭐ 虚拟分段拦截：video_init.m4s / video_seg_N.m4s → 真实 m4s 字节范围
    let targetUrl = '';
    let knownSize = 0;
    let segStart = 0;
    let segSize = 0;

    if (url.indexOf('video_init.m4s') >= 0 || url.endsWith('video.m4s') || url.indexOf('video.m4s') >= 0) {
      targetUrl = this.config.videoUrl;
      knownSize = this.config.videoContentLength || 0;
      // init.m4s: 0-initSize；video.m4s 兜底整文件
      if (url.indexOf('video_init.m4s') >= 0) {
        const initSize = this.config.videoInitSize || 0;
        segSize = initSize;
        segStart = 0;
        knownSize = segSize > 0 ? segSize : knownSize;
      }
    } else if (url.indexOf('audio_init.m4s') >= 0 || url.endsWith('audio.m4s') || url.indexOf('audio.m4s') >= 0) {
      targetUrl = this.config.audioUrl;
      knownSize = this.config.audioContentLength || 0;
      if (url.indexOf('audio_init.m4s') >= 0) {
        const initSize = this.config.audioInitSize || 0;
        segSize = initSize;
        segStart = 0;
        knownSize = segSize > 0 ? segSize : knownSize;
      }
    } else if (url.startsWith('https://') || url.startsWith('http://')) {
      // ⭐ 透传兜底：任意 http(s) 媒体 URL（含 .m4v/.m4a/.mp4 等）直连回源。
      //    注意：video_init/video_seg 等虚拟名在上一分支拦截，不会走到这里。
      targetUrl = url;
    }

    // ⭐ video_seg_N.m4s / audio_seg_N.m4s：从探测的分段表取字节范围
    //   MPD startNumber="1"，故 seg_N → table[N-1]
    const segPattern = /(video|audio)_seg_(\d+)\.m4s/;
    const segMatch = segPattern.exec(url);
    if (segMatch) {
      const kind = segMatch[1];
      const num = parseInt(segMatch[2], 10);
      const idx = num - 1;
      const list = kind === 'video' ? this.config.videoSegments : this.config.audioSegments;
      targetUrl = kind === 'video' ? this.config.videoUrl : this.config.audioUrl;
      if (list && idx >= 0 && idx < list.length) {
        const entry = list[idx];
        segStart = entry.fileOffset;
        segSize = entry.size;
        knownSize = segSize;
      } else {
        console.warn(`${TAG} seg[${num}] 不在表内，拒绝`);
        request.finishLoading(uuid, media.LoadingRequestError.LOADING_ERROR_NO_RESOURCE);
        return -1;
      }
    }

    if (!targetUrl) {
      console.error(`${TAG} unknown URL: ${url}`);
      request.finishLoading(uuid, media.LoadingRequestError.LOADING_ERROR_NO_RESOURCE);
      return -1;
    }

    const activeReq: ActiveRequest = {
      url: targetUrl,
      request: request,
      totalSize: knownSize,
      offset: 0,
      done: false,
      segStart: segStart
    };
    this.requests.set(uuid, activeReq);
    if (knownSize > 0) {
      // ⭐ 大小已知：同步回 header，等 read 回调即可，无需额外探测请求
      request.respondHeader(uuid, {
        'Content-Type': 'video/mp4',
        'content-length': String(knownSize),
        'Accept-Ranges': 'bytes'
      });
    } else {
      this.fetchRemoteSize(uuid, targetUrl);
    }
    return uuid;
  }

  private handleRead(uuid: number, requestedOffset: number, requestedLength: number): void {
    const activeReq = this.requests.get(uuid);
    if (!activeReq || activeReq.done) {
      console.info(`${TAG} read: uuid=${uuid} offset=${requestedOffset} len=${requestedLength} SKIP(done=${activeReq?.done})`);
      return;
    }
    console.info(`${TAG} read: uuid=${uuid} offset=${requestedOffset} len=${requestedLength} url=${activeReq.url} total=${activeReq.totalSize}`);
    // ⭐ inlineData（MPD 合成源）本地切片推送，不走网络
    if (activeReq.inlineData) {
      this.pushInline(uuid, activeReq, requestedOffset, requestedLength);
      return;
    }
    this.fetchRange(uuid, requestedOffset, requestedLength);
  }

  /** ⭐ MPD 合成源：从 inlineData 按 offset 切回（len=-1 表示读到 EOF，这是 AVPlayer 常见请求） */
  private pushInline(uuid: number, activeReq: ActiveRequest, offset: number, len: number): void {
    const buf = activeReq.inlineData;
    if (!buf) {
      return;
    }
    const total = buf.byteLength;
    if (offset >= total) {
      activeReq.done = true;
      activeReq.request.finishLoading(uuid, media.LoadingRequestError.LOADING_ERROR_SUCCESS);
      return;
    }
    const end = len < 0 ? total : Math.min(offset + len, total);
    const slice = buf.slice(offset, end);
    const accepted = activeReq.request.respondData(uuid, offset, slice);
    if (accepted === -2) {
      activeReq.done = true;
      return;
    }
    if (end >= total) {
      activeReq.done = true;
      activeReq.request.finishLoading(uuid, media.LoadingRequestError.LOADING_ERROR_SUCCESS);
    }
  }

  private handleClose(uuid: number): void {
    const task = this.httpTasks.get(uuid);
    if (task) {
      try {
        task.destroy();
      } catch (_e) {
      }
      this.httpTasks.remove(uuid);
    }
    this.requests.remove(uuid);
  }

  private async fetchRemoteSize(uuid: number, url: string): Promise<void> {
    const activeReq = this.requests.get(uuid);
    if (!activeReq) {
      return;
    }
    try {
      const httpRequest = http.createHttp();
      // ⭐ Range: bytes=0-0 只取 1 字节，通过 Content-Range 拿全量大小，
      //    避免无 Range 请求触发 CDN 返回 200 全量体导致 OOM
      const rangeHeaders = this.buildHeaders();
      rangeHeaders['Range'] = 'bytes=0-0';
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: rangeHeaders,
        // ⭐ 修复：默认 STRING 会把分片二进制解码为字符串，respondData 将收到坏数据
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 10000
      });
      httpRequest.destroy();
      const headerObj = response.header as Record<string, string>;
      const contentRange = headerObj['content-range'] || '';
      const rangeParts = contentRange.split('/');
      const contentLength = rangeParts.length > 1
        ? Number(rangeParts[1]) || 0
        : Number(headerObj['content-length']) || 0;
      if (contentLength > 0) {
        activeReq.totalSize = contentLength;
        activeReq.request.respondHeader(uuid, {
          'Content-Type': 'video/mp4',
          'content-length': String(contentLength),
          'Accept-Ranges': 'bytes'
        });
      }
    } catch (err) {
      console.error(`${TAG} fetchRemoteSize failed: ${(err as BusinessError).message}`);
      const req = this.requests.get(uuid);
      if (req) {
        req.request.finishLoading(uuid, media.LoadingRequestError.LOADING_ERROR_ACCESS_TIMEOUT);
      }
    }
  }

  private async fetchRange(uuid: number, offset: number, length: number): Promise<void> {
    const activeReq = this.requests.get(uuid);
    if (!activeReq || activeReq.done) {
      return;
    }
    const url = activeReq.url;
    // ⭐ len=-1：AVPlayer 表示“读到 EOF”，按已知总长拉取剩余
    let end = offset + (length < 0 ? (activeReq.totalSize > 0 ? activeReq.totalSize - offset : 0) : length) - 1;
    // ⭐ clamp 到已知文件末尾，避免超界 Range 被 CDN 回 416
    if (activeReq.totalSize > 0 && end >= activeReq.totalSize) {
      end = activeReq.totalSize - 1;
    }
    if (offset > end) {
      // 已到文件尾：EOF
      activeReq.done = true;
      activeReq.request.finishLoading(uuid, media.LoadingRequestError.LOADING_ERROR_SUCCESS);
      return;
    }
    console.info(`${TAG} fetchRange: uuid=${uuid} bytes=${offset}-${end} segStart=${activeReq.segStart}`);

    try {
      const httpRequest = http.createHttp();
      this.httpTasks.set(uuid, httpRequest);
      // ⭐ 虚拟分段：真实文件偏移 = segStart + 段内 offset
      const realOffset = activeReq.segStart + offset;
      const realEnd = activeReq.segStart + end;
      const rangeHeader = `bytes=${realOffset}-${realEnd}`;
      const baseHeaders = this.buildHeaders();
      const rangeHeaders: Record<string, string> = {
        'User-Agent': baseHeaders['User-Agent'],
        'Referer': baseHeaders['Referer'],
        'Origin': baseHeaders['Origin'],
        'Range': rangeHeader
      };
      if (baseHeaders['Cookie']) {
        rangeHeaders['Cookie'] = baseHeaders['Cookie'];
      }
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: rangeHeaders,
        // ⭐ 修复：默认 STRING 会把分片二进制解码为字符串，respondData 将收到坏数据
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 15000
      });
      this.httpTasks.remove(uuid);
      httpRequest.destroy();

      if (response.responseCode === 200 || response.responseCode === 206) {
        const buf = response.result as ArrayBuffer;
        const accepted = activeReq.request.respondData(uuid, offset, buf);
        if (accepted === -2) {
          activeReq.done = true;
        }
        if (offset + buf.byteLength >= activeReq.totalSize && activeReq.totalSize > 0) {
          activeReq.done = true;
          activeReq.request.finishLoading(uuid, media.LoadingRequestError.LOADING_ERROR_SUCCESS);
        }
      } else {
        console.error(`${TAG} fetchRange HTTP ${response.responseCode}`);
        activeReq.request.finishLoading(uuid, media.LoadingRequestError.LOADING_ERROR_ACCESS_DENIED);
      }
    } catch (err) {
      console.error(`${TAG} fetchRange error: ${(err as BusinessError).message}`);
      this.httpTasks.remove(uuid);
      const req = this.requests.get(uuid);
      if (req && !req.done) {
        req.request.finishLoading(uuid, media.LoadingRequestError.LOADING_ERROR_ACCESS_TIMEOUT);
      }
    }
  }

  private buildHeaders(): Record<string, string> {
    if (!this.config) {
      const empty: Record<string, string> = {};
      return empty;
    }
    const headers: Record<string, string> = {
      'User-Agent': this.config.userAgent,
      'Referer': this.config.referer,
      'Origin': 'https://www.bilibili.com'
    };
    if (this.config.cookie) {
      headers['Cookie'] = this.config.cookie;
    }
    return headers;
  }

  private strToArrayBuffer(str: string): ArrayBuffer {
    const buf = new ArrayBuffer(str.length);
    const view = new Uint8Array(buf);
    for (let i = 0; i < str.length; i++) {
      view[i] = str.charCodeAt(i);
    }
    return buf;
  }
}
