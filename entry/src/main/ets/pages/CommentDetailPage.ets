import { router } from '@kit.ArkUI';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { CommentItem, VideoDetail, getCommentReplies, getCommentDetail, CommentDetailResult, addVideoComment } from '../api/BilibiliApi';
import { ObservableComment } from '../model/ObservableComment';
import { ReplyItemComponent } from '../components/ReplyItemComponent';
import { CommentContentRenderer } from '../components/CommentContentRenderer';
import { CommentInputBar, CommentImageDraft, CommentInputBarCtrl } from '../components/CommentInputBar';
import { MaterialUtil } from '../utils/MaterialUtil';

@Entry
@Component({ freezeWhenInactive: true })
struct CommentDetailPage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @StorageLink('playerFollowTheme') playerFollowTheme: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('biliCookie') biliCookie: string = '';
  @StorageLink('wallpaper') wallpaper: string = 'default';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;

  @State mainComment: ObservableComment | null = null;
  @State videoDetail: VideoDetail | null = null;
  @State replies: ObservableComment[] = [];
  @State totalCount: number = 0;
  @State currentPage: number = 1;
  @State isLoading: boolean = false;
  @State hasMore: boolean = true;
  @State aid: number = 0;
  @State repliesVersion: number = 0;
  @State highlightRpid: number = 0;
  @State commentSheetVisible: boolean = false;
  @State commentSheetMode: string = 'reply';
  @State replyTargetName: string = '';
  /**
   * ⭐ 回复评论弹层的表情面板控制器（见 CommentInputBarCtrl）：
   *    表情面板展开时，侧滑返回/返回键应**先收起面板**，而不是把整个输入弹层关掉。
   */
  private cmSheetEmoteCtrl: CommentInputBarCtrl = new CommentInputBarCtrl();

  private scroller: Scroller = new Scroller();
  private rootId_: number = 0;
  private secondaryId_: number = 0;
  private bvid_: string = '';
  private isMsgNavMode: boolean = false;
  private replyRoot: number = 0;
  private replyParent: number = 0;

  async aboutToAppear(): Promise<void> {
    const params = router.getParams() as Record<string, Object>;
    if (!params) return;

    const mainCommentData = params['mainComment'] as CommentItem;
    if (mainCommentData) {
      this.mainComment = ObservableComment.from(mainCommentData);
      this.totalCount = mainCommentData.rcount;
    }

    this.videoDetail = params['videoDetail'] as VideoDetail;
    if (this.videoDetail) {
      this.aid = this.videoDetail.aid;
    }

    const repliesData = params['replies'] as CommentItem[];
    if (repliesData && repliesData.length > 0) {
      this.replies = repliesData.map(item => ObservableComment.from(item));
      this.hasMore = this.totalCount > this.replies.length;
    }

    const rootIdParam = params['rootId'];
    if (rootIdParam) {
      this.rootId_ = typeof rootIdParam === 'number' ? rootIdParam : parseInt(rootIdParam as string, 10) || 0;
    }
    const secondaryIdParam = params['secondaryId'];
    if (secondaryIdParam) {
      this.secondaryId_ = typeof secondaryIdParam === 'number' ? secondaryIdParam : parseInt(secondaryIdParam as string, 10) || 0;
    }
    const bvidParam = params['bvid'];
    if (bvidParam) {
      this.bvid_ = bvidParam as string;
    }
    const aidParam = params['aid'];
    if (aidParam) {
      this.aid = typeof aidParam === 'number' ? aidParam : parseInt(aidParam as string, 10) || this.aid;
    }

    if (!this.mainComment && this.rootId_ > 0 && this.aid > 0) {
      this.isMsgNavMode = true;
      await this.loadFromMsgNav();
    }
  }

  private async loadFromMsgNav(): Promise<void> {
    this.isLoading = true;
    try {
      const result: CommentDetailResult | null = await getCommentDetail(this.aid, this.rootId_, 1, 20);
      if (!result) {
        logWarn('[CommentDetailPage] loadFromMsgNav: getCommentDetail 返回 null');
        this.isLoading = false;
        return;
      }

      if (result.rootComment) {
        this.mainComment = ObservableComment.from(result.rootComment);
        this.totalCount = result.totalCount;
      }

      if (result.replies && result.replies.length > 0) {
        this.replies = result.replies.map(item => ObservableComment.from(item));
        this.hasMore = this.totalCount > this.replies.length;
      }

      if (this.secondaryId_ > 0) {
        this.highlightRpid = this.secondaryId_;
      }

      logInfo(`[CommentDetailPage] loadFromMsgNav: root rpid=${this.mainComment?.rpid ?? 0}, replies=${this.replies.length}, highlight=${this.highlightRpid}`);
    } catch (err) {
      logError(`[CommentDetailPage] loadFromMsgNav 异常: ${err}`);
    } finally {
      this.isLoading = false;
    }
  }

  private async loadMoreReplies(): Promise<void> {
    if (this.isLoading || !this.hasMore || !this.mainComment) {
      return;
    }

    this.isLoading = true;
    try {
      const newReplies = await getCommentReplies(
        this.aid,
        this.mainComment.rpid,
        this.currentPage + 1,
        20
      );

      if (newReplies && newReplies.length > 0) {
        const existingIds = new Set(this.replies.map(r => r.rpid));
        for (let i = 0; i < newReplies.length; i++) {
          if (!existingIds.has(newReplies[i].rpid)) {
            this.replies.push(ObservableComment.from(newReplies[i]));
            existingIds.add(newReplies[i].rpid);
          }
        }
        this.currentPage++;
        this.repliesVersion++;
        this.hasMore = this.totalCount > this.replies.length;
      } else {
        this.hasMore = false;
      }
    } catch (err) {
      logError(`[CommentDetailPage] 加载回复失败: ${err}`);
    } finally {
      this.isLoading = false;
    }
  }

  private formatTimeAgo(timestamp: number): string {
    const now = Date.now() / 1000;
    const diff = now - timestamp;

    if (diff < 60) return '刚刚';
    if (diff < 3600) return `${Math.floor(diff / 60)}分钟前`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}小时前`;
    if (diff < 2592000) return `${Math.floor(diff / 86400)}天前`;
    if (diff < 31536000) return `${Math.floor(diff / 2592000)}月前`;
    return `${Math.floor(diff / 31536000)}年前`;
  }

  private getLevelBgColor(level: number): string {
    if (level >= 6) return '#FFD700';
    if (level >= 4) return '#4169E1';
    if (level >= 2) return '#32CD32';
    return '#A9A9A9';
  }

  private openUserSpace(): void {
    const member = this.mainComment?.member;
    if (!member) return;
    const mid = parseInt(member.mid ?? '', 10);
    if (!mid || isNaN(mid)) return;
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UpSpacePage',
      params: {
        mid: mid,
        upName: member.uname ?? '',
        upFace: member.avatar ?? ''
      }
    }).catch((err: Error) => {
      logWarn(`[CommentDetail] 打开空间失败: ${err}`);
    });
  }

  private goToVideo(): void {
    if (this.bvid_ || this.aid) {
      router.pushUrl({
        url: 'pages/VideoPlayerPage',
        params: {
          bvid: this.bvid_ || '',
          aid: this.aid || 0,
          title: ''
        }
      }).catch((err: Error) => {
        logError('[CommentDetailPage] 跳转视频失败', err.message);
      });
    }
  }

  private openReplySheet(parent: number, targetName: string): void {
    if (!this.biliCookie.includes('SESSDATA')) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录' });
      return;
    }
    this.commentSheetMode = 'reply';
    this.replyRoot = this.mainComment?.rpid ?? 0;
    this.replyParent = parent;
    this.replyTargetName = targetName;
    this.commentSheetVisible = true;
  }

  private async handleCommentSend(content: string, pictures: CommentImageDraft[]): Promise<boolean> {
    if (!this.aid) {
      this.getUIContext().getPromptAction().showToast({ message: '评论失败：缺少视频ID' });
      return false;
    }
    let picturesJson = '';
    if (pictures.length > 0) {
      this.getUIContext().getPromptAction().showToast({ message: '回复不支持图片' });
      return false;
    }
    const res = await addVideoComment(this.aid, content, this.replyRoot, this.replyParent, picturesJson);
    if (!res.ok) {
      this.getUIContext().getPromptAction().showToast({ message: res.message || '发表失败，请稍后再试', duration: 2000 });
      return false;
    }
    this.getUIContext().getPromptAction().showToast({ message: '回复成功' });
    this.commentSheetVisible = false;
    this.replyRoot = 0;
    this.replyParent = 0;
    this.replyTargetName = '';
    this.currentPage = 1;
    this.replies = [];
    this.hasMore = true;
    if (this.mainComment) {
      const freshReplies = await getCommentReplies(this.aid, this.mainComment.rpid, 1, 20);
      if (freshReplies && freshReplies.length > 0) {
        this.replies = freshReplies.map(item => ObservableComment.from(item));
        this.repliesVersion++;
        this.hasMore = this.totalCount > this.replies.length;
      }
    }
    return true;
  }

  /**
   * ⭐ 评论输入弹层内容（对齐播放页 comSheetContent / 发弹幕：内容根走条件透明，
   *    让半模态面板自己的沉浸光感玻璃透出来）
   */
  @Builder
  commentSheetContent() {
    Column() {
      CommentInputBar({
        ctrl: this.cmSheetEmoteCtrl,
        placeholder: this.commentSheetMode === 'reply' ? `回复 @${this.replyTargetName}：` : '发一条友善的评论',
        showImageButton: false,
        onSend: (content: string, pictures: CommentImageDraft[]) => {
          return this.handleCommentSend(content, pictures);
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .backgroundColor(this.sheetRootBg(this.isDarkMode ? '#242424' : '#FFFFFF'))
  }

  /**
   * ⭐ 半模态面板内容根底色：设备支持沉浸光感材质时必须全透明
   * （材质层在 backgroundColor 之下，不透明底会把玻璃整层盖住——MaterialUtil 硬要求①）。
   * 与播放页 sheetRootBg() 同一约定（该页 2026-09-23 起 7 个面板都用它）。
   */
  private sheetRootBg(base: ResourceColor): ResourceColor {
    return MaterialUtil.sheetMaterial() !== undefined ? Color.Transparent : base;
  }

  @Builder
  wallpaperDarknessLayer() {
    if (this.wallpaperDarkness < 50) {
      Column()
        .width('100%').height('100%')
        .backgroundColor(`rgba(0, 0, 0, ${(50 - this.wallpaperDarkness) / 50})`)
    } else if (this.wallpaperDarkness > 50) {
      Column()
        .width('100%').height('100%')
        .backgroundColor(`rgba(255, 255, 255, ${(this.wallpaperDarkness - 50) / 50})`)
    }
  }

  build() {
    Stack() {
      if (this.wallpaper === 'builtin') {
        Stack() {
          Image(this.isDarkMode ? $r('app.media.wallpaper_shen') : $r('app.media.wallpaper_qian'))
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
          this.wallpaperDarknessLayer()
        }
        .width('100%').height('100%')
      } else if (this.wallpaper === 'custom' && this.customWallpaper) {
        Stack() {
          Image('file://' + this.customWallpaper)
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
            .blur(this.wallpaperBlur)
          this.wallpaperDarknessLayer()
        }
        .width('100%').height('100%')
      } else {
        Stack() {
          Column()
            .width('100%').height('100%')
            .backgroundColor(this.isDarkMode ? '#1A1A1A' : '#F5F6F7')
          this.wallpaperDarknessLayer()
        }
        .width('100%').height('100%')
      }

    Column() {
      Row() {
        Image($r('app.media.ic_public_arrow_left_filled'))
          .width(24)
          .height(24)
          .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .onClick(() => router.back())
          .padding(8);

        Text('评论详情')
          .fontSize(18)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center);

        if (this.isMsgNavMode && (this.bvid_ || this.aid)) {
          Text('前往视频')
            .fontSize(14)
            .fontColor(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
            .padding({ right: 8 })
            .onClick(() => this.goToVideo());
        } else {
          Blank().width(40);
        }
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: this.hideStatusBar ? 12 : (this.statusBarHeight + 8), bottom: 12 })


      if (this.mainComment) {
        Scroll(this.scroller) {
          Column() {
            Column() {
              Row() {
                Image(this.mainComment.member?.avatar ?? '')
                  .width(40)
                  .height(40)
                  .borderRadius(20)
                  .onClick(() => { this.openUserSpace(); });

                Column() {
                  Row() {
                    Text(this.mainComment.member?.uname ?? '')
                      .fontSize(14)
                      .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                      .fontWeight(FontWeight.Medium);

                    Text(`LV${this.mainComment.member?.level_info?.current_level ?? 0}`)
                      .fontSize(10)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#FFFFFF')
                      .backgroundColor(this.getLevelBgColor(this.mainComment.member?.level_info?.current_level ?? 0))
                      .borderRadius(3)
                      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                      .margin({ left: 6 });

                    if (this.videoDetail &&
                        this.mainComment.member?.mid === this.videoDetail.owner.mid.toString()) {
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

                  Text(this.formatTimeAgo(this.mainComment.ctime))
                    .fontSize(11)
                    .fontColor(this.isDarkMode ? '#999999' : '#666666')
                    .margin({ top: 4 });
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 12 });
              }
              .width('100%')
              .alignItems(VerticalAlign.Top);

              CommentContentRenderer({ content: this.mainComment?.content ?? null, fontSize: 15, textColor: this.isDarkMode ? '#FFFFFF' : '#000000', maxLines: 999, thumbIdPrefix: String(this.mainComment?.rpid ?? 0) })
                .margin({ top: 12 })
                .width('100%');

              Row() {
                Image($r('app.media.ic_public_thumbsup_filled'))
                  .width(16)
                  .height(16)
                  .fillColor(this.isDarkMode ? '#999999' : '#666666')
                  .margin({ right: 4 });

                Text(`${this.mainComment.like}`)
                  .fontSize(12)
                  .fontColor(this.isDarkMode ? '#999999' : '#666666');

                Blank();

                Text('回复')
                  .fontSize(13)
                  .fontColor(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
                  .onClick(() => {
                    this.openReplySheet(this.mainComment?.rpid ?? 0, this.mainComment?.member?.uname ?? '');
                  });
              }
              .width('100%')
              .margin({ top: 8 });
            }
            .width('100%')
            .padding(16)

            .borderRadius(12)
            .margin({ left: 12, right: 12, top: 12 });

            Row() {
              Text(`全部回复 (${this.totalCount})`)
                .fontSize(14)
                .fontColor(this.isDarkMode ? '#999999' : '#666666')
                .fontWeight(FontWeight.Medium);
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 8 });

            if (this.replies.length > 0) {
              Column() {
                ForEach(this.replies, (reply: ObservableComment, index: number) => {
                  ReplyItemComponent({
                    reply: reply,
                    showDivider: false,
                    videoDetail: this.videoDetail,
                    depth: 0,
                    isHighlighted: this.highlightRpid > 0 && reply.rpid === this.highlightRpid,
                    onReplyTap: (parent: number, targetName: string) => {
                      this.openReplySheet(parent, targetName);
                    }
                  });
                }, (reply: ObservableComment) => `${reply.rpid}_v${this.repliesVersion}`);
              }
              .width('100%')
              .padding({ left: 8, right: 8 });
            }

            Column() {
              if (this.isLoading) {
                Row() {
                  LoadingProgress()
                    .width(20)
                    .height(20)
                    .color(this.playerFollowTheme ? this.customThemeColor : '#FB7299');
                  Text('加载中...')
                    .fontSize(13)
                    .fontColor(this.isDarkMode ? '#999999' : '#666666')
                    .margin({ left: 8 });
                }
                .padding(16);
              } else if (this.hasMore && this.replies.length > 0) {
                Text('点击加载更多回复')
                  .fontSize(13)
                  .fontColor(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
                  .padding(16)
                  .onClick(() => this.loadMoreReplies());
              } else if (!this.hasMore && this.replies.length > 0) {
                Text('没有更多回复了')
                  .fontSize(13)
                  .fontColor(this.isDarkMode ? '#666666' : '#999999')
                  .padding(16);
              } else if (this.replies.length === 0) {
                Text('暂无回复')
                  .fontSize(13)
                  .fontColor(this.isDarkMode ? '#666666' : '#999999')
                  .padding(16);
              }
            }
            .width('100%')
            .margin({ bottom: 20 });
          }
          .width('100%');
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      } else if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(this.playerFollowTheme ? this.customThemeColor : '#FB7299');

          Text('加载中...')
            .fontSize(14)
            .fontColor(this.isDarkMode ? '#999999' : '#666666')
            .margin({ top: 12 });
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center);
      } else {
        Column() {
          Text('评论加载失败')
            .fontSize(14)
            .fontColor(this.isDarkMode ? '#999999' : '#666666');
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center);
      }

      Column().width(1).height(1).opacity(0).hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.commentSheetVisible, this.commentSheetContent(), {
          height: SheetSize.FIT_CONTENT,
          // ⭐ 原先漏配 systemMaterial + 内容根不透明 ⇒ 面板是纯白平板，与播放页评论/发弹幕
          //    的沉浸光感完全不一致。补齐：面板挂材质 + 底色透明，内容根再由 sheetRootBg 透明化。
          backgroundColor: Color.Transparent,
          systemMaterial: MaterialUtil.sheetMaterial(),
          dragBar: true,
          showClose: false,
          keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL,
          // ⭐ 表情面板展开时，返回（侧滑/返回键）应当**先收起面板**、不关整个输入弹层。
          //    ⚠️ 官方文档：注册 onWillDismiss 后弹层不再自动关，必须自己决定是否 dismiss()
          //       ⇒ 非 PRESS_BACK 的原因（下拉关闭/点遮罩）显式调 a.dismiss()，关闭行为不变。
          //    📌 唯一副作用：注册了 onWillDismiss 又未注册 onWillSpringBackWhenDismiss 时，
          //       **下拉关闭会先回弹再关**（官方默认流程）；这是使用该回调的既定代价。
          onWillDismiss: (a: DismissSheetAction): void => {
            if (a.reason === DismissReason.PRESS_BACK && this.cmSheetEmoteCtrl.collapseEmote()) {
              return;   // 面板本来开着 → 已收起，弹层保持打开
            }
            a.dismiss();
          },
          onAppear: () => {
            setTimeout(() => {
              try {
                this.getUIContext().getFocusController().requestFocus('comment_rich_editor');
              } catch (_) {}
            }, 30);
          },
          onDisappear: () => {
            this.commentSheetVisible = false;
          }
        })
    }
    .width('100%')
    .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
