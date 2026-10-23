// CarouselSheet.ets - 首页轮播设置弹窗

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

@Component
export struct CarouselSheet {
  onClose?: () => void;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('showHomeCarouselPortrait') showHomeCarouselPortrait: boolean = true;
  @StorageLink('showHomeCarouselLandscape') showHomeCarouselLandscape: boolean = true;
  @StorageLink('showCarouselBgPortrait') showCarouselBgPortrait: boolean = true;
  @StorageLink('showCarouselBgLandscape') showCarouselBgLandscape: boolean = true;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';

  @State carouselExpanded: boolean = false;

  private async savePrefs(key: string, value: Object): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put(key, value);
      await pref.flush();
    } catch (_) {}
  }

  private getLandscapeCols(): number {
    return AppStorage.get<number>('homeColumnCountLandscape') ?? 3;
  }

  build() {
    Column() {
      // ── 标题栏 ──
      Row() {
        Text('首页轮播')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Blank()
        Image($r('app.media.ic_public_albums'))
          .width(24).height(24)
          .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
      }
      .width('100%').height(44)
      .margin({ bottom: 8 })

      // ── 可折叠轮播选项 ──
      Column() {
        // ── 折叠头 ──
        Row() {
          Row() {
            Image($r('app.media.ic_public_albums'))
              .width(24).height(24)
              .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
              .margin({ right: 14 })
            Text('轮播选项')
              .fontSize(15)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .fontWeight(FontWeight.Medium)
            Blank()
            Image($r('app.media.ic_public_arrow_left_filled'))
              .width(20).height(20)
              .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
              .rotate({ angle: this.carouselExpanded ? 90 : -90 })
              .animation({ duration: 200, curve: Curve.FastOutSlowIn })
          }
          .width('100%')
          .height(48)
          .padding({ left: 14, right: 14 })
        }
        .width('100%')
        .height(48)
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(20)
        .padding({ left: 14, right: 14 })
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
        .margin({ bottom: 12 })
        .onClick(() => {
          this.carouselExpanded = !this.carouselExpanded;
        })

        // ── 展开后的 4 个选项 ──
        if (this.carouselExpanded) {
          // 竖屏轮播图
          this.ToggleItem(
            '竖屏轮播图',
            $r('app.media.ic_public_devices_phone_filled'),
            this.showHomeCarouselPortrait,
            (value: boolean) => {
              AppStorage.set('showHomeCarouselPortrait', value);
              this.savePrefs('showHomeCarouselPortrait', value);
            }
          )

          // 竖屏轮播背景
          this.ToggleItem(
            '竖屏轮播背景',
            $r('app.media.ic_settings_wallpaper'),
            this.showCarouselBgPortrait,
            (value: boolean) => {
              AppStorage.set('showCarouselBgPortrait', value);
              this.savePrefs('showCarouselBgPortrait', value);
            }
          )

          // 横屏轮播图
          this.ToggleItem(
            '横屏轮播图',
            $r('app.media.ic_public_devices_phone_filled'),
            this.showHomeCarouselLandscape,
            (value: boolean) => {
              AppStorage.set('showHomeCarouselLandscape', value);
              this.savePrefs('showHomeCarouselLandscape', value);
            },
            true
          )

          // 横屏轮播背景
          this.ToggleItem(
            '横屏轮播背景',
            $r('app.media.ic_settings_wallpaper'),
            this.showCarouselBgLandscape,
            (value: boolean) => {
              AppStorage.set('showCarouselBgLandscape', value);
              this.savePrefs('showCarouselBgLandscape', value);
            }
          )
        }
      }

      // ── 横屏布局（轮播开启时可选2列/3列） ──
      Row() {
        Text('横屏布局')
          .fontSize(15)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .fontWeight(FontWeight.Medium)
        Blank()
        Row({ space: 8 }) {
          ForEach([2, 3], (col: number) => {
            Column() {
              Text(`${col}列`)
                .fontSize(13)
                .fontColor(col === this.getLandscapeCols()
                  ? '#FFFFFF' : this.isDarkMode ? '#BBBBBB' : '#666666')
                .fontWeight(col === this.getLandscapeCols()
                  ? FontWeight.Bold : FontWeight.Normal)
            }
            .width(48).height(32)
            .borderRadius(8)
            .backgroundColor(col === this.getLandscapeCols()
              ? this.customThemeColor : (this.isDarkMode ? 'rgba(255,255,255,0.30)' : 'rgba(0,0,0,0.06)'))
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              AppStorage.set('homeColumnCountLandscape', col);
              this.savePrefs('homeColumnCountLandscape', col);
            })
          })
        }
      }
      .width('100%')
      .height(48)
      .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
      .borderRadius(20)
      .padding({ left: 14, right: 14 })
      .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      .margin({ bottom: 12 })
    }
    .width('100%')
    .padding(16)
  }

  @Builder
  ToggleItem(title: string, icon: Resource, isOn: boolean, onChange: (isOn: boolean) => void, rotateIcon: boolean = false) {
    Row() {
      Image(icon)
        .width(24).height(24)
        .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
        .margin({ right: 14 })
        .rotate({ angle: rotateIcon ? 90 : 0 })
      Text(title)
        .fontSize(15)
        .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .flexShrink(1)
      Blank()
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
}
