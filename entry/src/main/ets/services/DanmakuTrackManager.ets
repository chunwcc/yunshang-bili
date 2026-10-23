/**
 * 弹幕轨道管理器
 * 负责弹幕的轨道分配和碰撞检测
 */
import { DanmakuItem, DanmakuType, DanmakuConfig } from '../model/DanmakuItem'
import { logInfo, logWarn, logError } from '../utils/Logger';

// 轨道状态
class TrackState {
  lastEndTime: number = 0      // 最后一条弹幕的结束时间
  lastEndX: number = 0         // 最后一条弹幕的结束X坐标
  lastSpeed: number = 0        // 最后一条弹幕的速度
  occupied: boolean = false    // 是否被占用
  // ⭐ 该轨道上最后加入的弹幕引用。碰撞检测必须看它的【实时 x】（渲染器每帧在推进），
  //   只看 lastEndTime/lastEndX 这类静态快照无法判断"此刻尾部在哪"。
  lastItem: DanmakuItem | null = null
}

// 相邻两条滚动弹幕之间的最小水平间隙（vp）。
// ⭐ 官方（canvas_danmaku）这个间隙是 0（只判定"前一条尾部完全越过右边界"），
//   这里留 6vp 作为防贴边的余量，避免两条弹幕首尾相连糊成一片。
// ⭐★ 这个间隙直接决定【每行能同时显示几条】：本轨道必须等前一条**整体进屏**（再往前挪 SCROLL_GAP）
//   才放行下一条，所以同一行的复用间隔 = 前一条走过 `自身宽度 + GAP` 的时间，
//   换算成静止画面上的间距就是 **典型弹幕宽 + GAP**。
//   ⇒ 每行同时条数 ≈ `画布宽 / (典型弹幕宽 + GAP)`；减小 GAP 收益很小（典型宽是几百 vp），
//     真正有效的是**降字号**（同时抬高"每行条数"与"行数"）。
const SCROLL_GAP: number = 6

// ⭐ 原始字号带来的大小浮动区间（`varyFontSize = true` 时生效）。
//   约束来自【轨道高 = 字号 × 行高 1.2】：字号 28、轨道 34vp 时最大 1.1 倍 = 31vp 字形，
//   行间还剩约 3vp —— 刚好不压到相邻轨道，所以不必把 maxRatio 再乘进轨道高
//   （早期版本乘了，白白把轨道撑高、减少行数）。
const DANMAKU_SIZE_MIN_RATIO: number = 0.85
const DANMAKU_SIZE_MAX_RATIO: number = 1.1

/**
 * ⭐ 行高：**轨道高 = 字号 × 行高**，不再额外加 gap。当前 **1.2**（字号 28 → 轨道 34vp）。
 *
 *   为什么不是官方的 1.6：官方 `lineHeight=1.6` 是配 **15vp** 的（轨道 24vp，绝对留白约 9vp）。
 *   字号放大到 28 后仍乘 1.6 → 轨道 45vp，`floor(291*0.9/45)` 只剩 5 行、行到行 45vp 明显发飘；
 *   我们的目标是把"字行之间的留白"压到与官方**同量级**，所以统一取 **1.2**：
 *     字号 28 → 轨道 34vp，字形约 25vp ⇒ 行间留白 ≈ 9vp（与官方的 9vp 一致）。
 *   （改造前那版是 `字号×1.15+4`，字号 37 时 = 47vp —— 同样是"留白 ~10vp"这一档。）
 *
 *   ⚠️ 下限：字形高度约 0.88em + Latin 下伸部，行高低于 ~1.1 相邻两条会互相压字，别再往下压。
 *   想增加行数请优先降字号（它对"每行条数"和"行数"是双重增益，见 DanmakuConfig.fontSize 注释）。
 */
const DANMAKU_LINE_HEIGHT: number = 1.2

