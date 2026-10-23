/**
 * 用户行为上报服务
 * 用于向B站推荐系统反馈用户行为，优化推荐结果
 * 
 * ⭐ 这是实现个性化推荐的关键！
 * B站推荐算法依赖用户行为数据来优化推荐内容
 * 
 * 实现的API：
 * 1. 观看心跳 - /x/report/web/heartbeat（影响推荐权重最大）
 * 2. 互动上报 - 点赞、投币、收藏、分享
 * 3. 推荐反馈 - 不感兴趣、屏蔽UP主
 */
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { RecommendItem } from '../model/RecommendItem';
import { extractMidFromCookie, extractCsrfFromCookie, getBiliHeaders } from '../api/FeedbackService';
import { AppSign, WbiSign } from '../utils/SignUtils';
import { refreshAccessKeyFromCookie } from '../api/BilibiliApi';
import { MIN_HEARTBEAT_PROGRESS_SEC } from '../model/WatchHistoryHelper';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

// ========== 类型定义 ==========

export interface WatchBehavior {
  bvid: string;
  cid: number;
  duration: number;      // 视频总时长（秒）
  watchTime: number;     // 实际观看时长（秒）
  progress: number;      // 观看进度 (0-100)
}

export interface InteractionBehavior {
  bvid: string;
  aid?: number;  // 视频的数字ID（收藏API需要）
  multiply?: number;  // 投币数量（投币专用）
  type: 'like' | 'coin' | 'favorite' | 'share' | 'triple';
  action: 'add' | 'cancel';
}

export interface FeedbackBehavior {
  bvid: string;
  reason: 'not_interested' | 'seen_before' | 'block_uploader' | 'inappropriate';
  uploaderMid?: string;
  tagName?: string;
}

// 内部接口定义
interface WatchReportData {
  bvid: string;
  cid: number;
  mid: string;
  duration: number;
  watch_time: number;
  progress: number;
  ts: number;
  is_finish: number;
  is_effective: number;
  watch_type: string;
}

interface InteractionReportData {
  bvid: string;
  mid: string;
  type: string;
  action: string;
  ts: number;
}

interface FeedbackReportData {
  goto: string;
  id: string;
  mid: string;
  reason: string;
  rmid: string;
  tag_name: string;
  ts: number;
}

// ⭐ 内部方法参数接口（替代内联对象类型）
interface HeartbeatParams {
  bvid: string;
  cid: number;
  csrf: string;
  played_time: number;
  type: number;  // 3=普通视频, 4=课程等
}

interface InteractionReportParams {
  bvid: string;
  aid?: number;  // 视频的数字ID（收藏API需要）
  multiply?: number;  // 投币数量
  mid: string;
  csrf: string;
  type: string;
  action: string;
}

interface FeedbackReportParams {
  bvid: string;
  mid: string;
  csrf: string;
  reason: string;
  uploaderMid?: string;
}

/**
 * ⭐ 辅助函数：构建 URL 编码字符串
 * 替代 URLSearchParams（鸿蒙不支持）
 */
function buildUrlEncoded(params: Record<string, string>): string {
  const parts: string[] = [];
  const keys = Object.keys(params);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const value = params[key];
    parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
  }
  return parts.join('&');
}

/**
 * 构建增强的 Cookie 头（追加设备标识 cookie 绕开风控）
 * B站 API 的风控系统依赖 buvid3/b_nut/b_lsid 等设备标识，仅靠登录 cookie 会被判为"账号异常"
 */
function buildEnhancedCookie(): string {
  const rawCookie = AppStorage.get<string>('biliCookie') || '';
  
  // 获取或生成持久设备 ID（与 BilibiliApi.ets 的 getDeviceId 逻辑一致）
  let deviceId = AppStorage.get<string>('biliDeviceId');
  if (!deviceId) {
    // ⭐ 生成标准格式的 buvid3：{8位hex}-{4位hex}-{4位hex}-{4位hex}-{12位hex}infoc
    const hex = (len: number): string => {
      let s = '';
      for (let i = 0; i < len; i++) {
        s += Math.floor(Math.random() * 16).toString(16);
      }
      return s;
    };
    deviceId = `${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}infoc`;
    AppStorage.setOrCreate('biliDeviceId', deviceId);
  }
  
  // 生成合理的 cookie 值，避免 WAF 识别到 "undefined" 字面串
  const fpSuffix = Math.floor(Math.random() * 1000000).toString(36);
  
  // 补充 B站 风控所需的设备标识 cookie
  const parts: string[] = [];
  if (rawCookie) {
    parts.push(rawCookie);
  }
  parts.push('buvid3=' + deviceId);
  parts.push('buvid4=' + deviceId + fpSuffix);
  parts.push('b_nut=100');
  parts.push('i-wanna-go-back=-1');
  parts.push('nostalgia_conf=-1');
  parts.push('b_lsid=' + fpSuffix + '_' + Math.floor(Date.now() / 1000));
  parts.push('PVID=1');
  parts.push('browser_resolution=1920-1080');
  parts.push('innersign=0');
  parts.push('buvid_fp=' + deviceId);
  parts.push('buvid_fp_plain=' + deviceId);

  return parts.join('; ');
}

