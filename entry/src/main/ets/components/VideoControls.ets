// VideoControls.ets - 视频/直播播放控制组件
// materialStyle: 0~4 对应 ImmersiveStyle (ULTRA_THIN=0, THIN=1, REGULAR=2, THICK=3, ULTRA_THICK=4)
import { statistics } from '@kit.NetworkKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import { display, curves, uiMaterial } from '@kit.ArkUI';
import { SeekThumb } from '../model/SeekThumb';
import { MaterialUtil } from '../utils/MaterialUtil';
import { ImmersiveLightWrapper } from './ImmersiveLightWrapper';


@Component
export struct VideoControls {
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  // 播放状态
  @Link isPlaying: boolean;
  @Link currentTime: number;
  @Link duration: number;
  @Link isControlsVisible: boolean;
  @Link isLocked: boolean;
  @Link isFullscreen: boolean;
  @State seekTrackVisible: boolean = false; // 非全屏拖动/点击调节时显示未播放轨道，松手后隐藏
  // ⭐ 全屏控制栏镜像：按钮组左右整体对调（标准↔镜像）；与播放页双向绑定，弹窗跟随镜像
  @Link isMirrorControls: boolean;
  @Link isMuted: boolean;
  @Link playbackRate: number;
  @Link @Watch('syncHintPopups') showGestureHint: boolean;
  @Link @Watch('syncHintPopups') gestureHintMainText: string;
  // ⭐ 音量/亮度图标的"档位脉冲"（2026-09-24 用户选定）——必须拿到它的**每次变化**：
  //   滑动时每个 move 事件都会更新（跟手），回调用它算百分比档位，见 `onHintProgressTick()`。
  @Link @Watch('onHintProgressTick') gestureHintProgress: number;
  // ⭐ 本次进度调节的**起点秒数**（拖动进度条 = 按下时的位置；视频区手势 = 手指落下的位置）。
  //   提示胶囊右侧据此显示相对位移：+10S（绿）/ -10S（红）/ 0S（弱化白）；-1 = 无效不显示
  @Link gestureHintBase: number;
  @Link @Watch('syncHintPopups') gestureHintType: string;
  // ⭐ 沉浸光感胶囊走 bindPopup 通道（CustomPopupOptions.systemMaterial，API 26.0.0 起）。
  //   popup 是"状态驱动显隐"，锚点组件必须常驻（不能 if 挂载），所以把
  //   showGestureHint + gestureHintType 拆成派生 @State（@Watch 同步，见 syncHintPopups）
  //   ⭐ 2026-09-24（方案 C）：seek 胶囊与音量/亮度**竖条**拆成独立锚点——竖条要贴边，
  //   位置写死在各自锚点上，不依赖 bindPopup options 重建。若共用一个状态，
  //   连续手势（音量→亮度，间隔 < 800ms、gh 一直为 true）时 @State 赋值不变 ⇒ build 不重跑
  //   ⇒ 位置会留在旧的一侧，竖条就跑到手指底下去了。
  @State pillPopupVisible: boolean = false;   // seek 胶囊（锚点居中 x 50% / y 30%）
  @State volPopupVisible: boolean = false;    // 音量竖条（恒贴播放器左侧）
  @State brightPopupVisible: boolean = false; // 亮度竖条（恒贴播放器右侧）
  @State holdPopupVisible: boolean = false;   // 长按加速胶囊（锚点 y 10%）
  // ⭐ 播放器区域实测宽度（vp）——音量/亮度竖条的**右侧**锚点必须用数值 x 才精确（见 edgeAnchorX）。
  //   由根 Stack 的 onAreaChange 实测（首次布局后即有值），旋转/尺寸变化会自动跟随重估。
  @State vcW: number = 0;
  /** 播放器区域实测高度（vp）—— seek 锚点要用数值 y（30% 处再按生长量上移），见 seekAnchorY() */
  @State vcH: number = 0;
  // ⭐ 提示胶囊渲染通道开关（一次性能力探测，无副作用）：
  //   true  = 沉浸光感 bindPopup 通道（CustomPopupOptions.systemMaterial，API 26.0.0 弹层作用域）；
  //   false = 老设备走原来的内联条件渲染（ImmersiveLightWrapper 降级）。
  //   ⚠️ 2026-09-23 真机实证：HarmonyOS 6.1 老系统上 bindPopup 挂 26.0.0 新增字段
  //   （systemMaterial/colorMode）会导致 VideoControls 整棵子树渲染失败（控制栏+提示全消失），
  //   老设备绝不能走弹层通道。
  private hintUsePopup: boolean = MaterialUtil.available();
  /** 提示上一次的显示状态：`syncHintPopups` 用它识别"隐藏 → 显示"这一刻（缩略图生长系数的初值只在那一刻定） */
  private lastHintShown: boolean = false;
  /**
   * ⭐ 提示卡片在"隐藏 → 显示"那一刻**冻结**的两个量（2026-09-24 二次修正）：
   *   · `hintShownH`：显示瞬间的**结构高度**（只看结构 = 缩略图槽? + 条 + 内边距，**不含卷帘系数**）；
   *   · `hintOffsetY`：本次显示的 popup 垂直偏移 = **−hintShownH / 2**。
   *
   * 为什么要冻结：popup 顶边在显示瞬间锁定（= 锚点底边 + offset.y），offset 若随高度重算，
   * 面板会在生长动画中途整体跳一下。
   *
   * ★★ 更要紧的是**不能把 hintGrow 算进去**（这是"卷帘方向时对时错"的根因）：
   *   早先锚点补偿用的是**含卷帘系数的当前高度**（`edgePillCurH()` 等），于是 220ms 里锚点
   *   一路往上顶（竖条 0 → 61.6vp），面板被迫"上下同时展开"；而 popup 是否**逐帧跟随**
   *   移动中的锚点并不可靠（系统在显示瞬间锁位，之后跟随与否取决于实现/时序）⇒ 同一个手势
   *   时而是"自上而下"，时而是"上下对开"甚至像"从下往上"，非全屏时播放区小、位移占比大，更明显。
   *   ⇒ 现在把两件事彻底分开：
   *     · **卷帘（hintGrow）**：锚点与 offset 全程恒定 ⇒ 面板顶边不动 ⇒ **永远自上而下**；
   *     · **缩略图异步到达（结构变化）**：才允许用 `hintRise()` 把锚点上顶半个增量（保持中心不动）。
   */
  @State hintOffsetY: number = -28;
  @State hintShownH: number = 0;
  /** 本次显示是否已启动卷帘（onAppear 与兜底定时器都可能触发 ⇒ 幂等去重） */
  private hintGrowStarted: boolean = false;
  /** 卷帘兜底启动定时器（popup 内容挂载比预期晚时用；-1 = 无） */
  private hintGrowTimer: number = -1;
  /** 上一次的提示类型：类型中途切换（音量↔seek）时要重冻结几何并重放卷帘 */
  private lastHintType: string = '';
  /** 卷帘"世代"：每显示一次 +1 —— 上一轮动画迟到的 onFinish 直接丢弃，别影响这一轮 */
  private hintCurtainGen: number = 0;
  /** 填充条卷帘是否已播完（缩略图必须等它 ⇒ 用户要求"填充先完成动画、缩略图再弹簧卷帘"） */
  private hintCurtainDone: boolean = false;
  /** 卷帘结束的兜底定时器：万一段动画的 onFinish 没回调，也要把缩略图放出来（-1 = 无） */
  private hintRevealTimer: number = -1;

  // ⭐ 长按加速的"涟漪"描边（2026-09-24 用户选定"B 弹入 + E 涟漪"）：
  //   画在**弹层之外**（弹层会把超出内容框的部分裁掉，描边必须能扩散到胶囊之外），
  //   位置与胶囊中心重合，每次长按只播一次。
  @State rippleS: number = 0.9;   // 描边缩放
  @State rippleO: number = 0;     // 描边不透明度
  private rippleTimer: number = -1;
  /** 上一次长按胶囊是否显示：用来识别"隐藏 → 显示"，触发一次涟漪 */
  private lastHoldShown: boolean = false;
  /**
   * ⭐ 长按胶囊的"原地弹入"系数（0.62 → 1）：同时驱动**外壳布局尺寸**（玻璃跟着弹）
   * 与**内容 `scale` 属性**（图标跟着弹），并由 `holdAnchorY()` 做垂直补偿。
   * ⛔ 不要退回 `TransitionEffect.scale`：它的缩放参照系不是胶囊自己（方向会随布局变，见 startHoldPop 注释）。
   */
  @State holdPop: number = 0.62;
  private holdPopStarted: boolean = false;
  private holdPopTimer: number = -1;

  // ⭐ 音量/亮度竖条的"边缘滑入 + 回弹"（2026-09-24 用户选定方案 A）。
  //   ⛔ **必须由弹层 transition 驱动（`edgePillTransition()`），不能用内容层 `.translate()`**：
  //   玻璃是弹层材质、内容是我们自己画的 ⇒ 内容自己滑、玻璃只淡入 = **两条时间轴**
  //   （弹层创建早于内容挂载），用户原话"内外的动画好像不一致…沉浸光感不是滑进来的，是直接出现的"。
  //   transition 作用于整个弹层节点 ⇒ 材质与内容严格同步。起点/方向见 `edgeSlideDist()` / `edgeSlideDir()`。

  // ⭐ 音量/亮度图标的**档位脉冲**（2026-09-24 用户选定"方案 1"）：
  //   值每跨越一个 10% 档位，图标弹一下（1 → 峰值 → 1，带阻尼回落）。
  //   ★ 为什么是 10%：播放页**每跨 10% 就震一次**（`fireHaptic(12)` + `lastHapticPct_`），
  //     挂在同一个节拍上 ⇒ 视觉与触觉同时"响一下"，手感最实。
  //   ⚠️ 判定用的是"档位边界变化"（`Math.floor(pct/10)`），与播放页的"滑动累计 10%"**不完全等同**
  //     （如 19%→21%：播放页不震、这里会弹）。选边界是因为视觉上更规律（每次跨 10/20/30… 都弹）。
  //   ⭐ 2026-09-24 追加"描边脉冲" → **真机后改成涟漪**（用户："描边脉冲为什么和长按涟漪
  //     不一样？我想要长按涟漪那样的"）。第一版把描边贴在竖条**外缘内侧**闪一下（玻璃弹层会
  //     裁掉越界内容，图省事没往外做），观感是"边缘亮一下"，而不是"一圈光漾开"。
  //     现在与长按涟漪同款：**画在弹层之外**、从竖条轮廓向外扩散并淡出（见 edgePillRippleRing）。
  @State iconPulse: number = 1;
  /** 涟漪环缩放：1 → `rippleEdgeUp()`（从竖条轮廓向外扩） */
  @State rippleEdgeS: number = 1;
  /** 涟漪环不透明度：起点 → 0（扩散的同时淡出） */
  @State rippleEdgeO: number = 0;
  /** 涟漪环的起跑定时器（-1 = 无）—— 沿用 playHoldRipple 的"同帧写起点 + 次帧推进"套路 */
  private rippleEdgeTimer: number = -1;
  /** 上一次的百分比档位号（-1 = 本次提示还没建立基线，第一次只记不弹） */
  private lastIconTick: number = -1;
  /** 本拍脉冲的结束时刻（ms）：下一拍要排在这之后（快速滑动时防"连发抽搐"，见 playTickPulse） */
  private pulseUntil: number = 0;
  /** 脉冲内部两段延时用的定时器（-1 = 无） */
  private pulseTimer: number = -1;
  // ⭐ 进度调节缩略图（拖动/滑动目标位置的画面）。
  //   与上面那组提示同源：由播放页在 sGH() 时同步更新，并在提示 800ms 超时隐藏时一并隐藏。
  //   ⚠️ 播放页每次变化都整体替换 SeekThumb 实例（@Link 对类对象改字段不触发刷新）
  @Link @Watch('onThumbChange') thumb: SeekThumb;
  // ⭐ 缩略图"长出来"的生长系数（0 → 1，2026-09-24）：
  //   缩略图是**异步到达**的（手势开始时还没解码完 ⇒ 先显示无缩略图版），之前直接从
  //   56vp 的小卡切成 172vp 的大卡 = 硬跳。现在图片高度/透明度/上间距都由它驱动，
  //   pm 到达时用 animateTo 把它从 0 推到 1 ⇒ 画面"卷帘式"展开。
  //   · 拖动开始前就已有图（缓存命中）⇒ `syncHintPopups` 直接置 1，不播动画；
  //   · 拖动过程中到达 ⇒ `onThumbChange()` 里 animateTo 0→1。
  @State seekThumbGrow: number = 0;
  /**
   * ⭐ 三种提示的**整卡卷帘生长系数**（2026-09-24 用户要求："seek 填充条 / 长按胶囊 / 音量亮度竖条
   * 都要弹簧卷帘"）。
   *
   * 做法 = **内容保持满尺寸、外层容器高度从起点长到目标、`clip(true)` 裁切** ⇒ 内容自上而下露出，
   * 即"卷帘"（不是 scale 缩放：缩放会把图标/文字一起拉伸，用户已识别出差别）。
   * 起点取 `growStart()` 而**不是 0**：高度为 0 的弹层面板可能被系统忽略/塌陷，
   * 留 12% 既保证面板始终有尺寸、观感上仍是"从一条细线拉开"。
   * 曲线与 seek 缩略图同源：220ms `springMotion(0.36, 0.9)`。
   *
   * ⚠️ 面板尺寸随内容生长而变化（popup 会重测）—— 这是"真卷帘"必须付的代价（scale 方案面板不动）。
   * ⚠️ **竖条已不用这个系数**：滑入是**弹层自身的入场过渡**（`edgePillTransition()`），
   *   面板尺寸恒定、内容也不需要位移 ⇒ 连"尺寸变化重排"这类未实证的行为都不用赌。
   *   竖条显示时本系数直接置 1（见 syncHintPopups）。
   * ⚠️ 方向和稳定性靠**锚点/offset 在卷帘期间恒定**保证（见 `hintOffsetY` 的注释）：
   *   面板顶边不动 ⇒ 只会"自上而下"拉开，不会出现时对时错的对开/上翻。
   * ⚠️ 启动时机：卷帘必须在**面板已挂载**之后才开始（否则面板一创建就已经是终态 = 看起来没动画）。
   *   触发走两条路（`startHintGrow()` 幂等）：面板内容的 `onAppear` + 32ms 兜底定时器。
   */
  @State hintGrow: number = 0.12;
  @Link showBottomHint: boolean;
  @Link bottomHintImage: ResourceStr | undefined;
  @Link bottomHintText: string;
  @Link showUnlockButton: boolean;
  
  // ⭐ 弹幕开关状态
  @Link isDanmakuEnabled: boolean;

  // ⭐ 直播模式
  @Prop liveMode: boolean = false;
  @Prop liveTitle: string = '';
  @Prop liveOnline: number = 0;
  @Prop liveUname: string = '';

  // ⭐ 视频名称（点播：显示在进度条上方）
  @Prop @Watch('onVideoTitleChange') videoTitle: string = '';

  // 额外属性
  blurAmount: number = 0; // 拖拽时的模糊量
  onBackPress: () => void = () => {};
  // ⭐ 由**提示弹层**转交过来的返回（2026-09-24 真机实证）：
  //   四个提示（seek / 音量 / 亮度 / 长按加速）走的是 bindPopup 弹层，而弹层默认挂在
  //   **应用窗口根节点层** ⇒ 它属于 OverlayManager 的返回键路由，会把返回键 / 系统侧滑返回
  //   **吃掉**（hilog：`Overlay consumed backpressed event`），页面 `onBackPress()` 根本没跑。
  //   ⇒ 把弹层的 `onWillDismiss` 设成**函数形式**，官方文档保证侧滑/返回键/路由跳转/Esc 都会
  //     以 `reason === DismissReason.PRESS_BACK` 回调进来；我们在这个回调里把返回语义
  //     转交给页面（见四个 bindPopup 的 onWillDismiss）。
  onOverlayBack: () => void = () => {};
  onHomePress: () => void = () => {};
  togglePlayPause: () => void = () => {};
  seekTo: (time: number) => void = (_time: number) => {};
  // ⭐ 进度条交互状态回调（Slider 的 Down / Up / Cancel 触发）：
  //   播放页据此在拖动期间冻结 ct（阻止 timeUpdate 回写）+ 抑制控制栏自动隐藏，并在松手时统一提交一次
  onSeekBarInteract: (active: boolean, time: number) => void = (_active: boolean, _time: number) => {};
  formatTime: (seconds: number) => string = (_s: number) => '00:00';
  setPlaybackRate: (rate: number) => void = (_rate: number) => {};
  toggleLock: () => void = () => {};
  toggleMute: () => void = () => {};
  // ⭐ 镜像切换回调（播放页：取消控制栏延迟隐藏 + 持久化状态）
  onMirrorToggle: () => void = () => {};
  // ⭐ 下一集：是否有下一集（多P/番剧分集）+ 切下一集回调
  //   ⚠️ 必须是 @Prop（普通成员不行）：本组件挂在播放页的"常驻播放器层"
  //   （`buildPlayerOverlay`，跨布局分支常驻、只改几何不改挂载），页面创建时就实例化了，
  //   那一刻 vd 还是 null、currentPageIndex 还是 0；普通成员只在构造时赋值一次、之后**永不更新**，
  //   于是"下一集/上一集"按钮在真机上永远不出现。同文件能正常显示的都是 @Prop/@Link
  //   （videoTitle / videoOwnerName / hasMultipleEpisodes / isFullscreen），可作反例对照。
  @Prop hasNextEpisode: boolean = false;
  toggleNextEpisode: () => void = () => {};
  // ⭐ 上一集：是否有上一集 + 切上一集回调（图标为下一集水平翻转）
  @Prop hasPreviousEpisode: boolean = false;
  togglePreviousEpisode: () => void = () => {};
  toggleFullscreen: () => void = () => {};
  showColorStyleOptions: () => void = () => {};
  showScaleOptions: () => void = () => {};
  showQualityOptions: () => void = () => {};
  // ⭐ 更多菜单回调（缓存等后续功能）
  onMorePress: () => void = () => {};
  // ⭐ 弹幕开关回调
  toggleDanmaku: () => void = () => {};
  // ⭐ 发弹幕输入回调
  onDanmakuPress: () => void = () => {};
  // ⭐ 选集回调
  onEpisodePress: () => void = () => {};
  // ⭐ 全屏评论浮层回调
  onCommentPress: () => void = () => {};
  // ⭐ 是否有多集
  @Prop hasMultipleEpisodes: boolean = false;

  // ⭐ 后台播放
  @Link isBackgroundPlayback: boolean;
  toggleBackgroundPlayback: () => void = () => {};

  // 触控事件转发（让 LivePlayerPage 接收手势）
  onPlayerTouch: (e: TouchEvent) => void = (_e: TouchEvent) => {};

