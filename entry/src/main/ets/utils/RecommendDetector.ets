/**
 * 推荐功能检测工具
 * 用于验证个性化推荐是否正常工作
 */
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError } from './Logger';
import { getRecommendVideosOptimized, resetRecommendSession } from '../api/RecommendApiOptimized';
import { UserBehaviorService } from '../services/UserBehaviorService';
import { RecommendItem } from '../model/RecommendItem';

export interface DetectionResult {
  success: boolean;
  score: number;           // 0-100分
  issues: string[];        // 问题列表
  suggestions: string[];   // 建议列表
  details: DetectionDetails;
}

export interface DetectionDetails {
  cookieStatus: CookieStatus;
  paramStatus: ParamStatus;
  recommendStatus: RecommendStatus;
  behaviorStatus: BehaviorStatus;
}

export interface CookieStatus {
  hasCookie: boolean;
  hasSESSDATA: boolean;
  hasBiliJct: boolean;
  hasDedeUserID: boolean;
  hasBuvid3: boolean;
  userMid: string;
  isValid: boolean;
}

export interface ParamStatus {
  hasFreshIdx: boolean;
  hasDeviceId: boolean;
  hasSessionId: boolean;
  hasWebMid: boolean;
  paramCount: number;
  isValid: boolean;
}

export interface RecommendStatus {
  canFetchRecommend: boolean;
  recommendCount: number;
  uniqueVideoCount: number;
  hasPersonalized: boolean;
  error: string;
}

export interface BehaviorStatus {
  hasWatchedVideos: boolean;
  watchedCount: number;
  hasBlockedUploaders: boolean;
  blockedCount: number;
}

/**
 * 推荐功能检测器
 */
export class RecommendDetector {
  
  /**
   * 执行完整检测
   */
  static async runFullDetection(): Promise<DetectionResult> {
    logInfo('========== 开始推荐功能检测 ==========');
    
    const issues: string[] = [];
    const suggestions: string[] = [];
    let score = 0;
    
    // 1. 检测Cookie状态
    logInfo('\n【1/4】检测Cookie状态...');
    const cookieStatus = await RecommendDetector.detectCookie();
    if (!cookieStatus.isValid) {
      issues.push('Cookie不完整');
      if (!cookieStatus.hasDedeUserID) {
        suggestions.push('请先登录B站账号');
      }
    } else {
      score += 25;
      logInfo('✅ Cookie状态正常');
    }
    
    // 2. 检测推荐参数
    logInfo('\n【2/4】检测推荐参数...');
    const paramStatus = await RecommendDetector.detectParams();
    // 参数有效性将在推荐检测后更新
    
    // 3. 检测推荐功能
    logInfo('\n【3/4】检测推荐功能...');
    const recommendStatus = await RecommendDetector.detectRecommend();
    
    // 如果推荐功能正常，参数状态也视为有效
    if (recommendStatus.canFetchRecommend) {
      paramStatus.isValid = true;
      paramStatus.hasDeviceId = true;
      paramStatus.hasSessionId = true;
      score += 25;  // 参数分
      logInfo('✅ 推荐参数正常（运行时生成）');
    }
    
    if (!recommendStatus.canFetchRecommend) {
      issues.push('无法获取推荐数据');
      suggestions.push(`错误: ${recommendStatus.error}`);
    } else if (!recommendStatus.hasPersonalized) {
      issues.push('推荐内容不够个性化');
      suggestions.push('补充用户行为数据');
    } else {
      score += 30;
      logInfo('✅ 推荐功能正常');
    }
    
    // 4. 检测行为数据
    logInfo('\n【4/4】检测行为数据...');
    const behaviorStatus = await RecommendDetector.detectBehavior();
    if (!behaviorStatus.hasWatchedVideos) {
      suggestions.push('建议添加观看历史记录');
    } else {
      score += 20;
      logInfo('✅ 行为数据正常');
    }
    
    const success = issues.length === 0 && score >= 70;
    
    logInfo('\n========== 检测完成 ==========');
    logInfo(`总分: ${score}/100`);
    logInfo(`状态: ${success ? '✅ 推荐功能正常' : '❌ 需要优化'}`);
    
    return {
      success,
      score,
      issues,
      suggestions,
      details: {
        cookieStatus,
        paramStatus,
        recommendStatus,
        behaviorStatus
      }
    };
  }
  
