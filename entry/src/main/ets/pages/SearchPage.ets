﻿import { router, curves, display } from '@kit.ArkUI';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { FloatingVideoButton } from '../components/FloatingVideoButton';
import { searchByType, searchLive, SearchType, SearchOrder, SEARCH_ORDER_KEYS, getSearchOrderLabel, getSearchTypeLabel, SearchTypeLabelMap, getFollowStatus, modifyFollow, getVideoInfo } from '../api/BilibiliApi';
import { fetchRecommendedLiveRooms, LiveFeedRoom } from '../api/LiveFeedApi';
import { fetchHotSearch, fetchSearchDiscovery, fetchSearchSuggestions, HotSearchItem } from '../api/HotSearchService';
import { RecommendItem } from '../model/RecommendItem';
import { common } from '@kit.AbilityKit';
import { formatPlayCountText, getPlayCountDisplayColor } from '../utils/PlayCountStyle';
import { window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { VibrateUtils } from '../utils/VibrateUtils';
import { motion } from '@kit.MultimodalAwarenessKit';
import { ImmersiveLightWrapper } from '../components/ImmersiveLightWrapper';
import { HdsMiniBarButton } from '../components/infra/HdsMiniBarButton';
import { HdsTabs } from '@kit.UIDesignKit';
import { hdsMaterial } from '@hms.hds.hdsMaterial';
import { StatusBarUtils } from '../utils/StatusBarUtils';

// ── Tab 类型 ──
const TAB_KEYS: string[] = ['video', 'media_bangumi', 'media_ft', 'live_user', 'bili_user'];

@Entry
@Component({ freezeWhenInactive: true })
struct SearchPage {
  @State searchText: string = '';
  @State isLoading: boolean = false;
  @State showClearButton: boolean = false;
  @State searchBarFocused: boolean = false;
  @State showSkeleton: boolean = false;
  @State showAllHistory: boolean = false;
  @State searchHistory: string[] = [];
  // ⭐ 路由传入的待搜索关键词（搜索历史加载完成后执行，防止覆盖历史）
  private pendingKeyword_: string = '';
  // ⭐ 路由传入的待搜索 Tab（如 'all' 综合搜索）
  private pendingTab_: string = '';
  @State showHistory: boolean = false;
  @State isLandscape: boolean = false;
  @State hotSearchItems: HotSearchItem[] = [];
  @State searchDiscoveryWords: string[] = [];
  @State suggestionWords: string[] = [];
  @State showSuggestions: boolean = false;
  // 搜索类型 Tab — UI 直接绑定的当前 Tab 数据
  @State activeTab: string = 'video';
  @State hasActiveSearch: boolean = false;  // 用户是否主动搜索过（0结果时留在搜索结果页，不回到初始页以避开ImmersiveLightWrapper崩溃）
  @State activeOrder: string = 'totalrank';
  @State activeResults: RecommendItem[] = [];
  @State activePage: number = 1;
  @State activeHasMore: boolean = true;
  @State searchTabBarW: number = 320;
  @State searchOrderBarW: number = 280;
  @State searchInputBarW: number = 200;
  @State searchCapsuleExpanded: boolean = false;
  @State searchOrderTranslateX: number = 0;
  @State searchOrderOpacity: number = 1;
  @State currentWindowW: number = 360;
  @State liveStreamers: RecommendItem[] = [];   // 直播搜索结果中的主播列表
  @State showAllStreamers: boolean = false;     // 主播折叠展开
  // 私有缓存（非 @State，切换 Tab 时保存/恢复）
  private cachedResults: Map<string, RecommendItem[]> = new Map();
  private cachedPages: Map<string, number> = new Map();
  private cachedHasMore: Map<string, boolean> = new Map();
  private cachedOrders: Map<string, string> = new Map();
  // 搜索结果区动画状态
  @State contentOpacity: number = 1;
  @State contentTranslateY: number = 0;
  // 搜索历史动画状态
  @State historyOpacity: number = 0;
  @State historyTranslateY: number = -20;

  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @StorageLink('statusBarHeight') globalStatusBarHeight: number = 0;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('wallpaper') wallpaper: string = 'default';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;
  @StorageLink('wallpaperColor') wallpaperColor: string = '#007DFF';
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('da') da: boolean = false;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = false;
  @StorageLink('cardBorderFollowPlayCount') cardBorderFollowPlayCount: boolean = false;
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
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 40;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1.5;
  @StorageLink('cardCustomColor') cardCustomColor: string = '';
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  @StorageLink('cardListMargin') cardListMargin: number = 0;
  @StorageLink('cardStyleSearchSuggest') cardStyleSearchSuggest: boolean = true;
  @StorageLink('showSearchDiscovery') showSearchDiscovery: boolean = true;
  @StorageLink('showHotSearch') showHotSearch: boolean = true;
  @StorageLink('showSearchHistory') showSearchHistory: boolean = true;
  @StorageLink('searchHistoryRows') searchHistoryRows: number = 3;
  @State showEditPanel: boolean = false;
  @State imageLoadFailed: boolean = false;
  @State followedUserIds: string[] = [];
  // ⭐ 智感握持 - 边距
  @State private gripSafeAreaRight: number = 24;
  @State private gripSafeAreaLeft: number = 24;
  // ⭐ 智感握持 - 最终计算出的按钮定位
  @State private smartGripBottom: number = 120;
  @State private smartGripRight: number = 32;
  @State private smartGripLeft: number = -1;
  // ⭐ 智感握持 - 当前握持状态
  @State private hand: number = 16; // motion.HoldingHandStatus.UNKNOWN_STATUS
  // ⭐ 智感握姿开关
  @StorageLink('smartGripEnabled') smartGripEnabled: boolean = true;
  @StorageLink('floatBtnFollowTheme') floatBtnFollowTheme: boolean = true;
  // ⭐ 拖拽自定义按钮位置（智感握姿关闭时生效）
  @StorageLink('searchFloatBtnSide') searchFloatBtnSide: string = 'right';
  @StorageLink('searchFloatBtnY') searchFloatBtnY: number = 120;
  @State private dragStartY: number = 0;
  @State private dragOffsetX: number = 0;
  private touchStartWX: number = 0;
  private touchStartWY: number = 0;
  private touchMoved: boolean = false;
  @State private dragDeltaY: number = 0;
  @State private isDragging: boolean = false;
  @State private btnScale: number = 1;
  @State private maxFloatBtnBottom: number = 592; // 按钮顶部距屏幕顶部至少80vp
  // 是否已监听握持事件
  private gripListenersInitialized: boolean = false;
  @State showBackToTop: boolean = false;
  // ⭐ 初始数据加载状态
  @State isInitialLoading: boolean = true;  // 初始数据是否加载完成
  @State contentFadeIn: number = 0;         // 初始页淡入动画（0→1）
  // ⭐ 搜索栏背景Stack固定高度（margin 42 + ImmersiveLightWrapper内容高度42）
  private readonly SEARCH_BAR_STACK_HEIGHT: number = 84;
  // ⭐ 状态栏下方固定间隔
  private readonly SEARCH_BAR_SPACER: number = 8;
  // ⭐ 搜索栏总高度（供 onAreaChange 回调使用，模板中直接用计算值）
  @State actualSearchBarHeight: number = 0;

  /** 计算固定搜索栏的精确高度：状态栏 + 8vp间隔 + Stack(84vp) */
  private getSearchBarHeight(): number {
    const sb = this.hideStatusBar ? 0 : this.globalStatusBarHeight;
    return sb + this.SEARCH_BAR_SPACER + this.SEARCH_BAR_STACK_HEIGHT;
  }

  private hideHistoryTimeout: number = 0;
  private suggestTimer: number = 0;
  private suppressSuggestDebounce: boolean = false;
  private scroller: Scroller = new Scroller();
  private windowClass: window.Window | null = null;
  private windowSizeChangeCallback: ((size: window.Size) => void) | null = null;
  // 保存进入搜索页前的状态栏属性，退出时恢复
  private previousStatusBarColor: string = '';
  private previousStatusBarContentColor: string = '';
  // 保存进入搜索页前的状态栏显隐状态
  private previousHideStatusBar: boolean = false;
  // 输入框控制器，用于自动聚焦和关闭键盘
  private inputController: TextInputController = new TextInputController();

  aboutToAppear() {
    this.saveAndSetStatusBarTransparent();
    this.initOrientationAndListen();
    this.initSmartGrip();
    this.recalcSearchTabBarW();
    // ⭐ 长按文本选取「搜索」直达：接收路由 keyword，待搜索历史加载完成后再自动搜索
    //   （立即 performSearch 会用未加载的空历史数组 addToSearchHistory，覆盖掉旧搜索历史）
    try {
      const p = this.getUIContext().getRouter().getParams() as Record<string, Object>;
      const kw = p ? ((p['keyword'] as string) || '') : '';
      if (kw) {
        this.pendingKeyword_ = kw;
        const tab = (p['tab'] as string) || '';
        if (tab) {
          this.pendingTab_ = tab;
        }
      }
    } catch (e) {
      logWarn(`[SearchPage] 路由参数解析失败: ${e}`);
    }
    // ⭐ 统一加载所有初始数据，完成后一起淡入
    this.loadInitialData();
  }

  /** 统一加载初始数据，完成后触发淡入动画 */
  private async loadInitialData(): Promise<void> {
    try {
      // 并行加载所有数据
      await Promise.all([
        this.loadSearchHistory(),
        this.loadHotSearch(),
        this.loadSearchDiscovery(),
        this.loadSearchEditSettings()
      ]);

      // ⭐ 路由 keyword：待搜索历史加载完成后再搜索，避免覆盖旧搜索历史
      if (this.pendingKeyword_ !== '') {
        this.searchText = this.pendingKeyword_;
        this.pendingKeyword_ = '';
        if (this.pendingTab_ !== '') {
          this.activeTab = this.pendingTab_;
          this.pendingTab_ = '';
        }
        void this.performSearch(true);
      }

      // 所有数据加载完成，标记加载结束
      this.isInitialLoading = false;
      
      // ⭐ 等一帧让布局稳定，再触发淡入动画
      setTimeout(() => {
        animateTo({ duration: this.da ? 0 : 350, curve: Curve.EaseOut }, () => {
          this.contentFadeIn = 1;
        });
      }, 16);
    } catch (e) {
      logError('[SearchPage] loadInitialData 失败:', e);
      this.isInitialLoading = false;
      this.contentFadeIn = 1;
    }
  }

  /** ⭐ 动态计算搜索标签行和输入框宽度：标签行根据文字自适应 */
  private recalcSearchTabBarW(windowW?: number): void {
    try {
      let screenW: number;
      if (windowW !== undefined) {
        screenW = windowW;
      } else {
        const d = display.getDefaultDisplaySync();
        screenW = this.getUIContext().px2vp(d.width);
      }
      const maxTabBarW = Math.max(200, screenW - 28 - 16);
      // 标签行：根据 TAB_KEYS 文字内容估算总宽度
      const tabLabels: string[] = TAB_KEYS.map((k: string) => getSearchTypeLabel(k));
      this.searchTabBarW = this.estimateBarWidth(tabLabels, 14, 24, 8, 8, maxTabBarW);
      // 排序行：参数和实际渲染一致（fontSize=14, itemPadding=24, itemSpace=8）
      const orderLabels: string[] = SEARCH_ORDER_KEYS.map((k: string) => getSearchOrderLabel(k));
      const orderMaxW = Math.max(160, screenW - this.getCollapsedTabBarW() - 68);
      this.searchOrderBarW = this.estimateBarWidth(orderLabels, 14, 16, 4, 8, orderMaxW);
      // 搜索输入框：屏幕宽×60% - margin(8+8)，但不超过可用宽度
      this.searchInputBarW = Math.max(120, Math.min(Math.round(screenW * 0.6) - 16, screenW - 100));
    } catch (_) {
      this.searchTabBarW = 340;
      this.searchInputBarW = 200;
    }
  }

  /** 估算胶囊宽度：根据文字内容自适应 */
  private estimateBarWidth(labels: string[], fontSize: number, itemPadding: number,
    itemSpace: number, rowPadding: number, maxW: number): number {
    if (labels.length === 0) {
      return maxW;
    }
    let totalW = rowPadding;
    for (const label of labels) {
      let textW = 0;
      for (const ch of label) {
        textW += (ch.charCodeAt(0) > 0x4e00 && ch.charCodeAt(0) < 0x9fff) ? fontSize : fontSize * 0.55;
      }
      totalW += textW + itemPadding + itemSpace;
    }
    totalW -= itemSpace;
    return Math.min(totalW, maxW);
  }

  /** 收起态胶囊宽度：当前标签文字 + 右侧展开图标 */
  private getCollapsedTabBarW(): number {
    const label = getSearchTypeLabel(this.activeTab);
    let textW = 0;
    for (const ch of label) {
      textW += (ch.charCodeAt(0) > 0x4e00 && ch.charCodeAt(0) < 0x9fff) ? 14 : 14 * 0.55;
    }
    return textW + 24 + 20 + 8;
  }

  /** 展开态胶囊宽度：显示所有标签，考虑 contentPadding*4 和外层 padding */
  private getExpandedTabBarW(windowW?: number): number {
    try {
      let screenW: number;
      if (windowW !== undefined) {
        screenW = windowW;
      } else {
        const d = display.getDefaultDisplaySync();
        screenW = this.getUIContext().px2vp(d.width);
      }
      return Math.max(280, screenW - 28 - 16);
    } catch (_) {
      return 320;
    }
  }

  /** 展开/收起搜索标签胶囊 */
  private setSearchCapsuleExpanded(expanded: boolean): void {
    if (this.searchCapsuleExpanded === expanded) return;
    this.triggerHaptic();
    if (expanded) {
      this.getUIContext().animateTo({
        duration: 450,
        curve: curves.springMotion(0.4, 0.8)
      }, () => {
        this.searchCapsuleExpanded = true;
        this.searchOrderTranslateX = 300;
        this.searchOrderOpacity = 0;
      });
    } else {
      this.getUIContext().animateTo({
        duration: 280,
        curve: curves.springMotion(0.5, 0.85)
      }, () => {
        this.searchCapsuleExpanded = false;
        this.searchOrderTranslateX = 0;
        this.searchOrderOpacity = 1;
      });
    }
  }

  private async initOrientationAndListen() {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.windowClass = await window.getLastWindow(context);
      const props = this.windowClass.getWindowProperties();
      this.isLandscape = props.windowRect.width > props.windowRect.height;
      this.maxFloatBtnBottom = this.isLandscape ? 392 : 592;

      // ★ 从窗口避让区读取实际状态栏高度，更新 AppStorage
      const avoidArea = this.windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const realSbHeight = this.getUIContext().px2vp(avoidArea.topRect.height);
      if (realSbHeight > 0) {
        AppStorage.set('statusBarHeight', realSbHeight);
      }

      // 保存回调引用，以便精确移除，避免误删其他页面的监听器
      this.windowSizeChangeCallback = (size: window.Size): void => {
        this.isLandscape = size.width > size.height;
        this.maxFloatBtnBottom = this.isLandscape ? 392 : 592;
        const windowW = this.getUIContext().px2vp(size.width);
        this.currentWindowW = windowW;
        this.recalcSearchTabBarW(windowW);
      };
      this.windowClass.on('windowSizeChange', this.windowSizeChangeCallback);
    } catch (err) {
      logError('初始化屏幕方向监听失败:', err);
    }
  }

  aboutToDisappear() {
    if (this.hideHistoryTimeout) {
      clearTimeout(this.hideHistoryTimeout);
      this.hideHistoryTimeout = 0;
    }
    // 精确移除自己的监听器，不影响首页等其他页面的 windowSizeChange 监听
    if (this.windowClass && this.windowSizeChangeCallback) {
      this.windowClass.off('windowSizeChange', this.windowSizeChangeCallback);
      this.windowSizeChangeCallback = null;
    }
    // 恢复进入搜索页前的状态栏属性
    this.restoreStatusBar();
  }

  async saveAndSetStatusBarTransparent() {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass: window.Window = await window.getLastWindow(context);
      const props = windowClass.getWindowSystemBarProperties();
      this.previousStatusBarColor = props.statusBarColor ?? '';
      this.previousStatusBarContentColor = props.statusBarContentColor ?? '';
      // 保存当前状态栏显隐状态
      this.previousHideStatusBar = AppStorage.get<boolean>('hideStatusBar') ?? false;
      await windowClass.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: '#FFFFFF'
      });
      // 横屏时强制隐藏状态栏
      const isLandscape = AppStorage.get<boolean>('isLandscape') ?? false;
      if (isLandscape) {
        windowClass.setSpecificSystemBarEnabled('status', false);
      }
    } catch (error) {
      logError('设置状态栏透明失败', error);
    }
  }

  private async restoreStatusBar() {
    try {
      if (!this.windowClass) return;
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const isDark = AppStorage.get<boolean>('isDarkMode') ?? false;
      // 根据当前深色模式恢复状态栏颜色
      await this.windowClass.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: isDark ? '#FFFFFF' : '#000000'
      });
      // 横屏时保持状态栏隐藏，不恢复
      const isLandscape = AppStorage.get<boolean>('isLandscape') ?? false;
      if (!isLandscape) {
        // 重新应用用户的状态栏隐藏设置
        await StatusBarUtils.setStatusBarHidden(context, this.previousHideStatusBar);
      }
    } catch (err) {
      logError('恢复状态栏失败', err);
    }
  }

  private getSolidBackground(): string {
    switch (this.wallpaper) {
      case 'dark': return '#0A0E1A';
      case 'light': return '#FFFFFF';
      case 'mint': return '#E0F7F0';
      case 'blue': return '#1E2A4F';
      case 'custom_color': return this.wallpaperColor;
      default: return this.isDarkMode ? '#121212' : '#FFFFFF';
    }
  }

  async loadSearchHistory(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      const savedHistory = await pref.get('searchHistory', '[]') as string;
      const historyArray: string[] = JSON.parse(savedHistory);
      if (Array.isArray(historyArray)) {
        this.searchHistory = historyArray;
      }
    } catch (error) {
      logError('加载搜索历史失败:', error);
    }
  }

  async saveSearchHistory() {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('searchHistory', JSON.stringify(this.searchHistory));
      await pref.flush();
    } catch (error) {
      logError('保存搜索历史失败:', error);
    }
  }

  async loadSearchEditSettings(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      this.showHotSearch = await pref.get('showHotSearch', true) as boolean;
      this.showSearchHistory = await pref.get('showSearchHistory', true) as boolean;
      this.searchHistoryRows = await pref.get('searchHistoryRows', 3) as number;
      this.showSearchDiscovery = await pref.get('showSearchDiscovery', true) as boolean;
    } catch (error) {
      logError('加载搜索编辑设置失败:', error);
    }
  }

  async saveSearchEditSettings(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('showHotSearch', this.showHotSearch);
      await pref.put('showSearchHistory', this.showSearchHistory);
      await pref.put('searchHistoryRows', this.searchHistoryRows);
      await pref.put('showSearchDiscovery', this.showSearchDiscovery);
      await pref.flush();
    } catch (error) {
      logError('保存搜索编辑设置失败:', error);
    }
  }

  async performSearch(reset: boolean = true): Promise<void> {
    try {
      const isFirstSearch: boolean = this.activeResults.length === 0 && !this.hasActiveSearch;

      if (!isFirstSearch) {
        // 已有搜索结果的场景（排序切换、换Tab无缓存、翻页）：立即标记
        this.hasActiveSearch = true;
      }
      this.isLoading = true;
      // ⭐ 清除待处理的搜索建议定时器，防止其异步触发后重新显示建议面板
      if (this.suggestTimer > 0) {
        clearTimeout(this.suggestTimer);
        this.suggestTimer = 0;
      }
      // ⭐ 关闭搜索建议面板
      this.showSuggestions = false;
      this.suggestionWords = [];

      const keyword = this.searchText.trim();
      if (!keyword) {
        this.suppressSuggestDebounce = false;
        this.getUIContext().getPromptAction().showToast({ message: '请输入搜索关键词' });
        return;
      }

      this.addToSearchHistory(keyword);

      if (reset) {
        // 只重置分页，不清空 activeResults —— 保留旧结果避免闪烁
        this.activePage = 1;
        this.activeHasMore = true;
        // 首次搜索不用骨架屏 —— 默认页保持可见，轻微变暗提示加载中
        if (isFirstSearch) {
          this.contentOpacity = 0.75;
        } else if (this.activeResults.length === 0) {
          this.showSkeleton = true;
        }
        // 不再立即清空 activeResults 和触发 fade 动画
        this.suppressSuggestDebounce = false;
      }
      let newItems: RecommendItem[];
      if (this.activeTab === 'live_user') {
        // 直播 Tab：用 B站直播搜索 API 获取匹配的房间（自带封面）
        newItems = await this.searchLiveFeedRooms(keyword, this.activePage);
      } else {
        newItems = await searchByType(keyword, this.activeTab, this.activePage, 20, this.activeOrder);
      }
      // 直播 Tab：自动翻页凑够至少 10 个结果
      let collectedItems = newItems;
      if (this.activeTab === 'live_user') {
        if (reset) {
          let hasMorePages = newItems.length >= 20;
          const MAX_LIVE_SEARCH_PAGES = 10;
          let searchedPages = 1;
          let page = this.activePage;
          while (collectedItems.length < 10 && hasMorePages && searchedPages < MAX_LIVE_SEARCH_PAGES) {
            page++;
            const moreItems = await this.searchLiveFeedRooms(keyword, page);
            collectedItems = collectedItems.concat(moreItems);
            hasMorePages = moreItems.length >= 20;
            searchedPages++;
          }
          this.activePage = page;
        }
      }
      this.activeHasMore = this.activeTab === 'live_user'
        ? collectedItems.length >= 20
        : newItems.length > 0;  // ⭐ 综合排序接口可能返回不足20条（如17条），有内容即可继续翻页
      if (reset) {
        if (isFirstSearch) {
          // 首次搜索：初始页缓慢下沉淡出 → 搜索结果淡入
          // 先缓存结果（网络数据已就绪）
          this.cachedResults.set(this.activeTab, collectedItems);
          this.cachedPages.set(this.activeTab, this.activePage);
          this.cachedHasMore.set(this.activeTab, this.activeHasMore);
          // 第一段：初始页（当前可见，opacity=0.75）下沉淡出
          animateTo({ duration: this.da ? 0 : 200, curve: Curve.EaseIn }, () => {
            this.contentOpacity = 0;
            this.contentTranslateY = 30;
          });
          setTimeout(() => {
            // 切换状态到搜索结果（opacity=0，不可见）
            this.hasActiveSearch = true;
            this.activeResults = collectedItems;
            this.showSkeleton = false;
            this.isLoading = false;
            this.hideHistoryWithAnimation();
            // ⭐ 等一帧让布局稳定后再启动淡入动画，避免 layout thrashing
            setTimeout(() => {
              animateTo({ duration: this.da ? 0 : 250, curve: Curve.EaseOut }, () => {
                this.contentOpacity = 1;
                this.contentTranslateY = 0;
              });
            }, 16);
          }, 240);
        } else {
          this.activeResults = collectedItems;
          this.showSkeleton = false;
          this.isLoading = false;
          this.hideHistoryWithAnimation();
          this.cachedResults.set(this.activeTab, this.activeResults);
          this.cachedPages.set(this.activeTab, this.activePage);
          this.cachedHasMore.set(this.activeTab, this.activeHasMore);
        }
      } else {
        this.activeResults = this.activeResults.concat(collectedItems);
        this.isLoading = false;
      }
      // 初始化用户搜索的关注状态
      if (this.activeTab === 'bili_user') {
        logInfo(`[SearchPage] 开始 initFollowedUsers, 结果数=${this.activeResults.length}`);
        try {
          await this.initFollowedUsers();
        } catch (e) {
          logError(`[SearchPage] initFollowedUsers 异常: ${e}`);
        }
      }
    } catch (e) {
      logError(`[SearchPage] performSearch 异常: ${e}`);
    }
  }

  /**
   * 切换到指定 Tab：保存当前 Tab 状态，恢复目标 Tab 状态
   */
  switchToTab(tabKey: string): void {
    // 保存当前 Tab 状态到缓存
    this.cachedResults.set(this.activeTab, this.activeResults);
    this.cachedPages.set(this.activeTab, this.activePage);
    this.cachedHasMore.set(this.activeTab, this.activeHasMore);
    this.cachedOrders.set(this.activeTab, this.activeOrder);

    // 切换到新 Tab
    this.activeTab = tabKey;

    // 从缓存恢复目标 Tab 状态（直接替换，不淡入淡出）
    const cached = this.cachedResults.get(tabKey);
    if (cached && cached.length > 0) {
      this.hasActiveSearch = true;
      this.activeResults = cached;
      this.activePage = this.cachedPages.get(tabKey) || 1;
      this.activeHasMore = this.cachedHasMore.get(tabKey) || true;
      this.activeOrder = this.cachedOrders.get(tabKey) || 'totalrank';
    } else {
      // 缓存未命中 → 自动发起搜索（保留当前页旧结果，加载完成后替换）
      this.performSearch(true);
    }
  }

  /** 直播 Tab：搜索直播间（live_room），主播存入 liveStreamers */
  private async searchLiveFeedRooms(keyword: string, page: number): Promise<RecommendItem[]> {
    const rooms: RecommendItem[] = [];
    const existingIds = new Set<string>();

    // 1) 搜索直播间（live_room）
    try {
      const roomResults = await searchLive(keyword, page, 20);
      for (const item of roomResults) {
        if (item.id && !existingIds.has(item.id)) {
          rooms.push(item);
          if (item.id) existingIds.add(item.id);
        }
      }
      logInfo(`[SearchPage] searchLive(room) → ${roomResults.length} 条`);
    } catch (err) {
      logWarn(`[SearchPage] searchLive(room) 失败: ${err}`);
    }

    // 2) 搜索正在直播的主播（live_user），只取第一页
    if (page === 1) {
      try {
        const userResults = await searchByType(keyword, 'live_user', 1, 20);
        const newStreamers: RecommendItem[] = [];
        const streamerIds = new Set<string>();
        for (const item of userResults) {
          if (item.id && !streamerIds.has(item.id)) {
            newStreamers.push(item);
            streamerIds.add(item.id);
            // 也标记到已有 ID 集，避免与直播间重复
            if (item.id) existingIds.add(item.id);
          }
        }
        this.liveStreamers = newStreamers.sort((a, b) => (b.pubdate || 0) - (a.pubdate || 0));
        this.showAllStreamers = false;
        logInfo(`[SearchPage] searchByType(live_user) → ${newStreamers.length} 条主播`);
      } catch (err) {
        logWarn(`[SearchPage] searchByType(live_user) 失败: ${err}`);
      }
    }

    // 3) 如果房间不足 20 条，从推荐流补全（不包含主播列表中的房间）
    if (rooms.length < 20) {
      try {
        const lowerKw = keyword.toLowerCase();
        const feedRooms = await fetchRecommendedLiveRooms(page, 50);
        const matched = feedRooms.filter((r: LiveFeedRoom) =>
        r.title.toLowerCase().includes(lowerKw) ||
          r.uname.toLowerCase().includes(lowerKw)
        );
        const feedItems = matched.map((r: LiveFeedRoom): RecommendItem => {
          const item = new RecommendItem();
          item.id = r.roomId ? `live_${r.roomId}` : '';
          item.title = r.title;
          item.ownerName = r.uname;
          item.ownerFace = r.face ? (r.face.startsWith('//') ? `https:${r.face}` : r.face) : '';
          item.coverUrl = r.cover ? (r.cover.startsWith('//') ? `https:${r.cover}` : r.cover.startsWith('http') ? r.cover : `https:${r.cover}`) : '';
          item.pubdate = 1;
          item.ownerMid = String(r.uid);
          return item;
        });
        for (const fi of feedItems) {
          if (!existingIds.has(fi.id)) {
            rooms.push(fi);
            existingIds.add(fi.id);
          }
        }
        logInfo(`[SearchPage] 推荐流补全 ${feedItems.length} 条，去重后共 ${rooms.length} 条`);
      } catch (err) {
        logWarn(`[SearchPage] 推荐流补全失败: ${err}`);
      }
    }

    return rooms;
  }

  /** 格式化观看人数（如 1.2万） */
  formatShortCount(count: number): string {
    if (count >= 10000) {
      return (count / 10000).toFixed(1) + '万';
    }
    return String(count);
  }

  addToSearchHistory(keyword: string) {
    const index = this.searchHistory.indexOf(keyword);
    if (index !== -1) {
      this.searchHistory.splice(index, 1);
    }
    this.searchHistory.unshift(keyword);
    if (this.searchHistory.length > 30) {
      this.searchHistory = this.searchHistory.slice(0, 30);
    }
    this.saveSearchHistory();
  }

  removeFromSearchHistory(index: number) {
    this.searchHistory.splice(index, 1);
    this.saveSearchHistory();
  }

  clearSearchHistory() {
      this.getUIContext().getPromptAction().showDialog({
        title: '确认清空',
        message: '确定要清空所有搜索历史吗？',
        buttons: [
          { text: '取消', color: '#666666' },
          { text: '清空', color: '#FB7299' }
        ]
      }).then((result) => {
        if (result.index === 1) {
          this.searchHistory = [];
          this.saveSearchHistory();
        }
      }).catch(() => {});
    }

  loadMore() {
    if (!this.activeHasMore || this.isLoading) return;
    this.activePage++;
    this.performSearch(false);
  }

  // ═══════════════════════════════════════════
  // 智感握持 —— 回到顶部按钮定位
  // ═══════════════════════════════════════════

  private recalcSmartGripPosition(): void {
    const screenH: number = this.isLandscape ? 520 : 720; // 兜底值
    const bottomSafe: number = 24;
    if (this.isLandscape) {
      this.smartGripBottom = Math.max(bottomSafe + 24, screenH * 0.20);
    } else {
      this.smartGripBottom = Math.max(bottomSafe + 12, screenH * 0.15);
    }
    const LEFT_HAND = 1; // motion.HoldingHandStatus.LEFT_HAND_HELD
    // 两边始终保持有效值，避免 position 跳变触发平移动画
    this.smartGripLeft = this.gripSafeAreaLeft + 16;
    this.smartGripRight = this.gripSafeAreaRight + 8;
  }

  private initSmartGrip(): void {
    if (this.gripListenersInitialized) return;
    if (!this.smartGripEnabled) return;
    try {
      motion.on('holdingHandChanged', (data: number) => {
        if (data !== this.hand && (data === 1 || data === 2)) {
          this.hand = data;
          this.recalcSmartGripPosition();
        }
      });
      this.gripListenersInitialized = true;
    } catch (_e) { }
  }

  // 统一触觉反馈（短震动）
  private triggerHaptic(): void {
    VibrateUtils.vibrateTime(15);
  }

  private async saveFloatBtnPrefs(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('searchFloatBtnSide', this.searchFloatBtnSide);
      await pref.put('searchFloatBtnY', this.searchFloatBtnY);
      await pref.flush();
    } catch (e) {
      logError('保存悬浮按钮位置失败', e);
    }
  }

  /** 回到顶部按钮点击（覆盖层 Up 未拖动时调用，替代 TabBar onTabBarClick） */
  private handleBackToTopClick(): void {
    this.triggerHaptic();
    animateTo({ duration: 100, curve: Curve.FastOutLinearIn }, () => {
      this.btnScale = 0.8;
    });
    setTimeout(() => {
      animateTo({ duration: 300, curve: curves.springMotion(0.4, 0.8) }, () => {
        this.btnScale = 1;
      });
    }, 100);
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300, curve: Curve.EaseOut } });
  }

  goBack(): void {
    this.triggerHaptic();
    // 有搜索结果或输入文字时，播放向下渐隐动画后回到初始搜索页
    if (this.activeResults.length > 0 || this.searchText.trim().length > 0) {
      this.searchText = '';
      this.showClearButton = false;
      this.suppressSuggestDebounce = false;
      this.showSuggestions = false;
      this.suggestionWords = [];
      // 向下渐隐动画（内容淡出并下移）
      animateTo({ duration: this.da ? 0 : 300, curve: Curve.EaseIn }, () => {
        this.contentOpacity = 0;
        this.contentTranslateY = 40;
      });
      // ⭐ 等待淡出完成，切换状态，再淡入初始页
      setTimeout(() => {
        this.hasActiveSearch = false;
        this.activeResults = [];
        this.isLoading = false;
        this.showSkeleton = false;
        this.showBackToTop = false;
        this.activePage = 1;
        this.activeHasMore = true;
        // ⭐ 等一帧让布局稳定后再启动淡入动画，避免 layout thrashing
        setTimeout(() => {
          animateTo({ duration: this.da ? 0 : 300, curve: Curve.EaseOut }, () => {
            this.contentOpacity = 1;
            this.contentTranslateY = 0;
          });
        }, 16);
      }, 340);
      return;
    }
    router.back();
  }

  // 拦截系统侧滑返回 / 虚拟键返回，与返回按钮行为一致
  onBackPress(): boolean | void {
    // 有搜索结果或输入文字时，播放下沉动画后回到初始搜索页
    if (this.activeResults.length > 0 || this.searchText.trim().length > 0) {
      this.searchText = '';
      this.showClearButton = false;
      this.suppressSuggestDebounce = false;
      this.showSuggestions = false;
      this.suggestionWords = [];
      // 向下渐隐动画
      animateTo({ duration: this.da ? 0 : 300, curve: Curve.EaseIn }, () => {
        this.contentOpacity = 0;
        this.contentTranslateY = 40;
      });
      // ⭐ 等待淡出完成，切换状态，再淡入初始页
      setTimeout(() => {
        this.hasActiveSearch = false;
        this.activeResults = [];
        this.isLoading = false;
        this.showSkeleton = false;
        this.showBackToTop = false;
        this.activePage = 1;
        this.activeHasMore = true;
        // ⭐ 等一帧让布局稳定后再启动淡入动画，避免 layout thrashing
        setTimeout(() => {
          animateTo({ duration: this.da ? 0 : 300, curve: Curve.EaseOut }, () => {
            this.contentOpacity = 1;
            this.contentTranslateY = 0;
          });
        }, 16);
      }, 340);
      return true; // 拦截返回，停留在初始搜索页
    }
    // 已是初始态，允许正常返回上一页
    return false;
  }

  // 向下渐隐清空搜索结果
  private animateClearResults(): void {
    animateTo({ duration: this.da ? 0 : 300, curve: Curve.EaseIn }, () => {
      this.contentOpacity = 0;
      this.contentTranslateY = 50; // 向下位移
      this.historyOpacity = 0;
      this.historyTranslateY = -20; // 历史同步向上淡出
    });

    setTimeout(() => {
      this.searchText = '';
      this.showClearButton = false;
      this.activeResults = [];
      this.activePage = 1;
      this.activeHasMore = true;
      this.showSkeleton = false;
      this.showBackToTop = false;
      this.isLoading = false;
      this.showHistory = this.searchHistory.length > 0;
      this.contentOpacity = 1;
      this.contentTranslateY = 0;
      this.historyOpacity = 0;
      this.historyTranslateY = -20;

      // 回到初始态后若有历史记录，渐显
      if (this.showHistory) {
        setTimeout(() => {
          animateTo({ duration: this.da ? 0 : 250, curve: Curve.EaseOut }, () => {
            this.historyOpacity = 1;
            this.historyTranslateY = 0;
          });
        }, 16);
      }
    }, 300);
  }

  // 带动画显示搜索历史
  private showHistoryWithAnimation(): void {
    this.showHistory = true;
    this.historyOpacity = 0;
    this.historyTranslateY = -20;
    setTimeout(() => {
      animateTo({ duration: this.da ? 0 : 250, curve: Curve.EaseOut }, () => {
        this.historyOpacity = 1;
        this.historyTranslateY = 0;
      });
    }, 16);
  }

  // 带动画隐藏搜索历史
  private hideHistoryWithAnimation(): void {
    if (!this.showHistory) return;
    animateTo({ duration: this.da ? 0 : 200, curve: Curve.EaseIn }, () => {
      this.historyOpacity = 0;
      this.historyTranslateY = -20;
    });
    if (this.hideHistoryTimeout) {
      clearTimeout(this.hideHistoryTimeout);
    }
    this.hideHistoryTimeout = setTimeout(() => {
      this.showHistory = false;
      this.historyOpacity = 0;
      this.historyTranslateY = -20;
      this.hideHistoryTimeout = 0;
    }, 200);
  }

  async playVideo(item: RecommendItem) {
    if (!item.id) {
      this.getUIContext().getPromptAction().showToast({ message: '视频ID无效' });
      return;
    }

    // 番剧/影视（PGC）：id 形如 media_12345，跳转播放页并传 mediaId
    if (item.id.startsWith('media_')) {
      const mediaIdStr = item.id.substring(6);
      const mediaId = parseInt(mediaIdStr);
      if (isNaN(mediaId) || mediaId <= 0) {
        this.getUIContext().getPromptAction().showToast({ message: '番剧ID无效' });
        return;
      }
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/VideoPlayerPage',
        params: {
          mediaId: mediaId,
          title: item.title,
          coverUrl: item.coverUrl,
          score: item.pgcScore ? item.pgcScore.toString() : '',
          indexShow: item.pgcEpSize ? `全${item.pgcEpSize}话` : '',
        }
      });
      return;
    }

    if (item.cid && item.cid > 0) {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/VideoPlayerPage',
        params: {
          bvid: item.id,
          cid: item.cid,
          title: item.title,
          coverUrl: item.coverUrl,
        }
      });
      return;
    }

    const videoInfo = await getVideoInfo(item.id);
    if (videoInfo && videoInfo.cid > 0) {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/VideoPlayerPage',
        params: {
          bvid: item.id,
          cid: videoInfo.cid,
          title: videoInfo.title || item.title,
          coverUrl: videoInfo.coverUrl || item.coverUrl,
        }
      });
    } else {
      this.getUIContext().getPromptAction().showToast({ message: '无法获取视频信息，请重试' });
    }
  }

  clearSearchText() {
    this.searchText = '';
    this.showClearButton = false;
    this.showSuggestions = false;
    this.suggestionWords = [];
    if (this.suggestTimer > 0) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = 0;
    }
    // 向下渐隐动画
    animateTo({ duration: this.da ? 0 : 200, curve: Curve.EaseIn }, () => {
      this.contentOpacity = 0;
      this.contentTranslateY = 30;
    });
    // ⭐ 延迟清空 activeResults，避免 ImmersiveLightWrapper 在页面切换时崩溃
    setTimeout(() => {
      this.hasActiveSearch = false;
      this.activeResults = [];
      this.isLoading = false;
      this.showSkeleton = false;
      this.showBackToTop = false;
      this.activePage = 1;
      this.activeHasMore = true;
      // 重置动画状态，让初始页自然淡入
      this.contentOpacity = 1;
      this.contentTranslateY = 0;
    }, 260);
  }

  onSearchTextChange(value: string) {
    this.searchText = value;
    this.showClearButton = value.length > 0;

    // 防抖：清除之前的定时器
    if (this.suggestTimer > 0) {
      clearTimeout(this.suggestTimer);
      this.suggestTimer = 0;
    }
    // 隐藏搜索建议面板
    if (this.showSuggestions) {
      this.showSuggestions = false;
      this.suggestionWords = [];
    }

    // 程序化设置文本（如点击建议词）时不触发防抖
    if (this.suppressSuggestDebounce) {
      return;
    }

    // 加载中或首次搜索过渡中不触发搜索建议
    if (this.showSkeleton || (this.isLoading && !this.hasActiveSearch)) {
      return;
    }

    // 输入不为空时，延迟 300ms 请求搜索建议
    if (value.trim().length > 0) {
      this.suggestTimer = setTimeout(async () => {
        this.suggestTimer = 0;
        const words = await fetchSearchSuggestions(value.trim());
        if (words.length > 0 && this.searchText.trim().length > 0) {
          this.suggestionWords = words;
          this.showSuggestions = true;
        }
      }, 300);
    }
  }

  /** 热搜标签文字颜色 */
  private getTagTextColor(tag: string): string {
    switch (tag) {
      case '新': return '#FFFFFF';
      case '热': return '#FFFFFF';
      case '梗': return '#FFFFFF';
      case '话题': return '#FFFFFF';
      case '活动': return '#FFFFFF';
      case '推荐': return '#FFFFFF';
      case '上升': return '#FFFFFF';
      default: return '#FFFFFF';
    }
  }

  /** 热搜标签背景色 */
  private getTagBgColor(tag: string): string {
    switch (tag) {
      case '新': return '#64B5F6';  // 天蓝
      case '热': return '#FF6699';  // 粉红
      case '梗': return '#CE93D8';  // 浅紫
      case '话题': return '#4FC3F7'; // 浅蓝
      case '独家': return '#FFD54F'; // 琥珀
      case '直播': return '#FF7043'; // 橙红
      case '活动': return '#FFB74D'; // 橙色
      case '推荐': return '#4DB6AC'; // 青绿
      case '上升': return '#FF8A65'; // 珊瑚
      default: return '#90A4AE';    // 灰蓝
    }
  }

  private async loadHotSearch(): Promise<void> {
    const items = await fetchHotSearch();
    if (items.length > 0) {
      this.hotSearchItems = items;
    }
  }

  private async loadSearchDiscovery(): Promise<void> {
    const words = await fetchSearchDiscovery();
    // 如果已有搜索结果，不再更新搜索发现（防止搜索完成后弹出）
    if (this.activeResults.length > 0) return;
    if (words.length > 0) {
      this.searchDiscoveryWords = words;
    }
  }

  build() {
    Stack() {
      // ── 背景层 ──
      if (this.wallpaper === 'builtin') {
        Stack() {
          Image(this.isDarkMode ? $r('app.media.wallpaper_shen') : $r('app.media.wallpaper_qian'))
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
          if (this.wallpaperDarkness < 50) {
            Column()
              .width('100%').height('100%')
              .backgroundColor(`rgba(0, 0, 0, ${(50 - this.wallpaperDarkness) / 50})`)
          } else if (this.wallpaperDarkness > 50) {
            Column()
              .width('100%').height('100%')
              .backgroundColor(`rgba(255, 255, 255, ${(this.wallpaperDarkness - 50) / 50})`)
          }
        }
        .width('100%').height('100%')
      } else if (this.wallpaper === 'custom' && this.customWallpaper && !this.imageLoadFailed) {
        Stack() {
          Image('file://' + this.customWallpaper)
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
            .blur(this.wallpaperBlur)
            .onError(() => {
              this.imageLoadFailed = true;
              AppStorage.set('wallpaper', 'default');
            })
            .onComplete(() => { this.imageLoadFailed = false; })
          // 明暗效果层
          if (this.wallpaperDarkness < 50) {
            Column()
              .width('100%').height('100%')
              .backgroundColor(`rgba(0, 0, 0, ${(50 - this.wallpaperDarkness) / 50})`)
          } else if (this.wallpaperDarkness > 50) {
            Column()
              .width('100%').height('100%')
              .backgroundColor(`rgba(255, 255, 255, ${(this.wallpaperDarkness - 50) / 50})`)
          }
        }
        .width('100%').height('100%')
      } else {
        Stack() {
          Column()
            .width('100%').height('100%')
            .backgroundColor(this.getSolidBackground())
          // 明暗效果层
          if (this.wallpaperDarkness < 50) {
            Column()
              .width('100%').height('100%')
              .backgroundColor(`rgba(0, 0, 0, ${(50 - this.wallpaperDarkness) / 50})`)
          } else if (this.wallpaperDarkness > 50) {
            Column()
              .width('100%').height('100%')
              .backgroundColor(`rgba(255, 255, 255, ${(this.wallpaperDarkness - 50) / 50})`)
          }
        }
        .width('100%').height('100%')
      }

      // ── 可滚动内容区 ──
      Scroll(this.scroller) {
        Column() {
          // 显式占位，将内容推到固定搜索栏下方（inline 表达式确保 V1 状态追踪）
          Column()
            .width('100%')
            .height((this.hideStatusBar ? 0 : this.globalStatusBarHeight) + this.SEARCH_BAR_SPACER + this.SEARCH_BAR_STACK_HEIGHT)

          // ========== 搜索内容区 ==========
          Column() {
            // ⭐ 加载占位：数据未就绪时显示加载指示器
      if (this.isInitialLoading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color('#FF6699')
            .margin({ top: 100 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
      } else if (this.activeResults.length === 0 && !this.showSkeleton && !this.hasActiveSearch) {
              // ── 横屏：左右并排（历史左 | 热搜右）──
              // ── 竖屏：上下排列（热搜2列上方 | 历史多列下方）──
              Column() {

                if (this.isLandscape) {
                  // 横屏：左右并排（同原版）
                  Row() {
                    // ── 左侧：搜索历史 + 搜索发现 ──
                    Column() {
                      // ── 搜索历史 ──
                      if (this.showSearchHistory && this.searchHistory.length > 0) {
                        Column() {
                          Row() {
                            Text('搜索历史')
                              .fontSize(16)
                              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                              .fontWeight(FontWeight.Medium)
                            Blank()
                          }
                          .width('100%')
                          .alignItems(VerticalAlign.Top)
                          .margin({ bottom: 12 })

                          Flex({ wrap: FlexWrap.Wrap }) {
                              ForEach(
                                this.showAllHistory ? this.searchHistory :
                                  this.searchHistory.slice(0, this.searchHistoryRows * (this.isLandscape ? 8 : 5)),
                                (item: string, index: number) => {
                                Row() {
                                  Text(item)
                                    .fontSize(13)
                                    .fontColor($r('app.color.search_history_text'))
                                    .maxLines(1)
                                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                                    .constraintSize({ maxWidth: 160 })
                                  Image($r('app.media.ic_public_cancel_filled'))
                                    .width(12).height(12)
                                    .opacity(0.4)
                                    .margin({ left: 4 })
                                    .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                                    .onClick(() => {
                                      this.triggerHaptic();
                                      this.removeFromSearchHistory(index);
                                    })
                                }
                                .padding({ left: 12, right: 8, top: 6, bottom: 6 })
                                .borderRadius(16)
                                .backgroundColor('rgba(255,255,255,0.08)')
                                .onClick(() => {
                                  this.triggerHaptic();
                                  this.searchText = item;
                                  this.inputController.stopEditing();
                                  this.performSearch(true);
                                })
                                .margin({ right: 6, bottom: 12 })
                              })
                            }
                            .width('100%')


                          // 展开/收起
                          if (this.searchHistory.length > 8) {
                            Row() {
                              // 展开/收起胶囊（蓝色）
                              Row() {
                                Image(this.showAllHistory ? $r('app.media.ic_celiakeyboard_switch_majuscule') : $r('app.media.chevron_down'))
                                  .width(14).height(14)
                                  .fillColor('#42A5F5')
                                Text(this.showAllHistory ? '收起' : '展开全部')
                                  .fontSize(13)
                                  .fontColor('#42A5F5')
                                  .margin({ left: 4 })
                              }
                              .alignItems(VerticalAlign.Center)
                              .padding({ left: 10, right: 12, top: 5, bottom: 5 })
                              .borderRadius(14)
                              .backgroundColor('rgba(255,255,255,0.08)')
                              .onClick(() => {
                                this.triggerHaptic();
                                this.showAllHistory = !this.showAllHistory;
                              })
                              .margin({ right: 8 })

                              // 清空胶囊（粉红）
                              Row() {
                                Image($r('app.media.trash'))
                                  .width(14).height(14)
                                  .fillColor('#EC407A')
                                Text('清空')
                                  .fontSize(13)
                                  .fontColor('#EC407A')
                                  .margin({ left: 4 })
                              }
                              .alignItems(VerticalAlign.Center)
                              .padding({ left: 10, right: 12, top: 5, bottom: 5 })
                              .borderRadius(14)
                              .backgroundColor('rgba(255,255,255,0.08)')
                              .onClick(() => {
                                this.triggerHaptic();
                                this.clearSearchHistory();
                              })
                            }
                            .width('100%')
                            .justifyContent(FlexAlign.Center)
                            .margin({ top: 4 })
                          }
                        }
                        .alignItems(HorizontalAlign.Start)
                        .width('100%')
                        .margin({ bottom: 24 })
                      }

                      // ── 搜索发现 ──
                      if (this.showSearchDiscovery && this.searchDiscoveryWords.length > 0) {
                        Column() {
                          Text('搜索发现')
                            .fontSize(16)
                            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                            .fontWeight(FontWeight.Medium)
                            .margin({ bottom: 12 })

                          Flex({ wrap: FlexWrap.Wrap }) {
                            ForEach(this.searchDiscoveryWords.slice(0, 8), (word: string) => {
                              Row() {
                                Text(word)
                                  .fontSize(13)
                                  .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                                  .borderRadius(16)
                                  .backgroundColor('rgba(255,255,255,0.08)')
                                  
                                  .onClick(() => {
                                    this.triggerHaptic();
                                    this.searchText = word;
                                    this.inputController.stopEditing();
                                    this.performSearch(true);
                                  })
                              }
                              .margin({ right: 6, bottom: 8 })
                            })
                          }
                          .width('100%')
                        }
                        .alignItems(HorizontalAlign.Start)
                        .width('100%')
                      }
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(6)
                    .padding({ right: 8 })

                    // ── 右侧：Bilibili 热搜（列表）──
                    if (this.showHotSearch && this.hotSearchItems.length > 0) {
                      Column() {
                        Text('Bilibili 热搜')
                          .fontSize(16)
                          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                          .fontWeight(FontWeight.Medium)
                          .margin({ bottom: 8 })

                        ForEach(this.hotSearchItems.slice(0, 15), (item: HotSearchItem, idx: number) => {
                          Row() {
                            Text(`${idx + 1}`)
                              .fontSize(14)
                              .fontColor(idx < 3 ? '#FB7299' : (this.isDarkMode ? '#FFFFFF' : '#666666'))
                              .fontWeight(FontWeight.Medium)
                              .width(24)
                              .flexShrink(0)

                            Text(item.keyword)
                              .fontSize(14)
                              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                              .flexShrink(1)

                            if (item.iconUrl && item.iconUrl.length > 0) {
                              // 官方图标（如小绿瓶、热词badge图等），B站API返回的icon URL优先
                              Image(item.iconUrl)
                                .width(18).height(18)
                                .objectFit(ImageFit.Contain)
                                .margin({ left: 4 })
                                .flexShrink(0)
                            } else if (item.tagLabel && item.tagLabel.length > 0) {
                              // 无官方图标时，用 word_type 映射的文字标签
                              Text(item.tagLabel)
                                .fontSize(9)
                                .fontColor(this.getTagTextColor(item.tagLabel))
                                .textAlign(TextAlign.Center)
                                .height(16).constraintSize({ minWidth: 22 })
                                .padding({ left: 5, right: 5 })
                                .borderRadius(4)
                                .backgroundColor(this.getTagBgColor(item.tagLabel))
                                .margin({ left: 4 })
                                .flexShrink(0)
                            }
                          }
                          .width('100%')
                          .padding({ top: 6, bottom: 6, left: 4, right: 4 })
                          .borderRadius(10)
                          .onClick(() => {
                            this.searchText = item.keyword;
                            this.inputController.stopEditing();
                            this.performSearch(true);
                          })
                        }, (item: HotSearchItem, idx: number) => item.keyword + idx.toString())
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(4)
                      .padding({ left: 8 })
                    }
                  }
                  .alignItems(VerticalAlign.Top)
                  .width('100%')
                  .margin({ top: 12 })

                } else {
                  // 竖屏：上方热搜（2列）、下方搜索历史（多列换行）
                  Column() {

                    // ── 上部：Bilibili 热搜（2列网格）──
                    if (this.showHotSearch && this.hotSearchItems.length > 0) {
                      Column() {
                        Text('Bilibili 热搜')
                          .fontSize(16)
                          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                          .fontWeight(FontWeight.Medium)
                          .margin({ bottom: 8 })

                        Grid() {
                          ForEach(this.hotSearchItems.slice(0, 15), (item: HotSearchItem, idx: number) => {
                            GridItem() {
                              Row() {
                                Text(`${idx + 1}`)
                                  .fontSize(14)
                                  .fontColor(idx < 3 ? '#FB7299' : (this.isDarkMode ? '#FFFFFF' : '#666666'))
                                  .fontWeight(FontWeight.Medium)
                                  .width(24)
                                  .flexShrink(0)

                                Text(item.keyword)
                                  .fontSize(14)
                                  .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                                  .maxLines(1)
                                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                                  .flexShrink(1)

                                if (item.iconUrl && item.iconUrl.length > 0) {
                                  // 官方图标优先
                                  Image(item.iconUrl)
                                    .width(18).height(18)
                                    .objectFit(ImageFit.Contain)
                                    .margin({ left: 4 })
                                    .flexShrink(0)
                                } else if (item.tagLabel && item.tagLabel.length > 0) {
                                  Text(item.tagLabel)
                                    .fontSize(9)
                                    .fontColor(this.getTagTextColor(item.tagLabel))
                                    .textAlign(TextAlign.Center)
                                    .height(16).constraintSize({ minWidth: 22 })
                                    .padding({ left: 5, right: 5 })
                                    .borderRadius(4)
                                    .backgroundColor(this.getTagBgColor(item.tagLabel))
                                    .margin({ left: 4 })
                                    .flexShrink(0)
                                }
                              }
                              .width('100%')
                              .padding({ top: 6, bottom: 6, left: 4, right: 4 })
                              .borderRadius(10)
                              .onClick(() => {
                                this.searchText = item.keyword;
                                this.inputController.stopEditing();
                                this.performSearch(true);
                              })
                            }
                          }, (item: HotSearchItem, idx: number) => item.keyword + idx.toString())
                        }
                        .columnsTemplate('1fr 1fr')
                        .columnsGap(12)
                        .rowsGap(8)
                      }
                      .alignItems(HorizontalAlign.Start)
                      .width('100%')
                      .padding({ bottom: 24 })
                    }

                    // ── 下部：搜索历史 ──
                    if (this.showSearchHistory && this.searchHistory.length > 0) {
                      Column() {
                        Row() {
                          Text('搜索历史')
                            .fontSize(16)
                            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                            .fontWeight(FontWeight.Medium)
                          Blank()
                        }
                        .width('100%')
                        .alignItems(VerticalAlign.Top)
                        .margin({ bottom: 12 })

                        Flex({ wrap: FlexWrap.Wrap }) {
                          ForEach(
                            this.showAllHistory ? this.searchHistory :
                              this.searchHistory.slice(0, this.searchHistoryRows * (this.isLandscape ? 8 : 5)),
                            (item: string, index: number) => {
                            Row() {
                              Text(item)
                                .fontSize(13)
                                .fontColor($r('app.color.search_history_text'))
                                .maxLines(1)
                                .textOverflow({ overflow: TextOverflow.Ellipsis })
                                .constraintSize({ maxWidth: 160 })
                              Image($r('app.media.ic_public_cancel_filled'))
                                .width(12).height(12)
                                .opacity(0.4)
                                .margin({ left: 4 })
                                .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                                .onClick(() => {
                                  this.triggerHaptic();
                                  this.removeFromSearchHistory(index);
                                })
                            }
                            .padding({ left: 12, right: 8, top: 6, bottom: 6 })
                            .borderRadius(16)
                            .backgroundColor('rgba(255,255,255,0.08)')

                            .onClick(() => {
                              this.triggerHaptic();
                              this.searchText = item;
                              this.inputController.stopEditing();
                              this.performSearch(true);
                            })
                            .margin({ right: 6, bottom: 12 })
                          })
                        }
                        .width('100%')
                        if (this.searchHistory.length > 8) {
                          Row() {
                            // 展开/收起胶囊（蓝色）
                            Row() {
                              Image(this.showAllHistory ? $r('app.media.ic_celiakeyboard_switch_majuscule') : $r('app.media.chevron_down'))
                                .width(14).height(14)
                                .fillColor('#64B5F6')
                              Text(this.showAllHistory ? '收起' : '展开全部')
                                .fontSize(13)
                                .fontColor('#64B5F6')
                                .margin({ left: 4 })
                            }
                            .alignItems(VerticalAlign.Center)
                            .padding({ left: 10, right: 12, top: 5, bottom: 5 })
                            .borderRadius(14)
                            .backgroundColor('rgba(255,255,255,0.08)')
                            .onClick(() => {
                              this.triggerHaptic();
                              this.showAllHistory = !this.showAllHistory;
                            })
                            .margin({ right: 8 })

                            // 清空胶囊（粉红）
                            Row() {
                              Image($r('app.media.trash'))
                                .width(14).height(14)
                                .fillColor('#FB7299')
                              Text('清空')
                                .fontSize(13)
                                .fontColor('#FB7299')
                                .margin({ left: 4 })
                            }
                            .alignItems(VerticalAlign.Center)
                            .padding({ left: 10, right: 12, top: 5, bottom: 5 })
                            .borderRadius(14)
                            .backgroundColor('rgba(255,255,255,0.08)')
                            .onClick(() => {
                              this.triggerHaptic();
                              this.clearSearchHistory();
                            })
                          }
                          .width('100%')
                          .justifyContent(FlexAlign.Center)
                          .margin({ top: 4 })
                        }
                      }
                      .alignItems(HorizontalAlign.Start)
                      .width('100%')
                    }

                    // ── 搜索发现 ──
                    if (this.showSearchDiscovery && this.searchDiscoveryWords.length > 0) {
                      Column() {
                        Text('搜索发现')
                          .fontSize(16)
                          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                          .fontWeight(FontWeight.Medium)
                          .margin({ bottom: 12 })

                        Flex({ wrap: FlexWrap.Wrap }) {
                          ForEach(this.searchDiscoveryWords.slice(0, 8), (word: string) => {
                            Row() {
                              Text(word)
                                .fontSize(13)
                                .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                                .borderRadius(16)
                                .backgroundColor('rgba(255,255,255,0.08)')
                                
                                .onClick(() => {
                                  this.triggerHaptic();
                                  this.searchText = word;
                                  this.inputController.stopEditing();
                                  this.performSearch(true);
                                })
                            }
                            .margin({ right: 6, bottom: 8 })
                          })
                        }
                        .width('100%')
                      }
                        .alignItems(HorizontalAlign.Start)
                        .width('100%')
                      }
                    }
                    .width('100%')
                    .justifyContent(FlexAlign.Start)
                    .margin({ top: 12 })
                }
              }
              .padding({ left: 20, right: 20, top: 0 })
    // ⭐ 初始页淡入动画（竖屏向上位移 60vp，横屏不动）
    .opacity(this.contentFadeIn)
    .translate({ y: (1 - this.contentFadeIn) * 20 + (this.isLandscape ? 0 : -60) })

            } else if (this.showSkeleton) {
              // 骨架屏
              WaterFlow() {
                ForEach([0, 1, 2, 3, 4], (idx: number) => {
                  FlowItem() { this.SkeletonCard(idx) }
                })
              }
              .columnsTemplate(this.activeTab === 'live_user'
                ? (this.isLandscape ? '1fr 1fr 1fr' : '1fr 1fr')
                : (this.isLandscape ? '1fr 1fr' : '1fr'))
              .columnsGap(this.cardListMargin)
              .rowsGap(this.cardListMargin)
              .padding({ left: 14, right: 14, top: 4 })
              .backgroundColor('transparent')

            } else {
              // ── 标签胶囊（可展开/收起）+ 右侧排序胶囊 ──
                Row() {
                  HdsMiniBarButton({
                    barWidth: this.searchCapsuleExpanded ? this.getExpandedTabBarW(this.currentWindowW) : this.getCollapsedTabBarW(),
                    barHeight: 36,
                    contentPadding: 4,
                    barBottomMargin: 0,
                    barOverlap: true,
                    barPosition: BarPosition.End
                  }) {
                    if (this.searchCapsuleExpanded) {
                      Scroll() {
                        Row({ space: 8 }) {
                          ForEach(TAB_KEYS, (tabKey: string) => {
                            Column() {
                              Text(getSearchTypeLabel(tabKey))
                                .fontSize(14)
                                .fontColor(tabKey === this.activeTab
                                  ? '#FB7299'
                                  : (this.isDarkMode ? '#E0E0E0' : '#000000'))
                                .fontWeight(tabKey === this.activeTab ? FontWeight.Medium : FontWeight.Regular)
                              if (tabKey === this.activeTab) {
                                Row()
                                  .width(24)
                                  .height(3)
                                  .borderRadius(1.5)
                                  .backgroundColor('#FB7299')
                                  .margin({ top: 2 })
                              }
                            }
                            .height(32)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .padding({ left: 12, right: 12 })
                            .onClick(() => {
                              if (tabKey !== this.activeTab) {
                                this.switchToTab(tabKey);
                                if (tabKey === 'video') {
                                  this.setSearchCapsuleExpanded(false);
                                }
                              } else {
                                this.setSearchCapsuleExpanded(false);
                              }
                            })
                          })
                        }
                        .padding({ left: 4, right: 4 })
                      }
                      .width('100%')
                      .height('100%')
                      .scrollable(ScrollDirection.Horizontal)
                      .scrollBar(BarState.Off)
                      .edgeEffect(EdgeEffect.None)
                      .onClick(() => {
                        this.setSearchCapsuleExpanded(false);
                      })
                    } else {
                      Row() {
                        Text(getSearchTypeLabel(this.activeTab))
                          .fontSize(14)
                          .fontColor('#FB7299')
                          .fontWeight(FontWeight.Medium)
                          .maxLines(1)
                        Image($r('app.media.MingcuteRightSmallLine'))
                          .width(16)
                          .height(16)
                          .margin({ left: 4 })
                          .fillColor('#FB7299')
                      }
                      .height(32)
                      .justifyContent(FlexAlign.Center)
                      .alignItems(VerticalAlign.Center)
                      .padding({ left: 12, right: 12 })
                      .onClick(() => {
                        this.setSearchCapsuleExpanded(true);
                      })
                    }
                  }

                  Row().width(8)
                    .visibility(this.activeTab === 'video' && !this.searchCapsuleExpanded ? Visibility.Visible : Visibility.None)

                  Stack() {
                    HdsMiniBarButton({
                      barWidth: this.searchOrderBarW,
                      barHeight: 36,
                      contentPadding: 4,
                      barBottomMargin: 0,
                      barOverlap: true,
                      barPosition: BarPosition.End
                    }) {
                      Scroll() {
                        Row({ space: 4 }) {
                          ForEach(SEARCH_ORDER_KEYS, (orderKey: string) => {
                            Column() {
                              Text(getSearchOrderLabel(orderKey))
                                .fontSize(14)
                                .fontColor(orderKey === this.activeOrder
                                  ? '#FB7299'
                                  : (this.isDarkMode ? '#E0E0E0' : '#000000'))
                                .fontWeight(orderKey === this.activeOrder ? FontWeight.Medium : FontWeight.Regular)
                              if (orderKey === this.activeOrder) {
                                Row()
                                  .width(24)
                                  .height(3)
                                  .borderRadius(1.5)
                                  .backgroundColor('#FB7299')
                                  .margin({ top: 2 })
                              }
                            }
                            .height(32)
                            .justifyContent(FlexAlign.Center)
                            .alignItems(HorizontalAlign.Center)
                            .padding({ left: 8, right: 8 })
                            .onClick(() => {
                              this.triggerHaptic();
                              if (orderKey !== this.activeOrder) {
                                this.activeOrder = orderKey;
                                this.performSearch(true);
                              }
                            })
                          })
                        }
                        .justifyContent(FlexAlign.Center)
                        .padding({ left: 4, right: 4 })
                        .flexShrink(0)
                      }
                      .scrollable(ScrollDirection.Horizontal)
                      .scrollBar(BarState.Off)
                      .width('100%')
                    }
                  }
                  .visibility(this.activeTab === 'video' && !this.searchCapsuleExpanded ? Visibility.Visible : Visibility.None)
                  .translate({ x: this.searchOrderTranslateX })
                  .opacity(this.searchOrderOpacity)
                }
                .width('100%')
                .justifyContent(FlexAlign.Start)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })



              // ────────── 直播搜索结果 — 主播区（折叠/展开） ──────────
              if (this.activeTab === 'live_user' && this.liveStreamers.length > 0) {
                Column() {
                  // 区头
                  Row() {
                    Text('主播').fontSize(16).fontWeight(FontWeight.Bold)
                      .fontColor(this.isDarkMode ? Color.White : Color.Black)
                    Text(`(${this.liveStreamers.length})`)
                      .fontSize(13).fontColor('#999999').margin({ left: 4 })
                    Blank()
                    if (this.liveStreamers.length > 8) {
                      Text(this.showAllStreamers ? '收起' : '展开全部')
                        .fontSize(12).fontColor('#FB7299')
                        .onClick(() => {
                          this.showAllStreamers = !this.showAllStreamers;
                        })
                    }
                  }
                  .width('100%').padding({ left: 14, right: 14, bottom: 8 })
                  // 主播胶囊行（Flex 支持换行，默认显示 2 排约 6 个）
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(this.liveStreamers.slice(0,
                      this.showAllStreamers ? this.liveStreamers.length : 8
                    ), (streamer: RecommendItem) => {
                      Row() {
                        ImmersiveLightWrapper({ radius: 18, materialStyle: 0, lightIntensity: 2.0 }) {
                          Row() {
                            if (streamer.ownerFace) {
                              Image(streamer.ownerFace)
                                .width(28).height(28)
                                .borderRadius(14)
                                .objectFit(ImageFit.Cover)
                                .margin({ right: 6 })
                            }
                            Text(streamer.ownerName || '')
                              .fontSize(13)
                              .fontColor(this.isDarkMode ? Color.White : Color.Black)
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                            // 粉色直播状态指示图标（仅正在直播的显示）
                            if (streamer.pubdate > 0) {
                              Image($r('app.media.ic_public_brightness_filled'))
                                .width(12).height(12)
                                .fillColor('#FB7299')
                                .margin({ left: 4 })
                            }
                          }
                          .height(36)
                          .padding({ left: 4, right: 12 })
                          .alignItems(VerticalAlign.Center)
                          .onClick(() => {
                            if (streamer.id) {
                              this.enterLiveRoom(streamer.id);
                            }
                          })
                        }
                      }
                      .margin({ right: 8, bottom: 8 })
                    })
                  }
                  .width('100%')
                  .padding({ left: 14, right: 14, bottom: 12 })
                }
              }

              // ────────── 直播搜索结果 — 直播间区头 ──────────
              if (this.activeTab === 'live_user' && this.activeResults.length > 0) {
                Row() {
                  Text('直播间').fontSize(16).fontWeight(FontWeight.Bold)
                    .fontColor(this.isDarkMode ? Color.White : Color.Black)
                  Text(`(${this.activeResults.length})`)
                    .fontSize(13).fontColor('#999999').margin({ left: 4 })
                  Blank()
                }
                .width('100%')
                .padding({ left: 14, right: 14, bottom: 8 })
              }

              // 搜索结果——竖屏单列 / 横屏双列
              WaterFlow() {
                ForEach(this.activeResults, (item: RecommendItem, index: number) => {
                  FlowItem() {
                    if (this.activeTab === 'video') {
                      this.VideoCard(item, index)
                    } else if (this.activeTab === 'bili_user') {
                      this.UserCard(item)
                    } else if (this.activeTab === 'live_user') {
                      this.LiveSearchCard(item)
                    } else if (this.activeTab === 'media_bangumi' || this.activeTab === 'media_ft') {
                      this.VideoCard(item, index)
                    } else {
                      this.LiveSearchCard(item)
                    }
                  }
                }, (item: RecommendItem) => item.id)
              }
              .columnsTemplate(this.activeTab === 'live_user'
                ? (this.isLandscape ? '1fr 1fr 1fr' : '1fr 1fr')
                : (this.isLandscape ? '1fr 1fr' : '1fr'))
              .columnsGap(this.cardListMargin)
              .rowsGap(this.cardListMargin)
              .padding({ left: 14, right: 14, top: 4 })
              .backgroundColor('transparent')

              // ⭐ 空结果提示：搜索无结果时显示
              if (this.activeResults.length === 0 && this.hasActiveSearch && !this.isLoading) {
                Column() {
                  Text('未找到相关内容')
                    .fontSize(16)
                    .fontColor(this.isDarkMode ? '#888888' : '#999999')
                    .margin({ top: 80 })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
              }

              // 加载更多指示器
              if (this.isLoading) {
                Column() {
                  LoadingProgress()
                    .width(32).height(32)
                    .color('#FF6699')
                  Text('正在加载更多...')
                    .fontSize(14)
                    .fontColor(this.isDarkMode ? '#888888' : '#999999')
                    .margin({ top: 12 })
                }
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
                .padding(24)
                .width('100%')
              } else if (!this.activeHasMore && this.activeResults.length > 0) {
                Row() {
                  Divider().strokeWidth(1)
                    .color(this.isDarkMode ? '#444444' : '#E0E0E0')
                    .layoutWeight(1)
                  Text('已经到底了')
                    .fontSize(12)
                    .fontColor(this.isDarkMode ? '#666666' : '#BBBBBB')
                    .margin({ left: 12, right: 12 })
                  Divider().strokeWidth(1)
                    .color(this.isDarkMode ? '#444444' : '#E0E0E0')
                    .layoutWeight(1)
                }
                .padding(16)
                .width('100%')
              }
            }
          }
          .opacity(this.contentOpacity)
          .translate({ y: this.contentTranslateY })
        }
        .width('100%')
      }
      .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
      // ⭐ 结果区顶部对齐（内容少时不居中）；初始页（热搜/历史/发现）保持居中
      .align(this.hasActiveSearch ? Alignment.Top : Alignment.Center)
      .onReachEnd(() => {
        if (this.activeResults.length > 0 && !this.isLoading && this.activeHasMore) {
          this.loadMore();
        }
      })
      .onWillScroll(() => {
        // 滚动时检测是否超出阈值 → 显示/隐藏回到顶部按钮
        // 只有有搜索结果时才显示，回到初始页时无条件隐藏
        if (this.activeResults.length > 0) {
          const offset = this.scroller.currentOffset().yOffset;
          this.showBackToTop = Math.abs(offset) > 300;
        } else {
          this.showBackToTop = false;
        }
      })
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      // ── 固定顶部的搜索栏 ──
      Column() {
        // 状态栏占位
        Row()
          .height(this.hideStatusBar ? 0 : this.globalStatusBarHeight)
          .width('100%')
          .backgroundColor(Color.Transparent)

        Row()
          .height(8)
          .width('100%')
          .backgroundColor(Color.Transparent)

        // 搜索栏主体——改用 Row Flex 布局，避免绝对定位导致触摸测试 miss
        Row() {
          // 返回按钮（左上角，margin top 保持原 y=12 位置）
          Row() {
            HdsMiniBarButton({
              barWidth: 40,
              barHeight: 40,
              contentPadding: 0,
              containerSize: { width: 40, height: 40 },
              barBottomMargin: 0,
              barOverlap: true,
              barPosition: BarPosition.End,
              onButtonClick: (): void => {
                this.goBack();
              }
            }) {
              Image($r('app.media.ic_public_arrow_left_filled'))
                .width(20).height(20)
                .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            }
          }
          .width(40)
          .height(40)
          .margin({ top: 12 })

          // 中间搜索输入框（占据剩余宽度）
          Row() {
            HdsTabs() {
              TabContent()
                .tabBar(this.searchInputBar())
                .backgroundColor(Color.Transparent)
            }
            .barWidth(this.searchInputBarW)
            .barHeight(40)
            .barOverlap(true)
            .barPosition(BarPosition.End)
            .barFloatingStyle({
              gradientMask: {
                maskColor: Color.Transparent
              },
              barBottomMargin: 0,
              systemMaterialEffect: {
                materialType: hdsMaterial.MaterialType.IMMERSIVE,
                materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
              }
            })
            .scrollable(false)
            .animationDuration(0)
            .backgroundColor(Color.Transparent)
            .width(this.searchInputBarW)
            .height(40)
            .clip(false)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .margin({ top: 42, left: 8, right: 8 })

          // 右侧编辑按钮（替换原搜索按钮）
          Row() {
            HdsMiniBarButton({
              barWidth: 40,
              barHeight: 40,
              contentPadding: 0,
              containerSize: { width: 40, height: 40 },
              barBottomMargin: 0,
              barOverlap: true,
              barPosition: BarPosition.End,
              onButtonClick: (): void => {
                this.triggerHaptic();
                this.showEditPanel = true;
              }
            }) {
              Image($r('app.media.ic_public_edit_filled'))
                .width(18).height(18)
                .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            }
          }
          .width(40)
          .height(40)
          .margin({ top: 12 })
        }
        .width('100%')
        .height(this.SEARCH_BAR_STACK_HEIGHT)
        .alignItems(VerticalAlign.Top)
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({ left: 14, right: 14 })
      }
      .width('100%')
      .position({ x: 0, y: 0 })
      .zIndex(1)
      .onAreaChange((_oldValue: Area, newValue: Area) => {
        const newHeight: number = newValue.height as number;
        logInfo(`[SearchPage] onAreaChange: actualSearchBarHeight old=${this.actualSearchBarHeight} new=${newHeight} calculated=${this.getSearchBarHeight()} sb=${this.globalStatusBarHeight} hideSb=${this.hideStatusBar}`);
        if (Math.abs(this.actualSearchBarHeight - newHeight) > 1) {
          this.actualSearchBarHeight = newHeight;
        }
      })

      // ── 搜索建议面板 ──
      if (this.showSuggestions && this.suggestionWords.length > 0) {
        Column() {
          // 占位：将面板推到搜索栏下方
          Column() {}.height((this.hideStatusBar ? 0 : this.globalStatusBarHeight) + this.SEARCH_BAR_SPACER + this.SEARCH_BAR_STACK_HEIGHT)
          Column() {
            ForEach(this.suggestionWords.slice(0, 10), (word: string) => {
              Row() {
                Image($r('app.media.ic_public_search_filled'))
                  .width(14).height(14)
                  .fillColor(this.isDarkMode ? '#999999' : '#888888')
                  .margin({ right: 10 })
                Text(word)
                  .fontSize(14)
                  .fontColor(this.isDarkMode ? '#E0E0E0' : '#000000')
              }
              .width('100%')
              .height(40)
              .justifyContent(FlexAlign.Center)
              .hitTestBehavior(HitTestMode.Default)
              .onClick(() => {
                this.triggerHaptic();
                this.suppressSuggestDebounce = true;
                this.searchText = word;
                this.inputController.stopEditing();
                this.showSuggestions = false;
                this.suggestionWords = [];
                this.performSearch(true);
              })
            })
          }
          .width('100%')
          .borderRadius(20)
          .backgroundColor(Color.Transparent)
          // 与直播页分类面板一致：系统磨砂毛玻璃 + clip 裁切成型
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .clip(true)
        }
        .width('100%')
        .margin({ top: 8 })
        .padding({ left: 62, right: 62 })
        .position({ x: 0, y: 0 })
        .zIndex(2)
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(this.da ? TransitionEffect.OPACITY : TransitionEffect.asymmetric(
            TransitionEffect.translate({ y: -12 }).combine(TransitionEffect.opacity(0))
              .animation({ duration: 200, curve: Curve.FastOutSlowIn }),
            TransitionEffect.translate({ y: -12 }).combine(TransitionEffect.opacity(0))
              .animation({ duration: 150, curve: Curve.FastOutSlowIn })
          )
        )

      }

      // ⭐ 回到顶部悬浮按钮
      if (this.smartGripEnabled && !this.isLandscape) {
        // ⭐ 左侧按钮（左手握持时显示）
        Stack() {
          HdsMiniBarButton({
            barWidth: 48,
            barHeight: 48,
            contentPadding: 0,
            containerSize: { width: 48, height: 48 },
            barBottomMargin: 0,
            barOverlap: true,
            barPosition: BarPosition.End
          }) {
            Image($r('app.media.chevron_down'))
              .width(20).height(20)
              .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : (this.isDarkMode ? Color.White : Color.Black))
              .rotate({ angle: 180 })
          }
          // 触摸接管层：HdsTabs TabBar 原生消费事件导致外层 onTouch 收不到，
          // 用 Block 模式透明层强制接管，拖动+点击都由本层实现
          // 跟手优化：拖动中只更新 translate（GPU 变换不重排），Up 时才写回 position
          Column()
            .width(48).height(48)
            .hitTestBehavior(HitTestMode.Block)
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.touchStartWX = event.touches[0].windowX;
                this.touchStartWY = event.touches[0].windowY;
                this.dragStartY = this.searchFloatBtnY;
                this.touchMoved = false;
                this.isDragging = true;
                logInfo('[searchFloatBtn] overlay touch down');
              } else if (event.type === TouchType.Move) {
                const offYpx = event.touches[0].windowY - this.touchStartWY;
                if (Math.abs(offYpx) > 5) {
                  this.touchMoved = true;
                }
                this.searchFloatBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.dragStartY - Math.round(this.getUIContext().px2vp(offYpx))));
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.isDragging = false;
                if (this.touchMoved) {
                  AppStorage.set('searchFloatBtnY', this.searchFloatBtnY);
                  this.saveFloatBtnPrefs();
                } else if (event.type === TouchType.Up) {
                  this.handleBackToTopClick();
                }
              }
            })
        }
        .width(48).height(48)
        .position({ bottom: this.searchFloatBtnY, left: this.smartGripLeft })
        .opacity(this.hand === 1 && this.showBackToTop ? 1 : 0)
        .translate({ x: this.hand === 1 && this.showBackToTop ? 0 : -20 })
        .scale({ x: this.showBackToTop ? this.btnScale : 0, y: this.showBackToTop ? this.btnScale : 0 })
        .hitTestBehavior(this.hand === 1 && this.showBackToTop ? HitTestMode.Default : HitTestMode.None)
        .animation(this.da || this.isDragging ? { duration: 0 } : {
          duration: 300,
          curve: curves.springMotion(0.3, 0.4)
        })

        // ⭐ 右侧按钮（右手/默认握持时显示）
        Stack() {
          HdsMiniBarButton({
            barWidth: 48,
            barHeight: 48,
            contentPadding: 0,
            containerSize: { width: 48, height: 48 },
            barBottomMargin: 0,
            barOverlap: true,
            barPosition: BarPosition.End
          }) {
            Image($r('app.media.chevron_down'))
              .width(20).height(20)
              .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : (this.isDarkMode ? Color.White : Color.Black))
              .rotate({ angle: 180 })
          }
          // 触摸接管层：同左侧按钮
          Column()
            .width(48).height(48)
            .hitTestBehavior(HitTestMode.Block)
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.touchStartWX = event.touches[0].windowX;
                this.touchStartWY = event.touches[0].windowY;
                this.dragStartY = this.searchFloatBtnY;
                this.touchMoved = false;
                this.isDragging = true;
                logInfo('[searchFloatBtn] overlay touch down');
              } else if (event.type === TouchType.Move) {
                const offYpx = event.touches[0].windowY - this.touchStartWY;
                if (Math.abs(offYpx) > 5) {
                  this.touchMoved = true;
                }
                this.searchFloatBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.dragStartY - Math.round(this.getUIContext().px2vp(offYpx))));
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.isDragging = false;
                if (this.touchMoved) {
                  AppStorage.set('searchFloatBtnY', this.searchFloatBtnY);
                  this.saveFloatBtnPrefs();
                } else if (event.type === TouchType.Up) {
                  this.handleBackToTopClick();
                }
              }
            })
        }
        .width(48).height(48)
        .position({ bottom: this.searchFloatBtnY, right: this.smartGripRight })
        .opacity(this.hand !== 1 && this.showBackToTop ? 1 : 0)
        .translate({ x: this.hand !== 1 && this.showBackToTop ? 0 : 20 })
        .scale({ x: this.showBackToTop ? this.btnScale : 0, y: this.showBackToTop ? this.btnScale : 0 })
        .hitTestBehavior(this.hand !== 1 && this.showBackToTop ? HitTestMode.Default : HitTestMode.None)
        .animation(this.da || this.isDragging ? { duration: 0 } : {
          duration: 300,
          curve: curves.springMotion(0.3, 0.4)
        })
      } else {
        // ⭐ 智感握姿关闭：单个可拖拽按钮
        Stack() {
          HdsMiniBarButton({
            barWidth: 48,
            barHeight: 48,
            contentPadding: 0,
            containerSize: { width: 48, height: 48 },
            barBottomMargin: 0,
            barOverlap: true,
            barPosition: BarPosition.End
          }) {
            Image($r('app.media.chevron_down'))
              .width(20).height(20)
              .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : (this.isDarkMode ? Color.White : Color.Black))
              .rotate({ angle: 180 })
          }
          // 触摸接管层：拖动+吸附+点击全由本层实现
          Column()
            .width(48).height(48)
            .hitTestBehavior(HitTestMode.Block)
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.touchStartWX = event.touches[0].windowX;
                this.touchStartWY = event.touches[0].windowY;
                this.dragStartY = this.searchFloatBtnY;
                this.dragOffsetX = 0;
                this.touchMoved = false;
                this.isDragging = true;
                logInfo('[searchFloatBtn] overlay touch down');
              } else if (event.type === TouchType.Move) {
                const offYpx = event.touches[0].windowY - this.touchStartWY;
                const offXpx = event.touches[0].windowX - this.touchStartWX;
                if (Math.abs(offYpx) > 5 || Math.abs(offXpx) > 5) {
                  this.touchMoved = true;
                }
                this.searchFloatBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.dragStartY - Math.round(this.getUIContext().px2vp(offYpx))));
                this.dragOffsetX = Math.round(this.getUIContext().px2vp(offXpx));
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.isDragging = false;
                if (this.touchMoved) {
                  const totalOffsetX: number = this.dragOffsetX;
                  let newSide: string = this.searchFloatBtnSide;
                  let sideChanged: boolean = false;
                  if (totalOffsetX < -60) {
                    newSide = 'left';
                    sideChanged = true;
                  } else if (totalOffsetX > 60) {
                    newSide = 'right';
                    sideChanged = true;
                  }
                  if (sideChanged || totalOffsetX !== 0) {
                    animateTo({ duration: 300, curve: Curve.Ease }, () => {
                      this.dragOffsetX = 0;
                      if (sideChanged) {
                        this.searchFloatBtnSide = newSide;
                      }
                    });
                  } else {
                    this.dragOffsetX = 0;
                  }
                  AppStorage.set('searchFloatBtnSide', this.searchFloatBtnSide);
                  AppStorage.set('searchFloatBtnY', this.searchFloatBtnY);
                  this.saveFloatBtnPrefs();
                } else {
                  this.dragOffsetX = 0;
                  if (event.type === TouchType.Up) {
                    this.handleBackToTopClick();
                  }
                }
              }
            })
        }
        .width(48).height(48)
        .position(this.searchFloatBtnSide === 'left'
          ? { bottom: this.searchFloatBtnY, left: 32 }
          : { bottom: this.searchFloatBtnY, right: 32 })
        .opacity(this.showBackToTop ? 1 : 0)
        .scale({ x: this.showBackToTop ? this.btnScale : 0, y: this.showBackToTop ? this.btnScale : 0 })
        .hitTestBehavior(this.showBackToTop ? HitTestMode.Default : HitTestMode.None)
        .animation(this.da || this.isDragging ? { duration: 0 } : {
          duration: 300,
          curve: Curve.Ease
        })
        .translate({ x: this.dragOffsetX })
      }
      // ⭐ 最小化视频悬浮按钮
      FloatingVideoButton()
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet(this.showEditPanel, this.searchEditPanel(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: this.isDarkMode ? '#1A1A1A' : '#FFFFFF',
      onDisappear: () => {
        this.showEditPanel = false;
      }
    })
  }

  // ────────── Builder：搜索页编辑面板 ──────────
  @Builder
  searchEditPanel() {
    Column() {
      // 标题
      Row() {
        Text('编辑')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 12 })

      // 热搜开关
      Row() {
        Text('热搜')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.showHotSearch })
          .onChange((isOn: boolean) => {
            this.triggerHaptic();
            this.showHotSearch = isOn;
            this.saveSearchEditSettings();
          })
          .selectedColor('#FB7299')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 12 })

      Divider().color(this.isDarkMode ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.1)').margin({ left: 20, right: 20 })

      // 搜索历史开关
      Row() {
        Text('搜索历史')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.showSearchHistory })
          .onChange((isOn: boolean) => {
            this.triggerHaptic();
            this.showSearchHistory = isOn;
            this.saveSearchEditSettings();
          })
          .selectedColor('#FB7299')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 12 })

      // 搜索历史行数选择
      if (this.showSearchHistory) {
        Row() {
          Text('显示行数')
            .fontSize(14)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#666666')
          Blank()
          Row({ space: 8 }) {
            ForEach([1, 2, 3], (rows: number) => {
              Text(rows === 1 ? '少' : rows === 2 ? '中' : '多')
                .fontSize(13)
                .fontColor(this.searchHistoryRows === rows ? '#FB7299' : (this.isDarkMode ? '#FFFFFF' : '#666666'))
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(12)
                .backgroundColor(this.searchHistoryRows === rows ? 'rgba(251,114,153,0.15)' : 'rgba(255,255,255,0.08)')
                .onClick(() => {
                  this.triggerHaptic();
                  this.searchHistoryRows = rows;
                  this.saveSearchEditSettings();
                })
            })
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 8, bottom: 12 })
      }

      Divider().color(this.isDarkMode ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.1)').margin({ left: 20, right: 20 })

      // 搜索发现开关
      Row() {
        Text('搜索发现')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.showSearchDiscovery })
          .onChange((isOn: boolean) => {
            this.triggerHaptic();
            this.showSearchDiscovery = isOn;
            this.saveSearchEditSettings();
          })
          .selectedColor('#FB7299')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 12 })
    }
    .width('100%')
    .backgroundColor(this.isDarkMode ? '#1A1A1A' : '#FFFFFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  // ────────── Builder：搜索输入栏（HdsTabs 承载沉浸光感）──────────
  @Builder
  searchInputBar() {
    Row() {
      Image($r('app.media.ic_public_search_filled'))
        .width(18).height(18)
        .margin({ left: 14 })
        .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')

      TextInput({
        placeholder: '搜索 B 站视频',
        text: this.searchText,
        controller: this.inputController
      })
        .defaultFocus(true)
        .layoutWeight(1)

        .backgroundColor(Color.Transparent)
        .margin({ left: 8, right: 8 })
        .placeholderColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        .placeholderFont({ size: 15 })
        .caretColor('#FF6699')
        .fontColor($r('app.color.color_primary_text'))
        .fontSize(15)
        .textAlign(TextAlign.Center)
        .onChange((value) => {
          this.onSearchTextChange(value);
        })
        .onSubmit(() => {
          this.showSuggestions = false;
          this.suggestionWords = [];
          this.performSearch(true);
        })
        .onEditChange((isEditing) => {
          this.searchBarFocused = isEditing;
          if (isEditing) {
            if (this.searchHistory.length > 0) {
              this.showHistoryWithAnimation();
            }
          } else {
            this.hideHistoryWithAnimation();
          }
        })

      if (this.showClearButton) {
        Image($r('app.media.ic_public_cancel_filled'))
          .width(18).height(18)
          .margin({ right: 14 })
          .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.85 })
          .onClick(() => {
            this.triggerHaptic();
            this.clearSearchText();
          })
      } else {
        Row().width(32)
      }
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Color.Transparent)
  }

  // ────────── Builder：搜索结果卡片（对齐发现页风格）──────────
  @Builder
  VideoCard(item: RecommendItem, index: number) {
    Row() {
      // 封面图
      Image(item.coverUrl)
        .width(180)
        .aspectRatio(16 / 9)
        .objectFit(ImageFit.Cover)
        .borderRadius(this.cardListBorderRadius)
        .backgroundColor('#E0E0E0')
        .margin({ right: 12 })
        .sharedTransition(`videoCover_`, this.da ? { duration: 0 } : {
          duration: 350,
          curve: Curve.EaseOut
        })

      // 信息区
      Column() {
        Text(item.title)
          .fontSize(14)
          .fontColor(this.isDarkMode ? Color.White : Color.Black)
          .width('100%')
          .margin({ bottom: 6 })
          .maxLines(this.isLandscape ? 3 : 4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row() {
          Text(item.ownerName)
            .fontSize(this.cardCapsuleShow ? this.cardCapsuleSize : 12)
            .fontColor(this.cardCapsuleShow
              ? ((this.cardCapsuleColor || this.cardCapsuleFollowTheme)
                ? (this.isDarkMode ? '#FFFFFF' : '#000000')
                : $r('app.color.color_primary_text'))
              : $r('app.color.color_primary_text'))
            .padding(this.cardCapsuleShow
              ? { left: 6, right: 6, top: 4, bottom: 4 }
              : { left: 0, right: 0, top: 0, bottom: 0 })
            .backgroundColor(this.cardCapsuleShow
              ? (this.cardCapsuleColor
                ? this.cardCapsuleColor
                : (this.cardCapsuleFollowTheme ? this.customThemeColor : 'rgba(186, 136, 65, 1)'))
              : Color.Transparent)
            .borderRadius(this.cardCapsuleShow ? this.cardCapsuleRadius : 0)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          Blank()
          if (item.pubdate > 0) {
            Text(this.formatTimeAgo(item.pubdate))
              .fontSize(11)
              .fontColor(this.isDarkMode ? '#888888' : '#999999')
              .flexShrink(0)
          }
        }
        .width('100%')
        .margin({ top: 4 })

        // ⭐ 番剧/影视 Tab：搜索接口无播放量字段，显示「共N集 / 评分X」
        if (this.activeTab === 'media_bangumi' || this.activeTab === 'media_ft') {
          Row() {
            if (item.pgcEpSize > 0) {
              Text(`共${item.pgcEpSize}集`)
                .fontSize(12)
                .fontColor(this.isDarkMode ? '#888888' : '#999999')
                .margin({ right: 8 })
            }
            if (item.pgcScore > 0) {
              Text(`${item.pgcScore.toFixed(1)}分`)
                .fontSize(12)
                .fontColor('#FB7299')
                .fontWeight(FontWeight.Medium)
            }
          }
          .alignItems(VerticalAlign.Center)
          .height(20)
          .margin({ top: 6 })
        } else {
          if (this.cardPlayCountShow) {
            Row() {
              Text(formatPlayCountText(item.playCount, this.cardPlayCountUnit) + '播放')
                .fontSize(this.cardPlayCountSize)
                .fontColor(getPlayCountDisplayColor(item.playCount,
                  this.cardPlayCountColorMode, this.cardPlayCountColor, this.customThemeColor, this.isDarkMode))
              if (this.cardPlayCountIcon) {
                Image($r('app.media.play_fill'))
                  .width(20)
                  .height(20)
                  .objectFit(ImageFit.Contain)
                  .margin({ left: 4 })
                  .fillColor(getPlayCountDisplayColor(item.playCount,
                    this.cardPlayCountColorMode, this.cardPlayCountColor, this.customThemeColor, this.isDarkMode))
              }
            }
            .alignItems(VerticalAlign.Center)
            .height(20)
            .margin({ top: 6 })
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 8, bottom: 8 })
    }
    .width('100%')
    .backgroundColor(this.cardCustomColor && this.cardCustomColor !== '#007DFF'
      ? (this.cardTransparentStyle
        ? '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1)
        : this.cardCustomColor)
      : (this.cardTransparentStyle
        ? (this.isDarkMode
          ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
          : `rgba(255,255,255,${this.cardBgOpacity / 100})`)
        : (this.isDarkMode ? '#2C2C2C' : '#FFFFFF')))
    .border({ width: this.cardTransparentStyle ? this.cardBorderWidth : 0,
      color: this.cardTransparentStyle
        ? (this.cardBorderFollowPlayCount
          ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.getPlayCountColor(item.playCount).slice(1))
          : (this.cardBorderFollowTheme
            ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1))
            : (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)')))
        : Color.Transparent })
    .borderRadius(this.cardListBorderRadius)
    .clip(true)
    .padding(12)
    .shadow({ radius: 4, color: '#10000000', offsetY: 2 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .onClick(() => {
      this.triggerHaptic();
      this.playVideo(item);
    })
  }

  @Builder
  SkeletonCard(index: number) {
    Row() {
      Column() { Blank() }
      .width(180)
      .aspectRatio(16 / 9)
      .backgroundColor(this.isDarkMode ? '#333333' : '#E0E0E0')
      .borderRadius(12)
      .margin({ right: 12 })

      Column() {
        Column() { Blank() }
        .width('80%').height(16)
        .backgroundColor(this.isDarkMode ? '#333333' : '#E0E0E0')
        .borderRadius(4)
        .margin({ bottom: 8 })

        Row() {
          Column() { Blank() }
          .width(60).height(12)
          .backgroundColor(this.isDarkMode ? '#333333' : '#E0E0E0')
          .borderRadius(4)
          Blank()
          Column() { Blank() }
          .width(40).height(12)
          .backgroundColor(this.isDarkMode ? '#333333' : '#E0E0E0')
          .borderRadius(4)
          .margin({ left: 8 })
        }
        .width('100%').margin({ bottom: 8 })

        Row() {
          Column() { Blank() }
          .width(50).height(12)
          .backgroundColor(this.isDarkMode ? '#333333' : '#E0E0E0')
          .borderRadius(4)
          .margin({ right: 12 })
          Column() { Blank() }
          .width(50).height(12)
          .backgroundColor(this.isDarkMode ? '#333333' : '#E0E0E0')
          .borderRadius(4)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 8, bottom: 8 })
    }
    .width('100%')
    .backgroundColor(this.isDarkMode ? '#2C2C2C' : '#FFFFFF')
    .borderRadius(12)
    .padding(12)
    .shadow({ radius: 4, color: '#10000000', offsetY: 2 })
  }

  // ────────── 直播搜索卡片（仿 LivePage 垂直卡片风格） ──────────
  @Builder
  LiveSearchCard(item: RecommendItem) {
    Column() {
      // ---- 封面区 ----
      Stack() {
        Image(item.coverUrl)
          .width('100%')
          .aspectRatio(16 / 9)
          .objectFit(ImageFit.Cover)
          .backgroundColor(this.isDarkMode ? '#333333' : '#E8E8E8')
          .draggable(false)

        // 底部渐变遮罩
        Row()
          .width('100%')
          .height(40)
          .position({ bottom: 0 })
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: [['#00000000', 0], ['#CC000000', 1]]
          })

        // 左上角"直播"角标
        Row() {
          Circle().width(7).height(7).fill('#FF4D4D')
          Text('直播')
            .fontSize(11)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Bold)
            .margin({ left: 4 })
        }
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor('rgba(255,77,77,0.85)')
        .borderRadius(4)
        .position({ top: 6, left: 6 })

        // 右上角观看人数
        if (item.online > 0) {
          Row() {
            Image($r('app.media.ic_public_screencap'))
              .width(12).height(12)
              .fillColor(Color.White)
            Text(this.formatShortCount(item.online))
              .fontSize(11)
              .fontColor(Color.White)
              .margin({ left: 3 })
          }
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('rgba(0,0,0,0.55)')
          .borderRadius(4)
          .position({ bottom: 6, right: 6 })
        }
      }
      .width('100%')
      .borderRadius(12)
      .clip(true)
      .backgroundColor(this.isDarkMode ? '#333333' : '#F0F0F0')

      // ---- 标题 ----
      Text(item.title || '未命名直播')
        .fontSize(14)
        .fontColor(this.isDarkMode ? Color.White : Color.Black)
        .maxLines(2)
        .lineHeight(20)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 8, left: 2, right: 2 })
        .width('100%')

      // ---- 主播信息行 ----
      Row() {
        if (item.ownerFace) {
          Image(item.ownerFace)
            .width(20).height(20)
            .borderRadius(10)
            .margin({ right: 5 })
            .backgroundColor(this.isDarkMode ? '#444444' : '#E0E0E0')
        }
        Text(item.ownerName || '未知主播')
          .fontSize(13)
          .fontColor(this.isDarkMode ? '#AAAAAA' : '#666666')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        if (item.online > 0) {
          Text(this.formatShortCount(item.online) + '观看')
            .fontSize(11)
            .fontColor(this.isDarkMode ? '#888888' : '#999999')
            .flexShrink(0)
        }
      }
    }
    .backgroundColor(this.cardCustomColor && this.cardCustomColor !== '#007DFF'
      ? (this.cardTransparentStyle
        ? '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1)
        : this.cardCustomColor)
      : (this.cardTransparentStyle
        ? (this.isDarkMode
          ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
          : `rgba(255,255,255,${this.cardBgOpacity / 100})`)
        : (this.isDarkMode ? '#2C2C2C' : '#FFFFFF')))
    .border({ width: this.cardTransparentStyle ? this.cardBorderWidth : 0,
      color: this.cardTransparentStyle
        ? (this.cardBorderFollowTheme
          ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1))
          : (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)'))
        : Color.Transparent })
    .borderRadius(12)
    .clip(true)
    .padding(12)
    .shadow({ radius: 4, color: '#10000000', offsetY: 2 })
    .clickEffect({ level: 0, scale: 0.95 })
    .onClick(() => {
      if (item.id && item.id.startsWith('live_')) {
        const roomId = item.id.replace('live_', '');
        this.openLiveRoom(roomId, item.ownerName);
      }
    })
  }

  // ────────── 用户搜索结果卡片 ──────────
  @Builder
  UserCard(item: RecommendItem) {
    Row() {
      // 头像（圆形）
      Image(item.ownerFace)
        .width(48).height(48)
        .borderRadius(24)
        .margin({ right: 12 })
        .objectFit(ImageFit.Cover)
        .backgroundColor(this.isDarkMode ? '#444444' : '#E0E0E0')

      Column() {
        // 用户名
        Text(item.ownerName)
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#E0E0E0' : '#000000')
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        // 签名
        if (item.title) {
          Text(item.title)
            .fontSize(12)
            .fontColor(this.isDarkMode ? '#888888' : '#999999')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 4 })
        }

        // 粉丝数 + 视频数
        Row() {
          if (item.playCount > 0) {
            Text(`${this.formatFansCount(item.playCount)} 粉丝`)
              .fontSize(11)
              .fontColor(this.isDarkMode ? '#666666' : '#AAAAAA')
          }
          if (item.danmakuCount > 0) {
            Text(`${item.danmakuCount} 视频`)
              .fontSize(11)
              .fontColor(this.isDarkMode ? '#666666' : '#AAAAAA')
              .margin({ left: 12 })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 右侧关注按钮
      Image($r('app.media.checkmark_circle_fill'))
        .width(48).height(48)
        .margin({ left: 8 })
        .objectFit(ImageFit.Contain)
        .flexShrink(0)
        .fillColor(this.followedUserIds.indexOf(item.id) >= 0 ? '#FB7299' : '#545452')
        .onClick(() => {
          this.triggerHaptic();
          this.toggleFollowUser(item);
        })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.cardCustomColor && this.cardCustomColor !== '#007DFF'
      ? (this.cardTransparentStyle
        ? '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1)
        : this.cardCustomColor)
      : (this.cardTransparentStyle
        ? (this.isDarkMode
          ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
          : `rgba(255,255,255,${this.cardBgOpacity / 100})`)
        : (this.isDarkMode ? '#2C2C2C' : '#FFFFFF')))
    .border({ width: this.cardTransparentStyle ? this.cardBorderWidth : 0,
      color: this.cardTransparentStyle
        ? (this.cardBorderFollowTheme
          ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1))
          : (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)'))
        : Color.Transparent })
    .borderRadius(999)
    .onClick(() => {
      this.triggerHaptic();
      const mid = parseInt(item.ownerMid, 10);
      if (mid && !isNaN(mid)) {
        this.getUIContext().getRouter().pushUrl({
          url: 'pages/UpSpacePage',
          params: {
            mid: mid,
            upName: item.ownerName,
            upFace: item.ownerFace
          }
        });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: `用户: ${item.ownerName}` });
      }
    })
  }

  private formatFansCount(count: number): string {
    if (count >= 10000) {
      return (count / 10000).toFixed(1) + '万';
    }
    return count.toString();
  }

  private opacityToHexAlpha(opacity: number): string {
    const clamped = Math.max(0, Math.min(100, opacity));
    const hex = Math.round(clamped / 100 * 255).toString(16).toUpperCase();
    return hex.length < 2 ? '0' + hex : hex;
  }

  // ⭐ 真实关注/取关用户
  private toggleFollowUser(item: RecommendItem): void {
    const midStr = item.ownerMid;
    const mid = parseInt(midStr, 10);
    if (!mid || isNaN(mid)) {
      this.getUIContext().getPromptAction().showToast({ message: '无法获取用户ID' });
      return;
    }

    const isCurrentlyFollowed = this.followedUserIds.indexOf(item.id) >= 0;

    // 先乐观更新 UI
    if (isCurrentlyFollowed) {
      // 当前已关注 → 移除（变为未关注）
      this.followedUserIds = this.followedUserIds.filter(id => id !== item.id);
    } else {
      // 当前未关注 → 加入（变为已关注）
      this.followedUserIds = [...this.followedUserIds, item.id];
    }

    // 调用 API：act=1 关注, act=2 取关
    modifyFollow(mid, isCurrentlyFollowed ? 2 : 1).then((success: boolean) => {
      if (success) {
        this.getUIContext().getPromptAction().showToast({ message: isCurrentlyFollowed ? '取消关注' : '关注成功', duration: 1500 });
      } else {
        // 失败则回滚
        if (isCurrentlyFollowed) {
          this.followedUserIds = [...this.followedUserIds, item.id];
        } else {
          this.followedUserIds = this.followedUserIds.filter(id => id !== item.id);
        }
        this.getUIContext().getPromptAction().showToast({ message: '操作失败，请重试', duration: 1500 });
      }
    });
  }

  // 标记已关注的用户：先用搜索结果的 isFollowed（快速通道），再通过 getFollowStatus 逐个查询
  private async initFollowedUsers(): Promise<void> {
    logInfo(`[initFollowedUsers] 开始，结果数=${this.activeResults.length}`);
    // 第一遍：利用搜索 API 自带的 is_followed 字段（零开销）
    for (const item of this.activeResults) {
      if (item.ownerMid.length === 0) continue;
      if (item.isFollowed && this.followedUserIds.indexOf(item.id) < 0) {
        this.followedUserIds = [...this.followedUserIds, item.id];
      }
    }
    logInfo(`[initFollowedUsers] 第一遍完成，followedUserIds=${this.followedUserIds.length}`);
    // 第二遍：通过 x/web-interface/card 接口逐个查询
    for (const item of this.activeResults) {
      if (item.ownerMid.length === 0) continue;
      if (this.followedUserIds.indexOf(item.id) >= 0) continue; // 已标记则跳过
      try {
        const mid = parseInt(item.ownerMid, 10);
        if (!mid || isNaN(mid)) continue;
        const isFollowed = await getFollowStatus(mid);
        if (isFollowed && this.followedUserIds.indexOf(item.id) < 0) {
          this.followedUserIds = [...this.followedUserIds, item.id];
        }
      } catch (e) {
        logWarn(`[initFollowedUsers] 查询 mid=${item.ownerMid} 失败: ${e}`);
      }
    }
    logInfo(`[initFollowedUsers] 全部完成，共 ${this.followedUserIds.length} 个`);
  }

  // ────────── 根据类型导航 ──────────
  private navigateToDetail(item: RecommendItem, tabType: string): void {
    if (tabType === 'live_user' && item.id.startsWith('live_')) {
      const roomId = item.id.replace('live_', '');
      this.openLiveRoom(roomId, item.ownerName);
    } else {
      this.getUIContext().getPromptAction().showToast({ message: `${getSearchTypeLabel(tabType) || tabType}: ${item.title}` });
    }
  }

  private openLiveRoom(roomId: string, ownerName: string): void {
    logInfo(`[SearchPage] 进入直播间 roomId=${roomId}`);
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/LivePlayerPage',
      params: { roomId: parseInt(roomId) }
    });
  }

  /** 从主播头像进入直播间 */
  private enterLiveRoom(id: string): void {
    if (id.startsWith('live_')) {
      const roomId = id.substring(5);
      this.openLiveRoom(roomId, '');
    }
  }

  // ────────── 工具函数 ──────────
  private formatNumber(num: number): string {
    if (num >= 100000000) return (num / 100000000).toFixed(1) + '亿';
    if (num >= 10000) return (num / 10000).toFixed(1) + '万';
    return num.toString();
  }

  private getPlayCountColor(count: number): string {
    if (count >= 10000000) return '#FF0000';
    if (count >= 3000000) return '#C2185B';
    if (count >= 1000000) return '#FF8C00';
    if (count >= 100000) return '#FFB800';
    if (count >= 50000) return '#4A90D9';
    return '#999999';
  }

  private formatTimeAgo(timestamp: number): string {
    if (!timestamp) return '';
    const now = Math.floor(Date.now() / 1000);
    const diff = now - timestamp;

    if (diff < 60) {
      return '刚刚';
    } else if (diff < 3600) {
      return `${Math.floor(diff / 60)}分钟前`;
    } else if (diff < 86400) {
      return `${Math.floor(diff / 3600)}小时前`;
    } else if (diff < 2592000) {
      return `${Math.floor(diff / 86400)}天前`;
    } else if (diff < 31536000) {
      return `${Math.floor(diff / 2592000)}个月前`;
    } else {
      return `${Math.floor(diff / 31536000)}年前`;
    }
  }
}