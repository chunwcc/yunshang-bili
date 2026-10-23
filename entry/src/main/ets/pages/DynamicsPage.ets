// DynamicsPage.ets — 首页关注动态流页
// 数据源：x/polymer/web-dynamic/v1/feed/all（需登录）
// 布局：标题胶囊（仿首页）+ 左侧动态流 + 右侧 UP 面板（仿 PiliPlus rightFixed）
import { logInfo, logWarn, logError } from '../utils/Logger';
import { getHomeDynamics, getLastHomeDynErrorMsg, getDynUpList, SpaceDynamicItem, DynVideoInfo, DynImageInfo, DynUpItem, DynTextSegment, prefetchVideoDetail, setDynamicLike, CommentLikeResult } from '../api/BilibiliApi';
import { hdsMaterial, HdsTabs } from '@kit.UIDesignKit';
import { display, mediaquery, curves, promptAction } from '@kit.ArkUI';
import { HdsMiniBarButton } from '../components/infra/HdsMiniBarButton';
import { FullImagePreview } from '../components/FullImagePreview';
import { DynLikePill } from '../components/DynLikePill';
import { DynamicCardBody } from '../components/DynamicCardBody';
import { DynamicTextContent } from '../components/DynamicTextContent';
import { ObservableDynLike } from '../model/ObservableDynLike';
import { fmtCount } from '../utils/NumberFormat';
import { cardItemBg, cardItemBorder } from '../utils/CardStyle';
import { fmtRelativeTime } from '../utils/TimeFormat';
import { themeRgba } from '../utils/ThemeColor';
import { resizeImageUrl as resizeImageUrlShared } from '../utils/ImageUrl';

/**
 * 图片 URL 追加压缩参数（实现在 utils/ImageUrl.ets，详情页等共用同一份策略）
 * ⚠️ 具体坑（为什么不能见 '@' 就跳过压缩）见 utils/ImageUrl.ets 注释
 */
function resizeImageUrl(url: string, width: number): string {
  return resizeImageUrlShared(url, width);
}

/** 动态类型常量（分发按已解析字段优先，仅 WORD/FORWARD 需要字符串判断） */
const DYN_TYPE_FORWARD: string = 'DYNAMIC_TYPE_FORWARD';
const DYN_TYPE_WORD: string = 'DYNAMIC_TYPE_WORD';

/** 类型筛选选项（仿 PiliPlus DynamicsTabType） */
interface DynFilterOption {
  type: string;
  label: string;
  icon: Resource;
}

/** 多图网格单图角圆角：仅四角图加对应角（左上 topLeft / 右上 topRight / 左下 bottomLeft / 右下 bottomRight） */
interface DynCornerRadius {
  topLeft?: number;
  topRight?: number;
  bottomLeft?: number;
  bottomRight?: number;
}

const DYN_FILTERS: DynFilterOption[] = [
  { type: 'all', label: '全部', icon: $r('app.media.house') },
  { type: 'video', label: '投稿', icon: $r('app.media.post_job') },
  { type: 'pgc', label: '番剧', icon: $r('app.media.tvo_old') },
  { type: 'article', label: '专栏', icon: $r('app.media.form') },
  { type: 'up', label: 'UP', icon: $r('app.media.media_center') }
];

/**
 * ⭐ 动态流首屏缓存条目：键 = `分类_UPmid`。
 * 左侧导轨点 UP、顶部胶囊切分类都属于"手动高频来回切"，每次都发请求既慢又浪费配额，
 * 所以首屏数据落地后缓存 3 分钟，来回点时直接渲染（下拉刷新不走缓存，永远是新的）。
 */
interface DynFeedCacheEntry {
  items: SpaceDynamicItem[];
  offset: string;
  hasMore: boolean;
  ts: number;
}
const DYN_FEED_CACHE_TTL_MS = 3 * 60 * 1000;
/** 缓存条数上限（每条约 10~20 条动态数据，超了淘汰最旧一条） */
const DYN_FEED_CACHE_MAX = 8;

/** 格式化计数：万单位（实现在 utils/NumberFormat.ets，点赞胶囊组件共用同一份） */
function fmtN(n: number): string {
  return fmtCount(n);
}

/** 格式化发布时间戳 → 相对时间（实现在 utils/TimeFormat.ets，详情页共用同一份） */
function fmtPubdate(ts: number): string {
  return fmtRelativeTime(ts);
}

@Component({ freezeWhenInactive: true })
export struct DynamicsPage {
  // 登录状态
  @State isLoggedIn: boolean = false;

  // 动态列表状态
  @State dynamics: SpaceDynamicItem[] = [];
  @State dynOffset: string = '';
  @State dynHasMore: boolean = false;
  @State dynLoading: boolean = false;
  @State isDynLoaded: boolean = false;
  @State isRefreshing: boolean = false;
  @State loadError: string = '';
  // ⭐ 待加载标志：快速切换 UP/分类时，若上一次请求未完成，先记录待重载，完成后自动加载最新筛选
  private pendingReload: boolean = false;

  /** ⭐ 动态流首屏缓存（键 = 分类_UPmid，见 DynFeedCacheEntry）：来回点 UP / 切分类秒开 */
  private dynFeedCache: Map<string, DynFeedCacheEntry> = new Map();

  // ⭐ 已读 UP mid 记录：点击 UP 清除红点后记录，防止 loadUpList 重新拉接口恢复红点
  private readUpMids: number[] = [];

  /** ⭐ 点赞在途集合：同一动态连点只发一次请求（否则计数会被来回打乱） */
  private likingIds_: Set<string> = new Set<string>();

  /**
   * ⭐ 点赞状态表（key = 动态 idStr）。
   * 必须在页面长期持有、按 id 复用同一个 ObservableDynLike 实例——@ObjectLink 靠对象身份绑定，
   * 每次 build 都 new 一个的话胶囊不会随状态刷新。
   */
  private likeStates_: Map<string, ObservableDynLike> = new Map<string, ObservableDynLike>();

  // ⭐ 去重标志：主动调用 changeIndex（selectUp/switchFilter/selectAllUp）会触发 Tabs onChange，
  //    但主动调用里已 loadDynamics，onChange 再触发会重复请求 → 置位后 onChange 跳过。
  //    配合 lastTabsIndex：仅当 index 真变化时才置位，避免标志残留误吞下一次横滑的 onChange
  private suppressNextOnChange: boolean = false;
  private lastTabsIndex: number = 0;
  // ⭐ 分类切换动画：@Watch 监听 highlightType 变化（横滑动画开始即更新，胶囊高亮即时跟随），
  //    左侧圆形按钮图标+文字缩放/淡入
  @State @Watch('onFilterTypeChange') highlightType: string = 'all'; // 仅胶囊/按钮 UI 高亮
  @State filterType: string = 'all'; // 数据渲染与加载用：横滑动画结束（onChange）才更新，避免新分类渲染旧数据
  @State selectedUpMid: number = 0;  // 0=未选（UP 段回落全部）
  @State selectedUpName: string = '';

  // ⭐ 左侧圆形按钮图标+文字切换动画状态（缩小淡出 → 弹回）
  @State btnSwitchScale: number = 1;
  @State btnSwitchOpacity: number = 1;

  // ⭐ 选中 UP 头像呼吸灯：边框透明度低频翻转（0.35 ↔ 1），定时器仅选中时运行，低负载
  @State selectedRingAlpha: number = 1;
  private breatheTimer: number = -1;

  // ⭐ 横竖屏状态（横屏时动态列表两列）
  @State isLandscape: boolean = false;
  private landscapeListener: mediaquery.MediaQueryListener | null = null;

  // ⚠️ 这里**不再**用「整页淡入」当入场动画（原 entranceOpacity/entranceScale，初值 0 / 0.85）：
  //    实测冷启动点进动态页，数据 0.45s 才到，而整页要等入场动画播完才显形 ⇒
  //    进入后的 0~0.5s 用户看到的是**上一层页面的内容透过半透明新页面显现**（截图 +275ms/+504ms 两帧
  //    都是"幽灵态"），观感上就是"先闪一下旧的内容"。
  //    现在改为：页面**首帧即不透明**（立刻显出"加载动态中"），入场观感由
  //    ①信息流卡片逐卡弹入 ②左侧 UP 栏**头像逐条瀑布弹入** 两处小动画承担。
  /** ⭐ UP 栏外壳（胶囊背景/边框）到位标志：upList 到手前透明（否则先看到一个空胶囊），到手后 200ms 淡入 */
  @State upRailReady: boolean = false;
  /** ⭐ UP 栏头像逐条瀑布弹入：与信息流 dynCardsVisible 同一套做法（数组按下标置位 + 逐条 setTimeout 错峰） */
  @State upItemVisible: boolean[] = [];

  // ⭐ 动态图文全屏预览（仿 CommentContentRenderer 方案）
  // ⚠️ @Watch 必须叠加在状态变量上（不能装饰方法）：showPreview 变化时回调 onShowPreviewChange 同步下沉状态
  @State @Watch('onShowPreviewChange') showPreview: boolean = false;
  @State previewImageUrls: string[] = [];
  @State previewIndex: number = 0;
  /** 一镜到底起点矩形（点击的缩略图相对窗口的 vp 坐标/尺寸；点击时由 getRectangleById 填充） */
  @State previewOriginX: number = 0;
  @State previewOriginY: number = 0;
  @State previewOriginW: number = 0;
  @State previewOriginH: number = 0;
  /** ⭐ 每张预览图对应的缩略图组件 id（与 previewImageUrls 对齐）：滑动切图后关闭时飞回当前图位置 */
  @State previewThumbIds: string[] = [];

  /** 打开预览时背景页面缩放（iOS 式 modal 层级感：0.95 微缩；由 @Watch 在 showPreview 变化时更新） */
  @State previewSinkScale: number = 1.0;
  /** 打开预览时背景页面下沉距离（vp） */
  @State previewSinkY: number = 0;

