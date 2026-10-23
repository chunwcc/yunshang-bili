// WatchHistoryHelper.ets - 观看历史管理类（调用B站API）
import { BilibiliHistoryApi } from '../api/BilibiliHistoryApi';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { WatchHistoryItem, HistoryItem } from '../model/WatchHistoryItem';
import { common } from '@kit.AbilityKit';

/**
 * ⭐ B 站心跳（`/x/click-interface/web/heartbeat`）允许的**最小有效进度**（秒）。
 * 偏低一律视为"还没真正看过"，任何上报路径都不得发出。
 *
 * 为什么必须存在：这条心跳**既写历史进度、又用 `played_time` 直接覆盖**，而且
 * **同一部番剧（PGC）只保留一条历史记录**，记录的键就是 `kid` = 心跳里的 `sid`（= season_id），
 * 这一季里**任何一集**的心跳都会覆盖这唯一一条。实测（2026-09-14，真机 Cookie 对拍）：
 *   上报 `epid=733333, sid=28747, played_time=0` → 云端该季记录立刻变成 `ep=733333, progress=0`，
 *   连原先 `ep=733335, progress=354` 的续播点也查不到了（playurl 的
 *   `user_status.watch_progress` 回落成 0）。
 * 播放入口/切集瞬间进度会被播放器重置成 0（`floor(0.4) = 0`），若照发就会把记录清零——
 * 用户看到的现象正是"退出播放页后官方历史变成 0、再进去只能定位到集却定位不到时间"。
 *
 * UGC（type=3）同理：记录按视频独立，写 0 不会波及别的集，但会把**这个视频原本看过的进度抹成 0%**，
 * 所以阈值对 type=3 / type=4 一律生效。
 */
export const MIN_HEARTBEAT_PROGRESS_SEC: number = 5;

/**
 * 观看历史帮助类
 * 负责与B站服务器交互，管理观看历史记录
 * 注意：需要用户已登录（Cookie中包含SESSDATA）
 */
export class WatchHistoryHelper {
  private static instance: WatchHistoryHelper;
  private historyApi: BilibiliHistoryApi;
  private cookie: string = '';
  
  // 缓存历史记录列表（用于UI展示）
  private cachedHistory: WatchHistoryItem[] = [];
  private lastFetchTime: number = 0;
  private cacheExpireTime: number = 5 * 60 * 1000; // 缓存5分钟

  private constructor() {
    this.historyApi = BilibiliHistoryApi.getInstance();
  }

  static getInstance(): WatchHistoryHelper {
    if (!WatchHistoryHelper.instance) {
      WatchHistoryHelper.instance = new WatchHistoryHelper();
    }
    return WatchHistoryHelper.instance;
  }

  /**
   * 设置用户Cookie
   * 必须在调用其他方法前设置，否则API请求会失败
   * @param cookie 完整的Cookie字符串（必须包含SESSDATA）
   */
  setCookie(cookie: string): void {
    this.cookie = cookie;
    logInfo('[WatchHistory] Cookie已设置');
  }

  /**
   * 获取当前Cookie
   */
  getCookie(): string {
    return this.cookie;
  }

  /**
   * 初始化（兼容旧接口，现在不需要做任何操作）
   * @deprecated 不再需要初始化数据库
   */
  async init(context: common.Context): Promise<void> {
    logInfo('[WatchHistory] 使用B站API模式，无需初始化数据库');
    return Promise.resolve();
  }

