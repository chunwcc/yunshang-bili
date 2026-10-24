// RelationListPage.ets — 粉丝/关注列表页（UpSpacePage 三栏数字点击进入）
// ⭐ 布局：全屏沉浸（列表扩展至状态栏/小白条安全区，壁纸不压暗）；
//    返回键（悬浮圆钮，与首页搜索按钮同款材质）在左上角，粉丝/关注切换胶囊（与首页频道胶囊同款材质）
//    水平居中悬浮于列表之上且恒展开；下方 Swiper 左右滑动切换两个列表；
//    列表项 = 私信页同款胶囊卡片 + 右侧主题色胶囊关注按钮（点击切换并 toast）
import { router } from '@kit.ArkUI';
import { hdsMaterial } from '@kit.UIDesignKit';
import { HdsMiniBarButton } from '../components/infra/HdsMiniBarButton';
import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';
import { fetchRelationList, getFollowStatus, modifyRelation, RelationUserItem } from '../api/BilibiliApi';

/** 每页拉取数量 */
const PAGE_SIZE: number = 30;
/** 关注状态批量查询并发数 */
const STATE_BATCH: number = 5;

@Entry
@Component({ freezeWhenInactive: true })
struct RelationListPage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @StorageLink('wallpaper') wallpaper: string = 'default';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  /** 目标用户 mid */
  @State mid: number = 0;
  /** 当前面板：0 = 粉丝；1 = 关注（Swiper index 双向同步） */
  @State currentIdx: number = 0;
  private swiperController: SwiperController = new SwiperController();

  async aboutToAppear(): Promise<void> {
    const params = router.getParams() as Record<string, Object>;
    if (params) {
      this.mid = (params['mid'] as number) || 0;
      const t = (params['type'] as string) || 'fans';
      this.currentIdx = t === 'following' ? 1 : 0;
    }
  }

  /** 胶囊分段项（恒展开；选中主题色 + 底部下划线，与首页频道分段一致） */
  @Builder
  capsuleSegmentItem(idx: number, label: string) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.currentIdx === idx ? this.customThemeColor : (this.isDarkMode ? '#FFFFFF' : '#000000'))
        .width(62)
        .height(22)
        .textAlign(TextAlign.Center)
      // ⭐ 选中指示：底部主题色下划线（与首页频道分段一致）
      if (this.currentIdx === idx) {
        Row()
          .width(28)
          .height(3)
          .borderRadius(1.5)
          .backgroundColor(this.customThemeColor)
      }
    }
    .width(62)
    .height(36)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      if (this.currentIdx !== idx) {
        this.swiperController.changeIndex(idx, true);
      }
    })
  }

  build() {
    Stack() {
      // ── 壁纸层（与私信页一致：不压暗；扩展至上下安全区）──
      if (this.wallpaper === 'builtin') {
        Image(this.isDarkMode ? $r('app.media.wallpaper_shen') : $r('app.media.wallpaper_qian'))
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      } else if (this.wallpaper === 'custom' && this.customWallpaper) {
        Image('file://' + this.customWallpaper)
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
          .blur(this.wallpaperBlur)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      } else {
        Column()
          .width('100%').height('100%')
          .backgroundColor(this.isDarkMode ? '#1A1A1A' : '#F5F6F7')
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }

      // ── 全屏 Swiper：左右滑动切换粉丝/关注（列表扩展至上下安全区）──
      Swiper(this.swiperController) {
        UserListPanel({ mid: this.mid, panelType: 'fans' })
        UserListPanel({ mid: this.mid, panelType: 'following' })
      }
      .width('100%')
      .height('100%')
      .index(this.currentIdx)
      .loop(false)
      .indicator(false)
      .onChange((idx: number) => {
        this.currentIdx = idx;
      })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // ── 顶部悬浮层：返回钮（左上）+ 切换胶囊（水平居中，恒展开），悬浮于列表之上 ──
      Row() {
        // 返回按钮：悬浮圆钮（与首页搜索按钮同款 HdsMiniBarButton 材质）
        // ⚠️ 包一层 Row（struct 组件尾闭包后直接链属性解析异常，Index 同款包裹写法）
        Row() {
          HdsMiniBarButton({
            barWidth: 40,
            barHeight: 40,
            contentPadding: 4,
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
            barOverlap: true,
            barPosition: BarPosition.End,
            onButtonClick: (): void => {
              router.back();
            }
          }) {
            Image($r('app.media.ic_public_arrow_left_filled'))
              .width(24).height(24)
              .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          }
        }

        Blank()
          .layoutWeight(1)

        // 粉丝/关注切换胶囊（恒展开分段选择器，与首页频道胶囊同款材质）
        Row() {
          HdsMiniBarButton({
            barWidth: 150,
            barHeight: 40,
            contentPadding: 4,
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
            barOverlap: true,
            barPosition: BarPosition.End
          }) {
            Row() {
              this.capsuleSegmentItem(0, '粉丝')
              this.capsuleSegmentItem(1, '关注')
            }
            .padding({ left: 4, right: 4 })
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
          }
        }

        Blank()
          .layoutWeight(1)

        // 右侧对称占位（与返回钮等宽）：保证胶囊按屏幕几何中心居中
        Row()
          .width(40)
          .height(40)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 8, right: 8, top: this.hideStatusBar ? 12 : (this.statusBarHeight + 7) })
    }
    .width('100%')
    .height('100%')
    // ⭐ 悬浮层顶对齐（Stack 默认居中会把返回钮/胶囊浮到屏幕中部）；
    //    全屏沉浸：壁纸 + 列表扩展至状态栏与小白条安全区
    .alignContent(Alignment.TopStart)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

