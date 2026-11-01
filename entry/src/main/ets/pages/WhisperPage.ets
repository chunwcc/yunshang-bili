// WhisperPage.ets — 私聊会话列表页（消息页）
import { router, mediaquery, display, LengthMetrics, curves } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hdsMaterial, HdsNavDestination, ScrollEffectType } from '@kit.UIDesignKit';
import { HdsMiniBarButton } from '../components/infra/HdsMiniBarButton';
import { WhisperChatView } from '../components/WhisperChatView';
import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';
import { ImGrpcService, ImSessionListResult, ImSession, ImUnreadCount } from '../services/ImGrpcService';
import { getUserFaceByMid } from '../api/BilibiliApi';
import { ChatEmote, ChatTextSegment } from '../utils/ChatEmote';

/** 头像 URL 尺寸压缩后缀（显示 46×46，96px 足够清晰且体积小得多） */
const FACE_SIZE_SUFFIX = '@96w_96h.webp';
/** ⚠️ 分栏左栏宽度可调节范围（左右占比 3:7）：最小 = 屏幕宽×30%（左30%右70%），最大 = 屏幕宽×70%（左70%右30%） */
const SPLIT_MIN_RATIO: number = 0.3;
const SPLIT_MAX_RATIO: number = 0.7;
/** 内存头像缓存（mid → face URL），避免同会话内重复请求 */
let faceCache: Map<number, string> = new Map<number, string>();
/** 持久化缓存是否已加载 */
let faceCacheLoaded: boolean = false;

/** 顶部四类通知入口配置 */
interface NoticeEntry {
  title: string;
  type: number;
  icon: string;
}

const NOTICE_ENTRIES: NoticeEntry[] = [
  { title: '回复我的', type: 1, icon: 'message_on_message_fill' },
  { title: '@我', type: 2, icon: 'at_outline' },
  { title: '收到的赞', type: 3, icon: 'give_the_thumbs_up' },
  { title: '系统通知', type: 4, icon: 'notification' }
];

@Component({ freezeWhenInactive: true })
export struct WhisperPage {
  /** 会话列表 */
  @State sessions: ImSession[] = [];
  /** 加载中 */
  @State isLoading: boolean = true;
  /** 加载失败 */
  @State loadError: string = '';
  /** 是否有更多 */
  @State hasMore: boolean = false;
  /** 加载更多中 */
  @State isLoadingMore: boolean = false;
  /** 下拉刷新中（⭐ 与首页同款指示器 + 逐卡弹入动画） */
  @State isRefreshing: boolean = false;
  /** 下拉刷新指示器文案（与首页 customRefreshComponent 同款状态机） */
  @State refreshBuilderText: string = '下拉刷新';
  // ⭐ 刷新完成会话卡片逐卡弹入（与首页 refreshData 两段式同款：旧卡错落淡出 → 新卡错落弹入）
  @State sessionVisible: boolean[] = [];
  @State animateSessions: boolean = false;
  private sessionDelays: number[] = [];
  private sessionTranslateYs: number[] = [];
  // ⭐ 底栏重复点击消息 Tab（与动态页同款）：未置顶 → 回顶；已置顶 → 刷新
  @StorageProp('scrollToTopFlag') @Watch('onScrollToTopFlag') scrollToTopFlag: number = 0;
  @StorageProp('refreshMsgFlag') @Watch('onRefreshMsgFlag') refreshMsgFlag: number = 0;
  /** 分页 offset */
  private offsetBytes: Uint8Array | null = null;
  /** 四类通知未读数（回复/@/赞/系统） */
  @State unreadList: number[] = [0, 0, 0, 0];
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  // ⚠️ 卡片样式/圆角设置（与首页/动态页一致）；消息卡片圆角已固定 40vp 不随此设置
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardListMargin') cardListMargin: number = 24;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 15;
  @StorageLink('cardCustomColor') cardCustomColor: string = '#007DFF';
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = true;
  // ⭐ 「消息页 Tab 自动隐藏」开关（关闭 = 消息页保留悬浮底栏，列表需预留底部空间避让）
  @StorageLink('msgTabAutoHide') msgTabAutoHide: boolean = false;
  @StorageLink('navIndicatorHeight') navIndicatorHeight: number = 0;

