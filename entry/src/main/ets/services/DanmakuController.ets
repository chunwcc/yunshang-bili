/**
 * 弹幕控制器
 * 整合数据获取、过滤、轨道管理、渲染等所有模块
 */
import { DanmakuItem, DanmakuItemInit, DanmakuConfig, DanmakuSegment, DanmakuSegmentInit, DanmakuStats } from '../model/DanmakuItem'
import { logInfo, logWarn, logError } from '../utils/Logger';
import { DanmakuService } from './DanmakuService'
import { DanmakuTrackManager } from './DanmakuTrackManager'
import { DanmakuFilter } from './DanmakuFilter'
import { DanmakuRenderer } from './DanmakuRenderer'

/**
 * 弹幕注入窗口容差（毫秒）：一条弹幕只有在"自己的时间点 ± 这个容差"内才会尝试上屏。
 * 对齐官方语义（见 updateVisibleDanmaku 内注释）；容差只为吸收分段数据晚到的网络延迟。
 */
const INJECT_GRACE_MS: number = 1000

export class DanmakuController {
  // 配置
  private config: DanmakuConfig

  // 各模块实例
  private service: DanmakuService
  private trackManager: DanmakuTrackManager
  private filter: DanmakuFilter
  private renderer: DanmakuRenderer

  // 弹幕数据
  private allDanmaku: DanmakuItem[] = []           // 所有弹幕
  private visibleDanmaku: DanmakuItem[] = []       // 当前可见弹幕
  private segments: DanmakuSegment[] = []          // 分段数据

  // ⭐ 0.1s 时间分桶索引（仿 PiliPlus _dmSegMap）：key = Math.floor(time/100)
  // 播放时按桶 O(1) 取档，替代二分查找 + 线性扫描
  private timeBuckets: Map<number, DanmakuItem[]> = new Map()

  // ⭐ 正在请求中的分段索引（in-flight 锁）。没有它时，网络往返期间 updateTime 的
  //   高频调用会让同一个分段被并发加载多次，同一批弹幕被重复追加进 allDanmaku。
  private loadingSegments: Set<number> = new Set()
  
  // 优化：缓存上次计算结果
  private lastUpdateTime: number = -1              // 上次更新时间
  private cachedCandidates: DanmakuItem[] = []     // 缓存的候选弹幕

  // 视频信息
  private cid: number = 0                          // 视频cid
  private aid: number = 0                          // 视频aid

  // ⭐ gRPC 回退标志：当 gRPC 分段返回空时，尝试加载 XML 全量弹幕作为补充
  private grpcFallbackLoaded: boolean = false

  // 播放状态
  private currentSegment: number = 0               // 当前分段索引
  private currentTime: number = 0                  // 当前播放时间（毫秒）
  private videoDuration: number = 0                // 视频总时长（毫秒）
  private isPlaying: boolean = false               // 是否播放中
  private canvasWidth: number = 0                  // 弹幕画布宽度（剔除已出屏弹幕时需要）

  // 帧间增量时间：每帧按真实时间差推进弹幕位置，独立于currentTime的更新频率
  private lastFrameTimestamp: number = 0

  // 渲染定时器
  private renderTimer: number = 0
  private lastRenderTime: number = 0
  // ⭐ 渲染自调度链是否存活。必须与 renderTimer 分开记录：
  //   renderTimer 是 setTimeout 返回的 id，链终止后这个值【不会被清零】，
  //   若只靠它判断"是否已在渲染"，链一旦停掉就永远无法重启（见 startRendering 注释）。
  private renderActive: boolean = false

  // 统计信息
  private stats: DanmakuStats = new DanmakuStats()
  private isMassiveMode: boolean = false  // 当前是否大量弹幕模式

  // 回调函数
  private onStatsUpdate: ((stats: DanmakuStats) => void) | null = null

  constructor(config: DanmakuConfig) {
    this.config = config

    // 初始化各模块
    this.service = new DanmakuService()
    this.trackManager = new DanmakuTrackManager(config)
    this.filter = new DanmakuFilter(config)
    this.renderer = new DanmakuRenderer(config)

    logInfo('[DanmakuController] 初始化完成')
  }

