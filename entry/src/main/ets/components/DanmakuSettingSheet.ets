/**
 * 弹幕设置面板（分组卡片式；配色随「深浅模式 + 播放器主题色」走）
 *
 * 对标 PiliPlus `lib/pages/video/widgets/header_mixin.dart` 的 `showSetDanmaku()`：
 * 屏蔽（云屏蔽等级 / 按类型 / 彩色）、显示几何（显示区域 / 不透明度 / 字号 / 全屏缩放 /
 * 行高 / 字重 / 描边 / 滚动时长 / 静止时长）、以及三个行为开关。
 *
 * 视觉（⚠️ 曾经硬编码为深色，现已改为随主题）：
 *   - 深浅：跟随 `AppStorage['isDarkMode']`（应用内开关，Index/播放页改它时还会一并
 *     `setColorMode` 推给系统，所以它与 `resources/dark/` 同源）。深色沿用原来拍板的
 *     `#161618` 面板 / `#242427` 卡片；浅色是 `#F1F1F3` 面板 / `#FFFFFF` 卡片。
 *   - ⭐ 卡片半透明（2026-09-24 用户定，走"推荐方案"）：外层 bindSheet 挂了沉浸光感，
 *     面板根节点早已透明，本次把**卡片底也改成半透明染色**让玻璃透到卡片区域 ——
 *     深色 `#52000000`（32% 黑）、浅色 `#14FFFFFF`（8% 白），
 *     同时把 `line` 从 6~7% 提到 12~14%（卡片底不再不透明，"看得出来是卡片"只能靠描边 +
 *     卡内分隔线撑，原来的淡线压在磨砂上等于看不见）。
 *     ⚠️ 卡片底必须随「材质可用性」切换，不能一味半透明：材质不可用时**根节点会画不透明
 *     `pal.bg`**，半透明卡片压在同色面板底上等于没有卡片。判据收在 `DmPalette` 构造里。
 *   - 强调色：跟随 `playerFollowTheme ? customThemeColor : B站粉 #FB7299`，
 *     与播放器其它控件（选集/倍速胶囊等）同一套语义，不新增开关。
 *   - 卡内行之间都有 0.5vp 淡线；
 *   - 数值 = 主色浅底 pill；与默认值不同才出现「默认」回弹 pill；
 *   - 滑轨：⚠️ **必须用 SliderStyle.InSet** —— OutSet 下 trackThickness 不生效（渲染恒为默认 ~4vp 细轨，
 *     前几轮"滑轨太细"全是这个原因）。InSet 下圆钮嵌进轨道，**轨道 / 圆钮现为 17 / 17**（用户实机定档：28/22 偏大）。
 *
 * ⚠️ 三条接入约定（踩过的坑，改这里前先读）：
 *   1. **只能改 config 的字段，绝不能 `config = new DanmakuConfig()` 换对象** ——
 *      controller / renderer / filter / trackManager 在构造时就拿走了引用，换对象后所有修改静默失效。
 *      所以"恢复默认"是逐字段写回，不是换对象。
 *   2. 改完必须调用 `onChanged()`（页面侧 → debounce → AppStorage('danmakuSettingVersion')++），
 *      由 DanmakuView 的 @Watch 落到 `controller.applyDisplaySettings()` 重建轨道几何；
 *      不通知的话几何类设置（字号 / 显示区 / 行高）要退到下次旋屏或重进播放页才生效。
 *   3. 取色一律走 `this.pal`（见下），**不要在 build 里现算**：色板由 @Watch 在主题变更时
 *      重建一次即可，否则每次渲染都会新建几十个字符串。@Watch 不会在初始化时触发，
 *      所以子组件都必须有 `aboutToAppear → refreshPalette()`。
 */
import { DanmakuConfig } from '../model/DanmakuItem'
import { MaterialUtil } from '../utils/MaterialUtil'

/** 默认强调色（B站粉）。`playerFollowTheme` 关闭、或主题色非法时的回落值 */
const DM_ACCENT_DEFAULT: string = '#FB7299'

/**
 * 面板整套色板：由 (深浅模式, 强调色) 算出。
 * 做成类而不是一堆模块级常量，是因为 ArkTS 的 @StorageLink 不能被模块常量继承 ——
 * 4 个 struct 各自持有 @StorageLink，谁都得独立算一套；集中在这里改色时只动一处。
 */