  /** 横屏检测（分栏用，与 DynamicsPage 同方案） */
  @State isLandscape: boolean = false;
  /** 表情表是否已加载（加载完成后会话预览中的 [xxx] 文本替换为表情图片） */
  @State emoteReady: boolean = false;
  private landscapeListener: mediaquery.MediaQueryListener | null = null;
  /** 分栏右侧当前会话 */
  @State chatTalkerId: number = 0;
  @State chatTalkerName: string = '';
  @State chatTalkerFace: string = '';
  /** 分栏左栏宽度（vp，PanGesture 拖动调整） */
  @State leftWidth: number = 400;
  private dragStartWidth: number = 0;
  /** ⭐ 会话列表 scroller（底栏滚动显隐要取"绝对偏移"来算 delta） */
  private listScroller: Scroller = new Scroller();
  /** ⭐ 底栏滚动显隐：上次滚动偏移 + 触发阈值（对齐首页/动态页的 10vp） */
  private lastScrollY: number = 0;
  private readonly SCROLL_THRESHOLD: number = 10;

  /**
   * 会话列表末尾空白占位的高度（避让悬浮底栏）
   * - 用于**列表最后一个 ListItem**（不是 List.padding）⇒ 随信息流一起滑动，
   *   而不是把内容区静态内缩、看着像"列表在底部被截断"
   * - 底栏可见时（「消息页 Tab 自动隐藏」关闭）= 96 + navIndicatorHeight；
   *   横屏消息页为双栏、底栏恒隐藏，返回 0（末项高度 0，无影响）
   */
  private listBottomPadding(): number {
    if (this.msgTabAutoHide || this.isLandscape) {
      return 0;
    }
    return 96 + this.navIndicatorHeight;
  }

  /**
   * ⭐ 会话列表滚动 → 悬浮底栏显隐（与首页 HomePage / 动态页 DynamicsPage 同款规则）：
   * 下滑（内容上移）delta > 10vp 收起底栏；反向上滑展开；滚回顶部 5vp 内复位展开。
   * ⚠️ 守卫：开关打开（消息页底栏本就恒隐藏）或横屏（双栏、底栏恒隐藏）时一律不接管 —
   *    否则会把本该隐藏的底栏"展开"出来。
   */
  private onMsgListScroll(absoluteOffset: number): void {
    // ⭐ 上报消息页滚动偏移（Index.handleTabClick 判断回顶/刷新用；放守卫前：横屏分栏同样上报）
    // ⚠️ 必须用 setOrCreate：msgScrollOffset 无 @StorageLink/@StorageProp 声明预创建 key，
    //    AppStorage.set 对不存在的 key 静默失败（返回 false 不写入）→ Index 恒读到 0 → 回顶永远不触发
    AppStorage.setOrCreate('msgScrollOffset', absoluteOffset);
    if (this.msgTabAutoHide || this.isLandscape) {
      return;
    }
    const delta: number = absoluteOffset - this.lastScrollY;
    if (absoluteOffset < 5) {
      // 回到顶部：复位展开
      this.lastScrollY = 0;
      AppStorage.set('bottomBarHidden', false);
    } else if (delta > this.SCROLL_THRESHOLD) {
      // 下滑（内容上移）：收起
      this.lastScrollY = absoluteOffset;
      AppStorage.set('bottomBarHidden', true);
    } else if (delta < -this.SCROLL_THRESHOLD) {
      // 上滑（内容下移）：展开
      this.lastScrollY = absoluteOffset;
      AppStorage.set('bottomBarHidden', false);
    }
  }

  async aboutToAppear(): Promise<void> {
    this.listenOrientationChange();
    // ⭐ 预加载 B站表情表（带重试等待：冷启动 Cookie 恢复竞态下自动重拉；完成后重渲染会话列表）
    ChatEmote.waitForLoaded().then(() => {
      this.emoteReady = true;
    });
    await this.loadLeftWidth();
    await this.loadSessions();
    this.loadUnread();
  }

  aboutToDisappear(): void {
    if (this.landscapeListener) {
      this.landscapeListener.off('change');
      this.landscapeListener = null;
    }
  }

  /** 注册媒体查询监听（方向变化，与 DynamicsPage/UpSpacePage 相同方案） */
  private listenOrientationChange(): void {
    try {
      const mediaQuery = this.getUIContext().getMediaQuery();
      this.landscapeListener = mediaQuery.matchMediaSync('(orientation: landscape)');
      this.isLandscape = this.landscapeListener.matches;
      this.landscapeListener.on('change', (result: mediaquery.MediaQueryResult) => {
        const newIsLandscape = result.matches;
        if (this.isLandscape !== newIsLandscape) {
          logInfo(`[WhisperPage] 方向变化: ${newIsLandscape ? '横屏' : '竖屏'}`);
          this.isLandscape = newIsLandscape;
        }
      });
    } catch (err) {
      logWarn(`[WhisperPage] 方向监听注册失败: ${errMsg(err)}`);
    }
  }

