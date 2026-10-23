/**
 * 弹幕UI组件
 * 可直接集成到视频播放器中
 * 
 * 性能优化：
 * - 使用@Reusable装饰器实现组件复用，避免销毁重建
 * - 实现aboutToReuse方法复用已有controller
 */
import { DanmakuItem, DanmakuConfig, DanmakuStats } from '../model/DanmakuItem'
import { logInfo, logWarn, logError } from '../utils/Logger';
import { DanmakuController } from '../services/DanmakuController'

// ⭐ 不使用 @Reusable：复用会把旧位置的 Canvas/渲染上下文一起带到新位置，
// onReady 不再触发 → 渲染到失效画布（关灯切换到视频外弹幕时表现为不显示）
@Component
export struct DanmakuView {
  // 配置参数
  @Prop cid: number = 0                    // 视频cid
  @Prop aid: number = 0                    // 视频aid
  @Prop @Watch('onDurationChange') duration: number = 0               // 视频时长（毫秒）
  @Prop @Watch('onTimeChange') currentTime: number = 0  // 当前播放时间（毫秒）
  @Prop @Watch('onPlayingChange') isPlaying: boolean = false  // 是否播放中
  // ⭐ 后台门控：App 退后台（屏幕熄灭）时停止弹幕渲染，回前台恢复
  @StorageProp('appInBackground') @Watch('onAppBackgroundChange') appInBackground: boolean = false
  @Prop cookie: string = ''                // Cookie
  
  // 尺寸参数（用于强制刷新Canvas）
  @Prop @Watch('onCanvasSizeChange') canvasWidth: number = 0
  @Prop @Watch('onCanvasSizeChange') canvasHeight: number = 0

  // ⭐「弹幕设置」面板的版本号：页面每次改完设置自增它，这里 @Watch 到就把新的几何
  //   （字号 / 显示区域 / 行高 / 全屏缩放）应用到本组件的 controller。
  //   为什么走 AppStorage 而不是新增 @Prop：本组件在页面里有 4 个挂载点，
  //   逐个加 @Prop 要改 4 处调用、还容易漏；@StorageLink 一处收口。
  @StorageLink('danmakuSettingVersion') @Watch('onSettingVersionChange') dmSettingVersion: number = 0

  // 配置状态（可通过外部修改）
  @Link config: DanmakuConfig

  // ⭐ 用户自己发送的弹幕（发送成功后页面追加，这里注入到弹幕流立即上屏）
  @Link @Watch('onSelfDanmakuChange') selfDanmaku: DanmakuItem[]

  // 统计信息回调
  private onStatsUpdate: ((stats: DanmakuStats) => void) | null = null