class DmPalette {
  /** 面板底（只有「材质不可用」的降级路径上才真的会被画出来） */
  readonly bg: string
  /** 分组卡片底：材质可用时是半透明染色（透出玻璃），不可用时是不透明底色 */
  readonly card: string
  /** 卡片描边 + 卡内分隔线（玻璃下要更实，否则压在磨砂上看不见） */
  readonly line: string
  /** 标题 / 正文字色 */
  readonly title: string
  /** 说明文字、小节标题等弱化文字 */
  readonly sub: string
  /** 滑轨底色 */
  readonly track: string
  /** 未选中 chip 底 / 字 */
  readonly chipIdle: string
  readonly chipIdleText: string
  /** 次级按钮（「默认」「恢复默认」）底 / 字 */
  readonly btnIdle: string
  readonly btnIdleText: string
  /** 强调色：选中态、数值 pill、「完成」按钮 */
  readonly accent: string
  /** 强调色浅底（数值 pill 背景） */
  readonly accentSoft: string
  /** 压在强调色上的文字色（随强调色亮度自动取深/浅） */
  readonly onAccent: string
  /** 滑轨圆钮：深色下白钮（原设计），浅色下用强调色（白钮落在浅轨上几乎看不见） */
  readonly sliderBlock: string

  constructor(isDark: boolean, accentHex: string) {
    const a = DmPalette.normalizeAccent(accentHex)
    this.accent = a
    // 8 位 hex 在 ArkUI 里是 #AARRGGBB（透明度在前），2E ≈ 18%，与原 rgba(...,0.18) 等价
    this.accentSoft = '#2E' + a.substring(1)
    this.onAccent = DmPalette.contrastText(a)

    // ⭐ 玻璃是否真的挂上了 —— 决定卡片画「半透明染色」还是「不透明底」。
    //   这里直接问 MaterialUtil（内部有缓存，4 个 struct 每次 refreshPalette 都问一遍，
    //   代价只是读一个布尔值）。
    //   ⚠️ 判据必须与「面板根节点背景」那处保持一致（根节点同样按这个函数决定要不要透明），
    //   两边一旦不一致，就会出现「根节点透了、卡片没透」这类半截玻璃。
    const glass: boolean = MaterialUtil.sheetMaterial() !== undefined

    if (isDark) {
      this.bg = '#161618'
      // 玻璃下卡片只染色：32% 黑把玻璃压暗，保证白字对比度
      this.card = glass ? '#52000000' : '#242427'
      this.line = glass ? 'rgba(255, 255, 255, 0.14)' : 'rgba(255, 255, 255, 0.07)'
      this.title = '#FFFFFF'
      this.sub = '#8E8E96'
      this.track = '#3A3A42'
      this.chipIdle = '#33333A'
      this.chipIdleText = '#E2E2E8'
      this.btnIdle = '#33333A'
      this.btnIdleText = '#B0B0B8'
      this.sliderBlock = '#FFFFFF'
    } else {
      this.bg = '#F1F1F3'
      // 玻璃下卡片只染色：8% 白轻微提亮（浅色玻璃本身偏亮，加多了会发灰）
      this.card = glass ? '#14FFFFFF' : '#FFFFFF'
      this.line = glass ? 'rgba(0, 0, 0, 0.12)' : 'rgba(0, 0, 0, 0.06)'
      this.title = '#000000'
      this.sub = '#8E8E96'
      this.track = '#E0E0E4'
      this.chipIdle = '#EFEFF2'
      this.chipIdleText = '#1A1A1C'
      this.btnIdle = '#EFEFF2'
      this.btnIdleText = '#5C5C66'
      this.sliderBlock = a
    }
  }

  /** 只接受 6 位 `#RRGGBB`；主题色可能被设成空串 / rgba() / 8 位 hex，一律回落到 B站粉 */
  private static normalizeAccent(hex: string): string {
    if (hex.length === 7 && hex.charAt(0) === '#') {
      return hex
    }
    return DM_ACCENT_DEFAULT
  }

  /**
   * 按相对亮度选强调色上的文字色。
   * 主题色是用户可选的：选了亮黄/亮青这类高亮度色时，白字会糊掉看不清。
   */
  private static contrastText(hex: string): string {
    const r = parseInt(hex.substring(1, 3), 16)
    const g = parseInt(hex.substring(3, 5), 16)
    const b = parseInt(hex.substring(5, 7), 16)
    const lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
    return lum > 0.62 ? '#1A1A1C' : '#FFFFFF'
  }
}