  /** showPreview 变化时同步背景动画状态（getter 在 ArkUI 响应式追踪中不可靠，改用 @Watch 显式更新） */
  onShowPreviewChange(_propName: string): void {
    if (this.showPreview) {
      // ⭐ 打开预览：背景放大（原为微缩 0.95 + 下沉 24vp，按用户要求改为放大 1.05）
      this.previewSinkScale = 1.05;
      this.previewSinkY = 0;
    } else {
      this.previewSinkScale = 1.0;
      this.previewSinkY = 0;
    }
  }

  // UP 面板状态
  @State upList: DynUpItem[] = [];
  @State upOffset: string = '';
  @State upHasMore: boolean = false;
  @State upLoading: boolean = false;

  // ⭐ 标题胶囊（仿首页）：常驻展开态 = 分段选择器（无需展开/收起状态）
  // 胶囊自适应尺寸：按屏幕宽收缩分段项宽/栏宽/平移量，窄屏不超屏且保持信息流视角居中
  @State capsuleItemW: number = 66;
  @State capsuleBarW: number = 370;
  @State capsuleTranslateX: number = 40;
  @State capsuleIconSize: number = 16;
  @State capsuleIconGap: number = 4;
  @State capsuleFontSize: number = 13;

  // 样式状态
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  // ⭐ 卡片样式选项（与首页一致）：卡片圆角 + 卡片间距
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  @StorageLink('cardListMargin') cardListMargin: number = 12;
  // ⚠️ 卡片样式扩展（与 WhisperPage 一致）：透明样式/背景透明度/边框
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 15;
  @StorageLink('cardCustomColor') cardCustomColor: string = '#007DFF';
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = true;
  // ⭐ 「动态页点击切换分类」（默认打开）：true = 只允许点顶部胶囊切分类，禁用左右横滑
  @StorageLink('dynFilterTapOnly') dynFilterTapOnly: boolean = true;
  // ⭐ 登录 Cookie（变化时重载动态，覆盖登录/退出场景）
  @StorageLink('biliCookie') @Watch('onCookieChange') biliCookie: string = '';
  // ⭐ 底栏重复点击刷新信号 / 回顶信号
  @StorageProp('refreshDynamicsFlag') @Watch('onRefreshDynamicsFlag') refreshDynamicsFlag: number = 0;
  @StorageProp('scrollToTopFlag') @Watch('onScrollToTopFlag') scrollToTopFlag: number = 0;

  private dynScroller: Scroller = new Scroller();
  private upScroller: Scroller = new Scroller();
  // ⭐ 横滑筛选 Tabs：5 页对应 5 个筛选类型（all/video/pgc/article/up），左右滑动切换筛选
  private dynTabsController: TabsController = new TabsController();

  // ⭐ 滑动显隐顶部分类栏：下滑隐藏、上滑显示（仿首页底栏显隐逻辑）
  @State capsuleHidden: boolean = false;
  private lastDynScrollY: number = 0;
  private readonly dynScrollThreshold: number = 10;

  // ⭐ 信息流刷新逐卡动画（仿首页 refreshData）：刷新时旧卡逐卡淡出、加载完成后新卡逐卡弹性弹入
  @State dynCardsVisible: boolean[] = [];
  @State animateDynCards: boolean = false;
  @State dynBulkLoading: boolean = false;
  private dynCardDelays: number[] = [];
  private dynCardTranslateYs: number[] = [];

  /** 登录状态变化 → 重载动态（登录后自动加载，退出后复位） */
  private onCookieChange(): void {
    const loggedIn = this.biliCookie.includes('SESSDATA');
    if (loggedIn === this.isLoggedIn) return;
    this.isLoggedIn = loggedIn;
    // ⭐ 换了账号（或退出）→ 首屏缓存全部作废，否则会串号显示上一个账号的动态
    this.dynFeedCache.clear();
    if (loggedIn) {
      this.loadDynamics('');
      this.loadUpList('');
    } else {
      this.dynamics = [];
      this.dynOffset = '';
      this.dynHasMore = false;
      this.isDynLoaded = true;
      this.upList = [];
      this.upRailReady = false; // 退出登录：UP 栏复位，下次登录重新淡入 + 瀑布弹入
      this.upItemVisible = [];
    }
  }

  /** 底栏重复点击动态 Tab（已置顶）→ 刷新 */
  private onRefreshDynamicsFlag(): void {
    if (this.isLoggedIn && this.isDynLoaded) {
      this.onRefresh();
    }
  }

  /** 底栏重复点击动态 Tab（未置顶）→ 回顶 */
  private onScrollToTopFlag(): void {
    this.dynScroller.scrollTo({
      xOffset: 0,
      yOffset: 0,
      animation: { duration: 300, curve: Curve.EaseOut }
    });
  }

  /** ⭐ 动态信息流滚动：上报偏移 + 显隐顶部分类栏/底部栏（仿 HomePage 阈值逻辑） */
  private onDynFeedScroll(absoluteOffset: number): void {
    AppStorage.set('dynScrollOffset', absoluteOffset);
    const delta = absoluteOffset - this.lastDynScrollY;
    if (absoluteOffset < 5) {
      // 回到顶部：复位显示胶囊与底栏
      this.lastDynScrollY = 0;
      this.capsuleHidden = false;
      AppStorage.set('bottomBarHidden', false);
    } else if (delta > this.dynScrollThreshold) {
      // 下滑（内容上移）：隐藏胶囊与底栏
      this.lastDynScrollY = absoluteOffset;
      this.capsuleHidden = true;
      AppStorage.set('bottomBarHidden', true);
    } else if (delta < -this.dynScrollThreshold) {
      // 上滑（内容下移）：显示胶囊与底栏
      this.lastDynScrollY = absoluteOffset;
      this.capsuleHidden = false;
      AppStorage.set('bottomBarHidden', false);
    }
  }

  /** ⭐ 分类切换时：左侧圆形按钮图标+文字先缩小淡出、再弹回淡入（横滑/点击均经 filterType 触发） */
  private onFilterTypeChange(): void {
    this.btnSwitchScale = 0.5;
    this.btnSwitchOpacity = 0;
    setTimeout(() => {
      this.btnSwitchScale = 1;
      this.btnSwitchOpacity = 1;
    }, 80);
  }

  /** ⭐ 主题色转 rgba（呼吸灯边框用）：customThemeColor 形如 #RRGGBB */
  /** 主题色 + 透明度 → rgba()（实现在 utils/ThemeColor.ets，点赞胶囊等组件共用同一份） */
  private themeColorRgba(alpha: number): string {
    return themeRgba(this.customThemeColor, alpha);
  }

  /** ⭐ 选中 UP：启动呼吸灯（低频定时器翻转透明度，配合 .animation 平滑过渡，几乎无负载） */
  private startBreathe(): void {
    this.stopBreathe();
    this.selectedRingAlpha = 1;
    this.breatheTimer = setInterval(() => {
      this.selectedRingAlpha = this.selectedRingAlpha > 0.6 ? 0.35 : 1;
    }, 600);
  }

  /** ⭐ 停止呼吸灯（取消选中 / 离开页面时调用，避免持续空转耗电） */
  private stopBreathe(): void {
    if (this.breatheTimer !== -1) {
      clearInterval(this.breatheTimer);
      this.breatheTimer = -1;
    }
    this.selectedRingAlpha = 1;
  }

  /** 检查登录状态并加载动态 */
  private async checkLoginAndLoad(): Promise<void> {
    const cookie = AppStorage.get<string>('biliCookie') ?? '';
    this.isLoggedIn = cookie.includes('SESSDATA');
    if (this.isLoggedIn) {
      await this.loadDynamics('');
      await this.loadUpList('');
    } else {
      this.isDynLoaded = true;
    }
  }

  /** 当前生效的 type：UP 段未选具体UP时回落 all */
  private effectiveType(): string {
    if (this.filterType === 'up' && this.selectedUpMid === 0) return 'all';
    return this.filterType;
  }

  /** 当前生效的 hostMid */
  private effectiveHostMid(): number {
    if (this.filterType === 'up') return this.selectedUpMid;
    return 0;
  }

  /**
   * ⭐ 空态文案按分类区分。
   *    B站对「该分类没有内容」不会返回空列表，而是返回业务错误 4101132（"请求数据发生错误，请刷新或稍后重试"）——
   *    最典型的场景就是**没追番时切到「番剧」**（BilibiliApi.DYN_EMPTY_CODES 已把它转成空列表）。
   *    这里补一句人话，用户才知道是"没内容"而不是"加载坏了"。
   */
  private emptyFeedHint(): string {
    switch (this.effectiveType()) {
      case 'pgc':
        return '还没有追番，去追一部试试';
      case 'video':
        return '还没有关注的 UP 发布投稿';
      case 'article':
        return '还没有关注的 UP 发布专栏';
      case 'up':
        return '这位 UP 还没有动态';
      default:
        return '暂无关注动态';
    }
  }

  /** 首屏缓存键：分类 + UP mid（同为 hostMid=0 的 all/video/pgc/article 之间靠分类区分） */
  private dynFeedKey(): string {
    return `${this.effectiveType()}_${this.effectiveHostMid()}`;
  }

  /** 写入首屏缓存（超过上限淘汰最旧一条） */
  private putDynFeedCache(items: SpaceDynamicItem[], offset: string, hasMore: boolean): void {
    this.dynFeedCache.set(this.dynFeedKey(), { items: items, offset: offset, hasMore: hasMore, ts: Date.now() });
    if (this.dynFeedCache.size > DYN_FEED_CACHE_MAX) {
      let oldestKey: string = '';
      let oldestTs: number = Number.MAX_SAFE_INTEGER;
      this.dynFeedCache.forEach((v: DynFeedCacheEntry, k: string) => {
        if (v.ts < oldestTs) { oldestTs = v.ts; oldestKey = k; }
      });
      if (oldestKey) this.dynFeedCache.delete(oldestKey);
    }
  }