  /**
   * 初始化弹幕系统
   * @param cid 视频cid
   * @param aid 视频aid
   * @param duration 视频时长（毫秒）
   */
  async initialize(cid: number, aid: number, duration: number): Promise<void> {
    logInfo(`[DanmakuController] initialize被调用: cid=${cid}, aid=${aid}, duration=${duration}`)
    
    // 检查是否是同一个视频，如果是则跳过重复下载
    if (this.cid === cid && this.allDanmaku.length > 0) {
      // ⚠️ 这里**不能**只更新 videoDuration 就返回。
      //    初始化发生在播放器拿到真实时长之前，首帧 duration 往往是 0，
      //    而 calculateSegmentCount(0) = max(1, ceil(0/6min)) = 1 —— 于是只建了 1 个分段、
      //    只加载了【第 1 个 6 分钟】的弹幕。真实时长（如 20:13）随后到达时若在此直接 return，
      //    分段数会永久停留在 1：checkSegmentLoading 里 `segmentIndex < segments.length` 永不成立，
      //    第 2 段及以后永远不会加载 → 视频播过 6 分钟后弹幕彻底消失（用户反馈的"有些时候会没有弹幕"）。
      //    真实日志证据：duration=0 时 segments=1；随后 "duration更新，但cid相同，跳过重新加载"；
      //    播放到 t=671s 时可见弹幕数恒为 0（而该视频共有 15908 条弹幕）。
      //    修法：按时长对分段列表做一次【只扩容、不丢数据】的补齐，已加载的段原样保留、不重复下载。
      const before = this.segments.length
      const after = this.ensureSegments(duration)
      this.videoDuration = duration
      logInfo(`[DanmakuController] 相同cid=${cid}，弹幕已加载(${this.allDanmaku.length}条)，跳过重复下载；分段数 ${before} -> ${after}`)
      return
    }
    
    // 清空旧数据（新视频或首次加载）
    this.allDanmaku = []
    this.visibleDanmaku = []
    this.cachedCandidates = []
    this.timeBuckets.clear()
    this.lastUpdateTime = -1
    
    this.cid = cid
    this.aid = aid
    this.videoDuration = duration

    // 计算分段数量
    const segmentCount = this.service.calculateSegmentCount(duration)

    logInfo(`[DanmakuController] 初始化: cid=${cid}, aid=${aid}, duration=${duration}ms, segments=${segmentCount}`)

    // 创建分段对象
    this.segments = []
    for (let i = 1; i <= segmentCount; i++) {
      const init: DanmakuSegmentInit = {
        segmentIndex: i,
        startTime: (i - 1) * 360000,
        endTime: i * 360000
      }
      const segment = new DanmakuSegment(init)
      this.segments.push(segment)
    }

    // 预加载第一段弹幕
    if (this.segments.length > 0) {
      logInfo('[DanmakuController] 开始加载第一段弹幕...')
      await this.loadSegment(0)
    } else {
      logWarn('[DanmakuController] 没有创建任何分段')
    }
  }

  /**
   * 按时长【扩容】分段列表（已存在 / 已加载的分段原样保留，数据不丢、不重复下载）
   *
   * 为什么需要单独一个方法：分段数由时长决定，而时长是"稍后才知道"的 ——
   * 播放器页挂载时 duration 常为 0，只能建 1 个分段；真实时长到位后必须补齐，
   * 否则超过第一个 6 分钟分段的弹幕永远不会被请求。
   *
   * @param duration 视频真实时长（毫秒）
   * @returns 补齐后的分段总数
   */
  ensureSegments(duration: number): number {
    const need = this.service.calculateSegmentCount(duration)
    if (need <= this.segments.length) {
      return this.segments.length   // 已是够用（含 duration=0 退化成 1 段的情况），不动
    }

    for (let i = this.segments.length + 1; i <= need; i++) {
      const init: DanmakuSegmentInit = {
        segmentIndex: i,
        startTime: (i - 1) * 360000,
        endTime: i * 360000
      }
      this.segments.push(new DanmakuSegment(init))
    }
    return this.segments.length
  }

  /**
   * 播放器拿到真实时长后回填（只扩容分段，不触发任何下载）
   * 后续 updateTime → checkSegmentLoading 会在时间推进到对应分段时按需加载。
   */
  updateDuration(duration: number): void {
    if (duration <= 0) {
      return
    }
    const before = this.segments.length
    const after = this.ensureSegments(duration)
    this.videoDuration = duration
    if (after > before) {
      logInfo(`[DanmakuController] 时长补齐 ${duration}ms，分段数 ${before} -> ${after}`)
    }
  }

