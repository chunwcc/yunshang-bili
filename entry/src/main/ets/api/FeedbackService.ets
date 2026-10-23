/**
 * B站用户反馈服务
 * 
 * 核心功能：
 * 1. X-Bili-Mid 请求头 - 用户身份识别
 * 2. 不感兴趣反馈 - 训练推荐模型
 * 3. CSRF Token 提取
 */
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { refreshAccessKeyFromCookie } from './BilibiliApi';

// ========== 类型定义 ==========

export interface FeedbackResult {
  success: boolean;
  message: string;
}

export interface DislikeReason {
  id: number;
  name: string;
}

// 预定义的不感兴趣原因
export const DISLIKE_REASONS: DislikeReason[] = [
  { id: 1, name: '不感兴趣' },
  { id: 2, name: '内容质量差' },
  { id: 3, name: '重复内容' },
  { id: 4, name: '封面与内容不符' },
  { id: 5, name: 'UP主不感兴趣' },
  { id: 6, name: '分区不感兴趣' }
];

// ========== 用户身份工具 ==========

/**
 * 从 Cookie 中提取 DedeUserID（用户 mid）
 * 格式: DedeUserID=123456789
 */
export function extractMidFromCookie(cookie: string): string {
  if (!cookie) return '0';
  
  // 匹配 DedeUserID=xxx
  const match = cookie.match(/DedeUserID=(\d+)/);
  if (match && match[1]) {
    return match[1];
  }
  
  return '0';
}

/**
 * 从 Cookie 中提取 CSRF Token（bili_jct）
 * 格式: bili_jct=xxxxxxxx
 */
export function extractCsrfFromCookie(cookie: string): string {
  if (!cookie) return '';
  
  // 匹配 bili_jct=xxx
  const match = cookie.match(/bili_jct=([a-f0-9]+)/);
  if (match && match[1]) {
    return match[1];
  }
  
  return '';
}

/**
 * 从 Cookie 中提取 SESSDATA
 */
export function extractSessdataFromCookie(cookie: string): string {
  if (!cookie) return '';
  
  const match = cookie.match(/SESSDATA=([^;]+)/);
  if (match && match[1]) {
    return match[1];
  }
  
  return '';
}

/**
 * 获取完整的请求头（包含用户身份）
 * ⭐ 关键：X-Bili-Mid 是服务器识别用户的关键
 */
export function getBiliHeaders(): Record<string, string> {
  const cookie = AppStorage.get<string>('biliCookie') || '';
  const mid = extractMidFromCookie(cookie);
  
  const headers: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36',
    'Referer': 'https://www.bilibili.com/',
    'Origin': 'https://www.bilibili.com',
    'Cookie': cookie
  };
  
  // ⭐ 关键：添加用户身份标识
  if (mid !== '0') {
    headers['X-Bili-Mid'] = mid;
    logInfo(`[BiliHeaders] 用户身份: mid=${mid}`);
  } else {
    logWarn('[BiliHeaders] 未检测到登录用户，推荐可能不精准');
  }
  
  return headers;
}

// ========== 用户反馈服务 ==========

export class FeedbackService {
  private static instance: FeedbackService | null = null;
  
  // 已反馈的视频缓存（避免重复提交）
  private feedbackCache: Set<string> = new Set();
  
  static getInstance(): FeedbackService {
    if (!FeedbackService.instance) {
      FeedbackService.instance = new FeedbackService();
    }
    return FeedbackService.instance;
  }
  