  /** 读取持久化的分栏左栏宽度（横屏分栏恢复上次调节） */
  private async loadLeftWidth(): Promise<void> {
    try {
      const context = AppStorage.get<common.UIAbilityContext>('appContext');
      if (!context) {
        return;
      }
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      const saved = await pref.get('whisperSplitLeftWidth', 400) as number;
      if (saved > 0) {
        this.leftWidth = saved;
      }
    } catch (err) {
      logWarn(`[WhisperPage] 读取分栏宽度失败: ${errMsg(err)}`);
    }
  }

  /** 保存分栏左栏宽度（拖动结束时调用，Persist Preferences） */
  private async saveLeftWidth(): Promise<void> {
    try {
      const context = AppStorage.get<common.UIAbilityContext>('appContext');
      if (!context) {
        return;
      }
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('whisperSplitLeftWidth', this.leftWidth);
      await pref.flush();
    } catch (err) {
      logWarn(`[WhisperPage] 保存分栏宽度失败: ${errMsg(err)}`);
    }
  }

  /**
   * 拉取四类通知未读数
   */
  private async loadUnread(): Promise<void> {
    try {
      const u: ImUnreadCount = await ImGrpcService.fetchTotalUnread();
      this.unreadList = [u.reply, u.at, u.like, u.sysMsg];
    } catch (err) {
      logWarn(`[WhisperPage] 未读数加载失败: ${errMsg(err)}`);
    }
  }

  /**
   * 进入通知列表页
   */
  private openNotice(type: number): void {
    try {
      router.pushUrl({
        url: 'pages/MsgNoticePage',
        params: {
          'type': type
        }
      });
    } catch (err) {
      logError(`[WhisperPage] 跳转通知页失败: ${errMsg(err)}`);
    }
  }

  /**
   * 下拉刷新（与首页 refreshData 两段式同款）：
   * ① 旧会话卡随机错落淡出（0~300ms）→ ② 并发重拉未读数 + 会话列表 →
   * ③ 新会话卡随机错落弹入（弹簧曲线，仿首页逐卡入场）
   */
  private async refreshAll(): Promise<void> {
    // ① 旧卡错落淡出（数据保留，卡片 opacity→0 / scale→0.8 / translateY 下沉）
    const oldCount = this.sessions.length;
    if (oldCount > 0) {
      this.animateSessions = true;
      for (let i = 0; i < oldCount; i++) {
        const idx = i;
        const delay = Math.floor(Math.random() * 300);
        setTimeout(() => {
          const nv = [...this.sessionVisible];
          if (idx < nv.length) {
            nv[idx] = false;
            this.sessionVisible = nv;
          }
        }, delay);
      }
    }
    // ② 重拉（保留旧数据展示，避免白屏）
    try {
      await Promise.all([this.loadUnread(), this.loadSessions()]);
    } catch (err) {
      logWarn(`[WhisperPage] 刷新失败: ${errMsg(err)}`);
    } finally {
      this.isRefreshing = false;
    }
    // ③ 新卡错落弹入（0~600ms 随机延迟 + 随机下沉距离，弹簧曲线带回弹）
    const count = this.sessions.length;
    if (count > 0) {
      this.sessionVisible = new Array<boolean>(count).fill(false);
      this.sessionDelays = [];
      this.sessionTranslateYs = [];
      for (let i = 0; i < count; i++) {
        this.sessionDelays.push(Math.floor(Math.random() * 600));
        this.sessionTranslateYs.push(Math.floor(Math.random() * 40) + 15);
      }
      setTimeout(() => {
        this.animateSessions = true;
        for (let i = 0; i < count; i++) {
          const idx = i;
          setTimeout(() => {
            const nv = [...this.sessionVisible];
            if (idx < nv.length) {
              nv[idx] = true;
              this.sessionVisible = nv;
            }
          }, this.sessionDelays[idx]);
        }
      }, 120);
    }
  }

  /** 底栏重复点击消息 Tab（未置顶）→ 会话列表回顶（与动态页同款动画） */
  private onScrollToTopFlag(): void {
    this.listScroller.scrollTo({
      xOffset: 0,
      yOffset: 0,
      animation: { duration: 300, curve: Curve.EaseOut }
    });
  }

  /** 底栏重复点击消息 Tab（已置顶）→ 刷新会话列表（点亮原生 Refresh） */
  private onRefreshMsgFlag(): void {
    this.isRefreshing = true;
    this.refreshAll();
  }

