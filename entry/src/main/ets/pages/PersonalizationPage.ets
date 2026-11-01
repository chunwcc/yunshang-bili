// PersonalizationPage.ets - 个性化设置（隐藏状态栏、锁定屏幕旋转、默认画质、选择壁纸）
import { common } from '@kit.AbilityKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { LengthMetrics, window } from '@kit.ArkUI';
import {
  hdsMaterial,
  HdsNavigation,
  HdsNavigationTitleMode,
  IconStyleMode,
  ScrollEffectType
} from '@kit.UIDesignKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { StatusBarUtils } from '../utils/StatusBarUtils';
import { WallpaperSelectPage } from './WallpaperSelectPage';
import { loadWallpaperModes, persistWallpaperMode } from '../utils/WallpaperTheme';

interface QualityItem {
  qn: number;
  label: string;
}

interface ActionButton {
  value: string;
  fontColor: string;
  action: () => void;
}

interface DialogButton {
  value: string;
  fontColor: string;
  action: () => void;
}

const QUALITY_LIST: Array<QualityItem> = [
  { qn: 16, label: '360P' },
  { qn: 32, label: '480P' },
  { qn: 64, label: '720P' },
  { qn: 80, label: '1080P' },
  { qn: 112, label: '1080P+' },
  { qn: 116, label: '1080P60' },
  { qn: 120, label: '4K' }
];

const DEFAULT_QN: number = 116;

function labelByQn(qn: number): string {
  const item = QUALITY_LIST.find(q => q.qn === qn);
  return item ? item.label : '1080P60';
}

// ⭐ 全屏过渡动画模式
interface AnimMode {
  value: string;
  label: string;
}

const ANIM_MODES: AnimMode[] = [
  { value: 'none', label: '无' },
  { value: 'slideUpDown', label: '上下滑入/滑出' },
  { value: 'scaleFade', label: '缩放淡出/淡入' },
  { value: 'slideLeftRight', label: '左滑出/右滑入' },
  { value: 'blurFade', label: '模糊' },
  { value: 'flip', label: '翻转' },
  { value: 'minimizeCorner', label: '缩角' },
  { value: 'diagonal', label: '对角线' },
];

function labelByMode(value: string): string {
  const item = ANIM_MODES.find(m => m.value === value);
  return item ? item.label : '上下滑入/滑出';
}

interface FloatBtnSpeedOption {
  value: number;
  label: string;
}

const FLOAT_BTN_SPEEDS: FloatBtnSpeedOption[] = [
  { value: 3, label: '慢' },
  { value: 8, label: '标准' },
  { value: 10, label: '快' },
];

function labelByFloatBtnSpeed(value: number): string {
  const item = FLOAT_BTN_SPEEDS.find(m => m.value === value);
  return item ? item.label : '普通';
}

// ⭐ 缩小播放器后的小窗样式（与 VideoPlayerPage.vidShrink 几何联动）
interface ShrinkStyleOption {
  value: string;
  label: string;
  desc: string;
}

const SHRINK_STYLES: ShrinkStyleOption[] = [
  { value: 'circle', label: '圆形', desc: '缩成直径 120vp 正圆' },
  { value: 'square', label: '正方形', desc: '120×120vp 圆角方窗' },
  { value: 'ratio', label: '等比', desc: '按画面比例缩成小矩窗' },
  { value: 'hidden', label: '隐藏', desc: '不显示小窗，只留还原浮标' },
];

function labelByShrinkStyle(value: string): string {
  const item = SHRINK_STYLES.find(m => m.value === value);
  return item ? item.label : '圆形';
}

// ⭐ 缩小后小窗的尺寸（vp）：Slider 量程 + 默认值，必须与 VideoPlayerPage 里的一致
const SHRINK_SIZE_MIN: number = 80;
const SHRINK_SIZE_MAX: number = 200;
const SHRINK_SIZE_DEFAULT: number = 120;

@Component
export struct PersonalizationPage {
  onClose?: () => void;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 15;
  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @StorageLink('screenOrientationLock') screenOrientationLock: string = '自动旋转';
  @StorageLink('wallpaper') wallpaper: string = 'builtin';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;
  @StorageLink('wallpaperColor') wallpaperColor: string = '#007DFF';
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('savedCustomColors') savedCustomColors: string = '[]';
  // ⭐ 推荐API源切换（Web/App）
  @StorageLink('recommendApiSource') recommendApiSource: string = 'App';
  // ⭐ 全屏切换动画开关（统一连续缩放平移；关闭=瞬时切换）
  @StorageLink('fsAnimOn') fsAnimOn: boolean = true;
  // ⭐ 页面加载动画模式
  @StorageLink('pageEnterAnim') pageEnterAnim: string = 'scaleFade';

  // ⭐ 全局关闭动画总开关
  @StorageLink('da') disableAnimations: boolean = false;
  // ⭐ 关灯模式切换为仅隐藏组件
  @StorageLink('lightsOffHideOnly') lightsOffHideOnly: boolean = false;
  // ⭐ 关灯后显示开灯按钮（默认关闭）
  @StorageLink('lightsOffShowBtn') lightsOffShowBtn: boolean = false;
  // ⭐ 关灯视频外弹幕（默认开启；关闭后弹幕恢复叠加在视频内）
  @StorageLink('lightsOffDanmakuOutside') lightsOffDanmakuOutside: boolean = true;
  // ⭐ 智感握姿开关
  @StorageLink('smartGripEnabled') smartGripEnabled: boolean = true;
  // ⭐ 悬浮按钮跟随颜色主题
  @StorageLink('floatBtnFollowTheme') floatBtnFollowTheme: boolean = true;
  // ⭐ 标题胶囊彩色图标（默认开；关闭后胶囊图标用深浅色模式黑白）
  @StorageLink('capsuleColorIcons') capsuleColorIcons: boolean = true;
  // ⭐ 震动反馈开关（默认开）
  @StorageLink('vibrateEnabled') vibrateEnabled: boolean = true;
  // ⭐ 浮窗封面旋转速度
  @StorageLink('floatBtnRotationSpeed') floatBtnRotationSpeed: number = 8;
  // ⭐ 缩小播放器后的小窗样式：circle / square / ratio / hidden
  @StorageLink('shrinkWindowStyle') shrinkWindowStyle: string = 'circle';
  // ⭐ 缩小后是否自动暂停播放（还原时按需继续）
  @StorageLink('shrinkPauseOnMinimize') shrinkPauseOnMinimize: boolean = false;
  // ⭐ 缩小后小窗的尺寸（vp，即小窗宽；等比样式按它等比算高）
  @StorageLink('shrinkWindowSize') shrinkWindowSize: number = SHRINK_SIZE_DEFAULT;
  @State statusBarHeight: number = 0;
  @State showContent: boolean = false;
  @State defaultQn: number = DEFAULT_QN;
  @State defaultQualityLabel: string = labelByQn(DEFAULT_QN);
  // 颜色选择器状态
  @State colorPickerHue: number = 210;
  @State colorPickerSaturation: number = 85;
  @State colorPickerBrightness: number = 95;
  @State showColorTheme: boolean = false;
  private committedThemeColor: string = '#007DFF'; // 已应用（持久化）的颜色
  @State showColorWheel: boolean = false;
  @State isWallpaperSheetShow: boolean = false;
  @State isAnimModeSheetShow: boolean = false;
  /** ⭐ 动画预览相位（0→1 循环，见 startPreviewLoop） */
  @State previewPhase: number = 0;
  private pvTimer_: number = -1;
  /** ⭐ 预览画布实测宽（vp，onAreaChange 写入）*/
  @State pvCanvasW: number = 0;
  /** ⭐ 参考视频区宽（vp）= 窗口宽 − 2×cardMargin，与 VideoPlayerPage.updatePortraitSize 同一口径 */
  @State pvRefW: number = 0;
  /** ⭐ 小窗尺寸落盘防抖句柄 */
  private sizeSaveTimer_: number = -1;
  @State isFloatBtnSpeedMenuShow: boolean = false;
  @State isOrientationMenuShow: boolean = false;
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D();
  private dataPreferences: preferences.Preferences | null = null;

  private presetColors: string[] = [
    '#007DFF', '#00C853', '#FF6D00', '#E91E63',
    '#9C27B0', '#FFD600', '#00BCD4', '#795548',
  ];

  aboutToDisappear(): void {
    // ⭐ 弹窗若在打开状态下被销毁，定时器必须停掉
    this.stopPreviewLoop();
    // ⭐ 尺寸防抖若还挂着，落一次盘再走（否则最后一段拖动会丢）
    if (this.sizeSaveTimer_ !== -1) {
      clearTimeout(this.sizeSaveTimer_);
      this.sizeSaveTimer_ = -1;
      this.persistShrinkWindowSize(this.shrinkWindowSize);
    }
  }

  async aboutToAppear(): Promise<void> {
    await this.loadSettings();
    await this.getStatusBarHeight();
    await this.measurePreviewRef();
    const hsv = this.hexToHsv(this.customThemeColor);
    this.colorPickerHue = hsv[0];
    this.colorPickerSaturation = hsv[1];
    this.colorPickerBrightness = hsv[2];
    setTimeout(() => {
      this.showContent = true;
    }, 50);
  }

  // ── 颜色选择器方法 ──

