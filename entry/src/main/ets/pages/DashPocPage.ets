/**
 * DASH PoC 验证页
 *
 * 目的：验证「方案② 拼 MPD + MediaSourceLoader 喂单 AVPlayer」能否播放 B 站 DASH 双流。
 * 链路：强制 DASH 取流(fnval=16) → 探测 m4s init/index Range → buildSegmentBaseMpd
 *      → DashMediaLoader 挂在 MediaSource 上 → 单 AVPlayer 播放（音画引擎内同步）
 *
 * 全部为独立验证代码，不影响现有双 AVPlayer 链路；验证后可整体删除本页。
 * 操作：输入 bvid（cid 可留空自动取首P）→ 点击「开始验证」→ 看日志。
 */
import { media } from '@kit.MediaKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppSign, BiliRequest } from '../utils/SignUtils';
import { logError } from '../utils/Logger';
import { DashMediaLoader, DashLoaderConfig, SegmentRange } from '../services/DashMediaLoader';
import { probeM4sInitSegment, InitSegmentInfo, SegmentEntry } from '../services/DashProbe';
import { buildSegmentTemplateMpd, DashMpdParams, DashVideoStream, DashAudioStream,
         safeSegmentTemplateTicks } from '../services/DashMpdBuilder';
import { DashMediaServer, DashServerConfig } from '../services/DashMediaServer';

const TAG = '[DashPoc]';

/** B 站 playurl dash.video 完整字段（web API 驼峰命名） */
interface RawDashVideo {
  id: number;
  baseUrl: string;
  backupUrl?: string[];
  codecid: number;
  bandwidth?: number;
  width?: number;
  height?: number;
  frameRate?: string;
  sar?: string;
  startWithSap?: number;
  contentLength?: number;
}

interface RawDashAudio {
  id: number;
  baseUrl: string;
  backupUrl?: string[];
  bandwidth?: number;
  contentLength?: number;
}

interface RawDash {
  video?: Array<RawDashVideo>;
  audio?: Array<RawDashAudio>;
  timelength?: number;
}

interface RawPlayUrlData {
  quality?: number;
  timelength?: number;
  dash?: RawDash;
}

interface RawPlayUrlResponse {
  code: number;
  message?: string;
  data?: RawPlayUrlData;
}

/** 详情接口响应（仅取 cid） */
interface RawVideoDetailData {
  cid?: number;
}

interface RawVideoDetailResp {
  code: number;
  data?: RawVideoDetailData;
}

/** 选流结果（简化返回包装） */
interface PickVideoResult {
  r: RawDashVideo | null;
}

interface PickAudioResult {
  r: RawDashAudio | null;
}

