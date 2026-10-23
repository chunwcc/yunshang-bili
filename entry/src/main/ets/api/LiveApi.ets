// LiveApi.ets — B站直播API服务
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { HttpConstants } from './HttpConstants';

// ==================== 流地址缓存（避免CDN节点反复切换） ====================
const STREAM_URL_CACHE_TTL: number = 30000; // 缓存有效期 30 秒
interface CacheEntry {
  url: string;
  qn: number;
  time: number;
  videoWidth?: number;
  videoHeight?: number;
}

interface CachedStreamUrl {
  url: string;
  qn: number;
  videoWidth?: number;
  videoHeight?: number;
}

const streamUrlCache: Map<string, CacheEntry> = new Map();

/** 生成缓存键: "roomId_qn" */
function cacheKey(roomId: number, qn: number): string {
  return `${roomId}_${qn}`;
}

/** 获取缓存的流地址（未过期则返回，否则返回 null） */
function getCachedStreamUrl(roomId: number, qn: number): CachedStreamUrl | null {
  const key: string = cacheKey(roomId, qn);
  const cached: CacheEntry | undefined = streamUrlCache.get(key);
  if (cached && (Date.now() - cached.time) < STREAM_URL_CACHE_TTL) {
    logInfo(`[LiveApi] 🔄 命中缓存(roomId=${roomId}, qn=${qn}), 跳过API请求`);
    const result: CachedStreamUrl = {
      url: cached.url, qn: cached.qn,
      videoWidth: cached.videoWidth, videoHeight: cached.videoHeight
    };
    return result;
  }
  return null;
}

/** 缓存成功获取的 HLS 流地址 */
function setCachedStreamUrl(roomId: number, url: string, qn: number, videoWidth?: number, videoHeight?: number): void {
  const key: string = cacheKey(roomId, qn);
  streamUrlCache.set(key, { url, qn, time: Date.now(), videoWidth, videoHeight });
  logInfo(`[LiveApi] 💾 缓存流地址(roomId=${roomId}, qn=${qn})`);
}

/** 播放失败时作废缓存（下次请求强制刷新） */
export function invalidateCachedStreamUrl(roomId: number, qn?: number): void {
  if (qn !== undefined) {
    const key: string = cacheKey(roomId, qn);
    streamUrlCache.delete(key);
    logInfo(`[LiveApi] 🗑️ 作废缓存(roomId=${roomId}, qn=${qn})`);
  } else {
    // 未指定 qn 时清除该房间所有画质的缓存
    const prefix: string = `${roomId}_`;
    const keysToDelete: string[] = [];
    streamUrlCache.forEach((_val, k: string) => {
      if (k.startsWith(prefix)) {
        keysToDelete.push(k);
      }
    });
    for (const k of keysToDelete) {
      streamUrlCache.delete(k);
    }
    logInfo(`[LiveApi] 🗑️ 作废所有缓存(roomId=${roomId}, 共${keysToDelete.length}条)`);
  }
}

/** 从全局存储中获取B站登录Cookie，并附加设备和浏览器标识 */
function getBiliCookie(): string {
  const cookie = AppStorage.get<string>('biliCookie') || '';
  let deviceId = AppStorage.get<string>('biliDeviceId');
  if (!deviceId) {
    deviceId = 'XY' + Math.random().toString(36).substring(2, 15) + Math.random().toString(36).substring(2, 15);
    AppStorage.setOrCreate('biliDeviceId', deviceId);
  }
  let cookieHeader = cookie;
  if (deviceId) {
    cookieHeader += (cookieHeader ? '; ' : '') + `buvid3=${deviceId}`;
  }

  // ⚠️ 同 BilibiliApi.getCookieHeader：伪造 buvid4/b_lsid/buvid_fp 的 "undefined" 值
  //    会被 B站 WAF 判为异常设备，直播取流/hi 接口会静默降级或 -351。只补合法字段。
  const additionalCookies = [
    `b_nut=${Math.floor(Date.now() / 1000)}`,
    'i-wanna-go-back=-1',
    'nostalgia_conf=-1',
    'PVID=1',
    'browser_resolution=1920-1080',
    'innersign=0'
  ];

  if (cookieHeader) {
    cookieHeader += '; ' + additionalCookies.join('; ');
  } else {
    cookieHeader = additionalCookies.join('; ');
  }

  return cookieHeader;
}

// ==================== 类型定义 ====================

export interface LiveRoomInfo {
  roomId: number;
  uid: number;
  title: string;
  uname: string;
  face: string;
  online: number;
  liveStatus: number;
  keyframe?: string;
  tags?: string;
}

