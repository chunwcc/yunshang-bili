import { ObservableComment } from '../model/ObservableComment';
import { VideoDetail, setCommentLike } from '../api/BilibiliApi';
import { CommentContentRenderer } from './CommentContentRenderer';
import { TextSelectionDialog } from './TextSelectionDialog';
import { measureTextLines } from '../utils/TextMeasure';
import { logWarn } from '../utils/Logger';
import { MaterialUtil } from '../utils/MaterialUtil';
import { VibrateUtils } from '../utils/VibrateUtils';

/**
 * 回复项组件 - 气泡式风格
 * 特点：
 * 1. 圆角气泡背景
 * 2. 缩进层次感
 * 3. 连接线显示层级关系
 * 4. 现代美观的UI风格
 */
@Component
export struct ReplyItemComponent {
  @ObjectLink reply: ObservableComment;
  @Prop showDivider: boolean = false;
  @Prop videoDetail: VideoDetail | null = null;
  @Prop depth: number = 0;
  @Prop isHighlighted: boolean = false;
  onReplyTap?: (parent: number, targetName: string) => void;
  // ⭐ 双击回复卡片收起该评论的回复区
  onCollapseParent?: () => void;
  @State isTextExpanded: boolean = false;
  /** ⭐ 回复文本实际容器宽度（vp，onAreaChange 实测；各布局宽度不同） */
  @State contentW: number = 0;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('cardTransparentStyleVideo') cardTransparentStyleVideo: boolean = false;
  @StorageLink('cardStyleVideoCommentBubble') cardStyleVideoCommentBubble: boolean = true;
  @StorageLink('cardStyleVideoCommentAlign') commentTextAlign: string = 'center';
  @StorageLink('cardCustomColor') cardCustomColor: string = '';
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('playerFollowTheme') playerFollowTheme: boolean = false;

  // ⭐ 按实测容器宽度测量真实行数（不同布局宽度不同，固定字符估算会误报）
  private shouldShowExpandButton(): boolean {
    const msg = this.reply.content?.message ?? '';
    if (!msg) return false;
    // 容器宽度未就绪时保守不显示（宁可漏不错，避免"内容完整却有展开按钮"）
    if (this.contentW <= 0) return false;
    return measureTextLines(this.getUIContext(), msg, this.contentW, 13) > 8;
  }

  /**
   * 点赞/取消点赞回复（乐观更新，失败回滚）
   */
  private async toggleReplyLike(): Promise<void> {
    const like = this.reply.action !== 1;
    const prevLike = this.reply.like;
    const prevAction = this.reply.action;
    this.reply.like = like ? this.reply.like + 1 : Math.max(0, this.reply.like - 1);
    this.reply.action = like ? 1 : 0;
    try { VibrateUtils.vibrateTime(10); } catch (_e) { /* ignore */ }
    const res = await setCommentLike(this.reply.oid, this.reply.rpid, like);
    if (res.ok) return;
    // ⭐ 失败回滚，保持展示与服务器一致
    this.reply.like = prevLike;
    this.reply.action = prevAction;
    this.getUIContext().getPromptAction().showToast({
      message: res.code === -101 ? '请先登录' : (res.message || '操作失败，请重试')
    });
  }

  /** ⭐ 文本工具弹窗 id（与主评论一致，用于关闭后跳搜索） */
  private commentSelDialogId_: number = -1;

