// DiscoverPage.ets - 竖屏单列左图右字，横屏双列左图右字，图片宽度180，支持共享元素转场
// 使用媒体查询监听横竖屏变化，响应式更新 WaterFlow 列数，动画流畅自然
import { common } from '@kit.AbilityKit';
import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';
import { window, curves, mediaquery } from '@kit.ArkUI';
import { getPopularVideos, blacklistUploader, prefetchVideoDetail } from '../api/BilibiliApi';
import { RecommendItem } from '../model/RecommendItem';
import { VibrateUtils } from '../utils/VibrateUtils';
import { formatPlayCountText, getPlayCountDisplayColor } from '../utils/PlayCountStyle';
import { sendDislikeFeedback, sendDislikeUpFeedback } from '../api/FeedbackService';
import { UserBehaviorService } from '../services/UserBehaviorService';
import { GenericDataSource } from '../model/GenericDataSource';

@Component({ freezeWhenInactive: true })
export struct DiscoverPage {
  // ★ 由父组件传入，供 Scroll 组件和 HdsNavigation.bindToScrollable 使用
  externalScroller?: Scroller = undefined;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('navIndicatorHeight') navIndicatorHeight: number = 0;
  @StorageLink('scrollToTopFlag') @Watch('onScrollToTop') scrollToTopFlag: number = 0;
  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @StorageLink('pageShowCounter') @Watch('onPageShowReset') pageShowCounter: number = 0;
  @StorageLink('refreshDiscoverFlag') @Watch('onRefreshDiscoverFlagChange') refreshDiscoverFlag: number = 0;
  @StorageLink('homeScrollOffset') homeScrollOffset: number = 0;
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

  // 滚动隐藏底栏相关
  private lastScrollY: number = 0;
  private readonly SCROLL_THRESHOLD: number = 10;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  private dataSource: GenericDataSource<RecommendItem> = new GenericDataSource();
  @State isLoading: boolean = true;
  @State isLoadingMore: boolean = false;
  @State isRefreshing: boolean = false;
  @State pageNum: number = 1;
  @State isLandscape: boolean = false;      // 当前是否横屏
  @State columnCount: number = 1;           // 当前列数，横屏2列，竖屏1列
  private pageSize: number = 20;
  private hasMore: boolean = true;
  private isPageActive: boolean = true;
  private longPullTimer: number = -1;
  private longPullTriggered: boolean = false;
  @State refreshBuilderText: string = '下拉刷新';
  @State showSearchIcon: boolean = false;

  // 底部弹窗相关状态
  @State isMenuSheetVisible: boolean = false;
  @State selectedMenuItem: RecommendItem | null = null;

  // 媒体查询监听器
  private landscapeListener: mediaquery.MediaQueryListener | null = null;

  // 入场动画相关
  @State cardsVisible: boolean[] = [];
  @State isBulkLoading: boolean = false;
  private cardDelays: number[] = [];
  private cardTranslateYs: number[] = [];

  async aboutToAppear() {
    if (AppStorage.get('scrollToTopFlag') === undefined) {
      AppStorage.setOrCreate('scrollToTopFlag', 0);
    }
    this.getStatusBarHeight();
    await this.initOrientationAndMediaQuery();
    this.loadData(true);
    this.initScrollState();
  }

  aboutToDisappear() {
    // 移除媒体查询监听
    if (this.landscapeListener) {
      this.landscapeListener.off('change');
      this.landscapeListener = null;
    }
  }

  onPageShow() {
    this.isPageActive = true;
    // 重新检查方向，确保从播放器返回后方向正确
    this.updateOrientationFromWindow();
  }

  onPageHide() {
    this.isPageActive = false;
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
  }

  @Watch('onHideStatusBarChange')
  @StorageLink('hideStatusBar') watchHideStatusBarLink: boolean = false;

  private onHideStatusBarChange() {
    if (this.hideStatusBar) {
      this.statusBarHeight = 0;
    } else {
      const cached = AppStorage.get<number>('realStatusBarHeight');
      if (cached && cached > 0) {
        this.statusBarHeight = cached;
      } else {
        this.getStatusBarHeight();
      }
    }
  }