export interface LiveStreamUrlResult {
  url: string;
  acceptQuality: number[];
  currentQn: number;
  isFlvOnly?: boolean;  // true=仅获取到FLV(系统播放器不支持)
  videoWidth?: number;   // 视频宽度（来自API，用于判断横竖屏）
  videoHeight?: number;  // 视频高度
}

/** B站 API 通用响应 */
interface ApiResponseBase {
  code: number;
  message: string;
}

/** 房间信息 data 字段 */
interface RoomInfoData {
  room_id?: number;
  uid?: number;
  title?: string;
  uname?: string;
  user_cover?: string;
  online?: number;
  live_status?: number;
  keyframe?: string;
  tags?: string;
}

interface RoomInfoResponse extends ApiResponseBase {
  data?: RoomInfoData;
}

/** 流地址 data 字段 */
interface DurlItem {
  url: string;
  length?: number;
  order?: number;
}

interface PlayUrlData {
  current_qn?: number;
  accept_quality?: number[];
  durl?: DurlItem[];
}

interface PlayUrlResponse extends ApiResponseBase {
  data?: PlayUrlData;
}

/** 新版 API — 流信息 */
interface UrlInfo {
  host: string;
  extra: string;
  stream_ttl: number;
}

interface CodecInfo {
  codec_name: string;
  current_qn?: number;
  base_url: string;
  url_info?: UrlInfo[];
}

interface FormatInfo {
  format_name: string;
  codec?: CodecInfo[];
}

interface StreamInfo {
  protocol_name: string;
  format?: FormatInfo[];
}

interface QnDesc {
  qn: number;
  desc: string;
}

interface PlayUrlInfo {
  g_qn_desc?: QnDesc[];
  stream?: StreamInfo[];
}

interface NewPlayUrlData {
  current_qn?: number;
  accept_quality?: number[];
  quality_description?: QualityDescription[];
  playurl?: PlayUrlInfo;
}

interface NewPlayUrlResponse extends ApiResponseBase {
  data?: NewPlayUrlData;
}

/** LIVE_QUALITY 类型 */
export interface LiveQualityMap {
  ORIGINAL: number;
  HIGH: number;
  MEDIUM: number;
  LOW: number;
  VERY_LOW: number;
}

/** 画质描述（getRoomPlayInfo 返回） */
export interface QualityDescription {
  qn: number;
  desc: string;
}

/** V2 API: data.playurl_info.playurl.stream[].format[].codec[] 的 URL 信息 */
interface CdnUrlInfo {
  host: string;
  extra: string;
  stream_ttl?: number;
}

/** V2 API: codec 层 - 包含画质和流地址 */
interface CodecItem {
  codec_name?: string;
  current_qn?: number;
  accept_qn?: number[];
  base_url?: string;
  url_info?: CdnUrlInfo[];
  hdr_qn?: number;
  dolby_type?: number;
  attr_name?: string;
  width?: number;   // B站 API 返回的视频宽度
  height?: number;  // B站 API 返回的视频高度
}

/** V2 API: format 层 */
interface FormatItem {
  format_name?: string;
  codec?: CodecItem[];
}

/** V2 API: stream 层 */
interface StreamItem {
  protocol_name?: string;
  format?: FormatItem[];
}

/** V2 API: playurl 层 */
interface PlayurlV2 {
  cid?: number;
  g_qn_desc?: QnDesc[];
  stream?: StreamItem[];
}

/** V2 API: playurl_info 层 */
interface PlayurlInfoV2 {
  playurl?: PlayurlV2;
}

/** V2 API: data 层 */
interface V2RoomPlayInfoData {
  room_id?: number;
  uid?: number;
  live_status?: number;
  short_id?: number;
  playurl_info?: PlayurlInfoV2;
}

/** V2 API: 完整响应 */
interface V2RoomPlayInfoResponse extends ApiResponseBase {
  data?: V2RoomPlayInfoData;
}

/** getRoomPlayInfo 的公共返回类型 */
export interface RoomPlayInfoResult {
  currentQn: number;
  qualities: QualityDescription[];
}

// ==================== API 实现 ====================