  /**
   * 加载动态列表（offset 为空 = 首屏/刷新）
   * @param useCache 允许命中首屏缓存（点 UP / 切分类时传 true；下拉刷新、重试一律 false，保证拿到新数据）
   */
  private async loadDynamics(offset: string, useCache: boolean = false): Promise<void> {
    if (this.dynLoading) {
      // ⭐ 上一次请求未完成（快速切换 UP/分类）：记录待重载，完成后自动加载最新筛选，
      //    避免「selectedUpMid/filterType 已更新但信息流没加载」的问题
      this.pendingReload = true;
      return;
    }
    // ⭐ 缓存命中：直接渲染，不发请求（放在 dynLoading 守卫之后，避免与在途请求的结果互相覆盖）
    if (useCache && !offset) {
      const hit = this.dynFeedCache.get(this.dynFeedKey());
      if (hit && Date.now() - hit.ts < DYN_FEED_CACHE_TTL_MS) {
        this.dynamics = hit.items;
        this.syncLikeStates();
        this.dynOffset = hit.offset;
        this.dynHasMore = hit.hasMore;
        this.loadError = '';
        this.isDynLoaded = true;
        this.setupCardEntrance();
        logInfo(`[DynamicsPage] 首屏缓存命中 ${this.dynFeedKey()}: items=${hit.items.length}`);
        return;
      }
    }
    this.dynLoading = true;
    if (!offset) {
      this.isDynLoaded = false;
    }
    try {
      const result = await getHomeDynamics(offset, this.effectiveType(), this.effectiveHostMid());
      if (result) {
        const items: SpaceDynamicItem[] = result.items;
        if (!offset) {
          this.dynamics = items;
          this.syncLikeStates();
          // ⭐ 首屏数据落地即写缓存：来回点 UP / 切分类时秒开（见 loadDynamics 的 useCache）
          this.putDynFeedCache(items, result.offset, result.hasMore);
          // ⭐ 刷新/首屏：新卡片逐卡弹性弹入（仿首页 refreshData）
          this.setupCardEntrance();
        } else {
          // ⭐ 加载更多：增量逐卡弹入——旧卡保持显示，仅新卡从透明+上移弹性弹入
          const oldLen = this.dynamics.length;
          this.dynamics = [...this.dynamics, ...items];
          this.syncLikeStates();
          const newCount = items.length;
          const newVisible = [...this.dynCardsVisible];
          for (let i = 0; i < newCount; i++) {
            newVisible.push(false);
            this.dynCardDelays.push(Math.floor(Math.random() * 400));
            this.dynCardTranslateYs.push(Math.floor(Math.random() * 30) + 10);
          }
          this.dynCardsVisible = newVisible;
          for (let i = 0; i < newCount; i++) {
            const idx = oldLen + i;
            const delay = this.dynCardDelays[this.dynCardDelays.length - newCount + i];
            setTimeout(() => {
              const v = [...this.dynCardsVisible];
              v[idx] = true;
              this.dynCardsVisible = v;
            }, delay);
          }
        }
        this.dynOffset = result.offset;
        this.dynHasMore = result.hasMore;
        this.loadError = '';
        logInfo(`[DynamicsPage] 加载动态: items=${items.length}, hasMore=${result.hasMore}, offset=${result.offset}`);
      } else {
        if (this.dynamics.length === 0) {
          // ⭐ 带上服务端原文：B站返回「请求数据发生错误，请刷新或稍后重试」这类时，
          //    用户能一眼看出是 B站侧/账号侧，而不是去怀疑客户端或网络（已内置一次重试）
          const srvMsg = getLastHomeDynErrorMsg();
          this.loadError = srvMsg ? `加载失败：${srvMsg}` : '加载失败，请检查网络或登录状态';
        } else {
          // ⭐ 刷新失败但旧数据还在：恢复旧卡显示（淡出动画不能把卡片永久隐藏）
          this.restoreCardsVisible();
        }
        logWarn('[DynamicsPage] getHomeDynamics 返回 null');
      }
    } catch (err) {
      logError(`[DynamicsPage] 加载动态异常: ${err}`);
      if (this.dynamics.length === 0) {
        this.loadError = '网络错误，请稍后重试';
      } else {
        // ⭐ 刷新失败但旧数据还在：恢复旧卡显示
        this.restoreCardsVisible();
      }
    } finally {
      this.dynLoading = false;
      this.isDynLoaded = true;
      this.isRefreshing = false;
      // ⭐ 若期间有新筛选触发：重载最新 UP/分类（等当前请求结束再发，避免并发覆盖）
      if (this.pendingReload) {
        this.pendingReload = false;
        this.loadDynamics('');
      }
    }
  }

  /** 加载关注UP列表（offset 为空 = 首屏） */
  private async loadUpList(offset: string): Promise<void> {
    if (this.upLoading) return;
    this.upLoading = true;
    try {
      const result = await getDynUpList(offset);
      if (result) {
        // ⭐ 已读的 UP 强制 hasUpdate=false：接口可能仍返回 true，本地已读记录优先
        const items: DynUpItem[] = [];
        for (const it of result.items) {
          if (this.readUpMids.includes(it.mid)) {
            const updated: DynUpItem = { mid: it.mid, uname: it.uname, face: it.face, hasUpdate: false };
            items.push(updated);
          } else {
            items.push(it);
          }
        }
        if (!offset) {
          this.upList = items;
        } else {
          this.upList = [...this.upList, ...items];
          // ⭐ 追加的项都在屏幕外：直接置为可见，不做瀑布弹入（否则滚上去时它们还在"等弹入"）
          const v: boolean[] = [...this.upItemVisible];
          for (let i = 0; i < items.length; i++) v.push(true);
          this.upItemVisible = v;
        }
        this.upOffset = result.offset;
        this.upHasMore = result.hasMore;
        // ⭐ 头像瀑布弹入：只有首屏（offset 为空）才播
        if (!offset && this.upList.length > 0) {
          this.playUpRailEntrance();
        } else if (this.upList.length > 0) {
          this.upRailReady = true; // 追加场景：外壳早已到位，这里只是兜底
        }
        logInfo(`[DynamicsPage] 加载UP列表: items=${result.items.length}, hasMore=${result.hasMore}`);
      } else {
        logWarn('[DynamicsPage] getDynUpList 返回 null');
      }
    } catch (err) {
      logError(`[DynamicsPage] 加载UP列表异常: ${err}`);
    } finally {
      this.upLoading = false;
    }
  }

  /** 切换类型筛选：重置列表并重新加载（胶囊段点击 / Tabs onChange 共用） */
  private switchFilter(type: string): void {
    if (type === 'up' && this.selectedUpMid === 0) {
      // UP 段未选中具体UP → 显示全部关注动态（回落 all）
    }
    // ⭐ 切到非 UP 分类：停止呼吸灯（不选中任何 UP）
    if (type !== 'up') {
      this.stopBreathe();
    }
    this.filterType = type;
    this.highlightType = type;
    this.dynamics = [];
    this.dynOffset = '';
    this.dynHasMore = false;
    // ⭐ 同步横滑 Tabs 页码（胶囊点击与横滑共用 switchFilter，双向一致）
    const idx = DYN_FILTERS.findIndex((f: DynFilterOption) => f.type === type);
    if (idx >= 0 && idx !== this.lastTabsIndex) {
      // ⭐ 主动 changeIndex 会触发 onChange → 又走一遍 switchFilter + loadDynamics 造成重复请求，
      //    仅 index 真变化才置位去重（避免标志残留误吞下一次横滑的 onChange）
      this.suppressNextOnChange = true;
      this.dynTabsController.changeIndex(idx);
      this.lastTabsIndex = idx;
    }
    // ⭐ 允许命中首屏缓存：胶囊切分类/横滑来回切换时秒开（下拉刷新不走缓存）
    this.loadDynamics('', true);
  }

  /** ⭐ 横滑动画开始即更新胶囊选中态（仿 HomeChannelContainer onTabsAnimationStart）：
   *  Tabs onChange 要等滑动动画结束才触发，胶囊高亮会延迟；在动画开始时就改 highlightType，标题立即跟随。
   *  注意：这里只改高亮（highlightType），不动 filterType/数据 —— 若横滑期间就改 filterType 清空数据，
   *  动画中新分类 TabContent 会渲染旧数据/空白，切换过程错乱；数据切换由 onChange → switchFilter 统一执行 */
  private onTabsAnimationStart(fromIndex: number, toIndex: number): void {
    if (fromIndex === toIndex) return;
    if (toIndex >= 0 && toIndex < DYN_FILTERS.length) {
      this.highlightType = DYN_FILTERS[toIndex].type;
    }
  }

  /** 右侧面板选择某个UP：只看该UP动态（同时清除该UP的红点） */
  private selectUp(up: DynUpItem): void {
    // ⭐ 先清除该 UP 的红点（无论是否重复点击都执行，早退不影响红点清除）
    const newList: DynUpItem[] = [];
    for (const u of this.upList) {
      if (u.mid === up.mid) {
        const updated: DynUpItem = { mid: u.mid, uname: u.uname, face: u.face, hasUpdate: false };
        newList.push(updated);
      } else {
        newList.push(u);
      }
    }
    this.upList = newList;
    // ⭐ 记录已读 UP：防止 loadUpList 重新拉接口时恢复红点
    if (!this.readUpMids.includes(up.mid)) {
      this.readUpMids.push(up.mid);
    }
    if (up.mid === this.selectedUpMid && this.filterType === 'up') return;
    this.selectedUpMid = up.mid;
    this.selectedUpName = up.uname;
    this.filterType = 'up';
    this.highlightType = 'up';
    // ⭐ 选中 UP：启动头像呼吸灯
    this.startBreathe();
    this.dynamics = [];
    this.dynOffset = '';
    this.dynHasMore = false;
    // ⭐ 同步横滑 Tabs 到 UP 页：否则 TabContent 按 filterType 条件渲染但 Tabs 停留在原页 → 信息流空白不显示
    const upIdx = DYN_FILTERS.findIndex((f: DynFilterOption) => f.type === 'up');
    if (upIdx >= 0 && upIdx !== this.lastTabsIndex) {
      // ⭐ 置位去重：changeIndex 触发的 onChange 不再重复加载（本方法末尾已 loadDynamics）
      this.suppressNextOnChange = true;
      this.dynTabsController.changeIndex(upIdx);
      this.lastTabsIndex = upIdx;
    }
    // ⭐ 允许命中首屏缓存：来回点同一个/不同的 UP 时秒开（3 分钟内），不再每次等接口+节流
    this.loadDynamics('', true);
  }