  /**
   * 查询所有观看历史（从B站服务器获取）
   * @param limit 获取数量，默认100
   * @param forceRefresh 是否强制刷新（忽略缓存）
   */
  async queryAllHistory(limit: number = 100, forceRefresh: boolean = false): Promise<WatchHistoryItem[]> {
    // 检查缓存是否有效
    const now = Date.now();
    if (!forceRefresh && this.cachedHistory.length > 0 && (now - this.lastFetchTime) < this.cacheExpireTime) {
      logInfo('[WatchHistory] 使用缓存的历史记录');
      return this.cachedHistory.slice(0, limit);
    }

    if (!this.cookie) {
      logError('[WatchHistory] Cookie未设置，无法获取历史记录');
      return [];
    }

    try {
      logInfo('[WatchHistory] 从B站服务器获取历史记录...');
      
      // 调用B站API获取历史记录
      const historyItems = await this.historyApi.getHistoryList(0, limit, this.cookie);
      
      // 转换为本地展示模型
      this.cachedHistory = historyItems.map((item: HistoryItem, index: number) => {
        const watchItem = WatchHistoryItem.fromBilibiliHistory(item);
        watchItem.id = index + 1; // 为UI列表分配临时ID
        // ⭐ 补 PGC epId：B 站 v2 历史接口的 PGC 记录无 epId，用本地保存的 aid→epId 映射补齐
        //   （否则 PGC 记录被当 UGC 播放 -404；本地播放番剧时 saveWatchHistory 已存映射）
        if (watchItem.epId <= 0 && watchItem.aid > 0) {
          const epMapRaw: string = AppStorage.get<string>('pgcEpIdMap') || '{}';
          try {
            const epMap = JSON.parse(epMapRaw) as Record<string, number>;
            const mappedEp: number = epMap[`${watchItem.aid}`] ?? 0;
            if (mappedEp > 0) {
              watchItem.epId = mappedEp;
              watchItem.bvid = '';  // PGC 记录 bvid 无效，清空避免被当 UGC
              logInfo(`[WatchHistory] 补 PGC epId: aid=${watchItem.aid} → epId=${mappedEp}`);
            }
          } catch (e) {
            // 映射解析失败，忽略（保持原记录）
          }
        }
        return watchItem;
      });
      
      this.lastFetchTime = now;
      
      logInfo('[WatchHistory] 获取到', this.cachedHistory.length, '条历史记录');
      return this.cachedHistory;
      
    } catch (error) {
      logError('[WatchHistory] 获取历史记录失败:', JSON.stringify(error));
      return [];
    }
  }

  /**
   * 删除单条历史记录
   * @param aid 视频aid（注意：不是本地ID）
   */
  async deleteRecord(aid: number): Promise<boolean> {
    if (!this.cookie) {
      logError('[WatchHistory] Cookie未设置，无法删除历史记录');
      return false;
    }

    try {
      const success = await this.historyApi.deleteHistoryItem(aid, this.cookie);
      
      if (success) {
        // 从缓存中移除
        this.cachedHistory = this.cachedHistory.filter(item => item.aid !== aid);
        logInfo('[WatchHistory] 本地缓存已更新');
      }
      
      return success;
      
    } catch (error) {
      logError('[WatchHistory] 删除历史记录失败:', JSON.stringify(error));
      return false;
    }
  }

  /**
   * 批量删除历史记录
   * @param aids 视频aid数组
   */
  async deleteRecords(aids: number[]): Promise<boolean> {
    if (!this.cookie) {
      logError('[WatchHistory] Cookie未设置，无法删除历史记录');
      return false;
    }

    try {
      let allSuccess = true;
      for (const aid of aids) {
        const success = await this.historyApi.deleteHistoryItem(aid, this.cookie);
        if (!success) {
          allSuccess = false;
        }
      }
      
      if (allSuccess) {
        // 从缓存中移除
        this.cachedHistory = this.cachedHistory.filter(item => !aids.includes(item.aid));
        logInfo('[WatchHistory] 批量删除成功，本地缓存已更新');
      }
      
      return allSuccess;
      
    } catch (error) {
      logError('[WatchHistory] 批量删除失败:', JSON.stringify(error));
      return false;
    }
  }

  /**
   * 清空所有观看历史
   */
  async clearAll(): Promise<boolean> {
    if (!this.cookie) {
      logError('[WatchHistory] Cookie未设置，无法清空历史记录');
      return false;
    }

    try {
      const success = await this.historyApi.clearAllHistory(this.cookie);
      
      if (success) {
        // 清空缓存
        this.cachedHistory = [];
        logInfo('[WatchHistory] 所有历史记录已清空');
      }
      
      return success;
      
    } catch (error) {
      logError('[WatchHistory] 清空历史记录失败:', JSON.stringify(error));
      return false;
    }
  }

  /**
   * 获取历史记录总数
   */
  async getCount(): Promise<number> {
    // 如果缓存有效，直接返回缓存数量
    const now = Date.now();
    if (this.cachedHistory.length > 0 && (now - this.lastFetchTime) < this.cacheExpireTime) {
      return this.cachedHistory.length;
    }
    
    // 否则重新获取
    const items = await this.queryAllHistory();
    return items.length;
  }

