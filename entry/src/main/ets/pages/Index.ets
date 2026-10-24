import {
  HdsTabs,
  HdsTabsController,
  HdsAnimationMode,
  hdsMaterial,
  HdsNavigation,
  HdsNavigationTitleMode,
  ScrollEffectType
} from '@kit.UIDesignKit';
import { ProfilePage } from './ProfilePage';
import { DynamicsPage } from './DynamicsPage';
import { WhisperPage } from './WhisperPage';
import { HomeChannelContainer, CHANNEL_TABS, ChannelTabDef } from '../components/HomeChannelContainer';
import { window, LengthMetrics, curves, display } from '@kit.ArkUI';
import { VibrateUtils } from '../utils/VibrateUtils';
import { preferences } from '@kit.ArkData';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { motion } from '@kit.MultimodalAwarenessKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { BusinessError } from '@kit.BasicServicesKit';
import { FloatingVideoButton } from '../components/FloatingVideoButton';
import { StatusBarUtils } from '../utils/StatusBarUtils';
import { loadWallpaperModes } from '../utils/WallpaperTheme';
import { applyCardStyleModeArchive } from '../utils/CardStyleMode';
import { getHdsMaterialLevelRaw } from '../components/infra/MaterialLevel';
import { HdsMiniBarButton } from '../components/infra/HdsMiniBarButton';

// ⭐ 一级 Tab 逻辑页 ID（固定不变，与显隐无关；所有业务判断统一用它）
//    物理位置（TabContent 实际渲染序号）随「显示动态页/消息页」开关变化，仅 HdsTabs index 参数需要映射
const PAGE_HOME: number = 0;
const PAGE_DYN: number = 1;
const PAGE_MSG: number = 2;
const PAGE_PROFILE: number = 3;

@Entry
@Component({ freezeWhenInactive: true })
struct Index {
  private controller: HdsTabsController = new HdsTabsController();
  /** ⚠️ Tab 历史栈：右滑/返回键时回退到上一个浏览的 Tab（不退出应用）；存逻辑页 ID */
  private tabHistory: number[] = [];
  // ⭐ activeTab 语义 = 逻辑页 ID（0=首页, 1=动态, 2=消息, 3=我的），与 TabContent 渲染位置无关；
  //    传给 HdsTabs 的 index 参数需经 tabIndexFor() 映射为物理位置
  @State activeTab: number = PAGE_HOME; // ⭐ 启动默认落在首页频道容器
  // ⭐ 一级 Tab 显隐开关（默认都显示）— 关闭后对应 TabContent 不渲染、底栏图标消失
  @StorageLink('showDynamicsTab') @Watch('onTabVisibilityChange') showDynamicsTab: boolean = true;
  @StorageLink('showWhisperTab') @Watch('onTabVisibilityChange') showWhisperTab: boolean = true;
  @State iconActiveTab: number = 0; // ⭐ 底栏图标高亮目标：onAnimationStart 即时更新，避免等 onChange（动画结束）才切换图标
  @State animatingTab: number = -1; // ⭐ 切换时缩小，短延时后弹回
  @State capsuleOpacity: number = 1; // ⭐ 胶囊标题动画
  @State capsuleScale: number = 1;
  @State titleBarReady: boolean = false; // ⭐ 标题栏延迟挂载：安全区就绪后再渲染，避免首帧错误位置成像残影
  @State capsuleLabelIdx: number = 2; // ⭐ 胶囊显示当前频道（0=分类 1=直播 2=推荐 3=热门 4=番剧 5=影视；默认 2=推荐，与 homeChannelIndex 一致）
  @State capsuleExpanded: boolean = false; // ⭐ 胶囊展开为频道分段选择器
  @State capsuleContentOpacity: number = 0; // ⭐ 展开态内容淡入透明度
  @State capsuleSegStep: number = 0; // ⭐ 展开态分段逐个出现步进（0-6，每步多出现一段）
  // ⭐ 番剧索引按钮显隐动画状态（始终渲染 + animateTo 驱动：上下滑动标题栏整体显隐时不重播 transition，
  //    频道切换/胶囊展开时由 updateIndexBtnVisibility 播放分裂/融入）
  @State indexBtnOpacity: number = 0;   // 0=隐藏 1=显示
  @State indexBtnScale: number = 0.2;   // 显示时 1
  @State indexBtnOffsetX: number = -20; // 显示时 -8（8vp 视觉间距）；隐藏时再向左 12vp 融向胶囊
  private capsuleStaggerToken: number = 0; // 分段逐个出现 token：收起/重开时递增使残留回调作废
  private capsuleAnimToken: number = 0; // 胶囊标题切换动画 token：新切换递增使旧 setTimeout 回调作废（替代易卡死的 capsuleAnimating 标志）
  // ⭐ 当前首页频道（0=推荐 1=热门 2=直播 3=番剧 4=影视 5=分类）— 与 HomeChannelContainer 双向同步
  @StorageLink('homeChannelIndex') @Watch('onHomeChannelIndexChange') homeChannelIndex: number = 2;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('navIndicatorHeight') navIndicatorHeight: number = 0;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @StorageLink('wallpaper') wallpaper: string = 'builtin';
  @StorageLink('customWallpaper') customWallpaper: string = '/data/local/tmp/wallpaper_def.jpg';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;
  @StorageLink('wallpaperColor') wallpaperColor: string = '#007DFF';
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @State imageLoadFailed: boolean = false;
  @State wallpaperReady: boolean = false;
  // 横竖屏状态 — 用于 barFloatingStyle 自适应
  @State isLandscape: boolean = false;
  // 智感握姿：左手持握为 true，右手为 false
  @State leftHanded: boolean = false;
  // ⭐ 页面切换缩放+淡入动画状态
  @State pageScale0: number = 1;
  @State pageOpacity0: number = 1;
  @State pageRadius0: number = 0;
  @State pageScale1: number = 1;
  @State pageOpacity1: number = 1;
  @State pageRadius1: number = 0;
  @State pageScale2: number = 1;
  @State pageOpacity2: number = 1;
  @State pageRadius2: number = 0;
  @State pageScale3: number = 1;
  @State pageOpacity3: number = 1;
  @State pageRadius3: number = 0;
  // ⭐ 智感握姿开关
  @StorageLink('smartGripEnabled') smartGripEnabled: boolean = true;
  // 数据偏好设置
  private dataPreferences: preferences.Preferences | null = null;


  // 底栏显隐由子页面 onScrollEnd 驱动，调用系统 API 动画
  @StorageLink('bottomBarHidden') @Watch('onBottomBarHiddenChange') bottomBarHidden: boolean = false;

  // ⭐ 消息页 Tab 自动隐藏开关（默认关闭 = 消息页保留底部 Tab 栏）
  //    仅控制「进入消息页(2)是否隐藏底栏」，不影响其他页面的滚动自动显隐
  @StorageLink('msgTabAutoHide') @Watch('onMsgTabAutoHideChange') msgTabAutoHide: boolean = false;

  @StorageLink('homeScrollOffset') @Watch('onHomeScrollOffsetChange') homeScrollOffset: number = 0;

  // 上一次底栏显隐状态，避免重复调用系统 API
  private prevBottomBarHidden: boolean = false;

  // ★ 系统级沉浸光感配置 — 探测设备支持后降级，避免 sys.float.hms_material_style 解析失败闪烁
  // 默认 ADAPTIVE（跟随系统），aboutToAppear 中根据 getSystemMaterialTypes() 结果调整
  @State customMaterialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.ADAPTIVE;
  @State customMaterialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;

  // ★ 各页面的 Scroller — 由 Index 直接创建，同时传给子页面和 bindToScrollable
  private homeScroller: Scroller = new Scroller();
  private discoverScroller: Scroller = new Scroller();

  // ══════════ 逻辑页 ID ↔ 物理 Tab 位置 映射（显隐开关会改变物理位置） ══════════

  /** 当前可见的逻辑页 ID 列表（按固定顺序：首页 → 动态? → 消息? → 我的） */
  private visiblePages(): number[] {
    const pages: number[] = [PAGE_HOME];
    if (this.showDynamicsTab) pages.push(PAGE_DYN);
    if (this.showWhisperTab) pages.push(PAGE_MSG);
    pages.push(PAGE_PROFILE);
    return pages;
  }

  /** 物理 Tab 位置 → 逻辑页 ID（越界兜底首页） */
  private pageIndexOf(tabIndex: number): number {
    const pages: number[] = this.visiblePages();
    return (tabIndex >= 0 && tabIndex < pages.length) ? pages[tabIndex] : PAGE_HOME;
  }

  /** 逻辑页 ID → 物理 Tab 位置（被隐藏的页兜底返回首页位置 0） */
  private tabIndexFor(pageId: number): number {
    const pages: number[] = this.visiblePages();
    const idx: number = pages.indexOf(pageId);
    return idx >= 0 ? idx : 0;
  }

  /**
   * ⭐ 显隐开关变化：若当前正停留在被隐藏的页 → 回退首页（底栏恢复、清返回栈）。
   * 设置入口在「我的」页，常规操作不会触发；此为防御（未来若有别处改开关）。
   */
  private onTabVisibilityChange(): void {
    if ((this.activeTab === PAGE_DYN && !this.showDynamicsTab)
      || (this.activeTab === PAGE_MSG && !this.showWhisperTab)) {
      this.activeTab = PAGE_HOME;
      this.iconActiveTab = PAGE_HOME;
      AppStorage.set('bottomBarHidden', false);
    }
    this.tabHistory = [];
  }

