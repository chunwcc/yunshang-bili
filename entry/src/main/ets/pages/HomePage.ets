import { common } from '@kit.AbilityKit';
import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';
import { window, curves, mediaquery, display } from '@kit.ArkUI';
import { hdsMaterial } from '@kit.UIDesignKit';
import { getRecommendVideos, blacklistUploader, prefetchVideoDetail } from '../api/BilibiliApi';
import { getRecommendVideosOptimized } from '../api/RecommendApiOptimized';
import { RecommendItem } from '../model/RecommendItem';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { VibrateUtils } from '../utils/VibrateUtils';
import { WatchHistoryHelper } from '../model/WatchHistoryHelper';
import { sendDislikeFeedback, sendDislikeUpFeedback } from '../api/FeedbackService';
import { UserBehaviorService } from '../services/UserBehaviorService';  // ⭐ 用于本地屏蔽过滤
import { VideoCardComponent } from '../components/VideoCardComponent';
import { formatPlayCountText, getPlayCountDisplayColor } from '../utils/PlayCountStyle';
import { HdsMiniBarButton } from '../components/infra/HdsMiniBarButton';
import { cardItemBg, cardItemBorder } from '../utils/CardStyle';
import { http } from '@kit.NetworkKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';

// ⭐ 已看视频缓存接口（带时间戳，支持7天有效期）
interface WatchedVideoCache {
  id: string;
  timestamp: number;  // 看到的时间
}

// ⭐ 封面图片并发解码跟踪（限制同时解码数量，避免 JPEG HW 解码器过载）
let gActiveImageDecodes: number = 0;
const gMaxConcurrentDecodes: number = 5;

function acquireDecodeSlot(): boolean {
  if (gActiveImageDecodes < gMaxConcurrentDecodes) {
    gActiveImageDecodes++;
    logInfo(`[图片解码] 获取解码槽: ${gActiveImageDecodes}/${gMaxConcurrentDecodes}`);
    return true;
  }
  return false;
}

// TODO(解码槽只增不减: releaseDecodeSlot 当前无调用方，gActiveImageDecodes 只增不减可能耗尽解码槽，需找到图片解码完成后的释放点)
function releaseDecodeSlot(): void {
  gActiveImageDecodes = Math.max(0, gActiveImageDecodes - 1);
  logInfo(`[图片解码] 释放解码槽: ${gActiveImageDecodes}/${gMaxConcurrentDecodes}`);
}

class VideoDataSource implements IDataSource {
  private items: RecommendItem[] = [];
  private listeners: DataChangeListener[] = [];

  public totalCount(): number {
    return this.items.length;
  }

  public getData(index: number): RecommendItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) this.listeners.splice(pos, 1);
  }

  notifyDataReload(): void {
    this.listeners.forEach(listener => listener.onDataReloaded());
  }

  notifyDataAdd(index: number): void {
    this.listeners.forEach(listener => listener.onDataAdd(index));
  }

  public addItems(newItems: RecommendItem[]): void {
    const startIdx = this.items.length;
    this.items.push(...newItems);
    this.notifyDataAdd(startIdx);
  }

  public reloadItems(allItems: RecommendItem[]): void {
    this.items = allItems;
    this.notifyDataReload();
  }

  public getRawItems(): RecommendItem[] {
    return this.items;
  }

  public setRawItems(items: RecommendItem[]): void {
    this.items = items;
  }
}

@Component({ freezeWhenInactive: true })
export struct HomePage {
  // ★ 由父组件传入，供 Scroll 组件和 HdsNavigation.bindToScrollable 使用
  externalScroller?: Scroller = undefined;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('navIndicatorHeight') navIndicatorHeight: number = 0;
  @StorageLink('refreshHomeFlag') @Watch('onRefreshFlagChange') refreshFlag: number = 0;
  @StorageLink('scrollToTopFlag') @Watch('onScrollToTop') scrollToTopFlag: number = 0;
  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @StorageLink('pageShowCounter') @Watch('onPageShowReset') pageShowCounter: number = 0;
  @StorageLink('homeTabLeaving') @Watch('onHomeTabLeaving') homeTabLeaving: number = 0;
  @StorageLink('homeScrollOffset') homeScrollOffset: number = 0;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('showRefreshSeparator') showRefreshSeparator: boolean = true;
  @StorageLink('showHomeCarouselPortrait') showHomeCarouselPortrait: boolean = true;
  @StorageLink('showHomeCarouselLandscape') showHomeCarouselLandscape: boolean = true;
  @StorageLink('showCarouselBgPortrait') showCarouselBgPortrait: boolean = true;
  @StorageLink('showCarouselBgLandscape') showCarouselBgLandscape: boolean = true;
  // ⭐ 轮播背景圆角（0-40vp，默认 30）：仅作用于背景层顶部两角（bottomLeft/bottomRight 恒为 0）
  @StorageLink('carouselBgRadius') carouselBgRadius: number = 30;
  // ⭐ 轮播图标题胶囊自定义：字体大小/粗细/胶囊宽高（宽为百分比 20-100，默认 85）
  @StorageLink('carouselTitleFontSize') carouselTitleFontSize: number = 15;
  @StorageLink('carouselTitleFontWeight') carouselTitleFontWeight: string = 'medium';
  @StorageLink('carouselTitleCapsuleWidth') carouselTitleCapsuleWidth: number = 85;
  @StorageLink('carouselTitleCapsuleHeight') carouselTitleCapsuleHeight: number = 36;
  @StorageLink('carouselTitleLetterSpacing') carouselTitleLetterSpacing: number = 1;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = false;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 40;
  @StorageLink('cardBorderFollowPlayCount') cardBorderFollowPlayCount: boolean = false;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1.5;
  @StorageLink('cardCustomColor') cardCustomColor: string = '';
  @StorageLink('cardCapsuleFollowTheme') cardCapsuleFollowTheme: boolean = false;
  @StorageLink('cardCapsuleShow') cardCapsuleShow: boolean = true;
  @StorageLink('cardCapsuleSize') cardCapsuleSize: number = 12;
  @StorageLink('cardCapsuleRadius') cardCapsuleRadius: number = 7;
  @StorageLink('cardCapsuleColor') cardCapsuleColor: string = '';
  @StorageLink('cardPlayCountShow') cardPlayCountShow: boolean = true;
  @StorageLink('cardPlayCountUnit') cardPlayCountUnit: string = 'wanYi';
  @StorageLink('cardPlayCountSize') cardPlayCountSize: number = 12;
  @StorageLink('cardPlayCountColorMode') cardPlayCountColorMode: string = 'level';
@StorageLink('cardPlayCountIcon') cardPlayCountIcon: boolean = true;
  @StorageLink('cardPlayCountColor') cardPlayCountColor: string = '';
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  // ⭐ 卡片间距滑块同时控制页面左右边距（各引用点直接用 cardListMargin，与 UpSpacePage「边距/间隔统一走它」对齐）
  // @Watch：横屏轮播宽度预算含左右边距，滑块变了要重算
  @StorageLink('cardListMargin') @Watch('onCardListMarginChange') cardListMargin: number = 12;
  @StorageLink('da') da: boolean = false;

  @State dataSource: VideoDataSource = new VideoDataSource();
  @State banners: RecommendItem[] = [];
  @State carouselVisible: boolean = false;
  @State dotsOpacity: number = 0;
  @State currentSwiperIndex: number = 0;
  @State animatedSwiperIndex: number = 0;
  @State lastCoverUrl: string = '';
  @State bgCoverUrl: string = '';
  @State bgFade: number = 0;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @State carouselHeight: number = 338;
  @State carouselMargin: number = 60;
  @State carouselParallaxY: number = 0;
  @State carouselTitleOpacity: number = 1;
  /**
   * ⭐ 网点装饰层的「滚动淡出」系数（与 carouselTitleOpacity 同一条曲线）。
   * ⚠️ 必须与 dotsOpacity **相乘**使用，不能直接写 dotsOpacity：
   *    dotsOpacity 有 11 个写入方（触摸 400ms / onAnimationStart 600ms / onChange 800ms /
   *    数据加载与可见性切换等），滚动若直接覆盖它，轮播自身的流程会把它抢回 1 ——
   *    表现为"已经滚下去了网点却又冒出来"（autoPlay 自动翻页时尤其明显）。
   *    两个来源相乘即互不干扰：滚动只管这一层淡出，触摸/翻页管那一层。
   */
  @State carouselDotsFade: number = 1;
  @State carouselTitleWidth: number = 200;
  @State landscapeCarouselWidth: number = 0;
  @State landscapeCarouselCols: number = 1;
  @State landscapeCarouselMargin: number = 50;
  @StorageLink('landscapeCarouselCols') landscapeCarouselColsPref: number = 1;
  @State landscapeCarouselVisible: boolean = false;
  @State scrollOffset: number = 0;
  @State animateCards: boolean = false;
  @State isLoading: boolean = true;
  @State isLoadingMore: boolean = false;
  @State isRefreshing: boolean = false;
  @State pageNum: number = 1;
  @State refreshIdx: number = 1;  // 刷新索引，每次刷新递增
  @State columnCount: number = 2;
  @State waterFlowKey: number = 0;  // 列数变化时递增，强制 WaterFlow 重建
  @State isLandscape: boolean = false;
  @State topPadding: number = 0;
  @State bottomPadding: number = 0;
  // ⭐ 左右边距跟随卡片间距滑块（cardListMargin）。
  //    ⚠️ ArkUI V1 依赖收集按「属性引用的直接性」收集：build 里经 getter 间接读状态变量
  //    不建立依赖（padding 永不刷新，表现为"间隔变了、边距贴边不动"）。
  //    所以这里不用 getter，改在 4 个引用点直接写 this.cardListMargin。
  private onCardListMarginChange(): void {
    // 横屏轮播宽度预算含左右边距，间距滑块变化时重算
    this.recalcLandscapeCarouselWidth();
  }
  @State manualLoading: boolean = false;

  // ⭐ 长按菜单弹窗相关状态（页面内 overlay：封面丝滑变形 + 胶囊菜单 + 模糊渐强）
  @State isMenuSheetVisible: boolean = false;
  @State selectedMenuItem: RecommendItem | null = null;
  // ⭐ 封面浮层（变形载体）：初始与源封面完全重合，animateTo 逐帧插值 position/scale/圆角
  @State morphDstW: number = 0;      // 浮层布局宽（目标宽，固定；尺寸变化靠 scale）
  @State morphX: number = 0;         // 浮层左上 X（position 动画）
  @State morphY: number = 0;         // 浮层左上 Y
  @State morphScale: number = 1;     // 浮层缩放（初始=源宽/目标宽，动画到 1）
  @State morphRadius: number = 12;   // 浮层圆角（初始=卡片圆角/scale 补偿，动画到卡片圆角）
  @State menuX: number = 0;          // 菜单列位置（固定目标位置，不参与变形）
  @State menuY: number = 0;
  @State menuW: number = 0;          // 菜单列宽（竖屏=封面宽；横屏固定 220 胶囊列居右）
  // ⭐ 遮罩/菜单淡入淡出（状态驱动：关闭时浮层须存活到回弹动画结束，不能靠 transition 卸载）
  @State maskOpacity: number = 0;
  @State menuOpacity: number = 0;
  @State menuScale: number = 0.92;
  // 源封面参数（关闭回弹用）
  private morphSrcX: number = 0;
  private morphSrcY: number = 0;
  private morphSrcScale: number = 1;
  private morphSrcRadius: number = 12;
  private morphTimerId: number = -1;

  // ⭐ 已看视频 ID 集合（用于去重）- 使用Map存储时间戳，支持7天有效期
  private watchedVideoIds: Map<string, number> = new Map();  // id -> timestamp
  // 最大保留的已看视频数量（防止内存过大）
  private readonly MAX_WATCHED_CACHE: number = 500;
  // 7天有效期（毫秒）
  private readonly WATCHED_EXPIRE_TIME: number = 7 * 24 * 60 * 60 * 1000;
  // 防抖保存时间（5秒，比原3秒更长以减少写入频次）
  private readonly SAVE_DEBOUNCE_TIME: number = 5000;
  // 防抖保存定时器
  private pendingSaveTimer: number = -1;
  // ⭐ 脏标记：有新增已看视频但尚未持久化
  private seenVideosDirty: boolean = false;
  // ⭐ 滑过的视频ID（持久化存储的key）
  private readonly SEEN_VIDEOS_KEY: string = 'seen_video_ids_v2';  // v2版本，带时间戳

