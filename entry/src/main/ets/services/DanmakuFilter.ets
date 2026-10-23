/**
 * 弹幕过滤器
 * 支持关键词、用户ID、正则表达式过滤
 */
import { DanmakuItem, DanmakuConfig, DanmakuType } from '../model/DanmakuItem'
import { logInfo, logWarn, logError } from '../utils/Logger';

// 过滤规则类型
enum FilterRuleType {
  KEYWORD = 'keyword',      // 关键词
  USER_ID = 'userId',       // 用户ID
  REGEX = 'regex',          // 正则表达式
  LEVEL = 'level'           // 屏蔽等级
}

// 过滤规则
class FilterRule {
  type: FilterRuleType
  value: string
  enabled: boolean = true
  
  constructor(type: FilterRuleType, value: string, enabled: boolean = true) {
    this.type = type
    this.value = value
    this.enabled = enabled
  }
}

export class DanmakuFilter {
  private config: DanmakuConfig
  private rules: FilterRule[] = []
  private regexCache: Map<string, RegExp> = new Map()
  
  // 统计信息
  private filteredCount: number = 0
  private totalCount: number = 0
  
  constructor(config: DanmakuConfig) {
    this.config = config
    this.initializeRules()
  }
  
  /**
   * 初始化过滤规则
   */
  private initializeRules(): void {
    // 添加关键词规则
    this.config.blockKeywords.forEach((keyword: string) => {
      this.rules.push(new FilterRule(FilterRuleType.KEYWORD, keyword))
    })
    
    // 添加用户ID规则
    this.config.blockUsers.forEach((userId: string) => {
      this.rules.push(new FilterRule(FilterRuleType.USER_ID, userId))
    })
    
    // 添加正则表达式规则
    if (this.config.blockRegex) {
      this.rules.push(new FilterRule(FilterRuleType.REGEX, this.config.blockRegex))
    }
    
    logInfo(`[DanmakuFilter] 初始化过滤规则: ${this.rules.length}条`)
  }
  
  /**
   * 检查弹幕是否应该被过滤
   * @param item 弹幕项
   * @returns true表示应该过滤掉，false表示保留
   */
  shouldFilter(item: DanmakuItem): boolean {
    this.totalCount++
    
    // 检查屏蔽等级
    if (this.checkLevelFilter(item)) {
      this.filteredCount++
      return true
    }
    
    // 检查所有规则
    for (const rule of this.rules) {
      if (!rule.enabled) {
        continue
      }
      
      let shouldFilter = false
      
      switch (rule.type) {
        case FilterRuleType.KEYWORD:
          shouldFilter = this.checkKeyword(item, rule.value)
          break
        case FilterRuleType.USER_ID:
          shouldFilter = this.checkUserId(item, rule.value)
          break
        case FilterRuleType.REGEX:
          shouldFilter = this.checkRegex(item, rule.value)
          break
      }
      
      if (shouldFilter) {
        this.filteredCount++
        return true
      }
    }
    
    return false
  }
  
  /**
   * 检查屏蔽等级
   * 等级说明：
   * 0: 不屏蔽
   * 1: 屏蔽滚动弹幕
   * 2: 屏蔽顶部+底部弹幕
   * 3: 屏蔽所有弹幕
   */
  private checkLevelFilter(item: DanmakuItem): boolean {
    if (this.config.blockLevel === 0) {
      return false
    }
    
    if (this.config.blockLevel === 1 && item.isScrolling()) {
      return true
    }
    
    if (this.config.blockLevel === 2 && !item.isScrolling()) {
      return true
    }
    
    if (this.config.blockLevel === 3) {
      return true
    }
    
    return false
  }
  
  /**
   * ⭐ 运行时（每帧）过滤：**只判"类型 / 彩色 / 云屏蔽等级"会变的规则**。
   *
   * 为什么必须有一条运行时通道：`shouldFilter()` 是在【弹幕数据加载期一次性】跑的
   *   （`DanmakuController.preprocess`），那时被过滤的弹幕直接不进渲染管线。
   *   用户在播放途中勾上"屏蔽顶部弹幕"时，数据早已加载完毕 —— 再调 shouldFilter 也来得及不再用，
   *   **但屏幕上那几条已经在上屏的顶部弹幕必须立刻消失**，所以这些开关要在轨道分配前后实时判。
   * 关键词 / 正则这类"静态规则"不在这里重复跑（每帧对每条弹幕做 includes / RegExp 太贵），
   *   它们仍然只在加载期生效（改了之后下一次 seek / 切集会自然生效）。
   */
  shouldFilterRuntime(item: DanmakuItem): boolean {
    return this.checkTypeFilter(item) || this.checkColorfulFilter(item) || this.checkWeightFilter(item)
  }