export async function getLiveRoomInfo(roomId: number): Promise<LiveRoomInfo | null> {
  const httpRequest = http.createHttp();
  try {
    const url = `${HttpConstants.liveBaseUrl}/room/v1/Room/get_info?room_id=${roomId}`;
    logInfo(`[LiveApi] 获取房间信息: ${url}`);

    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://live.bilibili.com/',
        'Origin': 'https://live.bilibili.com',
        'Cookie': getBiliCookie()
      },
      connectTimeout: 10000,
      readTimeout: 10000
    });

    if (response.responseCode !== 200) {
      logError(`[LiveApi] 请求失败: ${response.responseCode}`);
      return null;
    }

    const body = JSON.parse(response.result as string) as RoomInfoResponse;
    if (body.code !== 0) {
      logError(`[LiveApi] API错误: ${body.message}`);
      return null;
    }

    const d = body.data;
    const info: LiveRoomInfo = {
      roomId: d?.room_id ?? roomId,
      uid: d?.uid ?? 0,
      title: d?.title ?? '',
      uname: d?.uname ?? '',
      face: d?.user_cover ?? '',
      online: d?.online ?? 0,
      liveStatus: d?.live_status ?? 0,
      keyframe: d?.keyframe ?? '',
    };
    return info;
  } catch (_e) {
    logError(`[LiveApi] getLiveRoomInfo 异常: ${_e}`);
    return null;
  } finally {
    httpRequest.destroy();
  }
}

/**
 * 获取直播间的可用画质列表
 * 使用 v2 getRoomPlayInfo 接口（与 PiliPlus 一致）
 * 从 data.playurl_info.playurl.g_qn_desc 提取画质列表
 */
export async function getRoomPlayInfo(roomId: number): Promise<RoomPlayInfoResult | null> {
  const httpRequest = http.createHttp();
  try {
    const url = `${HttpConstants.liveBaseUrl}/xlive/web-room/v2/index/getRoomPlayInfo` +
      `?room_id=${roomId}&protocol=0,1&format=0,1,2&codec=0,1,2&qn=250&platform=web&ptype=8&dolby=5&panorama=1&web_location=444.8`;
    logInfo(`[LiveApi] 获取房间画质列表(v2): ${url.substring(0, 120)}...`);

    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://live.bilibili.com/',
        'Origin': 'https://live.bilibili.com',
        'Cookie': getBiliCookie()
      },
      connectTimeout: 10000,
      readTimeout: 10000
    });

    if (response.responseCode !== 200) {
      logWarn(`[LiveApi] getRoomPlayInfo HTTP错误: ${response.responseCode}`);
      return null;
    }

    const body = JSON.parse(response.result as string) as V2RoomPlayInfoResponse;
    if (body.code !== 0 || !body.data) {
      logWarn(`[LiveApi] getRoomPlayInfo API错误: code=${body.code}, msg=${body.message}`);
      return null;
    }

    // 从 playurl_info.playurl.g_qn_desc 提取画质列表
    let qualities: QualityDescription[] = [];
    let currentQn: number = 250;

    const playurlInfo: PlayurlInfoV2 | undefined = body.data.playurl_info;
    if (playurlInfo?.playurl?.g_qn_desc) {
      qualities = playurlInfo.playurl.g_qn_desc.map((q: QnDesc) => ({
        qn: q.qn,
        desc: q.desc
      }) as QualityDescription);
    }

    // 从第一个流的第一种编码的 current_qn 获取当前画质
    const streams: StreamItem[] | undefined = playurlInfo?.playurl?.stream;
    if (streams && streams.length > 0) {
      const formats: FormatItem[] | undefined = streams[0].format;
      if (formats && formats.length > 0) {
        const codecs: CodecItem[] | undefined = formats[0].codec;
        if (codecs && codecs.length > 0 && codecs[0].current_qn !== undefined) {
          currentQn = codecs[0].current_qn;
        }
      }
    }

    if (qualities.length === 0) {
      logWarn(`[LiveApi] getRoomPlayInfo 无法获取画质列表`);
      return null;
    }

    const result: RoomPlayInfoResult = {
      currentQn: currentQn,
      qualities: qualities
    };
    logInfo(`[LiveApi] ✅ 获取到画质列表: ${JSON.stringify(qualities)}, currentQn=${currentQn}`);
    return result;
  } catch (_e) {
    logError(`[LiveApi] getRoomPlayInfo 异常: ${_e}`);
    return null;
  } finally {
    httpRequest.destroy();
  }
}

