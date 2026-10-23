/**
 * LivePage.ets — 直播信息流页面（B站风格）
 *
 * 功能：
 * - 顶部悬浮毛玻璃分区 Tab 栏（在历史/搜索按钮下方）
 * - 信息流穿透效果：内容在 Tab 栏下方滚动
 * - 2列直播卡片网格 + 入场弹簧动画
 * - 下拉刷新 + 上拉加载更多
 */
import { curves, mediaquery, display } from '@kit.ArkUI';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { VibrateUtils } from '../utils/VibrateUtils';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  LiveFeedRoom,
  LiveArea,
  fetchRecommendedLiveRooms,
  fetchLiveRoomsByArea,
  fetchLiveAreas,
  fetchFollowedLiveRooms,
  formatOnlineCount
} from '../api/LiveFeedApi';
import { ImmersiveLightWrapper } from '../components/ImmersiveLightWrapper';
import { HdsMiniBarButton } from '../components/infra/HdsMiniBarButton';

/** 数据源封装，供 LazyForEach 使用 */
class LiveDataSource implements IDataSource {
  private items: LiveFeedRoom[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): LiveFeedRoom {
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

  notifyDataAdd(startIndex: number): void {
    this.listeners.forEach(listener => listener.onDataAdd(startIndex));
  }

  addItems(newItems: LiveFeedRoom[]): void {
    const startIdx = this.items.length;
    this.items.push(...newItems);
    this.notifyDataAdd(startIdx);
  }

  reloadItems(allItems: LiveFeedRoom[]): void {
    this.items = allItems;
    this.notifyDataReload();
  }

  getRawItems(): LiveFeedRoom[] {
    return this.items;
  }
}

interface AreaTab {
  id: number;
  name: string;
  isSelected: boolean;
  pinned: boolean;
}

@Component({ freezeWhenInactive: true })
export struct LivePage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#00A1D6';
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @StorageLink('scrollToTopFlag') @Watch('onScrollToTop') scrollToTopFlag: number = 0;
  @StorageLink('tabBarHidden') tabBarHidden: boolean = false;
  @StorageLink('refreshLiveFlag') @Watch('onRefreshFlagChange') refreshFlag: number = 0;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = false;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 40;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1.5;
  @StorageLink('cardCustomColor') cardCustomColor: string = '';
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  @StorageLink('cardListMargin') cardListMargin: number = 0;
  @StorageLink('cardStyleLiveCategory') cardStyleLiveCategory: boolean = true;
  @StorageLink('livePanelCollapseSignal') @Watch('onCollapseSignal') livePanelCollapseSignal: number = 0;
  @StorageLink('da') da: boolean = false;

  // 数据
  @State dataSource: LiveDataSource = new LiveDataSource();
  @State areas: AreaTab[] = [{ id: 0, name: '全部', isSelected: true, pinned: true }];
  @State selectedAreaId: number = 0;

  // ⭐ 关注的UP主正在直播列表（信息流上方横向区块）
  @State followedLiveRooms: LiveFeedRoom[] = [];
  @State showAllFollowed: boolean = false;   // 关注主播折叠展开
  private followedLoading: boolean = false;  // 防止重复请求

  // 加载状态
  @State lastScrollY: number = 0;
  // ⭐ 滚动方向阈值：与分类页一致，delta 为自上次触发以来的累积位移，慢速滑动也能触发显隐
  private readonly SCROLL_THRESHOLD: number = 20;
  @State isLoading: boolean = true;
  @State isRefreshing: boolean = false;
  @State isLoadingMore: boolean = false;
  @State hasMore: boolean = true;

  // 分页
  private pageNum: number = 1;
  private readonly PAGE_SIZE: number = 30;

  // 已显示的 roomId 集合（去重）
  private roomIdSet: Set<number> = new Set();

  // 滚动控制器
  private scroller: Scroller = new Scroller();
  private tabScroller: Scroller = new Scroller();

  // 折叠展开
  @State isCategoriesExpanded: boolean = false;
  @State isEditing: boolean = false;
  private readonly MAX_VISIBLE_TABS: number = 4;
  /** ⭐ 长条胶囊宽度（动态计算） */
  @State liveBarW: number = 200;

  // 下拉刷新状态
  @State refreshBuilderText: string = '下拉刷新';
  private longPullTimer: number = -1;
  private longPullTriggered: boolean = false;
  @State showSearchIcon: boolean = false;