/**
 * ⭐ 全屏 / 横屏时的字号放大系数（对齐 PiliPlus：`fontSize = 15 * (竖屏 ? 1.0 : 1.2)`）。
 *   没有它的话，进入全屏画布变宽、字号不变 → 弹幕相对画面明显变小，与官方不一致。
 */
const DANMAKU_FULLSCREEN_FONT_SCALE: number = 1.2

// ⭐ 滚动弹幕穿越屏幕的时长（毫秒）。对齐官方 `danmakuDuration` 默认 7.0 秒（原来是 8 秒）
const DANMAKU_SCROLL_DURATION: number = 7000
// ⭐ 静止弹幕（顶部/底部）停留时长（毫秒）。对齐官方 `danmakuStaticDuration` 默认 4.0 秒
const DANMAKU_STATIC_DURATION: number = 4000

export class DanmakuTrackManager {
  private config: DanmakuConfig

  /** 行高：优先取面板设置，非法值（0/NaN/负）退回常量 1.2（下限定理见 DANMAKU_LINE_HEIGHT 注释） */
  private get lineHeightValue(): number {
    const v = this.config.lineHeight
    return (typeof v === 'number' && v > 0) ? v : DANMAKU_LINE_HEIGHT
  }
  /** 全屏 / 横屏字号放大系数（面板可调，默认 1.2） */
  private get fullscreenScale(): number {
    const v = this.config.fullScreenFontScale
    return (typeof v === 'number' && v > 0) ? v : DANMAKU_FULLSCREEN_FONT_SCALE
  }
  /** 滚动弹幕穿越时长（毫秒，面板可调，默认 7000）。下限 1000ms 防止除零 / 弹幕瞬移 */
  private get scrollDurationMs(): number {
    const v = this.config.scrollDuration
    return (typeof v === 'number' && v >= 1000) ? v : DANMAKU_SCROLL_DURATION
  }
  /** 静止弹幕停留时长（毫秒，面板可调，默认 4000）。下限 500ms */
  private get staticDurationMs(): number {
    const v = this.config.staticDuration
    return (typeof v === 'number' && v >= 500) ? v : DANMAKU_STATIC_DURATION
  }
  private canvasWidth: number = 0
  private canvasHeight: number = 0
  
  // 不同类型弹幕的轨道
  private scrollTracks: TrackState[] = []      // 滚动弹幕轨道（从左往右滚）
  private reverseTracks: TrackState[] = []     // 逆向弹幕轨道（从右往左滚）
  private topTracks: TrackState[] = []         // 顶部弹幕轨道
  private bottomTracks: TrackState[] = []      // 底部弹幕轨道
  
  // 轨道高度 = 字号 × 行高（初始化时按实际字号重算）
  private trackHeight: number = 24
  // ⭐ 当前实际绘制字号 = config.stdFontSize × 全屏放大系数
  private baseFont: number = 15
  // 当前轨道数（滚动 / 顶部 / 底部共享同一套，对齐官方）
  private trackCount: number = 0
  
  constructor(config: DanmakuConfig) {
    this.config = config
  }
  