export async function getLiveStreamUrl(roomId: number, qn: number = 250, forceRefresh: boolean = false): Promise<LiveStreamUrlResult | null> {
  // ① 检查缓存（非强制刷新时直接返回缓存的 HLS 地址，避免 CDN 重新分配）
  if (!forceRefresh) {
    const cached = getCachedStreamUrl(roomId, qn);
    if (cached) {
      logInfo(`[LiveApi] 🎯 返回缓存的HLS流地址(roomId=${roomId}, qn=${qn})`);
      return {
        url: cached.url,
        acceptQuality: [cached.qn],
        currentQn: cached.qn,
        videoWidth: cached.videoWidth,
        videoHeight: cached.videoHeight
      };
    }
  }

  // ② 优先尝试 v2 API — Video 组件支持 HLS(.m3u8) 流
  const v2Result: LiveStreamUrlResult | null = await tryFetchV2PlayUrl(roomId, qn);
  if (v2Result) {
    logInfo(`[LiveApi] ✅ v2 API 获取到流(qn=${qn})`);
    setCachedStreamUrl(roomId, v2Result.url, v2Result.currentQn, v2Result.videoWidth, v2Result.videoHeight);
    return v2Result;
  }

  // ③ 降级到旧逻辑（原 getLiveStreamUrl 的 fallback 链）
  // 降级画质列表：从用户请求的画质开始逐级下降（去重）
  const qualityLevels: number[] = [qn, 400, 250, 150, 80];
  const uniqueLevels: number[] = [];
  const seen = new Set<number>();
  for (const q of qualityLevels) {
    if (!seen.has(q)) { seen.add(q); uniqueLevels.push(q); }
  }

  let flvFallback: LiveStreamUrlResult | null = null;

  for (const currentQn of uniqueLevels) {
    logInfo(`[LiveApi] ⬇️ 尝试画质 qn=${currentQn} 查找HLS(旧API)...`);

    // ③-1 新API (xlive v1)
    const newResult = await tryFetchNewPlayUrl(roomId, currentQn);
    if (newResult) {
      if (newResult.url.includes('.m3u8')) {
        logInfo(`[LiveApi] ✅ 新API获取到HLS(qn=${currentQn})`);
        setCachedStreamUrl(roomId, newResult.url, newResult.currentQn);
        return newResult;
      }
      if (!flvFallback) { flvFallback = newResult; }
    }

    // ③-2 getInfoByRoom
    const infoResult = await tryFetchInfoByRoom(roomId, currentQn);
    if (infoResult) {
      logInfo(`[LiveApi] ✅ getInfoByRoom获取到HLS(qn=${currentQn})`);
      setCachedStreamUrl(roomId, infoResult.url, currentQn);
      return infoResult;
    }

    // ③-3 旧API找可播流（FLV/TS，系统播放器可播H.264+AAC）
    const strategies: string[] = [
      `?cid=${roomId}&qn=${currentQn}&platform=web&protocol=1&https_url_req=1`,
      `?cid=${roomId}&qn=${currentQn}&platform=web&protocol=1`,
      `?cid=${roomId}&qn=${currentQn}&platform=android&protocol=1&https_url_req=1`,
    ];

    for (const strategy of strategies) {
      const result = await tryFetchPlayUrl(roomId, strategy);
      if (result) {
        if (result.url.includes('.m3u8') || result.url.includes('m3u8')) {
          logInfo(`[LiveApi] ✅ 旧API获取到HLS(qn=${currentQn})`);
          setCachedStreamUrl(roomId, result.url, currentQn);
          return result;
        }
        if (!flvFallback) {
          flvFallback = result;
        }
      }
    }
  }

  // ④ 没有找到HLS → 退回FLV流（系统播放器可播H.264+AAC的FLV）
  if (flvFallback) {
    logInfo(`[LiveApi] ✅ 返回FLV流(系统播放器兼容), qn=${flvFallback.currentQn}`);
    setCachedStreamUrl(roomId, flvFallback.url, flvFallback.currentQn);
    return flvFallback;
  }

  return null;
}

/**
 * 使用 v2 API 获取指定 qn 的 HLS 流地址
 * 与 PiliPlus 一致: 从 data.playurl_info.playurl.stream 中拼出完整URL
 */