  /**
   * 加载指定分段
   */
  private async loadSegment(index: number): Promise<void> {
    if (index < 0 || index >= this.segments.length) {
      return
    }

    const segment = this.segments[index]
    if (segment.loaded || this.loadingSegments.has(index)) {
      return
    }

    // ⭐ 必须在发起请求【之前】打上"加载中"标记。
    //   原因：segment.loaded 要等 await 结束才置位，而 updateTime 每约 100ms 就会调一次
    //   checkSegmentLoading —— 网络往返期间（实测 1.7 万条要 ~4 秒）会有多次调用同时通过
    //   `!segment.loaded` 这个判定，于是各自发一次请求、各自把同一批弹幕 push 进 allDanmaku。
    //   实测后果：分段 2 被加载 4 次，总弹幕数从 3.2 万虚涨到 8.2 万，同一条弹幕被叠加绘制
    //   4 次（视觉上发粗发糊），并白白多跑 3 次 rebuildBuckets。这里用独立的 in-flight 集合兜住。
    this.loadingSegments.add(index)

    try {
    logInfo(`[DanmakuController] 加载分段 ${index + 1}/${this.segments.length}`)

    // 根据配置选择数据源（xml/grpc），传递 apiSource
    const loadedSegment = await this.service.loadDanmakuSegment(this.cid, index + 1, this.config.apiSource)

    // 如果是 XML 模式且第一段加载失败，回退到历史弹幕API
    const isXmlFallback = this.config.apiSource !== 'grpc' && loadedSegment.items.length === 0 && index === 0 && this.allDanmaku.length === 0
    if (isXmlFallback) {
      logInfo('[DanmakuController] 分段加载失败，尝试历史弹幕API')
      const historyItems = await this.service.loadHistoryDanmaku(this.cid, this.aid)
      if (historyItems.length > 0) {
        this.allDanmaku = this.preprocessItems(historyItems)
        this.rebuildBuckets()
        segment.loaded = true
        logInfo(`[DanmakuController] 历史弹幕加载完成，总弹幕数: ${this.allDanmaku.length}`)
        return
      }
    }

    // ⭐ gRPC 模式回退：如果分段返回空（B站API对后续分段可能返回空），尝试加载 XML 全量弹幕
    if (this.config.apiSource === 'grpc' && loadedSegment.items.length === 0 && !this.grpcFallbackLoaded) {
      logInfo('[DanmakuController] gRPC分段返回空，尝试XML全量弹幕回退')
      this.grpcFallbackLoaded = true
      try {
        const xmlItems = await this.service.loadXmlDanmaku(this.cid)
        if (xmlItems.length > 0) {
          this.allDanmaku.push(...this.preprocessItems(xmlItems))
          this.allDanmaku.sort((a: DanmakuItem, b: DanmakuItem) => a.time - b.time)
          this.rebuildBuckets()
          logInfo(`[DanmakuController] XML回退成功，补充 ${xmlItems.length} 条弹幕，总数: ${this.allDanmaku.length}`)
          segment.loaded = true
          return
        }
      } catch (err) {
        logError(`[DanmakuController] XML回退加载异常: ${err}`)
      }
    }

    // 合并到总弹幕列表（先过滤 + 同内容合并去重）
    this.allDanmaku.push(...this.preprocessItems(loadedSegment.items))
    this.allDanmaku.sort((a: DanmakuItem, b: DanmakuItem) => a.time - b.time)
    this.rebuildBuckets()

    segment.loaded = true

    logInfo(`[DanmakuController] 分段 ${index + 1} 加载完成，总弹幕数: ${this.allDanmaku.length}`)
    } finally {
      // 无论成功、失败还是走了回退分支，都必须摘掉"加载中"标记，
      // 否则该分段会被永久卡在 in-flight 状态、再也无法重试。
      this.loadingSegments.delete(index)
    }
  }

  /**
   * ⭐ 弹幕预处理（数据加载期一次性执行，避免渲染期每帧重复过滤）
   * 1) 屏蔽过滤：shouldFilter 的弹幕直接丢弃，不进渲染管线
   * 2) 同内容合并：相同 content 合并为一条，count 累加，渲染显示 ×N
   * @param items 原始弹幕列表
   * @returns 处理后的弹幕列表
   */
  private preprocessItems(items: DanmakuItem[]): DanmakuItem[] {
    if (items.length === 0) {
      return items
    }

    const result: DanmakuItem[] = []
    const merged: Map<string, DanmakuItem> = new Map()

    for (let i = 0; i < items.length; i++) {
      const item = items[i]

      // ① 屏蔽过滤（前置）：规则在数据加载时生效，丢弃即不再渲染
      if (this.filter.shouldFilter(item)) {
        continue
      }

      // ② 同内容合并：保留第一条，count 累加（热门弹幕合并后渲染压力骤降）
      // ⚠️ 合并键必须带上【时间桶】。原先只用 content 作键，而这里处理的是整整一个
      //    360 秒分段的弹幕 —— 等于说 6 分钟内所有相同内容的弹幕会被合并成一条，
      //    且只保留【第一条的时间】；第一个时间点之后所有相同的弹幕全部消失，
      //    用户看到的就是"某些时间段几乎没有弹幕"。
      //    改成同一秒（1024ms 桶）内才合并，既压掉真刷屏又不吞掉后续时间的弹幕。
      const mergeKey = `${item.time >> 10}#${item.content}`
      const existing = merged.get(mergeKey)
      if (existing) {
        existing.count++
      } else {
        merged.set(mergeKey, item)
        result.push(item)
      }
    }

    // 合并完成后，将 count>1 的条目内容更新为 "原文 ×N"，
    // 保证宽度估算、碰撞检测与绘制内容一致
    for (let i = 0; i < result.length; i++) {
      const item = result[i]
      if (item.count > 1) {
        item.content = `${item.content} ×${item.count}`
      }
    }

    return result
  }

