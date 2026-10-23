/**
 * HomeChannelContainer.ets — 首页频道容器（挂在首页 Tab 下）
 *
 * 频道体系（对齐官方 B 站首页）：
 *   推荐 | 热门 | 直播 | 番剧 | 影视 | 分类
 *
 * - 内容 Tabs 承载 6 个频道，左右滑动切换（保留原 HdsTabs 滑动切换手感）
 * - 频道切换入口 = 右上角胶囊标题（Index 持有），此处不再渲染频道 Tab 条
 * - 与 Index 胶囊标题双向同步：胶囊选择频道 ↔ 容器滑动切换
 *   通过 AppStorage key `homeChannelIndex`（0-5）联动
 * - 顶部刷新路由：refreshHomeFlag → 转发到当前频道的刷新信号
 */
import { HomePage } from '../pages/HomePage';
import { DiscoverPage } from '../pages/DiscoverPage';
import { LivePage } from '../pages/LivePage';
import { PgcChannelPage } from '../pages/PgcChannelPage';
import { RegionChannelPage } from '../pages/RegionChannelPage';

/** 频道定义（供 Index 胶囊复用） */
export interface ChannelTabDef {
  index: number;
  name: string;
}

/** 首页频道顺序：0=分类 1=直播 2=首页 3=热门 4=番剧 5=影视 */
export const CHANNEL_TABS: ChannelTabDef[] = [
  { index: 0, name: '分类' },
  { index: 1, name: '直播' },
  { index: 2, name: '首页' },
  { index: 3, name: '热门' },
  { index: 4, name: '番剧' },
  { index: 5, name: '影视' }
];

@Component({ freezeWhenInactive: true })
export struct HomeChannelContainer {
  /** 推荐频道 scroller（由 Index 传入，供 HdsNavigation.bindToScrollable） */
  externalScroller?: Scroller = undefined;
  /** 热门频道 scroller */
  discoverScroller?: Scroller = undefined;

  /** 当前频道索引，与 Index 胶囊标题双向同步（默认 2=推荐） */
  @StorageLink('homeChannelIndex') @Watch('onChannelIndexChange') channelIndex: number = 2;
  /** 顶部刷新信号：按当前频道路由 */
  @StorageLink('refreshHomeFlag') @Watch('onRefreshHomeFlag') refreshHomeFlag: number = 0;

  /**
   * ⭐ 「首页点击切换分类」开关（默认关闭）
   * - 关闭（默认）：允许左右横滑切频道（原有手感）
   * - 打开：禁用横滑，只能用顶部胶囊/分类按钮点击切频道
   */
  @StorageLink('homeFilterTapOnly') homeFilterTapOnly: boolean = false;

  private tabController: TabsController = new TabsController();
  @State activeChannel: number = 0;
  private channelInitDone: boolean = false;
  /** ⭐ 滑动动画进行中标志：动画期间 homeChannelIndex 已提前同步（仅标题），禁止 changeIndex 中断动画 */
  private tabAnimating: boolean = false;

  aboutToAppear() {
    // 从 AppStorage 恢复上次频道（胶囊可能已在其它入口设置）；默认 2=推荐
    const saved: number = AppStorage.get<number>('homeChannelIndex') ?? 2;
    this.activeChannel = saved >= 0 && saved < CHANNEL_TABS.length ? saved : 2;
    this.channelInitDone = true;
  }

  /** 胶囊标题切换频道 → 容器 Tabs 跟随 */
  private onChannelIndexChange(): void {
    if (!this.channelInitDone) return;
    const target: number = this.channelIndex;
    if (target < 0 || target >= CHANNEL_TABS.length) return;
    // ⭐ 滑动动画进行中：homeChannelIndex 已由 onTabsAnimationStart 提前同步（仅更新胶囊标题），
    // 此时不能 changeIndex 强制跳页（会中断 Swiper 惯性动画，松手立即切页）；等 onChange 自然落位
    if (this.tabAnimating) return;
    if (target !== this.activeChannel) {
      this.activeChannel = target;
      this.tabController.changeIndex(target);
    }
  }

