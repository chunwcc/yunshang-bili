import { DynTextSegment } from '../api/BilibiliApi';
import { themeRgba } from '../utils/ThemeColor';

/**
 * 动态正文渲染（文字 / B站表情图 / #话题#胶囊 / @某人 混排）
 *
 * ⭐ 抽成公共组件的原因：**动态流与动态详情页必须长得一模一样**。
 *    本工程历史上 `dynTextSegmentsBuilder` 在多个页面各有一份副本，
 *    改一处忘一处导致"同一条动态在两个页面表现不一致"，所以这里只保留一份实现。
 *
 * 交互（与动态流一致）：
 *   - `#话题#` / `@某人` 点击：走统一的路由入口（搜索页关键词 / UP 空间），组件内部自带，不需要调用方传回调。
 */
@Component
export struct DynamicTextContent {
  /** 正文分段（由 BilibiliApi 解析：含 emoji 的 emoteUrl、话题 kind='topic'、@ kind='at'） */
  @Prop segments: DynTextSegment[] = [];
  /** 是否整体居中（动态流的视频卡用居中，详情页用左对齐） */
  @Prop isCenter: boolean = false;
  @Prop bottomMargin: number = 0;
  /** 正文字号：详情页可以更大 */
  @Prop fontSize: number = 14;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';

  /** ⭐ 点击正文里的 #话题#：本工程没有话题详情页，带关键词进搜索页（与"长按选词→搜索"同一入口） */
  private openTopicTag(topicText: string): void {
    let kw: string = topicText;
    if (kw.startsWith('#')) kw = kw.substring(1);
    if (kw.endsWith('#')) kw = kw.substring(0, kw.length - 1);
    kw = kw.trim();
    if (!kw) return;
    this.getUIContext().getRouter().pushUrl({ url: 'pages/SearchPage', params: { keyword: kw } }).catch(() => {});
  }

  /** ⭐ 点击正文里的 @某人：进 TA 的空间（mid 来自富文本节点 rid，缺失就提示而不是静默无反应） */
  private openMentionedUp(seg: DynTextSegment): void {
    const mid: number = seg.mid ?? 0;
    if (mid <= 0) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开该用户主页', duration: 1500 });
      return;
    }
    let name: string = seg.text ?? '';
    if (name.startsWith('@')) name = name.substring(1);
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UpSpacePage',
      params: { mid: mid, upName: name, upFace: '' }
    }).catch(() => {});
  }

  build() {
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
      justifyContent: this.isCenter ? FlexAlign.Center : FlexAlign.Start }) {
      ForEach(this.segments, (seg: DynTextSegment, index: number) => {
        if (seg.emoteUrl) {
          Image(seg.emoteUrl)
            .width(20)
            .height(20)
            .margin({ left: 2, right: 2 })
            .objectFit(ImageFit.Contain)
        } else if (seg.kind === 'topic') {
          // #话题# → 胶囊：主题色文字 + 主题色 16% 底 + 小圆角；点击进搜索
          // ⭐ 高度收紧（12 号字 + 行高 16 + 上下 padding 1 = 胶囊仅 18vp）：胶囊过高时换行行距不够，
          //    相邻两行胶囊会互相压住（用户截图实证）；上下 margin 2 让换行行之间留出 4vp 间隙
          Text(seg.text)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.customThemeColor)
            .lineHeight(16)
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .margin({ left: 2, right: 2, top: 2, bottom: 2 })
            .borderRadius(5)
            .backgroundColor(themeRgba(this.customThemeColor, 0.16))
            .clickEffect({ level: 0, scale: 0.95 })
            .onClick(() => { this.openTopicTag(seg.text); })
        } else if (seg.kind === 'at') {
          // @某人 → 主题色 + Medium（比正文醒目，但不加底色，与话题胶囊区分开）；点击进 TA 的空间
          Text(seg.text)
            .fontSize(this.fontSize)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.customThemeColor)
            .lineHeight(20)
            .textAlign(this.isCenter ? TextAlign.Center : TextAlign.Start)
            .clickEffect({ level: 0, scale: 0.95 })
            .onClick(() => { this.openMentionedUp(seg); })
        } else {
          Text(seg.text)
            .fontSize(this.fontSize)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            .lineHeight(this.fontSize + 6)
            .textAlign(this.isCenter ? TextAlign.Center : TextAlign.Start)
        }
      }, (seg: DynTextSegment, index: number) => `dseg_${index}`)
    }
    .width('100%')
    .margin({ bottom: this.bottomMargin })
  }
}