  /**
   * ⭐ 重建 0.1s 时间分桶索引（在数据进入 allDanmaku 后调用）
   * key = Math.floor(item.time / 100)，播放时 O(桶数) 取档
   */
  private rebuildBuckets(): void {
    this.timeBuckets.clear()
    for (let i = 0; i < this.allDanmaku.length; i++) {
      const item = this.allDanmaku[i]
      const key = Math.floor(item.time / 100)
      let bucket = this.timeBuckets.get(key)
      if (bucket === undefined) {
        bucket = []
        this.timeBuckets.set(key, bucket)
      }
      bucket.push(item)
    }
  }

  /**
   * 设置画布尺寸
   */
  setCanvasSize(width: number, height: number): void {
    this.canvasWidth = width
    this.trackManager.initialize(width, height)
    this.renderer.setSize(width, height)
    logInfo(`[DanmakuController] 画布尺寸: ${width}x${height}`)
  }

  /**
   * 设置渲染上下文
   */
  setRenderContext(context: CanvasRenderingContext2D): void {
    this.renderer.setContext(context)
  }

  /**
   * 设置Cookie
   */
  setCookie(cookie: string): void {
    this.service.setCookie(cookie)
  }

  /**
   * 更新播放时间
   * @param time 当前播放时间（毫秒）
   */
  async updateTime(time: number): Promise<void> {
    // ⭐ seek 检测：时间跳变超过 5 秒说明发生了跳转（拖进度条 / 切集 / 续播定位）。
    //   此时屏幕上遗留的滚动弹幕，位置是基于旧时间一帧帧推进出来的，与新时间点完全对不上，
    //   必须整体重置，否则会出现"弹幕停在半路不动""新旧弹幕挤在一起"这类错乱。
    //   阈值取 5 秒（而不是 2 秒）：正常播放的 timeUpdate 间隔通常 100ms~1s，
    //   但卡顿时可能拉长到数秒，阈值太小会把卡顿误判成 seek、把弹幕反复清空。
    const prev = this.currentTime
    if (prev > 0 && Math.abs(time - prev) > 5000) {
      this.resetScrollingState()
    }

    this.currentTime = time

    // 检查是否需要加载新分段
    await this.checkSegmentLoading()

    // 更新轨道状态（释放过期轨道）
    this.trackManager.updateTracks(time)

    // ⭐ 渲染链自愈：播放中（isPlaying=true）但自调度链已经停掉时，重新拉起。
    //   为什么需要：链一旦中断（帧回调里抛异常、config.enable 短暂为 false 等），
    //   画面就永久静止在最后一帧 —— 位置不再推进，停在 x=canvasWidth 的弹幕滞留在右边缘，
    //   还把每条滚动轨道判成"放不下"，导致后续弹幕全部被丢弃。
    //   表现为"视频在播但弹幕不动 / 有时完全没有弹幕"，且无法自行恢复。
    //   有这一层兜底后，即使触发原因再出现，下一帧时间回调就会把渲染链救回来。
    if (this.isPlaying && this.config.enable && !this.renderActive) {
      logWarn('[DanmakuController] 渲染链已停止，自动重启')
      this.startRendering()
    }

    // 在时间变化时更新可见弹幕列表，而非每帧重算
    // 避免 filter + track assignment 在 render 循环（60fps）中反复执行
    this.updateVisibleDanmaku()
  }

  /**
   * 重置滚动弹幕的运行时状态（seek / 切集后调用）
   * 把轨道分配和位置全部作废，让弹幕按新的时间点重新分配、从右侧重新进入
   */
  private resetScrollingState(): void {
    // ⚠️ 必须遍历【全量弹幕】而不是只遍历 visibleDanmaku。
    //    原因：滚动弹幕一旦移出屏幕就会被 visibleDanmaku 剔除，但它们仍留在 allDanmaku 里，
    //    且 track 仍是旧轨道号（>=0）、x 冻结在屏幕外。seek 回到之前看过的时间点后，
    //    这些弹幕重新落进时间窗口，却会被 updateVisibleDanmaku 的可见性判定读成
    //    "已分配轨道 + 位置在屏外" → 直接剔除；而分配轨道那一步只处理 track<0 的项，
    //    于是它们永远不会被重新分配 → 表现为"往回拖进度条后弹幕明显变少、甚至一条都没有"。
    //    这里统一作废全部项的运行时状态，让它们按新时间点重新分配、重新从右侧进入。
    for (let i = 0; i < this.allDanmaku.length; i++) {
      const item = this.allDanmaku[i]
      item.track = -1
      item.dropped = false
      item.visible = true
      // ⭐ missed 必须一起清：seek 到之前看过的时间点后，那些"当时被挤掉"的弹幕
      //   需要重新获得一次上屏机会，否则往回拖之后弹幕会明显变少。
      item.missed = false
    }
    this.visibleDanmaku = []
    this.cachedCandidates = []
    this.lastUpdateTime = -1          // 强制下次重算候选（跳过 <100ms 的缓存分支）
    this.trackManager.clearTracks()
    logInfo(`[DanmakuController] 检测到时间跳变，已重置弹幕滚动状态（全量 ${this.allDanmaku.length} 条）`)
  }

