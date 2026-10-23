/**
 * DashPlayerBridge —— DASH 转播站播放链路组装器
 *
 * 把「探测 → MPD 生成 → 起本地转播站 → 输出 playerUrl」封装为可复用类。
 * 供 VideoPlayerPage（DASH 双流场景）替代「双 AVPlayer」链路：
 *    AVPlayer 直连 http://127.0.0.1:PORT/manifest.mpd（单播放器，音画引擎内同步）。
 *
 * 生命周期：
 *   - buildAndStart()  组装并启动（页面初始化/切画质时调用）
 *   - stopIfRunning()  停止服务（页面退出/切换画质时调用）
 *   - 页面最小化转移 PlayerService 时，服务一并移交（服务器不停止，
 *     浮窗继续消费；恢复页面时 takeDashServer 接回）。
 */
import { DashFullInfo, DashVideoItem, DashAudioItem } from '../api/BilibiliApi';
import { probeM4sInitSegment, probeFastestInitSegment, InitSegmentInfo, SegmentEntry, ProbeWinner } from './DashProbe';
import { buildSegmentTemplateMpd, DashMpdParams, DashVideoStream, DashAudioStream,
         askSegmentCount, safeSegmentTemplateTicks } from './DashMpdBuilder';
import { DashMediaServer, DashServerConfig, SegmentRange } from './DashMediaServer';
import { DashServerHandle } from './PlayerService';

const TAG = '[DashBridge]';

export class DashPlayerBridge implements DashServerHandle {
  /**
   * ⭐ CDN 竞速结果缓存（进程级）：同一视频的「预热实例」与「正式切档实例」必须选到
   *    同一个 CDN，否则回源 URL 不同 ⇒ DashMediaServer 的静态缓存 key 全部 miss，
   *    预热完全白做（实测两次竞速分别选中 mountaintoys 与 mcdn）。
   *    key = 候选 URL 前缀（含 aid/cid，能区分视频）。
   */
  private static raceCache: Map<string, ProbeWinner> = new Map();
  private server: DashMediaServer | null = null;
  private active: boolean = false;

  constructor() {}

  /** 竞速缓存 key：候选 URL 前缀（含 aid/cid）——签名 query 每次取流都变，不能用完整 URL */
  private static raceKey(urls: Array<string>): string {
    return urls.length > 0 ? urls[0].substring(0, 120) : '';
  }

  isActive(): boolean {
    return this.active;
  }

  getServer(): DashMediaServer | null {
    return this.server;
  }

  /**
   * ⭐ 停服（DashServerHandle 契约；PlayerService.release 与页面释放调用）。
   */
  async stop(): Promise<void> {
    await this.stopIfRunning();
  }