  // ⭐ "上次看到这里"重新实现：刷新时保留旧视频
  private readonly REFRESH_SEPARATOR_ID: string = '__refresh_separator__';
  private oldItems: RecommendItem[] = [];

  /**
   * ⭐ 从本地存储加载观看历史和滑过的视频用于去重
   * 这是解决"昨天看过的视频今天又出现"的关键！
   * 同时会清理过期的缓存条目，避免存储膨胀
   */
  private async loadWatchHistoryForDedup(): Promise<void> {
    try {
      const now = Date.now();
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;

      // 1. 加载持久化存储的已看视频ID（带时间戳）
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      
      const cachedStr = await pref.get(this.SEEN_VIDEOS_KEY, '') as string;

      if (cachedStr) {
        try {
          const cached: WatchedVideoCache[] = JSON.parse(cachedStr) as WatchedVideoCache[];
          let expiredCount = 0;

          for (const item of cached) {
            // 检查是否在7天有效期内
            if (now - item.timestamp < this.WATCHED_EXPIRE_TIME) {
              this.watchedVideoIds.set(item.id, item.timestamp);
            } else {
              expiredCount++;
            }
          }

          logInfo(`[去重] 从缓存加载 ${cached.length} 条，过期 ${expiredCount} 条，有效 ${this.watchedVideoIds.size} 条`);
          
          // ⭐ 如果有过期条目，主动清理存储，避免下次还要处理
          if (expiredCount > 0) {
            const validItems: WatchedVideoCache[] = [];
            this.watchedVideoIds.forEach((timestamp, id) => {
              validItems.push({ id, timestamp });
            });
            await pref.put(this.SEEN_VIDEOS_KEY, JSON.stringify(validItems));
            await pref.flush();
            logInfo(`[去重] 已清理 ${expiredCount} 条过期缓存`);
          }
        } catch (e) {
          logWarn(`[去重] 解析缓存失败: ${e}`);
        }
      }

      // 2. 加载观看历史（点进去看的）- 只加载最近100条
      await WatchHistoryHelper.getInstance().init(context);
      const history = await WatchHistoryHelper.getInstance().queryAllHistory(100);

      if (history && history.length > 0) {
        for (const item of history) {
          if (item.bvid && !this.watchedVideoIds.has(item.bvid)) {
            this.watchedVideoIds.set(item.bvid, now);  // 使用当前时间作为时间戳
          }
        }
        logInfo(`[去重] 从观看历史加载 ${history.length} 条`);
      }

      logInfo(`[去重] 总计 ${this.watchedVideoIds.size} 条去重记录（7天有效）`);
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : String(err);
      logError(`[去重] 加载历史失败: ${errorMsg}`);
    }
  }

  /**
   * ⭐ 保存已看视频ID到持久化存储（带时间戳）
   */
  private async saveSeenVideos(): Promise<void> {
    if (!this.seenVideosDirty) {
      return; // ⭐ 没有新数据，跳过写入
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');

      // 转换为带时间戳的数组
      const cacheData: WatchedVideoCache[] = [];
      this.watchedVideoIds.forEach((timestamp, id) => {
        cacheData.push({ id, timestamp });
      });

      // 只保存最近的500条
      const toSave = cacheData.slice(-this.MAX_WATCHED_CACHE);
      await pref.put(this.SEEN_VIDEOS_KEY, JSON.stringify(toSave));
      await pref.flush();
      this.seenVideosDirty = false; // ⭐ 重置脏标记

      logInfo(`[去重] 已保存 ${toSave.length} 条已看视频记录`);
    } catch (err) {
      logError(`[去重] 保存失败: ${err}`);
    }
  }

  /**
   * ⭐ 防抖保存：延迟3秒后保存，避免频繁写磁盘
   * 用于自动记录浏览时调用
   */
  private scheduleSaveSeenVideos(): void {
    if (this.pendingSaveTimer !== -1) {
      clearTimeout(this.pendingSaveTimer);
    }
    this.pendingSaveTimer = setTimeout(async () => {
      await this.saveSeenVideos();
      this.pendingSaveTimer = -1;
    }, this.SAVE_DEBOUNCE_TIME);
  }

  /**
   * ⭐ 自动记录浏览过的视频（调用此方法）
   * 在 FlowItem.onAppear 和 onCardClick 中调用
   */
  private autoRecordWatched(item: RecommendItem): void {
    // 如果已记录过，不重复记录（避免频繁触发）
    if (this.watchedVideoIds.has(item.id)) {
      return;
    }
    // 记录到缓存
    this.watchedVideoIds.set(item.id, Date.now());
    this.seenVideosDirty = true; // ⭐ 标记有新数据待持久化
    // 防抖保存
    this.scheduleSaveSeenVideos();
  }

  private pageSize: number = 20;
  private hasMore: boolean = true;
  private lastScrollY: number = 0;
  private readonly SCROLL_THRESHOLD: number = 10;
  /**
   * ⭐ 轮播换代（刷新 / 重新可见）时的缩放目标值：可见为 1，隐藏时缩到它。
   * 单独提成常量是因为这个值需要反复实机试手感 —— 调它只改这一处。
   */
  private readonly CAROUSEL_HIDDEN_SCALE: number = 0.86;
  private maxRetryPages: number = 20;
  private longPullTimer: number = -1;
  private longPullTriggered: boolean = false;
  private windowSizeChangeListener: ((size: window.Size) => void) | null = null;
  private mainWindowRef: window.Window | null = null;
  private isPageActive: boolean = false;
  private portraitSwiperController: SwiperController = new SwiperController();
  private landscapeSwiperController: SwiperController = new SwiperController();
  private clickedCarouselIndex: number = -1;
  @State refreshBuilderText: string = '下拉刷新';
  @State showSearchIcon: boolean = false;

  // 媒体查询监听器
  private landscapeListener: mediaquery.MediaQueryListener | null = null;

  @State cardsVisible: boolean[] = [];
  @State isBulkLoading: boolean = false;
  private cardDelays: number[] = [];
  private cardTranslateYs: number[] = [];

  async aboutToAppear() {
    this.isPageActive = true;
    await this.getStatusBarHeight();
    await this.waitForStableOrientation();
    await this.initOrientationAndColumn();
    // ⭐ 加载观看历史用于去重
    await this.loadWatchHistoryForDedup();
    // ⭐ 从持久化存储加载屏蔽UP主列表
    await UserBehaviorService.loadBlockedUploaders();
    // ⭐ 从持久化存储加载推荐API源设置（PersonalizationPage 可能尚未执行）
    try {
      const pf = await preferences.getPreferences(this.getUIContext().getHostContext() as common.Context, 'my_app_settings');
      const savedSource = await pf.get('recommendApiSource', 'App') as string;
      logInfo(`[PrefDebug] 从Preferences读取recommendApiSource="${savedSource}"` +
        ` (Preferences名=my_app_settings, key=recommendApiSource)`);
      AppStorage.set('recommendApiSource', savedSource);
    } catch (e) {
      logError(`[PrefDebug] 读取recommendApiSource异常: ${e}`);
    }
    // ⭐ 从持久化存储加载弹幕数据源设置
    try {
      const dmkPf = await preferences.getPreferences(this.getUIContext().getHostContext() as common.Context, 'my_app_settings');
      const savedDmkSource = await dmkPf.get('danmakuApiSource', 'grpc') as string;
      logInfo(`[PrefDebug] 从Preferences读取danmakuApiSource="${savedDmkSource}"`);
      AppStorage.set('danmakuApiSource', savedDmkSource);
    } catch (e) {
      logError(`[PrefDebug] 读取danmakuApiSource异常: ${e}`);
    }
    await this.refreshData();
    await this.watchWindowSizeChange();
    this.updatePaddings();
    this.recalcCarouselHeight();
    this.recalcLandscapeCarouselWidth();
    AppStorage.set('bottomBarHidden', false);
    this.registerOrientationListener();
  }
  async aboutToDisappear() {
    this.isPageActive = false;
    // 清除防抖保存定时器
    if (this.pendingSaveTimer !== -1) {
      clearTimeout(this.pendingSaveTimer);
      this.pendingSaveTimer = -1;
    }
    // 保存当前列数设置
    await this.saveCurrentColumnCount();
    // ⭐ 不再保存滑过的视频ID - 依赖B站服务端去重
    // await this.saveSeenVideos();
    if (this.mainWindowRef && this.windowSizeChangeListener) {
      this.mainWindowRef.off('windowSizeChange', this.windowSizeChangeListener);
      this.windowSizeChangeListener = null;
    }
    // 移除媒体查询监听
    if (this.landscapeListener) {
      this.landscapeListener.off('change');
      this.landscapeListener = null;
    }
  }

  // 注册媒体查询监听
  private registerOrientationListener() {
    const mediaQuery = this.getUIContext().getMediaQuery();
    this.landscapeListener = mediaQuery.matchMediaSync('(orientation: landscape)');
    this.landscapeListener.on('change', async (result: mediaquery.MediaQueryResult) => {
      if (!this.isPageActive) return;
      const newIsLandscape = result.matches;
      if (this.isLandscape !== newIsLandscape) {
        logInfo(`[HomePage] 方向变化: ${newIsLandscape ? '横屏' : '竖屏'}`);
        this.isLandscape = newIsLandscape;
        // ⭐ 长按菜单弹窗打开中 → 旋转后位置全部失效，自动关闭
        this.dismissMenuIfOpen();
        // ⭐ 先同步 paddings 和 carouselHeight，在异步加载之前让 build 拿到正确值
        this.updatePaddings();
        this.recalcCarouselHeight();
        // 加载新方向对应的列数（用户自定义值）
        await this.loadColumnCountForOrientation();
        this.recalcLandscapeCarouselWidth();
        // ⭐ 横屏→竖屏时，触发展示轮播图（横屏下 carouselVisible 保持 false）
        if (!newIsLandscape && this.showHomeCarouselPortrait && this.banners.length > 0) {
          // Swiper 重建后内部索引重置为 0，同步 state 避免缩放/模糊错乱
          this.currentSwiperIndex = 0;
          this.animatedSwiperIndex = 0;
          try {
            this.getUIContext().animateTo({ duration: 600, curve: Curve.FastOutSlowIn }, () => {
              this.carouselVisible = true;
            });
          } catch (_) {
            this.carouselVisible = true;
          }
          // 横屏轮播隐藏
          this.landscapeCarouselVisible = false;
        }
        // ⭐ 竖屏→横屏时，展示左侧固定轮播图
        if (newIsLandscape && this.showHomeCarouselLandscape && this.banners.length > 0) {
          // 设为索引1使上下预览同时显示相邻项（prev=索引0, next=索引2）
          this.currentSwiperIndex = this.banners.length > 1 ? 1 : 0;
          this.animatedSwiperIndex = this.currentSwiperIndex;
          try {
            this.getUIContext().animateTo({ duration: 600, curve: Curve.FastOutSlowIn }, () => {
              this.landscapeCarouselVisible = true;
            });
          } catch (_) {
            this.landscapeCarouselVisible = true;
          }
          this.carouselVisible = false;
        }
        // 可选：刷新滚动偏移量保持
        AppStorage.setOrCreate('homeScrollOffset', this.scrollOffset);
      } else if (this.banners.length > 0) {
        // ⭐ 兜底：isLandscape 已被 windowSizeChange 设过，强制同步轮播显隐
        // 仅在轮播从隐藏→显示时重置索引，避免覆盖 onPageShow 的索引推进
        if (!newIsLandscape) {
          if (!this.carouselVisible) {
            this.currentSwiperIndex = 0;
            this.animatedSwiperIndex = 0;
          }
          this.carouselVisible = this.showHomeCarouselPortrait;
          this.landscapeCarouselVisible = false;
        } else {
          if (!this.landscapeCarouselVisible) {
            this.currentSwiperIndex = this.banners.length > 1 ? 1 : 0;
            this.animatedSwiperIndex = this.currentSwiperIndex;
          }
          this.landscapeCarouselVisible = this.showHomeCarouselLandscape;
          this.carouselVisible = false;
        }
      }
    });
  }

  private async waitForStableOrientation(): Promise<void> {
    await new Promise<void>(resolve => setTimeout(resolve, 150));
  }

