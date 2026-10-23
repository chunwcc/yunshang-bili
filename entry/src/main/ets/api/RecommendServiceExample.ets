/**
 * 推荐服务使用示例
 * 
 * 本文件展示如何在页面中正确使用 fresh_idx 递增机制和 WBI 签名
 */

// ========== 方式一：使用 BilibiliApi（推荐） ==========

import { getRecommendVideos, resetRecommendIndex, getCurrentRecommendIndex } from './BilibiliApi';
import { logInfo, logWarn, logError } from '../utils/Logger';

@Component
struct RecommendPageExample {
  @State videoList: RecommendItem[] = [];
  @State isLoading: boolean = false;
  @State isRefreshing: boolean = false;
  
  // 下拉刷新
  async onRefresh() {
    this.isRefreshing = true;
    
    // ✅ 正确：不传参数，自动使用递增的 fresh_idx
    const videos = await getRecommendVideos();
    
    // ❌ 错误：传入固定值，会导致重复内容
    // const videos = await getRecommendVideos(1);
    
    this.videoList = videos;
    this.isRefreshing = false;
    
    logInfo(`当前 fresh_idx: ${getCurrentRecommendIndex()}`);
  }
  
  // 加载更多
  async onLoadMore() {
    if (this.isLoading) return;
    this.isLoading = true;
    
    // ✅ 正确：自动递增获取下一页
    const videos = await getRecommendVideos();
    
    // 合并去重
    this.videoList = [...this.videoList, ...videos];
    this.isLoading = false;
  }
  
  // 强制刷新（重置索引）
  async onForceRefresh() {
    resetRecommendIndex();  // 重置为 1
    await this.onRefresh();
  }
  
  build() {
    Column() {
      // 刷新按钮
      Button('刷新')
        .onClick(() => this.onRefresh())
      
      // 视频列表
      List() {
        ForEach(this.videoList, (video: RecommendItem) => {
          ListItem() {
            Text(video.title)
          }
        })
      }
      .onReachEnd(() => this.onLoadMore())
    }
  }
}


// ========== 方式二：使用 RecommendService（高级） ==========

import { 
  RecommendService, 
  fetchRecommendRefresh, 
  fetchRecommendMore,
  resetRecommendService,
  addWatchedVideo 
} from './RecommendService';

@Component
struct AdvancedRecommendPage {
  @State videoList: RecommendItem[] = [];
  private recommendService: RecommendService = RecommendService.getInstance();
  
  async aboutToAppear() {
    // 初始化服务
    await this.recommendService.init(20, 'web');
    
    // 设置过滤条件
    this.recommendService.setDurationFilter(60, 1800);  // 1分钟 ~ 30分钟
    this.recommendService.setExcludeKeywords(['广告', '推广']);
    
    // 加载初始数据
    await this.onRefresh();
  }
  
  async onRefresh() {
    // 刷新（会递增 fresh_idx）
    const result = await fetchRecommendRefresh();
    
    if (result.state === 'success' && result.data) {
      this.videoList = result.data;
    }
  }
  
  async onLoadMore() {
    // 加载更多
    const result = await fetchRecommendMore();
    
    if (result.state === 'success' && result.data) {
      this.videoList = [...this.videoList, ...result.data];
    }
  }
  
  // 标记已观看（后续会过滤）
  onVideoWatched(bvid: string) {
    addWatchedVideo(bvid);
  }
  
  build() {
    Column() {
      // ...
    }
  }
}


// ========== 关键说明 ==========

/**
 * ⭐ fresh_idx 参数递增机制
 * 
 * 问题：刷新时视频总是重复
 * 原因：fresh_idx 没有递增，B站服务端返回相同内容
 * 
 * 解决方案：
 * 1. 每次请求后自动递增 fresh_idx
 * 2. 刷新时使用新的 fresh_idx
 * 3. 加载更多时也递增
 * 
 * 请求参数：
 * - fresh_idx: 刷新索引（必须递增）
 * - brush: 刷次（与 fresh_idx 同步）
 * - fresh_type: 4 = 刷新推荐
 * - ps: 每页数量
 */

/**
 * ⭐ WBI 签名机制
 * 
 * 作用：防止请求被拦截返回 412 错误
 * 
 * 流程：
 * 1. 从 B站 nav 接口获取 wbi_img
 * 2. 从 URL 中提取 img_key 和 sub_key
 * 3. 使用混合密钥对参数签名
 * 4. 添加 w_rid 和 wts 参数
 * 
 * 注意：
 * - 密钥有时效性（约1小时），需定期刷新
 * - 参数必须按字母顺序排序后再签名
 */

/**
 * ⭐ 本地过滤机制
 * 
 * 过滤内容：
 * 1. 已观看视频（excludeBvids）
 * 2. 黑名单用户（excludeMids）
 * 3. 时长范围（minDuration/maxDuration）
 * 4. 屏蔽关键词（excludeKeywords）
 * 5. 直播/广告（goto === 'live' || 'ad'）
 */