  /**
   * 初始化轨道
   * @param width 画布宽度
   * @param height 画布高度
   */
  initialize(width: number, height: number): void {
    this.canvasWidth = width
    this.canvasHeight = height
    
    // ⭐ 全屏 / 横屏（画布明显宽于高）时按官方做法放大字号（PiliPlus：全屏 ×1.2）
    const fontScale = (height > 0 && width > height * 1.4) ? this.fullscreenScale : 1.0
    this.baseFont = Math.max(8, Math.round(this.config.stdFontSize * fontScale))

    // ⭐ 轨道高 = 字号 × 行高，**没有额外的 gap**（倍率的选择理由见 DANMAKU_LINE_HEIGHT 注释）。
    //   硬约束：字号越大，行数越少 —— 这是一条初一档也好不了的乘法关系，
    //   想增加行数请先降字号（见 DanmakuTrackManager.SCROLL_GAP 处与 DanmakuConfig.fontSize 的注释）。
    this.trackHeight = Math.round(this.baseFont * this.lineHeightValue)
    
    // 计算可用区域高度
    const availableHeight = height * this.config.displayArea
    const trackCount = Math.max(1, Math.floor(availableHeight / this.trackHeight))
    this.trackCount = trackCount
    
    // 初始化滚动弹幕轨道
    this.scrollTracks = []
    for (let i = 0; i < trackCount; i++) {
      this.scrollTracks.push(new TrackState())
    }

    // ⭐ 逆向弹幕独立一套轨道。原先它与正向弹幕共用 scrollTracks，而分配逻辑
    //   一律 `item.x = canvasWidth`（从右侧进入）+ 渲染器让它 `x += speed*dt`（向右走），
    //   结果刚分配就被推到画布外 → 逆向弹幕（B站 mode=6）**从来没有显示过**。
    //   独立轨道后，正反向各自的"尾部是否让开"判定互不干扰，逻辑也简单可靠。
    this.reverseTracks = []
    for (let i = 0; i < trackCount; i++) {
      this.reverseTracks.push(new TrackState())
    }
    
    // ⭐ 顶部 / 底部弹幕轨道与滚动【共享同一套轨道数】（对齐官方 canvas_danmaku：
    //   `_staticDanmakuItems` 长度就是 trackCount，顶部从上往下、底部从下往上找空位）。
    //   原来是写死 5 条：竖屏下总轨道是 7 条，写死的 5 条既会溢出小画布、
    //   在大画布上又平白少 2 行；而底部那条公式更是把 y 算成了负数（见 calculateTrackY）。
    this.topTracks = []
    for (let i = 0; i < trackCount; i++) {
      this.topTracks.push(new TrackState())
    }
    
    this.bottomTracks = []
    for (let i = 0; i < trackCount; i++) {
      this.bottomTracks.push(new TrackState())
    }
    
    logInfo(`[TrackManager] 初始化轨道: 正向${this.scrollTracks.length}条, 逆向${this.reverseTracks.length}条, 顶部${this.topTracks.length}条, 底部${this.bottomTracks.length}条, 字号${this.baseFont}, 轨道高${this.trackHeight}`)
  }

  /**
   * ⭐ 运行时修改设置（字号 / 显示区域 / 行高 / 全屏缩放）后的重算入口。
   *
   * 为什么不直接复用 `initialize()`：它会把四套 `TrackState[]` **整个换掉**，
   *   于是每条轨道的 `lastItem` 都变成 null → 碰撞检测会误判"这条轨道是空的"，
   *   紧接着进来的新弹幕会直接叠在还在屏幕上滚动的旧弹幕身上（改一下字号就满屏重影）。
   * 这里是**就地重算**字号/轨道高，并**只在数量变化时才增删轨道尾部**，
   *   已有轨道的占用状态原样保留 —— 屏幕上正在滚的弹幕继续滚，新弹幕按新几何上屏。
   *
   * @param width 画布宽度
   * @param height 画布高度
   */
  updateGeometry(width: number, height: number): void {
    if (width <= 0 || height <= 0) {
      return
    }
    this.canvasWidth = width
    this.canvasHeight = height

    const fontScale = (height > 0 && width > height * 1.4) ? this.fullscreenScale : 1.0
    this.baseFont = Math.max(8, Math.round(this.config.stdFontSize * fontScale))
    this.trackHeight = Math.round(this.baseFont * this.lineHeightValue)

    const availableHeight = height * this.config.displayArea
    const trackCount = Math.max(1, Math.floor(availableHeight / this.trackHeight))
    if (trackCount === this.trackCount) {
      return
    }
    const old = this.trackCount
    this.trackCount = trackCount
    this.resizeTracks(this.scrollTracks, trackCount)
    this.resizeTracks(this.reverseTracks, trackCount)
    this.resizeTracks(this.topTracks, trackCount)
    this.resizeTracks(this.bottomTracks, trackCount)
    logInfo(`[TrackManager] 几何已更新: 轨道数 ${old} -> ${trackCount}, 字号${this.baseFont}, 轨道高${this.trackHeight}`)
  }

