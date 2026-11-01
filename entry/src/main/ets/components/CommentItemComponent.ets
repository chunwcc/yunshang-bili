import { ObservableComment } from '../model/ObservableComment';
import { VideoDetail, setCommentLike } from '../api/BilibiliApi';
import { componentUtils } from '@kit.ArkUI';
import { ReplyItemComponent } from './ReplyItemComponent';
import { CommentContentRenderer } from './CommentContentRenderer';
import { TextSelectionDialog } from './TextSelectionDialog';
import { getCachedPixelMap } from '../utils/ImageCache';
import { measureTextLines } from '../utils/TextMeasure';
import { logWarn } from '../utils/Logger';
import { MaterialUtil } from '../utils/MaterialUtil';
import { VibrateUtils } from '../utils/VibrateUtils';

/**
 * Bilibili CDN 图片缩放辅助：在 URL 后追加 `@Ww` 参数缩放到指定宽度
 */
function avatarUrlResize(url: string, width: number): string {
  if (!url || !url.includes('hdslb.com')) {
    return url;
  }
  // ⚠️ 原实现 `!url.includes('@')`：URL 已带后缀时**整段跳过压缩** → 原图整张解码
  const at: number = url.indexOf('@');
  const base: string = (at > url.lastIndexOf('/') && url.indexOf('?') < 0) ? url.substring(0, at) : url;
  return base + `@${width}w`;
}

/**
 * 评论项组件 - 气泡式展开风格
 * 特点：
 * 1. 点击主评论展开回复
 * 2. 回复以气泡形式显示
 * 3. 气泡有圆角背景和缩进
 * 4. 连接线显示层级关系
 */
@Component
export struct CommentItemComponent {
  /** ⭐ 透传给 CommentContentRenderer 的单图适配框（内容宽 / 高度上限）；只有播放页评论区传非 0 */
  @Prop picBoxW: number = 0;
  @Prop picBoxH: number = 0;
  @ObjectLink comment: ObservableComment;
  @Prop isLast: boolean = false;
  @Prop videoDetail: VideoDetail | null = null;
  @Prop isExpanded: boolean = false;
  /**
   * 二级回复版本号 —— 这是回复列表**唯一的刷新通道**。
   * ⚠️ 血泪：原先 `@Watch('onRepliesVersionChange')` 挂在了 `isDarkMode` 上，而那个方法**根本不存在**，
   *    所以列表刷新一直只靠"ForEach 的 key 里拼版本号"（key 变 ⇒ 整列重建 ⇒ 头像重新解码会闪）。
   *    2026-09-18 把 key 改成稳定的 rpid 后刷新通道就断了：**数据加载了 3 页、20→40→56，界面纹丝不动**
   *    （用户："点击后还是没有展开更多回复"）。
   *    现在把 @Watch 挂到真正会变的 repliesVersion 上，回调里把数组**浅拷贝换引用**给 @State `replies_`，
   *    ForEach 仍用 rpid 做 key ⇒ **只创建新增项、已有项复用**：既刷新、又不闪。
   */
  @Prop @Watch('onRepliesVersionChange') repliesVersion: number = 0;
  /**
   * 条目左右外边距（vp）。
   * ⭐ 为什么要参数化：组件根节点是 `width('100%')` + 自带 margin，**只有当父容器是 List 时**
   *    交叉轴才会把 margin 算进去（播放页评论区就是 List）。
   *    在 `Scroll + Column` 里用（动态详情页）时，100% 宽 + margin 会超出父容器右侧被裁 ⇒ 左右不对称。
   *    ⇒ Scroll 场景请传 0，由外层容器给左右内边距（**两个只能给一处**）。
   */
  @Prop cardMarginVp: number = 12;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardTransparentStyleVideo') cardTransparentStyleVideo: boolean = false;
  @StorageLink('cardStyleVideoCommentBubble') cardStyleVideoCommentBubble: boolean = true;
  @StorageLink('cardStyleVideoCommentAlign') commentTextAlign: string = 'left';
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = false;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 40;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1.5;
  @StorageLink('cardCustomColor') cardCustomColor: string = '';
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('playerFollowTheme') playerFollowTheme: boolean = false;
  /** 二级回复列表的本地数据源（由 onRepliesVersionChange 换引用驱动，见 repliesVersion 注释） */
  @State replies_: ObservableComment[] = [];
  @State isTextExpanded: boolean = false;
  // ⭐ 长按文本选取弹窗：openCustomDialog 返回的对话框 id
  private commentSelDialogId_: number = -1
  /** ⭐ 评论文本实际容器宽度（vp，onAreaChange 实测；各布局宽度不同） */
  @State contentW: number = 0;
  @State topReplyAvatar: string = '';
  @State topReplyUname: string = '';
  @State topReplyMessage: string = '';
  @State hasTopReply: boolean = false;

