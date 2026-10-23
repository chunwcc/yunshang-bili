/**
 * 推荐服务 - 管理 B站推荐 API 请求
 * 
 * 核心功能：
 * 1. fresh_idx 参数递增机制 - 解决刷新重复问题
 * 2. WBI 签名集成
 * 3. 本地过滤（已观看、黑名单等）
 * 4. 请求状态管理
 */
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { AppSign, WbiSign, WbiKeys } from '../utils/SignUtils';
import { RecommendItem } from '../model/RecommendItem';

// ========== 类型定义 ==========

export interface LoadingState<T> {
  state: 'loading' | 'success' | 'error' | 'empty';
  data?: T;
  message?: string;
}

export interface RecommendFilter {
  excludeBvids: Set<string>;      // 已观看的视频
  excludeMids: Set<string>;       // 黑名单用户
  minDuration?: number;           // 最小时长（秒）
  maxDuration?: number;           // 最大时长（秒）
  excludeKeywords: string[];      // 屏蔽关键词
}

interface RcmdVideoItem {
  id?: number;
  bvid?: string;
  title?: string;
  pic?: string;
  owner?: { mid?: number; name?: string; face?: string };
  stat?: { view?: number; like?: number; danmaku?: number };
  duration?: number;
  goto?: string;  // 'av' = 视频, 'live' = 直播, 'ad' = 广告
  uri?: string;
  cid?: number;
}

interface RcmdResponse {
  code: number;
  message?: string;
  data?: {
    item?: RcmdVideoItem[];
  };
}

// ========== 推荐服务类 ==========

export class RecommendService {
  // 单例实例
  private static instance: RecommendService | null = null;

  // ========== 核心状态 ==========
  
  /** 
   * fresh_idx - 刷新索引
   * ⭐ 这是解决"刷新重复"问题的关键参数
   * 每次刷新必须递增，B站服务端据此返回不同的推荐内容
   */
  private freshIdx: number = 1;
  
  /** 
   * brush - 刷次
   * 与 fresh_idx 同步递增
   */
  private brush: number = 1;
  
  /** 是否已初始化 */
  private initialized: boolean = false;
  
  /** 上次请求时间戳 */
  private lastRequestTime: number = 0;
  
  /** 请求间隔（毫秒）- 避免请求过快 */
  private readonly REQUEST_INTERVAL: number = 500;

  // ========== 过滤器 ==========
  
  private filter: RecommendFilter = {
    excludeBvids: new Set<string>(),
    excludeMids: new Set<string>(),
    excludeKeywords: []
  };

  // ========== 配置 ==========
  
  /** 每页数量 */
  private pageSize: number = 20;
  
  /** API 类型：'web' | 'app' */
  private apiType: 'web' | 'app' = 'web';

  // ========== 私有构造函数 ==========
  
  private constructor() {}

  // ========== 单例获取 ==========
  
  static getInstance(): RecommendService {
    if (!RecommendService.instance) {
      RecommendService.instance = new RecommendService();
    }
    return RecommendService.instance;
  }

  // ========== 初始化 ==========
  
  /**
   * 初始化推荐服务
   * @param pageSize 每页数量
   * @param apiType API 类型
   */
  async init(pageSize: number = 20, apiType: 'web' | 'app' = 'web'): Promise<void> {
    if (this.initialized) return;
    
    this.pageSize = pageSize;
    this.apiType = apiType;
    
    // 预热 WBI 密钥
    await WbiSign.getWbiKeys();
    
    this.initialized = true;
    logInfo(`[RecommendService] 初始化完成: pageSize=${pageSize}, apiType=${apiType}`);
  }

  // ========== fresh_idx 递增机制 ==========
  
  /**
   * 获取当前 fresh_idx
   */
  getFreshIdx(): number {
    return this.freshIdx;
  }
  
  /**
   * 重置 fresh_idx（用于强制刷新）
   */
  reset(): void {
    this.freshIdx = 1;
    this.brush = 1;
    logInfo('[RecommendService] fresh_idx 已重置');
  }
  
  /**
   * 递增 fresh_idx
   */
  private incrementIdx(): void {
    this.freshIdx++;
    this.brush++;
    logInfo(`[RecommendService] fresh_idx 递增至 ${this.freshIdx}`);
  }

  // ========== 过滤器管理 ==========
  