  // ⭐ 当前清晰度文字（画质按钮显示）
  @Prop qualityLabel: string = '';

  // ⭐ 全屏左上角 UP主头像（为空时回退为返回箭头）
  @Prop videoOwnerFace: string = '';
  // ⭐ 全屏左上角 UP主名字（显示在头像右侧）
  @Prop videoOwnerName: string = '';

  // ⭐ 关注按钮（头像名字胶囊外）：已关注显示主题色、未关注白色
  @Prop isFollowed: boolean = false;
  @Prop followColor: string = '#FB7299';
  toggleFollow: () => void = () => {};

  // ⭐ 顶部中间状态（网速·时间·电量，仅点播全屏）
  @State speedText: string = '--';
  @State clockText: string = '';
  @State batteryText: string = '';
  // 顶栏宽度（vp）：过窄（竖屏全屏）时隐藏状态栏，避免把右侧按钮挤出屏幕
  @State topBarWidth: number = 0;
  // ⭐ 动效状态：低电/充电闪烁、网速脉冲、镜像按钮旋转、锁定脉冲、标题淡换、拖动气泡
  @State blinkPhase: boolean = false;
  @State isLowBattery: boolean = false;
  @State isMediumBattery: boolean = false;
  @State isCharging: boolean = false;
  @State speedPulse: boolean = false;
  @State mirrorIconAngle: number = 0;
  @State lockPulse: number = 1;
  @State titleFade: number = 1;
  // ⭐ 挂载首帧禁用入场 transition：进出全屏时控制栏全新挂载，重放滑入动画会与全屏动画叠加产生闪烁
  @State controlsMounted: boolean = false;
  // onAreaChange 顶栏高度节流：仅变化超过 1vp 才写 AppStorage
  private lastTopBarHeight: number = -1;
  private statusTimerId: number = -1;
  private statusTickCount: number = 0;
  private lastRxBytes: number = -1;
  private lastTxBytes: number = -1;
  private lastSampleTime: number = -1;

  // ═══ ⭐ 镜像布局：顶部/底部控制栏按钮组抽成 Builder，切换时左右整体对调（组内顺序不变，手势分区不受影响）═══

  // ⭐ 顶部状态定时器：每秒刷新时间+网速，每 15 秒刷新电量
  private startStatusTimer() {
    this.updateClock();
    this.updateBattery();
    void this.sampleSpeed(true);
    if (this.statusTimerId !== -1) {
      clearInterval(this.statusTimerId);
    }
    this.statusTimerId = setInterval(() => {
      this.updateClock();
      void this.sampleSpeed(false);
      this.statusTickCount++;
      if (this.statusTickCount % 15 === 0) {
        this.updateBattery();
      }
      if (this.isLowBattery || this.isCharging) {
        this.blinkPhase = !this.blinkPhase;
      }
    }, 1000);
  }

  private stopStatusTimer() {
    if (this.statusTimerId !== -1) {
      clearInterval(this.statusTimerId);
      this.statusTimerId = -1;
    }
  }

  private updateClock() {
    const d = new Date();
    this.clockText = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  }

  private updateBattery() {
    try {
      const soc = batteryInfo.batterySOC;
      this.isCharging = batteryInfo.chargingStatus === batteryInfo.BatteryChargeState.ENABLE;
      this.isLowBattery = soc >= 0 && soc <= 20;
      this.isMediumBattery = soc >= 0 && soc > 20 && soc <= 35;
      this.batteryText = soc >= 0 ? `${soc}%` : '--';
    } catch (_) {
      this.batteryText = '--';
    }
  }

  private formatSpeed(bytesPerSec: number): string {
    if (bytesPerSec < 1024) {
      return `${Math.max(0, Math.round(bytesPerSec))}B/s`;
    }
    if (bytesPerSec < 1024 * 1024) {
      return `${(bytesPerSec / 1024).toFixed(1)}KB/s`;
    }
    return `${(bytesPerSec / (1024 * 1024)).toFixed(1)}MB/s`;
  }

  /** 采样系统上下行总流量差分，计算实时网速；first=true 只建立基线不更新显示 */
  private async sampleSpeed(first: boolean): Promise<void> {
    try {
      const rx = await statistics.getAllRxBytes();
      const tx = await statistics.getAllTxBytes();
      const now = Date.now();
      if (!first && this.lastRxBytes >= 0 && this.lastTxBytes >= 0 && this.lastSampleTime > 0) {
        const dt = (now - this.lastSampleTime) / 1000;
        if (dt > 0) {
          const speed = ((rx - this.lastRxBytes) + (tx - this.lastTxBytes)) / dt;
          this.speedText = this.formatSpeed(speed);
          this.speedPulse = !this.speedPulse;
        }
      }
      this.lastRxBytes = rx;
      this.lastTxBytes = tx;
      this.lastSampleTime = now;
    } catch (_) {
      this.speedText = '--';
    }
  }

  /**
   * 进度调节缩略图的显示高度（vp）。
   * 全屏横屏给大一点、其余给小一点（与参考实现 PiliPlus 的 108 / 81 同一档），
   * 宽度由 thumb.aspect 推算 —— 接口给的是每格像素尺寸（通常 160×90）。
   */
  private seekThumbH(): number {
    return this.isFullscreen ? 108 : 81;
  }

  /**
   * ⭐ 缩略图"卷帘式长出"的驱动（2026-09-24）。
   * · 提示还没显示（拖动开始前预热到位）⇒ 瞬时置 1，避免"一出现就先长一遍"；
   * · 提示显示期间到达 ⇒ animateTo 从 0 推到 1（220ms 弹性），画面自上而下展开；
   * · ⭐ 但**要等填充条的卷帘播完**（`hintCurtainDone`）才播 —— 用户要求"填充先完成动画、
   *   缩略图再弹簧卷帘"，否则两个动画重叠、看起来是一坨；
   * · 缩略图被清掉 ⇒ 归 0（实际很少单独发生：它与提示同生共死，通常整体淡出）。
   */
  private onThumbChange(): void {
    const has: boolean = this.thumb.pm !== undefined;
    if (!this.showGestureHint) {
      this.seekThumbGrow = has ? 1 : 0;
      return;
    }
    if (has) {
      // 填充条卷帘还没播完 ⇒ 先不显示缩略图，等 onFinish 的 revealSeekThumb() 再播
      if (!this.hintCurtainDone) return;
      this.revealSeekThumb();
    } else {
      this.seekThumbGrow = 0;
    }
  }

  /** 整卡卷帘的**起点比例**：不取 0（0 高面板可能被系统忽略），留一点保证面板始终有尺寸 */
  private growStart(): number {
    return 0.12;
  }

  /**
   * ⭐ 启动本次显示的卷帘（**幂等**：`onAppear` 与兜底定时器谁先到谁触发）。
   *
   * 为什么需要幂等双通道：卷帘本质是"面板高度从起点长到目标"，而面板是**异步创建**的。
   *   · 内容还没挂载就 animateTo ⇒ 面板一创建读到的就是终值 ⇒ 视觉上**没有动画**（"不是稳定触发"）；
   *   · 内容挂载了但没触发 ⇒ 同上。
   * 所以：三个外壳都挂 `.onAppear(() => this.startHintGrow())`（挂载即刻开跑，最准），
   * 再由 `startHintGrowSoon()` 的定时器兜底（内容被复用、onAppear 不再触发的场景）。
   *
   * ⚠️ 卷帘期间锚点与 offset 都不变（见 `hintOffsetY`）⇒ 即使某次没跑成动画，
   *   也只是"直接到位"，不会出现方向错乱或位置偏移。
   */
  private startHintGrow(): void {
    if (this.hintGrowStarted) return;
    if (!this.showGestureHint || !this.gestureHintMainText) return;
    // ⭐ 竖条不走卷帘（已改为横向"边缘滑入"，见 startEdgeSlide）：它的 hintGrow 在
    //   syncHintPopups 里直接置满 ⇒ 高度恒定 140，滑入才有完整的可视窗口。
    //   这里若不拦，会把 1 再"动画"到 1（无效果，但会占掉 started 标记，语义混乱）。
    if (this.isEdgePill()) return;
    if (this.hintGrowTimer >= 0) {
      clearTimeout(this.hintGrowTimer);
      this.hintGrowTimer = -1;
    }
    this.hintGrowStarted = true;
    const gen: number = this.hintCurtainGen;
    animateTo({
      duration: 220,
      curve: curves.springMotion(0.36, 0.9),
      // ⭐ 填充条的卷帘**播完之后**才让缩略图弹簧卷帘进来（用户 2026-09-24 要求
      //   "先不显示缩略图动画，填充先完成动画、缩略图再弹簧卷帘"）⇒ 两段首尾相接、不重叠。
      onFinish: () => {
        if (gen !== this.hintCurtainGen) return;   // 上一轮的迟到回调，丢弃
        this.hintCurtainDone = true;
        this.revealSeekThumb();
      }
    }, () => {
      this.hintGrow = 1;
    });
  }

  /** 兜底启动：面板挂载晚于预期时也能把卷帘跑起来（32ms ≈ 2 帧，正常情况 onAppear 已抢先） */
  private startHintGrowSoon(): void {
    if (this.hintGrowTimer >= 0) clearTimeout(this.hintGrowTimer);
    this.hintGrowTimer = setTimeout(() => {
      this.hintGrowTimer = -1;
      this.startHintGrow();
    }, 32);
  }

  /** 提示隐藏：撤销兜底定时器与"已启动"标记（**不重置 `hintGrow`**，收缩由 `startHintCollapse()` 负责） */
  private cancelHintGrow(): void {
    if (this.hintGrowTimer >= 0) {
      clearTimeout(this.hintGrowTimer);
      this.hintGrowTimer = -1;
    }
    if (this.hintRevealTimer >= 0) {
      clearTimeout(this.hintRevealTimer);
      this.hintRevealTimer = -1;
    }
    this.hintGrowStarted = false;
    this.hintCurtainDone = false;
  }

  /**
   * ⭐ 提示隐藏时的**退场卷帘**（2026-09-24 二次修正）。
   *
   * 为什么必须有它：用户反馈"seek 填充条 / 长按加速胶囊 / 音量亮度竖条**都是只有显示动画、
   * 没有消失动画**"。根因是出场只写了弹层那一层（`hintTransition()` 的 110ms 纯淡出），
   * 而**入场最抢眼的那个动作在内容侧**（`hintGrow` 卷帘 / `holdPop` 弹入），出场时这一半压根没写
   * ⇒ 卡片是"长出来的"，却是"原地淡没的"。
   * ⇒ 修法 = 入场动作的**逆动作**，与弹层淡出**同时启动**：
   *      · seek 卡：高度从满高卷帘回到 `growStart()`（0.12），缩略图槽同时收回 0；
   *      · 长按胶囊：外壳高度 + 内容 scale 一起缩回 `holdPopStart()`（0.62，见 syncHintPopups）；
   *      · 竖条：**不做卷帘**（高度恒 140），退场是"原路滑回边缘"，由 `edgePillTransition()` 负责。
   *
   * ⚠️ 时长 **180ms 必须 ≤ 弹层出场 200ms**（`hintTransition()`）：弹层先销毁的话收缩会被截断，
   *   结果又变成"没看到动画"。改一个必须改另一个。
   * ⚠️ 上一版的注释写着"隐藏时**不重置** hintGrow，否则淡出期间卡片会先塌一下"——
   *   那句在"没有退场动画"的前提下是对的（瞬塌 + 淡出 = 抖一下）；现在改成 **animateTo 平滑收缩**，
   *   与淡出同一条时间轴，读起来是"卷帘收起"，不是"塌"。
   */
  private startHintCollapse(): void {
    // 竖条不走卷帘（高度恒定）⇒ 退场交给弹层过渡，这里什么都不做
    if (this.isEdgePill()) return;
    // 长按胶囊的缩回在 syncHintPopups 的 hold 分支里（它走的是 holdPop，不是 hintGrow）
    if (this.gestureHintType === '') return;
    animateTo({ duration: 180, curve: Curve.EaseIn }, () => {
      // seek：整卡卷帘收回起点 + 缩略图槽一并收回（入场是"先填充条卷帘、再缩略图卷帘"，
      // 出场合成一段收回即可 —— 反正是同一块高度在缩）
      this.hintGrow = this.growStart();
      this.seekThumbGrow = 0;
    });
  }

  /**
   * 卷帘结束的**兜底**：正常由 `startHintGrow()` 的 `onFinish` 收尾（时序最准），
   * 这里只防"动画被抢占/组件重建导致 onFinish 不回调"⇒ 缩略图永远出不来。
   * 260ms ≈ 卷帘 220ms + 启动余量。
   */
  private scheduleRevealFallback(): void {
    if (this.hintRevealTimer >= 0) clearTimeout(this.hintRevealTimer);
    this.hintRevealTimer = setTimeout(() => {
      this.hintRevealTimer = -1;
      this.hintCurtainDone = true;
      this.revealSeekThumb();
    }, 260);
  }

  /**
   * ⭐ 缩略图的**弹簧卷帘**（只在填充条卷帘播完之后调用，见 `startHintGrow` 的 onFinish）。
   * 幂等：已经在 1、不是 seek、没有位图、提示已隐藏 —— 都不播。
   */
  private revealSeekThumb(): void {
    if (this.gestureHintType !== 'seek') return;
    if (!this.showGestureHint || !this.gestureHintMainText) return;
    if (this.thumb.pm === undefined || this.seekThumbGrow >= 1) return;
    animateTo({ duration: 220, curve: curves.springMotion(0.36, 0.9) }, () => {
      this.seekThumbGrow = 1;
    });
  }

  /** 缩略图当前高度（vp）：只由"缩略图到达系数"驱动（整卡卷帘由外层裁切负责） */
  private thumbGrowH(): number {
    return this.seekThumbH() * this.seekThumbGrow;
  }

  /** 缩略图下间距（vp）：跟着生长，避免"图还没出来就先撑开一段空档" */
  private thumbGrowGap(): number {
    return 8 * this.seekThumbGrow;
  }

  /**
   * ⭐ 提示卡片的**结构高度**（vp）—— 只看结构，**不含卷帘系数**。
   * seek = 缩略图槽（有图时=图高+间距）+ 填充条 + 上下内边距 16；
   * 竖条 = 140；长按胶囊 = 36。
   * 用途：`hintCardCurH()` 的增量来源（增量 = 本值 − 开场冻结的 `hintBaseH()`）。
   */
  private hintStructH(): number {
    if (this.gestureHintType === 'seek') {
      const slot: number = this.thumb.pm !== undefined ? this.seekThumbH() + 8 : 0;
      return slot + this.seekBarH() + 16;
    }
    if (this.isEdgePill()) return this.edgePillH();
    return this.holdPillH();
  }

  /**
   * ⭐ 开场（显示瞬间）的**基准高度**（vp）—— **不含缩略图槽**。
   *
   * 为什么开场也要把缩略图槽排除：用户要求"**填充条先走完卷帘，缩略图再弹簧卷帘进来**"。
   * 所以显示的瞬间卡片只有填充条那么高（seek = 56），缩略图槽的高度全部由
   * `seekThumbGrow` 那一段增量长出来（56 → 172），两个动画首尾相接、不重叠。
   * 竖条（140）与长按胶囊（36）没有缩略图 ⇒ 基准 = 结构高度，增量恒为 0。
   */
  private hintBaseH(): number {
    if (this.gestureHintType === 'seek') return this.seekBarH() + 16;
    if (this.isEdgePill()) return this.edgePillH();
    return this.holdPillH();
  }

  /** 显示瞬间冻结的基准高度（0 = 还没显示过 ⇒ 回退到当前基准，避免首帧出现 NaN） */
  private hintShownHeight(): number {
    return this.hintShownH > 0 ? this.hintShownH : this.hintBaseH();
  }

  /**
   * ⭐ 锚点补偿量（vp）：**只补偿"缩略图那段生长"**，**不补偿填充条的卷帘**。
   *
   * 填充条卷帘期间恒为 0 ⇒ 锚点不动 ⇒ 面板顶边不动 ⇒ 永远自上而下拉开（用户要求"弹簧卷帘"）。
   * 缩略图弹簧进来时（结构高度 +Δ）才上顶 Δ×系数/2：面板顶边上移 Δ/2、底边下移 Δ/2，
   * 中心不动 —— 与"一开始就有图"的终态完全重合（这是用户此前明确要求过的）。
   */
  private hintRise(): number {
    const delta: number = Math.max(0, this.hintStructH() - this.hintShownHeight());
    return delta * this.seekThumbGrow / 2;
  }

  /**
   * ⭐ 卡片**当前**高度（vp）= 基准高 × 卷帘 + 结构增量 × 缩略图系数。
   *
   * 两段彼此独立、都单调，所以面板高度连续、不会在缩略图到达的瞬间跳变
   * （早先是 `hintStructH() × hintGrow`，pm 一到位目标高度就从 56×g 跳到 145×g）。
   */
  private hintCardCurH(): number {
    const shownH: number = this.hintShownHeight();
    const delta: number = Math.max(0, this.hintStructH() - shownH);
    return shownH * this.hintGrow + delta * this.seekThumbGrow;
  }

  /** 缩略图宽度（vp）：**恒定不变** —— 只让高度长出来（宽度也变会读成"整体放大"，不如卷帘自然） */
  private thumbW(): number {
    return this.seekThumbH() * this.thumb.aspect;
  }

  /**
   * ⭐ seek 锚点的 y（vp）：屏幕 30% 处，**再按"显示之后长出来的那一半"上移**。
   *
   * 为什么需要它：popup 顶边在**显示瞬间**锁定（= 锚点底边 + offset.y，而 offset.y = −H₀/2，
   * H₀ = 显示那一刻的卡片高）。缩略图稍后到达、卡片从 56 长到 172 时，是**向下**长的 ⇒
   * 中心比"一开始就有缩略图"低 (H−H₀)/2 = 58vp。
   * 把锚点上移 (H_now − H₀)/2 正好抵消 ⇒ 卡片全程围绕**同一个中心**长出来：
   *   中心 = (A − rise) − H₀/2 + H/2 = A ✓
   * ⚠️ 用 H_now − H₀ 而不是 H_now：一开始就有图时 H₀ = H ⇒ rise = 0，锚点不动（否则会重复补偿）。
   * ⚠️ 依赖"锚点移动时弹层跟随"（工程内已知：键盘 RESIZE 时弹层会跟随锚点移动）；
   *   若某设备不跟随，改锚点无效（无害），需退回"offset 按最终高度冻结"的方案。
   */
  private seekAnchorY(): Length {
    if (this.vcH <= 0) return '30%';
    return this.vcH * 0.30 - this.hintRise();
  }

