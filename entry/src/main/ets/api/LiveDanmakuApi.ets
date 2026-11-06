/**
 * LiveDanmakuApi.ets — 直播弹幕 token / 发送弹幕
 *
 * token:  GET {liveBaseUrl}/xlive/web-room/v1/index/getDanmuInfo?id=<roomId>&type=0&web_location=444.8（WBI 签名）
 * 发送:   POST {liveBaseUrl}/msg/send  (form-urlencoded, csrf=bili_jct)
 */
import { http } from '@kit.NetworkKit';
import { AppSign } from '../utils/SignUtils';
import { HttpConstants } from './HttpConstants';
import { extractCsrfFromCookie } from './FeedbackService';
import { logInfo, logWarn, logError } from '../utils/Logger';

export interface LiveDanmuHost {
  host: string;
  wssPort: number;
}

export interface LiveDanmuInfo {
  token: string;
  hosts: LiveDanmuHost[];
}

export interface LiveSendResult {
  ok: boolean;
  code: number;
  message: string;
}

interface RawHost {
  host: string;
  wss_port: number;
}

interface DanmuInfoData {
  token: string;
  host_list: RawHost[];
}

interface DanmuInfoResponse {
  code: number;
  message: string;
  data: DanmuInfoData;
}

interface SendResponse {
  code: number;
  message: string;
}

/**
 * ⭐ 与 BilibiliApi.getCookieHeader 保持同一套规则：
 *    - 只补合法的 buvid3，不伪造 buvid4/b_lsid
 *    - b_nut 固定为首次访问时间戳（逐次变化会让设备指纹漂移，触发风控）
 */
export function getLiveCookieString(): string {
  const cookie = AppStorage.get<string>('biliCookie') || '';
  let deviceId = AppStorage.get<string>('biliDeviceId');
  if (!deviceId) {
    deviceId = 'XY' + Math.random().toString(36).substring(2, 15) + Math.random().toString(36).substring(2, 15);
    AppStorage.setOrCreate('biliDeviceId', deviceId);
  }
  let header = cookie;
  if (deviceId) {
    header += (header ? '; ' : '') + `buvid3=${deviceId}`;
  }
  let bNut = AppStorage.get<number>('biliBNut');
  if (!bNut || bNut <= 0) {
    bNut = Math.floor(Date.now() / 1000);
    AppStorage.setOrCreate('biliBNut', bNut);
  }
  const extras = [
    `b_nut=${bNut}`,
    'i-wanna-go-back=-1',
    'nostalgia_conf=-1',
    'PVID=1',
    'browser_resolution=1920-1080',
    'innersign=0'
  ];
  header += (header ? '; ' : '') + extras.join('; ');
  return header;
}

/** 直播间弹幕服务器 token + host 列表 */
export async function getLiveDanmuInfo(roomId: number): Promise<LiveDanmuInfo | null> {
  const httpRequest = http.createHttp();
  try {
    const params: Record<string, string> = {
      'id': `${roomId}`,
      'type': '0',
      'web_location': '444.8'
    };
    let query: string = '';
    try {
      query = await AppSign.generateWebParams(params);
    } catch (e) {
      logWarn(`[LiveDanmakuApi] WBI 签名失败，回退无签名: ${e}`);
      query = `id=${roomId}&type=0`;
    }
    const url = `${HttpConstants.liveBaseUrl}/xlive/web-room/v1/index/getDanmuInfo?${query}`;
    logInfo(`[LiveDanmakuApi] 获取弹幕 token: room=${roomId}`);
    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': `https://live.bilibili.com/${roomId}`,
        'Origin': 'https://live.bilibili.com',
        'Cookie': getLiveCookieString()
      },
      connectTimeout: 10000,
      readTimeout: 10000
    });
    if (response.responseCode !== 200) {
      logError(`[LiveDanmakuApi] getDanmuInfo HTTP ${response.responseCode}`);
      return null;
    }
    const body = JSON.parse(response.result as string) as DanmuInfoResponse;
    if (body.code !== 0 || !body.data || !body.data.token) {
      logError(`[LiveDanmakuApi] getDanmuInfo code=${body.code} msg=${body.message}`);
      return null;
    }
    const hosts: LiveDanmuHost[] = [];
    const rawHosts = body.data.host_list ? body.data.host_list : [];
    for (let i = 0; i < rawHosts.length; i++) {
      const h = rawHosts[i];
      const port: number = h.wss_port > 0 ? h.wss_port : 443;
      hosts.push({ host: h.host, wssPort: port });
    }
    logInfo(`[LiveDanmakuApi] 弹幕 token 就绪: hosts=${hosts.length}`);
    return { token: body.data.token, hosts };
  } catch (e) {
    logError(`[LiveDanmakuApi] getDanmuInfo 异常: ${e}`);
    return null;
  } finally {
    httpRequest.destroy();
  }
}

/** 发送直播弹幕（需要登录 + bili_jct） */
export async function sendLiveDanmaku(roomId: number, msg: string, color: number = 16777215,
  mode: number = 1): Promise<LiveSendResult> {
  const cookie = getLiveCookieString();
  const csrf = extractCsrfFromCookie(cookie);
  if (!csrf) {
    return { ok: false, code: -1, message: '请先登录' };
  }
  const httpRequest = http.createHttp();
  try {
    const form = `roomid=${roomId}` +
      `&msg=${encodeURIComponent(msg)}` +
      `&color=${color}` +
      `&fontsize=25` +
      `&pool=0` +
      `&mode=${mode}` +
      `&rnd=${Math.floor(Date.now() / 1000)}` +
      `&csrf=${csrf}`;
    const response = await httpRequest.request(`${HttpConstants.liveBaseUrl}/msg/send`, {
      method: http.RequestMethod.POST,
      header: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': `https://live.bilibili.com/${roomId}`,
        'Origin': 'https://live.bilibili.com',
        'Cookie': cookie
      },
      extraData: form,
      connectTimeout: 10000,
      readTimeout: 10000
    });
    if (response.responseCode !== 200) {
      return { ok: false, code: -1, message: `HTTP ${response.responseCode}` };
    }
    const body = JSON.parse(response.result as string) as SendResponse;
    if (body.code === 0) {
      logInfo(`[LiveDanmakuApi] 弹幕发送成功: room=${roomId}`);
      return { ok: true, code: 0, message: 'ok' };
    }
    logWarn(`[LiveDanmakuApi] 弹幕发送失败: code=${body.code} msg=${body.message}`);
    return { ok: false, code: body.code, message: body.message || '发送失败' };
  } catch (e) {
    logError(`[LiveDanmakuApi] 发送弹幕异常: ${e}`);
    return { ok: false, code: -1, message: '发送异常' };
  } finally {
    httpRequest.destroy();
  }
}
