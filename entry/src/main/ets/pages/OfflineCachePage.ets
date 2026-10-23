// OfflineCachePage.ets - 离线缓存列表页
import { router, mediaquery } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { logError } from '../utils/Logger';
import { OfflineCacheService } from '../services/OfflineCacheService';
import { OfflineCacheItem, CacheStatus } from '../model/OfflineCacheItem';
import { OfflineInlinePlayer } from '../components/OfflineInlinePlayer';

// ⭐ 缓存进度子组件：内部定时轮询最新进度，避免 ForEach 因 downloadedBytes 变化整行重建导致封面闪烁
@Component
struct CacheItemProgress {
  @StorageLink('isDarkMode') isDarkMode: boolean = false
  @Prop bvid: string = ''
  @Prop cid: number = 0
  @Prop status: CacheStatus = CacheStatus.WAIT
  @Prop qualityLabel: string = ''
  @State downloadedBytes: number = 0
  @State totalBytes: number = 0
  private refreshTimer_: number = -1

  aboutToAppear(): void {
    this.syncFromService();
    if (this.refreshTimer_ === -1) {
      this.refreshTimer_ = setInterval(() => { this.syncFromService(); }, 1000);
    }
  }

  aboutToDisappear(): void {
    if (this.refreshTimer_ !== -1) {
      clearInterval(this.refreshTimer_);
      this.refreshTimer_ = -1;
    }
  }

  private syncFromService(): void {
    try {
      const fresh = OfflineCacheService.getInstance().getCachedItem(this.bvid, this.cid);
      if (fresh) {
        this.downloadedBytes = fresh.downloadedBytes;
        this.totalBytes = fresh.totalBytes;
      }
    } catch (e) {
      // 读取失败忽略，下次轮询重试
    }
  }

  private progressPercent(): number {
    if (this.totalBytes > 0) {
      return Math.min(Math.round(this.downloadedBytes / this.totalBytes * 100), 100);
    }
    return 0;
  }

