/**
 * PgcChannelPage.ets — 番剧/影视频道页（首页频道体系内嵌）
 *
 * - seasonType=1 番剧（含国创），seasonType=2 影视（电影/电视剧/纪录片）
 * - 双列瀑布流卡片 + 下拉刷新 + 上拉加载更多
 * - 点击卡片 → VideoPlayerPage（传 mediaId，复用搜索页 PGC 跳转方式）
 */
import { curves, display, mediaquery } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { logError } from '../utils/Logger';
import { VibrateUtils } from '../utils/VibrateUtils';
import {
  fetchPgcIndexCondition,
  fetchPgcSeasonsByParams,
  PgcIndexFilter,
  PgcIndexOrder,
  PgcIndexValue,
  PgcSeason
} from '../api/PgcApi';
import { GenericDataSource } from '../model/GenericDataSource';

@Component({ freezeWhenInactive: true })
export struct PgcChannelPage {
  /** 频道类型：1=番剧 2=影视 */
  seasonType?: number = 1;
  /** ⭐ Tab 频道索引（HomeChannelContainer：番剧=4、影视=5），用于信号隔离：仅当前活跃频道响应索引按钮 */
  @Prop channelIndex: number = 4;
  /** ⭐ 面板锁定状态：锁定后展开面板默认全部展开（番剧页收起按钮左侧的锁定/解锁按钮控制，persist 持久化） */
  @State panelLocked: boolean = false;

  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @StorageLink('navIndicatorHeight') navIndicatorHeight: number = 0;
  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  @StorageLink('cardListMargin') cardListMargin: number = 12;
  // ⚠️ 卡片样式扩展（与消息页/动态页一致）：透明样式/背景透明度/边框
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 15;
  @StorageLink('cardCustomColor') cardCustomColor: string = '#007DFF';
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = true;
  @StorageLink('da') da: boolean = false;
  @StorageLink('refreshHomeFlag') @Watch('onRefreshFlagChange') refreshFlag: number = 0;
  @StorageLink('scrollToTopFlag') @Watch('onScrollToTop') scrollToTopFlag: number = 0;
  // ⭐ 番剧索引面板展开/收起信号（Index.ets 索引按钮驱动；仅番剧 seasonType=1 响应）
  @StorageLink('pgcIndexPanelSignal') @Watch('onIndexPanelSignal') pgcIndexPanelSignal: number = 0;

  // ⭐ 索引筛选面板状态
  @State isIndexPanelExpanded: boolean = false;
  // ⭐ 收起标志：收起时行高/padding 归零但面板不移除（占 0 高），从根源消除"移除面板瞬间"的布局跳变
  @State panelCollapsed: boolean = false;
  // ⭐ 面板当前动画方向：true=正在展开，false=正在收起。
  //    forceFinishPanelAnimation 用它区分方向（不能用 isIndexPanelExpanded&&!panelCollapsed，
  //    因为收起动画期间该条件也成立，会误判为展开方向导致反复动画）
  private panelExpanding: boolean = false;
  @State isFilterExpanded: boolean = false;  // ⭐ 折叠态：只显示排序/地区/风格，其余维度展开后显示
  @State orderList: PgcIndexOrder[] = [];
  @State filterList: PgcIndexFilter[] = [];
  @State selectedOrder: number = 0;
  @State selectedFilterIdx: number[] = [];
  private indexParams: Record<string, string> = {};
  // ⭐ 收起动画 token：新收起递增使旧 setTimeout 回调作废（快速反复点按时防错乱）
  private collapseToken: number = 0;
  // ⭐ 面板展开/收起忙碌标志：动画/加载进行中忽略新的索引按钮信号，避免状态不同步
  private panelBusy: boolean = false;
  // ⭐ 面板逐行高度动画：rowHeights 每行 height 0↔44 交错动画，height 参与布局实时推动信息流（挤着下移/上移）
  @State rowHeights: number[] = [];
  // ⭐ 整体淡出动画（收起用）：单节点 opacity+scale，避免逐行高度动画在收起方向的卡顿
  @State panelOpacity: number = 1;
  @State panelScale: number = 1;
  // ⭐ 横屏左侧面板宽度（0=收起，屏宽*0.33=展开）：Row 分栏常驻，宽度动画平滑过渡（信息流 layoutWeight 自动跟随）
  @State panelWidth: number = 0;
  // ⭐ Column 垂直 padding 动画值：收起时同步收缩到 0，避免行收完后 16vp padding 残留导致突然上移
  @State panelPaddingV: number = 8;
  @State panelMarginV: number = 12; // 包裹面板的上下边距（随收起动画一并归零，消除末尾跳变）
  private rowAnimToken: number = 0;
  // ⭐ 展开更多/收起的独立动画 token：不与 rowAnimToken 共享，
  //    避免展开更多时作废 expandRowHeights 的 panelBusy=false 回调导致面板无法再次收起
  private filterAnimToken: number = 0;
  private readonly PANEL_ROW_HEIGHT: number = 44;

  private dataSource: GenericDataSource<PgcSeason> = new GenericDataSource();
  private scroller: Scroller = new Scroller();
  @State isLoading: boolean = true;
  @State isRefreshing: boolean = false;
  // ⭐ 长按下拉跳搜索（与 HomePage 一致：OverDrag 持续 800ms → 松手进搜索页而非刷新）
  private longPullTimer: number = -1;
  private longPullTriggered: boolean = false;
  @State refreshBuilderText: string = '下拉刷新';
  @State showSearchIcon: boolean = false;
  @State isLoadingMore: boolean = false;
  private pageNum: number = 1;
  private hasMore: boolean = true;
  private readonly PAGE_SIZE: number = 20;
  private lastScrollY: number = 0;
  private readonly SCROLL_THRESHOLD: number = 10;
  // ⭐ 横竖屏检测：竖屏 3 列，横屏 4 列
  @State isLandscape: boolean = false;
  private landscapeListener: mediaquery.MediaQueryListener | null = null;