/**
 * 获取设备ID（与 BilibiliApi.ets 共享同一个 AppStorage 键）
 */
function getDeviceId(): string {
  let deviceId = AppStorage.get<string>('biliDeviceId');
  if (!deviceId) {
    const hex = (len: number): string => {
      let s = '';
      for (let i = 0; i < len; i++) {
        s += Math.floor(Math.random() * 16).toString(16);
      }
      return s;
    };
    deviceId = `${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}infoc`;
    AppStorage.setOrCreate('biliDeviceId', deviceId);
  }
  return deviceId;
}

/**
 * 生成 TraceId（用于移动端 API 请求头）
 */
function generateTraceId(): string {
  const timestamp = Date.now().toString(16);
  const random = Math.random().toString(16).substring(2, 10);
  return `${timestamp}:${random}:0:0`;
}

export class UserBehaviorService {
  
  // ========== 观看行为上报 ==========
  
  /**
   * 上报视频播放行为
   * ⭐ 这是最重要的行为数据，直接影响推荐
   * 
   * @param params 观看行为参数
   */
  static async reportWatchBehavior(params: WatchBehavior): Promise<void> {
    try {
      // ⭐ 使用增强Cookie（含buvid3等设备标识），避免WAF拦截
      const cookie = buildEnhancedCookie();
      const mid = extractMidFromCookie(cookie);
      const csrf = extractCsrfFromCookie(cookie);
      
      // 判断观看质量
      const isEffective = params.progress >= 30;  // 观看30%以上算有效观看
      const isFinished = params.progress >= 90;   // 观看90%以上算看完
      
      // 构建上报数据
      const reportData: WatchReportData = {
        bvid: params.bvid,
        cid: params.cid,
        mid: mid,
        duration: params.duration,
        watch_time: params.watchTime,
        progress: params.progress,
        ts: Math.floor(Date.now() / 1000),
        
        // ⭐ 关键指标
        is_finish: isFinished ? 1 : 0,
        is_effective: isEffective ? 1 : 0,
        watch_type: isFinished ? 'finish' : (isEffective ? 'effective' : 'quick')
      };
      
      logInfo(`[行为上报] 观看: ${params.bvid}, 进度=${params.progress}%, 时长=${params.watchTime}s, 类型=${reportData.watch_type}`);
      
      // ⭐ 调用B站真实的心跳上报API（参考 bilibili-API-collect 规范）
      const heartbeatParams: HeartbeatParams = {
        bvid: params.bvid,
        cid: params.cid,
        csrf: csrf,
        played_time: Math.floor(params.watchTime),
        type: 3  // 普通视频
      };
      const success = await UserBehaviorService.sendWatchHeartbeat(heartbeatParams);
      
      if (success) {
        logInfo(`[行为上报] ✅ 心跳上报成功: ${params.bvid}`);
      } else {
        logWarn(`[行为上报] ⚠️ 心跳上报失败，已本地记录`);
      }
      
      // 本地记录（用于调试和离线缓存）
      UserBehaviorService.saveLocalBehavior('watch', reportData);
      
    } catch (err) {
      logError(`观看行为上报失败: ${err}`);
    }
  }
  