  private onScrollToTop() {
    if (this.externalScroller) {
      this.externalScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300 } });
    }
  }

  private onRefreshDiscoverFlagChange() {
    this.loadData(true);
    // ⭐ 程序化刷新不触发 Refresh 下拉头部
    this.isRefreshing = false;
  }

  // 通过窗口属性更新方向（用于手动触发）
  private updateOrientationFromWindow() {
    const mainWindow = AppStorage.get<window.Window>('mainWindow');
    if (mainWindow) {
      try {
        const props = mainWindow.getWindowProperties();
        const newIsLandscape = props.windowRect.width > props.windowRect.height;
        if (this.isLandscape !== newIsLandscape) {
          this.isLandscape = newIsLandscape;
          this.updateColumnCount();
        }
      } catch (err) {
        logWarn(`updateOrientationFromWindow 异常: ${errMsg(err)}`);
      }
    }
  }

  // 初始化方向并注册媒体查询监听
  private async initOrientationAndMediaQuery() {
    // 获取当前方向（优先从 AppStorage，取不到则直接从 context 获取）
    let mainWindow = AppStorage.get<window.Window>('mainWindow');
    if (!mainWindow) {
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        mainWindow = await window.getLastWindow(context);
      } catch (e) {
        logWarn('[DiscoverPage] 无法获取窗口对象:', e);
      }
    }
    if (mainWindow) {
      try {
        const props = mainWindow.getWindowProperties();
        this.isLandscape = props.windowRect.width > props.windowRect.height;
        this.updateColumnCount();
        logInfo(`[DiscoverPage] 初始方向: ${this.isLandscape ? '横屏' : '竖屏'}, 列数=${this.columnCount}`);
      } catch (err) {
        logWarn(`initOrientationAndMediaQuery 异常: ${errMsg(err)}`);
      }
    }

    // 注册媒体查询监听横竖屏变化（官方推荐方式）
    const mediaQuery = this.getUIContext().getMediaQuery();
    this.landscapeListener = mediaQuery.matchMediaSync('(orientation: landscape)');
    this.landscapeListener.on('change', (result: mediaquery.MediaQueryResult) => {
      if (!this.isPageActive) return;
      const newIsLandscape = result.matches;
      if (this.isLandscape !== newIsLandscape) {
        this.isLandscape = newIsLandscape;
        this.updateColumnCount();
        logInfo(`[DiscoverPage] 方向变化，横屏=${this.isLandscape}, 列数=${this.columnCount}`);
      }
    });
  }

  private updateColumnCount() {
    this.columnCount = this.isLandscape ? 2 : 1;
  }

  private initScrollState() {
    AppStorage.set('bottomBarHidden', false);
  }

  private async loadData(refresh: boolean = false) {
    if (refresh) {
      this.pageNum = 1;
      this.hasMore = true;
      this.isLoading = true;
      this.isRefreshing = true;
    } else {
      if (this.isLoadingMore || !this.hasMore) return;
      this.isLoadingMore = true;
    }
    const newItems = await getPopularVideos(this.pageNum, this.pageSize);
    // ⭐ 只过滤已屏蔽的UP主，不过滤已看视频
    const filteredItems = UserBehaviorService.filterBlockedUploadersOnly(newItems);
    if (filteredItems.length > 0) {
      if (refresh) {
        this.dataSource.reloadItems(filteredItems);
        this.triggerCardAnimation(0, this.dataSource.totalCount(), false);
      } else {
        const beforeCount = this.dataSource.getRawItems().length;
        this.dataSource.addItems(filteredItems);
        this.triggerCardAnimation(beforeCount, this.dataSource.totalCount(), true);
      }
      this.pageNum++;
    } else {
      this.hasMore = false;
    }
    this.isLoading = false;
    this.isRefreshing = false;
    this.isLoadingMore = false;
  }

  // 触发卡片入场动画
  private triggerCardAnimation(fromIndex: number, toIndex: number, ordered: boolean = true) {
    const totalCount = this.dataSource.totalCount();
    // ⭐ 全量刷新时重置所有卡片为不可见
    if (!ordered) {
      this.cardsVisible = new Array<boolean>(totalCount).fill(false);
    } else if (this.cardsVisible.length < totalCount) {
      const addCount = totalCount - this.cardsVisible.length;
      this.cardsVisible = [...this.cardsVisible, ...new Array<boolean>(addCount).fill(false)];
    }
    const addCount = toIndex - fromIndex;
    if (addCount <= 0) return;
    for (let i = 0; i < addCount; i++) {
      const globalIdx = fromIndex + i;
      if (ordered) {
        this.cardDelays[globalIdx] = Math.floor(Math.random() * 180) + i * 55;
        this.cardTranslateYs[globalIdx] = Math.floor(Math.random() * 55) + 35;
      } else {
        this.cardDelays[globalIdx] = Math.floor(Math.random() * 500);
        this.cardTranslateYs[globalIdx] = Math.floor(Math.random() * 40) + 15;
      }
    }
    this.isBulkLoading = !ordered;
    if (this.da) {
      // 关闭动画时，一次性显示所有卡片
      const newVisible = [...this.cardsVisible];
      for (let i = 0; i < addCount; i++) {
        const globalIdx = fromIndex + i;
        newVisible[globalIdx] = true;
      }
      this.cardsVisible = newVisible;
      this.isBulkLoading = false;
      return;
    }
    const delays = this.cardDelays.slice(fromIndex, toIndex);
    const maxDelay = delays.length > 0 ? Math.max(...delays) : 0;
    setTimeout(() => {
      for (let i = 0; i < addCount; i++) {
        const globalIdx = fromIndex + i;
        setTimeout(() => {
          const newVisible = [...this.cardsVisible];
          newVisible[globalIdx] = true;
          this.cardsVisible = newVisible;
        }, this.cardDelays[globalIdx]);
      }
      setTimeout(() => {
        this.isBulkLoading = false;
      }, maxDelay + 1600);
    }, 100);
  }

  private onRefresh() {
    this.loadData(true);
  }

  private loadMore() {
    if (!this.isLoadingMore && this.hasMore && !this.isRefreshing) {
      this.loadData(false);
    }
  }

  private onCardClick(item: RecommendItem) {
    // ⭐ 预热详情（fire-and-forget）：把加载详情的 RTT 藏在转场+播放器初始化期间
    prefetchVideoDetail(item.aid > 0 ? String(item.aid) : item.id);
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/VideoPlayerPage',
      params: {
        bvid: item.id,
        aid: item.aid,  // ⭐ App API 的项只有 aid，没有 bvid
        title: item.title,
        ownerName: item.ownerName,
        coverUrl: item.coverUrl,
        cid: item.cid || 0
      }
    }).catch((err: Error) => {
      logError(`跳转播放页失败: ${err.message}`);
    });
  }

  /**
   * ⭐ 显示视频菜单（底部弹窗）
   */
  private showVideoMenu(item: RecommendItem): void {
    this.selectedMenuItem = item;
    this.isMenuSheetVisible = true;
  }

  /**
   * ⭐ 处理不感兴趣
   */
  private async handleDislike(item: RecommendItem): Promise<void> {
    try {
      const result = await sendDislikeFeedback(item.id, 1);
      this.removeVideoFromList(item.id);
      if (result.success) {
        this.getUIContext().getPromptAction().showToast({ message: '已减少此类推荐', duration: 1500 });
        logInfo(`[不感兴趣] ✅ ${item.id} - ${item.title}`);
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '已移除（服务器反馈暂不可用）', duration: 1500 });
        logInfo(`[不感兴趣] ⚠️ 本地移除 ${item.id}（${result.message}）`);
      }
    } catch (err) {
      logError(`[不感兴趣] 异常: ${err}`);
      try { this.removeVideoFromList(item.id); } catch (_) { }
      this.getUIContext().getPromptAction().showToast({ message: '已移除', duration: 1500 });
    }
  }

  /**
   * ⭐ 屏蔽UP主
   */
  private async handleBlockUploader(item: RecommendItem): Promise<void> {
    try {
      const result = await sendDislikeUpFeedback(item.id, item.ownerMid);
      UserBehaviorService.addBlockedUploader(item.ownerMid);
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
    this.dataSource.removeItem((item: RecommendItem) => item.id === bvid);
    // 同步更新 cardsVisible
    const count = this.dataSource.totalCount();
    this.cardsVisible = new Array(count).fill(true);
  }

  /**
   * ⭐ 移除某UP主的所有视频
   */
  private removeVideosByUploader(mid: string) {
    this.dataSource.removeItems((item: RecommendItem) => item.ownerMid === mid);
    // 同步更新 cardsVisible
    const count = this.dataSource.totalCount();
    this.cardsVisible = new Array(count).fill(true);
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

  private opacityToHexAlpha(opacity: number): string {
    const clamped = Math.max(0, Math.min(100, opacity));
    const hex = Math.round(clamped / 100 * 255).toString(16).toUpperCase();
    return hex.length < 2 ? '0' + hex : hex;
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
   * ⭐ 底部菜单弹窗内容
   */
  @Builder
  menuSheetContent() {
    Column() {
      Column() {
        // 顶部拖动条
        Row() {
          Row()
            .width(36)
            .height(4)
            .backgroundColor(this.isDarkMode ? '#666666' : '#CCCCCC')
            .borderRadius(2)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 12, bottom: 16 })

        // 菜单选项
        Column({ space: 12 }) {
          // 不感兴趣
          this.MenuItemButton('不感兴趣', () => {
            this.isMenuSheetVisible = false;
            if (this.selectedMenuItem) {
              this.handleDislike(this.selectedMenuItem);
            }
          })

          // 屏蔽UP主
          this.MenuItemButton('屏蔽UP主', () => {
            this.isMenuSheetVisible = false;
            if (this.selectedMenuItem) {
              this.handleBlockUploader(this.selectedMenuItem);
            }
          })

          // 拉黑UP主
          this.MenuItemButton('拉黑UP主', () => {
            this.isMenuSheetVisible = false;
            if (this.selectedMenuItem) {
              this.handleBlacklistUploader(this.selectedMenuItem);
            }
          })

          // 看过类似
          this.MenuItemButton('看过类似', () => {
            this.isMenuSheetVisible = false;
            if (this.selectedMenuItem) {
              this.handleSeenBefore(this.selectedMenuItem);
            }
          })

          // 取消
          this.MenuItemButton('取消', () => {
            this.isMenuSheetVisible = false;
          }, true)
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 30 })
      }
      .width(this.isLandscape ? '100%' : '85%')
      .backgroundColor(this.isDarkMode ? '#1A1A1A' : '#FFFFFF')
      .borderRadius(20)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * ⭐ 菜单项按钮
   */
  @Builder
  MenuItemButton(text: string, onClick: () => void, isCancelButton: boolean = false) {
    Text(text)
      .fontSize(15)
      .fontColor(isCancelButton ? '#FFFFFF' : (this.isDarkMode ? '#FFFFFF' : '#000000'))
      .width('100%')
      .height(50)
      .textAlign(TextAlign.Center)
      .backgroundColor(isCancelButton ? this.customThemeColor : (this.isDarkMode ? '#2A2A2A' : '#F5F5F5'))
      .borderRadius(20)
      .onClick(() => onClick())
  }

  @Builder
  VideoCard(item: RecommendItem) {
    Row() {
      Image(item.coverUrl)
        .width(180)
        .aspectRatio(16 / 9)
        .objectFit(ImageFit.Cover)
        .borderRadius(this.cardListBorderRadius)
        .backgroundColor('#E0E0E0')
        .margin({ right: 12 })
        .draggable(false)
        .sharedTransition(`videoCover_${item.id}`, this.da ? { duration: 0 } : {
          duration: 350,
          curve: Curve.EaseOut
        })

      Column() {
        Text(item.title)
          .fontSize(14)
          .fontColor(this.isDarkMode ? Color.White : Color.Black)
          .width('100%')
          .margin({ bottom: 6 })
          .textOverflow({ overflow: TextOverflow.None })
          .maxLines(this.isLandscape ? 3 : 4)
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
            .flexShrink(0)
          }
        }
        .width('100%')
        .margin({ top: 4 })
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
    .clickEffect({ level: 0, scale: 0.9 })
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          this.showVideoMenu(item);
        })
    )
    .onClick(() => this.onCardClick(item))
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

  build() {
    Refresh({ refreshing: $$this.isRefreshing, builder: this.customRefreshComponent() }) {
      Scroll(this.externalScroller!) {
        Column() {
          if (this.isLoading && this.dataSource.totalCount() === 0) {
            Row() { LoadingProgress().width(40).height(40).color('#007DFF') }
            .width('100%').height(200).justifyContent(FlexAlign.Center)
          } else {
            WaterFlow() {
              LazyForEach(this.dataSource, (item: RecommendItem, index: number) => {
                FlowItem() { this.VideoCard(item) }
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
              }, (item: RecommendItem) => item.id)
            }
            .columnsTemplate(this.columnCount === 2 ? '1fr 1fr' : '1fr')
            .columnsGap(this.cardListMargin).rowsGap(this.cardListMargin)
            .padding({
              left: this.cardListMargin,
              right: this.cardListMargin,
              top: (this.isLandscape ? 12 : 56) + (this.hideStatusBar ? 0 : this.statusBarHeight),
              bottom: this.isLandscape ? (176 + this.navIndicatorHeight) : (190 + this.navIndicatorHeight)
            })
            .backgroundColor('transparent')
            .clip(false)
          }
          if (this.isLoadingMore) {
            Row() {
              LoadingProgress().width(24).height(24).color('#007DFF')
              Text('加载更多...').fontSize(12).fontColor('#999999').margin({ left: 8 })
            }
            .width('100%').height(40).justifyContent(FlexAlign.Center)
            .backgroundColor('transparent')
          } else if (!this.hasMore && this.dataSource.totalCount() > 0) {
            Text('没有更多了')
              .fontSize(12).fontColor('#999999')
              .width('100%').height(40).textAlign(TextAlign.Center)
          }
        }.width('100%').clip(false)
      }
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .onWillScroll((_, yOffset) => {
        const absoluteOffset = this.externalScroller!.currentOffset().yOffset;
        this.homeScrollOffset = absoluteOffset;
        AppStorage.set('homeScrollOffset', absoluteOffset);

        // ⭐ 与首页 HomePage 一致的滚动显隐：lastScrollY 只在触发分支内更新，
        // delta 为「自上次触发以来的累积位移」，轻滑累积超阈值即可触发
        const delta = absoluteOffset - this.lastScrollY;
        if (absoluteOffset < 5) {
          // 滚动接近顶部时自然复位
          this.lastScrollY = 0;
          AppStorage.set('homeScrollOffset', 0);
          AppStorage.set('bottomBarHidden', false);
        } else if (delta > this.SCROLL_THRESHOLD) {
          this.lastScrollY = absoluteOffset;
          AppStorage.set('bottomBarHidden', true);
        } else if (delta < -this.SCROLL_THRESHOLD) {
          this.lastScrollY = absoluteOffset;
          AppStorage.set('bottomBarHidden', false);
        }
      })
      .onReachEnd(() => {
        if (!this.isLoadingMore && !this.isLoading && !this.isRefreshing && this.hasMore) {
          this.loadMore();
        }
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
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.isMenuSheetVisible, this.menuSheetContent(), {
      height: SheetSize.FIT_CONTENT,
      backgroundColor: Color.Transparent,
      dragBar: false,
      showClose: false,
      onDisappear: () => {
        this.isMenuSheetVisible = false;
      }
    })
  }
}