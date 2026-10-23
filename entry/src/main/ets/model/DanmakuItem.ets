/**
 * 弹幕数据模型
 * 定义弹幕项的所有属性和类型
 */

// 弹幕类型枚举（对应B站弹幕mode字段）
export enum DanmakuType {
  ROLL = 1,        // 滚动弹幕（从右到左）
  TOP = 2,         // 顶部弹幕（静止）
  BOTTOM = 3,      // 底部弹幕（静止）
  REVERSE = 4,     // 逆向弹幕（从左到右）
  ADVANCED = 5,    // 高级弹幕（特殊效果）
  SCRIPT = 6,      // 脚本弹幕
  TOP_FIXED = 7,   // 顶部固定弹幕
  SPECIAL = 8      // 特殊弹幕
}

// 弹幕颜色枚举
export enum DanmakuColor {
  WHITE = 0xFFFFFF,
  RED = 0xFF0000,
  ORANGE = 0xFFA500,
  YELLOW = 0xFFFF00,
  GREEN = 0x00FF00,
  CYAN = 0x00FFFF,
  BLUE = 0x0000FF,
  PURPLE = 0x8B00FF,
  PINK = 0xFF69B4
}

// 弹幕项初始化参数接口
export interface DanmakuItemInit {
  id?: number
  content?: string
  time?: number
  type?: DanmakuType
  color?: number
  fontSize?: number
  sendTime?: number
  userId?: string
  pool?: number
  weight?: number
}

// 弹幕项数据结构
export class DanmakuItem {
  // 基础属性
  id: number = 0                    // 弹幕唯一ID
  content: string = ''              // 弹幕内容
  time: number = 0                  // 出现时间（毫秒）
  type: DanmakuType = DanmakuType.ROLL  // 弹幕类型
  color: number = DanmakuColor.WHITE    // 弹幕颜色（RGB）
  fontSize: number = 25             // 字体大小（**绘制用**，由控制器按 config 归一化后写入）
  // ⭐ 原始（B站）字号：18(超小) / 25(标准) / 36(中) / 45(大) / 64(超大)。
  //   只在数据解析时写入，之后永不再改 —— `fontSize` 是"归一化后实际绘制"的字号。
  //   两者必须分开：否则每次归一化都会在上一次的结果上再乘一次比例（字号会越滚越大）。
  rawFontSize: number = 25

  // 扩展属性
  sendTime: number = 0              // 发送时间戳
  userId: string = ''               // 发送者ID（用于过滤）
  pool: number = 0                  // 弹幕池（0:普通 1:字幕 2:特殊）
  weight: number = 10               // 权重（用于排序）

  // 渲染属性（运行时计算）
  x: number = 0                     // 当前X坐标
  y: number = 0                     // 当前Y坐标
  track: number = -1                // 分配的轨道号
  width: number = 0                 // 弹幕宽度（像素；优先取 measureText 的真实值）
  // ⭐ 该宽度是在哪个字号下测出来的：字号变化后宽度缓存失效，需要重测（否则碰撞/出屏判定全错）
  widthFontSize: number = 0
  height: number = 0                // 弹幕高度（像素）
  speed: number = 0                 // 移动速度（像素/帧）
  visible: boolean = true           // 是否可见

  // ⭐ 绘制缓存：颜色字符串只算一次，避免每帧重复拼接（PiliPlus paragraph 缓存思路）
  private cachedColorString: string = ''

  // ⭐ 同内容合并计数：相同内容弹幕合并为一条，count 累加（渲染显示 ×N）
  count: number = 1

  // ⭐ 需要按【真实测量宽度】水平居中的静止弹幕（顶部/底部）。
  //   为什么不能用估算宽度：estimateTextWidth 把 charCodeAt>255 的字符一律按 1 个 fontSize
  //   计宽，而 emoji 是代理对（两个码元都 >255）会被算成 2 倍宽；中英混排与全角标点的
  //   实际宽度也和估算不一致 → (canvasWidth - width)/2 算出的位置偏左，
  //   视觉上就是"居中的弹幕没有对齐"。改由 Canvas measureText 拿真实宽度。
  centerAligned: boolean = false

  // ⭐ 真实测量宽度缓存（渲染器用 measureText 填充），0 表示尚未测量
  measuredWidth: number = 0

