/**
 * 弹幕Canvas渲染引擎
 * 高性能批量绘制弹幕
 */
import { DanmakuItem, DanmakuConfig, DanmakuType } from '../model/DanmakuItem'

export class DanmakuRenderer {
  private config: DanmakuConfig
  private canvasWidth: number = 0
  private canvasHeight: number = 0
  
  // 渲染上下文（由外部设置）
  private context: CanvasRenderingContext2D | null = null
  
  // 性能统计
  private frameCount: number = 0
  private lastFpsTime: number = 0
  private currentFps: number = 0
  private renderTime: number = 0

  // ⭐ 字体字符串缓存：key=fontSize，避免每帧重复拼接（PiliPlus paragraph 缓存思路）
  private fontCache: Map<number, string> = new Map()

  // ⭐ 文本真实宽度缓存：key = `${fontSize}|${text}`。
  //    刷屏弹幕内容高度重复，命中率很高；measureText 不便宜，只在首次 / 字号变化时真正测量。
  private widthCache: Map<string, number> = new Map()

  // ⭐ 大量弹幕模式是否激活（可见弹幕数超过 massiveThreshold 时跳过描边/阴影）
  private massiveModeActive: boolean = false

  // ⭐ 绘制状态去重缓存：记录"当前画布上实际生效"的字体/颜色/描边。
  //   为什么重要：Canvas 的 `font` 赋值需要重新解析字体串并查找字体族，是这里最贵的
  //   一次调用；`fillStyle` 会解析颜色串。原先每条弹幕每帧都无条件重设一次，
  //   100 条弹幕 60fps 就是每秒 1.8 万次无效赋值。大部分弹幕颜色/字号相同（默认全白），
  //   去重后绝大多数赋值都能跳过。
  //   ⚠️ 仅对【不经过 save/restore】的滚动弹幕路径有效；静止弹幕原先每条都 save/restore，
  //   会把这里的缓存状态一起回滚 → 已改为用 globalAlpha 手工还原，不再用状态栈。
  private lastFontSize: number = -1
  private lastFillStyle: string = ''
  private lastStrokeStyle: string = ''
  private lastLineWidth: number = -1

  // ⭐ 画布内容是否"脏"（上一帧画过东西）。空列表时据此跳过整屏 clearRect：
  //   低频轮询模式（250ms）下静止画面每 250ms 白清一次全画布是纯浪费。
  private needsClear: boolean = false
  
  constructor(config: DanmakuConfig) {
    this.config = config
  }
  
  /**
   * 设置渲染上下文
   */
  setContext(context: CanvasRenderingContext2D): void {
    this.context = context
    this.invalidateStateCache()
  }
  
  /**
   * 设置画布尺寸
   */
  setSize(width: number, height: number): void {
    // ⭐ 尺寸变化通常伴随 Canvas 重建，上下文状态会一起重置 → 缓存必须失效，
    //   否则会以为"字体/颜色已设置过"而跳过赋值，导致弹幕用默认字体绘制。
    if (this.canvasWidth !== width || this.canvasHeight !== height) {
      this.invalidateStateCache()
    }
    this.canvasWidth = width
    this.canvasHeight = height
  }

  /**
   * 使绘制状态缓存失效（上下文重建 / 配置变更 / 尺寸变化时调用）
   */
  private invalidateStateCache(): void {
    this.lastFontSize = -1
    this.lastFillStyle = ''
    this.lastStrokeStyle = ''
    this.lastLineWidth = -1
  }

  /**
   * 渲染所有可见弹幕（优化版）
   * @param items 待渲染的弹幕列表
   * @param currentTime 当前播放时间（毫秒，用于静止弹幕淡入淡出和可见性判断）
   * @param dt 帧间增量时间（毫秒，用于滚动弹幕位置推进）
   */
  render(items: DanmakuItem[], currentTime: number, dt: number): void {
    if (!this.context || !this.config.enable) {
      return
    }

    const ctx = this.context

    // 没有可见弹幕时跳过绘制。⭐ 只有上一帧真的画过东西才需要清屏（脏标记），
    // 否则低频轮询模式下每 250ms 都会白清一次全屏画布。
    if (items.length === 0) {
      if (this.needsClear) {
        ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight)
        this.needsClear = false
      }
      return
    }

