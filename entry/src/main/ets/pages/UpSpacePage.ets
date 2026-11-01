// UpSpacePage.ets — UP主个人空间页
import { router, mediaquery, display, window, SegmentButton, SegmentButtonOptions, LengthMetrics } from '@kit.ArkUI';
import { hdsMaterial, HdsTabs, HdsNavDestination, ScrollEffectType } from '@kit.UIDesignKit';
import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { FloatingVideoButton } from '../components/FloatingVideoButton';
import { FullImagePreview } from '../components/FullImagePreview';
import { preferences } from '@kit.ArkData';
import { getUserSpaceVideos, UpSpaceInfo, UpRelationStat, UpSpaceVideoItem, modifyFollow, clearFollowedMidsCache, getUpSpaceInitData, blacklistUploader, unblacklistUploader, getUpSpaceDynamics, SpaceDynamicItem, DynVideoInfo, DynImageInfo, DynCommonInfo, DynTextSegment, prefetchVideoDetail } from '../api/BilibiliApi';

/** 图片网格四角圆角参数（与动态页同款） */
interface DynCornerRadius {
  topLeft?: number;
  topRight?: number;
  bottomLeft?: number;
  bottomRight?: number;
}

/** 动态类型常量 */
const DYN_TYPE_AV: string = 'DYNAMIC_TYPE_AV';
const DYN_TYPE_DRAW: string = 'DYNAMIC_TYPE_DRAW';
const DYN_TYPE_FORWARD: string = 'DYNAMIC_TYPE_FORWARD';
const DYN_TYPE_WORD: string = 'DYNAMIC_TYPE_WORD';

/** 排序选项 */
interface OrderOption {
  key: string;
  label: string;
}

const ORDER_OPTIONS: OrderOption[] = [
  { key: 'pubdate', label: '最新' },
  { key: 'click', label: '播放' },
  { key: 'stow', label: '收藏' }
];

/**
 * 图片 URL 追加压缩参数（hdslb 图床）：列表加载缩略图，避免直接解码原图导致内存峰值过高闪退
 * （与 CommentContentRenderer.resizeImageUrl 一致；原图仅全屏预览时使用）
 */
function resizeImageUrl(url: string, width: number): string {
  if (!url || !url.includes('hdslb.com')) {
    return url;
  }
  // ⚠️ 原实现 `!url.includes('@')`：URL 已带后缀（动态/OPUS 图常见）时**整段跳过压缩** → 原图整张解码
  const at: number = url.indexOf('@');
  const base: string = (at > url.lastIndexOf('/') && url.indexOf('?') < 0) ? url.substring(0, at) : url;
  return base + `@${width}w`;
}

/** 格式化播放数：万单位 */
function fmtN(n: number): string {
  // ⭐ 兜底：接口个别投稿缺 play/danmaku 等字段（undefined 会直接崩）
  const v: number = n || 0;
  if (v >= 10000) return (v / 10000).toFixed(1) + '万';
  if (v >= 1000) return (v / 1000).toFixed(1) + '千';
  return v.toString();
}