  // 弹幕控制器
  private controller: DanmakuController | null = null
  private canvasContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true))

  // 初始化标志
  private initialized: boolean = false
  private canvasReady: boolean = false
  private lastCid: number = 0
  private isReusing: boolean = false  // 组件复用标志
  private isLoading: boolean = false  // 加载锁，防止并发初始化
  private pendingSelfDanmaku: DanmakuItem | null = null  // 弹幕流就绪前暂存的自发弹幕

  /**
   * 自发弹幕注入：@Watch（数组重新赋值触发）
   */
  private onSelfDanmakuChange(): void {
    if (!this.selfDanmaku || this.selfDanmaku.length === 0) return
    const item = this.selfDanmaku[this.selfDanmaku.length - 1]
    if (!item || item.content === '') return
    if (this.controller && this.initialized) {
      try {
        this.controller.addDanmaku(item)
      } catch (err) {
        logWarn(`[DanmakuView] 注入自发弹幕失败: ${err}`)
      }
    } else {
      // 弹幕数据尚未加载完成，先暂存，初始化完成后注入
      this.pendingSelfDanmaku = item
    }
  }

  /**
   * 弹幕流初始化完成后，注入暂存的自发弹幕
   */
  private tryInjectPendingSelfDanmaku(): void {
    if (this.pendingSelfDanmaku && this.controller) {
      try {
        this.controller.addDanmaku(this.pendingSelfDanmaku)
      } catch (err) {
        logWarn(`[DanmakuView] 注入暂存弹幕失败: ${err}`)
      }
      this.pendingSelfDanmaku = null
    }
  }
  
  // Canvas尺寸防抖
  private canvasSizeDebounceTimer: number = 0
  private pendingCanvasWidth: number = 0
  private pendingCanvasHeight: number = 0
  
  // 注意：时间同步仅靠 @Watch('onTimeChange') 驱动，不再使用独立定时器
  // 避免 @Watch + 定时器两套机制重复调用 controller.updateTime()

  aboutToAppear(): void {
    logInfo('[DanmakuView] aboutToAppear开始')
    logInfo(`[DanmakuView] 参数: cid=${this.cid}, aid=${this.aid}, duration=${this.duration}, isPlaying=${this.isPlaying}`)
    
    // 检查是否是组件复用（aboutToReuse先被调用）
    if (this.isReusing) {
      logInfo(`[DanmakuView] 组件复用模式，保留已有状态: initialized=${this.initialized}, lastCid=${this.lastCid}`)
      this.isReusing = false  // 重置复用标志
      return
    }
    
    // 只有在controller不存在时才创建新的
    // 组件复用时，aboutToReuse会保留controller，aboutToAppear也会被调用
    if (!this.controller) {
      // 初始化控制器
      this.controller = new DanmakuController(this.config)

      // 设置统计回调
      this.controller.setStatsCallback((stats: DanmakuStats) => {
        if (this.onStatsUpdate) {
          this.onStatsUpdate(stats)
        }
      })

      logInfo('[DanmakuView] 组件初始化完成')
    } else {
      logInfo(`[DanmakuView] controller已存在，initialized=${this.initialized}, lastCid=${this.lastCid}`)
    }
  }

  aboutToDisappear(): void {
    // 停止Canvas尺寸防抖定时器
    if (this.canvasSizeDebounceTimer) {
      clearTimeout(this.canvasSizeDebounceTimer)
      this.canvasSizeDebounceTimer = 0
    }

    // 注意：不要在这里销毁controller，因为组件可能被复用
    // 只停止渲染，保留controller供复用
    if (this.controller) {
      this.controller.stopRendering()
    }

    logInfo('[DanmakuView] 组件销毁')
  }

  /**
   * 组件复用回调（@Reusable装饰器）
   * 当组件从复用缓存中取出时调用，避免重新创建controller
   */
  aboutToReuse(params: Record<string, Object>): void {
    logInfo('[DanmakuView] aboutToReuse: 组件被复用')
    
    // 设置复用标志，防止aboutToAppear重置状态
    this.isReusing = true
    
    // 注意：不清空 canvasReady，因为组件复用后 Canvas 上下文仍然有效
    // 不复位 initialized 和 lastCid，保留已加载的弹幕数据
    
    if (this.controller) {
      this.controller.stopRendering()
      logInfo('[DanmakuView] 复用已有controller，initialized=' + this.initialized + ', lastCid=' + this.lastCid)
      
      // 如果正在播放，立即恢复渲染（@Watch onPlayingChange 在值未变时不会触发）
      if (this.isPlaying && this.initialized) {
        this.controller.startRendering()
        logInfo('[DanmakuView] 复用后立即恢复渲染')
      }
    }
  }

  // 上次处理的播放时间（毫秒），用于防抖
  private lastProcessedTime: number = -1

  /**
   * 播放时间变化回调
   */
  private async onTimeChange(): Promise<void> {
    // ⭐ 防抖：@Prop 传播偶尔会触发两次相同时间的 @Watch，跳过重复处理
    if (Math.abs(this.currentTime - this.lastProcessedTime) < 1) {
      return
    }
    // ⭐ 只在"异常跳变"时打日志。播放中 timeUpdate 约每 100ms 一次，逐条记录会以
    //    10 条/秒的速度灌满 hilog 环形缓冲（实测 90 秒内 1476 条），既冲掉真正有用的
    //    上下文，也让每次日志写入参与主线程调度。正常推进不再记录，跳变（seek/切集/
    //    续播定位）仍保留，排查弹幕错位时看这一条即可。
    if (this.lastProcessedTime > 0 && Math.abs(this.currentTime - this.lastProcessedTime) > 1000) {
      logInfo(`[DanmakuView] 时间跳变: ${this.lastProcessedTime}ms -> ${this.currentTime}ms, initialized=${this.initialized}`)
    }
    this.lastProcessedTime = this.currentTime
    if (this.controller && this.initialized) {
      await this.controller.updateTime(this.currentTime)
    }
  }
  
  /**
   * 尺寸变化回调
   */
  private onCanvasSizeChange(): void {
    // 忽略无效尺寸
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      logWarn(`[DanmakuView] onCanvasSizeChange: 无效尺寸 ${this.canvasWidth}x${this.canvasHeight}`)
      return
    }
    
    // 防抖：延迟100ms处理，避免频繁触发
    this.pendingCanvasWidth = this.canvasWidth
    this.pendingCanvasHeight = this.canvasHeight
    
    if (this.canvasSizeDebounceTimer) {
      clearTimeout(this.canvasSizeDebounceTimer)
    }
    
    this.canvasSizeDebounceTimer = setTimeout(() => {
      if (this.controller && this.canvasReady && 
          this.pendingCanvasWidth > 0 && this.pendingCanvasHeight > 0) {
        this.controller.setCanvasSize(this.pendingCanvasWidth, this.pendingCanvasHeight)
        logInfo(`[DanmakuView] Canvas尺寸已更新: ${this.pendingCanvasWidth}x${this.pendingCanvasHeight}`)
      }
      this.canvasSizeDebounceTimer = 0
    }, 100)
  }

  /**
   * ⭐「弹幕设置」面板改动落地（字号 / 显示区域 / 行高 / 全屏缩放 / 时长）。
   * 只重算几何，**不重建 controller**（重建＝重新下载弹幕分段，会白屏几秒 + 重复流量）。
   */
  private onSettingVersionChange(): void {
    if (!this.controller || !this.canvasReady || this.dmSettingVersion <= 0) {
      return
    }
    // 尺寸优先取布局给的 Props；部分分支（外移实例）Props 为 0，退回 Canvas 自己的量测结果
    let w = this.canvasWidth
    let h = this.canvasHeight
    if (w <= 0 || h <= 0) {
      w = this.canvasContext.width
      h = this.canvasContext.height
    }
    if (w <= 0 || h <= 0) {
      logWarn('[DanmakuView] 弹幕设置变更但画布尺寸无效，跳过')
      return
    }
    this.controller.applyDisplaySettings(w, h)
  }

  /**
   * 视频时长变化回调
   */
  private onDurationChange(): void {
    logInfo(`[DanmakuView] duration变化: ${this.duration}ms`)
    
    // 如果duration从0变为有效值，且已经初始化过，需要重新加载弹幕
    if (this.duration > 0 && this.controller && this.canvasReady && this.cid > 0) {
      // 检查是否是同一个视频（lastCid === cid），如果是则不需要重新下载弹幕数据
      if (this.initialized && this.lastCid === this.cid) {
        // ⚠️ 这里原先直接 return，把"真实时长补齐"这一步丢掉了 —— 这是"播过 6 分钟后弹幕全消失"的直接成因。
        //    首次初始化时 duration 常为 0（播放器还没解析出时长），此时只建了 1 个分段，
        //    即只加载了【第 1 个 6 分钟】的弹幕；真实时长到位后若不同步给 controller，
        //    分段列表永远不扩容，checkSegmentLoading 也就永远不会去请求第 2 段及以后。
        //    现在改成"不重新下载、但要同步时长"，由 controller 按需扩容分段。
        logInfo('[DanmakuView] duration更新（cid相同），同步时长以扩容弹幕分段')
        this.controller.updateDuration(this.duration)
        return
      }
      
      if (this.initialized) {
        // 已经初始化过，但cid不同，需要重新加载弹幕数据
        logInfo('[DanmakuView] duration更新且cid变化，重新加载弹幕数据')
        this.reinitializeDanmaku()
      } else {
        // 还未初始化，尝试初始化
        logInfo('[DanmakuView] duration更新，尝试初始化弹幕')
        this.autoInitialize()
      }
    }
  }

  /**
   * 重新初始化弹幕数据（duration变化时）
   */
  private async reinitializeDanmaku(): Promise<void> {
    if (!this.controller || !this.canvasReady || this.cid <= 0 || this.duration <= 0) {
      return
    }

    // 检查是否是同一个视频，如果是则跳过
    if (this.lastCid === this.cid) {
      logInfo(`[DanmakuView] 相同cid=${this.cid}，跳过重新初始化`)
      return
    }

    logInfo(`[DanmakuView] 重新初始化弹幕: cid=${this.cid}, duration=${this.duration}ms`)

    // 停止渲染
    this.controller.stopRendering()

    // 设置Cookie
    if (this.cookie) {
      this.controller.setCookie(this.cookie)
    }

    try {
      // 重新初始化弹幕数据
      await this.controller.initialize(this.cid, this.aid, this.duration)
      
      // 更新标志
      this.initialized = true
      this.lastCid = this.cid
      logInfo('[DanmakuView] 弹幕数据重新初始化完成')
      this.tryInjectPendingSelfDanmaku()

      // 如果正在播放，开始渲染
      if (this.isPlaying && this.controller) {
        this.controller.startRendering()
        logInfo('[DanmakuView] 自动开始渲染')
      }
    } catch (error) {
      logError(`[DanmakuView] 重新初始化失败: ${error}`)
    }
  }

  /**
   * 播放状态变化回调
   */
  private onPlayingChange(): void {
    if (!this.controller || !this.initialized) {
      logWarn('[DanmakuView] onPlayingChange: controller未初始化或未完成初始化')
      return
    }

    if (this.isPlaying) {
      this.controller.startRendering()
      logInfo('[DanmakuView] 开始渲染')
    } else {
      this.controller.stopRendering()
      logInfo('[DanmakuView] 停止渲染')
    }
  }

  /**
   * App 前后台切换回调（@StorageProp('appInBackground') 驱动）
   * 退后台（屏幕熄灭/切走）时停止 60fps 渲染循环，回前台且播放中时恢复
   */
  private onAppBackgroundChange(): void {
    if (!this.controller) {
      return
    }

    if (this.appInBackground) {
      this.controller.stopRendering()
      logInfo('[DanmakuView] App切后台，停止弹幕渲染')
    } else if (this.isPlaying && this.initialized) {
      this.controller.startRendering()
      logInfo('[DanmakuView] App回前台，恢复弹幕渲染')
    }
  }

  build() {
    Stack() {
      // Canvas渲染层
      Canvas(this.canvasContext)
        .width('100%')
        .height('100%')
        .onReady(() => {
          this.onCanvasReady()
        })

      // 调试信息（可选）
      if (this.config.enable) {
        this.DebugOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * Canvas准备就绪
   */
  private onCanvasReady(): void {
    logInfo('[DanmakuView] onCanvasReady被调用')
    
    if (!this.controller) {
      logError('[DanmakuView] controller为null，无法初始化')
      return
    }

    // 获取画布尺寸
    const width = this.canvasContext.width
    const height = this.canvasContext.height
    
    logInfo(`[DanmakuView] Canvas尺寸: ${width}x${height}`)
    
    if (width <= 0 || height <= 0) {
      logError('[DanmakuView] Canvas尺寸无效（width或height <= 0），等待重新初始化')
      // 尝试延迟重新初始化（可能是尺寸还未设置）
      setTimeout(() => {
        const retryWidth = this.canvasContext.width
        const retryHeight = this.canvasContext.height
        logInfo(`[DanmakuView] 延迟重试Canvas尺寸: ${retryWidth}x${retryHeight}`)
        if (retryWidth > 0 && retryHeight > 0 && this.controller) {
          this.controller.setRenderContext(this.canvasContext)
          this.controller.setCanvasSize(retryWidth, retryHeight)
          this.canvasReady = true
          logInfo(`[DanmakuView] Canvas延迟就绪: ${retryWidth}x${retryHeight}`)
          this.autoInitialize()
        }
      }, 100)
      return
    }

    // 设置渲染上下文
    this.controller.setRenderContext(this.canvasContext)
    this.controller.setCanvasSize(width, height)

    this.canvasReady = true
    logInfo(`[DanmakuView] Canvas就绪: ${width}x${height}`)

    // 如果已经初始化过且cid相同，只需要更新Canvas尺寸并恢复渲染
    if (this.initialized && this.lastCid === this.cid && this.cid > 0) {
      logInfo('[DanmakuView] 组件复用：Canvas尺寸已更新，恢复渲染')
      if (this.isPlaying && this.controller) {
        this.controller.startRendering()
      }
      return
    }

    // 如果initialized为true但lastCid不同，说明是新视频，需要重新加载
    if (this.initialized && this.lastCid !== this.cid) {
      logInfo(`[DanmakuView] cid变化: ${this.lastCid} -> ${this.cid}，重新加载弹幕`)
      this.initialized = false  // 重置标志，允许重新初始化
    }

    // 自动初始化弹幕数据
    this.autoInitialize()
  }

  /**
   * 自动初始化弹幕数据
   */
  private async autoInitialize(): Promise<void> {
    logInfo(`[DanmakuView] autoInitialize被调用: controller=${this.controller !== null}, initialized=${this.initialized}, isLoading=${this.isLoading}, canvasReady=${this.canvasReady}, cid=${this.cid}`)
    
    // 检查加载锁，防止并发初始化
    if (this.isLoading) {
      logWarn('[DanmakuView] 正在加载中，跳过重复初始化')
      return
    }
    
    if (!this.controller || this.initialized || !this.canvasReady) {
      logWarn('[DanmakuView] 初始化条件不满足，跳过初始化')
      return
    }
    
    if (this.cid <= 0) {
      logWarn('[DanmakuView] cid无效，等待有效cid')
      return
    }

    // 设置加载锁
    this.isLoading = true
    logInfo(`[DanmakuView] 开始加载弹幕: cid=${this.cid}, aid=${this.aid}, duration=${this.duration}`)

    // 设置Cookie
    if (this.cookie) {
      this.controller.setCookie(this.cookie)
      logInfo('[DanmakuView] Cookie已设置')
    } else {
      logWarn('[DanmakuView] Cookie为空，可能无法加载弹幕')
    }

    try {
      // 初始化弹幕数据
      logInfo('[DanmakuView] 调用controller.initialize...')
      await this.controller.initialize(this.cid, this.aid, this.duration)

      this.initialized = true
      this.lastCid = this.cid
      logInfo('[DanmakuView] 弹幕数据初始化完成')
      this.tryInjectPendingSelfDanmaku()

      // ⭐ 同步当前播放时间到控制器
      // 初始化完成前 onTimeChange() 因 initialized=false 跳过同步，
      // 这里补调确保 controller.currentTime 与视频实时进度一致
      this.controller.updateTime(this.currentTime)
      logInfo(`[DanmakuView] 初始化后同步当前时间: ${this.currentTime}ms`)

      // 如果正在播放，开始渲染
      if (this.isPlaying && this.controller) {
        this.controller.startRendering()
        logInfo('[DanmakuView] 自动开始渲染')
      }
    } catch (error) {
      logError(`[DanmakuView] 初始化失败: ${error}`)
      this.initialized = false
    } finally {
      // 释放加载锁
      this.isLoading = false
    }
  }

  /**
   * 调试信息覆盖层
   */
  @Builder
  DebugOverlay() {
    // 可选：显示FPS、弹幕数量等调试信息
    // 这里暂时留空，实际使用时可以添加
  }
}

/**
 * 弹幕配置面板组件
 */
@Component
export struct DanmakuConfigPanel {
  @Link config: DanmakuConfig
  @State visible: boolean = false

  build() {
    if (this.visible) {
      Column() {
        // 标题
        Text('弹幕设置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 16 })

        // 开关
        Row() {
          Text('启用弹幕')
            .fontSize(14)
            .width(80)
          Toggle({ type: ToggleType.Switch, isOn: this.config.enable })
            .onChange((isOn: boolean) => {
              this.config.enable = isOn
            })
        }
        .width('100%')
        .margin({ bottom: 12 })

        // 透明度
        Row() {
          Text('透明度')
            .fontSize(14)
            .width(80)
          Slider({ value: this.config.opacity, min: 0, max: 1, step: 0.1 })
            .onChange((value: number) => {
              this.config.opacity = value
            })
        }
        .width('100%')
        .margin({ bottom: 12 })

        // 速度
        Row() {
          Text('速度')
            .fontSize(14)
            .width(80)
          Slider({ value: this.config.speed, min: 0.5, max: 2.0, step: 0.1 })
            .onChange((value: number) => {
              this.config.speed = value
            })
        }
        .width('100%')
        .margin({ bottom: 12 })

        // 显示区域
        Row() {
          Text('显示区域')
            .fontSize(14)
            .width(80)
          Slider({ value: this.config.displayArea, min: 0.25, max: 1.0, step: 0.05 })
            .onChange((value: number) => {
              this.config.displayArea = value
            })
        }
        .width('100%')
        .margin({ bottom: 12 })

        // 字体大小（就是屏幕上的绘制字号）
        // ⚠️ 量程必须覆盖默认值 37：滑块的 value 会被 min/max 钳位，
        //    上限写成 32 时一进设置面板就会把 37 悄悄夹到 32（字号被改掉还不自知）
        Row() {
          Text('字体大小')
            .fontSize(14)
            .width(80)
          Slider({ value: this.config.fontSize, min: 14, max: 48, step: 1 })
            .onChange((value: number) => {
              this.config.fontSize = Math.round(value)
            })
        }
        .width('100%')
        .margin({ bottom: 12 })

        // 关闭按钮
        Button('关闭')
          .width('100%')
          .margin({ top: 16 })
          .onClick(() => {
            this.visible = false
          })
      }
      .width(280)
      .padding(16)
      .backgroundColor('#E0000000')
      .borderRadius(12)
    }
  }

  /**
   * 显示面板
   */
  public show(): void {
    this.visible = true
  }

  /**
   * 隐藏面板
   */
  public hide(): void {
    this.visible = false
  }
}
