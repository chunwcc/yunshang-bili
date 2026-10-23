// BilibiliHistoryApi.ets - B站历史记录API服务
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { HistoryItem, HistoryListResponse, HistoryData } from '../model/WatchHistoryItem';
import { extractCsrfFromCookie } from './FeedbackService';

/**
 * B站API通用响应结构
 */
interface BiliApiResponse {
  code: number;
  message: string;
  ttl?: number;
}

/**
 * ⭐ 观看进度上报的可选项（番剧/影视/课程）
 */
export interface WatchProgressOptions {
  /** 业务类型：3=投稿视频（默认）, 4=番剧/影视, 10=课程 */
  type?: number;
  /** 番剧分集 id（type=4 时用于把进度归到具体某一集） */
  epid?: number;
  /** 番剧季 id */
  sid?: number;
  /** 投稿 bvid（与 aid 二选一，优先 bvid） */
  bvid?: string;
  /** CSRF token（bili_jct）；不传则从 cookie 自动提取 */
  csrf?: string;
}

/**
 * B站历史记录API服务类
 * 负责与B站服务器交互，管理观看历史记录
 */
export class BilibiliHistoryApi {
  private static instance: BilibiliHistoryApi;
  private baseUrl: string = 'https://api.bilibili.com';

  static getInstance(): BilibiliHistoryApi {
    if (!BilibiliHistoryApi.instance) {
      BilibiliHistoryApi.instance = new BilibiliHistoryApi();
    }
    return BilibiliHistoryApi.instance;
  }