/** 格式化时长：秒 → mm:ss / h:mm:ss */
function fmtDuration(sec: number): string {
  if (sec <= 0) return '';
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  if (m >= 60) {
    const h = Math.floor(m / 60);
    return `${h}:${String(m % 60).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  }
  return `${m}:${String(s).padStart(2, '0')}`;
}

/** 格式化发布时间戳 → 相对时间 */
function fmtPubdate(ts: number): string {
  const t: number = ts || 0;
  const now = Math.floor(Date.now() / 1000);
  const diff = now - t;
  if (diff < 3600) return `${Math.floor(diff / 60)}分钟前`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}小时前`;
  if (diff < 2592000) return `${Math.floor(diff / 86400)}天前`;
  if (diff < 31536000) return `${Math.floor(diff / 2592000)}个月前`;
  return `${Math.floor(diff / 31536000)}年前`;
}

@Entry
@Component({ freezeWhenInactive: true })
struct UpSpacePage {
  // 路由参数
  @State mid: number = 0;
  @State upName: string = '';
  @State upFace: string = '';

  // 加载状态
  @State isInfoLoaded: boolean = false;
  @State isListLoaded: boolean = false;
  @State loadError: string = '';

  // UP主信息
  @State spaceInfo: UpSpaceInfo | null = null;
  @State relationStat: UpRelationStat | null = null;

  // 视频列表
  @State videos: UpSpaceVideoItem[] = [];
  @State videoPairs: UpSpaceVideoItem[][] = []; // A1 竖屏 2 列网格：两两分组
  @State videoTriples: UpSpaceVideoItem[][] = []; // A1 横屏 3 列网格：三三分组
  @State currentPage: number = 1;
  @State totalCount: number = 0;
  @State hasMore: boolean = true;
  @State isLoadingMore: boolean = false;
  @State order: string = 'pubdate'; // 排序：pubdate最新/click播放/stow收藏

  // 动态列表
  @State dynamics: SpaceDynamicItem[] = [];
  @State dynOffset: string = '';
  @State dynHasMore: boolean = false;
  @State dynLoading: boolean = false;
  @State isDynLoaded: boolean = false;

  // Tab：video=投稿 / dynamic=动态
  @State activeTab: string = 'video';

  // ⭐ SegmentButton 胶囊（仿播放页「详情/评论」）：投稿/动态（选中色跟随主题色，recalcSeg 里重建）
  @State tabOpt: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [{ text: '投稿' }, { text: '动态' }],
    fontColor: '#999999',
    selectedFontColor: '#FFFFFF',
    fontWeight: FontWeight.Normal,
    selectedFontWeight: FontWeight.Medium,
    backgroundColor: Color.Transparent,
    selectedBackgroundColor: '#007DFF',
    fontSize: 13,
    selectedFontSize: 13,
    buttonPadding: { top: 6, right: 16, bottom: 6, left: 16 },
  })
  @State tabSelIdx: number[] = [0]

  // ⭐ 分段按钮动态尺寸（窄屏适配，仿动态页 recalcCapsule 按屏宽计算）
  @State tabW: number = 160;
  @State sortW: number = 230;

  // ⭐ SegmentButton 胶囊：最新/播放/收藏（选中色跟随主题色，recalcSeg 里重建）
  @State sortOpt: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [{ text: '最新' }, { text: '播放' }, { text: '收藏' }],
    fontColor: '#999999',
    selectedFontColor: '#FFFFFF',
    fontWeight: FontWeight.Normal,
    selectedFontWeight: FontWeight.Medium,
    backgroundColor: Color.Transparent,
    selectedBackgroundColor: '#007DFF',
    fontSize: 12,
    selectedFontSize: 12,
    buttonPadding: { top: 5, right: 14, bottom: 5, left: 14 },
  })
  @State sortSelIdx: number[] = [0]

  // 样式状态
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') @Watch('onCustomThemeColorChanged') customThemeColor: string = '#007DFF';
  @StorageLink('wallpaper') wallpaper: string = 'default';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;
  // ⭐ 卡片样式（与动态页/首页一致）
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 15;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = true;
  // ⭐ 首页同款卡片间距（个性化页"首页样式 → 卡片间距"滑块；页面级左右边距/卡片间隔统一走它）
  // @Watch：胶囊宽度预算含 cardListMargin，滑块变了要重算 tabW/sortW
  @StorageLink('cardListMargin') @Watch('onCardListMarginChange') cardListMargin: number = 12;
  // ⭐ 图片全屏预览状态（动态图文同款 FullImagePreview）
  @State showPreview: boolean = false;
  @State previewImageUrls: string[] = [];
  @State previewThumbIds: string[] = [];
  @State previewIndex: number = 0;
  @State previewOriginX: number = 0;
  @State previewOriginY: number = 0;
  @State previewOriginW: number = 0;
  @State previewOriginH: number = 0;
  @State isLandscape: boolean = false;
  // ⭐ 状态栏高度走 EntryAbility 维护的全局值（vp，0=隐藏/横屏；本页自测 getWindowAvoidArea 实测会拿到 0）
  @StorageLink('statusBarHeight') statusBarHeight: number = 40;
  // ⭐ 关注状态
  @State isFollowed: boolean = false;
  // 下拉刷新
  @State isRefreshing: boolean = false;
  // 黑名单状态（简化：本地记录，菜单文案切换）
  @State isBlacklisted: boolean = false;
  // 媒体查询监听器（方向变化，与 HomePage 相同方案）
  private landscapeListener: mediaquery.MediaQueryListener | null = null;
  private isPageActive: boolean = false;
  // ⭐ A1 页眉吸顶：列表滚动器 + 页眉实测高度（onAreaChange）+ 吸顶开关（仅竖屏用）
  private videoScroller: Scroller = new Scroller();
  private dynScroller: Scroller = new Scroller();
  @State headerH: number = 0;
  @State videoSticky: boolean = false;
  @State dynSticky: boolean = false;
  // 节标题行实测高度（onAreaChange）：吸顶期间列表内本行用同高占位隐藏，防布局跳动
  @State secRowH: number = 0;
  // 沉浸光感分段胶囊的玻璃条高（官方 SegmentButton 内在高 ~40.5，回归官方比例）；
  // 内容 34 居中、上下各 3vp 对称余量——系统内缩（~3vp，在哪侧未知）最多造成 1vp 视觉偏差
  @State segBarH: number = 40;

  async aboutToAppear(): Promise<void> {
    this.isPageActive = true;
    // 获取路由参数
    const params = router.getParams() as Record<string, Object>;
    if (params) {
      this.mid = (params['mid'] as number) || 0;
      this.upName = (params['upName'] as string) || '';
      this.upFace = (params['upFace'] as string) || '';
    }
    // 状态栏高度由 @StorageLink('statusBarHeight') 提供（EntryAbility 维护）；
    // 但全局值可能被"全屏播放退出 / 上次横屏持久化"等路径留成 0（状态栏其实可见）⇒ 竖屏进页时按 SearchPage 同口径自愈一次
    this.refreshStatusBarHeight();
    this.listenOrientationChange();
    this.recalcSeg();
    // 加载数据
    await this.loadAllData();
  }

  aboutToDisappear(): void {
    this.isPageActive = false;
    // 移除媒体查询监听
    if (this.landscapeListener) {
      this.landscapeListener.off('change');
      this.landscapeListener = null;
    }
  }

  /** 注册媒体查询监听（方向变化，与 HomePage 相同方案） */
  private listenOrientationChange(): void {
    const mediaQuery = this.getUIContext().getMediaQuery();
    this.landscapeListener = mediaQuery.matchMediaSync('(orientation: landscape)');
    // 初始方向
    this.isLandscape = this.landscapeListener.matches;
    this.landscapeListener.on('change', (result: mediaquery.MediaQueryResult) => {
      if (!this.isPageActive) return;
      const newIsLandscape = result.matches;
      if (this.isLandscape !== newIsLandscape) {
        logInfo(`[UpSpacePage] 方向变化: ${newIsLandscape ? '横屏' : '竖屏'}`);
        this.isLandscape = newIsLandscape;
        this.recalcSeg();
        if (!newIsLandscape) {
          // 横转竖：全局状态栏高度在横屏期间为 0，转回竖屏后自愈一次
          this.refreshStatusBarHeight();
        }
      }
    });
  }

  /**
   * 竖屏时刷新全局状态栏高度（与 SearchPage 同口径：getLastWindow + TYPE_SYSTEM 避让区）。
   * 仅测得 >0 才写 AppStorage——横屏/隐藏态测到 0 不写，避免把好值冲掉。
   */
  private async refreshStatusBarHeight(): Promise<void> {
    if (this.isLandscape) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(context);
      const avoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const realHeight = this.getUIContext().px2vp(avoidArea.topRect.height);
      if (realHeight > 0 && realHeight !== this.statusBarHeight) {
        AppStorage.set('statusBarHeight', realHeight);
      }
    } catch (_) {}
  }

  /** ⭐ 主题色变化时重建分段按钮（选中胶囊色跟随主题色） */
  private onCustomThemeColorChanged(): void {
    this.recalcSeg();
  }

  /** ⭐ 卡片间距变化时重算分段按钮宽度（宽度预算含 cardListMargin） */
  private onCardListMarginChange(): void {
    this.recalcSeg();
  }

  /** ⭐ 分段按钮窄屏适配：按屏宽动态计算宽度，窄屏（<380vp）缩字号/内边距，避免显示不完整 */
  private recalcSeg(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const screenW = this.getUIContext().px2vp(d.width);
      const avail = Math.max(240, screenW - 2 * this.cardListMargin - 12);
      const narrow = screenW < 380;
      // 选中胶囊底色：主题色 + 25% 透明（"特别透明"）；选中文字用主题色保证浅色玻璃上可读
      const accent = this.customThemeColor;
      const rgb = accent.length >= 7 ? accent.slice(-6) : accent.replace('#', '');
      const selBg = '#40' + rgb;
      if (screenW > 600) {
        // 横屏/宽屏：按比例并封顶（160/230，观感已验证正确，勿动）
        this.tabW = Math.min(160, Math.round(avail * 0.41));
        this.sortW = Math.min(230, Math.round(avail * 0.59));
      } else {
        // 竖屏：胶囊紧凑定宽（总 ≈340vp，中间留呼吸空白），可用宽不足时按比例收缩
        const k = Math.min(1, avail / 340);
        this.tabW = Math.round(140 * k);
        this.sortW = Math.round(200 * k);
      }
      this.tabOpt = SegmentButtonOptions.capsule({
        buttons: [{ text: '投稿' }, { text: '动态' }],
        fontColor: '#999999',
        selectedFontColor: '#FFFFFF',
        fontWeight: FontWeight.Normal,
        selectedFontWeight: FontWeight.Medium,
        backgroundColor: Color.Transparent,
        selectedBackgroundColor: accent,
        fontSize: narrow ? 12 : 13,
        selectedFontSize: narrow ? 12 : 13,
        // 按钮内边距左右 12：防"投稿/动态"出省略号；上下 5 配合内容高 34
        buttonPadding: narrow ? { top: 4, right: 10, bottom: 4, left: 10 } : { top: 5, right: 12, bottom: 5, left: 12 },
      });
      this.sortOpt = SegmentButtonOptions.capsule({
        buttons: [{ text: '最新' }, { text: '播放' }, { text: '收藏' }],
        fontColor: '#999999',
        selectedFontColor: '#FFFFFF',
        fontWeight: FontWeight.Normal,
        selectedFontWeight: FontWeight.Medium,
        backgroundColor: Color.Transparent,
        selectedBackgroundColor: accent,
        fontSize: narrow ? 11 : 12,
        selectedFontSize: narrow ? 11 : 12,
        buttonPadding: narrow ? { top: 4, right: 11, bottom: 4, left: 11 } : { top: 5, right: 12, bottom: 5, left: 12 },
      });
    } catch (_e) {
      // 异常时保持默认尺寸（160/230）
    }
  }

  private async loadAllData(): Promise<void> {
    if (!this.mid) {
      this.loadError = '用户ID无效';
      return;
    }
    // 并行加载：UP主信息 + 视频列表 同时发起（无节流延迟）
    await Promise.all([
      this.loadProfileData(),
      this.loadVideos(1)
    ]);
  }

  private async loadProfileData(): Promise<void> {
    try {
      const result = await getUpSpaceInitData(this.mid);
      if (result.info) {
        this.spaceInfo = result.info;
        this.upName = result.info.name;
        this.upFace = result.info.face;
      }
      this.relationStat = result.relation;
      this.isFollowed = result.isFollowed;
      logInfo(`[UpSpacePage] 并行加载完成: info=${result.info !== null}, relation=${result.relation !== null}, isFollowed=${result.isFollowed}`);
    } catch (err) {
      logError(`[UpSpacePage] 加载UP主信息失败: ${err}`);
    } finally {
      this.isInfoLoaded = true;
    }
  }

  private async loadVideos(page: number): Promise<void> {
    if (this.isLoadingMore) return;
    this.isLoadingMore = true;
    try {
      const result = await getUserSpaceVideos(this.mid, page, 30, this.order);
      if (result) {
        if (page === 1) {
          this.videos = result.list.vlist || [];
          this.videoPairs = this.buildVideoGroups(this.videos, 2);
          this.videoTriples = this.buildVideoGroups(this.videos, 3);
          logInfo(`[UpSpacePage] loadVideos page=1: videos.length=${this.videos.length}, totalCount=${result.page.count}`);
          // 打印第一个视频信息确认
          if (this.videos.length > 0) {
            logInfo(`[UpSpacePage] 第一个视频: bvid=${this.videos[0].bvid}, title=${this.videos[0].title}`);
          }
        } else {
          this.videos = [...this.videos, ...(result.list.vlist || [])];
          this.videoPairs = this.buildVideoGroups(this.videos, 2);
          this.videoTriples = this.buildVideoGroups(this.videos, 3);
        }
        this.totalCount = result.page.count || 0;
        this.currentPage = page;
        this.hasMore = this.videos.length < this.totalCount;
      } else {
        if (page === 1) {
          this.loadError = '加载视频列表失败';
        }
      }
    } catch (err) {
      logError(`[UpSpacePage] 加载视频列表失败: ${err}`);
      if (page === 1) {
        this.loadError = '网络错误，请稍后重试';
      }
    } finally {
      this.isListLoaded = true;
      this.isLoadingMore = false;
    }
  }

  private loadMore(): void {
    if (this.hasMore && !this.isLoadingMore) {
      this.loadVideos(this.currentPage + 1);
    }
  }

  /** 切换排序：重置视频列表并重新加载 */
  private switchOrder(newOrder: string): void {
    if (newOrder === this.order) return;
    this.order = newOrder;
    this.videos = [];
    this.videoPairs = [];
    this.videoTriples = [];
    this.currentPage = 1;
    this.hasMore = true;
    this.isListLoaded = false;
    this.loadError = '';
    this.loadVideos(1);
  }

  /** 加载动态列表（offset 游标分页） */
  private async loadDynamics(offset: string): Promise<void> {
    if (this.dynLoading) return;
    this.dynLoading = true;
    try {
      const result = await getUpSpaceDynamics(this.mid, offset);
      if (result) {
        if (!offset) {
          this.dynamics = result.items;
        } else {
          this.dynamics = [...this.dynamics, ...result.items];
        }
        this.dynOffset = result.offset;
        this.dynHasMore = result.hasMore;
        logInfo(`[UpSpacePage] 动态加载: items=${result.items.length}, hasMore=${result.hasMore}`);
      }
    } catch (err) {
      logError(`[UpSpacePage] 加载动态失败: ${err}`);
    } finally {
      this.dynLoading = false;
      this.isDynLoaded = true;
    }
  }

  /** 动态触底加载更多 */
  private loadMoreDynamics(): void {
    if (this.dynHasMore && !this.dynLoading) {
      this.loadDynamics(this.dynOffset);
    }
  }

  /** 切换 Tab：首次进入动态时懒加载 */
  private switchTab(tab: string): void {
    if (tab === this.activeTab) return;
    this.activeTab = tab;
    if (tab === 'dynamic' && !this.isDynLoaded) {
      this.loadDynamics('');
    }
  }

  /** 从动态视频卡片跳转播放 */
  private playDynVideo(video: DynVideoInfo | null): void {
    if (!video || !video.bvid) {
      this.getUIContext().getPromptAction().showToast({ message: '无法播放该动态视频', duration: 1500 });
      return;
    }
    // ⭐ 预热详情（fire-and-forget）：把加载 cid 的 RTT 藏进转场+播放器初始化
    prefetchVideoDetail(video.bvid);
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/VideoPlayerPage',
      params: {
        bvid: video.bvid,
        title: video.title,
        coverUrl: video.cover,
        cid: 0
      }
    });
  }

  /** 将视频列表按每行 size 个分组（A1 网格：竖屏 2 列 / 横屏 3 列） */
  private buildVideoGroups(videos: UpSpaceVideoItem[], size: number): UpSpaceVideoItem[][] {
    const groups: UpSpaceVideoItem[][] = [];
    for (let i: number = 0; i < videos.length; i += size) {
      groups.push(videos.slice(i, Math.min(i + size, videos.length)));
    }
    return groups;
  }

  private goBack(): void {
    router.back();
  }

  private playVideo(item: UpSpaceVideoItem): void {
    // ⭐ 预热详情（fire-and-forget）：把加载 cid 的 RTT 藏进转场+播放器初始化
    prefetchVideoDetail(item.bvid);
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/VideoPlayerPage',
      params: {
        bvid: item.bvid,
        title: item.title,
        coverUrl: item.pic,
        cid: 0
      }
    });
  }

  // ⭐ 切换关注状态
  private async toggleFollow(): Promise<void> {
    if (!this.spaceInfo) return;
    const newIsFollowed = !this.isFollowed;
    const success = await modifyFollow(this.mid, newIsFollowed ? 1 : 2);
    if (success) {
      this.isFollowed = newIsFollowed;
      clearFollowedMidsCache();
      this.getUIContext().getPromptAction().showToast({ message: newIsFollowed ? '关注成功' : '取消关注', duration: 1500 });
    } else {
      this.getUIContext().getPromptAction().showToast({ message: '操作失败，请重试', duration: 1500 });
    }
  }

  /** 打开私信（跟UP主聊天） */
  private openWhisper(): void {
    try {
      const cookie = AppStorage.get<string>('biliCookie') || '';
      if (!cookie.includes('SESSDATA')) {
        this.getUIContext().getPromptAction().showToast({ message: '请先登录', duration: 1500 });
        return;
      }
      router.pushUrl({
        url: 'pages/WhisperDetailPage',
        params: {
          'talkerId': this.mid,
          'name': this.spaceInfo?.name ?? this.upName,
          'face': this.spaceInfo?.face ?? this.upFace
        }
      });
    } catch (err) {
      logError(`[UpSpacePage] openWhisper 失败: ${errMsg(err)}`);
    }
  }

  /** 下拉刷新：按当前 Tab 刷新 */
  private async onRefresh(): Promise<void> {
    try {
      if (this.activeTab === 'video') {
        this.order = 'pubdate';
        this.videos = [];
        this.videoPairs = [];
        this.videoTriples = [];
        this.currentPage = 1;
        this.hasMore = true;
        this.isListLoaded = false;
        this.loadError = '';
        await Promise.all([
          this.loadProfileData(),
          this.loadVideos(1)
        ]);
      } else {
        this.dynamics = [];
        this.dynOffset = '';
        this.dynHasMore = false;
        this.isDynLoaded = false;
        await this.loadDynamics('');
      }
    } finally {
      this.isRefreshing = false;
    }
  }

  /** 加入/移除黑名单 */
  private async toggleBlacklist(): Promise<void> {
    try {
      const ok = this.isBlacklisted ? await unblacklistUploader(this.mid) : await blacklistUploader(this.mid);
      if (ok) {
        this.isBlacklisted = !this.isBlacklisted;
        this.getUIContext().getPromptAction().showToast({ message: this.isBlacklisted ? '已加入黑名单' : '已移除黑名单', duration: 1500 });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '操作失败，请重试', duration: 1500 });
      }
    } catch (err) {
      logError(`[UpSpacePage] 黑名单操作失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '操作失败，请重试', duration: 1500 });
    }
  }

  /** 复制用户名 */
  private async copyUpName(): Promise<void> {
    const name = this.spaceInfo?.name ?? this.upName;
    if (!name) return;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, name);
      await pasteboard.getSystemPasteboard().setData(data);
      this.getUIContext().getPromptAction().showToast({ message: '已复制用户名', duration: 1500 });
    } catch (err) {
      logError(`[UpSpacePage] 复制失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '复制失败', duration: 1500 });
    }
  }

  /** 更多操作菜单 */
  private showMoreMenu(): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: '更多操作',
      buttons: [
        { text: '复制用户名', color: this.isDarkMode ? '#E5E5E5' : '#333333' },
        { text: this.isBlacklisted ? '移除黑名单' : '加入黑名单', color: '#FF4444' }
      ]
    }).then((result) => {
      const idx = result.index;
      if (idx === 0) {
        this.copyUpName();
      } else if (idx === 1) {
        this.toggleBlacklist();
      }
    }).catch((_err: Error) => {
      // 用户取消菜单，忽略
    });
  }

  /** 明暗效果层（全局壁纸暗化/亮化：wallpaperDarkness <50 压黑，>50 提白） */
  @Builder
  wallpaperDarknessLayer() {
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

  /** 下拉刷新指示器（非刷新态显示静态箭头，仅刷新时转圈，避免 LoadingProgress 常驻动画） */
  @Builder
  customRefreshComponent() {
    Stack() {
      Column() {
        if (this.isRefreshing) {
          LoadingProgress()
            .width(26).height(26)
            .color(this.customThemeColor)
        } else {
          Text('↓')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.customThemeColor)
        }
        Text('下拉刷新')
          .fontSize(12)
          .fontColor('#999999')
          .margin({ top: 6 })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 12 })
    }
    .width('100%')
  }

  build() {
    HdsNavDestination() {
    Stack() {
      // ── 背景层：全局壁纸（默认壁纸分深/浅模式；与搜索页等其余页面同款三分支）──
      if (this.wallpaper === 'builtin') {
        Stack() {
          Image(this.isDarkMode ? $r('app.media.wallpaper_shen') : $r('app.media.wallpaper_qian'))
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
          this.wallpaperDarknessLayer()
        }
        .width('100%').height('100%')
      } else if (this.wallpaper === 'custom' && this.customWallpaper) {
        Stack() {
          Image('file://' + this.customWallpaper)
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
            .blur(this.wallpaperBlur)
          this.wallpaperDarknessLayer()
        }
        .width('100%').height('100%')
      } else {
        Stack() {
          Column()
            .width('100%').height('100%')
            .backgroundColor(this.paperBg())
          this.wallpaperDarknessLayer()
        }
        .width('100%').height('100%')
      }

      // ── 前景内容（完全在遮罩之上）──
      if (this.isLandscape) {
        // ── A1 横屏：左 rail（固定不滚）+ 右侧 Stack（列表全高，内容从固定分段条下方滑过屏幕顶）──
        Row() {
          this.railSection()

          Stack() {
            // 列表全高：视口顶边 = 屏幕顶，卡片滑到屏幕边才被裁切（内容顶 spacer 撑出初始位置）
            Column() {
              if (this.activeTab === 'video') {
                this.videoListLandscape()
              } else {
                this.dynamicList()
              }
            }
            .width('100%')
            .height('100%')

            // 固定节标题条覆盖层（不在列表内需自带上下间距；无遮罩；透传触摸给下方列表）
            Column() {
              this.sectionRow(this.cardListMargin, this.cardListMargin)
            }
            .width('100%')
            .hitTestBehavior(HitTestMode.Transparent)
          }
          .layoutWeight(1)
          .height('100%')
          .alignContent(Alignment.TopStart)
        }
        .width('100%')
        .height('100%')
      } else {
        // ── A1 竖屏：列表全高（内容滑到屏幕顶才裁切）+ 页眉随列表滚走 + 吸顶节标题 ──
        Column() {
          if (this.activeTab === 'video') {
            this.videoListPortrait()
          } else {
            this.dynamicList()
          }
        }
        .width('100%')
        .height('100%')
        .clip(false)

        // ── 吸顶节标题替身（滚过页眉后出现；无遮罩无底边线；透传触摸给下方列表）──
        if (this.activeTab === 'video' ? this.videoSticky : this.dynSticky) {
          Column() {
            Row() {}.width('100%').height(this.statusBarHeight + 56 + 16)
            // 顶 0：与列表内行（无上下 padding）像素级对位，交换无缝
            this.sectionRow(0, this.cardListMargin)
          }
          .width('100%')
          .hitTestBehavior(HitTestMode.Transparent)
        }
      }

    // ⭐ 最小化视频悬浮按钮
    FloatingVideoButton()

    // ⭐ 图片全屏预览（与动态页同款：一镜到底飞入、左右滑动切图）
    FullImagePreview({
      isShow: $showPreview,
      previewUrls: this.previewImageUrls,
      thumbIds: this.previewThumbIds,
      initialIndex: this.previewIndex,
      originX: $previewOriginX,
      originY: $previewOriginY,
      originW: $previewOriginW,
      originH: $previewOriginH,
      immersiveMode: this.isLandscape
    })
  }
  .width('100%').height('100%')
  .backgroundColor(Color.Transparent)
  .alignContent(Alignment.TopStart);
    }
    .hideBackButton(false)
    .onBackPressed(() => {
      this.goBack();
      return true;
    })
    .backgroundColor('transparent')
    .titleBar({
      avoidLayoutSafeArea: true,
      padding: { start: LengthMetrics.vp(16), end: LengthMetrics.vp(16) },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        },
        originalStyle: {
          backgroundStyle: { backgroundColor: 'transparent' },
          contentStyle: {
            titleStyle: {
              mainTitleColor: this.isDarkMode ? '#FFFFFF' : '#000000'
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: { backgroundColor: 'transparent' },
          contentStyle: {
            titleStyle: {
              mainTitleColor: this.isDarkMode ? '#FFFFFF' : '#000000'
            }
          }
        }
      },
      content: {
        title: { mainTitle: '个人空间' },
        backIcon: {
          action: () => {
            this.goBack();
          }
        }
      }
    })
  }

  /**
   * A1 页眉（竖屏，随列表滚走）：mono 标签 + 头像/衬线名/认证/LV + 签名 + 数据条 + 全宽关注条
   * 纯排版、无图片依赖：0 投稿、接口半失败（spaceInfo 为 null 用路由参数兜底）页面都完整成立。
   */
  @Builder
  spaceHeader() {
    Column() {
      // ⭐ 圆角矩形卡片包裹个人信息（纸面白卡 + hairline 描边 + 轻投影）
      Column() {
      // mono 标签 + 更多（卡片内右上）
      Row() {
        Text(`UP-SPACE · UID ${this.mid}`)
          .fontFamily('monospace')
          .fontSize(9.5)
          .letterSpacing(2.5)
          .fontColor(this.muted())
        Blank()
        Stack() {
          Image($r('app.media.more'))
            .width(16).height(16)
            .fillColor(this.inkSoft())
        }
        .width(30).height(30)
        .borderRadius(15)
        .backgroundColor(this.iconBtnBg())
        .onClick(() => { this.showMoreMenu(); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 头像行（底对齐）
      Row() {
        Image(this.upFace)
          .width(84).height(84).borderRadius(42)
          .objectFit(ImageFit.Cover)
          .backgroundColor(this.isDarkMode ? '#2A2723' : '#E8E4DC')
          .border({ width: 3, color: this.isDarkMode ? '#26221D' : '#FFFFFF' })
          .shadow({ radius: 18, color: 'rgba(60,70,90,0.25)', offsetX: 0, offsetY: 6 })

        Column() {
          Row() {
            Text(this.spaceInfo?.name ?? this.upName)
              .fontFamily('serif')
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.ink())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            this.verifyBadge()
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row() {
            this.lvBadge()
          }
          .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 15 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 12 })

      // 签名（无签名整块省略，页眉预算 −60）
      if (this.spaceInfo?.sign) {
        Text(this.spaceInfo.sign)
          .fontSize(12.5)
          .fontColor(this.warmGray())
          .lineHeight(20)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 12 })
      }

      // 数据条：上下 hairline + 三栏（投稿/粉丝/关注）
      Row() {
        this.statCell('count', '投稿')
        Column().width(1).height('100%').backgroundColor(this.hairlineSoft())
        this.statCell('follower', '粉丝')
        Column().width(1).height('100%').backgroundColor(this.hairlineSoft())
        this.statCell('following', '关注')
      }
      .width('100%')
      .height(52)
      .margin({ top: 14 })
      .border({ width: { top: 1, bottom: 1 }, color: this.hairline() })

      // 关注主条 + 私信图标钮
      Row() {
        Row() {
          Text(this.isFollowed ? '已关注' : '＋ 关注')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .letterSpacing(0.5)
            .fontColor(this.isFollowed ? this.muted() : '#FFFFFF')
        }
        .layoutWeight(1)
        .height(42)
        .borderRadius(12)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.isFollowed ? Color.Transparent : this.customThemeColor)
        .border({ width: this.isFollowed ? 1 : 0, color: this.isFollowed ? this.hairline() : Color.Transparent })
        .onClick(() => this.toggleFollow())

        Stack() {
          Image($r('app.media.message'))
            .width(18).height(18)
            .fillColor(this.inkSoft())
        }
        .width(42).height(42)
        .borderRadius(12)
        .backgroundColor(this.iconBtnBg())
        .margin({ left: 8 })
        .onClick(() => this.openWhisper())
      }
      .width('100%')
      .margin({ top: 14 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 16 })
      .backgroundColor(this.getCardItemBg())
      .borderRadius(15)
      .border({ width: this.cardBorderWidth, color: this.getCardItemBorder() })
      .shadow({ radius: 4, color: '#10000000', offsetX: 0, offsetY: 2 })
    }
    .width('100%')
    .padding({ left: this.cardListMargin, right: this.cardListMargin })
    .alignItems(HorizontalAlign.Start)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.headerH = newArea.height as number;
    })
  }

  /**
   * ⭐ 数据条数值（按数据种类取值）：
   * @Builder 按值传参（value: string）不建立状态刷新依赖——relationStat 异步到达后
   * Text 仍显示求值快照 "0"，直到横屏等其它状态触发 build 重跑才正确显示。
   * 改为在 @Builder 内渲染期直接读取 @State，数据到达即刷新。
   */
  private statText(kind: string): string {
    if (kind === 'count') {
      return fmtN(this.totalCount);
    }
    if (kind === 'follower') {
      return fmtN(this.relationStat?.follower ?? 0);
    }
    return fmtN(this.relationStat?.following ?? 0);
  }

  /** A1 数据条单元：衬线数字 + letterspacing 小标签 */
  @Builder
  statCell(kind: string, label: string) {
    Column() {
      Text(this.statText(kind))
        .fontFamily('serif')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.ink())
      Text(label)
        .fontSize(9)
        .letterSpacing(1.5)
        .fontColor(this.muted())
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .clickEffect({ level: 1, scale: 0.9 })
    .onClick(() => {
      this.onStatCellClick(label);
    })
  }

  /** LV 胶囊（主题色底白字） */
  @Builder
  lvBadge() {
    if (this.spaceInfo?.level && this.spaceInfo.level > 0) {
      Text(`LV${this.spaceInfo.level}`)
        .fontSize(9)
        .fontWeight(FontWeight.Bold)
        .letterSpacing(0.6)
        .fontColor('#FFFFFF')
        .backgroundColor(this.customThemeColor)
        .padding({ left: 6, right: 6, top: 1.5, bottom: 1.5 })
        .borderRadius(4)
    }
  }

  /** 认证徽章（0=个人蓝 / 1=机构粉；无认证省略） */
  @Builder
  verifyBadge() {
    if (this.spaceInfo?.official_verify?.type === 0 || this.spaceInfo?.official_verify?.type === 1) {
      Text('✓')
        .fontSize(11)
        .fontColor('#FFFFFF')
        .width(17).height(17)
        .borderRadius(8.5)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.spaceInfo?.official_verify?.type === 0 ? '#56B7FF' : '#FB7299')
        .margin({ left: 7 })
    }
  }

  /**
   * A1 节标题行：投稿/动态胶囊（左）+ 排序胶囊（右，仅投稿 Tab）。
   * ⭐ 分段胶囊 = 真·沉浸光感：官方 SegmentButton（透明底）装进钉死尺寸的 HdsTabs 浮动条，
   *    玻璃由系统自绘（barFloatingStyle.systemMaterialEffect，IMMERSIVE + ADAPTIVE）。
   *    内容区直接挂 systemMaterial 不渲染（docs/沉浸光感实现指南.md §一），
   *    HdsTabs 浮动条本身就是合法材质表面（DynamicsPage 悬浮钮 / YunShangSJ ServerPage.segControl 同款，真机已验证）。
   * ⚠️ HdsTabs 在无界滚动上下文里必须显式钉 width/height（否则布局爆炸）；
   *    barWidth 传数值（本页 tabW/sortW 本就是数值）；gradientMask 必须显式 Transparent（红线 13）。
   * ⚠️ 上下 padding 由调用方按场景传入：列表内项传 0/0（List 的 space 已提供间距，自带会变 2 倍缝）；
   *    吸顶替身传 0/间距；横屏固定条传 间距/间距（不在列表内，需自带）。
   */
  @Builder
  sectionRow(vPadTop: number, vPadBottom: number) {
    Row() {
      // 投稿 / 动态（真沉浸光感玻璃胶囊）
      HdsTabs() {
        TabContent()
          .tabBar(this.segTabContent())
      }
      .barWidth(this.tabW)
      .barHeight(this.segBarH)
      .width(this.tabW)
      .height(this.segBarH)
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .barFloatingStyle({
        gradientMask: { maskColor: Color.Transparent },
        barBottomMargin: 0,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      })
      .scrollable(false)
      .animationDuration(0)
      .backgroundColor(Color.Transparent)
      .clip(false)

      Blank()

      if (this.activeTab === 'video') {
        HdsTabs() {
          TabContent()
            .tabBar(this.segSortContent())
        }
        .barWidth(this.sortW)
        .barHeight(this.segBarH)
        .width(this.sortW)
        .height(this.segBarH)
        .barOverlap(true)
        .barPosition(BarPosition.End)
        .barFloatingStyle({
          gradientMask: { maskColor: Color.Transparent },
          barBottomMargin: 0,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .scrollable(false)
        .animationDuration(0)
        .backgroundColor(Color.Transparent)
        .clip(false)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: this.cardListMargin, right: this.cardListMargin, top: vPadTop, bottom: vPadBottom })
  }

  /** 投稿/动态 玻璃胶囊内容：官方 SegmentButton 透明底，选中滑块主题色由官方自绘。
   *  ⚠️ 高度显式 44（不是 '100%'）：条内系统 ~3vp 内缩在底部，写满会整体上浮（"选中胶囊靠上"根因） */
  @Builder
  segTabContent() {
    Stack({ alignContent: Alignment.Center }) {
      SegmentButton({
        options: this.tabOpt,
        selectedIndexes: $tabSelIdx,
        onItemClicked: (idx: number) => { this.switchTab(idx === 0 ? 'video' : 'dynamic'); }
      })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  /** 排序 玻璃胶囊内容（同上） */
  @Builder
  segSortContent() {
    Stack({ alignContent: Alignment.Center }) {
      SegmentButton({
        options: this.sortOpt,
        selectedIndexes: $sortSelIdx,
        onItemClicked: (idx: number) => { this.switchOrder(ORDER_OPTIONS[idx].key); }
      })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  /**
   * A1 横屏左侧个人信息（圆角矩形卡片，与竖屏页眉同款、受全局卡片样式控制）：
   * mono 标签 + 更多（卡内右上）、头像/名/LV、纵列数据、关注条、衬线斜体签名引文；超高时 Scroll 兜底
   */
  @Builder
  railSection() {
    Column() {
      Scroll() {
        Column() {
          // mono 标签 + 更多（卡片内右上）
          Row() {
            Text(`UP-SPACE · UID ${this.mid}`)
              .fontFamily('monospace')
              .fontSize(9)
              .letterSpacing(2)
              .fontColor(this.muted())
            Blank()
            Stack() {
              Image($r('app.media.more'))
                .width(16).height(16)
                .fillColor(this.inkSoft())
            }
            .width(30).height(30)
            .borderRadius(15)
            .backgroundColor(this.iconBtnBg())
            .onClick(() => { this.showMoreMenu(); })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Image(this.upFace)
            .width(72).height(72).borderRadius(36)
            .objectFit(ImageFit.Cover)
            .backgroundColor(this.isDarkMode ? '#2A2723' : '#E8E4DC')
            .border({ width: 3, color: this.isDarkMode ? '#26221D' : '#FFFFFF' })
            .margin({ top: 14 })

          Text(this.spaceInfo?.name ?? this.upName)
            .fontFamily('serif')
            .fontSize(21)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.ink())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 9 })

          Row() {
            this.lvBadge()
            this.verifyBadge()
          }
          .margin({ top: 4 })

          // 纵列数据（每行：衬线数字 + 小标签，行间 hairline）
          Column() {
            this.railStat('count', '投稿')
            this.railStat('follower', '粉丝')
            this.railStat('following', '关注')
          }
          .width('100%')
          .margin({ top: 12 })

          // 关注条 + 私信
          Row() {
            Row() {
              Text(this.isFollowed ? '已关注' : '＋ 关注')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isFollowed ? this.muted() : '#FFFFFF')
            }
            .layoutWeight(1)
            .height(40)
            .borderRadius(12)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.isFollowed ? Color.Transparent : this.customThemeColor)
            .border({ width: this.isFollowed ? 1 : 0, color: this.isFollowed ? this.hairline() : Color.Transparent })
            .onClick(() => this.toggleFollow())

            Stack() {
              Image($r('app.media.message'))
                .width(16).height(16)
                .fillColor(this.inkSoft())
            }
            .width(40).height(40)
            .borderRadius(12)
            .backgroundColor(this.iconBtnBg())
            .margin({ left: 7 })
            .onClick(() => this.openWhisper())
          }
          .width('100%')
          .margin({ top: 12 })

          // 签名引文（衬线斜体 + 左侧 3px 主题色线；无签名省略）
          // Blank 把它钉到卡片底部：卡片高度自适应可用区域时，底部不留死白
          if (this.spaceInfo?.sign) {
            Blank().layoutWeight(1)
            Text(this.spaceInfo.sign)
              .fontFamily('serif')
              .fontStyle(FontStyle.Italic)
              .fontSize(13)
              .fontColor(this.warmGray())
              .lineHeight(20)
              .maxLines(4)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 12 })
              .border({ width: { left: 3 }, color: this.customThemeColor })
              .margin({ top: 12 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .backgroundColor(this.getCardItemBg())
        .borderRadius(15)
        .border({ width: this.cardBorderWidth, color: this.getCardItemBorder() })
        .shadow({ radius: 4, color: '#10000000', offsetX: 0, offsetY: 2 })
        // ⭐ 上下自适应：至少撑满 rail 可用高度（内容超出时随内容增长、Scroll 兜底滚动）
        .constraintSize({ minHeight: '100%' })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width(296)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    // 右侧 padding 给 0：与内容区间的缝由内容列自己的左 padding（= cardListMargin）提供，避免双倍间距
    .padding({ left: this.cardListMargin, right: 0, top: this.statusBarHeight + 56 + this.cardListMargin, bottom: this.cardListMargin })
  }

  /** A1 横屏 rail 纵列数据行（点击行为与竖屏 statCell 一致） */
  @Builder
  railStat(kind: string, label: string) {
    Row() {
      Text(this.statText(kind))
        .fontFamily('serif')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.ink())
      Text(label)
        .fontSize(11)
        .fontColor(this.muted())
        .margin({ left: 8 })
      Blank()
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .border({ width: { bottom: 1 }, color: this.hairlineSoft() })
    .clickEffect({ level: 1, scale: 0.97 })
    .onClick(() => {
      this.onStatCellClick(label);
    })
  }

  /**
   * ⭐ 数据条点击（参考 B 站官方）：
   * 投稿 → 切到投稿 Tab 并滚回列表顶；粉丝 → 粉丝列表页；关注 → 关注列表页
   */
  private onStatCellClick(label: string): void {
    if (label === '投稿') {
      if (this.activeTab !== 'video') {
        this.switchTab('video');
      }
      this.videoScroller.scrollTo({
        xOffset: 0,
        yOffset: 0,
        animation: { duration: 300, curve: Curve.EaseOut }
      });
      return;
    }
    const type: string = label === '关注' ? 'following' : 'fans';
    const title: string = label === '关注' ? '关注列表' : '粉丝列表';
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/RelationListPage',
      params: {
        mid: this.mid,
        type: type,
        title: title
      }
    }).catch((err: Error) => {
      logWarn(`[UpSpacePage] 进入${title}失败: ${err.message}`);
    });
  }

  /**
   * A1 网格视频卡（圆角矩形卡片，受全局卡片样式控制）：
   * 16:10 封面（右下时长角标）+ 2 行标题 + meta（播放 · 相对时间）；封面按显示尺寸压缩解码（@400w）
   */
  @Builder
  gridVideoCard(item: UpSpaceVideoItem) {
    Column() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(resizeImageUrl(item.pic, 400))
          .width('100%')
          .aspectRatio(16 / 10)
          .objectFit(ImageFit.Cover)
          .borderRadius(Math.max(4, this.cardListBorderRadius - 4))
          .backgroundColor(this.isDarkMode ? '#2A2723' : '#E8E4DC')
        if (item.duration > 0) {
          Text(fmtDuration(item.duration))
            .fontSize(9)
            .fontColor('#FFFFFF')
            .backgroundColor('rgba(0,0,0,0.55)')
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .borderRadius(5)
            .margin({ right: 7, bottom: 7 })
        }
      }
      .width('100%')

      Text(item.title)
        .fontSize(11.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.inkSoft())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(16)
        .width('100%')
        .margin({ top: 8 })

      Text(`${fmtN(item.play)} · ${fmtPubdate(item.pubdate)}`)
        .fontSize(9.5)
        .fontColor(this.isDarkMode ? '#8A8478' : '#A6A29A')
        .maxLines(1)
        .width('100%')
        .margin({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(8)
    .backgroundColor(this.getCardItemBg())
    .borderRadius(this.cardListBorderRadius)
    .border({ width: this.cardBorderWidth, color: this.getCardItemBorder() })
    .shadow({ radius: 4, color: '#10000000', offsetX: 0, offsetY: 2 })
    .clickEffect({ level: 0, scale: 0.97 })
    .onClick(() => this.playVideo(item))
  }

  /** 网格骨架单元（A1：灰圆角块，不转圈） */
  @Builder
  skeletonCell() {
    Column() {
      Column()
        .width('100%')
        .aspectRatio(1.6)
        .borderRadius(Math.max(4, this.cardListBorderRadius - 4))
        .backgroundColor(this.skeletonBg())
      Column()
        .width('70%')
        .height(11)
        .borderRadius(5.5)
        .backgroundColor(this.skeletonBg())
        .margin({ top: 8 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 投稿空态（A1：衬线空态；加载失败给下拉重试提示） */
  @Builder
  emptyVideos() {
    Column() {
      Text(this.loadError ? '加载失败' : 'TA 还没有投稿')
        .fontFamily('serif')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.warmGray())
      Text(this.loadError ? '下拉重试' : 'NO VIDEOS YET')
        .fontFamily('monospace')
        .fontSize(9)
        .letterSpacing(2)
        .fontColor(this.muted())
        .margin({ top: 6 })
    }
    .width('100%')
    .padding({ top: 60, bottom: 60 })
    .alignItems(HorizontalAlign.Center)
  }

  /** A1 竖屏投稿列表：页眉随列表滚走 + 2 列网格 + 吸顶节标题（videoScroller 驱动替身） */
  @Builder
  videoListPortrait() {
    Refresh({ refreshing: $$this.isRefreshing, builder: this.customRefreshComponent() }) {
      List({ space: this.cardListMargin, scroller: this.videoScroller }) {
        // 顶部占位 = 状态栏高 + TitleBar 高度(56)：避让标题栏与返回按钮，内容可滑到屏幕顶才裁切
        ListItem() {
          Column().width('100%').height(this.statusBarHeight + 56)
        }
        // A1 页眉（随列表滚走）
        ListItem() {
          this.spaceHeader()
        }
        // 节标题（滚过后由吸顶替身接管；吸顶期间本行隐藏为同高占位——吸顶条已无遮罩，不隐藏会两套按钮同时可见）
        // 上下 padding 传 0：List 的 space 已提供间距，行自带会变 2 倍缝
        ListItem() {
          Column() {
            if (this.videoSticky) {
              Column().width('100%').height(this.secRowH > 0 ? this.secRowH : 36)
            } else {
              this.sectionRow(0, 0)
            }
          }
          .width('100%')
          .onAreaChange((_old: Area, now: Area) => {
            // 记录列表内节标题行实测高度（吸顶占位同高防跳动）
            const h = Number(now.height);
            if (!Number.isNaN(h) && h > 0) {
              this.secRowH = h;
            }
          })
        }
        if (!this.isListLoaded) {
          // 网格骨架：2×2 灰块
          ForEach([0, 1], (_row: number) => {
            ListItem() {
              Row() {
                this.skeletonCell()
                Column() {}.width(this.cardListMargin)
                this.skeletonCell()
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .padding({ left: this.cardListMargin, right: this.cardListMargin })
            }
          }, (row: number) => 'sk' + row.toString())
        } else if (this.videos.length === 0) {
          ListItem() {
            this.emptyVideos()
          }
        } else {
          ForEach(this.videoPairs, (pair: UpSpaceVideoItem[]) => {
            ListItem() {
              Row() {
                Column() {
                  this.gridVideoCard(pair[0])
                }
                .layoutWeight(1)
                Column() {}.width(this.cardListMargin)
                if (pair.length > 1) {
                  Column() {
                    this.gridVideoCard(pair[1])
                  }
                  .layoutWeight(1)
                } else {
                  Column().layoutWeight(1)
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .padding({ left: this.cardListMargin, right: this.cardListMargin })
            }
          }, (pair: UpSpaceVideoItem[]) => pair[0].bvid)
        }
        // ⭐ 底部留白：避免最后一项被悬浮播放按钮/系统导航遮挡
        ListItem() {
          Column().width('100%').height(30)
        }
      }
      .width('100%')
      .height('100%')
      .lanes(1)
      .edgeEffect(EdgeEffect.None)
      .cachedCount(50)
      .onReachEnd(() => this.loadMore())
      .onDidScroll((_offset: number, _state: ScrollState) => {
        // 顶 spacer 0 + 两行距 2×cardListMargin − 吸顶条顶距 6
        const y = this.videoScroller.currentOffset().yOffset;
        const sticky = y > this.headerH + 2 * this.cardListMargin - 16;
        if (sticky !== this.videoSticky) {
          this.videoSticky = sticky;
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .onRefreshing(() => { this.onRefresh(); })
  }

  /** A1 横屏投稿列表：右侧 3 列网格（节标题在右侧固定，列表自身不带头） */
  @Builder
  videoListLandscape() {
    Refresh({ refreshing: $$this.isRefreshing, builder: this.customRefreshComponent() }) {
      List({ space: this.cardListMargin }) {
        // 顶部占位 = 固定分段条高度（条高 m+胶囊+m，再让掉 List space）：列表全高，首排卡初始位置在条下方，内容可滑到屏幕顶
        ListItem() {
          Column().width('100%')
            .height(this.statusBarHeight + 56 + this.cardListMargin + (this.secRowH > 0 ? this.secRowH : 36))
        }
        if (!this.isListLoaded) {
          ForEach([0, 1], (_row: number) => {
            ListItem() {
              Row() {
                this.skeletonCell()
                Column() {}.width(this.cardListMargin)
                this.skeletonCell()
                Column() {}.width(this.cardListMargin)
                this.skeletonCell()
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
          }, (row: number) => 'sk' + row.toString())
        } else if (this.videos.length === 0) {
          ListItem() {
            this.emptyVideos()
          }
        } else {
          ForEach(this.videoTriples, (tri: UpSpaceVideoItem[]) => {
            ListItem() {
              Row() {
                Column() {
                  this.gridVideoCard(tri[0])
                }
                .layoutWeight(1)
                Column() {}.width(this.cardListMargin)
                if (tri.length > 1) {
                  Column() {
                    this.gridVideoCard(tri[1])
                  }
                  .layoutWeight(1)
                } else {
                  Column().layoutWeight(1)
                }
                Column() {}.width(this.cardListMargin)
                if (tri.length > 2) {
                  Column() {
                    this.gridVideoCard(tri[2])
                  }
                  .layoutWeight(1)
                } else {
                  Column().layoutWeight(1)
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
          }, (tri: UpSpaceVideoItem[]) => tri[0].bvid)
        }
        // ⭐ 底部留白
        ListItem() {
          Column().width('100%').height(30)
        }
      }
      .width('100%')
      .height('100%')
      .lanes(1)
      .edgeEffect(EdgeEffect.None)
      .cachedCount(50)
      .padding({ left: this.cardListMargin, right: this.cardListMargin })
      .onReachEnd(() => this.loadMore())
    }
    .width('100%')
    .layoutWeight(1)
    .onRefreshing(() => { this.onRefresh(); })
  }

  // ── 动态卡片渲染 ──

  /** 动态：视频类型（上图下文全宽封面：封面占满整行、2:1 比例 + 标题与统计在下方） */
  @Builder
  dynVideoCard(item: SpaceDynamicItem) {
    Column() {
      if (item.text) {
        this.dynTextSegmentsBuilder(item, false, 12)
      }
      if (item.video) {
        Column() {
          Stack({ alignContent: Alignment.BottomStart }) {
            Image(item.video.cover)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .borderRadius(this.cardListBorderRadius)
              .backgroundColor('#E8E8E8')
            Row({ space: 8 }) {
              if (item.video.durationText) {
                Text(item.video.durationText)
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#B0000000')
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(4)
              }
              Text(`${fmtN(item.video.play)}播放`)
                .fontSize(12).fontColor('#FFFFFF')
                .fontWeight(FontWeight.Bold)
                .textShadow({ radius: 2, color: '#99000000', offsetX: 0, offsetY: 1 })
                .padding({ bottom: 2 })
              Text(`${fmtN(item.video.danmaku)}弹幕`)
                .fontSize(12).fontColor('#FFFFFF')
                .fontWeight(FontWeight.Bold)
                .textShadow({ radius: 2, color: '#99000000', offsetX: 0, offsetY: 1 })
                .padding({ bottom: 2 })
              Blank()
              Image($r('app.media.tvdasd'))
                .width(54).height(54)
                .fillColor('#FFFFFF')
                .opacity(0.7)
                .margin({ right: 8 })
            }
            .width('100%')
            .align(Alignment.BottomStart)
            .padding({ left: 14, right: 8, bottom: 4 })
            .alignItems(VerticalAlign.Bottom)
          }
          .width('100%')
          .aspectRatio(2 / 1)
          // 标题（最多 2 行）
          Text(item.video.title)
            .fontSize(13)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(18)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 12 })
          // 统计：点赞/转发/评论胶囊（与外层其他卡片统计行同款样式）
          Row({ space: 16 }) {
            Row({ space: 4 }) {
              Image($r('app.media.give_the_thumbs_up'))
                .width(16).height(16)
                .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              Text(fmtN(item.likeCount)).fontSize(11).fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
            }
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(16)
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)')
            .alignItems(VerticalAlign.Center)
            Row({ space: 4 }) {
              Image($r('app.media.share_zf'))
                .width(16).height(16)
                .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              Text(fmtN(item.forwardCount)).fontSize(11).fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
            }
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(16)
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)')
            .alignItems(VerticalAlign.Center)
            Row({ space: 4 }) {
              Image($r('app.media.message_on_message'))
                .width(16).height(16)
                .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              Text(fmtN(item.commentCount)).fontSize(11).fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
            }
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(16)
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)')
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 12 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .onClick(() => { this.playDynVideo(item.video); })
      }
    }
    .width('100%')
  }

  /** 动态：图文类型（单图原比例完整显示/超长图 3:4；多图 2/4 张两列、其余三列九宫格） */
  @Builder
  dynDrawCard(item: SpaceDynamicItem) {
    Column() {
      if (item.text) {
        this.dynTextSegmentsBuilder(item, false, 12)
      }
      if (item.images.length === 1) {
        // ⭐ 单图：普通图原比例完整显示；超长图（高/宽 > 16:9）用 3:4 竖版 + 顶部对齐 + 底部「长图」胶囊
        Stack() {
          Image(resizeImageUrl(item.images[0].src, 800))
            .width('100%')
            .aspectRatio(this.originalImageAspectRatio(item.images[0]))
            .objectFit(ImageFit.Cover)
            .backgroundColor('#E8E8E8')
          if (this.isTallImage(item.images[0])) {
            Column() {
              Blank()
              this.tallImageBadge()
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.Center)
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .width('100%')
        .aspectRatio(this.singleImageAspectRatio(item.images[0]))
        .alignContent(Alignment.Top)
        .borderRadius(this.cardListBorderRadius)
        .clip(true)
        .id(`dyn_thumb_${item.images[0].src}`)
        .onClick(() => { this.openImagePreview(item.images, item.images[0].src, `dyn_thumb_${item.images[0].src}`); })
      } else if (item.images.length > 1) {
        // ⭐ 多图：2/4 张每行 2 个；其余每行 3 个（最多 9 张）；四角单圆角 + 右下 +N 胶囊
        Column() {
          ForEach(this.chunkImages(item.images), (row: DynImageInfo[], rowIndex: number) => {
            Row({ space: 6 }) {
              ForEach(row, (img: DynImageInfo, colIndex: number) => {
                Image(resizeImageUrl(img.src, 400))
                  .layoutWeight(1)
                  .aspectRatio(1)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(this.gridCornerRadius(this.chunkImages(item.images), rowIndex, colIndex))
                  .backgroundColor('#E8E8E8')
                  .overlay(this.overflowBadgeIfNeeded(item.images.length, this.chunkImages(item.images), rowIndex, colIndex), { align: Alignment.Bottom })
                  .id(`dyn_thumb_${img.src}`)
                  .onClick(() => { this.openImagePreview(item.images, img.src, `dyn_thumb_${img.src}`); })
              }, (img: DynImageInfo, colIndex: number) => `img_${img.src}_${colIndex}`)
            }
            .width('100%')
            .margin({ bottom: rowIndex < this.chunkImages(item.images).length - 1 ? 6 : 0 })
          }, (row: DynImageInfo[]) => row[0].src)
        }
        .width('100%')
      }
    }
    .width('100%')
  }

  /** 动态：纯文本类型 */
  @Builder
  dynTextCard(item: SpaceDynamicItem) {
    Column() {
      this.dynTextSegmentsBuilder(item, false, 0)
    }
    .width('100%')
  }

  /** 动态：转发类型（显示转发源摘要） */
  @Builder
  dynForwardCard(item: SpaceDynamicItem) {
    Column() {
      if (item.text) {
        this.dynTextSegmentsBuilder(item, false, 8)
      }
      if (item.orig) {
        Row() {
          if (item.orig.video) {
            Image(item.orig.video.cover)
              .width(64).height(40)
              .objectFit(ImageFit.Cover)
              .borderRadius(6)
              .backgroundColor('#E8E8E8')
          }
          Column() {
            if (item.orig.video) {
              Text(item.orig.video.title)
                .fontSize(12)
                .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .lineHeight(17)
                .width('100%')
            } else {
              Text(item.orig.text)
                .fontSize(12)
                .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .lineHeight(17)
                .width('100%')
            }
            Text(`@${item.orig.authorName || '原动态'}`)
              .fontSize(10)
              .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
              .margin({ top: 4 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 8 })
        }
        .width('100%')
        .padding(10)
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)')
        .borderRadius(10)
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.playDynVideo(item.orig?.video ?? null); })
      }
    }
    .width('100%')
  }

  /** 动态：不支持的类型占位 */
  @Builder
  dynUnsupportedCard(item: SpaceDynamicItem) {
    Column() {
      if (item.text) {
        this.dynTextSegmentsBuilder(item, false, 8)
      }
      Text('暂不支持此动态类型')
        .fontSize(12)
        .fontColor('#999999')
        .padding({ top: 8, bottom: 8 })
    }
    .width('100%')
  }

  /** 动态卡片（按类型分发渲染，与动态页同款） */
  @Builder
  dynamicCard(item: SpaceDynamicItem) {
    // ⭐ 根 Column：仅 width + 背景 + 圆角（不含 padding，总宽 = 列宽，不会溢出）
    Column() {
      // ⭐ 内部包裹 Column：承载 padding，保证内容在卡片内
      Column() {
        // 作者行（点击进入该用户空间）
        Row() {
          Image(item.authorFace)
            .width(28).height(28)
            .borderRadius(14)
            .objectFit(ImageFit.Cover)
            .backgroundColor('#E8E8E8')
          Text(item.authorName || this.upName)
            .fontSize(12)
            .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
            .margin({ left: 8 })
            .maxLines(1)
          Blank()
          Text(fmtPubdate(item.pubTs))
            .fontSize(11)
            .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 12 })
        .onClick(() => { this.openUpSpace(item); })

        // ⭐ 按已解析字段分发（优先字段而非 type 字符串）：PGC 走竖版海报卡，视频/图文/专栏/文字/转发依次兜底
        if (item.type.startsWith('DYNAMIC_TYPE_PGC')) {
          this.dynPgcCard(item)
        } else if (item.video) {
          this.dynVideoCard(item)
        } else if (item.images.length > 0) {
          this.dynDrawCard(item)
        } else if (item.common) {
          this.dynCommonCard(item)
        } else if (item.type === DYN_TYPE_WORD) {
          this.dynTextCard(item)
        } else if (item.type === DYN_TYPE_FORWARD) {
          this.dynForwardCard(item)
        } else if (item.text) {
          this.dynTextCard(item)
        } else {
          this.dynUnsupportedCard(item)
        }

        // 统计行（⭐ 视频卡已含播放/弹幕/点赞/转发/评论，不再重复显示外层统计行）
        if (!item.video) {
          Row({ space: 16 }) {
            Row({ space: 4 }) {
              Image($r('app.media.give_the_thumbs_up'))
                .width(16).height(16)
                .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              Text(fmtN(item.likeCount)).fontSize(11).fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
            }
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(16)
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)')
            .alignItems(VerticalAlign.Center)
            Row({ space: 4 }) {
              Image($r('app.media.share_zf'))
                .width(16).height(16)
                .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              Text(fmtN(item.forwardCount)).fontSize(11).fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
            }
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(16)
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)')
            .alignItems(VerticalAlign.Center)
            Row({ space: 4 }) {
              Image($r('app.media.message_on_message'))
                .width(16).height(16)
                .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              Text(fmtN(item.commentCount)).fontSize(11).fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
            }
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(16)
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)')
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 14 })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    }
    .width('100%')
    .backgroundColor(this.getCardItemBg())
    .borderRadius(this.cardListBorderRadius)
    .border({ width: this.cardBorderWidth, color: this.getCardItemBorder() })
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 2 })
    .clickEffect({ level: 0, scale: 0.95 })
    // ⭐ 点卡片任意位置 → 动态详情页（与动态页一致；本页原先**完全没有**进详情页的入口）
    .onClick(() => { this.openDynDetail(item); })
  }

  /** ⭐ 动态正文分段渲染：普通文字 / B 站表情图 / #话题# 胶囊 / @某人 高亮（动态页同款，后两者可点击） */
  @Builder
  dynTextSegmentsBuilder(item: SpaceDynamicItem, isCenter: boolean, bottomMargin: number) {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, justifyContent: isCenter ? FlexAlign.Center : FlexAlign.Start }) {
      ForEach(item.textSegments, (seg: DynTextSegment, index: number) => {
        if (seg.emoteUrl) {
          Image(seg.emoteUrl)
            .width(20)
            .height(20)
            .margin({ left: 2, right: 2 })
            .objectFit(ImageFit.Contain)
        } else if (seg.kind === 'topic') {
          // ⭐ #话题# → 胶囊（主题色文字 + 主题色 16% 底）：点击进搜索
          // ⭐ 与 DynamicTextContent 同步收紧（12 号字 + 行高 16 + 上下 padding 1 = 胶囊仅 18vp）：
          //    胶囊过高时换行行距不够、相邻两行互相压住；上下 margin 2 让行间留出 4vp 间隙
          Text(seg.text)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.customThemeColor)
            .lineHeight(16)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .margin({ left: 2, right: 2, top: 2, bottom: 2 })
            .borderRadius(5)
            .backgroundColor('#' + this.opacityToHexAlpha(16) + this.customThemeColor.slice(1))
            .clickEffect({ level: 0, scale: 0.95 })
            .onClick(() => { this.openTopicTag(seg.text); })
        } else if (seg.kind === 'at') {
          // ⭐ @某人 → 主题色 + Medium（不加底色，与话题胶囊区分）：点击进 TA 的空间
          Text(seg.text)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.customThemeColor)
            .lineHeight(20)
            .textAlign(isCenter ? TextAlign.Center : TextAlign.Start)
            .clickEffect({ level: 0, scale: 0.95 })
            .onClick(() => { this.openMentionedUp(seg); })
        } else {
          Text(seg.text)
            .fontSize(14)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            .lineHeight(20)
            .textAlign(isCenter ? TextAlign.Center : TextAlign.Start)
        }
      }, (seg: DynTextSegment, index: number) => `dseg_${index}`)
    }
    .width('100%')
    .margin({ bottom: bottomMargin })
  }

  /** ⭐ 点击正文 #话题#：本工程无话题详情页，带关键词进搜索页（与动态页同一入口，两页各留一份） */
  private openTopicTag(topicText: string): void {
    let kw: string = topicText;
    if (kw.startsWith('#')) kw = kw.substring(1);
    if (kw.endsWith('#')) kw = kw.substring(0, kw.length - 1);
    kw = kw.trim();
    if (!kw) return;
    this.getUIContext().getRouter().pushUrl({ url: 'pages/SearchPage', params: { keyword: kw } }).catch(() => {});
  }

  /** ⭐ 点击正文 @某人：进 TA 的空间（mid 来自富文本节点 rid） */
  private openMentionedUp(seg: DynTextSegment): void {
    const mid: number = seg.mid ?? 0;
    if (mid <= 0) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开该用户主页', duration: 1500 });
      return;
    }
    let name: string = seg.text ?? '';
    if (name.startsWith('@')) name = name.substring(1);
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UpSpacePage',
      params: { mid: mid, upName: name, upFace: '' }
    }).catch(() => {});
  }

  /** 动态：专栏/通用卡片类型（majorType=COMMON，如专栏文章；点击打开跳转链接） */
  @Builder
  dynCommonCard(item: SpaceDynamicItem) {
    Column() {
      if (item.text) {
        this.dynTextSegmentsBuilder(item, false, 8)
      }
      if (item.common) {
        Row() {
          if (item.common.cover) {
            Image(item.common.cover)
              .width(84).height(56)
              .objectFit(ImageFit.Cover)
              .borderRadius(6)
              .backgroundColor('#E8E8E8')
          }
          Column() {
            Text(item.common.title)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .lineHeight(18)
              .width('100%')
            if (item.common.desc) {
              Text(item.common.desc)
                .fontSize(11)
                .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .lineHeight(15)
                .width('100%')
                .margin({ top: 3 })
            }
          }
          .layoutWeight(1)
          .margin({ left: 8 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .borderRadius(8)
        .backgroundColor(this.isDarkMode ? '#2A2A2A' : '#F5F6F7')
        .padding({ left: 10, right: 10 })
        // ⭐ 仅展示卡片（jumpUrl 为外部 http 链接，pushUrl 仅接受应用内路由，暂不跳转）
      }
    }
    .width('100%')
  }

  /** 番剧卡封面（数据源兼容：番剧 majorType=ARCHIVE 时只有 video，common 为 null 时用 video 兜底） */
  private pgcCoverOf(item: SpaceDynamicItem): string {
    return (item.common?.cover ?? item.video?.cover) ?? '';
  }

  /** 番剧卡标题（video 兜底） */
  private pgcTitleOf(item: SpaceDynamicItem): string {
    return (item.common?.title ?? item.video?.title) ?? '';
  }

  /** 番剧卡描述（video 兜底） */
  private pgcDescOf(item: SpaceDynamicItem): string {
    return (item.common?.desc ?? item.video?.desc) ?? '';
  }

  /** 动态：番剧/影视卡片（DYNAMIC_TYPE_PGC，竖版海报适配番剧封面） */
  @Builder
  dynPgcCard(item: SpaceDynamicItem) {
    Column() {
      if (item.text) {
        this.dynTextSegmentsBuilder(item, false, 8)
      }
      if (this.pgcCoverOf(item) || this.pgcTitleOf(item)) {
        // ---- 横版封面（16:9，动态页卡片统一横版比例）----
        Stack({ alignContent: Alignment.BottomStart }) {
          Image(this.pgcCoverOf(item))
            .width('100%')
            .aspectRatio(16 / 9)
            .objectFit(ImageFit.Cover)
            .backgroundColor(this.isDarkMode ? '#333333' : '#E8E8E8')
            .borderRadius(this.cardListBorderRadius)

          // 底部渐变遮罩
          Row()
            .width('100%')
            .height(30)
            .position({ bottom: 0 })
            .linearGradient({
              direction: GradientDirection.Bottom,
              colors: [['#00000000', 0], ['#66000000', 1]]
            })

          // ⭐ 播放图标：tvdasd（与视频投稿卡同款），封面右下角，70% 不透明
          Image($r('app.media.tvdasd'))
            .width(54)
            .height(54)
            .fillColor(Color.White)
            .opacity(0.7)
            .position({ bottom: 8, right: 8 })
        }
        .width('100%')
        .borderRadius(this.cardListBorderRadius)
        .clip(true)

        // ---- 标题 ----
        Text(this.pgcTitleOf(item))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(20)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 8, left: 2, right: 2 })

        // ---- 描述 ----
        if (this.pgcDescOf(item)) {
          Text(this.pgcDescOf(item))
            .fontSize(12)
            .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(17)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 4, left: 2, right: 2 })
        }
      }
    }
    .width('100%')
    .padding(8)
    .backgroundColor(this.getCardItemBg())
    .borderRadius(this.cardListBorderRadius)
    .border({ width: this.cardBorderWidth, color: this.getCardItemBorder() })
    .clip(true)
    .shadow({ radius: 4, color: '#10000000', offsetY: 2 })
    .onClick(() => { this.openPgcLink(item); })
  }

  /** 提取字符串开头的连续数字（用于解析 jumpUrl 中的 id），无数字返回 0 */
  private parseLeadingNumber(s: string): number {
    let num: number = 0;
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c >= 48 && c <= 57) {
        num = num * 10 + (c - 48);
      } else {
        break;
      }
    }
    return num;
  }

  /** 点击番剧卡：优先用解析保留的 seasonId/epId，其次从 jumpUrl 解析，应用内跳转 VideoPlayerPage 播放 */
  private openPgcLink(item: SpaceDynamicItem): void {
    let seasonId: number = item.common?.seasonId ?? 0;
    let epId: number = item.common?.epId ?? 0;
    const url = item.common?.jumpUrl ?? '';
    if (seasonId <= 0) {
      const ssIdx = url.indexOf('/ss');
      if (ssIdx >= 0) {
        seasonId = this.parseLeadingNumber(url.substring(ssIdx + 3));
      }
    }
    if (epId <= 0) {
      const epIdx = url.indexOf('/ep');
      if (epIdx >= 0) {
        epId = this.parseLeadingNumber(url.substring(epIdx + 3));
      }
    }
    if (seasonId <= 0 && epId <= 0) {
      this.getUIContext().getPromptAction().showToast({ message: '暂无详情链接', duration: 1500 });
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/VideoPlayerPage',
      params: {
        mediaId: seasonId > 0 ? seasonId : 0,
        epId: epId,
        title: item.common?.title ?? '',
      }
    }).catch((err: Error) => {
      logWarn(`[UpSpacePage] 跳转番剧失败: ${err}`);
    });
  }

  /**
   * ⭐ 打开动态详情页（正文不截断 + 看评论），与动态页 openDynDetail 同款。
   * 把整条 item 当 preload 传过去：详情页先渲染，再后台拉 `feed/detail` 校正数据（避免白屏）。
   * ⚠️ 本页原先**根本没有**这个入口 —— UP 空间页的动态卡片点哪儿都进不去详情页
   *    （内部各分支既没挂 onTapSelf，也没有跳转方法），用户报"有些卡片点击后打不开"就包括这里。
   */
  private openDynDetail(item: SpaceDynamicItem): void {
    if (!item.idStr) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开该动态', duration: 1500 });
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/DynamicDetailPage',
      params: { dynIdStr: item.idStr, preload: item }
    }).catch(() => {});
  }

  /** 点击作者行 → 打开该作者的空间 */
  private openUpSpace(item: SpaceDynamicItem): void {
    if (!item.authorName) return;
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UpSpacePage',
      params: {
        mid: item.authorMid,
        upName: item.authorName,
        upFace: item.authorFace
      }
    });
  }

  // ── 图片网格辅助（与动态页同款）──

  /** 最大显示数量：5 张显示 4；7/8 张显示 6；其余按 9 张（3×3） */
  private maxDisplayCount(count: number): number {
    let maxCount: number = count;
    if (count === 5) {
      maxCount = 4;
    } else if (count === 7 || count === 8) {
      maxCount = 6;
    }
    return maxCount;
  }

  /** 将图片列表按行分组：2/4 张 → 每行 2 个（4 张为 2×2）；其余 → 每行 3 个（最多 9 张 = 3×3） */
  private chunkImages(images: DynImageInfo[]): DynImageInfo[][] {
    const rows: DynImageInfo[][] = [];
    const maxCount: number = this.maxDisplayCount(images.length);
    const cols: number = (maxCount === 2 || maxCount === 4) ? 2 : 3;
    for (let i: number = 0; i < maxCount; i += cols) {
      const row: DynImageInfo[] = [];
      for (let j: number = i; j < Math.min(i + cols, maxCount); j++) {
        row.push(images[j]);
      }
      rows.push(row);
    }
    return rows;
  }

  /** 多图网格四角单圆角：左上/右上/左下/右下用卡片圆角，内部小圆角 4 */
  private gridCornerRadius(rows: DynImageInfo[][], rowIndex: number, colIndex: number): DynCornerRadius {
    const r: number = this.cardListBorderRadius;
    const rowCount: number = rows.length;
    const rowLen: number = rows[rowIndex].length;
    const corner: DynCornerRadius = {};
    const isRowLast: boolean = colIndex === rowLen - 1;
    const isLastRow: boolean = rowIndex === rowCount - 1;
    const nextRowHasCol: boolean = rowIndex + 1 < rowCount && rows[rowIndex + 1].length > colIndex;
    const isBottomRight: boolean = isRowLast && (isLastRow || !nextRowHasCol);
    const isCornerCell: boolean = (rowIndex === 0 && colIndex === 0) ||
      (rowIndex === 0 && colIndex === rowLen - 1) ||
      (rowIndex === rowCount - 1 && colIndex === 0) || isBottomRight;
    if (isCornerCell) {
      corner.topLeft = (rowIndex === 0 && colIndex === 0) ? r : 4;
      corner.topRight = (rowIndex === 0 && colIndex === rowLen - 1) ? r : 4;
      corner.bottomLeft = (rowIndex === rowCount - 1 && colIndex === 0) ? r : 4;
      corner.bottomRight = isBottomRight ? r : 4;
    } else {
      const small: number = 4;
      corner.topLeft = small;
      corner.topRight = small;
      corner.bottomLeft = small;
      corner.bottomRight = small;
    }
    return corner;
  }

  /** 是否为超长图（高/宽 > 16:9）：单图时用 3:4 竖版展示并显示「长图」标识 */
  private isTallImage(img: DynImageInfo): boolean {
    return img.width > 0 && img.height > 0 && img.height / img.width > 16 / 9;
  }

  /** 原图宽高比（宽/高）：超长图按原比例撑高后，由外层容器裁剪出顶部区域 */
  private originalImageAspectRatio(img: DynImageInfo): number {
    if (img.width > 0 && img.height > 0) {
      return img.width / img.height;
    }
    return 1;
  }

  /** 单图宽高比：普通图按原比例完整显示；超长图（高/宽 > 16:9）用 3:4 竖版展示 */
  private singleImageAspectRatio(img: DynImageInfo): number {
    if (this.isTallImage(img)) {
      return 3 / 4;
    }
    if (img.width > 0 && img.height > 0) {
      return img.width / img.height;
    }
    return 16 / 9;
  }

  /** 超长图「长图」标识：底部居中半透明胶囊（点击穿透到图片，避免拦截展开预览） */
  @Builder
  tallImageBadge() {
    Text('长图')
      .fontSize(13)
      .fontColor('#FFFFFF')
      .fontWeight(FontWeight.Medium)
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor('rgba(0,0,0,0.45)')
      .margin({ bottom: 10 })
      .align(Alignment.Bottom)
      .hitTestBehavior(HitTestMode.None)
  }

  /** 超出数量 +N 胶囊：最右下角图片叠加显示（与「长图」胶囊同尺寸，白字） */
  @Builder
  overflowBadge(count: number) {
    Text('+' + count.toString())
      .fontSize(13)
      .fontColor('#FFFFFF')
      .fontWeight(FontWeight.Medium)
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor('rgba(0,0,0,0.45)')
      .margin({ bottom: 10 })
  }

  /** 图片超出显示数量（原图数 - 显示数），>0 时需要在最右下角叠加 +N */
  private overflowCount(total: number): number {
    return total - this.maxDisplayCount(total);
  }

  /** 是否应在该图叠加 +N 胶囊：图片超出显示数量，且该图是网格最右下角 */
  private shouldShowOverflowBadge(total: number, rows: DynImageInfo[][], rowIndex: number, colIndex: number): boolean {
    if (this.overflowCount(total) <= 0) return false;
    return rowIndex === rows.length - 1 && colIndex === rows[rowIndex].length - 1;
  }

  /** 仅当图片超出显示数量时，在最右下角图片上叠加 +N 胶囊 */
  @Builder
  overflowBadgeIfNeeded(total: number, rows: DynImageInfo[][], rowIndex: number, colIndex: number) {
    if (this.shouldShowOverflowBadge(total, rows, rowIndex, colIndex)) {
      this.overflowBadge(this.overflowCount(total))
    }
  }

  /** 点击图文图片：打开全屏预览（压缩图，左右滑动切换；预览 UI 由通用 FullImagePreview 组件渲染） */
  private openImagePreview(images: DynImageInfo[], src: string, thumbId: string): void {
    if (images.length === 0) return;
    let idx = -1;
    for (let i = 0; i < images.length; i++) {
      if (images[i].src === src) {
        idx = i;
        break;
      }
    }
    const urls: string[] = [];
    const thumbIds: string[] = [];
    for (const img of images) {
      urls.push(resizeImageUrl(img.src, 1600));
      thumbIds.push(`dyn_thumb_${img.src}`);
    }
    this.previewImageUrls = urls;
    this.previewThumbIds = thumbIds;
    this.previewIndex = idx >= 0 ? idx : 0;
    this.captureThumbRect(thumbId);
    this.showPreview = true;
  }

  /** 通过组件 id 获取缩略图相对窗口矩形并转 vp；失败时置 0（退回中心缩放） */
  private captureThumbRect(thumbId: string): void {
    try {
      const info = this.getUIContext().getComponentUtils().getRectangleById(thumbId);
      this.previewOriginX = this.getUIContext().px2vp(info.windowOffset.x);
      this.previewOriginY = this.getUIContext().px2vp(info.windowOffset.y);
      this.previewOriginW = this.getUIContext().px2vp(info.size.width);
      this.previewOriginH = this.getUIContext().px2vp(info.size.height);
    } catch (e) {
      this.previewOriginX = 0;
      this.previewOriginY = 0;
      this.previewOriginW = 0;
      this.previewOriginH = 0;
    }
  }

  /** ⭐ 动态卡片背景（与动态页/首页卡片样式一致） */
  private getCardItemBg(): string {
    if (this.cardTransparentStyle) {
      return this.isDarkMode
        ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
        : `rgba(255,255,255,${this.cardBgOpacity / 100})`;
    }
    return this.isDarkMode ? '#2C2C2C' : '#E8E8E8';
  }

  /** ⭐ 动态卡片边框色（与动态页/首页卡片样式一致） */
  private getCardItemBorder(): string {
    if (!this.cardTransparentStyle) {
      return 'rgba(0,0,0,0)';
    }
    if (this.cardBorderFollowTheme) {
      return '#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1);
    }
    return this.isDarkMode
      ? `rgba(255,255,255,${this.cardBorderOpacity / 100})`
      : 'rgba(255,255,255,0.25)';
  }

  /** 透明度(0-100) → 两位十六进制 */
  private opacityToHexAlpha(opacity: number): string {
    const val = Math.round(opacity / 100 * 255);
    return val.toString(16).padStart(2, '0');
  }

  // ── A1 色彩 token（纸面编辑风；明暗双模式）──
  /** 纸面底（默认壁纸分支） */
  private paperBg(): string { return this.isDarkMode ? '#171512' : '#FAF9F6'; }
  /** 主墨色 */
  private ink(): string { return this.isDarkMode ? '#EAE5DC' : '#232323'; }
  /** 次墨色（卡片标题/图标） */
  private inkSoft(): string { return this.isDarkMode ? '#C9C2B6' : '#3A3630'; }
  /** 暖灰正文（签名） */
  private warmGray(): string { return this.isDarkMode ? '#A8A298' : '#5C574E'; }
  /** 弱提示（mono 标签/数据标签） */
  private muted(): string { return this.isDarkMode ? '#8A8478' : '#A0988C'; }
  /** 标准 hairline */
  private hairline(): string { return this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.07)'; }
  /** 更弱 hairline（数据条分隔/rail 数据行） */
  private hairlineSoft(): string { return this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)'; }
  /** 图标钮/胶囊槽底 */
  private iconBtnBg(): string { return this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)'; }
  /** 骨架灰块 */
  private skeletonBg(): string { return this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)'; }

  /**
   * 动态列表（含加载态、下拉刷新、触底加载）
   * A1：竖屏 = 浮丸留白 + 页眉（随列表滚走）+ 02 节标题（dynScroller 驱动吸顶替身）；
   *     横屏 = 纯列表（页眉在左 rail，节标题在右侧固定行）
   */
  @Builder
  dynamicList() {
    Refresh({ refreshing: $$this.isRefreshing, builder: this.customRefreshComponent() }) {
      List({ space: this.cardListMargin, scroller: this.dynScroller }) {
        if (!this.isLandscape) {
          // 顶部占位 = 状态栏高 + TitleBar 高度(56)：避让标题栏与返回按钮，内容可滑到屏幕顶才裁切
          ListItem() {
            Column().width('100%').height(this.statusBarHeight + 56)
          }
          // A1 页眉（随列表滚走）
          ListItem() {
            this.spaceHeader()
          }
          // 节标题（滚过后由吸顶替身接管；吸顶期间本行隐藏为同高占位——吸顶条已无遮罩，不隐藏会两套按钮同时可见）
          // 上下 padding 传 0：List 的 space 已提供间距，行自带会变 2 倍缝
          ListItem() {
            Column() {
              if (this.dynSticky) {
                Column().width('100%').height(this.secRowH > 0 ? this.secRowH : 36)
              } else {
                this.sectionRow(0, 0)
              }
            }
            .width('100%')
            .onAreaChange((_old: Area, now: Area) => {
              const h = Number(now.height);
              if (!Number.isNaN(h) && h > 0) {
                this.secRowH = h;
              }
            })
          }
        } else {
          // 横屏：顶部占位 = 固定分段条高度（列表全高，首排卡初始位置在条下方）
          ListItem() {
            Column().width('100%')
              .height(this.statusBarHeight + 56 + this.cardListMargin + (this.secRowH > 0 ? this.secRowH : 36))
          }
        }
        if (!this.isDynLoaded) {
          ListItem() {
            Column() {
              LoadingProgress().width(28).height(28).color(this.customThemeColor)
              Text('加载动态中...').fontSize(13).fontColor(this.muted()).margin({ top: 10 })
            }
            .width('100%').padding({ top: 80, bottom: 40 })
          }
        } else if (this.dynamics.length === 0) {
          ListItem() {
            Text('暂无动态，或登录后可查看完整动态')
              .fontSize(13).fontColor(this.muted())
              .width('100%').textAlign(TextAlign.Center)
              .padding({ top: 80, bottom: 40 })
          }
        } else {
          ForEach(this.dynamics, (item: SpaceDynamicItem) => {
            ListItem() {
              Column() {
                this.dynamicCard(item)
              }
              .padding({ left: this.cardListMargin, right: this.cardListMargin })
            }
          }, (item: SpaceDynamicItem) => item.idStr)
        }
        // ⭐ 底部留白：避免最后一项被悬浮播放按钮/系统导航遮挡
        ListItem() {
          Column().width('100%').height(30)
        }
      }
      .width('100%')
      .height('100%')
      .lanes(1)
      .edgeEffect(EdgeEffect.None)
      .cachedCount(50)
      .onReachEnd(() => this.loadMoreDynamics())
      .onDidScroll((_offset: number, _state: ScrollState) => {
        if (this.isLandscape) {
          return;
        }
        const y = this.dynScroller.currentOffset().yOffset;
        const sticky = y > this.headerH + 2 * this.cardListMargin - 16;
        if (sticky !== this.dynSticky) {
          this.dynSticky = sticky;
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .onRefreshing(() => { this.onRefresh(); })
  }
}