  /** 按目标长度就地裁剪/补齐轨道数组（保留既有 TrackState 的占用状态） */
  private resizeTracks(tracks: TrackState[], target: number): void {
    if (tracks.length > target) {
      tracks.splice(target, tracks.length - target)
      return
    }
    while (tracks.length < target) {
      tracks.push(new TrackState())
    }
  }
  
  /**
   * 为弹幕分配轨道
   * @param item 弹幕项
   * @param currentTime 当前播放时间（毫秒）
   * @returns 分配的轨道号（-1表示无法分配）
   */
  /**
   * 归一化绘制字号：B站原始字号（18 / 25 / 36 / 45 / 64）→ 实际绘制字号。
   * 比例收敛到 [0.8, 1.15]，保证任意弹幕都不溢出自己的轨道（轨道高度按 1.15 倍算）。
   *
   * ⚠️ 必须基于 rawFontSize 而不是 fontSize：fontSize 每次都会被这里覆盖，
   *    拿它当输入就变成"每次分配再乘一次比例"的累积放大（字号越滚越大）。
   */
  normalizeFontSize(item: DanmakuItem): void {
    // ⭐ 默认【统一字号】= 官方行为：普通弹幕不使用 B站 fontsize 字段，整屏一样大
    //   （PiliPlus 只在 mode=7 高级弹幕里才用 `e.fontsize`）。
    //   `config.varyFontSize = true` 时才保留大小差异（按原始字号收敛到 [0.8, 1.15] 倍）。
    if (!this.config.varyFontSize) {
      item.fontSize = this.baseFont
      return
    }
    const raw = item.rawFontSize > 0 ? item.rawFontSize : 25
    let ratio = raw / 25
    if (ratio < DANMAKU_SIZE_MIN_RATIO) {
      ratio = DANMAKU_SIZE_MIN_RATIO
    } else if (ratio > DANMAKU_SIZE_MAX_RATIO) {
      ratio = DANMAKU_SIZE_MAX_RATIO
    }
    item.fontSize = Math.round(this.baseFont * ratio)
  }

  assignTrack(item: DanmakuItem, currentTime: number): number {
    this.normalizeFontSize(item)

    // ⭐ 宽度优先使用控制器测好的【真实宽度】（measureText 结果，随字号缓存在 item 上）；
    //    拿不到渲染上下文 / 尚未测量时才退回估算值。
    //    为什么必须用真实宽度：估算偏小 → 弹幕尾巴还在屏幕内就被判定"已出屏"（滚到一半消失）；
    //    估算偏大 → 碰撞检测误判"放不下"（密集时段丢弹幕）。
    if (item.width <= 0 || item.widthFontSize !== item.fontSize) {
      item.width = this.estimateTextWidth(item.content, item.fontSize)
      item.widthFontSize = item.fontSize
    }
    item.height = this.trackHeight

    // ⭐ static2Scroll：静止弹幕转滚动，统一走滚动轨道以减少独立的顶部/底部轨道管理
    if (this.config.static2Scroll && !item.isScrolling()) {
      item.type = DanmakuType.ROLL
    }

    // ⚠️ REVERSE 必须在 isScrolling() 之前分流：isScrolling() 把逆向也算作滚动弹幕，
    //   而两者的进入方向与轨道占用判定完全相反（见 reverseTracks 注释）。
    if (item.type === DanmakuType.REVERSE) {
      return this.assignReverseTrack(item, currentTime)
    }
    if (item.isScrolling()) {
      return this.assignScrollTrack(item, currentTime)
    } else if (item.type === DanmakuType.TOP || item.type === DanmakuType.TOP_FIXED) {
      return this.assignTopTrack(item, currentTime)
    } else if (item.type === DanmakuType.BOTTOM) {
      return this.assignBottomTrack(item, currentTime)
    }

    return -1
  }