  // ⭐ 回复长按文本选取弹窗（可选中 → 复制/搜索）
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
          logWarn(`[回复] 搜索页跳转失败: ${err}`);
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
      logWarn(`[回复] 文本弹窗打开失败: ${err}`);
    });
  }

  /** 点击头像/昵称 → 打开回复用户的空间页 */
  private openUserSpace(): void {
    const mid = parseInt(this.reply.member?.mid ?? '', 10);
    if (!mid || isNaN(mid)) return;
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UpSpacePage',
      params: {
        mid: mid,
        upName: this.reply.member?.uname ?? '',
        upFace: this.reply.member?.avatar ?? ''
      }
    }).catch((err: Error) => {
      logWarn(`[ReplyItem] 打开空间失败: ${err}`);
    });
  }

  // 获取等级背景色
  private getLevelBgColor(level: number): string {
    if (level >= 6) return '#FFD700'; // 金色 - 最高等级
    if (level >= 4) return '#4169E1'; // 皇家蓝 - 高等级
    if (level >= 2) return '#32CD32'; // 酸橙绿 - 中等级
    return '#A9A9A9'; // 深灰色 - 低等级
  }

  // 获取气泡不透明度（根据深度变化）
  private getBubbleOpacity(): number {
    // 深度越深，不透明度越低（越透明）
    const opacityValues = [0.8, 0.7, 0.6, 0.5]; // 深度0-3对应的不透明度
    return opacityValues[Math.min(this.depth, 3)];
  }

  // 将百分比透明度转为十六进制字符串（与主评论气泡一致）
  private opacityToHexAlpha(opacity: number): string {
    const clamped = Math.max(0, Math.min(100, opacity));
    const hex = Math.round(clamped / 100 * 255).toString(16).toUpperCase();
    return hex.length < 2 ? '0' + hex : hex;
  }

  // 计算缩进宽度
  private getIndentWidth(): number {
    return Math.min(this.depth, 3) * 12; // 每层缩进12vp，最多3层
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

  build() {
    Column() {
      // 气泡主体 - 垂直布局（与评论区主评论一致）
      Column() {
        // 左上角小圆点（指示层级）
        Row() {
          Circle()
            .width(6).height(6)
            .fill(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
        }
        .width('100%')
        .margin({ bottom: 6 })

        // 头像 + 用户名 + LV + UP — 同一行
        Row() {
          Image(this.reply.member?.avatar ?? '')
            .width(20)
            .height(20)
            .borderRadius(10)
            .margin({ right: 6 })
            .onClick(() => { this.openUserSpace(); });

          Text(this.reply.member?.uname ?? '')
            .fontSize(12)
            .fontColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1);

          // LV 等级标签
          if (this.reply.member?.level_info?.current_level !== undefined) {
            Text(`LV${this.reply.member.level_info.current_level}`)
              .fontSize(10)
              .fontColor('#FFFFFF')
              .backgroundColor(this.getLevelBgColor(this.reply.member.level_info.current_level))
              .borderRadius(3)
              .padding({ left: 3, right: 3, top: 1, bottom: 1 })
              .margin({ left: 4 });
          }

          // UP 主标注
          if (this.videoDetail && this.reply.member?.mid === this.videoDetail.owner.mid.toString()) {
            Text('UP')
              .fontSize(10)
              .fontColor('#FFFFFF')
              .backgroundColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
              .borderRadius(3)
              .padding({ left: 3, right: 3, top: 1, bottom: 1 })
              .margin({ left: 4 });
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Center);

        Column() {
          // 回复内容
          CommentContentRenderer({ content: this.reply.content, fontSize: 13, textColor: $r('app.color.color_player_text'), maxLines: this.isTextExpanded ? 999 : 8, isCenter: this.commentTextAlign === 'center', thumbIdPrefix: String(this.reply.rpid) })
            .margin({ top: 6 })
        }
        .width('100%')
        .gesture(LongPressGesture().onAction(() => {
          const msg = this.reply.content?.message ?? '';
          if (msg) {
            this.showTextSelection('文本工具 · 回复', msg);
          }
        }))
        .onAreaChange((_o: Area, n: Area) => {
          const w = n.width as number;
          if (w > 0 && Math.abs(w - this.contentW) > 1) {
            this.contentW = w;
          }
        });

        // 展开/收起全文按钮
        if (this.shouldShowExpandButton()) {
          Text(this.isTextExpanded ? '收起' : '展开全文')
            .fontSize(13)
            .fontColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
            .margin({ top: 4 })
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => {
              this.isTextExpanded = !this.isTextExpanded;
            });
        }

        // IP + 时间（· 分隔）— 左侧；回复按钮 + 点赞 — 右侧（与评论区主评论一致）
        Row() {
          if (this.reply.ipLocation !== '') {
            Text(`IP : ${this.reply.ipLocation}`)
              .fontSize(11)
              .fontColor($r('app.color.color_player_text_secondary'))
              .margin({ right: 4 });
            Text('·')
              .fontSize(11)
              .fontColor($r('app.color.color_player_text_secondary'))
              .margin({ right: 4 });
          }
          Text(this.formatTimeAgo(this.reply.ctime))
            .fontSize(11)
            .fontColor($r('app.color.color_player_text_secondary'));
          Blank();
          // ⭐ 回复按钮（message.svg）：点击触发回复输入
          Image($r('app.media.message'))
            .width(14)
            .height(14)
            .fillColor($r('app.color.color_player_text_secondary'))
            .margin({ right: 10 })
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => {
              VibrateUtils.vibrateTime(10);
              this.onReplyTap?.(this.reply.rpid, this.reply.member?.uname ?? '');
            })
          Row() {
            Image($r('app.media.ic_public_thumbsup_filled'))
              .width(12)
              .height(12)
              .fillColor(this.reply.action === 1
                ? (this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                : $r('app.color.color_player_text_secondary'))
              .margin({ right: 3 });
            Text(`${this.reply.like}`)
              .fontSize(11)
              .fontColor(this.reply.action === 1
                ? (this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                : $r('app.color.color_player_text_secondary'));
          }
          .hitTestBehavior(HitTestMode.Block)
          .onClick(() => { this.toggleReplyLike(); })
        }
        .width('100%')
        .margin({ top: 6 });
      }
      .width('100%')
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
      .borderRadius(20)
      .borderWidth(this.isHighlighted ? 2 : 0)
      .borderColor(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
      .opacity(this.getBubbleOpacity())
      // ⭐ 双击卡片（空白/文字区域，子按钮点击优先）收起整条回复区
      .gesture(
        TapGesture({ count: 2 }).onAction(() => {
          try { VibrateUtils.vibrateTime(10); } catch (_) {}
          this.onCollapseParent?.();
        })
      );
    }
    .width('100%')
    .padding({ left: this.getIndentWidth() }) // 缩进
    .borderWidth({ left: this.depth > 0 ? 2 : 0 }) // 连接线 - 左边框
    .borderColor({ left: 'rgba(251, 114, 153, 0.3)' })
    .borderStyle({ left: BorderStyle.Solid })
    .margin({ left: 12, right: 12, top: 8, bottom: 8 });
  }
}