  // ★ 底栏显隐变化 → 系统 API 动画
  onBottomBarHiddenChange() {
    if (this.bottomBarHidden === this.prevBottomBarHidden) return;
    this.prevBottomBarHidden = this.bottomBarHidden;
    if (this.bottomBarHidden) {
      this.controller.applyHideAnimation(HdsAnimationMode.SCROLL_ANIMATION);
    } else {
      this.controller.applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION);
    }
  }

  // ★ 消息页 Tab 自动隐藏开关变化 → 若此刻正停在消息页则实时生效；关闭时清空返回栈
  onMsgTabAutoHideChange() {
    if (this.activeTab === PAGE_MSG) {
      AppStorage.set('bottomBarHidden', this.shouldHideBottomBarForTab(PAGE_MSG));
    }
    if (!this.msgTabAutoHide) {
      this.tabHistory = [];
    }
  }

  /**
   * 消息页是否需要隐藏悬浮底栏
   * - 竖屏：由「消息页 Tab 自动隐藏」开关决定（默认关闭 = 保留底栏，可正常切 Tab）
   * - 横屏：始终隐藏 —— 横屏消息页是「会话列表 + 聊天」双栏、底部常驻聊天输入栏，
   *   悬浮底栏会压在输入区上，沿用原有隐藏行为
   */
  private shouldHideBottomBarForTab(pageId: number): boolean {
    if (pageId !== PAGE_MSG) {
      return false;
    }
    return this.msgTabAutoHide || this.isLandscape;
  }

  onHomeScrollOffsetChange() {
    logInfo('Index: homeScrollOffset changed to', this.homeScrollOffset);
  }

  // ⭐ 容器内滑动/点击切换频道 → 胶囊标题跟随（仅当首页 Tab 激活时生效）
  onHomeChannelIndexChange() {
    const ch: number = this.homeChannelIndex;
    if (ch < 0 || ch >= CHANNEL_TABS.length) return;
    if (this.capsuleLabelIdx !== ch) {
      this.capsuleLabelIdx = ch;
      this.playCapsuleAnimation(ch);
      // ⭐ 频道切换后同步番剧索引按钮显隐（番剧频道从胶囊分裂弹出，其他频道融入胶囊）
      this.updateIndexBtnVisibility();
    }
  }

  onPageShow() {
    const goHome = AppStorage.get<boolean>('goHome') ?? false;
    if (goHome) {
      AppStorage.setOrCreate<boolean>('goHome', false);
      this.activeTab = PAGE_HOME;
    }
  }

  async aboutToAppear() {
    // ⭐ 标题栏延迟挂载：安全区/布局未稳定前不创建标题栏材质组件（首帧即空），
    //    350ms 后再渲染，让材质直接成像在正确位置，杜绝横屏更明显的首帧错位残影
    this.titleBarReady = false;
    setTimeout(() => {
      this.titleBarReady = true;
    }, 1500);
    // 初始化数据偏好设置
    try {
      const uiContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.dataPreferences = await preferences.getPreferences(uiContext, 'my_app_settings');

      // ⭐ 默认画质以 preferences 为唯一权威来源：
      //    VideoPlayerPage 里曾用 PersistentStorage.persistProp 持久化该 key，它会把
      //    上一次运行的内存值固化下来，与用户在设置里保存的值冲突 ——
      //    实测「默认 4K」被快速起播的自动升档写成 1080P 后，重启仍然读到 1080P，
      //    而 preferences 里其实还是 4K。这里启动时统一校正一次。
      const storedVideoQn = await this.dataPreferences.get('defaultVideoQn', 116) as number;
      AppStorage.setOrCreate<number>('defaultVideoQn', storedVideoQn);

      
      // 从持久化存储加载设置
      let darkMode = await this.dataPreferences.get('isDarkMode', false) as boolean;
      let storedWallpaper = await this.dataPreferences.get('wallpaper', 'builtin') as string;
      let storedCustomPath = await this.dataPreferences.get('customWallpaper', '') as string;
      let storedCustomColor = await this.dataPreferences.get('customThemeColor', '#007DFF') as string;
      let storedWallpaperColor = await this.dataPreferences.get('wallpaperColor', '#007DFF') as string;
      let storedBlur = await this.dataPreferences.get('wallpaperBlur', 0) as number;
      let storedDarkness = await this.dataPreferences.get('wallpaperDarkness', 50) as number;
      let storedCardTransparent = await this.dataPreferences.get('cardTransparentStyle', true) as boolean;
      let storedCardBorderTheme = await this.dataPreferences.get('cardBorderFollowTheme', true) as boolean;
      let storedCardBorderPlayCount = await this.dataPreferences.get('cardBorderFollowPlayCount', false) as boolean;
      let storedCardBorderOpacity = await this.dataPreferences.get('cardBorderOpacity', 25) as number;
      let storedCardBgOpacity = await this.dataPreferences.get('cardBgOpacity', 70) as number;
      let storedCardBorderWidth = await this.dataPreferences.get('cardBorderWidth', 1) as number;
      let storedCardCustomColor = await this.dataPreferences.get('cardCustomColor', '') as string;
      let storedCapsuleFollowTheme = await this.dataPreferences.get('cardCapsuleFollowTheme', false) as boolean;
      let storedCapsuleShow = await this.dataPreferences.get('cardCapsuleShow', true) as boolean;
      let storedCapsuleSize = await this.dataPreferences.get('cardCapsuleSize', 12) as number;
      let storedCapsuleRadius = await this.dataPreferences.get('cardCapsuleRadius', 7) as number;
      let storedCapsuleColor = await this.dataPreferences.get('cardCapsuleColor', '') as string;
      let storedPlayCountShow = await this.dataPreferences.get('cardPlayCountShow', true) as boolean;
      let storedPlayCountUnit = await this.dataPreferences.get('cardPlayCountUnit', 'wanYi') as string;
      let storedPlayCountSize = await this.dataPreferences.get('cardPlayCountSize', 12) as number;
      let storedPlayCountColorMode = await this.dataPreferences.get('cardPlayCountColorMode', 'level') as string;
      let storedPlayCountColor = await this.dataPreferences.get('cardPlayCountColor', '') as string;
      let storedPlayCountIcon = await this.dataPreferences.get('cardPlayCountIcon', true) as boolean;
      let storedCardStylePerMode = await this.dataPreferences.get('cardStylePerMode', true) as boolean;
      let storedPlayerFollowTheme = await this.dataPreferences.get('playerFollowTheme', true) as boolean;
      let storedBgBlurAmount = await this.dataPreferences.get('cardBgBlurAmount', 24) as number;
      let storedBgDarkness = await this.dataPreferences.get('cardBgDarkness', 50) as number;
      let storedVideoStyle = await this.dataPreferences.get('cardTransparentStyleVideo', true) as boolean;
      let storedVideoDetail = await this.dataPreferences.get('cardStyleVideoDetail', true) as boolean;
      let storedVideoCommentSection = await this.dataPreferences.get('cardStyleVideoCommentSection', true) as boolean;
      let storedVideoCommentBubble = await this.dataPreferences.get('cardStyleVideoCommentBubble', true) as boolean;
      let storedVideoDescription = await this.dataPreferences.get('cardStyleVideoDescription', true) as boolean;
      let storedVideoSegmentBtn = await this.dataPreferences.get('cardStyleVideoSegmentBtn', true) as boolean;
      let storedVideoInteractBtns = await this.dataPreferences.get('cardStyleVideoInteractBtns', true) as boolean;
      let storedVideoNavBtns = await this.dataPreferences.get('cardStyleVideoNavBtns', true) as boolean;
      let storedVideoCommentAlign = await this.dataPreferences.get('cardStyleVideoCommentAlign', 'center') as string;
      let storedVideoBgMode = await this.dataPreferences.get('videoBgMode', 'cover') as string;
      let storedVideoBgColor = await this.dataPreferences.get('videoBgColor', '#007DFF') as string;
      let storedVideoBgCustomWallpaper = await this.dataPreferences.get('videoBgCustomWallpaper', '') as string;
      let storedVideoBgCustomWallpaperBlur = await this.dataPreferences.get('videoBgCustomWallpaperBlur', 0) as number;
      let storedVideoBgCustomWallpaperDarkness = await this.dataPreferences.get('videoBgCustomWallpaperDarkness', 50) as number;
      let storedSearchSuggest = await this.dataPreferences.get('cardStyleSearchSuggest', true) as boolean;
      let storedLiveCategory = await this.dataPreferences.get('cardStyleLiveCategory', true) as boolean;
      let storedLiveQuality = await this.dataPreferences.get('cardStyleLiveQuality', true) as boolean;
      let storedCardBorderRadius = await this.dataPreferences.get('cardBorderRadius', 30) as number;
      let storedCardMargin = await this.dataPreferences.get('cardMargin', 12) as number;
      let storedCardListBorderRadius = await this.dataPreferences.get('cardListBorderRadius', 12) as number;
      let storedCardListMargin = await this.dataPreferences.get('cardListMargin', 12) as number;
      // ⭐ 标题胶囊彩色图标开关（默认开）
      let storedCapsuleColorIcons = await this.dataPreferences.get('capsuleColorIcons', true) as boolean;
      let storedSmartGripEnabled = await this.dataPreferences.get('smartGripEnabled', true) as boolean;
      let storedFloatBtnFollowTheme = await this.dataPreferences.get('floatBtnFollowTheme', true) as boolean;
      let storedFloatBtnRotationSpeed = await this.dataPreferences.get('floatBtnRotationSpeed', 8) as number;

      // 从持久化存储加载全屏动画 / 页面动画设置
      let storedPageEnterAnim = await this.dataPreferences.get('pageEnterAnim', 'scaleFade') as string;
      let storedFsAnimOn = await this.dataPreferences.get('fsAnimOn', true) as boolean;

      // 从持久化存储加载登录状态 + 状态栏隐藏
      let storedCookie = await this.dataPreferences.get('biliCookie', '') as string;
      let storedAccessKey = await this.dataPreferences.get('biliAccessKey', '') as string;
      let storedHideStatusBar = await this.dataPreferences.get('hideStatusBar', false) as boolean;
      let storedShrinkVideo = await this.dataPreferences.get('shrinkVideoOnScroll', false) as boolean;
      // ⭐ 消息页 Tab 自动隐藏（默认关闭）
      let storedMsgTabAutoHide = await this.dataPreferences.get('msgTabAutoHide', false) as boolean;
      // ⭐ 一级 Tab 显隐（默认都显示）：隐藏动态页/消息页后 TabContent 不渲染、底栏图标消失
      let storedShowDynamicsTab = await this.dataPreferences.get('showDynamicsTab', true) as boolean;
      let storedShowWhisperTab = await this.dataPreferences.get('showWhisperTab', true) as boolean;
      // ⭐ 动态页点击切换分类（默认打开；打开 = 只能点胶囊切分类，关闭 = 恢复横滑切分类）
      let storedDynFilterTapOnly = await this.dataPreferences.get('dynFilterTapOnly', true) as boolean;
      // ⭐ 首页点击切换分类（默认关闭；关闭 = 允许横滑切频道，打开 = 只能点胶囊切频道）
      let storedHomeFilterTapOnly = await this.dataPreferences.get('homeFilterTapOnly', false) as boolean;
// ⭐ 缩小播放器的小窗样式 / 缩小后暂停播放（个性化 → 视频页动画）
let storedShrinkWindowStyle = await this.dataPreferences.get('shrinkWindowStyle', 'circle') as string;
let storedShrinkPauseOnMinimize = await this.dataPreferences.get('shrinkPauseOnMinimize', false) as boolean;
let storedShrinkWindowSize = await this.dataPreferences.get('shrinkWindowSize', 120) as number;
      let storedShowRefreshSeparator = await this.dataPreferences.get('showRefreshSeparator', true) as boolean;
      let storedShowHomeCarouselPortrait = await this.dataPreferences.get('showHomeCarouselPortrait', true) as boolean;
      let storedShowHomeCarouselLandscape = await this.dataPreferences.get('showHomeCarouselLandscape', true) as boolean;
      let storedShowCarouselBgPortrait = await this.dataPreferences.get('showCarouselBgPortrait', true) as boolean;
      let storedShowCarouselBgLandscape = await this.dataPreferences.get('showCarouselBgLandscape', true) as boolean;
      // ⭐ 轮播背景圆角（0-40vp，默认 30，越界值夹紧）
      let storedCarouselBgRadiusRaw = await this.dataPreferences.get('carouselBgRadius', 30) as number;
      let storedCarouselBgRadius = Math.max(0, Math.min(40, Math.round(storedCarouselBgRadiusRaw)));
      // ⭐ 轮播图标题胶囊自定义设置（冷启动即回填，避免进"我的页面"前首页不生效）
      let storedCarouselTitleFontSize = await this.dataPreferences.get('carouselTitleFontSize', 15) as number;
      let storedCarouselTitleFontWeight = await this.dataPreferences.get('carouselTitleFontWeight', 'medium') as string;
      // 兼容旧版本语义：旧值 0=自动 或固定 vp（160-240），统一归一为百分比 20-100（默认 85）
      let storedCarouselTitleCapsuleWidthRaw = await this.dataPreferences.get('carouselTitleCapsuleWidth', 85) as number;
      let storedCarouselTitleCapsuleWidth = (storedCarouselTitleCapsuleWidthRaw >= 20 && storedCarouselTitleCapsuleWidthRaw <= 100)
        ? storedCarouselTitleCapsuleWidthRaw
        : 85;
      let storedCarouselTitleCapsuleHeight = await this.dataPreferences.get('carouselTitleCapsuleHeight', 36) as number;
      let storedCarouselTitleLetterSpacing = await this.dataPreferences.get('carouselTitleLetterSpacing', 1) as number;

      // 更新本地变量和AppStorage
      this.isDarkMode = darkMode;
      this.wallpaper = storedWallpaper;
      this.customWallpaper = storedCustomPath;
      this.customThemeColor = storedCustomColor;
      this.wallpaperColor = storedWallpaperColor;
      this.wallpaperBlur = storedBlur;
      this.wallpaperDarkness = storedDarkness;
      
      AppStorage.setOrCreate('isDarkMode', darkMode);
      AppStorage.setOrCreate('wallpaper', storedWallpaper);
      AppStorage.setOrCreate('customWallpaper', storedCustomPath);
      AppStorage.setOrCreate('customThemeColor', storedCustomColor);
      AppStorage.setOrCreate('wallpaperColor', storedWallpaperColor);
      AppStorage.setOrCreate('wallpaperBlur', storedBlur);
      AppStorage.setOrCreate('wallpaperDarkness', storedDarkness);
      // 加载深/浅两套壁纸存档（缺失回填激活值）并装载当前模式
      await loadWallpaperModes(this.dataPreferences, darkMode);
      // 卡片样式「深浅色独立」：启动时装载当前模式档案
      if (AppStorage.get<boolean>('cardStylePerMode') === true) {
        // applyCardStyleModeArchive 已由预加载保证；此处同步激活键
        await applyCardStyleModeArchive(this.dataPreferences, darkMode);
      }
      AppStorage.setOrCreate('cardTransparentStyle', storedCardTransparent);
      AppStorage.setOrCreate('cardBorderFollowTheme', storedCardBorderTheme);
      AppStorage.setOrCreate('cardBorderFollowPlayCount', storedCardBorderPlayCount);
      AppStorage.setOrCreate('cardBorderOpacity', storedCardBorderOpacity);
      AppStorage.setOrCreate('cardBgOpacity', storedCardBgOpacity);
      AppStorage.setOrCreate('cardBorderWidth', storedCardBorderWidth);
      AppStorage.setOrCreate('cardCustomColor', storedCardCustomColor);
      AppStorage.setOrCreate('cardCapsuleFollowTheme', storedCapsuleFollowTheme);
      AppStorage.setOrCreate('cardCapsuleShow', storedCapsuleShow);
      AppStorage.setOrCreate('cardCapsuleSize', storedCapsuleSize);
      AppStorage.setOrCreate('cardCapsuleRadius', storedCapsuleRadius);
      AppStorage.setOrCreate('cardCapsuleColor', storedCapsuleColor);
      AppStorage.setOrCreate('cardPlayCountShow', storedPlayCountShow);
      AppStorage.setOrCreate('cardPlayCountUnit', storedPlayCountUnit);
      AppStorage.setOrCreate('cardPlayCountSize', storedPlayCountSize);
      AppStorage.setOrCreate('cardPlayCountColorMode', storedPlayCountColorMode);
      AppStorage.setOrCreate('cardPlayCountColor', storedPlayCountColor);
      AppStorage.setOrCreate('cardPlayCountIcon', storedPlayCountIcon);
      AppStorage.setOrCreate('cardStylePerMode', storedCardStylePerMode);
      AppStorage.setOrCreate('playerFollowTheme', storedPlayerFollowTheme);
      AppStorage.setOrCreate('cardBgBlurAmount', storedBgBlurAmount);
      AppStorage.setOrCreate('cardBgDarkness', storedBgDarkness);
      AppStorage.setOrCreate('cardTransparentStyleVideo', storedVideoStyle);
      AppStorage.setOrCreate('cardStyleVideoDetail', storedVideoDetail);
      AppStorage.setOrCreate('cardStyleVideoCommentSection', storedVideoCommentSection);
      AppStorage.setOrCreate('cardStyleVideoCommentBubble', storedVideoCommentBubble);
      AppStorage.setOrCreate('cardStyleVideoDescription', storedVideoDescription);
      AppStorage.setOrCreate('cardStyleVideoSegmentBtn', storedVideoSegmentBtn);
      AppStorage.setOrCreate('cardStyleVideoInteractBtns', storedVideoInteractBtns);
      AppStorage.setOrCreate('cardStyleVideoNavBtns', storedVideoNavBtns);
      AppStorage.setOrCreate('cardStyleVideoCommentAlign', storedVideoCommentAlign);
      AppStorage.setOrCreate('videoBgMode', storedVideoBgMode);
      AppStorage.setOrCreate('videoBgColor', storedVideoBgColor);
      AppStorage.setOrCreate('videoBgCustomWallpaper', storedVideoBgCustomWallpaper);
      AppStorage.setOrCreate('videoBgCustomWallpaperBlur', storedVideoBgCustomWallpaperBlur);
      AppStorage.setOrCreate('videoBgCustomWallpaperDarkness', storedVideoBgCustomWallpaperDarkness);
      AppStorage.setOrCreate('smartGripEnabled', storedSmartGripEnabled);
      AppStorage.setOrCreate('floatBtnFollowTheme', storedFloatBtnFollowTheme);
      AppStorage.setOrCreate('floatBtnRotationSpeed', storedFloatBtnRotationSpeed);
      AppStorage.setOrCreate('cardStyleSearchSuggest', storedSearchSuggest);
      AppStorage.setOrCreate('cardStyleLiveCategory', storedLiveCategory);
      AppStorage.setOrCreate('cardStyleLiveQuality', storedLiveQuality);
      AppStorage.setOrCreate('cardBorderRadius', storedCardBorderRadius);
      AppStorage.setOrCreate('cardMargin', storedCardMargin);
      AppStorage.setOrCreate('cardListBorderRadius', storedCardListBorderRadius);
      AppStorage.setOrCreate('cardListMargin', storedCardListMargin);
      AppStorage.setOrCreate('capsuleColorIcons', storedCapsuleColorIcons);

      // 同步悬浮按钮位置设置
      let storedSearchFloatBtnSide = await this.dataPreferences.get('searchFloatBtnSide', 'right') as string;
      let storedSearchFloatBtnY = await this.dataPreferences.get('searchFloatBtnY', 120) as number;
      let storedWatchHistoryFloatBtnSide = await this.dataPreferences.get('watchHistoryFloatBtnSide', 'right') as string;
      let storedWatchHistoryFloatBtnY = await this.dataPreferences.get('watchHistoryFloatBtnY', 120) as number;
      AppStorage.setOrCreate('searchFloatBtnSide', storedSearchFloatBtnSide);
      AppStorage.setOrCreate('searchFloatBtnY', storedSearchFloatBtnY);
      AppStorage.setOrCreate('watchHistoryFloatBtnSide', storedWatchHistoryFloatBtnSide);
      AppStorage.setOrCreate('watchHistoryFloatBtnY', storedWatchHistoryFloatBtnY);

      // 同步动态详情页的回到顶部悬浮按钮位置（与上面各页各自的 key，互不干扰）
      let storedDynDetailFloatBtnSide = await this.dataPreferences.get('dynDetailFloatBtnSide', 'right') as string;
      let storedDynDetailFloatBtnY = await this.dataPreferences.get('dynDetailFloatBtnY', 120) as number;
      AppStorage.setOrCreate('dynDetailFloatBtnSide', storedDynDetailFloatBtnSide);
      AppStorage.setOrCreate('dynDetailFloatBtnY', storedDynDetailFloatBtnY);

      // 同步视频页悬浮按钮位置设置
      let storedVideoShrinkBtnSide = await this.dataPreferences.get('videoShrinkBtnSide', 'right') as string;
      let storedVideoShrinkBtnY = await this.dataPreferences.get('videoShrinkBtnY', 120) as number;
      let storedVideoLightBtnSide = await this.dataPreferences.get('videoLightBtnSide', 'right') as string;
      let storedVideoLightBtnY = await this.dataPreferences.get('videoLightBtnY', 120) as number;
      AppStorage.setOrCreate('videoShrinkBtnSide', storedVideoShrinkBtnSide);
      AppStorage.setOrCreate('videoShrinkBtnY', storedVideoShrinkBtnY);
      AppStorage.setOrCreate('videoLightBtnSide', storedVideoLightBtnSide);
      AppStorage.setOrCreate('videoLightBtnY', storedVideoLightBtnY);

      // 同步缓存提示条拖拽位置
      let storedCacheHintLeft = await this.dataPreferences.get('cacheHintLeft', 16) as number;
      let storedCacheHintBottom = await this.dataPreferences.get('cacheHintBottom', 96) as number;
      AppStorage.setOrCreate('cacheHintLeft', storedCacheHintLeft);
      AppStorage.setOrCreate('cacheHintBottom', storedCacheHintBottom);

      // 同步状态栏隐藏设置
      AppStorage.setOrCreate('hideStatusBar', storedHideStatusBar);

      // 同步视频缩小设置
      AppStorage.setOrCreate('shrinkVideoOnScroll', storedShrinkVideo);
      // 同步「消息页 Tab 自动隐藏」开关
      AppStorage.setOrCreate('msgTabAutoHide', storedMsgTabAutoHide);
      // 同步一级 Tab 显隐开关
      AppStorage.setOrCreate('showDynamicsTab', storedShowDynamicsTab);
      AppStorage.setOrCreate('showWhisperTab', storedShowWhisperTab);
      // 同步「动态页点击切换分类」开关
      AppStorage.setOrCreate('dynFilterTapOnly', storedDynFilterTapOnly);
      // 同步「首页点击切换分类」开关
      AppStorage.setOrCreate('homeFilterTapOnly', storedHomeFilterTapOnly);
AppStorage.setOrCreate('shrinkWindowStyle', storedShrinkWindowStyle);
AppStorage.setOrCreate('shrinkPauseOnMinimize', storedShrinkPauseOnMinimize);
AppStorage.setOrCreate('shrinkWindowSize', storedShrinkWindowSize);

      // 同步"上次看到这里"开关
      AppStorage.setOrCreate('showRefreshSeparator', storedShowRefreshSeparator);

      // 同步首页轮播图开关（竖屏/横屏独立）
      AppStorage.setOrCreate('showHomeCarouselPortrait', storedShowHomeCarouselPortrait);
      AppStorage.setOrCreate('showHomeCarouselLandscape', storedShowHomeCarouselLandscape);

      // 同步轮播图封面背景开关（竖屏/横屏独立）
      AppStorage.setOrCreate('showCarouselBgPortrait', storedShowCarouselBgPortrait);
      AppStorage.setOrCreate('showCarouselBgLandscape', storedShowCarouselBgLandscape);

      // ⭐ 同步轮播背景圆角
      AppStorage.setOrCreate('carouselBgRadius', storedCarouselBgRadius);

      // ⭐ 同步轮播图标题胶囊自定义设置到 AppStorage（冷启动即生效）
      AppStorage.setOrCreate('carouselTitleFontSize', storedCarouselTitleFontSize);
      AppStorage.setOrCreate('carouselTitleFontWeight', storedCarouselTitleFontWeight);
      AppStorage.setOrCreate('carouselTitleCapsuleWidth', storedCarouselTitleCapsuleWidth);
      AppStorage.setOrCreate('carouselTitleCapsuleHeight', storedCarouselTitleCapsuleHeight);
      AppStorage.setOrCreate('carouselTitleLetterSpacing', storedCarouselTitleLetterSpacing);

      // 同步全屏动画 / 页面动画设置到 AppStorage
      AppStorage.setOrCreate('pageEnterAnim', storedPageEnterAnim);
      AppStorage.setOrCreate('fsAnimOn', storedFsAnimOn);

      // 恢复登录状态
      if (storedCookie) {
        AppStorage.setOrCreate('biliCookie', storedCookie);
      }
      if (storedAccessKey) {
        AppStorage.setOrCreate('biliAccessKey', storedAccessKey);
      }

      // 同步系统色彩模式，让 HDS 组件（返回图标、菜单图标等）自动适配
      uiContext.getApplicationContext().setColorMode(
        darkMode ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
      );
    } catch (e) {
      // 如果加载失败，使用默认值初始化AppStorage
      logError('Failed to load preferences:', e);
      if (AppStorage.get('isDarkMode') === undefined) AppStorage.setOrCreate('isDarkMode', false);
      if (AppStorage.get('wallpaper') === undefined) AppStorage.setOrCreate('wallpaper', 'builtin');
      if (AppStorage.get('customWallpaper') === undefined) AppStorage.setOrCreate('customWallpaper', '');
      if (AppStorage.get('customThemeColor') === undefined) AppStorage.setOrCreate('customThemeColor', '#007DFF');
      if (AppStorage.get('wallpaperColor') === undefined) AppStorage.setOrCreate('wallpaperColor', '#007DFF');
      if (AppStorage.get('wallpaperBlur') === undefined) AppStorage.setOrCreate('wallpaperBlur', 0);
      if (AppStorage.get('wallpaperDarkness') === undefined) AppStorage.setOrCreate('wallpaperDarkness', 50);
    }
    
    // 初始化其他AppStorage值（如果不存在）
    if (AppStorage.get('refreshHomeFlag') === undefined) AppStorage.setOrCreate('refreshHomeFlag', 0);
    if (AppStorage.get('refreshDiscoverFlag') === undefined) AppStorage.setOrCreate('refreshDiscoverFlag', 0);
    if (AppStorage.get('refreshLiveFlag') === undefined) AppStorage.setOrCreate('refreshLiveFlag', 0);
    if (AppStorage.get('scrollToTopFlag') === undefined) AppStorage.setOrCreate('scrollToTopFlag', 0);
    if (AppStorage.get('homeScrollOffset') === undefined) AppStorage.setOrCreate('homeScrollOffset', 0);
    if (AppStorage.get('refreshDynamicsFlag') === undefined) AppStorage.setOrCreate('refreshDynamicsFlag', 0);
    if (AppStorage.get('dynScrollOffset') === undefined) AppStorage.setOrCreate('dynScrollOffset', 0);
    // HdsNavigation 管理标题栏，不再需要 topBarOffset
    if (AppStorage.get('bottomBarHidden') === undefined) AppStorage.setOrCreate('bottomBarHidden', false);
    // ⭐ 消息页 Tab 自动隐藏（默认关闭）
    if (AppStorage.get('msgTabAutoHide') === undefined) AppStorage.setOrCreate('msgTabAutoHide', false);
    // ⭐ 一级 Tab 显隐（默认都显示）
    if (AppStorage.get('showDynamicsTab') === undefined) AppStorage.setOrCreate('showDynamicsTab', true);
    if (AppStorage.get('showWhisperTab') === undefined) AppStorage.setOrCreate('showWhisperTab', true);
    // ⭐ 动态页点击切换分类（默认打开）
    if (AppStorage.get('dynFilterTapOnly') === undefined) AppStorage.setOrCreate('dynFilterTapOnly', true);
    // ⭐ 首页点击切换分类（默认关闭）
    if (AppStorage.get('homeFilterTapOnly') === undefined) AppStorage.setOrCreate('homeFilterTapOnly', false);
    if (AppStorage.get('statusBarHeight') === undefined) AppStorage.setOrCreate('statusBarHeight', 0);
    if (AppStorage.get('isLandscape') === undefined) AppStorage.setOrCreate('isLandscape', false);
    if (AppStorage.get('cardTransparentStyle') === undefined) AppStorage.setOrCreate('cardTransparentStyle', true);
    if (AppStorage.get('cardBorderFollowTheme') === undefined) AppStorage.setOrCreate('cardBorderFollowTheme', true);
    if (AppStorage.get('cardBorderOpacity') === undefined) AppStorage.setOrCreate('cardBorderOpacity', 25);
    if (AppStorage.get('cardBorderFollowPlayCount') === undefined) AppStorage.setOrCreate('cardBorderFollowPlayCount', false);
    if (AppStorage.get('cardBgOpacity') === undefined) AppStorage.setOrCreate('cardBgOpacity', 70);
    if (AppStorage.get('cardBorderWidth') === undefined) AppStorage.setOrCreate('cardBorderWidth', 1);
    if (AppStorage.get('cardCustomColor') === undefined) AppStorage.setOrCreate('cardCustomColor', '');
    if (AppStorage.get('cardCapsuleFollowTheme') === undefined) AppStorage.setOrCreate('cardCapsuleFollowTheme', false);
    if (AppStorage.get('playerFollowTheme') === undefined) AppStorage.setOrCreate('playerFollowTheme', true);
    if (AppStorage.get('cardBgBlurAmount') === undefined) AppStorage.setOrCreate('cardBgBlurAmount', 24);
    if (AppStorage.get('cardBgDarkness') === undefined) AppStorage.setOrCreate('cardBgDarkness', 50);
    if (AppStorage.get('cardTransparentStyleVideo') === undefined) AppStorage.setOrCreate('cardTransparentStyleVideo', true);
    if (AppStorage.get('cardStyleVideoDetail') === undefined) AppStorage.setOrCreate('cardStyleVideoDetail', true);
    if (AppStorage.get('cardStyleVideoCommentSection') === undefined) AppStorage.setOrCreate('cardStyleVideoCommentSection', true);
    if (AppStorage.get('cardStyleVideoCommentBubble') === undefined) AppStorage.setOrCreate('cardStyleVideoCommentBubble', true);
    if (AppStorage.get('cardStyleVideoDescription') === undefined) AppStorage.setOrCreate('cardStyleVideoDescription', true);
    if (AppStorage.get('cardStyleVideoSegmentBtn') === undefined) AppStorage.setOrCreate('cardStyleVideoSegmentBtn', true);
    if (AppStorage.get('cardStyleVideoInteractBtns') === undefined) AppStorage.setOrCreate('cardStyleVideoInteractBtns', true);
    if (AppStorage.get('cardStyleVideoNavBtns') === undefined) AppStorage.setOrCreate('cardStyleVideoNavBtns', true);
    if (AppStorage.get('videoBgMode') === undefined) AppStorage.setOrCreate('videoBgMode', 'cover');
    if (AppStorage.get('videoBgColor') === undefined) AppStorage.setOrCreate('videoBgColor', '#007DFF');
    if (AppStorage.get('videoBgCustomWallpaper') === undefined) AppStorage.setOrCreate('videoBgCustomWallpaper', '');
    if (AppStorage.get('videoBgCustomWallpaperBlur') === undefined) AppStorage.setOrCreate('videoBgCustomWallpaperBlur', 0);
    if (AppStorage.get('videoBgCustomWallpaperDarkness') === undefined) AppStorage.setOrCreate('videoBgCustomWallpaperDarkness', 50);
    if (AppStorage.get('smartGripEnabled') === undefined) AppStorage.setOrCreate('smartGripEnabled', true);
    if (AppStorage.get('cardStyleSearchSuggest') === undefined) AppStorage.setOrCreate('cardStyleSearchSuggest', true);
    if (AppStorage.get('showSearchDiscovery') === undefined) AppStorage.setOrCreate('showSearchDiscovery', true);
    if (AppStorage.get('showHotSearch') === undefined) AppStorage.setOrCreate('showHotSearch', true);
    if (AppStorage.get('showSearchHistory') === undefined) AppStorage.setOrCreate('showSearchHistory', true);
    if (AppStorage.get('searchHistoryRows') === undefined) AppStorage.setOrCreate('searchHistoryRows', 3);
    if (AppStorage.get('cardStyleLiveCategory') === undefined) AppStorage.setOrCreate('cardStyleLiveCategory', true);
    if (AppStorage.get('cardStyleLiveQuality') === undefined) AppStorage.setOrCreate('cardStyleLiveQuality', true);
    if (AppStorage.get('cardBorderRadius') === undefined) AppStorage.setOrCreate('cardBorderRadius', 30);
    if (AppStorage.get('cardMargin') === undefined) AppStorage.setOrCreate('cardMargin', 12);
    if (AppStorage.get('cardListBorderRadius') === undefined) AppStorage.setOrCreate('cardListBorderRadius', 12);
    if (AppStorage.get('cardListMargin') === undefined) AppStorage.setOrCreate('cardListMargin', 12);
    // ⭐ 轮播背景圆角默认值（0-40vp，默认 30）
    if (AppStorage.get('carouselBgRadius') === undefined) AppStorage.setOrCreate('carouselBgRadius', 30);
    // 全屏动画 / 页面动画设置默认值
    if (AppStorage.get('pageEnterAnim') === undefined) AppStorage.setOrCreate('pageEnterAnim', 'scaleFade');
    if (AppStorage.get('fsAnimOn') === undefined) AppStorage.setOrCreate('fsAnimOn', true);

    // ★ 初始化状态栏/导航栏透明 + 隐藏状态
    try {
      StatusBarUtils.updateStatusBarColor(this.getUIContext().getHostContext() as common.UIAbilityContext, this.isDarkMode);
      // 应用用户的状态栏隐藏设置
      const hideSb: boolean = AppStorage.get<boolean>('hideStatusBar') ?? false;
      StatusBarUtils.setStatusBarHidden(this.getUIContext().getHostContext() as common.UIAbilityContext, hideSb);
    } catch (_) {}

    // ★ 探测设备沉浸光感支持 — 避免 sys.float.hms_material_style 缺失时材质反复 fallback 闪烁
    this.checkImmersiveSupport();

    // ★ 横竖屏检测 — 监听窗口尺寸变化，横屏时全局隐藏状态栏
    window.getLastWindow(this.getUIContext().getHostContext() as common.Context).then((win) => {
      const rect = win.getWindowProperties().windowRect;
      this.isLandscape = rect.width > rect.height;
      AppStorage.setOrCreate('isLandscape', this.isLandscape);
      // 初始横屏状态同步
      this.applyLandscapeStatusBar(this.isLandscape);
      win.on('windowSizeChange', (size: window.Size) => {
        const isNowLandscape = size.width > size.height;
        this.isLandscape = isNowLandscape;
        AppStorage.setOrCreate('isLandscape', isNowLandscape);
        this.applyLandscapeStatusBar(isNowLandscape);
        // ⭐ 旋转时若正停在消息页：重算底栏显隐（横屏恒隐藏 / 竖屏按「消息页 Tab 自动隐藏」开关）
        if (this.activeTab === PAGE_MSG) {
          AppStorage.set('bottomBarHidden', this.shouldHideBottomBarForTab(PAGE_MSG));
        }
      });
    });

    // ★ 智感握姿 — motion 事件驱动检测左右手持握（系统级传感器融合，仅状态变化时触发）
    if (this.smartGripEnabled) {
      try {
        motion.on('holdingHandChanged', (data: motion.HoldingHandStatus) => {
          if (data === motion.HoldingHandStatus.LEFT_HAND_HELD || data === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
            this.leftHanded = (data === motion.HoldingHandStatus.LEFT_HAND_HELD);
          }
        });
      } catch (err) {
        let error = err as BusinessError;
        logError(`[SmartGrip] motion订阅失败. Code: ${error.code}, message: ${error.message}`);
      }
    }
    // 壁纸数据加载完成，允许渲染真实壁纸
    this.wallpaperReady = true;
  }

  aboutToDisappear(): void {
    if (this.smartGripEnabled) {
      try {
        motion.off('holdingHandChanged');
      } catch (err) {
        let error = err as BusinessError;
        logError(`[SmartGrip] 取消motion订阅失败. Code: ${error.code}, message: ${error.message}`);
      }
    }
  }

  // ⭐ 返回键确认退出
  onBackPress(): boolean {
    // ⚠️ 仅「消息页 + 底栏处于隐藏状态」才支持右滑返回/返回键回退到上一个 Tab
    //    （底栏不可见时才需要返回通道）；其余情况有可见底栏，侧滑/返回键直接弹退出确认
    if (this.activeTab === PAGE_MSG && this.shouldHideBottomBarForTab(PAGE_MSG) && this.tabHistory.length > 0) {
      const prev: number = this.tabHistory.pop() as number;
      this.activeTab = prev;
      // ⚠️ 同步底栏按钮高亮：强制跳转不触发 onAnimationStart，需手动更新 iconActiveTab
      this.iconActiveTab = prev;
      AppStorage.set('bottomBarHidden', this.shouldHideBottomBarForTab(prev));
      return true;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.getUIContext().getPromptAction().showDialog({
      title: '确认退出',
      message: '确定要退出软件吗？',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '退出', color: this.customThemeColor }
      ]
    }).then((result) => {
      if (result.index === 1) {
        context.terminateSelf();
      }
    }).catch(() => {});
    return true; // 拦截默认返回行为
  }

  private getSolidBackground(): string {
    if (this.wallpaper === 'custom_color') return this.wallpaperColor;
    return this.isDarkMode ? '#121212' : '#FFFFFF';
  }

  // ★ 探测设备沉浸光感支持 — 避免 sys.float.hms_material_style 缺失时材质反复 fallback 闪烁
  // 优先 IMMERSIVE，不支持则降级 ADAPTIVE（跟随系统默认材质）
  private checkImmersiveSupport(): void {
    try {
      const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      if (types && types.includes(hdsMaterial.MaterialType.IMMERSIVE)) {
        this.customMaterialType = hdsMaterial.MaterialType.IMMERSIVE;
      } else {
        this.customMaterialType = hdsMaterial.MaterialType.ADAPTIVE;
      }
      this.customMaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
      logInfo(`[Index] 沉浸光感材质类型: ${this.customMaterialType}`);
    } catch (e) {
      // 探测失败 — 维持默认 ADAPTIVE，不再触发系统资源解析
      this.customMaterialType = hdsMaterial.MaterialType.ADAPTIVE;
      this.customMaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
      logError(`[Index] 沉浸光感探测失败, 降级 ADAPTIVE: ${e}`);
    }
  }

  // ★ 沉浸光感颜色 — 将主题色转为低透明度光效色
  private getImmersiveLightColor(): string {
    // 提取主题色的 RGB 部分，附加 33（约 20% 透明度）作为光效
    const hex = this.customThemeColor.replace('#', '');
    return `#33${hex}`;
  }

  // ★ 处理底栏点击（支持重复点击当前 Tab 滚动到顶）
  private handleTabClick(index: number): void {
    logInfo(`handleTabClick: index=${index}, activeTab=${this.activeTab}, homeScrollOffset=${this.homeScrollOffset}`);
    logInfo(`AppStorage.get('homeScrollOffset'): ${AppStorage.get('homeScrollOffset')}`);

    // ⭐ 底栏图标收到的是逻辑页 ID（TabIcon 直接传 pageId）
    const pageId: number = index;
    if (this.activeTab === pageId) {
      // 如果已经在顶部，则刷新当前页面；否则滚动到顶部
      // 动态页使用自己的滚动偏移，首页使用 homeScrollOffset，消息页使用 msgScrollOffset
      const currentOffset = pageId === PAGE_DYN
        ? Math.abs(AppStorage.get<number>('dynScrollOffset') ?? 0)
        : pageId === PAGE_MSG
          ? Math.abs(AppStorage.get<number>('msgScrollOffset') ?? 0)
          : Math.abs(this.homeScrollOffset);
      logInfo(`Current scroll offset: ${currentOffset}, threshold check: ${currentOffset < 5}`);

      if (currentOffset < 5) {
        logInfo('Already at top, triggering refresh');
        // 在顶部，触发刷新（逻辑页：0=首页容器, 1=动态, 2=消息, 3=我的；刷新由容器按当前频道路由）
        if (pageId === PAGE_HOME) {
          let refreshFlag = AppStorage.get<number>('refreshHomeFlag') ?? 0;
          AppStorage.set('refreshHomeFlag', refreshFlag + 1);
        } else if (pageId === PAGE_DYN) {
          // 动态页刷新信号
          let refreshFlag = AppStorage.get<number>('refreshDynamicsFlag') ?? 0;
          AppStorage.set('refreshDynamicsFlag', refreshFlag + 1);
        } else if (pageId === PAGE_MSG) {
          // 消息页刷新信号
          let refreshFlag = AppStorage.get<number>('refreshMsgFlag') ?? 0;
          AppStorage.set('refreshMsgFlag', refreshFlag + 1);
        }
        // 我的页暂不支持刷新
      } else {
        // 不在顶部，滚动到顶部
        logInfo('Not at top, triggering scroll to top');
        let flag = AppStorage.get<number>('scrollToTopFlag') ?? 0;
        logInfo('scrollToTopFlag before:', flag);
        AppStorage.set('scrollToTopFlag', Date.now());
        logInfo('scrollToTopFlag after:', Date.now());
        // 添加延迟以确保触发，特别是对于发现页
        setTimeout(() => {
          AppStorage.set('scrollToTopFlag', Date.now() + 1);
          logInfo('scrollToTopFlag delayed update:', Date.now() + 1);
        }, 50);
      }
    }
    // ⚠️ 不在此提前设置 activeTab：HdsTabs 的 index 参数绑定 activeTab，
    // 提前赋值会让 HdsTabs 强制跳转（无动画），onAnimationStart 不触发，胶囊标题不更新。
    // 页面切换由 HdsTabs 内部完成，activeTab 统一在 onChange 中同步。
    // 短震动反馈
    VibrateUtils.vibrateTime(15);
  }

  // 统一触觉反馈（短震动）
  private triggerHaptic(): void {
    VibrateUtils.vibrateTime(15);
  }

  /** 横屏时全局隐藏状态栏，竖屏时按用户设置恢复 */
  private applyLandscapeStatusBar(isLandscape: boolean): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(context).then((win) => {
        if (isLandscape) {
          // 使用 setWindowSystemBarEnable([]) 彻底隐藏状态栏+导航栏（setSpecificSystemBarEnabled 在部分设备无效）
          win.setWindowSystemBarEnable([]);
          // 同步更新 statusBarHeight，让各页面布局不再预留状态栏空间
          AppStorage.set('statusBarHeight', 0);
        } else {
          const hideSb = AppStorage.get<boolean>('hideStatusBar') ?? false;
          if (hideSb) {
            win.setWindowSystemBarEnable(['navigation']);
          } else {
            win.setWindowSystemBarEnable(['status', 'navigation']);
          }
          // 竖屏时恢复状态栏真实高度
          const avoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          const realHeight = this.getUIContext().px2vp(avoidArea.topRect.height);
          AppStorage.set('statusBarHeight', realHeight > 0 ? realHeight : 40);
        }
      });
    } catch (_) {}
  }

  // 收起直播页展开面板（通过 AppStorage 信号通知 LivePage）
  private collapseLivePanel(): void {
    const signal: number = (AppStorage.get('livePanelCollapseSignal') as number) || 0;
    AppStorage.set('livePanelCollapseSignal', signal + 1);
  }

  // ⭐ 页面切换动画辅助 — 按 index 设置缩放/透明度
  private setPageScale(index: number, value: number): void {
    if (index === 0) this.pageScale0 = value;
    else if (index === 1) this.pageScale1 = value;
    else if (index === 2) this.pageScale2 = value;
    else if (index === 3) this.pageScale3 = value;
  }

  private setPageOpacity(index: number, value: number): void {
    if (index === 0) this.pageOpacity0 = value;
    else if (index === 1) this.pageOpacity1 = value;
    else if (index === 2) this.pageOpacity2 = value;
    else if (index === 3) this.pageOpacity3 = value;
  }

  private setPageRadius(index: number, value: number): void {
    if (index === 0) this.pageRadius0 = value;
    else if (index === 1) this.pageRadius1 = value;
    else if (index === 2) this.pageRadius2 = value;
    else if (index === 3) this.pageRadius3 = value;
  }

  // 胶囊标题切换动画：两段（淡出 → 弹入），用 token + setTimeout 衔接
  // 不依赖 animateTo 的 onFinish 嵌套：HdsTabs 切换动画竞争下 onFinish 可能不触发，
  // 导致 capsuleAnimating 卡死、后续切换不再播放动画（日志只有一次 animateTo 即为该现象）
  private playCapsuleAnimation(labelIdx: number): void {
    const token: number = ++this.capsuleAnimToken;
    // 第一段：缩小淡出（旧文字隐藏）
    this.getUIContext().animateTo({
      duration: 350,
      curve: Curve.FastOutSlowIn
    }, () => {
      this.capsuleOpacity = 0;
      this.capsuleScale = 0.5;
    });
    // 第二段：切换文字后弹性弹入（setTimeout 衔接；token 不匹配则已被更新切换取代）
    setTimeout(() => {
      if (token !== this.capsuleAnimToken) return;
      this.capsuleLabelIdx = labelIdx;
      this.capsuleOpacity = 0;
      this.capsuleScale = 0.5;
      this.getUIContext().animateTo({
        duration: 500,
        curve: curves.springMotion(0.5, 0.85)
      }, () => {
        this.capsuleOpacity = 1;
        this.capsuleScale = 1;
      });
    }, 350);
  }


  /**
   * ⭐ 番剧/影视索引按钮显隐：显示时从胶囊分裂弹出、隐藏时融入胶囊
   * 由频道切换/胶囊展开收起驱动（animateTo 状态动画）；
   * 上下滑动标题栏显隐由 HdsNavigation 整体处理，不触发本方法
   */
  private updateIndexBtnVisibility(): void {
    // ⭐ 番剧(4)与影视(5)频道都显示索引按钮
    const show: boolean = !this.capsuleExpanded
      && (this.capsuleLabelIdx === 4 || this.capsuleLabelIdx === 5);
    this.getUIContext().animateTo({
      duration: show ? 420 : 220,
      curve: show ? curves.springMotion(0.4, 0.5) : Curve.FastOutSlowIn
    }, () => {
      this.indexBtnOpacity = show ? 1 : 0;
      this.indexBtnScale = show ? 1 : 0.2;
      this.indexBtnOffsetX = show ? -8 : -20;
    });
  }

  // 展开/收起标题胶囊（带动画）
  // 展开：宽度弹性拉长 + 内容整体淡入 + 分段逐个弹入；收起：内容淡出后再宽度弹性缩回
  private setCapsuleExpanded(expanded: boolean): void {
    if (this.capsuleExpanded === expanded) return;
    this.triggerHaptic();
    if (expanded) {
      // 作废旧的分段推进回调，重置步进
      const token: number = ++this.capsuleStaggerToken;
      this.capsuleSegStep = 0;
      // 宽度弹性展开 + 内容整体淡入
      this.getUIContext().animateTo({
        duration: 450,
        curve: curves.springMotion(0.4, 0.8)
      }, () => {
        this.capsuleExpanded = true;
        this.capsuleContentOpacity = 1;
        // ⭐ 胶囊展开时索引按钮融入胶囊隐藏
        this.updateIndexBtnVisibility();
      });
      // 分段逐个出现：每步延时后推进一段
      this.scheduleCapsuleStagger(token, 1);
    } else {
      // 作废残留的分段推进回调
      this.capsuleStaggerToken++;
      // 第一步：展开内容先淡出（保持展开态，让 capsuleContentOpacity 动画真正生效，
      // 否则 capsuleExpanded=false 会即时销毁展开态分支、吞掉淡出动画）
      this.getUIContext().animateTo({
        duration: 140,
        curve: Curve.FastOutSlowIn
      }, () => {
        this.capsuleContentOpacity = 0;
        this.capsuleSegStep = 0;
      });
      // 第二步：内容淡出完成后，再收起宽度（胶囊缩回 + 按钮组滑回）
      setTimeout(() => {
        this.getUIContext().animateTo({
          duration: 280,
          curve: curves.springMotion(0.5, 0.85)
        }, () => {
          this.capsuleExpanded = false;
          // ⭐ 胶囊收起后索引按钮按频道恢复显隐（番剧频道时从胶囊分裂弹出）
          this.updateIndexBtnVisibility();
        });
      }, 140);
    }
  }

  // 分段逐个出现推进：token 不匹配（已收起/重新展开）则中止
  // ⭐ 6 个频道分段步进加快：90ms→50ms，总步进时长从约 540ms 降至约 300ms，接近改前 3 段手感
  private scheduleCapsuleStagger(token: number, step: number): void {
    if (token !== this.capsuleStaggerToken) return;
    setTimeout(() => {
      if (token !== this.capsuleStaggerToken) return;
      this.getUIContext().animateTo({
        duration: 220,
        curve: curves.springMotion(0.5, 0.85)
      }, () => {
        this.capsuleSegStep = step;
      });
      if (step < CHANNEL_TABS.length) {
        this.scheduleCapsuleStagger(token, step + 1);
      }
    }, 50);
  }

  // 点击展开胶囊中的分段：收起胶囊，收起动画完成后再切换频道
  // 收起动画约 420ms（内容淡出 140ms + 宽度回缩 280ms），延迟切页可避免
  // 频道切换动画与收起动画并发打架
  private selectCapsuleSegment(index: number): void {
    this.setCapsuleExpanded(false);
    if (this.homeChannelIndex !== index) {
      setTimeout(() => {
        AppStorage.set('homeChannelIndex', index);
      }, 430);
    }
  }

  /** 频道图标（0=分类 1=直播 2=首页 3=热门 4=番剧 5=影视） */
  private getChannelIcon(index: number): Resource {
    switch (index) {
      case 0: return $r('app.media.animestudio');
      case 1: return $r('app.media.earth_1_solid');
      case 2: return $r('app.media.loading_circle_solid');
      case 3: return $r('app.media.chart_fill');
      case 4: return $r('app.media.tv_old');
      default: return $r('app.media.film_slate_solid');
    }
  }

  /** ⭐ 频道图标配色：0=分类黄 1=直播紫 2=首页红粉 3=热门金 4=番剧蓝 5=影视绿；
   *  开关「标题胶囊彩色图标」关闭时全部返回深浅色模式黑白 */
  private getChannelIconColor(index: number): ResourceColor {
    const colorIcons: boolean = AppStorage.get<boolean>('capsuleColorIcons') ?? true;
    if (!colorIcons) {
      return this.isDarkMode ? '#FFFFFF' : '#000000';
    }
    switch (index) {
      case 0: return '#FFD700';
      case 1: return '#A855F7';
      case 2: return '#EC6FA4';
      case 3: return '#FFC107';
      case 4: return '#2196F3';
      default: return '#7EDC15';
    }
  }

  /** 频道名称（越界兜底为首页） */
  private getChannelName(index: number): string {
    if (index >= 0 && index < CHANNEL_TABS.length) return CHANNEL_TABS[index].name;
    return '首页';
  }

  /**
   * ⭐ 展开态胶囊宽度
   * - 横屏：自适应内容长度（6 段 + 间距 + 内边距 + bar 内边距余量），确保分类完整显示
   * - 竖屏：占满屏幕并左右留对称边距（与屏幕边缘间距一致）
   */
  private getExpandedCapsuleWidth(): number {
    try {
      // 内容自适应宽度：6 段 × 62vp + 段间距 6vp×5 + 左右内边距 8vp
      const contentWidth = CHANNEL_TABS.length * 62 + (CHANNEL_TABS.length - 1) * 6 + 8;
      if (this.isLandscape) {
        // HdsTabs bar 内容区比 barWidth 略小（内部水平内边距），加余量避免末位分类被裁
        return contentWidth + 24;
      }
      const defaultDisplay = display.getDefaultDisplaySync();
      const screenWidthVp = this.getUIContext().px2vp(defaultDisplay.width);
      // 左右各留 16vp 边距，与屏幕边缘间距对称
      return Math.max(280, screenWidthVp - 32);
    } catch (e) {
      return 340;
    }
  }

  // 展开胶囊中的单个分段项：图标 + 名称
  // ⭐ 选中样式：透明背景 + 主题色下划线指示（方案：主题色下划线/圆点指示）
  // ⭐ 固定宽度（展开态放在横向 Scroll 中，layoutWeight 在滚动容器内不生效）
  @Builder
  capsuleSegmentItem(index: number, label: string, icon: Resource) {
    Column() {
      Row() {
        Image(icon)
          .width(16).height(16)
          .margin({ right: 4 })
          // ⭐ 每个频道图标按各自配色染色（分类黄/直播紫/首页粉/热门金/番剧蓝/影视绿）
          .fillColor(this.getChannelIconColor(index))
        Text(label)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.capsuleLabelIdx === index ? this.customThemeColor : (this.isDarkMode ? '#FFFFFF' : '#000000'))
      }
      .width(62)
      .height(22)
      .justifyContent(FlexAlign.Center)
      .opacity(this.capsuleSegStep > index ? 1 : 0)
      .scale({ x: this.capsuleSegStep > index ? 1 : 0.5, y: this.capsuleSegStep > index ? 1 : 0.5 })
      // ⭐ 透明背景（移除毛玻璃），仅保留图标/文字本身
      // ⭐ 选中指示：底部主题色下划线（3vp 粗圆角横条，紧贴文字下方居中）
      if (this.capsuleLabelIdx === index) {
        Row()
          .width(28)
          .height(3)
          .borderRadius(1.5)
          .backgroundColor(this.customThemeColor)
          .margin({ top: 0 })
          .opacity(this.capsuleSegStep > index ? 1 : 0)
      }
    }
    .width(62)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      // 注意：ArkTS ClickEvent 无 stopPropagation；父级 Row 的 onClick 会随后触发 setCapsuleExpanded(false)，幂等无副作用
      this.selectCapsuleSegment(index);
    })
  }


  // ★ 标题栏 Builder — 由 titleBar.stackBuilder 嵌入 HdsNavigation 标题栏内部
  // 显隐由 HdsNavigation.hideTitleBar 统一驱动，与菜单按钮动画一致
  // 胶囊 + 历史/搜索按钮统一使用 HdsMiniBarButton（IMMERSIVE + EXQUISITE 同款材质）
  // 点击胶囊：展开为 推荐/热门/直播/番剧/影视/分类 频道分段选择器，历史/搜索按钮被推出屏幕外
  @Builder
  capsuleTitleBuilder() {
    if (this.titleBarReady) {
      Row() {
      // ── 标题胶囊（点击展开/收起）──
      HdsMiniBarButton({
        barWidth: this.capsuleExpanded ? this.getExpandedCapsuleWidth() : 120,
        barHeight: 40,
        contentPadding: 4,
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
        barOverlap: true,
        barPosition: BarPosition.End
      }) {
        if (this.capsuleExpanded) {
          // 展开态：频道分段选择器（单行，拥挤时横向滑动）
          Scroll() {
            Row({ space: 6 }) {
              ForEach(CHANNEL_TABS, (tab: ChannelTabDef) => {
                this.capsuleSegmentItem(tab.index, tab.name, this.getChannelIcon(tab.index))
              }, (tab: ChannelTabDef) => tab.index.toString())
            }
            .padding({ left: 4, right: 4 })
            .flexShrink(0)
          }
          .width('100%')
          .height('100%')
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
          .opacity(this.capsuleContentOpacity)
          .onClick(() => this.setCapsuleExpanded(false))
        } else {
          // 收起态：当前频道单标签
          Row() {
            // ⭐ 每个频道图标按各自配色染色（分类黄/直播紫/推荐粉/热门金/番剧蓝/影视绿）
            Image(this.getChannelIcon(this.capsuleLabelIdx))
              .width(20).height(20).margin({ right: 6 })
              .fillColor(this.getChannelIconColor(this.capsuleLabelIdx))
            Text(this.getChannelName(this.capsuleLabelIdx))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
          }
          .alignItems(VerticalAlign.Center)
          .opacity(this.capsuleOpacity)
          .scale({ x: this.capsuleScale, y: this.capsuleScale })
          .onClick(() => this.setCapsuleExpanded(true))
        }
      }
      // ⭐ 番剧索引按钮（始终渲染，显隐由 updateIndexBtnVisibility 状态动画驱动）
      // 上下滑动标题栏整体显隐由 HdsNavigation 统一处理（不重播 transition）；
      // 频道切换/胶囊展开时由 animateTo 播放分裂/融入动画
      // 注意：不能用负 margin（会导致 HdsMiniBarButton 容器 size 失效，高度从 56vp 塌缩到 40vp）
      Row() {
        HdsMiniBarButton({
          barWidth: 40,
          barHeight: 40,
          contentPadding: 4,
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
          barOverlap: true,
          barPosition: BarPosition.End,
          onButtonClick: (): void => {
            this.triggerHaptic();
            this.collapseLivePanel();
            // ⭐ 通知番剧页展开/收起索引筛选面板（不再跳转新页面）
            const signal: number = (AppStorage.get('pgcIndexPanelSignal') as number) || 0;
            AppStorage.set('pgcIndexPanelSignal', signal + 1);
          }
        }) {
          Image($r('app.media.filter_solid'))
            .width(24).height(24)
            .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        }
      }
      // 显示时左移 8vp 与胶囊保持视觉间距；隐藏时再左移 12vp 融向胶囊 + 缩小淡出
      .offset({ x: this.indexBtnOffsetX })
      .scale({ x: this.indexBtnScale, y: this.indexBtnScale, centerX: '0%', centerY: '50%' })
      .opacity(this.indexBtnOpacity)
      Blank()
      // ── 历史/搜索按钮组（胶囊展开时被推出屏幕外）──
      Row() {
        // 历史按钮（同款材质）
        HdsMiniBarButton({
          barWidth: 40,
          barHeight: 40,
          contentPadding: 4,
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
          barOverlap: true,
          barPosition: BarPosition.End,
          onButtonClick: (): void => {
            this.triggerHaptic();
            this.collapseLivePanel();
            this.getUIContext().getRouter().pushUrl({ url: 'pages/WatchHistoryPage' });
          }
        }) {
          Image($r('app.media.ic_settings_history'))
            .width(24).height(24)
            .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        }
        // 搜索按钮（同款材质）
        // ⭐ 包一层 Row + offset 视觉左移 8vp，使与历史按钮视觉间距为 8vp
        // （容器相邻时两侧 contentPadding 留白共 16vp，-8 后剩 8vp）
        Row() {
          HdsMiniBarButton({
            barWidth: 40,
            barHeight: 40,
            contentPadding: 4,
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
            barOverlap: true,
            barPosition: BarPosition.End,
            onButtonClick: (): void => {
              this.triggerHaptic();
              this.collapseLivePanel();
              this.getUIContext().getRouter().pushUrl({ url: 'pages/SearchPage' });
            }
          }) {
            Image($r('app.media.ic_public_search_filled'))
              .width(24).height(24)
              .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          }
        }
        .offset({ x: -8 })
      }
      .translate({ x: this.capsuleExpanded ? 200 : 0 })
      .opacity(this.capsuleExpanded ? 0 : 1)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 8, top: 7, right: 8 })
    } else {
      // ⭐ 就绪前空占位：不创建 HdsMiniBarButton 材质组件，避免首帧在错误位置成像产生残影
      Row().width('100%').height('100%')
    }
  }


  @Builder
  TabIcon(normalIcon: Resource, selectedIcon: Resource, index: number) {
    TabIconComponent({
      iconActiveTab: this.iconActiveTab,
      index: index,
      normalIcon: normalIcon,
      selectedIcon: selectedIcon,
      themeColor: this.customThemeColor,
      animatingTab: this.animatingTab,
      onTabClick: (idx: number) => this.handleTabClick(idx)
    })
  }

  build() {
    HdsNavigation() {
      Stack() {
          // 全局背景（wallpaper 层）
        if (!this.wallpaperReady) {
          // 数据未加载完——纯色背景，避免闪默认壁纸
          Column()
            .width('100%').height('100%')
            .backgroundColor(this.isDarkMode ? '#121212' : '#FFFFFF')
        } else if (this.wallpaper === 'builtin') {
          Stack() {
            Image(this.isDarkMode ? $r('app.media.wallpaper_shen') : $r('app.media.wallpaper_qian'))
              .width('100%').height('100%').objectFit(ImageFit.Cover)
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
              .width('100%').height('100%').objectFit(ImageFit.Cover).blur(this.wallpaperBlur)
              .onError(() => { this.imageLoadFailed = true; AppStorage.set('wallpaper', 'default'); })
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

        // 主内容：HdsTabs + 沉浸光感悬浮底栏
        Column() {
          // ⭐ index 参数必须传物理位置（映射自逻辑 activeTab）；TabContent 按逻辑页条件渲染
          HdsTabs({ controller: this.controller, index: this.tabIndexFor(this.activeTab) }) {
            TabContent() {
              Stack() {
                HomeChannelContainer({
                  externalScroller: this.homeScroller,
                  discoverScroller: this.discoverScroller
                })
              }
              .scale({ x: this.pageScale0, y: this.pageScale0 })
              .opacity(this.pageOpacity0)
              .borderRadius(this.pageRadius0)
              .clip(true)
              .width('100%').height('100%')
            }
            .tabBar(this.TabIcon($r('app.media.house'), $r('app.media.house_fill'), PAGE_HOME))
            if (this.showDynamicsTab) {
              TabContent() {
                Stack() { DynamicsPage() }
                  .scale({ x: this.pageScale1, y: this.pageScale1 })
                  .opacity(this.pageOpacity1)
                  .borderRadius(this.pageRadius1)
                  .clip(true)
                  .width('100%').height('100%')
              }
              .tabBar(this.TabIcon($r('app.media.discover_fill_discover'), $r('app.media.discover_fill'), PAGE_DYN))
            }
            if (this.showWhisperTab) {
              TabContent() {
                Stack() { WhisperPage() }
                  .scale({ x: this.pageScale2, y: this.pageScale2 })
                  .opacity(this.pageOpacity2)
                  .borderRadius(this.pageRadius2)
                  .clip(true)
                  .width('100%').height('100%')
              }
              .tabBar(this.TabIcon($r('app.media.message_on_message'), $r('app.media.message'), PAGE_MSG))
            }
            TabContent() {
              Stack() { ProfilePage() }
                .scale({ x: this.pageScale3, y: this.pageScale3 })
                .opacity(this.pageOpacity3)
                .borderRadius(this.pageRadius3)
                .clip(true)
                .width('100%').height('100%')
            }
            .tabBar(this.TabIcon($r('app.media.heart'), $r('app.media.heart_fill'), PAGE_PROFILE))
          }
          .barOverlap(true)
          .barPosition(BarPosition.End)
          .vertical(false)
          .barFloatingStyle({
            barWidth: { smallWidth: 264, mediumWidth: 264, largeWidth: 264 },
            barSideMargin: 20,
            barBottomMargin: 27 + this.navIndicatorHeight,
            // ⚠️ 全局不画这层底栏遮罩：它绘制在内容层之下，凡是"内容没铺满屏幕底部"的页面
            //    （消息页/我的页…）都会显出一条灰带（真机像素取证见 memory/2026-09-23.md）。
            // ⚠️⚠️ 回退：把 maskColor 改回 `this.isDarkMode ? '#662C2C2C' : '#66F1F3F5'` 即恢复原行为。
            gradientMask: { maskColor: Color.Transparent, maskHeight: 92 },
            systemMaterialEffect: { materialType: this.customMaterialType, materialLevel: this.customMaterialLevel },
            // ★ 自定义沉浸光感颜色 — 跟随主题色动态变化
            lightColor: this.getImmersiveLightColor(),
            // ★ 握持手自适应
            adaptToHandedness: true
          })
          // ⭐ 加快 Tab 切换动画速度
          .animationDuration(150)
          // ★ 动画开始时执行视觉联动；activeTab 移到 onChange 同步，
          // 避免 index={this.activeTab} 参数在动画期间变化导致 HdsTabs 强制中断切换动画
          .onAnimationStart((_index: number, targetIndex: number) => {
            const fromIndex: number = _index; // 使用回调参数而非 this.activeTab（点击切换时 handleTabClick 已提前修改 activeTab）
            // ⭐ 回调参数是物理位置，统一换算为逻辑页 ID
            const fromPage: number = this.pageIndexOf(fromIndex);
            const targetPage: number = this.pageIndexOf(targetIndex);
            // ⭐ 取消切换（滑动回原页）→ 跳过动画，避免闪烁
            if (fromIndex === targetIndex) {
              return;
            }
            // ⭐ 图标高亮即时跟随目标页（activeTab 延迟到 onChange 同步，避免 index 参数变化中断动画）
            this.iconActiveTab = targetPage;
            // 切换时渐隐/渐显首页渐变网点（首页容器是逻辑页 0）
            if (fromPage === PAGE_HOME) {
              // 离开首页容器 → 渐隐
              const leavingFlag = AppStorage.get<number>('homeTabLeaving') ?? 0;
              AppStorage.set('homeTabLeaving', leavingFlag + 1);
            }
            // 切到非首页容器时收起直播展开面板（直播现在是首页内频道）
            if (targetPage !== PAGE_HOME) {
              const signal: number = (AppStorage.get('livePanelCollapseSignal') as number) || 0;
              AppStorage.set('livePanelCollapseSignal', signal + 1);
            }
            // ⭐ 滑动期间保持圆角，结束后恢复（两个页面都恢复，避免离开页残留 30 圆角）
            // ⚠️ setPageRadius 的 0-3 是逻辑页 ID（pageRadius0-3 按逻辑页绑定 TabContent），
            //    不能传物理位置——动态页隐藏时物理 1 是消息页，传物理会设错对象
            this.setPageRadius(fromPage, 30);
            this.setPageRadius(targetPage, 30);
            // ⭐ 底部栏图标：先缩小，短延时后弹回
            this.animatingTab = targetPage;
            setTimeout(() => { this.animatingTab = -1; }, 100);
            // ⭐ 胶囊标题动画：缩小淡出 → 弹性缩放弹入（胶囊显示当前频道，我的页映射回频道）
            const labelIdx: number = this.capsuleLabelIdx;
            // token 机制自会作废旧切换，无需排队；每次切换都直接播动画
            this.playCapsuleAnimation(labelIdx);
          })
          .onChange((index: number) => {
            // ⭐ 回调参数是物理位置，换算为逻辑页 ID（activeTab 统一存逻辑 ID）
            const pageId: number = this.pageIndexOf(index);
            // ⚠️ 仅「进入消息页 且底栏会被隐藏」时记录来源 Tab
            //    （底栏隐藏后没有切 Tab 入口，需要返回通道；底栏可见时不需要，也避免残留历史）
            if (this.activeTab !== pageId && this.shouldHideBottomBarForTab(pageId)) {
              this.tabHistory.push(this.activeTab);
            }
            // ★ 动画结束后同步 activeTab（驱动图标高亮等），此时 HdsTabs 已稳定，index 参数变化不会中断动画
            this.activeTab = pageId;
            // ★ 动画结束后重置滚动偏移和UI显隐状态
            AppStorage.set('homeScrollOffset', 0);
            // ⚠️ 消息页按开关（横屏恒隐藏）决定是否收起底部 Tab 栏，其余页面显示
            AppStorage.set('bottomBarHidden', this.shouldHideBottomBarForTab(pageId));
            // ⭐ 滑动结束，两个页面圆角都恢复（onAnimationStart 同时给 from/target 设了 30）
            this.setPageRadius(0, 0);
            this.setPageRadius(1, 0);
            this.setPageRadius(2, 0);
            this.setPageRadius(3, 0);
            // ⭐ 动画完成后通知首页渐显渐变网点（首页容器是逻辑页 0）
            if (pageId === PAGE_HOME) {
              const counter = AppStorage.get<number>('pageShowCounter') ?? 0;
              AppStorage.set('pageShowCounter', counter + 1);
            }
          })
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')

        // ⭐ 最小化视频悬浮按钮
        FloatingVideoButton()
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      style: {
        // ★ 找回 scrollEffectOpts：用 WatchHistoryPage 已验证可编译的 GRADIENT_BLUR 配置
        // 滚动触发的渐变模糊带；originalStyle 已透明，不再有初始白色遮罩闪烁
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        systemMaterialEffect: {
          materialType: this.customMaterialType,
          materialLevel: this.customMaterialLevel
        },
        // ★ originalStyle 背景改透明：让标题栏初始即为沉浸材质，去掉初始白色遮罩
        originalStyle: {
          backgroundStyle: {
            backgroundColor: 'transparent'
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: this.isDarkMode ? '#FFFFFF' : '#000000',
            },
            menuStyle: {
              backgroundColor: 'rgba(255,255,255,0.30)',
              iconColor: this.isDarkMode ? '#FFFFFF' : '#000000'
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: 'transparent'
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: this.isDarkMode ? '#FFFFFF' : '#000000',
            },
            menuStyle: {
              backgroundColor: 'rgba(255,255,255,0.30)',
              iconColor: this.isDarkMode ? '#FFFFFF' : '#000000'
            }
          }
        },
      },
      padding: { start: LengthMetrics.vp(16), end: LengthMetrics.vp(16) },
      content: {
        title: { mainTitle: '' },
        stackBuilder: (): void => {
          this.capsuleTitleBuilder();
        }
      },
      enableComponentSafeArea: false,
      avoidLayoutSafeArea: true
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    // ★ 标题栏显隐：上滑时隐藏 或 在"消息"/"动态"/"我的"页面时隐藏，统一动画
    .hideTitleBar(this.bottomBarHidden
      || this.activeTab === PAGE_DYN
      || this.activeTab === PAGE_MSG
      || this.activeTab === PAGE_PROFILE, true)
    // ★ 绑定各页面的 Scroller，让 HdsNavigation 感知滚动
    .bindToScrollable([this.homeScroller, this.discoverScroller])
    .ignoreLayoutSafeArea()
    .width('100%')
    .height('100%')
  }
}

// ★ 底栏图标组件 — 独立 @Component 以支持每个图标独立的按压缩放状态
@Component
struct TabIconComponent {
  @Prop iconActiveTab: number = 0;
  @Prop index: number = 0;
  @Prop normalIcon: Resource = $r('app.media.house');
  @Prop selectedIcon: Resource = $r('app.media.house_fill');
  @Prop themeColor: string = '#007DFF';
  @Prop animatingTab: number = -1; // ⭐ 切换时缩小触发标记
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('homeScrollOffset') homeScrollOffset: number = 0;
  @StorageProp('dynScrollOffset') dynScrollOffset: number = 0;
  @StorageProp('msgScrollOffset') msgScrollOffset: number = 0;
  @State isPressing: boolean = false;
  onTabClick?: (index: number) => void;
  private readonly SCROLL_THRESHOLD: number = 200;

  /** 当前 Tab 是否超过阈值（滚动后显示回顶图标）：首页用 homeScrollOffset，动态用 dynScrollOffset，消息用 msgScrollOffset
   *  ⭐ index 语义 = 逻辑页 ID（0=首页, 1=动态, 2=消息, 3=我的），与 TabContent 渲染位置无关 */
  private isOverScrollThreshold(): boolean {
    if (this.index === 0) return this.homeScrollOffset > this.SCROLL_THRESHOLD;
    if (this.index === 1) return this.dynScrollOffset > this.SCROLL_THRESHOLD;
    if (this.index === 2) return this.msgScrollOffset > this.SCROLL_THRESHOLD;
    return false;
  }

  private getIconScale(): number {
    let s: number = 1;
    if (this.isPressing) s *= 0.82;
    if (this.animatingTab === this.index) s *= 0.3;
    return s;
  }

  build() {
    Column() {
      // 判断是否显示回到顶部图标：首页(index=0)/动态(index=1) 滚动偏移超过阈值时切换
      // ⭐ if/else 分支重建组件：用 transition 播放「退出缩小渐隐 + 进入放大渐显」
      if (this.isOverScrollThreshold() && this.iconActiveTab === this.index) {
        Image($r('app.media.ic_celiakeyboard_switch_majuscule'))
          .width(28)
          .height(28)
          .objectFit(ImageFit.Contain)
          .margin({ top: -9 })
          .fillColor(this.themeColor)
          .transition(
            TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut })
              .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }).animation({ duration: 200, curve: Curve.EaseOut }))
          )
          .animation({ duration: 200, curve: Curve.EaseOut })
      } else {
        Image(this.iconActiveTab === this.index ? this.selectedIcon : this.normalIcon)
          .width(28)
          .height(28)
          .objectFit(ImageFit.Contain)
          .margin({ top: -9 })
          .fillColor(this.iconActiveTab === this.index ? this.themeColor :
            (this.isDarkMode ? '#FFFFFF' : '#000000'))
          .transition(
            TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut })
              .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }).animation({ duration: 200, curve: Curve.EaseOut }))
          )
          .animation({ duration: 200, curve: Curve.EaseOut })
      }
    }
    .width(50)
    .height(56)
    .justifyContent(FlexAlign.Center)
    // ★ 按压缩小反馈 + 切换 spring 弹跳
    .scale({ x: this.getIconScale(), y: this.getIconScale() })
    .animation(this.animatingTab === this.index
      ? { duration: 400, curve: curves.springMotion(0.4, 0.9) }
      : { duration: this.isPressing ? 60 : 280, curve: Curve.FastOutSlowIn })
    // ★ 按压透明度反馈
    .opacity(this.isPressing ? 0.75 : 1)
    .animation({ duration: 100, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.isPressing = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isPressing = false;
      }
    })
    .onClick(() => {
      if (this.onTabClick) {
        this.onTabClick(this.index);
      }
    })
  }
}