  /**
   * 拉取会话列表
   */
  private async loadSessions(): Promise<void> {
    this.isLoading = true;
    this.loadError = '';
    try {
      const result: ImSessionListResult = await ImGrpcService.fetchSessionList(null);
      this.sessions = result.sessions;
      this.hasMore = result.hasMore;
      this.offsetBytes = result.offsetBytes;
      logInfo(`[WhisperPage] 加载 ${this.sessions.length} 个会话`);
      // ⚠️ 首次进入横屏分栏：默认选中列表第一个（最顶上）的对话。
      //    会话列表异步加载，若不在加载完成后设置 chatTalkerId，右栏 WhisperChatView
      //    会用初始值 0 抢先拉取错误对话（日志：fetchSessionMsgs 先于 fetchSessionList）
      if (this.isLandscape && this.chatTalkerId === 0 && this.sessions.length > 0) {
        const first = this.sessions[0];
        this.chatTalkerId = first.talkerUid;
        this.chatTalkerName = first.sessionName;
        this.chatTalkerFace = first.face;
        logInfo(`[WhisperPage] 横屏分栏默认选中: ${first.sessionName}`);
      }
      // ⚠️ 头像补取不阻塞列表渲染：串行请求太慢会卡住 loading，异步后台补齐
      this.fetchFaces();
    } catch (err) {
      logError(`[WhisperPage] 加载失败: ${errMsg(err)}`);
      this.loadError = '加载失败，请检查网络';
    }
    this.isLoading = false;
  }

  /**
   * 对 face 为空的会话异步补取头像
   * ⚠️ 串行 30 个 REST 请求太慢（每个含 throttle+WBI，45秒+），改为并发限流（每批5个）
   */
  private async fetchFaces(): Promise<void> {
    // 首次加载时从持久化缓存读取 mid→face 映射
    if (!faceCacheLoaded) {
      await this.loadFaceCache();
      faceCacheLoaded = true;
    }
    const missing: number[] = [];  // 需要补头像的会话下标
    for (let i = 0; i < this.sessions.length; i++) {
      const s = this.sessions[i];
      if (s.face) {
        continue;
      }
      // ⚠️ 命中缓存直接使用，不再发 REST 请求
      const cached = faceCache.get(s.talkerUid);
      if (cached && s.talkerUid > 0) {
        const updated = new ImSession();
        updated.talkerUid = s.talkerUid;
        updated.sessionName = s.sessionName;
        updated.face = cached;
        updated.lastMsg = s.lastMsg;
        updated.unread = s.unread;
        updated.timestamp = s.timestamp;
        updated.isPinned = s.isPinned;
        updated.isMuted = s.isMuted;
        const next: ImSession[] = [...this.sessions];
        next[i] = updated;
        this.sessions = next;
        continue;
      }
      if (s.talkerUid > 0) {
        missing.push(i);
      }
    }
    logInfo(`[WhisperPage] 需补头像 ${missing.length} 个`);
    const BATCH = 5;
    for (let b = 0; b < missing.length; b += BATCH) {
      const batch = missing.slice(b, Math.min(b + BATCH, missing.length));
      const jobs: Promise<void>[] = [];
      for (let k = 0; k < batch.length; k++) {
        jobs.push(this.fetchOneFace(batch[k]));
      }
      await Promise.all(jobs);
    }
    logInfo(`[WhisperPage] 头像补取完成`);
  }

  /**
   * 从 Preferences 加载 mid→face 缓存
   */
  private async loadFaceCache(): Promise<void> {
    try {
      const context = AppStorage.get<common.UIAbilityContext>('appContext');
      if (!context) {
        return;
      }
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      const stored = await pref.get('whisperFaceCache', '') as string;
      if (stored && stored.length > 0) {
        const arr = JSON.parse(stored) as string[];
        for (let i = 0; i + 1 < arr.length; i += 2) {
          const mid = parseInt(arr[i]);
          if (mid > 0 && arr[i + 1]) {
            faceCache.set(mid, arr[i + 1]);
          }
        }
        logInfo(`[WhisperPage] 加载头像缓存 ${faceCache.size} 条`);
      }
    } catch (err) {
      logWarn(`[WhisperPage] 加载头像缓存失败: ${errMsg(err)}`);
    }
  }

  /**
   * 保存一条 mid→face 到持久化缓存
   */
  private async saveFaceCache(mid: number, face: string): Promise<void> {
    faceCache.set(mid, face);
    try {
      const context = AppStorage.get<common.UIAbilityContext>('appContext');
      if (!context) {
        return;
      }
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      const arr: string[] = [];
      faceCache.forEach((v: string, k: number) => {
        arr.push(k.toString(), v);
      });
      await pref.put('whisperFaceCache', JSON.stringify(arr));
      await pref.flush();
    } catch (err) {
      logWarn(`[WhisperPage] 保存头像缓存失败: ${errMsg(err)}`);
    }
  }

