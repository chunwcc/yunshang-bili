// CardStyleSheet.ets - 卡片样式设置弹窗
// 顶部分类：通用 / 首页 / 播放页 / 更多（各分类下的控件与原版保持一致）

import { preferences } from '@kit.ArkData';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { applyWallpaperMode, persistWallpaperMode } from '../utils/WallpaperTheme';
import { StatusBarUtils } from '../utils/StatusBarUtils';
import { formatPlayCountText, getPlayCountDisplayColor } from '../utils/PlayCountStyle';
import { CARD_STYLE_MODE_KEYS, persistCardStyleModeArchive, applyCardStyleModeArchive } from '../utils/CardStyleMode';
import { StylePresetData, ModePresetValues, getBuiltinPresets, buildModePairSnapshot, loadCustomPresets, saveCustomPreset, deleteCustomPreset, loadBuiltinEdits, saveBuiltinEdit, restoreBuiltinDefault, applyPresetModeArchive } from '../utils/CardStylePreset';

@Component
export struct CardStyleSheet {
  onClose?: () => void;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('isLandscape') isLandscape: boolean = false;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = true;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = true;
  @StorageLink('cardBorderFollowPlayCount') cardBorderFollowPlayCount: boolean = false;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 25;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 70;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('wallpaper') wallpaper: string = 'builtin';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;
  @StorageLink('wallpaperColor') wallpaperColor: string = '#007DFF';
  @StorageLink('cardTransparentStyleVideo') cardTransparentStyleVideo: boolean = true;
  @StorageLink('cardStyleVideoDetail') cardStyleVideoDetail: boolean = true;
  @StorageLink('cardStyleVideoCommentSection') cardStyleVideoCommentSection: boolean = true;
  @StorageLink('cardStyleVideoCommentBubble') cardStyleVideoCommentBubble: boolean = true;
  /** 评论区文字布局：left=文本左对齐 center=文本居中 */
  @StorageLink('cardStyleVideoCommentAlign') cardStyleVideoCommentAlign: string = 'center';
  @StorageLink('cardStyleVideoDescription') cardStyleVideoDescription: boolean = true;
  @StorageLink('cardStyleVideoSegmentBtn') cardStyleVideoSegmentBtn: boolean = true;
  @StorageLink('cardStyleVideoInteractBtns') cardStyleVideoInteractBtns: boolean = true;
  @StorageLink('cardStyleVideoNavBtns') cardStyleVideoNavBtns: boolean = true;
  @StorageLink('cardStyleSearchSuggest') cardStyleSearchSuggest: boolean = true;
  @StorageLink('cardStyleLiveCategory') cardStyleLiveCategory: boolean = true;
  @StorageLink('cardStyleLiveQuality') cardStyleLiveQuality: boolean = true;
  @StorageLink('videoBgMode') videoBgMode: string = 'cover';
  @StorageLink('videoBgColor') videoBgColor: string = '#007DFF';
  @StorageLink('videoBgCustomWallpaper') videoBgCustomWallpaper: string = '';
  @StorageLink('videoBgCustomWallpaperBlur') videoBgCustomWallpaperBlur: number = 0;
  @StorageLink('videoBgCustomWallpaperDarkness') videoBgCustomWallpaperDarkness: number = 50;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1;
  @StorageLink('cardCapsuleFollowTheme') cardCapsuleFollowTheme: boolean = false;
  @StorageLink('playerFollowTheme') playerFollowTheme: boolean = true;
  @StorageLink('cardBgBlurAmount') cardBgBlurAmount: number = 24;
  @StorageLink('cardBgDarkness') cardBgDarkness: number = 50;
  @StorageLink('cardCustomColor') cardCustomColor: string = '';
  @StorageLink('cardMargin') cardMargin: number = 12;
  @StorageLink('cardBorderRadius') cardBorderRadius: number = 30;
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  @StorageLink('cardListMargin') cardListMargin: number = 12;
  @StorageLink('cardCapsuleShow') cardCapsuleShow: boolean = true;
  @StorageLink('cardCapsuleSize') cardCapsuleSize: number = 12;
  @StorageLink('cardCapsuleRadius') cardCapsuleRadius: number = 7;
  @StorageLink('cardCapsuleColor') cardCapsuleColor: string = '';
  @StorageLink('cardPlayCountShow') cardPlayCountShow: boolean = true;
  @StorageLink('cardPlayCountUnit') cardPlayCountUnit: string = 'wanYi';
  @StorageLink('cardPlayCountSize') cardPlayCountSize: number = 12;
  @StorageLink('cardPlayCountColorMode') cardPlayCountColorMode: string = 'level';
  @StorageLink('cardPlayCountColor') cardPlayCountColor: string = '';
  @StorageLink('cardPlayCountIcon') cardPlayCountIcon: boolean = true;
  @State previewImageFailed: boolean = false;
  @State showCardColorPicker: boolean = false;
  @State showVideoBgColorPicker: boolean = false;
  /** 播放页细节开关组展开状态（默认收起） */
  @State playerDetailExpanded: boolean = false;
  /** 胶囊自定义取色器 */
  @State showCapsuleColorPicker: boolean = false;
  @State capsuleHue: number = 210;
  @State capsuleSaturation: number = 85;
  @State capsuleBrightness: number = 95;
  /** UP主胶囊自定义组展开状态（默认收起） */
  @State capsuleGroupExpanded: boolean = false;
  /** 播放量自定义组展开状态（默认收起） */
  @State playCountGroupExpanded: boolean = false;
  /** 取色器目标：capsule=胶囊颜色 / playCount=播放量颜色 */
  @State colorPickerTarget: string = 'capsule';
  /** 卡片样式「深浅色独立」开关（每模式一份档案） */
  @StorageLink('cardStylePerMode') cardStylePerMode: boolean = true;
  /** 预设：用户自定义列表 + 保存命名弹窗 */
  @State customPresets: StylePresetData[] = [];
  @State showPresetNameSheet: boolean = false;
  @State presetNameInput: string = '';
  /** 内置预设修改覆盖（同名记录替换默认值） */
  @State builtinEdits: StylePresetData[] = [];
  @State showBuiltinEditSheet: boolean = false;
  @State editingBuiltinName: string = '';
  /** 当前分类：0 通用 / 1 首页 / 2 播放页 / 3 更多 */
  @State activeCategory: number = 0;

  private readonly presetColors: string[] = [
    '#007DFF', '#00C853', '#FF6D00', '#E91E63',
    '#9C27B0', '#FFD600', '#00BCD4', '#795548',
  ];

  /** 胶囊预设色（较少数量，避免窄屏挤出去） */
  private readonly capsuleColors: string[] = [
    '#007DFF', '#00C853', '#FF6D00', '#E91E63', '#9C27B0', '#FFD600',
  ];

  private readonly videoBgPresetColors: string[] = [
    '#FFFFFF', '#000000',
    '#007DFF', '#00C853', '#FF6D00', '#E91E63',
    '#9C27B0', '#FFD600', '#00BCD4', '#795548',
  ];

  // ── HSV 转换（与个性化页颜色主题取色器同一套算法） ──

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

  private getPreviewSolidBg(): string {
    if (this.wallpaper === 'custom_color') return this.wallpaperColor;
    return this.isDarkMode ? '#121212' : '#FFFFFF';
  }

  private getPreviewImmersiveLight(): string {
    const hex = this.customThemeColor.replace('#', '');
    return `#33${hex}`;
  }

  // 预览用模拟播放量（50万 → 金色 #FFB800）
  private readonly MOCK_PLAY_COUNT: number = 500000;

  private getPreviewPlayCountColor(): string {
    const count = this.MOCK_PLAY_COUNT;
    if (count >= 10000000) return '#FF0000';
    if (count >= 3000000) return '#C2185B';
    if (count >= 1000000) return '#E65100';
    if (count >= 500000) return '#FF8C00';
    if (count >= 100000) return '#FFB800';
    if (count >= 50000) return '#4A90D9';
    return '#999999';
  }

  private opacityToHexAlpha(opacity: number): string {
    const val = Math.round(opacity / 100 * 255);
    const hex = val.toString(16);
    return hex.length === 1 ? '0' + hex : hex;
  }

  private formatCount(count: number): string {
    if (count >= 100000000) return (count / 100000000).toFixed(1) + '亿';
    if (count >= 10000) return (count / 10000).toFixed(1) + '万';
    return count.toString();
  }