  // ⭐ measuredWidth 对应的字号：字号变化时缓存失效，需要重测
  measuredFontSize: number = 0

  // ⭐ 轨道分配失败标记（本帧不绘制）。
  //   为什么需要：顶/底弹幕轨道满员时 assignTrack 返回 -1，但这些弹幕仍留在
  //   visibleDanmaku 里且被置 visible=true，x/y 还停在默认值 0 → 会被直接画到画布
  //   左上角 (0,0)，表现就是"弹幕没对齐 / 跑到边角去了"。
  dropped: boolean = false

  // ⭐ 已错过注入窗口（对齐官方语义：一条弹幕只在它自己的时间点尝试上屏一次，
  //   轨道放不下就【永久丢弃】，不会在几秒后轨道空了再冒出来）。
  //   为什么需要：原先的实现会把"过去 11~30 秒内所有分配失败的弹幕"每 100ms 重试一次，
  //   于是几秒前的旧弹幕会在之后突然出现在屏幕上 —— 时间点与画面内容对不上，
  //   这是"弹幕节奏和官方不一样"最隐蔽的一处（纯数值调整改不掉）。
  //   ⚠️ seek / 重置时会整体清掉（见 DanmakuController.resetScrollingState）。
  missed: boolean = false

  // 高级弹幕属性
  isAdvanced: boolean = false       // 是否为高级弹幕
  duration: number = 0              // 持续时间（毫秒）

  constructor(init?: DanmakuItemInit) {
    if (init) {
      if (init.id !== undefined) this.id = init.id
      if (init.content !== undefined) this.content = init.content
      if (init.time !== undefined) this.time = init.time
      if (init.type !== undefined) this.type = init.type
      if (init.color !== undefined) this.color = init.color
      if (init.fontSize !== undefined) {
        this.fontSize = init.fontSize
        // ⭐ 解析阶段传进来的就是原始字号，一并存档（归一化只在控制器里做一次，避免重复缩放）
        this.rawFontSize = init.fontSize
      }
      if (init.sendTime !== undefined) this.sendTime = init.sendTime
      if (init.userId !== undefined) this.userId = init.userId
      if (init.pool !== undefined) this.pool = init.pool
      if (init.weight !== undefined) this.weight = init.weight
    }
  }
  
  // 判断是否为静止弹幕
  isStatic(): boolean {
    return this.type === DanmakuType.TOP || 
           this.type === DanmakuType.BOTTOM ||
           this.type === DanmakuType.TOP_FIXED
  }
  
  // 判断是否为滚动弹幕
  isScrolling(): boolean {
    return this.type === DanmakuType.ROLL || 
           this.type === DanmakuType.REVERSE ||
           this.type === DanmakuType.ADVANCED ||
           this.type === DanmakuType.SCRIPT
  }
  
  // 获取颜色字符串（用于Canvas），结果缓存，避免每帧重复拼接
  getColorString(): string {
    if (this.cachedColorString !== '') {
      return this.cachedColorString
    }
    const r = (this.color >> 16) & 0xFF
    const g = (this.color >> 8) & 0xFF
    const b = this.color & 0xFF
    this.cachedColorString = `rgb(${r}, ${g}, ${b})`
    return this.cachedColorString
  }
}

// 弹幕配置初始化参数接口
export interface DanmakuConfigInit {
  enable?: boolean
  opacity?: number
  fontSize?: number
  speed?: number
  displayArea?: number
  showTop?: boolean
  showBottom?: boolean
  showScroll?: boolean
  showAdvanced?: boolean
  blockLevel?: number
  blockKeywords?: string[]
  blockUsers?: string[]
  blockRegex?: string
  maxCount?: number
  density?: number
  fontWeight?: number
  fontFamily?: string
  borderWidth?: number
  shadowBlur?: number
  massiveMode?: boolean           // 大量弹幕模式（降低绘制质量）
  massiveThreshold?: number       // 触发大量弹幕模式的阈值
  static2Scroll?: boolean         // 静止弹幕转滚动
  scrollFixedVelocity?: boolean   // 固定速度滚动
  apiSource?: string              // 弹幕数据源: 'xml' | 'grpc'
  varyFontSize?: boolean          // 是否保留原始字号的大小差异（默认统一字号）
  lineHeight?: number             // 弹幕行高（轨道高 = 字号 × 行高）
  fullScreenFontScale?: number    // 全屏/横屏时的字号放大系数
  scrollDuration?: number         // 滚动弹幕穿越屏幕时长（毫秒）
  staticDuration?: number         // 静止弹幕停留时长（毫秒）
  blockColorful?: boolean         // 屏蔽彩色弹幕（非白色）
  blockWeight?: number            // 智能云屏蔽等级（weight < level 的弹幕丢弃）
}

