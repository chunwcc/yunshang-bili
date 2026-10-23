import { common } from '@kit.AbilityKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { applyWallpaperMode, persistWallpaperMode } from '../utils/WallpaperTheme';

@Component
export struct WallpaperSelectPage {
  onClose?: () => void;
  @StorageLink('wallpaper') wallpaper: string = 'builtin';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperColor') wallpaperColor: string = '#007DFF';
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @State showContent: boolean = false;
  @State showColorPicker: boolean = false;
  /** 当前编辑的模式：light / dark（与系统深浅模式独立） */
  @State wallpaperMode: string = 'light';

  private presetColors: string[] = [
    '#FFFFFF', '#000000',
    '#007DFF', '#00C853', '#FF6D00', '#E91E63',
    '#9C27B0', '#FFD600', '#00BCD4', '#795548',
    '#F44336', '#3F51B5', '#009688', '#FF5722'
  ];

  aboutToAppear(): void {
    // 打开时默认编辑当前系统深浅模式对应的壁纸
    this.wallpaperMode = this.isDarkMode ? 'dark' : 'light';
    setTimeout(() => { this.showContent = true; }, 50);
  }

  aboutToDisappear(): void {
    // 关闭时恢复当前系统模式的壁纸，避免设置页临时编辑的另一模式泄漏到主界面
    applyWallpaperMode(this.isDarkMode);
  }

