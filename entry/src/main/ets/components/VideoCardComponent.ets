// VideoCardComponent.ets - 可复用的视频卡片组件
import { RecommendItem } from '../model/RecommendItem';
import { formatPlayCountText, getPlayCountDisplayColor } from '../utils/PlayCountStyle';

@Reusable
@Component
export struct VideoCardComponent {
  @Prop item: RecommendItem = new RecommendItem();
  onCardClick?: (item: RecommendItem) => void;
  onLongPress?: (item: RecommendItem) => void;

  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = false;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 40;
  @StorageLink('cardBorderFollowPlayCount') cardBorderFollowPlayCount: boolean = false;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1.5;
  @StorageLink('cardCustomColor') cardCustomColor: string = '';
  @StorageLink('cardCapsuleFollowTheme') cardCapsuleFollowTheme: boolean = false;
  @StorageLink('cardCapsuleShow') cardCapsuleShow: boolean = true;
  @StorageLink('cardCapsuleSize') cardCapsuleSize: number = 12;
  @StorageLink('cardCapsuleRadius') cardCapsuleRadius: number = 7;
  @StorageLink('cardCapsuleColor') cardCapsuleColor: string = '';
  @StorageLink('cardPlayCountShow') cardPlayCountShow: boolean = true;
  @StorageLink('cardPlayCountUnit') cardPlayCountUnit: string = 'wanYi';
  @StorageLink('cardPlayCountSize') cardPlayCountSize: number = 12;
  @StorageLink('cardPlayCountColorMode') cardPlayCountColorMode: string = 'level';
@StorageLink('cardPlayCountIcon') cardPlayCountIcon: boolean = true;
  @StorageLink('cardPlayCountColor') cardPlayCountColor: string = '';
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  @StorageLink('cardListMargin') cardListMargin: number = 0;
  @StorageLink('da') da: boolean = false;
  // ⭐ 长按菜单变形期间被浮层接管的封面 id（隐藏源封面避免双影）
  @StorageLink('morphActiveCoverId') morphActiveCoverId: string = '';

  aboutToReuse(params: Record<string, Object>): void {
    if (params.item) {
      this.item = params.item as RecommendItem;
    }
  }

  build() {
    Column() {
      Image(this.item.coverUrl)
        .width('100%')
        .aspectRatio(16 / 9)
        .objectFit(ImageFit.Cover)
        .borderRadius(this.cardListBorderRadius)
        .backgroundColor('#E0E0E0')
        .draggable(false)
        .id(`cover_${this.item.id}`)
        // ⭐ 长按菜单浮层接管封面变形期间隐藏源封面（占位保持布局），
        //    浮层初始位置/尺寸/圆角与源完全重合 → 无缝交换
        .visibility(this.item.id === this.morphActiveCoverId ? Visibility.Hidden : Visibility.Visible)
        .onComplete(() => {
          // 封面加载完成，在原 HomePage 中会调用 releaseDecodeSlot
        })
        .onError(() => {
          // 封面加载失败
        })
        .sharedTransition(`videoCover_${this.item.id}`, this.da ? { duration: 0 } : {
          duration: 350,
          curve: Curve.EaseOut
        })
      Column() {
        Text(this.item.title)
          .fontSize(14).fontColor(this.isDarkMode ? Color.White : Color.Black)
          .width('100%').margin({ bottom: 6 })
        Row() {
          Text(this.item.ownerName)
            .fontSize(this.cardCapsuleShow ? this.cardCapsuleSize : 12)
            .fontColor(this.cardCapsuleShow
              ? ((this.cardCapsuleColor || this.cardCapsuleFollowTheme)
                ? (this.isDarkMode ? '#FFFFFF' : '#000000')
                : $r('app.color.color_primary_text'))
              : $r('app.color.color_primary_text'))
            .padding(this.cardCapsuleShow
              ? { left: 6, right: 6, top: 4, bottom: 4 }
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
            Row() {
              Text(formatPlayCountText(this.item.playCount, this.cardPlayCountUnit) + '播放')
                .fontSize(this.cardPlayCountSize)
                .fontColor(getPlayCountDisplayColor(this.item.playCount,
                  this.cardPlayCountColorMode, this.cardPlayCountColor, this.customThemeColor, this.isDarkMode))
              if (this.cardPlayCountIcon) {
                Image($r('app.media.play_fill'))
                  .width(20)
                  .height(20)
                  .objectFit(ImageFit.Contain)
                  .margin({ left: 4 })
                  .fillColor(getPlayCountDisplayColor(this.item.playCount,
                    this.cardPlayCountColorMode, this.cardPlayCountColor, this.customThemeColor, this.isDarkMode))
              }
            }
            .alignItems(VerticalAlign.Center)
            .height(20)
            .flexShrink(0)
          }
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .width('100%')
      .padding(8)
      .backgroundColor('transparent')
    }
    .width('100%')
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
        ? (this.cardBorderFollowPlayCount
          ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.getPlayCountColor(this.item.playCount).slice(1))
          : (this.cardBorderFollowTheme
            ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1))
            : (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)')))
        : Color.Transparent })
    .borderRadius(this.cardListBorderRadius).clip(true)
    .shadow({ radius: 4, color: '#10000000', offsetY: 2 })
    .clickEffect({ level: 0, scale: 0.9 })
    .onClick(() => {
      if (this.onCardClick) {
        this.onCardClick(this.item);
      }
    })
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          if (this.onLongPress) {
            this.onLongPress(this.item);
          }
        })
    )
    .width('100%')
  }

  formatCount(count: number): string {
    if (count >= 100000000) return (count / 100000000).toFixed(1) + '亿';
    if (count >= 10000) return (count / 10000).toFixed(1) + '万';
    return count.toString();
  }

  getPlayCountColor(count: number): string {
    if (count >= 10000000) return '#FF0000';
    if (count >= 3000000) return '#C2185B';
    if (count >= 1000000) return '#E65100';
    if (count >= 500000) return '#FF8C00';
    if (count >= 100000) return '#FFB800';
    if (count >= 50000) return '#4A90D9';
    return '#999999';
  }

  opacityToHexAlpha(opacity: number): string {
    const val = Math.round(opacity / 100 * 255);
    const hex = val.toString(16);
    return hex.length === 1 ? '0' + hex : hex;
  }
}