  /**
   * 按类型屏蔽（对应 PiliPlus `hideScroll / hideTop / hideBottom / hideSpecial`）。
   *
   * ⚠️ 配置项语义是"**显示**"而非"屏蔽"（`showXxx = true` 表示放行），
   *    与面板上的"选中 = 屏蔽"正好相反 —— 面板负责取反读，这里一律按"显示开关"判。
   * B站 mode 映射见 `DanmakuGrpcParser.parseDanmakuType`：
   *   1/2/3 → ROLL，4 → BOTTOM，5 → TOP，6 → REVERSE，7 → ADVANCED，8 → SCRIPT，9 → TOP_FIXED
   */
  private checkTypeFilter(item: DanmakuItem): boolean {
    switch (item.type) {
      case DanmakuType.ROLL:
      case DanmakuType.REVERSE:
        return !this.config.showScroll
      case DanmakuType.TOP:
      case DanmakuType.TOP_FIXED:
        return !this.config.showTop
      case DanmakuType.BOTTOM:
        return !this.config.showBottom
      case DanmakuType.ADVANCED:
      case DanmakuType.SCRIPT:
        // PiliPlus 的 hideSpecial 只对应 mode=7；这里把同为"特殊／脚本"的 mode=8 一并算进来，
        // 因为它们同样是华丽的非滚动效果，单独放 8 出来反而会让"屏蔽高级"看起来没生效。
        return !this.config.showAdvanced
      default:
        return false
    }
  }

  /** 屏蔽彩色弹幕：只留白色（0xFFFFFF），其余全部丢弃 */
  private checkColorfulFilter(item: DanmakuItem): boolean {
    if (!this.config.blockColorful) {
      return false
    }
    return item.color !== 0xFFFFFF
  }

  /**
   * 智能云屏蔽等级：**weight < level 的丢弃**（对齐 PiliPlus `view.dart` 的
   * `if (e.weight < danmakuWeight) return;`）。level = 0 表示不启用。
   */
  private checkWeightFilter(item: DanmakuItem): boolean {
    const level = this.config.blockWeight
    if (level <= 0) {
      return false
    }
    return item.weight < level
  }

  /**
   * 检查关键词过滤
   */
  private checkKeyword(item: DanmakuItem, keyword: string): boolean {
    return item.content.includes(keyword)
  }
  
  /**
   * 检查用户ID过滤
   */
  private checkUserId(item: DanmakuItem, userId: string): boolean {
    return item.userId === userId
  }
  
  /**
   * 检查正则表达式过滤
   */
  private checkRegex(item: DanmakuItem, pattern: string): boolean {
    try {
      // 使用缓存提高性能
      let regex = this.regexCache.get(pattern)
      if (!regex) {
        regex = new RegExp(pattern, 'i')
        this.regexCache.set(pattern, regex)
      }
      
      return regex.test(item.content)
    } catch (error) {
      logError(`[DanmakuFilter] 正则表达式错误: ${pattern}, ${error}`)
      return false
    }
  }
  
  /**
   * 添加过滤规则
   */
  addRule(type: FilterRuleType, value: string, enabled: boolean = true): void {
    this.rules.push(new FilterRule(type, value, enabled))
    logInfo(`[DanmakuFilter] 添加规则: ${type}=${value}`)
  }
  
  /**
   * 移除过滤规则
   */
  removeRule(type: FilterRuleType, value: string): void {
    const index = this.rules.findIndex((rule: FilterRule) => 
      rule.type === type && rule.value === value
    )
    
    if (index >= 0) {
      this.rules.splice(index, 1)
      logInfo(`[DanmakuFilter] 移除规则: ${type}=${value}`)
    }
  }
  
  /**
   * 启用/禁用规则
   */
  toggleRule(type: FilterRuleType, value: string, enabled: boolean): void {
    const rule = this.rules.find((r: FilterRule) => 
      r.type === type && r.value === value
    )
    
    if (rule) {
      rule.enabled = enabled
      logInfo(`[DanmakuFilter] 规则${enabled ? '启用' : '禁用'}: ${type}=${value}`)
    }
  }
  
  /**
   * 清空所有规则
   */
  clearRules(): void {
    this.rules = []
    this.regexCache.clear()
    logInfo('[DanmakuFilter] 清空所有规则')
  }
  
  /**
   * 获取过滤统计信息
   */
  getStats(): string {
    const filterRate = this.totalCount > 0 
      ? (this.filteredCount / this.totalCount * 100).toFixed(1) 
      : '0.0'
    return `过滤: ${this.filteredCount}/${this.totalCount} (${filterRate}%)`
  }
  
  /**
   * 重置统计信息
   */
  resetStats(): void {
    this.filteredCount = 0
    this.totalCount = 0
  }
  
  /**
   * 更新配置
   */
  updateConfig(config: DanmakuConfig): void {
    this.config = config
    this.clearRules()
    this.initializeRules()
  }
}