  /**
   * 提交"不感兴趣"反馈
   * ⭐ 这是训练推荐模型的关键数据
   * 
   * @param bvid 视频ID
   * @param reasonId 原因ID（1-6）
   */
  async sendDislike(bvid: string, reasonId: number = 1): Promise<FeedbackResult> {
    // 检查是否已反馈
    if (this.feedbackCache.has(bvid)) {
      return { success: true, message: '已反馈过' };
    }
    
    const cookie = AppStorage.get<string>('biliCookie') || '';
    const csrf = extractCsrfFromCookie(cookie);
    const mid = extractMidFromCookie(cookie);
    
    if (!csrf) {
      return { success: false, message: '未登录或缺少 CSRF Token' };
    }
    
    // ⭐ 尝试获取 access_key（移动端 API 凭证，B站已移除 Web 反馈接口）
    let accessKey = AppStorage.get<string>('biliAccessKey') || '';
    if (!accessKey) {
      logInfo('[Feedback] 未找到 access_key，尝试从 Cookie 刷新...');
      accessKey = await refreshAccessKeyFromCookie();
      if (accessKey) {
        AppStorage.setOrCreate('biliAccessKey', accessKey);
        logInfo(`[Feedback] ✅ 成功获取 access_key: ${accessKey.substring(0, 10)}...`);
      } else {
        logWarn('[Feedback] 无法获取 access_key，反馈将仅本地生效');
      }
    }
    
    // ====== 方案 A：移动端 API（app.bilibili.com/x/feed/dislike） ======
    if (accessKey) {
      try {
        logInfo(`[Feedback] 使用移动端 API 提交不感兴趣: bvid=${bvid}, reason=${reasonId}, mid=${mid}`);
        
        // 构建查询参数（无需 AppSign，该接口仅需 access_key）
        const queryParams: Record<string, string> = {
          'access_key': accessKey,
          'goto': 'av',
          'id': bvid,
          'mid': mid,
          'reason_id': String(reasonId),
          'platform': 'android'
        };
        
        // 如果是屏蔽UP主，添加rmid
        // reason_id=5 表示屏蔽UP主
        
        // 拼接 URL
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
          logInfo(`[Feedback] 移动端 API 响应: ${resultStr}`);
          const json = JSON.parse(resultStr) as Record<string, Object>;
          if (json['code'] === 0) {
            this.feedbackCache.add(bvid);
            logInfo(`[Feedback] ✅ 移动端反馈成功: ${bvid}`);
            return { success: true, message: '已减少此类推荐' };
          } else {
            logWarn(`[Feedback] 移动端反馈失败: code=${json['code']}, msg=${json['message']}`);
            // 返回 false，由调用方处理（仍会本地移除）
            return { success: false, message: `API 错误: ${json['message'] || json['code']}` };
          }
        } else {
          logWarn(`[Feedback] 移动端 API HTTP 错误: ${response.responseCode}`);
          // 不返回，继续走 Web 方案
        }
      } catch (err) {
        logError(`[Feedback] 移动端 API 异常: ${err}`);
        // fallthrough 到 Web 方案
      }
    }
    
    // ====== 方案 B：Web API（备用，使用GET + 查询参数） ======
    try {
      const httpRequest = http.createHttp();

      // ⭐ Web API 使用 GET 请求，参数通过 URL 查询字符串传递
      const queryParams: Record<string, string> = {
        'goto': 'av',
        'id': bvid,
        'mid': mid,
        'reason': String(reasonId),
        'csrf': csrf,
        'platform': 'web'
      };
      const queryString = Object.keys(queryParams).map(
        (key: string): string => `${encodeURIComponent(key)}=${encodeURIComponent(queryParams[key])}`
      ).join('&');
      const webUrl = `https://api.bilibili.com/x/web-interface/index/feed-back?${queryString}`;

      logInfo(`[Feedback] 使用 Web API 提交不感兴趣: bvid=${bvid}`);

      const response = await httpRequest.request(
        webUrl,
        {
          method: http.RequestMethod.GET,
          header: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Referer': 'https://www.bilibili.com/',
            'Cookie': cookie,
            'X-Bili-Mid': mid
          },
          connectTimeout: 10000,
          readTimeout: 10000
        }
      );
      
      httpRequest.destroy();
      
      if (response.responseCode === 200) {
        const json = JSON.parse(response.result as string) as Record<string, Object>;
        if (json['code'] === 0) {
          this.feedbackCache.add(bvid);
          logInfo(`[Feedback] ✅ Web 反馈成功: ${bvid}`);
          return { success: true, message: '已减少此类推荐' };
        } else {
          logWarn(`[Feedback] Web 反馈失败: code=${json['code']}, msg=${json['message']}`);
          return { success: false, message: `API 错误: ${json['message']}` };
        }
      }
      