// 弹幕配置项
export class DanmakuConfig {
  // 显示配置
  enable: boolean = true            // 是否启用弹幕
  /**
   * ⭐ 透明度默认 1.0（对齐官方/PiliPlus：`danmakuOpacity` 默认 1.0）。
   *   原来是 0.8，整屏弹幕偏灰偏淡，是"和官方不一样"的观感来源之一。
   */
  opacity: number = 1.0             // 透明度 (0-1)
  /**
   * ⭐ 绘制字号基准 = **28vp**（用户第三轮确认的"大小 / 密度平衡档"）。
   *   ⇒ **这里的 fontSize 直接就是屏幕上的绘制字号**，解析器只存原始字号、不再放大。
   *
   *   三轮取舍（别再凭感觉跳档）：15 太小 → 37 太大（行距与横向间距都发散）→ **折中 28**。
   *
   *   ★★ 字号不能随便调大，因为它**同时决定了同屏弹幕条数**，是个乘法约束：
   *     ① 每行能同时放几条 ≈ `画布宽 / (典型弹幕宽 + SCROLL_GAP)`，
   *        典型弹幕宽 ≈ **8 个字 × 字号**（越宽，同一行的"复用间隔"越长）；
   *     ② 行数 = `画布高 × displayArea / 轨道高`，轨道高 = 字号 × 行高 ⇒ 字号↑ 行数↓。
   *     竖屏 517×291vp 实测：
   *       字号 37 → 每行 1.7 条 × 5 行 ≈ **9 条**（用户反馈"太稀、不自然"）
   *       **字号 28 → 每行 2.3 条 × 7 行 ≈ 16 条（当前）**
   *       官方 15 → 每行 4.1 条 × 6 行 ≈ **24 条**
   *     ⇒ "和官方比不自然"的真因是**同屏条数**（≈2 倍差），不是行距本身 —— 只能靠字号解。
   */
  fontSize: number = 28
  /**
   * 标准绘制字号（== 用户设定的 fontSize）。
   * 轨道高度与每条弹幕的绘制字号统一以它为基准，不再额外乘系数。
   * 全屏放大由 `DanmakuTrackManager` 按画布比例处理（官方做法：全屏 ×1.2）。
   */
  get stdFontSize(): number {
    return Math.round(this.fontSize)
  }
  /**
   * ⭐ 弹幕速度倍率。**与播放倍速联动**（`VideoPlayerPage.setRate` 会同步写入）：
   *   官方/PiliPlus 是 `duration / playbackSpeed` —— 2 倍速时弹幕也走两倍快。
   *   速度计算里 `speed` 是乘数、时长计算里 `speed` 是除数，两种语义等价。
   */
  speed: number = 1.0               // 速度倍率 (= 播放倍速，0.5-3.0)
  /**
   * ⭐ 显示区域 **0.9**：轨道数 = 可用高度 / 轨道高（从画布顶部往下算）。
   *   官方默认 0.5 —— 那是给画面留白、不让弹幕压满的做法；
   *   本项目字号比官方大近一倍（轨道 34vp vs 官方 24vp），照搬 0.5 只排得下 4 行。
   *   0.9 是"尽量多给行数"的取值（再往上收益被 `floor()` 步长吃掉），
   *   竖屏 291vp 高 → `floor(291×0.9/34)` = **7 行**。
   */
  displayArea: number = 0.9         // 显示区域 (0.25-1.0，从顶部开始的比例)

  // 功能配置
  showTop: boolean = true           // 显示顶部弹幕
  showBottom: boolean = true        // 显示底部弹幕
  showScroll: boolean = true        // 显示滚动弹幕
  showAdvanced: boolean = true      // 显示高级弹幕