  /**
   * ⭐ 发送观看心跳到B站服务器
   * 使用 /x/click-interface/web/heartbeat 端点（bilibili-API-collect 规范）
   * 这是影响推荐算法最关键的API
   */
  private static async sendWatchHeartbeat(params: HeartbeatParams): Promise<boolean> {
    // ⭐ 近 0 秒不上报：本方法打的是 /x/click-interface/web/heartbeat（与历史进度同一接口），
    //   played_time 会**直接覆盖**该视频已有的观看进度。快速划过/打开即退出时 played_time 为 0，
    //   照发就会把"原本看过几分钟"的那个视频抹成 0%（B 站侧实测同样会落库，不是静默忽略）。
    if (params.played_time < MIN_HEARTBEAT_PROGRESS_SEC) {
      logInfo(`[行为上报] 进度仅 ${params.played_time}s（<${MIN_HEARTBEAT_PROGRESS_SEC}s），`
        + `跳过心跳以免覆盖已有进度: ${params.bvid}`);
      return false;
    }
    try {
      const httpRequest = http.createHttp();
      // ⭐ 使用增强Cookie（含buvid3等设备标识），避免WAF拦截
      const cookie = buildEnhancedCookie();

      // ⭐ 构造心跳参数（参考 PiliPlus / bilibili-API-collect）
      // csrf 仅登录用户有，匿名用户不发送
      const heartbeatData: Record<string, string> = {
        'bvid': params.bvid,
        'cid': String(params.cid),
        'played_time': String(params.played_time),
        'type': String(params.type)
      };
      if (params.csrf) {
        heartbeatData['csrf'] = params.csrf;
      }

      const response = await httpRequest.request(
        'https://api.bilibili.com/x/click-interface/web/heartbeat',
        {
          method: http.RequestMethod.POST,
          header: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Referer': `https://www.bilibili.com/video/${params.bvid}`,
            'Cookie': cookie
          },
          extraData: buildUrlEncoded(heartbeatData),
          connectTimeout: 10000,
          readTimeout: 10000
        }
      );

      httpRequest.destroy();

      if (response.responseCode === 200) {
        const json = JSON.parse(response.result as string) as Record<string, Object>;
        if (json['code'] === 0) {
          return true;
        } else {
          logWarn(`[心跳] 返回错误: code=${json['code']}, msg=${json['message']}`);
          return false;
        }
      }

      return false;
    } catch (err) {
      logError(`[心跳] 请求异常: ${err}`);
      return false;
    }
  }
  
  /**
   * 批量上报观看历史
   * 用于应用启动时同步观看历史
   */
  static async reportWatchHistory(historyList: WatchBehavior[]): Promise<void> {
    try {
      logInfo(`[行为上报] 批量上报观看历史: ${historyList.length} 条`);
      
      for (const item of historyList) {
        await UserBehaviorService.reportWatchBehavior(item);
        // 避免请求过快
        await new Promise<void>(resolve => setTimeout(resolve, 100));
      }
      
    } catch (err) {
      logError(`批量上报失败: ${err}`);
    }
  }
  
  // ========== 互动行为上报 ==========
  
  /**
   * 上报互动行为（点赞、投币、收藏、分享）
   * ⭐ 这些行为权重很高，显著影响推荐
   */
  static async reportInteraction(params: InteractionBehavior): Promise<boolean> {
    try {
      const cookie = AppStorage.get<string>('biliCookie') || '';
      const mid = extractMidFromCookie(cookie);
      const csrf = extractCsrfFromCookie(cookie);
      
      const reportData: InteractionReportData = {
        bvid: params.bvid,
        mid: mid,
        type: params.type,
        action: params.action,
        ts: Math.floor(Date.now() / 1000)
      };
      
      logInfo(`[行为上报] 互动: ${params.bvid}, 类型=${params.type}, 操作=${params.action}`);
      
      // ⭐ 调用B站真实的互动上报API
      const interactionParams: InteractionReportParams = {
        bvid: params.bvid,
        aid: params.aid,  // 传递aid用于收藏API
        multiply: params.multiply,  // 投币数量
        mid: mid,
        csrf: csrf,
        type: params.type,
        action: params.action
      };
      const success = await UserBehaviorService.sendInteractionReport(interactionParams);
      
      if (success) {
        logInfo(`[行为上报] ✅ 互动上报成功: ${params.type} ${params.action}`);
      } else {
        logWarn(`[行为上报] ⚠️ 互动上报失败`);
      }
      
      UserBehaviorService.saveLocalBehavior('interaction', reportData);
      return success;
      
    } catch (err) {
      logError(`互动行为上报失败: ${err}`);
      return false;
    }
  }
  
  /**
   * ⭐ 发送互动行为到B站服务器
   * 点赞/投币使用移动端API（带app签名），收藏使用Web API
   */
  private static async sendInteractionReport(params: InteractionReportParams): Promise<boolean> {
    if (!params.csrf || params.mid === '0') {
      logWarn('[互动] 未登录，跳过上报');
      return false;
    }
    
    // ===== 共享变量 =====
    const cookie = buildEnhancedCookie();
    const deviceId = getDeviceId();
    
    try {
      let webParams: Record<string, string> = {};
      let useApp = false;
      let appUrl = '';
      let appBody = '';

      // 获取移动端 access_key
      let accessKey = AppStorage.get<string>('biliAccessKey') || '';
      if (!accessKey) {
        logInfo('[互动] 未找到 access_key，尝试从Cookie会话获取...');
        const refreshedKey = await refreshAccessKeyFromCookie();
        if (refreshedKey) {
          accessKey = refreshedKey;
          logInfo(`[互动] ✅ 成功获取 access_key: ${accessKey.substring(0, 10)}...`);
        } else {
          logInfo('[互动] 无法获取 access_key，将使用 Web API');
        }
      }

      switch (params.type) {
        case 'like': {
          if (accessKey) {
            useApp = true;
            const appParams: Record<string, string> = {
              'aid': String(params.aid ?? 0),
              'like': params.action === 'add' ? '1' : '2',
              'access_key': accessKey,
              'ts': Math.floor(Date.now() / 1000).toString()
            };
            await AppSign.signParams(appParams, 'android_hd');
            appUrl = 'https://app.bilibili.com/x/v2/view/like';
            appBody = buildUrlEncoded(appParams);
            logInfo('[点赞] 使用 App API (app.bilibili.com)');
          } else {
            webParams = {
              'aid': String(params.aid ?? 0),
              'bvid': params.bvid,
              'like': params.action === 'add' ? '1' : '2',
              'csrf': params.csrf
            };
            logInfo('[点赞] 无access_key，使用 Web API + WBI签名');
          }
          break;
        }
          
        case 'coin': {
          if (!params.aid) {
            logWarn('[投币] 缺少aid参数');
            return false;
          }
          if (accessKey) {
            useApp = true;
            const appParams: Record<string, string> = {
              'aid': String(params.aid),
              'multiply': String(params.multiply ?? 1),
              'select_like': '0',
              'access_key': accessKey,
              'ts': Math.floor(Date.now() / 1000).toString()
            };
            await AppSign.signParams(appParams, 'android_hd');
            appUrl = 'https://app.bilibili.com/x/v2/view/coin/add';
            appBody = buildUrlEncoded(appParams);
            logInfo('[投币] 使用 App API (app.bilibili.com)');
          } else {
            webParams = {
              'aid': String(params.aid),
              'multiply': String(params.multiply ?? 1),
              'select_like': '0',
              'csrf': params.csrf
            };
            logInfo('[投币] 无access_key，使用 Web API + WBI签名（可能触发风控）');
          }
          break;
        }
          
        case 'favorite': {
          if (!params.aid) {
            logWarn('[收藏] 缺少aid参数，无法收藏');
            return false;
          }
          const defaultFid = await UserBehaviorService.getDefaultFavoriteFolder(params.mid, cookie);
          if (!defaultFid) {
            logWarn('[收藏] 获取收藏夹失败，用户可能还没有创建收藏夹');
            logWarn('[收藏] 请在B站网页或APP中先创建一个收藏夹');
            return false;
          }
          if (params.action === 'add') {
            webParams = {
              'rid': String(params.aid),
              'type': '2',
              'add_media_ids': String(defaultFid),
              'csrf': params.csrf
            };
          } else {
            webParams = {
              'rid': String(params.aid),
              'type': '2',
              'del_media_ids': String(defaultFid),
              'csrf': params.csrf
            };
          }
          logInfo(`[收藏] 使用rid=${params.aid}, fid=${defaultFid}, action=${params.action}`);
          break;
        }
          
        case 'triple': {
          if (!params.aid) {
            logWarn('[三连] 缺少aid参数');
            return false;
          }
          const defaultFid = await UserBehaviorService.getDefaultFavoriteFolder(params.mid, cookie);
          webParams = {
            'aid': String(params.aid),
            'eab_x': '2',
            'ramval': '0',
            'source': 'web_normal',
            'ga': '1',
            'csrf': params.csrf,
            'spmid': '333.788.0.0',
            'statistics': '{"appId":100,"platform":5}'
          };
          if (defaultFid) {
            webParams['add_media_ids'] = String(defaultFid);
          }
          logInfo('[三连] 使用 Web API triple');
          break;
        }
          
        case 'share':
          logInfo('[分享] 分享行为已记录');
          return true;
          
        default:
          logWarn(`[互动] 未知的互动类型: ${params.type}`);
          return false;
      }

      // ===== App API 请求（like/coin走app.bilibili.com） =====
      if (useApp) {
        const appHeaders: Record<string, string> = {
          'User-Agent': 'Mozilla/5.0 BiliDroid/7.67.0 (bbcallen@gmail.com) os/android model/ONEPLUS A6000 mobi_app/android build/6740300 channel/bili',
          'Content-Type': 'application/x-www-form-urlencoded',
          'env': 'prod',
          'app-key': 'android64',
          'x-bili-aurora-zone': 'sh001',
          'x-bili-mid': params.mid,
          'Referer': `https://www.bilibili.com/video/${params.bvid}`,
          'Accept': 'application/json, text/plain, */*'
        };
        
        logInfo(`[互动] 调用App API(POST): ${appUrl}`);
        const httpRequest = http.createHttp();
        const response = await httpRequest.request(appUrl, {
          method: http.RequestMethod.POST,
          header: appHeaders,
          extraData: appBody,
          connectTimeout: 10000,
          readTimeout: 10000
        });
        httpRequest.destroy();
        
        if (response.responseCode === 200) {
          const json = JSON.parse(response.result as string) as Record<string, Object>;
          if (json['code'] === 0) {
            logInfo(`[互动] ✅ ${params.type}成功`);
            return true;
          } else {
            logWarn(`[互动] ⚠️ ${params.type}失败: code=${json['code']}, msg=${json['message']}`);
            logWarn(`[互动] 完整响应: ${response.result?.toString().substring(0, 300)}`);
            if (params.type === 'like' || params.type === 'coin') {
              logInfo(`[互动] App API失败，回退到Web API`);
            } else {
              return false;
            }
          }
        } else {
          logWarn(`[互动] HTTP错误: ${response.responseCode}`);
          if (params.type === 'like' || params.type === 'coin') {
            logInfo(`[互动] App API不可用，回退到Web API`);
          } else {
            return false;
          }
        }
        
        // 回退：准备Web API参数
        if (params.type === 'like') {
          webParams = {
            'aid': String(params.aid ?? 0),
            'bvid': params.bvid,
            'like': params.action === 'add' ? '1' : '2',
            'csrf': params.csrf
          };
        } else if (params.type === 'coin') {
          webParams = {
            'aid': String(params.aid!),
            'multiply': String(params.multiply ?? 1),
            'select_like': '0',
            'csrf': params.csrf
          };
        } else {
          return false;
        }
      }
      
      // ===== 确定Web API URL =====
      let webApiUrl = '';
      if (params.type === 'like') {
        webApiUrl = 'https://api.bilibili.com/x/web-interface/archive/like';
      } else if (params.type === 'coin') {
        webApiUrl = 'https://api.bilibili.com/x/web-interface/coin/add';
      } else if (params.type === 'favorite') {
        webApiUrl = 'https://api.bilibili.com/x/v3/fav/resource/deal';
      } else if (params.type === 'triple') {
        webApiUrl = 'https://api.bilibili.com/x/web-interface/archive/like/triple';
      }
      
      // ===== WBI签名（like/coin/triple需要） =====
      if (params.type === 'like' || params.type === 'coin' || params.type === 'triple') {
        try {
          const wbiKeys = await WbiSign.getWbiKeys();
          const wbiResult = await WbiSign.sign(webParams, wbiKeys.img_key, wbiKeys.sub_key);
          webParams['w_rid'] = wbiResult.w_rid;
          webParams['wts'] = wbiResult.wts;
          logInfo(`[互动] WBI签名: w_rid=${wbiResult.w_rid.substring(0, 8)}..., wts=${wbiResult.wts}`);
        } catch (e) {
          logWarn(`[互动] WBI签名失败，继续无签名请求: ${e}`);
        }
      }
      
      // ===== 发送Web API请求 =====
      logInfo(`[互动] 调用Web API: ${webApiUrl}`);
      const webHeaders: Record<string, string> = {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
        'Referer': `https://www.bilibili.com/video/${params.bvid}`,
        'Origin': 'https://www.bilibili.com',
        'Cookie': cookie,
        'X-Bili-Mid': params.mid,
        'X-Bili-Device-Id': deviceId,
        'X-Bili-Trace-Id': generateTraceId(),
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
      };
      const httpRequest2 = http.createHttp();
      const response = await httpRequest2.request(
        webApiUrl,
        {
          method: http.RequestMethod.POST,
          header: webHeaders,
          extraData: buildUrlEncoded(webParams),
          connectTimeout: 10000,
          readTimeout: 10000
        }
      );
      httpRequest2.destroy();
      
      if (response.responseCode === 200) {
        const json = JSON.parse(response.result as string) as Record<string, Object>;
        if (json['code'] === 0) {
          logInfo(`[互动] ✅ ${params.type}成功`);
          return true;
        } else {
          logWarn(`[互动] ⚠️ ${params.type}失败: code=${json['code']}, msg=${json['message']}`);
          logWarn(`[互动] 完整响应: ${response.result?.toString().substring(0, 300)}`);
          return false;
        }
      }
      logWarn(`[互动] HTTP错误: ${response.responseCode}`);
      return false;
      
    } catch (err) {
      logError(`[互动] 请求异常: ${err}`);
      return false;
    }
  }
  
  /**
   * 获取默认收藏夹ID
   */
  private static async getDefaultFavoriteFolder(mid: string, cookie: string): Promise<number | null> {
    try {
      const httpRequest = http.createHttp();
      // ⭐ 使用正确的收藏夹列表API（v3版本）
      const response = await httpRequest.request(
        `https://api.bilibili.com/x/v3/fav/folder/created/list-all?up_mid=${mid}&pn=1&ps=10`,
        {
          method: http.RequestMethod.GET,
          header: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
            'Referer': 'https://www.bilibili.com/',
            'Cookie': cookie,
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
          },
          connectTimeout: 10000,
          readTimeout: 10000
        }
      );
      
      httpRequest.destroy();
      
      if (response.responseCode === 200) {
        const json = JSON.parse(response.result as string) as Record<string, Object>;
        if (json['code'] === 0 && json['data']) {
          const data = json['data'] as Record<string, Object>;
          // v3 API返回的是 { list: [...] } 或直接是数组
          let list: Array<Record<string, Object>> | undefined;
          if (Array.isArray(data)) {
            list = data as Array<Record<string, Object>>;
          } else if (data['list']) {
            list = data['list'] as Array<Record<string, Object>>;
          }
          
          if (list && list.length > 0) {
            // 返回第一个收藏夹的ID（默认收藏夹）
            const fid = list[0]['id'] as number;
            logInfo(`[收藏夹] 获取成功: fid=${fid}, 名称=${list[0]['title']}`);
            return fid;
          } else {
            logWarn('[收藏夹] 收藏夹列表为空，用户可能还没有创建收藏夹');
          }
        } else {
          logWarn(`[收藏夹] API返回错误: code=${json['code']}, msg=${json['message']}`);
        }
      } else {
        logWarn(`[收藏夹] HTTP错误: ${response.responseCode}`);
      }
      
      return null;
    } catch (err) {
      logError(`[收藏夹] 获取失败: ${err}`);
      return null;
    }
  }
  
  // ========== 推荐反馈 ==========
  
  /**
   * 上报推荐反馈（不感兴趣、屏蔽等）
   * ⭐ 负反馈对推荐优化很重要
   */
  static async reportFeedback(params: FeedbackBehavior): Promise<void> {
    try {
      const cookie = AppStorage.get<string>('biliCookie') || '';
      const mid = extractMidFromCookie(cookie);
      const csrf = extractCsrfFromCookie(cookie);
      
      logInfo(`[反馈上报] ${params.bvid}, 原因=${params.reason}, UP主=${params.uploaderMid || '无'}`);
      
      // ⭐ 调用B站真实的推荐反馈API
      const feedbackParams: FeedbackReportParams = {
        bvid: params.bvid,
        mid: mid,
        csrf: csrf,
        reason: params.reason,
        uploaderMid: params.uploaderMid
      };
      const success = await UserBehaviorService.sendFeedbackReport(feedbackParams);
      
      if (success) {
        logInfo(`[反馈上报] ✅ 反馈上报成功`);
      } else {
        logWarn(`[反馈上报] ⚠️ 反馈上报失败`);
      }
      
      // 本地记录（用于调试）
      const localFeedbackData: FeedbackReportData = {
        goto: 'av',
        id: params.bvid,
        mid: mid,
        reason: UserBehaviorService.mapReason(params.reason),
        rmid: params.uploaderMid || '',
        tag_name: params.tagName || '',
        ts: Math.floor(Date.now() / 1000)
      };
      UserBehaviorService.saveLocalBehavior('feedback', localFeedbackData);
      
      // 本地记录屏蔽的UP主
      if (params.reason === 'block_uploader' && params.uploaderMid) {
        UserBehaviorService.addBlockedUploader(params.uploaderMid);
      }
      
    } catch (err) {
      logError(`反馈上报失败: ${err}`);
    }
  }
  
  /**
   * ⭐ 发送推荐反馈到B站服务器
   * 使用官方推荐反馈接口
   */
  private static async sendFeedbackReport(params: FeedbackReportParams): Promise<boolean> {
    if (!params.csrf || params.mid === '0') {
      logWarn('[反馈] 未登录，跳过上报');
      return false;
    }
    
    try {
      const cookie = AppStorage.get<string>('biliCookie') || '';
      
      // ⭐ 尝试获取 access_key（移动端 API 凭证）
      let accessKey = AppStorage.get<string>('biliAccessKey') || '';
      if (!accessKey) {
        logInfo('[反馈] 未找到 access_key，尝试从 Cookie 刷新...');
        const refreshedKey = await refreshAccessKeyFromCookie();
        if (refreshedKey) {
          accessKey = refreshedKey;
          AppStorage.setOrCreate('biliAccessKey', accessKey);
          logInfo(`[反馈] ✅ 成功获取 access_key: ${accessKey.substring(0, 10)}...`);
        } else {
          logWarn('[反馈] 无法获取 access_key');
        }
      }
      
      // ====== 方案 A：移动端 API（app.bilibili.com/x/feed/dislike） ======
      if (accessKey) {
        try {
          const queryParams: Record<string, string> = {
            'access_key': accessKey,
            'goto': 'av',
            'id': params.bvid,
            'mid': params.mid,
            'reason_id': UserBehaviorService.mapReason(params.reason),
            'platform': 'android'
          };
          
          // 如果是屏蔽UP主，添加rmid
          if (params.uploaderMid) {
            queryParams['rmid'] = params.uploaderMid;
          }
          
          const queryString = Object.keys(queryParams).map(
            (key: string): string => `${encodeURIComponent(key)}=${encodeURIComponent(queryParams[key])}`
          ).join('&');
          
          const url = `https://app.bilibili.com/x/feed/dislike?${queryString}`;
          
          const httpRequest = http.createHttp();
          const response = await httpRequest.request(
            url,
            {
              method: http.RequestMethod.GET,
              header: {
                'User-Agent': 'Mozilla/5.0 BiliDroid/7.67.0 (bbcallen@gmail.com) os/android model/ONEPLUS A6000 mobi_app/android build/6740300 channel/bili',
                'Referer': 'https://www.bilibili.com/',
              },
              connectTimeout: 10000,
              readTimeout: 10000
            }
          );
          
          httpRequest.destroy();
          
          if (response.responseCode === 200) {
            const resultStr: string = response.result as string;
            logInfo(`[反馈] 移动端 API 响应: ${resultStr}`);
            const json = JSON.parse(resultStr) as Record<string, Object>;
            if (json['code'] === 0) {
              logInfo(`[反馈] ✅ 移动端反馈成功`);
              return true;
            } else {
              logWarn(`[反馈] 移动端反馈失败: code=${json['code']}, msg=${json['message']}`);
              // fallthrough 到 Web API
            }
          } else {
            logWarn(`[反馈] 移动端 API HTTP 错误: ${response.responseCode}`);
            // fallthrough
          }
        } catch (err) {
          logError(`[反馈] 移动端 API 异常: ${err}`);
          // fallthrough
        }
      }
      
      // ====== 方案 B：Web API（备用） ======
      const httpRequest = http.createHttp();
      
      // 构建反馈数据
      const feedbackData: Record<string, string> = {
        'goto': 'av',
        'id': params.bvid,
        'mid': params.mid,
        'reason': UserBehaviorService.mapReason(params.reason),
        'csrf': params.csrf,
        'platform': 'web'
      };
      
      // 如果是屏蔽UP主，添加rmid参数
      if (params.uploaderMid) {
        feedbackData['rmid'] = params.uploaderMid;
      }
      
      // B站推荐反馈接口
      const response = await httpRequest.request(
        'https://api.bilibili.com/x/web-interface/index/feed-back',
        {
          method: http.RequestMethod.POST,
          header: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Referer': 'https://www.bilibili.com/',
            'Cookie': cookie,
            'X-Bili-Mid': params.mid
          },
          extraData: buildUrlEncoded(feedbackData),
          connectTimeout: 10000,
          readTimeout: 10000
        }
      );
      
      httpRequest.destroy();
      
      if (response.responseCode === 200) {
        const json = JSON.parse(response.result as string) as Record<string, Object>;
        if (json['code'] === 0) {
          return true;
        } else {
          logWarn(`[反馈] Web API 返回错误: code=${json['code']}, msg=${json['message']}`);
          return false;
        }
      }
      
      logWarn(`[反馈] Web API HTTP 错误: ${response.responseCode}`);
      return false;
    } catch (err) {
      logError(`[反馈] 请求异常: ${err}`);
      return false;
    }
  }
  
  // ========== 本地过滤管理 ==========
  
  /**
   * 添加已观看视频
   */
  static addWatchedVideo(bvid: string): void {
    let watched = AppStorage.get<Set<string>>('watchedVideos') || new Set<string>();
    watched.add(bvid);
    
    // 限制大小，防止内存过大
    if (watched.size > 1000) {
      const arr = Array.from(watched);
      watched = new Set(arr.slice(-1000));
    }
    
    AppStorage.setOrCreate('watchedVideos', watched);
  }
  
  /**
   * 检查是否已观看
   */
  static isWatched(bvid: string): boolean {
    const watched = AppStorage.get<Set<string>>('watchedVideos') || new Set<string>();
    return watched.has(bvid);
  }
  
  /**
   * 添加屏蔽UP主
   * ⭐ 同时保存到持久化存储
   */
  static addBlockedUploader(mid: string): void {
    let blocked = AppStorage.get<Set<string>>('blockedUploaders') || new Set<string>();
    blocked.add(mid);
    AppStorage.setOrCreate('blockedUploaders', blocked);
    logInfo(`[屏蔽] 已屏蔽UP主: ${mid}`);
    
    // ⭐ 异步保存到持久化存储
    UserBehaviorService.saveBlockedUploaders();
  }
  
  /**
   * ⭐ 保存屏蔽UP主列表到持久化存储
   */
  static async saveBlockedUploaders(): Promise<void> {
    try {
      const blocked = AppStorage.get<Set<string>>('blockedUploaders') || new Set<string>();
      const blockedArray = Array.from(blocked);
      const context = AppStorage.get<common.UIAbilityContext>('appContext');
      if (!context) {
        logWarn('[屏蔽] 无法获取context，跳过保存');
        return;
      }
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('blockedUploaders', JSON.stringify(blockedArray));
      await pref.flush();
      logInfo(`[屏蔽] 已保存 ${blockedArray.length} 个屏蔽UP主到持久化存储`);
    } catch (err) {
      logError(`[屏蔽] 保存失败: ${err}`);
    }
  }
  
  /**
   * 移除屏蔽UP主
   */
  static removeBlockedUploader(mid: string): void {
    let blocked = AppStorage.get<Set<string>>('blockedUploaders') || new Set<string>();
    blocked.delete(mid);
    AppStorage.setOrCreate('blockedUploaders', blocked);
    logInfo(`[屏蔽] 已取消屏蔽UP主: ${mid}`);
    UserBehaviorService.saveBlockedUploaders();
  }

  /**
   * ⭐ 从持久化存储加载屏蔽UP主列表（应用启动时调用）
   */
  static async loadBlockedUploaders(): Promise<void> {
    try {
      const context = AppStorage.get<common.UIAbilityContext>('appContext');
      if (!context) {
        logWarn('[屏蔽] 无法获取context，跳过加载');
        return;
      }
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      const stored = await pref.get('blockedUploaders', '') as string;
      if (stored) {
        const blockedArray: string[] = JSON.parse(stored) as string[];
        const blocked = new Set<string>(blockedArray);
        AppStorage.setOrCreate('blockedUploaders', blocked);
        logInfo(`[屏蔽] 已从持久化存储加载 ${blocked.size} 个屏蔽UP主`);
      } else {
        logInfo('[屏蔽] 持久化存储中无屏蔽UP主数据');
      }
    } catch (err) {
      logError(`[屏蔽] 加载失败: ${err}`);
    }
  }
  
  /**
   * 检查UP主是否被屏蔽
   */
  static isBlockedUploader(mid: string): boolean {
    const blocked = AppStorage.get<Set<string>>('blockedUploaders') || new Set<string>();
    return blocked.has(mid);
  }
  
  /**
   * 仅过滤屏蔽UP主（不过滤已观看）
   * ⭐ DiscoverPage 使用此方法，只屏蔽UP主，不屏蔽已看视频
   */
  static filterBlockedUploadersOnly(items: RecommendItem[]): RecommendItem[] {
    const originalCount = items.length;
    let blockedFiltered = 0;

    const result = items.filter((item: RecommendItem): boolean => {
      // 只过滤屏蔽UP主，不过滤已观看
      if (item.ownerMid && UserBehaviorService.isBlockedUploader(item.ownerMid)) {
        blockedFiltered++;
        logInfo(`[本地屏蔽] 过滤掉屏蔽UP主的视频: ${item.title?.substring(0, 20)}... (mid: ${item.ownerMid})`);
        return false;
      }

      return true;
    });

    if (blockedFiltered > 0) {
      logInfo(`[本地过滤] 原始${originalCount}条 → 过滤屏蔽UP主${blockedFiltered}条 → 剩余${result.length}条`);
    }

    return result;
  }

  /**
   * 过滤推荐列表
   * 移除已观看和屏蔽的视频
   * ⭐ 添加详细日志便于调试
   */
  static filterRecommendList(items: RecommendItem[]): RecommendItem[] {
    const originalCount = items.length;
    let watchedFiltered = 0;
    let blockedFiltered = 0;
    
    const result = items.filter((item: RecommendItem): boolean => {
      // 过滤已观看
      if (UserBehaviorService.isWatched(item.id)) {
        watchedFiltered++;
        return false;
      }
      
      // 过滤屏蔽UP主
      if (item.ownerMid && UserBehaviorService.isBlockedUploader(item.ownerMid)) {
        blockedFiltered++;
        logInfo(`[本地屏蔽] 过滤掉屏蔽UP主的视频: ${item.title?.substring(0, 20)}... (mid: ${item.ownerMid})`);
        return false;
      }
      
      return true;
    });
    
    // 输出过滤统计
    if (watchedFiltered > 0 || blockedFiltered > 0) {
      logInfo(`[本地过滤] 原始${originalCount}条 → 过滤已观看${watchedFiltered}条、屏蔽UP主${blockedFiltered}条 → 剩余${result.length}条`);
    }
    
    return result;
  }
  
  // ========== 辅助方法 ==========
  
  private static mapReason(reason: string): string {
    const reasonMap: Record<string, string> = {
      'not_interested': '1',
      'seen_before': '2',
      'block_uploader': '3',
      'inappropriate': '4'
    };
    return reasonMap[reason] || '1';
  }
  
  private static saveLocalBehavior(type: string, data: Object): void {
    try {
      const key = `behavior_${type}_${Date.now()}`;
      // 简单的本地记录，用于调试
      logInfo(`[本地记录] ${key}: ${JSON.stringify(data)}`);
    } catch (err) {
      logError(`本地记录失败: ${err}`);
    }
  }
}