async function tryFetchV2PlayUrl(roomId: number, qn: number): Promise<LiveStreamUrlResult | null> {
  const httpRequest = http.createHttp();
  try {
    const url = `${HttpConstants.liveBaseUrl}/xlive/web-room/v2/index/getRoomPlayInfo` +
      `?room_id=${roomId}&protocol=0,1&format=0,1,2&codec=0,1,2&qn=${qn}&platform=web&ptype=8&dolby=5&panorama=1&web_location=444.8`;
    logInfo(`[LiveApi] v2 API请求流地址: ${url.substring(0, 120)}...`);

    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://live.bilibili.com/',
        'Origin': 'https://live.bilibili.com',
        'Cookie': getBiliCookie()
      },
      connectTimeout: 10000,
      readTimeout: 10000
    });

    if (response.responseCode !== 200) {
      logWarn(`[LiveApi] v2 API HTTP错误: ${response.responseCode}`);
      return null;
    }

    const body = JSON.parse(response.result as string) as V2RoomPlayInfoResponse;
    if (body.code !== 0 || !body.data) {
      logWarn(`[LiveApi] v2 API返回错误: code=${body.code}`);
      return null;
    }

    const streams: StreamItem[] | undefined = body.data.playurl_info?.playurl?.stream;
    if (!streams || streams.length === 0) {
      logWarn(`[LiveApi] v2 API无stream数据`);
      return null;
    }

    // 日志: 打印所有流的协议名
    let protoLog: string = '';
    for (let i = 0; i < streams.length; i++) {
      protoLog += `[${i}]${streams[i].protocol_name || '?'} `;
    }
    logInfo(`[LiveApi] v2 API流协议列表: ${protoLog}`);

    // 选择协议和格式：优先 http_hls+fmp4（fMP4分段更高效，卡顿少）
    // 其次 http_hls+ts，最次 http_stream+flv
    let selectedFormat: FormatItem | undefined;
    let selectedProtocol: string = '';

    for (const stream of streams) {
      if (stream.protocol_name === 'http_hls' && stream.format) {
        // 在 http_hls 中优先选 fmp4 格式（更高效的流媒体分段）
        for (const fmt of stream.format) {
          if (fmt.format_name === 'fmp4') {
            selectedFormat = fmt;
            selectedProtocol = 'http_hls';
            break;
          }
        }
        if (selectedFormat) break;
        // 无 fmp4 则用 ts
        selectedFormat = stream.format[0];
        selectedProtocol = 'http_hls';
        break;
      }
    }
    if (!selectedFormat) {
      for (const stream of streams) {
        if (stream.protocol_name === 'http_stream' && stream.format) {
          selectedFormat = stream.format[0];
          selectedProtocol = 'http_stream';
          break;
        }
      }
    }
    if (!selectedFormat && streams[0]?.format) {
      selectedFormat = streams[0].format[0];
      selectedProtocol = streams[0].protocol_name || '?';
    }
    if (!selectedFormat) {
      logWarn(`[LiveApi] v2 API无可用的format`);
      return null;
    }

    logInfo(`[LiveApi] v2 API 选择: proto=${selectedProtocol} fmt=${selectedFormat.format_name || '?'}`);

    // 选 codec：优先 avc/h264，兼容性最好
    const fmtCodecs: CodecItem[] | undefined = selectedFormat.codec;
    if (!fmtCodecs || fmtCodecs.length === 0) {
      logWarn(`[LiveApi] v2 API无codec数据`);
      return null;
    }
    let selectedCodec: CodecItem | undefined;
    for (const c of fmtCodecs) {
      if (c.codec_name === 'avc' || c.codec_name === 'h264') {
        selectedCodec = c;
        break;
      }
    }
    if (!selectedCodec) {
      selectedCodec = fmtCodecs[0];
    }

    if (!selectedCodec || !selectedCodec.base_url || !selectedCodec.url_info) {
      logWarn(`[LiveApi] v2 API无可用codec/url信息`);
      return null;
    }
    const urlInfos: CdnUrlInfo[] | undefined = selectedCodec.url_info;
    if (!urlInfos || urlInfos.length === 0) {
      logWarn(`[LiveApi] v2 API无url_info条目`);
      return null;
    }

    const cdnInfo: CdnUrlInfo = urlInfos[0];
    const fullUrl: string = cdnInfo.host + selectedCodec.base_url + cdnInfo.extra;
    const acceptQn: number[] = selectedCodec.accept_qn ?? [qn];
    const currentQn: number = selectedCodec.current_qn ?? qn;

    logInfo(`[LiveApi] ✅ v2 API获取到流(qn=${currentQn}, fmt=${selectedFormat.format_name || '?'}, codec=${selectedCodec.codec_name || '?'}, proto=${selectedProtocol}): ${fullUrl.substring(0, 100)}...`);
    // 提取视频宽高（B站API在codec层返回）
    const vw: number | undefined = selectedCodec.width;
    const vh: number | undefined = selectedCodec.height;
    if (vw && vh) {
      logInfo(`[LiveApi] v2 API 视频尺寸: ${vw}x${vh}`);
    }
    const result: LiveStreamUrlResult = {
      url: fullUrl,
      acceptQuality: acceptQn,
      currentQn: currentQn,
      videoWidth: vw,
      videoHeight: vh
    };
    return result;
  } catch (_e) {
    logError(`[LiveApi] tryFetchV2PlayUrl 异常: ${_e}`);
    return null;
  } finally {
    if (httpRequest) {
      httpRequest.destroy();
    }
  }
}

