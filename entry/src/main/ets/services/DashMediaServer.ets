/**
 * DashMediaServer —— 方案① 本地 HTTP 转播站
 *
 * 在 App 内起一个 127.0.0.1 TCP 服务，把 B 站 DASH 双流伪装成真实 HTTP 资源：
 *   GET /manifest.mpd   → 合成 SegmentTemplate MPD（AVPlayer 直连 DASH 已验证可播）
 *   GET /video/init     → 视频轨 ftyp+moov（真实 m4s 0-initSize）
 *   GET /video/seg/:n   → 视频轨第 n 个 moof/mdat（sidx 字节范围）
 *   GET /audio/init     → 音频轨 init
 *   GET /audio/seg/:n   → 音频轨第 n 段
 *
 * AVPlayer 用 createMediaSourceWithUrl("http://127.0.0.1:PORT/manifest.mpd")
 * 直连播放（不挂 MediaSourceLoader — 已实测 loader 模式不走 DASH 解析）。
 *
 * 协议：HTTP/1.1，支持 Range（AVPlayer 会用 byte-range 拉取），
 *       全部二进制回源 B 站真实 m4s URL，Referer/Cookie 由本服务注入。
 */
import { socket } from '@kit.NetworkKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = '[DashMediaServer]';

/** 转播站配置（由 PoC 页探测后注入） */
export interface DashServerConfig {
  mpdXml: string;
  videoUrl: string;
  audioUrl: string;
  referer: string;
  userAgent: string;
  cookie: string;
  /** 各子段字节范围（sidx 解析结果） */
  videoSegments: Array<SegmentRange>;
  audioSegments: Array<SegmentRange>;
  videoInitSize: number;
  audioInitSize: number;
  /** ⭐ 文件总大小（探测 contentLength）：越界 Range 返回 416，必须先夹紧 */
  videoFileSize: number;
  audioFileSize: number;
  /** ⭐ 探测已下载的头部字节（覆盖 initRange=0-moovEnd）：init 请求命中时零回源 */
  videoInitBuffer?: ArrayBuffer;
  audioInitBuffer?: ArrayBuffer;
  /**
   * ⭐ 时间轴刻度（sidx 的 timescale）。
   * 只有 `prefetchSegmentAtTime()` 做「时间 → 分段下标」换算时才需要它；
   * 不填的调用方（如 DashPocPage）不受影响，只是用不了按时间预取。
   */
  videoTimescale?: number;
  audioTimescale?: number;
}

export interface SegmentRange {
  fileOffset: number;
  size: number;
  /**
   * ⭐ 该子段的时长（sidx 的 subsegment_duration，单位 = timescale）。
   * 供 `prefetchSegmentAtTime()` 累加定位「第 N 秒落在哪一段」——
   * 分段时长并不均匀，不能用 总时长/段数 平均估算，所以必须把 sidx 的真实值带过来。
   * 老调用方不填也能跑（缺失时按 5 秒兜底估算，只影响预取精度）。
   */
  duration?: number;
}

/** 单个客户端连接 */
class Client {
  conn: socket.TCPSocketConnection;
  buffer: Uint8Array = new Uint8Array(0);
  /** 是否正在处理某个请求（防并发写同一连接） */
  busy: boolean = false;
  reqId: string = '';

  constructor(conn: socket.TCPSocketConnection) {
    this.conn = conn;
  }

  /** 追加接收字节 */
  append(data: ArrayBuffer): void {
    const incoming = new Uint8Array(data);
    const merged = new Uint8Array(this.buffer.length + incoming.length);
    merged.set(this.buffer, 0);
    merged.set(incoming, this.buffer.length);
    this.buffer = merged;
  }

  /** 消费已处理的字节（丢弃前 count 字节） */
  consume(count: number): void {
    if (count <= 0) {
      return;
    }
    const remain = this.buffer.length - count;
    if (remain <= 0) {
      this.buffer = new Uint8Array(0);
      return;
    }
    const next = new Uint8Array(remain);
    next.set(this.buffer.subarray(count), 0);
    this.buffer = next;
  }
}