/**
 * 单行滑块（标题 + 说明 + 数值标签 + 默认值回弹 + 粗滑轨）
 */
@Component
struct DmSliderRow {
  @StorageLink('isDarkMode') @Watch('refreshPalette') isDarkMode: boolean = false
  @StorageLink('playerFollowTheme') @Watch('refreshPalette') playerFollowTheme: boolean = false
  @StorageLink('customThemeColor') @Watch('refreshPalette') customThemeColor: string = '#007DFF'
  private pal: DmPalette = new DmPalette(false, DM_ACCENT_DEFAULT)

  @Prop title: string = ''
  @Prop desc: string = ''
  @Prop value: number = 0
  @Prop min: number = 0
  @Prop max: number = 100
  @Prop step: number = 1
  @Prop defVal: number = 0
  @Prop decimals: number = 0
  @Prop unit: string = ''
  onChange: (v: number) => void = () => {}

  aboutToAppear(): void {
    this.refreshPalette()
  }

  private refreshPalette(): void {
    this.pal = new DmPalette(this.isDarkMode, this.playerFollowTheme ? this.customThemeColor : DM_ACCENT_DEFAULT)
  }

  /** 按 decimals 定小数位，避免 0.30000000000000004 这种浮点尾巴出现在 UI 上 */
  private fmt(v: number): string {
    const s = this.decimals > 0 ? v.toFixed(this.decimals) : String(Math.round(v))
    return this.unit === '' ? s : `${s}${this.unit}`
  }

  private changed(): boolean {
    return Math.abs(this.value - this.defVal) > 1e-6
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text(this.title)
            .fontSize(16)
            .fontColor(this.pal.title)
            .fontWeight(FontWeight.Medium)
            .alignSelf(ItemAlign.Start)
          if (this.desc !== '') {
            Text(this.desc)
              .fontSize(12)
              .fontColor(this.pal.sub)
              .margin({ top: 3 })
              .alignSelf(ItemAlign.Start)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 数值标签
        Text(this.fmt(this.value))
          .fontSize(12)
          .fontColor(this.pal.accent)
          .fontWeight(FontWeight.Medium)
          .padding({ left: 11, right: 11, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor(this.pal.accentSoft)
          .margin({ left: 8 })

        if (this.changed()) {
          Text('默认')
            .fontSize(12)
            .fontColor(this.pal.btnIdleText)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .borderRadius(10)
            .backgroundColor(this.pal.btnIdle)
            .margin({ left: 6 })
            .onClick(() => {
              this.onChange(this.defVal)
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Slider({
        value: this.value,
        min: this.min,
        max: this.max,
        step: this.step,
        style: SliderStyle.InSet
      })
      .width('100%')
      .height(44)
      .selectedColor(this.pal.accent)
      .trackColor(this.pal.track)
      .trackThickness(17)
      .blockSize({ width: 17, height: 17 })
      .blockColor(this.pal.sliderBlock)
      .margin({ top: 6 })
        .onChange((v: number, mode: SliderChangeMode) => {
          // Moving / Click 也要上报，否则手指抬起前 UI 不动；Begin 时 value 尚未更新，跳过
          if (mode === SliderChangeMode.Begin) {
            return
          }
          this.onChange(v)
        })
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 16, bottom: 16 })
  }
}

/**
 * 可勾选的小胶囊（用于「按类型屏蔽」）
 */
@Component
struct DmChip {
  @StorageLink('isDarkMode') @Watch('refreshPalette') isDarkMode: boolean = false
  @StorageLink('playerFollowTheme') @Watch('refreshPalette') playerFollowTheme: boolean = false
  @StorageLink('customThemeColor') @Watch('refreshPalette') customThemeColor: string = '#007DFF'
  private pal: DmPalette = new DmPalette(false, DM_ACCENT_DEFAULT)

  @Prop label: string = ''
  @Prop active: boolean = false
  onToggle: () => void = () => {}

  aboutToAppear(): void {
    this.refreshPalette()
  }

  private refreshPalette(): void {
    this.pal = new DmPalette(this.isDarkMode, this.playerFollowTheme ? this.customThemeColor : DM_ACCENT_DEFAULT)
  }

  build() {
    Text(this.label)
      .fontSize(14)
      // 选中态压在强调色上，用 onAccent 而不是写死白色（主题色偏亮时白字会糊）
      .fontColor(this.active ? this.pal.onAccent : this.pal.chipIdleText)
      .fontWeight(this.active ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 18, right: 18, top: 10, bottom: 10 })
      .borderRadius(20)
      .backgroundColor(this.active ? this.pal.accent : this.pal.chipIdle)
      .margin({ right: 10, bottom: 10 })
      .onClick(() => {
        this.onToggle()
      })
  }
}

/**
 * 开关行（左侧文案 + 副标题，右侧 Toggle）
 */
@Component
struct DmSwitchRow {
  @StorageLink('isDarkMode') @Watch('refreshPalette') isDarkMode: boolean = false
  @StorageLink('playerFollowTheme') @Watch('refreshPalette') playerFollowTheme: boolean = false
  @StorageLink('customThemeColor') @Watch('refreshPalette') customThemeColor: string = '#007DFF'
  private pal: DmPalette = new DmPalette(false, DM_ACCENT_DEFAULT)

  @Prop title: string = ''
  @Prop desc: string = ''
  @Prop value: boolean = false
  onChange: (v: boolean) => void = () => {}

  aboutToAppear(): void {
    this.refreshPalette()
  }

  private refreshPalette(): void {
    this.pal = new DmPalette(this.isDarkMode, this.playerFollowTheme ? this.customThemeColor : DM_ACCENT_DEFAULT)
  }

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(16)
          .fontColor(this.pal.title)
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start)
        if (this.desc !== '') {
          Text(this.desc)
            .fontSize(12)
            .fontColor(this.pal.sub)
            .margin({ top: 3 })
            .alignSelf(ItemAlign.Start)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.value })
        .selectedColor(this.pal.accent)
        .margin({ left: 8 })
        .onChange((isOn: boolean) => {
          this.onChange(isOn)
        })
    }
    .width('100%')
    .padding({ left: 24, right: 18, top: 16, bottom: 16 })
    .alignItems(VerticalAlign.Center)
  }
}