/**
 * 新 API: xlive/web-room/v1/playUrl/playUrl
 * 返回更详细的流信息，可以从 hls stream 中拼出 HLS 地址
 */
async function tryFetchNewPlayUrl(roomId: number, qn: number): Promise<LiveStreamUrlResult | null> {
  const ptypeList: number[] = [1]; // 只试 HLS(ptype=1)，跳过 FLV(0/2)
  for (const ptype of ptypeList) {
    const result = await tryFetchNewPlayUrlWithPtype(roomId, qn, ptype);
    if (result) return result;
  }
  return null;
}

/**
 * 带平台参数的新API尝试
 */
async function tryFetchNewPlayUrlWithPlatform(roomId: number, qn: number, platform: string, ptype: number): Promise<LiveStreamUrlResult | null> {
  const httpRequest = http.createHttp();
  try {
    const url = `${HttpConstants.liveBaseUrl}/xlive/web-room/v1/playUrl/playUrl?cid=${roomId}&platform=${platform}&qn=${qn}&https_url_req=1&ptype=${ptype}`;
    logInfo(`[LiveApi] 新API尝试(platform=${platform}, ptype=${ptype}): ${url.substring(0, 100)}...`);

    const ua = platform === 'android'
      ? 'Mozilla/5.0 (Linux; Android 13; Xiaomi13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36 BiliApp/6770600'
      : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';

    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': ua,
        'Referer': 'https://live.bilibili.com/',
        'Origin': 'https://live.bilibili.com',
        'Cookie': getBiliCookie()
      },
      connectTimeout: 10000,
      readTimeout: 10000
    });

    if (response.responseCode !== 200) {
      logWarn(`[LiveApi] 新API HTTP错误: ${response.responseCode}`);
      return null;
    }

    const body = JSON.parse(response.result as string) as NewPlayUrlResponse;
    if (body.code !== 0 || !body.data) {
      logWarn(`[LiveApi] 新API返回错误: code=${body.code}, msg=${body.message}, hasData=${!!body.data}`);
      return null;
    }

    let streams: StreamInfo[] = [];
    if (body.data.playurl?.stream) {
      // 旧格式: stream 在 data.playurl 下
      streams = body.data.playurl.stream;
    } else {
      // 新格式: stream 可能直接在 data 层
      const dataAny = body.data as Record<string, Object>;
      if (dataAny['stream']) {
        streams = dataAny['stream'] as StreamInfo[];
        logInfo(`[LiveApi] 新API新格式: 从data层获取到${streams.length}个流`);
      } else {
        logWarn(`[LiveApi] 新API返回错误: code=0, msg=0, hasData=true, hasPlayurl=false`);
        // 日志：输出响应结构的前300字符供调试
        const rawPreview = (response.result as string).substring(0, 300);
        logInfo(`[LiveApi] 新API响应结构预览: ${rawPreview}`);
        // 备用：从原始响应中搜索HLS URL
        try {
          const rawStr: string = response.result as string;
          const m3u8Regex = /https?:\/\/[^"'\s]*?m3u8[^"'\s]*/gi;
          const m3u8Matches: RegExpMatchArray | null = rawStr.match(m3u8Regex);
          if (m3u8Matches && m3u8Matches.length > 0) {
            logInfo(`[LiveApi] 备用搜索到HLS: ${m3u8Matches[0].substring(0, 80)}...`);
            return {
              url: m3u8Matches[0],
              acceptQuality: [qn],
              currentQn: qn
            };
          }
          // 也搜索FLV URL
          const flvRegex = /https?:\/\/[^"'\s]*?flv[^"'\s]*/gi;
          const flvMatches: RegExpMatchArray | null = rawStr.match(flvRegex);
          if (flvMatches && flvMatches.length > 0) {
            logInfo(`[LiveApi] 备用搜索到FLV: ${flvMatches[0].substring(0, 80)}...`);
            const flvResult: LiveStreamUrlResult = {
              url: flvMatches[0],
              acceptQuality: [qn],
              currentQn: qn
            };
            return flvResult;
          }
        } catch (_regexErr) {
          // 正则搜索失败，忽略
        }
        return null;
      }
    }

    // 优先找 HLS 协议流, 找不到就接受 HTTP-FLV
    let flvUrl: string = '';
    let hlsUrl: string = '';

    for (const stream of streams) {
      const isHlsProtocol: boolean = stream.protocol_name === 'hls';
      const formats: FormatInfo[] = stream.format ?? [];
      for (const fmt of formats) {
        const codecs: CodecInfo[] = fmt.codec ?? [];
        for (const codec of codecs) {
          const infos: UrlInfo[] = codec.url_info ?? [];
          for (const info of infos) {
            const fullUrl = info.host + codec.base_url + info.extra;
            if (fullUrl.includes('.m3u8') || isHlsProtocol) {
              hlsUrl = fullUrl;
            } else if (!flvUrl) {
              flvUrl = fullUrl;
            }
          }
        }
      }
    }

    // 优先返 HLS，没有就返 FLV 作为保底
    const finalUrl = hlsUrl || flvUrl;
    if (finalUrl) {
      logInfo(`[LiveApi] ✅ 新API获取到${hlsUrl ? 'HLS' : 'FLV(保底)'}: ${finalUrl.substring(0, 80)}...`);
      const result: LiveStreamUrlResult = {
        url: finalUrl,
        acceptQuality: body.data?.accept_quality ?? [qn],
        currentQn: body.data?.current_qn ?? qn
      };
      return result;
    }

    return null;
  } catch (_e) {
    logError(`[LiveApi] tryFetchNewPlayUrlWithPlatform 异常: ${_e}`);
    return null;
  } finally {
    httpRequest.destroy();
  }
}