export class DashMediaServer {
  private config: DashServerConfig | null = null;
  private server: socket.TCPSocketServer | null = null;
  private clients: Array<Client> = [];
  private port: number = 0;
  /** ⭐ 兜底段大小：sidx 无 size 时拉取上限 */
  private static readonly MAX_SEG: number = 4 * 1024 * 1024;
  /**
   * ⭐ "大段"阈值：超过它就不再顺带预取下一段。
   * 4K（15Mbps）5 秒段 8~10MB，顺带多拉一段等于把首帧前的下载量翻倍；
   * 1080P（1~4Mbps）段只有 0.6~2.4MB，顺带预取仍然划算。
   */
  private static readonly LARGE_SEG_BYTES: number = 3 * 1024 * 1024;
  /**
   * ⭐ 回源字节缓存：key=url#start-end。预取首分片命中，免 CDN 冷连接（首帧关键路径）
   *
   * ⚠️ static：切画质会新建一个 DashMediaServer（旧实例被 stop），若缓存是实例字段，
   *    升级前预取好的 4K 分段在切换瞬间全丢，切档又要冷拉 8~10MB/段（实测中断 4.6s）。
   *    改成进程级共享后，「预取实例」拉到的段「播放实例」直接可用。
   */
  private static cache: Map<string, ArrayBuffer> = new Map();
  private static cacheBytes: number = 0;
  /** ⭐ 在途回源请求：相同区间并发去重（预取与 AVPlayer 请求同时拉同一分片时合并，避免双份下载抢带宽） */
  private static inflight: Map<string, Promise<ArrayBuffer | null>> = new Map();
  /** 缓存总字节上限：超出按插入序淘汰最旧（后续分片无需长期缓存） */
  private static readonly CACHE_LIMIT: number = 8 * 1024 * 1024;

  constructor() {}

  getPort(): number {
    return this.port;
  }

  setConfig(config: DashServerConfig): void {
    this.config = config;
  }

  /** 启动服务：监听 127.0.0.1:0（自动分配端口） */
  async start(): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    this.server = server;
    server.on('connect', (conn: socket.TCPSocketConnection) => {
      this.handleConnection(conn);
    });