  /**
   * 添加已观看视频
   */
  addWatchedBvid(bvid: string): void {
    this.filter.excludeBvids.add(bvid);
  }
  
  /**
   * 批量添加已观看视频
   */
  addWatchedBvids(bvids: string[]): void {
    bvids.forEach(bvid => this.filter.excludeBvids.add(bvid));
  }
  
  /**
   * 添加黑名单用户
   */
  addBlockedMid(mid: string): void {
    this.filter.excludeMids.add(mid);
  }
  
  /**
   * 设置屏蔽关键词
   */
  setExcludeKeywords(keywords: string[]): void {
    this.filter.excludeKeywords = keywords;
  }
  
  /**
   * 设置时长过滤
   */
  setDurationFilter(min?: number, max?: number): void {
    this.filter.minDuration = min;
    this.filter.maxDuration = max;
  }

  // ========== 核心请求方法 ==========
  
  /**
   * 获取推荐视频列表
   * @param isRefresh 是否为刷新操作（刷新时递增 fresh_idx）
   */
  async getRecommendVideos(isRefresh: boolean = false): Promise<LoadingState<RecommendItem[]>> {
    // 等待请求间隔
    await this.waitForRequestInterval();
    
    // 刷新时递增 fresh_idx
    if (isRefresh) {
      this.incrementIdx();
    }
    
    try {
      logInfo(`[RecommendService] 请求推荐: fresh_idx=${this.freshIdx}, brush=${this.brush}`);
      
      // 构建请求参数
      const params = this.buildRequestParams();
      
      // 生成签名参数
      const queryStr = await AppSign.generateWebParams(params);
      
      // 发起请求
      const url = `https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd?${queryStr}`;
      const response = await this.fetchRcmd(url);
      
      if (response.state !== 'success' || !response.data) {
        return response;
      }
      
      // 本地过滤
      const filteredItems = this.filterVideos(response.data);
      
      // 更新请求时间
      this.lastRequestTime = Date.now();
      
      // 如果是加载更多（非刷新），递增索引
      if (!isRefresh) {
        this.incrementIdx();
      }
      
      return {
        state: filteredItems.length > 0 ? 'success' : 'empty',
        data: filteredItems
      };
      
    } catch (err) {
      logError(`[RecommendService] 请求异常: ${err}`);
      return {
        state: 'error',
        message: String(err)
      };
    }
  }
  
  /**
   * 构建请求参数
   * ⭐ 关键：fresh_idx 和 brush 必须同步递增
   */
  private buildRequestParams(): Record<string, string> {
    const params: Record<string, string> = {};
    
    // 基础参数
    params['ps'] = this.pageSize.toString();
    params['fresh_idx'] = this.freshIdx.toString();  // ⭐ 核心参数
    params['brush'] = this.brush.toString();         // ⭐ 与 fresh_idx 同步
    params['fresh_type'] = '4';                      // 刷新类型
    params['version'] = '1';
    params['feed_version'] = 'V8';
    params['homepage_ver'] = '1';
    params['web_location'] = '1433601';
    
    return params;
  }
  