  // ⭐ 已废弃 round-robin 起点（原来每次从"上次的下一条"开始找）。
  //   严格轮转会让连续到达的弹幕排成 0→1→2→3 的整齐阶梯，加上统一字号后观感像排好的表格。
  //   现在每条**随机挑起点**再顺序往后找第一条可用轨道：分布仍然均匀，但不再有可见的次序。

  /**
   * 分配滚动弹幕轨道（带碰撞检测）
   *
   * ⚠️ 旧实现是纯 round-robin 轮询、完全不检测碰撞，注释写"与B站官方一致"其实是错的：
   *    所有弹幕都从 x=canvasWidth 起步，弹幕密集时同一轨道几毫秒内就会被连分到两条，
   *    两者速度又相同 → 会【完全重叠】并一起从右侧飘出，用户看到的正是"右侧挤成一堆"。
   *    B 站官方的做法是放不下就丢弃这条弹幕（宁可少显示也不重叠）。
   *
   * 现在的判定（对齐 danmaku.js）：
   *   ① 该轨道最后一条弹幕的尾部必须已完全越过右边界，否则新弹幕会直接叠在它身上；
   *   ② 新弹幕不能追尾：若新弹幕更快，追上旧弹幕的时间必须晚于旧弹幕滚出屏幕的时间。
   * 所有轨道都不满足 → 返回 -1，由调用方丢弃该弹幕。
   */
  private assignScrollTrack(item: DanmakuItem, currentTime: number): number {
    // ⭐ scrollFixedVelocity：固定速度，不按文本宽度计算，所有弹幕统一速度
    // ⭐ 穿越时长默认 7 秒（对齐官方 `danmakuDuration` 默认 7.0；原来是 8 秒，略慢），面板可调
    if (this.config.scrollFixedVelocity) {
      // 固定速度：所有弹幕一样快，不受内容宽度影响
      item.speed = this.canvasWidth / this.scrollDurationMs * this.config.speed
    } else {
      // 固定穿越时长：宽弹幕走得更快（官方默认行为）
      const baseSpeed = (this.canvasWidth + item.width) / this.scrollDurationMs
      item.speed = baseSpeed * this.config.speed
    }

    // 计算弹幕完全通过屏幕的时间
    const duration = (this.canvasWidth + item.width) / item.speed

    // ⭐ 随机起点 + 顺序查找第一条可用轨道（不再用 round-robin，详见上方成员注释）
    const trackCount = this.scrollTracks.length
    const start = trackCount > 0 ? Math.floor(Math.random() * trackCount) : 0
    let bestTrack = -1
    for (let offset = 0; offset < trackCount; offset++) {
      const idx = (start + offset) % trackCount
      if (this.isScrollTrackAvailable(idx, item)) {
        bestTrack = idx
        break
      }
    }

    // 全部轨道都放不下：丢弃（不重叠显示），并标记 missed 不再事后补位
    if (bestTrack < 0) {
      return -1
    }

    const track = this.scrollTracks[bestTrack]
    track.lastEndTime = currentTime + duration
    track.lastEndX = 0  // 从右侧进入
    track.lastSpeed = item.speed
    track.occupied = true
    track.lastItem = item

    // 设置弹幕位置
    item.track = bestTrack
    item.x = this.canvasWidth
    item.y = this.calculateTrackY(bestTrack, 'scroll')
    // ⭐ 设置弹幕穿越屏幕的时长，用于 updateVisibleDanmaku 判断可见性窗口
    // 避免长弹幕在滚动途中被 8 秒硬限制提前移除
    item.duration = duration

    return bestTrack
  }

