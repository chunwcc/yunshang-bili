import { ObservableDynLike } from '../model/ObservableDynLike';
import { fmtCount } from '../utils/NumberFormat';
import { themeHexAlpha } from '../utils/ThemeColor';

/**
 * 动态点赞胶囊（可点）
 *
 * ⭐ 状态通过 `@ObjectLink like` 读取：**只有本组件**会在点赞变化时刷新，
 *    卡片其余部分（封面 Image 等）不会被重建 —— 这是"点赞导致封面闪一下"的修法。
 *    ⚠️ like 必须是页面长期持有的同一个对象实例（页面用 Map 缓存，见 DynamicsPage.likeStateOf），
 *    不能在 build 里 new 一个新对象传进来，否则 @ObjectLink 的绑定会每次都换。
 */
@Component
export struct DynLikePill {
  @ObjectLink like: ObservableDynLike;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  /** 点击回调由页面提供（页面负责登录校验、调接口、失败回滚） */
  onToggle?: () => void;

  build() {
    Row({ space: 4 }) {
      Image($r('app.media.give_the_thumbs_up'))
        .width(16).height(16)
        .fillColor(this.like.liked ? this.customThemeColor : (this.isDarkMode ? '#FFFFFF' : '#000000'))
      Text(fmtCount(this.like.count))
        .fontSize(11)
        .fontColor(this.like.liked ? this.customThemeColor : (this.isDarkMode ? '#E5E5E5' : '#333333'))
    }
    .padding({ left: 12, right: 12, top: 5, bottom: 5 })
    .borderRadius(16)
    .backgroundColor(this.like.liked
      ? themeHexAlpha(this.customThemeColor, 14)
      : (this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)'))
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .onClick(() => {
      if (this.onToggle) this.onToggle();
    })
  }
}
