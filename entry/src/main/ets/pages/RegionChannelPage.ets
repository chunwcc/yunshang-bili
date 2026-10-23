/**
 * RegionChannelPage.ets — 分类频道页（首页频道体系内嵌）
 *
 * 交互对齐直播页：
 * - 悬浮分类 Tab 栏：只显示「已固定」分区，未固定分区收进「全部分区」面板
 * - 展开按钮 → 全部分区面板（含编辑模式：锁定/解锁固定分区，持久化到 Preferences）
 * - 内容：分区排行榜（ranking/v2）双列瀑布流
 * - 点击卡片 → VideoPlayerPage（bvid + aid）
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { curves, display } from '@kit.ArkUI';
import { logError } from '../utils/Logger';
import { fetchRegionRanking, REGION_TABS, RegionTab } from '../api/RegionApi';
import { RecommendItem } from '../model/RecommendItem';
import { GenericDataSource } from '../model/GenericDataSource';
import { VideoCardComponent } from '../components/VideoCardComponent';
import { ImmersiveLightWrapper } from '../components/ImmersiveLightWrapper';
import { HdsMiniBarButton } from '../components/infra/HdsMiniBarButton';
import { VibrateUtils } from '../utils/VibrateUtils';

/** 分类分区 Tab（含固定状态） */
interface RegionPinnedTab {
  rid: number;
  name: string;
  isSelected: boolean;
  pinned: boolean;
}