      logWarn(`[Feedback] Web API HTTP 错误: ${response.responseCode}`);
      return { success: false, message: `HTTP ${response.responseCode}` };
      
    } catch (err) {
      logError(`[Feedback] Web API 异常: ${err}`);
      return { success: false, message: String(err) };
    }
  }
  
  /**
   * 提交"不感兴趣UP主"反馈
   * ⭐ 使用推荐反馈接口（与不感兴趣一致），带上 rmid 参数标识UP主
   * @param bvid 视频ID（该UP主的一个视频）
   * @param uploaderMid UP主的mid
   */
  async sendDislikeUp(bvid: string, uploaderMid: string): Promise<FeedbackResult> {
    const cookie = AppStorage.get<string>('biliCookie') || '';
    const csrf = extractCsrfFromCookie(cookie);
    const mid = extractMidFromCookie(cookie);
    
    if (!csrf) {
      return { success: false, message: '未登录或缺少 CSRF Token' };
    }
    
    // ⭐ 尝试获取 access_key（移动端 API 凭证）
    let accessKey = AppStorage.get<string>('biliAccessKey') || '';
    if (!accessKey) {
      logInfo('[Feedback] 未找到 access_key，尝试从 Cookie 刷新...');
      accessKey = await refreshAccessKeyFromCookie();
      if (accessKey) {
        AppStorage.setOrCreate('biliAccessKey', accessKey);
        logInfo(`[Feedback] ✅ 成功获取 access_key: ${accessKey.substring(0, 10)}...`);
      } else {
        logWarn('[Feedback] 无法获取 access_key，屏蔽UP主将仅本地生效');
      }
    }
    
    // ====== 方案 A：移动端 API ======
    if (accessKey) {
      try {
        logInfo(`[Feedback] 使用移动端 API 提交UP主不感兴趣: bvid=${bvid}, uploaderMid=${uploaderMid}, mid=${mid}`);
        
        const queryParams: Record<string, string> = {
          'access_key': accessKey,
          'goto': 'av',
          'id': bvid,
          'mid': mid,
          'reason_id': '5',        // reason=5 表示UP主不感兴趣
          'rmid': uploaderMid,      // 指定UP主
          'platform': 'android'
        };
        
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
          logInfo(`[Feedback] 移动端 API 响应: ${resultStr}`);
          const json = JSON.parse(resultStr) as Record<string, Object>;
          if (json['code'] === 0) {
            logInfo(`[Feedback] ✅ UP主不感兴趣反馈成功: ${uploaderMid}`);
            return { success: true, message: '已减少该UP主的推荐' };
          } else {
            logWarn(`[Feedback] UP主不感兴趣反馈失败: code=${json['code']}, msg=${json['message']}`);
            return { success: false, message: `API 错误: ${json['message'] || json['code']}` };
          }
        } else {
          logWarn(`[Feedback] 移动端 API HTTP 错误: ${response.responseCode}`);
          // fallthrough
        }
      } catch (err) {
        logError(`[Feedback] sendDislikeUp 移动端异常: ${err}`);
        // fallthrough
      }
    }
    
    // ====== 方案 B：Web API（备用，使用GET + 查询参数） ======
    try {
      const httpRequest = http.createHttp();
      
      // ⭐ Web API 使用 GET 请求
      const queryParamsUp: Record<string, string> = {
        'goto': 'av',
        'id': bvid,
        'mid': mid,
        'reason': '5',
        'rmid': uploaderMid,
        'csrf': csrf,
        'platform': 'web'
      };
      const queryStringUp = Object.keys(queryParamsUp).map(
        (key: string): string => `${encodeURIComponent(key)}=${encodeURIComponent(queryParamsUp[key])}`
      ).join('&');
      const webUrlUp = `https://api.bilibili.com/x/web-interface/index/feed-back?${queryStringUp}`;
      
      logInfo(`[Feedback] 使用 Web API 提交UP主不感兴趣: bvid=${bvid}`);
      
      const response = await httpRequest.request(
        webUrlUp,
        {
          method: http.RequestMethod.GET,
          header: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Referer': 'https://www.bilibili.com/',
            'Cookie': cookie,
            'X-Bili-Mid': mid
          },
          connectTimeout: 10000,
          readTimeout: 10000
        }
      );
      
      httpRequest.destroy();
      
      if (response.responseCode === 200) {
        const json = JSON.parse(response.result as string) as Record<string, Object>;
        if (json['code'] === 0) {
          logInfo(`[Feedback] ✅ Web 版UP主不感兴趣反馈成功: ${uploaderMid}`);
          return { success: true, message: '已减少该UP主的推荐' };
        } else {
          logWarn(`[Feedback] Web 版UP主不感兴趣反馈失败: code=${json['code']}, msg=${json['message']}`);
        }
      }
      
      return { success: false, message: '操作失败' };
      
    } catch (err) {
      logError(`[Feedback] sendDislikeUp Web 异常: ${err}`);
      return { success: false, message: String(err) };
    }
  }
  
  /**
   * 提交视频观看反馈（用于训练推荐模型）
   * 
   * @param bvid 视频ID
   * @param progress 观看进度（0-100）
   * @param duration 观看时长（秒）
   */
  async sendWatchFeedback(bvid: string, progress: number, duration: number): Promise<void> {
    const cookie = AppStorage.get<string>('biliCookie') || '';
    const mid = extractMidFromCookie(cookie);
    
    if (mid === '0') return;  // 未登录不发送
    
    try {
      // 观看进度反馈（可选）
      // 这个接口帮助推荐系统理解用户的观看偏好
      logInfo(`[Feedback] 观看反馈: bvid=${bvid}, progress=${progress}%, duration=${duration}s`);
      
      // 实际项目中可以调用相关接口上报观看行为
      
    } catch (err) {
      logError(`[Feedback] 观看反馈异常: ${err}`);
    }
  }
  
  /**
   * 清除反馈缓存
   */
  clearCache(): void {
    this.feedbackCache.clear();
  }
}

// ========== 便捷导出函数 ==========

/**
 * 提交UP主不感兴趣反馈
 */
export async function sendDislikeUpFeedback(bvid: string, mid: string): Promise<FeedbackResult> {
  return FeedbackService.getInstance().sendDislikeUp(bvid, mid);
}

/**
 * 提交不感兴趣反馈
 */
export async function sendDislikeFeedback(bvid: string, reasonId: number = 1): Promise<FeedbackResult> {
  return FeedbackService.getInstance().sendDislike(bvid, reasonId);
}