  // 过滤配置
  blockLevel: number = 0            // 屏蔽等级 (0-3)
  blockKeywords: string[] = []      // 屏蔽关键词
  blockUsers: string[] = []         // 屏蔽用户ID
  blockRegex: string = ''           // 屏蔽正则表达式

  // 性能配置
  maxCount: number = 100            // 最大同时显示数量（原500，减至100降低绘制开销）
  density: number = 1.0             // 弹幕密度 (0.5-2.0)

  // 样式配置
  // ⭐ 字重 500（官方 `danmakuFontWeight` 手机端默认 5 = w500）；原来是 400，笔迹偏细
  fontWeight: number = 500          // 字体粗细
  fontFamily: string = 'sans-serif' // 字体
  /**
   * 描边宽度 **2**（改造前就是这个值，占当前字号 28 的 **7.1%**）。
   * 说明：官方 `danmakuStrokeWidth` 默认 1.5，但那是给 **15vp** 字号定的（=10%）；
   *   我们没有采用官方字号，描边若照搬绝对像素 1.5，字号一大就只占 4%，
   *   大字配细边会显得虚、亮画面上不够清楚。按同比例换算到 28vp 是 2.8（偏重），取 **2** 居中。
   */
  borderWidth: number = 2           // 描边宽度
  shadowBlur: number = 0            // 阴影模糊度
  /**
   * ⭐ 是否保留 B站原始字号（18/25/36/45/64）带来的大小差异 —— **默认 true**。
   *   严格对齐官方应设为 false（官方普通弹幕不用 fontsize 字段，整屏一样大），
   *   但那样实机观感过于整齐、缺少错落感。默认改成 true 后按 `rawFontSize / 25`
   *   收敛到 **[0.85, 1.1]** 倍：既看得出大小差别，又保证不溢出轨道
   *   （轨道高 = 字号 × 行高 1.2 ≈ 34px，最大 1.1 倍字形约 31px，行间仍留约 3px）。
   */
  varyFontSize: boolean = true

  // 数据源配置（弹幕API选择）
  apiSource: string = 'grpc'         // 弹幕数据源: 'xml' | 'grpc'

  // 性能优化配置（PiliPlus 灵感）
  massiveMode: boolean = false      // 大量弹幕模式：弹幕多时自动跳过描边，降低绘制开销
  massiveThreshold: number = 60     // 触发大量弹幕模式的可见弹幕数阈值
  static2Scroll: boolean = false    // 静止弹幕独立轨道：顶部/底部弹幕使用专用轨道，不转为滚动
  scrollFixedVelocity: boolean = false // 固定速度滚动：false=按宽度计算，宽弹幕更快，与B站原版一致

  // ══════════════════════════════════════════════════════════════
  // ⭐ 以下为「更多 → 弹幕设置」面板可调项（对齐 PiliPlus showSetDanmaku）
  //   默认值 = 改造前散落在 DanmakuTrackManager 里的编译期常量，
  //   抽成配置字段后才能在运行时改。改动这些字段后必须由调用方触发
  //   `DanmakuTrackManager.updateGeometry()` 才会重新算轨道（见 VideoPlayerPage.notifyDanmakuSettingsChanged）。
  // ══════════════════════════════════════════════════════════════
  /** 行高（轨道高 = 字号 × 行高）。选值理由见 DanmakuTrackManager.DANMAKU_LINE_HEIGHT 注释 */
  lineHeight: number = 1.2
  /** 全屏 / 横屏时的字号放大系数（对齐 PiliPlus `fontSize * (全屏 ? 1.2 : 1.0)`） */
  fullScreenFontScale: number = 1.2
  /** 滚动弹幕穿越屏幕的时长（毫秒）。对齐官方 `danmakuDuration` 默认 7.0 秒 */
  scrollDuration: number = 7000
  /** 静止弹幕（顶部/底部）停留时长（毫秒）。对齐官方 `danmakuStaticDuration` 默认 4.0 秒 */
  staticDuration: number = 4000
  /** 屏蔽彩色弹幕（非白色的全部丢弃） */
  blockColorful: boolean = false
  /**
   * ⭐ 智能云屏蔽等级 **0~11**（对齐 PiliPlus `DanmakuOptions.danmakuWeight`）。
   *   语义：**weight < level 的弹幕丢弃**（`view.dart: if (e.weight < danmakuWeight) return;`）。
   *   weight 来自弹幕协议第 9 个字段，区间约 1~10；XML 源没有该字段时用默认值 10
   *   ⇒ 等级 ≤10 不会误杀 XML 弹幕，等级 11 会全杀（等同"屏蔽全部"）。
   */
  blockWeight: number = 0