  private formatSize(bytes: number): string {
    if (bytes <= 0) return '--';
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)}KB`;
    return `${(bytes / 1024 / 1024).toFixed(1)}MB`;
  }

  build() {
    Column() {
      Text(`${this.qualityLabel || '--'} · ${this.formatSize(this.downloadedBytes)}${this.totalBytes > 0 ? ' / ' + this.formatSize(this.totalBytes) : ''}`)
        .fontSize(12)
        .fontColor(this.isDarkMode ? '#8E8E93' : '#999999')
        .margin({ top: 6 })
      // ⭐ 下载中/已暂停：显示进度条
      if (this.status === CacheStatus.DOWNLOADING || this.status === CacheStatus.PAUSED) {
        Row() {
          Progress({ value: this.progressPercent(), total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(4)
            .color(this.status === CacheStatus.PAUSED ? '#8E8E93' : '#007AFF')
            .backgroundColor(this.isDarkMode ? '#2C2C2E' : '#E5E5EA')
            .margin({ top: 8 })
        }
        .width('100%')
      }
    }
  }
}

@Entry
@Component({ freezeWhenInactive: true })
struct OfflineCachePage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @State items: OfflineCacheItem[] = [];
  // ⭐ 内嵌播放：当前展开播放的条目（不跳转 VideoPlayerPage，点击已完成条目原位播放）
  @State playingBvid: string = '';
  @State playingCid: number = 0;
  // ⭐ 内嵌播放器全屏请求信号（递增触发组件 @Watch 进入内置全屏）
  @State fullscreenRequest: number = 0;
  // 删除点击标志：ClickEvent 无 stopPropagation，用标志位阻止冒泡触发播放
  private deleting_: boolean = false;
  // ⭐ 列表定时刷新（显示下载中条目与进度）
  private refreshTimer_: number = -1;
  // ⭐ 横屏两列：媒体查询监听器与状态（横屏且未展开播放时 lanes=2）
  private landscapeListener: mediaquery.MediaQueryListener | null = null;
  @State isLandscape: boolean = false;

  aboutToAppear(): void {
    // ⭐ 惰性初始化：注入沙箱 filesDir
    try {
      OfflineCacheService.getInstance().init(this.getUIContext().getHostContext() as common.Context);
    } catch (e) {
      logError(`[OfflineCachePage] init 异常: ${JSON.stringify(e)}`);
    }
    this.refresh();
    // ⭐ 每秒刷新一次，展示下载进度与状态变化
    if (this.refreshTimer_ === -1) {
      this.refreshTimer_ = setInterval(() => { this.refresh(); }, 1000);
    }
    // ⭐ 注册横屏监听（参考 HomePage：横屏时缓存列表显示两列）
    try {
      const mq = this.getUIContext().getMediaQuery();
      this.landscapeListener = mq.matchMediaSync('(orientation: landscape)');
      this.isLandscape = this.landscapeListener.matches;
      this.landscapeListener.on('change', (result: mediaquery.MediaQueryResult) => {
        this.isLandscape = result.matches;
      });
    } catch (e) {
      logError(`[OfflineCachePage] 注册横屏监听失败: ${JSON.stringify(e)}`);
    }
  }

  aboutToDisappear(): void {
    if (this.refreshTimer_ !== -1) {
      clearInterval(this.refreshTimer_);
      this.refreshTimer_ = -1;
    }
    // 注销横屏监听
    if (this.landscapeListener) {
      this.landscapeListener.off('change');
      this.landscapeListener = null;
    }
    // 离页清空展开状态（OfflineInlinePlayer 随组件销毁自动释放播放器与 fd）
    this.playingBvid = '';
    this.playingCid = 0;
  }

  private refresh(): void {
    try {
      this.items = OfflineCacheService.getInstance().listCached();
    } catch (e) {
      logError(`[OfflineCachePage] 读取缓存列表失败: ${JSON.stringify(e)}`);
      this.items = [];
    }
  }

  // ⭐ 删除确认对话框（左滑删除按钮触发）
  private confirmDelete(item: OfflineCacheItem): void {
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: '删除缓存',
        message: `确定删除「${item.title}」的缓存吗？`,
        buttons: [
          { text: '取消', color: '#8E8E93' },
          { text: '删除', color: '#FF453A' }
        ]
      }).then((result) => {
        if (result.index === 1) {
          this.removeItem(item);
        }
      });
    } catch (e) {
      logError(`[OfflineCachePage] 弹窗异常: ${JSON.stringify(e)}`);
    }
  }

  private removeItem(item: OfflineCacheItem): void {
    try {
      const ok = OfflineCacheService.getInstance().removeCache(item.bvid, item.cid);
      if (ok) {
        this.refresh();
      }
    } catch (e) {
      logError(`[OfflineCachePage] 删除失败: ${JSON.stringify(e)}`);
    }
  }

  /** 是否当前展开播放的条目 */
  private isPlaying(item: OfflineCacheItem): boolean {
    return item.status === CacheStatus.COMPLETED && item.bvid === this.playingBvid && item.cid === this.playingCid;
  }

  /**
   * 播放缓存视频（仅已完成条目可播放）：原位展开内嵌播放，不再跳转页面
   * 再点同一行收起；点其他行先收起旧的（其组件 aboutToDisappear 自动释放）再展开新的
   */
  private playItem(item: OfflineCacheItem): void {
    if (item.status !== CacheStatus.COMPLETED || !item.videoPath) {
      return;
    }
    if (this.isPlaying(item)) {
      this.collapsePlayer();
      return;
    }
    animateTo({ duration: 300 }, () => {
      this.playingBvid = item.bvid;
      this.playingCid = item.cid;
    });
  }

  /** 收起内嵌播放器（组件 aboutToDisappear 自动释放播放器与 fd） */
  private collapsePlayer(): void {
    animateTo({ duration: 300 }, () => {
      this.playingBvid = '';
      this.playingCid = 0;
    });
  }

  // ⭐ 左滑删除按钮内容（trash.svg，点击弹确认框）
  @Builder
  swipeDeleteButton(item: OfflineCacheItem) {
    Row() {
      Image($r('app.media.trash'))
        .width(24).height(24)
        .fillColor(Color.White)
    }
    .width(72)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#FF453A')
    .borderRadius(12)
    .onClick(() => {
      this.deleting_ = true;
      this.confirmDelete(item);
    })
  }

  private statusText(status: CacheStatus): string {
    switch (status) {
      case CacheStatus.DOWNLOADING:
        return '下载中';
      case CacheStatus.PAUSED:
        return '已暂停';
      case CacheStatus.COMPLETED:
        return '已完成';
      case CacheStatus.FAILED:
        return '失败';
      case CacheStatus.WAIT:
      default:
        return '等待中';
    }
  }

  // ⭐ 暂停下载（中断请求，进度保留）
  private pauseItem(item: OfflineCacheItem): void {
    try {
      OfflineCacheService.getInstance().pause(item.bvid, item.cid);
      this.refresh();
      this.getUIContext().getPromptAction().showToast({ message: '暂停缓存', duration: 1500 });
    } catch (e) {
      logError(`[OfflineCachePage] 暂停失败: ${JSON.stringify(e)}`);
    }
  }

  // ⭐ 继续下载（断点续传）
  private resumeItem(item: OfflineCacheItem): void {
    try {
      const svc = OfflineCacheService.getInstance();
      const started: boolean = svc.resume(item.bvid, item.cid, (ok: boolean) => {
        // ⭐ 下载结束回调：真正完成才提示「缓存完成」
        if (ok) {
          this.getUIContext().getPromptAction().showToast({ message: '缓存完成', duration: 1500 });
        } else {
          // ⭐ 区分「被暂停」与「真失败」：继续后立刻又暂停（点击行/暂停按钮触发 pause）
          // 会使 requestInStream 抛 2300023 而返回 false，此时条目已是 PAUSED，不算失败
          const fresh = svc.getCachedItem(item.bvid, item.cid);
          if (!fresh || fresh.status !== CacheStatus.PAUSED) {
            this.getUIContext().getPromptAction().showToast({ message: '继续下载失败', duration: 1500 });
          }
        }
        this.refresh();
      });
      if (started) {
        // ⭐ 启动成功：立即提示「继续缓存」
        this.getUIContext().getPromptAction().showToast({ message: '继续缓存', duration: 1500 });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '继续下载失败', duration: 1500 });
      }
      this.refresh();
    } catch (e) {
      logError(`[OfflineCachePage] 继续下载失败: ${JSON.stringify(e)}`);
    }
  }

  build() {
    Column() {
      // 顶部栏（外观对齐历史记录页：返回箭头 + 标题，无右侧计数）
      Row() {
        Image($r('app.media.ic_public_arrow_left_filled'))
          .width(24).height(24)
          .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
          .onClick(() => { router.back(); })
        Text('离线缓存')
          .fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .margin({ left: 12 })
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 + this.statusBarHeight, bottom: 12 })

      if (this.items.length === 0) {
        // 空态
        Column({ space: 12 }) {
          Image($r('app.media.save'))
            .width(64).height(64)
            .fillColor(this.isDarkMode ? '#5A5A5F' : '#C7C7CC')
          Text('暂无缓存视频')
            .fontSize(15)
            .fontColor(this.isDarkMode ? '#8E8E93' : '#999999')
          Text('在视频播放页点击「更多 → 缓存」即可离线缓存')
            .fontSize(13)
            .fontColor(this.isDarkMode ? '#636366' : '#C7C7CC')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // 缓存列表
        List({ space: 12 }) {
          ForEach(this.items, (item: OfflineCacheItem) => {
            ListItem() {
              if (this.isPlaying(item)) {
                // ⭐ 展开：内嵌播放器原位放大播放，其他条目被挤开
                Column() {
                  OfflineInlinePlayer({
                    bvid: item.bvid,
                    cid: item.cid,
                    videoPath: item.videoPath,
                    audioPath: item.audioPath || '',
                    fullscreenRequest: this.fullscreenRequest,
                    onClose: () => { this.collapsePlayer(); }
                  })
                  // 信息区（标题 + 进度）
                  Row() {
                    Column() {
                      Text(item.title)
                        .fontSize(14).fontWeight(FontWeight.Medium)
                        .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      CacheItemProgress({
                        bvid: item.bvid,
                        cid: item.cid,
                        status: item.status,
                        qualityLabel: item.qualityLabel || ''
                      })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    .margin({ left: 12 })
                    // ⭐ 全屏按钮：圆形 + 全屏图标，点击进入内置全屏（与收起按钮同风格）
                    Column() {
                      Image($r('app.media.full_screen_fill'))
                        .width(16).height(16)
                        .fillColor(this.isDarkMode ? '#FFFFFF' : '#333333')
                    }
                    .width(32).height(32)
                    .borderRadius(16)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(this.isDarkMode ? '#2C2C2E' : '#F2F2F7')
                    .margin({ right: 8 })
                    .onClick(() => {
                      this.deleting_ = true; // 阻止冒泡触发卡片 onClick
                      this.fullscreenRequest++;
                    })
                    // ⭐ 收起按钮：圆形 + 朝上箭头（chevron_down 旋转 180°），点击收起展开的视频
                    Column() {
                      Image($r('app.media.chevron_down'))
                        .width(16).height(16)
                        .fillColor(this.isDarkMode ? '#FFFFFF' : '#333333')
                        .rotate({ angle: 180 })
                    }
                    .width(32).height(32)
                    .borderRadius(16)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .backgroundColor(this.isDarkMode ? '#2C2C2E' : '#F2F2F7')
                    .margin({ right: 4 })
                    .onClick(() => {
                      this.deleting_ = true; // 阻止冒泡触发卡片 onClick
                      this.collapsePlayer();
                    })
                  }
                  .width('100%')
                  .margin({ top: 10 })
                }
                .width('100%')
                .padding(12)
                .backgroundColor(this.isDarkMode ? '#1C1C1E' : '#FFFFFF')
                .borderRadius(16)
                .onClick(() => {
                  if (this.deleting_) {
                    this.deleting_ = false;
                    return;
                  }
                  // 展开中：点击不收起（关闭按钮负责收起）
                })
              } else {
              Row() {
                // 封面
                Stack() {
                  if (item.cover) {
                    Image(item.cover)
                      .width(120).height(68)
                      .objectFit(ImageFit.Cover)
                      .borderRadius(8)
                  } else {
                    Column().width(120).height(68).borderRadius(8)
                      .backgroundColor(this.isDarkMode ? '#2C2C2E' : '#F2F2F7')
                  }
                  // 状态角标
                  Text(this.statusText(item.status))
                    .fontSize(10).fontColor(Color.White)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor(item.status === CacheStatus.COMPLETED ? '#34C759' : '#FF9500')
                    .borderRadius(4)
                    .position({ bottom: 4, right: 4 })
                }

                // 信息
                Column() {
                  Text(item.title)
                    .fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  // ⭐ 进度与大小由子组件定时轮询刷新（key 不含 downloadedBytes → 封面不再整行重建闪烁）
                  CacheItemProgress({
                    bvid: item.bvid,
                    cid: item.cid,
                    status: item.status,
                    qualityLabel: item.qualityLabel || ''
                  })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 12 })

                // 操作按钮：暂停/继续（删除改为左滑）
                Column() {
                  // ⭐ 下载中 → 暂停；已暂停 → 继续
                  if (item.status === CacheStatus.DOWNLOADING) {
                    Column() {
                      Image($r('app.media.ic_public_pause'))
                        .width(20).height(20)
                        .fillColor('#FF9500')
                    }
                    .width(36).height(36).borderRadius(18)
                    .backgroundColor('rgba(255,149,0,0.12)')
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .onClick(() => {
                      this.deleting_ = true;
                      this.pauseItem(item);
                    })
                  } else if (item.status === CacheStatus.PAUSED) {
                    Column() {
                      Image($r('app.media.ic_public_play'))
                        .width(20).height(20)
                        .fillColor('#007AFF')
                    }
                    .width(36).height(36).borderRadius(18)
                    .backgroundColor('rgba(0,122,255,0.12)')
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
                    .onClick(() => {
                      this.deleting_ = true;
                      this.resumeItem(item);
                    })
                  }
                }
                .alignItems(HorizontalAlign.End)
              }
              .width('100%')
              .padding(12)
              .backgroundColor(this.isDarkMode ? '#1C1C1E' : '#FFFFFF')
              .borderRadius(16)
              .onClick(() => {
                if (this.deleting_) {
                  this.deleting_ = false;
                  return;
                }
                // ⭐ 按状态分发：下载中→暂停，已暂停→继续，已完成→播放
                if (item.status === CacheStatus.DOWNLOADING) {
                  this.pauseItem(item);
                } else if (item.status === CacheStatus.PAUSED) {
                  this.resumeItem(item);
                } else {
                  this.playItem(item);
                }
              })
              }
            }
            // ⭐ 左滑露出删除按钮（红色），右滑直接触发全屏
            .swipeAction({
              start: {
                onAction: (): void => {
                  this.deleting_ = true;
                  if (item.status === CacheStatus.COMPLETED) {
                    this.playItem(item);
                    this.fullscreenRequest++;
                  }
                }
              },
              end: this.swipeDeleteButton(item)
            })
            // ⭐ 横屏两列时右侧留 8vp 列间距（lanes 模式无 columnsGap，用 margin 实现）
            .margin({ right: this.isLandscape ? 8 : 0 })
            // ⭐ 展开播放的卡片置顶，视频自适应宽度时不被相邻卡片覆盖
            .zIndex(this.isPlaying(item) ? 1 : 0)
          // ⭐ key 不含 downloadedBytes：进度由子组件轮询刷新，避免整行重建导致封面闪烁
          }, (item: OfflineCacheItem) => `${item.bvid}_${item.cid}_${item.status}`)
        }
        .width('100%')
        .layoutWeight(1)
        // ⭐ 横屏两列：横屏时 lanes=2（展开播放也保持两列，播放卡片自适应宽度挤压相邻）
        .lanes(this.isLandscape ? 2 : 1)
        .padding({ left: 16, right: 16 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? '#000000' : '#F2F2F7')
  }
}