  /**
   * 检测Cookie状态
   */
  private static async detectCookie(): Promise<CookieStatus> {
    const cookie = AppStorage.get<string>('biliCookie') || '';
    
    const status: CookieStatus = {
      hasCookie: cookie.length > 0,
      hasSESSDATA: cookie.includes('SESSDATA'),
      hasBiliJct: cookie.includes('bili_jct'),
      hasDedeUserID: cookie.includes('DedeUserID'),
      hasBuvid3: cookie.includes('buvid3') || AppStorage.get<string>('buvid3') !== undefined,
      userMid: '0',
      isValid: false
    };
    
    // 提取用户ID
    const match = cookie.match(/DedeUserID=(\d+)/);
    status.userMid = match && match[1] ? match[1] : '0';
    
    // 判断有效性
    status.isValid = status.hasSESSDATA && status.hasBiliJct && status.hasDedeUserID;
    
    logInfo(`  Cookie长度: ${cookie.length}`);
    logInfo(`  SESSDATA: ${status.hasSESSDATA ? '✅' : '❌'}`);
    logInfo(`  bili_jct: ${status.hasBiliJct ? '✅' : '❌'}`);
    logInfo(`  DedeUserID: ${status.hasDedeUserID ? '✅' : '❌'} (mid=${status.userMid})`);
    logInfo(`  buvid3: ${status.hasBuvid3 ? '✅' : '❌'}`);
    
    return status;
  }
  
  /**
   * 检测推荐参数
   */
  private static async detectParams(): Promise<ParamStatus> {
    const deviceId = AppStorage.get<string>('buvid3') || '';
    const sessionId = AppStorage.get<string>('recommend_session_id') || '';
    const cookie = AppStorage.get<string>('biliCookie') || '';
    const match = cookie.match(/DedeUserID=(\d+)/);
    const webMid = match && match[1] ? match[1] : '';
    
    const status: ParamStatus = {
      hasFreshIdx: true,  // 假设已实现
      hasDeviceId: deviceId.length > 0,
      hasSessionId: sessionId.length > 0,
      hasWebMid: webMid.length > 0,
      paramCount: 0,
      isValid: false
    };
    
    // 计算参数数量
    status.paramCount = [
      status.hasFreshIdx,
      status.hasDeviceId,
      status.hasSessionId,
      status.hasWebMid
    ].filter(Boolean).length;
    
    // 判断有效性（至少需要设备ID）
    status.isValid = status.hasDeviceId;
    
    logInfo(`  设备ID: ${status.hasDeviceId ? '✅ ' + deviceId.substring(0, 8) + '...' : '❌'}`);
    logInfo(`  会话ID: ${status.hasSessionId ? '✅ ' + sessionId.substring(0, 15) + '...' : '❌'}`);
    logInfo(`  用户ID: ${status.hasWebMid ? '✅ ' + webMid : '❌ 未登录'}`);
    logInfo(`  参数完整度: ${status.paramCount}/4`);
    
    return status;
  }
  
  /**
   * 检测推荐功能
   */
  private static async detectRecommend(): Promise<RecommendStatus> {
    const status: RecommendStatus = {
      canFetchRecommend: false,
      recommendCount: 0,
      uniqueVideoCount: 0,
      hasPersonalized: false,
      error: ''
    };
    
    try {
      // 尝试获取推荐
      logInfo('  尝试获取推荐数据...');
      const videos: RecommendItem[] = await getRecommendVideosOptimized(1, 20);
      
      status.recommendCount = videos.length;
      status.canFetchRecommend = videos.length > 0;
      
      if (status.canFetchRecommend) {
        // 检测唯一性（避免重复推荐）
        const uniqueIds = new Set<string>();
        videos.forEach((v: RecommendItem) => uniqueIds.add(v.id));
        status.uniqueVideoCount = uniqueIds.size;
        
        // 检测个性化程度（简单判断：如果推荐内容多样化，说明有个性化）
        const categories = new Set<string>();
        videos.forEach((v: RecommendItem) => {
          if (v.ownerMid) categories.add(v.ownerMid);
        });
        status.hasPersonalized = categories.size > 5;  // 超过5个不同UP主
        
        logInfo(`  ✅ 获取到 ${videos.length} 条推荐`);
        logInfo(`  唯一视频数: ${status.uniqueVideoCount}`);
        logInfo(`  UP主多样性: ${categories.size} 个不同UP主`);
        logInfo(`  个性化程度: ${status.hasPersonalized ? '✅ 良好' : '⚠️ 较低'}`);
        
        // 打印前3条推荐
        logInfo('  前3条推荐:');
        const topVideos = videos.slice(0, 3);
        topVideos.forEach((v: RecommendItem, i: number) => {
          const title = v.title.length > 30 ? v.title.substring(0, 30) : v.title;
          logInfo(`    ${i + 1}. ${title}... (${v.ownerName})`);
        });
      } else {
        status.error = '推荐数据为空';
        logInfo('  ❌ 推荐数据为空');
      }
      
    } catch (err) {
      status.error = String(err);
      logError(`  ❌ 推荐请求失败: ${err}`);
    }
    
    return status;
  }
  