  /**
   * 提示胶囊里「进度条 / 时间行」的宽度（vp）：与缩略图等宽。
   * ⚠️ 2026-09-24 方案 S1：时间行已经坐进"满铺填充条"，所以这个宽度同时是**填充条**的宽度；
   *   无缩略图时从 96 放大到 **150**（原先那条只有 4vp 高、不承载文字，现在要装下时间行 + 位移）。
   */
  private hintContentW(): number {
    return this.thumbW();
  }

  /** seek 填充条的整体高度（vp）—— 也是全圆半径的来源（高/2） */
  private seekBarH(): number {
    return 40;
  }

  /** 长按加速胶囊的高度（vp）：图标 22 + 上下内边距 7×2 */
  private holdPillH(): number {
    return 36;
  }

  /** 长按加速胶囊的宽度（vp）：图标 22 + 左右内边距 22×2（显式声明，涟漪描边才能与它精确重合） */
  private holdPillW(): number {
    return 66;
  }

  /** 长按"原地弹入"的起点比例（外壳尺寸与内容 scale 同步） */
  private holdPopStart(): number {
    return 0.62;
  }

  /**
   * ⭐ 长按胶囊的**原地弹入**（`holdPop` 0.62 → 1，260ms 弹性）。
   *
   * ⛔ **不要用 `TransitionEffect.scale` 做这件事（2026-09-24 真机反馈的坑）**：
   *   用户反馈"不是原地弹入，有时从下方弹入，有时从右下弹入"——方向随**布局**变化
   *   （横屏非全屏：播放器只占窗口左侧 ⇒ "从右下"；全屏竖屏 ⇒ "从下方"），
   *   说明**弹层 transition 的缩放参照系不是胶囊自己**，而是比胶囊大得多的盒子（弹层/组件/窗口）。
   *   SDK 里 `ScaleOptions.centerX/centerY` 的 `'50%'` 明确是"**该效果所作用的那个节点**宽高的 50%"
   *   ⇒ 参照系不是胶囊时，写死 50% 也落不到胶囊中心。
   *
   * ✅ 改用**两件我们自己能控的东西同步**：
   *   ① **外壳尺寸** = 目标尺寸 × `holdPop`（布局尺寸 ⇒ 弹层材质/圆角跟着缩，玻璃真的在弹）；
   *   ② **内容 `scale` 属性**（原点默认就是自身中心，与弹层参照系无关）⇒ 图标跟着弹；
   *   ③ **垂直补偿**：`Placement.Bottom` 让弹层顶边被锚点锁住，高度缩小会让中心下移
   *      ⇒ 锚点 y 加 `holdPillH()/2 × (1 − holdPop)`（见 `holdAnchorY()`）；
   *      水平不用管 —— 弹层本身就以锚点为中心左右居中。
   * 启动时机与卷帘同套路：内容 `onAppear` + 32ms 兜底定时器（面板异步创建，早跑=没动画），
   *   `startHoldPop()` 幂等去重。
   */
  private startHoldPop(): void {
    if (this.holdPopStarted) return;
    if (!this.showGestureHint || this.gestureHintType !== '') return;
    if (this.holdPopTimer >= 0) {
      clearTimeout(this.holdPopTimer);
      this.holdPopTimer = -1;
    }
    this.holdPopStarted = true;
    animateTo({ duration: 260, curve: curves.springMotion(0.35, 0.7) }, () => {
      this.holdPop = 1;
    });
  }

  /** 兜底启动：面板挂载晚于预期时也能把弹入跑起来（32ms ≈ 2 帧） */
  private startHoldPopSoon(): void {
    if (this.holdPopTimer >= 0) clearTimeout(this.holdPopTimer);
    this.holdPopTimer = setTimeout(() => {
      this.holdPopTimer = -1;
      this.startHoldPop();
    }, 32);
  }

  /** 长按结束：只清定时器与标记，**不动 `holdPop`**（缩回由 syncHintPopups 里的 animateTo 平滑播，见那处注释） */
  private cancelHoldPop(): void {
    if (this.holdPopTimer >= 0) {
      clearTimeout(this.holdPopTimer);
      this.holdPopTimer = -1;
    }
    this.holdPopStarted = false;
  }

  /**
   * ⭐ 长按涟漪：从胶囊位置向外扩散一圈描边（每次长按只播一次，420ms `EaseOut`）。
   * ⚠️ 起点(0.9, 0.5) 与终点(1.6, 0) 分**两帧**赋：同一帧内连赋两次 @State 会被合并成一次
   *   ⇒ 没有动画过程（工程内既有结论），所以晚一帧再 animateTo。
   */
  private playHoldRipple(): void {
    if (this.rippleTimer >= 0) {
      clearTimeout(this.rippleTimer);
      this.rippleTimer = -1;
    }
    this.rippleS = 0.9;
    this.rippleO = 0.5;
    this.rippleTimer = setTimeout(() => {
      this.rippleTimer = -1;
      animateTo({ duration: 420, curve: Curve.EaseOut }, () => {
        this.rippleS = 1.6;
        this.rippleO = 0;
      });
    }, 0);
  }

  /** 长按结束：复位涟漪（此时不透明度已为 0，跳变不可见） */
  private resetHoldRipple(): void {
    if (this.rippleTimer >= 0) {
      clearTimeout(this.rippleTimer);
      this.rippleTimer = -1;
    }
    this.rippleS = 0.9;
    this.rippleO = 0;
  }

  /**
   * ⭐ 弹层相对锚点的**垂直落位**（vp）：`Placement.Bottom` 把面板顶边放在锚点下方这个距离处，
   * 再叠加 `offset.y`；当 `offset.y = −半高` 时 ⇒ **面板中心 = 锚点 + 本值**。
   * 真机实测（2026-09-24，横屏非全屏、胶囊 66×36）：偏移 ≈ **8vp**
   *   （长按胶囊中心 46.7vp vs 锚点 39.2vp；seek 卡中心 111.0vp vs 锚点 101.8vp ⇒ 8~9vp）。
   */
  private hintPopPadV(): number {
    return 8;
  }