  /**
   * 切换编辑模式：先把当前激活值持久化到旧模式存档，再装载目标模式存档为激活值
   */
  private async switchMode(target: string): Promise<void> {
    if (target === this.wallpaperMode) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const dataPreferences = await preferences.getPreferences(context, 'my_app_settings');
      await persistWallpaperMode(this.wallpaperMode === 'dark', dataPreferences);
      this.wallpaperMode = target;
      applyWallpaperMode(target === 'dark');
    } catch (err) {
      logError(`切换壁纸模式失败: ${err}`);
    }
  }

  private getDefaultColor(): string {
    return this.isDarkMode ? '#121212' : '#FFFFFF';
  }

  private async saveWallpaperSettings(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const dataPreferences = await preferences.getPreferences(context, 'my_app_settings');
      await dataPreferences.put('wallpaper', this.wallpaper);
      await dataPreferences.put('customWallpaper', this.customWallpaper);
      await dataPreferences.put('wallpaperColor', this.wallpaperColor);
      await dataPreferences.put('customThemeColor', this.customThemeColor);
      await dataPreferences.put('wallpaperBlur', this.wallpaperBlur);
      await dataPreferences.put('wallpaperDarkness', this.wallpaperDarkness);
      // 同步持久化当前编辑模式的独立存档
      await persistWallpaperMode(this.wallpaperMode === 'dark', dataPreferences);
      await dataPreferences.flush();
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
      AppStorage.set('wallpaper', 'custom');
      AppStorage.set('customWallpaper', destUri);
      await this.saveWallpaperSettings();
      this.getUIContext().getPromptAction().showToast({ message: '壁纸已更换' });
    } catch (error) {
      const err = error as BusinessError;
      this.getUIContext().getPromptAction().showToast({ message: `失败: ${err.message}` });
    }
  }

  private async resetToDefault(): Promise<void> {
    this.wallpaper = 'builtin';
    this.customWallpaper = '';
    AppStorage.set('wallpaper', 'builtin');
    AppStorage.set('customWallpaper', '');
    await this.saveWallpaperSettings();
    this.getUIContext().getPromptAction().showToast({ message: '已恢复默认壁纸' });
  }

  private async selectColor(color: string): Promise<void> {
    this.wallpaper = 'custom_color';
    this.wallpaperColor = color;
    AppStorage.set('wallpaper', 'custom_color');
    AppStorage.set('wallpaperColor', color);
    await this.saveWallpaperSettings();
    this.getUIContext().getPromptAction().showToast({ message: '已设为颜色壁纸' });
  }

  private closeSheet(): void {
    this.onClose?.();
  }

  build() {
    Row() {
      // ── 左侧：竖向预览图 ──
      Stack() {
        // 底层：壁纸或默认背景
        if (this.wallpaper === 'builtin') {
          Image(this.isDarkMode ? $r('app.media.wallpaper_shen') : $r('app.media.wallpaper_qian'))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
        } else if (this.wallpaper === 'custom' && this.customWallpaper) {
          Image('file://' + this.customWallpaper)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .blur(this.wallpaperBlur)
        } else if (this.wallpaper === 'custom_color') {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.wallpaperColor)
        } else {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.getDefaultColor())
        }
        // 叠加层：明暗调节（<50 变黑，>50 变白，50 为原始）
        if (this.wallpaperDarkness < 50) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(`rgba(0, 0, 0, ${(50 - this.wallpaperDarkness) / 50})`)
        } else if (this.wallpaperDarkness > 50) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(`rgba(255, 255, 255, ${(this.wallpaperDarkness - 50) / 50})`)
        }
      }
      .layoutWeight(1)
      .height(230)
      .borderRadius(16)
      .clip(true)
      .margin({ right: 8 })

      // ── 右侧：控制选项（可滚动） ──
      if (this.showContent) {
        Scroll() {
          Column() {
            // ── 深色/浅色分段按钮：独立编辑两套壁纸 ──
            Row() {
              Text('浅色')
                .fontSize(13)
                .fontWeight(this.wallpaperMode === 'light' ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.wallpaperMode === 'light' ? Color.White : (this.isDarkMode ? '#CCCCCC' : '#555555'))
                .backgroundColor(this.wallpaperMode === 'light' ? this.customThemeColor : Color.Transparent)
                .borderRadius(8)
                .padding({ left: 16, right: 16, top: 5, bottom: 5 })
                .onClick(() => this.switchMode('light'))
              Text('深色')
                .fontSize(13)
                .fontWeight(this.wallpaperMode === 'dark' ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.wallpaperMode === 'dark' ? Color.White : (this.isDarkMode ? '#CCCCCC' : '#555555'))
                .backgroundColor(this.wallpaperMode === 'dark' ? this.customThemeColor : Color.Transparent)
                .borderRadius(8)
                .padding({ left: 16, right: 16, top: 5, bottom: 5 })
                .onClick(() => this.switchMode('dark'))
            }
            .padding(3)
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.06)')
            .borderRadius(12)
            .margin({ bottom: 16 })

            // ── 模糊 ──
          Column() {
            Text('模糊')
              .fontSize(13)
              .fontColor(this.isDarkMode ? '#CCCCCC' : '#555555')
              .width('100%')
            Row() {
              Image($r('app.media.arrow_clockwise'))
                .width(18).height(18)
                .margin({ right: 8 })
                .fillColor(this.customThemeColor)
                .onClick(() => {
                  this.wallpaperBlur = 0;
                  AppStorage.set('wallpaperBlur', 0);
                  this.saveWallpaperSettings();
                })
              Slider({
                value: this.wallpaperBlur,
                min: 0,
                max: 150,
                step: 1,
                style: SliderStyle.InSet
              })
                .layoutWeight(1)
                .trackColor(this.isDarkMode ? '#444444' : '#E8E8E8')
                .selectedColor(this.customThemeColor)
                .blockColor(this.customThemeColor)
                .onChange((value: number) => {
                  this.wallpaperBlur = value;
                  AppStorage.set('wallpaperBlur', value);
                  this.saveWallpaperSettings();
                })
              Text(`${Math.round(this.wallpaperBlur)}`)
                .fontSize(13)
                .fontColor(this.customThemeColor)
                .fontWeight(FontWeight.Medium)
                .width(28)
                .textAlign(TextAlign.End)
            }
            .width('100%')
          }
          .width('100%')
          .margin({ bottom: 16 })

          // ── 明暗 ──
          Column() {
            Text('明暗')
              .fontSize(13)
              .fontColor(this.isDarkMode ? '#CCCCCC' : '#555555')
              .width('100%')
            Row() {
              Image($r('app.media.arrow_clockwise'))
                .width(18).height(18)
                .margin({ right: 8 })
                .fillColor(this.customThemeColor)
                .onClick(() => {
                  this.wallpaperDarkness = 50;
                  AppStorage.set('wallpaperDarkness', 50);
                  this.saveWallpaperSettings();
                })
              Slider({
                value: this.wallpaperDarkness,
                min: 0,
                max: 100,
                step: 1,
                style: SliderStyle.InSet
              })
                .layoutWeight(1)
                .trackColor(this.isDarkMode ? '#444444' : '#E8E8E8')
                .selectedColor(this.customThemeColor)
                .blockColor(this.customThemeColor)
                .onChange((value: number) => {
                  this.wallpaperDarkness = value;
                  AppStorage.set('wallpaperDarkness', value);
                  this.saveWallpaperSettings();
                })
              Text(`${Math.round(this.wallpaperDarkness)}`)
                .fontSize(13)
                .fontColor(this.customThemeColor)
                .fontWeight(FontWeight.Medium)
                .width(28)
                .textAlign(TextAlign.End)
            }
            .width('100%')
          }
          .width('100%')
          .margin({ bottom: 20 })

          // ── 颜色选择器（可折叠） ──
          Column() {
            Row() {
              Text('颜色壁纸')
                .fontSize(13)
                .fontColor(this.isDarkMode ? '#CCCCCC' : '#555555')
              Blank()
              Text(this.showColorPicker ? '收起' : '展开')
                .fontSize(12)
                .fontColor(Color.White)
                .backgroundColor(this.customThemeColor)
                .padding({ left: 12, right: 12, top: 3, bottom: 3 })
                .borderRadius(10)
            }
            .width('100%')
            .onClick(() => { this.showColorPicker = !this.showColorPicker; })

            if (this.showColorPicker) {
              // 预设色板
              Flex({
                wrap: FlexWrap.Wrap,
                justifyContent: FlexAlign.SpaceBetween
              }) {
                ForEach(this.presetColors, (color: string) => {
                  Stack() {
                    Circle()
                      .width(32).height(32)
                      .fill(color)
                      .stroke(this.wallpaper === 'custom_color' && this.wallpaperColor === color ?
                        (this.isDarkMode ? Color.White : '#333333') : Color.Transparent)
                      .strokeWidth(2.5)
                    if (this.wallpaper === 'custom_color' && this.wallpaperColor === color) {
                      Text('✓')
                        .fontSize(14)
                        .fontColor(this.isDarkMode ? Color.White : '#333333')
                        .fontWeight(FontWeight.Bold)
                    }
                  }
                  .width(36).height(36)
                  .margin({ right: 8, bottom: 8 })
                  .onClick(() => this.selectColor(color))
                })
              }
              .width('100%')
              .margin({ top: 8 })
            }
          }
          .width('100%')
          .margin({ bottom: 16 })

          // ── 按钮区 ──
          Column() {
            Button('从相册选择')
              .width('100%')
              .height(40)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .backgroundColor(this.customThemeColor)
              .fontColor(Color.White)
              .borderRadius(10)
              .onClick(() => this.pickImageFromAlbum())
              .clickEffect({ level: 0, scale: 0.96 })

            Button('恢复默认')
              .width('100%')
              .height(40)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.04)')
              .fontColor('#999999')
              .borderRadius(10)
              .margin({ top: 8 })
              .onClick(() => this.resetToDefault())
              .clickEffect({ level: 0, scale: 0.96 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Start)
      }
      .layoutWeight(1)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
    }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .backgroundColor(this.isDarkMode ? '#1A1A1A' : '#F5F5F5')
    .opacity(this.showContent ? 1 : 0)
    .animation({ duration: 280, curve: Curve.EaseOut })
  }
}