  private hexToHsv(hex: string): [number, number, number] {
    const r = parseInt(hex.slice(1, 3), 16) / 255;
    const g = parseInt(hex.slice(3, 5), 16) / 255;
    const b = parseInt(hex.slice(5, 7), 16) / 255;
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const delta = max - min;
    let hue = 0;
    if (delta !== 0) {
      if (max === r) hue = ((g - b) / delta) % 6;
      else if (max === g) hue = (b - r) / delta + 2;
      else hue = (r - g) / delta + 4;
      hue = Math.round(hue * 60);
      if (hue < 0) hue += 360;
    }
    const saturation = max === 0 ? 0 : Math.round((delta / max) * 100);
    const value = Math.round(max * 100);
    return [hue, saturation, value];
  }

  private hsvToHex(h: number, s: number, v: number): string {
    const c = v * s;
    const x = c * (1 - Math.abs((h / 60) % 2 - 1));
    const m = v - c;
    let rp = 0, gp = 0, bp = 0;
    if (h < 60) { rp = c; gp = x; }
    else if (h < 120) { rp = x; gp = c; }
    else if (h < 180) { gp = c; bp = x; }
    else if (h < 240) { gp = x; bp = c; }
    else if (h < 300) { rp = x; bp = c; }
    else { rp = c; bp = x; }
    const toHex = (val: number): string => {
      const str = Math.round((val + m) * 255).toString(16);
      return str.length === 1 ? '0' + str : str;
    };
    return `#${toHex(rp)}${toHex(gp)}${toHex(bp)}`;
  }

  private updateColorPickerPreview(): void {
    this.customThemeColor = this.hsvToHex(this.colorPickerHue, this.colorPickerSaturation / 100, this.colorPickerBrightness / 100);
  }

  // ── 从壁纸自动取色 ──
  private async extractColorFromWallpaper(): Promise<void> {
    if (!this.customWallpaper) {
      this.getUIContext().getPromptAction().showToast({ message: '请先设置自定义壁纸' });
      return;
    }
    try {
      const imgSource = image.createImageSource(this.customWallpaper);
      // 创建小缩略图采样
      const pixelMap: PixelMap = await imgSource.createPixelMap({
        desiredSize: { width: 32, height: 32 }
      });
      const bufSize: number = 32 * 32 * 4;
      const buffer: ArrayBuffer = new ArrayBuffer(bufSize);
      await pixelMap.readPixelsToBuffer(buffer);
      const pixels = new Uint8Array(buffer);
      const colorCounts: Map<string, [number, number, number, number]> = new Map();

      for (let i = 0; i < bufSize; i += 4) {
        const r = Math.round(pixels[i] / 16) * 16;
        const g = Math.round(pixels[i + 1] / 16) * 16;
        const b = Math.round(pixels[i + 2] / 16) * 16;
        const key = `${r},${g},${b}`;
        if (colorCounts.has(key)) {
          const entry = colorCounts.get(key) as [number, number, number, number];
          entry[3] = entry[3] + 1;
        } else {
          colorCounts.set(key, [r, g, b, 1]);
        }
      }

      let maxCount: number = 0;
      let dominant: [number, number, number] = [0, 0, 0];
      colorCounts.forEach((val: [number, number, number, number]) => {
        if (val[3] > maxCount) {
          maxCount = val[3];
          dominant = [val[0], val[1], val[2]];
        }
      });

      const toHex2 = (n: number): string => n.toString(16).padStart(2, '0');
      const hex: string = `#${toHex2(dominant[0])}${toHex2(dominant[1])}${toHex2(dominant[2])}`;

      const hsv: [number, number, number] = this.hexToHsv(hex);
      this.colorPickerHue = hsv[0];
      this.colorPickerSaturation = hsv[1];
      this.colorPickerBrightness = hsv[2];
      this.updateColorPickerPreview();
      this.onCustomColorSelected(hex);

      await pixelMap.release();
      imgSource.release();
      this.getUIContext().getPromptAction().showToast({ message: '已提取壁纸主色' });
    } catch (err) {
      logError('[壁纸取色] 失败:', err);
      this.getUIContext().getPromptAction().showToast({ message: '取色失败，请检查壁纸文件' });
    }
  }

  // ── 色环绘制 ──
  private drawColorWheel(): void {
    const ctx = this.canvasCtx;
    if (!ctx) return;
    const size = 160;
    const cx = size / 2;
    const cy = size / 2;
    const outerR = 69;
    const innerR = 46;

    ctx.clearRect(0, 0, size, size);

    // 色环 360 段弧
    for (let i = 0; i < 360; i++) {
      const a1 = (i - 90) * Math.PI / 180;
      const a2 = (i + 1 - 90) * Math.PI / 180;
      ctx.beginPath();
      ctx.arc(cx, cy, outerR, a1, a2);
      ctx.arc(cx, cy, innerR, a2, a1, true);
      ctx.closePath();
      ctx.fillStyle = this.hsvToHex(i, 1, 1);
      ctx.fill();
    }

    // 当前颜色指示点
    const midR = (outerR + innerR) / 2;
    const angle = (this.colorPickerHue - 90) * Math.PI / 180;
    const ix = cx + midR * Math.cos(angle);
    const iy = cy + midR * Math.sin(angle);

    ctx.beginPath();
    ctx.arc(ix, iy, 6, 0, 2 * Math.PI);
    ctx.fillStyle = '#FFFFFF';
    ctx.fill();
    ctx.strokeStyle = '#333333';
    ctx.lineWidth = 2;
    ctx.stroke();

    // 中心预览小圆
    ctx.beginPath();
    ctx.arc(cx, cy, 14, 0, 2 * Math.PI);
    ctx.fillStyle = this.customThemeColor;
    ctx.fill();
    ctx.strokeStyle = 'rgba(255,255,255,0.4)';
    ctx.lineWidth = 2;
    ctx.stroke();
  }

  private handleColorWheelTouch(event: TouchEvent): void {
    if (event.type !== TouchType.Move && event.type !== TouchType.Down) {return;}
    event.stopPropagation();
    const touch: TouchObject = event.touches[0];
    // Canvas 160x160，中心在 (80, 80)
    const cx: number = 80;
    const cy: number = 80;
    const dx: number = touch.x - cx;
    const dy: number = touch.y - cy;
    const dist: number = Math.sqrt(dx * dx + dy * dy);

    const outerR = 69;
    const innerR = 46;
    if (dist >= innerR && dist <= outerR) {
      let angle = Math.atan2(dy, dx) * 180 / Math.PI + 90;
      if (angle < 0) {angle += 360;}
      this.colorPickerHue = Math.round(angle) % 360;
      this.updateColorPickerPreview();
      this.drawColorWheel();
    }
  }