    // 监听地址：本机回环
    // socket.NetAddress 的 address 字段为 string
    const addr: socket.NetAddress = { address: '127.0.0.1', family: 1, port: 0 };
    await server.listen(addr);
    const localAddr = await server.getLocalAddress();
    this.port = localAddr.port ?? 0;
    console.info(`${TAG} 转播站已启动 127.0.0.1:${this.port}`);
  }

  async stop(): Promise<void> {
    if (this.server) {
      try {
        await this.server.close();
      } catch (e) {
        console.error(`${TAG} stop error: ${(e as BusinessError).message}`);
      }
      this.server = null;
    }
    this.clients = [];
    this.port = 0;
    // ⚠️ 不要在这里清静态缓存：切画质会先 stop 旧实例，
    //    而「升级前预热」拉好的 4K 分段正是靠这份缓存被新实例复用；
    //    在这里清空等于预热白做（实测切档仍要 4.24s）。
    //    缓存由 CACHE_LIMIT 控制总量，跨视频残留也是 8MB 上限内。
  }

  /** ⭐ 显式清空回源缓存（页面退出/切视频时调用） */
  static clearSharedCache(): void {
    DashMediaServer.cache.clear();
    DashMediaServer.cacheBytes = 0;
    DashMediaServer.inflight.clear();
  }

  // ==================== 回源缓存层（首分片预取 + 精确/切片命中） ====================

  private cacheKey(url: string, start: number, end: number): string {
    return `${url}#${start}-${end}`;
  }

  private cachePut(key: string, data: ArrayBuffer): void {
    DashMediaServer.cache.set(key, data);
    DashMediaServer.cacheBytes += data.byteLength;
    while (DashMediaServer.cacheBytes > DashMediaServer.CACHE_LIMIT && DashMediaServer.cache.size > 0) {
      const oldestKey = DashMediaServer.cache.keys().next().value as string;
      const old = DashMediaServer.cache.get(oldestKey);
      if (old) {
        DashMediaServer.cacheBytes -= old.byteLength;
      }
      DashMediaServer.cache.delete(oldestKey);
    }
  }

  private cacheGetExact(url: string, start: number, end: number): ArrayBuffer | null {
    const hit = DashMediaServer.cache.get(this.cacheKey(url, start, end));
    return hit ? hit : null;
  }

  /** 缓存中存在覆盖 [start,end] 的完整段时切片返回（AVPlayer 带 Range 请求也能命中整段预取） */
  private cacheGetSlice(url: string, start: number, end: number): ArrayBuffer | null {
    let bestKey: string | null = null;
    let bestStart = -1;
    let bestLen = Number.MAX_SAFE_INTEGER;
    DashMediaServer.cache.forEach((_data: ArrayBuffer, k: string) => {
      if (!k.startsWith(url + '#')) {
        return;
      }
      const m = /#(\d+)-(\d+)$/.exec(k);
      if (!m) {
        return;
      }
      const cStart = parseInt(m[1], 10);
      const cEnd = parseInt(m[2], 10);
      // 取覆盖 [start,end] 且范围最小者（避免误命中更大的相邻缓存）
      if (cStart <= start && end <= cEnd && (cEnd - cStart) < bestLen) {
        bestKey = k;
        bestStart = cStart;
        bestLen = cEnd - cStart;
      }
    });
    if (bestKey !== null) {
      const data = DashMediaServer.cache.get(bestKey);
      if (data) {
        return data.slice(start - bestStart, end - bestStart + 1);
      }
    }
    return null;
  }

  /** 先查缓存（精确/切片命中），未命中回源；相同区间在途请求合并共享同一次回源 */
  private async fetchCached(url: string, start: number, end: number, cfg: DashServerConfig): Promise<ArrayBuffer | null> {
    const exact = this.cacheGetExact(url, start, end);
    if (exact) {
      return exact;
    }
    const slice = this.cacheGetSlice(url, start, end);
    if (slice) {
      return slice;
    }
    const key = this.cacheKey(url, start, end);
    const pending = DashMediaServer.inflight.get(key);
    if (pending) {
      return await pending;
    }
    const p = this.fetchRange(url, start, end, cfg);
    DashMediaServer.inflight.set(key, p);
    try {
      return await p;
    } finally {
      DashMediaServer.inflight.delete(key);
    }
  }

  /** ⭐ 预取指定段入缓存（fire-and-forget；失败不影响播放，route 会回源兜底） */
  prefetchSegment(isVideo: boolean, segIdx: number): void {
    const cfg = this.config;
    if (!cfg) {
      return;
    }
    const list = isVideo ? cfg.videoSegments : cfg.audioSegments;
    const url = isVideo ? cfg.videoUrl : cfg.audioUrl;
    const fileSize = isVideo ? cfg.videoFileSize : cfg.audioFileSize;
    if (segIdx < 0 || segIdx >= list.length) {
      return;
    }
    const entry = list[segIdx];
    // 与 route 的 seg 计算保持一致：sidx size 兜底 + 异常大值防御 + 文件尾 clamp
    let segLen = entry.size > 0 ? entry.size : DashMediaServer.MAX_SEG;
    if (segLen > DashMediaServer.MAX_SEG * 16) {
      segLen = DashMediaServer.MAX_SEG;
    }
    let realEnd = entry.fileOffset + segLen - 1;
    if (fileSize > 0 && realEnd >= fileSize) {
      realEnd = fileSize - 1;
    }
    if (realEnd < entry.fileOffset) {
      return;
    }
    const key = this.cacheKey(url, entry.fileOffset, realEnd);
    if (DashMediaServer.cache.has(key) || DashMediaServer.inflight.has(key)) {
      return;
    }
    // 注册在途：AVPlayer 随后请求同区间时经 fetchCached 合并共享，不重复回源
    const p = this.fetchRange(url, entry.fileOffset, realEnd, cfg).then((data: ArrayBuffer | null) => {
      if (data) {
        this.cachePut(key, data);
      }
      DashMediaServer.inflight.delete(key);
      return data;
    }, () => {
      DashMediaServer.inflight.delete(key);
      return null;
    });
    DashMediaServer.inflight.set(key, p);
  }

  /**
   * ⭐ 按【时间】预取分段（续播 / 切画质用）。
   *
   * 为什么需要：播放器 seek 到 N 秒时，必须冷拉覆盖该时刻的整段（高码率片一段 2~4MB），
   * 实测这是首帧前最大的一块等待 —— 3.83s 的首帧里有 2.8s 花在「拉 seg 6~9」上，
   * 而首分片预取只覆盖了第 0 段、对 seek 目标无能为力。
   * 本方法把「N 秒 → 分段下标」算出来后走同一条 prefetchSegment 通路，于是这段下载
   * 与 AVPlayer 创建 / prepare 并行，seek 发起时直接命中缓存。
   *
   * 顺带预取下一段：seek 命中后播放器会紧接着连续请求后一段，一起拉掉省一次往返。
   */
  prefetchSegmentAtTime(isVideo: boolean, timeMs: number): void {
    const cfg = this.config;
    if (!cfg || timeMs <= 0) {
      return;
    }
    const list = isVideo ? cfg.videoSegments : cfg.audioSegments;
    const timescale = isVideo ? cfg.videoTimescale : cfg.audioTimescale;
    if (!timescale || timescale <= 0 || list.length === 0) {
      return;
    }
    // ⚠️ 分段时长不均匀（sidx 逐条给出），必须累加真实 duration 而不是 总时长/段数 均分
    const target = timeMs / 1000 * timescale;
    const fallback = timescale * 5;   // 缺 duration 时按 5 秒兜底
    let acc = 0;
    for (let i = 0; i < list.length; i++) {
      // ⚠️ duration 是可选字段，必须先 ?? 收敛成 number ——
      //    ArkTS 严格空值检查不允许在条件里判完再当 number 用（Object is possibly 'undefined'）
      const raw: number = list[i].duration ?? 0;
      const d: number = raw > 0 ? raw : fallback;
      acc += d;
      if (acc > target) {
        this.prefetchSegment(isVideo, i);
        // ⭐ 大段（4K 常见 8~10MB/段）不再顺带预取下一段：
        //    实测 4K+续播场景预取 seg4+seg5 ≈ 19MB，而播放器真正从 seg5 起播，
        //    多拉的这一段纯属把首帧前排队的字节数翻倍；1080P 段只有 1~2MB，顺带预取仍划算。
        const curSize: number = list[i].size ?? 0;
        const nextSize: number = (i + 1 < list.length) ? (list[i + 1].size ?? 0) : 0;
        const alsoNext: boolean = curSize > 0 && curSize <= DashMediaServer.LARGE_SEG_BYTES && nextSize > 0;
        if (alsoNext) {
          this.prefetchSegment(isVideo, i + 1);
        }
        console.info(`${TAG} 按时间预取: ${timeMs}ms -> seg[${i}]${(isVideo ? '(video)' : '(audio)')} ${curSize}B${alsoNext ? ' + 下一段' : '（大段，跳过下一段）'}`);
        return;
      }
    }
  }

  private handleConnection(conn: socket.TCPSocketConnection): void {
    const client = new Client(conn);
    this.clients.push(client);

    conn.on('message', (info: socket.SocketMessageInfo) => {
      client.append(info.message);
      this.tryParseAndRespond(client);
    });
    conn.on('close', () => {
      this.removeClient(client);
    });
    conn.on('error', () => {
      this.removeClient(client);
    });
  }

  private removeClient(client: Client): void {
    const idx = this.clients.indexOf(client);
    if (idx >= 0) {
      this.clients.splice(idx, 1);
    }
  }

  /**
   * 从缓冲区尝试解析 HTTP 请求头（\r\n\r\n 为界）。
   * 同一连接支持连续多请求（keep-alive）：解析并消费一个请求后，
   * 若缓冲区仍有数据则继续处理（由 route 完成后重新调用）。
   */
  private tryParseAndRespond(client: Client): void {
    if (client.busy) {
      return;
    }
    const buf = client.buffer;
    // 找 \r\n\r\n
    let headerEnd = -1;
    for (let i = 0; i + 3 < buf.length; i++) {
      if (buf[i] === 0x0d && buf[i + 1] === 0x0a && buf[i + 2] === 0x0d && buf[i + 3] === 0x0a) {
        headerEnd = i + 3;
        break;
      }
    }
    if (headerEnd < 0) {
      // 头未完整，继续等（但限最大长度防滥用）
      if (buf.length > 65536) {
        this.sendResponse(client, 400, 'text/plain', strToArrayBuffer('Bad Request: header too large'), -1, -1, -1);
      }
      return;
    }
    const headerText = bytesToString(buf, 0, headerEnd);
    console.info(`${TAG} request: ${headerText.split('\r\n')[0]}`);
    // 解析请求行与 Range
    const req = parseHttpRequest(headerText);
    if (!req) {
      this.sendResponse(client, 400, 'text/plain', strToArrayBuffer('Bad Request'), -1, -1, -1);
      return;
    }
    client.reqId = req.path;
    // ⭐ 消费已解析的请求头，之后同一连接可继续收新请求
    client.consume(headerEnd + 1);
    client.busy = true;
    this.route(client, req).then(() => {
      client.busy = false;
      // 若缓冲区还有数据（同一请求管线下的后续请求），继续解析
      if (client.buffer.length > 0) {
        this.tryParseAndRespond(client);
      }
    });
  }

  /** 路由请求 */
  private async route(client: Client, req: HttpRequestInfo): Promise<void> {
    const cfg = this.config;
    if (!cfg) {
      this.sendResponse(client, 503, 'text/plain', strToArrayBuffer('no config'), -1, -1, -1);
      return;
    }

    try {
      // ⭐ MPD
      if (req.path === '/manifest.mpd' || req.path === '/') {
        this.sendResponse(client, 200, 'application/dash+xml', strToArrayBuffer(cfg.mpdXml), req.rangeStart, req.rangeEnd, -1);
        return;
      }

      // ⭐ init 段：video_init.m4s / audio_init.m4s（与 MPD initialization 一致）
      if (req.path === '/video_init.m4s' || req.path === '/audio_init.m4s') {
        const isVideo = req.path === '/video_init.m4s';
        const size = isVideo ? cfg.videoInitSize : cfg.audioInitSize;
        if (size <= 0) {
          this.sendResponse(client, 500, 'text/plain', strToArrayBuffer('init size unknown'), -1, -1, -1);
          return;
        }
        const url = isVideo ? cfg.videoUrl : cfg.audioUrl;
        // ⭐ 按 AVPlayer Range 精确切片；无 Range 则整段
        const start = req.rangeStart >= 0 ? req.rangeStart : 0;
        const end = req.rangeEnd >= 0 ? req.rangeEnd : size - 1;
        const clampedEnd = Math.min(end, size - 1);
        // ⭐ 探测缓冲命中：探测窗口完整覆盖 initRange，直接切片零回源（首帧关键路径）
        const headBuf = isVideo ? cfg.videoInitBuffer : cfg.audioInitBuffer;
        if (headBuf && headBuf.byteLength > 0 && start >= 0 && clampedEnd < headBuf.byteLength) {
          const slice = headBuf.slice(start, clampedEnd + 1);
          this.sendResponse(client, 200, 'video/mp4', slice, req.rangeStart, req.rangeEnd, size);
          return;
        }
        const data = await this.fetchCached(url, start, clampedEnd, cfg);
        if (data) {
          this.sendResponse(client, 200, 'video/mp4', data, req.rangeStart, req.rangeEnd, size);
        } else {
          this.sendResponse(client, 502, 'text/plain', strToArrayBuffer('fetch init failed'), -1, -1, -1);
        }
        return;
      }

      // ⭐ 媒体段：video_seg_N.m4s / audio_seg_N.m4s（与 MPD media 模板一致，startNumber=1）
      const segMatch = /^\/(video|audio)_seg_(\d+)\.m4s$/.exec(req.path);
      if (segMatch) {
        const isVideo = segMatch[1] === 'video';
        const num = parseInt(segMatch[2], 10);
        const idx = num - 1;
        const list = isVideo ? cfg.videoSegments : cfg.audioSegments;
        if (idx < 0 || list.length === 0) {
          this.sendResponse(client, 404, 'text/plain', strToArrayBuffer('segment not found'), -1, -1, -1);
          return;
        }
        // ⭐ 越界兜底（2026-09-19）：这里就是「最后几秒画面静止 / 结尾报错」的直接现场。
        //    ⚠️ **不能回 404** —— 实测 AVPlayer 收到 404 会抛 5411007 IO Resource Not Found
        //    并进入 error 态（后续 seek/播放全部失败），比「最后一段数据重复」严重得多。
        //    ⇒ 回落到最后一段返回（重复尾部数据）：播放能正常走到片尾，不会中途崩掉。
        //    根治在 DashMpdBuilder.safeSegmentTemplateTicks()（让播放器根本不会请求越界段），这里只是安全网。
        const servedIdx = idx < list.length ? idx : list.length - 1;
        if (servedIdx !== idx) {
          console.warn(`${TAG} seg[${num}] 越界(${isVideo ? 'video' : 'audio'}: idx=${idx}, list=${list.length}) → 回落到最后一段 seg[${servedIdx + 1}]`);
        }
        const entry = list[servedIdx];
        const url = isVideo ? cfg.videoUrl : cfg.audioUrl;
        const fileSize = isVideo ? cfg.videoFileSize : cfg.audioFileSize;
        // ⭐ 用 sidx 真实 fileOffset 映射（seek/乱序请求也准确）。
        //    此前游标顺序分配只在顺序播放时正确，seek 后 AVPlayer 按任意 seg_N 请求
        //    会错乱映射（实测拖动进度条后音画全无）。
        //    若该段 fileOffset 超出文件（sidx 尾条失真），回退游标模式。
        const rangeStart = req.rangeStart >= 0 ? req.rangeStart : 0;
        const hasRangeEnd = req.rangeEnd >= 0;
        let realStart = entry.fileOffset + rangeStart;
        let realEnd = hasRangeEnd ? entry.fileOffset + req.rangeEnd : -1;
        // 无 Range：段大小优先用 entry.size，再兜底 4MB；并 clamp 到文件尾
        if (realEnd < 0) {
          let segLen = (entry.size > 0 ? entry.size : DashMediaServer.MAX_SEG);
          // ⭐ 防御：个别文件 sidx 条目解析出异常大值(>64MB)时按 4MB 兜底，
          //    避免对 CDN 发起千次分块拉取把回源拖死
          if (segLen > DashMediaServer.MAX_SEG * 16) {
            console.warn(`${TAG} seg[${num}] size 异常(${segLen})，按 ${DashMediaServer.MAX_SEG} 兜底`);
            segLen = DashMediaServer.MAX_SEG;
          }
          realEnd = entry.fileOffset + segLen - 1;
        }
        // ⭐ clamp 到文件末尾：CDN 对越界 Range 回 416
        if (fileSize > 0 && realEnd >= fileSize) {
          // ⚠️ 被夹紧意味着 sidx 尾条(fileOffset/size)与实际文件大小不一致：
          //    该段只会拿到预期的一部分字节 ⇒ 解码器拿不到完整尾段（表现为结尾画面异常/静止）。
          console.warn(`${TAG} seg[${num}](${isVideo ? 'video' : 'audio'}) Range 被文件尾夹紧: 期望到 ${realEnd} 实际到 ${fileSize - 1} (fileSize=${fileSize}, sidx offset=${entry.fileOffset} size=${entry.size})`);
          realEnd = fileSize - 1;
        }
        const fetchLen = realEnd - realStart + 1;
        if (fetchLen <= 0) {
          this.sendResponse(client, 400, 'text/plain', strToArrayBuffer('bad range'), -1, -1, -1);
          return;
        }
        console.info(`${TAG} seg[${num}] fetch bytes=${realStart}-${realEnd} len=${fetchLen} (sidx offset=${entry.fileOffset} size=${entry.size})`);
        const data = await this.fetchCached(url, realStart, realEnd, cfg);
        if (data) {
          this.sendResponse(client, 200, 'video/mp4', data, req.rangeStart, req.rangeEnd, fileSize);
        } else {
          this.sendResponse(client, 502, 'text/plain', strToArrayBuffer('fetch seg failed'), -1, -1, -1);
        }
        return;
      }

      this.sendResponse(client, 404, 'text/plain', strToArrayBuffer('Not Found: ' + req.path), -1, -1, -1);
    } catch (e) {
      console.error(`${TAG} route error: ${(e as BusinessError).message}`);
      this.sendResponse(client, 500, 'text/plain', strToArrayBuffer('internal error'), -1, -1, -1);
    }
  }

  /** 从 B 站 m4s 拉指定字节范围（带防盗链头） */
  private async fetchRange(
    url: string,
    offset: number,
    end: number,
    cfg: DashServerConfig
  ): Promise<ArrayBuffer | null> {
    // ⭐ 分块回源：单次 http 响应有大小上限(CURLcode 23)，大段(如 25MB 的 seg_2)按 2MB/次拆多块拼装。
    //    ⚠️ 2MB 上限不能去掉（去掉就踩 CURLcode 23），但**不要再串行 await** ——
    //    实测每次回源的 TTFB 有 100~214ms，串行会把这段延迟按块数累加：
    //    一个 3MB 分段串行 = 2 × (150ms 延迟 + 200ms 传输) ≈ 700ms；续播 seek 要连拉 4 段，
    //    整段等待 2.8s（实测 3.83s 首帧里占 2.8s，见 hilog：seg 6 3,089,606B
    //    = 2,097,152 + 992,454 两次请求）。并发后同样两块只付一次 TTFB 的墙上时间。
    const CHUNK = 2 * 1024 * 1024;
    // 并发上限取 4：再高对 CDN 不友好，且每块都要驻留内存 ——
    // 不过原实现本来就要求所有块同时在内存里拼装，所以并发并不比原来更费内存。
    const MAX_PARALLEL = 4;
    if (offset < 0 || end < offset) {
      return null;
    }
    const total = end - offset + 1;
    if (total <= 0) {
      return null;
    }
    if (total <= CHUNK) {
      return this.fetchSingleRange(url, offset, end, cfg);
    }
    // 先切好所有子区间：下标顺序 == 拼装顺序（并发完成顺序不可依赖）
    const starts: number[] = [];
    const ends: number[] = [];
    let cur = offset;
    while (cur <= end) {
      const chunkEnd = Math.min(cur + CHUNK - 1, end);
      starts.push(cur);
      ends.push(chunkEnd);
      cur = chunkEnd + 1;
    }
    try {
      const parts: Array<Uint8Array> = [];
      for (let i = 0; i < starts.length; i++) {
        parts.push(new Uint8Array(0));
      }
      let next = 0;
      let failed = false;
      // 固定 MAX_PARALLEL 个 worker 从队列取下一块（比一次性并发全部更可控）
      const worker = async (): Promise<void> => {
        while (!failed) {
          const i = next;
          next += 1;
          if (i >= starts.length) {
            return;
          }
          const part = await this.fetchSingleRange(url, starts[i], ends[i], cfg);
          if (!part) {
            failed = true;
            return;
          }
          parts[i] = new Uint8Array(part);
        }
      };
      const workers: Array<Promise<void>> = [];
      const workerCount = Math.min(MAX_PARALLEL, starts.length);
      for (let i = 0; i < workerCount; i++) {
        workers.push(worker());
      }
      await Promise.all(workers);
      if (failed) {
        return null;
      }
      // 拼装
      let len = 0;
      for (let i = 0; i < parts.length; i++) {
        len += parts[i].length;
      }
      const merged = new Uint8Array(len);
      let pos = 0;
      for (let i = 0; i < parts.length; i++) {
        merged.set(parts[i], pos);
        pos += parts[i].length;
      }
      return merged.buffer;
    } catch (e) {
      console.error(`${TAG} chunked fetchRange error: ${(e as BusinessError).message}`);
      return null;
    }
  }

  /** 单次 http Range 拉取 */
  private async fetchSingleRange(
    url: string,
    offset: number,
    end: number,
    cfg: DashServerConfig
  ): Promise<ArrayBuffer | null> {
    try {
      const req = http.createHttp();
      const headers: Record<string, string> = {
        'User-Agent': cfg.userAgent,
        'Referer': cfg.referer,
        'Origin': 'https://www.bilibili.com',
        'Range': `bytes=${offset}-${end}`
      };
      if (cfg.cookie) {
        headers['Cookie'] = cfg.cookie;
      }
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 15000
      });
      req.destroy();
      if (resp.responseCode === 200 || resp.responseCode === 206) {
        return resp.result as ArrayBuffer;
      }
      console.error(`${TAG} fetchHTTP ${resp.responseCode}`);
      return null;
    } catch (e) {
      console.error(`${TAG} fetchSingleRange error: ${(e as BusinessError).message}`);
      return null;
    }
  }

  /**
   * 发送 HTTP 响应（大响应分块发送）。
   * ⭐ body 已是 route 按 Range 精确拉取的结果，不再二次切片；
   *    仅当带 Range 且 body 未按 Range 处理时（无 Range 请求）返回全部。
   */
  private async sendResponse(
    client: Client,
    code: number,
    contentType: string,
    body: ArrayBuffer,
    rangeStart: number,
    rangeEnd: number,
    totalSize: number
  ): Promise<void> {
    let reason = 'OK';
    if (code === 200) {
      reason = 'OK';
    } else if (code === 400) {
      reason = 'Bad Request';
    } else if (code === 404) {
      reason = 'Not Found';
    } else if (code === 416) {
      reason = 'Range Not Satisfiable';
    } else if (code === 500) {
      reason = 'Internal Server Error';
    } else if (code === 502) {
      reason = 'Bad Gateway';
    } else if (code === 503) {
      reason = 'Service Unavailable';
    }

    const bodyLen = body.byteLength;
    let sendBody = body;
    let respCode = code;
    let contentRange = '';
    // ⭐ 若请求带 Range 且 totalSize 已知，标记为 206 + Content-Range（body 已是精确切片）
    if (rangeStart >= 0 && bodyLen > 0) {
      respCode = 206;
      const respEnd = rangeEnd >= 0 ? rangeEnd : rangeStart + bodyLen - 1;
      contentRange = `Content-Range: bytes ${rangeStart}-${respEnd}/${totalSize > 0 ? totalSize : bodyLen}\r\n`;
    }

    const head =
      `HTTP/1.1 ${respCode} ${reason}\r\n` +
      `Content-Type: ${contentType}\r\n` +
      `Content-Length: ${sendBody.byteLength}\r\n` +
      `Accept-Ranges: bytes\r\n` +
      `${contentRange}` +
      `Connection: keep-alive\r\n` +
      `\r\n`;
    const headBytes = strToArrayBuffer(head);

    try {
      // 先发头，再发体（TCP 顺序保证）；大响应按 4MB 分块避免单次 send 过载
      const headOpt: socket.TCPSendOptions = { data: headBytes };
      await client.conn.send(headOpt);
      const SEND_CHUNK = 4 * 1024 * 1024;
      let pos = 0;
      const sendLen = sendBody.byteLength;
      while (pos < sendLen) {
        const endPos = Math.min(pos + SEND_CHUNK, sendLen);
        const chunk = sendBody.slice(pos, endPos);
        const bodyOpt: socket.TCPSendOptions = { data: chunk };
        await client.conn.send(bodyOpt);
        pos = endPos;
      }
    } catch (e) {
      console.error(`${TAG} send error: ${(e as BusinessError).message}`);
      try {
        await client.conn.close();
      } catch (_e) {
      }
    }
  }
}