  // 卡片入场动画
  @State cardsVisible: boolean[] = [];
  @State isBulkLoading: boolean = false;

  // 横竖屏检测
  @State isLandscape: boolean = false;
  private landscapeListener: mediaquery.MediaQueryListener | null = null;
  private cardDelays: number[] = [];
  private cardTranslateYs: number[] = [];

  // Tab 栏浮动高度：状态栏 + HdsNavigation mini 标题栏（含历史/搜索按钮）让 Tab 出现在按钮下方
  private readonly TAB_BAR_HEIGHT: number = 56;
  // HdsNavigation mini 标题栏高度（含历史/搜索按钮区域）
  private readonly TITLE_BAR_HEIGHT: number = 48;
  private get tabBarTopOffset(): number {
    return this.statusBarHeight + this.TITLE_BAR_HEIGHT;
  }

  aboutToAppear() {
    this.loadAreas();
    this.loadLiveRooms(true);
    this.loadFollowedLiveRooms();
    this.setupMediaQuery();
  }

  /** ⭐ 动态计算长条胶囊宽度：根据标签文字内容自适应，不占满屏幕 */
  private recalcLiveBarW(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const screenW = this.getUIContext().px2vp(d.width);
      const maxBarW = Math.max(200, screenW - 24 - 16);
      const pinnedTabs = this.areas.filter((t: AreaTab) => t.pinned);
      if (pinnedTabs.length === 0) {
        this.liveBarW = maxBarW;
        return;
      }
      const fontSize = 14;
      const itemPadding = 24;
      const itemSpace = 8;
      const rowPadding = 8;
      let totalW = rowPadding;
      for (const tab of pinnedTabs) {
        let textW = 0;
        for (const ch of tab.name) {
          textW += (ch.charCodeAt(0) > 0x4e00 && ch.charCodeAt(0) < 0x9fff) ? fontSize : fontSize * 0.55;
        }
        totalW += textW + itemPadding + itemSpace;
      }
      totalW -= itemSpace;
      this.liveBarW = Math.min(totalW, maxBarW);
    } catch (_) {
      this.liveBarW = 340;
    }
  }

  aboutToDisappear() {
    this.landscapeListener?.off('change');
  }

  private setupMediaQuery(): void {
    this.landscapeListener = this.getUIContext().getMediaQuery().matchMediaSync('(min-aspect-ratio: 1.4)');
    this.landscapeListener.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isLandscape = result.matches;
    });
    this.isLandscape = this.landscapeListener.matches;
  }

  // ==================== 数据加载 ====================

  private async loadAreas(): Promise<void> {
    try {
      const areas = await fetchLiveAreas();
      if (areas.length > 0) {
        // 先按默认方式创建
        let tabList: AreaTab[] = areas.map((a: LiveArea, idx: number) => ({
          id: a.id,
          name: a.name,
          isSelected: a.id === this.selectedAreaId,
          pinned: idx < this.MAX_VISIBLE_TABS
        }) as AreaTab);
        // 从 Preferences 恢复保存的 pinned 状态
        const savedIds: number[] = await this.loadPinnedAreaIds();
        if (savedIds.length > 0) {
          tabList = tabList.map((tab: AreaTab) => ({
            id: tab.id,
            name: tab.name,
            isSelected: tab.isSelected,
            pinned: savedIds.indexOf(tab.id) >= 0
          }) as AreaTab);
        }
        this.areas = tabList;
      }
      this.recalcLiveBarW();
    } catch (err) {
      logError(`[LivePage] 加载分区失败: ${err}`);
    }
  }

  // 持久化：保存已固定的分区ID列表
  private async savePinnedAreas(): Promise<void> {
    try {
      const pinnedIds: number[] = this.areas
        .filter((a: AreaTab) => a.pinned)
        .map((a: AreaTab) => a.id);
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref: preferences.Preferences = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('livePinnedAreas', JSON.stringify(pinnedIds));
      await pref.flush();
    } catch (_e) {}
  }

  // 持久化：读取之前保存的固定分区ID列表
  private async loadPinnedAreaIds(): Promise<number[]> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref: preferences.Preferences = await preferences.getPreferences(context, 'my_app_settings');
      const raw: string = await pref.get('livePinnedAreas', '') as string;
      if (raw) {
        return JSON.parse(raw) as number[];
      }
    } catch (_e) {}
    return [];
  }

  private async loadLiveRooms(isRefresh: boolean): Promise<void> {
    try {
      if (isRefresh) {
        this.isLoading = true;
        this.pageNum = 1;
        this.roomIdSet.clear();
      } else {
        this.isLoadingMore = true;
      }

      let rooms: LiveFeedRoom[];
      if (this.selectedAreaId === 0) {
        rooms = await fetchRecommendedLiveRooms(this.pageNum, this.PAGE_SIZE);
      } else {
        rooms = await fetchLiveRoomsByArea(this.selectedAreaId, this.pageNum, this.PAGE_SIZE);
      }

      const uniqueRooms: LiveFeedRoom[] = [];
      for (const room of rooms) {
        if (!this.roomIdSet.has(room.roomId)) {
          this.roomIdSet.add(room.roomId);
          uniqueRooms.push(room);
        }
      }

      if (isRefresh) {
        this.dataSource.reloadItems(uniqueRooms);
        this.prepareCardAnimation();
      } else {
        const beforeCount = this.dataSource.totalCount();
        this.dataSource.addItems(uniqueRooms);
        this.prepareMoreAnimation(beforeCount);
      }

      this.hasMore = uniqueRooms.length >= this.PAGE_SIZE;
      this.pageNum++;
    } catch (err) {
      logError(`[LivePage] 加载直播列表失败: ${err}`);
    } finally {
      this.isLoading = false;
      this.isRefreshing = false;
      this.isLoadingMore = false;
    }
  }

  /**
   * ⭐ 加载关注的UP主中正在直播的房间（信息流上方区块）
   * 需要登录 Cookie；失败时静默清空区块
   */
  private async loadFollowedLiveRooms(): Promise<void> {
    if (this.followedLoading) return;
    this.followedLoading = true;
    try {
      const rooms: LiveFeedRoom[] = await fetchFollowedLiveRooms(1, 50);
      this.followedLiveRooms = rooms;
      this.showAllFollowed = false;
    } catch (err) {
      logError(`[LivePage] 加载关注直播失败: ${err}`);
      this.followedLiveRooms = [];
    } finally {
      this.followedLoading = false;
    }
  }

  private prepareCardAnimation(): void {
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
      this.cardsVisible = new Array(count).fill(true);
      this.isBulkLoading = false;
    } else {
      setTimeout(() => {
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
  }

  private prepareMoreAnimation(beforeCount: number): void {
    const newTotal = this.dataSource.totalCount();
    const currentVisible = this.cardsVisible.length;
    if (newTotal > currentVisible) {
      const addCount = newTotal - currentVisible;
      const extendedVisible: boolean[] = [...this.cardsVisible, ...new Array<boolean>(addCount).fill(false)];
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
  }

  private onScrollToTop(): void {
    if (this.scroller) {
      this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300 } });
    }
  }

  private onRefreshFlagChange(): void {
    this.loadLiveRooms(true);
    this.loadFollowedLiveRooms();
  }

  private onRefresh(): void {
    this.isRefreshing = true;
    this.loadLiveRooms(true);
    this.loadFollowedLiveRooms();
  }

  private loadMore(): void {
    if (this.isLoadingMore || !this.hasMore || this.isRefreshing) return;
    this.loadLiveRooms(false);
  }

  private onAreaSelect(areaId: number): void {
    if (areaId === this.selectedAreaId) return;
    this.selectedAreaId = areaId;
    this.areas = this.areas.map(a => ({
      id: a.id,
      name: a.name,
      isSelected: a.id === areaId,
      pinned: a.pinned
    }) as AreaTab);
    this.loadLiveRooms(true);
  }

  // ==================== 页面跳转 ====================

  private enterRoom(room: LiveFeedRoom): void {
    if (room.roomId <= 0) return;
    this.collapsePanel();
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/LivePlayerPage',
      params: { roomId: room.roomId }
    });
  }

  // ==================== 工具方法 ====================

  getThemeColor(): string {
    return this.customThemeColor || '#00A1D6';
  }

  private expandPanel(): void {
    this.isCategoriesExpanded = true;
    this.recalcLiveBarW();
  }

  private collapsePanel(): void {
    this.isCategoriesExpanded = false;
    this.recalcLiveBarW();
    if (this.isEditing) {
      this.isEditing = false;
      this.savePinnedAreas();
    }
  }

  private onCollapseSignal(): void {
    this.collapsePanel();
  }

  private formatShortCount(count: number): string {
    if (count >= 10000) {
      return (count / 10000).toFixed(1) + '万';
    }
    return String(count);
  }

  private opacityToHexAlpha(opacity: number): string {
    const clamped = Math.max(0, Math.min(100, opacity));
    const hex = Math.round(clamped / 100 * 255).toString(16).toUpperCase();
    return hex.length < 2 ? '0' + hex : hex;
  }

  private get cardBg(): string {
    // 使用稍微不同的颜色以区分页面背景
    return this.isDarkMode ? '#1E1E1E' : '#FAFAFA';
  }

  // ⭐ 面板展开时悬浮 Tab 栏向左滑出屏幕的距离（需大于屏宽，确保完全滑出）
  private panelSlideOutX(): number {
    return 1200;
  }

  // ⭐ 页面显示/隐藏时重置下拉状态
  onPageShow(): void {
    this.isRefreshing = false;
    this.showSearchIcon = false;
    this.refreshBuilderText = '下拉刷新';
    this.longPullTriggered = false;
    if (this.longPullTimer !== -1) {
      clearTimeout(this.longPullTimer);
      this.longPullTimer = -1;
    }
  }

  // ==================== 构建UI ====================

  @Builder
  customRefreshComponent() {
    Column() {
      if (this.showSearchIcon) {
        Image($r('app.media.ic_public_search_filled'))
          .width(32).height(32)
          .objectFit(ImageFit.Contain)
          .fillColor(this.getThemeColor())
      } else {
        LoadingProgress()
          .width(32).height(32)
          .color(this.getThemeColor())
      }
      Text(this.refreshBuilderText)
        .fontSize(12)
        .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        .margin({ top: 4 })
    }
    .width('100%')
    .height(60)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * ⭐ 直播卡片
   */
  @Builder
  LiveCard(room: LiveFeedRoom) {
    Column() {
      // ---- 封面区 ----
      Stack() {
        Image(room.cover ? room.cover : '')
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
        Row() {
          Image($r('app.media.ic_public_screencap'))
            .width(12).height(12)
            .fillColor(Color.White)
          Text(formatOnlineCount(room.online))
            .fontSize(11)
            .fontColor(Color.White)
            .margin({ left: 3 })
        }
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor('rgba(0,0,0,0.55)')
        .borderRadius(4)
        .position({ bottom: 6, right: 6 })

        // 分区标签
        if (room.areaName) {
          Text(room.areaName)
            .fontSize(10)
            .fontColor('rgba(255,255,255,0.9)')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('rgba(0,0,0,0.4)')
            .borderRadius(3)
            .position({ bottom: 6, left: 6 })
        }
      }
      .width('100%')
      .borderRadius(this.cardListBorderRadius)
      .clip(true)
      .backgroundColor(this.isDarkMode ? '#333333' : '#F0F0F0') // 封面容器背景

      // ---- 标题 ----
      Text(room.title || '未命名直播')
        .fontSize(14)
        .fontColor(this.isDarkMode ? Color.White : Color.Black)
        .maxLines(2)
        .lineHeight(20)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 8, left: 2, right: 2 })
        .width('100%')

      // ---- 主播信息行 ----
      Row() {
        if (room.face) {
          Image(room.face)
            .width(20).height(20)
            .borderRadius(10)
            .margin({ right: 5 })
            .backgroundColor(this.isDarkMode ? '#444444' : '#E0E0E0') // 头像占位背景
        }
        Text(room.uname || '未知主播')
          .fontSize(13)
          .fontColor(this.isDarkMode ? '#AAAAAA' : '#666666')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(this.formatShortCount(room.online) + '观看')
          .fontSize(11)
          .fontColor(this.isDarkMode ? '#888888' : '#999999')
          .flexShrink(0)
      }
      .width('100%')
      .margin({ top: 4, left: 2, right: 2 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(8)
    .backgroundColor(this.cardCustomColor && this.cardCustomColor !== '#007DFF'
      ? (this.cardTransparentStyle
        ? '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1)
        : this.cardCustomColor)
      : (this.cardTransparentStyle
        ? (this.isDarkMode
          ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
          : `rgba(255,255,255,${this.cardBgOpacity / 100})`)
        : (this.isDarkMode ? '#2A2A2A' : '#F0F0F0'))) // 动态背景色，深色/浅色模式都有对比
    .border({ width: this.cardTransparentStyle ? this.cardBorderWidth : 0,
      color: this.cardTransparentStyle
        ? (this.cardBorderFollowTheme
          ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1))
          : (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)'))
        : Color.Transparent })
    .borderRadius(this.cardListBorderRadius)
    .clip(true)
    .shadow({ radius: 8, color: this.isDarkMode ? '#40000000' : '#20000000', offsetY: 4 })
    .clickEffect({ level: 0, scale: 0.9 })
    .onClick(() => this.enterRoom(room))
  }

  // ==================== 主构建 ====================

  build() {
    Stack() {
      // ═══ Layer 1: 内容层（填满屏幕，穿透 Tab 栏下方） ═══
      Column() {
        Refresh({ refreshing: $$this.isRefreshing, builder: this.customRefreshComponent() }) {
          Scroll(this.scroller) {
            Column() {
              // ⭐ 关注的UP主正在直播区块（信息流上方，需要登录）
              if (this.followedLiveRooms.length > 0) {
                Column() {
                  // 区头
                  Row() {
                    Text('关注的主播').fontSize(16).fontWeight(FontWeight.Bold)
                      .fontColor(this.isDarkMode ? Color.White : Color.Black)
                    Text(`(${this.followedLiveRooms.length})`)
                      .fontSize(13).fontColor('#999999').margin({ left: 4 })
                    Blank()
                    if (this.followedLiveRooms.length > 8) {
                      Text(this.showAllFollowed ? '收起' : '展开全部')
                        .fontSize(12).fontColor('#FB7299')
                        .onClick(() => {
                          this.showAllFollowed = !this.showAllFollowed;
                        })
                    }
                  }
                  .width('100%').padding({ left: 24, right: 20, bottom: 8 })
                  // 主播胶囊行（Flex 支持换行，默认显示 8 个，可展开全部）
                  Flex({ wrap: FlexWrap.Wrap }) {
                    ForEach(this.followedLiveRooms.slice(0,
                      this.showAllFollowed ? this.followedLiveRooms.length : 8
                    ), (room: LiveFeedRoom) => {
                      Row() {
                        ImmersiveLightWrapper({ radius: 18, materialStyle: 0, lightIntensity: 2.0 }) {
                          Row() {
                            if (room.face) {
                              Image(room.face)
                                .width(28).height(28)
                                .borderRadius(14)
                                .objectFit(ImageFit.Cover)
                                .margin({ right: 6 })
                            }
                            Text(room.uname || '')
                              .fontSize(13)
                              .fontColor(this.isDarkMode ? Color.White : Color.Black)
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                            // 粉色直播状态指示图标（该列表均为直播中）
                            Image($r('app.media.ic_public_brightness_filled'))
                              .width(12).height(12)
                              .fillColor('#FB7299')
                              .margin({ left: 4 })
                          }
                          .height(36)
                          .padding({ left: 4, right: 12 })
                          .alignItems(VerticalAlign.Center)
                          .onClick(() => {
                            this.enterRoom(room);
                          })
                        }
                      }
                      .margin({ right: 8, bottom: 8 })
                    }, (room: LiveFeedRoom) => String(room.roomId))
                  }
                  .width('100%')
                  .padding({ left: 20, right: 20, bottom: 12 })
                }
              }

              if (this.isLoading && this.dataSource.totalCount() === 0) {
                Column() {
                  LoadingProgress().width(40).height(40).color(this.getThemeColor())
                  Text('加载中...')
                    .fontSize(13).fontColor('#999999')
                    .margin({ top: 12 })
                }
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
              } else if (!this.isLoading && this.dataSource.totalCount() === 0) {
                Column() {
                  Image($r('app.media.ic_public_screencap'))
                    .width(64).height(64)
                    .fillColor(this.isDarkMode ? '#555555' : '#CCCCCC')
                    .margin({ bottom: 12 })
                  Text('暂无直播')
                    .fontSize(14).fontColor(this.isDarkMode ? '#888888' : '#999999')
                  Text('下拉刷新试试')
                    .fontSize(12).fontColor(this.isDarkMode ? '#666666' : '#BBBBBB')
                    .margin({ top: 4 })
                }
                .width('100%')
                .height(300)
                .justifyContent(FlexAlign.Center)
              } else {
                WaterFlow() {
                  LazyForEach(this.dataSource, (room: LiveFeedRoom, index: number) => {
                    FlowItem() {
                      this.LiveCard(room)
                    }
                    .backgroundColor('transparent')
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
                    .animation(this.da ? { duration: 0 } : {
                      duration: 1400,
                      curve: this.isBulkLoading
                        ? curves.springCurve(0.15, 1, 80, 8)
                        : curves.springCurve(0.15, 1, 80, 12)
                    })
                  }, (room: LiveFeedRoom, index: number) => `${room.roomId}_${index}`)
                }
                .columnsTemplate(this.isLandscape ? '1fr 1fr 1fr' : '1fr 1fr')
                .columnsGap(this.cardListMargin).rowsGap(this.cardListMargin)
                .padding({
                  left: this.cardListMargin,
                  right: this.cardListMargin,
                  bottom: 4
                })
                .backgroundColor('transparent')
                .cachedCount(20)
                .clip(false)

                // 底部加载提示
                if (this.isLoadingMore) {
                  Row() {
                    LoadingProgress().width(20).height(20).color(this.getThemeColor())
                    Text(' 加载更多...')
                      .fontSize(12).fontColor('#999999')
                  }
                  .width('100%')
                  .height(44)
                  .justifyContent(FlexAlign.Center)
                } else if (!this.hasMore && this.dataSource.totalCount() > 0) {
                  Text('已经到底了~')
                    .fontSize(12).fontColor(this.isDarkMode ? '#666666' : '#CCCCCC')
                    .width('100%')
                    .height(44)
                    .textAlign(TextAlign.Center)
                }
              }
            }
            .width('100%')
            // ⭐ 顶部让位固定不变（与分类页一致）：内容位移只由 Scroll 驱动，滚动完全跟手；
            // 悬浮分区栏独立滑出/滑入，不带动内容（避免轻滑时内容被动画推上一大段）
            .padding({
              top: this.statusBarHeight + this.TITLE_BAR_HEIGHT + this.TAB_BAR_HEIGHT + 4
            })
          }
          .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
          .onWillScroll((_, yOffset: number) => {
            // ⭐ 与分类页一致：delta 为「自上次触发以来的累积位移」
            // （lastScrollY 只在触发分支内更新），慢速滑动累积超阈值也能触发显隐；
            // 若末尾无条件更新 lastScrollY，delta 会退化为单次回调增量，慢滑永远不触发
            const absoluteOffset = this.scroller.currentOffset().yOffset;
            const delta = absoluteOffset - this.lastScrollY;
            if (delta > this.SCROLL_THRESHOLD) {
              this.lastScrollY = absoluteOffset;
              AppStorage.set('homeScrollOffset', absoluteOffset);
              AppStorage.set('bottomBarHidden', true);
              AppStorage.set('tabBarHidden', true);
            } else if (delta < -this.SCROLL_THRESHOLD) {
              this.lastScrollY = absoluteOffset;
              AppStorage.set('homeScrollOffset', absoluteOffset);
              AppStorage.set('bottomBarHidden', false);
              AppStorage.set('tabBarHidden', false);
            }
          })
          .onReachEnd(() => {
            this.loadMore();
          })
        }
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
          } else {
            this.onRefresh();
          }
        })
        .onStateChange((refreshStatus: RefreshStatus) => {
          if (refreshStatus === RefreshStatus.OverDrag) {
            if (this.longPullTimer !== -1) clearTimeout(this.longPullTimer);
            this.longPullTimer = setTimeout(() => {
              this.showSearchIcon = true;
              this.refreshBuilderText = '释放打开搜索';
              this.longPullTriggered = true;
              try {
                VibrateUtils.vibrateTime(25);
              } catch (err) { }
            }, 800);
          } else if (refreshStatus === RefreshStatus.Drag) {
            if (this.longPullTimer !== -1) clearTimeout(this.longPullTimer);
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
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('transparent')
      }
      .width('100%')
      .height('100%')

      // ═══ Layer 2: 悬浮毛玻璃 Tab 栏 ═══
      Column() {
        // 透明间隔：确保 Tab 出现在历史/搜索按钮下方
        Column()
          .width('100%')
          .height(this.statusBarHeight + this.TITLE_BAR_HEIGHT)
          .backgroundColor('transparent')

        // Tab 栏容器（长条型胶囊沉浸光感，宽度=屏幕宽-左右padding）
        Row() {
          HdsMiniBarButton({
            barWidth: this.liveBarW,
            barHeight: 36,
            contentPadding: 4,

            barBottomMargin: 0,
            barOverlap: true,
            barPosition: BarPosition.End
          }) {
            Scroll() {
              Row({ space: 8 }) {
                ForEach(this.areas.filter(t => t.pinned), (tab: AreaTab) => {
                  Column() {
                    Text(tab.name)
                      .fontSize(14)
                      .fontColor(tab.isSelected
                        ? this.getThemeColor()
                        : (this.isDarkMode ? 'rgba(255,255,255,0.7)' : 'rgba(0,0,0,0.55)'))
                      .fontWeight(tab.isSelected ? FontWeight.Bold : FontWeight.Medium)
                    if (tab.isSelected) {
                      Row()
                        .width(24)
                        .height(3)
                        .borderRadius(1.5)
                        .backgroundColor(this.getThemeColor())
                        .margin({ top: 2 })
                    }
                  }
                  .height(32)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(HorizontalAlign.Center)
                  .padding({ left: 12, right: 12 })
                  .onClick(() => {
                    try {
                      VibrateUtils.vibrateTime(15);
                    } catch (_) { }
                    this.onAreaSelect(tab.id);
                  })
                })
                if (!this.isCategoriesExpanded) {
                  Row() {
                    Image($r('app.media.more'))
                      .width(16)
                      .height(16)
                      .fillColor(this.isDarkMode ? 'rgba(255,255,255,0.7)' : 'rgba(0,0,0,0.55)')
                  }
                  .width(28)
                  .height(28)
                  .justifyContent(FlexAlign.Center)
                  .onClick(() => {
                    try {
                      VibrateUtils.vibrateTime(15);
                    } catch (_) { }
                    this.expandPanel();
                  })
                }
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
        .height(this.TAB_BAR_HEIGHT)
        .padding({ left: 12, right: 12 })
        .justifyContent(FlexAlign.Center)
      }
      // ⭐ 面板展开时向左滑出屏幕（x 负位移），滚动隐藏仍向上（y 负位移）
      .offset({
        x: this.isCategoriesExpanded ? -this.panelSlideOutX() : 0,
        y: this.tabBarHidden ? -(this.statusBarHeight + this.TITLE_BAR_HEIGHT + this.TAB_BAR_HEIGHT + 16) : 0
      })
      // ⭐ 与分类页一致：400ms EaseInOut 缓入缓出，滑出/滑回更柔和
      .animation(this.da ? { duration: 0 } : { duration: 400, curve: Curve.EaseInOut })

  // ═══ Layer 3: 展开浮层 + 透明遮罩 ═══
  if (this.isCategoriesExpanded) {
    // 透明遮罩 — 点击面板外区域收起面板
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.collapsePanel();
      })

    // 外层 Row 提供左右边距，内层系统磨砂毛玻璃（backgroundBlurStyle COMPONENT_THICK）
    Row() {
      Column() {
        // ---- 标题栏：全部分类 + 收起按钮（编辑/完成按钮已移到底部） ----
        Row() {
          Text('全部分类')
            .fontSize(16)
            .fontColor(this.isDarkMode ? Color.White : Color.Black)
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)

          Row() {
            Text('收起')
              .fontSize(14)
              .fontColor(this.getThemeColor())
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.04)')
          .borderRadius(16)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
          .onClick(() => {
            if (this.isEditing) {
              this.isEditing = false;
              this.savePinnedAreas();
            }
            this.collapsePanel();
            try {
              VibrateUtils.vibrateTime(15);
            } catch (_) { }
          })
        }
        .width('100%')
        .margin({ bottom: 12 })

        // 全部分类网格
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.areas, (tab: AreaTab) => {
            Row() {
              // 锁定/解锁图标（编辑模式下显示）
              if (this.isEditing) {
                Image(tab.pinned
                  ? $r('app.media.ic_public_unlock')
                  : $r('app.media.ic_public_lock'))
                  .width(14).height(14)
                  .fillColor(tab.pinned
                    ? this.getThemeColor()
                    : (this.isDarkMode ? '#AAAAAA' : '#888888'))
                  .margin({ right: 4 })
              }

              Text(tab.name)
                .fontSize(14)
                .fontColor(tab.id === this.selectedAreaId && !this.isEditing
                  ? Color.White
                  : (this.isDarkMode ? 'rgba(255,255,255,0.75)' : 'rgba(0,0,0,0.6)'))
                .fontWeight(tab.id === this.selectedAreaId && !this.isEditing ? FontWeight.Bold : FontWeight.Normal)
            }
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor(tab.id === this.selectedAreaId && !this.isEditing
              ? this.getThemeColor()
              : (this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)'))
            .borderRadius(16)
            .margin(4)
            .onClick(() => {
              if (this.isEditing) {
                // 编辑模式：切换 pinned 状态
                const updatedAreas: AreaTab[] = this.areas.map((a: AreaTab) => ({
                  id: a.id,
                  name: a.name,
                  isSelected: a.isSelected,
                  pinned: a.id === tab.id ? !a.pinned : a.pinned
                }) as AreaTab);
                this.areas = updatedAreas;
                this.recalcLiveBarW();
              } else {
                // 正常模式：选择分区
                this.onAreaSelect(tab.id);
                this.collapsePanel();
              }
              try {
                VibrateUtils.vibrateTime(15);
              } catch (_) { }
            })
          })
        }
        .width('100%')

        // 底部按钮：编辑/完成 + 收起（并排）
        Row({ space: 12 }) {
          Row() {
            if (!this.isEditing) {
              Image($r('app.media.ic_public_edit_filled'))
                .width(16).height(16)
                .fillColor(Color.White)
                .margin({ right: 4 })
            }
            Text(this.isEditing ? '完成' : '编辑')
              .fontSize(14)
              .fontColor(Color.White)
          }
          .padding({ left: 24, right: 24, top: 8, bottom: 8 })
          .backgroundColor(this.getThemeColor())
          .borderRadius(20)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
          .onClick(() => {
            this.isEditing = !this.isEditing;
            if (!this.isEditing) {
              // 完成编辑，保存 pinned 状态
              this.savePinnedAreas();
            }
            try {
              VibrateUtils.vibrateTime(15);
            } catch (_) { }
          })

          // ⭐ 收起按钮（编辑按钮右侧）
          Row() {
            Text('收起')
              .fontSize(14)
              .fontColor(this.getThemeColor())
          }
          .padding({ left: 24, right: 24, top: 8, bottom: 8 })
          .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.05)')
          .borderRadius(20)
          .border({ width: 1, color: this.getThemeColor() })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
          .onClick(() => {
            if (this.isEditing) {
              this.isEditing = false;
              this.savePinnedAreas();
            }
            this.collapsePanel();
            try {
              VibrateUtils.vibrateTime(15);
            } catch (_) { }
          })
        }
        .width('100%')
        .height(48)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .margin({ top: 4 })
      }
      .width('100%')
      .padding(20)
      .borderRadius(20)
      .backgroundColor(Color.Transparent)
      // ⭐ 系统磨砂毛玻璃（COMPONENT_THICK）：中等厚度，玻璃质感且保留一定不透明度
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .clip(true)
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    .position({ top: 50 + this.TAB_BAR_HEIGHT })
    // ⭐ 生长动画：缩放中心定在面板右上角（展开按钮所在方位，100% / 0%），
    // 进入时从按钮处由小放大展开，收起反向缩回，与展开按钮形成连续过渡
    .transition(
      this.da ? TransitionEffect.IDENTITY : TransitionEffect.asymmetric(
        TransitionEffect.scale({ x: 0.15, y: 0.15, centerX: '100%', centerY: '0%' })
          .combine(TransitionEffect.opacity(0))
          .animation({ duration: 350, curve: Curve.FastOutSlowIn }),
        TransitionEffect.scale({ x: 0.15, y: 0.15, centerX: '100%', centerY: '0%' })
          .combine(TransitionEffect.opacity(0))
          .animation({ duration: 250, curve: Curve.FastOutSlowIn })
      )
    )
    .hitTestBehavior(HitTestMode.Default)

  }
  
  }
  .align(Alignment.Top)
  .width('100%')
  .height('100%')
  .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
}
}