  async onPageShow() {
    await this.recheckOrientationAndColumn();
    // 每次返回时轮播切到下一张（用保存的点击索引，防止 autoPlay 干扰）
    if (this.clickedCarouselIndex >= 0 && this.banners.length > 0) {
      const nextIndex = (this.clickedCarouselIndex + 1) % this.banners.length;
      this.currentSwiperIndex = nextIndex;
      this.animatedSwiperIndex = nextIndex;
      this.clickedCarouselIndex = -1;
    }
    // 返回页面时渐显渐变网点（离开时可能为 0），首次加载跳过（由 refreshData 统一控制）
    if (this.banners.length > 0) {
      this.getUIContext().animateTo({ duration: 800, curve: Curve.FastOutSlowIn }, () => {
        this.dotsOpacity = 1;
      });
    }
  }

  onPageShowReset() {
    this.isRefreshing = false;
    this.showSearchIcon = false;
    this.refreshBuilderText = '下拉刷新';
    this.longPullTriggered = false;
    if (this.longPullTimer !== -1) {
      clearTimeout(this.longPullTimer);
      this.longPullTimer = -1;
    }
    this.recheckOrientationAndColumn();
    // 回到首页 → 渐显渐变网点
    this.dotsOpacity = 1;
  }

  /** 离开首页 → 渐隐渐变网点 */
  onHomeTabLeaving(): void {
    this.dotsOpacity = 0;
  }

  private async recheckOrientationAndColumn() {
    await this.waitForStableOrientation();
    await this.initOrientationAndColumn();
    this.updatePaddings();
  }

  @Watch('onHideStatusBarChange')
  @StorageLink('hideStatusBar') watchHideStatusBarLink: boolean = false;

  private async onHideStatusBarChange() {
    if (this.hideStatusBar) {
      this.statusBarHeight = 0;
    } else {
      // 系统避让区可能还未更新，使用缓存的真实高度
      const cached = AppStorage.get<number>('realStatusBarHeight');
      if (cached && cached > 0) {
        this.statusBarHeight = cached;
      } else {
        await this.getStatusBarHeight();
      }
    }
    this.updatePaddings();
    this.recalcCarouselHeight();
  }

  @Watch('onCarouselToggle')
  @StorageLink('showHomeCarouselPortrait') watchCarouselTogglePortrait: boolean = true;

  @Watch('onCarouselToggle')
  @StorageLink('showHomeCarouselLandscape') watchCarouselToggleLandscape: boolean = true;

  private async onCarouselToggle() {
    // 竖屏或横屏轮播开关变化 — 横屏时重算列数
    if (this.isLandscape) {
      await this.loadColumnCountForOrientation();
      this.recalcLandscapeCarouselWidth();
      this.waterFlowKey++;
    }
  }