  onExpandComment?: (comment: ObservableComment) => void;
  onCollapseComment?: (rpid: number) => void;
  onLoadMoreReplies?: (comment: ObservableComment) => void;
  onReplyTap?: (root: number, parent: number, targetName: string) => void;

  // ⚠️ 不使用 @Reusable（多次尝试后弃用）：本机 SDK 复用池中 @ObjectLink 绑定链无法可靠重建，
  //   嵌套子组件全部标记 @Reusable + aboutToReuse 后仍会间歇性显示上一条评论的配图/文本
  //   （2026-08-31 实测：滚动回收后配图与评论错位）。宁可销毁重建，不可复用出脏数据。

  aboutToAppear(): void {
    this.replies_ = this.comment.replies ? this.comment.replies.slice() : [];
    this.updateTopReply();
  }

  /**
   * 当 repliesVersion 变化时刷新（展开第一页 / 加载更多 / 点赞都会 ++repliesVersion）。
   *
   * ⭐ 两件事：① 换一次 `replies_` 的引用 —— 它是回复列表的数据源，ForEach 用 rpid 做 key，
   *    所以**只有新增项会被创建、已有项（含头像）原样复用**（既不"纹丝不动"、也不"整列重建闪头像"）；
   *    ② 重算"点赞最高的回复"预览。
   * ⚠️ 这段逻辑原先只挂在 `isDarkMode` 上（@Watch 挂错了变量）—— 所以回复列表的刷新一直靠
   *    ForEach 的 key 里拼版本号（整列重建）。2026-09-18 把 key 改稳定后列表就彻底不刷新了。
   */
  private onRepliesVersionChange(): void {
    this.replies_ = this.comment.replies ? this.comment.replies.slice() : [];
    this.updateTopReply();
  }

  /**
   * 点赞/取消点赞评论（乐观更新，失败回滚）
   */
  private async toggleCommentLike(): Promise<void> {
    const like = this.comment.action !== 1;
    const prevLike = this.comment.like;
    const prevAction = this.comment.action;
    this.comment.like = like ? this.comment.like + 1 : Math.max(0, this.comment.like - 1);
    this.comment.action = like ? 1 : 0;
    try { VibrateUtils.vibrateTime(10); } catch (_e) { /* ignore */ }
    const res = await setCommentLike(this.comment.oid, this.comment.rpid, like);
    if (res.ok) return;
    // ⭐ 失败回滚，保持展示与服务器一致
    this.comment.like = prevLike;
    this.comment.action = prevAction;
    this.getUIContext().getPromptAction().showToast({
      message: res.code === -101 ? '请先登录' : (res.message || '操作失败，请重试')
    });
  }