/**
 * 新 API 入口 — 尝试多个 ptype 和平台组合
 */
async function tryFetchNewPlayUrlWithPtype(roomId: number, qn: number, ptype: number): Promise<LiveStreamUrlResult | null> {
  const platforms: string[] = ['web', 'android']; // iOS 平台很少返回 HLS，跳过
  for (const platform of platforms) {
    const result = await tryFetchNewPlayUrlWithPlatform(roomId, qn, platform, ptype);
    if (result) return result;
  }
  return null;
}

/**
 * 第三种方案: getInfoByRoom — 房间信息接口也返回流地址
 */
interface GetInfoByRoomData {
  play_url_info?: RoomPlayUrlInfo;
}

interface RoomPlayUrlInfo {
  play_url?: Object;
}

interface GetInfoByRoomResponse extends ApiResponseBase {
  data?: GetInfoByRoomData;
}

async function tryFetchInfoByRoom(roomId: number, qn: number): Promise<LiveStreamUrlResult | null> {
  const httpRequest = http.createHttp();
  try {
    const url = `${HttpConstants.liveBaseUrl}/xlive/web-room/v1/index/getInfoByRoom?room_id=${roomId}`;
    logInfo(`[LiveApi] getInfoByRoom尝试: ${url}`);

    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://live.bilibili.com/',
        'Origin': 'https://live.bilibili.com',
        'Cookie': getBiliCookie()
      },
      connectTimeout: 10000,
      readTimeout: 10000
    });

    if (response.responseCode !== 200) {
      logWarn(`[LiveApi] getInfoByRoom HTTP错误: ${response.responseCode}`);
      return null;
    }

    const body = JSON.parse(response.result as string) as GetInfoByRoomResponse;
    if (body.code !== 0 || !body.data) {
      logWarn(`[LiveApi] getInfoByRoom返回错误: code=${body.code}, msg=${body.message}`);
      return null;
    }

    // ① 标准解析: play_url_info.play_url 结构
    const playUrlInfo = body.data.play_url_info;
    if (playUrlInfo?.play_url) {
      const playUrlObj: Object = playUrlInfo.play_url;
      const entries: Array<[string, Object]> = Object.entries(playUrlObj);
      for (let i = 0; i < entries.length; i++) {
        const val = entries[i][1];
        // 兼容：value 可能是纯字符串 URL，也可能是 {url: "...", ...} 对象
        let urlStr: string = '';
        if (typeof val === 'string') {
          urlStr = val as string;
        } else if (val && typeof val === 'object') {
          const urlObj = val as Record<string, Object>;
          urlStr = (urlObj['url'] as string) || '';
          // 也检查嵌套对象中的url
          if (!urlStr && urlObj['host']) {
            urlStr = (urlObj['host'] as string) + (urlObj['base_url'] as string || '') + (urlObj['extra'] as string || '');
          }
        }
        if (urlStr.includes('.m3u8') || urlStr.includes('m3u8')) {
          logInfo(`[LiveApi] getInfoByRoom找到HLS: ${urlStr.substring(0, 80)}...`);
          const result: LiveStreamUrlResult = {
            url: urlStr,
            acceptQuality: [qn],
            currentQn: qn
          };
          return result;
        }
      }
    }

    // ② 备用：在整个响应数据中递归搜索 hls_url 或 m3u8 字段
    try {
      const raw = response.result as string;
      // 搜索URL中包含m3u8的字段值
      const m3u8Regex = /https?:\/\/[^"'\s]*?m3u8[^"'\s]*/g;
      const matches: RegExpMatchArray | null = raw.match(m3u8Regex);
      if (matches && matches.length > 0) {
        const hlsUrl = matches[0];
        logInfo(`[LiveApi] getInfoByRoom原始搜索找到HLS: ${hlsUrl.substring(0, 80)}...`);
        return {
          url: hlsUrl,
          acceptQuality: [qn],
          currentQn: qn
        };
      }
    } catch (_regexErr) {
      // 正则搜索失败，忽略
    }

    return null;
  } catch (_e) {
    logError(`[LiveApi] tryFetchInfoByRoom 异常: ${_e}`);
    return null;
  } finally {
    httpRequest.destroy();
  }
}