    const startTime = Date.now()

    // 清空画布
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight)
    this.needsClear = true

    // 设置全局透明度
    ctx.globalAlpha = this.config.opacity

    // ⭐ 大量弹幕模式：可见弹幕数超过阈值时跳过描边/阴影，降低绘制开销
    this.massiveModeActive = this.config.massiveMode && items.length > this.config.massiveThreshold

    // ⭐ 描边样式整帧只需设置一次（原先在每条弹幕里重复设置三行）。
    //   由 applyStrokeStyle() 统一走缓存，滚动/静止两条路径共用。
    if (this.config.borderWidth > 0 && !this.massiveModeActive) {
      this.applyStrokeStyle()
    }
    if (this.config.shadowBlur > 0 && !this.massiveModeActive) {
      ctx.shadowColor = 'rgba(0, 0, 0, 0.5)'
      ctx.shadowBlur = this.config.shadowBlur
      ctx.shadowOffsetX = 1
      ctx.shadowOffsetY = 1
    }

    // 优化：单次遍历，根据类型分流渲染
    //   ⭐ 用 for 循环而不是 forEach：render 每帧都跑，forEach 每帧都会新建一个闭包。
    let scrollCount = 0
    let staticCount = 0

    for (let i = 0; i < items.length; i++) {
      const item = items[i]

      // ⭐ dropped：轨道分配失败（顶/底轨道满员，或滚动轨道全部放不下）。
      //   必须拦在这里 —— 否则它的 x/y 还停在默认值 0，会被画到画布左上角，
      //   表现就是"弹幕跑到边角上、居中的弹幕没对齐"。
      if (!item.visible || item.dropped) {
        continue
      }

      if (item.isScrolling()) {
        // 滚动弹幕：使用增量时间(dt)每帧推进位置
        this.advanceScrollingPosition(item, dt)
        if (this.isInViewport(item)) {
          this.drawDanmakuOptimized(item)
          scrollCount++
        } else {
          // 完全移出屏幕的弹幕标记为不可见
          item.visible = false
        }
      } else {
        // 静止弹幕（顶部、底部）：使用currentTime计算淡入淡出
        const elapsed = currentTime - item.time
        if (elapsed >= 0 && elapsed < item.duration) {
          const fadeInDuration = 200
          const fadeOutDuration = 200
          let alpha = 1.0
          if (elapsed < fadeInDuration) {
            alpha = elapsed / fadeInDuration
          } else if (elapsed > item.duration - fadeOutDuration) {
            alpha = (item.duration - elapsed) / fadeOutDuration
          }
          this.drawDanmaku(item, alpha)
          staticCount++
        } else {
          item.visible = false
        }
      }
    }

    // 更新性能统计
    this.renderTime = Date.now() - startTime
    this.updateFps()
  }
  
  /**
   * 增量推进滚动弹幕位置（每帧调用）
   * 使用帧间增量时间(dt)推进，不依赖currentTime，实现60fps流畅滚动
   * 注意：不在此处标记 visible=false，统一由 render 循环的 isInViewport 判定
   */
  private advanceScrollingPosition(item: DanmakuItem, dt: number): void {
    // 如果宽度未设置，使用估算值（避免measureText）
    if (item.width === 0) {
      const fontSize = item.fontSize || this.config.fontSize
      let width = 0
      for (let i = 0; i < item.content.length; i++) {
        const char = item.content.charAt(i)
        if (char.charCodeAt(0) > 255) {
          width += fontSize
        } else {
          width += fontSize * 0.6
        }
      }
      item.width = width
      item.height = fontSize
    }
    
    // 计算speed（如果TrackManager没有设置）
    // 7000 = 官方滚动穿越时长默认 7 秒（与 DanmakuTrackManager.DANMAKU_SCROLL_DURATION 一致）
    if (item.speed === 0) {
      const duration = item.duration > 0 ? item.duration : 7000
      item.speed = (this.canvasWidth + item.width) / duration
    }
    
    // 每帧按固定像素量推进位置
    if (item.type === DanmakuType.ROLL || item.type === DanmakuType.ADVANCED || item.type === DanmakuType.SCRIPT) {
      item.x -= item.speed * dt
    } else if (item.type === DanmakuType.REVERSE) {
      item.x += item.speed * dt
    }
    // 不再在此处设置 item.visible = false，交由 render 循环统一判定
  }
  
  /**
   * 检查弹幕是否在视口内
   */
  private isInViewport(item: DanmakuItem): boolean {
    // X坐标范围：[-item.width, canvasWidth]
    // Y坐标范围：[0, canvasHeight]
    return item.x >= -item.width && 
           item.x <= this.canvasWidth &&
           item.y >= 0 && 
           item.y <= this.canvasHeight
  }
  
  /**
   * 获取字体字符串（带缓存，key=fontSize）
   * 避免每条弹幕每帧重复拼接 `${fontWeight} ${size}px ${family}`
   */
  private getFontString(fontSize: number): string {
    let font = this.fontCache.get(fontSize)
    if (font === undefined) {
      font = `${this.config.fontWeight} ${fontSize}px ${this.config.fontFamily}`
      this.fontCache.set(fontSize, font)
    }
    return font
  }

  /**
   * ⭐ 只在字体真的变化时才赋值（Canvas 的 font 赋值需要重新解析字体串，是这里最贵的调用）
   */
  private applyFont(fontSize: number): void {
    if (!this.context || this.lastFontSize === fontSize) {
      return
    }
    this.context.font = this.getFontString(fontSize)
    this.lastFontSize = fontSize
  }

  /**
   * ⭐ 只在颜色真的变化时才赋值（大部分弹幕是默认白色，可跳过绝大多数赋值）
   */
  private applyFillStyle(color: string): void {
    if (!this.context || this.lastFillStyle === color) {
      return
    }
    this.context.fillStyle = color
    this.lastFillStyle = color
  }

  /**
   * ⭐ 描边样式（颜色/线宽/接合）整帧只需生效一次，走缓存避免每条弹幕重复设置
   */
  private applyStrokeStyle(): void {
    if (!this.context) {
      return
    }
    const width = this.config.borderWidth
    if (this.lastStrokeStyle !== '#000000') {
      this.context.strokeStyle = '#000000'
      this.lastStrokeStyle = '#000000'
    }
    if (this.lastLineWidth !== width) {
      this.context.lineWidth = width
      this.context.lineJoin = 'round'
      this.lastLineWidth = width
    }
  }

  /**
   * 绘制单条弹幕（静止弹幕：顶部/底部，带淡入淡出）
   *
   * ⚠️ 这里**不再使用 save/restore**：原先每条都 save+restore，会把 applyFont/applyFillStyle
   *    维护的状态缓存一起回滚掉，导致缓存永远失效（等于没优化）。
   *    淡入淡出只需要改 globalAlpha，手工还原即可，代价远低于状态栈操作。
   */
  private drawDanmaku(item: DanmakuItem, alpha: number = 1.0): void {
    if (!this.context) {
      return
    }

    // ⭐ 居中弹幕（顶部/底部）：用 measureText 的真实宽度重算水平位置。
    //   为什么不能信 TrackManager 里用 estimateTextWidth 算的 x：那个估算把
    //   charCodeAt>255 的字符一律按 1 个 fontSize 计宽，而 emoji 是代理对（两个码元
    //   都 >255）会被当成 2 倍宽，中英混排与全角标点的实际宽度也对不上 →
    //   (canvasWidth - width)/2 偏左，视觉上就是"居中的弹幕没有对齐"。
    if (item.centerAligned) {
      this.applyCenteredX(item)
    }

    const ctx = this.context
    const faded = alpha < 1.0
    if (faded) {
      ctx.globalAlpha = this.config.opacity * alpha
    }

    this.applyFont(item.fontSize || this.config.fontSize)
    this.applyFillStyle(item.getColorString())

    // 绘制描边（黑色，大量弹幕模式跳过）
    if (this.config.borderWidth > 0 && !this.massiveModeActive) {
      ctx.strokeText(item.content, item.x, item.y)
    }

    // 绘制文本
    ctx.fillText(item.content, item.x, item.y)

    // 还原透明度（不用 restore，见方法注释）
    if (faded) {
      ctx.globalAlpha = this.config.opacity
    }
  }

  /**
   * 用【真实测量宽度】把静止弹幕水平居中
   * 测量结果按字号缓存在 item 上，避免每帧 measureText 的开销
   */
  private applyCenteredX(item: DanmakuItem): void {
    if (!this.context) {
      return
    }
    const fontSize = item.fontSize || this.config.fontSize
    if (item.measuredFontSize !== fontSize) {
      // 测量前必须先把字体设成实际绘制用的字体，否则量到的是默认字体的宽度
      this.context.font = this.getFontString(fontSize)
      // ⭐ 同步状态缓存：字体已被改成这个字号，避免 applyFont 又设一次（或误判为已设置）
      this.lastFontSize = fontSize
      item.measuredWidth = this.context.measureText(item.content).width
      item.measuredFontSize = fontSize
    }
    item.x = (this.canvasWidth - item.measuredWidth) / 2
  }

  /**
   * 测量文本真实宽度（带缓存）。轨道分配前由控制器调用，用来替代估算宽度。
   *
   * 为什么要真实宽度：估算值只按"全角=1em、半角=0.6em"累加，与真实排版宽度有系统性偏差。
   * 偏小 → 弹幕尾巴还在屏幕内就被判定"已出屏"（视觉上"滚到一半消失"）；
   * 偏大 → 碰撞检测误判"放不下"（密集时段白白丢弹幕）。
   *
   * @returns 真实宽度；**返回 0 表示当前没有渲染上下文**，调用方应退回估算值
   */
  measureWidth(text: string, fontSize: number): number {
    if (!this.context) {
      return 0
    }
    const key = `${fontSize}|${text}`
    let w = this.widthCache.get(key)
    if (w !== undefined) {
      return w
    }
    // 测量前必须把字体设成实际绘制用的字体，否则量到的是默认字体的宽度
    this.context.font = this.getFontString(fontSize)
    // ⭐ 同步绘制状态缓存：字体已被改成这个字号，避免 applyFont 重复设置或误判
    this.lastFontSize = fontSize
    w = this.context.measureText(text).width
    // 缓存无界会吃内存（长视频几十万条），超过上限整体清空即可（刷屏内容很快重新命中）
    if (this.widthCache.size > 3000) {
      this.widthCache.clear()
    }
    this.widthCache.set(key, w)
    return w
  }

  /**
   * 绘制单条弹幕（滚动弹幕热路径，减少save/restore调用）
   */
  private drawDanmakuOptimized(item: DanmakuItem): void {
    if (!this.context) {
      return
    }

    // 设置字体（带状态缓存，字号未变则跳过）
    this.applyFont(item.fontSize || this.config.fontSize)

    // 设置颜色（带状态缓存，颜色未变则跳过）
    this.applyFillStyle(item.getColorString())

    // 描边（大量弹幕模式跳过）
    if (this.config.borderWidth > 0 && !this.massiveModeActive) {
      this.context.strokeText(item.content, item.x, item.y)
    }

    // 绘制文本
    this.context.fillText(item.content, item.x, item.y)
  }
  
  /**
   * 更新帧率统计
   */
  private updateFps(): void {
    this.frameCount++
    const now = Date.now()
    const elapsed = now - this.lastFpsTime
    
    if (elapsed >= 1000) {
      this.currentFps = Math.round(this.frameCount * 1000 / elapsed)
      this.frameCount = 0
      this.lastFpsTime = now
    }
  }
  
  /**
   * 获取性能统计信息
   */
  getPerformanceStats(): PerformanceStats {
    return {
      fps: this.currentFps,
      renderTime: this.renderTime,
      canvasWidth: this.canvasWidth,
      canvasHeight: this.canvasHeight
    }
  }
  
  /**
   * 更新配置
   */
  updateConfig(config: DanmakuConfig): void {
    this.config = config
    this.fontCache.clear()  // 字体配置可能变化，缓存失效
    this.widthCache.clear()  // 字号/字体变了，之前测出来的宽度全部作废
    this.invalidateStateCache()  // 字号/描边等样式可能变化，绘制状态缓存一并失效
  }
  
  /**
   * 清空画布
   */
  clear(): void {
    if (this.context) {
      this.context.clearRect(0, 0, this.canvasWidth, this.canvasHeight)
      this.needsClear = false
    }
  }
}

// 性能统计接口
interface PerformanceStats {
  fps: number
  renderTime: number
  canvasWidth: number
  canvasHeight: number
}