  /**
   * 补取单个会话头像（按下标）
   */
  private async fetchOneFace(idx: number): Promise<void> {
    const s = this.sessions[idx];
    if (!s || s.face || s.talkerUid <= 0) {
      return;
    }
    try {
      const face = await getUserFaceByMid(s.talkerUid);
      // ⚠️ URL 加尺寸参数：显示仅 46×46，96px 足够且下载体积小得多
      let faceUrl = face;
      if (faceUrl && faceUrl.indexOf('@') < 0) {
        faceUrl = faceUrl + FACE_SIZE_SUFFIX;
      }
      logInfo(`[WhisperPage] mid=${s.talkerUid} 头像=${faceUrl ? faceUrl.substring(0, 60) : '空'}`);
      if (faceUrl) {
        this.saveFaceCache(s.talkerUid, faceUrl);
        // ⚠️ ArkTS 禁止对象展开（arkts-no-spread），逐字段拷贝新对象
        const updated = new ImSession();
        updated.talkerUid = s.talkerUid;
        updated.sessionName = s.sessionName;
        updated.face = faceUrl;
        updated.lastMsg = s.lastMsg;
        updated.unread = s.unread;
        updated.timestamp = s.timestamp;
        updated.isPinned = s.isPinned;
        updated.isMuted = s.isMuted;
        const next: ImSession[] = [...this.sessions];
        next[idx] = updated;
        this.sessions = next;
      }
    } catch (err) {
      logWarn(`[WhisperPage] 会话 ${s.sessionName} 头像获取失败: ${errMsg(err)}`);
    }
  }

  /**
   * 触底加载更多会话
   */
  private async loadMore(): Promise<void> {
    if (this.isLoadingMore || !this.hasMore || this.offsetBytes === null) {
      return;
    }
    this.isLoadingMore = true;
    try {
      const result: ImSessionListResult = await ImGrpcService.fetchSessionList(this.offsetBytes);
      this.sessions = [...this.sessions, ...result.sessions];
      this.hasMore = result.hasMore;
      this.offsetBytes = result.offsetBytes;
      // ⚠️ 新加载的会话也异步补头像，不阻塞 isLoadingMore 复位
      this.fetchFaces();
    } catch (err) {
      logWarn(`[WhisperPage] 加载更多失败: ${errMsg(err)}`);
    }
    this.isLoadingMore = false;
  }

  /**
   * 进入会话
   */
  private openWhisper(s: ImSession): void {
    try {
      // ⚠️ 横屏分栏：更新右侧聊天会话（@Watch 触发重新加载）；竖屏：整页跳转
      if (this.isLandscape) {
        this.chatTalkerId = s.talkerUid;
        this.chatTalkerName = s.sessionName;
        this.chatTalkerFace = s.face;
      } else {
        router.pushUrl({
          url: 'pages/WhisperDetailPage',
          params: {
            'talkerId': s.talkerUid,
            'name': s.sessionName,
            'face': s.face
          }
        });
      }
    } catch (err) {
      logError(`[WhisperPage] 跳转失败: ${errMsg(err)}`);
    }
  }