  /** 顶部刷新：路由到当前频道的刷新信号 */
  private onRefreshHomeFlag(): void {
    // 推荐/番剧/影视/分类都监听 refreshHomeFlag，无需转发；
    // 热门/直播各有独立信号，需转发
    if (this.activeChannel === 3) {
      const flag = AppStorage.get<number>('refreshDiscoverFlag') ?? 0;
      AppStorage.set('refreshDiscoverFlag', flag + 1);
    } else if (this.activeChannel === 1) {
      const flag = AppStorage.get<number>('refreshLiveFlag') ?? 0;
      AppStorage.set('refreshLiveFlag', flag + 1);
    }
  }

  /** 滑动切换频道 → 通知胶囊更新标题 */
  private onTabsChange(index: number): void {
    // ⭐ 动画结束：解除动画中保护，恢复胶囊点击等 changeIndex 路径
    this.tabAnimating = false;
    this.activeChannel = index;
    if (AppStorage.get<number>('homeChannelIndex') !== index) {
      AppStorage.set('homeChannelIndex', index);
    }
    // 离开直播频道时收起直播展开面板（直播为索引 1）
    if (index !== 1) {
      const signal: number = (AppStorage.get('livePanelCollapseSignal') as number) || 0;
      AppStorage.set('livePanelCollapseSignal', signal + 1);
    }
  }

  /** ⭐ 动画开始即同步频道索引：Swiper 惯性动画约 530ms，onChange 要等动画结束才触发，
   *  导致胶囊标题延迟；在动画开始时就更新 homeChannelIndex，标题立即跟随 */
  private onTabsAnimationStart(fromIndex: number, toIndex: number): void {
    if (fromIndex === toIndex) return;
    // ⭐ 标记动画进行中：onChannelIndexChange 会跳过 changeIndex，避免中断 Swiper 惯性动画
    this.tabAnimating = true;
    if (AppStorage.get<number>('homeChannelIndex') !== toIndex) {
      AppStorage.set('homeChannelIndex', toIndex);
    }
  }

  build() {
    // 内容层：Tabs 6 频道（左右滑动切换）
    // ⭐ 顺序：0=分类 1=直播 2=推荐 3=热门 4=番剧 5=影视（与 CHANNEL_TABS 一致）
    // ⭐ 统一 30vp 圆角：外层 Stack 裁剪，使所有频道页（含推荐页轮播背景）滑动切换时呈圆角卡片
    Stack() {
      Tabs({ controller: this.tabController, index: this.activeChannel }) {
        TabContent() {
          RegionChannelPage()
        }
        TabContent() {
          LivePage()
        }
        TabContent() {
          HomePage({ externalScroller: this.externalScroller })
        }
        TabContent() {
          DiscoverPage({ externalScroller: this.discoverScroller })
        }
        TabContent() {
          PgcChannelPage({ seasonType: 1, channelIndex: 4 })
        }
        TabContent() {
          PgcChannelPage({ seasonType: 2, channelIndex: 5 })
        }
      }
      .barHeight(0)
      .barPosition(BarPosition.End)
      .vertical(false)
      // ⚠️ 「首页点击切换分类」开关（默认关闭）：
      //    关闭（默认）= 允许左右横滑切频道（原手感）；
      //    打开 = 禁用横滑，只能点顶部胶囊/分类按钮切频道
      .scrollable(!this.homeFilterTapOnly)
      .animationDuration(200)
      // ⭐ 关键：内层 Tabs 默认避让系统安全区（顶部状态栏），会把 TabContent 整体下推；
      // 各频道页（HomePage/DiscoverPage/LivePage/Pgc/Region）内部已自行预留 statusBarHeight，
      // 这里必须扩展到安全区，否则顶部会形成「状态栏 + 页面自带偏移」双重间距
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      // ⭐ 动画开始即更新胶囊标题（不等惯性动画结束，消除标题切换延迟）
      .onAnimationStart((fromIndex: number, toIndex: number) => this.onTabsAnimationStart(fromIndex, toIndex))
      .onChange((index: number) => this.onTabsChange(index))
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