  /**
   * 检查是否需要加载新分段
   */
  private async checkSegmentLoading(): Promise<void> {
    // 计算当前时间对应的分段索引
    const segmentIndex = Math.floor(this.currentTime / 360000)

    // ⭐ 记录切段日志（不再以切换作为加载触发条件）
    if (segmentIndex !== this.currentSegment) {
      this.currentSegment = segmentIndex
      logInfo(`[DanmakuController] 切换到分段 ${segmentIndex + 1}`)
    }

    // ⭐ 每次时间更新都确保当前段+下一段已加载（loaded 幂等；加载失败可自然重试，
    // 修复长视频深位置（如25min）新挂载实例只预载第1段、当前段无任何请求导致空白的问题）
    if (segmentIndex < this.segments.length && !this.segments[segmentIndex].loaded) {
      await this.loadSegment(segmentIndex)
    }

    // 预加载下一段
    if (segmentIndex + 1 < this.segments.length) {
      await this.loadSegment(segmentIndex + 1)
    }
  }

  /**
   * 更新可见弹幕列表（优化版）
   */
  private updateVisibleDanmaku(): void {
    // 优化：如果时间变化小于100ms，使用缓存的候选弹幕
    const timeDiff = Math.abs(this.currentTime - this.lastUpdateTime)
    const useCache = timeDiff < 100 && this.cachedCandidates.length > 0

    // ⭐ 候选窗口按【实际滚动耗时】计算，不再固定前后各 30 秒。
    //   滚动弹幕穿越屏幕耗时 = (canvasWidth + width) / speed
    //                          = 7000 / config.speed 毫秒（与宽度无关，因为速度随宽度同比放大）
    //   7000 = 官方 `danmakuDuration` 默认 7 秒（原来是 8000）。
    //   ⚠️ 收窄是安全的：弹幕一旦超过这个时长必然已滚出屏幕，"再晚显示"也没有意义；
    //   同时把 maxCount 与轨道配额的竞争范围缩小，反而更贴近 B 站"该出现的时刻就出现"。
    const rollCrossMs = this.config.speed > 0 ? 7000 / this.config.speed : 7000
    const trailWindow = Math.min(30000, Math.max(11000, Math.ceil(rollCrossMs) + 3000))
    // ⭐ 前向窗口只需要很小的容差：下面的可见性判定要求 currentTime >= item.time，
    //   任何"未来弹幕"都会被直接丢弃。原先也开 30 秒，等于每次白收集一半用不上的弹幕
    //   （分桶扫描量翻倍），纯浪费。
    const forwardWindow = 1000

    let candidates: DanmakuItem[]

    if (useCache) {
      // 使用缓存的候选弹幕
      candidates = this.cachedCandidates
    } else {
      // ⭐ 0.1s 时间分桶取档（仿 PiliPlus _dmSegMap）：直接按桶范围收集，替代二分+线性扫描
      const minTime = Math.max(0, this.currentTime - trailWindow)
      const maxTime = this.currentTime + forwardWindow
      const minBucket = Math.floor(minTime / 100)
      const maxBucket = Math.floor(maxTime / 100)

      candidates = []
      for (let b = minBucket; b <= maxBucket; b++) {
        const bucket = this.timeBuckets.get(b)
        if (bucket !== undefined) {
          for (let i = 0; i < bucket.length; i++) {
            candidates.push(bucket[i])
          }
        }
      }

      // 更新缓存
      this.cachedCandidates = candidates
      this.lastUpdateTime = this.currentTime
    }

    // ⭐ 单次遍历同时完成「时间窗口筛选」和「出屏弹幕剔除」（原先分两趟 filter，
    //   候选集上千条时每 100ms 就要多走一趟，白白多一遍回调开销）。
    //
    //   为什么必须剔除出屏弹幕：时间窗口是"滚动弹幕最多滚多久"的经验值，它会让
    //   【窗口内出现过的所有弹幕】都留在候选里，而其中大多数早已滚出屏幕。
    //   这些幽灵弹幕会占满 maxCount 配额，把真正该显示的新弹幕挤掉，
    //   表现为"密集时段新弹幕反而不出现"。
    const now = this.currentTime
    const canvasW = this.canvasWidth
    const visible = candidates.filter((item: DanmakuItem) => {
      // 出现时间未到 → 一律不可见（顺带把未来弹幕挡在窗口外）
      if (now < item.time) {
        return false
      }

      // ⭐ 未分配过轨道的弹幕必须处在自己的【注入窗口】内，否则永久跳过。
      //   对齐官方/PiliPlus：一条弹幕只在它自己的时间点（100ms 桶）尝试上屏一次，
      //   轨道放不下就丢弃，**不会**在几秒后轨道空出来时再补显示。
      //   没有这条限制时，过去 11~30 秒内所有分配失败的旧弹幕会持续重试，
      //   一旦轨道空出来就集体涌入 → 屏幕上冒出与当前画面无关的迟到弹幕。
      //   容差 1000ms 是留给"分段数据晚到"的（网络往返导致的几百毫秒延迟不算迟到）。
      if (item.track < 0 && (item.missed || now - item.time > INJECT_GRACE_MS)) {
        return false
      }

      if (item.isScrolling()) {
        // ⭐ 用"这条弹幕自己的穿越时长"兜底：scrollFixedVelocity 模式下宽弹幕的实际 duration
        //    会超过全局 trailWindow，只按全局值判定会让它滚到屏幕中间被剔除（凭空消失）。
        //    取 max —— 任何情况下都不会早于它自己的生存期被移除。
        const life = item.duration > 0 ? item.duration + 1000 : trailWindow
        if (now > item.time + Math.max(trailWindow, life)) {
          return false
        }
        // 未分配过轨道的还无从判断位置，保留（下一段会尝试分配轨道）
        if (item.track < 0) {
          return true
        }
        // 完全离开视口：尾部已越过左边界，或整体仍在右边界之外
        return !(item.x + item.width < 0 || item.x > canvasW)
      }

      // 静止弹幕（顶部/底部）：按各自的停留时长判定（默认 4 秒，对齐官方 staticDuration）
      const duration = item.duration > 0 ? item.duration : 4000
      return now <= item.time + duration
    })

    this.visibleDanmaku = visible

    // ⭐ 为新弹幕分配轨道；分配失败的标记 dropped 并在本帧列表里移除。
    //   为什么必须移除：顶/底弹幕轨道只有 5 条，满员时 assignTrack 返回 -1，而这些弹幕的
    //   x/y 还停在默认值 0，留在列表里就会被画到画布左上角（表现是"弹幕跑到边角、没对齐"）。
    //   移除后，等轨道空出来的下一帧它还会重新参与分配，相当于"让位后再显示"。
    const assigned: DanmakuItem[] = []
    for (let i = 0; i < this.visibleDanmaku.length; i++) {
      const item = this.visibleDanmaku[i]
      // ⭐ 播放途中被面板改过的屏蔽开关（按类型 / 彩色 / 云屏蔽等级）在这里即时生效。
      //   不能只靠加载期的 shouldFilter：那时候数据早就进管线了，
      //   而用户勾掉"顶部弹幕"时**上半屏正在显示的顶部弹幕必须当场消失**。
      if (this.filter.shouldFilterRuntime(item)) {
        item.visible = false
        continue
      }
      if (item.track < 0) {
        // ⭐ 分配轨道前先定好两件事，因为轨道碰撞检测与出屏判定都依赖它们：
        //   ① 绘制字号（B站原始字号 → 按 config 归一化，大小号收敛到 0.8~1.15 倍）
        //   ② 真实宽度（measureText，带缓存；拿不到上下文时 assignTrack 内部退回估算值）
        this.trackManager.normalizeFontSize(item)
        const measured = this.renderer.measureWidth(item.content, item.fontSize)
        if (measured > 0) {
          item.width = measured
          item.widthFontSize = item.fontSize
        }
        const track = this.trackManager.assignTrack(item, this.currentTime)
        if (track < 0) {
          item.dropped = true
          // ⭐ 对齐官方：这一时刻放不下就【永久丢弃】。
          //   不标记的话，它会在后续每一帧继续重试，等几秒后轨道空出来再冒出来 ——
          //   那条弹幕的内容已经和当前画面对不上了（"迟到弹幕"）。
          item.missed = true
          continue
        }
      }
      item.dropped = false
      // ⭐ 重置可见标志：刚从 allDanmaku 加入的弹幕可能之前被渲染器标记为不可见
      item.visible = true
      assigned.push(item)
    }
    this.visibleDanmaku = assigned

    // ⭐ 限制最大数量：优先保留【已在屏幕上】（已分配轨道）的弹幕，剩余名额给最新的。
    //   原实现直接 slice(0, maxCount)，而列表是按时间升序排的 —— 等于永远砍掉队尾的新弹幕，
    //   密集时段新弹幕被系统性挤掉（"该出现的没出现"）。
    if (this.visibleDanmaku.length > this.config.maxCount) {
      const onScreen: DanmakuItem[] = []
      const pending: DanmakuItem[] = []
      for (let i = 0; i < this.visibleDanmaku.length; i++) {
        const it = this.visibleDanmaku[i]
        if (it.track >= 0) {
          onScreen.push(it)
        } else {
          pending.push(it)
        }
      }
      if (onScreen.length >= this.config.maxCount) {
        this.visibleDanmaku = onScreen.slice(0, this.config.maxCount)
      } else {
        // pending 同为时间升序，取尾部 = 用最新的若干条把名额补满
        const rest = this.config.maxCount - onScreen.length
        this.visibleDanmaku = onScreen.concat(pending.slice(Math.max(0, pending.length - rest)))
      }
    }

    // 更新统计信息
    this.stats.displayedCount = this.visibleDanmaku.length
    this.stats.totalCount = this.allDanmaku.length
  }

