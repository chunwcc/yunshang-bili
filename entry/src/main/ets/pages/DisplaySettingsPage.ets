// DisplaySettingsPage.ets - 显示设置页（页面中嵌入 PersonalizationPage 设置项）
import { common } from '@kit.AbilityKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { window, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';

interface QualityItem {
  qn: number;
  label: string;
}

interface AnimMode {
  value: string;
  label: string;
}

const QUALITY_LIST: QualityItem[] = [
  { qn: 16, label: '360P' } as QualityItem,
  { qn: 32, label: '480P' } as QualityItem,
  { qn: 64, label: '720P' } as QualityItem,
  { qn: 80, label: '1080P' } as QualityItem,
  { qn: 112, label: '1080P+' } as QualityItem,
  { qn: 116, label: '1080P60' } as QualityItem,
  { qn: 120, label: '4K' } as QualityItem
];

const DEFAULT_QN: number = 116;

function labelByQn(qn: number): string {
  const item = QUALITY_LIST.find(q => q.qn === qn);
  return item ? item.label : '1080P60';
}

const ANIM_MODES: AnimMode[] = [
  { value: 'none', label: '无' } as AnimMode,
  { value: 'slideUpDown', label: '上下滑入/滑出' } as AnimMode,
  { value: 'scaleFade', label: '缩放淡出/淡入' } as AnimMode,
  { value: 'slideLeftRight', label: '左滑出/右滑入' } as AnimMode,
  { value: 'blurFade', label: '模糊' } as AnimMode,
  { value: 'flip', label: '翻转' } as AnimMode,
  { value: 'minimizeCorner', label: '缩角' } as AnimMode,
  { value: 'diagonal', label: '对角线' } as AnimMode,
];

function labelByMode(value: string): string {
  const item = ANIM_MODES.find(m => m.value === value);
  return item ? item.label : '上下滑入/滑出';
}

@Entry
@Component
struct DisplaySettingsPage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @StorageLink('screenOrientationLock') screenOrientationLock: string = '自动旋转';
  @StorageLink('defaultVideoQn') defaultVideoQn: number = DEFAULT_QN;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('recommendApiSource') recommendApiSource: string = 'App';
  @StorageLink('pageEnterAnim') pageEnterAnim: string = 'scaleFade';
  @StorageLink('wallpaper') wallpaper: string = 'builtin';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;
  @StorageLink('liveMaxVisibleTabs') liveMaxVisibleTabs: number = 4;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @State qualityLabel: string = labelByQn(DEFAULT_QN);
  @State statusBarHeightLocal: number = 0;

  async aboutToAppear(): Promise<void> {
    await this.loadSettings();
    await this.getStatusBarHeight();
  }

  private async loadSettings(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const dataPreferences: preferences.Preferences = await preferences.getPreferences(context, 'my_app_settings');
      const storedQn = await dataPreferences.get('defaultVideoQn', DEFAULT_QN) as number;
      this.qualityLabel = labelByQn(storedQn);
    } catch (err) {
      logError(`加载设置失败: ${err}`);
    }
  }

  private async getStatusBarHeight(): Promise<void> {
    if (this.hideStatusBar) {
      this.statusBarHeightLocal = 0;
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass: window.Window = await window.getLastWindow(context);
      const avoidArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.statusBarHeightLocal = this.getUIContext().px2vp(avoidArea.topRect.height);
    } catch (error) {
      this.statusBarHeightLocal = 40;
    }
  }

  build() {
    Column() {
      // 顶部导航栏
      Row() {
        Image($r('app.media.ic_public_arrow_left_filled'))
          .width(24)
          .height(24)
          .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .onClick(() => {
            router.back();
          })
        Text('显示设置')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .margin({ left: 12 })
        Blank()
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })
      .margin({ bottom: 16 })

      Scroll() {
        Column() {
          // 此处可嵌入 PersonalizationPage 的通用设置项
          Text('设置项')
            .fontSize(14)
            .fontColor(this.isDarkMode ? '#AAAAAA' : '#666666')
            .width('100%')
            .margin({ bottom: 12 })
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? '#000000' : '#F5F5F5')
    .padding({ top: this.statusBarHeightLocal })
  }
}