async function tryFetchPlayUrl(roomId: number, query: string): Promise<LiveStreamUrlResult | null> {
  const httpRequest = http.createHttp();
  try {
    const url = `${HttpConstants.liveBaseUrl}/room/v1/Room/playUrl${query}`;
    logInfo(`[LiveApi] 尝试获取直播流: ${url}`);

    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://live.bilibili.com/',
        'Origin': 'https://live.bilibili.com',
        'Cookie': getBiliCookie()
      },
      connectTimeout: 10000,
      readTimeout: 10000
    });

    if (response.responseCode !== 200) {
      return null;
    }

    const body = JSON.parse(response.result as string) as PlayUrlResponse;
    if (body.code !== 0 || !body.data) {
      logWarn(`[LiveApi] 流地址API错误: ${body.message}`);
      return null;
    }

    const d = body.data;
    let playUrl = '';
    let hlsUrl = '';
    if (d?.durl && d.durl.length > 0) {
      logInfo(`[LiveApi] 旧API返回${d.durl.length}个流地址`);
      for (const item of d.durl) {
        const url = item.url || '';
        logInfo(`[LiveApi]   流[order=${item.order}]: ${url.substring(0, 80)}...`);
        if (url.includes('.m3u8') || url.includes('m3u8')) {
          hlsUrl = url;
          break;
        }
        if (!playUrl) {
          playUrl = url;
        }
      }
    }

    // 如果durl中没有HLS，尝试在整个响应中搜索m3u8 URL（兼容响应格式变化）
    try {
      const rawStr = response.result as string;
      const m3u8Regex = /https?:\/\/[^"'\s]*?m3u8[^"'\s]*/gi;
      const matches = rawStr.match(m3u8Regex);
      if (matches && matches.length > 0) {
        const foundUrl = matches[0];
        // 只有当durl没找到HLS时，或找到的URL与现有playUrl不同时，才使用这个
        if (!hlsUrl) {
          hlsUrl = foundUrl;
          logInfo(`[LiveApi] 响应全文搜索到HLS: ${hlsUrl.substring(0, 80)}...`);
        }
      }
    } catch (_e) {}

    // 优先返回HLS
    if (hlsUrl) {
      playUrl = hlsUrl;
    }

    if (!playUrl) {
      return null;
    }

    logInfo(`[LiveApi] ✅ 获取到流地址: ${playUrl.substring(0, 80)}...`);
    const result: LiveStreamUrlResult = {
      url: playUrl,
      acceptQuality: d?.accept_quality ?? [80],
      currentQn: d?.current_qn ?? 80
    };
    return result;
  } catch (_e) {
    logError(`[LiveApi] tryFetchPlayUrl 异常: ${_e}`);
    return null;
  } finally {
    httpRequest.destroy();
  }
}

export const LIVE_QUALITY: LiveQualityMap = {
  ORIGINAL: 10000,  // 原画
  HIGH: 400,        // 蓝光
  MEDIUM: 250,      // 超清
  LOW: 150,         // 高清
  VERY_LOW: 80      // 流畅
};

export function getLiveQualityLabel(qn: number): string {
  switch (qn) {
    case LIVE_QUALITY.ORIGINAL: return '原画';
    case LIVE_QUALITY.HIGH: return '蓝光';
    case LIVE_QUALITY.MEDIUM: return '超清';
    case LIVE_QUALITY.LOW: return '高清';
    case LIVE_QUALITY.VERY_LOW: return '流畅';
    default: return `画质(${qn})`;
  }
}