  /**
   * 保存观看记录（上报到B站服务器）
   * 注意：B站会自动记录观看历史，这里主要用于上报播放进度
   * @param item 观看记录项
   */
  async saveWatchRecord(item: WatchHistoryItem): Promise<void> {
    if (!this.cookie) {
      logWarn('[WatchHistory] Cookie未设置，无法上报观看进度');
      return;
    }

    if (!item.aid || !item.cid) {
      logWarn('[WatchHistory] aid或cid为空，无法上报观看进度');
      return;
    }

    try {
      // 上报观看进度到B站服务器
      // ⭐ 番剧/影视（PGC）：必须带 type=4 + epid + **sid**，否则进度归不到具体分集
      //   （现象就是"历史里能看到看过这一集，但位置丢失，重进从 0:00 开始"）
      //   ⚠️ 缺 sid 时 B 站返回 code=0【假成功】但云端 progress 不变，所以这里先拦一道
      const isPgc: boolean = item.epId > 0;
      if (isPgc && item.seasonId <= 0) {
        logError(`[WatchHistory] PGC 记录缺少 seasonId (epId=${item.epId})，`
          + `B 站会静默丢弃该进度，已中止上报`);
        return;
      }
      // ⭐ 最后一道闸：进度低于阈值绝不上报（type=4 会覆盖整季唯一那条记录，type=3 会抹掉该视频原有进度）
      if (item.playProgress < MIN_HEARTBEAT_PROGRESS_SEC) {
        logInfo(`[WatchHistory] 进度 ${item.playProgress}s < ${MIN_HEARTBEAT_PROGRESS_SEC}s，`
          + `跳过上报以保护已有进度 (${isPgc ? 'PGC' : 'UGC'}, aid=${item.aid})`);
        return;
      }
      await this.historyApi.reportWatchProgress(
        item.aid,
        item.cid,
        item.playProgress,
        this.cookie,
        {
          type: isPgc ? 4 : 3,
          epid: item.epId,
          sid: item.seasonId,
          bvid: isPgc ? '' : item.bvid
        }
      );
      
      logInfo(`[WatchHistory] 观看进度已上报 (${isPgc ? 'PGC' : 'UGC'}, ${item.playProgress}s`
        + `${isPgc ? `, epId=${item.epId}, seasonId=${item.seasonId}` : ''})`);

      // ⭐ PGC（番剧）记录：B 站 v2 历史接口的 PGC 记录无 epId（history.epid 缺失），
      //   但本地播放时知道 epId（saveWatchHistory 传 item.epId）——存入 aid→epId 映射，
      //   历史页加载云端记录时据此补 epId，否则 PGC 记录被当 UGC 播放 -404
      if (item.epId > 0 && item.aid > 0) {
        const epMapRaw: string = AppStorage.get<string>('pgcEpIdMap') || '{}';
        let epMap: Record<string, number> = {};
        try {
          epMap = JSON.parse(epMapRaw) as Record<string, number>;
        } catch (e) {
          epMap = {};
        }
        epMap[`${item.aid}`] = item.epId;
        AppStorage.set('pgcEpIdMap', JSON.stringify(epMap));
        logInfo(`[WatchHistory] 已记录 PGC epId 映射: aid=${item.aid} → epId=${item.epId}`);
      }

      // 清除缓存，下次获取时会从服务器重新拉取
      this.lastFetchTime = 0;
      
    } catch (error) {
      logError('[WatchHistory] 上报观看进度失败:', JSON.stringify(error));
    }
  }

  /**
   * 根据 bvid 查询单条记录（从缓存中查找）
   * @param bvid 视频bvid
   */
  queryByBvid(bvid: string): WatchHistoryItem | null {
    return this.cachedHistory.find(item => item.bvid === bvid) || null;
  }

  /**
   * 刷新历史记录（强制从服务器重新获取）
   */
  async refresh(): Promise<WatchHistoryItem[]> {
    logInfo('[WatchHistory] 刷新历史记录');
    return await this.queryAllHistory(100, true);
  }

  /**
   * 清除本地缓存
   */
  clearCache(): void {
    this.cachedHistory = [];
    this.lastFetchTime = 0;
    logInfo('[WatchHistory] 本地缓存已清除');
  }
}