  /** 右侧面板"全部动态"：回到全部关注流 */
  private selectAllUp(): void {
    // ⭐ 取消选中：停止呼吸灯
    this.stopBreathe();
    this.selectedUpMid = 0;
    this.selectedUpName = '';
    this.filterType = 'all';
    this.highlightType = 'all';
    this.dynamics = [];
    this.dynOffset = '';
    this.dynHasMore = false;
    // ⭐ 同步横滑 Tabs 到全部页（index 0）；置位去重避免 onChange 重复加载
    if (0 !== this.lastTabsIndex) {
      this.suppressNextOnChange = true;
      this.dynTabsController.changeIndex(0);
      this.lastTabsIndex = 0;
    }
    // ⭐ 允许命中首屏缓存（回到"全部关注流"通常刚看过）
    this.loadDynamics('', true);
  }

  /** 下拉刷新：旧卡逐卡淡出（不清空数据，列表保留使淡出可见）→ 重载（新卡逐卡弹入） */
  private onRefresh(): void {
    this.isRefreshing = true;
    // ⭐ 旧卡逐卡淡出（0~300ms 随机，仿首页 refreshData 第一步）
    //    注意：不清空 dynamics —— 首页也是先逐卡置 cardsVisible=false（数据保留），
    //    等新数据返回后才替换；若立即清空，列表分支被卸载，逐卡淡出动画看不到
    const oldCount = this.dynamics.length;
    if (oldCount > 0) {
      this.animateDynCards = true;
      for (let i = 0; i < oldCount; i++) {
        const idx = i;
        const delay = Math.floor(Math.random() * 300);
        setTimeout(() => {
          const newVisible = [...this.dynCardsVisible];
          if (idx < newVisible.length) {
            newVisible[idx] = false;
            this.dynCardsVisible = newVisible;
          }
        }, delay);
      }
    }
    this.dynOffset = '';
    this.dynHasMore = false;
    this.loadDynamics('');
  }

  /** ⭐ 刷新失败：恢复旧卡片显示（避免被淡出动画永久隐藏） */
  private restoreCardsVisible(): void {
    const count = this.dynamics.length;
    this.dynCardsVisible = new Array<boolean>(count).fill(true);
    this.animateDynCards = false;
    this.dynBulkLoading = false;
  }

  /** ⭐ 新卡片逐卡弹性弹入（仿首页 refreshData：随机延迟 + 随机起始位移 + springCurve）
   *  首屏与刷新统一走逐卡弹入 —— 这是本页**唯一**的入场观感（不再有整页淡入，见状态声明处注释） */
  private setupCardEntrance(): void {
    const count = this.dynamics.length;
    this.dynCardsVisible = new Array<boolean>(count).fill(false);
    this.dynCardDelays = [];
    this.dynCardTranslateYs = [];
    for (let i = 0; i < count; i++) {
      this.dynCardDelays.push(Math.floor(Math.random() * 240));
      this.dynCardTranslateYs.push(Math.floor(Math.random() * 40) + 15);
    }
    // 逐卡弹入（首次进入与刷新一致）
    this.animateDynCards = true;
    this.dynBulkLoading = true;
    // ⭐ 数据到手后 60ms 起跳（原先为等整页淡入留 600ms 错位），最坏 0.28s 内 20 张卡全部开始弹入
    const entranceBaseDelay = 60;
    const maxDelay = entranceBaseDelay + (this.dynCardDelays.length > 0 ? Math.max(...this.dynCardDelays) : 0);
    for (let i = 0; i < count; i++) {
      const idx = i;
      setTimeout(() => {
        const newVisible = [...this.dynCardsVisible];
        newVisible[idx] = true;
        this.dynCardsVisible = newVisible;
      }, entranceBaseDelay + this.dynCardDelays[i]);
    }
    setTimeout(() => {
      this.dynBulkLoading = false;
    }, maxDelay + 1600);
  }

  /**
   * ⭐ UP 栏头像"瀑布弹入"（方案 A）：外壳先 200ms 淡入，头像自上而下逐条错峰弹出。
   * 错峰 = 60ms 起跳、每条 +70ms；只给前 11 条累加（可见区约 6 条，后面都在屏幕外，
   * 否则 50 个 UP 会变成 3.5s 的漫长队列）。做法与信息流 setupCardEntrance 一致，便于日后统一维护。
   */
  private playUpRailEntrance(): void {
    this.upRailReady = true;
    const count = this.upList.length;
    this.upItemVisible = new Array<boolean>(count).fill(false);
    for (let i = 0; i < count; i++) {
      const idx = i;
      const delay = 60 + Math.min(i, 10) * 70;
      setTimeout(() => {
        const v = [...this.upItemVisible];
        // 期间列表可能已被重载（登录态变化/切换）→ 越界就丢弃，别写坏数组
        if (idx >= v.length) return;
        v[idx] = true;
        this.upItemVisible = v;
      }, delay);
    }
  }

  /** 触底加载更多 */
  private onReachEnd(): void {
    if (this.dynHasMore && !this.dynLoading) {
      this.loadDynamics(this.dynOffset);
    }
  }

  /** UP 面板触底加载更多 */
  private onUpReachEnd(): void {
    if (this.upHasMore && !this.upLoading) {
      this.loadUpList(this.upOffset);
    }
  }

  /** 播放动态视频 */
  private playDynVideo(video: DynVideoInfo | null): void {
    if (!video || !video.bvid) {
      this.getUIContext().getPromptAction().showToast({ message: '无法播放该动态视频', duration: 1500 });
      return;
    }
    // ⭐ 预热详情（fire-and-forget）：动态卡只给 bvid，播放页要等详情里的 cid 才能起播，
    //   在转场这一刻先发出去，与转场 + 播放器 surface 初始化重叠
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

  /**
   * ⭐ 打开动态详情页（正文不截断 + 看评论）。
   * 把整条 item 当 preload 传过去：详情页先渲染，再后台拉 `feed/detail` 校正数据（避免白屏）。
   */
  private openDynDetail(item: SpaceDynamicItem): void {
    if (!item.idStr) {
      promptAction.showToast({ message: '无法打开该动态', duration: 1500 });
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/DynamicDetailPage',
      params: { dynIdStr: item.idStr, preload: item }
    }).catch(() => {});
  }

  /** ⭐ 打开转发源（原文）的详情页；原文没有 idStr 时退回播放原文视频 */
  private openOrigDetail(item: SpaceDynamicItem): void {
    const orig: SpaceDynamicItem | null = item.orig;
    if (orig && orig.idStr) {
      this.openDynDetail(orig);
      return;
    }
    this.playDynVideo(item.orig?.video ?? null);
  }