  /**
   * 开始渲染
   * 自调度循环：有可见弹幕时 60fps 流畅渲染，无弹幕时 250ms 低频轮询（空弹幕停帧省电）
   */
  startRendering(): void {
    // ⚠️ 这里原先判断的是 `if (this.renderTimer) return`，而 renderTimer 是 setTimeout 的 id，
    //    自调度链一旦终止，renderTimer 仍留着上一次的旧 id（非 0）→ 本方法会永远直接 return，
    //    渲染链再也无法恢复。实测后果就是：视频一直在播、updateTime 每秒触发 10 次，
    //    但画布不再重绘 —— 停在 x=canvasWidth 的弹幕永远滞留在右边缘（"右侧挤成一堆"），
    //    同时它们把每条轨道判成"放不下"，后续弹幕全被丢弃（"有时没有弹幕"）。
    //    改用独立的 renderActive 标志判断，保证链停掉后仍可重新拉起。
    if (this.renderActive) {
      return
    }

    this.renderActive = true
    this.isPlaying = true
    this.lastRenderTime = Date.now()
    this.lastFrameTimestamp = 0  // 重置帧时间，避免恢复播放时产生大dt跳帧

    this.scheduleNextFrame()

    logInfo('[DanmakuController] 开始渲染 (自调度)')
  }