  /**
   * 判断某条滚动轨道此刻能否安全接纳新弹幕
   */
  private isScrollTrackAvailable(index: number, item: DanmakuItem): boolean {
    const track = this.scrollTracks[index]
    const last = track.lastItem
    if (last === null) {
      return true   // 该轨道从未使用或已空闲
    }

    // 旧弹幕尾巴的当前位置：渲染器每帧推进 last.x，这里拿到的是实时值。
    // 已经滚出屏幕的弹幕不再被推进，x 冻结在负值 → lastTail 为负 → 下面 ① 自然通过。
    const lastTail = last.x + last.width

    // ① 尾部必须已完全越过右边界
    if (lastTail > this.canvasWidth - SCROLL_GAP) {
      return false
    }

    // ② 防追尾：新弹幕更快时，追上旧尾巴的时间要晚于旧弹幕滚出屏幕的时间
    if (item.speed > last.speed && last.speed > 0) {
      const catchUpTime = (this.canvasWidth - lastTail - SCROLL_GAP) / (item.speed - last.speed)
      const oldClearTime = lastTail > 0 ? lastTail / last.speed : 0
      if (catchUpTime < oldClearTime) {
        return false
      }
    }

    return true
  }

  /**
   * 分配逆向弹幕轨道（从【左】往右滚，B站 mode=6）
   *
   * 判定与正向完全镜像：
   *   ① 该轨道上一条逆向弹幕的【左边缘】(last.x) 必须已越出左边界，否则新弹幕
   *      从 x=-width 进入时会直接叠在它身上；
   *   ② 防追尾：新弹幕更快时，它的前端（右边缘，起点为 0）追上旧弹幕左边缘的时间
   *      必须晚于旧弹幕滚出右边界的时间。
   * 放不下同样返回 -1 由调用方丢弃。
   */
  private assignReverseTrack(item: DanmakuItem, currentTime: number): number {
    // 速度公式与正向一致（穿越屏幕耗时同为 scrollDurationMs，不因方向不同而变快变慢）
    if (this.config.scrollFixedVelocity) {
      item.speed = this.canvasWidth / this.scrollDurationMs * this.config.speed
    } else {
      const baseSpeed = (this.canvasWidth + item.width) / this.scrollDurationMs
      item.speed = baseSpeed * this.config.speed
    }

    const duration = (this.canvasWidth + item.width) / item.speed

    const trackCount = this.reverseTracks.length
    const start = trackCount > 0 ? Math.floor(Math.random() * trackCount) : 0
    let bestTrack = -1
    for (let offset = 0; offset < trackCount; offset++) {
      const idx = (start + offset) % trackCount
      if (this.isReverseTrackAvailable(idx, item)) {
        bestTrack = idx
        break
      }
    }

    if (bestTrack < 0) {
      return -1
    }

    const track = this.reverseTracks[bestTrack]
    track.lastEndTime = currentTime + duration
    track.lastSpeed = item.speed
    track.occupied = true
    track.lastItem = item

    item.track = bestTrack
    // ⭐ 从左侧进入：起步位置是"整条弹幕贴在左边界之外"
    item.x = -item.width
    item.y = this.calculateTrackY(bestTrack, 'scroll')
    item.duration = duration
    // 逆向弹幕不居中（安全起见显式复位，避免复用对象时带上居中标记）
    item.centerAligned = false

    return bestTrack
  }

  /**
   * 判断某条逆向轨道此刻能否安全接纳新弹幕（与 isScrollTrackAvailable 左右镜像）
   */
  private isReverseTrackAvailable(index: number, item: DanmakuItem): boolean {
    const track = this.reverseTracks[index]
    const last = track.lastItem
    if (last === null) {
      return true
    }

    // 旧弹幕左边缘的当前位置（渲染器每帧推进 last.x）
    const lastHead = last.x

    // ① 旧弹幕必须已完全进入屏幕（左边缘越过 SCROLL_GAP）
    if (lastHead < SCROLL_GAP) {
      return false
    }

    // ② 防追尾：新弹幕更快时，前端追上旧弹幕左边缘的时间要晚于旧弹幕滚出右边界的时间
    if (item.speed > last.speed && last.speed > 0) {
      const catchUpTime = (lastHead - SCROLL_GAP) / (item.speed - last.speed)
      const oldClearTime = (this.canvasWidth - lastHead) / last.speed
      if (catchUpTime < oldClearTime) {
        return false
      }
    }

    return true
  }
  