  /** 打开 UP 主空间 */
  private openUpSpace(item: SpaceDynamicItem): void {    if (!item.authorName) return;
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UpSpacePage',
      params: {
        mid: item.authorMid,
        upName: item.authorName,
        upFace: item.authorFace
      }
    });
  }

  /** 打开 UP 空间（面板头像） */
  private openUpSpaceByMid(up: DynUpItem): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UpSpacePage',
      params: {
        mid: up.mid,
        upName: up.uname,
        upFace: up.face
      }
    });
  }

  /**
   * ⭐ 打开图片预览（由 cards 组件回调过来：组件算 URL/缩略图 id/起点矩形，页面负责开浮层）
   * 浮层放在页面根节点才能铺满整屏（放进滚动容器会被裁剪与限制层级）。
   */
  private openCardPreview(urls: string[], thumbIds: string[], index: number,
    ox: number, oy: number, ow: number, oh: number): void {
    this.previewImageUrls = urls;
    this.previewThumbIds = thumbIds;
    this.previewIndex = index;
    this.previewOriginX = ox;
    this.previewOriginY = oy;
    this.previewOriginW = ow;
    this.previewOriginH = oh;
    this.showPreview = true;
  }

  /** 跳转登录页 */
  private goToLogin(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/QrCodeLoginPage' }).catch(() => {});
  }

  /**
   * ⭐ 取（或首次创建）某条动态的点赞状态对象。
   * 按 id 缓存 → 同一动态在视频卡/统计行两处拿到的是**同一个实例**，点一处两处都变。
   * ⚠️ 不要在 build 里 new 对象（@ObjectLink 会失去绑定），所以这里走 Map 复用。
   */
  private likeStateOf(item: SpaceDynamicItem): ObservableDynLike {
    let st: ObservableDynLike | undefined = this.likeStates_.get(item.idStr);
    if (!st) {
      st = ObservableDynLike.from(item.liked, item.likeCount);
      this.likeStates_.set(item.idStr, st);
    }
    return st;
  }

  /**
   * ⭐ 数据落地后用服务端值重建点赞状态表（刷新/切分类/加载更多都要调）。
   *  - 已在途（likingIds_）的动态保留现有状态：否则会被旧数据覆盖掉乐观更新的结果；
   *  - 其余按服务端 liked/count 重建，避免"刷新后仍显示上次点的状态"。
   */
  private syncLikeStates(): void {
    const next: Map<string, ObservableDynLike> = new Map<string, ObservableDynLike>();
    for (const it of this.dynamics) {
      if (this.likingIds_.has(it.idStr)) {
        const keep: ObservableDynLike | undefined = this.likeStates_.get(it.idStr);
        if (keep) {
          next.set(it.idStr, keep);
          continue;
        }
      }
      next.set(it.idStr, ObservableDynLike.from(it.liked, it.likeCount));
    }
    this.likeStates_ = next;
  }

  /**
   * 点赞 / 取消点赞一条动态
   *  1. 未登录：提示 + 跳登录页（不白跑一次必然失败的请求）；
   *  2. **乐观更新**：先改本地点赞状态立即反馈，接口失败再回滚（手感不被网络拖住）；
   *  3. 同一动态在途只允许一个请求（连点会打乱计数）；
   *  4. dyn_id_str 是 19 位串，全程当字符串用（接口层已注释，别 parseInt）。
   *
   * ⚠️ 只改 ObservableDynLike（+ 同步回 item 字段），**绝不动 ForEach 的 key**：
   *    改 key 会让框架销毁重建整张卡 → 封面重新加载闪一下（这就是上一版的 bug）。
   */
  private async toggleDynLike(item: SpaceDynamicItem): Promise<void> {
    if (!this.isLoggedIn) {
      promptAction.showToast({ message: '登录后才能点赞', duration: 1500 });
      this.goToLogin();
      return;
    }
    if (this.likingIds_.has(item.idStr)) return;
    this.likingIds_.add(item.idStr);

    const st: ObservableDynLike = this.likeStateOf(item);
    const target: boolean = !st.liked;
    const prevLiked: boolean = st.liked;
    const prevCount: number = st.count;
    st.liked = target;
    st.count = Math.max(0, prevCount + (target ? 1 : -1));
    // item 只是数据源副本，同步一份便于后续详情页/缓存拿到一致的值（不参与渲染判等）
    item.liked = st.liked;
    item.likeCount = st.count;

    try {
      const res: CommentLikeResult = await setDynamicLike(item.idStr, target);
      if (!res.ok) {
        // 回滚 + 把服务端给的原因直接透给用户（未登录/风控/动态已删）
        st.liked = prevLiked;
        st.count = prevCount;
        item.liked = prevLiked;
        item.likeCount = prevCount;
        promptAction.showToast({ message: res.message, duration: 1800 });
      }
    } catch (e) {
      st.liked = prevLiked;
      st.count = prevCount;
      item.liked = prevLiked;
      item.likeCount = prevCount;
      promptAction.showToast({ message: '点赞失败，请稍后重试', duration: 1800 });
      logError(`[DynamicsPage] toggleDynLike 异常: ${e}`);
    } finally {
      this.likingIds_.delete(item.idStr);
    }
  }

  /**
   * 点赞胶囊（可点）：已赞 = 主题色图标 + 主题色 14% 底；未赞 = 中性色
   * ⭐ 外观实现在 components/DynLikePill 里（**只有一份**，视频卡与外层统计行共用同一实例状态）；
   *    这里只是"取状态 + 传给组件"的薄包装，两点调用处保持一行。
   */
  @Builder
  likePill(item: SpaceDynamicItem) {
    DynLikePill({
      like: this.likeStateOf(item),
      onToggle: () => { this.toggleDynLike(item); }
    })
  }

  aboutToAppear(): void {
    // ⭐ 复位胶囊显隐与底栏（进入动态页时显示）
    this.capsuleHidden = false;
    AppStorage.set('bottomBarHidden', false);
    // ⭐ 按当前屏宽计算胶囊自适应尺寸（窄屏不超屏）
    this.recalcCapsule();
    this.checkLoginAndLoad();
    this.listenOrientationChange();
  }

  aboutToDisappear(): void {
    // ⭐ 离开页面：停止呼吸灯（避免定时器空转耗电）
    this.stopBreathe();
    if (this.landscapeListener) {
      this.landscapeListener.off('change');
      this.landscapeListener = null;
    }
  }

  /** 注册媒体查询监听（方向变化，与 UpSpacePage 相同方案） */
  private listenOrientationChange(): void {
    const mediaQuery = this.getUIContext().getMediaQuery();
    this.landscapeListener = mediaQuery.matchMediaSync('(orientation: landscape)');
    // 初始方向
    this.isLandscape = this.landscapeListener.matches;
    this.landscapeListener.on('change', (result: mediaquery.MediaQueryResult) => {
      const newIsLandscape = result.matches;
      if (this.isLandscape !== newIsLandscape) {
        logInfo(`[DynamicsPage] 方向变化: ${newIsLandscape ? '横屏' : '竖屏'}`);
        this.isLandscape = newIsLandscape;
        // ⭐ 横竖屏切换后屏宽变化：屏幕尺寸缓存失效 + 重算胶囊自适应尺寸
        this.screenWvp = 0;
        this.screenHvp = 0;
        this.recalcCapsule();
      }
    });
  }

  /** ⭐ 屏幕尺寸缓存（vp）：getUpPanelHeight() 每次 build 都会执行，原实现每次都做
   *  display.getDefaultDisplaySync() + 2 次 px2vp（同步调用，实测是 build 期的固定开销）；
   *  方向变化/尺寸变化时置 0 失效重取 */
  private screenWvp: number = 0;
  private screenHvp: number = 0;

  /** 取屏幕尺寸（带缓存），失败返回 false（调用方保持默认值） */
  private ensureScreenSize(): boolean {
    if (this.screenWvp > 0 && this.screenHvp > 0) return true;
    try {
      const d = display.getDefaultDisplaySync();
      this.screenWvp = this.getUIContext().px2vp(d.width);
      this.screenHvp = this.getUIContext().px2vp(d.height);
      return this.screenWvp > 0 && this.screenHvp > 0;
    } catch (e) {
      this.screenWvp = 0;
      this.screenHvp = 0;
      return false;
    }
  }

  // ── 标题胶囊（仿首页 capsuleTitleBuilder）──

  /** 当前筛选分类的图标（全部/投稿/番剧/专栏/UP） */
  private currentFilterIcon(): Resource {
    for (const f of DYN_FILTERS) {
      if (f.type === this.highlightType) return f.icon;
    }
    return DYN_FILTERS[0].icon;
  }

  /**
   * 胶囊自适应尺寸：按屏幕宽收缩分段项宽/栏宽/图标字号/平移量。
   * 公式：胶囊总宽 = barWidth + contentPadding×4（16vp），写死 386vp 在窄屏会超屏；
   *       改为按可用宽度收缩，同时 translate 随胶囊宽度钳制，保证右缘不超屏。
   */
  private recalcCapsule(): void {
    if (!this.ensureScreenSize()) return; // 取不到屏幕尺寸 → 保持默认尺寸（66/370/40）
    const screenW = this.screenWvp;
    // ⭐ 信息流内容避开左侧悬浮 UP 面板（左占位 92vp = 面板 68 + margin 12 + padding 12），
    //    胶囊在信息流内容区 [92, 屏宽] 中心居中 = 屏幕中心右移 46vp（92/2）
    // 胶囊总宽 = itemW×5 + space(6×4) + 16(barWidth 内) + 16(contentPadding×4)
    // 保证总宽 ≤ 内容区宽（screenW - 92），并留 8vp 右缘安全边距
    const maxTotal = Math.max(200, screenW - 92 - 8);
    const naturalTotal = 66 * DYN_FILTERS.length + 6 * (DYN_FILTERS.length - 1) + 16 + 16;
    const totalW = Math.min(naturalTotal, maxTotal);
    // 分段项宽：总宽扣除 space 与 padding 后均分（下限 44 保证可点击）
    this.capsuleItemW = Math.max(44, Math.round((totalW - 6 * (DYN_FILTERS.length - 1) - 16 - 16) / DYN_FILTERS.length));
    this.capsuleBarW = this.capsuleItemW * DYN_FILTERS.length + 6 * (DYN_FILTERS.length - 1) + 16;
    // 平移量：内容区中心（屏幕中心右移 46vp）+ 右缘不超屏（留 8vp）
    const capsuleCenter = 46;
    const capsuleHalf = (this.capsuleBarW + 16) / 2;
    const maxTranslate = screenW / 2 - capsuleHalf - 8;
    this.capsuleTranslateX = Math.min(capsuleCenter, Math.max(0, maxTranslate));
    // 窄屏收缩图标与字号（itemW < 56 时）
    const narrow: boolean = this.capsuleItemW < 56;
    this.capsuleIconSize = narrow ? 14 : 16;
    this.capsuleIconGap = narrow ? 3 : 4;
    this.capsuleFontSize = narrow ? 12 : 13;
  }

  /** 胶囊分段项（图标 + 文字 + 选中下划线） */
  @Builder
  capsuleSegmentItem(index: number) {
    Column() {
      Row() {
        Image(DYN_FILTERS[index].icon)
          .width(this.capsuleIconSize).height(this.capsuleIconSize)
          .margin({ right: this.capsuleIconGap })
          .fillColor(this.highlightType === DYN_FILTERS[index].type ? this.customThemeColor : (this.isDarkMode ? '#FFFFFF' : '#000000'))
        Text(DYN_FILTERS[index].label)
          .fontSize(this.capsuleFontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.highlightType === DYN_FILTERS[index].type ? this.customThemeColor : (this.isDarkMode ? '#FFFFFF' : '#000000'))
      }
      .width(this.capsuleItemW)
      .height(22)
      .justifyContent(FlexAlign.Center)
      if (this.highlightType === DYN_FILTERS[index].type) {
        Row()
          .width(28)
          .height(3)
          .borderRadius(1.5)
          .backgroundColor(this.customThemeColor)
          .margin({ top: 0 })
      }
    }
    .width(this.capsuleItemW)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.switchFilter(DYN_FILTERS[index].type);
    })
  }

  /** 标题胶囊 Builder（常驻展开态：始终显示分段选择器） */
  @Builder
  capsuleTitleBuilder() {
    Row() {
      HdsMiniBarButton({
        barWidth: this.capsuleBarW,
        barHeight: 40,
        contentPadding: 4,
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
        barOverlap: true,
        barPosition: BarPosition.End
      }) {
        // 常驻展开：分段选择器（单行）
        Scroll() {
          Row({ space: 6 }) {
            ForEach(DYN_FILTERS, (_f: DynFilterOption, idx: number) => {
              this.capsuleSegmentItem(idx)
            }, (f: DynFilterOption) => f.type)
          }
          .padding({ left: 4, right: 4 })
          .flexShrink(0)
        }
        .width('100%')
        .height('100%')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    // ⭐ 向右平移：左侧有 UP 面板占位（80vp），胶囊中心在信息流视角居中（屏幕中心右移 40vp）；
    //    窄屏时随胶囊宽度钳制，保证右缘不超屏（见 recalcCapsule）
    .translate({ x: this.capsuleTranslateX })
    .padding({ top: 8 })
  }

  // ── 右侧 UP 面板（仿 PiliPlus up_panel rightFixed）──

  /** UP 面板单项：头像 + 名字（index 用于瀑布弹入的逐条错峰，见 upItemVisible） */
  @Builder
  upItem(up: DynUpItem, index: number) {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Image(resizeImageUrl(up.face, 160))
          .width(40).height(40)
          .borderRadius(20)
          .objectFit(ImageFit.Cover)
          .backgroundColor('#E8E8E8')
        if (up.hasUpdate) {
          Circle({ width: 8, height: 8 })
            .fill(this.customThemeColor)
            .position({ top: 0, right: 0 })
        }
      }
      .width(44).height(44)
      // ⭐ 选中时头像加主题色边框圈（呼吸灯：透明度随 selectedRingAlpha 低频翻转，.animation 平滑）
      .border({
        width: this.highlightType === 'up' && this.selectedUpMid === up.mid ? 3 : 0,
        color: this.themeColorRgba(this.selectedRingAlpha)
      })
      .borderRadius(22)
      .animation({ duration: 600, curve: Curve.EaseInOut })
      Text(up.uname)
        .fontSize(10)
        .fontColor(this.highlightType === 'up' && this.selectedUpMid === up.mid
          ? this.customThemeColor
          : (this.isDarkMode ? '#FFFFFF' : '#000000'))
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .lineHeight(13)
        .margin({ top: 3 })
        .width('100%')
    }
    // ⭐ 撑满面板宽度并水平居中：头像与名字在 UP 面板内居中显示
    // ⭐ 不用整体 opacity 灰度（未选中 0.65 会让头像变灰）：头像保持原色，
    //    选中态由头像主题色边框圈 + 名字文字主题色 + 红点提示区分
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    // ⭐ 瀑布弹入（方案 A）：该条未置位时缩到 0.55 + 下移 7vp + 全透明，置位后由 spring 弹回原位
    //    下标越界（追加数据）时按"已可见"处理，避免老条目突然消失
    .opacity(this.upItemVisible.length > index ? (this.upItemVisible[index] ? 1 : 0) : 1)
    .scale({
      x: this.upItemVisible.length > index ? (this.upItemVisible[index] ? 1 : 0.55) : 1,
      y: this.upItemVisible.length > index ? (this.upItemVisible[index] ? 1 : 0.55) : 1
    })
    .translate({ y: this.upItemVisible.length > index ? (this.upItemVisible[index] ? 0 : 7) : 0 })
    .onClick(() => { this.selectUp(up); })
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => { this.openUpSpaceByMid(up); })
    )
    // ⚠️ .animation() 只作用于**它之前**声明的属性 → 必须放在 opacity/scale/translate 之后
    .animation({ duration: 700, curve: curves.springCurve(0.15, 1, 80, 10) })
  }

  /** UP 面板高度：面板底部距屏幕底部 90vp；横屏限制不超屏（vp）
   *  ⚠️ 本方法在 build 期被 upPanel() 调用，屏幕尺寸走 ensureScreenSize() 缓存（原来每次都同步查屏） */
  private getUpPanelHeight(): number {
    if (!this.ensureScreenSize()) return 420;
    const screenW = this.screenWvp;
    const screenH = this.screenHvp;
    // 顶部避让胶囊区域（statusBarHeight + 76）+ 全部按钮占位(含space 10) + 底部 90vp 间距
    // 按钮实际高度：HdsMiniBarButton 容器 68 + 文字≈14 + margin 4 ≈ 86，加 space 10 = 96
    const topReserve = this.statusBarHeight + 76;
    const upButtonReserve = 96;
    const bottomGap = 90;
    const height = screenH - topReserve - upButtonReserve - bottomGap;
    if (screenW > screenH) {
      // 横屏：短边为屏幕高度，面板不超过可用区域
      return Math.max(160, Math.min(height, screenH - topReserve - upButtonReserve - 20));
    }
    // 竖屏：底部距屏幕底部 90vp
    return Math.max(160, height);
  }

  /** 「全部动态」圆形沉浸光感按钮（图标 + 当前分类文字，跟随筛选切换） */
  @Builder
  allUpButton() {
    Column() {
      HdsMiniBarButton({
        // ⭐ 直径与下方 UP 面板宽度对齐：可见圆直径 = barWidth = 68vp（与面板宽一致）
        barWidth: 68,
        barHeight: 68,
        contentPadding: 4,
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
        barOverlap: true,
        barPosition: BarPosition.End,
        onButtonClick: (): void => { this.selectAllUp(); }
      }) {
        // ⭐ 图标（去掉文字，仅图标居中显示）
        Stack({ alignContent: Alignment.Center }) {
          Image(this.currentFilterIcon())
            .width(26).height(26)
            // ⭐ 与其他分类统一：深色模式白 / 浅色模式黑（不再用主题色高亮"全部"）
            .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        }
        .width('100%')
        .height('100%')
        // ⭐ 分类切换动画：缩小淡出 → 弹回淡入（btnSwitchScale/btnSwitchOpacity 由 @Watch 驱动）
        .scale({ x: this.btnSwitchScale, y: this.btnSwitchScale })
        .opacity(this.btnSwitchOpacity)
        .animation({ duration: 250, curve: Curve.EaseOut })
      }
    }
    .width(68)
    // ⭐ 与其他分类统一：始终 65% 半透明（不再对"全部"全不透明）
    .opacity(0.65)
  }

  /** UP 面板（左侧胶囊竖排，只含关注UP列表；「全部」按钮独立于本面板）
   *  ⭐ 材质通道与「全部动态」悬浮按钮同款：HdsTabs barFloatingStyle.systemMaterialEffect
   *    （内容区唯一可用的真材质通道），替换原 backgroundBlurStyle(COMPONENT_THICK) 模拟磨砂 */
  @Builder
  upPanel() {
    HdsTabs() {
      TabContent()
        .tabBar(this.upPanelBar())
        .backgroundColor(Color.Transparent)
    }
    .barWidth(68)
    .barHeight(this.getUpPanelHeight())
    .width(68)
    .height(this.getUpPanelHeight())
    .barOverlap(true)
    .barPosition(BarPosition.End)
    // ⚠️ IMMERSIVE 材质必须显式配 gradientMask（省略会渲染成黑色遮罩，见红线）
    .barFloatingStyle({
      gradientMask: {
        maskColor: Color.Transparent
      },
      barBottomMargin: 0,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
      }
    })
    .scrollable(false)
    .animationDuration(0)
    .backgroundColor(Color.Transparent)
    .clip(false)
    // ⭐ 外壳只做 200ms 快速淡入（避免"空胶囊"戳在屏上），头像由 upItem 逐条瀑布弹入
    //    ⚠️ .animation() 只作用于**它之前**声明的属性，所以必须写在 opacity 之后
    .opacity(this.upRailReady ? 1 : 0)
    .animation({ duration: 200, curve: Curve.EaseOut })
  }

  /** UP 面板 bar 内容：关注 UP 列表（竖排滚动；材质与胶囊圆角由 HdsTabs bar 承载） */
  @Builder
  upPanelBar() {
    List({ space: 12, scroller: this.upScroller }) {
      // ⭐ 顶部空白占位（跟随滚动）：与底部对称各 4vp，头像不与胶囊弧线贴边
      ListItem() {
        Column().width('100%').height(4)
      }
      ForEach(this.upList, (up: DynUpItem, index: number) => {
        ListItem() {
          this.upItem(up, index)
        }
        // ⚠️ key 里**必须带上 hasUpdate**：ForEach 只按 key 判断"重建还是复用"，
        //    key 不变时**不会重新执行 item 构建**（hilog 实证：`AceForEach: ForEachNode skip mark dirty. Ids.size[50]`），
        //    而 hasUpdate 是普通数据字段（不是 @State）→ 红点永远不会消失。
        //    带上这个字段后，点击清红点时 key 变化 → 该条重建 → 红点消失（官方推荐的 key 用法）。
      }, (up: DynUpItem) => `${up.mid}_${up.hasUpdate ? 1 : 0}`)
      // ⭐ 底部空白占位（跟随滚动）：与顶部对称各 4vp
      ListItem() {
        Column().width('100%').height(4)
      }
    }
    .width('100%')
    // ⚠️ 外壳固定全高、**不做高度/缩放动画**：动画若改 List 视口，每帧都要按新的视口重排
    //    cachedCount 个项；入场观感全部交给 upItem 的逐条瀑布弹入（见 upItemVisible）
    .height('100%')
    .lanes(1)
    // ⭐ 触底回弹（Spring）
    .edgeEffect(EdgeEffect.Spring)
    .cachedCount(30)
    // ⭐ 遮罩归零：无上下 padding（头像为 40vp 圆，圆心在胶囊半圆内，不被 clip 裁剪）
    .scrollBar(BarState.Off)
    .onReachEnd(() => this.onUpReachEnd())
    // ⭐ 裁剪内容到胶囊圆形边界：消除 List 矩形内容区的"直边"观感（bar 材质圆角由系统浮动栏提供）
    .borderRadius(34)
    .clip(true)
  }

  // ── 动态卡片渲染（与 UP 空间动态同款样式）──

  /**
   * 动态正文（文字/表情/话题/@ 混排）
   * ⭐ 实现已抽到 components/DynamicTextContent（详情页共用同一份外观，避免两页表现不一致）；
   *    这里保留同名薄包装，调用处不用改。

  /** 动态卡片（按类型分发渲染） */
  @Builder
  dynamicCard(item: SpaceDynamicItem) {
    // ⭐ 根 Column：仅 width + 背景 + 圆角（不含 padding，总宽 = 列宽，不会溢出）
    Column() {
      // ⭐ 内部包裹 Column：承载 padding，保证内容在卡片内
      Column() {
        // 作者行（点击进入 UP 空间）
        Row() {
          Image(resizeImageUrl(item.authorFace, 120))
            .width(28).height(28)
            .borderRadius(14)
            .objectFit(ImageFit.Cover)
            .backgroundColor('#E8E8E8')
          Text(item.authorName)
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

        // ⭐ 按已解析字段分发（优先字段而非 type 字符串）：
        //    番剧/影视动态 majorType=ARCHIVE 时 video 已填充 → 视频卡；
        //    专栏动态 majorType=COMMON 时 common 已填充 → 通用卡；
        //    避免 DYNAMIC_TYPE_PGC / DYNAMIC_TYPE_ARTICLE 落入「暂不支持」
        // ⚠️ 番剧动态真实 type 是 DYNAMIC_TYPE_PGC_UNION（日志实证），用 startsWith 匹配所有 PGC 变体
        DynamicCardBody({
          item: item,
          like: this.likeStateOf(item),
          onToggleLike: () => { this.toggleDynLike(item); },
          onTapSelf: () => { this.openDynDetail(item); },
          // ⭐ 图片预览浮层必须挂在页面根节点（卡片组件里放会被滚动容器限制尺寸），
          //    所以卡片只算出 URL/矩形，实际开预览由页面做
          onPreview: (urls: string[], thumbIds: string[], index: number,
            ox: number, oy: number, ow: number, oh: number) => {
            this.openCardPreview(urls, thumbIds, index, ox, oy, ow, oh);
          }
        })

        // 统计行（⭐ 视频卡已含播放/弹幕/点赞/转发/评论，不再重复显示外层统计行）
        //    图标 + 数字胶囊，居中显示（去掉中文标签）
        if (!item.video) {
          Row({ space: 16 }) {
            // 点赞胶囊（可点：乐观更新 + 失败回滚）
            this.likePill(item)
            // 转发胶囊
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
            // 评论胶囊
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
            // ⭐ 评论胶囊 → 详情页（评论区在那边）
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => { this.openDynDetail(item); })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 14 })
        }
      }
      .width('100%')
      // ⭐ padding 在内部包裹 Column 上：根不含 padding，卡片总宽 = 列宽（不溢出、两列有间距）
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    }
    .width('100%')
    // ⚠️ 背景跟随卡片样式（透明样式 → 主题色+透明度；实心 → 深/浅灰）
    .backgroundColor(this.getCardItemBg())
    // ⭐ 卡片圆角跟随卡片样式选项（与首页一致）
    .borderRadius(this.cardListBorderRadius)
    // ⚠️ 边框跟随卡片样式（宽度/透明度/跟随主题色）
    .border({ width: this.cardBorderWidth, color: this.getCardItemBorder() })
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 2 })
    // ⭐ 所有信息流卡片统一按压反馈（与首页整卡 clickEffect 一致；子卡片 onClick 点击时整卡缩放）
    .clickEffect({ level: 0, scale: 0.95 })
    // ⭐ 点卡片任意位置 → 动态详情页。覆盖"卡片留白 / 内边距 / 统计行空白处"这些
    //    DynamicCardBody 够不到的边缘（组件根只能管到自己的矩形）。
    //    子区域有自己的行为时以子区域为准：作者行 → UP 空间、图片 → 预览、封面 → 播放、
    //    点赞胶囊 → 点赞、评论胶囊 → 详情（同一结果）、话题/@ → 搜索 / UP 空间。
    .onClick(() => { this.openDynDetail(item); })
  }

  /**
   * 动态卡片背景色（跟随卡片样式选项；实现在 utils/CardStyle.ets，详情页共用同一套规则）
   */
  private getCardItemBg(): string {
    return cardItemBg(this.isDarkMode, this.cardTransparentStyle, this.cardBgOpacity);
  }

  /**
   * 动态卡片边框色（实现在 utils/CardStyle.ets）
   */
  private getCardItemBorder(): string {
    return cardItemBorder(this.isDarkMode, this.cardTransparentStyle,
      this.cardBorderOpacity, this.cardBorderFollowTheme, this.customThemeColor);
  }

  /**
   * 透明度(0-100) → 两位十六进制（与首页一致）
   */
  private opacityToHexAlpha(opacity: number): string {
    const val = Math.round(opacity / 100 * 255);
    const hex = val.toString(16);
    return hex.length === 1 ? '0' + hex : hex;
  }

  /** 下拉刷新指示器（仅刷新时转圈） */
  @Builder
  customRefreshComponent() {
    Stack() {
      if (this.isRefreshing) {
        LoadingProgress()
          .width(22).height(22)
          .color(this.customThemeColor)
      } else {
        Text('↓')
          .fontSize(16)
          .fontColor(this.customThemeColor)
      }
    }
    .width('100%')
    .height(40)
  }

  /** 动态列表（含加载态、错误态、下拉刷新、触底加载） */
  @Builder
  dynFeed() {
    Column() {
      // ⭐ 仅首次且无数据时显示加载中：刷新时列表仍有旧数据 → 继续走 Refresh 分支（组件常驻不卸载，
      //    避免重建时 onStateChange 在渲染期改 refreshBuilderText 触发 "changed during render" 报错）
      if (!this.isDynLoaded && this.dynamics.length === 0) {
        Column() {
          LoadingProgress().width(28).height(28).color(this.customThemeColor)
          Text('加载动态中...').fontSize(13).fontColor('#999999').margin({ top: 10 })
        }
        .width('100%').padding({ top: 40, bottom: 40 })
      } else if (this.loadError && this.dynamics.length === 0) {
        Column() {
          Text(this.loadError)
            .fontSize(13).fontColor('#999999')
            .width('100%').textAlign(TextAlign.Center)
          Text('点击重试')
            .fontSize(13).fontColor(this.customThemeColor)
            .margin({ top: 10 })
            .onClick(() => { this.loadDynamics(''); })
        }
        .width('100%').padding({ top: 40, bottom: 40 })
      } else if (this.dynamics.length === 0) {
        Column() {
          Text(this.emptyFeedHint())
            .fontSize(13).fontColor('#999999')
            .width('100%').textAlign(TextAlign.Center)
          Text('下拉可以刷新')
            .fontSize(12).fontColor('#BBBBBB')
            .width('100%').textAlign(TextAlign.Center)
            .margin({ top: 6 })
        }
        .width('100%').padding({ top: 40, bottom: 40 })
      } else {
        Refresh({ refreshing: $$this.isRefreshing, builder: this.customRefreshComponent() }) {
          if (this.isLandscape) {
            // ⭐ 横屏：WaterFlow 瀑布流（仿 WatchHistoryPage 成功模式）——每列独立堆积，
            //    FlowItem 自身 width('100%') 约束为列宽，WaterFlow 用 layoutWeight(1) 由容器分配高度
            WaterFlow({ scroller: this.dynScroller }) {
              ForEach(this.dynamics, (item: SpaceDynamicItem, index: number) => {
                FlowItem() {
                  this.dynamicCard(item)
                }
                // ⭐ FlowItem 自身撑满列宽（仿 WatchHistoryPage），避免列宽计算异常导致两列叠加/超屏
                .width('100%')
                // ⭐ 顶部两列首项留白（高度 = 胶囊区域）：内容初始在悬浮胶囊下方可见，
                //    滚动时留白滚出、内容从胶囊下方穿过（与竖屏 List 顶部 spacer 方案一致）
                .margin({ top: index < 2 ? this.statusBarHeight + 76 : 0 })
                // ⭐ 刷新逐卡动画：opacity/scale/translate 由 dynCardsVisible 驱动
                .opacity(this.dynCardsVisible.length > index ? (this.dynCardsVisible[index] ? 1 : 0) : 1)
                .scale({
                  x: this.dynCardsVisible.length > index ? (this.dynCardsVisible[index] ? 1 : 0.8) : 1,
                  y: this.dynCardsVisible.length > index ? (this.dynCardsVisible[index] ? 1 : 0.8) : 1
                })
                .translate({
                  y: this.dynCardsVisible.length > index
                    ? (this.dynCardsVisible[index] ? 0 : (this.dynCardTranslateYs[index] || 60))
                    : 0
                })
                .animation(!this.animateDynCards ? { duration: 0 } : {
                  duration: 1400,
                  curve: this.dynBulkLoading
                    ? curves.springCurve(0.15, 1, 80, 8)
                    : curves.springCurve(0.15, 1, 80, 12)
                })
              }, (item: SpaceDynamicItem) => item.idStr)
            }
            .columnsTemplate('1fr 1fr')
            .columnsGap(this.cardListMargin)
            .rowsGap(this.cardListMargin)
            .width('100%')
            .layoutWeight(1)
            // ⭐ 去掉滑动指示器；edgeEffect 用 Spring（对齐首页：上滑加载到底有弹性回弹，不顿住）
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(50)
            // ⭐ 左侧 92vp 占位（悬浮 UP 面板 68 + margin 12 + 原 padding 12）：内容避开面板，
            //    保持叠层布局但信息流不全宽；顶部留白由前两列首项 margin 承担（与竖屏 List 一致）
            .padding({ left: 92, right: 12 })
            .onWillScroll((_dx: number, _dy: number) => {
              // ⭐ 与 HomePage/DiscoverPage 同款：用 scroller 取绝对偏移（回调参数不可靠）
              const absoluteOffset = this.dynScroller.currentOffset().yOffset;
              this.onDynFeedScroll(absoluteOffset);
            })
            .onReachEnd(() => this.onReachEnd());
          } else {
            // ⭐ 竖屏：单列 List，行间距 = cardListMargin
            List({ space: this.cardListMargin, scroller: this.dynScroller }) {
              // ── 顶部空白占位（跟随列表滚动）：初始首条内容在悬浮胶囊下方可见，
              //    滑动时 spacer 滚出，内容自然从胶囊下方穿过（仿 UpSpacePage 顶部 spacer 方案）──
              ListItem() {
                Column().width('100%').height(this.statusBarHeight + 76)
              }
              ForEach(this.dynamics, (item: SpaceDynamicItem, index: number) => {
                ListItem() {
                  // ⭐ 外层 Column 撑满列表宽度（dynamicCard 根不设固定宽，由这里约束）
                  Column() {
                    this.dynamicCard(item)
                  }
                  .width('100%')
                  // ⭐ 刷新逐卡动画：opacity/scale/translate 由 dynCardsVisible 驱动
                  .opacity(this.dynCardsVisible.length > index ? (this.dynCardsVisible[index] ? 1 : 0) : 1)
                  .scale({
                    x: this.dynCardsVisible.length > index ? (this.dynCardsVisible[index] ? 1 : 0.8) : 1,
                    y: this.dynCardsVisible.length > index ? (this.dynCardsVisible[index] ? 1 : 0.8) : 1
                  })
                  .translate({
                    y: this.dynCardsVisible.length > index
                      ? (this.dynCardsVisible[index] ? 0 : (this.dynCardTranslateYs[index] || 60))
                      : 0
                  })
                  .animation(!this.animateDynCards ? { duration: 0 } : {
                    duration: 1400,
                    curve: this.dynBulkLoading
                      ? curves.springCurve(0.15, 1, 80, 8)
                      : curves.springCurve(0.15, 1, 80, 12)
                  })
                }
              }, (item: SpaceDynamicItem) => item.idStr)
            }
            .width('100%')
            .height('100%')
            .lanes(1)
            // ⭐ 去掉滑动指示器；edgeEffect 用 Spring（对齐首页：上滑加载到底有弹性回弹，不顿住）
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(50)
            // ⭐ 左侧 92vp 占位（悬浮 UP 面板 68 + margin 12 + 原 padding 12）：内容避开面板，
            //    保持叠层布局但信息流不全宽；顶部留白由 ListItem spacer 承担（跟随滚动）
            .padding({ left: 92, right: 12 })
            .onWillScroll((_dx: number, _dy: number) => {
              // ⭐ 与 HomePage/DiscoverPage 同款：用 scroller 取绝对偏移（回调参数不可靠）
              const absoluteOffset = this.dynScroller.currentOffset().yOffset;
              this.onDynFeedScroll(absoluteOffset);
            })
            .onReachEnd(() => this.onReachEnd());
          }
        }
        .width('100%')
        .layoutWeight(1)
        .onRefreshing(() => { this.onRefresh(); })
      }
    }
    .width('100%')
  }

  /** 未登录视图 */
  @Builder
  NotLoggedInView() {
    Column() {
      Blank()
      Text('请先登录B站账号')
        .fontSize(16)
        .fontColor(this.isDarkMode ? '#999999' : '#666666')
      Text('登录后即可查看关注动态')
        .fontSize(12)
        .fontColor(this.isDarkMode ? '#666666' : '#AAAAAA')
        .margin({ top: 8 })
      Button('去登录')
        .type(ButtonType.Capsule)
        .backgroundColor('#FB7299')
        .fontColor(Color.White)
        .margin({ top: 16 })
        .onClick(() => { this.goToLogin(); })
      Blank()
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ── 底层：信息流全宽（滚动/横滑时内容从悬浮 UP 面板下方穿过）──
      if (this.isLoggedIn) {
        Column() {
          // ⭐ 横滑筛选 Tabs：5 页对应 5 个筛选类型，左右滑动切换（不再触发底部 HdsTabs 切换首页/我的）
          Tabs({ controller: this.dynTabsController }) {
            ForEach(DYN_FILTERS, (_f: DynFilterOption, idx: number) => {
              TabContent() {
                // ⭐ 仅当前筛选页渲染 dynFeed：避免多个 TabContent 的 List/WaterFlow 共享同一个
                //    dynScroller 导致 currentOffset() 取到非当前列表偏移、底部置顶图标不切换
                if (this.filterType === DYN_FILTERS[idx].type) {
                  this.dynFeed()
                }
              }
            }, (f: DynFilterOption) => f.type)
          }
          .barHeight(0)
          .barPosition(BarPosition.End)
          .vertical(false)
          // ⚠️ 「动态页点击切换分类」开关（默认打开）：
          //    打开（默认）= 禁用横滑，只能用顶部胶囊/分类按钮点击切分类；
          //    关闭 = 恢复左右横滑切分类（原手感）
          .scrollable(!this.dynFilterTapOnly)
          .animationDuration(200)
          // ⭐ 动画开始即同步胶囊选中态（不等 onChange，消除胶囊切换延迟）
          .onAnimationStart((fromIndex: number, toIndex: number) => this.onTabsAnimationStart(fromIndex, toIndex))
          .onChange((index: number) => {
            // ⭐ 更新 Tabs 实际 index（供主动 changeIndex 去重判断）
            this.lastTabsIndex = index;
            // ⭐ 主动 changeIndex 触发的 onChange：跳过（避免重复加载）；横滑触发的正常处理
            if (this.suppressNextOnChange) {
              this.suppressNextOnChange = false;
              return;
            }
            if (index >= 0 && index < DYN_FILTERS.length) {
              this.switchFilter(DYN_FILTERS[index].type);
            }
          })
        }
        .width('100%')
        .height('100%')
      } else {
        Column() {
          this.NotLoggedInView()
        }
        .width('100%')
        .height('100%')
      }

      // ── 中层：UP 面板悬浮层（左侧，覆盖在信息流上方，内容从其下方穿过）──
      if (this.isLoggedIn) {
        Column({ space: 10 }) {
          // 「全部」圆形沉浸光感按钮（独立）
          this.allUpButton()

          // UP 面板胶囊（只含关注UP列表，高度为屏幕 4/5）
          this.upPanel()
        }
        .width(68)
        .alignItems(HorizontalAlign.Center)
        // ⭐ 与屏幕左边缘保持 12vp 间距
        .margin({ left: 12 })
        // ⭐ 顶部避让悬浮胶囊区域（与列表同高），避免「全部」按钮被胶囊盖住
        .padding({ top: this.statusBarHeight + 76 })
        // ⚠️ 整列不再用 entranceOpacity 淡入（会让上一层页面透出来）；
        //    UP 胶囊自己的弹入动画在 upPanel() 里（由 upRailReady 驱动）
      }

      // ── 顶层：悬浮胶囊标题（列表内容从胶囊下方穿过，不被提前裁剪）──
      Column() {
        this.capsuleTitleBuilder()
      }
      .width('100%')
      .padding({ top: this.statusBarHeight + 6 })
      // ⭐ 滑动显隐：下滑隐藏、上滑显示（仿首页底栏显隐）
      .translate({ y: this.capsuleHidden ? -(this.statusBarHeight + 76) : 0 })
      .opacity(this.capsuleHidden ? 0 : 1)
      // ⭐ 时长 500ms：与底部栏系统动画节奏更接近（原 250ms 偏快）
      .animation({ duration: 500, curve: Curve.FastOutSlowIn })

      // ⭐ 通用全屏图片预览（缩略图点击→原图；Swiper 滑动 + 双指缩放 + 平移 + minimap 导航）
      // ⚠️ @Link 参数用单美元 $ 传引用（$$ 仅用于 bindContentCover 等内置 API，运行时 $$this 未定义）
      FullImagePreview({
        isShow: $showPreview,
        previewUrls: this.previewImageUrls,
        // ⭐ 每张预览图对应的缩略图 id：滑动切图后关闭时飞回当前图位置
        thumbIds: this.previewThumbIds,
        initialIndex: this.previewIndex,
        // ⭐ 一镜到底起点矩形（点击缩略图相对窗口 vp 坐标/尺寸；用 $ 传引用，@Watch 回调中读到最新值）
        originX: $previewOriginX,
        originY: $previewOriginY,
        originW: $previewOriginW,
        originH: $previewOriginH,
        // ⭐ 沉浸式全屏仅横屏（状态栏应一直隐藏）：预览关闭不恢复状态栏；竖屏预览关闭恢复状态栏
        //   （用户确认：竖屏动态页预览退出后状态栏应恢复显示；横屏保持隐藏）
        immersiveMode: this.isLandscape
      })
    }
    .width('100%')
    .height('100%')
    // ⭐ 打开预览时背景页面微缩 + 下沉（iOS 式 modal 层级感，关闭时恢复）
    //    弹簧曲线 interpolatingSpring（与预览一镜到底一致）：下沉/恢复都带轻微回弹
    .scale({ x: this.previewSinkScale, y: this.previewSinkScale })
    .translate({ y: this.previewSinkY })
    .animation({ curve: curves.interpolatingSpring(0, 1, 228, 22) })
  }
}