  /**
   * 调度下一帧
   * 有可见弹幕：16ms（约60fps）流畅渲染
   * 无可见弹幕：250ms 低频轮询，仅刷新可见列表检查新弹幕，避免 60fps 空转耗电
   */
  private scheduleNextFrame(): void {
    // 不再继续调度时必须把 renderActive 与 renderTimer 一并复位，
    // 否则渲染链处于"已死但标志未清"的状态，之后永远无法重启。
    if (!this.isPlaying || !this.config.enable) {
      this.renderActive = false
      this.renderTimer = 0
      return
    }

    const interval = this.visibleDanmaku.length > 0 ? 16 : 250

    this.renderTimer = setTimeout(() => {
      // ⭐ 帧回调必须包住异常：render() 里任何一处抛错都会中断自调度链，
      //   而链中断是静默的（没有崩溃弹窗、日志里也看不到），排查成本极高。
      //   catch 里只记录一次，finally 保证链继续往下走。
      try {
        this.render()
      } catch (e) {
        logError(`[DanmakuController] 渲染帧异常（已捕获，不影响后续帧）: ${JSON.stringify(e)}`)
      } finally {
        this.scheduleNextFrame()
      }
    }, interval)
  }

  /**
   * 停止渲染
   */
  stopRendering(): void {
    if (this.renderTimer) {
      clearTimeout(this.renderTimer)
      this.renderTimer = 0
    }

    this.renderActive = false
    this.isPlaying = false
    this.lastFrameTimestamp = 0  // 重置帧时间，避免恢复播放时产生大dt跳帧
    // 注意：不清空画布，保留最后一帧弹幕，便于暂停时仍可见

    logInfo('[DanmakuController] 停止渲染')
  }

  /**
   * 执行渲染
   */
  private render(): void {
    if (!this.isPlaying || !this.config.enable) {
      return
    }

    const now = Date.now()

    // 空弹幕（低频轮询模式）：只刷新可见列表检查新弹幕，不重绘画布
    if (this.visibleDanmaku.length === 0) {
      this.updateVisibleDanmaku()
      if (this.visibleDanmaku.length === 0) {
        // 仍无弹幕：清掉已滚出屏幕的残留画面（250ms 一次，成本可忽略）
        this.renderer.render(this.visibleDanmaku, this.currentTime, 16)
        this.lastFrameTimestamp = now  // 保持帧时间连续，恢复 60fps 时 dt 正常
        return
      }
      // 刷新后有弹幕出现：fall through 走正常渲染
      this.lastFrameTimestamp = now
    }

    // 计算帧间增量时间(dt)：用真实时间差推进弹幕位置
    // 独立于 currentTime 的更新频率，保证60fps流畅滚动
    const dt = this.lastFrameTimestamp > 0 ? now - this.lastFrameTimestamp : 16
    this.lastFrameTimestamp = now

    // 限制最大dt：只用于挡"页面被挂起/极端卡顿"这类异常，不能收得太紧。
    //   ⚠️ 原先截到 50ms 反而是 bug：dt 本身就是真实经过的时间，弹幕"应该"走这么远，
    //   截断只会让它永久落后于真实进度，累积起来就是弹幕越来越偏向右侧（视觉上堆积），
    //   而且 seek/暂停恢复后也无法自愈。放宽到 200ms 足以消除正常掉帧造成的漂移。
    const cappedDt = Math.min(dt, 200)

    const startTime = now

    // 使用增量时间(dt)推进滚动位置，每帧移动固定像素量
    this.renderer.render(this.visibleDanmaku, this.currentTime, cappedDt)

    // 更新统计信息
    this.stats.renderTime = Date.now() - startTime

    // 触发回调
    if (this.onStatsUpdate) {
      this.onStatsUpdate(this.stats)
    }
  }