  /**
   * 分配顶部弹幕轨道
   */
  private assignTopTrack(item: DanmakuItem, currentTime: number): number {
    // 顶部弹幕停留时间（对齐官方 `danmakuStaticDuration` 默认 4 秒，面板可调）
    const duration = item.duration > 0 ? item.duration : this.staticDurationMs
    
    // 寻找空闲轨道
    for (let i = 0; i < this.topTracks.length; i++) {
      const track = this.topTracks[i]
      
      if (!track.occupied || track.lastEndTime <= currentTime) {
        // 更新轨道状态
        track.lastEndTime = currentTime + duration
        track.occupied = true
        
        // 设置弹幕位置
        item.track = i
        // ⭐ 这里先用估算宽度给个位置兜底，渲染器会用 measureText 的真实宽度重算（见 centerAligned）
        item.x = (this.canvasWidth - item.width) / 2
        item.centerAligned = true
        item.y = this.calculateTrackY(i, 'top')
        item.duration = duration
        
        return i
      }
    }
    
    return -1
  }
  
  /**
   * 分配底部弹幕轨道
   */
  private assignBottomTrack(item: DanmakuItem, currentTime: number): number {
    // 底部弹幕停留时间（对齐官方 `danmakuStaticDuration` 默认 4 秒，面板可调）
    const duration = item.duration > 0 ? item.duration : this.staticDurationMs
    
    // 寻找空闲轨道
    for (let i = 0; i < this.bottomTracks.length; i++) {
      const track = this.bottomTracks[i]
      
      if (!track.occupied || track.lastEndTime <= currentTime) {
        // 更新轨道状态
        track.lastEndTime = currentTime + duration
        track.occupied = true
        
        // 设置弹幕位置
        item.track = i
        // ⭐ 这里先用估算宽度给个位置兜底，渲染器会用 measureText 的真实宽度重算（见 centerAligned）
        item.x = (this.canvasWidth - item.width) / 2
        item.centerAligned = true
        item.y = this.calculateTrackY(i, 'bottom')
        item.duration = duration
        
        return i
      }
    }
    
    return -1
  }
  
  /**
   * 计算轨道Y坐标
   */
  private calculateTrackY(trackIndex: number, type: string): number {
    const padding = 4  // 顶部padding
    
    if (type === 'scroll' || type === 'top') {
      // 从上往下按轨道排；+0.8×轨道高 是因为 Canvas 的 y 是**文字基线**，不是顶边
      return padding + trackIndex * this.trackHeight + this.trackHeight * 0.8
    } else if (type === 'bottom') {
      // ⭐ 底部弹幕从【显示区最下面一条轨道】往上排，且用的是与滚动相同的轨道网格。
      //   原公式 `H*0.85 - 4 - (5 - idx - 1) * 47`：轨道高 47 时 idx=0 算出 **y ≈ −20**，
      //   底部弹幕直接画到画布上方外面（看不见），idx=1 的 y≈27 又压在顶部弹幕区。
      //   对齐官方（canvas_danmaku 底部 index = trackCount-1-i）：直接用同一套轨道网格换算。
      const idx = Math.max(0, this.trackCount - 1 - trackIndex)
      return padding + idx * this.trackHeight + this.trackHeight * 0.8
    }
    
    return 0
  }
  