@Component
export struct DanmakuSettingSheet {
  @StorageLink('isDarkMode') @Watch('refreshPalette') isDarkMode: boolean = false
  @StorageLink('playerFollowTheme') @Watch('refreshPalette') playerFollowTheme: boolean = false
  @StorageLink('customThemeColor') @Watch('refreshPalette') customThemeColor: string = '#007DFF'
  private pal: DmPalette = new DmPalette(false, DM_ACCENT_DEFAULT)

  @Link config: DanmakuConfig
  /** 任意一项被修改后回调（页面侧负责 debounce 应用 + 持久化） */
  onChanged: () => void = () => {}
  /** 点「完成」/「恢复默认」后收起面板 */
  onClose: () => void = () => {}

  // ── 本地镜像：面板内所有可调项都用 @State 存，避免依赖深层对象观察 ──
  @State sCloudLevel: number = 0
  @State bScroll: boolean = false
  @State bTop: boolean = false
  @State bBottom: boolean = false
  @State bColorful: boolean = false
  @State bAdvanced: boolean = false

  @State sArea: number = 0.9
  @State sOpacity: number = 1.0
  @State sFontSize: number = 28
  @State sFsScale: number = 1.2
  @State sLineHeight: number = 1.2
  @State sFontWeight: number = 5
  @State sStroke: number = 2
  @State sScrollDur: number = 7
  @State sStaticDur: number = 4

  @State swVary: boolean = true
  @State swMassive: boolean = false
  @State swStatic2Scroll: boolean = false
  @State swFixedV: boolean = false

  // 出厂默认值快照（「恢复默认」逐字段写回用，不能整体替换 config 对象）
  private dft: DanmakuConfig = new DanmakuConfig()

  aboutToAppear(): void {
    this.refreshPalette()
    this.syncFromConfig()
  }

  private refreshPalette(): void {
    this.pal = new DmPalette(this.isDarkMode, this.playerFollowTheme ? this.customThemeColor : DM_ACCENT_DEFAULT)
  }

