// FavoritesPage.ets - 我的收藏页面（同步B站官方收藏夹）
import {
  router,
  mediaquery,
  window,
  LengthMetrics,
  curves,
  SegmentButton,
  SegmentButtonOptions,
  SegmentButtonTextItem,
  ItemRestriction,
  uiMaterial
} from '@kit.ArkUI';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { FloatingVideoButton } from '../components/FloatingVideoButton';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  FavFolderItem,
  FavResourceItem,
  getCreatedFavFolders,
  getCollectedFavFolders,
  getFavFolderResources,
  formatDuration,
  formatCount
} from '../api/FavoritesApi';
import { getUserInfo, prefetchVideoDetail } from '../api/BilibiliApi';
import { HdsNavDestination, HdsNavDestinationTitleMode, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { motion } from '@kit.MultimodalAwarenessKit';
import { HdsMiniBarButton } from '../components/infra/HdsMiniBarButton';
import { StatusBarUtils } from '../utils/StatusBarUtils';
import { VibrateUtils } from '../utils/VibrateUtils';

enum PageMode {
  FOLDER_LIST,
  FOLDER_DETAIL
}

@Entry
@Component({ freezeWhenInactive: true })
struct FavoritesPage {
  @StorageLink('isDarkMode') @Watch('onThemeChange') isDarkMode: boolean = false;
  @StorageLink('wallpaper') wallpaper: string = 'default';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;
  @StorageLink('wallpaperColor') wallpaperColor: string = '#007DFF';
  @StorageLink('customThemeColor') @Watch('onThemeChange') customThemeColor: string = '#007DFF';
  @StorageLink('da') da: boolean = false;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = false;
  @StorageLink('cardCapsuleFollowTheme') @Watch('onThemeChange') cardCapsuleFollowTheme: boolean = false;
  @StorageLink('cardCapsuleShow') cardCapsuleShow: boolean = true;
  @StorageLink('cardCapsuleSize') cardCapsuleSize: number = 12;
  @StorageLink('cardCapsuleRadius') cardCapsuleRadius: number = 7;
  @StorageLink('cardCapsuleColor') cardCapsuleColor: string = '';
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 40;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1.5;
  @StorageLink('cardCustomColor') cardCustomColor: string = '';
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  @StorageLink('cardListMargin') cardListMargin: number = 0;
  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @StorageLink('statusBarHeight') globalStatusBarHeight: number = 0;

  @StorageLink('smartGripEnabled') smartGripEnabled: boolean = true;
  @StorageLink('floatBtnFollowTheme') floatBtnFollowTheme: boolean = true;
  @StorageLink('favoritesFloatBtnSide') favoritesFloatBtnSide: string = 'right';
  @StorageLink('favoritesFloatBtnY') favoritesFloatBtnY: number = 120;

  @State pageMode: PageMode = PageMode.FOLDER_LIST;
  @State activeTabIndex: number = 0;
  @State tabSelectedIndexes: number[] = [0];
  @State tabOptions: SegmentButtonOptions = SegmentButtonOptions.tab({
    buttons: [
      { text: '收藏夹' },
      { text: '订阅' }
    ] as ItemRestriction<SegmentButtonTextItem>,
    selectedFontColor: '#FB7299',
    backgroundBlurStyle: BlurStyle.BACKGROUND_THIN,
    selectedBackgroundColor: Color.White,
    textPadding: { top: 5, right: 5, bottom: 5, left: 5 }
  });
  @State myMaterial: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    interactive: true,
    lightEffect: {}
  });
  @State folderList: FavFolderItem[] = [];
  @State isLoadingFolders: boolean = true;
  @State folderListError: string = '';
  @State currentFolderId: number = 0;
  @State currentFolderTitle: string = '';
  @State resourceList: FavResourceItem[] = [];
  @State isLoadingResources: boolean = false;
  @State resourcePage: number = 1;
  @State resourceHasMore: boolean = true;
  @State isLoadingMore: boolean = false;
  @State isLoggedIn: boolean = false;
  @State userMid: number = 0;
  @State isLoadingCovers: boolean = false;
  @State isLandscape: boolean = false;
  @State columnCount: number = 1;

  @State customMaterialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
  @State customMaterialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.IMMERSIVE;
  @State supportImmersive: boolean = false;
  @State imageLoadFailed: boolean = false;

  @State contentOpacity: number = 1;
  @State contentScale: number = 1;
  @State isContentReady: boolean = true;
  @State isRefreshing: boolean = false;
  @State showBackToTop: boolean = false;
  @State btnScale: number = 1;
  @State hand: number = 0;
  @State dragOffsetX: number = 0;
  @State isDragging: boolean = false;

  @State tabExpandAnimated: boolean = false;

  private landscapeListener: mediaquery.MediaQueryListener | null = null;
  private waterFlowScroller: Scroller = new Scroller();
  private folderScroller: Scroller = new Scroller();
  private touchStartWX: number = 0;
  private touchStartWY: number = 0;
  private dragStartY: number = 0;
  private gripListenersInitialized: boolean = false;
  private gripSafeAreaLeft: number = 0;
  private gripSafeAreaRight: number = 0;
  private smartGripLeft: number = 0;
  private smartGripRight: number = 0;
  private smartGripBottom: number = 0;
  private maxFloatBtnBottom: number = 592;
  private bottomSafeHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    this.tabOptions = this.initTabOptions();
    this.initOrientation();
    this.checkImmersiveSupport();
    await this.checkLoginState();
    this.initSmartGrip();
    this.setStatusBarTransparent();
    this.initBottomSafeHeight();
  }

  private onThemeChange(): void {
    this.tabOptions = this.initTabOptions();
  }

  private initTabOptions(): SegmentButtonOptions {
    return SegmentButtonOptions.tab({
      buttons: [
        { text: '收藏夹' },
        { text: '订阅' }
      ] as ItemRestriction<SegmentButtonTextItem>,
      selectedFontColor: this.cardCapsuleFollowTheme ? this.customThemeColor : '#FB7299',
      fontColor: this.isDarkMode ? 'rgba(255, 255, 255, 0.7)' : 'rgba(0, 0, 0, 0.6)',
      backgroundBlurStyle: BlurStyle.BACKGROUND_THIN,
      selectedBackgroundColor: this.isDarkMode ? 'rgba(255, 255, 255, 0.18)' : Color.White,
      textPadding: { top: 5, right: 5, bottom: 5, left: 5 }
    });
  }

  aboutToDisappear(): void {
    if (this.landscapeListener) {
      this.landscapeListener.off('change');
      this.landscapeListener = null;
    }
  }

  private initOrientation(): void {
    const mainWindow = AppStorage.get<window.Window>('mainWindow');
    if (mainWindow) {
      const props = mainWindow.getWindowProperties();
      this.isLandscape = props.windowRect.width > props.windowRect.height;
      this.columnCount = this.isLandscape ? 2 : 1;
    }
    const mediaQuery = this.getUIContext().getMediaQuery();
    this.landscapeListener = mediaQuery.matchMediaSync('(orientation: landscape)');
    this.landscapeListener.on('change', (result: mediaquery.MediaQueryResult) => {
      const newIsLandscape = result.matches;
      if (this.isLandscape !== newIsLandscape) {
        this.isLandscape = newIsLandscape;
        this.columnCount = this.isLandscape ? 2 : 1;
        this.maxFloatBtnBottom = this.isLandscape ? 392 : 592;
      }
    });
  }

  private checkImmersiveSupport(): void {
    try {
      const apiVersion = deviceInfo.sdkApiVersion ?? 0;
      this.supportImmersive = apiVersion >= 23;
      if (this.supportImmersive) {
        const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
        if (types && types.includes(hdsMaterial.MaterialType.IMMERSIVE)) {
          this.customMaterialType = hdsMaterial.MaterialType.IMMERSIVE;
        } else {
          this.customMaterialType = hdsMaterial.MaterialType.ADAPTIVE;
        }
      }
    } catch (e) {
      this.supportImmersive = false;
    }
  }

  private async setStatusBarTransparent(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass: window.Window = await window.getLastWindow(context);
      await windowClass.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: this.isDarkMode ? '#FFFFFF' : '#000000'
      });
      const hideSb: boolean = AppStorage.get<boolean>('hideStatusBar') ?? false;
      await StatusBarUtils.setStatusBarHidden(context, hideSb);
    } catch (error) {
      logError('设置状态栏透明失败', error);
    }
  }

  private async initBottomSafeHeight(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(context);
      const navArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.bottomSafeHeight = this.getUIContext().px2vp(navArea.bottomRect.height);
    } catch (e) {
      logError('获取底部安全区域高度失败', e);
    }
  }

  private initSmartGrip(): void {
    if (this.gripListenersInitialized) return;
    try {
      motion.on('holdingHandChanged', (data: number) => {
        if (data !== this.hand && (data === 1 || data === 2)) {
          this.hand = data;
          this.recalcSmartGripPosition();
        }
      });
      this.gripListenersInitialized = true;
    } catch (err) {
      logWarn('[Favorites] 初始化智感握持失败:', err);
    }
  }

  private recalcSmartGripPosition(): void {
    const screenH: number = this.isLandscape ? 520 : 720;
    const bottomSafe: number = 24;
    if (this.isLandscape) {
      this.smartGripBottom = Math.max(bottomSafe + 24, screenH * 0.20);
    } else {
      this.smartGripBottom = Math.max(bottomSafe + 12, screenH * 0.15);
    }
    this.smartGripLeft = this.gripSafeAreaLeft + 16;
    this.smartGripRight = this.gripSafeAreaRight + 8;
  }

  private async checkLoginState(): Promise<void> {
    const cookie = AppStorage.get<string>('biliCookie') ?? '';
    this.isLoggedIn = cookie.includes('SESSDATA');
    if (this.isLoggedIn) {
      const user = await getUserInfo();
      if (user && user.isLogin) {
        this.userMid = user.mid;
        await this.loadFolders();
        return;
      }
    }
    this.isLoggedIn = false;
    this.isLoadingFolders = false;
  }

  private async loadFolders(): Promise<void> {
    if (this.folderList.length > 0) {
      this.isContentReady = false;
      await new Promise<void>((resolve) => {
        animateTo({ duration: this.da ? 0 : 200, curve: Curve.FastOutSlowIn }, () => {
          this.contentOpacity = 0;
        });
        setTimeout(resolve, 250);
      });
    } else {
      this.contentOpacity = 0;
    }

    this.isLoadingFolders = true;
    this.folderListError = '';
    try {
      if (this.activeTabIndex === 0) {
        if (this.userMid === 0) {
          this.folderListError = '无法获取用户信息';
          this.isLoadingFolders = false;
          return;
        }
        const folders = await getCreatedFavFolders(this.userMid);
        if (folders) {
          this.folderList = folders;
        } else {
          this.folderList = [];
          this.folderListError = '获取收藏夹列表失败';
        }
      } else {
        const folders = await getCollectedFavFolders();
        if (folders) {
          this.folderList = folders;
        } else {
          this.folderList = [];
          this.folderListError = '获取订阅收藏夹列表失败';
        }
      }
    } catch (err) {
      let error = err as Error;
      logError(`[FavoritesPage] loadFolders异常: ${error.message}`);
      this.folderListError = '加载失败，请稍后重试';
    }
    this.isLoadingFolders = false;

    if (this.folderList.length > 0) {
      setTimeout(() => {
        this.loadAllFolderCovers();
      }, 500);
    }

    this.isContentReady = true;
    setTimeout(() => {
      animateTo({ duration: this.da ? 0 : 400, curve: Curve.FastOutSlowIn }, () => {
        this.contentOpacity = 1;
      });
    }, 16);
  }

  private async loadAllFolderCovers(): Promise<void> {
    if (this.isLoadingCovers) return;
    this.isLoadingCovers = true;
    const maxFolders = Math.min(this.folderList.length, 6);
    for (let fi = 0; fi < maxFolders; fi++) {
      const folder = this.folderList[fi];
      if (folder.covers && folder.covers.length >= 3) {
        continue;
      }
      try {
        if (fi > 0) {
          await new Promise<void>((resolve: Function) => setTimeout(resolve, 300));
        }
        const result = await getFavFolderResources(folder.id, 1, 3);
        if (result && result.medias && result.medias.length > 0) {
          const coverUrls: string[] = [];
          for (let mi = 0; mi < result.medias.length; mi++) {
            if (result.medias[mi].cover) {
              coverUrls.push(result.medias[mi].cover);
            }
          }
          while (coverUrls.length < 3 && coverUrls.length > 0) {
            coverUrls.push(coverUrls[0]);
          }
          if (coverUrls.length > 0) {
            const updated: FavFolderItem[] = [];
            for (let j = 0; j < this.folderList.length; j++) {
              if (j === fi) {
                updated.push({
                  id: this.folderList[j].id,
                  title: this.folderList[j].title,
                  cover: this.folderList[j].cover,
                  covers: coverUrls,
                  media_count: this.folderList[j].media_count
                });
              } else {
                updated.push(this.folderList[j]);
              }
            }
            this.folderList = updated;
          }
        }
      } catch (err) {
        logWarn(`[FavoritesPage] 获取收藏夹${folder.id}封面失败: ${err}`);
      }
    }
    this.isLoadingCovers = false;
  }

  private async onTabChange(index: number): Promise<void> {
    if (this.pageMode === PageMode.FOLDER_DETAIL) {
      this.pageMode = PageMode.FOLDER_LIST;
    }
    this.activeTabIndex = index;
    this.tabSelectedIndexes = [index];
    await this.loadFolders();
  }

  private async onFolderClick(folder: FavFolderItem): Promise<void> {
    this.currentFolderId = folder.id;
    this.currentFolderTitle = folder.title;
    this.resourceList = [];
    this.resourcePage = 1;
    this.resourceHasMore = true;
    this.pageMode = PageMode.FOLDER_DETAIL;
    await this.loadFolderResources(true);
  }

  private async loadFolderResources(isRefresh: boolean): Promise<void> {
    if (this.currentFolderId === 0) return;
    if (!isRefresh) {
      if (!this.resourceHasMore || this.isLoadingMore) return;
      this.isLoadingMore = true;
    } else {
      this.isLoadingResources = true;
      this.resourcePage = 1;
    }
    try {
      const result = await getFavFolderResources(
        this.currentFolderId,
        this.resourcePage,
        20,
        'mtime',
        ''
      );
      if (result) {
        const medias = result.medias || [];
        if (isRefresh) {
          this.resourceList = medias;
        } else {
          const merged: FavResourceItem[] = [];
          for (let i = 0; i < this.resourceList.length; i++) {
            merged.push(this.resourceList[i]);
          }
          for (let i = 0; i < medias.length; i++) {
            merged.push(medias[i]);
          }
          this.resourceList = merged;
        }
        this.resourceHasMore = result.has_more || false;
      } else {
        if (isRefresh) {
          this.resourceList = [];
        }
        this.resourceHasMore = false;
      }
    } catch (err) {
      let error = err as Error;
      logError(`[FavoritesPage] loadFolderResources异常: ${error.message}`);
    }
    this.isLoadingResources = false;
    this.isLoadingMore = false;
  }

  private async onLoadMore(): Promise<void> {
    this.resourcePage++;
    await this.loadFolderResources(false);
  }

  private goBackToFolderList(): void {
    this.pageMode = PageMode.FOLDER_LIST;
    this.currentFolderId = 0;
    this.currentFolderTitle = '';
    this.resourceList = [];
  }

  private goToVideo(video: FavResourceItem): void {
    // ⭐ 预热详情（fire-and-forget）：收藏页只传 bvid，播放页要等详情里的 cid 才能起播，
    //   在转场这一刻先把这次 RTT 发出去，与转场/播放器初始化重叠
    prefetchVideoDetail(video.bvid);
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/VideoPlayerPage',
      params: {
        bvid: video.bvid,
        title: video.title,
        coverUrl: video.cover,
        duration: video.duration
      }
    }).catch((err: Error) => {
      logError('跳转视频播放失败', err.message);
      this.getUIContext().getPromptAction().showToast({ message: '播放页面暂不可用' });
    });
  }

  onBackPress(): boolean {
    if (this.pageMode === PageMode.FOLDER_DETAIL) {
      this.goBackToFolderList();
      return true;
    }
    return false;
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

  private opacityToHexAlpha(opacity: number): string {
    const clamped = Math.max(0, Math.min(100, opacity));
    const hex = Math.round(clamped / 100 * 255).toString(16).toUpperCase();
    return hex.length < 2 ? '0' + hex : hex;
  }

  private getCardBgColor(): string {
    if (this.cardCustomColor && this.cardCustomColor !== '#007DFF') {
      if (this.cardTransparentStyle) {
        return '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1);
      }
      return this.cardCustomColor;
    }
    if (this.cardTransparentStyle) {
      if (this.isDarkMode) {
        return `rgba(0,0,0,${this.cardBgOpacity / 100})`;
      }
      return `rgba(255,255,255,${this.cardBgOpacity / 100})`;
    }
    return this.isDarkMode ? '#2C2C2C' : '#FFFFFF';
  }

  private getCardBorderColor(): string {
    if (!this.cardTransparentStyle) return 'transparent';
    if (this.cardBorderFollowTheme) {
      return '#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1);
    }
    if (this.isDarkMode) {
      return `rgba(255,255,255,${this.cardBorderOpacity / 100})`;
    }
    return 'rgba(255,255,255,0.25)';
  }

  private getCoverByIndex(folder: FavFolderItem, idx: number): string {
    const fallback = folder.cover ?? '';
    if (folder.covers && folder.covers.length > idx) {
      return folder.covers[idx];
    }
    return fallback;
  }

  private triggerHaptic(): void {
    try {
      VibrateUtils.vibrateTime(15);
    } catch (err) {
    }
  }

  /** 顶部悬浮区总高（列表顶部避让：状态栏 + 悬浮行 40 + 间距，关注粉丝页面同款） */
  private topInset(): number {
    return (this.hideStatusBar ? 12 : (this.globalStatusBarHeight + 7)) + 40 + 16;
  }

  private async saveFloatBtnPrefs(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('favoritesFloatBtnSide', this.favoritesFloatBtnSide);
      await pref.put('favoritesFloatBtnY', this.favoritesFloatBtnY);
      await pref.flush();
    } catch (e) {
      logError('保存收藏页悬浮按钮位置失败', e);
    }
  }

  /** 胶囊分段项（关注粉丝页同款；选中主题色 + 底部下划线） */
  @Builder
  capsuleSegmentItem(idx: number, label: string) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.activeTabIndex === idx
          ? (this.cardCapsuleFollowTheme ? this.customThemeColor : '#FB7299')
          : (this.isDarkMode ? '#FFFFFF' : '#000000'))
        .width(62)
        .height(22)
        .textAlign(TextAlign.Center)
      if (this.activeTabIndex === idx) {
        Row()
          .width(28)
          .height(3)
          .borderRadius(1.5)
          .backgroundColor(this.cardCapsuleFollowTheme ? this.customThemeColor : '#FB7299')
      }
    }
    .width(62)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      if (this.activeTabIndex !== idx) {
        this.triggerHaptic();
        this.onTabChange(idx);
      }
    })
  }

  /*
  // ── 备用：SegmentButton 分段按钮版本（Hivid 同款，结合 uiMaterial.ImmersiveMaterial） ──
  @Builder
  segmentButtonBuilder() {
    if (this.pageMode === PageMode.FOLDER_LIST) {
      Row() {
        SegmentButton({
          options: this.tabOptions,
          selectedIndexes: $tabSelectedIndexes,
          onItemClicked: (idx: number) => {
            if (this.activeTabIndex !== idx) {
              this.triggerHaptic();
              this.onTabChange(idx);
            }
          }
        })
          .width(150)
      }
      .borderRadius(20)
      .systemMaterial(this.myMaterial)
    } else {
      Row() {
        Text(this.currentFolderTitle)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .borderRadius(20)
      .systemMaterial(this.myMaterial)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
    }
  }
  */

  // ==================== Build ====================

  build() {
    HdsNavDestination() {
      Stack() {
        this.BackgroundLayer()

        Column() {
          if (this.pageMode === PageMode.FOLDER_LIST) {
            if (!this.isLoggedIn) {
              this.NotLoggedInView()
            } else if (this.isLoadingFolders && this.folderList.length === 0) {
              this.SkeletonView()
            } else if (this.folderListError.length > 0 && this.folderList.length === 0) {
              this.ErrorView()
            } else if (this.folderList.length === 0) {
              this.EmptyView()
            } else {
              this.FolderContent()
            }
          } else {
            this.FolderDetailView()
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .opacity(this.contentOpacity)
        .scale({ x: this.contentScale, y: this.contentScale })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        // ── 顶部悬浮层：返回钮（左上）+ 切换胶囊（水平居中，恒展开），悬浮于列表之上（粉丝关注页面同款）──
        Row() {
          // 返回按钮：悬浮圆钮（与关注粉丝页同款 HdsMiniBarButton 材质）
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
                if (this.pageMode === PageMode.FOLDER_DETAIL) {
                  this.goBackToFolderList();
                } else {
                  router.back();
                }
              }
            }) {
              Image($r('app.media.ic_public_arrow_left_filled'))
                .width(24).height(24)
                .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            }
          }

          Blank()
            .layoutWeight(1)

          // 收藏夹/订阅切换胶囊（恒展开分段选择器，与关注粉丝页同款材质）
          Row() {
            HdsMiniBarButton({
              barWidth: 150,
              barHeight: 40,
              contentPadding: 4,
              materialType: hdsMaterial.MaterialType.IMMERSIVE,
              materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
              barOverlap: true,
              barPosition: BarPosition.End
            }) {
              if (this.pageMode === PageMode.FOLDER_LIST) {
                Row() {
                  this.capsuleSegmentItem(0, '收藏夹')
                  this.capsuleSegmentItem(1, '订阅')
                }
                .padding({ left: 4, right: 4 })
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
              } else {
                Row() {
                  Text(this.currentFolderTitle)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .padding({ left: 16, right: 16 })
                .width('100%')
                .height('100%')
                .justifyContent(FlexAlign.Center)
                .alignItems(VerticalAlign.Center)
              }
            }
          }

          Blank()
            .layoutWeight(1)

          // 右侧对称占位（与返回钮等宽）：保证胶囊按屏幕几何中心居中
          Row()
            .width(40)
            .height(40)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 8, right: 8, top: this.hideStatusBar ? 12 : (this.globalStatusBarHeight + 7) })

        this.FloatButtonLayer()

        FloatingVideoButton()
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.TopStart)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .hideTitleBar(true)
    .hideBackButton(true)
    .onBackPressed(() => {
      if (this.pageMode === PageMode.FOLDER_DETAIL) {
        this.goBackToFolderList();
        return true;
      }
      router.back();
      return true;
    })
    .backgroundColor('transparent')
    /*
    // 备用：HdsNavDestination 标题栏渐变模糊 + SegmentButton 配置
    .titleBar({
      avoidLayoutSafeArea: true,
      padding: { start: LengthMetrics.vp(16), end: LengthMetrics.vp(16) },
      style: {
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
        originalStyle: {
          backgroundStyle: {
            backgroundColor: Color.Transparent
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: this.isDarkMode ? 'rgba(30, 30, 30, 0.85)' : 'rgba(255, 255, 255, 0.85)'
          }
        }
      },
      content: {
        title: {
          mainTitle: ''
        },
        backIcon: {
          action: (): void => {
            if (this.pageMode === PageMode.FOLDER_DETAIL) {
              this.goBackToFolderList();
            } else {
              router.back();
            }
          }
        },
        stackBuilder: (): void => {
          this.segmentButtonBuilder();
        }
      }
    })
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .bindToScrollable([this.folderScroller, this.waterFlowScroller])
    */
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ==================== 背景层 ====================

  @Builder
  BackgroundLayer() {
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
  }

  // ==================== 未登录 ====================

  @Builder
  NotLoggedInView() {
    Column() {
      Blank()
      Text('请先登录B站账号')
        .fontSize(16)
        .fontColor(this.isDarkMode ? '#999999' : '#666666')
      Button('去登录')
        .type(ButtonType.Capsule)
        .backgroundColor('#FB7299')
        .fontColor(Color.White)
        .margin({ top: 16 })
        .onClick(() => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/QrCodeLoginPage' }).catch(() => {});
        })
      Blank()
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 骨架屏 ====================

  @Builder
  SkeletonView() {
    WaterFlow() {
      ForEach([0, 1, 2, 3], (idx: number) => {
        FlowItem() {
          this.SkeletonFolderCard()
        }
        .width('100%')
        .margin({ top: idx < this.columnCount ? this.topInset() : 0 })
      })
    }
    .columnsTemplate(this.columnCount === 2 ? '1fr 1fr' : '1fr')
    .columnsGap(this.cardListMargin)
    .rowsGap(this.cardListMargin)
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 12, right: 12, bottom: 0 })
    .backgroundColor('transparent')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  @Builder
  SkeletonFolderCard() {
    Row() {
      Column() { Blank() }
      .width(160)
      .height(120)
      .backgroundColor('#E0E0E0')
      .borderRadius(20)
      .margin({ right: 16 })

      Column() {
        Column() { Blank() }
        .width('80%')
        .height(16)
        .borderRadius(4)
        .margin({ bottom: 8 })
        .backgroundColor('#E0E0E0')

        Column() { Blank() }
        .width(60)
        .height(12)
        .borderRadius(4)
        .backgroundColor('#E0E0E0')
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.Start)
    }
    .alignItems(VerticalAlign.Center)
    .height(168)
    .backgroundColor(this.isDarkMode ? '#2C2C2C' : '#FFFFFF')
    .borderRadius(20)
    .padding({ left: 18, right: 20, top: 15, bottom: 15 })
    .clip(true)
    .opacity(0.35)
    .animation(this.da ? { duration: 0 } : { duration: 1000, curve: Curve.Ease, iterations: -1, playMode: PlayMode.Alternate })
  }

  // ==================== 错误状态 ====================

  @Builder
  ErrorView() {
    Column() {
      Blank()
      Text(this.folderListError)
        .fontSize(14)
        .fontColor('#FF4444')
        .margin({ bottom: 12 })
      Button('重试')
        .type(ButtonType.Capsule)
        .backgroundColor('#FB7299')
        .fontColor(Color.White)
        .onClick(() => this.loadFolders())
      Blank()
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 空状态 ====================

  @Builder
  EmptyView() {
    Column() {
      Blank()
      Text(this.activeTabIndex === 0 ? '还没有创建收藏夹' : '还没有订阅收藏夹')
        .fontSize(16)
        .fontColor(this.isDarkMode ? '#999999' : '#666666')
      Blank()
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 收藏夹列表内容 ====================

  @Builder
  FolderContent() {
    Column() {
      Refresh({ refreshing: $$this.isRefreshing }) {
        WaterFlow({ scroller: this.folderScroller }) {
          ForEach(this.folderList, (item: FavFolderItem, index: number) => {
            FlowItem() {
              this.FolderCard(item)
            }
            .width('100%')
            .margin({ top: index < this.columnCount ? this.topInset() : 0 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          }, (item: FavFolderItem) => String(item.id))
        }
        .columnsTemplate(this.columnCount === 2 ? '1fr 1fr' : '1fr')
        .columnsGap(this.cardListMargin)
        .rowsGap(this.cardListMargin + 8)
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .cachedCount(30)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .padding({ left: 12, right: 12, bottom: 0 })
        .backgroundColor('transparent')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
        .opacity(this.isContentReady ? 1 : 0)
        .animation(this.da ? { duration: 0 } : { duration: 400, curve: Curve.FastOutSlowIn })
        .onScrollIndex((firstIndex: number) => {
          const scrollOffset: number = this.folderScroller.currentOffset().yOffset;
          this.showBackToTop = Math.abs(scrollOffset) > 300;
        })
      }
      .onRefreshing(() => {
        this.loadFolders().finally(() => {
          this.isRefreshing = false;
        });
      })
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('transparent')
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 收藏夹卡片 ====================

  @Builder
  FolderCard(folder: FavFolderItem) {
    Row() {
      Stack() {
        if (folder.cover) {
          Image(this.getCoverByIndex(folder, 2))
            .width(160)
            .height(120)
            .borderRadius(this.cardListBorderRadius)
            .objectFit(ImageFit.Cover)
            .border({ width: 1, color: this.isDarkMode ? '#33FFFFFF' : '#33000000' })
            .offset({ x: 24, y: 18 })
            .opacity(0.20)

          Image(this.getCoverByIndex(folder, 1))
            .width(160)
            .height(120)
            .borderRadius(this.cardListBorderRadius)
            .objectFit(ImageFit.Cover)
            .border({ width: 1, color: this.isDarkMode ? '#55FFFFFF' : '#55000000' })
            .offset({ x: 12, y: 9 })
            .opacity(0.50)

          Image(this.getCoverByIndex(folder, 0))
            .width(160)
            .height(120)
            .borderRadius(this.cardListBorderRadius)
            .objectFit(ImageFit.Cover)
        } else {
          Text('📁')
            .fontSize(36)
            .opacity(0.5)
        }
      }
      .width(160)
      .height(120)
      .margin({ right: 24 })

      Column() {
        Blank()
          .layoutWeight(1)
        Text(folder.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(22)
          .width('100%')

        Row() {
          Text(String(folder.media_count) + ' 个内容')
            .fontSize(13)
            .fontColor(this.isDarkMode ? '#999999' : '#999999')
        }
        .width('100%')
        .margin({ top: 6 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 100 })
    }
    .width('100%')
    .height(168)
    .padding({ left: 18, right: 20, top: 15, bottom: 33 })
    .backgroundColor(this.getCardBgColor())
    .border({
      width: this.cardTransparentStyle ? this.cardBorderWidth : 0,
      color: this.getCardBorderColor()
    })
    .borderRadius(this.cardListBorderRadius)
    .clip(true)
    .shadow({
      radius: 16,
      color: this.isDarkMode ? 'rgba(0, 0, 0, 0.3)' : 'rgba(0, 0, 0, 0.08)',
      offsetX: 0,
      offsetY: 2
    })
    .onClick(() => {
      this.triggerHaptic();
      this.onFolderClick(folder);
    })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
  }

  // ==================== 收藏夹详情（视频列表） ====================

  @Builder
  FolderDetailView() {
    Column() {
      if (this.isLoadingResources) {
        WaterFlow() {
          ForEach([0, 1, 2, 3], (idx: number) => {
            FlowItem() {
              this.SkeletonVideoCard()
            }
            .width('100%')
            .margin({ top: idx < this.columnCount ? this.topInset() : 0 })
          })
        }
        .columnsTemplate(this.columnCount === 2 ? '1fr 1fr' : '1fr')
        .columnsGap(this.cardListMargin)
        .rowsGap(this.cardListMargin)
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12, bottom: 0 })
        .backgroundColor('transparent')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
      } else if (this.resourceList.length === 0) {
        Column() {
          Blank()
          Text('收藏夹为空')
            .fontSize(16)
            .fontColor(this.isDarkMode ? '#999999' : '#666666')
          Blank()
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        Refresh({ refreshing: $$this.isRefreshing }) {
          WaterFlow({ scroller: this.waterFlowScroller }) {
            ForEach(this.resourceList, (item: FavResourceItem, index: number) => {
              FlowItem() {
                this.VideoCard(item)
              }
              .width('100%')
              .margin({ top: index < this.columnCount ? this.topInset() : 0 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
            }, (item: FavResourceItem) => String(item.id))

            if (this.resourceHasMore) {
              FlowItem() {
                if (this.isLoadingMore) {
                  Row() {
                    LoadingProgress()
                      .width(20)
                      .height(20)
                      .color('#FB7299')
                    Text('加载中...')
                      .fontSize(13)
                      .fontColor(this.isDarkMode ? '#999999' : '#666666')
                      .margin({ left: 8 })
                  }
                  .width('100%')
                  .height(48)
                  .justifyContent(FlexAlign.Center)
                } else {
                  Text('点击加载更多')
                    .fontSize(13)
                    .fontColor('#FB7299')
                    .width('100%')
                    .height(48)
                    .textAlign(TextAlign.Center)
                    .onClick(() => this.onLoadMore())
                }
              }
            }
          }
          .columnsTemplate(this.columnCount === 2 ? '1fr 1fr' : '1fr')
          .columnsGap(this.cardListMargin)
          .rowsGap(this.cardListMargin + 4)
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .cachedCount(30)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .padding({ left: 12, right: 12, bottom: 0 })
          .backgroundColor('transparent')
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
          .onScrollIndex((firstIndex: number) => {
            const scrollOffset: number = this.waterFlowScroller.currentOffset().yOffset;
            this.showBackToTop = Math.abs(scrollOffset) > 300;
          })
        }
        .onRefreshing(() => {
          this.loadFolderResources(true).finally(() => {
            this.isRefreshing = false;
          });
        })
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('transparent')
      }
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 视频卡片 ====================

  @Builder
  VideoCard(video: FavResourceItem) {
    Row() {
      Stack() {
        if (video.cover) {
          Image(video.cover)
            .width(160)
            .height(90)
            .objectFit(ImageFit.Cover)
            .backgroundColor('#E0E0E0')
            .borderRadius(this.cardListBorderRadius)
        } else {
          Column()
            .width(160)
            .height(90)
            .backgroundColor(this.isDarkMode ? '#3A3A3A' : '#E0E0E0')
            .borderRadius(this.cardListBorderRadius)
        }

        if (video.duration > 0) {
          Text(formatDuration(video.duration))
            .fontSize(10)
            .fontColor('#FFFFFF')
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .backgroundColor('rgba(0,0,0,0.6)')
            .borderRadius(3)
            .position({ bottom: 6, right: 6 })
        }
      }
      .width(160)
      .height(90)
      .margin({ right: 12 })

      Column() {
        Text(video.title)
          .fontSize(14)
          .fontColor(this.isDarkMode ? Color.White : Color.Black)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ bottom: 6 })

        Row() {
          if (video.cnt_info) {
            if (this.cardCapsuleShow) {
              Text(formatCount(video.cnt_info.play) + '播放')
                .fontSize(this.cardCapsuleSize)
                .fontColor(this.cardCapsuleColor
                  ? (this.isDarkMode ? '#FFFFFF' : '#000000')
                  : $r('app.color.color_primary_text'))
                .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                .backgroundColor(this.cardCapsuleColor
                  ? this.cardCapsuleColor
                  : (this.cardCapsuleFollowTheme ? this.customThemeColor : 'rgba(186, 136, 65, 1)'))
                .borderRadius(this.cardCapsuleRadius)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .flexShrink(1)
            } else {
              Text(formatCount(video.cnt_info.play) + '播放')
                .fontSize(12)
                .fontColor(this.isDarkMode ? '#888888' : '#999999')
            }

            Text(formatCount(video.cnt_info.danmaku))
              .fontSize(12)
              .fontColor(this.isDarkMode ? '#888888' : '#999999')
              .margin({ left: 8 })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(HorizontalAlign.Start)
    }
    .alignItems(VerticalAlign.Center)
    .height(130)
    .padding(12)
    .backgroundColor(this.getCardBgColor())
    .border({
      width: this.cardTransparentStyle ? this.cardBorderWidth : 0,
      color: this.getCardBorderColor()
    })
    .borderRadius(this.cardListBorderRadius)
    .clip(true)
    .shadow({
      radius: 16,
      color: this.isDarkMode ? 'rgba(0, 0, 0, 0.3)' : 'rgba(0, 0, 0, 0.08)',
      offsetX: 0,
      offsetY: 2
    })
    .onClick(() => {
      this.triggerHaptic();
      this.goToVideo(video);
    })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
  }

  // ==================== 骨架屏视频卡片 ====================

  @Builder
  SkeletonVideoCard() {
    Row() {
      Column() { Blank() }
      .width(160)
      .height(90)
      .backgroundColor('#E0E0E0')
      .borderRadius(20)
      .margin({ right: 12 })

      Column() {
        Column() { Blank() }
        .width('100%')
        .height(14)
        .borderRadius(4)
        .margin({ bottom: 6 })
        .backgroundColor('#E0E0E0')

        Row() {
          Column() { Blank() }
          .width(60)
          .height(12)
          .borderRadius(6)
          .backgroundColor('#E0E0E0')

          Column() { Blank() }
          .width(40)
          .height(12)
          .borderRadius(4)
          .margin({ left: 8 })
          .backgroundColor('#E0E0E0')
        }
        .width('100%')

        Blank()
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(HorizontalAlign.Start)
    }
    .alignItems(VerticalAlign.Center)
    .height(130)
    .backgroundColor(this.isDarkMode ? '#2C2C2C' : '#FFFFFF')
    .borderRadius(20)
    .padding(12)
    .clip(true)
    .opacity(0.35)
    .animation(this.da ? { duration: 0 } : { duration: 1000, curve: Curve.Ease, iterations: -1, playMode: PlayMode.Alternate })
  }

  // ==================== 悬浮按钮 ====================

  @Builder
  FloatButtonLayer() {
    if (this.smartGripEnabled && !this.isLandscape) {
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
        Column()
          .width(48).height(48)
          .hitTestBehavior(HitTestMode.Block)
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.touchStartWY = event.touches[0].windowY;
              this.dragStartY = this.favoritesFloatBtnY;
              this.isDragging = true;
            } else if (event.type === TouchType.Move) {
              const offYpx = event.touches[0].windowY - this.touchStartWY;
              this.favoritesFloatBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.dragStartY - Math.round(this.getUIContext().px2vp(offYpx))));
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.isDragging = false;
              if (event.type === TouchType.Up) {
                this.triggerHaptic();
                animateTo({ duration: 100, curve: Curve.FastOutLinearIn }, () => {
                  this.btnScale = 0.8;
                });
                setTimeout(() => {
                  animateTo({ duration: 300, curve: curves.springMotion(0.4, 0.8) }, () => {
                    this.btnScale = 1;
                  });
                }, 100);
                if (this.pageMode === PageMode.FOLDER_LIST) {
                  this.folderScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300, curve: Curve.EaseOut } });
                } else {
                  this.waterFlowScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300, curve: Curve.EaseOut } });
                }
              }
            }
          })
      }
      .width(48).height(48)
      .position({ bottom: this.favoritesFloatBtnY, left: this.smartGripLeft })
      .opacity(this.hand === 1 && this.showBackToTop ? 1 : 0)
      .scale({ x: this.showBackToTop ? this.btnScale : 0, y: this.showBackToTop ? this.btnScale : 0 })
      .hitTestBehavior(this.hand === 1 && this.showBackToTop ? HitTestMode.Default : HitTestMode.None)
      .animation(this.da || this.isDragging ? { duration: 0 } : { duration: 300, curve: curves.springMotion(0.3, 0.4) })

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
        Column()
          .width(48).height(48)
          .hitTestBehavior(HitTestMode.Block)
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.touchStartWY = event.touches[0].windowY;
              this.dragStartY = this.favoritesFloatBtnY;
              this.isDragging = true;
            } else if (event.type === TouchType.Move) {
              const offYpx = event.touches[0].windowY - this.touchStartWY;
              this.favoritesFloatBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.dragStartY - Math.round(this.getUIContext().px2vp(offYpx))));
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.isDragging = false;
              if (event.type === TouchType.Up) {
                this.triggerHaptic();
                animateTo({ duration: 100, curve: Curve.FastOutLinearIn }, () => {
                  this.btnScale = 0.8;
                });
                setTimeout(() => {
                  animateTo({ duration: 300, curve: curves.springMotion(0.4, 0.8) }, () => {
                    this.btnScale = 1;
                  });
                }, 100);
                if (this.pageMode === PageMode.FOLDER_LIST) {
                  this.folderScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300, curve: Curve.EaseOut } });
                } else {
                  this.waterFlowScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300, curve: Curve.EaseOut } });
                }
              }
            }
          })
      }
      .width(48).height(48)
      .position({ bottom: this.favoritesFloatBtnY, right: this.smartGripRight })
      .opacity(this.hand !== 1 && this.showBackToTop ? 1 : 0)
      .scale({ x: this.showBackToTop ? this.btnScale : 0, y: this.showBackToTop ? this.btnScale : 0 })
      .hitTestBehavior(this.hand !== 1 && this.showBackToTop ? HitTestMode.Default : HitTestMode.None)
      .animation(this.da || this.isDragging ? { duration: 0 } : { duration: 300, curve: curves.springMotion(0.3, 0.4) })
    } else {
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
        Column()
          .width(48).height(48)
          .hitTestBehavior(HitTestMode.Block)
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.touchStartWX = event.touches[0].windowX;
              this.touchStartWY = event.touches[0].windowY;
              this.dragStartY = this.favoritesFloatBtnY;
              this.dragOffsetX = 0;
              this.isDragging = true;
            } else if (event.type === TouchType.Move) {
              const offYpx = event.touches[0].windowY - this.touchStartWY;
              const offXpx = event.touches[0].windowX - this.touchStartWX;
              this.favoritesFloatBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.dragStartY - Math.round(this.getUIContext().px2vp(offYpx))));
              this.dragOffsetX = Math.round(this.getUIContext().px2vp(offXpx));
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.isDragging = false;
              if (event.type === TouchType.Up) {
                const totalOffsetX: number = this.dragOffsetX;
                let newSide: string = this.favoritesFloatBtnSide;
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
                      this.favoritesFloatBtnSide = newSide;
                    }
                  });
                } else {
                  this.dragOffsetX = 0;
                }
                AppStorage.set('favoritesFloatBtnSide', this.favoritesFloatBtnSide);
                AppStorage.set('favoritesFloatBtnY', this.favoritesFloatBtnY);
                this.saveFloatBtnPrefs();
                this.triggerHaptic();
                animateTo({ duration: 100, curve: Curve.FastOutLinearIn }, () => {
                  this.btnScale = 0.8;
                });
                setTimeout(() => {
                  animateTo({ duration: 300, curve: curves.springMotion(0.4, 0.8) }, () => {
                    this.btnScale = 1;
                  });
                }, 100);
                if (this.pageMode === PageMode.FOLDER_LIST) {
                  this.folderScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300, curve: Curve.EaseOut } });
                } else {
                  this.waterFlowScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300, curve: Curve.EaseOut } });
                }
              }
            }
          })
      }
      .width(48).height(48)
      .position(this.favoritesFloatBtnSide === 'left'
        ? { bottom: this.favoritesFloatBtnY, left: 32 }
        : { bottom: this.favoritesFloatBtnY, right: 32 })
      .opacity(this.showBackToTop ? 1 : 0)
      .scale({ x: this.showBackToTop ? this.btnScale : 0, y: this.showBackToTop ? this.btnScale : 0 })
      .hitTestBehavior(this.showBackToTop ? HitTestMode.Default : HitTestMode.None)
      .animation(this.da || this.isDragging ? { duration: 0 } : { duration: 300, curve: Curve.Ease })
      .translate({ x: this.dragOffsetX })
    }
  }
}