/** 解析后的 HTTP 请求信息 */
interface HttpRequestInfo {
  method: string;
  path: string;
  rangeStart: number;
  rangeEnd: number;
}

/** 解析 HTTP 请求头文本（请求行 + Range 头） */
function parseHttpRequest(headerText: string): HttpRequestInfo | null {
  const lines = headerText.split('\r\n');
  if (lines.length < 1) {
    return null;
  }
  const parts = lines[0].split(' ');
  if (parts.length < 2) {
    return null;
  }
  const method = parts[0];
  const target = parts[1];
  // 去 query
  const qIdx = target.indexOf('?');
  const path = qIdx >= 0 ? target.substring(0, qIdx) : target;

  let rangeStart = -1;
  let rangeEnd = -1;
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i];
    const cIdx = line.indexOf(':');
    if (cIdx < 0) {
      continue;
    }
    const name = line.substring(0, cIdx).toLowerCase();
    const value = line.substring(cIdx + 1).trim();
    if (name === 'range') {
      const m = /bytes=(\d+)-(\d*)/.exec(value);
      if (m) {
        rangeStart = parseInt(m[1], 10);
        if (m[2] && m[2].length > 0) {
          rangeEnd = parseInt(m[2], 10);
        }
      } else {
        const m2 = /bytes=-(\d+)/.exec(value);
        if (m2) {
          rangeStart = 0;
          rangeEnd = -1; // 未知，按全量处理
        }
      }
    }
  }

  const info: HttpRequestInfo = {
    method: method,
    path: path,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd
  };
  return info;
}

function strToArrayBuffer(str: string): ArrayBuffer {
  const buf = new ArrayBuffer(str.length);
  const view = new Uint8Array(buf);
  for (let i = 0; i < str.length; i++) {
    view[i] = str.charCodeAt(i);
  }
  return buf;
}

function bytesToString(view: Uint8Array, start: number, end: number): string {
  let s = '';
  for (let i = start; i < end; i++) {
    s += String.fromCharCode(view[i]);
  }
  return s;
}