  /** 从 config 反向同步到 UI 镜像（面板每次打开都会重建组件 → aboutToAppear 走这里） */
  private syncFromConfig(): void {
    this.sCloudLevel = this.config.blockWeight
    // ⚠️ 语义翻转：config 存的是"是否显示"，面板上"选中"表示屏蔽
    this.bScroll = !this.config.showScroll
    this.bTop = !this.config.showTop
    this.bBottom = !this.config.showBottom
    this.bColorful = this.config.blockColorful
    this.bAdvanced = !this.config.showAdvanced

    this.sArea = this.config.displayArea
    this.sOpacity = this.config.opacity
    this.sFontSize = Math.round(this.config.fontSize)
    this.sFsScale = this.config.fullScreenFontScale
    this.sLineHeight = this.config.lineHeight
    this.sFontWeight = Math.round(this.config.fontWeight / 100)
    this.sStroke = this.config.borderWidth
    this.sScrollDur = Math.round(this.config.scrollDuration / 100) / 10
    this.sStaticDur = Math.round(this.config.staticDuration / 100) / 10

    this.swVary = this.config.varyFontSize
    this.swMassive = this.config.massiveMode
    this.swStatic2Scroll = this.config.static2Scroll
    this.swFixedV = this.config.scrollFixedVelocity
  }

  private commit(): void {
    this.onChanged()
  }

  /** 恢复默认：逐字段写回 config，然后同步 UI 镜像 */
  private restoreDefault(): void {
    const d = this.dft
    this.config.blockWeight = d.blockWeight
    this.config.showScroll = d.showScroll
    this.config.showTop = d.showTop
    this.config.showBottom = d.showBottom
    this.config.blockColorful = d.blockColorful
    this.config.showAdvanced = d.showAdvanced
    this.config.displayArea = d.displayArea
    this.config.opacity = d.opacity
    this.config.fontSize = d.fontSize
    this.config.fullScreenFontScale = d.fullScreenFontScale
    this.config.lineHeight = d.lineHeight
    this.config.fontWeight = d.fontWeight
    this.config.borderWidth = d.borderWidth
    this.config.scrollDuration = d.scrollDuration
    this.config.staticDuration = d.staticDuration
    this.config.varyFontSize = d.varyFontSize
    this.config.massiveMode = d.massiveMode
    this.config.static2Scroll = d.static2Scroll
    this.config.scrollFixedVelocity = d.scrollFixedVelocity
    this.syncFromConfig()
    this.commit()
  }