  private async loadSettings(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.dataPreferences = await preferences.getPreferences(context, 'my_app_settings');
      const storedHideStatusBar = await this.dataPreferences.get('hideStatusBar', false) as boolean;
      const storedOrientationLock = await this.dataPreferences.get('screenOrientationLock', '自动旋转') as string;
      const storedDefaultQn = await this.dataPreferences.get('defaultVideoQn', DEFAULT_QN) as number;

      // 加载壁纸相关设置
      const storedWallpaper = await this.dataPreferences.get('wallpaper', 'builtin') as string;
      const storedCustomPath = await this.dataPreferences.get('customWallpaper', '') as string;
      const storedWallpaperColor = await this.dataPreferences.get('wallpaperColor', '#007DFF') as string;
      const storedCustomColor = await this.dataPreferences.get('customThemeColor', '#007DFF') as string;
      const storedBlur = await this.dataPreferences.get('wallpaperBlur', 0) as number;
      const storedDarkness = await this.dataPreferences.get('wallpaperDarkness', 50) as number;

      // ⭐ 加载推荐API源设置
      const storedRecommendApiSource = await this.dataPreferences.get('recommendApiSource', 'App') as string;
      logInfo(`[PrefDebug] PersonalizationPage.loadSettings 读取recommendApiSource="${storedRecommendApiSource}"` +
        ` (my_app_settings, 默认值=Web)`);
      // ⭐ 加载全屏切换动画开关
      const storedFsAnimOn = await this.dataPreferences.get('fsAnimOn', true) as boolean;
      // ⭐ 加载页面加载动画模式
      const storedPageEnterAnim = await this.dataPreferences.get('pageEnterAnim', 'scaleFade') as string;
      // ⭐ 加载全局动画总开关
      const storedDa = await this.dataPreferences.get('da', false) as boolean;
      // ⭐ 加载关灯模式切换设置
      const storedLightsOffHideOnly = await this.dataPreferences.get('lightsOffHideOnly', false) as boolean;
      // ⭐ 加载关灯后开灯按钮显示设置
      const storedLightsOffShowBtn = await this.dataPreferences.get('lightsOffShowBtn', false) as boolean;
      // ⭐ 加载关灯视频外弹幕设置
      const storedLightsOffDanmakuOutside = await this.dataPreferences.get('lightsOffDanmakuOutside', true) as boolean;
      // ⭐ 加载标题胶囊彩色图标开关（默认开）
      const storedCapsuleColorIcons = await this.dataPreferences.get('capsuleColorIcons', true) as boolean;
      // ⭐ 加载震动反馈开关（默认开）
      const storedVibrateEnabled = await this.dataPreferences.get('vibrateEnabled', true) as boolean;
      const storedShrinkWindowStyle = await this.dataPreferences.get('shrinkWindowStyle', 'circle') as string;
      const storedShrinkPauseOnMinimize = await this.dataPreferences.get('shrinkPauseOnMinimize', false) as boolean;
      const storedShrinkWindowSize = await this.dataPreferences.get('shrinkWindowSize', SHRINK_SIZE_DEFAULT) as number;

      this.hideStatusBar = storedHideStatusBar;
      this.screenOrientationLock = storedOrientationLock;
      this.defaultQn = storedDefaultQn;
      this.defaultQualityLabel = labelByQn(storedDefaultQn);

      this.wallpaper = storedWallpaper;
      this.customWallpaper = storedCustomPath;
      this.wallpaperColor = storedWallpaperColor;
      this.customThemeColor = storedCustomColor;
      this.committedThemeColor = storedCustomColor;
      this.wallpaperBlur = storedBlur;
      this.wallpaperDarkness = storedDarkness;

      // ⭐ 加载已保存的自定义颜色列表
      const storedSavedColors = await this.dataPreferences.get('savedCustomColors', '[]') as string;
      AppStorage.set('savedCustomColors', storedSavedColors);
      this.recommendApiSource = storedRecommendApiSource;
      this.fsAnimOn = storedFsAnimOn;
      this.pageEnterAnim = storedPageEnterAnim;
      this.disableAnimations = storedDa;
      this.lightsOffHideOnly = storedLightsOffHideOnly;
      this.lightsOffShowBtn = storedLightsOffShowBtn;
      this.lightsOffDanmakuOutside = storedLightsOffDanmakuOutside;
      this.capsuleColorIcons = storedCapsuleColorIcons;
      this.vibrateEnabled = storedVibrateEnabled;

      AppStorage.set('hideStatusBar', storedHideStatusBar);
      AppStorage.set('screenOrientationLock', storedOrientationLock);
      AppStorage.set('defaultVideoQn', storedDefaultQn);
      AppStorage.set('wallpaper', storedWallpaper);
      AppStorage.set('customWallpaper', storedCustomPath);
      AppStorage.set('wallpaperColor', storedWallpaperColor);
      AppStorage.set('customThemeColor', storedCustomColor);
      AppStorage.set('wallpaperBlur', storedBlur);
      AppStorage.set('wallpaperDarkness', storedDarkness);
      // 加载深/浅两套壁纸存档并装载当前模式（缺失时回填激活值）
      await loadWallpaperModes(this.dataPreferences, this.isDarkMode);
      AppStorage.set('recommendApiSource', storedRecommendApiSource);
      AppStorage.set('fsAnimOn', storedFsAnimOn);
      AppStorage.set('pageEnterAnim', storedPageEnterAnim);
      AppStorage.set('da', storedDa);
      AppStorage.set('lightsOffHideOnly', storedLightsOffHideOnly);
      AppStorage.set('lightsOffShowBtn', storedLightsOffShowBtn);
      AppStorage.set('lightsOffDanmakuOutside', storedLightsOffDanmakuOutside);
      AppStorage.set('capsuleColorIcons', storedCapsuleColorIcons);
      AppStorage.set('vibrateEnabled', storedVibrateEnabled);
      AppStorage.set('shrinkWindowStyle', storedShrinkWindowStyle);
      AppStorage.set('shrinkPauseOnMinimize', storedShrinkPauseOnMinimize);
      AppStorage.set('shrinkWindowSize', Math.max(SHRINK_SIZE_MIN, Math.min(SHRINK_SIZE_MAX, Math.round(storedShrinkWindowSize))));

      await this.applyOrientationLock(storedOrientationLock);
    } catch (err) {
      logError(`加载个性化设置失败: ${err}`);
    }
  }

  private async saveHideStatusBar(isOn: boolean): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('hideStatusBar', isOn);
      await this.dataPreferences.flush();
      AppStorage.set('hideStatusBar', isOn);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // 横屏时强制隐藏状态栏，忽略用户开关
      const isLandscape = AppStorage.get<boolean>('isLandscape') ?? false;
      await StatusBarUtils.setStatusBarHidden(context, isLandscape || isOn);
      await this.getStatusBarHeight();
    } catch (err) {
      logError(`保存隐藏状态栏失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
  }

  /** ⭐ 保存标题胶囊彩色图标开关 */
  private async saveCapsuleColorIcons(isOn: boolean): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('capsuleColorIcons', isOn);
      await this.dataPreferences.flush();
      AppStorage.set('capsuleColorIcons', isOn);
    } catch (err) {
      logError(`保存标题胶囊彩色图标失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
  }

  private async saveDisableAnimations(isOn: boolean): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('da', isOn);
      await this.dataPreferences.flush();
      AppStorage.set('da', isOn);
      this.disableAnimations = isOn;
    } catch (err) {
      logError(`保存关闭动画设置失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
  }

  // ⭐ 保存关灯模式切换设置
  private async saveLightsOffHideOnly(isOn: boolean): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('lightsOffHideOnly', isOn);
      await this.dataPreferences.flush();
      AppStorage.set('lightsOffHideOnly', isOn);
      this.lightsOffHideOnly = isOn;
    } catch (err) {
      logError(`保存关灯模式设置失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
  }

  // ⭐ 保存关灯后开灯按钮显示设置
  private async saveLightsOffShowBtn(isOn: boolean): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('lightsOffShowBtn', isOn);
      await this.dataPreferences.flush();
      AppStorage.set('lightsOffShowBtn', isOn);
      this.lightsOffShowBtn = isOn;
    } catch (err) {
      logError(`保存开灯按钮显示设置失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
  }

  // ⭐ 保存关灯视频外弹幕设置
  private async saveLightsOffDanmakuOutside(isOn: boolean): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('lightsOffDanmakuOutside', isOn);
      await this.dataPreferences.flush();
      AppStorage.set('lightsOffDanmakuOutside', isOn);
      this.lightsOffDanmakuOutside = isOn;
    } catch (err) {
      logError(`保存关灯视频外弹幕设置失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
  }

  // ⭐ 保存智感握姿开关
  private async saveSmartGripEnabled(isOn: boolean): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('smartGripEnabled', isOn);
      await this.dataPreferences.flush();
      AppStorage.set('smartGripEnabled', isOn);
      this.smartGripEnabled = isOn;
    } catch (err) {
      logError(`保存智感握姿设置失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
  }

  // ⭐ 保存震动反馈开关
  private async saveVibrateEnabled(isOn: boolean): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('vibrateEnabled', isOn);
      await this.dataPreferences.flush();
      AppStorage.set('vibrateEnabled', isOn);
      this.vibrateEnabled = isOn;
    } catch (err) {
      logError(`保存震动反馈设置失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
  }

  // ⭐ 保存悬浮按钮跟随颜色主题
  private async saveFloatBtnFollowTheme(isOn: boolean): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('floatBtnFollowTheme', isOn);
      await this.dataPreferences.flush();
      AppStorage.set('floatBtnFollowTheme', isOn);
      this.floatBtnFollowTheme = isOn;
    } catch (err) {
      logError(`保存悬浮按钮跟随颜色主题失败: ${err}`);
    }
  }

  private async saveOrientationLock(lock: string): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('screenOrientationLock', lock);
      await this.dataPreferences.flush();
      AppStorage.set('screenOrientationLock', lock);
      await this.applyOrientationLock(lock);
      this.screenOrientationLock = lock;
    } catch (err) {
      logError(`保存屏幕旋转锁定失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
  }

  private async saveDefaultQn(qn: number): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('defaultVideoQn', qn);
      await this.dataPreferences.flush();
      AppStorage.set('defaultVideoQn', qn);
      this.defaultQn = qn;
      this.defaultQualityLabel = labelByQn(qn);
    } catch (err) {
      logError(`保存默认画质失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
  }

  // ⭐ 保存推荐API源设置
  private async saveRecommendApiSource(source: string): Promise<void> {
    if (!this.dataPreferences) {
      logError(`[PrefDebug] saveRecommendApiSource: dataPreferences 为 null，无法保存`);
      return;
    }
    try {
      logInfo(`[PrefDebug] saveRecommendApiSource: 正在保存 source="${source}"` +
        ` 到 Preferences(my_app_settings, key=recommendApiSource)`);
      await this.dataPreferences.put('recommendApiSource', source);
      await this.dataPreferences.flush();
      AppStorage.set('recommendApiSource', source);
      this.recommendApiSource = source;
      logInfo(`[PrefDebug] saveRecommendApiSource: 保存成功, AppStorage.get()="${AppStorage.get<string>('recommendApiSource')}"`);
      this.getUIContext().getPromptAction().showToast({ message: `已切换到${source} API` });
    } catch (err) {
      logError(`保存推荐API源失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
  }

  // 显示推荐API源选择对话框
  private showRecommendApiPicker(): void {
    const primaryColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const cancelColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const backgroundColor = this.isDarkMode ? 'rgba(44, 44, 44, 0.95)' : 'rgba(255, 255, 255, 0.95)';

    AlertDialog.show({
      title: '选择推荐API源',
      message: 'Web API: 更稳定，推荐质量较高\nApp API: 更新更快，内容更丰富',
      backgroundColor: backgroundColor,
      buttons: [
        {
          value: 'Web API',
          fontColor: primaryColor,
          action: () => {
            this.saveRecommendApiSource('Web');
          }
        },
        {
          value: 'App API',
          fontColor: primaryColor,
          action: () => {
            this.saveRecommendApiSource('App');
          }
        },
        {
          value: '取消',
          fontColor: cancelColor,
          action: () => {
            // 取消操作
          }
        }
      ]
    });
  }

  // ⭐ 全屏切换动画开关保存
  private async saveFsAnimOn(on: boolean): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('fsAnimOn', on);
      await this.dataPreferences.flush();
      AppStorage.set('fsAnimOn', on);
      this.fsAnimOn = on;
      this.getUIContext().getPromptAction().showToast({ message: on ? '进出全屏动画：开' : '进出全屏动画：关' });
    } catch (err) {
      logError(`保存全屏动画开关失败: ${err}`);
    }
  }

  // ⭐ 页面加载动画模式保存
  private async savePageEnterAnim(mode: string): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('pageEnterAnim', mode);
      await this.dataPreferences.flush();
      AppStorage.set('pageEnterAnim', mode);
      this.pageEnterAnim = mode;
      this.getUIContext().getPromptAction().showToast({ message: `页面加载：${labelByMode(mode)}` });
    } catch (err) {
      logError(`保存页面加载动画失败: ${err}`);
    }
  }

  private showAnimModePicker(): void {
    this.isAnimModeSheetShow = true;
    this.startPreviewLoop();
  }

  /** ⭐ 弹窗关闭时务必停掉预览循环（25fps 的 @State churn，留着白耗电） */
  private stopPreviewLoop(): void {
    if (this.pvTimer_ !== -1) {
      clearInterval(this.pvTimer_);
      this.pvTimer_ = -1;
    }
  }

  /**
   * ⭐ 动画预览循环：**8 张卡共用一个相位** `previewPhase`(0→1)，
   *    每张卡按自己的模式把相位换算成位移/缩放/透明度 —— 只有一个定时器，
   *    代价与卡片数无关（每张卡各起一个定时器会把弹窗拖卡）。
   *    周期 3.2s（40ms × 80 步）：前 30% 静置、中间离场、后段归位，眼睛跟得上。
   */
  private startPreviewLoop(): void {
    this.stopPreviewLoop();
    if (this.disableAnimations) {   // 「关闭所有动画」开着就摆一个静态姿势
      this.previewPhase = 0;
      return;
    }
    this.pvTimer_ = setInterval(() => {
      this.previewPhase = (this.previewPhase + 0.0125) % 1;
    }, 40);
  }

  /** 相位 → 离场系数 k：0=正常，1=完全离场（两端各留 30% 静置段） */
  private pvK(): number {
    const p = this.previewPhase;
    if (p < 0.30) return 0;
    if (p < 0.50) return (p - 0.30) / 0.20;
    if (p < 0.70) return 1;
    if (p < 0.90) return 1 - (p - 0.70) / 0.20;
    return 0;
  }
  private pvTx(value: string): number {
    const k = this.pvK();
    if (value === 'slideLeftRight') return -22 * k;
    if (value === 'minimizeCorner') return -10 * k;
    if (value === 'diagonal') return -8 * k;
    return 0;
  }
  private pvTy(value: string): number {
    const k = this.pvK();
    if (value === 'slideUpDown') return -14 * k;
    if (value === 'minimizeCorner') return -8 * k;
    if (value === 'diagonal') return 7 * k;
    return 0;
  }
  private pvScale(value: string): number {
    const k = this.pvK();
    if (value === 'scaleFade') return 1 - 0.55 * k;
    if (value === 'minimizeCorner') return 1 - 0.6 * k;
    return 1;
  }
  private pvOpacity(value: string): number {
    if (value === 'none' || value === 'flip') return 1;
    return 1 - 0.7 * this.pvK();
  }
  private pvRotY(value: string): number {
    if (value === 'flip') return 80 * this.pvK();
    return 0;
  }
  private pvBlur(value: string): number {
    if (value === 'blurFade') return 3 * this.pvK();
    return 0;
  }
  /** 弹窗内统一取色（预览画布 / 卡片底） */
  private pvCardBg(): string {
    return this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.03)';
  }
  private pvCanvasBg(): string {
    return this.isDarkMode ? 'rgba(255,255,255,0.08)' : '#FFFFFF';
  }
  private pvLine(): string {
    return this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.08)';
  }
  /** 预览缩放比 = 预览画布宽 / 参考视频区宽（两边都用 vp，纯比例） */
  private pvUiScale(): number {
    const ref = this.pvRefW > 0 ? this.pvRefW : 493;
    const w = this.pvCanvasW > 0 ? this.pvCanvasW : 360;
    return w / ref;
  }

  /** 尺寸预览里那个形状的边长（vp）：真实尺寸 × 缩放比 → 与视频区的相对大小和真机一致 */
  private pvShapeSize(): number {
    return Math.max(6, Math.round(this.shrinkWindowSize * this.pvUiScale()));
  }

  /** 预览画布高度：按最大档（200vp）也能完整放下，避免拖到最大时被裁 */
  private pvBoxH(): number {
    return Math.max(96, Math.round(SHRINK_SIZE_MAX * this.pvUiScale()) + 20);
  }

  /** 尺寸预览里「等比」的高度：设置页拿不到真实画幅，统一按 16:9 折算（播放页仍按真实比例） */
  private pvRatioH(): number {
    return Math.max(6, Math.round(this.pvShapeSize() * 9 / 16));
  }

  /** 尺寸预览的圆角：与播放页保持同一套比例（圆=边长一半 / 正方形 30:120 / 等比 10:120） */
  private pvShapeRadius(): number {
    const sz = this.pvShapeSize();
    if (this.shrinkWindowStyle === 'circle') return sz / 2;
    if (this.shrinkWindowStyle === 'square') return Math.round(sz * 30 / 120);
    if (this.shrinkWindowStyle === 'ratio') return Math.round(sz * 10 / 120);
    return 0;
  }

  /** 选中卡：主题色描边（不叠 alpha 底色，避免自定义主题色算不出色值） */
  private pvBorder(selected: boolean): BorderOptions {
    return selected
      ? { width: 1.5, color: this.customThemeColor }
      : { width: 0.5, color: this.pvLine() };
  }
  /** 形状卡的填充色（选中=主题色） */
  private shapeFill(mode: string): string {
    if (this.shrinkWindowStyle === mode) return this.customThemeColor;
    return this.isDarkMode ? 'rgba(255,255,255,0.22)' : '#D3D1C7';
  }

  private showFloatBtnSpeedPicker(): void {
    this.isFloatBtnSpeedMenuShow = true;
  }

  private async saveFloatBtnRotationSpeed(value: number): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('floatBtnRotationSpeed', value);
      await this.dataPreferences.flush();
      AppStorage.set('floatBtnRotationSpeed', value);
      this.floatBtnRotationSpeed = value;
      this.getUIContext().getPromptAction().showToast({ message: `浮窗旋转速度：${labelByFloatBtnSpeed(value)}` });
    } catch (err) {
      logError(`保存浮窗旋转速度失败: ${err}`);
    }
  }

  /** ⭐ 保存小窗样式（Preferences 'my_app_settings' + AppStorage 双向） */
  private async saveShrinkWindowStyle(value: string): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('shrinkWindowStyle', value);
      await this.dataPreferences.flush();
      AppStorage.set('shrinkWindowStyle', value);
      this.getUIContext().getPromptAction().showToast({ message: `小窗样式：${labelByShrinkStyle(value)}` });
    } catch (err) {
      logError(`保存小窗样式失败: ${err}`);
    }
  }

  /**
   * ⭐ 保存小窗尺寸：@StorageLink 赋值即生效，落盘做 400ms 防抖
   *    （拖一次滑块会有几十次 onChange，每次都 flush 会把磁盘写爆、也会卡手）。
   */
  private saveShrinkWindowSize(v: number): void {
    const val = Math.max(SHRINK_SIZE_MIN, Math.min(SHRINK_SIZE_MAX, Math.round(v)));
    this.shrinkWindowSize = val;   // @StorageLink：同步写入 AppStorage，播放页立即拿到
    if (this.sizeSaveTimer_ !== -1) {
      clearTimeout(this.sizeSaveTimer_);
    }
    this.sizeSaveTimer_ = setTimeout(() => {
      this.sizeSaveTimer_ = -1;
      this.persistShrinkWindowSize(this.shrinkWindowSize);
    }, 400);
  }

  private async persistShrinkWindowSize(val: number): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('shrinkWindowSize', val);
      await this.dataPreferences.flush();
    } catch (err) {
      logError(`保存小窗尺寸失败: ${err}`);
    }
  }

  /** ⭐ 保存「缩小后暂停播放」 */
  private async saveShrinkPauseOnMinimize(isOn: boolean): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('shrinkPauseOnMinimize', isOn);
      await this.dataPreferences.flush();
      AppStorage.set('shrinkPauseOnMinimize', isOn);
    } catch (err) {
      logError(`保存缩小后暂停失败: ${err}`);
    }
  }

  /** 半宽开关卡（方案 B：两个开关并排，把纵向空间让给预览网格） */
  @Builder
  PvToggleCard(title: string, desc: string, on: boolean, cb: (v: boolean) => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .alignSelf(ItemAlign.Start)
        Text(desc)
          .fontSize(11)
          .fontColor(this.isDarkMode ? '#888888' : '#999999')
          .margin({ top: 2 })
          .alignSelf(ItemAlign.Start)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: on })
        .selectedColor(this.customThemeColor)
        .onChange((isOn: boolean) => { cb(isOn); })
    }
    .layoutWeight(1)
    .padding({ left: 12, right: 8, top: 10, bottom: 10 })
    .backgroundColor(this.pvCardBg())
    .borderRadius(12)
  }

  /** 小窗样式形状卡：直接画出该样式的真实轮廓 */
  @Builder
  PvShapeCard(label: string, mode: string) {
    Column() {
      if (mode === 'ratio') {
        Row()
          .width(28).height(16).borderRadius(3)
          .backgroundColor(this.shapeFill(mode))
      } else if (mode === 'hidden') {
        Stack() {
          Row()
            .width(24).height(24).borderRadius(6)
            .border({ width: 1, color: this.isDarkMode ? '#6B6B70' : '#B4B2A9', style: BorderStyle.Dashed })
          Row()
            .width(30).height(1)
            .backgroundColor(this.isDarkMode ? '#6B6B70' : '#B4B2A9')
            .rotate({ angle: -45 })
        }
        .width(30).height(26)
      } else {
        Row()
          .width(24).height(24)
          .borderRadius(mode === 'circle' ? 12 : 7)
          .backgroundColor(this.shapeFill(mode))
      }

      Text(label)
        .fontSize(11)
        .fontWeight(this.shrinkWindowStyle === mode ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.shrinkWindowStyle === mode
          ? this.customThemeColor
          : (this.isDarkMode ? '#AAAAAA' : '#666666'))
        .margin({ top: 6 })
    }
    .layoutWeight(1)
    .padding({ top: 9, bottom: 9 })
    .backgroundColor(this.pvCardBg())
    .borderRadius(12)
    .border(this.pvBorder(this.shrinkWindowStyle === mode))
    .onClick(() => { this.saveShrinkWindowStyle(mode); })
  }

  /** 小窗尺寸调节行（单选一条：尺寸对圆形/正方形/等比都生效，隐藏样式下无意义） */
  @Builder
  PvSizeRow() {
    Column() {
      Row() {
        Text('小窗大小')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Blank()
        // ⭐ 恢复默认：**实心胶囊**（主题色底 + 白字）——描边款在深色底上仍然"糊"在看板里，
        //    实心才是唯一一眼能认出的按钮形态；已处于默认值时整体转中性灰（形状还在，告知"当前无需恢复"）
        Text('恢复默认')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.shrinkWindowSize === SHRINK_SIZE_DEFAULT
            ? (this.isDarkMode ? '#8A8A90' : '#9A9AA0')
            : '#FFFFFF')
          .padding({ left: 13, right: 13, top: 6, bottom: 6 })
          .backgroundColor(this.shrinkWindowSize === SHRINK_SIZE_DEFAULT
            ? (this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.06)')
            : this.customThemeColor)
          .borderRadius(15)
          // .shadow(this.shrinkWindowSize === SHRINK_SIZE_DEFAULT
          //   ? { radius: 0, color: '#00000000' }
          //   : { radius: 8, color: '#33000000', offsetY: 2 })
          .margin({ right: 6 })
          .onClick(() => { this.saveShrinkWindowSize(SHRINK_SIZE_DEFAULT); })
        Text(`${Math.round(this.shrinkWindowSize)} vp`)
          .fontSize(11)
          .fontColor(this.customThemeColor)
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.05)')
          .borderRadius(9)
      }
      .width('100%')

      // ⭐ 实时预览：上面那块是"视频区"的示意，形状按当前尺寸/样式画在左上角
      //    （真机缩小时小窗也贴在视频区左上，位置语义一致）；拖动滑块会立刻跟着变。
      Stack() {
        if (this.shrinkWindowStyle === 'hidden') {
          Stack() {
            Row()
              .width(this.pvShapeSize()).height(this.pvShapeSize()).borderRadius(6)
              .border({ width: 1, color: this.isDarkMode ? '#6B6B70' : '#B4B2A9', style: BorderStyle.Dashed })
            Row()
              .width(Math.round(this.pvShapeSize() * 1.2)).height(1)
              .backgroundColor(this.isDarkMode ? '#6B6B70' : '#B4B2A9')
              .rotate({ angle: -45 })
          }
        } else {
          Row()
            .width(this.pvShapeSize())
            .height(this.shrinkWindowStyle === 'ratio' ? this.pvRatioH() : this.pvShapeSize())
            .borderRadius(this.pvShapeRadius())
            .backgroundColor(this.customThemeColor)
        }
      }
      .width('100%')
      .height(this.pvBoxH())
      .padding(10)
      .backgroundColor(this.pvCanvasBg())
      .borderRadius(10)
      .alignContent(Alignment.Center)   // 形状居中：尺寸对比更直观（真机上小窗贴的是视频区左上角）
      .margin({ top: 8, bottom: 6 })
      // ⭐ 画布宽度实测回来才能算缩放比（写死宽度会在不同窗口/折叠态下偏）
      .onAreaChange((_o: Area, n: Area) => {
        const w = Number(n.width);
        if (Number.isFinite(w) && w > 0 && Math.abs(w - this.pvCanvasW) > 0.5) {
          this.pvCanvasW = w;
        }
      })

      // ⚠️ 同弹幕面板：必须 InSet —— OutSet 下 trackThickness 不生效（永远是 ~4vp 细轨）
      Slider({
        value: this.shrinkWindowSize,
        min: SHRINK_SIZE_MIN,
        max: SHRINK_SIZE_MAX,
        step: 5,
        style: SliderStyle.InSet
      })
        .width('100%')
        .height(40)
        .selectedColor(this.customThemeColor)
        .trackColor(this.isDarkMode ? '#3A3A42' : '#E4E4E9')
        .trackThickness(16)
        .blockSize({ width: 20, height: 20 })
        .blockColor('#FFFFFF')
        .enabled(this.shrinkWindowStyle !== 'hidden')
        .opacity(this.shrinkWindowStyle === 'hidden' ? 0.35 : 1)
        .onChange((v: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.Begin) {
            return;
          }
          this.saveShrinkWindowSize(v);
        })

      Text(this.shrinkWindowStyle === 'hidden'
        ? '「隐藏」样式下不显示小窗，此项不生效'
        : `小窗宽度，默认 ${SHRINK_SIZE_DEFAULT} vp；预览与真机等比（按 16:9 视频的内联播放区折算）`)
        .fontSize(11)
        .fontColor(this.isDarkMode ? '#888888' : '#999999')
        .width('100%')
        .margin({ top: 2 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.pvCardBg())
    .borderRadius(12)
    .margin({ bottom: 16 })
  }

  /** 动效预览卡：画布里的小方块按该模式实时播放 */
  @Builder
  PvAnimCard(label: string, value: string) {
    Column() {
      Stack() {
        Row()
          .width(30).height(18).borderRadius(3)
          .backgroundColor(value === 'none'
            ? (this.isDarkMode ? '#6B6B70' : '#888780')
            : '#85B7EB')
          .translate({ x: this.pvTx(value), y: this.pvTy(value) })
          .scale({ x: this.pvScale(value), y: this.pvScale(value) })
          .opacity(this.pvOpacity(value))
          .rotate({ y: 1, angle: this.pvRotY(value) })   // ⚠️ RotateOptions 的 angle 是必填：y=1 表示绕 Y 轴翻转
          .blur(this.pvBlur(value))
      }
      .width('100%').height(50)
      .backgroundColor(this.pvCanvasBg())
      .borderRadius(8)
      .clip(true)

      Text(label)
        .fontSize(12)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontWeight(this.pageEnterAnim === value ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.pageEnterAnim === value
          ? this.customThemeColor
          : (this.isDarkMode ? '#CCCCCC' : '#333333'))
        .margin({ top: 6 })
    }
    .width('48.5%')
    .padding(8)
    .backgroundColor(this.pvCardBg())
    .borderRadius(12)
    .border(this.pvBorder(this.pageEnterAnim === value))
    .margin({ bottom: 8 })
    .onClick(() => { this.savePageEnterAnim(value); })
  }

  @Builder
  AnimModeSheetContent() {
    HdsNavigation() {
      Scroll() {
        Column() {
          // ── 两个开关（半宽并排）──
          Row({ space: 8 }) {
            this.PvToggleCard('进出全屏动画',
              this.fsAnimOn ? '连续缩放平移' : '瞬时切换',
              this.fsAnimOn,
              (v: boolean) => { this.saveFsAnimOn(v); })
            this.PvToggleCard('缩小后暂停',
              this.shrinkPauseOnMinimize ? '缩小即暂停' : '缩小时保持播放',
              this.shrinkPauseOnMinimize,
              (v: boolean) => { this.saveShrinkPauseOnMinimize(v); })
          }
          .width('100%')
          .margin({ bottom: 16 })

          // ── 小窗样式（4 张形状卡）──
          Text('缩小后的小窗样式')
            .fontSize(11)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .margin({ bottom: 6 })
          Row({ space: 8 }) {
            this.PvShapeCard('圆形', 'circle')
            this.PvShapeCard('正方形', 'square')
            this.PvShapeCard('等比', 'ratio')
            this.PvShapeCard('隐藏', 'hidden')
          }
          .width('100%')
          .margin({ bottom: 10 })

          this.PvSizeRow()

          // ── 页面加载动画（2 列预览网格）──
          Row() {
            Text('页面加载动画')
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
            Blank()
            Text('共 8 种')
              .fontSize(11)
              .fontColor($r('sys.color.font_tertiary'))
          }
          .width('100%')
          .margin({ bottom: 6 })

          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
            ForEach(ANIM_MODES, (mode: AnimMode) => {
              this.PvAnimCard(mode.label, mode.value)
            })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ top: 56 + 12, left: 16, right: 16, bottom: 24 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .titleMode(HdsNavigationTitleMode.MODAL)
    .titleBar({
      padding: { start: LengthMetrics.vp(16), end: LengthMetrics.vp(16) },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        },
        originalStyle: {
          backgroundStyle: { backgroundColor: 'transparent' },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            menuStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') },
            backIconStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: { backgroundColor: 'transparent' },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            menuStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') },
            backIconStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') }
          }
        }
      },
      content: {
        title: {
          mainTitle: '视频页动画',
          subTitle: '实时预览'
        },
        menu: {
          value: [
            {
              content: {
                label: 'modal_cancel',
                isEnabled: true,
                type: IconStyleMode.SMALL,
                action: (): void => {
                  this.isAnimModeSheetShow = false;
                  this.stopPreviewLoop();
                }
              }
            }
          ]
        }
      }
    })
  }

  @Builder
  FloatBtnSpeedMenuBuilder() {
    Menu() {
      ForEach(FLOAT_BTN_SPEEDS, (option: FloatBtnSpeedOption) => {
        MenuItem({
          content: option.label,
          labelInfo: this.floatBtnRotationSpeed === option.value ? '当前' : ''
        })
          .selectIcon(this.floatBtnRotationSpeed === option.value)
          .selected(this.floatBtnRotationSpeed === option.value)
          .onClick(() => {
            this.isFloatBtnSpeedMenuShow = false;
            this.saveFloatBtnRotationSpeed(option.value);
          })
      }, (option: FloatBtnSpeedOption) => `${option.value}_${option.label}`)
    }
  }

  // ── 壁纸相关方法 ──

  private async saveBlur(value: number): Promise<void> {
    this.wallpaperBlur = value;
    AppStorage.set('wallpaperBlur', value);
    await this.saveWallpaperSettings();
  }

  private async saveDarkness(value: number): Promise<void> {
    this.wallpaperDarkness = value;
    AppStorage.set('wallpaperDarkness', value);
    await this.saveWallpaperSettings();
  }

  private async saveWallpaperSettings(): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('wallpaper', this.wallpaper);
      await this.dataPreferences.put('customWallpaper', this.customWallpaper);
      await this.dataPreferences.put('wallpaperColor', this.wallpaperColor);
      await this.dataPreferences.put('customThemeColor', this.customThemeColor);
      await this.dataPreferences.put('wallpaperBlur', this.wallpaperBlur);
      await this.dataPreferences.put('wallpaperDarkness', this.wallpaperDarkness);
      // 同步持久化当前系统模式的独立存档
      await persistWallpaperMode(this.isDarkMode, this.dataPreferences);
      await this.dataPreferences.flush();
    } catch (err) {
      logError(`保存壁纸设置失败: ${err}`);
    }
  }

  private async pickImageFromAlbum(): Promise<void> {
    try {
      const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = 1;
      const photoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const photoSelectResult = await photoViewPicker.select(photoSelectOptions);
      if (photoSelectResult.photoUris.length === 0) return;
      const sourceUri = photoSelectResult.photoUris[0];
      const uiContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const filesDir = uiContext.filesDir;
      const fileName = `wallpaper_${Date.now()}.jpg`;
      const destUri = `${filesDir}/${fileName}`;
      const srcFile = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      const destFile = fileIo.openSync(destUri, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      const buffer = new ArrayBuffer(4096);
      let readLen = 0;
      while ((readLen = fileIo.readSync(srcFile.fd, buffer)) > 0) {
        fileIo.writeSync(destFile.fd, buffer.slice(0, readLen));
      }
      fileIo.closeSync(srcFile.fd);
      fileIo.closeSync(destFile.fd);
      this.wallpaper = 'custom';
      this.customWallpaper = destUri;
      await this.saveWallpaperSettings();
      this.getUIContext().getPromptAction().showToast({ message: '壁纸已更换' });
    } catch (error) {
      const err = error as BusinessError;
      this.getUIContext().getPromptAction().showToast({ message: `失败: ${err.message}` });
    }
  }

  private async onCustomColorSelected(color: string): Promise<void> {
    this.customThemeColor = color;
    this.committedThemeColor = color;
    AppStorage.set('customThemeColor', color);
    await this.saveWallpaperSettings();
    this.getUIContext().getPromptAction().showToast({ message: '自定义颜色已应用' });
  }

  // ⭐ 获取已保存颜色列表
  private getSavedColorsList(): string[] {
    try {
      const arr: string[] = JSON.parse(this.savedCustomColors) as string[];
      return arr;
    } catch (e) {
      return [];
    }
  }

  // ⭐ 保存当前色卡到已存列表
  private async saveCurrentColor(): Promise<void> {
    const color: string = this.customThemeColor;
    const list: string[] = this.getSavedColorsList();
    // 去重：已存在则移到最前
    const idx: number = list.indexOf(color);
    if (idx !== -1) {
      list.splice(idx, 1);
    }
    // 已达上限 8 个且非重复色 → 提示先删除
    if (list.length >= 8 && idx === -1) {
      this.getUIContext().getPromptAction().showToast({ message: '已保存颜色已达上限(8个)，请长按删除多余颜色' });
      return;
    }
    list.unshift(color);
    AppStorage.set('savedCustomColors', JSON.stringify(list));
    // 持久化到 Preferences
    if (this.dataPreferences) {
      try {
        await this.dataPreferences.put('savedCustomColors', JSON.stringify(list));
        await this.dataPreferences.flush();
      } catch (e) {
        logError(`保存已保存颜色失败: ${e}`);
      }
    }
    this.getUIContext().getPromptAction().showToast({ message: '颜色已保存' });
  }

  // ⭐ 删除已保存颜色（长按触发）
  private async removeSavedColor(index: number): Promise<void> {
    const list: string[] = this.getSavedColorsList();
    if (index >= 0 && index < list.length) {
      list.splice(index, 1);
      AppStorage.set('savedCustomColors', JSON.stringify(list));
      // 持久化到 Preferences
      if (this.dataPreferences) {
        try {
          await this.dataPreferences.put('savedCustomColors', JSON.stringify(list));
          await this.dataPreferences.flush();
        } catch (e) {
          logError(`保存已保存颜色失败: ${e}`);
        }
      }
      this.getUIContext().getPromptAction().showToast({ message: '已删除' });
    }
  }

  private async resetToDefault(): Promise<void> {
    this.wallpaper = 'default';
    this.customWallpaper = '';
    await this.saveWallpaperSettings();
    this.getUIContext().getPromptAction().showToast({ message: '已恢复默认背景' });
  }

  private showWallpaperPicker(): void {
    this.isWallpaperSheetShow = true;
  }

  private dismissColorThemeSheet(): void {
    if (this.customThemeColor !== this.committedThemeColor) {
      AlertDialog.show({
        title: '退出颜色主题',
        message: '有未应用的颜色更改，退出后将丢失。是否退出？',
        autoCancel: false,
        primaryButton: {
          value: '取消',
          fontColor: this.isDarkMode ? '#FFFFFF' : '#000000',
          action: () => {}
        },
        secondaryButton: {
          value: '退出',
          fontColor: '#E84040',
          action: () => {
            this.customThemeColor = this.committedThemeColor;
            this.showColorTheme = false;
          }
        }
      });
    } else {
      this.showColorTheme = false;
    }
  }

  @Builder
  WallpaperSheetContent() {
    HdsNavigation() {
      WallpaperSelectPage({ onClose: () => { this.isWallpaperSheetShow = false; } })
    }
    .titleMode(HdsNavigationTitleMode.MODAL)
    .titleBar({
      padding: { start: LengthMetrics.vp(16), end: LengthMetrics.vp(16) },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        },
        originalStyle: {
          backgroundStyle: { backgroundColor: 'transparent' },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            menuStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') },
            backIconStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: { backgroundColor: 'transparent' },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            menuStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') },
            backIconStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') }
          }
        }
      },
      content: {
        title: {
          mainTitle: '壁纸设置'
        },
        menu: {
          value: [
            {
              content: {
                label: 'modal_cancel',
                isEnabled: true,
                type: IconStyleMode.SMALL,
                action: (): void => {
                  this.isWallpaperSheetShow = false;
                }
              }
            }
          ]
        }
      }
    })
  }

  @Builder
  ColorThemeSheetContent() {
    HdsNavigation() {
      Scroll() {
        Column() {
          // ⭐ Row 1：色轮（左50%）| 预设色卡（右上）+ 保持色卡（右下）
          Row() {
            // ── 左50%：色轮（完整显示 160×160）──
            Column() {
              Canvas(this.canvasCtx)
                .width(160).height(160)
                .onReady(() => { this.drawColorWheel(); })
                .onTouch((event: TouchEvent) => { this.handleColorWheelTouch(event); })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Center)
            .justifyContent(FlexAlign.Center)

            // ── 右50%：上为预设色卡，下为保持色卡 ──
            Column() {
              // 预设色卡（顶部，4列2行方形）
              Column() {
                Text('预设色卡').fontSize(11).fontColor(this.isDarkMode ? '#AAAAAA' : '#888888')
                  .margin({ bottom: 4 })
                Grid() {
                  ForEach(this.presetColors, (color: string) => {
                    GridItem() {
                      Column() {
                        Column()
                          .width('100%')
                          .height('100%')
                          .backgroundColor(color)
                          .borderRadius(8)
                          .onClick(() => {
                            const hsv2: [number, number, number] = this.hexToHsv(color);
                            this.colorPickerHue = hsv2[0];
                            this.colorPickerSaturation = hsv2[1];
                            this.colorPickerBrightness = hsv2[2];
                            this.updateColorPickerPreview();
                          })
                          .clickEffect({ level: 0, scale: 0.9 })
                      }
                      .padding(4)
                    }
                    // .shadow({ radius: 2, color: '#15000000', offsetY: 1 })
                  })
                }
                .columnsTemplate('1fr 1fr 1fr 1fr')
                .rowsTemplate('1fr 1fr')
                .columnsGap(6)
                .rowsGap(6)
                .height(68)
                .width('100%')
              }

              // 弹性间距
              Blank().layoutWeight(1)

              // 保持色卡（底部，4列2行方形）
              Column() {
                Text('已保存色卡').fontSize(11).fontColor(this.isDarkMode ? '#AAAAAA' : '#888888')
                  .margin({ bottom: 4 })
                Grid() {
                  ForEach(this.getSavedColorsList(), (color: string, index: number) => {
                    GridItem() {
                      Column() {
                        Column()
                          .width('100%')
                          .height('100%')
                          .backgroundColor(color)
                          .borderRadius(8)
                          .onClick(() => {
                            const hsv3: [number, number, number] = this.hexToHsv(color);
                            this.colorPickerHue = hsv3[0];
                            this.colorPickerSaturation = hsv3[1];
                            this.colorPickerBrightness = hsv3[2];
                            this.updateColorPickerPreview();
                          })
                          .gesture(
                            LongPressGesture({ repeat: false, duration: 500 })
                              .onAction(() => {
                                this.removeSavedColor(index);
                              })
                          )
                          .clickEffect({ level: 0, scale: 0.9 })
                      }
                      .padding(4)
                    }
                    // .shadow({ radius: 2, color: '#15000000', offsetY: 1 })
                  })
                }
                .columnsTemplate('1fr 1fr 1fr 1fr')
                .rowsTemplate('1fr 1fr')
                .columnsGap(6)
                .rowsGap(6)
                .height(68)
                .width('100%')
              }
            }
            .layoutWeight(1)
            .height('100%')
            .padding({ left: 8 })
          }
          .width('100%')
          .height(195)
          .margin({ bottom: 14 })

          // ⭐ 单列：HSV 滑块
          Row() {
            Text('色相').fontSize(13).fontColor(this.isDarkMode ? '#FFFFFF' : '#000000').width(36)
            Slider({ value: this.colorPickerHue, min: 0, max: 360, step: 1, style: SliderStyle.InSet })
              .layoutWeight(1)
              .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
              .blockColor(this.customThemeColor)
              .onChange((value: number) => { this.colorPickerHue = value; this.updateColorPickerPreview(); this.drawColorWheel(); })
            Text(`${Math.round(this.colorPickerHue)}°`).fontSize(12).fontColor(this.isDarkMode ? '#FFFFFF' : '#000000').width(30).textAlign(TextAlign.End)
          }
          .width('100%').height(32).alignItems(VerticalAlign.Center)

          Row() {
            Text('饱和').fontSize(13).fontColor(this.isDarkMode ? '#FFFFFF' : '#000000').width(36)
            Slider({ value: this.colorPickerSaturation, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
              .layoutWeight(1)
              .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
              .blockColor(this.customThemeColor)
              .onChange((value: number) => { this.colorPickerSaturation = value; this.updateColorPickerPreview(); this.drawColorWheel(); })
            Text(`${Math.round(this.colorPickerSaturation)}`).fontSize(12).fontColor(this.isDarkMode ? '#FFFFFF' : '#000000').width(30).textAlign(TextAlign.End)
          }
          .width('100%').height(32).alignItems(VerticalAlign.Center)

          Row() {
            Text('亮度').fontSize(13).fontColor(this.isDarkMode ? '#FFFFFF' : '#000000').width(36)
            Slider({ value: this.colorPickerBrightness, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
              .layoutWeight(1)
              .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
              .blockColor(this.customThemeColor)
              .onChange((value: number) => { this.colorPickerBrightness = value; this.updateColorPickerPreview(); this.drawColorWheel(); })
            Text(`${Math.round(this.colorPickerBrightness)}`).fontSize(12).fontColor(this.isDarkMode ? '#FFFFFF' : '#000000').width(30).textAlign(TextAlign.End)
          }
          .width('100%').height(32).alignItems(VerticalAlign.Center)
          .margin({ bottom: 8 })

          // ⭐ 单列：预览色 + 保存当前颜色
          Row() {
            Column() {
              Text('预览色')
                .fontSize(13)
                .fontColor(Color.White)
            }
            .height(32)
            .backgroundColor(this.customThemeColor)
            .borderRadius(8)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .layoutWeight(1)
            .onClick(() => { this.onCustomColorSelected(this.customThemeColor); })
            .clickEffect({ level: 0, scale: 0.94 })
            Blank().width(8)
            Button('保存当前色卡')
              .height(32)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.04)')
              .fontColor(this.customThemeColor)
              .border({ width: 1, color: this.customThemeColor })
              .borderRadius(8)
              .layoutWeight(1)
              .onClick(() => { this.saveCurrentColor(); })
              .clickEffect({ level: 0, scale: 0.94 })
          }
          .width('100%')
          .margin({ bottom: 14 })

          // ⭐ Row 2：从壁纸取色 | 应用
          Row() {
            Button('从壁纸取色')
              .height(40)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .backgroundColor(this.customThemeColor)
              .fontColor(Color.White)
              .borderRadius(10)
              .onClick(() => { this.extractColorFromWallpaper(); })
              .clickEffect({ level: 0, scale: 0.96 })
              .layoutWeight(1)
              .margin({ right: 6 })
            Button('应用').fontSize(14).height(40).fontColor(Color.White).backgroundColor(this.customThemeColor)
              .borderRadius(10).layoutWeight(1).fontWeight(FontWeight.Medium)
              .onClick(() => { this.onCustomColorSelected(this.customThemeColor); })
              .clickEffect({ level: 0, scale: 0.94 })
          }
          .width('100%')
          .margin({ bottom: 14 })

          // ⭐ 底部提示：引导壁纸取色失败时手动选色
          Text('壁纸取色失败，底部栏回退到默认的非悬浮态外观时，请手动选取颜色。')
            .fontSize(13)
            .fontColor(this.isDarkMode ? '#666666' : '#999999')
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ top: 0, bottom: 0 })
        }
        .width('100%')
        .padding({ top: 56 + 12, left: 18, right: 18, bottom: 24 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .titleMode(HdsNavigationTitleMode.MODAL)
    .titleBar({
      padding: { start: LengthMetrics.vp(16), end: LengthMetrics.vp(16) },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        },
        originalStyle: {
          backgroundStyle: { backgroundColor: 'transparent' },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            menuStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') },
            backIconStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: { backgroundColor: 'transparent' },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            menuStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') },
            backIconStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') }
          }
        }
      },
      content: {
        title: {
          mainTitle: '颜色主题'
        },
        menu: {
          value: [
            {
              content: {
                label: 'modal_cancel',
                isEnabled: true,
                type: IconStyleMode.SMALL,
                action: (): void => {
                  this.dismissColorThemeSheet();
                }
              }
            }
          ]
        }
      }
    })
  }

  // ── 其他方法 ──

  private showQualityPicker(): void {
    const primaryColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const cancelColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const backgroundColor = this.isDarkMode ? 'rgba(44, 44, 44, 0.95)' : 'rgba(255, 255, 255, 0.95)';

    const buttons: Array<ActionButton> = [];

    for (const item of QUALITY_LIST) {
      buttons.push({
        value: item.label,
        fontColor: primaryColor,
        action: () => {
          this.saveDefaultQn(item.qn);
        }
      });
    }

    buttons.push({
      value: '取消',
      fontColor: cancelColor,
      action: () => {
        // 取消操作
      }
    });

    AlertDialog.show({
      title: '选择默认播放画质',
      message: '',
      backgroundColor: backgroundColor,
      buttons: buttons
    });
  }

  private async applyOrientationLock(lock: string): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass: window.Window = await window.getLastWindow(context);
      let orientation: window.Orientation;
      switch (lock) {
        case '锁定竖屏':
          orientation = window.Orientation.PORTRAIT;
          break;
        case '锁定横屏':
          // 允许横屏之间旋转（普通横屏和反向横屏）
          orientation = window.Orientation.AUTO_ROTATION_LANDSCAPE;
          break;
        default:
          orientation = window.Orientation.AUTO_ROTATION;
          break;
      }
      await windowClass.setPreferredOrientation(orientation);
    } catch (err) {
      logError(`应用屏幕旋转设置失败: ${err}`);
      this.getUIContext().getPromptAction().showToast({ message: '设置旋转失败' });
    }
  }

  private async getStatusBarHeight(): Promise<void> {
    if (this.hideStatusBar) {
      this.statusBarHeight = 0;
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass: window.Window = await window.getLastWindow(context);
      const avoidArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.statusBarHeight = this.getUIContext().px2vp(avoidArea.topRect.height);
    } catch (error) {
      this.statusBarHeight = 40;
    }
  }

  /**
   * ⭐ 量出"参考视频区宽"：播放页竖屏内联播放区的宽度 = 窗口宽 − 2 × cardMargin
   *    （见 VideoPlayerPage.updatePortraitSize：`containerWidth = this.cw - 2 * this.cardMargin`）。
   *    预览画布按它等比折算，屏幕上小窗占视频区的比例才和真机一致 —— 之前用固定 0.45 折算，
   *    画布宽与视频区宽不成那个比例，所以看起来"预览比实际小"。
   */
  private async measurePreviewRef(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass: window.Window = await window.getLastWindow(context);
      const wvp = this.getUIContext().px2vp(windowClass.getWindowProperties().windowRect.width);
      const rawCm = AppStorage.get<number>('cardMargin');
      const cm = (Number.isFinite(Number(rawCm)) && Number(rawCm) > 0) ? Number(rawCm) : 12;
      // ⚠️ 只在竖屏下有"缩小"这个概念；横屏拿到的是长边，此处不关心（弹窗在竖屏打开）
      this.pvRefW = Math.max(160, wvp - 2 * cm);
    } catch (err) {
      this.pvRefW = 493;   // 兜底：本机竖屏实测的视频区宽
    }
  }

  @Builder
  OrientationMenuBuilder() {
    Menu() {
      ForEach(['自动旋转', '锁定竖屏', '锁定横屏'], (option: string) => {
        MenuItem({
          content: option,
          labelInfo: this.screenOrientationLock === option ? '当前' : ''
        })
          .selectIcon(this.screenOrientationLock === option)
          .selected(this.screenOrientationLock === option)
          .onClick(() => {
            this.isOrientationMenuShow = false;
            this.saveOrientationLock(option);
          })
      }, (option: string) => option)
    }
  }

  private getCardItemBg(): ResourceColor {
    if (this.cardTransparentStyle) {
      return this.isDarkMode
        ? `rgba(28,28,30,${this.cardBgOpacity / 100})`
        : `rgba(255,255,255,${this.cardBgOpacity / 100})`;
    }
    return $r('app.color.card_background');
  }

  // ── Hivid 风格设置项构建器 ──

  @Builder
  SettingItemWithToggle(title: string, isOn: boolean, onChange: (isOn: boolean) => void) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(this.customThemeColor)
        .switchPointColor(Color.White)
        .onChange((value: boolean) => {
          if (value !== isOn) {
            onChange(value);
          }
        })
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      onChange(!isOn);
    })
  }

  @Builder
  SettingItemWithPicker(title: string, value: string, onClick: () => void) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(value)
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ right: 8 })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => { onClick(); })
  }

  // ── 分组标题构建器 ──
  @Builder
  SectionHeader(title: string) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_secondary'))
      .width('94%')
      .margin({ top: 18, bottom: 8, left: 12 })
  }

  build() {
    Scroll() {
      Column() {
        if (this.showContent) {
          Column() {
            // ── 视觉与外观 ──
            this.SectionHeader('视觉与外观')
            Column() {
              this.SettingItemWithPicker('壁纸', this.getWallpaperLabel(), () => {
                this.showWallpaperPicker();
              })
              Divider()
              this.SettingItemWithPicker('颜色主题', this.customThemeColor, () => {
                this.showColorTheme = true;
              })
              Divider()
              this.SettingItemWithToggle('状态栏隐藏', this.hideStatusBar, (isOn: boolean) => {
                this.saveHideStatusBar(isOn);
              })
              Divider()
              this.SettingItemWithToggle('标题胶囊彩色图标', this.capsuleColorIcons, (isOn: boolean) => {
                this.saveCapsuleColorIcons(isOn);
              })
              Divider()
              this.SettingItemWithToggle('悬浮按钮跟随颜色主题', this.floatBtnFollowTheme, (isOn: boolean) => {
                this.saveFloatBtnFollowTheme(isOn);
              })
            }
            .width('94%')
            .borderRadius(15)
            .backgroundColor(this.getCardItemBg())
            // .shadow({
            //   radius: 50,
            //   color: '#80000000',
            //   offsetX: 0,
            //   offsetY: 15
            // })

            // ── 交互与动效 ──
            this.SectionHeader('交互与动效')
            Column() {
              this.SettingItemWithToggle('关闭所有动画', this.disableAnimations, (isOn: boolean) => {
                this.saveDisableAnimations(isOn);
              })
              Divider()
              Column() {
                this.SettingItemWithPicker('视频页动画', `${labelByShrinkStyle(this.shrinkWindowStyle)} · ${labelByMode(this.pageEnterAnim)}`, () => {
                  this.showAnimModePicker();
                })
              }
              .width('100%')
              .bindSheet($$this.isAnimModeSheetShow, this.AnimModeSheetContent, {
                height: '75%',
                dragBar: false,
                showClose: false,
                backgroundColor: undefined,
                preferType: SheetType.CENTER,
                onDisappear: () => {
                  this.isAnimModeSheetShow = false;
                  this.stopPreviewLoop();
                }
              })
              Divider()
              this.SettingItemWithToggle('震动反馈', this.vibrateEnabled, (isOn: boolean) => {
                this.saveVibrateEnabled(isOn);
              })
              Divider()
              this.SettingItemWithToggle('智感握姿', this.smartGripEnabled, (isOn: boolean) => {
                this.saveSmartGripEnabled(isOn);
              })
              Divider()
              this.SettingItemWithToggle('开灯按钮显示', this.lightsOffShowBtn, (isOn: boolean) => {
                this.saveLightsOffShowBtn(isOn);
              })
              Divider()
              this.SettingItemWithToggle('关灯视频外弹幕', this.lightsOffDanmakuOutside, (isOn: boolean) => {
                this.saveLightsOffDanmakuOutside(isOn);
              })
              Divider()
              this.SettingItemWithToggle('关灯切换为隐藏组件', this.lightsOffHideOnly, (isOn: boolean) => {
                this.saveLightsOffHideOnly(isOn);
              })
              Divider()
              Row() {
                Text('浮窗旋转速度')
                  .fontSize(16)
                  .fontColor($r('sys.color.font_primary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(labelByFloatBtnSpeed(this.floatBtnRotationSpeed))
                  .fontSize(14)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ right: 8 })
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(14)
                  .fontColor([$r('sys.color.icon_secondary')])
                  .bindMenu(this.isFloatBtnSpeedMenuShow, this.FloatBtnSpeedMenuBuilder(), {
                    onDisappear: () => { this.isFloatBtnSpeedMenuShow = false; }
                  })
              }
              .width('100%')
              .height(56)
              .padding({ left: 16, right: 16 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => { this.isFloatBtnSpeedMenuShow = true; })
            }
            .width('94%')
            .borderRadius(15)
            .backgroundColor(this.getCardItemBg())
            // .shadow({
            //   radius: 50,
            //   color: '#80000000',
            //   offsetX: 0,
            //   offsetY: 15
            // })

            // ── 其他 ──
            this.SectionHeader('其他')
            Column() {
              Row() {
                Text('旋转')
                  .fontSize(16)
                  .fontColor($r('sys.color.font_primary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(this.screenOrientationLock)
                  .fontSize(14)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ right: 8 })
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(14)
                  .fontColor([$r('sys.color.icon_secondary')])
                  .bindMenu(this.isOrientationMenuShow, this.OrientationMenuBuilder(), {
                    onDisappear: () => { this.isOrientationMenuShow = false; }
                  })
              }
              .width('100%')
              .height(56)
              .padding({ left: 16, right: 16 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => { this.isOrientationMenuShow = true; })
            }
            .width('94%')
            .borderRadius(15)
            .backgroundColor(this.getCardItemBg())
            // .shadow({
            //   radius: 50,
            //   color: '#80000000',
            //   offsetX: 0,
            //   offsetY: 15
            // })
          }
          .width('100%')
          .margin({ bottom: 12 })
          .bindSheet($$this.showColorTheme, this.ColorThemeSheetContent, {
            height: '78%',
            dragBar: false,
            showClose: false,
            backgroundColor: undefined,
            preferType: SheetType.CENTER,
            onWillDismiss: (dismissSheetAction: DismissSheetAction) => {
              if (this.customThemeColor !== this.committedThemeColor) {
                AlertDialog.show({
                  title: '退出颜色主题',
                  message: '有未应用的颜色更改，退出后将丢失。是否退出？',
                  autoCancel: false,
                  primaryButton: {
                    value: '取消',
                    fontColor: this.isDarkMode ? '#FFFFFF' : '#000000',
                    action: () => {}
                  },
                  secondaryButton: {
                    value: '退出',
                    fontColor: '#E84040',
                    action: () => {
                      this.customThemeColor = this.committedThemeColor;
                      this.showColorTheme = false;
                    }
                  }
                });
              } else {
                this.showColorTheme = false;
              }
            }
          })
        }
      }
      .width('100%')
      .opacity(this.showContent ? 1 : 0)
      .translate({ y: this.showContent ? 0 : 20 })
      .animation({ duration: 300, curve: Curve.EaseOut, delay: 50 })
      
    }
    .width('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .padding({ top: 56, bottom: 24 })
    .bindSheet($$this.isWallpaperSheetShow, this.WallpaperSheetContent, {
      height: '65%',
      dragBar: false,
      showClose: false,
      backgroundColor: undefined,
      preferType: SheetType.CENTER,
      onDisappear: () => { this.isWallpaperSheetShow = false; }
    })
  }

  private getWallpaperLabel(): string {
    if (this.wallpaper === 'builtin') return '内置壁纸';
    if (this.wallpaper === 'custom' && this.customWallpaper) return '图片';
    if (this.wallpaper === 'custom_color') return '颜色';
    return '默认';
  }
}