  /**
   * 组装并启动转播站。
   * @param startTimeMs 起播时间（毫秒）。> 0 时额外预取覆盖该时刻的分段 ——
   *        续播 seek / 切画质回到原位置都需要冷拉那段，实测是首帧前最大的一块等待。
   * @returns playerUrl（http://127.0.0.1:PORT/manifest.mpd）；失败返回 null
   */
  async buildAndStart(dash: DashFullInfo, referer: string, ua: string, cookie: string,
                      startTimeMs: number = 0): Promise<string | null> {
    // ⭐ 0. 校验时长（MPD duration; 若为 0 说明取流层丢了 timelength）
    if (!dash.timelength || dash.timelength <= 0) {
      console.error(`${TAG} dash.timelength=0，MPD 将生成 0 时长清单无法拉流`);
      return null;
    }
    // ⭐ 1. 挑流：视频非 AV1 优先 + 按目标画质(dash.quality)选择；音频 id 降序
    const videoItem: DashVideoItem | null = pickVideoItem(dash.videoStreams, dash.quality);
    const audioItem: DashAudioItem | null = pickAudioItem(dash.audioStreams);
    if (!videoItem || !audioItem) {
      console.error(`${TAG} 缺少流: video=${!!videoItem} audio=${!!audioItem}`);
      return null;
    }
    console.info(`${TAG} 视频流(目标qn=${dash.quality}) 选中qn=${videoItem.id} codecid=${videoItem.codecid} ${videoItem.width || '?'}x${videoItem.height || '?'} bps=${videoItem.bandwidth || 0} dur=${dash.timelength}ms`);

    // ⭐ 2. 双轨探测并行（各自独立冷连接，串行时两段 RTT 叠加 ~300ms）；
    //    旧转播站关闭与探测并发（切画质场景免串行等待）
    //
    // ⭐ CDN 竞速：B 站对同一视频会下发多个 CDN 候选（baseUrl + backupUrl[]），
    //    各节点速度差 3~4 倍。旧实现只用 baseUrl ⇒ 碰上慢节点时 4K 首段(6.5MB)
    //    与 seek 段(8~10MB/段) 会把起播拖到 10 秒级。这里并行探测所有候选，
    //    取最快者的 URL 作为后续【全部回源】的地址。
    const videoUrls: Array<string> = [videoItem.baseUrl];
    if (videoItem.backupUrl) {
      for (let i = 0; i < videoItem.backupUrl.length; i++) {
        videoUrls.push(videoItem.backupUrl[i]);
      }
    }
    const audioUrls: Array<string> = [audioItem.baseUrl];
    if (audioItem.backupUrl) {
      for (let i = 0; i < audioItem.backupUrl.length; i++) {
        audioUrls.push(audioItem.backupUrl[i]);
      }
    }
    const stopOld = this.stopIfRunning();
    const vKey: string = DashPlayerBridge.raceKey(videoUrls);
    const aKey: string = DashPlayerBridge.raceKey(audioUrls);
    const vCached: ProbeWinner | undefined = DashPlayerBridge.raceCache.get(vKey);
    const aCached: ProbeWinner | undefined = DashPlayerBridge.raceCache.get(aKey);
    const winners = await Promise.all([
      vCached !== undefined ? Promise.resolve(vCached) : probeFastestInitSegment(videoUrls, referer, ua, cookie),
      aCached !== undefined ? Promise.resolve(aCached) : probeFastestInitSegment(audioUrls, referer, ua, cookie),
    ]);
    if (vCached === undefined) {
      DashPlayerBridge.raceCache.set(vKey, winners[0]);
    }
    if (aCached === undefined) {
      DashPlayerBridge.raceCache.set(aKey, winners[1]);
    }
    const vWin: ProbeWinner = winners[0];
    const aWin: ProbeWinner = winners[1];
    const vInfo: InitSegmentInfo | null = vWin.info;
    const aInfo: InitSegmentInfo | null = aWin.info;
    // 胜出 URL：回源、MPD 的 baseUrl 都以它为准（否则 MPD 声明与实际拉流不一致）
    const videoUrl: string = vWin.url || videoItem.baseUrl;
    const audioUrl: string = aWin.url || audioItem.baseUrl;
    await stopOld;
    if (!vInfo) {
      console.error(`${TAG} 视频轨探测失败`);
      return null;
    }
    if (!aInfo) {
      console.error(`${TAG} 音频轨探测失败`);
      return null;
    }
    console.info(`${TAG} video timescale=${vInfo.timescale} segs=${vInfo.segments.length} (CDN ${vWin.costMs}ms) | audio timescale=${aInfo.timescale} segs=${aInfo.segments.length} (CDN ${aWin.costMs}ms)`);

    // ⭐ 段时长收敛（根治「最后几秒画面静止 / 结尾报错」）
    //    MPD 用 SegmentTemplate + **固定** duration = 首段时长，而清单时长 mediaPresentationDuration
    //    取接口给的 dash.timelength。播放器据此推算要拉多少段：请求段数 = ceil(清单时长 / 首段时长)。
    //    **当 清单时长 > sidx段数 × 首段时长 时就会多算出一段**（实测 BV1hb411c7RQ：75007ms vs
    //    15×5000ms=75000ms ⇒ 算出 16 段），结尾去请求不存在的 video_seg_16.m4s，转播站回 404
    //    ⇒ 该轨拿不到尾部数据（画面停在最后一帧），AVPlayer 还会抛 5411007 IO Resource Not Found
    //    直接进入 error 态；而另一轨与进度条（timeUpdate）继续走。
    //    修法见 DashMpdBuilder.safeSegmentTemplateTicks()：把 @duration 抬到「刚好不会多算一段」的下限。
    const trackSumMs = (segs: Array<SegmentEntry>, ts: number): number => {
      let acc = 0;
      for (let i = 0; i < segs.length; i++) {
        const d: number = segs[i].duration ?? 0;
        acc += d > 0 ? d : ts * 5;
      }
      return ts > 0 ? Math.round(acc / ts * 1000) : 0;
    };
    const vTrackMs: number = trackSumMs(vInfo.segments, vInfo.timescale);
    const aTrackMs: number = trackSumMs(aInfo.segments, aInfo.timescale);
    const vFirstMs: number = vInfo.segments.length > 0 && vInfo.timescale > 0
      ? Math.round((vInfo.segments[0].duration ?? 0) / vInfo.timescale * 1000) : 0;
    const aFirstMs: number = aInfo.segments.length > 0 && aInfo.timescale > 0
      ? Math.round((aInfo.segments[0].duration ?? 0) / aInfo.timescale * 1000) : 0;
    // 收敛后的 SegmentTemplate @duration（单位 = 该轨 timescale）
    const vDurTicks: number = safeSegmentTemplateTicks(dash.timelength, vInfo.segments.length,
      vInfo.segments.length > 0 ? (vInfo.segments[0].duration ?? 0) : 0, vInfo.timescale);
    const aDurTicks: number = safeSegmentTemplateTicks(dash.timelength, aInfo.segments.length,
      aInfo.segments.length > 0 ? (aInfo.segments[0].duration ?? 0) : 0, aInfo.timescale);
    const vDurMs: number = vInfo.timescale > 0 ? Math.round(vDurTicks / vInfo.timescale * 1000) : 0;
    const aDurMs: number = aInfo.timescale > 0 ? Math.round(aDurTicks / aInfo.timescale * 1000) : 0;
    const vRawAsk: number = vFirstMs > 0 ? Math.ceil(dash.timelength / vFirstMs) : 0;
    const aRawAsk: number = aFirstMs > 0 ? Math.ceil(dash.timelength / aFirstMs) : 0;
    const vAsk: number = askSegmentCount(dash.timelength, vInfo.timescale, vDurTicks);
    const aAsk: number = askSegmentCount(dash.timelength, aInfo.timescale, aDurTicks);
    console.info(`${TAG} 段数核对: MPD时长=${dash.timelength}ms 实际视频轨=${vTrackMs}ms/音频轨=${aTrackMs}ms`);
    console.info(`${TAG} 段数核对: video list=${vInfo.segments.length} 首段=${vFirstMs}ms ⇒ 按首段播放器将请求=${vRawAsk} 段 | audio list=${aInfo.segments.length} 首段=${aFirstMs}ms ⇒ 将请求=${aRawAsk} 段`);
    if (vRawAsk > vInfo.segments.length || aRawAsk > aInfo.segments.length) {
      // ⚠️ 别删：这是「结尾静止/报错」的唯一显性线索（404 分支本身不再致命，见 DashMediaServer）
      console.warn(`${TAG} ⚠️ 按首段时长会越界，已收敛 @duration: video ${vFirstMs}→${vDurMs}ms ⇒ ${vAsk} 段 | audio ${aFirstMs}→${aDurMs}ms ⇒ ${aAsk} 段`);
    } else {
      console.info(`${TAG} 段数核对 OK: video ⇒ ${vAsk} 段(sidx=${vInfo.segments.length}) | audio ⇒ ${aAsk} 段(sidx=${aInfo.segments.length})`);
    }

    // ⭐ 3. 组装 MPD
    const vStream: DashVideoStream = {
      id: videoItem.id,
      baseUrl: videoUrl,
      backupUrl: videoItem.backupUrl && videoItem.backupUrl.length > 0 ? videoItem.backupUrl[0] : videoUrl,
      codecid: videoItem.codecid,
      bandwidth: videoItem.bandwidth || 0,
      width: videoItem.width || 0,
      height: videoItem.height || 0,
      frameRate: videoItem.frameRate || '0',
      sar: videoItem.sar || '1:1',
      startWithSap: videoItem.startWithSap || 0,
      contentLength: videoItem.contentLength || 0
    };
    const aStream: DashAudioStream = {
      id: audioItem.id,
      baseUrl: audioUrl,
      backupUrl: audioItem.backupUrl && audioItem.backupUrl.length > 0 ? audioItem.backupUrl[0] : audioUrl,
      bandwidth: audioItem.bandwidth || 0,
      contentLength: audioItem.contentLength || 0
    };

    const mpdParams: DashMpdParams = {
      durationMs: dash.timelength,
      videoStreams: [vStream],
      audioStreams: [aStream],
      videoInitRange: vInfo.initRange,
      videoIndexRange: vInfo.indexRange,
      audioInitRange: aInfo.initRange,
      audioIndexRange: aInfo.indexRange,
      videoTimescale: vInfo.timescale,
      audioTimescale: aInfo.timescale,
      // ⭐ 不再是裸的「首段时长」：收敛后可保证播放器请求的段数 ≤ sidx 段数（见 DashMpdBuilder.safeSegmentTemplateTicks）
      videoSegmentDuration: vDurTicks,
      audioSegmentDuration: aDurTicks
    };
    const mpdXml = buildSegmentTemplateMpd(mpdParams);

    // ⭐ 4. 起转播站
    // ⭐ 把 sidx 的逐段 duration 一起带过去：只有它能让转播站把「第 N 秒」换算成分段下标
    //    （分段时长不均匀，用 总时长/段数 均分会定位到错的那一段）
    const segRanges = (segs: Array<SegmentEntry>): Array<SegmentRange> => {
      const list: Array<SegmentRange> = [];
      for (let i = 0; i < segs.length; i++) {
        const se = segs[i];
        const r: SegmentRange = { fileOffset: se.fileOffset, size: se.size, duration: se.duration };
        list.push(r);
      }
      return list;
    };
    const initEndIdx = vInfo.initRange.indexOf('-');
    const videoInitSize = initEndIdx >= 0 ? parseInt(vInfo.initRange.substring(initEndIdx + 1), 10) + 1 : 0;
    const aInitEndIdx = aInfo.initRange.indexOf('-');
    const audioInitSize = aInitEndIdx >= 0 ? parseInt(aInfo.initRange.substring(aInitEndIdx + 1), 10) + 1 : 0;

    const serverConfig: DashServerConfig = {
      mpdXml: mpdXml,
      videoUrl: videoUrl,
      audioUrl: audioUrl,
      referer: referer,
      userAgent: ua,
      cookie: cookie,
      videoSegments: segRanges(vInfo.segments),
      audioSegments: segRanges(aInfo.segments),
      videoInitSize: videoInitSize,
      audioInitSize: audioInitSize,
      videoFileSize: vInfo.contentLength,
      audioFileSize: aInfo.contentLength,
      // ⭐ 探测已下载的头部（完整覆盖 initRange），init 请求命中时零回源
      videoInitBuffer: vInfo.headBuffer,
      audioInitBuffer: aInfo.headBuffer,
      // ⭐ 按时间预取要用它把「秒」换算成分段下标
      videoTimescale: vInfo.timescale,
      audioTimescale: aInfo.timescale
    };

    // 旧服务已在探测期间停止
    const server = new DashMediaServer();
    server.setConfig(serverConfig);
    // ⭐ 首分片预取：sidx 表已就绪，先把首段拉入转播站缓存（与 AVPlayer 创建/prepare 并行）
    server.prefetchSegment(true, 0);
    server.prefetchSegment(false, 0);
    // ⭐ 起播位预取：续播/切画质会 seek 到 startTimeMs，覆盖该时刻的分段是首帧前的最大等待，
    //    在这里先拉掉（与 AVPlayer 创建/prepare 并行），seek 发起时命中缓存。
    //    ⚠️ 起点为 0 时不必调（首分片预取已覆盖）。
    if (startTimeMs > 0) {
      server.prefetchSegmentAtTime(true, startTimeMs);
      server.prefetchSegmentAtTime(false, startTimeMs);
    }
    await server.start();
    this.server = server;
    this.active = true;
    const port = server.getPort();
    console.info(`${TAG} 转播站已启动 127.0.0.1:${port}，MPD=${mpdXml.length}B init=${videoInitSize}/${audioInitSize}`);
    return `http://127.0.0.1:${port}/manifest.mpd`;
  }