  // 入场动画
  @State cardsVisible: boolean[] = [];
  @State isBulkLoading: boolean = false;
  private cardDelays: number[] = [];
  private cardTranslateYs: number[] = [];

  private readonly TITLE_BAR_HEIGHT: number = 48;

  aboutToAppear() {
    this.setupMediaQuery();
    this.loadPanelLocked();
    this.loadData(true);
  }

  /** ⭐ 读取持久化的面板锁定状态（番剧页锁定后展开默认全部展开） */
  private async loadPanelLocked(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(ctx, 'my_app_settings');
      const v = pref.getSync('pgcPanelLocked', false) as boolean;
      this.panelLocked = v === true;
    } catch (_e) { }
  }

  /** ⭐ 持久化面板锁定状态 */
  private async savePanelLocked(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(ctx, 'my_app_settings');
      await pref.putSync('pgcPanelLocked', this.panelLocked);
      // ⭐ 必须 flush 才落盘（与 CardStyleSheet 先例一致），否则重启后不生效
      await pref.flush();
    } catch (_e) { }
  }

  aboutToDisappear() {
    // 长按下拉计时器保底清理，避免切频道后回调仍改状态
    if (this.longPullTimer !== -1) {
      clearTimeout(this.longPullTimer);
      this.longPullTimer = -1;
    }
    if (this.landscapeListener) {
      this.landscapeListener.off('change');
      this.landscapeListener = null;
    }
  }

  /** ⭐ 横竖屏监听：竖屏 3 列 / 横屏 4 列 */
  private setupMediaQuery(): void {
    try {
      this.landscapeListener = this.getUIContext().getMediaQuery().matchMediaSync('(min-aspect-ratio: 1.4)');
      this.landscapeListener.on('change', (result: mediaquery.MediaQueryResult) => {
        this.isLandscape = result.matches;
      });
      this.isLandscape = this.landscapeListener.matches;
    } catch (_e) { }
  }

  /** 当前列数：竖屏 3 列，横屏 4 列 */
  private getColumnTemplate(): string {
    return this.isLandscape ? '1fr 1fr 1fr 1fr' : '1fr 1fr 1fr';
  }

  private onRefreshFlagChange(): void {
    this.loadData(true);
  }

  private onScrollToTop(): void {
    if (this.scroller) {
      this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: this.da ? 0 : 300 } });
    }
  }

  // ⭐ 防重入：面板信号与 Refresh 回调可能同时触发加载，避免重复请求导致信息流重置
  private isLoadingData: boolean = false;

  private async loadData(isRefresh: boolean, silent: boolean = false, skipEntryAnim: boolean = false): Promise<void> {
    if (isRefresh) {
      if (this.isLoadingData) return; // ⭐ 防重入：丢弃并发重复加载
      this.isLoadingData = true;
      // ⭐ silent：面板筛选/显隐触发时不设 isRefreshing，
      // 避免 Refresh 组件 onStateChange 回调再次触发 onRefresh 导致重复加载（信息流重置）
      if (!silent) {
        this.isRefreshing = true;
      }
      this.pageNum = 1;
    }
    try {
      // ⭐ 索引面板展开时带筛选参数，否则用默认综合列表
      const list = await fetchPgcSeasonsByParams(this.seasonType, this.pageNum, this.PAGE_SIZE, this.indexParams);
      this.isLoading = false;
      this.isRefreshing = false;
      if (list.length === 0) {
        this.hasMore = false;
        return;
      }
      if (isRefresh) {
        this.dataSource.reloadItems(list);
        if (skipEntryAnim) {
          // ⭐ 面板展开/筛选驱动：直接呈现新列表，不重放入场动画（避免信息流闪重置）
          this.cardsVisible = new Array<boolean>(list.length).fill(true);
          this.isBulkLoading = false;
        } else {
          this.prepareCardAnimation(list.length);
        }
      } else {
        const beforeCount = this.dataSource.totalCount();
        this.dataSource.addItems(list);
        this.prepareMoreAnimation(beforeCount, list.length);
      }
      this.hasMore = list.length >= this.PAGE_SIZE;
      this.pageNum++;
    } finally {
      this.isLoadingData = false;
    }
  }

  private loadMore(): void {
    if (this.isLoadingMore || !this.hasMore || this.isRefreshing) return;
    this.isLoadingMore = true;
    this.loadData(false).then(() => {
      this.isLoadingMore = false;
    }).catch((err: Error) => {
      logError(`[PgcChannelPage] 加载更多失败: ${err.message}`);
      this.isLoadingMore = false;
    });
  }

  private onRefresh(): void {
    this.loadData(true);
  }

  // ==================== 番剧/影视索引面板 ====================

  /** ⭐ 收到 Index 索引按钮信号：仅当前活跃频道（番剧=4/影视=5）响应展开/收起面板，另一实例忽略（信号隔离） */
  private onIndexPanelSignal(): void {
    // ⭐ 信号隔离：homeChannelIndex 表示当前活跃 Tab（0-5），仅当等于本实例 channelIndex 时才响应
    const active: number = AppStorage.get<number>('homeChannelIndex') ?? -1;
    if (active !== this.channelIndex) {
      return;
    }
    if (this.panelBusy) {
      // ⭐ 动画/加载进行中点击：不吞掉，先强制收尾当前动画到最终态，再立即切换方向
      this.forceFinishPanelAnimation();
    }
    if (this.isIndexPanelExpanded && !this.panelCollapsed) {
      this.collapseIndexPanel();
    } else {
      this.expandIndexPanel();
    }
  }

  /** ⭐ 强制收尾当前面板动画（行高/padding/淡出态直接置为最终态，作废旧动画回调） */
  private forceFinishPanelAnimation(): void {
    ++this.rowAnimToken;      // 作废逐行展开动画回调
    ++this.filterAnimToken;   // 作废展开更多/收起动画回调
    ++this.collapseToken;     // ⭐ 作废收起动画的 setTimeout 收尾回调（漏掉会导致快速再次展开后被强制收起 → 反复动画）
    const count: number = this.getVisibleRowCount();
    if (this.panelExpanding) {
      // 当前展开方向：直接置为完整展开态（淡出态恢复）
      this.rowHeights = new Array<number>(count).fill(this.PANEL_ROW_HEIGHT);
      this.panelPaddingV = 8;
      this.panelMarginV = this.cardListMargin;
      this.panelOpacity = 1;
      this.panelScale = 1;
    } else {
      // 当前收起方向：直接置为完全收起态（淡出到 0），并真正移除渲染（消除材质残留光带）
      this.rowHeights = new Array<number>(count).fill(0);
      this.panelPaddingV = 0;
      this.panelMarginV = 0;
      this.panelCollapsed = true;
      this.panelOpacity = 0;
      this.panelScale = 1;
      this.isIndexPanelExpanded = false;
    }
    this.panelBusy = false; // 解除忙碌，允许后续切换
  }

  /** 展开索引面板：首次展开拉条件并逐行展开；再次展开（数据保留）直接恢复行高；横屏时完全展开全部维度 */
  private expandIndexPanel(): void {
    this.panelBusy = true; // ⭐ 标记忙碌：加载/展开动画期间忽略新信号
    this.panelExpanding = true; // ⭐ 记录动画方向：展开
    // ⭐ 完全展开所有维度：横屏分栏总是展开；影视页（seasonType=2）默认全部展开（无折叠）；
    //    番剧页锁定后（panelLocked）展开默认全部展开；否则竖屏番剧页保持折叠态（默认排序/地区/风格 + 展开更多按钮）
    this.isFilterExpanded = this.isLandscape || this.seasonType === 2 || this.panelLocked;
    if (!this.isIndexPanelExpanded) {
      // ⭐ 面板当前未渲染（首次展开或已收起）：有数据则直接恢复行高，无数据才拉条件
      this.isIndexPanelExpanded = true;
      this.panelMarginV = this.cardListMargin; // 展开时包裹边距恢复（与面板一起出现）
      // ⭐ 横屏展开：面板淡入（透明+缩小 → 正常）+ 宽度 0→屏宽*0.33，与收起对称；竖屏由行高动画推动信息流，无需淡入
      if (this.isLandscape) {
        this.panelOpacity = 0;
        this.panelScale = 0.92;
        // ⭐ 左侧面板宽度动画：0 → 屏宽*0.33，信息流 layoutWeight 自动跟随平滑伸缩
        const screenW: number = display.getDefaultDisplaySync().width / display.getDefaultDisplaySync().densityPixels;
        this.getUIContext().animateTo({
          duration: 500,
          curve: Curve.EaseInOut
        }, () => {
          this.panelOpacity = 1;
          this.panelScale = 1;
          this.panelWidth = screenW * 0.33;
        });
      }
      if (this.orderList.length === 0) {
        this.loadIndexConditions();
      } else {
        // ⭐ 数据保留（收起时未清空）：直接恢复行高，无需重新拉条件
        this.panelCollapsed = false;
        this.expandRowHeights();
      }
    } else {
      // ⭐ 面板仍在渲染中（快速连点展开）：直接恢复行高
      this.panelCollapsed = false;
      this.expandRowHeights();
    }
  }

  /** 收起索引面板：单一 animateTo（行高/opacity/scale 同步同终，EaseInOut 对称曲线丝滑到底），动画结束后移除渲染 */
  private collapseIndexPanel(): void {
    this.panelBusy = true; // ⭐ 标记忙碌：动画期间忽略新信号
    this.panelExpanding = false; // ⭐ 记录动画方向：收起
    const token: number = ++this.collapseToken;
    // ⭐ 作废进行中的逐行展开(expandRowHeights)与"展开更多/收起"动画回调，
    //    避免收起动画把行高归零后仍有延时回调把某行重新拉高，导致面板移除瞬间留有余高 → 末尾顿一下
    ++this.rowAnimToken;
    ++this.filterAnimToken;
    const count: number = this.getVisibleRowCount();
    // ⭐ 单一 animateTo + EaseInOut：所有属性同步开始/同步结束，
    //    避免此前双动画时长差（350/420ms）尾段卡片已停、面板还在 scale/opacity 动的"最后一段位移"
    this.getUIContext().animateTo({
      duration: 500,
      curve: Curve.EaseInOut
    }, () => {
      this.rowHeights = new Array<number>(count).fill(0);
      this.panelPaddingV = 0;
      this.panelOpacity = 0;
      // ⭐ 收起不缩放：中心缩放会在高度收缩尾段产生上下位移 → "最后一下跳"；仅淡出+高度收缩
      this.panelScale = 1;
      // ⭐ 包裹边距随收起一并归零，消除动画结束移除时的末尾跳变
      this.panelMarginV = 0;
      // ⭐ 左侧面板宽度动画：屏宽*0.33 → 0，信息流 layoutWeight 自动跟随平滑伸缩
      this.panelWidth = 0;
    });
    // ⭐ 动画结束后：移除渲染（消除 ImmersiveLightWrapper 材质残留光带）
    setTimeout(() => {
      if (token !== this.collapseToken) return;
      // ⭐ 保险：同帧强制行高/边距归零，避免任何残留回调把高度留在非 0 值 → 移除瞬间跳变
      const c2: number = this.getVisibleRowCount();
      this.rowHeights = new Array<number>(c2).fill(0);
      this.panelPaddingV = 0;
      this.panelMarginV = 0;
      this.isFilterExpanded = false; // ⭐ 收起时重置折叠状态，下次展开回到默认（排序/地区/风格 + 展开更多按钮）
      this.panelCollapsed = true; // ⭐ 标记收起
      this.isIndexPanelExpanded = false; // ⭐ 真正移除渲染，无残留光带
      this.panelOpacity = 1; // ⭐ 重置动画状态，下次展开恢复
      this.panelScale = 1;
      this.panelMarginV = this.cardListMargin; // ⭐ 恢复包裹边距，下次展开直接使用
      this.panelBusy = false; // ⭐ 动画结束，解除忙碌
      // ⭐ 数据保留（orderList/filterList 不清空），再次展开直接恢复行高，无需重新拉条件/重载列表
    }, 520);
  }

  /** ⭐ 面板总行数（稳定，不随折叠状态变化）：排序行 + 全部 filter 行 + 展开/收起按钮（若有非主维度；影视页无按钮） */
  private getVisibleRowCount(): number {
    let count: number = 1; // 排序行
    count += this.filterList.length; // 所有 filter 行（含折叠时隐藏的非主维度槽位）
    // ⭐ 影视页(seasonType=2)默认全部展开、无折叠按钮，不计按钮行
    if (this.seasonType !== 2 && this.filterList.some((f: PgcIndexFilter) => !this.isPrimaryFilter(f))) count++; // 展开/收起按钮
    return count;
  }

  /** ⭐ filter 在行序列中的固定行号（排序行占 0，filter 行按全量索引从 1 开始，不随折叠状态变化） */
  private getFilterRowIndex(filterIndex: number): number {
    return filterIndex + 1;
  }

  /** ⭐ 当前可见行号列表（行号稳定）：排序行 0 + 非隐藏 filter 行 + 展开/收起按钮（最后一行） */
  private getVisibleRowIndexes(): number[] {
    const rows: number[] = [0]; // 排序行
    for (let i = 0; i < this.filterList.length; i++) {
      if (!this.isFilterHidden(this.filterList[i])) {
        rows.push(this.getFilterRowIndex(i));
      }
    }
    // ⭐ 影视页(seasonType=2)默认全部展开、无折叠按钮，不加入按钮行
    if (this.seasonType !== 2 && this.filterList.some((f: PgcIndexFilter) => !this.isPrimaryFilter(f))) {
      rows.push(this.getVisibleRowCount() - 1); // 展开/收起按钮（最后一行）
    }
    return rows;
  }

  /** ⭐ 展开更多/收起：收起方向先渐隐非主维度行（保持展开态）动画完成后切折叠；展开方向新行逐行渐显 */
  private toggleFilterExpanded(): void {
    const token: number = ++this.filterAnimToken; // ⭐ 独立 token，不影响 rowAnimToken/panelBusy
    if (this.isFilterExpanded) {
      // ── 收起方向：先渐隐非主维度行（此时 isFilterExpanded 仍为 true，行号基于展开态）──
      const hideRows: number[] = [];
      for (let i = 0; i < this.filterList.length; i++) {
        if (!this.isPrimaryFilter(this.filterList[i])) {
          hideRows.push(this.getFilterRowIndex(i));
        }
      }
      // 反向交错收缩这些行（height 参与布局，推动信息流上移）
      for (let k = hideRows.length - 1; k >= 0; k--) {
        const row: number = hideRows[k];
        setTimeout(() => {
          if (token !== this.filterAnimToken) return;
          this.getUIContext().animateTo({
            duration: 300,
            // ⚠️ 收起方向用临界阻尼（同 collapseRowHeights）：44→0 欠阻尼会在 0 处回弹→顿；1.0 无回弹平滑收敛
            curve: curves.springMotion(0.4, 1.0)
          }, () => {
            const cur: number[] = [...this.rowHeights];
            cur[row] = 0;
            this.rowHeights = cur;
          });
        }, (hideRows.length - 1 - k) * 70);
      }
      // ⭐ 收缩动画完成后才切折叠；springMotion 忽略 duration 实际收敛需 1s+，等待用 hideRows.length*70+1000 覆盖，
      //    切折叠前同帧强制被隐藏行高=0（非主维度行从 ForEach 移除时无残留高度，无跳变）
      setTimeout(() => {
        if (token !== this.filterAnimToken) return;
        // ⭐ 同帧强制收尾：先把将被隐藏的行高度强制置 0，再切折叠 → 无残留高度跳变
        const force: number[] = [...this.rowHeights];
        for (let k = 0; k < hideRows.length; k++) {
          force[hideRows[k]] = 0;
        }
        this.rowHeights = force;
        this.isFilterExpanded = false;
        // ⭐ 重建行高数组（全量长度）：只把可见行（排序+主维度+展开更多按钮）填满高，
        //    非主维度槽位保持 0，这样下次展开更多时这些行才从 0 动画到 44
        const totalCount: number = this.getVisibleRowCount();
        const rebuilt: number[] = new Array<number>(totalCount).fill(0);
        const visibleIdx: number[] = this.getVisibleRowIndexes();
        for (let k = 0; k < visibleIdx.length; k++) {
          rebuilt[visibleIdx[k]] = this.PANEL_ROW_HEIGHT;
        }
        this.rowHeights = rebuilt;
      }, hideRows.length * 70 + 1000);
    } else {
      // ── 展开方向：新出现的行高度从 0 动画展开 ──
      this.isFilterExpanded = true;
      // 扩展行高度数组：已有行保留，新行初始 0
      const count: number = this.getVisibleRowCount();
      const next: number[] = new Array<number>(count).fill(0);
      for (let i = 0; i < count; i++) {
        next[i] = this.rowHeights[i] ?? 0;
      }
      this.rowHeights = next;
      // 新出现的行逐行动画展开（height 参与布局，推动信息流下移）
      for (let i = 0; i < count; i++) {
        if (next[i] === 0) {
          setTimeout(() => {
            if (token !== this.filterAnimToken) return;
            this.getUIContext().animateTo({
              duration: 300,
              curve: curves.springMotion(0.4, 0.85)
            }, () => {
              const cur: number[] = [...this.rowHeights];
              cur[i] = this.PANEL_ROW_HEIGHT;
              this.rowHeights = cur;
            });
          }, i * 70);
        }
      }
    }
  }

  /** 加载索引筛选条件（动态维度 + 排序），默认各取第一项后刷新列表 */
  private async loadIndexConditions(): Promise<void> {
    const cond = await fetchPgcIndexCondition(this.seasonType);
    // ⭐ fetch 期间用户可能已再次点击收起/展开（panelCollapsed=true 或方向已切为收起），此时丢弃结果，
    //    避免收起后又展开导致反复动画
    if (this.panelCollapsed || !this.isIndexPanelExpanded || !this.panelExpanding) return;
    // ⭐ 条件填充后初始化行高度为 0，再逐行展开到 PANEL_ROW_HEIGHT（推动信息流下移）
    this.orderList = cond.order;
    this.filterList = cond.filter;
    this.selectedOrder = 0;
    this.selectedFilterIdx = this.filterList.map(() => 0);
    this.buildIndexParams();
    this.expandRowHeights();
    // ⭐ 错峰：等行展开动画完全结束（count*70+1000 覆盖 spring 收敛）后再加载列表，
    //    避免动画期间 WaterFlow 重排并发导致卡顿或动画被干扰
    // ⚠️ animToken 必须在 expandRowHeights 之后取值（其内部 ++rowAnimToken），
    //    否则与 rowAnimToken 恒不相等，错峰加载永远不会执行
    const animToken: number = this.rowAnimToken;
    setTimeout(() => {
      if (animToken !== this.rowAnimToken) return; // 新动画已开始，由新流程加载
      if (this.panelCollapsed) return;             // ⭐ 已收起（动画期间被再次收起），无需加载
      if (!this.isIndexPanelExpanded) return;       // 面板未展开，收起流程会自己加载
      this.loadData(true, true, true);
    }, this.getVisibleRowCount() * 70 + 1000);
  }

  /** ⭐ 面板逐行高度展开到 PANEL_ROW_HEIGHT（正向交错，只展开可见行；非主维度槽位保持 0），height 参与布局实时推动信息流下移 */
  private expandRowHeights(): void {
    const token: number = ++this.rowAnimToken;
    // ⭐ 确保外壳上下边距恢复（覆盖收起动画被作废/强制收尾残留 0 的路径，避免收起后再展开无间距）
    this.panelMarginV = this.cardListMargin;
    const count: number = this.getVisibleRowCount(); // 全量稳定行数
    this.rowHeights = new Array<number>(count).fill(0);
    // ⭐ Column 垂直 padding 恢复为 8（与行展开同步动画）
    this.getUIContext().animateTo({
      duration: 240,
      curve: curves.springMotion(0.4, 0.85)
    }, () => {
      this.panelPaddingV = 8;
    });
    // ⭐ 只展开可见行（排序 0 + 非隐藏 filter 行 + 按钮最后一行），非主维度槽位保持 0，
    //    这样展开更多时这些行才从 0 动画到 44
    const visibleRows: number[] = [0]; // 排序行
    for (let i = 0; i < this.filterList.length; i++) {
      if (!this.isFilterHidden(this.filterList[i])) {
        visibleRows.push(this.getFilterRowIndex(i));
      }
    }
    if (this.filterList.some((f: PgcIndexFilter) => !this.isPrimaryFilter(f))) {
      visibleRows.push(count - 1); // 展开/收起按钮（最后一行，行号稳定）
    }
    for (let k = 0; k < visibleRows.length; k++) {
      const row: number = visibleRows[k];
      setTimeout(() => {
        if (token !== this.rowAnimToken) return;
        this.getUIContext().animateTo({
          duration: 300,
          curve: curves.springMotion(0.4, 0.85)
        }, () => {
          const next: number[] = [...this.rowHeights];
          next[row] = this.PANEL_ROW_HEIGHT;
          this.rowHeights = next;
        });
      }, k * 70);
    }
    // ⭐ 最后一行动画结束后解除忙碌（springMotion 实际收敛需 1s+，等待覆盖 + 缓冲）；
    //    动画期间点击索引按钮会走 forceFinishPanelAnimation 强制收尾，不依赖此窗口吞点击
    setTimeout(() => {
      if (token !== this.rowAnimToken) return;
      this.panelBusy = false;
    }, count * 70 + 1000);
  }

  /** 根据当前选中项构建请求参数（order + 各维度 keyword） */
  private buildIndexParams(): void {
    const next: Record<string, string> = {};
    if (this.orderList.length > 0) {
      const o = this.orderList[this.selectedOrder];
      // ⭐ 排序参数：参数名固定为 order，值为所选排序项的 field（如 8=综合/3=追番/2=播放/0=更新/4=评分）
      //   ⚠️ 不能写成 next[o.field]=o.sort：condition 接口里 field 才是排序值，sort 恒为 "0"，
      //      那样会拼出 &8=0 之类的无效参数，服务器忽略 → 排序切换无效
      next['order'] = o.field;
    }
    for (let i = 0; i < this.filterList.length; i++) {
      const f = this.filterList[i];
      const idx = this.selectedFilterIdx[i] ?? 0;
      if (f.values.length > 0 && idx < f.values.length) {
        next[f.field] = f.values[idx].keyword;
      }
    }
    this.indexParams = next;
  }

  /** 切换排序后刷新 */
  private onOrderSelect(index: number): void {
    if (index === this.selectedOrder) return;
    this.selectedOrder = index;
    this.buildIndexParams();
    this.loadData(true, true, true);
  }

  /** 切换某维度选项后刷新 */
  private onFilterSelect(filterIndex: number, valueIndex: number): void {
    const next: number[] = [...this.selectedFilterIdx];
    next[filterIndex] = valueIndex;
    this.selectedFilterIdx = next;
    this.buildIndexParams();
    this.loadData(true, true, true);
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

  private enterSeason(item: PgcSeason): void {
    if (item.seasonId <= 0 && item.mediaId <= 0) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '番剧ID无效' });
      } catch (_) { }
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/VideoPlayerPage',
      params: {
        // ⭐ 优先传 seasonId：/pgc/view/web/season 才能返回完整分集（episodes）；
        // 若传 media_id，season 接口 -404、media 接口 result 无顶层 episodes → 播放页取不到 cid
        mediaId: item.seasonId > 0 ? item.seasonId : item.mediaId,
        title: item.title,
        coverUrl: item.cover,
        subTitle: item.subTitle,
        score: item.score,
        indexShow: item.indexShow,
        badge: item.badge
      }
    }).catch((err: Error) => {
      logError(`[PgcChannelPage] 跳转播放页失败: ${err.message}`);
    });
  }

  private formatScore(score: string): string {
    if (!score) return '';
    return score.length > 3 ? score.substring(0, 3) : score;
  }

  /**
   * 番剧/影视卡片背景色（跟随卡片样式选项，与消息页/动态页一致）
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
   * 番剧/影视卡片边框色（与首页 CardStyleSheet.getPreviewBorderColor 一致）
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

  @Builder
  PgcCard(item: PgcSeason) {
    Column() {
      // ---- 封面区 ----
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(item.cover)
          .width('100%')
          // ⭐ 番剧/影视海报为竖版（2:3），避免被横版裁剪
          .aspectRatio(2 / 3)
          .objectFit(ImageFit.Cover)
          .backgroundColor(this.isDarkMode ? '#333333' : '#E8E8E8')
          .draggable(false)
          .borderRadius(this.cardListBorderRadius)

        // 底部渐变遮罩
        Row()
          .width('100%')
          .height(34)
          .position({ bottom: 0 })
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: [['#00000000', 0], ['#66000000', 1]]
          })

        // 左上角角标（独家/大会员）
        if (item.badge) {
          Text(item.badge)
            .fontSize(11)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Bold)
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .backgroundColor('#FB7299')
            .borderRadius(4)
            .position({ top: 6, left: 6 })
        }

        // 右下角集数/上映信息
        if (item.indexShow) {
          Text(item.indexShow)
            .fontSize(11)
            .fontColor(Color.White)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('rgba(0,0,0,0.55)')
            .borderRadius(4)
            .position({ bottom: 6, right: 6 })
        }

        // ⭐ 评分徽章（封面内右上角，与左上角角标对称；文字居中）
        if (item.score) {
          Text(this.formatScore(item.score))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .textAlign(TextAlign.Center)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('rgba(0,0,0,0.55)')
            .borderRadius(4)
            .position({ top: 6, right: 6 })
        }
      }
      .width('100%')
      .borderRadius(this.cardListBorderRadius)
      .clip(true)
      .backgroundColor(this.isDarkMode ? '#333333' : '#F0F0F0')

      // ---- 标题（居中） ----
      Text(item.title)
        .fontSize(14)
        .fontColor(this.isDarkMode ? Color.White : Color.Black)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .margin({ top: 8, left: 2, right: 2 })
        .width('100%')

      // ---- 简介（评分已移入封面内；文字居中） ----
      Text(item.subTitle || item.indexShow)
        .fontSize(12)
        .fontColor(this.isDarkMode ? '#AAAAAA' : '#666666')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .margin({ top: 4, left: 2, right: 2 })
        .width('100%')
    }
    .width('100%')
    .padding(8)
    // ⚠️ 背景跟随卡片样式（透明样式 → 主题色+透明度；实心 → 深/浅灰）
    .backgroundColor(this.getCardItemBg())
    .borderRadius(this.cardListBorderRadius)
    // ⚠️ 边框跟随卡片样式（宽度/透明度/跟随主题色）
    .border({ width: this.cardBorderWidth, color: this.getCardItemBorder() })
    .clip(true)
    .shadow({ radius: 4, color: '#10000000', offsetY: 2 })
    .clickEffect({ level: 0, scale: 0.9 })
    .onClick(() => this.enterSeason(item))
  }

  // ==================== 索引筛选面板 UI ====================

  /** 排序行（横向 chips，分类名跟随滑动） */
  @Builder
  IndexOrderRow() {
    Row() {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.orderList, (order: PgcIndexOrder, index: number) => {
            Text(order.name)
              .fontSize(13)
              .fontColor(this.selectedOrder === index
                ? Color.White
                : (this.isDarkMode ? '#CCCCCC' : '#666666'))
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .backgroundColor(this.selectedOrder === index
                ? this.customThemeColor
                : (this.isDarkMode ? '#333333' : '#F0F0F0'))
              .borderRadius(14)
              .onClick(() => this.onOrderSelect(index))
          }, (order: PgcIndexOrder) => order.field + order.sort)
        }
        .padding({ left: 12, right: 12 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      // ⭐ 左右滑动加回弹效果
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  /** 单个筛选维度行：维度名 + 横向选项 chips（分类名跟随滑动） */
  @Builder
  IndexFilterRow(filter: PgcIndexFilter, filterIndex: number) {
    Row() {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(filter.values, (value: PgcIndexValue, valueIndex: number) => {
            Text(value.name)
              .fontSize(13)
              .fontColor(this.selectedFilterIdx[filterIndex] === valueIndex
                ? Color.White
                : (this.isDarkMode ? '#CCCCCC' : '#666666'))
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .backgroundColor(this.selectedFilterIdx[filterIndex] === valueIndex
                ? this.customThemeColor
                : (this.isDarkMode ? '#333333' : '#F0F0F0'))
              .borderRadius(14)
              .onClick(() => this.onFilterSelect(filterIndex, valueIndex))
          }, (value: PgcIndexValue) => value.keyword)
        }
        .padding({ left: 12, right: 12 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      // ⭐ 左右滑动加回弹效果
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  /** ⭐ 判断维度是否为「地区」或「风格」（折叠时固定显示） */
  private isPrimaryFilter(filter: PgcIndexFilter): boolean {
    const field: string = filter.field.toLowerCase();
    const name: string = filter.name;
    return field.indexOf('area') >= 0 || field.indexOf('style') >= 0
      || name.indexOf('地区') >= 0 || name.indexOf('风格') >= 0;
  }

  /** ⭐ 判断维度是否需要折叠隐藏（展开态 isFilterExpanded 才显示） */
  private isFilterHidden(filter: PgcIndexFilter): boolean {
    if (this.isFilterExpanded) return false;
    return !this.isPrimaryFilter(filter);
  }

  /** ⭐ 面板每行当前高度：行高度动画值（height 参与布局，推动信息流位移） */
  private getRowHeight(rowIndex: number): number {
    if (this.rowHeights.length > rowIndex) {
      return this.rowHeights[rowIndex] ?? 0;
    }
    return 0;
  }

  /** ⭐ 索引筛选面板（放在信息流内顶部，随信息流滚动；默认折叠只显示排序/地区/风格） */
  @Builder
  IndexPanel() {
    Column() {
      // 排序行（始终显示，行高动画展开）
      if (this.orderList.length > 0) {
        Row() {
          this.IndexOrderRow()
        }
        .width('100%')
        .height(this.getRowHeight(0))
        .clip(true)
      }
      // 地区/风格维度（始终显示）+ 其他维度（折叠，展开后显示）
      ForEach(this.filterList, (filter: PgcIndexFilter, index: number) => {
        if (!this.isFilterHidden(filter)) {
          Row() {
            this.IndexFilterRow(filter, index)
          }
          .width('100%')
          .height(this.getRowHeight(this.getFilterRowIndex(index)))
          .clip(true)
        }
      }, (filter: PgcIndexFilter) => filter.field)

      // ⭐ 展开/收起按钮：存在非主维度（可折叠维度）时始终显示；影视页(seasonType=2)默认全部展开、无折叠按钮
      if (this.seasonType !== 2 && this.filterList.some((f: PgcIndexFilter) => !this.isPrimaryFilter(f))) {
        Row({ space: 8 }) {
          // ⭐ 锁定/解锁按钮：横屏隐藏；且仅在面板已展开（isFilterExpanded）后显示，未展开时不显示
          if (!this.isLandscape && this.isFilterExpanded) {
            Image($r('app.media.' + (this.panelLocked ? 'ic_public_unlock' : 'ic_public_lock')))
              .width(20)
              .height(20)
              .fillColor(this.customThemeColor)
              .onClick(() => {
                this.panelLocked = !this.panelLocked;
                this.savePanelLocked();
                // ⭐ 锁定且面板已展开且当前折叠 → 立即展开全部维度
                if (this.panelLocked && this.isIndexPanelExpanded && !this.isFilterExpanded) {
                  this.toggleFilterExpanded();
                }
              })
          }
          Text(this.isFilterExpanded ? '收起' : '展开更多')
            .fontSize(12)
            .fontColor(this.customThemeColor)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            // ⭐ 胶囊样式：与选项 chips 同款圆角背景
            .backgroundColor(this.isDarkMode ? '#333333' : '#F0F0F0')
            .borderRadius(16)
            .onClick(() => {
              this.toggleFilterExpanded();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .height(this.getRowHeight(this.getVisibleRowCount() - 1))
        .clip(true)
      }
    }
    .width('100%')
    // ⭐ 垂直 padding 为动画值：收起时随行收缩同步减到 0，消除收完后 16vp 残留占位的突然上移
    .padding({ top: this.panelPaddingV, bottom: this.panelPaddingV })
  }

  /** ⭐ 信息流主体（loading/空态/WaterFlow 卡片 + 加载更多），横屏分栏与竖屏共用 */
  @Builder
  infoFlowBody() {
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
        LazyForEach(this.dataSource, (item: PgcSeason, index: number) => {
          FlowItem() {
            this.PgcCard(item)
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
        }, (item: PgcSeason, index: number) => `${item.seasonId}_${index}`)
      }
      // ⭐ 竖屏 3 列，横屏 4 列
      .columnsTemplate(this.getColumnTemplate())
      .columnsGap(this.cardListMargin).rowsGap(this.cardListMargin)
      .padding({
        left: this.cardListMargin,
        right: this.cardListMargin,
        bottom: 190 + this.navIndicatorHeight
      })
      .backgroundColor('transparent')
      .cachedCount(12)
      .clip(false)

      if (this.isLoadingMore) {
        Row() {
          LoadingProgress().width(24).height(24).color(this.customThemeColor)
          Text(' 加载更多...').fontSize(12).fontColor('#999999')
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

  /** ⭐ 索引面板主体（卡片样式背景/边框/圆角 + 整体淡出动画）；enableScroll=true 时容器固定高度、内部选项上下滑动（横屏侧栏，Spring 回弹） */
  @Builder
  indexPanelBody(enableScroll: boolean) {
    Column() {
      if (enableScroll) {
        // ⭐ 横屏侧栏：容器固定高度（扣除顶部标题栏与底部 100vp 边距），内部选项上下滚动 + 回弹
        Column() {
          Scroll() {
            this.IndexPanel()
          }
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .height(this.getPanelFixedHeight())
        // ⭐ 系统磨砂毛玻璃：圆角跟随卡片样式，背景改透明 + backgroundBlurStyle COMPONENT_THICK
        .borderRadius(this.cardListBorderRadius)
        .backgroundColor(Color.Transparent)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .clip(true)
      } else {
        Column() {
          this.IndexPanel()
        }
        .width('100%')
        // ⭐ 系统磨砂毛玻璃：圆角跟随卡片样式，背景改透明 + backgroundBlurStyle COMPONENT_THICK
        .borderRadius(this.cardListBorderRadius)
        .backgroundColor(Color.Transparent)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .clip(true)
      }
    }
    .opacity(this.panelOpacity)
    .scale({ x: this.panelScale, y: this.panelScale })
  }

  /** ⭐ 横屏侧栏面板固定高度：屏高 − 顶部标题栏区 − 底部 100vp 边距 */
  private getPanelFixedHeight(): number {
    const screenH: number = display.getDefaultDisplaySync().height / display.getDefaultDisplaySync().densityPixels;
    const topPad: number = (this.hideStatusBar ? 0 : this.statusBarHeight) + this.TITLE_BAR_HEIGHT + 8;
    return Math.max(100, screenH - topPad - 100);
  }

  /** ⭐ 信息流滚动主体（Refresh + Scroll + infoFlowBody），showPanel=true 时顶部内嵌索引面板（竖屏）；false 时不内嵌（横屏分栏左侧） */
  @Builder
  mainScrollBody(showPanel: boolean) {
    Refresh({ refreshing: $$this.isRefreshing, builder: this.customRefreshComponent() }) {
      Scroll(this.scroller) {
        Column() {
          if (showPanel && this.isIndexPanelExpanded) {
            // ⭐ 竖屏顶部内嵌面板：四周各 cardListMargin 边距，与信息流卡片对齐
            //    ⚠️ 用 padding（组件内收缩）而非 calc+margin（百分比基准易致左右不对称）
            Column() {
              this.indexPanelBody(false)
            }
            .width('100%')
            // ⭐ 间距跟随卡片样式设置（上下 + 左右）
            .padding({
              left: this.cardListMargin,
              right: this.cardListMargin,
              top: this.panelMarginV,
              bottom: this.panelMarginV
            })
          }
          this.infoFlowBody()
        }
        .width('100%')
        // ⭐ 顶部统一让位标题栏：面板与信息流都从标题栏（索引按钮）下方开始，两者紧贴
        .padding({ top: (this.hideStatusBar ? 0 : this.statusBarHeight) + this.TITLE_BAR_HEIGHT + 8 })
      }
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).backgroundColor('transparent')
      .onWillScroll((_, yOffset: number) => {
        const absoluteOffset = this.scroller.currentOffset().yOffset;
        const delta = absoluteOffset - this.lastScrollY;
        if (absoluteOffset < 5) {
          this.lastScrollY = 0;
          AppStorage.set('homeScrollOffset', 0);
          AppStorage.set('bottomBarHidden', false);
        } else if (delta > this.SCROLL_THRESHOLD) {
          this.lastScrollY = absoluteOffset;
          AppStorage.set('homeScrollOffset', absoluteOffset);
          AppStorage.set('bottomBarHidden', true);
        } else if (delta < -this.SCROLL_THRESHOLD) {
          this.lastScrollY = absoluteOffset;
          AppStorage.set('homeScrollOffset', absoluteOffset);
          AppStorage.set('bottomBarHidden', false);
        }
      })
      .onReachEnd(() => {
        this.loadMore();
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
  }

  build() {
    Stack() {
      if (this.isLandscape) {
        // ⭐ 横屏分栏常驻：左面板宽度动画（0↔屏宽*0.33），右信息流 layoutWeight 自动跟随，宽度平滑过渡（不再瞬间跳变）
        Row() {
          // 左：索引面板（宽度动画驱动 0↔屏宽*0.33，内容可上下滚动）
          Column() {
            this.indexPanelBody(true)
          }
          .width(this.panelWidth)
          .height('100%')
          .clip(true)
          // ⭐ 面板左侧间距跟随卡片样式设置，不贴屏幕边缘
          .margin({ left: this.cardListMargin })
          // ⭐ 顶部让位标题栏；底部与屏幕下边框保持至少 100vp 边距
          .padding({
            top: (this.hideStatusBar ? 0 : this.statusBarHeight) + this.TITLE_BAR_HEIGHT + 8,
            bottom: 100
          })

          // 右：信息流（不含内嵌面板，宽度随左面板动画自动伸缩）
          Column() {
            this.mainScrollBody(false)
          }
          .layoutWeight(1)
          .height('100%')
        }
        .width('100%')
        .height('100%')
      } else {
        // ⭐ 竖屏/横屏未展开：索引面板内嵌信息流顶部，随信息流滚动
        this.mainScrollBody(true)
      }
    }
    .width('100%')
    .height('100%')
  }
}