  /** 点击头像/昵称 → 打开评论用户的空间页 */
  private openUserSpace(): void {
    const mid = parseInt(this.comment.member?.mid ?? '', 10);
    if (!mid || isNaN(mid)) return;
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UpSpacePage',
      params: {
        mid: mid,
        upName: this.comment.member?.uname ?? '',
        upFace: this.comment.member?.avatar ?? ''
      }
    }).catch((err: Error) => {
      logWarn(`[CommentItem] 打开空间失败: ${err}`);
    });
  }

  // 从 replies 中找出点赞最高的回复，缓存到 topReplyData
  private updateTopReply(): void {
    if (!this.comment.replies || this.comment.replies.length === 0) {
      this.hasTopReply = false;
      return;
    }
    const best = this.comment.replies.reduce((best, r) => (r.like ?? 0) > ((best?.like ?? 0)) ? r : best, this.comment.replies[0]);
    if (best) {
      this.topReplyAvatar = best.member?.avatar ?? '';
      this.topReplyUname = best.member?.uname ?? '';
      this.topReplyMessage = best.content?.message ?? '';
      this.hasTopReply = true;
    } else {
      this.hasTopReply = false;
    }
  }

  /**
   * 判断是否需要"展开全文"按钮：按实测容器宽度测量真实行数，
   * 不同布局（竖屏/竖屏横看/横屏右栏）宽度不同，固定字符估算会误报
   */
  private shouldShowExpandButton(): boolean {
    const msg = this.comment.content?.message ?? '';
    if (!msg) return false;
    // ⭐ 容器宽度未就绪时保守不显示（宁可漏不错，避免"内容完整却有展开按钮"）
    if (this.contentW <= 0) return false;
    return measureTextLines(this.getUIContext(), msg, this.contentW, 13) > 8;
  }

  private formatTimeAgo(timestamp: number): string {
    const now = Date.now() / 1000;
    const diff = now - timestamp;

    if (diff < 60) return '刚刚';
    if (diff < 3600) return `${Math.floor(diff / 60)}分钟前`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}小时前`;
    if (diff < 2592000) return `${Math.floor(diff / 86400)}天前`;
    if (diff < 31536000) return `${Math.floor(diff / 2592000)}个月前`;
    return `${Math.floor(diff / 31536000)}年前`;
  }

  private getLevelBgColor(level: number): string {
    if (level >= 6) return '#FFD700'; // 金色 - 最高等级
    if (level >= 4) return '#4169E1'; // 皇家蓝 - 高等级
    if (level >= 2) return '#32CD32'; // 酸橙绿 - 中等
    return '#A9A9A9'; // 深灰色 - 低等级
  }

  private opacityToHexAlpha(opacity: number): string {
    const clamped = Math.max(0, Math.min(100, opacity));
    const hex = Math.round(clamped / 100 * 255).toString(16).toUpperCase();
    return hex.length < 2 ? '0' + hex : hex;
  }


  // ⭐ 评论长按文本选取弹窗（可选中 → 复制/搜索）
  @Builder
  textSelectDialog(title: string, text: string) {
    TextSelectionDialog({
      title: title,
      text: text,
      onSearchText: (keyword: string) => {
        if (this.commentSelDialogId_ >= 0) {
          this.getUIContext().getPromptAction().closeCustomDialog(this.commentSelDialogId_);
          this.commentSelDialogId_ = -1;
        }
        this.getUIContext().getRouter().pushUrl({
          url: 'pages/SearchPage',
          params: { keyword: keyword }
        }).catch((err: Error) => {
          logWarn(`[评论] 搜索页跳转失败: ${err}`);
        });
      }
    })
  }

  private showTextSelection(title: string, text: string) {
    if (!text || text.length === 0) return;
    this.getUIContext().getPromptAction().openCustomDialog({
      builder: () => {
        this.textSelectDialog(title, text);
      },
      autoCancel: true,
      // ⭐ 沉浸光感（官方"对话框通道"）：THICK 玻璃 + 无光效（复用面板材质配置）
      backgroundColor: Color.Transparent,
      systemMaterial: MaterialUtil.sheetMaterial()
    }).then((id: number) => {
      this.commentSelDialogId_ = id;
    }).catch((err: Error) => {
      logWarn(`[评论] 文本弹窗打开失败: ${err}`);
    });
  }

  build() {
    Column() {
      if (this.comment.rpid === 0) {
        // 空占位
      } else {
// 主评论内容 — 始终渲染
        Column() {
          // 头像 + 用户名 + LV + UP — 同一行
          Row() {
            Image(getCachedPixelMap(avatarUrlResize(this.comment.member?.avatar ?? '', 48)) ?? avatarUrlResize(this.comment.member?.avatar ?? '', 48))
              .width(20)
              .height(20)
              .borderRadius(10)
              .margin({ right: 6 })
              .onClick(() => { this.openUserSpace(); });

            Text(this.comment.member?.uname ?? '')
              .fontSize(12)
              .fontColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
              .maxLines(1);

            Text(`LV${this.comment.member?.level_info?.current_level ?? 0}`)
              .fontSize(10)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .backgroundColor(this.getLevelBgColor(this.comment.member?.level_info?.current_level ?? 0))
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ left: 6 });

            if (this.videoDetail && this.comment.member?.mid === this.videoDetail.owner.mid.toString()) {
              Text('UP')
                .fontSize(10)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
                .backgroundColor(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
                .borderRadius(3)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .margin({ left: 4 });
            }

            }
            .width('100%')
            .justifyContent(FlexAlign.Center);

          Column() {
            CommentContentRenderer({ content: this.comment.content, fontSize: 13, textColor: $r('app.color.color_player_text'), maxLines: this.isTextExpanded ? 999 : 8, isCenter: this.commentTextAlign === 'center', thumbIdPrefix: String(this.comment.rpid) , picBoxW: this.picBoxW, picBoxH: this.picBoxH })
              .margin({ top: 10 })
          }
          .width('100%')
          .gesture(LongPressGesture().onAction(() => {
            const msg = this.comment.content?.message ?? '';
            if (msg) {
              this.showTextSelection('文本工具 · 评论', msg);
            }
          }))
          .onAreaChange((_o: Area, n: Area) => {
            const w = n.width as number;
            if (w > 0 && Math.abs(w - this.contentW) > 1) {
              this.contentW = w;
            }
          });

          // 展开/收起全文按钮（超过8行时显示）
          if (this.shouldShowExpandButton()) {
            Row() {
              Text(this.isTextExpanded ? '收起' : '展开全文')
                .fontSize(12)
                .fontColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                .onClick(() => {
                  this.isTextExpanded = !this.isTextExpanded;
                })
                .hitTestBehavior(HitTestMode.Block)
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)
            .margin({ top: 4 });
          }

          // IP + 时间（· 分隔）— 左侧；回复按钮 + 点赞 — 右侧
          Row() {
            if (this.comment.ipLocation !== '') {
              Text(`IP : ${this.comment.ipLocation}`)
                .fontSize(11)
                .fontColor($r('app.color.color_player_text_secondary'))
                .margin({ right: 4 });
              Text('·')
                .fontSize(11)
                .fontColor($r('app.color.color_player_text_secondary'))
                .margin({ right: 4 });
            }
            Text(this.formatTimeAgo(this.comment.ctime))
              .fontSize(11)
              .fontColor($r('app.color.color_player_text_secondary'));
            Blank();
            // ⭐ 回复按钮（message.svg）：点击触发回复输入
            Image($r('app.media.message'))
              .width(16)
              .height(16)
              .fillColor($r('app.color.color_player_text_secondary'))
              .margin({ right: 12 })
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => {
                VibrateUtils.vibrateTime(10);
                this.onReplyTap?.(this.comment.rpid, this.comment.rpid, this.comment.member?.uname ?? '');
              })
            Row() {
              Image($r('app.media.ic_public_thumbsup_filled'))
                .width(14)
                .height(14)
                .fillColor(this.comment.action === 1
                  ? (this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                  : $r('app.color.color_player_text_secondary'))
                .margin({ right: 4 });
              Text(`${this.comment.like}`)
                .fontSize(11)
                .fontColor(this.comment.action === 1
                  ? (this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                  : $r('app.color.color_player_text_secondary'));
            }
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => { this.toggleCommentLike(); })
          }
          .width('100%')
          .margin({ top: 6 });

          // 回复数提示（有回复且未展开时，显示点赞最高的回复预览 + 回复数）
          if (this.comment.replies && this.comment.replies.length > 0 && !this.isExpanded) {
            Column() {
              // 点赞最高的回复预览（20vp圆角矩形包裹，仅两行）
              if (this.hasTopReply) {
                Column() {
                  // 头像 + 名称 同一行
                  Row() {
                    if (this.topReplyAvatar) {
                      Image(getCachedPixelMap(avatarUrlResize(this.topReplyAvatar, 48)) ?? avatarUrlResize(this.topReplyAvatar, 48))
                        .width(16).height(16).borderRadius(8)
                        .margin({ right: 4 });
                    }
                    Text(this.topReplyUname)
                      .fontSize(11)
                      .fontColor($r('app.color.color_player_text_secondary'))
                      .lineHeight(14);
                  }
                  .alignItems(VerticalAlign.Center);
                  // 回复内容（最多两行）
                  Text(this.topReplyMessage)
                    .fontSize(12)
                    .fontColor($r('app.color.color_player_text'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .lineHeight(16)
                    .width('100%')
                    .textAlign(TextAlign.Center);
                }
                .width('100%')
                .margin({ bottom: 10 })
                .padding({ left: 10, right: 10, top: 8, bottom: 12 })
                .backgroundColor(this.cardCustomColor && this.cardCustomColor !== '#007DFF'
                  ? (this.cardTransparentStyleVideo && this.cardStyleVideoCommentBubble
                    ? '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1)
                    : this.cardCustomColor)
                  : (this.cardTransparentStyleVideo && this.cardStyleVideoCommentBubble
                    ? (this.isDarkMode
                      ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
                      : `rgba(255,255,255,${this.cardBgOpacity / 100})`)
                    : 'rgba(0, 0, 0, 0.3)'))
                .border({ width: (this.cardTransparentStyleVideo && this.cardStyleVideoCommentBubble) ? this.cardBorderWidth : 0,
                  color: (this.cardTransparentStyleVideo && this.cardStyleVideoCommentBubble)
                    ? (this.cardBorderFollowTheme
                      ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1))
                      : (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)'))
                    : Color.Transparent })
                .borderRadius(20)
              }

              // "*条回复"
              Row() {
                Image($r('app.media.message'))
                  .width(14)
                  .height(14)
                  .fillColor($r('app.color.color_player_text_secondary'))
                  .margin({ right: 4 });
                Text(` ${this.comment.rcount || this.comment.replies.length}条回复`)
                  .fontSize(12)
                  .fontColor($r('app.color.color_player_text_secondary'));
              }
              .width('100%')
              .justifyContent(FlexAlign.Center);
            }
            .width('100%')
            .margin({ top: 6 });
          }
        }
        .width('100%')
        .margin({ top: 8, bottom: 8 })
        .padding({ left: 10, right: 10, top: 16, bottom: 16 })
        .backgroundColor(this.cardCustomColor && this.cardCustomColor !== '#007DFF'
          ? (this.cardTransparentStyleVideo && this.cardStyleVideoCommentBubble
            ? '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1)
            : this.cardCustomColor)
          : (this.cardTransparentStyleVideo && this.cardStyleVideoCommentBubble
            ? (this.isDarkMode
              ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
              : `rgba(255,255,255,${this.cardBgOpacity / 100})`)
            : $r('app.color.color_comment_bubble')))
        .border({ width: (this.cardTransparentStyleVideo && this.cardStyleVideoCommentBubble) ? this.cardBorderWidth : 0,
          color: (this.cardTransparentStyleVideo && this.cardStyleVideoCommentBubble)
            ? (this.cardBorderFollowTheme
              ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1))
              : (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)'))
            : Color.Transparent })
        .borderRadius(20)
        .onClick(() => {
          try { VibrateUtils.vibrateTime(10); } catch (_) {}
          if (this.isExpanded) {
            this.onCollapseComment?.(this.comment.rpid);
          } else {
            this.onExpandComment?.(this.comment);
          }
        });
      }

      // 回复区域（带展开/收起过渡动画）
      if (this.replies_.length > 0 && this.isExpanded) {
        Column() {
          // 顶部装饰线
          Row() {
            Column()
              .width(40)
              .height(2)
              .backgroundColor('rgba(251, 114, 153, 0.3)')
              .borderRadius(1);
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 4, bottom: 8 });

          // 气泡列表
          Column() {
            ForEach(this.replies_, (reply: ObservableComment, index: number) => {
              ReplyItemComponent({
                reply: reply,
                showDivider: false,
                videoDetail: this.videoDetail,
                depth: 0,
                onReplyTap: (parent: number, targetName: string) => {
                  this.onReplyTap?.(this.comment.rpid, parent, targetName);
                },
                onCollapseParent: () => {
                  this.onCollapseComment?.(this.comment.rpid);
                }
              });
            // ⚠️ key 只放 rpid：原先拼了 `_reply_v${repliesVersion}`，而展开/点赞都会 ++repliesVersion
            //    ⇒ 每次都被判成"新项"、整列重建，头像跟着重新加载（用户报的"展开时头像闪一下"）。
            //    回复数组本身是 @Track 字段，增删会正常刷新，不需要靠 key 变化驱动。
            }, (reply: ObservableComment) => reply.rpid.toString());
          }
          .width('100%')
          .padding({ left: 8, right: 8 });

          // 底部操作栏（收起回复圆形图标按钮 + 展开更多回复，同行居中）
          Column() {
            Row() {
              // ⭐ 收起回复：圆形主题色包裹 direction_upward 图标（浅色黑/深色白），直径 32 与展开更多回复遮罩一致，位于其左侧
              Column() {
                Image($r('app.media.direction_upward'))
                  .width(18)
                  .height(18)
                  .fillColor(this.isDarkMode ? Color.White : Color.Black)
              }
              .width(32)
              .height(32)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .borderRadius(16)
              .backgroundColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
              .margin({ right: 8 })
              .onClick(() => { try { VibrateUtils.vibrateTime(15); } catch (_) {} this.onCollapseComment?.(this.comment.rpid); })
              .hitTestBehavior(HitTestMode.Block)
              .clickEffect({ level: 1, scale: 0.95 })

              if (this.comment.hasMoreReplies && this.replies_.length > 0) {
                if (this.comment.loadingReplies) {
                  LoadingProgress()
                    .width(14)
                    .height(14)
                    .color(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'));
                  Text('加载中...')
                    .fontSize(11)
                    .fontColor($r('app.color.color_player_text_secondary'))
                    .margin({ left: 6 });
                } else {
                  Row() {
                    Text('展开更多回复')
                      .fontSize(13)
                      .fontColor(this.isDarkMode ? Color.White : Color.Black)
                      .fontWeight(FontWeight.Medium);
                    Text(` (${this.comment.rcount - this.replies_.length})`)
                      .fontSize(13)
                      .fontColor(this.isDarkMode ? Color.White : Color.Black);
                  }
                  .height(32)
                  .padding({ left: 16, right: 16 })
                  .borderRadius(16)
                  .backgroundColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                  .onClick(() => { try { VibrateUtils.vibrateTime(15); } catch (_) {} this.onLoadMoreReplies?.(this.comment); })
                  .hitTestBehavior(HitTestMode.Block)
                  .clickEffect({ level: 1, scale: 0.95 })
                }
              }
            }
            .padding({ top: 4, bottom: 4 });
          }
          .width('100%')
          .padding({ left: 16, right: 16 });
        }
        .width('100%')
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: -10 })),
            TransitionEffect.opacity(0).combine(TransitionEffect.translate({ y: -10 }))
          )
        )
      }
    }
    .width('100%')
    .margin({ left: this.cardMarginVp, right: this.cardMarginVp })
    .id(`comment_${this.comment.rpid}`);
  }
}