// ========== 导出便捷方法 ==========

/**
 * 上报观看行为
 */
export async function reportWatch(bvid: string, cid: number, duration: number, watchTime: number): Promise<void> {
  const progress = duration > 0 ? Math.floor((watchTime / duration) * 100) : 0;
  await UserBehaviorService.reportWatchBehavior({
    bvid,
    cid,
    duration,
    watchTime,
    progress
  });
  
  // 标记为已观看
  UserBehaviorService.addWatchedVideo(bvid);
}

/**
 * 上报点赞
 */
export async function reportLike(bvid: string, aid: number, isLike: boolean): Promise<void> {
  await UserBehaviorService.reportInteraction({
    bvid,
    aid,
    type: 'like',
    action: isLike ? 'add' : 'cancel'
  });
}

/**
 * 上报投币
 */
export async function reportCoin(bvid: string, aid: number, isCoin: boolean, multiply: number = 1): Promise<void> {
  await UserBehaviorService.reportInteraction({
    bvid,
    aid,
    multiply,
    type: 'coin',
    action: isCoin ? 'add' : 'cancel'
  });
}

/**
 * 上报收藏
 */
export async function reportFavorite(bvid: string, isFavorite: boolean): Promise<void> {
  await UserBehaviorService.reportInteraction({
    bvid,
    type: 'favorite',
    action: isFavorite ? 'add' : 'cancel'
  });
}

/**
 * 上报分享
 */
export async function reportShare(bvid: string): Promise<void> {
  await UserBehaviorService.reportInteraction({
    bvid,
    type: 'share',
    action: 'add'
  });
}

/**
 * 上报不感兴趣
 */
export async function reportNotInterested(bvid: string, uploaderMid?: string): Promise<void> {
  await UserBehaviorService.reportFeedback({
    bvid,
    reason: 'not_interested',
    uploaderMid
  });
}

/**
 * 上报屏蔽UP主
 */
export async function reportBlockUploader(bvid: string, uploaderMid: string): Promise<void> {
  await UserBehaviorService.reportFeedback({
    bvid,
    reason: 'block_uploader',
    uploaderMid
  });
}