  /** 停止服务（页面释放/切画质时调用） */
  async stopIfRunning(): Promise<void> {
    if (this.server) {
      try {
        await this.server.stop();
      } catch (e) {
        console.error(`${TAG} stop error: ${e}`);
      }
      this.server = null;
    }
    this.active = false;
  }
}

/**
 * 挑视频流：非 AV1 优先（设备解码限制），再**按目标画质**选。
 *
 * ⚠️ 不能无条件取 id 最高：B 站 playurl 的 `dash.video` 总是返回该视频全套轨，
 *    旧实现取最高档 ⇒ 请求 qn=80/112 时也把 4K 流写进 MPD，表现为
 *    「切了分辨率但 `视频流 ... 3840x2160` / `videoSizeChange: 3840x2160` 一直不变」。
 * 规则：精确匹配 targetQn → 取 ≤ targetQn 的最高档 → 都比目标高时取最低档兜底。
 */
function pickVideoItem(list: Array<DashVideoItem>, targetQn: number = 0): DashVideoItem | null {
  if (!list || list.length === 0) {
    return null;
  }
  const nonAv1 = list.filter((v: DashVideoItem) => v.codecid !== 13);
  const usable = nonAv1.length > 0 ? nonAv1 : list;
  const sorted = usable.slice().sort((a: DashVideoItem, b: DashVideoItem) => b.id - a.id);
  if (targetQn > 0) {
    const exact = sorted.find((v: DashVideoItem) => v.id === targetQn);
    if (exact) {
      return exact;
    }
    const lower = sorted.find((v: DashVideoItem) => v.id <= targetQn);
    if (lower) {
      return lower;
    }
    return sorted[sorted.length - 1];
  }
  return sorted.length > 0 ? sorted[0] : null;
}

/** 挑音频流：按 id 降序（高音质优先） */
function pickAudioItem(list: Array<DashAudioItem>): DashAudioItem | null {
  if (!list || list.length === 0) {
    return null;
  }
  const sorted = list.slice().sort((a: DashAudioItem, b: DashAudioItem) => b.id - a.id);
  return sorted.length > 0 ? sorted[0] : null;
}