/**
 * 用户列表面板（粉丝/关注通用，Swiper 内单页）
 * 自持数据与加载/关注逻辑；列表全屏，顶部避让悬浮控件、底部避让小白条
 */
@Component
struct UserListPanel {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('hideStatusBar') hideStatusBar: boolean = false;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @StorageLink('navIndicatorHeight') navIndicatorHeight: number = 0;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  // ⭐ 卡片样式设置（与私信页会话卡片联动）
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 15;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = true;
  /** 目标用户 mid */
  @Prop mid: number = 0;
  /** 面板类型：'fans' = 粉丝；'following' = 关注 */
  @Prop panelType: string = 'fans';
  /** 列表数据 */
  @State users: RelationUserItem[] = [];
  /** 每项关注状态（与 users 下标对齐；关注列表恒 true，粉丝列表批量查询） */
  @State followedFlags: boolean[] = [];
  /** 加载中 */
  @State isLoading: boolean = true;
  /** 加载失败 */
  @State loadError: string = '';
  /** 加载更多中 */
  @State isLoadingMore: boolean = false;
  /** 页码 */
  private pn: number = 1;
  /** 是否有更多 */
  private hasMore: boolean = false;
  /** 关注状态已查询标记（非响应式） */
  private stateQueried: boolean[] = [];
  /** 关注操作进行中的 mid（防连点） */
  private pendingMid: number = -1;

  async aboutToAppear(): Promise<void> {
    await this.loadList();
  }

  /** 首屏加载 */
  private async loadList(): Promise<void> {
    if (!this.mid) return;
    this.isLoading = true;
    this.loadError = '';
    this.pn = 1;
    this.stateQueried = [];
    try {
      const result = await fetchRelationList(this.mid, this.panelType, this.pn, PAGE_SIZE);
      this.users = result.users;
      this.hasMore = result.hasMore;
      // 关注列表天然全部已关注；粉丝列表先置 false 再批量查询
      this.followedFlags = this.users.map((u: RelationUserItem) => this.panelType === 'following');
      logInfo(`[RelationListPage] ${this.panelType} 加载 ${this.users.length} 条`);
      this.isLoading = false;
      // 粉丝列表：后台批量补查关注状态（不阻塞首屏渲染）
      this.queryFollowStates();
    } catch (err) {
      logError(`[RelationListPage] ${this.panelType} 加载失败: ${errMsg(err)}`);
      this.loadError = '加载失败，请检查网络';
      this.isLoading = false;
    }
  }

  /** 分页加载更多 */
  private async loadMore(): Promise<void> {
    if (this.isLoadingMore || !this.hasMore || this.isLoading) return;
    this.isLoadingMore = true;
    try {
      const result = await fetchRelationList(this.mid, this.panelType, this.pn + 1, PAGE_SIZE);
      this.pn = this.pn + 1;
      // 去重合并
      const knownMids: Set<number> = new Set(this.users.map((u: RelationUserItem) => u.mid));
      const fresh: RelationUserItem[] = result.users.filter((u: RelationUserItem) => !knownMids.has(u.mid));
      this.users = [...this.users, ...fresh];
      this.followedFlags = [...this.followedFlags, ...fresh.map((u: RelationUserItem) => this.panelType === 'following')];
      this.stateQueried = [...this.stateQueried, ...fresh.map((u: RelationUserItem) => false)];
      this.hasMore = result.hasMore;
      logInfo(`[RelationListPage] ${this.panelType} 加载更多 ${fresh.length} 条, 累计 ${this.users.length}`);
      this.isLoadingMore = false;
      this.queryFollowStates();
    } catch (err) {
      logWarn(`[RelationListPage] 加载更多失败: ${errMsg(err)}`);
      this.isLoadingMore = false;
    }
  }