  private onScrollToTop() {
    if (this.externalScroller) {
      this.externalScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300 } });
    }
  }

  private async initOrientationAndColumn() {
    let mainWindow = AppStorage.get<window.Window>('mainWindow');
    if (!mainWindow) {
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        mainWindow = await window.getLastWindow(context);
      } catch (err) {
        logError('获取窗口失败', err);
      }
    }
    if (mainWindow) {
      try {
        const props = mainWindow.getWindowProperties();
        const width = props.windowRect.width;
        const height = props.windowRect.height;
        const newIsLandscape = width > height;
        if (this.isLandscape !== newIsLandscape) {
          this.isLandscape = newIsLandscape;
          logInfo(`initOrientationAndColumn: 方向更新为 ${this.isLandscape ? '横屏' : '竖屏'}`);
        }
      } catch (err) {
        logError('获取窗口属性失败', err);
        this.isLandscape = false;
      }
    } else {
      this.isLandscape = false;
    }
    await this.loadColumnCountForOrientation();
    logInfo(`initOrientationAndColumn: 方向=${this.isLandscape ? '横屏' : '竖屏'}, 列数=${this.columnCount}`);
  }

  private async watchWindowSizeChange() {
    const mainWindow = AppStorage.get<window.Window>('mainWindow');
    if (mainWindow && !this.windowSizeChangeListener) {
      this.mainWindowRef = mainWindow;
      this.windowSizeChangeListener = async (size: window.Size) => {
        // 同步 isLandscape，确保 updatePaddings / recalcCarouselHeight 用正确的 topPadding
        const newIsLandscape = size.width > size.height;
        if (newIsLandscape !== this.isLandscape) {
          this.isLandscape = newIsLandscape;
          // ⭐ 长按菜单弹窗打开中 → 旋转后位置全部失效，自动关闭
          this.dismissMenuIfOpen();
        }
        this.updatePaddings();
        this.recalcCarouselHeight();
        this.recalcLandscapeCarouselWidth();
      };
      mainWindow.on('windowSizeChange', this.windowSizeChangeListener);
      logInfo('watchWindowSizeChange: 已注册窗口尺寸变化监听器');
    }
  }

  private updatePaddings() {
    const suspendedBarHeight = 56;
    if (this.isLandscape) {
      // 横屏：顶部边距12
      this.topPadding = 12;
      this.bottomPadding = 176 + this.navIndicatorHeight;
    } else {
      // 竖屏：使用首页的高度
      this.topPadding = suspendedBarHeight;
      this.bottomPadding = 190 + this.navIndicatorHeight;
    }
  }

  /** 轮播图标题字体粗细：根据设置字符串映射为 FontWeight */
  private resolveCarouselTitleFontWeight(): FontWeight {
    switch (this.carouselTitleFontWeight) {
      case 'bold': return FontWeight.Bold;
      case 'medium': return FontWeight.Medium;
      default: return FontWeight.Normal;
    }
  }

  /**
   * 实时计算轮播图标题胶囊 bar 宽度（vp）。
   * 不依赖 recalcCarouselHeight 的缓存值，保证调节百分比后立即生效：
   * barWidth = itemWidth × 百分比 - 16（contentPadding×4），最小 140。
   */
  private resolveCarouselTitleBarWidth(): number {
    try {
      const displayInfo = display.getDefaultDisplaySync();
      const screenWidthVp = this.getUIContext().px2vp(Math.min(displayInfo.width, displayInfo.height));
      const itemWidth = screenWidthVp - this.carouselMargin * 2;
      return Math.max(140, Math.round(itemWidth * this.carouselTitleCapsuleWidth / 100) - 16);
    } catch (err) {
      logWarn(`resolveCarouselTitleBarWidth 异常: ${errMsg(err)}`);
      return 140;
    }
  }

  /** 根据屏幕宽度动态计算轮播图高度与边距，使不同机型间距一致 */
  private recalcCarouselHeight(): void {
    try {
      const displayInfo = display.getDefaultDisplaySync();
      // 竖屏轮播用短边宽度，避免横竖屏切换时 display 未更新导致高度错误
      const screenWidthVp = this.getUIContext().px2vp(Math.min(displayInfo.width, displayInfo.height));
      // 窄屏机型增大图片可用宽度：边距 = 屏幕宽 × 10%（最小20，最大60）
      this.carouselMargin = Math.max(20, Math.min(60, Math.round(screenWidthVp * 0.1)));
      // Swiper 可见宽度 = 屏幕宽 - prevMargin - nextMargin
      const itemWidth = screenWidthVp - this.carouselMargin * 2;
      // 标题胶囊 bar 宽度：整体视觉 = Swiper 可见宽度 × 用户设置百分比（默认 60%）
      // HdsMiniBarButton 容器总宽 = barWidth + contentPadding*4（16vp），故减 16 取整对齐
      this.carouselTitleWidth = Math.max(140, Math.round(itemWidth * this.carouselTitleCapsuleWidth / 100) - 16);
      // 16:9 图片高度
      const imageH = itemWidth * 9 / 16;
      // 标题区域高度：仅当胶囊高度调大（>40）时按需扩容，默认保持 40 不变，
      // 避免轮播图与信息流间距变大；扩容量 = 胶囊超出 40 的部分
      const titleH = 40 + Math.max(0, this.carouselTitleCapsuleHeight - 40);
      // ⭐ 竖屏下 statusBarHeight 可能因横竖屏切换时序未恢复，用缓存值兜底
      let sbHeight = this.statusBarHeight;
      if (!this.isLandscape && sbHeight <= 0) {
        sbHeight = AppStorage.get<number>('realStatusBarHeight') ?? 40;
      }
      // 顶部 padding + 图片 + 标题 + 底部缓冲
      const paddingTop = this.topPadding + 12 + (this.hideStatusBar ? 0 : sbHeight);
      this.carouselHeight = Math.ceil(paddingTop + imageH + titleH + 12);
    } catch (_) {
      this.carouselHeight = 338;
    }
  }

  /** 计算横屏左侧固定轮播图的宽度（与 WaterFlow 列宽对齐） */
  private recalcLandscapeCarouselWidth(): void {
    try {
      const displayInfo = display.getDefaultDisplaySync();
      const screenWidthVp = this.getUIContext().px2vp(displayInfo.width);
      // 用户配置的横屏轮播占列数，最多 columnCount-1（至少留1列给视频）
      // 默认策略：3列占1列 ≈ 33%，4列占2列 ≈ 50%
      const maxCols = this.columnCount - 1;
      const smartDefaultCols = this.columnCount >= 4 ? 2 : 1;
      const effectivePref = this.landscapeCarouselColsPref === 1 ? smartDefaultCols : this.landscapeCarouselColsPref;
      this.landscapeCarouselCols = Math.max(1, Math.min(effectivePref, maxCols));
      // 计算单列 WaterFlow item 宽度
      const totalGaps = (this.columnCount - 1) * this.cardListMargin;
      const usableWidth = screenWidthVp - this.cardListMargin * 2 - totalGaps;
      const singleColWidth = usableWidth / this.columnCount;
      // 轮播区域宽度 = N列内容 + (N-1)个间隔 + 左右两侧边距
      this.landscapeCarouselWidth = Math.ceil(
        singleColWidth * this.landscapeCarouselCols +
        (this.landscapeCarouselCols - 1) * this.cardListMargin +
        this.cardListMargin * 2
      );
      // 横屏轮播垂直 Swiper 的上下预览区域，根据列数动态适配
      const screenHeightVp = this.getUIContext().px2vp(displayInfo.height);
      const topPad = this.topPadding + 12 + (this.hideStatusBar ? 0 : this.statusBarHeight);
      const swiperH = screenHeightVp - topPad;
      // 直板机（非折叠屏手机）用小比例，折叠屏/平板用大比例
      const isFoldable: boolean = display.isFoldable?.() ?? false;
      const isRegularPhone: boolean = deviceInfo.deviceType === 'phone' && !isFoldable;
      const ratio = isRegularPhone
        ? (this.columnCount <= 2 ? 0.17 : 0.28)
        : (this.columnCount <= 2 ? 0.26 : 0.33);
      this.landscapeCarouselMargin = Math.max(6, Math.round(swiperH * ratio));
    } catch (_) {
      this.landscapeCarouselWidth = this.landscapeCarouselColsPref >= 2 ? Math.ceil(this.getUIContext().px2vp(800) * 0.5) : Math.ceil(this.getUIContext().px2vp(800) / 3);
    }
  }

  private async loadColumnCountForOrientation() {
    const key = this.isLandscape ? 'homeColumnCountLandscape' : 'homeColumnCountPortrait';
    const defaultValue = this.isLandscape ? 3 : 2;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      let saved = await pref.get(key, defaultValue) as number;
      // 轮播开启时横屏可选 2列/3列（去掉4列）
      if (this.isLandscape && this.showHomeCarouselLandscape) {
        saved = Math.max(2, Math.min(saved, 3));
      }
      logInfo(`loadColumnCountForOrientation: key=${key}, 保存值=${saved}`);
      if (this.columnCount !== saved) {
        this.columnCount = saved;
        this.waterFlowKey++;
        // 列数变化后重新计算横屏轮播宽度
        if (this.isLandscape) {
          this.recalcLandscapeCarouselWidth();
        }
      }
    } catch (err) {
      logError('加载列数失败', err);
      this.columnCount = defaultValue;
    }
  }

  private updateBanners(items: RecommendItem[]): void {
    const valid = items.filter(item =>
      item.id !== this.REFRESH_SEPARATOR_ID && item.playCount > 0
    );
    valid.sort((a, b) => b.playCount - a.playCount);
    this.banners = valid.slice(0, 4);
    if (this.banners.length > 0) {
      this.currentSwiperIndex = 0;
      this.animatedSwiperIndex = 0;
      this.lastCoverUrl = this.bgCoverUrl;
      this.bgCoverUrl = this.banners[Math.min(this.currentSwiperIndex, this.banners.length - 1)].coverUrl;
      this.bgFade = 0;
      this.getUIContext().animateTo({ duration: 1000, curve: Curve.FastOutSlowIn }, () => {
        this.bgFade = 1;
      });
    }
  }

  private async saveCurrentColumnCount() {
    if (!this.isPageActive) return;
    const key = this.isLandscape ? 'homeColumnCountLandscape' : 'homeColumnCountPortrait';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put(key, this.columnCount);
      await pref.flush();
      logInfo(`saveCurrentColumnCount: 保存 ${key}=${this.columnCount}`);
    } catch (err) {
      logError('保存列数失败', err);
    }
  }

  onRefreshFlagChange() {
    this.refreshData();
  }

  private onRefresh() {
    this.refreshData().finally(() => {
      this.isRefreshing = false;
    });
  }

  private async manualRefresh() {
    if (this.manualLoading) return;
    this.manualLoading = true;
    await this.refreshData();
    this.manualLoading = false;
    try {
      this.getUIContext().getPromptAction().showToast({ message: '已刷新推荐内容', duration: 1000 });
    } catch (err) {
      logWarn(`showToast 异常: ${errMsg(err)}`);
    }
  }

  // ⭐ 过滤已看过的视频
  private filterWatched(items: RecommendItem[]): RecommendItem[] {
    const now = Date.now();
    return items.filter(item => {
      const timestamp = this.watchedVideoIds.get(item.id);
      if (!timestamp) return true;  // 没看过
      // 检查是否在有效期内
      if (now - timestamp >= this.WATCHED_EXPIRE_TIME) {
        // 过期了，删除缓存条目并允许显示
        this.watchedVideoIds.delete(item.id);
        return true;
      }
      return false;  // 在有效期内，过滤掉
    });
  }

  private mergeUnique(existing: RecommendItem[], newItems: RecommendItem[]): RecommendItem[] {
    const map = new Map<string, RecommendItem>();
    for (const item of existing) map.set(item.id, item);
    for (const item of newItems) {
      if (!map.has(item.id)) map.set(item.id, item);
    }
    return Array.from(map.values());
  }

  // ⭐ 从 Preferences 读取 recommendApiSource（AppStorage 在 aboutToAppear 异步中不可靠）
  private async readRecommendApiSource(): Promise<string> {
    try {
      const pf = await preferences.getPreferences(this.getUIContext().getHostContext() as common.Context, 'my_app_settings');
      const val: string = await pf.get('recommendApiSource', 'App') as string;
      logInfo(`[PrefDebug] fetchRecommendVideos: Preferences读取recommendApiSource="${val}"`);
      return val;
    } catch (e) {
      logError(`[PrefDebug] fetchRecommendVideos读取Preferences异常: ${e}`);
      return 'Web';
    }
  }

  // ⭐ 根据 recommendApiSource 设置选择推荐 API
  private async fetchRecommendVideos(freshIdx: number, pageSize: number): Promise<RecommendItem[]> {
    const source: string = await this.readRecommendApiSource();
    try {
      if (source === 'App') {
        logInfo(`[推荐] 使用优化API, fresh_idx=${freshIdx}, source=${source}`);
        return await getRecommendVideosOptimized(freshIdx, pageSize);
      } else {
        logInfo(`[推荐] 使用标准API, fresh_idx=${freshIdx}, source=${source}`);
        return await getRecommendVideos(freshIdx, pageSize);
      }
    } catch (err) {
      logError(`[推荐] API请求异常: ${errMsg(err)}，降级到标准API`);
      try {
        return await getRecommendVideos(freshIdx, pageSize);
      } catch (e) {
        logError(`[推荐] 降级也失败: ${JSON.stringify(e)}`);
        return [];
      }
    }
  }

  async refreshData() {
    // ⭐ 第一步：错落缩小现有卡片（随机延迟，与新卡片入场动画风格一致）
    const oldCount = this.dataSource.totalCount();
    if (oldCount > 0) {
      this.isBulkLoading = false;
      if (this.da) {
        this.cardsVisible = new Array(this.cardsVisible.length).fill(false);
      } else {
        for (let i = 0; i < oldCount; i++) {
          const delay = Math.floor(Math.random() * 300); // 0~300ms 随机
          setTimeout(() => {
            const newVisible = [...this.cardsVisible];
            if (i < newVisible.length) {
              newVisible[i] = false;
              this.cardsVisible = newVisible;
            }
          }, delay);
        }
      }
    }

    // ⭐ 保存当前视频列表，刷新后放在新视频下方
    this.oldItems = this.dataSource.getRawItems();

    this.isLoading = true;
    this.pageNum = 1;
    this.hasMore = true;
    this.refreshIdx++;  // 递增刷新索引

    // ⭐ 循环请求，直到获取足够的未观看视频
    let filteredItems: RecommendItem[] = [];
    let attempts = 0;
    const maxAttempts = 5;  // 最多尝试5次
    const minRequired = Math.floor(this.pageSize * 0.5);  // 至少需要一半的数量

    while (filteredItems.length < minRequired && attempts < maxAttempts) {
      let newItems = await this.fetchRecommendVideos(this.refreshIdx + attempts, this.pageSize);

      // ⭐ 调用服务层过滤（屏蔽UP主、已看视频）
      logInfo(`[调试] refreshData: 调用 filterRecommendList 前，原始数量: ${newItems.length}`);
      newItems = UserBehaviorService.filterRecommendList(newItems);
      logInfo(`[调试] refreshData: 调用 filterRecommendList 后，过滤数量: ${newItems.length}`);
      
      // 过滤已看过的视频
      const newFiltered = this.filterWatched(newItems);
      filteredItems = filteredItems.concat(newFiltered);

      logInfo(`[去重] 第${attempts + 1}次请求: 原始${newItems.length}条 → 过滤后${newFiltered.length}条 → 累计${filteredItems.length}条`);

      attempts++;

      // 如果已经获取足够的视频，退出循环
      if (filteredItems.length >= this.pageSize) {
        break;
      }
    }

    // 更新刷新索引
    this.refreshIdx += attempts;

    // 去重（防止重复）
    let uniqueItems = this.mergeUnique([], filteredItems);

    // ⭐ 组合：新视频 + (可选分隔卡片 + 旧视频)
    const combinedItems: RecommendItem[] = [...uniqueItems];
    if (this.showRefreshSeparator && this.oldItems.length > 0) {
      // 创建分隔卡片
      const separatorItem = new RecommendItem();
      separatorItem.id = this.REFRESH_SEPARATOR_ID;
      combinedItems.push(separatorItem);
      // 追加旧视频（去重，只保留最新 20 条）
      const newIds = new Set(uniqueItems.map(item => item.id));
      let appendedCount = 0;
      for (const old of this.oldItems) {
        if (appendedCount >= 20) break;
        if (!newIds.has(old.id)) {
          combinedItems.push(old);
          appendedCount++;
        }
      }
    }

    if (combinedItems.length > 0) {
      // ⭐ 记录已看过的视频
      // ⭐ 不再自动标记所有视频为已看，改为滑动/点击时自动记录
      // this.recordWatched(uniqueItems);

      this.dataSource.reloadItems(combinedItems);
      // ⭐ 发布真实推荐流供「应用比例调节」预览直接使用
      // ⭐ 延迟更新轮播图：先淡出旧内容，再更新并淡入新内容
      if (this.showHomeCarouselPortrait && !this.isLandscape && this.banners.length > 0) {
        // 有旧轮播图 → 渐变网点先渐隐（200ms），再淡出旧内容（400ms），然后更新数据 + 淡入
        try {
          this.getUIContext().animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
            this.dotsOpacity = 0;
          });
        } catch (_) {
          this.dotsOpacity = 0;
        }
        try {
          this.getUIContext().animateTo({ duration: 400, curve: Curve.FastOutSlowIn }, () => {
            this.carouselVisible = false;
          });
        } catch (_) {
          this.carouselVisible = false;
        }
        setTimeout(() => {
          this.updateBanners(uniqueItems);
          if (!this.bgCoverUrl && this.banners.length > 0) {
            this.bgCoverUrl = this.banners[0].coverUrl;
          }
          // ⭐ 淡入用带过冲的弹簧曲线（而不是 FastOutSlowIn 的匀速收敛）：缩放从 CAROUSEL_HIDDEN_SCALE
          //    弹回 1.0 时会略微冲过 1 再回落，这才是"弹回"的手感；线性缓动只会看到"慢慢变大"。
          //    曲线沿用本文件列表加载已经在用的 springCurve(0.15, 1, 80, 8)（8 比 12 更欠阻尼 = 更有弹性）。
          try {
            this.getUIContext().animateTo({ duration: 800, curve: curves.springCurve(0.15, 1, 80, 8) }, () => {
              this.carouselVisible = true;
            });
          } catch (_) {
            this.carouselVisible = true;
          }
          // 轮播图淡入完成后，渐显渐变网点
          setTimeout(() => {
            this.getUIContext().animateTo({ duration: 800, curve: Curve.FastOutSlowIn }, () => {
              this.dotsOpacity = 1;
            });
          }, 800);
        }, 500);
      } else if (this.isLandscape && this.showHomeCarouselLandscape && this.banners.length > 0) {
        // 横屏：左固定轮播图淡出→更新→淡入
        try {
          this.getUIContext().animateTo({ duration: 400, curve: Curve.FastOutSlowIn }, () => {
            this.landscapeCarouselVisible = false;
          });
        } catch (_) {
          this.landscapeCarouselVisible = false;
        }
        setTimeout(() => {
          this.updateBanners(uniqueItems);
          if (!this.bgCoverUrl && this.banners.length > 0) {
            this.bgCoverUrl = this.banners[0].coverUrl;
          }
          try {
            this.getUIContext().animateTo({ duration: 800, curve: Curve.FastOutSlowIn }, () => {
              this.landscapeCarouselVisible = true;
            });
          } catch (_) {
            this.landscapeCarouselVisible = true;
          }
        }, 500);
      } else {
        // 首次加载或轮播图被禁用
        this.updateBanners(uniqueItems);
        if (!this.bgCoverUrl && this.banners.length > 0) {
          this.bgCoverUrl = this.banners[0].coverUrl;
          // ⭐ bgCoverUrl 首次设置，从透明度 0 平滑淡入
          try {
            this.getUIContext().animateTo({ duration: 1500, curve: Curve.FastOutSlowIn }, () => {
              this.bgFade = 1;
            });
          } catch (_) {
            this.bgFade = 1;
          }
        }
        if (this.showHomeCarouselPortrait && !this.isLandscape && this.banners.length > 0) {
          // 重置网点透明度（onPageShow 首次调用时可能已设为 1，此处确保从 0 开始渐显）
          this.dotsOpacity = 0;
          // 等待封面开始加载后再一起渐显，避免先显示边框和黑色背景
          setTimeout(() => {
            try {
              this.getUIContext().animateTo({ duration: 600, curve: Curve.FastOutSlowIn }, () => {
                this.carouselVisible = true;
              });
            } catch (_) {
              this.carouselVisible = true;
            }
          }, 400);
          // 首次加载：轮播淡入完成后渐显渐变网点
          setTimeout(() => {
            this.getUIContext().animateTo({ duration: 800, curve: Curve.FastOutSlowIn }, () => {
              this.dotsOpacity = 1;
            });
          }, 1500);
        } else if (this.isLandscape && this.showHomeCarouselLandscape && this.banners.length > 0) {
          // 横屏首次加载：淡入左侧固定轮播图
          try {
            this.getUIContext().animateTo({ duration: 1500, curve: Curve.FastOutSlowIn }, () => {
              this.landscapeCarouselVisible = true;
            });
          } catch (_) {
            this.landscapeCarouselVisible = true;
          }
        } else {
          this.carouselVisible = false;
          this.landscapeCarouselVisible = false;
        }
      }
      this.pageNum = 2;
      logInfo(`刷新成功，获取到 ${uniqueItems.length} 条新视频，合并后共 ${combinedItems.length} 条`);

      const count = this.dataSource.totalCount();
      this.cardsVisible = new Array(count).fill(false);
      this.cardDelays = [];
      this.cardTranslateYs = [];
      for (let i = 0; i < count; i++) {
        this.cardDelays.push(Math.floor(Math.random() * 600));
        this.cardTranslateYs.push(Math.floor(Math.random() * 40) + 15);
      }
      this.isBulkLoading = true;
      if (this.da) {
        const newVisible = new Array<boolean>(count).fill(true);
        this.cardsVisible = newVisible;
        this.isBulkLoading = false;
        this.isLoading = false;
      } else {
        setTimeout(() => {
          // ⭐ 开启卡片动画 + 关闭加载态
          this.animateCards = true;
          this.isLoading = false;
          const maxDelay = this.cardDelays.length > 0 ? Math.max(...this.cardDelays) : 0;
          for (let i = 0; i < count; i++) {
            setTimeout(() => {
              const newVisible = [...this.cardsVisible];
              newVisible[i] = true;
              this.cardsVisible = newVisible;
            }, this.cardDelays[i]);
          }
          setTimeout(() => {
            this.isBulkLoading = false;
          }, maxDelay + 1600);
        }, 120);
      }

      // ⭐ 刷新时不设置 hasMore = false，让加载更多时再判断
      // 只有返回 0 条数据才说明没有更多了
    } else {
      this.hasMore = false;
    }
    this.isLoading = false;
  }


  async loadMore() {
    if (this.isLoadingMore || !this.hasMore) return;
    this.isLoadingMore = true;

    let addedCount = 0;
    let attempt = 0;
    const maxAttempt = this.maxRetryPages;

    while (attempt < maxAttempt && addedCount === 0) {
      // ⭐ 使用 refreshIdx 而不是 pageNum，确保索引一致
      this.refreshIdx++;
      // ⭐ 调用服务层过滤（屏蔽UP主、已看视频）
      let items = await this.fetchRecommendVideos(this.refreshIdx, this.pageSize);
      logInfo(`[调试] loadMore: 调用 filterRecommendList 前，原始数量: ${items.length}`);
      items = UserBehaviorService.filterRecommendList(items);
      logInfo(`[调试] loadMore: 调用 filterRecommendList 后，过滤数量: ${items.length}`);
      if (items.length === 0) break;
      // ⭐ 过滤已看过的视频
      const filteredItems = this.filterWatched(items);
      const beforeCount = this.dataSource.totalCount();
      const merged = this.mergeUnique(this.dataSource.getRawItems(), filteredItems);
      const newCount = merged.length - beforeCount;
      if (newCount > 0) {
        this.dataSource.setRawItems(merged);
        this.dataSource.notifyDataAdd(beforeCount);
        const newTotal = merged.length;
        const currentVisible = this.cardsVisible.length;
        if (newTotal > currentVisible) {
          const addCount = newTotal - currentVisible;
          const extendedVisible = [...this.cardsVisible, ...new Array<boolean>(addCount).fill(false)];
          this.cardsVisible = extendedVisible;
          for (let i = 0; i < addCount; i++) {
            const globalIdx = currentVisible + i;
            this.cardDelays[globalIdx] = Math.floor(Math.random() * 180) + i * 55;
            this.cardTranslateYs[globalIdx] = Math.floor(Math.random() * 55) + 35;
          }
          if (this.da) {
            const newVisible = [...this.cardsVisible];
            for (let i = 0; i < addCount; i++) {
              newVisible[currentVisible + i] = true;
            }
            this.cardsVisible = newVisible;
          } else {
            setTimeout(() => {
              for (let i = 0; i < addCount; i++) {
                const globalIdx = currentVisible + i;
                setTimeout(() => {
                  const newVisible = [...this.cardsVisible];
                  newVisible[globalIdx] = true;
                  this.cardsVisible = newVisible;
                }, this.cardDelays[globalIdx]);
              }
            }, 100);
          }
        }
        addedCount = newCount;
        logInfo(`加载更多成功，获取到 ${newCount} 条新内容，refreshIdx=${this.refreshIdx}`);
        break;
      } else {
        attempt++;
      }
    }

    if (addedCount === 0) {
      this.hasMore = false;
    }
    this.isLoadingMore = false;
  }

  async getStatusBarHeight() {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass: window.Window = await window.getLastWindow(context);
      const avoidArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const h = this.getUIContext().px2vp(avoidArea.topRect.height);
      if (h > 0) {
        this.statusBarHeight = h;
        AppStorage.setOrCreate('realStatusBarHeight', h);
      }
    } catch (error) {
      // 保留已有值
    }
  }

  formatCount(count: number): string {
    if (count >= 100000000) return (count / 100000000).toFixed(1) + '亿';
    if (count >= 10000) return (count / 10000).toFixed(1) + '万';
    return count.toString();
  }

  getPlayCountColor(count: number): string {
    if (count >= 10000000) return '#FF0000';
    if (count >= 3000000) return '#C2185B';
    if (count >= 1000000) return '#E65100';
    if (count >= 500000) return '#FF8C00';
    if (count >= 100000) return '#FFB800';
    if (count >= 50000) return '#4A90D9';
    return '#999999';
  }

  private onCardClick(item: RecommendItem) {
    // 自动记录点击播放的视频（用于去重）
    this.autoRecordWatched(item);
    // 保存被点击的轮播索引（页面隐藏时 autoPlay 会改变 currentSwiperIndex）
    this.clickedCarouselIndex = this.animatedSwiperIndex;

    // ⭐ 番剧卡片（App 推荐 feed 的 bangumi）：走 PGC 入口，
    //   避免把分集/季id当 aid 传入播放页被解析成撞号的 UGC 视频
    if (item.pgcEpId > 0) {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/VideoPlayerPage',
        params: {
          epId: item.pgcEpId,
          // ⭐ 一并带上 seasonId：PGC 心跳（type=4）缺 sid 会被 B 站静默丢弃，
          //   只传 epId 时播放页才需要多打一次季接口反查
          seasonId: item.pgcSeasonId,
          title: item.title,
          coverUrl: item.coverUrl,
          duration: item.duration
        }
      }).catch((err: Error) => logError(`跳转播放页失败: ${err.message}`));
      return;
    }
    if (item.pgcSeasonId > 0) {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/VideoPlayerPage',
        params: {
          mediaId: item.pgcSeasonId,
          title: item.title,
          coverUrl: item.coverUrl,
          duration: item.duration
        }
      }).catch((err: Error) => logError(`跳转播放页失败: ${err.message}`));
      return;
    }

    // ⭐ 预热详情（fire-and-forget）：App 推荐 feed 只有 aid，播放页必须先把 aid 换成
    //   bvid(+cid) 才能发 playurl。在转场开始的这一刻就发出去，把这次 RTT 藏进
    //   "页面转场 + 播放器 surface 初始化"（实测约 500ms）里，播放页则直接命中缓存。
    prefetchVideoDetail(item.aid > 0 ? String(item.aid) : item.id);

    this.getUIContext().getRouter().pushUrl({
      url: 'pages/VideoPlayerPage',
      params: {
        bvid: item.id,
        aid: item.aid,  // ⭐ App API 的项只有 aid，没有 bvid
        cid: item.cid,
        title: item.title,
        ownerName: item.ownerName,
        ownerFace: item.ownerFace,
        duration: item.duration,
        pubdate: item.pubdate,
        view: item.playCount,
        coverUrl: item.coverUrl
      }
    }).catch((err: Error) => logError(`跳转播放页失败: ${err.message}`));
  }

  /**
   * ⭐ 显示视频菜单（官方图库式"丝滑变形"）
   * 1. getRectangleById 取源封面屏幕 rect，浮层以相同 rect 上树（同帧隐藏源封面 → 无缝交换）
   * 2. 下一帧 animateTo 驱动浮层 position/scale/圆角逐帧变形到屏幕中央（弹簧过冲）
   * 3. 遮罩(backdropBlur)与胶囊菜单同步出现，模糊渐强
   */
  private showVideoMenu(item: RecommendItem): void {
    this.selectedMenuItem = item;
    try {
      const ui = this.getUIContext();
      // ⚠️ getRectangleById 的 windowOffset/size 单位是 **px**（SDK d.ts 明确标注），必须经 px2vp 转换。
      // 弹窗挂在 bindContentCover 模态层（全窗口，含状态栏/Tab 栏上方），
      // 模态内容区原点 = 窗口原点，故 position 直接使用窗口坐标（无需减页面偏移）。
      const rect = ui.getComponentUtils().getRectangleById(`cover_${item.id}`);
      const displayInfo = display.getDefaultDisplaySync();
      const screenW: number = ui.px2vp(displayInfo.width);
      const screenH: number = ui.px2vp(displayInfo.height);
      const isLandscape: boolean = screenW > screenH;
      // 目标布局：竖屏=85% 宽 16:9 封面 + 下方胶囊列（组合垂直居中）；
      //          横屏=封面居左 + 胶囊列居右（组合水平居中）
      const menuH: number = 6 * 46 + 5 * 10;
      let dstW: number;
      let dstH: number;
      let dstX: number;
      let dstY: number;
      if (isLandscape) {
        // 横屏：封面高度取屏高 55%（16:9 反推宽度），胶囊列固定宽 220 居右
        dstH = Math.round(screenH * 0.55);
        dstW = Math.round(dstH * 16 / 9);
        const gapH: number = 24;
        const menuW: number = 220;
        const totalW: number = dstW + gapH + menuW;
        const groupX: number = Math.round((screenW - totalW) / 2);
        dstX = groupX;
        dstY = Math.round((screenH - dstH) / 2);
        this.menuW = menuW;
        this.menuX = dstX + dstW + gapH;
        this.menuY = Math.round((screenH - menuH) / 2);
      } else {
        // 竖屏：85% 宽 16:9 封面 + 间隙 + 胶囊列
        dstW = Math.round(screenW * 0.85);
        dstH = Math.round(dstW * 9 / 16);
        const gap: number = 12;
        const totalH: number = dstH + gap + menuH;
        dstX = Math.round((screenW - dstW) / 2);
        dstY = Math.round((screenH - totalH) / 2);
        this.menuW = dstW;
        this.menuX = dstX;
        this.menuY = dstY + dstH + gap;
      }
      // 源封面 rect（px→vp，窗口坐标）
      const srcW: number = ui.px2vp(rect.size.width);
      const srcH: number = ui.px2vp(rect.size.height);
      const srcCX: number = ui.px2vp(rect.windowOffset.x) + srcW / 2;
      const srcCY: number = ui.px2vp(rect.windowOffset.y) + srcH / 2;
      const srcScale: number = srcW / dstW;
      // 保存源参数（关闭回弹）
      this.morphSrcX = srcCX - dstW / 2;
      this.morphSrcY = srcCY - dstH / 2;
      this.morphSrcScale = srcScale;
      this.morphSrcRadius = this.cardListBorderRadius / srcScale; // 圆角补偿：视觉圆角=卡片圆角
      // 浮层初值 = 源 rect（与源封面完全重合）；遮罩/菜单淡入初值置 0（上树帧无模糊闪烁）
      this.morphDstW = dstW;
      this.morphX = this.morphSrcX;
      this.morphY = this.morphSrcY;
      this.morphScale = srcScale;
      this.morphRadius = this.morphSrcRadius;
      this.maskOpacity = 0;
      this.menuOpacity = 0;
      this.menuScale = 0.92;
      // 隐藏源封面 + 模态上树（同帧无缝交换；模态层盖住 Tab 栏 → 模糊覆盖全窗口）
      AppStorage.setOrCreate('morphActiveCoverId', item.id);
      this.isMenuSheetVisible = true;
      // 下一帧：丝滑变形（position/scale/圆角逐帧插值）+ 遮罩模糊渐强 + 菜单稍后弹出
      if (this.morphTimerId >= 0) {
        clearTimeout(this.morphTimerId);
      }
      this.morphTimerId = setTimeout(() => {
        const uic = this.getUIContext();
        uic.animateTo({
          duration: 800,
          curve: curves.springCurve(0.15, 1, 80, 12)
        }, () => {
          this.morphX = dstX;
          this.morphY = dstY;
          this.morphScale = 1;
          this.morphRadius = this.cardListBorderRadius;
        });
        uic.animateTo({
          duration: 250,
          curve: Curve.EaseOut
        }, () => {
          this.maskOpacity = 1;
        });
        uic.animateTo({
          delay: 120,
          duration: 500,
          curve: curves.springCurve(0.15, 1, 80, 12)
        }, () => {
          this.menuOpacity = 1;
          this.menuScale = 1;
        });
      }, 0);
    } catch (err) {
      // 兜底：rect 获取失败时直接弹（无变形动画）
      logError(`[视频菜单] 获取封面位置失败: ${errMsg(err)}`);
      this.isMenuSheetVisible = true;
    }
  }

  /**
   * ⭐ 关闭视频菜单：浮层反向变形回源封面位置（丝滑回弹）+ 遮罩/菜单同步淡出。
   * ⚠️ 不能立即卸载模态（exit transition 无法承载属性回弹动画）——
   *    保持挂载 320ms 让回弹动画跑完，再同帧卸载模态 + 恢复源封面（无缝换回）。
   */
  private closeVideoMenu(): void {
    this.getUIContext().animateTo({
      duration: 300,
      curve: Curve.EaseOut
    }, () => {
      this.morphX = this.morphSrcX;
      this.morphY = this.morphSrcY;
      this.morphScale = this.morphSrcScale;
      this.morphRadius = this.morphSrcRadius;
      this.maskOpacity = 0;
      this.menuOpacity = 0;
      this.menuScale = 0.92;
    });
    if (this.morphTimerId >= 0) {
      clearTimeout(this.morphTimerId);
      this.morphTimerId = -1;
    }
    this.morphTimerId = setTimeout(() => {
      this.isMenuSheetVisible = false;
      AppStorage.setOrCreate('morphActiveCoverId', '');
    }, 320);
  }

  /**
   * ⭐ 横竖屏切换时若长按菜单弹窗处于打开状态 → 自动关闭。
   * ⚠️ 旋转后浮层/源封面的位置全部失效（列表重排、坐标系翻转），
   *    不做回弹动画，直接同帧卸载模态 + 恢复源封面显示。
   */
  private dismissMenuIfOpen(): void {
    if (!this.isMenuSheetVisible) {
      return;
    }
    if (this.morphTimerId >= 0) {
      clearTimeout(this.morphTimerId);
      this.morphTimerId = -1;
    }
    this.isMenuSheetVisible = false;
    this.maskOpacity = 0;
    this.menuOpacity = 0;
    this.menuScale = 0.92;
    AppStorage.setOrCreate('morphActiveCoverId', '');
    logInfo('[视频菜单] 横竖屏切换，自动关闭弹窗');
  }

  /**
   * ⭐ 保存视频封面到系统图库（免权限）
   * http 下载封面 → 沙箱临时文件 → showAssetsCreationDialog（系统"保存到图库"确认框）
   * → 用返回的目标 URI 写入媒体库
   */
  private async saveCover(): Promise<void> {
    const item = this.selectedMenuItem;
    if (!item || !item.coverUrl) {
      this.getUIContext().getPromptAction().showToast({ message: '封面无效' });
      return;
    }
    try {
      // 1. 下载封面（Accept 强制 jpeg 优先，避免 CDN 返回 webp）
      const client = http.createHttp();
      const reqHeader: Record<string, string> = { 'Accept': 'image/jpeg,image/png,image/*;q=0.8' };
      const response = await client.request(item.coverUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: reqHeader,
        connectTimeout: 10000,
        readTimeout: 15000
      });
      const buffer = response.result as ArrayBuffer;
      client.destroy();
      if (response.responseCode !== 200 || buffer.byteLength === 0) {
        this.getUIContext().getPromptAction().showToast({ message: `封面下载失败(${response.responseCode})` });
        return;
      }
      // 2. 扩展名判定：优先按响应 Content-Type（B 站 CDN 可能对 .jpg URL 返回 webp，
      //    扩展名与实际内容不匹配会被图库以 -2004 拒绝），URL 后缀兜底
      let ext: string = 'jpg';
      const headers = response.header as Record<string, string>;
      const contentType: string = (headers['content-type'] ?? headers['Content-Type'] ?? '').toLowerCase();
      if (contentType.indexOf('webp') >= 0) {
        ext = 'webp';
      } else if (contentType.indexOf('png') >= 0) {
        ext = 'png';
      } else if (contentType.indexOf('gif') >= 0) {
        ext = 'gif';
      } else if (contentType.indexOf('jpeg') >= 0 || contentType.indexOf('jpg') >= 0) {
        ext = 'jpg';
      } else {
        const m = item.coverUrl.split('?')[0].match(/\.(jpg|jpeg|png|webp|gif)$/i);
        if (m) {
          ext = m[1].toLowerCase();
        }
      }
      const context = getContext(this) as common.UIAbilityContext;
      const tmpPath = `${context.cacheDir}/cover_${item.id}.${ext}`;
      const tmpFile = fileIo.openSync(tmpPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(tmpFile.fd, buffer);
      fileIo.closeSync(tmpFile);
      // 3. 系统"保存到图库"确认框（用户确认后返回可写目标 URI；取消返回空数组）
      // ⚠️ srcFileUris 必须用 fileUri.getUriFromPath 生成合法文件 URI（file://<bundle>/...），
      //    手工拼 "file://<path>" 无法被框架识别 → 对话框进程判定参数无效 →
      //    不加载 UI → SetUIContent 4 秒超时 → 14000011 Internal system error
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const creationConfigs: Array<photoAccessHelper.PhotoCreationConfig> = [
        { photoType: photoAccessHelper.PhotoType.IMAGE, title: `bili_cover_${item.id}`, fileNameExtension: ext }
      ];
      const srcUri: string = fileUri.getUriFromPath(tmpPath);
      const dstUris: Array<string> =
        await helper.showAssetsCreationDialog([srcUri], creationConfigs);
      if (dstUris.length === 0) {
        logInfo('[保存封面] 用户取消保存');
        return;
      }
      // 4. 将封面字节写入目标 URI（媒体库）
      const dstFile = fileIo.openSync(dstUris[0], fileIo.OpenMode.READ_WRITE);
      fileIo.writeSync(dstFile.fd, buffer);
      fileIo.closeSync(dstFile);
      logInfo(`[保存封面] 成功: id=${item.id}, ext=${ext}, size=${buffer.byteLength}`);
      this.getUIContext().getPromptAction().showToast({ message: '封面已保存' });
    } catch (err) {
      logError(`[保存封面] 异常: ${errMsg(err)}`);
      this.getUIContext().getPromptAction().showToast({ message: `保存失败: ${errMsg(err)}` });
    }
  }

  /**
   * ⭐ 处理不感兴趣
   */
  private async handleDislike(item: RecommendItem): Promise<void> {
    try {
      // 1. 发送反馈到B站
      const result = await sendDislikeFeedback(item.id, 1);

      // 2. 无论API成功与否，都本地移除（即使B站服务不可用，也立即生效）
      this.removeVideoFromList(item.id);

      // 3. 加入本地去重集合（带时间戳）
      this.watchedVideoIds.set(item.id, Date.now());
      this.seenVideosDirty = true;  // ⭐ 标记脏数据，使 saveSeenVideos 真正写入持久化
      await this.saveSeenVideos();  // 保存到持久化存储

      // 4. ⭐ 同步到 UserBehaviorService 的 AppStorage Set，使 filterRecommendList 也能过滤
      UserBehaviorService.addWatchedVideo(item.id);

      if (result.success) {
        this.getUIContext().getPromptAction().showToast({ message: '已减少此类推荐', duration: 1500 });
        logInfo(`[不感兴趣] ✅ ${item.id} - ${item.title}`);
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '已移除（服务器反馈暂不可用）', duration: 1500 });
        logInfo(`[不感兴趣] ⚠️ 本地移除 ${item.id}（${result.message}）`);
      }
    } catch (err) {
      logError(`[不感兴趣] 异常: ${err}`);
      // 即使异常也尝试本地移除
      try {
        this.removeVideoFromList(item.id);
      } catch (_) { }
      this.getUIContext().getPromptAction().showToast({ message: '已移除', duration: 1500 });
    }
  }
  /**
   * ⭐ 屏蔽UP主
   */
  private async handleBlockUploader(item: RecommendItem): Promise<void> {
    try {
      // 1. 发送反馈到B站（传入bvid和UP主mid）
      const result = await sendDislikeUpFeedback(item.id, item.ownerMid);

      // 2. ⭐ 添加到本地屏蔽列表（持久化存储）
      UserBehaviorService.addBlockedUploader(item.ownerMid);

      // 3. 从列表中移除该UP主的所有视频
      this.removeVideosByUploader(item.ownerMid);

      if (result.success) {
        this.getUIContext().getPromptAction().showToast({ message: `已屏蔽 ${item.ownerName}`, duration: 1500 });
        logInfo(`[屏蔽UP主] ✅ ${item.ownerMid} - ${item.ownerName}`);
      } else {
        this.getUIContext().getPromptAction().showToast({ message: `已本地屏蔽 ${item.ownerName}`, duration: 1500 });
        logInfo(`[屏蔽UP主] ⚠️ 本地屏蔽 ${item.ownerMid}（${result.message}）`);
      }
    } catch (err) {
      logError(`[屏蔽UP主] 异常: ${err}`);
      // 即使异常也尝试本地屏蔽
      try {
        UserBehaviorService.addBlockedUploader(item.ownerMid);
        this.removeVideosByUploader(item.ownerMid);
      } catch (_) { }
      this.getUIContext().getPromptAction().showToast({ message: `已本地屏蔽 ${item.ownerName}`, duration: 1500 });
    }
  }

  /**
   * ⭐ 拉黑UP主（API拉黑）
   */
  private async handleBlacklistUploader(item: RecommendItem): Promise<void> {
    try {
      const result = await blacklistUploader(Number(item.ownerMid));
      if (result) {
        // 拉黑成功，也加入本地屏蔽列表
        UserBehaviorService.addBlockedUploader(item.ownerMid);
        this.removeVideosByUploader(item.ownerMid);
        this.getUIContext().getPromptAction().showToast({ message: `已拉黑 ${item.ownerName}`, duration: 1500 });
        logInfo(`[拉黑UP主] ${item.ownerMid} - ${item.ownerName}`);
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '拉黑失败，请检查登录状态', duration: 2000 });
      }
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: '操作失败', duration: 1500 });
    }
  }

  /**
   * ⭐ 标记为看过类似视频
   */
  private async handleSeenBefore(item: RecommendItem): Promise<void> {
    // 加入本地去重集合
    this.watchedVideoIds.set(item.id, Date.now());
    await this.saveSeenVideos();  // 保存到持久化存储

    // 从列表中移除
    this.removeVideoFromList(item.id);

    try {
      this.getUIContext().getPromptAction().showToast({ message: '已标记为看过', duration: 1500 });
    } catch (err) {
      logWarn(`showToast 异常: ${errMsg(err)}`);
    }
  }

  /**
   * ⭐ 从列表中移除单个视频
   */
  private removeVideoFromList(bvid: string) {
    const items = this.dataSource.getRawItems();
    const newItems = items.filter(item => item.id !== bvid);
    this.dataSource.reloadItems(newItems);

    // 更新可见状态数组
    this.cardsVisible = new Array(newItems.length).fill(true);
  }

  /**
   * ⭐ 移除某UP主的所有视频
   */
  private removeVideosByUploader(mid: string) {
    const items = this.dataSource.getRawItems();
    const newItems = items.filter(item => item.ownerMid !== mid);
    this.dataSource.reloadItems(newItems);

    // 更新可见状态数组
    this.cardsVisible = new Array(newItems.length).fill(true);
  }

  private formatPlayCount(count: number): string {
    if (count >= 100000000) return (count / 100000000).toFixed(1) + '亿';
    if (count >= 10000) return (count / 10000).toFixed(1) + '万';
    return count.toString();
  }

  private handlePinch(scale: number) {
    let changed = false;
    if (this.isLandscape) {
      // 轮播开启时横屏可选2-3列，关闭时3-4列
      const minCols = this.showHomeCarouselLandscape ? 2 : 3;
      const maxCols = this.showHomeCarouselLandscape ? 3 : 4;
      if (scale > 1.05 && this.columnCount < maxCols) {
        this.columnCount++;
        changed = true;
      } else if (scale < 0.95 && this.columnCount > minCols) {
        this.columnCount--;
        changed = true;
      }
    } else {
      if (scale > 1.05 && this.columnCount < 3) {
        this.columnCount = 3;
        changed = true;
      } else if (scale < 0.95 && this.columnCount > 2) {
        this.columnCount = 2;
        changed = true;
      }
    }
    if (changed) {
      this.saveCurrentColumnCount();
      try {
        this.getUIContext().getPromptAction().showToast({ message: `${this.columnCount}列`, duration: 800 });
      } catch (err) {
        logWarn(`showToast 异常: ${errMsg(err)}`);
      }
    }
  }

  /**
   * ⭐ 长按菜单弹窗内容（官方图库式丝滑变形）
   * 层级：模糊遮罩（渐强/渐弱）→ 变形封面浮层（position/scale/圆角逐帧动画）→ 胶囊菜单
   */
  @Builder
  menuSheetContent() {
    Column() {
      // ① 全屏模糊遮罩（无半透明色，纯大半径 backdropBlur；opacity 状态驱动=模糊渐强/渐弱）
      Column()
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .backdropBlur(60)
        .opacity(this.maskOpacity)
        .onClick(() => {
          this.closeVideoMenu();
        })

      // ② 变形封面浮层：长按时与源封面重合上树，animateTo 逐帧变形成中央大图
      Image(this.selectedMenuItem?.coverUrl ?? '')
        .width(this.morphDstW)
        .aspectRatio(16 / 9)
        .objectFit(ImageFit.Cover)
        .position({ x: this.morphX, y: this.morphY })
        .scale({ x: this.morphScale, y: this.morphScale })
        .borderRadius(this.morphRadius)
        .clip(true)

      // ③ 菜单选项（每个选项独立胶囊，参考私信列表样式；固定目标位置）
      Column({ space: 10 }) {
        // 不感兴趣
        this.MenuItemButton('不感兴趣', () => {
          this.closeVideoMenu();
          if (this.selectedMenuItem) {
            this.handleDislike(this.selectedMenuItem);
          }
        })

        // 屏蔽UP主
        this.MenuItemButton('屏蔽UP主', () => {
          this.closeVideoMenu();
          if (this.selectedMenuItem) {
            this.handleBlockUploader(this.selectedMenuItem);
          }
        })

        // 拉黑UP主
        this.MenuItemButton('拉黑UP主', () => {
          this.closeVideoMenu();
          if (this.selectedMenuItem) {
            this.handleBlacklistUploader(this.selectedMenuItem);
          }
        })

        // 看过类似
        this.MenuItemButton('看过类似', () => {
          this.closeVideoMenu();
          if (this.selectedMenuItem) {
            this.handleSeenBefore(this.selectedMenuItem);
          }
        })

        // 保存视频封面
        this.MenuItemButton('保存视频封面', () => {
          this.closeVideoMenu();
          this.saveCover();
        })

        // 取消
        this.MenuItemButton('取消', () => {
          this.closeVideoMenu();
        }, true)
      }
      .width(this.menuW)
      .position({ x: this.menuX, y: this.menuY })
      .opacity(this.menuOpacity)
      .scale({ x: this.menuScale, y: this.menuScale })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * ⭐ 菜单项按钮：独立胶囊样式（参考私信列表——cardItemBg/cardItemBorder 联动「卡片样式」设置）
   */
  @Builder
  MenuItemButton(text: string, onClick: () => void, isCancelButton: boolean = false) {
    Text(text)
      .fontSize(15)
      .fontColor(isCancelButton ? '#FFFFFF' : (this.isDarkMode ? '#FFFFFF' : '#000000'))
      .width('100%')
      .height(46)
      .textAlign(TextAlign.Center)
      .backgroundColor(isCancelButton
        ? this.customThemeColor
        : cardItemBg(this.isDarkMode, this.cardTransparentStyle, this.cardBgOpacity))
      .borderRadius(23)
      .border({
        width: !isCancelButton && this.cardTransparentStyle ? this.cardBorderWidth : 0,
        color: cardItemBorder(this.isDarkMode, this.cardTransparentStyle,
          this.cardBorderOpacity, this.cardBorderFollowTheme, this.customThemeColor)
      })
      .onClick(() => onClick())
  }

  @Builder
  customRefreshComponent() {
    Stack() {
      Column() {
        if (this.showSearchIcon) {
          Image($r('app.media.ic_public_search_filled'))
            .width(32)
            .height(32)
            .objectFit(ImageFit.Contain)
            .fillColor(this.customThemeColor)
        } else {
          LoadingProgress()
            .width(32)
            .height(32)
            .color(this.customThemeColor)
        }
        Text(this.refreshBuilderText)
          .fontSize(12)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Center)
    }
    .alignContent(Alignment.Center)
    .width('100%')
    .height(60)
  }

  /**
   * ⭐ "上次看到这里" 分隔卡片
   */
  @Builder
  RefreshSeparatorCard() {
    Column() {
      Column() {
        Image($r('app.media.arrow_clockwise'))
          .width(40).height(40)
          .fillColor(this.customThemeColor)
          .margin({ bottom: 6 })
        Text('上次看到这里')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.customThemeColor)
        Text('点击刷新，加载最新内容')
          .fontSize(12)
          .fontColor(this.customThemeColor)
          .opacity(0.7)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .height(100)
      .backgroundColor(this.isDarkMode ? '#2A2A2A' : '#F0F8FF')
      .borderRadius(16)
      .borderWidth(1)
      .borderColor(this.customThemeColor)
      .opacity(0.8)
      .padding({ left: 16, right: 16 })
      .clickEffect({ level: 0, scale: 0.95 })
      .onClick(() => {
        if (!this.manualLoading) {
          // 震动反馈
          try {
            VibrateUtils.vibrateTime(20);
          } catch (_e) { }
          // 回到顶部
          if (this.externalScroller) {
            this.externalScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300 } });
          }
          this.manualRefresh();
        }
      })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  build() {
    Stack() {
      // ★ 全页模糊封面渐变背景（由方向对应的轮播背景开关控制）
      // ⭐ 30vp 圆角裁剪：开启轮播背景时，推荐页背景图与频道页统一呈圆角卡片
      if ((this.isLandscape ? this.showHomeCarouselLandscape : this.showHomeCarouselPortrait) && (this.isLandscape ? this.showCarouselBgLandscape : this.showCarouselBgPortrait)) {
        Stack() {
          if (this.lastCoverUrl) {
            Image(this.lastCoverUrl)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .blur(150)
              .opacity(1 - this.bgFade)
          }
          if (this.bgCoverUrl) {
            Image(this.bgCoverUrl)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .blur(150)
              .opacity(this.bgFade)
          }
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              direction: GradientDirection.Bottom,
              colors: [['rgba(0,0,0,0)', 0.3], [this.isDarkMode ? '#1A1A1A' : '#F5F5F5', 0.9]]
            })
        }
        .width('100%')
        .height('100%')
        // ⭐ 背景图仅保留顶部圆角（topLeft/topRight 由"首页轮播→背景圆角"滑块控制，默认 30，底部直角，贴合状态栏边缘）
        .borderRadius({ topLeft: this.carouselBgRadius, topRight: this.carouselBgRadius, bottomLeft: 0, bottomRight: 0 })
        .clip(true)
      }
      Refresh({ refreshing: $$this.isRefreshing, builder: this.customRefreshComponent() }) {
        Scroll(this.externalScroller!) {
          Column() {
              // ★ 轮播图：播放量最高的 3 个视频 — cover-flow 风格
              // ⭐ 始终渲染（不在 else 分支），opacity 控制显隐动画
              if (this.showHomeCarouselPortrait && !this.isLandscape) {
                Stack() {
                  // ★ 渐变网点装饰层（轮播加载完成后渐显）
                  // ⭐ opacity 取两者之积：dotsOpacity=触摸/翻页/加载的显隐（400/600/800ms 缓动），
                  //    carouselDotsFade=上滑时按滚动位移淡出（与标题胶囊同曲线）。详见状态声明处注释。
                  Image($r('app.media.gradient_dots'))
                    .width('65%')
                    .aspectRatio(1)
                    .objectFit(ImageFit.Cover)
                    .position({ x: '17.5%', y: 85 })
                    .scale({ x: 1.55, y: 1.55 })
                    .opacity(this.dotsOpacity * this.carouselDotsFade)
                    .animation({ duration: 800, curve: Curve.FastOutSlowIn })
                    .hitTestBehavior(HitTestMode.Transparent)
                  Swiper(this.portraitSwiperController) {
                  ForEach(this.banners, (item: RecommendItem, index: number) => {
                    Column() {
                      Stack({ alignContent: Alignment.Bottom }) {
                        Image(item.coverUrl)
                          .width('100%')
                          .aspectRatio(16 / 9)
                          .objectFit(ImageFit.Cover)
                          .borderRadius(this.cardListBorderRadius)
                          .backgroundColor('#E0E0E0')
                          .blur(index === this.animatedSwiperIndex ? 0 : 6)
                          .border({
                            width: this.cardTransparentStyle ? this.cardBorderWidth : 0,
                            color: this.cardTransparentStyle
                              ? (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)')
                              : Color.Transparent
                          })
                          .align(Alignment.Top)

                      }
                      .width('100%')
                      .borderRadius(this.cardListBorderRadius)
                      .clip(true)
                      // ★ 标题（居中）沉浸光感胶囊遮罩 — 与左上角导航胶囊同款 HdsMiniBarButton 系统材质
                      // Stack 包裹：@BuilderParam 尾随闭包组件不能直接链式挂通用属性
                      Stack({ alignContent: Alignment.Center }) {
                        HdsMiniBarButton({
                          barWidth: this.resolveCarouselTitleBarWidth(),
                          barHeight: this.carouselTitleCapsuleHeight,
                          contentPadding: 4,
                          materialType: hdsMaterial.MaterialType.IMMERSIVE,
                          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
                          barOverlap: true,
                          barPosition: BarPosition.End,
                          onButtonClick: (): void => {
                            this.onCardClick(item)
                          }
                        }) {
                          Text(item.title)
                            .fontSize(this.carouselTitleFontSize)
                            .fontWeight(this.resolveCarouselTitleFontWeight())
                            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                            .letterSpacing(this.carouselTitleLetterSpacing)
                            .textAlign(TextAlign.Center)
                            .width('100%')
                        }
                      }
                      // 与导航胶囊一致：外层不裁剪，避免 Swiper/容器裁剪影响沉浸光感阴影
                      .clip(false)
                      .margin({ top: 12 })
                      .opacity(index === this.currentSwiperIndex ? this.carouselTitleOpacity : 0)
                      .animation({ duration: 800, curve: Curve.FastOutSlowIn })
                    }
                    .width('100%')
                    .scale({
                      x: index === this.animatedSwiperIndex ? 1.0 : 0.85,
                      y: index === this.animatedSwiperIndex ? 1.0 : 0.85
                    })
                    .opacity(index === this.animatedSwiperIndex ? 1.0 : 0.7)
                    .animation({ curve: curves.springMotion(0.5, 0.85, 0) })
                    .onClick(() => this.onCardClick(item))
                  }, (item: RecommendItem) => item.id)
                }
                .width('100%')
                .height(this.carouselHeight)
                .prevMargin(this.carouselMargin)
                .nextMargin(this.carouselMargin)
                .itemSpace(4)
                .curve(Curve.FastOutSlowIn)
                .indicator(false)
                .autoPlay(true)
                // 不裁剪子内容，避免沉浸光感胶囊阴影/光效被 Swiper 裁掉
                .clip(false)
                .interval(4000)
                .loop(true)
                .index(this.currentSwiperIndex)
                .onAnimationStart((_index: number, targetIndex: number) => {
                  this.animatedSwiperIndex = targetIndex;
                  this.lastCoverUrl = this.bgCoverUrl;
                  this.bgCoverUrl = this.banners[targetIndex].coverUrl;
                  this.bgFade = 0;
                  this.getUIContext().animateTo({ duration: 1000, curve: Curve.FastOutSlowIn }, () => {
                    this.bgFade = 1;
                  });
                  // 轮播开始移动时渐隐网点，为切换后的渐显做准备
                  this.getUIContext().animateTo({ duration: 600, curve: Curve.FastOutSlowIn }, () => {
                    this.dotsOpacity = 0;
                  });
                })
                .onChange((index: number) => {
                  this.currentSwiperIndex = index;
                  // 轮播到位后渐显网点
                  this.getUIContext().animateTo({ duration: 800, curve: Curve.FastOutSlowIn }, () => {
                    this.dotsOpacity = 1;
                  });
                })
                // 手动触摸时立即渐隐网点
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.getUIContext().animateTo({ duration: 400, curve: Curve.FastOutSlowIn }, () => {
                      this.dotsOpacity = 0;
                    });
                  }
                })
                .padding({ top: this.topPadding + 12 + (this.hideStatusBar ? 0 : this.statusBarHeight), bottom: 0 })
                }
                .opacity(this.banners.length > 0 && this.carouselVisible ? 1 : 0)
                // ⭐ 轮播换代时的缩放：隐藏时缩到 CAROUSEL_HIDDEN_SCALE、可见时弹回 1.0。
                //    大小变化比纯透明度更容易被眼睛捕捉 —— 光靠 opacity 的"消失/出现"几乎看不出是一次换代。
                // ⚠️ **从 carouselVisible 派生，不另外开状态**：carouselVisible 有 6 处独立置 true 的路径
                //    （旋屏回来 / 页面重新可见 / 数据首次到位 …），独立状态只要漏掉任意一条，轮播就会
                //    永久缩在 CAROUSEL_HIDDEN_SCALE。派生之后任何路径都自动一致。
                // ⚠️ 必须写在 .animation() **之前**，让它受这条隐式动画管辖（每条 600ms 平滑）；
                //    .translate(视差) 则必须留在 .animation() 之后 —— 视差要跟手，不能有缓动。
                .scale({
                  x: this.carouselVisible ? 1 : this.CAROUSEL_HIDDEN_SCALE,
                  y: this.carouselVisible ? 1 : this.CAROUSEL_HIDDEN_SCALE
                })
                .animation({ duration: 600, curve: Curve.FastOutSlowIn })
                .translate({ y: this.carouselParallaxY })
                .margin({ bottom: 15 })
              }   // if showHomeCarouselPortrait
            if (this.isLoading && this.dataSource.totalCount() === 0) {
              // ⭐ Loading 高度与轮播图区域一致，避免数据加载后布局抖动
              Row() { LoadingProgress().width(40).height(40).color(this.customThemeColor) }
              .width('100%').height(this.showHomeCarouselPortrait && !this.isLandscape ? this.carouselHeight : 200).justifyContent(FlexAlign.Center)
            } else {
              // ⭐ 使用 waterFlowKey 强制 WaterFlow 在列数变化时重建
              if (this.waterFlowKey >= 0) {
                WaterFlow() {
                  LazyForEach(this.dataSource, (item: RecommendItem, index: number) => {
                  FlowItem() {
                    if (item.id === this.REFRESH_SEPARATOR_ID) {
                      this.RefreshSeparatorCard()
                    } else {
                      VideoCardComponent({
                        item: item,
                        onCardClick: (clicked: RecommendItem): void => this.onCardClick(clicked),
                        onLongPress: (pressed: RecommendItem): void => this.showVideoMenu(pressed)
                      })
                    }
                  }
                  .onAppear(() => {
                    // 自动记录浏览过的视频（用于去重）
                    this.autoRecordWatched(item);
                    acquireDecodeSlot(); // ⭐ 标记封面开始加载（统计并发数）
                  })
                  .opacity(this.cardsVisible.length > index ? (this.cardsVisible[index] ? 1 : 0) : 1)
                  .scale({
                    x: this.cardsVisible.length > index ? (this.cardsVisible[index] ? 1 : 0.8) : 1,
                    y: this.cardsVisible.length > index ? (this.cardsVisible[index] ? 1 : 0.8) : 1
                  })
                  .translate({
                    y: this.cardsVisible.length > index
                      ? (this.cardsVisible[index] ? 0 : (this.cardTranslateYs[index] || 60))
                      : 0
                  })
                  .animation(this.da || !this.animateCards ? { duration: 0 } : {
                    duration: 1400,
                    curve: this.isBulkLoading
                      ? curves.springCurve(0.15, 1, 80, 8)
                      : curves.springCurve(0.15, 1, 80, 12)
                  })
                }, (item: RecommendItem, index: number) => `${item.id}_${index}`)
              }
              .columnsTemplate('1fr '.repeat(this.columnCount).trim())
              .columnsGap(this.cardListMargin).rowsGap(this.cardListMargin)
              .padding({ left: this.isLandscape && this.showHomeCarouselLandscape ? this.landscapeCarouselWidth : this.cardListMargin, right: this.cardListMargin, top: this.showHomeCarouselPortrait && !this.isLandscape ? 0 : this.topPadding + (this.hideStatusBar ? 0 : this.statusBarHeight), bottom: this.bottomPadding })
              .backgroundColor('transparent')
              .cachedCount(16)
              .clip(false)
              .gesture(PinchGesture().onActionUpdate((event: GestureEvent) => this.handlePinch(event.scale)))
              }
            }
            if (this.isLoadingMore) {
              Row() { LoadingProgress().width(24).height(24).color(this.customThemeColor); Text('努力获取新内容...').fontSize(12).fontColor('#999999').margin({ left: 8 }) }
              .width('100%').height(40).justifyContent(FlexAlign.Center).backgroundColor('transparent')
            } else if (!this.hasMore && this.dataSource.totalCount() > 0) {
              Text('没有更多推荐了，试试“换一批”')
                .fontSize(12).fontColor('#999999').width('100%').height(40).textAlign(TextAlign.Center)
            }
          }.width('100%').clip(false)
        }
        .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).backgroundColor('transparent')
        .onWillScroll((_, yOffset: number) => {
          this.scrollOffset = yOffset;
          const absoluteOffset = this.externalScroller!.currentOffset().yOffset;
          const delta = absoluteOffset - this.lastScrollY;

          if (this.showHomeCarouselPortrait && !this.isLandscape) {
            this.carouselParallaxY = absoluteOffset * 0.2;
            this.carouselTitleOpacity = Math.max(0, 1 - absoluteOffset / 50);
            // ⭐ 网点装饰层与标题胶囊同一条淡出曲线（滚 50px 内线性淡出）
            this.carouselDotsFade = Math.max(0, 1 - absoluteOffset / 50);
          }

          if (absoluteOffset < 5) {
            // 滚动接近顶部时自然复位（动画末段）
            this.lastScrollY = 0;
            this.homeScrollOffset = 0;
            AppStorage.set('homeScrollOffset', 0);
            AppStorage.set('bottomBarHidden', false);
          } else if (delta > this.SCROLL_THRESHOLD) {
            this.lastScrollY = absoluteOffset;
            this.homeScrollOffset = absoluteOffset;
            AppStorage.set('homeScrollOffset', absoluteOffset);
            AppStorage.set('bottomBarHidden', true);
          } else if (delta < -this.SCROLL_THRESHOLD) {
            this.lastScrollY = absoluteOffset;
            this.homeScrollOffset = absoluteOffset;
            AppStorage.set('homeScrollOffset', absoluteOffset);
            AppStorage.set('bottomBarHidden', false);
          }
        })
        .onReachEnd(() => {
          if (!this.isLoadingMore && !this.isLoading && !this.isRefreshing && this.hasMore) this.loadMore();
        })
      }
      .onStateChange((refreshStatus: RefreshStatus) => {
        if (refreshStatus === RefreshStatus.OverDrag) {
          if (this.longPullTimer !== -1) clearTimeout(this.longPullTimer);
          this.longPullTimer = setTimeout(() => {
            this.showSearchIcon = true;
            this.refreshBuilderText = '释放打开搜索';
            this.longPullTriggered = true;
            // 触发震动反馈
            try {
              VibrateUtils.vibrateTime(25);
            } catch (err) { }
          }, 800);
        } else if (refreshStatus === RefreshStatus.Drag) {
          if (this.longPullTimer !== -1) clearTimeout(this.longPullTimer);
          // 如果之前已触发长按，现在取消则震动反馈
          if (this.longPullTriggered) {
            try {
              VibrateUtils.vibrateTime(15);
            } catch (err) { }
          }
          this.showSearchIcon = false;
          this.refreshBuilderText = '下拉刷新';
          this.longPullTriggered = false;
        } else if (refreshStatus === RefreshStatus.Refresh) {
          if (this.longPullTimer !== -1) clearTimeout(this.longPullTimer);
        } else {
          if (this.longPullTimer !== -1) clearTimeout(this.longPullTimer);
          this.showSearchIcon = false;
          this.refreshBuilderText = '下拉刷新';
          this.longPullTriggered = false;
        }
      })
      .onRefreshing(() => {
        if (this.longPullTriggered) {
          this.isRefreshing = false;
          this.showSearchIcon = false;
          this.refreshBuilderText = '下拉刷新';
          this.longPullTriggered = false;
          setTimeout(() => {
            this.getUIContext().getRouter().pushUrl({ url: 'pages/SearchPage' }).catch((err: Error) => {
              logError(`下拉跳转搜索页失败: ${err.message}`);
            });
          }, 100);
          return;
        }
        this.onRefresh();
      })
      .width('100%')
      .height('100%')
      .backgroundColor('transparent')
      // ★ 横屏：左侧固定悬浮轮播图（不随滚动移动）
      if (this.isLandscape && this.showHomeCarouselLandscape && this.banners.length > 0) {
        Column() {
          Swiper(this.landscapeSwiperController) {
            ForEach(this.banners, (item: RecommendItem, index: number) => {
              Column() {
                // ⭐ 封面图
                Stack({ alignContent: Alignment.Bottom }) {
                  Image(item.coverUrl)
                    .width('100%')
                    .aspectRatio(16 / 9)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(this.cardListBorderRadius)
                    .backgroundColor('#E0E0E0')
                    .blur(index === this.animatedSwiperIndex ? 0 : 6)
                    .border({
                      width: this.cardTransparentStyle ? this.cardBorderWidth : 0,
                      color: this.cardTransparentStyle
                        ? (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)')
                        : Color.Transparent
                    })
                    .align(Alignment.Top)
                }
                .width('100%')
                .borderRadius(this.cardListBorderRadius)
                .clip(true)
                // ⭐ 标题 — 渐显
                Text(item.title)
                  .fontFamily('OhosThemeFont')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bolder)
                  .fontColor(this.isDarkMode ? '#FFFFFF' : '#FFFFFF')
                  .opacity(index === this.animatedSwiperIndex ? 0.85 : 0)
                  .animation({ duration: 800, curve: Curve.FastOutSlowIn })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 8, left: 4, right: 4 })
              }
              .width('100%')
              .scale({
                x: index === this.animatedSwiperIndex ? 1.0 : 0.88,
                y: index === this.animatedSwiperIndex ? 1.0 : 0.88
              })
              .opacity(index === this.animatedSwiperIndex ? 1.0 : 0.7)
              .animation({ curve: curves.springMotion(0.5, 0.85, 0) })
              .onClick(() => this.onCardClick(item))
            }, (item: RecommendItem) => item.id)
          }
          .width('100%')
          .height('100%')
          .vertical(true)
          .index(this.currentSwiperIndex)
          .prevMargin(this.landscapeCarouselMargin)
          .nextMargin(this.landscapeCarouselMargin)
          .itemSpace(4)
          .curve(Curve.FastOutSlowIn)
          .indicator(false)
          .autoPlay(true)
          .interval(4000)
          .loop(true)
          .onAnimationStart((_index: number, targetIndex: number) => {
            this.animatedSwiperIndex = targetIndex;
            this.lastCoverUrl = this.bgCoverUrl;
            this.bgCoverUrl = this.banners[targetIndex].coverUrl;
            this.bgFade = 0;
            this.getUIContext().animateTo({ duration: 1000, curve: Curve.FastOutSlowIn }, () => {
              this.bgFade = 1;
            });
          })
          .onChange((index: number) => {
            this.currentSwiperIndex = index;
          })
        }
        .width(this.landscapeCarouselWidth)
        .height('100%')
        .position({ x: 0, y: 0 })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        .padding({ left: this.cardListMargin, right: this.cardListMargin, top: 0, bottom: 0 })
        .opacity(this.landscapeCarouselVisible ? 1 : 0)
        // ⭐ 横屏轮播换代加缩放：原先横屏只有纯透明度淡出淡入，观感上"看不出是一次换代"
        //    （竖屏那边同时有缩放 + 弹簧过冲，所以更明显）。此处只补缩放，与竖屏用同一个
        //    CAROUSEL_HIDDEN_SCALE；淡入曲线不动 —— 那条隐式动画(600ms)还管着宽度变化，
        //    换成弹簧会连宽度一起弹跳，属于另一件事。
        //    ⚠️ 必须写在 .animation() **之前**：节点自带的 .animation() 只管它前面声明的属性，
        //      否则缩放不受它管辖、与透明度的时长对不上（这与竖屏那条的顺序要求同源）。
        .scale({
          x: this.landscapeCarouselVisible ? 1 : this.CAROUSEL_HIDDEN_SCALE,
          y: this.landscapeCarouselVisible ? 1 : this.CAROUSEL_HIDDEN_SCALE
        })
        .animation({ duration: 600, curve: Curve.FastOutSlowIn })
        .hitTestBehavior(HitTestMode.Default)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('transparent')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    // ⭐ 长按菜单：全窗口模态层（盖住底部 Tab 栏 → 模糊覆盖全窗口）。
    //    变形动画是浮层属性动画（非 geometryTransition），模态只做承载层。
    //    不带 $$：开关完全由 isMenuSheetVisible 手动控制（关闭须延迟到回弹动画结束）。
    .bindContentCover(this.isMenuSheetVisible, this.menuSheetContent(), {
      modalTransition: ModalTransition.NONE,
      backgroundColor: Color.Transparent,
      onWillDismiss: (dismiss: DismissContentCoverAction) => {
        this.closeVideoMenu();
      }
    })
  }
}