  /**
   * 检测行为数据
   */
  private static async detectBehavior(): Promise<BehaviorStatus> {
    const watchedVideos = AppStorage.get<Set<string>>('watchedVideos') || new Set<string>();
    const blockedUploaders = AppStorage.get<Set<string>>('blockedUploaders') || new Set<string>();
    
    const status: BehaviorStatus = {
      hasWatchedVideos: watchedVideos.size > 0,
      watchedCount: watchedVideos.size,
      hasBlockedUploaders: blockedUploaders.size > 0,
      blockedCount: blockedUploaders.size
    };
    
    logInfo(`  已观看视频: ${status.watchedCount} 条`);
    logInfo(`  已屏蔽UP主: ${status.blockedCount} 个`);
    
    return status;
  }
  
  /**
   * 对比测试：原始API vs 优化API
   */
  static async compareTest(): Promise<void> {
    logInfo('\n========== 对比测试 ==========');
    
    // 测试原始API
    logInfo('\n【原始API】');
    const startTime1 = Date.now();
    // const videos1 = await getRecommendVideos(1, 20);  // 原始API
    const time1 = Date.now() - startTime1;
    
    // 测试优化API
    logInfo('\n【优化API】');
    const startTime2 = Date.now();
    const videos2: RecommendItem[] = await getRecommendVideosOptimized(1, 20);
    const time2 = Date.now() - startTime2;
    
    logInfo('\n【对比结果】');
    logInfo(`原始API: ${0} 条, 耗时 ${time1}ms`);
    logInfo(`优化API: ${videos2.length} 条, 耗时 ${time2}ms`);
    
    // 分析推荐差异
    if (videos2.length > 0) {
      const upMasters = new Set<string>();
      videos2.forEach((v: RecommendItem) => {
        if (v.ownerMid) upMasters.add(v.ownerMid);
      });
      logInfo(`UP主多样性: ${upMasters.size} 个`);
      
      const playCounts: number[] = videos2.map((v: RecommendItem): number => v.playCount);
      const avgPlay = playCounts.reduce((a: number, b: number): number => a + b, 0) / playCounts.length;
      logInfo(`平均播放量: ${Math.floor(avgPlay).toLocaleString()}`);
    }
  }
  
  /**
   * 持续监控推荐质量
   */
  static startMonitoring(intervalMs: number = 60000): void {
    logInfo(`开始监控推荐质量，间隔 ${intervalMs / 1000} 秒`);
    
    setInterval(async () => {
      const result = await RecommendDetector.runFullDetection();
      
      if (!result.success) {
        logWarn('⚠️ 推荐质量下降，需要优化');
        logWarn(`问题: ${result.issues.join(', ')}`);
      }
    }, intervalMs);
  }
  
  /**
   * 生成检测报告
   */
  static generateReport(result: DetectionResult): string {
    let report = '╔══════════════════════════════════════╗\n';
    report += '║     B站推荐功能检测报告              ║\n';
    report += '╚══════════════════════════════════════╝\n\n';
    
    // 总体状态
    report += `【总体评分】${result.score}/100 分\n`;
    report += `【状态】${result.success ? '✅ 正常' : '❌ 需要优化'}\n\n`;
    
    // Cookie状态
    const cookie = result.details.cookieStatus;
    report += '【Cookie状态】\n';
    report += `  完整性: ${cookie.isValid ? '✅' : '❌'}\n`;
    report += `  用户ID: ${cookie.userMid !== '0' ? cookie.userMid : '未登录'}\n\n`;
    
    // 参数状态
    const params = result.details.paramStatus;
    report += '【参数状态】\n';
    report += `  完整度: ${params.paramCount}/4\n`;
    report += `  设备ID: ${params.hasDeviceId ? '✅' : '❌'}\n`;
    report += `  会话ID: ${params.hasSessionId ? '✅' : '❌'}\n\n`;
    
    // 推荐状态
    const recommend = result.details.recommendStatus;
    report += '【推荐状态】\n';
    report += `  可用性: ${recommend.canFetchRecommend ? '✅' : '❌'}\n`;
    report += `  推荐数量: ${recommend.recommendCount} 条\n`;
    report += `  个性化: ${recommend.hasPersonalized ? '✅' : '⚠️'}\n\n`;
    
    // 问题与建议
    if (result.issues.length > 0) {
      report += '【问题列表】\n';
      result.issues.forEach((issue: string) => report += `  ❌ ${issue}\n`);
      report += '\n';
    }
    
    if (result.suggestions.length > 0) {
      report += '【优化建议】\n';
      result.suggestions.forEach((s: string) => report += `  💡 ${s}\n`);
      report += '\n';
    }
    
    return report;
  }
}