  /** 粉丝列表：批量补查关注状态（并发限流） */
  private async queryFollowStates(): Promise<void> {
    if (this.panelType !== 'fans') return;
    const pending: number[] = [];
    for (let i = 0; i < this.users.length; i++) {
      if (!this.stateQueried[i]) pending.push(i);
    }
    if (pending.length === 0) return;
    logInfo(`[RelationListPage] ${this.panelType} 补查关注状态 ${pending.length} 个`);
    for (let b = 0; b < pending.length; b += STATE_BATCH) {
      const batch: number[] = pending.slice(b, Math.min(b + STATE_BATCH, pending.length));
      const jobs: Promise<void>[] = [];
      for (const idx of batch) {
        jobs.push(this.queryOneFollowState(idx));
      }
      await Promise.all(jobs);
    }
  }

  /** 查询单个用户关注状态（失败保持 false） */
  private async queryOneFollowState(idx: number): Promise<void> {
    if (idx >= this.users.length) return;
    this.stateQueried[idx] = true;
    try {
      const followed: boolean = await getFollowStatus(this.users[idx].mid);
      const flags: boolean[] = [...this.followedFlags];
      if (idx < flags.length) {
        flags[idx] = followed;
        this.followedFlags = flags;
      }
    } catch (_e) {
      // 保持默认 false
    }
  }