  private async savePrefs(key: string, value: Object): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put(key, value);
      await pref.flush();
    } catch (e) {
      logError(`保存 ${key} 失败`, e);
    }
    if (this.cardStylePerMode && CARD_STYLE_MODE_KEYS.includes(key)) {
      this.persistModeArchive();
    }
  }

  /** 当前模式档案落盘（深浅色独立开关开启时使用） */
  private async persistModeArchive(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await persistCardStyleModeArchive(pref, this.isDarkMode);
    } catch (e) {
      logError(`归档卡片样式失败: ${e}`);
    }
  }

  /** 同档/独立切换确认弹窗 */
  private confirmTogglePerMode(): void {
    const toIndependent = !this.cardStylePerMode;
    AlertDialog.show({
      title: toIndependent ? '切换为深浅色独立' : '切换为深浅色共用',
      message: toIndependent
        ? '开启后，深色和浅色将各保存一份卡片样式，切换深浅色时互不影响。是否开启？'
        : '关闭后，深浅色共用同一套卡片样式（另一模式的档案仍会保留，可随时切回）。是否关闭？',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: this.isDarkMode ? '#FFFFFF' : '#000000',
        action: () => {}
      },
      secondaryButton: {
        value: toIndependent ? '开启' : '关闭',
        fontColor: '#E84040',
        action: () => {
          this.cardStylePerMode = toIndependent;
          AppStorage.set('cardStylePerMode', toIndependent);
          this.savePrefs('cardStylePerMode', toIndependent);
          if (toIndependent) {
            this.persistModeArchive();
          }
          this.getUIContext().getPromptAction().showToast({
            message: toIndependent ? '已开启：深浅色各存一份样式' : '已切换：深浅色共用一套样式'
          });
        }
      }
    });
  }

  async aboutToAppear(): Promise<void> {
    try {
      if (this.cardStylePerMode) {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const pref = await preferences.getPreferences(context, 'my_app_settings');
        // 每次打开弹层都装载当前模式的档案（启动/切档后保持一致）
        await applyCardStyleModeArchive(pref, this.isDarkMode);
      }
      // 加载用户自定义预设
      const context0 = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref0 = await preferences.getPreferences(context0, 'my_app_settings');
      this.customPresets = await loadCustomPresets(pref0);
      this.builtinEdits = await loadBuiltinEdits(pref0);
    } catch (e) {
      logError(`装载模式档案失败: ${e}`);
    }
  }

  /** 标题栏深色/浅色分段切换：与「我的」页面 onDarkModeChange 完全一致（壁纸归档/装载 + 系统色彩模式 + 状态栏浅深色） */
  private async switchDarkMode(isDark: boolean): Promise<void> {
    if (this.isDarkMode === isDark) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      // 切换前：把当前激活壁纸归档到旧模式存档
      await persistWallpaperMode(this.isDarkMode, pref);
      this.isDarkMode = isDark;
      AppStorage.set('isDarkMode', isDark);
      this.savePrefs('isDarkMode', isDark);
      // 深浅色独立：切模式后装载另一模式档案
      if (this.cardStylePerMode) {
        await applyCardStyleModeArchive(pref, isDark);
      }
      // 切换后：装载新模式对应的壁纸到激活键（预览与消费页自动生效）
      applyWallpaperMode(isDark);
      this.savePrefs('wallpaper', AppStorage.get<string>('wallpaper') ?? 'builtin');
      this.savePrefs('customWallpaper', AppStorage.get<string>('customWallpaper') ?? '');
      this.savePrefs('wallpaperColor', AppStorage.get<string>('wallpaperColor') ?? '#007DFF');
      this.savePrefs('wallpaperBlur', AppStorage.get<number>('wallpaperBlur') ?? 0);
      this.savePrefs('wallpaperDarkness', AppStorage.get<number>('wallpaperDarkness') ?? 50);
      // 同步系统级色彩模式，让 HDS 组件（返回图标、菜单图标等）自动适配
      context.getApplicationContext().setColorMode(
        isDark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
      );
      await StatusBarUtils.updateStatusBarColor(context, isDark);
      this.getUIContext().getPromptAction().showToast({ message: isDark ? '已切换深色模式' : '已切换浅色模式' });
    } catch (e) {
      logError(`切换深色模式失败: ${e}`);
    }
  }

  private async pickWallpaper(): Promise<void> {
    try {
      this.getUIContext().getPromptAction().showToast({ message: '正在打开相册...' });
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = 1;
      const photoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const photoSelectResult = await photoViewPicker.select(photoSelectOptions);
      if (photoSelectResult.photoUris.length === 0) return;
      const sourceUri = photoSelectResult.photoUris[0];
      const destUri = `${context.filesDir}/videobg_${Date.now()}.jpg`;
      const srcFile = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      const destFile = fileIo.openSync(destUri, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      const buffer = new ArrayBuffer(4096);
      let readLen = 0;
      while ((readLen = fileIo.readSync(srcFile.fd, buffer)) > 0) {
        fileIo.writeSync(destFile.fd, buffer.slice(0, readLen));
      }
      fileIo.closeSync(srcFile.fd);
      fileIo.closeSync(destFile.fd);
      this.videoBgCustomWallpaper = destUri;
      AppStorage.set('videoBgCustomWallpaper', destUri);
      await this.savePrefs('videoBgCustomWallpaper', destUri);
      this.getUIContext().getPromptAction().showToast({ message: '视频背景壁纸已更换' });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: `失败: ${(error as BusinessError).message}` });
    }
  }

  private async resetWallpaper(): Promise<void> {
    this.videoBgCustomWallpaper = '';
    AppStorage.set('videoBgCustomWallpaper', '');
    await this.savePrefs('videoBgCustomWallpaper', '');
    this.getUIContext().getPromptAction().showToast({ message: '已恢复默认' });
  }

  private getPreviewBorderColor(): string {
    if (!this.cardTransparentStyle) return 'rgba(0,0,0,0)';
    if (this.cardBorderFollowPlayCount) {
      return '#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.getPreviewPlayCountColor().slice(1);
    }
    if (this.cardBorderFollowTheme) {
      return '#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1);
    }
    return this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)';
  }

  private getPreviewBgColor(): string {
    if (this.cardCustomColor && this.cardCustomColor !== '#007DFF') {
      if (this.cardTransparentStyle) {
        return '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1);
      }
      return this.cardCustomColor;
    }
    if (!this.cardTransparentStyle) {
      return this.isDarkMode ? '#2C2C2C' : '#FFFFFF';
    }
    return this.isDarkMode
      ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
      : `rgba(255,255,255,${this.cardBgOpacity / 100})`;
  }

  // ════════════════════════ 分类条 ════════════════════════

  @Builder
  CategoryBar() {
    Row() {
      ForEach(['预设', '通用', '首页', '播放页'], (label: string, index: number) => {
        Text(label)
          .fontSize(14)
          .fontColor(this.activeCategory === index
            ? Color.White
            : (this.isDarkMode ? '#AAAAAA' : '#666666'))
          .fontWeight(this.activeCategory === index ? FontWeight.Medium : FontWeight.Normal)
          .layoutWeight(1)
          .height(36)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.activeCategory === index
            ? this.customThemeColor
            : Color.Transparent)
          .borderRadius(18)
          .onClick(() => { this.activeCategory = index; })
          .clickEffect({ level: 0, scale: 0.96 })
      })
    }
    .width('100%')
    .padding(3)
    .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)')
    .borderRadius(21)
    .margin({ top: 8, bottom: 12 })
  }

  // ════════════════════════ 通用 ════════════════════════

  @Builder
  CommonSection() {
    // 第1行：卡片透明风格
    Row() {
      Column() {
        this.ToggleItem(
          '卡片透明风格',
          this.cardTransparentStyle,
          (value: boolean) => {
            AppStorage.set('cardTransparentStyle', value);
            this.savePrefs('cardTransparentStyle', value);
          }
        )
      }
      .layoutWeight(1)
    }
    .width('100%')

    // 实时预览（与首页同款：胶囊标题 + 双列卡片网格）
    this.HomePreview()

    // 边框跟随（双列）
    Row() {
      Column() {
        this.ToggleItem(
          '边框跟随主题色',
          this.cardBorderFollowTheme,
          (value: boolean) => {
            AppStorage.set('cardBorderFollowTheme', value);
            this.savePrefs('cardBorderFollowTheme', value);
          }
        )
      }
      .layoutWeight(1)
      .margin({ right: 6 })

      Column() {
        this.ToggleItem(
          '边框跟随播放量色彩',
          this.cardBorderFollowPlayCount,
          (value: boolean) => {
            AppStorage.set('cardBorderFollowPlayCount', value);
            this.savePrefs('cardBorderFollowPlayCount', value);
          }
        )
      }
      .layoutWeight(1)
      .margin({ left: 6 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)

    // 边框透明度 / 卡片背景透明度（双列）
    Row() {
      Column() {
        Column() {
          Row() {
            Text('边框透明度')
              .fontSize(16)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .fontWeight(FontWeight.Medium)
            Blank()
            Text(`${this.cardBorderOpacity}%`)
              .fontSize(14)
              .fontColor(this.customThemeColor)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ bottom: 8 })

          Slider({
            value: this.cardBorderOpacity,
            min: 0, max: 100, step: 5, style: SliderStyle.InSet
          })
            .width('100%')
            .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
            .selectedColor(this.customThemeColor)
            .blockColor(this.customThemeColor)
            .onChange((value: number) => {
              AppStorage.set('cardBorderOpacity', value);
              this.savePrefs('cardBorderOpacity', value);
            })
        }
        .width('100%')
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(20)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      }
      .layoutWeight(1)
      .margin({ right: 6 })

      Column() {
        Column() {
          Row() {
            Text('背景透明度')
              .fontSize(16)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .fontWeight(FontWeight.Medium)
            Blank()
            Text(`${this.cardBgOpacity}%`)
              .fontSize(14)
              .fontColor(this.customThemeColor)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ bottom: 8 })

          Slider({
            value: this.cardBgOpacity,
            min: 0, max: 80, step: 5, style: SliderStyle.InSet
          })
            .width('100%')
            .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
            .selectedColor(this.customThemeColor)
            .blockColor(this.customThemeColor)
            .onChange((value: number) => {
              AppStorage.set('cardBgOpacity', value);
              this.savePrefs('cardBgOpacity', value);
            })
        }
        .width('100%')
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(20)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 6 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 12 })

    // 边框粗细（双列） / 卡片色彩
    Row() {
      Column() {
        Column() {
          Row() {
            Text('边框粗细')
              .fontSize(16)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .fontWeight(FontWeight.Medium)
            Blank()
            Text(`${this.cardBorderWidth.toFixed(1)}px`)
              .fontSize(14)
              .fontColor(this.customThemeColor)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ bottom: 8 })

          Slider({
            value: this.cardBorderWidth,
            min: 0, max: 6, step: 0.5, style: SliderStyle.InSet
          })
            .width('100%')
            .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
            .selectedColor(this.customThemeColor)
            .blockColor(this.customThemeColor)
            .onChange((value: number) => {
              AppStorage.set('cardBorderWidth', value);
              this.savePrefs('cardBorderWidth', value);
            })
        }
        .width('100%')
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(20)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      }
      .layoutWeight(1)
      .margin({ right: 6 })

      Column() {
        Column() {
          Row() {
            Text('卡片色彩')
              .fontSize(16)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .fontWeight(FontWeight.Medium)
            Blank()
            Column()
              .width(24).height(24)
              .borderRadius(6)
              .backgroundColor(this.cardCustomColor)
              .border({ width: 1, color: this.isDarkMode ? 'rgba(255,255,255,0.2)' : 'rgba(0,0,0,0.1)' })
              .margin({ right: 8 })
            Text(this.cardCustomColor || '默认')
              .fontSize(13)
              .fontColor(this.customThemeColor)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .height(44)
          .onClick(() => { this.showCardColorPicker = true; })
          .clickEffect({ level: 0, scale: 0.95 })
        }
        .width('100%')
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(20)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 6 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 12 })
  }

  // ════════════════════════ 首页 ════════════════════════

  @Builder
  HomeSection() {
    // ── 首页预览（仿首页：胶囊标题 + 双列卡片网格，位于选项上方） ──
    Column() {
      Row() {
        Text('首页预览')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .fontWeight(FontWeight.Medium)
        Blank()
      }
      .width('100%')
      .margin({ top: 4, bottom: 8 })

      this.HomePreview()
    }
    .width('100%')
    .margin({ bottom: 12 })

    // ── UP主胶囊自定义 ──
    Column() {
      Row() {
        Text('UP主胶囊自定义')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .fontWeight(FontWeight.Medium)
        Blank()
        // 展开/收起：图标（chevron_right 旋转）包在胶囊底里
        Column() {
          Image($r('app.media.chevron_right'))
            .width(16).height(16)
            .fillColor(this.capsuleGroupExpanded ? Color.White : this.customThemeColor)
            .rotate({ angle: this.capsuleGroupExpanded ? -90 : 90 })
        }
        .width(28).height(28)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(14)
        .backgroundColor(this.capsuleGroupExpanded
          ? this.customThemeColor
          : (this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.06)'))
      }
      .width('100%')
      .height(44)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
      .borderRadius(20)
      .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      .margin({ top: 4, bottom: 10 })
      .onClick(() => { this.capsuleGroupExpanded = !this.capsuleGroupExpanded; })
      .clickEffect({ level: 0, scale: 0.98 })

      if (this.capsuleGroupExpanded) {
        if (this.cardCapsuleShow) {
          // 双列：显示胶囊 | 胶囊跟随主题色
          Row() {
            Column() {
              this.ToggleItem(
                '显示胶囊',
                this.cardCapsuleShow,
                (value: boolean) => {
                  AppStorage.set('cardCapsuleShow', value);
                  this.savePrefs('cardCapsuleShow', value);
                },
                '关闭后卡片上不显示UP主胶囊'
              )
            }
            .layoutWeight(1)
            .margin({ right: 6 })

            Column() {
              // 胶囊跟随主题色（切换时自动清除自定义颜色，保证开关生效）
              this.ToggleItem(
                '胶囊跟随主题色',
                this.cardCapsuleFollowTheme,
                (value: boolean) => {
                  AppStorage.set('cardCapsuleColor', '');
                  this.savePrefs('cardCapsuleColor', '');
                  AppStorage.set('cardCapsuleFollowTheme', value);
                  this.savePrefs('cardCapsuleFollowTheme', value);
                },
                '开=主题色，关=金色（自动取消自定义色）'
              )
            }
            .layoutWeight(1)
            .margin({ left: 6 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else {
          // 关闭胶囊时只显示开关
          this.ToggleItem(
            '显示胶囊',
            this.cardCapsuleShow,
            (value: boolean) => {
              AppStorage.set('cardCapsuleShow', value);
              this.savePrefs('cardCapsuleShow', value);
            },
            '开启后显示UP主胶囊'
          )
        }

        if (this.cardCapsuleShow) {
        // 胶囊大小 / 胶囊圆角（双列）
        Row() {
          Column() {
            Column() {
              Row() {
                Text('胶囊大小')
                  .fontSize(15)
                  .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                  .fontWeight(FontWeight.Medium)
                Blank()
                Text(`${Math.round(this.cardCapsuleSize)}`)
                  .fontSize(13)
                  .fontColor(this.customThemeColor)
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .margin({ bottom: 8 })
              Slider({
                value: this.cardCapsuleSize,
                min: 8, max: 18, step: 1, style: SliderStyle.InSet
              })
                .width('100%')
                .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
                .selectedColor(this.customThemeColor)
                .blockColor(this.customThemeColor)
                .onChange((value: number) => {
                  AppStorage.set('cardCapsuleSize', value);
                  this.savePrefs('cardCapsuleSize', value);
                })
            }
            .width('100%')
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
            .borderRadius(20)
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
          }
          .layoutWeight(1)
          .margin({ right: 6 })

          Column() {
            Column() {
              Row() {
                Text('胶囊圆角')
                  .fontSize(15)
                  .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                  .fontWeight(FontWeight.Medium)
                Blank()
                Text(`${Math.round(this.cardCapsuleRadius)}`)
                  .fontSize(13)
                  .fontColor(this.customThemeColor)
                  .fontWeight(FontWeight.Medium)
              }
              .width('100%')
              .margin({ bottom: 8 })
              Slider({
                value: this.cardCapsuleRadius,
                min: 0, max: 20, step: 1, style: SliderStyle.InSet
              })
                .width('100%')
                .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
                .selectedColor(this.customThemeColor)
                .blockColor(this.customThemeColor)
                .onChange((value: number) => {
                  AppStorage.set('cardCapsuleRadius', value);
                  this.savePrefs('cardCapsuleRadius', value);
                })
            }
            .width('100%')
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
            .borderRadius(20)
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
          }
          .layoutWeight(1)
          .margin({ left: 6 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .margin({ bottom: 10 })

        // 胶囊颜色自定义
        Row() {
          Text('胶囊颜色')
            .fontSize(15)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            .fontWeight(FontWeight.Medium)
          Blank()
          if (this.cardCapsuleColor) {
            Column()
              .width(24).height(24)
              .borderRadius(6)
              .backgroundColor(this.cardCapsuleColor)
              .border({ width: 1, color: this.isDarkMode ? 'rgba(255,255,255,0.2)' : 'rgba(0,0,0,0.1)' })
              .margin({ right: 8 })
          }
          Text(this.cardCapsuleColor ? this.cardCapsuleColor : '默认')
            .fontSize(13)
            .fontColor(this.customThemeColor)
            .fontWeight(FontWeight.Medium)
        }
        .width('100%')
        .height(44)
        .padding({ left: 18, right: 18 })
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(20)
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
        .margin({ bottom: 10 })

        // 色卡 + 自定义（圆角矩形卡片包裹）
        Column() {
          Row() {
            ForEach(this.capsuleColors, (color: string) => {
              Stack() {
                Circle().width(28).height(28).fill(color)
                  .stroke(this.cardCapsuleColor === color
                    ? (this.isDarkMode ? Color.White : '#333333') : Color.Transparent)
                  .strokeWidth(2.5)
                if (this.cardCapsuleColor === color) {
                  Text('✓').fontSize(12)
                    .fontColor(color === '#FFD600' && !this.isDarkMode ? '#333333' : Color.White)
                    .fontWeight(FontWeight.Bold)
                }
              }
              .width(32).height(32).margin({ right: 6 })
              .onClick(() => {
                AppStorage.set('cardCapsuleColor', color);
                this.savePrefs('cardCapsuleColor', color);
              })
            })
            Text('自定义')
              .flexShrink(1)
              .fontSize(11)
              .fontColor(this.customThemeColor)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .borderRadius(14)
              .border({ width: 1, color: this.customThemeColor })
              .onClick(() => {
                const hsv = this.hexToHsv(this.cardCapsuleColor || '#007DFF');
                this.capsuleHue = hsv[0];
                this.capsuleSaturation = hsv[1];
                this.capsuleBrightness = hsv[2];
                this.colorPickerTarget = 'capsule';
                this.showCapsuleColorPicker = true;
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
        .margin({ bottom: 10 })
      }
      }
    }
    .width('100%')
    .margin({ bottom: 12 })

    // ── 播放量自定义 ──
    Column() {
      Row() {
        Text('播放量自定义')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .fontWeight(FontWeight.Medium)
        Blank()
        Column() {
          Image($r('app.media.chevron_right'))
            .width(16).height(16)
            .fillColor(this.playCountGroupExpanded ? Color.White : this.customThemeColor)
            .rotate({ angle: this.playCountGroupExpanded ? -90 : 90 })
        }
        .width(28).height(28)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(14)
        .backgroundColor(this.playCountGroupExpanded
          ? this.customThemeColor
          : (this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.06)'))
      }
      .width('100%')
      .height(44)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
      .borderRadius(20)
      .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      .margin({ bottom: 10 })
      .onClick(() => { this.playCountGroupExpanded = !this.playCountGroupExpanded; })
      .clickEffect({ level: 0, scale: 0.98 })

      if (this.playCountGroupExpanded) {
        this.ToggleItem(
          '显示播放量',
          this.cardPlayCountShow,
          (value: boolean) => {
            AppStorage.set('cardPlayCountShow', value);
            this.savePrefs('cardPlayCountShow', value);
          },
          '关闭后卡片上不显示播放量'
        )

        if (this.cardPlayCountShow) {
          this.ToggleItem(
            '播放量图标',
            this.cardPlayCountIcon,
            (value: boolean) => {
              AppStorage.set('cardPlayCountIcon', value);
              this.savePrefs('cardPlayCountIcon', value);
            },
            '播放量文字后面的 ▶ 图标'
          )

          // 字号
          Column() {
            Row() {
              Text('字号')
                .fontSize(15)
                .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                .fontWeight(FontWeight.Medium)
              Blank()
              Text(`${Math.round(this.cardPlayCountSize)}`)
                .fontSize(13)
                .fontColor(this.customThemeColor)
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')
            .margin({ bottom: 8 })
            Slider({
              value: this.cardPlayCountSize,
              min: 10, max: 14, step: 1, style: SliderStyle.InSet
            })
              .width('100%')
              .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
              .selectedColor(this.customThemeColor)
              .blockColor(this.customThemeColor)
              .onChange((value: number) => {
                AppStorage.set('cardPlayCountSize', value);
                this.savePrefs('cardPlayCountSize', value);
              })
          }
          .width('100%')
          .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
          .borderRadius(20)
          .padding({ left: 18, right: 18, top: 12, bottom: 12 })
          .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
          .margin({ bottom: 10 })

          // 颜色模式（4 chips 卡片）
          Column() {
            Row() {
              Column() {
                Text('档位色')
                  .fontSize(12)
                  .fontColor(this.cardPlayCountColorMode === 'level'
                    ? Color.White : (this.isDarkMode ? '#CCCCCC' : '#666666'))
              }
              .layoutWeight(1).height(32)
              .justifyContent(FlexAlign.Center)
              .borderRadius(14)
              .backgroundColor(this.cardPlayCountColorMode === 'level'
                ? this.customThemeColor : (this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)'))
              .onClick(() => {
                AppStorage.set('cardPlayCountColorMode', 'level');
                this.savePrefs('cardPlayCountColorMode', 'level');
              })
              Column() {
                Text('主题色')
                  .fontSize(12)
                  .fontColor(this.cardPlayCountColorMode === 'theme'
                    ? Color.White : (this.isDarkMode ? '#CCCCCC' : '#666666'))
              }
              .layoutWeight(1).height(32)
              .justifyContent(FlexAlign.Center)
              .borderRadius(14)
              .backgroundColor(this.cardPlayCountColorMode === 'theme'
                ? this.customThemeColor : (this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)'))
              .onClick(() => {
                AppStorage.set('cardPlayCountColorMode', 'theme');
                this.savePrefs('cardPlayCountColorMode', 'theme');
              })
              Column() {
                Text('黑/白')
                  .fontSize(12)
                  .fontColor(this.cardPlayCountColorMode === 'mono'
                    ? Color.White : (this.isDarkMode ? '#CCCCCC' : '#666666'))
              }
              .layoutWeight(1).height(32)
              .justifyContent(FlexAlign.Center)
              .borderRadius(14)
              .backgroundColor(this.cardPlayCountColorMode === 'mono'
                ? this.customThemeColor : (this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)'))
              .onClick(() => {
                AppStorage.set('cardPlayCountColorMode', 'mono');
                this.savePrefs('cardPlayCountColorMode', 'mono');
              })
              Column() {
                Text('自定义')
                  .fontSize(12)
                  .fontColor(this.cardPlayCountColorMode === 'custom'
                    ? Color.White : (this.isDarkMode ? '#CCCCCC' : '#666666'))
              }
              .layoutWeight(1).height(32)
              .justifyContent(FlexAlign.Center)
              .borderRadius(14)
              .backgroundColor(this.cardPlayCountColorMode === 'custom'
                ? this.customThemeColor : (this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)'))
              .onClick(() => {
                if (this.cardPlayCountColor) {
                  AppStorage.set('cardPlayCountColorMode', 'custom');
                  this.savePrefs('cardPlayCountColorMode', 'custom');
                } else {
                  const hsv = this.hexToHsv('#007DFF');
                  this.capsuleHue = hsv[0];
                  this.capsuleSaturation = hsv[1];
                  this.capsuleBrightness = hsv[2];
                  this.colorPickerTarget = 'playCount';
                  this.showCapsuleColorPicker = true;
                }
              })
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
          .borderRadius(16)
          .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
          .margin({ bottom: 10 })

          // 自定义色卡（custom 模式时显示）
          if (this.cardPlayCountColorMode === 'custom') {
            Column() {
              Row() {
                ForEach(this.capsuleColors, (color: string) => {
                  Stack() {
                    Circle().width(28).height(28).fill(color)
                      .stroke(this.cardPlayCountColor === color
                        ? (this.isDarkMode ? Color.White : '#333333') : Color.Transparent)
                      .strokeWidth(2.5)
                    if (this.cardPlayCountColor === color) {
                      Text('✓').fontSize(12)
                        .fontColor(color === '#FFD600' && !this.isDarkMode ? '#333333' : Color.White)
                        .fontWeight(FontWeight.Bold)
                    }
                  }
                  .width(32).height(32).margin({ right: 6 })
                  .onClick(() => {
                    AppStorage.set('cardPlayCountColor', color);
                    this.savePrefs('cardPlayCountColor', color);
                  })
                })
                Text('自定义')
                  .fontSize(11)
                  .fontColor(this.customThemeColor)
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .border({ width: 1, color: this.customThemeColor })
                  .flexShrink(1)
                  .onClick(() => {
                    const hsv = this.hexToHsv(this.cardPlayCountColor || '#007DFF');
                    this.capsuleHue = hsv[0];
                    this.capsuleSaturation = hsv[1];
                    this.capsuleBrightness = hsv[2];
                    this.colorPickerTarget = 'playCount';
                    this.showCapsuleColorPicker = true;
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
            .borderRadius(16)
            .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
            .margin({ bottom: 10 })
          }
        }
      }
    }
    .width('100%')
    .margin({ bottom: 12 })

    // 卡片圆角 / 卡片间距（双列）
    Row() {
      Column() {
        Column() {
          Row() {
            Text('卡片圆角')
              .fontSize(15)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .fontWeight(FontWeight.Medium)
            Blank()
            Text(`${this.cardListBorderRadius}vp`)
              .fontSize(13)
              .fontColor(this.customThemeColor)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ bottom: 8 })

          Slider({
            value: this.cardListBorderRadius,
            min: 0, max: 40, step: 2, style: SliderStyle.InSet
          })
            .width('100%')
            .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
            .selectedColor(this.customThemeColor)
            .blockColor(this.customThemeColor)
            .onChange((value: number) => {
              AppStorage.set('cardListBorderRadius', value);
              this.savePrefs('cardListBorderRadius', value);
            })
        }
        .width('100%')
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(20)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      }
      .layoutWeight(1)
      .margin({ right: 6 })

      Column() {
        Column() {
          Row() {
            Text('卡片间距')
              .fontSize(15)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .fontWeight(FontWeight.Medium)
            Blank()
            Text(`${this.cardListMargin}vp`)
              .fontSize(13)
              .fontColor(this.customThemeColor)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ bottom: 8 })

          Slider({
            value: this.cardListMargin,
            min: 0, max: 32, step: 2, style: SliderStyle.InSet
          })
            .width('100%')
            .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
            .selectedColor(this.customThemeColor)
            .blockColor(this.customThemeColor)
            .onChange((value: number) => {
              AppStorage.set('cardListMargin', value);
              this.savePrefs('cardListMargin', value);
            })
        }
        .width('100%')
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(20)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 6 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 12 })
  }

  /** 首页样式预览：胶囊频道标题 + 双列卡片（背景用 backgroundImage 贴图，不影响布局高度） */
  @Builder
  HomePreview() {
    Column() {
      // 顶部：胶囊标题（仿首页）
      Row() {
        Row() {
          Row() {
            Text('推荐')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
          }
          .padding({ left: 12, right: 12 })
          .backgroundColor(this.isDarkMode ? 'rgba(40,40,40,0.9)' : 'rgba(0,0,0,0.55)')
          .borderRadius(14)
          .height(28)
        }
        Blank()
        Text('设置')
          .fontSize(12)
          .fontColor(this.isDarkMode ? '#AAAAAA' : '#666666')
      }
      .width('100%')
      .margin({ bottom: 10 })

      // 双列卡片网格（PreviewCardLayout 实时使用 cardListBorderRadius / cardListMargin）
      Column() {
        this.PreviewCardLayout()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(this.getPreviewBgColor())
      .borderRadius(this.cardListBorderRadius + 8)
      .clip(true)
      .border({
        width: this.cardTransparentStyle ? this.cardBorderWidth : 0,
        color: this.getPreviewBorderColor()
      })
      .shadow({ radius: 3, color: '#10000000', offsetY: 1 })
    }
    .width('100%')
    .padding(16)
    .backgroundImage($r('app.media.yulanbizhi'))
    .backgroundImageSize(ImageSize.Cover)
    .borderRadius(20)
    .clip(true)
    .margin({ bottom: 12 })
  }

  // ════════════════════════ 播放页 ════════════════════════

  @Builder
  PlayerSection() {
    // 透明风格 / 跟随主题色（双列）
    Row() {
      Column() {
        this.ToggleItem(
          '透明风格',
          this.cardTransparentStyleVideo,
          (value: boolean) => {
            AppStorage.set('cardTransparentStyleVideo', value);
            this.savePrefs('cardTransparentStyleVideo', value);
          }
        )
      }
      .layoutWeight(1)
      .margin({ right: 6 })

      Column() {
        this.ToggleItem(
          '跟随主题色',
          this.playerFollowTheme,
          (value: boolean) => {
            AppStorage.set('playerFollowTheme', value);
            this.savePrefs('playerFollowTheme', value);
          }
        )
      }
      .layoutWeight(1)
      .margin({ left: 6 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)

    // 视频页背景模糊强度滑块
    Column() {
      Row() {
        Text('视频页背景模糊强度')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .fontWeight(FontWeight.Medium)
        Blank()
        Text(`${this.cardBgBlurAmount}px`)
          .fontSize(14)
          .fontColor(this.customThemeColor)
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .margin({ bottom: 8 })

      Row() {
        Image($r('app.media.arrow_clockwise'))
          .width(18).height(18)
          .margin({ right: 8 })
          .fillColor(this.customThemeColor)
          .onClick(() => {
            AppStorage.set('cardBgBlurAmount', 24);
            this.savePrefs('cardBgBlurAmount', 24);
          })

        Slider({
          value: this.cardBgBlurAmount,
          min: 0, max: 150, step: 2, style: SliderStyle.InSet
        })
          .layoutWeight(1)
          .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
          .selectedColor(this.customThemeColor)
          .blockColor('#FFFFFF')
          .onChange((value: number) => {
            AppStorage.set('cardBgBlurAmount', value);
            this.savePrefs('cardBgBlurAmount', value);
            AppStorage.set('videoBgCustomWallpaperBlur', value);
            this.savePrefs('videoBgCustomWallpaperBlur', value);
          })
      }
      .width('100%')
    }
    .width('100%')
    .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
    .borderRadius(20)
    .padding({ left: 18, right: 18, top: 12, bottom: 12 })
    .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
    .margin({ bottom: 12 })

    // 视频页背景明暗调节滑块
    Column() {
      Row() {
        Text('视频页背景明暗调节')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .fontWeight(FontWeight.Medium)
        Blank()
        Text(`${this.cardBgDarkness}%`)
          .fontSize(14)
          .fontColor(this.customThemeColor)
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .margin({ bottom: 8 })

      Row() {
        Image($r('app.media.arrow_clockwise'))
          .width(18).height(18)
          .margin({ right: 8 })
          .fillColor(this.customThemeColor)
          .onClick(() => {
            AppStorage.set('cardBgDarkness', 50);
            this.savePrefs('cardBgDarkness', 50);
          })

        Slider({
          value: this.cardBgDarkness,
          min: 0, max: 100, step: 5, style: SliderStyle.InSet
        })
          .layoutWeight(1)
          .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
          .selectedColor(this.customThemeColor)
          .blockColor('#FFFFFF')
          .onChange((value: number) => {
            AppStorage.set('cardBgDarkness', value);
            this.savePrefs('cardBgDarkness', value);
            AppStorage.set('videoBgCustomWallpaperDarkness', value);
            this.savePrefs('videoBgCustomWallpaperDarkness', value);
          })
      }
      .width('100%')
    }
    .width('100%')
    .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
    .borderRadius(20)
    .padding({ left: 18, right: 18, top: 12, bottom: 12 })
    .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
    .margin({ bottom: 12 })

    // ── 播放页效果预览（位于背景明暗调节下方，实时反映开关/背景/圆角间距） ──
    this.VideoPageLandscapePreview()

    // 视频页背景
    Column() {
      Row() {
        Text('视频页背景')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .fontWeight(FontWeight.Medium)
        Blank()
        Text(this.videoBgMode === 'cover' ? '封面' : this.videoBgMode === 'wallpaper' ? '自定义' : '纯色')
          .fontSize(14)
          .fontColor(this.customThemeColor)
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')

      // 模式选择（常显）
      Row() {
        this.ModeChip('封面', 'cover')
        this.ModeChip('纯色', 'custom_color')
        this.ModeChip('自定义', 'wallpaper')
      }
      .width('100%')
      .margin({ top: 8, bottom: 8 })

      if (this.videoBgMode === 'custom_color') {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
          ForEach(this.videoBgPresetColors, (color: string) => {
            Stack() {
              Circle().width(32).height(32).fill(color)
                .stroke(this.videoBgColor === color ?
                  (this.isDarkMode ? Color.White : '#333333') : Color.Transparent)
                .strokeWidth(2.5)
              if (this.videoBgColor === color) {
                Text('✓').fontSize(14)
                  .fontColor(color === '#FFFFFF' && !this.isDarkMode ? '#333333' : Color.White)
                  .fontWeight(FontWeight.Bold)
              }
            }
            .width(36).height(36).margin({ right: 6, bottom: 6 })
            .onClick(() => {
              AppStorage.set('videoBgMode', 'custom_color');
              AppStorage.set('videoBgColor', color);
              this.savePrefs('videoBgMode', 'custom_color');
              this.savePrefs('videoBgColor', color);
            })
          })
        }
        .width('100%')
        .margin({ top: 4 })
      }

      if (this.videoBgMode === 'wallpaper') {
        if (this.videoBgCustomWallpaper) {
          Row() {
            Image('file://' + this.videoBgCustomWallpaper)
              .width(48).height(48).borderRadius(8).objectFit(ImageFit.Cover)
            Column() {
              Text('当前壁纸').fontSize(14).fontColor(this.isDarkMode ? '#CCCCCC' : '#555555')
              Text('点击下方按钮更换').fontSize(12).fontColor(this.isDarkMode ? '#888888' : '#999999')
            }
            .margin({ left: 10 }).alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .margin({ bottom: 10 })
        }
        Row() {
          Row() {
            Text('从相册选择壁纸').fontSize(14).fontWeight(FontWeight.Medium).fontColor(Color.White)
          }
          .layoutWeight(1).height(40)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.customThemeColor).borderRadius(10)
          .hitTestBehavior(HitTestMode.Block)
          .onClick(() => { this.pickWallpaper(); })
          .clickEffect({ level: 0, scale: 0.96 })
          if (this.videoBgCustomWallpaper) {
            Row() {
              Text('恢复默认').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#999999')
            }
            .layoutWeight(1).height(40)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.04)')
            .borderRadius(10).margin({ left: 8 })
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => { this.resetWallpaper(); })
            .clickEffect({ level: 0, scale: 0.96 })
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
    .borderRadius(20)
    .padding({ left: 18, right: 18, top: 12, bottom: 12 })
    .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
    .margin({ bottom: 12 })

    // 播放页卡片间距 / 圆角（双列）
    Row() {
      Column() {
        Column() {
          Row() {
            Text('卡片间距')
              .fontSize(15)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .fontWeight(FontWeight.Medium)
            Blank()
            Text(`${this.cardMargin}vp`)
              .fontSize(13)
              .fontColor(this.customThemeColor)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ bottom: 8 })

          Slider({
            value: this.cardMargin,
            min: 0, max: 32, step: 2, style: SliderStyle.InSet
          })
            .width('100%')
            .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
            .selectedColor(this.customThemeColor)
            .blockColor(this.customThemeColor)
            .onChange((value: number) => {
              AppStorage.set('cardMargin', value);
              this.savePrefs('cardMargin', value);
            })
        }
        .width('100%')
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(20)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      }
      .layoutWeight(1)
      .margin({ right: 6 })

      Column() {
        Column() {
          Row() {
            Text('卡片圆角')
              .fontSize(15)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .fontWeight(FontWeight.Medium)
            Blank()
            Text(`${this.cardBorderRadius}vp`)
              .fontSize(13)
              .fontColor(this.customThemeColor)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ bottom: 8 })

          Slider({
            value: this.cardBorderRadius,
            min: 0, max: 40, step: 2, style: SliderStyle.InSet
          })
            .width('100%')
            .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
            .selectedColor(this.customThemeColor)
            .blockColor(this.customThemeColor)
            .onChange((value: number) => {
              AppStorage.set('cardBorderRadius', value);
              this.savePrefs('cardBorderRadius', value);
            })
        }
        .width('100%')
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(20)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      }
      .layoutWeight(1)
      .margin({ left: 6 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 12 })

    // 播放页细节开关组（可折叠，默认收起）
    Column() {
      Row() {
        Text('播放页细节开关')
          .fontSize(15)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .fontWeight(FontWeight.Medium)
        Blank()
        Text(this.playerDetailExpanded ? '收起 ▴' : '展开 ▾')
          .fontSize(13)
          .fontColor(this.customThemeColor)
      }
      .width('100%')
      .height(44)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
      .borderRadius(16)
      .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      .onClick(() => { this.playerDetailExpanded = !this.playerDetailExpanded; })
      .clickEffect({ level: 0, scale: 0.97 })

      if (this.playerDetailExpanded) {
        Row() {
          Column() {
            this.CompactToggleItem(
              '详情卡片',
              this.cardStyleVideoDetail,
              (value: boolean) => {
                AppStorage.set('cardStyleVideoDetail', value);
                this.savePrefs('cardStyleVideoDetail', value);
              }
            )
            this.CompactToggleItem(
              '评论区',
              this.cardStyleVideoCommentSection,
              (value: boolean) => {
                AppStorage.set('cardStyleVideoCommentSection', value);
                this.savePrefs('cardStyleVideoCommentSection', value);
              }
            )
            this.CompactToggleItem(
              '评论气泡',
              this.cardStyleVideoCommentBubble,
              (value: boolean) => {
                AppStorage.set('cardStyleVideoCommentBubble', value);
                this.savePrefs('cardStyleVideoCommentBubble', value);
              }
            )
            // 评论区文字布局：左对齐 / 居中
            Column() {
              Text('评论区布局')
                .fontSize(14)
                .fontColor(this.isDarkMode ? '#CCCCCC' : '#666666')
                .fontWeight(FontWeight.Normal)
                .width('100%')
              Row() {
                this.CommentAlignChip('文本左对齐', 'left')
                this.CommentAlignChip('文本居中', 'center')
              }
              .width('100%')
              .margin({ top: 2 })
            }
            .width('100%')
            .padding({ left: 24, right: 8 })
            .margin({ bottom: 4 })
            this.CompactToggleItem(
              '简介卡片',
              this.cardStyleVideoDescription,
              (value: boolean) => {
                AppStorage.set('cardStyleVideoDescription', value);
                this.savePrefs('cardStyleVideoDescription', value);
              }
            )
          }
          .layoutWeight(1)
          .margin({ right: 6 })

          Column() {
            this.CompactToggleItem(
              '分段按钮',
              this.cardStyleVideoSegmentBtn,
              (value: boolean) => {
                AppStorage.set('cardStyleVideoSegmentBtn', value);
                this.savePrefs('cardStyleVideoSegmentBtn', value);
              }
            )
            this.CompactToggleItem(
              '互动按钮',
              this.cardStyleVideoInteractBtns,
              (value: boolean) => {
                AppStorage.set('cardStyleVideoInteractBtns', value);
                this.savePrefs('cardStyleVideoInteractBtns', value);
              }
            )
            this.CompactToggleItem(
              '导航按钮',
              this.cardStyleVideoNavBtns,
              (value: boolean) => {
                AppStorage.set('cardStyleVideoNavBtns', value);
                this.savePrefs('cardStyleVideoNavBtns', value);
              }
            )
          }
          .layoutWeight(1)
          .margin({ left: 6 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .margin({ bottom: 12 })
  }

  // ════════════════════════ 更多 ════════════════════════

  @Builder
  MoreSection() {
    // 预设：内置 + 自定义，点击应用需确认
    Column() {
      Row() {
        Text('预设')
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .fontWeight(FontWeight.Medium)
        Blank()
        Text('点击应用需确认')
          .fontSize(11)
          .fontColor(this.isDarkMode ? '#AAAAAA' : '#888888')
      }
      .width('100%')
      .margin({ top: 4, bottom: 8 })

      // 内置预设（长按可编辑/恢复默认；应用时覆盖值优先）
      ForEach(getBuiltinPresets(), (p: StylePresetData) => {
        Row() {
          if (p.icon) {
            Image($r('app.media.' + p.icon))
              .width(22).height(22)
              .margin({ right: 10 })
          }
          Column() {
            Text(p.name)
              .fontSize(15)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .fontWeight(FontWeight.Medium)
              .width('100%')
            Text(this.isBuiltinEdited(p.name) ? '已修改 · 长按编辑/恢复' : '内置 · 长按编辑')
              .fontSize(10)
              .fontColor(this.isBuiltinEdited(p.name)
                ? this.customThemeColor
                : (this.isDarkMode ? '#999999' : '#AAAAAA'))
              .width('100%')
              .margin({ top: 1 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('应用')
            .fontSize(13)
            .fontColor(this.customThemeColor)
        }
        .width('100%')
        .height(52)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
        .margin({ bottom: 8 })
        .onClick(() => { this.confirmApplyPreset(this.effBuiltinPreset(p)); })
        .gesture(
          LongPressGesture()
            .onAction(() => {
              this.editingBuiltinName = p.name;
              this.showBuiltinEditSheet = true;
            })
        )
        .clickEffect({ level: 0, scale: 0.97 })
      }, (p: StylePresetData) => p.name)

      // 用户自定义预设
      ForEach(this.customPresets, (p: StylePresetData) => {
        Row() {
          Column() {
            Text(p.name)
              .fontSize(15)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .fontWeight(FontWeight.Medium)
              .width('100%')
            Text('自定义 · 长按删除')
              .fontSize(10)
              .fontColor(this.customThemeColor)
              .width('100%')
              .margin({ top: 1 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('应用')
            .fontSize(13)
            .fontColor(this.customThemeColor)
        }
        .width('100%')
        .height(52)
        .padding({ left: 14, right: 14 })
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(16)
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
        .margin({ bottom: 8 })
        .onClick(() => { this.confirmApplyPreset(p); })
        .gesture(
          LongPressGesture()
            .onAction(() => { this.confirmDeletePreset(p); })
        )
        .clickEffect({ level: 0, scale: 0.97 })
      }, (p: StylePresetData) => p.name)

      // 保存当前为预设
      Row() {
        Text('保存当前样式为预设')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
      }
      .width('100%')
      .height(40)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.customThemeColor)
      .borderRadius(16)
      .onClick(() => {
        this.presetNameInput = '';
        this.showPresetNameSheet = true;
      })
      .clickEffect({ level: 0, scale: 0.96 })
      .margin({ top: 4 })
      .bindSheet($$this.showBuiltinEditSheet, this.BuiltinPresetEditSheetContent(), {
        height: 260,
        dragBar: false,
        showClose: false,
        backgroundColor: this.isDarkMode ? '#1C1C1E' : '#F5F5F5',
        onDisappear: () => { this.showBuiltinEditSheet = false; }
      })
    }
    .width('100%')
    .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.04)' : 'rgba(0,0,0,0.02)')
    .borderRadius(20)
    .padding({ left: 12, right: 12, top: 10, bottom: 14 })
    .bindSheet($$this.showPresetNameSheet, this.PresetNameSheetContent(), {
      height: 240,
      dragBar: false,
      showClose: false,
      backgroundColor: this.isDarkMode ? '#1C1C1E' : '#F5F5F5',
      onDisappear: () => { this.showPresetNameSheet = false; }
    })
  }

  /** 应用预设前确认 */
  private confirmApplyPreset(p: StylePresetData): void {
    AlertDialog.show({
      title: '应用预设',
      message: `切换到「${p.name}」预设？当前样式将被覆盖${this.cardStylePerMode ? '（当前模式档案也会更新）' : ''}。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: this.isDarkMode ? '#FFFFFF' : '#000000',
        action: () => {}
      },
      secondaryButton: {
        value: '应用',
        fontColor: '#E84040',
        action: () => { this.applyPresetData(p); }
      }
    });
  }

  /** 应用预设：按当前模式取档；另一模式档同步写入对应模式档案（独立开时切模式即见另一套） */
  private async applyPresetData(p: StylePresetData): Promise<void> {
    const cur = this.isDarkMode ? p.values.dark : p.values.light;
    const other = this.isDarkMode ? p.values.light : p.values.dark;
    const keys = Object.keys(cur);
    for (const k of keys) {
      const v = cur[k];
      if (v !== undefined) {
        AppStorage.set(k, v);
        this.savePrefs(k, v);
      }
    }
    // 另一模式档写入档案（深浅色独立开关时生效；同档时此档案将在切回时被同档值覆盖，无副作用）
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await applyPresetModeArchive(pref, !this.isDarkMode, other);
    } catch (e) {
      logError(`同步预设另一模式存档失败: ${e}`);
    }
    this.getUIContext().getPromptAction().showToast({ message: `已应用「${p.name}」（当前模式档）` });
  }

  /** 保存当前样式为命名预设 */
  private async doSaveCustomPreset(): Promise<void> {
    const name = this.presetNameInput.trim();
    if (name === '') {
      this.getUIContext().getPromptAction().showToast({ message: '请输入预设名称' });
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      const pair = await buildModePairSnapshot(pref, this.isDarkMode);
      this.customPresets = await saveCustomPreset(pref, name, pair);
      this.showPresetNameSheet = false;
      this.getUIContext().getPromptAction().showToast({ message: `已保存预设「${name}」（深浅各一档）` });
    } catch (e) {
      logError(`保存预设失败: ${e}`);
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
  }

  /** 内置预设是否被修改过 */
  private isBuiltinEdited(name: string): boolean {
    return this.builtinEdits.some((e: StylePresetData) => e.name === name);
  }

  /** 内置预设生效值：有修改覆盖用覆盖，否则用默认 */
  private effBuiltinPreset(p: StylePresetData): StylePresetData {
    const edit = this.builtinEdits.find((e: StylePresetData) => e.name === p.name);
    return edit ? edit : p;
  }

  /** 用当前样式覆盖内置预设 */
  private async doSaveBuiltinEdit(): Promise<void> {
    const name = this.editingBuiltinName;
    if (name === '') return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      const pair = await buildModePairSnapshot(pref, this.isDarkMode);
      this.builtinEdits = await saveBuiltinEdit(pref, name, pair);
      this.showBuiltinEditSheet = false;
      this.getUIContext().getPromptAction().showToast({ message: `已将「${name}」覆盖为当前样式（深浅各一档）` });
    } catch (e) {
      logError(`覆盖内置预设失败: ${e}`);
      this.getUIContext().getPromptAction().showToast({ message: '操作失败' });
    }
  }

  /** 恢复内置预设默认 */
  private async doRestoreBuiltinDefault(): Promise<void> {
    const name = this.editingBuiltinName;
    if (name === '') return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      this.builtinEdits = await restoreBuiltinDefault(pref, name);
      this.showBuiltinEditSheet = false;
      this.getUIContext().getPromptAction().showToast({ message: `「${name}」已恢复为默认` });
    } catch (e) {
      logError(`恢复内置预设失败: ${e}`);
      this.getUIContext().getPromptAction().showToast({ message: '操作失败' });
    }
  }

  @Builder
  BuiltinPresetEditSheetContent() {
    Column() {
      Row() {
        Text(`「${this.editingBuiltinName}」`)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Blank()
      }
      .width('100%')
      .margin({ bottom: 14 })

      // 编辑：用当前样式覆盖
      Row() {
        Text('编辑预设')
          .fontSize(15)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .fontWeight(FontWeight.Medium)
        Blank()
        Text('用当前样式覆盖')
          .fontSize(12)
          .fontColor(this.customThemeColor)
      }
      .width('100%')
      .height(48)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
      .borderRadius(16)
      .onClick(() => { this.doSaveBuiltinEdit(); })
      .clickEffect({ level: 0, scale: 0.97 })
      .margin({ bottom: 10 })

      // 恢复内置预设默认
      Row() {
        Text('恢复内置默认')
          .fontSize(15)
          .fontColor(this.isBuiltinEdited(this.editingBuiltinName)
            ? (this.isDarkMode ? '#FFFFFF' : '#000000')
            : (this.isDarkMode ? '#999999' : '#AAAAAA'))
          .fontWeight(FontWeight.Medium)
        Blank()
        Text(this.isBuiltinEdited(this.editingBuiltinName) ? '清除修改' : '未修改')
          .fontSize(12)
          .fontColor(this.isBuiltinEdited(this.editingBuiltinName)
            ? '#E84040' : (this.isDarkMode ? '#777777' : '#999999'))
      }
      .width('100%')
      .height(48)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
      .borderRadius(16)
      .onClick(() => {
        if (this.isBuiltinEdited(this.editingBuiltinName)) {
          this.doRestoreBuiltinDefault();
        } else {
          this.getUIContext().getPromptAction().showToast({ message: '该预设未被修改过' });
        }
      })
      .clickEffect({ level: 0, scale: 0.97 })
      .margin({ bottom: 14 })

      Button('关闭')
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(this.customThemeColor)
        .fontColor(Color.White)
        .borderRadius(12)
        .onClick(() => { this.showBuiltinEditSheet = false; })
        .clickEffect({ level: 0, scale: 0.96 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 })
  }

  /** 长按删除预设确认 */
  private confirmDeletePreset(p: StylePresetData): void {
    AlertDialog.show({
      title: '删除预设',
      message: `删除「${p.name}」？删除后不可恢复。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        fontColor: this.isDarkMode ? '#FFFFFF' : '#000000',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E84040',
        action: () => { this.doDeletePreset(p); }
      }
    });
  }

  /** 执行删除自定义预设 */
  private async doDeletePreset(p: StylePresetData): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      this.customPresets = await deleteCustomPreset(pref, p.name);
      this.getUIContext().getPromptAction().showToast({ message: `已删除「${p.name}」` });
    } catch (e) {
      logError(`删除预设失败: ${e}`);
      this.getUIContext().getPromptAction().showToast({ message: '删除失败' });
    }
  }

  @Builder
  PresetNameSheetContent() {
    Column() {
      Row() {
        Text('保存为预设')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Blank()
      }
      .width('100%')
      .margin({ bottom: 14 })

      TextInput({ placeholder: '输入预设名称（同名将覆盖）', text: this.presetNameInput })
        .height(44)
        .fontSize(14)
        .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        .placeholderColor(this.isDarkMode ? '#666666' : '#999999')
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.04)')
        .borderRadius(12)
        .margin({ bottom: 16 })
        .onChange((v: string) => { this.presetNameInput = v; })

      Row() {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(Color.Transparent)
          .fontColor(this.customThemeColor)
          .border({ width: 1.5, color: this.customThemeColor })
          .borderRadius(12)
          .margin({ right: 6 })
          .onClick(() => { this.showPresetNameSheet = false; })
          .clickEffect({ level: 0, scale: 0.96 })
        Button('保存')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(this.customThemeColor)
          .fontColor(Color.White)
          .borderRadius(12)
          .margin({ left: 6 })
          .onClick(() => { this.doSaveCustomPreset(); })
          .clickEffect({ level: 0, scale: 0.96 })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 })
  }

  @Builder
  ToggleItem(title: string, isOn: boolean, onChange: (isOn: boolean) => void, desc?: string) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (desc) {
          Text(desc)
            .fontSize(11)
            .fontColor(this.isDarkMode ? '#AAAAAA' : '#888888')
            .maxLines(1)
            .margin({ top: 2 })
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ right: 8 })
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(this.customThemeColor)
        .switchPointColor(Color.White)
        .scale({ x: 0.85, y: 0.85 })
        .onChange((value: boolean) => {
          onChange(value);
        })
    }
    .width('100%')
    .height(48)
    .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
    .borderRadius(20)
    .padding({ left: 14, right: 14 })
    .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
    .margin({ bottom: 12 })
    .animation({ duration: 150, curve: Curve.EaseOut })
    .stateStyles({
      pressed: {
        backgroundColor: this.isDarkMode ? 'rgba(255,255,255,0.18)' : 'rgba(255,255,255,0.55)'
      }
    })
  }

  @Builder
  CompactToggleItem(title: string, isOn: boolean, onChange: (isOn: boolean) => void) {
    Row() {
      Text(title)
        .fontSize(14)
        .fontColor(this.isDarkMode ? '#CCCCCC' : '#666666')
        .fontWeight(FontWeight.Normal)
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(this.customThemeColor)
        .switchPointColor(Color.White)
        .scale({ x: 0.75, y: 0.75 })
        .onChange((value: boolean) => {
          onChange(value);
        })
    }
    .width('100%')
    .height(40)
    .padding({ left: 24, right: 8 })
    .margin({ bottom: 4 })
  }

  // ════════════════════════ 主视图 ════════════════════════

  build() {
    Column() {
      // ── 标题栏 + 分类 + 内容：整体在一个滚动区内，随滚动一起移动 ──
      Scroll() {
        Column() {
          Row() {
        Text('卡片样式')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Blank()
        // ── 深浅色独立（同档=mingan 图标 / 独立=duli 图标；切换需确认） ──
        Row() {
          Image(this.cardStylePerMode ? $r('app.media.duli') : $r('app.media.mingan'))
            .width(20).height(20)
            .fillColor(this.cardStylePerMode ? Color.White : (this.isDarkMode ? '#AAAAAA' : '#888888'))
            .margin({ right: 5 })
          Text(this.cardStylePerMode ? '独立' : '同档')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.cardStylePerMode ? Color.White : (this.isDarkMode ? '#CCCCCC' : '#666666'))
        }
        .height(32)
        .padding({ left: 11, right: 12 })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .borderRadius(16)
        .backgroundColor(this.cardStylePerMode
          ? this.customThemeColor
          : (this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)'))
        .margin({ right: 8 })
        .onClick(() => { this.confirmTogglePerMode(); })

        // ── 深色/浅色分段切换（仅图标） ──
        Row() {
          Row() {
            Image($r('app.media.brightness_low7'))
              .width(16).height(16)
              .fillColor(!this.isDarkMode ? Color.White : '#888888')
          }
          .layoutWeight(1)
          .height(28)
          .justifyContent(FlexAlign.Center)
          .borderRadius(12)
          .backgroundColor(!this.isDarkMode ? this.customThemeColor : Color.Transparent)
          .onClick(() => { this.switchDarkMode(false); })
          .clickEffect({ level: 0, scale: 0.94 })

          Row() {
            Image($r('app.media.ic_settings_darkmode'))
              .width(16).height(16)
              .fillColor(this.isDarkMode ? Color.White : '#888888')
          }
          .layoutWeight(1)
          .height(28)
          .justifyContent(FlexAlign.Center)
          .borderRadius(12)
          .backgroundColor(this.isDarkMode ? this.customThemeColor : Color.Transparent)
          .onClick(() => { this.switchDarkMode(true); })
          .clickEffect({ level: 0, scale: 0.94 })
        }
        .width(76)
        .height(34)
        .padding(3)
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.05)')
        .borderRadius(17)
        .margin({ right: 4 })
      }
      .width('100%')
      .height(44)

          this.CategoryBar()

          // 四个分类全部常驻（visibility 显隐），切换时不销毁预览组件，
          // 避免 yulanbizhi 背景图每次切换都重新解码导致闪烁
          // ⭐ 预设排第一位（顺序：预设 → 通用 → 首页 → 播放页）
          Column() {
            this.MoreSection()
          }
          .width('100%')
          .visibility(this.activeCategory === 0 ? Visibility.Visible : Visibility.None)
          Column() {
            this.CommonSection()
          }
          .width('100%')
          .visibility(this.activeCategory === 1 ? Visibility.Visible : Visibility.None)
          Column() {
            this.HomeSection()
          }
          .width('100%')
          .visibility(this.activeCategory === 2 ? Visibility.Visible : Visibility.None)
          Column() {
            this.PlayerSection()
          }
          .width('100%')
          .visibility(this.activeCategory === 3 ? Visibility.Visible : Visibility.None)
        }
        .width('100%')
        .padding({ bottom: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .bindSheet($$this.showCapsuleColorPicker, this.CapsuleColorPickerSheetContent(), {
        height: 420,
        dragBar: false,
        showClose: false,
        backgroundColor: this.isDarkMode ? '#1C1C1E' : '#F5F5F5',
        onDisappear: () => { this.showCapsuleColorPicker = false; }
      })
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor(this.isDarkMode ? '#1C1C1E' : '#F5F5F5')
    .bindSheet($$this.showCardColorPicker, this.CardColorPickerSheetContent(), {
      height: 280,
      dragBar: false,
      showClose: false,
      backgroundColor: this.isDarkMode ? '#1C1C1E' : '#F5F5F5',
      onDisappear: () => { this.showCardColorPicker = false; }
    })
  }

  // ════════════════════════ 预览构建器 ════════════════════════

  @Builder
  PreviewCardLayout() {
    Column() {
      // 第1行
      Row() {
        this.PreviewCard('教程视频标题', 'UP主A', 500000)
        this.PreviewCard('精选内容推荐', 'UP主B', 1200000)
      }
      .width('100%')
      .margin({ bottom: this.cardListMargin })

      // 第2行
      Row() {
        this.PreviewCard('热门视频推荐', 'UP主C', 80000)
        this.PreviewCard('每日精选推荐', 'UP主D', 3000000)
      }
      .width('100%')
    }
    .width('100%')
    .backgroundColor(Color.Transparent)
  }

  @Builder
  PreviewCard(title: string, owner: string, playCount: number) {
    Column() {
      Column()
        .width('100%')
        .aspectRatio(16 / 9)
        .backgroundColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
        .borderRadius(this.cardListBorderRadius)

      Column() {
        Text(title)
          .fontSize(11)
          .fontColor(this.isDarkMode ? Color.White : Color.Black)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ bottom: 2 })

        Row() {
          Text(owner)
            .fontSize(this.cardCapsuleShow ? this.cardCapsuleSize : 11)
            .fontColor(this.cardCapsuleShow
              ? ((this.cardCapsuleColor || this.cardCapsuleFollowTheme)
                ? (this.isDarkMode ? '#FFFFFF' : '#000000')
                : '#BA8841')
              : (this.isDarkMode ? '#FFFFFF' : '#000000'))
            .padding(this.cardCapsuleShow
              ? { left: 4, right: 4, top: this.cardCapsuleSize <= 10 ? 2 : 3, bottom: this.cardCapsuleSize <= 10 ? 2 : 3 }
              : { left: 0, right: 0, top: 0, bottom: 0 })
            .backgroundColor(this.cardCapsuleShow
              ? (this.cardCapsuleColor
                ? this.cardCapsuleColor
                : (this.cardCapsuleFollowTheme ? this.customThemeColor : 'rgba(186, 136, 65, 1)'))
              : Color.Transparent)
            .borderRadius(this.cardCapsuleShow ? this.cardCapsuleRadius : 0)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          Blank()
          if (this.cardPlayCountShow) {
            Text(formatPlayCountText(playCount, this.cardPlayCountUnit) + '播放')
              .fontSize(this.cardPlayCountSize)
              .fontColor(getPlayCountDisplayColor(playCount,
                this.cardPlayCountColorMode, this.cardPlayCountColor, this.customThemeColor, this.isDarkMode))
              .flexShrink(0)
            if (this.cardPlayCountIcon) {
              Image($r('app.media.play_fill'))
                .width(14)
                .height(14)
                .objectFit(ImageFit.Contain)
                .margin({ left: 3 })
                .fillColor(getPlayCountDisplayColor(playCount,
                  this.cardPlayCountColorMode, this.cardPlayCountColor, this.customThemeColor, this.isDarkMode))
            }
          }
        }
        .width('100%')
      }
      .width('100%')
      .padding(4)
    }
    .layoutWeight(1)
    .backgroundColor(this.cardCustomColor && this.cardCustomColor !== '#007DFF'
      ? (this.cardTransparentStyle
        ? '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1)
        : this.cardCustomColor)
      : (this.cardTransparentStyle
        ? (this.isDarkMode
          ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
          : `rgba(255,255,255,${this.cardBgOpacity / 100})`)
        : (this.isDarkMode ? '#2C2C2C' : '#FFFFFF')))
    .border({ width: this.cardTransparentStyle ? this.cardBorderWidth : 0,
      color: this.cardTransparentStyle
        ? (this.cardBorderFollowTheme
          ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1))
          : (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)'))
        : Color.Transparent })
    .borderRadius(this.cardListBorderRadius)
    .clip(true)
    .margin({ left: this.cardListMargin / 2, right: this.cardListMargin / 2 })
  }

  // ════════════════════════ 卡片色彩选取弹窗 ════════════════════════

  @Builder
  CardColorPickerSheetContent() {
    Column() {
      Row() {
        Text('卡片色彩')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Blank()
      }
      .width('100%')
      .margin({ bottom: 16 })

      // 预设色卡
      Grid() {
        ForEach(this.presetColors, (color: string) => {
          GridItem() {
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor(color)
              .borderRadius(8)
              .onClick(() => {
                AppStorage.set('cardCustomColor', color);
                this.cardCustomColor = color;
                this.savePrefs('cardCustomColor', color);
                this.showCardColorPicker = false;
              })
              .clickEffect({ level: 0, scale: 0.9 })
          }
          .shadow({ radius: 3, color: '#15000000', offsetY: 1 })
        })
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(8)
      .rowsGap(8)
      .width('100%')
      .margin({ bottom: 20 })

      // 当前选中色
      Row() {
        Text('当前选择')
          .fontSize(14)
          .fontColor(this.isDarkMode ? '#CCCCCC' : '#666666')
        Blank()
        Column()
          .width(28).height(28)
          .borderRadius(8)
          .backgroundColor(this.cardCustomColor || '#007DFF')
          .border({ width: 1, color: this.isDarkMode ? 'rgba(255,255,255,0.2)' : 'rgba(0,0,0,0.1)' })
        Text(this.cardCustomColor || '(默认)')
          .fontSize(13)
          .fontColor(this.customThemeColor)
          .fontWeight(FontWeight.Medium)
          .margin({ left: 8 })
      }
      .width('100%')

      Row() {
        Button('重置')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(Color.Transparent)
          .fontColor(this.customThemeColor)
          .border({ width: 1.5, color: this.customThemeColor })
          .borderRadius(12)
          .margin({ top: 20, right: 6 })
          .onClick(() => {
            AppStorage.set('cardCustomColor', '');
            this.cardCustomColor = '';
            this.savePrefs('cardCustomColor', '');
            this.showCardColorPicker = false;
          })
          .clickEffect({ level: 0, scale: 0.96 })
        Button('关闭')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(this.customThemeColor)
          .fontColor(Color.White)
          .borderRadius(12)
          .margin({ top: 20, left: 6 })
          .onClick(() => { this.showCardColorPicker = false; })
          .clickEffect({ level: 0, scale: 0.96 })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 })
  }

  /** 胶囊颜色自定义取色器（HSV 三滑条 + 实时预览，算法与个性化页取色器一致） */
  @Builder
  CapsuleColorPickerSheetContent() {
    Column() {
      Row() {
        Text(this.colorPickerTarget === 'capsule' ? '胶囊颜色' : '播放量颜色')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Blank()
        Text(this.hsvToHex(this.capsuleHue, this.capsuleSaturation / 100, this.capsuleBrightness / 100))
          .fontSize(11)
          .fontColor(this.customThemeColor)
          .fontWeight(FontWeight.Medium)
      }
      .width('100%')
      .margin({ bottom: 12 })

      // ── 实时预览：胶囊目标显示胶囊样式，播放量目标显示“播放量文字（带图标）” ──
      if (this.colorPickerTarget === 'playCount') {
        Row() {
          Text(formatPlayCountText(500000, this.cardPlayCountUnit) + '播放')
            .fontSize(this.cardPlayCountSize)
            .fontColor(this.hsvToHex(this.capsuleHue, this.capsuleSaturation / 100, this.capsuleBrightness / 100))
          if (this.cardPlayCountIcon) {
            Image($r('app.media.play_fill'))
              .width(14)
              .height(14)
              .objectFit(ImageFit.Contain)
              .margin({ left: 3 })
              .fillColor(this.hsvToHex(this.capsuleHue, this.capsuleSaturation / 100, this.capsuleBrightness / 100))
          }
          Blank()
        }
        .width('100%')
        .margin({ bottom: 12 })
      } else {
        Row() {
          Text('UP主名字')
            .fontSize(this.cardCapsuleSize)
            .fontColor(this.capsuleBrightness < 45 ? '#FFFFFF' : '#000000')
            .padding({ left: 6, right: 6, top: 4, bottom: 4 })
            .backgroundColor(this.hsvToHex(this.capsuleHue, this.capsuleSaturation / 100, this.capsuleBrightness / 100))
            .borderRadius(this.cardCapsuleRadius)
            .maxLines(1)
          Blank()
        }
        .width('100%')
        .margin({ bottom: 12 })
      }

      // 色相
      Row() {
        Text('色相').fontSize(14).fontColor(this.isDarkMode ? '#FFFFFF' : '#000000').width(36)
        Slider({ value: this.capsuleHue, min: 0, max: 360, step: 1, style: SliderStyle.InSet })
          .layoutWeight(1)
          .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
          .selectedColor(this.customThemeColor)
          .blockColor(this.customThemeColor)
          .onChange((value: number) => { this.capsuleHue = value; })
        Text(`${Math.round(this.capsuleHue)}°`)
          .fontSize(13).fontColor(this.customThemeColor).width(36).textAlign(TextAlign.End).margin({ left: 8 })
      }
      .width('100%')
      .height(40)

      // 饱和
      Row() {
        Text('饱和').fontSize(14).fontColor(this.isDarkMode ? '#FFFFFF' : '#000000').width(36)
        Slider({ value: this.capsuleSaturation, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
          .layoutWeight(1)
          .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
          .selectedColor(this.customThemeColor)
          .blockColor(this.customThemeColor)
          .onChange((value: number) => { this.capsuleSaturation = value; })
        Text(`${Math.round(this.capsuleSaturation)}%`)
          .fontSize(13).fontColor(this.customThemeColor).width(36).textAlign(TextAlign.End).margin({ left: 8 })
      }
      .width('100%')
      .height(40)

      // 亮度
      Row() {
        Text('亮度').fontSize(14).fontColor(this.isDarkMode ? '#FFFFFF' : '#000000').width(36)
        Slider({ value: this.capsuleBrightness, min: 0, max: 100, step: 1, style: SliderStyle.InSet })
          .layoutWeight(1)
          .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
          .selectedColor(this.customThemeColor)
          .blockColor(this.customThemeColor)
          .onChange((value: number) => { this.capsuleBrightness = value; })
        Text(`${Math.round(this.capsuleBrightness)}%`)
          .fontSize(13).fontColor(this.customThemeColor).width(36).textAlign(TextAlign.End).margin({ left: 8 })
      }
      .width('100%')
      .height(40)
      .margin({ bottom: 16 })

      Row() {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(Color.Transparent)
          .fontColor(this.customThemeColor)
          .border({ width: 1.5, color: this.customThemeColor })
          .borderRadius(12)
          .margin({ right: 6 })
          .onClick(() => { this.showCapsuleColorPicker = false; })
          .clickEffect({ level: 0, scale: 0.96 })
        Button('应用')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(this.customThemeColor)
          .fontColor(Color.White)
          .borderRadius(12)
          .margin({ left: 6 })
          .onClick(() => {
            const hex = this.hsvToHex(this.capsuleHue, this.capsuleSaturation / 100, this.capsuleBrightness / 100);
            if (this.colorPickerTarget === 'playCount') {
              AppStorage.set('cardPlayCountColor', hex);
              this.savePrefs('cardPlayCountColor', hex);
              AppStorage.set('cardPlayCountColorMode', 'custom');
              this.savePrefs('cardPlayCountColorMode', 'custom');
            } else {
              AppStorage.set('cardCapsuleColor', hex);
              this.savePrefs('cardCapsuleColor', hex);
            }
            this.showCapsuleColorPicker = false;
          })
          .clickEffect({ level: 0, scale: 0.96 })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 })
  }

  @Builder VideoPageLandscapePreview() {
    Column() {
      // ── 背景层 ──
      Stack() {
        if (this.videoBgMode === 'custom_color') {
          Column().width('100%').height('100%').backgroundColor(this.videoBgColor)
        } else if (this.videoBgMode === 'wallpaper' && this.videoBgCustomWallpaper) {
          Image('file://' + this.videoBgCustomWallpaper)
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
            .blur(this.videoBgCustomWallpaperBlur)
        } else {
          Image($r('app.media.yulanbizhi'))
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
            .blur(this.cardBgBlurAmount)
        }
        if (this.cardBgDarkness < 50) {
          Column().width('100%').height('100%')
            .backgroundColor(`rgba(0,0,0,${(50 - this.cardBgDarkness) / 50})`)
        } else if (this.cardBgDarkness > 50) {
          Column().width('100%').height('100%')
            .backgroundColor(`rgba(255,255,255,${(this.cardBgDarkness - 50) / 50})`)
        }

        // ── 固定内容：详情 + 评论 ──
        Column() {
          // ── 详情卡片 ──
          if (this.cardStyleVideoDetail) {
            Column() {
              Text('【4K】HarmonyOS 应用开发入门教程')
                .fontSize(13).fontColor(Color.White).fontWeight(FontWeight.Bold)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%').margin({ bottom: this.cardMargin })

              Row() {
                Circle().width(24).height(24).fill('#FB7299')
                Column() {
                  Text('UP主名称').fontSize(11).fontColor('#FB7299').maxLines(1)
                  Text('50万播放 · 1.2万弹幕').fontSize(10).fontColor(Color.White).opacity(0.6)
                }
                .margin({ left: 6 })
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .margin({ bottom: this.cardMargin })

              if (this.cardStyleVideoDescription) {
                Text('这是视频简介内容，展示了简介卡片的显示效果。HarmonyOS 是基于 OpenHarmony 开发的面向全场景的操作系统。')
                  .fontSize(10).fontColor(Color.White).opacity(0.7)
                  .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
            }
            .width('100%')
            .padding(this.cardMargin)
            .backgroundColor(this.getPreviewVideoCardBg())
            .border(this.getPreviewVideoCardBorder())
            .borderRadius(this.cardBorderRadius)
          }

          // ── 评论区 ──
          if (this.cardStyleVideoCommentSection) {
            Column() {
              Row() {
                Text('评论').fontSize(12).fontColor(Color.White).fontWeight(FontWeight.Medium)
                Blank()
                Text('最热').fontSize(10).fontColor(this.customThemeColor)
              }
              .width('100%')
              .margin({ bottom: this.cardMargin })

              this.CommentPreviewItem('用户A', '视频讲得很详细，学习了！', false)
              this.CommentPreviewItem('用户B', '请问有源码吗？', true)
              if (this.cardStyleVideoCommentBubble) {
                this.CommentPreviewItem('UP主回复', '源码在简介里哦~', false)
              }
            }
            .width('100%')
            .padding(this.cardMargin)
            .backgroundColor(this.getPreviewVideoCardBg())
            .border(this.getPreviewVideoCardBorder())
            .borderRadius(this.cardBorderRadius)
            .margin({ top: this.cardMargin })
          }
        }
        .width('100%')
        .padding(this.cardMargin)
      }
      .width('100%')
      .height(360)
      .borderRadius(12)
      .clip(true)
      .margin({ top: 8 })
    }
    .margin({ bottom: 12 })
  }

  private getPreviewVideoCardBg(): string {
    if (this.cardCustomColor && this.cardCustomColor !== '#007DFF') {
      if (this.cardTransparentStyleVideo) {
        return '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1);
      }
      return this.cardCustomColor;
    }
    if (this.cardTransparentStyleVideo) {
      return this.isDarkMode
        ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
        : `rgba(255,255,255,${this.cardBgOpacity / 100})`;
    }
    return this.isDarkMode ? '#2C2C2C' : '#E8E8E8';
  }

  private getPreviewVideoCardBorder(): BorderOptions {
    if (this.cardTransparentStyleVideo) {
      return {
        width: this.cardBorderWidth,
        color: this.cardBorderFollowTheme
          ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1))
          : (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)')
      };
    }
    return { width: 0, color: Color.Transparent };
  }

  @Builder CommentPreviewItem(name: string, text: string, isLast: boolean) {
    Row() {
      Circle().width(24).height(24).fill(this.isDarkMode ? '#555555' : '#CCCCCC')
      Column() {
        Text(name).fontSize(11).fontColor('#FB7299').maxLines(1)
        Text(text).fontSize(11).fontColor(Color.White).opacity(0.8).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .margin({ left: 8 })
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: isLast ? 0 : 8 })
  }

  @Builder ModeChip(label: string, mode: string) {
    Column() {
      Text(label)
        .fontSize(14)
        .fontColor(this.videoBgMode === mode ?
          (this.isDarkMode ? Color.White : '#007DFF') :
          (this.isDarkMode ? '#CCCCCC' : '#666666'))
        .fontWeight(this.videoBgMode === mode ? FontWeight.Medium : FontWeight.Regular)
    }
    .layoutWeight(1)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .borderRadius(10)
    .margin({ right: 6 })
    .backgroundColor(this.videoBgMode === mode ?
      (this.isDarkMode ? 'rgba(0,125,255,0.25)' : 'rgba(0,125,255,0.12)') :
      (this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.06)'))
    .onClick(() => {
      AppStorage.set('videoBgMode', mode);
      this.savePrefs('videoBgMode', mode);
    })
    .clickEffect({ level: 0, scale: 0.96 })
  }

  /** ⭐ 评论区文字布局二选一 chip（左对齐/居中） */
  @Builder CommentAlignChip(label: string, mode: string) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(this.cardStyleVideoCommentAlign === mode ?
          (this.isDarkMode ? Color.White : '#007DFF') :
          (this.isDarkMode ? '#CCCCCC' : '#666666'))
        .fontWeight(this.cardStyleVideoCommentAlign === mode ? FontWeight.Medium : FontWeight.Regular)
    }
    .layoutWeight(1)
    .height(28)
    .justifyContent(FlexAlign.Center)
    .borderRadius(8)
    .margin({ right: 6 })
    .backgroundColor(this.cardStyleVideoCommentAlign === mode ?
      (this.isDarkMode ? 'rgba(0,125,255,0.25)' : 'rgba(0,125,255,0.12)') :
      (this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.06)'))
    .onClick(() => {
      AppStorage.set('cardStyleVideoCommentAlign', mode);
      this.savePrefs('cardStyleVideoCommentAlign', mode);
    })
    .clickEffect({ level: 0, scale: 0.96 })
  }
}