  /**
   * 获取观看历史列表
   * @param max 最大历史ID（用于分页，首次请求传0或不传）
   * @param ps 每页数量，默认30
   * @param cookie 用户Cookie（必须包含SESSDATA）
   */
  async getHistoryList(max: number = 0, ps: number = 30, cookie: string): Promise<HistoryItem[]> {
    const httpRequest = http.createHttp();
    
    try {
      // ⭐ 恢复 /x/v2/history 接口（用户验证记录显示正常）。
      //   cursor 接口（/x/web-interface/history/cursor）在本项目环境返回 code=-400 请求错误（缺 PiliPlusX 的
      //   额外 Cookie/UA 封装，无法复现其可用性），且 /x/web-interface/history 无 cursor 后缀会 404——均不可用
      let url = `${this.baseUrl}/x/v2/history?ps=${ps}`;
      if (max > 0) {
        url += `&max=${max}`;
      }

      logInfo('[BilibiliHistory] 请求历史列表:', url);

      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/',
          'Cookie': cookie
        },
        connectTimeout: 10000,
        readTimeout: 10000
      });

      if (response.responseCode !== 200) {
        logError('[BilibiliHistory] 请求失败:', response.responseCode);
        return [];
      }

      const result = JSON.parse(response.result as string) as HistoryListResponse;
      
      // 调试：打印完整响应
      logInfo('[BilibiliHistory] API响应 code:', result.code, ', message:', result.message);
      logInfo('[BilibiliHistory] data类型:', typeof result.data, ', data:', JSON.stringify(result.data)?.substring(0, 500));
      
      if (result.code !== 0) {
        logError('[BilibiliHistory] API返回错误:', result.message);
        return [];
      }

      // B站API返回格式：data可能是数组，也可能包含list字段
      let historyList: HistoryItem[] = [];
      if (Array.isArray(result.data)) {
        historyList = result.data as HistoryItem[];
      } else if (result.data && (result.data as HistoryData).list) {
        historyList = (result.data as HistoryData).list || [];
      }

      // ⭐ 字段布局守卫：progress/duration 必须在【顶层】、cid 必须在【顶层】。
      //   实测 /x/v2/history 的记录里**根本没有 history 对象**（cid/business/type/kid/bangumi 都在顶层），
      //   所以"进度只能定位到集、定位不到时间"就是这类层级错位导致的。B 站若再调整字段布局，
      //   这里会留下明确告警，不必再靠猜。正常情况静默。
      for (let i = 0; i < historyList.length; i++) {
        const it: HistoryItem = historyList[i];
        if (it.progress === undefined && it.history?.progress !== undefined) {
          logWarn(`[BilibiliHistory] 字段布局异常#${i}: progress 出现在 history 内而非顶层，进度会丢失`);
        }
        const biz: string = it.business ?? it.history?.business ?? '';
        if ((biz === 'archive' || biz === 'pgc') && (it.cid ?? 0) <= 0) {
          logWarn(`[BilibiliHistory] 字段布局异常#${i}: ${biz} 记录缺少顶层 cid，cid 会取错`);
        }
        if (biz === 'pgc' && (it.bangumi?.ep_id ?? 0) <= 0) {
          logWarn(`[BilibiliHistory] 字段布局异常#${i}: pgc 记录缺少 bangumi.ep_id，epId 需靠 bvid 反查`);
        }
      }

      logInfo('[BilibiliHistory] 获取到历史记录:', historyList.length, '条');
      return historyList;

    } catch (error) {
      logError('[BilibiliHistory] 获取历史列表异常:', JSON.stringify(error));
      return [];
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 删除单条历史记录
   * @param aid 视频aid（不是bvid）
   * @param cookie 用户Cookie
   */
  async deleteHistoryItem(aid: number, cookie: string): Promise<boolean> {
    const httpRequest = http.createHttp();
    
    try {
      const url = `${this.baseUrl}/x/v2/history/delete`;
      
      logInfo('[BilibiliHistory] 删除历史记录, aid:', aid);

      const response = await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/',
          'Cookie': cookie,
          'Content-Type': 'application/x-www-form-urlencoded'
        },
        extraData: `aid=${aid}`,
        connectTimeout: 10000,
        readTimeout: 10000
      });

      if (response.responseCode !== 200) {
        logError('[BilibiliHistory] 删除失败:', response.responseCode);
        return false;
      }

      const result = JSON.parse(response.result as string) as BiliApiResponse;
      const success = result.code === 0;
      
      if (success) {
        logInfo('[BilibiliHistory] 删除成功');
      } else {
        logError('[BilibiliHistory] 删除失败:', result.message);
      }
      
      return success;

    } catch (error) {
      logError('[BilibiliHistory] 删除历史记录异常:', JSON.stringify(error));
      return false;
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 清空所有历史记录
   * @param cookie 用户Cookie
   */
  async clearAllHistory(cookie: string): Promise<boolean> {
    const httpRequest = http.createHttp();
    
    try {
      const url = `${this.baseUrl}/x/v2/history/clear`;
      
      logInfo('[BilibiliHistory] 清空所有历史记录');

      const response = await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/',
          'Cookie': cookie,
          'Content-Type': 'application/x-www-form-urlencoded'
        },
        connectTimeout: 10000,
        readTimeout: 10000
      });

      if (response.responseCode !== 200) {
        logError('[BilibiliHistory] 清空失败:', response.responseCode);
        return false;
      }

      const result = JSON.parse(response.result as string) as BiliApiResponse;
      const success = result.code === 0;
      
      if (success) {
        logInfo('[BilibiliHistory] 清空成功');
      } else {
        logError('[BilibiliHistory] 清空失败:', result.message);
      }
      
      return success;

    } catch (error) {
      logError('[BilibiliHistory] 清空历史记录异常:', JSON.stringify(error));
      return false;
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 上报观看进度（心跳）
   * ⭐ 端点 /x/click-interface/web/heartbeat：B 站 Web 播放器与 PiliPlusX 同源，UGC / 番剧（PGC）通用
   *
   * 旧实现打的是 /x/report/web/heartbeat 且参数为 `aid&cid&progress&realtime&type=3&dt=2&play_type=1`：
   *   - **缺 csrf（bili_jct）** → B 站写接口会拒绝（-111），进度根本没落库
   *   - 番剧恒按 type=3 上报且不带 epid/sid → 即使落库也归不到分集
   *
   * @param aid 分集/稿件 aid
   * @param cid 视频 cid
   * @param progress 播放进度（秒）
   * @param cookie 用户 Cookie（需含 SESSDATA，登录用户还应含 bili_jct）
   * @param options 番剧（PGC）/课程参数：type（3=投稿 4=番剧 10=课程）、epid、sid、bvid
   */
  async reportWatchProgress(aid: number, cid: number, progress: number, cookie: string,
    options?: WatchProgressOptions): Promise<boolean> {
    const httpRequest = http.createHttp();
    
    try {
      const url = `${this.baseUrl}/x/click-interface/web/heartbeat`;
      const type: number = options?.type ?? 3;
      const epid: number = options?.epid ?? 0;
      const sid: number = options?.sid ?? 0;
      const csrf: string = options?.csrf || extractCsrfFromCookie(cookie);
      if (!csrf) {
        logWarn('[BilibiliHistory] Cookie 缺少 bili_jct（csrf），B 站可能拒绝写入进度');
      }

      // ⭐⭐ 番剧/影视（type=4）必须带 sid（季 id）：
      //   实测（真机 Cookie 对拍）——缺 sid 时 B 站返回 code=0【假成功】，但云端 progress 保持 0，
      //   即心跳被静默丢弃；补上 sid 后立即落库。sid 传 season_id 或 media_id 都能落库（只要非 0）。
      //   所以这里宁可不上报并大声报错，也不要发一个注定被丢掉、却让上层以为成功的请求。
      if (type === 4 && (sid <= 0 || epid <= 0)) {
        logError(`[BilibiliHistory] PGC 心跳缺少 ${sid <= 0 ? 'sid' : 'epid'}（sid=${sid}, epid=${epid}），`
          + `B 站会静默丢弃该进度，已跳过上报`);
        return false;
      }
      // ⭐ played_time 必须是整数：B 站按整型解析，浮点串（如 346.53）有被当成 0 的风险
      const playedTime: number = Math.max(0, Math.floor(progress));

      // 手动构建表单体（ArkTS 不支持 URLSearchParams）
      const parts: string[] = [];
      if (aid > 0) {
        parts.push(`aid=${aid}`);
      }
      if (options?.bvid) {
        parts.push(`bvid=${encodeURIComponent(options.bvid)}`);
      }
      parts.push(`cid=${cid}`);
      parts.push(`played_time=${playedTime}`);
      parts.push(`type=${type}`);
      if (epid > 0) {
        parts.push(`epid=${epid}`);
      }
      if (sid > 0) {
        parts.push(`sid=${sid}`);
      }
      if (csrf) {
        parts.push(`csrf=${csrf}`);
      }
      const params = parts.join('&');

      const response = await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/',
          'Cookie': cookie,
          'Content-Type': 'application/x-www-form-urlencoded'
        },
        extraData: params,
        connectTimeout: 5000,
        readTimeout: 5000
      });

      let success = false;
      if (response.responseCode === 200) {
        const result = JSON.parse(response.result as string) as BiliApiResponse;
        success = result.code === 0;
        if (success) {
          logInfo(`[BilibiliHistory] 上报观看进度成功, aid=${aid}, cid=${cid}, type=${type}, `
            + `epid=${epid}, sid=${sid}, played_time=${playedTime}s`);
        } else {
          logWarn(`[BilibiliHistory] 上报观看进度被拒: code=${result.code}, message=${result.message}`);
        }
      } else {
        logError(`[BilibiliHistory] 上报观看进度 HTTP 错误: ${response.responseCode}`);
      }
      
      return success;

    } catch (error) {
      logError('[BilibiliHistory] 上报观看进度异常:', JSON.stringify(error));
      return false;
    } finally {
      httpRequest.destroy();
    }
  }
}