  /**
   * 估算文本宽度（按【码点】而非码元计数）
   * 简化规则：全角/中文 = 字体大小，半角/ASCII = 字体大小*0.6
   *
   * ⚠️ 必须按码点走：emoji 等增补平面字符由高低两个代理码元组成，两个码元都 >255，
   *    旧写法（逐个 charCodeAt 判断 >255）会把一个 emoji 算成 2 个全角字符 = 2 倍宽，
   *    比真实宽度大一倍左右。这个估算值同时用于轨道碰撞检测与滚动时长，
   *    偏大意味着"该放得下的弹幕被判成放不下"→ 密集时段丢弹幕。
   *    实测真机上 emoji 权重很高的弹幕（"顔顔顔…"这类）本来丢得偏多。
   */
  private estimateTextWidth(text: string, fontSize: number): number {
    let width = 0
    for (let i = 0; i < text.length; i++) {
      const code = text.charCodeAt(i)
      // 代理对：高代理 + 低代理 = 一个字符
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        const next = text.charCodeAt(i + 1)
        if (next >= 0xDC00 && next <= 0xDFFF) {
          // emoji 实际宽度略大于 1em，取 1.2 倍（宁可略宽留出间隙，也不要重叠）
          width += fontSize * 1.2
          i++   // 跳过低位代理
          continue
        }
      }
      if (code > 255) {
        width += fontSize
      } else {
        width += fontSize * 0.6
      }
    }
    return width
  }
  
  /**
   * 更新轨道状态（每帧调用）
   */
  updateTracks(currentTime: number): void {
    // 更新滚动弹幕轨道
    this.scrollTracks.forEach((track: TrackState) => {
      if (track.occupied && track.lastEndTime <= currentTime) {
        track.occupied = false
      }
    })

    // 更新逆向弹幕轨道
    this.reverseTracks.forEach((track: TrackState) => {
      if (track.occupied && track.lastEndTime <= currentTime) {
        track.occupied = false
      }
    })
    
    // 更新顶部弹幕轨道
    this.topTracks.forEach((track: TrackState) => {
      if (track.occupied && track.lastEndTime <= currentTime) {
        track.occupied = false
      }
    })
    
    // 更新底部弹幕轨道
    this.bottomTracks.forEach((track: TrackState) => {
      if (track.occupied && track.lastEndTime <= currentTime) {
        track.occupied = false
      }
    })
  }
  
  /**
   * 清空所有轨道
   */
  clearTracks(): void {
    // ⚠️ lastItem 必须一并清掉。碰撞检测看的是 lastItem 的实时 x，如果只清 occupied，
    //    seek 重置后 lastItem 仍指向旧弹幕（x 还停在屏幕内），会让每条轨道都被判定成
    //    "放不下" → 滚动弹幕全被丢弃 → 表现为"重置之后一条弹幕都没有"。
    this.scrollTracks.forEach((track: TrackState) => {
      track.occupied = false
      track.lastEndTime = 0
      track.lastItem = null
    })
    this.reverseTracks.forEach((track: TrackState) => {
      track.occupied = false
      track.lastEndTime = 0
      track.lastItem = null
    })
    this.topTracks.forEach((track: TrackState) => {
      track.occupied = false
      track.lastEndTime = 0
      track.lastItem = null
    })
    this.bottomTracks.forEach((track: TrackState) => {
      track.occupied = false
      track.lastEndTime = 0
      track.lastItem = null
    })
  }
  
  /**
   * 获取轨道统计信息
   */
  getStats(): string {
    const scrollOccupied = this.scrollTracks.filter((t: TrackState) => t.occupied).length
    const reverseOccupied = this.reverseTracks.filter((t: TrackState) => t.occupied).length
    const topOccupied = this.topTracks.filter((t: TrackState) => t.occupied).length
    const bottomOccupied = this.bottomTracks.filter((t: TrackState) => t.occupied).length

    return `正向:${scrollOccupied}/${this.scrollTracks.length} 逆向:${reverseOccupied}/${this.reverseTracks.length} 顶部:${topOccupied}/${this.topTracks.length} 底部:${bottomOccupied}/${this.bottomTracks.length}`
  }
}