  /**
   * ⭐ 长按涟漪描边：**画在弹层之外**（弹层会裁掉超出内容框的部分）。
   * 纯装饰（`hitTestBehavior(None)`），常驻挂载、靠 `rippleS/rippleO` 驱动。
   *
   * ⚠️ **定位必须写成"百分比 + 内层固定偏移"，不能写成 `vcH*ratio + 常量`**（2026-09-24 真机踩到）：
   *   `vcH/vcW` 靠根 Stack 的 `onAreaChange` 实测，**在该布局下实测到它仍是 0** ⇒
   *   `holdRippleAnchorY()` 走了 `'10%'` 的退化分支，而**百分比带不动那个 +8vp 常量** ⇒
   *   涟漪中心落在锚点、比胶囊中心高 8vp（用户原话："涟漪位置不对，有点偏上了"）。
   *   现在的两层写法在"vcH 有值 / 没值"两种情况下结果**完全一致**（10% 的父高 = vcH×0.10）：
   *     外层：`.position({y:'10%'}) + translate(-50%,-50%)` ⇒ 盒中心落在锚点；
   *     内层：`translate({y: dropY})` ⇒ 再落到胶囊中心（popup 通道 +8，内联通道 +0）。
   * ⚠️ 这个 8 是**静置锚点**的下落量（不跟随 `holdPop`）—— 弹入期间锚点被补偿、面板中心始终不动，
   *   所以涟漪中心也应当是恒定的那一个点。
   */
  @Builder
  holdRippleRing(dropY: number) {
    Stack() {
      Stack()
        .width(this.holdPillW())
        .height(this.holdPillH())
        .borderRadius(this.holdPillH() / 2)
        .border({ width: 1, color: '#FFFFFF' })
        .opacity(this.rippleO)
        .scale({ x: this.rippleS, y: this.rippleS })
        .translate({ x: 0, y: dropY })
    }
    .width(this.holdPillW())
    .height(this.holdPillH())
    .position({ x: '50%', y: '10%' })
    .translate({ x: '-50%', y: '-50%' })
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * ⭐ seek 填充条里**填充**自身的圆角 = 内圈高的一半 ⇒ 填充是一根**完整胶囊**
   * （与音量/亮度竖条同款语义：填充是"内缩一圈的独立胶囊"，不是铺满整卡的色块）。
   * 内圈高 = 40 − 内缩 6×2 = 28 ⇒ 半径 14；进度很小、宽度不足时由框架收成圆头小胶囊。
   */
  private seekBarFillRadius(): number {
    return (this.seekBarH() - this.edgeInset() * 2) / 2;
  }

  /**
   * 提示胶囊圆角：seek 一律 **20**（有缩略图时是大卡 radius 20；无缩略图时整卡就是
   * 40vp 高的填充条 ⇒ 全圆也是 20）。长按加速胶囊用 12。
   * ⚠️ 2026-09-24 起音量/亮度是贴边竖条（`edgePillInner()`），圆角 = 半宽，不走这里。
   */
  private hintRadius(): number {
    if (this.gestureHintType === 'seek') return 20;
    return 12;
  }

  /**
   * ⭐ 竖条锚点的 y（vp）= 屏幕 50% 处 − `hintRise()`。
   * `hintRise()` 只反映**缩略图异步到达**（竖条没有缩略图 ⇒ 恒为 0 ⇒ 锚点完全恒定）。
   * 卷帘期间锚点/offset 都不动 ⇒ 面板顶边固定 ⇒ 纯自上而下展开（详见 `hintOffsetY`）。
   */
  private edgeAnchorY(): Length {
    if (this.vcH <= 0) return '50%';
    return this.vcH * 0.50 - this.hintRise();
  }

  /**
   * 长按胶囊锚点的 y（vp）：屏幕 10% 处，**再按"原地弹入"的缩量上移半个**。
   * 为什么必须补偿：`Placement.Bottom` 把弹层**顶边**锁在锚点下方，胶囊从 0.62 长到 1 时
   * 高度是**向下**长的 ⇒ 中心下移 `holdPillH()×(1−holdPop)/2`；把锚点同样上移，
   * 中心 = `anchor + 8 + offset + h/2` 全程 = `vcH*0.10 + 8` 恒定 ⇒ 真的是"原地"弹。
   * （`holdPop = 1` 时补偿为 0，与该方案之前的终态位置完全一致。）
   */
  private holdAnchorY(): Length {
    if (this.vcH <= 0) return '10%';
    return this.vcH * 0.10 + this.holdPillH() * (1 - this.holdPop) / 2 - this.hintRise();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ⭐ 音量/亮度提示 = 贴边竖条（2026-09-24 方案 C）
  //
  // 形态：46×140 全圆竖条，内部轨道铺满（比胶囊小一圈，内缩 3vp）用透明灰，
  //       填充自下而上生长；图标在上、百分比数字在下。
  // 位置：竖条落在**手指的反侧** —— 调音量（手指在右半屏）→ 贴左；
  //       调亮度（手指在左半屏）→ 贴右。同侧会被手掌/拇指挡住（用户要求）。
  // 为什么要两个锚点而不是一个：见 pillPopupVisible 附近注释（连续手势时状态不变、
  //       build 不重跑，靠 options 求值定位会留在旧的一侧）。
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 把 `Length`（`string | number | Resource`）收成 vp 数值（拿不到时返回 0）。
   *
   * ⚠️ 为什么需要它：`Area.width/height` 的静态类型是 `Length`，写 `x as number` 只是**断言**、
   *   不做转换 —— 运行时若是字符串，`x > 0` 静默为 false（`vcW/vcH` 一直是 0 的根因）。
   *   先 `Number()`（number 与纯数字串），不成再 `parseFloat()`（`'360.00vp'` 这类带单位串）。
   * 用途：根 Stack 实测播放器区域尺寸（见 onAreaChange）。
   */
  private lenToVp(v: Length): number {
    if (typeof v === 'number') return Number.isFinite(v) ? v : 0;
    if (typeof v === 'string') {
      const f: number = parseFloat(v);
      return Number.isFinite(f) ? f : 0;
    }
    return 0;   // Resource 等对象形态：拿不到数值，让调用侧保持旧值
  }

  /** 当前提示是否为贴边竖条（音量/亮度） */
  private isEdgePill(): boolean {
    return this.gestureHintType === 'volume' || this.gestureHintType === 'brightness';
  }

  /** 竖条宽度（vp） */
  private edgePillW(): number {
    return 46;
  }

  /** 竖条高度（vp） */
  private edgePillH(): number {
    return 140;
  }

  /** 竖条圆角 = 半宽 → 全圆（popup radius 传这个值） */
  private edgePillRadius(): number {
    return this.edgePillW() / 2;
  }

  /**
   * 填充相对胶囊外缘的内缩（vp）。**无轨道**后填充是竖条里唯一的实体，要"比胶囊再小一些"：
   * 内缩 6 ⇒ 填充 34×128，圆角 = 23-6 = 17（与外圆同心）；内容可用区也随之收成 34 宽。
   */
  private edgeInset(): number {
    return 6;
  }

  /**
   * 竖条外缘距播放器边（= 屏幕边）的距离（vp）。
   * 用户三次下调贴边距离的轨迹：12 → 24 → **55**（"距离屏幕边缘太近了"）。
   * ⚠️ 左右两侧都只靠这个值算（见 `edgeAnchorX()` / `edgeLegacyAnchorX()`），改一处两边同时生效。
   * 语义 = **竖条外缘**到边的距离：左侧面板左缘、右侧面板右缘都等于它。
   */
  private edgeMargin(): number {
    return 55;
  }

  /**
   * ⭐ 音量/亮度竖条的**边缘滑入起点与方向**（2026-09-24 方案 A）。
   *
   * 位移由**弹层入场过渡** `edgePillTransition()` 播放（`TransitionEffect.translate`），
   * 不走内容层 `.translate()` —— 后者只能动内容、动不了玻璃，会变成两条时间轴（见状态区注释）。
   * ⚠️ 起点距离同时是**回弹的放大倍数**：起点越大，同样的过冲比例带来的回弹位移越大。
   */
  private edgeSlideDist(): number {
    return this.edgePillW() + 10;
  }

  /** 滑入方向：音量（贴左）从左侧屏幕外滑入 = −1；亮度（贴右）从右侧屏幕外滑入 = +1 */
  private edgeSlideDir(): number {
    return this.gestureHintType === 'volume' ? -1 : 1;
  }

  /**
   * ⭐ 竖条锚点的 x（vp）——**锚点中心 = 面板中心**，所以直接把它放到"面板中心该在的位置"。
   *
   * 为什么不继续用 `offset.x`（2026-09-24 真机 dump 实测）：
   *   · 锚点用 `position({x:'100%'})` + `offset.x = -47.5vp` 时，面板右缘实际落在距窗口右边
   *     **54.5vp**（而非 24vp）；左侧 `offset.x = +23vp` 也多了 5.7vp。**offset.x 靠近窗口边缘
   *     会被系统再推一次，推多少与传入值不符**（长按胶囊 offset.x 恒为 0，面板中心与锚点中心
   *     误差仅 0.5px ⇒ 默认"居中于锚点"本身是精确的，问题只在 offset.x）。
   *   · 改成「锚点数值定位 + offset.x = 0」后位置可控，左右对称。
   * ⚠️ 所以右侧需要容器宽：`vcW`（根 Stack onAreaChange 实测）；未测到时退回 360（竖屏默认宽）。
   */
  private edgeAnchorX(isVolume: boolean): number {
    const half: number = this.edgePillRadius();
    if (isVolume) {
      // 面板左缘 = edgeMargin ⇒ 面板中心 = edgeMargin + 半宽
      return this.edgeMargin() + half - 0.5;
    }
    const w: number = this.vcW > 0 ? this.vcW : 360;
    // 面板右缘 = 容器宽 - edgeMargin ⇒ 面板中心 = w - edgeMargin - 半宽
    return w - this.edgeMargin() - half - 0.5;
  }

  /**
   * 老设备内联通道的竖条锚点 X：
   * ⚠️ 内联通道里**这个 Column 本身就是竖条**（不是 1vp 锚点），所以定位是"竖条自身左缘"：
   *   左（音量）= edgeMargin；右（亮度）= 容器宽 - edgeMargin - 竖条宽。
   *   右侧用数值（vcW 实测）而不是 '100%' + translate，避免同 popup 通道那类边缘偏移问题。
   */
  private edgeLegacyAnchorX(): Length {
    if (this.gestureHintType === 'volume') return this.edgeMargin();
    const w: number = this.vcW > 0 ? this.vcW : 360;
    return w - this.edgeMargin() - this.edgePillW();
  }

  /**
   * ⭐ 老设备内联通道的**卡片顶边** y（vp）。
   *
   * `ratio` = 该类提示的基准中心比例（seek 0.30 / 竖条 0.50 / 长按 0.10）。
   * 为什么必须给"顶边"而不是继续用 `translate({y:'-50%'})` 居中：
   *   translate 的 −50% 是**相对自身尺寸**的，卡片越高越往上顶 ⇒ 高度生长时变成"上下对开"，
   *   观感上就是"有时从上往下、有时从下往上"（用户 2026-09-24 反馈）。
   *   改成顶边固定后，高度只往下长 ⇒ 与 popup 通道一样是纯"卷帘"。
   * 缩略图异步到达（结构 +Δ）时再上顶 Δ/2（`hintRise()`）以保持中心不动。
   */
  private legacyHintTopY(ratio: number): Length {
    if (this.vcH <= 0) return `${Math.round(ratio * 100)}%`;
    return this.vcH * ratio - this.hintShownHeight() / 2 - this.hintRise();
  }

  /**
   * 把 @Link 的提示状态拆成 bindPopup 用的派生 @State（每个锚点一个）：
   * seek 胶囊 / 音量竖条 / 亮度竖条 / 长按加速胶囊。
   * （popup 锚点常驻、显隐靠状态，所以必须用 @State 驱动）
   */
  syncHintPopups(): void {
    const show: boolean = this.showGestureHint && !!this.gestureHintMainText;
    // ⭐ 提示**类型中途切换**（竖滑切横滑：音量 ↔ seek）时也要重来一遍：
    //   冻结的 offset / 结构高度是按"当时的类型"算的，不重算会把竖条的 140 用在 seek 卡上
    //   （高度、位置全错，卷帘方向也跟着乱）—— 这是"时对时错"的另一个来源。
    const typeChanged: boolean = show && this.lastHintType !== this.gestureHintType;
    // ⭐ 缩略图生长系数的初值只在「提示从隐藏 → 显示」那一刻定：
    //   拖动过程中 gestureHintMainText 每变一次都会进这里，若无条件重算会把
    //   正在播放的 220ms 生长动画直接掐断（图瞬间满高）。
    if (show && (!this.lastHintShown || typeChanged)) {
      // ⭐ 缩略图**开场一律不显示**（哪怕位图已缓存）：先只让填充条走完卷帘，
      //   缩略图等卷帘 onFinish 再弹簧卷帘进来（用户 2026-09-24 要求"填充先完成动画"）。
      this.seekThumbGrow = 0;
      // ⭐ 整卡卷帘：先把生长系数压回起点（面板仍有尺寸 ⇒ 位置可被系统测到），
      //   再在**内容挂载后**启动动画推到 1（见 startHintGrow：onAppear + 兜底定时器双通道）。
      //   ⚠️ 同一帧内连着赋两次 @State 只有最后一次生效 ⇒ 不能和 animateTo 写在同一帧。
      //   ⭐ 竖条例外：它不做卷帘（改为横向"边缘滑入"），高度**直接置满** —— 否则 hintCardCurH
      //      会停在 0.12 高（16.8vp），留个矮窗口纯属多余（滑入是弹层过渡，与内容高度无关）。
      this.hintGrow = this.isEdgePill() ? 1 : this.growStart();
      this.hintCurtainGen++;
      this.cancelHintGrow();
      // ⭐ 冻结本次显示的**基准高度**（不含缩略图槽）与垂直偏移：
      //   offset = −H₀/2 且在卷帘期间恒定 ⇒ 面板顶边固定 ⇒ 永远自上而下展开；
      //   锚点补偿只用于"缩略图那段生长"，见 hintRise()。
      this.hintShownH = this.hintBaseH();
      this.hintOffsetY = -(this.hintShownH / 2);
      // ⭐ 跨档脉冲的**基线**：用显示这一刻的当前值建，而不是先设 -1 等第一次变化再建
      //   （播放页可能"先给 progress、后给 show"，那次赋值会被 onHintProgressTick 的
      //    showGestureHint 守卫挡掉 ⇒ 基线要延到下一次跨档 ⇒ 白白浪费一次脉冲）。
      //   resetTickPulse 同时把图标与涟漪压回静置态（上次隐藏时若正播到一半会被掐断）。
      this.resetTickPulse();
      this.lastIconTick = this.gestureHintProgress >= 0 ? this.iconTickOf(this.gestureHintProgress) : -1;
      this.startHintGrowSoon();
      this.scheduleRevealFallback();
    } else if (!show) {
      // ⭐ 退场卷帘：把"显示"那一刻长出来的高度**原路收回**（与入场对称，见 startHintCollapse）；
      //   缩略图槽的 `seekThumbGrow = 0` 已并进那次 animateTo，不再瞬清（瞬清在可见的退场动画里会抖）
      this.startHintCollapse();
      this.cancelHintGrow();
      // 隐藏：掐掉在跑的脉冲（图标 + 涟漪一起复位；下次显示会重建基线）
      this.resetTickPulse();
      this.lastIconTick = -1;
      // ⚠️ 这里**不重置 hintGrow**：收缩由 startHintCollapse() 平滑播完，重置只在下次"显示"那一刻做。
    }
    this.lastHintShown = show;
    this.lastHintType = show ? this.gestureHintType : '';
    // ⭐ 长按：每次"从隐藏 → 显示"都（a）把弹入系数压回起点并启动原地弹入，（b）播一次涟漪
    const holdShow: boolean = show && this.gestureHintType === '';
    if (holdShow && !this.lastHoldShown) {
      this.holdPop = this.holdPopStart();
      this.cancelHoldPop();          // 复位"已启动"标记与兜底定时器（不动 holdPop）
      this.startHoldPopSoon();
      this.playHoldRipple();
    } else if (!holdShow && this.lastHoldShown) {
      this.cancelHoldPop();
      this.resetHoldRipple();
      // ⭐ 退场：外壳高度 + 内容 scale **一起缩回起点**（入场 0.62 → 1 的逆动作）。
      //   ⚠️ 与入场同一条时间轴：`holdAnchorY()` 会跟着缩量补偿，所以是"原地缩回"而不是缩小。
      //   ⚠️ 时长 180ms ≤ 弹层出场 200ms（`hintTransition()`），别让弹层先销毁把收缩截断。
      //   ⚠️ `cancelHoldPop()` 只清定时器/标记，**不动 holdPop**（老注释"不重置 holdPop"那句话
      //     在"没有退场动画"的前提下才成立，现在是 animateTo 平滑缩回）。
      animateTo({ duration: 180, curve: Curve.EaseIn }, () => {
        this.holdPop = this.holdPopStart();
      });
    }
    this.lastHoldShown = holdShow;
    this.pillPopupVisible = show && this.gestureHintType === 'seek';
    this.volPopupVisible = show && this.gestureHintType === 'volume';
    this.brightPopupVisible = show && this.gestureHintType === 'brightness';
    this.holdPopupVisible = show && this.gestureHintType === '';
  }

  /**
   * 提示胶囊右侧的「相对位移」文案：相对本次交互的**起点**前进/后退了多少秒。
   * 例：`+10S`（前进）/ `-10S`（后退）/ `0S`（没动）。
   * 起点由播放页给出（拖动进度条 = 按下时的位置；视频区手势 = 手指落下的位置），
   * 起点无效（<0）时返回空串，右侧不占位。
   */
  private hintDeltaText(): string {
    if (!this.hintDeltaValid()) return '';
    const d: number = this.hintDeltaSec();
    if (d === 0) return '0S';
    return `${d > 0 ? '+' : ''}${d}S`;
  }

  /**
   * 相对位移的颜色：后退红 / 前进绿 / 没动用弱化的白。
   * 红绿沿用本组件已有的 `#FF5A5A` / `#57C15A`，不引入新色值。
   */
  private hintDeltaColor(): string {
    if (!this.hintDeltaValid()) return '#B3FFFFFF';
    const d: number = this.hintDeltaSec();
    if (d > 0) return '#57C15A';
    if (d < 0) return '#FF5A5A';
    return '#B3FFFFFF';
  }

  /** 相对位移是否可用（起点有效、时长已知、比例已知） */
  private hintDeltaValid(): boolean {
    return this.gestureHintBase >= 0 && this.duration > 0 && this.gestureHintProgress >= 0;
  }

  /** 相对位移秒数（四舍五入，与文案/颜色同源） */
  private hintDeltaSec(): number {
    return Math.round(this.duration * this.gestureHintProgress - this.gestureHintBase);
  }

  // ⭐ 沉浸光感胶囊内容（bindPopup builder）：外框/材质由 CustomPopupOptions 负责
  //   （systemMaterial 挂 ImmersiveMaterial，radius 见 hintRadius），builder 只画内容。
  //   ⚠️ 材质层在 backgroundColor 之下，内容根不要再叠不透明底色 / backgroundBlurStyle。
  @Builder
  gesturePillBuilder() {
    if (this.gestureHintType === 'seek') {
      this.seekCard();
    }
    // ⚠️ 音量/亮度原先也在这个 builder 里（水平胶囊 + 图标 + 数字 + 96vp 进度条），
    //    2026-09-24 方案 C 已改为贴边竖条 —— 见 `edgePillInner()`。
    //    这里不再保留旧分支，避免两份同款内容漂移（红线 9）。
  }

  /**
   * ⭐ seek 卡片 = 缩略图槽 + 满铺填充条（方案 S1，时间行直接坐进填充里）。
   *
   * **popup 通道与老设备内联通道共用本 builder**（红线 9：同款外观不许留两份副本）。
   * 卷帘做法：外壳高度 = `hintCardCurH()`（起点高 × hintGrow + 结构增量 × 缩略图系数）并裁切，
   * 内容按满尺寸绘制 ⇒ **自上而下**露出；顶边由锚点/offset 恒定保证（见 `hintOffsetY`）。
   */
  @Builder
  seekCard() {
    Column() {
      this.seekCardBody();
    }
    .height(this.hintCardCurH())
    .clip(true)
    // 卷帘在"面板真正挂载"之后才开始（否则面板一创建就是终态 = 看不见动画）
    .onAppear(() => { this.startHintGrow(); })
  }

  @Builder
  seekCardBody() {
    Column() {
      if (this.thumb.pm) {
        // 缩略图：**图像本身按满尺寸绘制**，外层容器高度按"到达系数"生长并裁切 ⇒ 自上而下露出。
        //   ⚠️ 不要直接改 Image 高度 + Cover：那样看到的是"图像的中间带"在被裁，方向感不对。
        Stack({ alignContent: Alignment.Top }) {
          Image(this.thumb.pm!)
            .width(this.thumbW())
            .height(this.seekThumbH())
            .borderRadius(12)
            .objectFit(ImageFit.Cover)
        }
        .width(this.thumbW())
        .height(this.thumbGrowH())
        .clip(true)
        .margin({ bottom: this.thumbGrowGap() })
      }
      this.seekBarBody(this.hintContentW());
    }
    .alignItems(HorizontalAlign.Center)
    .padding(8)
  }

  /**
   * ⭐ seek 的「满铺填充条」（2026-09-24 方案 S1）—— 时间行直接坐在填充条里。
   *
   * 结构（两层）：
   *   ① 填充：左起、宽 = 百分比、**比胶囊内缩一圈**（四周 6vp，与音量/亮度竖条同一个
   *      `edgeInset()`），自身是**完整胶囊**（圆角 = 内圈高/2）—— 未填充处就是玻璃本身（无轨道底条）；
   *   ② 内容：左「目标时间」（分 / 秒各自翻牌）、右「相对位移」，浮在填充之上。
   * 尺寸：宽由调用方给（= 缩略图宽，无图时也是同一宽度以保证横向不跳），高 40、全圆（radius 20）。
   *
   * ⚠️ 白字会压在半透明填充上：进度 90% 时对比最弱 ⇒ 挂一层很淡的 textShadow 兜底
   *   （与详情页"白字压在亮海报上"同一手法），任何进度下都读得清。
   * ⚠️ **卷帘不在这里**：整卡的自上而下展开由外层 `seekCard()` 的裁切负责，
   *   这里只画满尺寸内容（早先这一层自己也套了一个 CurH 外壳 ⇒ 与新外壳重复裁切）。
   * ⚠️ 新机（popup 通道）与老设备（内联通道）共用本 builder + `seekCard()`（红线 9）。
   */
  @Builder
  seekBarBody(w: number) {
    Stack({ alignContent: Alignment.Start }) {
      // ① 填充（左起；内缩一圈 + 自身全圆 = 一根完整胶囊，同音量/亮度竖条）
      Row()
        .width(`${this.gestureHintProgress * 100}%`)
        .height('100%')
        .backgroundColor('#47FFFFFF')
        .borderRadius(this.seekBarFillRadius())
      // ② 内容（浮在填充之上）
      Row() {
        // ⭐ 目标时间必须拆成「分 / 冒号 / 秒」三个 Text 才能翻牌：
        //   整串 `1:02` 含冒号 → 不是正整数 → contentTransition 被**静默忽略**（真机实测确认）。
        //   拆开后两段各自是纯数字，都挂翻牌；冒号永不变化，不挂。
        Row() {
          Text(this.hintTimeMin())
            .fontSize(18)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)
            .textShadow({ radius: 4, color: '#66000000', offsetX: 0, offsetY: 1 })
            .contentTransition(this.numFlip())
          Text(':')
            .fontSize(18)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)
            .textShadow({ radius: 4, color: '#66000000', offsetX: 0, offsetY: 1 })
          Text(this.hintTimeSec())
            .fontSize(18)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Medium)
            .textShadow({ radius: 4, color: '#66000000', offsetX: 0, offsetY: 1 })
            .contentTransition(this.numFlip())
        }
        .alignItems(VerticalAlign.Center)
        // 右：+10S 绿（前进）/ -10S 红（后退）/ 0S 弱化白；起点无效时不占位
        Text(this.hintDeltaText())
          .fontSize(18)
          .fontColor(this.hintDeltaColor())
          .fontWeight(FontWeight.Medium)
          .textShadow({ radius: 4, color: '#66000000', offsetX: 0, offsetY: 1 })
      }
      .width('100%')
      .height('100%')
      // 内容相对**内圈**再留 6vp（外圈已有 6）⇒ 与卡边共 12vp，和原来的排版一致
      .padding({ left: 6, right: 6 })
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
    }
    .width(w)
    .height(this.seekBarH())
    // 全圆（= 高/2）：与音量/亮度竖条同一套语言
    .borderRadius(this.seekBarH() / 2)
    // 内缩 6vp：填充比胶囊小一圈（用户要求，与竖条 edgeInset 同一个值）
    .padding(this.edgeInset())
    .clip(true)
  }

  /**
   * ⭐ 音量/亮度**贴边竖条**的内容（2026-09-24 方案 C）。
   *
   * 只画内容，不画玻璃外壳——外壳由 popup 的 `systemMaterial`（新机）或
   * `ImmersiveLightWrapper`（老设备内联通道）提供，所以本 builder 的尺寸
   * （46×140）就是外壳尺寸，圆角由外层的 `edgePillRadius()`（半宽 = 全圆）决定。
   *
   * 结构（自下而上两层）：
   *   ① 填充：底对齐、高度 = 百分比，白 28% —— 用半透明而非实色，否则会盖死玻璃材质；
   *   ② 内容：图标在上、百分比数字在下，纯白（任何比例下都读得清）。
   * ⚠️ 2026-09-24 细化（用户要求）：**已去掉轨道底条**；填充也再从内缩 3 收到 6
   *   （34×128、圆角 17 与外圆同心），比胶囊明显小一圈，竖条里只剩"填充 + 内容"。
   */
  /**
   * ⭐ 竖条的**内容容器**（46×140）。
   *
   * ⚠️ 这里**没有横向位移**（早先有，已删）：滑入由**弹层入场过渡** `edgePillTransition()`
   *   统一驱动材质 + 内容。若在这里再加一层 `.translate()`，又会变成"内容滑、玻璃不滑"的
   *   两条时间轴（用户 2026-09-24：「内外的动画好像不一致…沉浸光感不是滑进来的」）。
   * ⚠️ 外层那个 `clip(true)` 对竖条**没有实际作用**（高度 = 内容高，没有超出），
   *   它服务于同一份 builder 里 seek / 长按的卷帘，别删。
   * ⚠️ 跨档的**涟漪环不在这一层**：它会被这个 clip / 弹层内容框裁掉，必须常驻在弹层之外
   *   （见 `edgePillRippleRing`，这也是它和"贴边闪一下的内描边"的根本区别）。
   */
  @Builder
  edgePillInner() {
    Column() {
      this.edgePillBody();
    }
    .width(this.edgePillW())
    .height(this.hintCardCurH())
    .clip(true)
    // 卷帘在"面板真正挂载"之后才开始（否则面板一创建就是终态 = 看不见动画）；竖条已被拦在
    // startHintGrow 之外（改走弹层过渡），这里的调用对它无害
    .onAppear(() => { this.startHintGrow(); })
  }

  /**
   * ⭐ 竖条的**涟漪环**（2026-09-24 二次修正：第一版做成了"贴外缘内侧亮一下"的内描边，
   *   用户对比长按涟漪后："描边脉冲为什么和长按涟漪不一样？我想要长按涟漪那样的"）。
   *
   * 与 `holdRippleRing()` **完全同构**（同一个套路、同一组视觉参数：
   *   `border 1vp` 白描边、`420ms EaseOut`、起点不透明度 0.5 上下、扩到约 1.4~1.6 倍后淡到 0）：
   *   ⛔ **必须画在弹层之外** —— 越出弹层内容框的部分会被**弹层裁掉**（工程内既有结论），
   *      所以它不能像图标那样待在 `edgePillInner()` 里（上一版就是这么做的，注定只能"贴边闪"）。
   *   ⇒ 常驻挂在提示根 Stack（页面层）上，靠 `rippleEdgeS/rippleEdgeO` 驱动、`opacity` 控可见。
   *
   * 定位（⚠️ 两条通道语义不同，所以带一个 `atTopLeft` 开关，别把它删成一个"看起来更简洁"的版本）：
   *   · **popup 通道**（`atTopLeft = false`）：锚点是 1vp 的点，面板中心 = 锚点 + `dropY`（=`hintPopPadV()`）
   *     ⇒ 用 `position(锚点) + translate(-50%,-50%)` 把盒子中心对到锚点，再由内层 `translate` 补 dropY。
   *     ★ 这是 `holdRippleRing` 踩过的坑：**不能**写成"`vcH*比例 + 常量`"——`vcW/vcH` 在该布局下
   *       可能仍是 0（静默失效），退化成"百分比"时**带不动那个常量** ⇒ 涟漪中心会偏移（用户当时原话
   *       "涟漪位置不对，有点偏上了"）。所以常量一律交给**内层 translate**。
   *   · **老设备内联通道**（`atTopLeft = true`）：竖条是**组件自身定位**（左上角 = `edgeLegacyAnchorX()`
   *     + `legacyHintTopY(0.50)`）⇒ 涟漪复制同一对表达式、不做居中换算就天然与竖条重合
   *     （连 `vcH = 0` 的退化分支也一致），`dropY` 传 0。
   * ⚠️ `.scale` 的原点默认是**自身中心** ⇒ 涟漪以竖条中心向外扩，与位置属性互不干扰。
   * ⚠️ `hitTestBehavior(None)`：纯装饰（常驻挂载在弹层之外），绝不能挡播放器的手势。
   *
   * ⛔⛔ **位置表达式必须写在 builder 内部，绝不能当参数传进来**（2026-09-24 真机踩坑）：
   *   用户反馈「涟漪只在左侧出现，调节亮度时涟漪也是左侧」——根因就是本 builder 原先的签名
   *   `edgePillRippleRing(posX, posY, dropY, atTopLeft)` 把 `edgeAnchorX(...)` 这类**会随
   *   `gestureHintType` 变化**的值当**按值参数**传了进来。ArkUI 的 `@Builder` 按值传参
   *   **不参与父组件的刷新**：参数变化不会重建 builder 内部 UI，节点停在**首次渲染**那一帧
   *   （首次渲染时 `gestureHintType === ''` ⇒ 走 `isVolume = true` 分支 ⇒ 永久钉在左侧）。
   *   ⇒ 修法：签名只留 `atTopLeft`（调用点传**字面常量** `false`/`true`，永不变），位置一律
   *   **在 builder 体内读 `this.gestureHintType` / `this.vcW`** —— 这样它和普通 UI 一样
   *   跟着状态刷新。⚠️ 同工程至少 15 处 `@Builder` 带参调用点，只要传的是字面常量就没事；
   *   `topBarBackButton(slideFrom)` 是既有反例（靠 `.onAppear` 记 `_from` 曲线救国）。
   */
  @Builder
  edgePillRippleRing(atTopLeft: boolean) {
    Stack() {
      Stack()
        .width(this.edgePillW())
        .height(this.edgePillH())
        .borderRadius(this.edgePillRadius())
        .border({ width: 1, color: '#FFFFFF' })
        .opacity(this.rippleEdgeO)
        .scale({ x: this.rippleEdgeS, y: this.rippleEdgeS })
        // popup 通道：外层 translate(-50%) 只能带比例、**带不动常量**，所以 dropY 交给内层
        // （这就是 holdRippleRing 当初"涟漪偏上"的坑）；内联通道不需要，传 0
        .translate({ x: 0, y: atTopLeft ? 0 : this.hintPopPadV() })
    }
    .width(this.edgePillW())
    .height(this.edgePillH())
    .position({
      x: atTopLeft ? this.edgeLegacyAnchorX() : this.edgeAnchorX(this.gestureHintType !== 'brightness'),
      y: atTopLeft ? this.legacyHintTopY(0.50) : this.edgeAnchorY()
    })
    .translate({ x: atTopLeft ? '0%' : '-50%', y: atTopLeft ? '0%' : '-50%' })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  edgePillBody() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ① 填充（从底部往上涨）
      Column()
        .width('100%')
        .height(`${this.gestureHintProgress * 100}%`)
        .backgroundColor('#47FFFFFF')
        .borderRadius(this.edgePillRadius() - this.edgeInset())
      // ② 内容
      Column() {
        Image(this.gestureHintType === 'volume'
          ? $r('app.media.music_fill')
          : $r('app.media.sun_min'))
          .width(20)
          .height(20)
          .fillColor('#FFFFFF')
          // ⭐ 跨档脉冲：每跨 10% 弹一下（`iconPulse` 1 → 1.3 → 1，曲线见 playTickPulse）；
          //   同一拍还会在**弹层之外**放一圈涟漪（edgePillRippleRing）
          //   ⚠️ 用**属性 scale**而不是 TransitionEffect.scale —— 属性 scale 的缩放原点
          //   默认就是元素自身中心（弹层参照系那个坑只影响 transition，见 startHoldPop 注释）。
          .scale({ x: this.iconPulse, y: this.iconPulse })
        Text(this.gestureHintMainText.replace('%', ''))
          // 内圈收窄到 34vp 后 17 会让 "100" 贴边，收到 16
          .fontSize(16)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          // 数字翻转：音量/亮度是纯正整数，完全符合官方约束（真机实测会翻）
          .contentTransition(this.numFlip())
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 12, bottom: 12 })
    }
    .width(this.edgePillW())
    .height(this.edgePillH())
    // 内缩 6：填充比胶囊小一圈（用户要求），内容可用区同时收成 34×128
    .padding(this.edgeInset())
  }

  // ⭐ 长按加速胶囊内容（bindPopup builder）： gooey_balls 转圈图标
  @Builder
  holdPillBuilder() {
    // ⭐ 长按 = **原地弹入**（用户 2026-09-24 选定）：显隐交给外壳尺寸 + 内容 scale（见 holdPillShell），
    //   弹层自己的 transition 只做淡入淡出（不带 scale —— 它的缩放参照系不是胶囊，方向会乱，见 startHoldPop）。
    this.holdPillShell();
  }

  /** 长按胶囊的**内容**：按满尺寸绘制，自身 `scale` 跟着 `holdPop` 弹（原点默认=自身中心） */
  @Builder
  holdPillContent() {
    Column() {
      Image($r('app.media.gooey_balls1'))
        .width(22).height(22)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .width(this.holdPillW())
    .height(this.holdPillH())
    .padding({ left: 22, right: 22, top: 7, bottom: 7 })
    .scale({ x: this.holdPop, y: this.holdPop })
  }

  /**
   * ⭐ 长按胶囊的**外壳**：高度 = 目标高 × `holdPop`（弹层材质/圆角按内容布局尺寸绘制
   * ⇒ 玻璃真的在弹），内容满尺寸居中、被裁切 ⇒ 视觉是**从中心向上下扩开**，不是从某条边拉开。
   * 两条通道共用（红线 9）。
   *
   * ⚠️ **只动高度、不动宽度**（刻意）：`Placement.Bottom` 的垂直规则是"顶边锁在锚点下"（可算、可补偿），
   *   而"面板宽度变化时弹层会不会逐帧重新水平居中"**没有实证**（工程里此前只有高度在长：
   *   竖条 140、seek 卡 172 都是只变高）。若宽度也跟着变而弹层不重新居中，就会变成"从左侧弹"——
   *   那就是换了个方向的同一个 bug。⇒ 宽度固定，靠**内容 scale**（原点=自身中心，见 holdPillContent）出弹感。
   */
  @Builder
  holdPillShell() {
    Stack({ alignContent: Alignment.Center }) {
      this.holdPillContent();
    }
    .width(this.holdPillW())
    .height(this.holdPillH() * this.holdPop)
    .clip(true)
    // 弹入在"面板真正挂载"之后才开始（否则面板一创建就是终态 = 看不见动画）
    .onAppear(() => { this.startHoldPop(); })
  }

  // ⭐ 顶部中间状态栏：网速 · 时间 · 电量（横屏全屏，居中；左右组等宽 88vp，时间严格居中）
  @Builder
  topBarStatusInfo() {
    Row() {
      // 网速组（图标 + 定宽文本：右对齐→右侧稳定、数值变化向左生长）
      Row() {
        Image($r('app.media.heart_rate'))
          .width(20)
          .height(20)
          .fillColor('#FFFFFF')
          .opacity(0.85)
          .margin({ right: 2 })
          .scale({ x: this.speedPulse ? 1.1 : 1, y: this.speedPulse ? 1.1 : 1 })
          .animation({ duration: 250, curve: Curve.Sharp })
          .transition(this.gatedT(
            TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.EaseInOut })
              .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }).animation({ duration: 250, curve: Curve.EaseOut }))
          ))
        Text(this.speedText)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width(66)
          .maxLines(1)
          .textAlign(TextAlign.End)
          .transition(this.gatedT(
            TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.EaseInOut, delay: 40 })
              .combine(TransitionEffect.translate({ y: 6 }).animation({ duration: 250, curve: Curve.EaseOut, delay: 40 }))
          ))
      }
      .width(88)

      Text('·')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .opacity(0.5)
        .margin({ left: 5, right: 5 })

      Text(this.clockText)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .width(48)
        .maxLines(1)
        .textAlign(TextAlign.Center)
          .transition(this.gatedT(
            TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.EaseInOut, delay: 40 })
              .combine(TransitionEffect.translate({ y: 6 }).animation({ duration: 250, curve: Curve.EaseOut, delay: 40 }))
          ))

      Text('·')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .opacity(0.5)
        .margin({ left: 5, right: 5 })

      // 电量组（文本 + 图标，与网速组等宽 88vp，时间两侧均衡）
      Row() {
        Text(this.batteryText)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width(40)
          .maxLines(1)
          .textAlign(TextAlign.Start)
          .transition(this.gatedT(
            TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.EaseInOut, delay: 40 })
              .combine(TransitionEffect.translate({ y: 6 }).animation({ duration: 250, curve: Curve.EaseOut, delay: 40 }))
          ))
        Image($r(this.isCharging ? 'app.media.battery_charge14' : 'app.media.batteryfull_32'))
          .width(20)
          .height(20)
          .fillColor(this.isLowBattery ? '#FF5A5A' : this.isMediumBattery ? '#FFB300' : this.isCharging ? '#57C15A' : '#FFFFFF')
          .opacity(this.isLowBattery ? (this.blinkPhase ? 0.4 : 1)
            : this.isCharging ? (this.blinkPhase ? 0.75 : 1) : 0.85)
          .margin({ left: 2 })
          .animation({ duration: 500, curve: Curve.Linear })
          .transition(this.gatedT(
            TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.EaseInOut })
              .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }).animation({ duration: 250, curve: Curve.EaseOut }))
          ))
      }
      .width(88)
    }
    .position({ x: '50%', y: 3 })
    .translate({ x: '-50%' })
    .hitTestBehavior(HitTestMode.None)
  }

  // ⭐ 顶部状态（竖屏全屏）：时间·网速锚定左上角，电量锚定右上角
  @Builder
  topBarStatusLeft() {
    Row() {
      Text(this.clockText)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .width(48)
        .maxLines(1)
        .textAlign(TextAlign.Center)
        .transition(this.gatedT(
          TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.EaseInOut, delay: 40 })
            .combine(TransitionEffect.translate({ y: 6 }).animation({ duration: 250, curve: Curve.EaseOut, delay: 40 }))
        ))
      Text('·')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .opacity(0.5)
        .margin({ left: 5, right: 5 })
      // 网速（图标 + 定宽文本：右对齐→右侧稳定、数值变化向左生长）
      Image($r('app.media.heart_rate'))
        .width(20)
        .height(20)
        .fillColor('#FFFFFF')
        .opacity(0.85)
        .margin({ right: 2 })
        .scale({ x: this.speedPulse ? 1.1 : 1, y: this.speedPulse ? 1.1 : 1 })
        .animation({ duration: 250, curve: Curve.Sharp })
        .transition(this.gatedT(
          TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.EaseInOut })
            .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }).animation({ duration: 250, curve: Curve.EaseOut }))
        ))
      Text(this.speedText)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .width(66)
        .maxLines(1)
        .textAlign(TextAlign.End)
        .transition(this.gatedT(
          TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.EaseInOut, delay: 40 })
            .combine(TransitionEffect.translate({ y: 6 }).animation({ duration: 250, curve: Curve.EaseOut, delay: 40 }))
        ))
    }
    .alignItems(VerticalAlign.Center)
    .position({ x: 16, y: 10 })
    .hitTestBehavior(HitTestMode.None)
  }

  // ⭐ 顶部右侧状态：电量（仅横屏点播全屏显示，锚定右上角）
  @Builder
  topBarStatusRight() {
    Row() {
      Text(this.batteryText)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .width(40)
        .maxLines(1)
        .textAlign(TextAlign.Start)
        .transition(this.gatedT(
          TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.EaseInOut, delay: 40 })
            .combine(TransitionEffect.translate({ y: 6 }).animation({ duration: 250, curve: Curve.EaseOut, delay: 40 }))
        ))
        Image($r(this.isCharging ? 'app.media.battery_charge14' : 'app.media.batteryfull_32'))
        .width(20)
        .height(20)
        .fillColor(this.isLowBattery ? '#FF5A5A' : this.isMediumBattery ? '#FFB300' : this.isCharging ? '#57C15A' : '#FFFFFF')
        .opacity(this.isLowBattery ? (this.blinkPhase ? 0.4 : 1)
          : this.isCharging ? (this.blinkPhase ? 0.75 : 1) : 0.85)
        .margin({ left: 2 })
        .animation({ duration: 500, curve: Curve.Linear })
        .transition(this.gatedT(
          TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.EaseInOut })
            .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }).animation({ duration: 250, curve: Curve.EaseOut }))
        ))
    }
    .alignItems(VerticalAlign.Center)
    .position({ x: '100%', y: 10 })
    .translate({ x: '-100%' })
    .padding({ right: 16 })
    .hitTestBehavior(HitTestMode.None)
  }

  /** 横屏全屏判断：显示方向为竖屏时不显示状态条 */
  private isPortraitDisplay(): boolean {
    try {
      const d = display.getDefaultDisplaySync();
      return d.height > d.width;
    } catch (_) {
      return false;
    }
  }

  /** 标题变化：快速淡出后淡入（切集 crossfade） */
  private onVideoTitleChange() {
    this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseIn }, () => {
      this.titleFade = 0;
    });
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 280, curve: Curve.EaseInOut }, () => {
        this.titleFade = 1;
      });
    }, 160);
  }

  // ⭐ 挂载首帧禁用入场过渡：进/出全屏时控制栏全新挂载，重放 transition 会与全屏动画叠加产生闪烁
  private gatedT(effect: TransitionEffect): TransitionEffect {
    return this.controlsMounted ? effect : TransitionEffect.IDENTITY;
  }

  /**
   * 提示的**显隐动画**：只做淡入淡出（**尺寸变化交给"卷帘生长"**）。
   *
   * 2026-09-24 用户要求三种提示都改成"弹簧卷帘"（真实高度生长 + 弹性）⇒ 这里不再做 `scale`：
   * `scale` 会把内容一起拉伸（图标/文字被压扁，用户能看出差别），卷帘是裁切式的、内容不变形。
   * 于是分工：**尺寸 = `hintGrow` 卷帘**（seek / 长按），**竖条 = 弹层过渡 `edgePillTransition()`**
   * （材质 + 内容整体滑入），**可见度 = 本动画**。
   *
   * 入场 170ms 弹性淡入（与卷帘同一条 `springMotion`，同频读起来是一个动作）；
   * 出场 **200ms** `EaseIn` 淡出。
   *
   * ★★ 2026-09-24 二次修正（用户："音量/亮度竖条、seek 填充条、长按加速胶囊**都是只有显示动画，
   *    为什么没有消失时的动画？**"）—— 上一版出场是 **110ms 纯透明度**，且**一处位移/尺寸都没写**：
   *      · 入场是 170~300ms 的"卷帘生长 / 原地弹入 / 边缘滑入 + 回弹"，
   *        出场是 110ms 的纯淡出 ⇒ **时长只有入场的 1/2~1/3、幅度为零**；
   *      · 人眼对 100ms 量级的纯淡出基本无感 ⇒ 读起来就是"啪一下没了"，而不是"收起来了"。
   *    ⇒ 现在改成**入场动作的逆动作**：本函数只负责"弹层淡出"这一半（时长放宽到 200ms，
   *      要**盖住**内容侧的收缩动画，否则弹层先销毁、收缩被截断）；
   *      "卷帘收起"那一半由 `startHintCollapse()` 在隐藏那一刻驱动内容（hintGrow / holdPop）
   *      —— 与入场的"内容生长 + 弹层淡入"严格对称。
   *    ⚠️ 弹层出场时长 **200ms ≥ 内容收缩 180ms**（`startHintCollapse()`），改一个必须改另一个。
   * ⚠️ `gatedT()`：VideoControls 常驻挂载，首帧不能让几个提示各"演"一遍入场。
   */
  private hintTransition(): TransitionEffect {
    return this.gatedT(
      TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({ duration: 170, curve: curves.springMotion(0.3, 0.9) }),
        TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseIn })
      )
    );
  }

  /**
   * ⭐ 音量/亮度竖条的**边缘滑入 + 回弹**（方案 A，2026-09-24 二次修正）。
   *
   * ★ **为什么必须走弹层 transition，不能用内容层 `.translate()`**：
   *   玻璃是弹层材质、内容是我们自己画的。用内容 translate 时，玻璃在**弹层创建**那一刻就开始
   *   170ms 淡入，内容却要等**内容挂载**之后再滑 220ms —— 两条时间轴的起点与长度都不同 ⇒
   *   用户原话："**内外的动画好像不一致，而且太快了。好像沉浸光感不是滑进来的，是直接出现的**"
   *   （玻璃先到、只有内容在滑）。
   *   transition 是**弹层自身**的入场过渡：材质与内容在同一个节点、同一条时间轴上完成位移与淡入
   *   ⇒ 内外天然一致，且与"弹层何时创建"无关（由系统在入场统一驱动）。
   *
   * 回弹：`springMotion(0.36, 0.62)` —— 阻尼比 < 1 才有过冲（到位后越过约 8% 再弹回）。
   *   起点 56vp ⇒ 约 4.7vp。想更明显就加大 `edgeSlideDist()`（过冲位移与起点成正比）。
   * 时长 **300ms**（上一版内容滑入 220ms + 玻璃 170ms，用户反馈"太快了"）。
   * ⚠️ `TransitionEffect.translate` 的参照系就是**弹层自身**（不像 `scale` 需要显式 centerX/centerY ——
   *   那个坑的根因正是"参照系不是元素自己"），所以方向不会随布局变。
   * ⚠️ **出场 = 入场的逆动作**（2026-09-24 二次修正）：原路**滑回边缘**（同一位移量 `offset`）
   *   并同步淡出，200ms `EaseIn`（加速离开）。
   *   ★ 上一版出场是"**不带位移**、110ms 纯淡出"（当时的理由是"消失要利落，滑出去会和淡出打架"），
   *     用户反馈："都是只有显示动画，为什么没有消失时的动画？" —— 竖条**滑进来**却**原地消失**，
   *     观感就是"啪一下没了"：入场那 300ms 的位移在这边一点回声都没有。
   *   ⇒ 现在"从哪来回哪去"：`translate(offset)` 与入场同值、只换曲线与时长（300 → 200ms 稍短）。
   * ⚠️ 与 `hintTransition()` 一样过 `gatedT()`：挂载首帧不能让它自己演一遍入场。
   */
  private edgePillTransition(): TransitionEffect {
    const offset: number = this.edgeSlideDir() * this.edgeSlideDist();
    return this.gatedT(
      TransitionEffect.asymmetric(
        TransitionEffect.translate({ x: offset })
          .animation({ duration: 300, curve: curves.springMotion(0.36, 0.62) })
          .combine(TransitionEffect.OPACITY.animation({ duration: 300, curve: curves.springMotion(0.36, 0.9) })),
        TransitionEffect.translate({ x: offset })
          .animation({ duration: 200, curve: Curve.EaseIn })
          .combine(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseIn }))
      )
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ⭐ 音量/亮度竖条的「跨档脉冲」（2026-09-24 用户选定"方案 1 档位脉冲"，
  //   同日追加"描边脉冲" → 真机对比后改为**涟漪**）
  //   值每跨一个 10% 档位响一次，同一拍两个反馈：
  //     · 图标 `scale`  1 → 1.3 → 1（90ms 涨 + 260ms 弹性回落，见 playTickPulse）
  //     · 涟漪环        1 → 1.4 倍、同时淡出（420ms EaseOut，见 playEdgeRipple）
  //   ★ 与播放页**每跨 10% 的震动**（`fireHaptic(12)` + `lastHapticPct_`）同拍 ——
  //     用户同时拿到"看得到的"和"摸得到的"，手感最实。
  //   ⚠️ 涟漪刻意**不并进图标那个 animateTo**：它是**另一条时间轴的独立动作**（420ms 扩散淡出，
  //     与长按涟漪同一套参数）—— 本质是"放出去的一圈光"，不是图标脉冲的一半。
  // ══════════════════════════════════════════════════════════════════════════

  /** 图标脉冲峰值（1.3 = 放大 30%）：再大图标会顶到下面的数字，20vp 图标放大后 26vp，内圈宽 34 还放得下 */
  private iconPulseUp(): number {
    return 1.3;
  }

  /** 涟漪环终点缩放：竖条 46×140 ⇒ 1.4 倍 = 64×196（四边各漾开 9 / 28vp）。想更张扬就往上调 */
  private rippleEdgeUp(): number {
    return 1.4;
  }

  /** 涟漪环起点不透明度（跟长按涟漪的 0.5 同档；再高会在竖条边缘糊出一圈白边） */
  private rippleEdgeOStart(): number {
    return 0.5;
  }

  /** 一个 10% 档位对应的距离（vp）：判定只看"跨没跨过档位边界"，不看实际滑了多远 */
  private iconPulseStep(): number {
    return 10;
  }

  /** 当前值所在的档位号（0 = 0~9%，1 = 10~19%，…；10 = 100%） */
  private iconTickOf(p: number): number {
    return Math.floor(Math.round(p * 100) / this.iconPulseStep());
  }

  /**
   * ⭐ `gestureHintProgress` 的每次变化都会进这里（`@Watch` 挂在 @Link 上）——
   *   把"值在动"翻译成"跨档了就弹一下"。滑动时每个 move 事件都会触发，所以这里只做整数运算。
   *
   * 判定 = **档位号**是否变化（`iconTickOf`）而不是"累计滑了 10%"，理由：
   *   · 视觉上更规律 —— 10/20/30… 每个整点各响一次，用户能预期；
   *   · ⚠️ 与播放页的"累计 10%"**不完全等同**（19% → 21%：播放页不震、这里会弹）。
   *     刻意的取舍，注释在此备案，别当成 bug 去"对齐"。
   * ⚠️ 不在提示之外的场合动作：非贴边竖条（seek/长按）直接返回 —— 它们没有这个图标。
   */
  private onHintProgressTick(): void {
    if (!this.showGestureHint) return;
    if (!this.isEdgePill()) return;
    const p: number = this.gestureHintProgress;
    if (!(p >= 0)) return;
    const tick: number = this.iconTickOf(p);
    if (this.lastIconTick < 0) {
      this.lastIconTick = tick;   // 还没建立基线（正常不会走到：基线在显示那一刻就定了）
      return;
    }
    if (tick === this.lastIconTick) return;
    this.lastIconTick = tick;
    this.playTickPulse();
  }

  /**
   * 播一次跨档脉冲：图标 `1 → iconPulseUp() → 1`（90ms 涨 + 260ms 弹性回落），
   *   并在同一拍放出**涟漪环**（`playEdgeRipple()`：420ms 向外扩散淡出，独立时间轴）。
   *
   * ⚠️ **必须分帧**：同一帧内对同一个 @State 连赋两次只有最后一次生效（工程内既有结论）
   *   ⇒ "压回起点 / 涨到峰值 / 落回起点"三段靠 0ms + 90ms 两个定时器推到自己那一帧去
   *   （与 `playHoldRipple()` 同一套路）。0ms 那个是"下一帧"，不是"立刻"。
   * ⚠️ **上一拍没播完就忽略这一拍**（`pulseUntil` 时间戳守卫）：快速滑动时
   *   10% 一格可能只隔几十毫秒，若每次都掐掉重来，图标会一直停在"刚涨起来就被压回"
   *   的抽搐状态；让它把 350ms 播完，读起来反而是连贯的弹跳。
   *   ★ 这个 350ms 也顺带把**涟漪**的重复启动挡住了：涟漪 420ms，差值那 70ms 里旧环已淡到
   *   ≈0（EaseOut 前段掉得快）⇒ 新环从中心冒出时看不出接缝，不必再给涟漪单设守卫。
   *
   * 曲线：涨用 90ms `EaseOut`（短促"顶一下"，不是慢慢长出来）；
   *   落用 260ms `springMotion(0.3, 0.55)` —— 阻尼比 < 1 会**越过终点再弹回**，
   *   这一下过冲就是"回弹"的观感来源（与竖条滑入的 springMotion 同一个手法）。
   */
  private playTickPulse(): void {
    const now: number = Date.now();
    if (now < this.pulseUntil) return;
    this.pulseUntil = now + 350;
    // 起点（与下面两段同属"同一帧只能留最后一次赋值"的那条约束 ⇒ 起点必须在这一帧写全）
    this.iconPulse = 1;
    this.pulseTimer = setTimeout(() => {
      this.pulseTimer = -1;
      // ① 涨：图标弹起
      animateTo({ duration: 90, curve: Curve.EaseOut }, () => {
        this.iconPulse = this.iconPulseUp();
      });
      this.pulseTimer = setTimeout(() => {
        this.pulseTimer = -1;
        // ② 落：弹性回落（"回弹"的来源）
        animateTo({ duration: 260, curve: curves.springMotion(0.3, 0.55) }, () => {
          this.iconPulse = 1;
        });
      }, 90);
    }, 0);
    // ③ 涟漪环（与上面两条时间轴并行；它本来就是一个独立的"放出去的动作"）
    this.playEdgeRipple();
  }

  /**
   * ⭐ 放一圈涟漪（与长按涟漪 `playHoldRipple()` 同款）：从竖条轮廓向外扩到 `rippleEdgeUp()` 倍、
   *   同时淡到透明。
   *
   * ⚠️ 与 `playHoldRipple()` 一样**必须分帧**：起点（`rippleEdgeS = 1` / `rippleEdgeO = 起点值`）
   *   写在这一帧，`animateTo` 推到下一帧（0ms 定时器）—— 否则同帧赋值被合并 ⇒ 直接停在终态、
   *   看不到扩散过程。
   * ⚠️ 涟漪元素**常驻挂载**（在提示根 Stack 里，见 `edgePillRippleRing`），所以这里只驱动状态，
   *   不涉及挂载/卸载 —— 与"提示显隐"完全解耦。
   */
  private playEdgeRipple(): void {
    if (this.rippleEdgeTimer >= 0) {
      clearTimeout(this.rippleEdgeTimer);
      this.rippleEdgeTimer = -1;
    }
    this.rippleEdgeS = 1;
    this.rippleEdgeO = this.rippleEdgeOStart();
    this.rippleEdgeTimer = setTimeout(() => {
      this.rippleEdgeTimer = -1;
      animateTo({ duration: 420, curve: Curve.EaseOut }, () => {
        this.rippleEdgeS = this.rippleEdgeUp();
        this.rippleEdgeO = 0;
      });
    }, 0);
  }

  /**
   * 脉冲复位：清掉在跑的定时器、把图标系数与涟漪都压回静置态、放行连发守卫。
   * ⚠️ **不动 `lastIconTick`** —— 基线的建立/清除由 `syncHintPopups` 按"显示/隐藏"统一管
   *   （见那里的注释：基线要在显示那一刻用**当前值**定，否则第一次跨档会白白浪费掉）。
   */
  private resetTickPulse(): void {
    if (this.pulseTimer >= 0) {
      clearTimeout(this.pulseTimer);
      this.pulseTimer = -1;
    }
    if (this.rippleEdgeTimer >= 0) {
      clearTimeout(this.rippleEdgeTimer);
      this.rippleEdgeTimer = -1;
    }
    this.pulseUntil = 0;
    this.iconPulse = 1;
    // 涟漪回到"收缩到看不见"的静置态（opacity 0 ⇒ 位置/缩放取什么都无所谓）
    this.rippleEdgeS = 1;
    this.rippleEdgeO = 0;
  }

  /**
   * 数字翻转（NumericTextTransition）—— 拖动时数值"滚"上去，而不是硬跳一下。
   *
   * 官方约束（《文本组件公共接口》NumericTextTransition，@since 20）原文：
   *   「数字翻牌动效。仅限正整数，不支持小数和负数。不支持渐变色和 Text 跑马灯模式。
   *     不支持选中，copyOption 属性无效。当文本存在子组件时或通过属性字符串设置时，数字翻牌失效。」
   * ★ 真机实测（2026-09-16）：音量 / 亮度（`45`）**会**翻，seek 的 `1:02` **不翻** ——
   *   印证了"必须是正整数"这条：**冒号让它不再是一个正整数**。官方 Text API 页的示例18 也只演示了
   *   `Text(this.number + '')`（纯整数 @State），没有任何"含非数字字符"的用法。
   *   ⇒ 结论：想让 `m:ss` 翻牌，**必须先把它拆成纯数字的片段**
   *     （「分」「秒」各一个 Text + 冒号单独一个 Text），见下方 `hintTimeMin()` / `hintTimeSec()`
   *     与时间行的三个 Text。整串 `m:ss` 挂着是**静默无效**的（不报错、不留残影，就是不动）。
   *
   * 据此只给**纯数字**的文本挂载：
   *   - 音量 / 亮度百分比（`gestureHintMainText` 去掉 '%' 后是纯正整数）—— 实测会翻；
   *   - seek 目标时间的「分」与「秒」两个片段（拆分后各自都是纯数字）；
   *   - seek 右侧位移（`+11S` / `-10S` / `0S`）**故意不挂**：含正负号，而"负数不支持"是明文约束，
   *     大概率出现"前进会滚、后退硬跳"的不一致观感 —— 一致地不动，比不一致地动要好。
   *   - 分隔符冒号自己一个 Text 且**不挂**：它永不变化，没有可翻的内容。
   *
   * 刷新频率：提示文本最快也就秒级（m:ss）或个位级（百分比）变化，不会出现
   * "每帧重置翻牌动画导致数字长期发虚"的情况（这一点是数字翻牌最容易翻车的地方）。
   * enableBlur 保持默认 false：胶囊本身已有 backdropBlur，再叠数字模糊会发糊且白耗 GPU。
   */
  private numFlip(): ContentTransition {
    return new NumericTextTransition({ flipDirection: FlipDirection.DOWN, enableBlur: false });
  }

  /**
   * seek 目标时间的「分」片段（纯数字，可翻牌）。
   * `VideoPlayerPage.formatDuration()` 的实现是 `${min}:${sec.padStart(2,'0')}`，且分钟**不做 60 上限**
   * （3800s → `63:20`）—— 所以字符串**恒为"单冒号两段"**，不会出现 `h:mm:ss` 三段。
   * 因此按第一个冒号切分即可，无需处理多冒号。
   */
  private hintTimeMin(): string {
    const t: string = this.gestureHintMainText;
    const i: number = t.indexOf(':');
    return i >= 0 ? t.substring(0, i) : t;
  }

  /** seek 目标时间的「秒」片段（`padStart(2,'0')` 补零，如 `02`；补零不影响"是否全为数字"） */
  private hintTimeSec(): string {
    const t: string = this.gestureHintMainText;
    const i: number = t.indexOf(':');
    return i >= 0 ? t.substring(i + 1) : '';
  }

  aboutToAppear() {
    this.startStatusTimer();
    // 挂载完成后放行 transition（仅影响之后镜像切换、控制栏显隐等场景的过渡）
    setTimeout(() => {
      this.controlsMounted = true;
    }, 120);
  }

  aboutToDisappear() {
    this.stopStatusTimer();
  }

  // ═══ ⭐ 镜像布局：组内顺序反序 = 子项条件排列 + 间距两侧翻转（Row 确定性布局）═══

  // 顶部：后台播放按钮
  @Builder
  topBgButton() {
    Column() {
      Image($r(this.isBackgroundPlayback ? 'app.media.nosign' : 'app.media.headphones_fill'))
        .width(22)
        .height(22)
        .fillColor('#FFFFFF')
    }
    .alignItems(HorizontalAlign.Center)
    .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { left: 36 } : { right: 36 })
    .onClick(() => {
      this.toggleBackgroundPlayback();
    })
  }

  // 顶部：比例按钮
  @Builder
  topScaleButton() {
    Column() {
      Image($r('app.media.ic_desktop_servicewidgets'))
        .width(22)
        .height(22)
        .fillColor('#FFFFFF')
    }
    .alignItems(HorizontalAlign.Center)
    .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { left: 36 } : { right: 36 })
    .onClick(() => {
      this.showScaleOptions();
    })
  }

  // 顶部：更多按钮
  @Builder
  topMoreButton() {
    Column() {
      Image($r('app.media.navigation_more'))
        .width(22)
        .height(22)
        .fillColor('#FFFFFF')
    }
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.onMorePress();
    })
  }

  // UP主头像+名字胶囊（点击返回）
  @Builder
  upOwnerPill() {
    Row() {
      if (this.isMirrorControls && this.isFullscreen && !this.liveMode) {
        if (this.videoOwnerName !== '') {
          Text(this.videoOwnerName)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .margin({ right: this.videoOwnerFace !== '' ? 8 : 0 })
            .maxLines(1)
        }
        if (this.videoOwnerFace !== '') {
          Image(this.videoOwnerFace)
            .width(30)
            .height(30)
            .borderRadius(15)
            .objectFit(ImageFit.Cover)
        }
      } else {
        if (this.videoOwnerFace !== '') {
          Image(this.videoOwnerFace)
            .width(30)
            .height(30)
            .borderRadius(15)
            .objectFit(ImageFit.Cover)
        }
        if (this.videoOwnerName !== '') {
          Text(this.videoOwnerName)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .margin({ left: this.videoOwnerFace !== '' ? 8 : 0 })
            .maxLines(1)
        }
      }
    }
    .alignItems(VerticalAlign.Center)
    // 内部边距镜像翻转：标准「头像5·名字15」，镜像「名字5…」对应为头像距边5/名字距边15（反射对称）
    .padding(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { left: 15, right: 5, top: 4, bottom: 4 } : { left: 5, right: 15, top: 4, bottom: 4 })
    .borderRadius(19)
    .backgroundColor('rgba(0,0,0,0.4)')
    .onClick(() => {
      this.onBackPress();
    })
  }

  // 关注按钮（胶囊外圆形遮罩：已关注主题色、未关注半透明白）
  @Builder
  followButton() {
    Column() {
      Image($r('app.media.checkmark_circle_fill'))
        .width(26)
        .height(26)
        .fillColor(this.isFollowed ? this.followColor : 'rgba(255,255,255,0.45)')
    }
    .width(38)
    .height(38)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(19)
    .backgroundColor('rgba(0,0,0,0.4)')
    .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { right: 6 } : { left: 6 })
    .onClick(() => {
      this.toggleFollow();
    })
  }

  // ⭐ 上一集按钮（仅全屏且有上一集；图标为下一集水平翻转）
  @Builder
  btnPrev() {
    if (this.isFullscreen && this.hasPreviousEpisode) {
      Column() {
        Image($r('app.media.ic_public_play_next'))
          .width(24)
          .height(24)
          .scale({ x: -1, y: 1 })
          .fillColor('#FFFFFF')
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { left: 18 } : { right: 18 })
      .onClick(() => {
        this.togglePreviousEpisode();
      })
    }
  }

  // 播放/暂停按钮（点播模式）
  @Builder
  btnPlay() {
    Column() {
      Image(this.isPlaying ? $r('app.media.pause') : $r('app.media.ic_public_play'))
        .width(24)
        .height(24)
        .fillColor('#FFFFFF')
    }
    .width(40)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { left: 18 } : { right: 18 })
    .onClick(() => {
      this.togglePlayPause();
    })
  }

  // ⭐ 下一集按钮（仅全屏且有下一集）
  @Builder
  btnNext() {
    if (this.isFullscreen && this.hasNextEpisode) {
      Column() {
        Image($r('app.media.ic_public_play_next'))
          .width(24)
          .height(24)
          .fillColor('#FFFFFF')
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { left: 18 } : { right: 18 })
      .onClick(() => {
        this.toggleNextEpisode();
      })
    }
  }

  // 弹幕开关按钮
  @Builder
  btnDanmaku() {
    Column() {
      Image($r('app.media.chat_bubble_text_square_solid'))
        .width(24)
        .height(24)
        .fillColor(this.isDanmakuEnabled ? '#FFFFFF' : 'rgba(255,255,255,0.45)')
    }
    .width(40)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.toggleDanmaku();
    })
  }

  // ⭐ 发弹幕胶囊按钮（间距由胶囊单独承担：8+14+12=34vp 视觉间隙）
  @Builder
  btnDanmakuSend() {
    Column() {
      Row() {
        Image($r('app.media.danmfas'))
          .width(18)
          .height(18)
          .fillColor('#FFFFFF')
          .margin({ right: 5 })
        Text('发弹幕')
          .fontSize(12)
          .fontColor(Color.White)
      }
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor('rgba(255,255,255,0.18)')
    }
    .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { right: 14 } : { left: 14 })
    .onClick(() => {
      this.onDanmakuPress();
    })
  }

  // ▶▶ 倍速按钮（仅全屏点播）
  @Builder
  btnRate() {
    if (this.isFullscreen && !this.liveMode) {
      Column() {
        Text(this.playbackRate.toFixed(1) + 'x')
          .fontSize(12)
          .fontColor('#FFFFFF')
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { left: 18 } : { right: 18 })
      .onClick(() => {
        const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
        const currentIndex = rates.indexOf(this.playbackRate);
        const nextIndex = (currentIndex + 1) % rates.length;
        this.setPlaybackRate(rates[nextIndex]);
      })
    }
  }

  // HD 画质按钮（仅全屏点播）
  @Builder
  btnHd() {
    if (this.isFullscreen && !this.liveMode) {
      Column() {
        Image($r('app.media.hd_24px_rounded'))
          .width(24)
          .height(24)
          .fillColor('#FFFFFF')
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { left: 18 } : { right: 18 })
      .onClick(() => {
        this.showQualityOptions();
      })
    }
  }

  // 全屏评论浮层按钮（仅全屏点播）
  @Builder
  btnComment() {
    if (this.isFullscreen && !this.liveMode) {
      Column() {
                Image($r('app.media.message'))
          .width(24)
          .height(24)
          .fillColor('#FFFFFF')
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { left: 18 } : { right: 18 })
      .onClick(() => {
        this.onCommentPress();
      })
    }
  }

  // 选集按钮（仅全屏且有多集）
  @Builder
  btnEpisodes() {
    if (this.isFullscreen && this.hasMultipleEpisodes) {
      Column() {
        Image($r('app.media.externaldrive_fill_3'))
          .width(24)
          .height(24)
          .fillColor('#FFFFFF')
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { left: 18 } : { right: 18 })
      .onClick(() => {
        this.onEpisodePress();
      })
    }
  }

  // 全屏切换按钮
  @Builder
  btnFs() {
    if (!this.liveMode) {
      Column() {
        Image(this.isFullscreen ? $r('app.media.reduce_31') : $r('app.media.full_screen_32'))
          .width(24)
          .height(24)
          .fillColor('#FFFFFF')
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        this.toggleFullscreen();
      })
    }
  }

  // 顶部返回按钮：全屏点播时显示「头像+名字」胶囊（点击返回）+ 胶囊外关注按钮；无资料时回退为返回箭头
  @Builder
  topBarBackButton(slideFrom: number) {
    if (this.isFullscreen && !this.liveMode && (this.videoOwnerFace !== '' || this.videoOwnerName !== '')) {
      Row() {
        if (this.isMirrorControls && this.isFullscreen && !this.liveMode) {
          // ⭐ 镜像：内部顺序反序（关注 → 胶囊），胶囊内名字→头像
          this.followButton();
          this.upOwnerPill();
        } else {
          this.upOwnerPill();
          this.followButton();
        }
      }
      .height(48)
      // 边距 3/6：标准左缘 19+3=22；镜像右缘 16+6=22（反射对称）
      .padding({ left: 3, right: 6 })
      .alignItems(VerticalAlign.Center)
    .transition(this.gatedT(
      TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
        .combine(TransitionEffect.translate({ x: slideFrom }).animation({ duration: 300, curve: Curve.EaseInOut }))
    ))

    } else {
      Column() {
        Image($r('app.media.return_453'))
          .width(30)
          .height(30)
          .fillColor('#FFFFFF')
      }
      .width(48)
      .height(48)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        this.onBackPress();
      })
    }
  }

  // 顶部右侧按钮组（后台播放/比例/更多，仅点播全屏，纯图标）
  @Builder
  topBarRightButtons(slideFrom: number) {
    if (this.isFullscreen && !this.liveMode) {
      // 图标 22vp 宽、间距 36vp → 列心距 58vp，与底部右侧按钮列（40+18）对齐
      Row() {
        if (this.isMirrorControls && this.isFullscreen && !this.liveMode) {
          // ⭐ 镜像：组内顺序反序
          this.topMoreButton();
          this.topScaleButton();
          this.topBgButton();
        } else {
          this.topBgButton();
          this.topScaleButton();
          this.topMoreButton();
        }
      }
      .alignItems(VerticalAlign.Center)
      // 9vp：使「更多」图标右缘/列心与底部「全屏」按钮列对齐（16+9+11=36）；镜像时补左侧 3vp 保持 22vp 边距
      .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { left: 6, right: 9 } : { right: 9 })
    .transition(this.gatedT(
      TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
        .combine(TransitionEffect.translate({ x: slideFrom }).animation({ duration: 300, curve: Curve.EaseInOut }))
    ))

    }
  }

  // 底部左侧按钮组（点播：上一集/播放/下一集/弹幕开关/发弹幕；直播：LIVE 标识+在线人数/下一集）
  @Builder
  bottomLeftGroup(slideFrom: number) {
    // 播放、静音、弹幕按钮 - 点播模式
    if (!this.liveMode) {
      Row() {
        if (this.isMirrorControls && this.isFullscreen && !this.liveMode) {
          // ⭐ 镜像：组内顺序反序
          this.btnDanmakuSend();
          this.btnDanmaku();
          this.btnNext();
          this.btnPlay();
          this.btnPrev();
        } else {
          this.btnPrev();
          this.btnPlay();
          this.btnNext();
          this.btnDanmaku();
          this.btnDanmakuSend();
        }
      }
      .height(40)
      .padding({ left: 4, right: 4 })
      .alignItems(VerticalAlign.Center)
      // ⭐ 补偿图标矢量左侧空隙：图标左缘与时间/进度条对齐；镜像后改为补偿右侧
      .margin(this.isMirrorControls && this.isFullscreen && !this.liveMode ? { right: -6 } : { left: -6 })
    .transition(this.gatedT(
      TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
        .combine(TransitionEffect.translate({ x: slideFrom }).animation({ duration: 300, curve: Curve.EaseInOut }))
    ))

    }

    // 直播模式：LIVE 标识 + 在线人数
    if (this.liveMode) {
      Row() {
        Row({ space: 6 }) {
          Circle().width(8).height(8).fill('#FF3333')
          Text('LIVE')
            .fontSize(13).fontColor(Color.White).fontWeight(FontWeight.Bold)
          if (this.liveOnline > 0) {
            Text(`${this.liveOnline}`)
              .fontSize(12).fontColor('#FF9999')
          }
        }
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })

        // 下一集按钮（有下一集时显示）
        if (this.hasNextEpisode) {
          Column() {
            Image($r('app.media.ic_public_play_next'))
              .width(24)
              .height(24)
              .fillColor('#FFFFFF')
          }
          .width(40)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {
            this.toggleNextEpisode();
          })
        }
      }
      .alignItems(VerticalAlign.Center)
    }
  }

  // 底部右侧按钮组（倍速/画质/选集/全屏；grouped=true 时包一层 Row，镜像对调时保持组内紧凑）
  @Builder
  bottomRightGroup(grouped: boolean, slideFrom: number) {
    if (grouped) {
      Row() {
        Blank()
        if (this.isMirrorControls && this.isFullscreen && !this.liveMode) {
          // ⭐ 镜像：组内顺序反序
          this.btnFs();
          this.btnEpisodes();

          this.btnHd();
          this.btnRate();
        } else {
        this.btnRate();
        this.btnHd();
        this.btnEpisodes();
        this.btnFs();
        }
      }
      .height(42)
      .alignItems(VerticalAlign.Center)
    .transition(this.gatedT(
      TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
        .combine(TransitionEffect.translate({ x: slideFrom }).animation({ duration: 300, curve: Curve.EaseInOut }))
    ))
    } else {
      Row() {
        if (this.isFullscreen && !this.liveMode) {
          Blank()
          this.btnRate();
        } else if (!this.liveMode) {
          Blank()
        }
        this.btnHd();

        this.btnEpisodes();
        this.btnFs();
      }
      .alignItems(VerticalAlign.Center)
    .transition(this.gatedT(
      TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
        .combine(TransitionEffect.translate({ x: slideFrom }).animation({ duration: 300, curve: Curve.EaseInOut }))
    ))
    }
  }

  // ⭐ 侧边按钮组（镜像切换 + 锁定/解锁）：'left'/'right' 决定贴边方向，左右对称
  // 切换+锁定为一个整体（固定 92vp 高），组合中心对齐屏幕中心；切换按钮隐藏时槽位留空，锁定按钮不跳动
  @Builder
  sideButtons(side: string) {
    if (this.isFullscreen) {
      Column({ space: 12 }) {
        // 切换按钮槽位（恒定 40 高；隐藏时保留占位，Transparent 不拦截手势）
        Column() {
          if (this.isControlsVisible && !this.liveMode) {
            Column() {
              Image($r('app.media.ic_gallery_collage'))
                .width(24)
                .height(24)
                .fillColor('#FFFFFF')
                .rotate({ angle: this.mirrorIconAngle })
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .width(40)
            .height(40)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.85 })
            .transition(this.gatedT(
      TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
        .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }).animation({ duration: 300, curve: Curve.EaseInOut }))
    ))

            .onClick(() => {
              // ⭐ 先通知播放页取消延迟隐藏并持久化，再切状态（animateTo 让四组按钮滑移过渡）
              this.onMirrorToggle();
              this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
                this.mirrorIconAngle += 180;
                this.isMirrorControls = !this.isMirrorControls;
              });
            })
          }
        }
        .width(40)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)

        // 第二槽位（恒定 40 高；隐藏时保留占位，Transparent 不拦截手势——组高保持 92，整组不位移）
        Column() {
          if ((side === 'right') !== (this.isMirrorControls && !this.liveMode)) {
            // 右侧：评论按钮（全屏点播，控制栏可见时显示）
            if (this.isControlsVisible && !this.liveMode) {
              Column() {
        Image($r('app.media.message'))
                  .width(24)
                  .height(24)
                  .fillColor('#FFFFFF')
              }
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .width(40)
              .height(40)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.85 })
              .transition(this.gatedT(
      TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut, delay: 60 })
        .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }).animation({ duration: 300, curve: Curve.EaseInOut, delay: 60 }))
    ))
              .hitTestBehavior(HitTestMode.Default)
              .onClick(() => {
                this.onCommentPress();
              })
            }
          } else {
            // 左侧：锁定/解锁按钮 - 形态融合动画
            // 圆形(🔓) ↔ 圆角矩形([🔓 解锁]) 平滑过渡
            if (this.isFullscreen && ((!this.isLocked && this.isControlsVisible) || (this.isLocked && this.showUnlockButton))) {
              Column() {
                Image(this.isLocked ? $r('app.media.ic_public_lock') : $r('app.media.ic_public_unlock'))
                  .width(24)
                  .height(24)
                  .fillColor('#FFFFFF')
              }
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .width(40)
              .height(40)
              .animation({
                duration: 400,
                curve: Curve.Friction
              })
              .scale({ x: this.lockPulse, y: this.lockPulse })
              .transition(this.gatedT(
      TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut, delay: 60 })
        .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }).animation({ duration: 300, curve: Curve.EaseInOut, delay: 60 }))
    ))
              .hitTestBehavior(HitTestMode.Default)
              .onClick(() => {
                this.lockPulse = this.lockPulse === 1 ? 1.15 : 1;
                this.toggleLock();
              })
            }
          }
        }
        .width(40)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .position({ x: side === 'left' ? 0 : '100%', y: '50%' })
      .transition(this.gatedT(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })))
      // 组合（92vp 高）中心对齐屏幕中心：y 上移自身一半高度；切换中心 50%-26、锁定中心 50%+26，间距 12
      // x：右侧 -76、左侧 +36，两边距屏幕边缘均 36vp（右侧 100%-76-40 → 36）
      .translate({ x: side === 'left' ? 36 : -76, y: '-50%' })
    }
  }

  build() {
    Stack() {
      // 主控制层：条件渲染，隐藏时不再拦截触摸事件
      if (this.isControlsVisible) {
        Column() {
          // 顶部控制栏（全屏/直播均显示）：Stack 使状态条水平居中不受两侧按钮宽度影响
          if (this.isFullscreen || this.liveMode) {
            Stack() {
              Row() {
                if (this.isMirrorControls && this.isFullscreen && !this.liveMode) {
                  // ⭐ 镜像布局：右侧按钮组对调到左侧，返回按钮到右侧（组内顺序不变）
                  this.topBarRightButtons(45);
                  Blank()
                  this.topBarBackButton(-45);
                } else {
                  this.topBarBackButton(45);

                  // 直播模式：LIVE 标识 + 直播间信息
                  if (this.liveMode) {
                    Column({ space: 2 }) {
                      Row({ space: 6 }) {
                        Circle().width(8).height(8).fill('#FF3333')
                        Text('LIVE')
                          .fontSize(13).fontColor(Color.White).fontWeight(FontWeight.Bold)
                      }
                      Text(this.liveTitle)
                        .fontSize(15).fontColor(Color.White).fontWeight(FontWeight.Medium)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .margin({ left: 12 })
                    .layoutWeight(1)
                  }

                  if (!this.liveMode) {
                    Blank()
                  }

                  // 后台播放/比例/更多按钮组（仅点播全屏，纯图标）
                  this.topBarRightButtons(-45);
                }
              }
              .width('100%')
              .padding({ left: 19, right: 16, top: 20 + this.statusBarHeight })
              .alignItems(VerticalAlign.Center)
              .onAreaChange((_oldArea: Area, newArea: Area) => {
                // 忽略 0 宽等无效测量（重渲染期间可能回传），避免状态栏被误隐藏
                const w = Number(newArea.width);
                if (w > 0) {
                  this.topBarWidth = w;
                }
                // 顶栏实测高度（vp）写入 AppStorage：播放页据此限定顶部触摸保护范围（横屏/竖屏/密度自适应）
                // ⭐ 节流：仅变化超过 1vp 才写入，避免旋转/重渲染期间高频触发播放页侧刷新
                const h = Number(newArea.height);
                if (h > 0 && Math.abs(h - this.lastTopBarHeight) > 1) {
                  this.lastTopBarHeight = h;
                  AppStorage.setOrCreate('fullscreenTopBarHeight', h);
                }
              })
              // ⭐ 吞掉顶栏区域触摸，防止命中测试异常时穿透到视频层触发「单击隐藏控制栏」
              .onTouch(() => {
              })
              .linearGradient({
                direction: GradientDirection.Bottom,
                colors: [['rgba(0,0,0,0.7)', 0], ['rgba(0,0,0,0)', 1]]
              })

              // 状态条：横屏全屏→居中显示；竖屏全屏→网速·时间左上角、电量右上角
              if (!this.liveMode) {
                if (this.isPortraitDisplay()) {
                  this.topBarStatusLeft();
                  this.topBarStatusRight();
                } else if (this.topBarWidth > 600) {
                  this.topBarStatusInfo();
                }
              }
            }
          }

          // ⭐ 非全屏（竖屏）左上角「返回首页」+ 右上角「更多」按钮
          if (!this.isFullscreen && !this.liveMode) {
            Row() {
              Column() {
                Image($r('app.media.backtohome_page'))
                  .width(24)
                  .height(24)
                  .fillColor('#FFFFFF')
              }
              .width(40)
              .height(40)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .transition(this.gatedT(
                TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
                  .combine(TransitionEffect.translate({ x: 24 }).animation({ duration: 300, curve: Curve.EaseInOut }))
              ))
              .onClick(() => {
                this.onHomePress();
              })
              Blank()
              Column() {
                Image($r('app.media.navigation_more'))
                  .width(24)
                  .height(24)
                  .fillColor('#FFFFFF')
              }
              .width(40)
              .height(40)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .transition(this.gatedT(
                TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
                  .combine(TransitionEffect.translate({ x: -24 }).animation({ duration: 300, curve: Curve.EaseInOut }))
              ))
              .onClick(() => {
                this.onMorePress();
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 10 })
            .linearGradient({
              direction: GradientDirection.Bottom,
              colors: [['rgba(0,0,0,0.7)', 0], ['rgba(0,0,0,0.3)', 0.5], ['rgba(0,0,0,0)', 1]]
            })
          }

          Blank().layoutWeight(1)

          // 底部控制栏
          Column() {
            // 进度条区域（仅点播显示）
            if (!this.liveMode) {
              // 视频名称：仅全屏显示，位于进度条上方（独占一行，不与进度条重叠）
              if (this.isFullscreen && this.videoTitle !== '') {
                Text(this.videoTitle)
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .height(14)
                  .width('100%')
                  .padding({ left: 37 })
                  .margin({ bottom: 8 })
                  .textAlign(TextAlign.Start)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .opacity(this.titleFade)
                  .marqueeOptions({ start: true, step: 4 })
                  .transition(this.gatedT(
                    TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
                      .combine(TransitionEffect.translate({ y: 8 }).animation({ duration: 300, curve: Curve.EaseInOut }))
                  ))
              }

              // 时间显示：当前时间在进度条左侧、总时长在右侧
              // 两侧定宽槽位（50vp）使进度条始终居中，间距左右对称
              Stack() {
              Row() {
                // 当前播放时间（左侧，右对齐贴住进度条）
                Text(this.formatTime(this.currentTime))
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .width(50)
                  .textAlign(TextAlign.End)
                  .maxLines(1)

                // 进度条滑块
                Slider({
                  value: this.currentTime,
                  min: 0,
                  max: this.duration > 0 ? this.duration : 100,
                  step: 1,
                  style: SliderStyle.OutSet
                })
                  .layoutWeight(1)
                  // ⭐ 轨道自带不对称缩进（左~14vp/右~7vp）：右侧 margin 多 7vp 补偿，使时间与轨道间距两侧一致
                  .margin({ left: 8, right: 15 })
                  // ⭐ 非全屏：默认只显示已播放部分，拖动/点击调节时显示未播放轨道；全屏始终显示
                  .trackColor(this.isFullscreen || this.seekTrackVisible ? '#4DFFFFFF' : Color.Transparent)
                  .selectedColor('#FFFFFF')
                  // ⭐ 滑块改为"调节时可见"：原先恒为 Transparent，静止状态下没有任何可抓取的视觉锚点
                  .blockColor(this.seekTrackVisible ? '#FFFFFF' : Color.Transparent)
                  // ⭐ 轨道粗细用 trackThickness 控制（height 只定组件高，轨道默认厚度是主题值，不随 height 变）
                  // ⭐ 触摸热区：**Slider 不支持 responseRegion**（官方 slider.d.ts 明确
                  //   "All the universal attributes except responseRegion are supported"），
                  //   所以唯一有效的办法是把 Slider 自身的布局盒撑高 —— 命中判定用的就是这个盒子。
                  //   OutSet 样式下轨道/滑块在盒内垂直居中，抬高 height 不会移动轨道视觉位置。
                  //   原先 height=20：手指容易落在 20vp 带外、反而命中视频区触发"单击隐藏控制栏"，
                  //   这是"点进度条不准/点不中"的高频原因。
                  .height(44)
                  .trackThickness(this.isFullscreen ? (this.seekTrackVisible ? 5 : 4) : (this.seekTrackVisible ? 4 : 3))
                  .onChange((value: number, mode: SliderChangeMode) => {
                    // ⭐ 交互上报必须**先于** currentTime 赋值：页面以"上报时刻的 ct"作为拖动锚点，
                    //   若先改 currentTime，锚点就变成了新值，页面会判成"位置没变"而吞掉提交。
                    // ⭐ 提交点选在 onChange 的 End/Click，而不是 onTouch 的 Up。
                    //   ⚠️ 真机实测（hilog）事件序列，点击滑轨时为：
                    //     onChange(Begin, 新值) → onTouch(Down) → onChange(Click) → onChange(End) → onTouch(Up)
                    //   两个反直觉点：
                    //     1) **Begin 早于 Down**，且 Begin 的 value 已经是跳转后的新值 ——
                    //        所以"按下时记锚点"必然把锚点记成目标值，位移判定为 0，提交被吞（旧实现即败于此）；
                    //     2) Click 与 End 连续触发且值相同，必须去重，否则一次点击提交两次 seek。
                    const interacting = mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving;
                    this.onSeekBarInteract(interacting, value);
                    // 跟随数值更新显示。
                    // ⭐ 点击滑轨保留原有的"平滑滑到位"观感：Slider 的 value 绑在 currentTime 上，
                    //   在 animateTo 里改它能让滑块/轨道滑过去而不是瞬跳
                    //   （文字内容不是可动画属性，所以时间文案仍是即时跳到目标值）。
                    if (mode === SliderChangeMode.Click) {
                      this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
                        this.currentTime = value;
                      });
                    } else {
                      this.currentTime = value;
                    }
                    // 非全屏：拖动/点击中显示轨道（厚度随之平滑过渡），松开后隐藏
                    if (!this.isFullscreen) {
                      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
                        this.seekTrackVisible = interacting;
                      });
                    }
                  })
                  // ⭐ 进度条交互**兜底**入口：只处理"交互被系统取消"（来电/多任务/父容器抢事件）。
                  //   ⚠️ 这里**不能**用 stopPropagation：实测发现它会把 Slider 自身的 click-jump 一起打断
                  //      （点击滑轨完全无反应），而它本来也拦不住父节点的手势对象 ——
                  //      官方明确"终止冒泡并不会中断父组件对手势的响应处理"。
                  //      父级手势的互斥已由页面侧 sliderDragging_ 守卫解决，不需要这一层。
                  .onTouch((e: TouchEvent) => {
                    if (e.type === TouchType.Cancel) {
                      this.onSeekBarInteract(false, this.currentTime);
                    }
                  })

                // 总时长（右侧，左对齐贴住进度条）
                Text(this.formatTime(this.duration))
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .width(50)
                  .textAlign(TextAlign.Start)
                  .maxLines(1)
              }
              .width('100%')
              // ⭐ 与内部 Slider 的 44vp 触摸热区等高：若这里仍是 20vp，Slider 会溢出父行，
              //   在非全屏下溢出部分压到下方按钮行顶部（抢点击）；等高后热区完整落在行内
              .height(44)
              .justifyContent(FlexAlign.SpaceBetween)
              .alignItems(VerticalAlign.Center)
              .padding({ left: 16, right: 16 })
              .transition(this.gatedT(
                TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
                  .combine(TransitionEffect.translate({ y: 8 }).animation({ duration: 300, curve: Curve.EaseInOut }))
              ))
              }
              .width('100%')
            }

            // 底部控制按钮行
            Row() {
              if (this.isMirrorControls && this.isFullscreen && !this.liveMode) {
                // ⭐ 镜像布局：左右按钮组整体对调（组内顺序不变）
                this.bottomRightGroup(true, 45);
                this.bottomLeftGroup(-45);
              } else {
                this.bottomLeftGroup(45);
                this.bottomRightGroup(false, -45);
              }
            }
            .width('100%')
            .height(42)
            .padding({ left: 16, right: 16 })
            .justifyContent(FlexAlign.SpaceBetween)
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding({ bottom: 10 })
          .linearGradient({
            direction: GradientDirection.Top,
            colors: [['rgba(0,0,0,0.7)', 0], ['rgba(0,0,0,0.3)', 0.5], ['rgba(0,0,0,0)', 1]]
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .transition(this.gatedT(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })))
      }

      // ⭐ 侧边按钮组（镜像切换 + 锁定/解锁）：左右两侧对称各一份，'left'/'right' 决定贴边方向
      this.sideButtons('right');
      this.sideButtons('left');

      if (this.hintUsePopup) {
        // ⭐ 手势提示胶囊（seek/音量/亮度）——沉浸光感 bindPopup 通道（仅材质可用设备走这里）：
        //   CustomPopupOptions.systemMaterial 自 API 26.0.0 起支持，popup 属弹层作用域，
        //   真材质可用（与已真机验证的 bindSheet 通道同族）。官方示例的按钮通道
        //   （attributeModifier + ImmersiveMaterial）实际传 canUseUIMaterial:false，
        //   官方自己也没在内容区挂真材质 —— 内容区三条路全部走不通，弹层是唯一出路。
        //   锚点：常驻 1vp 透明点（不可 if 挂载，popup 显隐由 pillPopupVisible 状态驱动）；
        //   mask:false 不挡手势，placement Bottom = 胶囊悬在锚点正下方、水平居中。
        //   ⚠️ 弹层的显隐动画由我们自己给：`CustomPopupOptions.transition`（该字段 @since 12，
        //      不设则用系统默认过渡 —— 这就是之前"新机提示像硬出现"的原因）。
        //   ⛔⛔ **四个弹层都必须把 `onWillDismiss` 写成"函数形式"，把返回转交页面**
        //      （2026-09-24 两轮真机 hilog 实证；前一版错误地写成 `onWillDismiss: false`）：
        //      · 现象：提示显示时按返回键/系统侧滑返回，**页面 `onBackPress()` 根本没跑**
        //        （该退全屏的没退、该返回的没返回）⇒ 用户要按两次返回。
        //      · 第一轮日志（当时 onWillDismiss 是默认值 true）：
        //          `49.474 OnBackPressed called` → `49.475 hide popup enter, targetId: 763`
        //          → `49.476 Overlay consumed backpressed event`
        //        —— 弹层在返回后 **1ms 就自己关了**，说明**弹层确实拿到了这次返回事件**。
        //        官方架构指南《侧滑无法关闭弹窗》把 `OnBackPressed called` +
        //        `Overlay consumed backpressed event` 明确列为"返回被弹窗叠加层消费"的判据
        //        （另一种正常形态是 `router user onBackPress return true`，二者互斥）。
        //      · ⚠️ 第二轮改成 `onWillDismiss: false` **无效**：该字段只管"弹层要不要自己关"
        //        （实测：`hide popup` 不再由返回触发、改由我们自己 800ms 定时器收 ⇒ 字段生效了），
        //        但事件**仍然被 Overlay 消费** —— `onWillDismiss` 挡的是"自动关闭"，
        //        挡不住"事件进入 Overlay 路由"。用户反馈："还是不行。"
        //      · ✅ 正解 = **函数形式**（SDK 原文 common.d.ts 14230-14238）：
        //          "If this parameter is set to a function, the dismissal event is intercepted
        //           and the callback function is executed. For swipes, back button, route
        //           navigation, and the Esc key, the value of `reason` returned in the callback
        //           function is **PRESS_BACK**."
        //        ⇒ 弹层拿到返回后**通知我们**，我们再把返回语义转交给页面（`onOverlayBack`），
        //          链路就是文档保证的那条，不依赖任何猜测。
        //      · ⚠️ 回调里**绝不能调 `action.dismiss()`**：弹层显隐完全由 `syncHintPopups()`
        //        的状态驱动，一旦被框架关掉而状态仍是 true，下次同一状态显示不出来
        //        （"常量 true 不重评"同一个坑）。
        //      · ⚠️ `autoCancel: false` / `mask: false` 与返回键是**两条路径**，管不到返回。
        //      · 📌 "6.1 好像没这个问题"的真相：6.1 走的是**内联渲染**通道（没有弹层），
        //        所以逐字没有该问题 —— 根因不是沉浸光感材质本身，而是"沉浸光感只能靠弹层承载"
        //        这条链把提示推到了窗口根 Overlay 层。
        Column()
          .width(1)
          .height(1)
          // ⭐ y 由 seekAnchorY() 算：屏幕 30% 处，再按缩略图生长量上移半个增量 ——
          //   否则"拖到一半图才到"的长出过程会让卡片中心比"一开始就有图"低 58vp
          .position({ x: '50%', y: this.seekAnchorY() })
          .hitTestBehavior(HitTestMode.None)
          .bindPopup(this.pillPopupVisible, {
            builder: (): void => { this.gesturePillBuilder(); },
            placement: Placement.Bottom,
            // ⭐ 用**显示瞬间冻结**的偏移（= −结构高度/2）：卷帘期间恒定 ⇒ 面板顶边不动 ⇒
            //   只会自上而下拉开；缩略图晚到时锚点才用 hintRise() 补偿（见 hintOffsetY）。
            offset: { x: 0, y: this.hintOffsetY },
            enableArrow: false,
            autoCancel: false,
            mask: false,
            // ⛔ 纯装饰弹层：不响应点击/滑动关闭，但**返回必须转交页面**（见本块上方长注释）
            //   ⚠️ 不调 action.dismiss()：显隐由状态驱动，被框架关掉会与 @State 失步
            onWillDismiss: (action: DismissPopupAction): void => {
              if (action.reason === DismissReason.PRESS_BACK) { this.onOverlayBack(); }
            },
            radius: this.hintRadius(),
            // ⭐ 显隐动画：淡入淡出（尺寸生长由"卷帘"负责，见 hintGrow）
            transition: this.hintTransition(),
            colorMode: AnchoredColorMode.FOLLOW_TARGET,
            systemMaterial: MaterialUtil.pillMaterial(),
          } as CustomPopupOptions)

        // ⭐ 音量竖条（贴播放器**左**侧）
        //   音量手势发生在右半屏 ⇒ 竖条落在手指反侧才不会被手掌挡住。
        //   锚点位置 = 面板中心该在的位置（edgeAnchorX），offset.x = 0 ——
        //   ⚠️ 不要用 offset.x 做横向位移：实测它在窗口边缘会被系统再推一次（见 edgeAnchorX 注释）。
        Column()
          .width(1)
          .height(1)
          .position({ x: this.edgeAnchorX(true), y: this.edgeAnchorY() })
          .hitTestBehavior(HitTestMode.None)
          .bindPopup(this.volPopupVisible, {
            builder: (): void => { this.edgePillInner(); },
            placement: Placement.Bottom,
            offset: { x: 0, y: this.hintOffsetY },
            enableArrow: false,
            autoCancel: false,
            mask: false,
            // ⛔ 纯装饰弹层：不响应点击/滑动关闭，但**返回必须转交页面**（见本块上方长注释）
            //   ⚠️ 不调 action.dismiss()：显隐由状态驱动，被框架关掉会与 @State 失步
            onWillDismiss: (action: DismissPopupAction): void => {
              if (action.reason === DismissReason.PRESS_BACK) { this.onOverlayBack(); }
            },
            radius: this.edgePillRadius(),
            // ⭐ 显隐动画：**弹层整体**横向"边缘滑入 + 回弹"（材质与内容同一条时间轴，见 edgePillTransition）
            transition: this.edgePillTransition(),
            colorMode: AnchoredColorMode.FOLLOW_TARGET,
            systemMaterial: MaterialUtil.pillMaterial(),
          } as CustomPopupOptions)

        // ⭐ 亮度竖条（贴播放器**右**侧）
        //   亮度手势发生在左半屏 ⇒ 竖条贴右，同理（x 由 vcW 实测宽算出，不再用 '100%'）。
        Column()
          .width(1)
          .height(1)
          .position({ x: this.edgeAnchorX(false), y: this.edgeAnchorY() })
          .hitTestBehavior(HitTestMode.None)
          .bindPopup(this.brightPopupVisible, {
            builder: (): void => { this.edgePillInner(); },
            placement: Placement.Bottom,
            offset: { x: 0, y: this.hintOffsetY },
            enableArrow: false,
            autoCancel: false,
            mask: false,
            // ⛔ 纯装饰弹层：不响应点击/滑动关闭，但**返回必须转交页面**（见本块上方长注释）
            //   ⚠️ 不调 action.dismiss()：显隐由状态驱动，被框架关掉会与 @State 失步
            onWillDismiss: (action: DismissPopupAction): void => {
              if (action.reason === DismissReason.PRESS_BACK) { this.onOverlayBack(); }
            },
            radius: this.edgePillRadius(),
            // ⭐ 显隐动画：**弹层整体**横向"边缘滑入 + 回弹"（材质与内容同一条时间轴，见 edgePillTransition）
            transition: this.edgePillTransition(),
            colorMode: AnchoredColorMode.FOLLOW_TARGET,
            systemMaterial: MaterialUtil.pillMaterial(),
          } as CustomPopupOptions)

        // ⭐ 长按加速胶囊（同通道，锚点更靠上，radius 18）
        Column()
          .width(1)
          .height(1)
          .position({ x: '50%', y: this.holdAnchorY() })
          .hitTestBehavior(HitTestMode.None)
          .bindPopup(this.holdPopupVisible, {
            builder: (): void => { this.holdPillBuilder(); },
            placement: Placement.Bottom,
            offset: { x: 0, y: this.hintOffsetY },
            enableArrow: false,
            autoCancel: false,
            mask: false,
            // ⛔ 纯装饰弹层：不响应点击/滑动关闭，但**返回必须转交页面**（见本块上方长注释）
            //   ⚠️ 不调 action.dismiss()：显隐由状态驱动，被框架关掉会与 @State 失步
            onWillDismiss: (action: DismissPopupAction): void => {
              if (action.reason === DismissReason.PRESS_BACK) { this.onOverlayBack(); }
            },
            radius: 18,
            // ⭐ 显隐 = 淡入淡出（弹层自己不做 scale：它的缩放参照系不是胶囊，方向会随布局乱 —— 见 startHoldPop）；
            //   真正的"原地弹入"由 holdPillShell 的尺寸 + 内容 scale + 锚点补偿完成
            transition: this.hintTransition(),
            colorMode: AnchoredColorMode.FOLLOW_TARGET,
            systemMaterial: MaterialUtil.pillMaterial(),
          } as CustomPopupOptions)

        // ⭐ 长按涟漪描边（常驻，弹层之外；与胶囊中心重合）
        this.holdRippleRing(this.hintPopPadV());

        // ⭐ 音量/亮度竖条的**涟漪环**（常驻在弹层之外；位置与竖条同源 ⇒ 永远重合）
        //   · `atTopLeft = false`：popup 通道的锚点是 1vp 的点、面板中心比锚点低 `hintPopPadV()`，
        //     所以外层负责"居中于锚点"、内层 translate 补那个常量（见 edgePillRippleRing 的注释）。
        //   · 只做一个常驻实例、靠 `gestureHintType` 决定贴哪边：类型切换时它会瞬移，但那一刻
        //     必然是"涟漪静息"（opacity 0）—— 播放器不可能在手势中途把涟漪留在半透明状态。
        //   ⛔ 这里**只传常量**：位置在 builder 体内算（传进来的值不刷新 —— 见 builder 上的长注释）
        this.edgePillRippleRing(false);
      } else {
        // ⭐ 老设备（不支持沉浸光感）：回到原来的内联条件渲染，不走 bindPopup
        //   （6.1 老系统解析 26.0.0 新增弹层字段会打挂整个 VideoControls 子树）
        // ── seek 胶囊（内联通道，居中） ──
        if (this.showGestureHint && this.gestureHintMainText && this.gestureHintType === 'seek') {
          // 外层只负责定位；材质与圆角交给 ImmersiveLightWrapper（与直播页分类胶囊同一套）
          Column() {
            ImmersiveLightWrapper({
              radius: this.hintRadius(),
              materialStyle: 0,
              fallbackColor: '#66000000',
              enableLight: false
            }) {
              // ⭐ 与 popup 通道**共用** seekCard（含整卡卷帘外壳，红线 9），不再各写一份
              this.seekCard();
            }
          }
          // ⭐ 顶边固定：位置给"卡片顶边该在的地方"，**不再用 translate(-50%) 居中**
          //   （translate 相对自身尺寸 ⇒ 高度越长越往上顶 = 上下对开，正是"方向时对时错"的根源）
          .position({ x: '50%', y: this.legacyHintTopY(0.30) })
          .translate({ x: '-50%' })
          .transition(this.hintTransition())
        }

        // ── 音量/亮度竖条（内联通道，贴边 + 落在手指反侧） ──
        //   内容与 popup 通道同款（edgePillInner：46×140 全圆竖条、内缩 6vp 的半透明填充、
        //   无轨道底条），外壳换成 ImmersiveLightWrapper 的磨砂降级；
        //   这里是**组件自身定位**（不是 1vp 锚点），左缘 = edgeMargin /（容器宽 - 边距 - 竖条宽）。
        if (this.showGestureHint && this.gestureHintMainText && this.isEdgePill()) {
          Column() {
            ImmersiveLightWrapper({
              radius: this.edgePillRadius(),
              materialStyle: 0,
              fallbackColor: '#66000000',
              enableLight: false
            }) {
              this.edgePillInner();
            }
          }
          // 同上：顶边固定（竖条没有缩略图 ⇒ hintRise 恒 0，位置完全恒定）
          .position({ x: this.edgeLegacyAnchorX(), y: this.legacyHintTopY(0.50) })
          // 与 popup 通道同款（红线 9）：内联元素自己整体横向滑入，材质（磨砂降级）+ 内容同一条时间轴
          .transition(this.edgePillTransition())
        }

        // 长按加速提示（胶囊遮罩，独立靠上定位）
        if (this.showGestureHint && this.gestureHintMainText && this.gestureHintType === '') {
          Column() {
            ImmersiveLightWrapper({
              radius: 18,
              materialStyle: 0,
              fallbackColor: '#66000000',
              enableLight: false
            }) {
              // ⭐ 与 popup 通道共用外壳（红线 9）：尺寸 / 内容 scale / onAppear 弹入都在里面
              this.holdPillShell();
            }
          }
          // ⭐ **按中心定位**（内联元素用 translate(-50%,-50%) 天然围绕中心缩放，与 popup 通道等价）：
          //   ⚠️ 用百分比而非 `vcH*0.10`（vcH 在该布局下可能仍是 0，退化分支会丢掉常量，见 holdRippleRing 注释）
          .position({ x: '50%', y: '10%' })
          .translate({ x: '-50%', y: '-50%' })
          // 与 popup 通道同款：只做淡入淡出
          .transition(this.hintTransition())
        }
        // ⭐ 长按涟漪描边（常驻、弹层/条件渲染之外；与胶囊中心重合）
        this.holdRippleRing(0);

        // ⭐ 竖条的涟漪环（内联通道）：`atTopLeft = true` —— 竖条自身就是"左上角定位"，
        //   涟漪复制同一对表达式（edgeLegacyAnchorX / legacyHintTopY）⇒ 天然重合，
        //   连 `vcH = 0` 的退化分支也一致（不需要任何常量补偿，所以内层 translate 为 0）。
        //   ⛔ 同样**只传常量**（位置表达式写在 builder 体内，否则不会随类型切换刷新）
        this.edgePillRippleRing(true);
      }

      // 底部提示
      if (this.showBottomHint && this.bottomHintText) {
        Column() {
          Row() {
            if (this.bottomHintImage) {
              Image(this.bottomHintImage)
                .width(24)
                .height(24)
                .fillColor('#FFFFFF')
                .margin({ right: 8 })
            }
            Text(this.bottomHintText)
              .fontSize(14)
              .fontColor('#FFFFFF')
          }
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('#90000000')
          .borderRadius(8)
        }
        .position({ x: '50%', y: '25%' })
        .translate({ x: '-50%', y: '-50%' })
      }

      // 播放速度提示（已移除 — 按钮文本变化即反映速率）
    }
    .width('100%')
    .height('100%')
    .blur(this.blurAmount)
    // ⭐ 实测播放器区域宽度（vp）：音量/亮度竖条的右侧锚点用它算数值 x
    //   （popup 的 offset.x 在靠近窗口边缘时会被系统再推一次，位置不可控 —— 见 edgeAnchorX）
    // ⚠️ `n.width / n.height` 的**静态类型是 `Length`**（`string | number | Resource`），
    //   原先写 `n.width as number` 只是**类型断言、不做任何转换**：一旦运行时给的是字符串，
    //   `w > 0` 就静默为 false ⇒ `vcW/vcH` 永远是 0（真机实测到 `vcH` 一直为 0 就是这个根因）。
    //   现在统一走 `lenToVp()` 收口（数字直接用、带单位字符串再 parseFloat 兜一次）：
    //   能拿到就写入，拿不到就保持旧值 —— 不会比原先更糟。
    //   受它影响的：亮度竖条的右侧锚点（`edgeAnchorX`）、竖条涟漪环的位置、
    //   `holdAnchorY()` 的弹入补偿、`seekAnchorY()` 的缩略图到达补偿。
    .onAreaChange((_o: Area, n: Area) => {
      const w: number = this.lenToVp(n.width);
      if (w > 0 && Math.abs(w - this.vcW) > 0.5) this.vcW = w;
      const h: number = this.lenToVp(n.height);
      if (h > 0 && Math.abs(h - this.vcH) > 0.5) this.vcH = h;
    })
    .onTouch((e: TouchEvent) => { this.onPlayerTouch(e); })
  }
}