  /**
   * 发起推荐请求
   */
  private async fetchRcmd(url: string): Promise<LoadingState<RecommendItem[]>> {
    const httpRequest = http.createHttp();
    
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36',
          'Referer': 'https://www.bilibili.com/',
          'Origin': 'https://www.bilibili.com',
          'Cookie': this.getCookieHeader()
        },
        connectTimeout: 10000,
        readTimeout: 10000
      });
      
      if (response.responseCode !== 200) {
        logError(`[RecommendService] HTTP 错误: ${response.responseCode}`);
        return { state: 'error', message: `HTTP ${response.responseCode}` };
      }
      
      const json: RcmdResponse = JSON.parse(response.result as string);
      
      if (json.code !== 0) {
        logWarn(`[RecommendService] API 错误: code=${json.code}, msg=${json.message}`);
        return { state: 'error', message: json.message || `API code ${json.code}` };
      }
      
      const items = json.data?.item || [];
      const result: RecommendItem[] = [];
      
      for (const item of items) {
        const recommendItem = this.parseRcmdItem(item);
        if (recommendItem) {
          result.push(recommendItem);
        }
      }
      
      logInfo(`[RecommendService] 获取到 ${result.length} 条推荐数据`);
      return { state: 'success', data: result };
      
    } finally {
      httpRequest.destroy();
    }
  }

  // ========== 数据解析 ==========
  
  /**
   * 解析推荐项
   */
  private parseRcmdItem(item: RcmdVideoItem): RecommendItem | null {
    // 过滤非视频内容
    if (item.goto === 'live' || item.goto === 'ad') {
      return null;
    }
    
    const bvid = item.bvid || '';
    if (!bvid) return null;
    
    return {
      id: bvid,
      title: item.title || '',
      coverUrl: item.pic || '',
      ownerName: item.owner?.name || '',
      ownerFace: item.owner?.face || '',
      playCount: item.stat?.view || 0,
      likeCount: item.stat?.like || 0,
      danmakuCount: item.stat?.danmaku || 0,
      duration: item.duration || 0,
      cid: item.cid || 0,
      mid: item.owner?.mid?.toString() || ''
    } as RecommendItem;
  }

  // ========== 本地过滤 ==========
  
  /**
   * 过滤视频列表
   */
  private filterVideos(items: RecommendItem[]): RecommendItem[] {
    return items.filter(item => {
      // 过滤已观看
      if (this.filter.excludeBvids.has(item.id)) {
        return false;
      }
      
      // 过滤黑名单用户
      if (item.mid && this.filter.excludeMids.has(item.mid)) {
        return false;
      }
      
      // 过滤时长
      if (this.filter.minDuration && item.duration < this.filter.minDuration) {
        return false;
      }
      if (this.filter.maxDuration && item.duration > this.filter.maxDuration) {
        return false;
      }
      
      // 过滤关键词
      if (this.filter.excludeKeywords.length > 0) {
        const title = item.title.toLowerCase();
        for (const keyword of this.filter.excludeKeywords) {
          if (title.includes(keyword.toLowerCase())) {
            return false;
          }
        }
      }
      
      return true;
    });
  }

  // ========== 工具方法 ==========
  
  /**
   * 等待请求间隔
   */
  private async waitForRequestInterval(): Promise<void> {
    const elapsed = Date.now() - this.lastRequestTime;
    if (elapsed < this.REQUEST_INTERVAL) {
      await new Promise<void>(resolve => 
        setTimeout(resolve, this.REQUEST_INTERVAL - elapsed)
      );
    }
  }
  
  /**
   * 获取 Cookie 头
   */
  private getCookieHeader(): string {
    const cookie = AppStorage.get<string>('biliCookie') || '';
    const deviceId = this.getOrCreateDeviceId();
    
    // ⚠️ 不要伪造 buvid4=undefined：B站 WAF 会判为异常设备（见 BilibiliApi.getCookieHeader 注释）
    const additionalCookies = [
      `buvid3=${deviceId}`,
      `b_nut=${Math.floor(Date.now() / 1000)}`,
      'i-wanna-go-back=-1',
      'nostalgia_conf=-1',
      'PVID=1',
      'browser_resolution=1920-1080'
    ];
    
    if (cookie) {
      return cookie + '; ' + additionalCookies.join('; ');
    }
    return additionalCookies.join('; ');
  }
  
  /**
   * 获取或创建设备 ID
   */
  private getOrCreateDeviceId(): string {
    let deviceId = AppStorage.get<string>('deviceId');
    if (!deviceId) {
      deviceId = this.generateDeviceId();
      AppStorage.setOrCreate('deviceId', deviceId);
    }
    return deviceId;
  }
  
  /**
   * 生成设备 ID
   */
  private generateDeviceId(): string {
    const chars = '0123456789abcdef';
    let id = '';
    for (let i = 0; i < 32; i++) {
      id += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return id;
  }
}

// ========== 导出单例便捷方法 ==========

/**
 * 获取推荐视频（刷新）
 */
export async function fetchRecommendRefresh(): Promise<LoadingState<RecommendItem[]>> {
  const service = RecommendService.getInstance();
  return service.getRecommendVideos(true);
}

/**
 * 获取推荐视频（加载更多）
 */
export async function fetchRecommendMore(): Promise<LoadingState<RecommendItem[]>> {
  const service = RecommendService.getInstance();
  return service.getRecommendVideos(false);
}

/**
 * 重置推荐服务
 */
export function resetRecommendService(): void {
  RecommendService.getInstance().reset();
}

/**
 * 添加已观看视频到过滤列表
 */
export function addWatchedVideo(bvid: string): void {
  RecommendService.getInstance().addWatchedBvid(bvid);
}