  /**
   * 格式化时间
   */
  private formatTime(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d = new Date(ts * 1000);
    const now = new Date();
    if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()) {
      return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
    }
    return `${(d.getMonth() + 1).toString().padStart(2, '0')}-${d.getDate().toString().padStart(2, '0')}`;
  }

  /**
   * 会话卡片背景色（跟随卡片样式选项，与 ProfilePage.getCardItemBg 一致）
   */
  private getCardItemBg(): string {
    if (this.cardTransparentStyle) {
      return this.isDarkMode
        ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
        : `rgba(255,255,255,${this.cardBgOpacity / 100})`;
    }
    return this.isDarkMode ? '#2C2C2C' : '#E8E8E8';
  }

  /**
   * 会话卡片边框色（与首页 CardStyleSheet.getPreviewBorderColor 一致）
   */
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

  /**
   * 透明度(0-100) → 两位十六进制（与首页一致）
   */
  private opacityToHexAlpha(opacity: number): string {
    const val = Math.round(opacity / 100 * 255);
    const hex = val.toString(16);
    return hex.length === 1 ? '0' + hex : hex;
  }

  /**
   * 会话预览文字 + 表情（Text + Span/ImageSpan 行内混排，自然换行）
   */
  @Builder
  sessionLastMsg(s: ImSession) {
    Text() {
      ForEach(ChatEmote.parse(s.lastMsg || '暂无消息'), (seg: ChatTextSegment, index: number) => {
        if (seg.emoteUrl) {
          ImageSpan(seg.emoteUrl)
            .width(22)
            .height(22)
            .objectFit(ImageFit.Contain)
            .verticalAlign(ImageSpanAlignment.CENTER)
        } else {
          Span(seg.text)
        }
      }, (seg: ChatTextSegment, index: number) => `slmsg_${index}`)
    }
    .fontSize(13)
    .fontColor(this.isDarkMode ? '#999999' : '#333333')
    // ⚠️ 最新消息预览最多 8 行，超出省略（卡片高度随之收敛）
    .maxLines(8)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
    .layoutWeight(1)
  }

  @Builder
  sessionRow(s: ImSession) {
    Row() {
      // 头像（有图显示真实头像，无图时用首字占位）
      Stack() {
        Circle()
          .width(46).height(46)
          .fill(this.isDarkMode ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.08)')
        if (s.face) {
          Image(s.face)
            .width(46).height(46)
            .borderRadius(23)
            .objectFit(ImageFit.Cover)
        } else {
          // 头像未加载成功时显示默认图标
          Image($r('app.media.tx_old'))
            .width(46).height(46)
            .borderRadius(23)
            .objectFit(ImageFit.Cover)
        }
      }
      .width(46).height(46)

      Column() {
        Row() {
          Text(s.sessionName || `用户${s.talkerUid}`)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (s.isPinned) {
            Text('置顶')
              .fontSize(10)
              .fontColor('#FF6699')
              .margin({ left: 6 })
          }
          Text(this.formatTime(s.timestamp))
            .fontSize(11)
            .fontColor(this.isDarkMode ? '#999999' : '#333333')
            .margin({ left: 8 })
        }
        .width('100%')

        Row() {
          this.sessionLastMsg(s)
          if (s.unread > 0) {
            Text(s.unread > 99 ? '99+' : `${s.unread}`)
              .fontSize(10)
              .fontColor('#FFFFFF')
              .backgroundColor('#FF4444')
              .borderRadius(9)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .margin({ top: 4 })
        .alignItems(VerticalAlign.Top)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 16, bottom: 16 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.getCardItemBg())
    // ⚠️ 消息卡片固定 40vp 圆角，不跟随「卡片圆角」设置（消息页统一胶囊风格）
    .borderRadius(40)
    .border({ width: this.cardBorderWidth, color: this.getCardItemBorder() })
    .onClick(() => {
      this.openWhisper(s);
    })
  }

  /** 下拉刷新指示器（与首页 customRefreshComponent 同款布局与配色） */
  @Builder
  msgRefreshIndicator() {
    Stack() {
      Column() {
        LoadingProgress()
          .width(32)
          .height(32)
          .color(this.customThemeColor)
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
   * 会话列表主体（透明透出 Index 全局壁纸 + 占位/通知入口/会话列表）
   * ⚠️ 抽为 @Builder：横屏分栏左栏与竖屏单页共用
   */
  @Builder
  sessionListBody() {
    Stack() {
      // ⚠️ 内容层透明：背景直接透出 Index 全局壁纸层（与首页/我的页一致）
      //    不自绘壁纸——避免 Tab 切换动画带着壁纸层位移（背景被拖动），
      //    且全局层统一处理 builtin/custom/default/custom_color 等壁纸类型
      Column() {
        // ── 会话列表（通知入口已内嵌为首个列表项，随列表滑动）──
      if (this.isLoading && this.sessions.length === 0) {
        Column() {
          LoadingProgress().width(32).height(32).color('#FF6699')
          Text('加载中...').fontSize(13).fontColor('#999999').margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.loadError && this.sessions.length === 0) {
        Column() {
          Text(this.loadError).fontSize(14).fontColor('#FF4444')
          Button('重试')
            .fontSize(14)
            .margin({ top: 12 })
            .onClick(() => {
              this.loadSessions();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.sessions.length === 0) {
        Column() {
          Text('暂无私信')
            .fontSize(14)
            .fontColor('#999999')
          Text('去个人主页点「发消息」开始聊天')
            .fontSize(12)
            .fontColor('#999999')
            .margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // ⭐ 下拉刷新（与首页同款指示器）：会话列表外包 Refresh；刷新期间保留旧列表数据
        Refresh({ refreshing: $$this.isRefreshing, builder: this.msgRefreshIndicator() }) {
        List({ space: this.cardListMargin, scroller: this.listScroller }) {
          // ⚠️ 顶部空白占位（不带颜色，露出整页自定义背景）：竖屏 50vp / 横屏 20vp
          ListItem() {
            Column()
              .width('100%')
              .height(this.isLandscape ? 20 : 50)
          }
          // ⚠️ 通知入口作为首个列表项，随会话列表一起滑动
          ListItem() {
            // ⚠️ 竖屏收拢间距：固定列宽 + columnsGap + 外层 Row 居中（Grid 无 justifyContent）；
            //    横屏分栏保持自适应列数原样
            Row() {
              // ⚠️ Grid 自适应列数：左栏宽(≥400vp)单排 4 个，窄(<400vp)双排 2×2，随分割线拖动实时变化
              Grid() {
              ForEach(NOTICE_ENTRIES, (entry: NoticeEntry, index: number) => {
                GridItem() {
                  Column() {
                    Stack() {
                      // ⚠️ 沉浸光感圆形遮罩（与动态页分类按钮一致）
                      HdsMiniBarButton({
                        barWidth: 40,
                        barHeight: 40,
                        contentPadding: 4,
                        materialType: hdsMaterial.MaterialType.IMMERSIVE,
                        materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
                        barOverlap: true,
                        barPosition: BarPosition.End,
                        // ⚠️ 必须走组件自带 onTabBarClick：HdsTabs 会消费图标区域的点击事件，
                        //    外层 Column.onClick 收不到（表现为点图标无反应、点文字才有反应）
                        onButtonClick: () => {
                          this.openNotice(entry.type);
                        }
                      }) {
                        Image($r('app.media.' + entry.icon))
                          .width(24).height(24)
                          .objectFit(ImageFit.Contain)
                          .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                      }
                      if (this.unreadList[index] > 0) {
                        Text(this.unreadList[index] > 99 ? '99+' : `${this.unreadList[index]}`)
                          .fontSize(10)
                          .fontColor('#FFFFFF')
                          .backgroundColor('#FF4444')
                          .borderRadius(8)
                          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                          .position({ top: -4, right: -6 })
                      }
                    }
                    .width(40).height(40)

                    Text(entry.title)
                      .fontSize(12)
                      .fontColor(this.isDarkMode ? '#AAAAAA' : '#000000')
                      .margin({ top: 6 })
                  }
                  .onClick(() => {
                    this.openNotice(entry.type);
                  })
                }
              }, (entry: NoticeEntry) => `${entry.type}`)
            }
            // ⚠️ 单排时入口间距 = 列宽(leftWidth/4) - 内容宽(≈52vp)；间距 < 5vp 才切双排（leftWidth < 228）
            // ⚠️ 竖屏用 1fr 均分（固定 '56vp' 列宽会退化成一列竖排），配合收窄宽度+columnsGap 缩小间距
            .columnsTemplate(this.isLandscape
              ? (this.leftWidth / 4 - 52 >= 5 ? '1fr 1fr 1fr 1fr' : '1fr 1fr')
              : '1fr 1fr 1fr 1fr')
            .columnsGap(this.isLandscape ? 0 : 8)
            .rowsGap(10)
            .width(this.isLandscape ? '100%' : 248)
            .padding({ top: 14, bottom: 14 })
        }
        .width('100%')
        .justifyContent(this.isLandscape ? FlexAlign.Start : FlexAlign.Center)
      }
          ForEach(this.sessions, (s: ImSession, index: number) => {
            ListItem() {
              this.sessionRow(s)
            }
            // ⭐ 刷新逐卡动画（与首页卡片同款）：淡出 = opacity 0 / 缩小 0.8 / 下沉；
            //    弹入 = 弹簧曲线回弹复位。未开启动画或越界下标时保持原样（分页追加项不动画）
            .opacity(this.sessionVisible.length > index ? (this.sessionVisible[index] ? 1 : 0) : 1)
            .scale({
              x: this.sessionVisible.length > index ? (this.sessionVisible[index] ? 1 : 0.8) : 1,
              y: this.sessionVisible.length > index ? (this.sessionVisible[index] ? 1 : 0.8) : 1
            })
            .translate({
              y: this.sessionVisible.length > index
                ? (this.sessionVisible[index] ? 0 : (this.sessionTranslateYs[index] || 60))
                : 0
            })
            .animation(!this.animateSessions ? { duration: 0 } : {
              duration: 1400,
              curve: curves.springCurve(0.15, 1, 80, 8)
            })
            // ⚠️ key 必须包含 face：face 异步补取后 key 变化 → 触发重建渲染头像（否则 skip mark dirty 不刷新）
            //    emoteReady：表情表加载完成后强制重建，刷新 [xxx] 预览文字为表情图片
          }, (s: ImSession, index: number) => `${s.talkerUid}_${s.face.length > 0 ? '1' : '0'}_${this.emoteReady ? 1 : 0}_${index}`)
          // ⭐ 列表末尾空白占位：**跟随信息流一起滑动**（原先是 List 的 padding bottom = 静态内缩，
          //    观感像"列表在底部被硬截断"）。高度扣掉 List 的 space —— 它会自动补在两项之间。
          ListItem() {
            Column()
              .width('100%')
              .height(Math.max(0, this.listBottomPadding() - this.cardListMargin))
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .padding({ left: this.cardListMargin, right: this.cardListMargin })
        // ⭐ 滑动联动底栏显隐（与首页/动态页同款；用绝对偏移算 delta）
        .onWillScroll((_dx: number, _dy: number) => {
          this.onMsgListScroll(this.listScroller.currentOffset().yOffset);
        })
        .onReachEnd(() => {
          this.loadMore();
        })
        }
        // ⭐ Refresh 承载原 List 的尺寸属性；onRefreshing 触发并发重拉
        .width('100%')
        .layoutWeight(1)
        // ⭐ 指示器文案状态机（与首页同款语义，去掉"长拉打开搜索"）
        .onStateChange((refreshStatus: RefreshStatus) => {
          if (refreshStatus === RefreshStatus.Drag) {
            this.refreshBuilderText = '下拉刷新';
          } else if (refreshStatus === RefreshStatus.OverDrag) {
            this.refreshBuilderText = '释放刷新';
          } else if (refreshStatus === RefreshStatus.Refresh) {
            this.refreshBuilderText = '正在刷新';
          } else if (refreshStatus === RefreshStatus.Done) {
            this.refreshBuilderText = '刷新成功';
          }
        })
        .onRefreshing(() => {
          this.refreshAll();
        })
      }
      }
      .width('100%')
      .height('100%')
      // ⚠️ 内容层透明，透出 Index 全局壁纸（与首页/我的页一致）
    }
    .width('100%')
    .height('100%')
  }

  build() {
    HdsNavDestination() {
      // ⚠️ 手动分栏（Navigation 嵌入 HdsTabs Tab 内容不渲染，改用条件布局 + mediaquery 方向监听）
      if (this.isLandscape) {
        // ⚠️ 手动分栏（对齐官方 RowSplit 视觉：左右栏直接相邻，只有一根细线；拖动热区独立放大不占布局）
        Stack() {
          Row() {
            Column() {
              this.sessionListBody()
            }
            .width(this.leftWidth)
            .height('100%')
            WhisperChatView({
              talkerId: this.chatTalkerId,
              talkerName: this.chatTalkerName,
              talkerFace: this.chatTalkerFace
            })
              .layoutWeight(1)
              .height('100%')
          }
          .width('100%')
          .height('100%')
          // 视觉分割线：只有一根 1vp 细线（position 跟随左栏宽度，不占布局→无背景色带）
          Column()
            .width(1)
            .height('100%')
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.25)' : 'rgba(0,0,0,0.20)')
            .position({ x: this.leftWidth - 0.5 })
          // 透明触控热区：20vp（position 跟随分割线，不占布局），PanGesture 拖动
          Column()
            .width(20)
            .height('100%')
            .position({ x: this.leftWidth - 10 })
            .gesture(
              PanGesture({ direction: PanDirection.Horizontal, distance: 0 })
                .onActionStart(() => {
                  this.dragStartWidth = this.leftWidth;
                })
                .onActionUpdate((event: GestureEvent) => {
                  // ⚠️ 左栏可调范围 = 屏幕宽 30%~70%（左30%右70% ↔ 左70%右30%）
                  const disp = display.getDefaultDisplaySync();
                  const screenW = disp.width / disp.densityPixels;
                  const minW = screenW * SPLIT_MIN_RATIO;
                  const maxW = screenW * SPLIT_MAX_RATIO;
                  const next = Math.min(maxW, Math.max(minW, this.dragStartWidth + event.offsetX));
                  if (next !== this.leftWidth) {
                    this.leftWidth = next;
                  }
                })
                .onActionEnd(() => {
                  // ⚠️ 拖动结束持久化左栏宽度，下次进入恢复
                  this.saveLeftWidth();
                })
            )
        }
        .width('100%')
        .height('100%')
        // ⚠️ 透明背景：透出 Index 全局壁纸层（与首页/我的页一致）；右栏 WhisperChatView 自带底色
      } else {
        this.sessionListBody()
      }
    }
    .hideBackButton(true)
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
        title: { mainTitle: '通知' }
      }
    })
  }
}