@Entry
@Component
struct DashPocPage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @State bvid: string = '';
  @State cidText: string = '';
  @State logs: string = '';
  @State statusText: string = '待验证';
  @State running: boolean = false;

  private xc: XComponentController = new XComponentController();
  private av: media.AVPlayer | null = null;
  private loader: DashMediaLoader | null = null;
  private server: DashMediaServer | null = null;
  private sId: string = '';
  private surfaceReady: boolean = false;
  /** ⭐ 播放进度轮询定时器 */
  private progressTimer: number = -1;

  private log(msg: string): void {
    const line = `[${new Date().toLocaleTimeString()}] ${msg}\n`;
    this.logs = this.logs + line;
    console.info(`${TAG} ${msg}`);
  }

  private setStatus(s: string): void {
    this.statusText = s;
    console.info(`${TAG} status: ${s}`);
  }

  aboutToDisappear(): void {
    this.releasePlayer();
    if (this.loader) {
      this.loader.destroy();
      this.loader = null;
    }
    if (this.server) {
      this.server.stop();
      this.server = null;
    }
  }

  private releasePlayer(): void {
    this.stopProgressProbe();
    if (this.av) {
      try {
        this.av.off('stateChange');
        this.av.release();
      } catch (e) {
        logError(`${TAG} release error: ${e}`);
      }
      this.av = null;
    }
  }

  /** 停止播放进度轮询 */
  private stopProgressProbe(): void {
    if (this.progressTimer >= 0) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  /** 从 XComponent surface 回调取 surfaceId */
  onXC = (): void => {
    const id = this.xc.getXComponentSurfaceId();
    if (!id) {
      return;
    }
    this.sId = id;
    this.surfaceReady = true;
    this.log(`surface 就绪: ${id}`);
    // 播放器可能在 surface 之前就 initialized 了，补一次绑定
    if (this.av && this.av.state === 'initialized') {
      this.bindSurfaceAndPrepare();
    }
  };

  private async bindSurfaceAndPrepare(): Promise<void> {
    if (!this.av) {
      return;
    }
    if (!this.sId) {
      this.log('surfaceId 未就绪，绑定延后（由 onXC 补）');
      return;
    }
    try {
      this.av.surfaceId = this.sId;
      if (this.av.state === 'initialized') {
        await this.av.prepare();
      }
    } catch (e) {
      this.log(`绑定/预备失败: ${e}`);
      this.setStatus('失败');
    }
  }

  private async runPoc(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    this.logs = '';
    this.setStatus('验证中…');
    this.releasePlayer();
    if (this.loader) {
      this.loader.destroy();
      this.loader = null;
    }

    const bvid = this.bvid.trim();
    if (!bvid) {
      this.log('请先输入 bvid');
      this.setStatus('待验证');
      this.running = false;
      return;
    }
    let cid = parseInt(this.cidText, 10) || 0;

    try {
      // ── 1. 取 cid ────────────────────────────────────────────────
      if (cid <= 0) {
        this.log(`bvid=${bvid} 未给 cid，从详情接口取首P…`);
        cid = await this.fetchFirstCid(bvid);
        if (cid <= 0) {
          this.log('取 cid 失败，中止');
          this.setStatus('失败');
          this.running = false;
          return;
        }
        this.log(`cid = ${cid}`);
      }

      // ── 2. 强制 DASH 取流（包含完整元数据）────────────────────────
      this.log('请求 playurl（fnval=16 强制 DASH）…');
      const playUrlData = await this.fetchDashPlayUrl(bvid, cid, 116);
      if (!playUrlData || !playUrlData.dash) {
        this.log('DASH 取流失败，中止');
        this.setStatus('失败');
        this.running = false;
        return;
      }
      const dashData = playUrlData.dash;
      const video = this.pickVideoStream(dashData.video || []);
      const audio = this.pickAudioStream(dashData.audio || []);
      if (!video.r || !audio.r) {
        this.log(`缺少流: video=${!!video.r}, audio=${!!audio.r}，中止`);
        this.setStatus('失败');
        this.running = false;
        return;
      }
      const timelength: number = playUrlData.timelength || dashData.timelength || 0;
      this.log(`视频: codecid=${video.r.codecid} ${video.r.width}x${video.r.height} bps=${video.r.bandwidth} frameRate=${video.r.frameRate} sar=${video.r.sar} total=${video.r.contentLength}`);
      this.log(`音频: id=${audio.r.id} bps=${audio.r.bandwidth} total=${audio.r.contentLength}`);
      this.log(`时长(timelength)=${timelength}ms，画质 qn=${playUrlData.quality}`);

      // ── 3. 探测两个 m4s 的 init/index Range ──────────────────────
      this.log('探测视频轨 init/index…');
      const vInfo: InitSegmentInfo | null = await probeM4sInitSegment(
        video.r.baseUrl, 'https://www.bilibili.com/', this.buildUA(), this.buildCookie());
      if (!vInfo) {
        this.log('视频轨探测失败，中止');
        this.setStatus('失败');
        this.running = false;
        return;
      }
      this.log(`视频 initRange=${vInfo.initRange} indexRange=${vInfo.indexRange} total=${vInfo.contentLength} timescale=${vInfo.timescale} segments=${vInfo.segments.length}`);

      this.log('探测音频轨 init/index…');
      const aInfo: InitSegmentInfo | null = await probeM4sInitSegment(
        audio.r.baseUrl, 'https://www.bilibili.com/', this.buildUA(), this.buildCookie());
      if (!aInfo) {
        this.log('音频轨探测失败，中止');
        this.setStatus('失败');
        this.running = false;
        return;
      }
      this.log(`音频 initRange=${aInfo.initRange} indexRange=${aInfo.indexRange} total=${aInfo.contentLength} timescale=${aInfo.timescale} segments=${aInfo.segments.length}`);

      // ── 4. 拼 MPD ───────────────────────────────────────────────
      const vStream: DashVideoStream = {
        id: video.r.id,
        baseUrl: video.r.baseUrl,
        backupUrl: (video.r.backupUrl && video.r.backupUrl.length > 0) ? video.r.backupUrl[0] : video.r.baseUrl,
        codecid: video.r.codecid,
        bandwidth: video.r.bandwidth || 0,
        width: video.r.width || 0,
        height: video.r.height || 0,
        frameRate: video.r.frameRate || '0',
        sar: video.r.sar || '1:1',
        startWithSap: video.r.startWithSap || 0,
        contentLength: video.r.contentLength || 0
      };
      const aStream: DashAudioStream = {
        id: audio.r.id,
        baseUrl: audio.r.baseUrl,
        backupUrl: (audio.r.backupUrl && audio.r.backupUrl.length > 0) ? audio.r.backupUrl[0] : audio.r.baseUrl,
        bandwidth: audio.r.bandwidth || 0,
        contentLength: audio.r.contentLength || 0
      };
      // ⭐ sidx 条目 → loader 用字节范围(需要含第一个子段之后的内容其实不需要 init 在表内)
      const videoSegs: Array<SegmentRange> = vInfo.segments.map((se: SegmentEntry): SegmentRange => {
        const r: SegmentRange = { fileOffset: se.fileOffset, size: se.size };
        return r;
      });
      const audioSegs: Array<SegmentRange> = aInfo.segments.map((se: SegmentEntry): SegmentRange => {
        const r: SegmentRange = { fileOffset: se.fileOffset, size: se.size };
        return r;
      });

      const mpdParams: DashMpdParams = {
        durationMs: timelength,
        videoStreams: [vStream],
        audioStreams: [aStream],
        videoInitRange: vInfo.initRange,
        videoIndexRange: vInfo.indexRange,
        audioInitRange: aInfo.initRange,
        audioIndexRange: aInfo.indexRange,
        videoTimescale: vInfo.timescale,
        audioTimescale: aInfo.timescale,
        // ⭐ 同样走收敛逻辑：PoC 页与正式链路共用一份，避免结尾「多算出一段」导致 404
        //    （见 DashMpdBuilder.safeSegmentTemplateTicks 的注释）
        videoSegmentDuration: safeSegmentTemplateTicks(timelength, vInfo.segments.length,
          vInfo.segments.length > 0 ? (vInfo.segments[0].duration ?? 0) : 0, vInfo.timescale),
        audioSegmentDuration: safeSegmentTemplateTicks(timelength, aInfo.segments.length,
          aInfo.segments.length > 0 ? (aInfo.segments[0].duration ?? 0) : 0, aInfo.timescale)
      };
      // ⭐ SegmentTemplate 虚拟分段（AVPlayer 26 实测只认分段形态）
      const mpdXml = buildSegmentTemplateMpd(mpdParams);
      this.log(`MPD(Template) 生成完成，长度=${mpdXml.length}，视频段时长=${mpdParams.videoSegmentDuration}/${vInfo.timescale} 音频段时长=${mpdParams.audioSegmentDuration}/${aInfo.timescale}`);

      // ── 5. 启动本地 HTTP 转播站 + 单 AVPlayer 直连 ────────────────
      const initEndIdx = vInfo.initRange.indexOf('-');
      const videoInitSize = initEndIdx >= 0 ? parseInt(vInfo.initRange.substring(initEndIdx + 1), 10) + 1 : 0;
      const aInitEndIdx = aInfo.initRange.indexOf('-');
      const audioInitSize = aInitEndIdx >= 0 ? parseInt(aInfo.initRange.substring(aInitEndIdx + 1), 10) + 1 : 0;

      // 停止旧服务
      if (this.server) {
        await this.server.stop();
        this.server = null;
      }

      const serverConfig: DashServerConfig = {
        mpdXml: mpdXml,
        videoUrl: video.r.baseUrl,
        audioUrl: audio.r.baseUrl,
        referer: 'https://www.bilibili.com/',
        userAgent: this.buildUA(),
        cookie: this.buildCookie(),
        videoSegments: videoSegs,
        audioSegments: audioSegs,
        videoInitSize: videoInitSize,
        audioInitSize: audioInitSize,
        videoFileSize: vInfo.contentLength,
        audioFileSize: aInfo.contentLength
      };
      this.server = new DashMediaServer();
      this.server.setConfig(serverConfig);
      await this.server.start();
      const port = this.server.getPort();
      this.log(`转播站已启动 127.0.0.1:${port}，MPD=${mpdXml.length}B init=${videoInitSize}/${audioInitSize} segs=${videoSegs.length}/${audioSegs.length}`);

      this.av = await media.createAVPlayer();
      this.av.on('stateChange', async (st: string) => {
        this.log(`AVPlayer state: ${st}`);
        switch (st) {
          case 'initialized':
            // ⭐ 若 XComponent surface 已就绪则立刻绑定；否则等 onXC 补
            if (this.sId) {
              await this.bindSurfaceAndPrepare();
            }
            break;
          case 'prepared':
            this.setStatus('播放中');
            await this.av?.play();
            // ⭐ 播放进度 probe：每秒打印 currentTime，直接观察画面推进/卡点
            this.progressTimer = setInterval(() => {
              const ct = this.av?.currentTime ?? -1;
              const dur = this.av?.duration ?? -1;
              this.log(`⏱ ct=${(ct / 1000).toFixed(1)}s dur=${(dur / 1000).toFixed(1)}s`);
            }, 1000);
            break;
          case 'paused':
            this.setStatus('已暂停');
            break;
          case 'completed':
            this.setStatus('播放完成');
            this.stopProgressProbe();
            break;
          case 'error':
            break;
        }
      });
      this.av.on('error', (err: BusinessError) => {
        this.log(`AVPlayer error: code=${err.code} ${err.message}`);
        this.setStatus('失败');
        this.stopProgressProbe();
      });
      this.av.on('videoSizeChange', (w: number, h: number) => {
        this.log(`videoSizeChange: ${w}x${h}`);
      });

      // ⭐ 直连转播站（真实 HTTP URL — AVPlayer DASH 已验证路径，不挂 loader）
      const src = media.createMediaSourceWithUrl(`http://127.0.0.1:${port}/manifest.mpd`, {
        'User-Agent': this.buildUA(),
        'Referer': 'https://www.bilibili.com/'
      });
      await this.av.setMediaSource(src);
      this.setStatus('初始化解码中…');
      this.log('MediaSource 已设置(直连转播站)，等待 AVPlayer 拉流…');
    } catch (e) {
      const msg = e instanceof Error ? `${e.message} | stack=${(e as Error).stack}` : String(e);
      this.log(`异常: ${msg}`);
      logError(`${TAG} runPoc exception: ${msg}`);
      this.setStatus('失败');
    } finally {
      this.running = false;
    }
  }

  /**
   * ⭐ 对照实验：不挂 loader，AVPlayer 直连标准公网 DASH MPD。
   * 判定：prepared → 能播 = 我们 MPD 不合规；error/超时 = 实机不支持 DASH。
   */
  private async runPublicMpdTest(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    this.logs = '';
    this.setStatus('公网对照中…');
    this.releasePlayer();
    if (this.loader) {
      this.loader.destroy();
      this.loader = null;
    }

    // 候选公网 DASH 测试流（已 curl 验证均 200；逐个尝试，前置 HTTP 可达性检查区分 URL 问题）
    const candidates: Array<string> = [
      'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd',
      'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.mpd'
    ];

    try {
      for (let i = 0; i < candidates.length; i++) {
        const mpdUrl = candidates[i];
        this.log(`[对照${i + 1}/${candidates.length}] ${mpdUrl}`);
        // 前置可达性检查：HTTP 状态码直接打印，区分「URL 问题」与「DASH 问题」
        const status = await this.checkUrlReachable(mpdUrl);
        this.log(`[对照${i + 1}] HTTP 预检 status=${status}`);
        const ok = await this.playPublicMpd(mpdUrl);
        if (ok) {
          this.log(`[对照${i + 1}] 播放成功（prepared）→ AVPlayer 支持 DASH，问题在自建 MPD/loader`);
          this.setStatus('对照-可播');
          return;
        }
        this.log(`[对照${i + 1}] 失败，尝试下一个…`);
        this.releasePlayer();
      }
      this.log('全部公网 MPD 失败 → 需分别排查（看各条 HTTP 预检 status 与 AVPlayer error）');
      this.setStatus('对照-全败');
    } catch (e) {
      const msg = e instanceof Error ? `${e.message}` : String(e);
      this.log(`对照异常: ${msg}`);
      this.setStatus('对照-异常');
    } finally {
      this.running = false;
    }
  }

  /** 用 http 预检 URL 可达性，返回 HTTP 状态码（-1 表示网络异常） */
  private async checkUrlReachable(url: string): Promise<number> {
    try {
      const req = http.createHttp();
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': this.buildUA()
        },
        connectTimeout: 8000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.STRING
      });
      req.destroy();
      return resp.responseCode;
    } catch (e) {
      logError(`${TAG} checkUrlReachable error: ${e}`);
      return -1;
    }
  }

  /**
   * ⭐ 决定性对照：akamai 原版 MPD 文本 + 我们 loader 分发全部请求。
   * MPD 通过 loader 推送（缓存 mpdXml），分段 URL 是 akamai 真实地址 → loader 透传拉取。
   *  能播 → loader+DASH 模式通，问题在 B 站 map 映射
   *  不能播 → AVPlayer 的 loader 模式不支持 DASH，方案②终审
   */
  private async runAkamaiLoaderTest(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    this.logs = '';
    this.setStatus('Akamai×Loader 对照中…');
    this.releasePlayer();
    if (this.loader) {
      this.loader.destroy();
      this.loader = null;
    }

    const mpdUrl = 'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd';

    try {
      // 1. 拉取 akamai MPD 原文
      const mpdXml = await this.fetchText(mpdUrl);
      if (!mpdXml) {
        this.log('拉取 akamai MPD 失败，中止');
        this.setStatus('失败');
        return;
      }
      this.log(`akamai MPD 原文已获取，长度=${mpdXml.length}`);

      // 2. loader：MPD 走缓存，其余 URL 透传（需要 baseUrl 指向真实站点）
      const loaderConfig: DashLoaderConfig = {
        mpdXml: mpdXml,
        videoUrl: mpdUrl,  // 无关紧要，透传分支不会用它
        audioUrl: mpdUrl,
        referer: '',
        userAgent: this.buildUA(),
        cookie: ''
      };
      this.loader = new DashMediaLoader();
      this.loader.setConfig(loaderConfig);

      // 3. AVPlayer 挂 loader，MPD URL 即 akamai 真实地址
      const player = await media.createAVPlayer();
      this.av = player;
      player.on('stateChange', async (st: string) => {
        this.log(`AVPlayer state: ${st}`);
        if (st === 'initialized') {
          const id = this.xc.getXComponentSurfaceId();
          if (id) {
            this.sId = id;
            player.surfaceId = id;
            await player.prepare();
          }
        } else if (st === 'prepared') {
          await player.play();
          this.setStatus('Akamai×Loader 可播');
        }
      });
      player.on('error', (err: BusinessError) => {
        this.log(`AVPlayer error: code=${err.code} ${err.message}`);
        this.setStatus('失败');
      });
      player.on('videoSizeChange', (w: number, h: number) => {
        this.log(`videoSizeChange: ${w}x${h}`);
      });

      const src = media.createMediaSourceWithUrl(mpdUrl, {
        'User-Agent': this.buildUA(),
        'Referer': 'https://www.bilibili.com/'
      });
      src.setMediaResourceLoaderDelegate(this.loader.getLoader());
      await player.setMediaSource(src);
      this.log('已设置 MediaSource+loader，等待 AVPlayer 拉流…');
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.log(`异常: ${msg}`);
      this.setStatus('失败');
    } finally {
      this.running = false;
    }
  }

  /** 拉取文本（供 MPD 原文获取） */
  private async fetchText(url: string): Promise<string> {
    try {
      const req = http.createHttp();
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': this.buildUA()
        },
        connectTimeout: 10000,
        readTimeout: 10000
      });
      req.destroy();
      if (resp.responseCode !== 200) {
        return '';
      }
      return resp.result as string;
    } catch (e) {
      logError(`${TAG} fetchText error: ${e}`);
      return '';
    }
  }

  /** 用给定公网 MPD URL 播放一次，prepared 视为成功 */
  private async playPublicMpd(mpdUrl: string): Promise<boolean> {
    let player: media.AVPlayer | null = null;
    let settled: boolean = false;
    let resolveState: (r: boolean) => void = () => {
    };
    const stateDone = new Promise<boolean>((resolve: (r: boolean) => void) => {
      resolveState = resolve;
    });
    const timer = setTimeout(() => {
      this.log(`[对照] 10s 超时未到 prepared，判定失败`);
      if (!settled) {
        settled = true;
        resolveState(false);
      }
    }, 10000);

    try {
      player = await media.createAVPlayer();
      this.av = player;

      const finish = (r: boolean) => {
        if (settled) {
          return;
        }
        settled = true;
        resolveState(r);
      };

      player.on('stateChange', async (st: string) => {
        this.log(`AVPlayer state: ${st}`);
        if (st === 'initialized') {
          const id = this.xc.getXComponentSurfaceId();
          if (id) {
            this.sId = id;
            player!.surfaceId = id;
            await player!.prepare();
          } else {
            this.log(`[对照] surfaceId 未就绪，绑定延后`);
          }
        } else if (st === 'prepared') {
          await player!.play();
          finish(true);
        }
      });
      player.on('error', (err: BusinessError) => {
        this.log(`[对照] AVPlayer error: code=${err.code} ${err.message}`);
        finish(false);
      });

      const src = media.createMediaSourceWithUrl(mpdUrl, {
        'User-Agent': this.buildUA(),
        'Referer': 'https://www.bilibili.com/'
      });
      await player.setMediaSource(src);
      return await stateDone;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.log(`[对照] 异常: ${msg}`);
      return false;
    } finally {
      clearTimeout(timer);
    }
  }

  /** 从详情接口取首P cid */
  private async fetchFirstCid(bvid: string): Promise<number> {
    const url = `https://api.bilibili.com/x/web-interface/view?${bvid.match(/^\d+$/) ? `aid=${bvid}` : `bvid=${bvid}`}`;
    try {
      const req = http.createHttp();
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': this.buildUA(),
          'Referer': 'https://www.bilibili.com/',
          'Cookie': this.buildCookie()
        },
        connectTimeout: 10000,
        readTimeout: 10000
      });
      req.destroy();
      if (resp.responseCode !== 200) {
        return 0;
      }
      const json = JSON.parse(resp.result as string) as RawVideoDetailResp;
      return json.code === 0 && json.data?.cid ? json.data.cid : 0;
    } catch (e) {
      logError(`${TAG} fetchFirstCid error: ${e}`);
      return 0;
    }
  }

  /**
   * 强制 DASH 取流（fnval=16 只回 DASH），返回完整元数据。
   * 不走 getVideoPlayUrl：它优先 FLV 且裁剪了带宽/宽高等字段。
   */
  private async fetchDashPlayUrl(bvid: string, cid: number, qn: number): Promise<RawPlayUrlData | null> {
    const params: Record<string, string> = {};
    params['bvid'] = bvid;
    params['cid'] = cid.toString();
    params['qn'] = qn.toString();
    params['fnval'] = '16';
    params['fnver'] = '0';
    params['fourk'] = '1';
    params['platform'] = 'html5';
    params['high_quality'] = '1';
    const queryStr = await AppSign.generateWebParams(params);
    const url = `https://api.bilibili.com/x/player/wbi/playurl?${queryStr}`;

    try {
      const req = http.createHttp();
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': this.buildUA(),
          'Referer': 'https://www.bilibili.com/',
          'Origin': 'https://www.bilibili.com',
          'Cookie': this.buildCookie()
        },
        connectTimeout: 10000,
        readTimeout: 10000
      });
      req.destroy();
      if (resp.responseCode !== 200) {
        this.log(`playurl HTTP ${resp.responseCode} 实际 qn=${qn}`);
        return null;
      }
      const json = JSON.parse(resp.result as string) as RawPlayUrlResponse;
      if (json.code !== 0) {
        this.log(`playurl code=${json.code} ${json.message || ''}`);
        return null;
      }
      return json.data || null;
    } catch (e) {
      logError(`${TAG} fetchDashPlayUrl error: ${e}`);
      return null;
    }
  }

  /** 选视频流：非 AV1 优先（设备解码限制），再按 id 降序（画质高者优先） */
  private pickVideoStream(list: Array<RawDashVideo>): PickVideoResult {
    const nonAv1 = list.filter((v: RawDashVideo) => v.codecid !== 13);
    const usable = nonAv1.length > 0 ? nonAv1 : list;
    const sorted = usable.slice().sort((a: RawDashVideo, b: RawDashVideo) => b.id - a.id);
    const result: PickVideoResult = { r: sorted.length > 0 ? sorted[0] : null };
    return result;
  }

  /** 选音频流：按 id 降序（高音质优先） */
  private pickAudioStream(list: Array<RawDashAudio>): PickAudioResult {
    const sorted = list.slice().sort((a: RawDashAudio, b: RawDashAudio) => b.id - a.id);
    const result: PickAudioResult = { r: sorted.length > 0 ? sorted[0] : null };
    return result;
  }

  private buildUA(): string {
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36';
  }

  private buildCookie(): string {
    const cookie = AppStorage.get<string>('biliCookie') || '';
    const deviceId = BiliRequest.getDeviceId();
    if (!deviceId) {
      return cookie;
    }
    return cookie ? `${cookie}; buvid3=${deviceId}` : `buvid3=${deviceId}`;
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Image($r('app.media.ic_public_arrow_left_filled'))
          .width(24)
          .height(24)
          .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .onClick(() => this.getUIContext().getRouter().back())

        Text('DASH PoC 验证')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .margin({ left: 16 })

        Blank()
        Text(this.statusText)
          .fontSize(13)
          .fontColor(this.statusText === '播放中' ? '#00AA00' : '#999999')
      }
      .width('100%')
      .padding({ top: 16 + this.statusBarHeight, left: 16, right: 16, bottom: 16 })

      // ⭐ 视频画面（渲染目标）
      XComponent({ id: 'dash_poc_xc', type: XComponentType.SURFACE, controller: this.xc })
        .onLoad(this.onXC)
        .width('100%')
        .height(200)
        .margin({ left: 16, right: 16 })
        .clip(true)
        .backgroundColor('#000000')

      // 输入区
      Column({ space: 8 }) {
        TextInput({ placeholder: 'bvid 例如 BV1xx411c7mD', text: this.bvid })
          .onChange((v: string) => { this.bvid = v; })
          .width('100%')

        TextInput({ placeholder: 'cid（留空自动取首P）', text: this.cidText })
          .onChange((v: string) => { this.cidText = v; })
          .width('100%')

        Button(this.running ? '验证中…' : '开始验证')
          .width('100%')
          .enabled(!this.running)
          .backgroundColor('#007DFF')
          .fontColor('#FFFFFF')
          .onClick(() => { this.runPoc(); })

        // ⭐ 对照实验：不挂 loader，AVPlayer 直连标准公网 DASH MPD
        //   结果决定性：能播 → 我们的 MPD 不合规需修生成器；不能播 → AVPlayer 26 实机不支持 DASH，方案②告吹
        Button(this.running ? '验证中…' : '公网 MPD 对照')
          .width('100%')
          .enabled(!this.running)
          .backgroundColor('#007DFF')
          .fontColor('#FFFFFF')
          .onClick(() => { this.runPublicMpdTest(); })

        // ⭐ 决定性对照：akamai 原版 MPD + 经我们 loader 分发（分段 URL 仍是 akamai 真实地址）
        //   能播 → loader 分发 DASH 可行，问题在 B 站分段映射；不能播 → loader 模式不支持 DASH
        Button(this.running ? '验证中…' : 'Akamai×Loader 对照')
          .width('100%')
          .enabled(!this.running)
          .backgroundColor('#007DFF')
          .fontColor('#FFFFFF')
          .onClick(() => { this.runAkamaiLoaderTest(); })
      }
      .padding(16)
      .width('100%')

      // 日志区
      Column() {
        Text('日志')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Scroll() {
          Text(this.logs)
            .fontSize(12)
            .fontFamily('monospace')
            .fontColor(this.isDarkMode ? '#CCCCCC' : '#333333')
            .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
      }
      .padding(16)
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? '#111111' : '#F5F5F5')
  }
}