@Component
export struct RegionChannelPage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @StorageLink('navIndicatorHeight') navIndicatorHeight: number = 0;
  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  @StorageLink('cardListMargin') cardListMargin: number = 12;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = false;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 40;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1.5;
  @StorageLink('cardCustomColor') cardCustomColor: string = '';
  @StorageLink('cardStyleLiveCategory') cardStyleLiveCategory: boolean = true;
  @StorageLink('da') da: boolean = false;
  @StorageLink('refreshHomeFlag') @Watch('onRefreshFlagChange') refreshFlag: number = 0;
  @StorageLink('scrollToTopFlag') @Watch('onScrollToTop') scrollToTopFlag: number = 0;
  /** ⭐ 悬浮分类栏显隐（上滑隐藏，与直播页一致） */
  @StorageLink('tabBarHidden') tabBarHidden: boolean = false;

  @State selectedRid: number = REGION_TABS.length > 0 ? REGION_TABS[0].rid : 0;
  @State regions: RegionPinnedTab[] = [];
  @State isCategoriesExpanded: boolean = false;
  @State isEditing: boolean = false;
  /** ⭐ 列数（与首页一致：竖屏2-3列） */
  @State columnCount: number = 2;
  /** ⭐ 长条胶囊宽度（动态计算：标签数×64 + 间距 + 展开按钮） */
  @State regionBarW: number = 200;

  private dataSource: GenericDataSource<RecommendItem> = new GenericDataSource();
  private scroller: Scroller = new Scroller();
  @State isLoading: boolean = true;
  @State isRefreshing: boolean = false;
  // ⭐ 长按下拉跳搜索（与 HomePage 一致：OverDrag 持续 800ms → 松手进搜索页而非刷新）
  private longPullTimer: number = -1;
  private longPullTriggered: boolean = false;
  @State refreshBuilderText: string = '下拉刷新';
  @State showSearchIcon: boolean = false;
  private lastScrollY: number = 0;
  // ⭐ 滚动阈值：上滑超过该距离才隐藏悬浮栏/底栏，避免轻滑反复切换导致内容跳变
  private readonly SCROLL_THRESHOLD: number = 60;

  // 入场动画
  @State cardsVisible: boolean[] = [];
  @State isBulkLoading: boolean = false;
  private cardDelays: number[] = [];
  private cardTranslateYs: number[] = [];

  private readonly TITLE_BAR_HEIGHT: number = 48;
  private readonly TAB_BAR_HEIGHT: number = 50;
  // 默认固定前 N 个分区到悬浮 Tab 栏
  private readonly MAX_VISIBLE_TABS: number = 4;

  aboutToAppear() {
    this.initRegions();
    this.loadColumnCount();
    this.loadRanking(true);
  }

  aboutToDisappear() {
    // 长按下拉计时器保底清理，避免切频道后回调仍改状态
    if (this.longPullTimer !== -1) {
      clearTimeout(this.longPullTimer);
      this.longPullTimer = -1;
    }
  }

  /** ⭐ 动态计算长条胶囊宽度：根据标签文字内容自适应，不占满屏幕 */
  private recalcRegionBarW(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const screenW = this.getUIContext().px2vp(d.width);
      const maxBarW = Math.max(200, screenW - 24 - 16);
      const pinnedTabs = this.regions.filter((t: RegionPinnedTab) => t.pinned);
      if (pinnedTabs.length === 0) {
        this.regionBarW = maxBarW;
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
      this.regionBarW = Math.min(totalW, maxBarW);
    } catch (_) {
      this.regionBarW = 340;
    }
  }

  /** 初始化分区列表：默认固定前 MAX_VISIBLE_TABS 个，随后从 Preferences 恢复 */
  private async initRegions(): Promise<void> {
    const tabList: RegionPinnedTab[] = REGION_TABS.map((a: RegionTab, idx: number) => ({
      rid: a.rid,
      name: a.name,
      isSelected: a.rid === this.selectedRid,
      pinned: idx < this.MAX_VISIBLE_TABS
    }) as RegionPinnedTab);
    const savedIds: number[] = await this.loadPinnedRidIds();
    if (savedIds.length > 0) {
      this.regions = tabList.map((tab: RegionPinnedTab) => ({
        rid: tab.rid,
        name: tab.name,
        isSelected: tab.isSelected,
        pinned: savedIds.indexOf(tab.rid) >= 0
      }) as RegionPinnedTab);
    } else {
      this.regions = tabList;
    }
    this.recalcRegionBarW();
  }

  // 持久化：保存已固定的分区 rid 列表
  private async savePinnedRidIds(): Promise<void> {
    try {
      const pinnedIds: number[] = this.regions
        .filter((t: RegionPinnedTab) => t.pinned)
        .map((t: RegionPinnedTab) => t.rid);
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref: preferences.Preferences = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('regionPinnedRids', JSON.stringify(pinnedIds));
      await pref.flush();
    } catch (_e) {}
  }

  // 持久化：读取之前保存的固定分区 rid 列表
  private async loadPinnedRidIds(): Promise<number[]> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref: preferences.Preferences = await preferences.getPreferences(context, 'my_app_settings');
      const raw: string = await pref.get('regionPinnedRids', '') as string;
      if (raw) {
        return JSON.parse(raw) as number[];
      }
    } catch (_e) {}
    return [];
  }

  /** ⭐ 列数（与首页一致：竖屏2-3列） */
  private async loadColumnCount(): Promise<void> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref: preferences.Preferences = await preferences.getPreferences(context, 'my_app_settings');
      const saved = await pref.get('regionColumnCount', 2) as number;
      if (saved >= 2 && saved <= 3 && this.columnCount !== saved) {
        this.columnCount = saved;
      }
    } catch (_e) {}
  }

  private async saveCurrentColumnCount(): Promise<void> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref: preferences.Preferences = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('regionColumnCount', this.columnCount);
      await pref.flush();
    } catch (_e) {}
  }

  /** ⭐ 双指捏合手势（与首页反转后一致）：张开减列、收拢加列 */
  private handlePinch(scale: number): void {
    let changed = false;
    if (scale > 1.05 && this.columnCount > 2) {
      this.columnCount = 2;
      changed = true;
    } else if (scale < 0.95 && this.columnCount < 3) {
      this.columnCount = 3;
      changed = true;
    }
    if (changed) {
      this.saveCurrentColumnCount();
      try {
        this.getUIContext().getPromptAction().showToast({ message: `${this.columnCount}列`, duration: 800 });
      } catch (_e) {}
    }
  }

  private onRefreshFlagChange(): void {
    this.loadRanking(true);
  }

  private onScrollToTop(): void {
    if (this.scroller) {
      this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300 } });
    }
  }

  private async loadRanking(isRefresh: boolean): Promise<void> {
    if (isRefresh) {
      this.isRefreshing = true;
    }
    const list = await fetchRegionRanking(this.selectedRid);
    this.isLoading = false;
    this.isRefreshing = false;
    if (isRefresh) {
      this.dataSource.reloadItems(list);
      this.prepareCardAnimation(list.length);
    } else {
      const beforeCount = this.dataSource.totalCount();
      this.dataSource.addItems(list);
      this.prepareMoreAnimation(beforeCount, list.length);
    }
  }

  private onRefresh(): void {
    this.loadRanking(true);
  }

  /** 选择分区（悬浮栏 / 面板正常模式） */
  private onRegionSelect(rid: number): void {
    if (rid === this.selectedRid) return;
    this.selectedRid = rid;
    this.regions = this.regions.map((t: RegionPinnedTab) => ({
      rid: t.rid,
      name: t.name,
      isSelected: t.rid === rid,
      pinned: t.pinned
    }) as RegionPinnedTab);
    this.isLoading = true;
    this.dataSource.reloadItems([]);
    this.loadRanking(true);
  }

  private expandPanel(): void {
    this.isCategoriesExpanded = true;
    this.recalcRegionBarW();
  }

  private collapsePanel(): void {
    this.isCategoriesExpanded = false;
    this.recalcRegionBarW();
    if (this.isEditing) {
      this.isEditing = false;
      this.savePinnedRidIds();
    }
  }

  private prepareCardAnimation(count: number): void {
    this.cardsVisible = new Array(count).fill(false);
    this.cardDelays = [];
    this.cardTranslateYs = [];
    for (let i = 0; i < count; i++) {
      this.cardDelays.push(Math.floor(Math.random() * 400));
      this.cardTranslateYs.push(Math.floor(Math.random() * 40) + 15);
    }
    if (this.da) {
      this.cardsVisible = new Array(count).fill(true);
      return;
    }
    setTimeout(() => {
      for (let i = 0; i < count; i++) {
        setTimeout(() => {
          const newVisible = [...this.cardsVisible];
          newVisible[i] = true;
          this.cardsVisible = newVisible;
        }, this.cardDelays[i]);
      }
    }, 100);
  }

  private prepareMoreAnimation(beforeCount: number, addCount: number): void {
    const extendedVisible: boolean[] = [...this.cardsVisible, ...new Array<boolean>(addCount).fill(false)];
    this.cardsVisible = extendedVisible;
    for (let i = 0; i < addCount; i++) {
      const globalIdx = beforeCount + i;
      this.cardDelays[globalIdx] = Math.floor(Math.random() * 180) + i * 40;
      this.cardTranslateYs[globalIdx] = Math.floor(Math.random() * 45) + 25;
    }
    if (this.da) return;
    setTimeout(() => {
      for (let i = 0; i < addCount; i++) {
        const globalIdx = beforeCount + i;
        setTimeout(() => {
          const newVisible = [...this.cardsVisible];
          newVisible[globalIdx] = true;
          this.cardsVisible = newVisible;
        }, this.cardDelays[globalIdx]);
      }
    }, 80);
  }

  private onCardClick(item: RecommendItem): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/VideoPlayerPage',
      params: {
        bvid: item.id,
        aid: item.aid,
        title: item.title,
        ownerName: item.ownerName,
        coverUrl: item.coverUrl,
        cid: item.cid || 0
      }
    }).catch((err: Error) => {
      logError(`[RegionChannelPage] 跳转播放页失败: ${err.message}`);
    });
  }

  getThemeColor(): string {
    return this.customThemeColor || '#007DFF';
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

  /** 悬浮栏 Tab 项：选中主题色文字+下划线，未选中普通文字（全部共享外层长条胶囊沉浸光感） */
  @Builder
  RegionTabItem(tab: RegionPinnedTab) {
    Column() {
      Text(tab.name)
        .fontSize(14)
        .fontColor(tab.rid === this.selectedRid
          ? this.customThemeColor
          : (this.isDarkMode ? 'rgba(255,255,255,0.7)' : 'rgba(0,0,0,0.55)'))
        .fontWeight(tab.rid === this.selectedRid ? FontWeight.Bold : FontWeight.Medium)
      if (tab.rid === this.selectedRid) {
        Row()
          .width(24)
          .height(3)
          .borderRadius(1.5)
          .backgroundColor(this.customThemeColor)
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
      this.onRegionSelect(tab.rid);
    })
  }

  build() {
    Stack() {
      // ═══ Layer 1: 内容层 ═══
      Refresh({ refreshing: $$this.isRefreshing, builder: this.customRefreshComponent() }) {
        Scroll(this.scroller) {
          Column() {
            if (this.isLoading && this.dataSource.totalCount() === 0) {
              Row() {
                LoadingProgress().width(40).height(40).color(this.customThemeColor)
              }
              .width('100%')
              .height(240)
              .justifyContent(FlexAlign.Center)
            } else if (!this.isLoading && this.dataSource.totalCount() === 0) {
              Column() {
                Text('暂无内容')
                  .fontSize(14).fontColor(this.isDarkMode ? '#888888' : '#999999')
                Text('下拉刷新试试')
                  .fontSize(12).fontColor(this.isDarkMode ? '#666666' : '#BBBBBB')
                  .margin({ top: 4 })
              }
              .width('100%')
              .height(240)
              .justifyContent(FlexAlign.Center)
            } else {
              WaterFlow() {
                LazyForEach(this.dataSource, (item: RecommendItem, index: number) => {
                  FlowItem() {
                    VideoCardComponent({
                      item: item,
                      onCardClick: (clicked: RecommendItem): void => this.onCardClick(clicked)
                    })
                  }
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
                    duration: 1200,
                    curve: curves.springCurve(0.15, 1, 80, 10)
                  })
                }, (item: RecommendItem, index: number) => `${item.id}_${index}`)
              }
              .columnsTemplate('1fr '.repeat(this.columnCount).trim())
              .columnsGap(this.cardListMargin).rowsGap(this.cardListMargin)
              .padding({
                left: this.cardListMargin,
                right: this.cardListMargin,
                bottom: 190 + this.navIndicatorHeight
              })
              .backgroundColor('transparent')
              .cachedCount(12)
              .clip(false)
              .gesture(PinchGesture().onActionUpdate((event: GestureEvent) => this.handlePinch(event.scale)))
            }
          }
          .width('100%')
          // ⭐ 顶部让位固定不变（与首页一致）：内容位移只由 Scroll 驱动，滚动完全跟手；
          // 悬浮分类栏独立滑出/滑入，不带动内容（避免轻滑时内容被动画推上一大段）
          .padding({
            top: (this.hideStatusBar ? 0 : this.statusBarHeight) + this.TITLE_BAR_HEIGHT + this.TAB_BAR_HEIGHT + 4
          })
        }
        .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).backgroundColor('transparent')
        .onWillScroll((_, yOffset: number) => {
          // ⭐ 与直播页 LivePage 完全一致的实现：
          // 用 currentOffset() 取当前绝对位置，与上次记录值求差得到方向增量 delta；
          // delta > 阈值 → 上滑隐藏；delta < -阈值 → 下滑显示（无需回顶）
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
      }
      .onStateChange((refreshStatus: RefreshStatus) => {
        if (refreshStatus === RefreshStatus.OverDrag) {
          // 长按（越过拖拽阈值后按住不放）800ms → 标记为"释放打开搜索"
          if (this.longPullTimer !== -1) clearTimeout(this.longPullTimer);
          this.longPullTimer = setTimeout(() => {
            this.showSearchIcon = true;
            this.refreshBuilderText = '释放打开搜索';
            this.longPullTriggered = true;
            try {
              VibrateUtils.vibrateTime(25);
            } catch (_) { }
          }, 800);
        } else if (refreshStatus === RefreshStatus.Drag) {
          // 回退到普通下拉：取消长按标记（之前已触发过则给一次轻震动表示撤销）
          if (this.longPullTimer !== -1) clearTimeout(this.longPullTimer);
          if (this.longPullTriggered) {
            try {
              VibrateUtils.vibrateTime(15);
            } catch (_) { }
          }
          this.showSearchIcon = false;
          this.refreshBuilderText = '下拉刷新';
          this.longPullTriggered = false;
        } else if (refreshStatus === RefreshStatus.Refresh) {
          // ⚠️ 此处只清定时器、绝不复位 longPullTriggered：
          // 松手进入刷新状态后还要靠它判断"该跳搜索还是该刷新"（见 onRefreshing）
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
          // 长按下拉 → 不刷新，直接进搜索页
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

      // ═══ Layer 2: 悬浮分类 Tab 栏（只显示已固定分区） ═══
      Column() {
        // 透明间隔：让出状态栏 + 悬浮标题栏
        Column()
          .width('100%')
          .height((this.hideStatusBar ? 0 : this.statusBarHeight) + this.TITLE_BAR_HEIGHT)
          .backgroundColor('transparent')

        // Tab 栏容器（长条型胶囊沉浸光感，宽度=屏幕宽-左右padding）
        Row() {
          HdsMiniBarButton({
            barWidth: this.regionBarW,
            barHeight: 36,
            contentPadding: 4,

            barBottomMargin: 0,
            barOverlap: true,
            barPosition: BarPosition.End
          }) {
            Scroll() {
              Row({ space: 8 }) {
                ForEach(this.regions.filter((t: RegionPinnedTab) => t.pinned), (tab: RegionPinnedTab) => {
                  this.RegionTabItem(tab)
                }, (tab: RegionPinnedTab) => tab.rid.toString())
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
      .width('100%')
      // ⭐ 面板展开时向左滑出屏幕（x 负位移，1200 确保完全滑出），滚动隐藏仍向上（y 负位移）
      .offset({
        x: this.isCategoriesExpanded ? -1200 : 0,
        y: this.tabBarHidden ? -((this.hideStatusBar ? 0 : this.statusBarHeight) + this.TITLE_BAR_HEIGHT + this.TAB_BAR_HEIGHT + 16) : 0
      })
      // ⭐ 加长时长 + EaseInOut 缓入缓出，滑出/滑回更柔和
      .animation(this.da ? { duration: 0 } : { duration: 400, curve: Curve.EaseInOut })

      // ═══ Layer 3: 全部分区面板 + 透明遮罩 ═══
      if (this.isCategoriesExpanded) {
        // 透明遮罩 — 点击面板外区域收起面板
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.collapsePanel();
          })

        Row() {
          // ⭐ 系统磨砂毛玻璃（backgroundBlurStyle COMPONENT_THICK）
          Column() {
            // 标题栏：全部分区 + 收起按钮（编辑/完成按钮已移到底部）
            Row() {
              Text('全部分区')
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
                  this.savePinnedRidIds();
                }
                this.collapsePanel();
                try {
                  VibrateUtils.vibrateTime(15);
                } catch (_) { }
              })
            }
            .width('100%')
            .margin({ bottom: 12 })

            // 全部分区网格
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.regions, (tab: RegionPinnedTab) => {
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
                    .fontColor(tab.rid === this.selectedRid && !this.isEditing
                      ? Color.White
                      : (this.isDarkMode ? 'rgba(255,255,255,0.75)' : 'rgba(0,0,0,0.6)'))
                    .fontWeight(tab.rid === this.selectedRid && !this.isEditing ? FontWeight.Bold : FontWeight.Normal)
                }
                .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                .backgroundColor(tab.rid === this.selectedRid && !this.isEditing
                  ? this.getThemeColor()
                  : (this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)'))
                .borderRadius(16)
                .margin(4)
                .onClick(() => {
                  if (this.isEditing) {
                    // 编辑模式：切换固定状态
                    this.regions = this.regions.map((t: RegionPinnedTab) => ({
                      rid: t.rid,
                      name: t.name,
                      isSelected: t.isSelected,
                      pinned: t.rid === tab.rid ? !t.pinned : t.pinned
                    }) as RegionPinnedTab);
                    this.recalcRegionBarW();
                  } else {
                    // 正常模式：选择分区
                    this.onRegionSelect(tab.rid);
                    this.collapsePanel();
                  }
                  try {
                    VibrateUtils.vibrateTime(15);
                  } catch (_) { }
                })
                // ⭐ key 必须包含 pinned：否则切换固定状态时 ForEach 复用旧节点，
                // 锁定/解锁图标不会实时刷新
              }, (tab: RegionPinnedTab) => `${tab.rid}_${tab.pinned ? 'p' : 'u'}`)
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
                  // 完成编辑，保存固定状态
                  this.savePinnedRidIds();
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
                  this.savePinnedRidIds();
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
        // ⭐ 与直播页展开面板位置一致（同为 106vp：TITLE_BAR_HEIGHT 48 + TAB_BAR_HEIGHT 50 + 8；
        // 直播页为 50 + TAB_BAR_HEIGHT 56），去掉 statusBarHeight 让面板上移到悬浮栏下方；
        // 再上移 4vp（+8 → +4）更贴近悬浮栏
        .position({ y: this.TITLE_BAR_HEIGHT + this.TAB_BAR_HEIGHT + 4 })
        .animation(this.da ? { duration: 0 } : { duration: 300, curve: Curve.FastOutSlowIn })
        // ⭐ 生长动画：与直播页一致，缩放中心定在面板右上角（展开按钮所在方位，100% / 0%），
        // 进入时从按钮处由小放大展开，收起反向缩回
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
      }
    }
    // ⭐ 关键：Stack 默认 alignContent=Center 会把悬浮栏垂直居中显示在屏幕中间，
    // 必须顶部对齐（与直播页 LivePage 根 Stack 一致），让悬浮分区栏贴在标题栏下方
    .align(Alignment.Top)
    .width('100%')
    .height('100%')
  }

  private opacityToHexAlpha(opacity: number): string {
    const clamped = Math.max(0, Math.min(100, opacity));
    const hex = Math.round(clamped / 100 * 255).toString(16).toUpperCase();
    return hex.length < 2 ? '0' + hex : hex;
  }
}