  /** 卡片外的小标题（弱化，不抢内容） */
  @Builder
  sectionTitle(t: string) {
    Text(t)
      .fontSize(13)
      .fontColor(this.pal.sub)
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: 12, right: 16, top: 22, bottom: 10 })
  }

  /** 开关行之间的淡分隔线（滑块行之间不放，靠留白分隔） */
  @Builder
  hairline() {
    Row()
      .width('100%')
      .height(0.5)
      .backgroundColor(this.pal.line)
      .margin({ left: 24, right: 24 })
  }

  build() {
    Column() {
      // ── 标题栏 ──
      Row() {
        Text('弹幕设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.pal.title)
        Blank()
        Text('恢复默认')
          .fontSize(12)
          .fontColor(this.pal.btnIdleText)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(14)
          .backgroundColor(this.pal.btnIdle)
          .onClick(() => {
            this.restoreDefault()
          })
        Text('完成')
          .fontSize(14)
          .fontColor(this.pal.onAccent)
          .fontWeight(FontWeight.Medium)
          .padding({ left: 20, right: 20, top: 9, bottom: 9 })
          .borderRadius(16)
          .backgroundColor(this.pal.accent)
          .margin({ left: 8 })
          .onClick(() => {
            this.onClose()
          })
      }
      .width('100%')
      .height(60)
      .padding({ left: 36, right: 24 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          // ══════════ 屏蔽 ══════════
          this.sectionTitle('屏蔽')

          Column() {
            DmSliderRow({
              title: '智能云屏蔽',
              desc: '等级越高屏蔽越多，0 为不启用',
              value: this.sCloudLevel,
              min: 0,
              max: 11,
              step: 1,
              defVal: this.dft.blockWeight,
              unit: ' 级',
              onChange: (v: number) => {
                this.sCloudLevel = Math.round(v)
                this.config.blockWeight = Math.round(v)
                this.commit()
              }
            })

            this.hairline()

            Column() {
              Row() {
                Text('按类型屏蔽')
                  .fontSize(16)
                  .fontColor(this.pal.title)
                  .fontWeight(FontWeight.Medium)
                Blank()
                Text('选中即屏蔽')
                  .fontSize(12)
                  .fontColor(this.pal.sub)
              }
              .width('100%')

              Flex({ wrap: FlexWrap.Wrap }) {
                DmChip({
                  label: '滚动',
                  active: this.bScroll,
                  onToggle: () => {
                    this.bScroll = !this.bScroll
                    this.config.showScroll = !this.bScroll
                    this.commit()
                  }
                })
                DmChip({
                  label: '顶部',
                  active: this.bTop,
                  onToggle: () => {
                    this.bTop = !this.bTop
                    this.config.showTop = !this.bTop
                    this.commit()
                  }
                })
                DmChip({
                  label: '底部',
                  active: this.bBottom,
                  onToggle: () => {
                    this.bBottom = !this.bBottom
                    this.config.showBottom = !this.bBottom
                    this.commit()
                  }
                })
                DmChip({
                  label: '彩色',
                  active: this.bColorful,
                  onToggle: () => {
                    this.bColorful = !this.bColorful
                    this.config.blockColorful = this.bColorful
                    this.commit()
                  }
                })
                DmChip({
                  label: '高级',
                  active: this.bAdvanced,
                  onToggle: () => {
                    this.bAdvanced = !this.bAdvanced
                    this.config.showAdvanced = !this.bAdvanced
                    this.commit()
                  }
                })
              }
              .width('100%')
              .margin({ top: 12 })
            }
            .width('100%')
            .padding({ left: 30, right: 30, top: 4, bottom: 18 })
          }
          .width('100%')
          .borderRadius(20)
          .backgroundColor(this.pal.card)
          .border({ width: 0.5, color: this.pal.line })
        
          // ══════════ 显示 ══════════
          this.sectionTitle('显示')

          Column() {
            DmSliderRow({
              title: '显示区域',
              desc: '弹幕可占用的画面高度比例',
              value: Math.round(this.sArea * 100),
              min: 10,
              max: 100,
              step: 5,
              defVal: Math.round(this.dft.displayArea * 100),
              unit: '%',
              onChange: (v: number) => {
                this.sArea = v / 100
                this.config.displayArea = v / 100
                this.commit()
              }
            })

            this.hairline()

            DmSliderRow({
              title: '不透明度',
              value: Math.round(this.sOpacity * 100),
              min: 0,
              max: 100,
              step: 5,
              defVal: Math.round(this.dft.opacity * 100),
              unit: '%',
              onChange: (v: number) => {
                this.sOpacity = v / 100
                this.config.opacity = v / 100
                this.commit()
              }
            })

            this.hairline()

            DmSliderRow({
              title: '字体大小',
              value: this.sFontSize,
              min: 14,
              max: 48,
              step: 1,
              defVal: Math.round(this.dft.fontSize),
              unit: ' vp',
              onChange: (v: number) => {
                this.sFontSize = Math.round(v)
                this.config.fontSize = Math.round(v)
                this.commit()
              }
            })

            this.hairline()

            DmSliderRow({
              title: '全屏字号缩放',
              desc: '横屏全屏时在上方字号基础上的倍率',
              value: Math.round(this.sFsScale * 100),
              min: 100,
              max: 200,
              step: 5,
              defVal: Math.round(this.dft.fullScreenFontScale * 100),
              unit: '%',
              onChange: (v: number) => {
                this.sFsScale = v / 100
                this.config.fullScreenFontScale = v / 100
                this.commit()
              }
            })

            this.hairline()

            DmSliderRow({
              title: '弹幕行高',
              desc: '低于 1.1 相邻两行会压字，想更密请调小字号',
              value: this.sLineHeight,
              min: 1.0,
              max: 2.5,
              step: 0.05,
              defVal: this.dft.lineHeight,
              decimals: 2,
              onChange: (v: number) => {
                this.sLineHeight = Math.round(v * 100) / 100
                this.config.lineHeight = this.sLineHeight
                this.commit()
              }
            })

            this.hairline()

            DmSliderRow({
              title: '字体粗细',
              value: this.sFontWeight,
              min: 1,
              max: 9,
              step: 1,
              defVal: Math.round(this.dft.fontWeight / 100),
              unit: '00',
              onChange: (v: number) => {
                this.sFontWeight = Math.round(v)
                this.config.fontWeight = Math.round(v) * 100
                this.commit()
              }
            })

            this.hairline()

            DmSliderRow({
              title: '描边粗细',
              value: this.sStroke,
              min: 0,
              max: 5,
              step: 0.5,
              defVal: this.dft.borderWidth,
              decimals: 1,
              onChange: (v: number) => {
                this.sStroke = Math.round(v * 10) / 10
                this.config.borderWidth = this.sStroke
                this.commit()
              }
            })
          }
          .width('100%')
          .borderRadius(20)
          .backgroundColor(this.pal.card)
          .border({ width: 0.5, color: this.pal.line })
        
          // ══════════ 时长 ══════════
          this.sectionTitle('时长')

          Column() {
            DmSliderRow({
              title: '滚动弹幕时长',
              desc: '数值越大走得越慢',
              value: this.sScrollDur,
              min: 3,
              max: 20,
              step: 0.5,
              defVal: this.dft.scrollDuration / 1000,
              decimals: 1,
              unit: ' 秒',
              onChange: (v: number) => {
                this.sScrollDur = Math.round(v * 10) / 10
                this.config.scrollDuration = Math.round(v * 1000)
                this.commit()
              }
            })

            this.hairline()

            DmSliderRow({
              title: '静止弹幕时长',
              desc: '顶部 / 底部弹幕的停留时间',
              value: this.sStaticDur,
              min: 1,
              max: 10,
              step: 0.5,
              defVal: this.dft.staticDuration / 1000,
              decimals: 1,
              unit: ' 秒',
              onChange: (v: number) => {
                this.sStaticDur = Math.round(v * 10) / 10
                this.config.staticDuration = Math.round(v * 1000)
                this.commit()
              }
            })
          }
          .width('100%')
          .borderRadius(20)
          .backgroundColor(this.pal.card)
          .border({ width: 0.5, color: this.pal.line })
        
          // ══════════ 其它 ══════════
          this.sectionTitle('其它')

          Column() {
            DmSwitchRow({
              title: '保留原始字号差异',
              desc: '关闭后整屏统一字号（官方行为）；开启时按 B站原字号收敛到 0.85~1.1 倍',
              value: this.swVary,
              onChange: (v: boolean) => {
                this.swVary = v
                this.config.varyFontSize = v
                this.commit()
              }
            })

            this.hairline()

            DmSwitchRow({
              title: '海量弹幕优化',
              desc: '同屏弹幕较多时自动跳过描边，降低绘制开销',
              value: this.swMassive,
              onChange: (v: boolean) => {
                this.swMassive = v
                this.config.massiveMode = v
                this.commit()
              }
            })

            this.hairline()

            DmSwitchRow({
              title: '静止弹幕转滚动',
              desc: '把顶部 / 底部弹幕当作滚动弹幕播放',
              value: this.swStatic2Scroll,
              onChange: (v: boolean) => {
                this.swStatic2Scroll = v
                this.config.static2Scroll = v
                this.commit()
              }
            })

            this.hairline()

            DmSwitchRow({
              title: '滚动弹幕固定速度',
              desc: '开启后所有滚动弹幕速度一致；关闭时长弹幕走得更快（B站原版）',
              value: this.swFixedV,
              onChange: (v: boolean) => {
                this.swFixedV = v
                this.config.scrollFixedVelocity = v
                this.commit()
              }
            })
          }
          .width('100%')
          .borderRadius(20)
          .backgroundColor(this.pal.card)
          .border({ width: 0.5, color: this.pal.line })
        
          Column().width('100%').height(28)
        }
        .width('100%')
        // ⚠️ 左右边距必须放在这里（外层 padding）：卡片是 width('100%')，
        //    给它加 margin 只会把卡片推出容器，视觉上等于没边距
        .padding({ left: 28, right: 28, top: 0, bottom: 8 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    // ⭐ 沉浸光感：本组件根节点原先画不透明 pal.bg（深色≈#161618），把外层 bindSheet 挂的
    //   玻璃整层盖住 → 用户看到"玻璃看不到、上方黑色遮罩"（2026-09-23）。
    //   材质在 backgroundColor 之下，根节点必须透明玻璃才透出来（MaterialUtil 硬要求①）；
    //   不支持材质的设备原样画 pal.bg 走降级。卡片/文字色板（pal.card 等）不动，层次仍靠卡片底拉开。
    .backgroundColor(MaterialUtil.sheetMaterial() !== undefined ? Color.Transparent : this.pal.bg)
  }
}