  constructor(init?: DanmakuConfigInit) {
    if (init) {
      if (init.enable !== undefined) this.enable = init.enable
      if (init.opacity !== undefined) this.opacity = init.opacity
      if (init.fontSize !== undefined) this.fontSize = init.fontSize
      if (init.speed !== undefined) this.speed = init.speed
      if (init.displayArea !== undefined) this.displayArea = init.displayArea
      if (init.showTop !== undefined) this.showTop = init.showTop
      if (init.showBottom !== undefined) this.showBottom = init.showBottom
      if (init.showScroll !== undefined) this.showScroll = init.showScroll
      if (init.showAdvanced !== undefined) this.showAdvanced = init.showAdvanced
      if (init.blockLevel !== undefined) this.blockLevel = init.blockLevel
      if (init.blockKeywords !== undefined) this.blockKeywords = init.blockKeywords
      if (init.blockUsers !== undefined) this.blockUsers = init.blockUsers
      if (init.blockRegex !== undefined) this.blockRegex = init.blockRegex
      if (init.maxCount !== undefined) this.maxCount = init.maxCount
      if (init.density !== undefined) this.density = init.density
      if (init.fontWeight !== undefined) this.fontWeight = init.fontWeight
      if (init.fontFamily !== undefined) this.fontFamily = init.fontFamily
      if (init.borderWidth !== undefined) this.borderWidth = init.borderWidth
      if (init.shadowBlur !== undefined) this.shadowBlur = init.shadowBlur
      if (init.massiveMode !== undefined) this.massiveMode = init.massiveMode
      if (init.apiSource !== undefined) this.apiSource = init.apiSource
      if (init.massiveThreshold !== undefined) this.massiveThreshold = init.massiveThreshold
      if (init.static2Scroll !== undefined) this.static2Scroll = init.static2Scroll
      if (init.scrollFixedVelocity !== undefined) this.scrollFixedVelocity = init.scrollFixedVelocity
      if (init.varyFontSize !== undefined) this.varyFontSize = init.varyFontSize
      if (init.lineHeight !== undefined) this.lineHeight = init.lineHeight
      if (init.fullScreenFontScale !== undefined) this.fullScreenFontScale = init.fullScreenFontScale
      if (init.scrollDuration !== undefined) this.scrollDuration = init.scrollDuration
      if (init.staticDuration !== undefined) this.staticDuration = init.staticDuration
      if (init.blockColorful !== undefined) this.blockColorful = init.blockColorful
      if (init.blockWeight !== undefined) this.blockWeight = init.blockWeight
    }
  }
}

// 弹幕分段初始化参数接口
export interface DanmakuSegmentInit {
  segmentIndex?: number
  startTime?: number
  endTime?: number
  items?: DanmakuItem[]
  loaded?: boolean
}

// 弹幕分段数据（用于分段加载）
export class DanmakuSegment {
  segmentIndex: number = 0          // 分段索引
  startTime: number = 0             // 开始时间（毫秒）
  endTime: number = 0               // 结束时间（毫秒）
  items: DanmakuItem[] = []         // 弹幕列表
  loaded: boolean = false           // 是否已加载

  constructor(init?: DanmakuSegmentInit) {
    if (init) {
      if (init.segmentIndex !== undefined) this.segmentIndex = init.segmentIndex
      if (init.startTime !== undefined) this.startTime = init.startTime
      if (init.endTime !== undefined) this.endTime = init.endTime
      if (init.items !== undefined) this.items = init.items
      if (init.loaded !== undefined) this.loaded = init.loaded
    }
  }
}

// 弹幕统计信息
export class DanmakuStats {
  totalCount: number = 0            // 总弹幕数
  displayedCount: number = 0        // 当前显示数
  filteredCount: number = 0         // 过滤掉的弹幕数
  fps: number = 0                   // 当前帧率
  renderTime: number = 0            // 渲染耗时（毫秒）
}
