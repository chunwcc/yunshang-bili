// MsgNoticePage.ets — 消息中心四类通知列表页（回复我的/@我/收到的赞/系统通知）
import { router } from '@kit.ArkUI';
import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';
import { MsgFeedApi, MsgFeedItem, MsgFeedListResult } from '../api/MsgFeedApi';

/** 类型配置（标题 + 类型号） */
interface NoticeTypeConfig {
  title: string;
  type: number;
}

const NOTICE_CONFIGS: NoticeTypeConfig[] = [
  { title: '回复我的', type: 1 },
  { title: '@我', type: 2 },
  { title: '收到的赞', type: 3 },
  { title: '系统通知', type: 4 }
];

@Entry
@Component({ freezeWhenInactive: true })
struct MsgNoticePage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @StorageLink('wallpaper') wallpaper: string = 'default';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;
  /** 当前类型 */
  @State currentType: number = 1;
  /** 标题 */
  @State title: string = '消息';
  /** 列表数据 */
  @State items: MsgFeedItem[] = [];
  /** 加载中 */
  @State isLoading: boolean = true;
  /** 加载失败 */
  @State loadError: string = '';
  /** 是否有更多 */
  @State hasMore: boolean = true;
  /** 加载更多中 */
  @State isLoadingMore: boolean = false;
  /** 游标 */
  private cursor: number = 0;
  private cursorTime: number = 0;


  async aboutToAppear(): Promise<void> {
    const params = router.getParams() as Record<string, Object>;
    if (params) {
      const type = (params['type'] as number) || 1;
      this.currentType = type;
      const conf = NOTICE_CONFIGS.find((c: NoticeTypeConfig) => c.type === type);
      if (conf) {
        this.title = conf.title;
      }
    }
    await this.loadList();
  }

  /**
   * 拉取列表（首页）
   */
  private async loadList(): Promise<void> {
    this.isLoading = true;
    this.loadError = '';
    this.cursor = 0;
    this.cursorTime = 0;
    try {
      const result: MsgFeedListResult = await MsgFeedApi.fetchList(this.currentType, 0, 0);
      this.items = result.items;
      this.cursor = result.cursor;
      this.cursorTime = result.cursorTime;
      this.hasMore = !result.isEnd;
      logInfo(`[MsgNoticePage] ${this.title} 加载 ${this.items.length} 条`);
    } catch (err) {
      logError(`[MsgNoticePage] 加载失败: ${errMsg(err)}`);
      this.loadError = '加载失败，请检查网络';
    }
    this.isLoading = false;
  }

  /**
   * 触底加载更多
   */
  private async loadMore(): Promise<void> {
    if (this.isLoadingMore || !this.hasMore) {
      return;
    }
    this.isLoadingMore = true;
    try {
      const result: MsgFeedListResult = await MsgFeedApi.fetchList(this.currentType, this.cursor, this.cursorTime);
      this.items = [...this.items, ...result.items];
      this.cursor = result.cursor;
      this.cursorTime = result.cursorTime;
      this.hasMore = !result.isEnd;
    } catch (err) {
      logWarn(`[MsgNoticePage] 加载更多失败: ${errMsg(err)}`);
    }
    this.isLoadingMore = false;
  }

  /**
   * 格式化时间
   */
  private formatTime(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d = new Date(ts * 1000);
    const now = new Date();
    const hm = `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
    if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()) {
      return hm;
    }
    return `${(d.getMonth() + 1).toString().padStart(2, '0')}-${d.getDate().toString().padStart(2, '0')} ${hm}`;
  }

  @Builder
  noticeRow(item: MsgFeedItem) {
    Row() {
      // 头像（无图时首字占位）
      Stack() {
        Circle()
          .width(42).height(42)
          .fill(this.isDarkMode ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.08)')
        if (item.avatar) {
          Image(item.avatar)
            .width(42).height(42)
            .borderRadius(21)
        } else {
          Text(item.uname.length > 0 ? item.uname.substring(0, 1) : '?')
            .fontSize(16)
            .fontColor('#FF6699')
        }
      }
      .width(42).height(42)

      Column() {
        Row() {
          Text(item.uname || '未知用户')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.formatTime(item.time))
            .fontSize(11)
            .fontColor('#999999')
            .margin({ left: 8 })
        }
        .width('100%')

        Text(item.content || '（无内容）')
          .fontSize(13)
          .fontColor('#999999')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (item.commentRootId > 0 && (item.bvid || item.aid)) {
        router.pushUrl({
          url: 'pages/CommentDetailPage',
          params: {
            aid: item.aid || 0,
            bvid: item.bvid || '',
            rootId: item.commentRootId,
            secondaryId: item.commentSecondaryId || 0
          }
        }).catch((err: Error) => {
          logError('跳转评论详情失败', err.message);
        });
      } else if (item.bvid || item.aid) {
        router.pushUrl({
          url: 'pages/VideoPlayerPage',
          params: {
            bvid: item.bvid || '',
            aid: item.aid || 0,
            title: item.videoTitle || item.content || ''
          }
        }).catch((err: Error) => {
          logError('跳转视频播放失败', err.message);
        });
      }
    })
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
      // ── 顶部标题栏 ──
      Row() {
        Image($r('app.media.ic_public_arrow_left_filled'))
          .width(22).height(22)
          .margin({ left: 8, right: 4 })
          .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .onClick(() => {
            router.back();
          })
        Text(this.title)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Blank()
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: this.hideStatusBar ? 12 : (this.statusBarHeight + 8), bottom: 12 })


      // ── 列表 ──
      if (this.isLoading) {
        Column() {
          LoadingProgress().width(32).height(32).color('#FF6699')
          Text('加载中...').fontSize(13).fontColor('#999999').margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.loadError) {
        Column() {
          Text(this.loadError).fontSize(14).fontColor('#FF4444')
          Button('重试')
            .fontSize(14)
            .margin({ top: 12 })
            .onClick(() => {
              this.loadList();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column() {
          Text('暂无通知')
            .fontSize(14)
            .fontColor('#999999')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 0 }) {
          ForEach(this.items, (item: MsgFeedItem) => {
            ListItem() {
              this.noticeRow(item)
            }
          }, (item: MsgFeedItem) => `${item.id}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .onReachEnd(() => {
          this.loadMore();
        })
      }
    }
    .width('100%')
    .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