  /**
   * 添加弹幕（实时发送）
   */
  addDanmaku(item: DanmakuItem): void {
    // 添加到列表
    this.allDanmaku.push(item)

    // ⭐ 同步加入 0.1s 时间分桶索引
    const key = Math.floor(item.time / 100)
    let bucket = this.timeBuckets.get(key)
    if (bucket === undefined) {
      bucket = []
      this.timeBuckets.set(key, bucket)
    }
    bucket.push(item)

    // 立即分配轨道（与 updateVisibleDanmaku 路径保持一致：先归一化字号 + 取真实宽度）
    this.trackManager.normalizeFontSize(item)
    const mw = this.renderer.measureWidth(item.content, item.fontSize)
    if (mw > 0) {
      item.width = mw
      item.widthFontSize = item.fontSize
    }
    this.trackManager.assignTrack(item, this.currentTime)

    // 添加到可见列表
    this.visibleDanmaku.push(item)

    logInfo(`[DanmakuController] 添加弹幕: ${item.content}`)
  }

  /**
   * 发送弹幕到服务器
   */
  async sendDanmaku(content: string, color: number = 0xFFFFFF): Promise<boolean> {
    // TODO: 调用B站API发送弹幕
    logInfo(`[DanmakuController] 发送弹幕: ${content}`)

    // 模拟添加到本地
    const init: DanmakuItemInit = {
      id: Date.now(),
      content: content,
      time: this.currentTime,
      color: color,
      fontSize: this.config.fontSize
    }
    const item = new DanmakuItem(init)

    this.addDanmaku(item)
    return true
  }

  /**
   * ⭐「弹幕设置」面板改动后的应用入口（此前没有任何调用点 —— 改完设置要重进播放页才生效）。
   *
   * 与 `updateConfig()` 的区别：
   *   - `updateConfig()` 会替换 config 引用并让渲染器清空所有宽度/字体缓存，适合"换了一个
   *     配置对象"的场景；而本项目严格禁止换对象（controller/renderer/filter 都持有构造时的引用），
   *     面板改的只是**同一个对象上的字段**，调它反而白白清掉大量缓存。
   *   - 这里只需要两件事：让轨道按新字号/显示区/行高**就地重算**（`updateGeometry`，
   *     保留正在滚动的弹幕，不会像 `initialize` 那样把轨道状态清空导致叠字），
   *     以及让渲染器作废"按字号缓存的文本宽度/绘制状态"。
   */
  applyDisplaySettings(width: number, height: number): void {
    this.canvasWidth = width
    this.trackManager.updateGeometry(width, height)
    this.filter.updateConfig(this.config)
    this.renderer.setSize(width, height)
    this.renderer.updateConfig(this.config)
    logInfo(`[DanmakuController] 弹幕显示设置已应用: ${width}x${height}`)
  }

  /**
   * 更新配置
   */
  updateConfig(config: DanmakuConfig): void {
    this.config = config
    this.trackManager.initialize(this.renderer.getPerformanceStats().canvasWidth,
      this.renderer.getPerformanceStats().canvasHeight)
    this.filter.updateConfig(config)
    this.renderer.updateConfig(config)

    logInfo('[DanmakuController] 配置已更新')
  }

  /**
   * 设置统计更新回调
   */
  setStatsCallback(callback: (stats: DanmakuStats) => void): void {
    this.onStatsUpdate = callback
  }

  /**
   * 获取统计信息
   */
  getStats(): DanmakuStats {
    return this.stats
  }

  /**
   * 清空所有弹幕
   */
  clear(): void {
    this.allDanmaku = []
    this.visibleDanmaku = []
    this.timeBuckets.clear()
    this.cachedCandidates = []
    this.segments.forEach((segment: DanmakuSegment) => {
      segment.loaded = false
    })
    this.trackManager.clearTracks()
    this.renderer.clear()

    logInfo('[DanmakuController] 清空所有弹幕')
  }

  /**
   * 销毁控制器
   */
  destroy(): void {
    this.stopRendering()
    this.service.destroy()
    this.clear()

    logInfo('[DanmakuController] 已销毁')
  }
}
