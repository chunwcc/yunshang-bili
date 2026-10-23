import { ObservableComment } from '../model/ObservableComment';
import { CommentContentRenderer } from './CommentContentRenderer';
import { fmtCount } from '../utils/NumberFormat';
import { themeHexAlpha } from '../utils/ThemeColor';

/** 相对时间（评论没有独立的时间工具，与动态用同一套规则） */
function timeAgo(ts: number): string {
  if (ts <= 0) return '';
  const diff = Math.floor(Date.now() / 1000) - ts;
  if (diff < 60) return '刚刚';
  if (diff < 3600) return `${Math.floor(diff / 60)}分钟前`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}小时前`;
  if (diff < 2592000) return `${Math.floor(diff / 86400)}天前`;
  if (diff < 31536000) return `${Math.floor(diff / 2592000)}个月前`;
  return `${Math.floor(diff / 31536000)}年前`;
}

/** B 站等级色（与评论条目组件同款取值） */
function levelBg(level: number): string {
  if (level <= 0) return '#C0C0C0';
  if (level <= 3) return '#7BC97B';
  if (level <= 5) return '#5DCAA5';
  return '#E24B4A';
}

/**
 * 气泡式评论行（聊天窗语言）
 *
 * ⭐ 与 `CommentItemComponent` 的关系：
 *   - **正文渲染复用同一个 `CommentContentRenderer`**（表情/图片/富文本都在里面，不存在两份实现）；
 *   - 这里只是**不同的版式**：播放页评论是"居中昵称 + 无气泡"，本组件是"左侧气泡 + 缩进二级回复"，
 *     是刻意的两套外观，不是同款副本。若哪天播放页也要气泡，把本组件参数化复用即可。
 *
 * ⚠️ 边距约定：组件**不含任何外部 margin**（宽度 100%，内边距自带），
 *    左右留白由调用方的容器 padding 决定 —— 避免再踩"外层 padding + 组件自带 margin 叠加溢出"的坑。
 */
@Component
export struct CommentBubble {
  @ObjectLink comment: ObservableComment;
  /** 0 = 一级评论；1 = 二级回复（缩进 + 浅底气泡 + 隐藏昵称行） */
  @Prop depth: number = 0;
  /** 正文里单图适配框（0 = 不启用，评论图按原比例缩进） */
  @Prop picBoxW: number = 0;
  @Prop picBoxH: number = 0;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';

  /** 展开/收起二级回复 */
  onToggleReplies?: (c: ObservableComment) => void;
  /** 加载更多二级回复 */
  onLoadMoreReplies?: (c: ObservableComment) => void;
  /** 回复这条评论（页面据此设置输入条目标） */
  onReply?: (c: ObservableComment) => void;
  /** 点赞/取消（页面负责调接口与乐观更新） */
  onLike?: (c: ObservableComment) => void;

  build() {
    Row() {
      // 头像（二级回复更小）
      Image(this.comment.member?.avatar ?? '')
        .width(this.depth === 0 ? 30 : 22)
        .height(this.depth === 0 ? 30 : 22)
        .borderRadius(this.depth === 0 ? 15 : 11)
        .objectFit(ImageFit.Cover)
        .backgroundColor('#E8E8E8')
        .flexShrink(0)

      Column() {
        // 昵称行（二级回复不重复昵称行，靠缩进 + 浅底区分层级）
        if (this.depth === 0) {
          Row() {
            Text(this.comment.member?.uname ?? '')
              .fontSize(12)
              .fontColor(this.isDarkMode ? '#CCCCCC' : '#666666')
              .maxLines(1)
            Text(`LV${this.comment.member?.level_info?.current_level ?? 0}`)
              .fontSize(9)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .backgroundColor(levelBg(this.comment.member?.level_info?.current_level ?? 0))
              .borderRadius(3)
              .padding({ left: 3, right: 3, top: 1, bottom: 1 })
              .margin({ left: 5 })
            if (this.comment.ipLocation !== '') {
              Text(this.comment.ipLocation)
                .fontSize(10)
                .fontColor(this.isDarkMode ? '#888888' : '#AAAAAA')
                .margin({ left: 6 })
            }
          }
          .width('100%')
          .margin({ bottom: 6 })
        }

        // 气泡本体
        Column() {
          CommentContentRenderer({
            content: this.comment.content,
            fontSize: 14,
            textColor: this.isDarkMode ? '#FFFFFF' : '#000000',
            maxLines: 999,
            thumbIdPrefix: `bub_${this.comment.rpid}`,
            picBoxW: this.picBoxW,
            picBoxH: this.picBoxH
          })
            .width('100%')
        }
        .width('100%')
        .padding({ left: 11, right: 11, top: 9, bottom: 9 })
        .borderRadius({ topLeft: 4, topRight: 14, bottomLeft: 14, bottomRight: 14 })
        .backgroundColor(this.depth === 0
          ? (this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.92)')
          : (this.isDarkMode ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.045)'))

        // 操作行：时间 · 已赞计数 · 回复 · 展开回复
        Row() {
          Text(timeAgo(this.comment.ctime))
            .fontSize(11)
            .fontColor(this.isDarkMode ? '#888888' : '#AAAAAA')

          if (this.comment.like > 0 || this.comment.action === 1) {
            Row() {
              Image($r('app.media.ic_public_thumbsup_filled'))
                .width(13)
                .height(13)
                .fillColor(this.comment.action === 1 ? this.customThemeColor
                  : (this.isDarkMode ? '#888888' : '#AAAAAA'))
                .margin({ right: 3 })
              Text(fmtCount(this.comment.like))
                .fontSize(11)
                .fontColor(this.comment.action === 1 ? this.customThemeColor
                  : (this.isDarkMode ? '#888888' : '#AAAAAA'))
            }
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(11)
            .backgroundColor(this.comment.action === 1
              ? themeHexAlpha(this.customThemeColor, 14)
              : (this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)'))
            .margin({ left: 10 })
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => { if (this.onLike) this.onLike(this.comment); })
          }

          Text('回复')
            .fontSize(11)
            .fontColor(this.isDarkMode ? '#CCCCCC' : '#666666')
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .borderRadius(11)
            .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.05)')
            .margin({ left: 8 })
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => { if (this.onReply) this.onReply(this.comment); })

          if (this.depth === 0 && this.comment.rcount > 0) {
            Row() {
              if (this.comment.loadingReplies) {
                LoadingProgress().width(12).height(12).color(this.customThemeColor)
              } else {
                Text(this.comment.expanded
                  ? '收起回复'
                  : `展开 ${fmtCount(this.comment.rcount)} 条回复`)
                  .fontSize(11)
                  .fontColor(this.customThemeColor)
              }
            }
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .borderRadius(11)
            .backgroundColor(themeHexAlpha(this.customThemeColor, 12))
            .margin({ left: 8 })
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => { if (this.onToggleReplies) this.onToggleReplies(this.comment); })
          }

          Blank()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 7 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 9 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    // ⚠️ 必须一次写全（同名属性后写会覆盖前面的）：上下 10 + 二级回复整体缩进 39（挂在父评论下面）
    .padding({ top: 10, bottom: 10, left: this.depth === 0 ? 0 : 39 })
  }
}