  /** 切换关注状态（乐观更新 + 失败回滚；成功 toast；关注列表取关成功后移除该项） */
  private async toggleFollow(idx: number): Promise<void> {
    if (idx >= this.users.length) return;
    const targetMid: number = this.users[idx].mid;
    if (this.pendingMid === targetMid) return;
    const target: boolean = !this.followedFlags[idx];
    // 乐观更新
    const flags: boolean[] = [...this.followedFlags];
    flags[idx] = target;
    this.followedFlags = flags;
    this.pendingMid = targetMid;
    const ok: boolean = await modifyRelation(targetMid, target ? 1 : 2);
    this.pendingMid = -1;
    if (!ok) {
      // 回滚
      const rollback: boolean[] = [...this.followedFlags];
      rollback[idx] = !target;
      this.followedFlags = rollback;
      this.getUIContext().getPromptAction().showToast({ message: '操作失败，请重试', duration: 1500 });
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: target ? '关注成功' : '已取消关注', duration: 1500 });
    // 关注列表取关成功 → 移除该项（官方行为）；粉丝列表仅切换按钮状态
    if (!target && this.panelType === 'following') {
      this.removeUserAt(idx);
    }
  }

  /** 从列表移除指定下标用户 */
  private removeUserAt(idx: number): void {
    const nextUsers: RelationUserItem[] = [...this.users];
    nextUsers.splice(idx, 1);
    this.users = nextUsers;
    const nextFlags: boolean[] = [...this.followedFlags];
    nextFlags.splice(idx, 1);
    this.followedFlags = nextFlags;
    this.stateQueried.splice(idx, 1);
  }

  /** 点击用户 → 进入对方空间 */
  private openUserSpace(user: RelationUserItem): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UpSpacePage',
      params: {
        mid: user.mid,
        upName: user.uname,
        upFace: user.face
      }
    }).catch((err: Error) => {
      logError(`[RelationListPage] 进入空间失败: ${err.message}`);
    });
  }

  /** 卡片背景色（跟随卡片样式选项，与私信页一致） */
  private getCardItemBg(): string {
    if (this.cardTransparentStyle) {
      return this.isDarkMode
        ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
        : `rgba(255,255,255,${this.cardBgOpacity / 100})`;
    }
    return this.isDarkMode ? '#2C2C2C' : '#E8E8E8';
  }

  /** 卡片边框色（与私信页一致） */
  private getCardItemBorder(): string {
    if (!this.cardTransparentStyle) {
      return 'rgba(0,0,0,0)';
    }
    if (this.cardBorderFollowTheme) {
      return '#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1);
    }
    return this.isDarkMode
      ? `rgba(255,255,255,${this.cardBorderOpacity / 100})`
      : 'rgba(255,255,255,0.25)';
  }

  private opacityToHexAlpha(opacity: number): string {
    const val = Math.round(opacity / 100 * 255);
    const hex = val.toString(16);
    return hex.length === 1 ? '0' + hex : hex;
  }

  /** 顶部悬浮区总高（列表顶部避让：状态栏 + 悬浮行 40 + 间距） */
  private topInset(): number {
    return (this.hideStatusBar ? 12 : (this.statusBarHeight + 7)) + 40 + 8;
  }

  /** 用户行：私信页同款胶囊卡片（头像 + 名字/签名 + 关注按钮） */
  @Builder
  userRow(user: RelationUserItem, idx: number) {
    Row() {
      // 头像（私信页同款：圆形底 + 真图/默认图）
      Stack() {
        Circle()
          .width(46).height(46)
          .fill(this.isDarkMode ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.08)')
        if (user.face) {
          Image(user.face)
            .width(46).height(46)
            .borderRadius(23)
            .objectFit(ImageFit.Cover)
        } else {
          Image($r('app.media.tx_old'))
            .width(46).height(46)
            .borderRadius(23)
            .objectFit(ImageFit.Cover)
        }
      }
      .width(46).height(46)

      // 中间：名字 + 签名
      Column() {
        Text(user.uname)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (user.sign) {
          Text(user.sign)
            .fontSize(12)
            .fontColor(this.isDarkMode ? '#999999' : '#888888')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })

      // 右侧：胶囊关注按钮（主题色，点击切换）
      Text(this.followedFlags.length > idx && this.followedFlags[idx] ? '已关注' : '+ 关注')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.followedFlags.length > idx && this.followedFlags[idx]
          ? (this.isDarkMode ? '#999999' : '#888888')
          : '#FFFFFF')
        .textAlign(TextAlign.Center)
        .width(64)
        .height(28)
        .borderRadius(14)
        .backgroundColor(this.followedFlags.length > idx && this.followedFlags[idx]
          ? (this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.06)')
          : this.customThemeColor)
        .border({
          width: 1,
          color: this.followedFlags.length > idx && this.followedFlags[idx]
            ? (this.isDarkMode ? 'rgba(255,255,255,0.15)' : 'rgba(0,0,0,0.10)')
            : Color.Transparent
        })
        .opacity(this.pendingMid === user.mid ? 0.5 : 1)
        .clickEffect({ level: 1, scale: 0.92 })
        .margin({ left: 10 })
        .onClick(() => {
          this.toggleFollow(idx);
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.getCardItemBg())
    // ⚠️ 与私信页会话卡片统一 40vp 胶囊圆角 + 边框（跟随卡片样式设置）
    .borderRadius(40)
    .border({ width: this.cardBorderWidth, color: this.getCardItemBorder() })
    .clickEffect({ level: 1, scale: 0.98 })
    .onClick(() => {
      this.openUserSpace(user);
    })
  }

  build() {
    Stack() {
      if (this.isLoading) {
        Column() {
          LoadingProgress().width(32).height(32).color(this.customThemeColor)
          Text('加载中...').fontSize(13).fontColor('#999999').margin({ top: 8 })
        }
        .width('100%')
        .height('100%')
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
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.users.length === 0) {
        Column() {
          Text(this.panelType === 'fans' ? '暂无粉丝' : '暂无关注')
            .fontSize(14)
            .fontColor('#999999')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 6 }) {
          // ⭐ 顶部空白占位（私信页同款 ListItem 占位，随内容滚动）：悬浮控件（返回钮/胶囊）悬浮于
          //    列表之上，滚动时内容从其后方穿过 —— 真沉浸（List 固定 padding 会挡住穿越）
          ListItem() {
            Column()
              .width('100%')
              .height(this.topInset())
          }

          ForEach(this.users, (user: RelationUserItem, idx: number) => {
            ListItem() {
              this.userRow(user, idx)
            }
          }, (user: RelationUserItem) => `${user.mid}`)

          // 底部加载更多指示
          if (this.isLoadingMore) {
            ListItem() {
              Row() {
                LoadingProgress().width(20).height(20).color(this.customThemeColor)
                Text('加载中...')
                  .fontSize(12)
                  .fontColor('#999999')
                  .margin({ left: 8 })
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
              .padding(12)
            }
          } else if (!this.hasMore && this.users.length > 0) {
            ListItem() {
              Text('没有更多了')
                .fontSize(12)
                .fontColor('#999999')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding(12)
            }
          }

          // ⭐ 底部空白占位（随内容滚动）：小白条沉浸（内容滚动时从小白条后方穿过）
          ListItem() {
            Column()
              .width('100%')
              .height(this.navIndicatorHeight + 12)
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .padding({ left: 10, right: 10 })
        .onReachEnd(() => {
          this.loadMore();
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
