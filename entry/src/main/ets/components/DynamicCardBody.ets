import { SpaceDynamicItem, DynImageInfo, DynVideoInfo, prefetchVideoDetail } from '../api/BilibiliApi';
import { promptAction } from '@kit.ArkUI';
import { ObservableDynLike } from '../model/ObservableDynLike';
import { DynLikePill } from './DynLikePill';
import { DynamicTextContent } from './DynamicTextContent';
import { fmtCount } from '../utils/NumberFormat';
import { resizeImageUrl } from '../utils/ImageUrl';
import { cardItemBg, cardItemBorder } from '../utils/CardStyle';

/** 多图网格单图角圆角：仅四角图加对应角（左上/右上/左下/右下） */
interface DynCornerRadius {
  topLeft?: number;
  topRight?: number;
  bottomLeft?: number;
  bottomRight?: number;
}

/**
 * 动态卡片主体（按类型分发：视频 / 图文 / 番剧 / 专栏 / 文字 / 转发 / 不支持）
 *
 * ⭐ 抽成组件的唯一原因：**动态流与动态详情页必须长得一模一样**。
 *    本工程"同款外观多副本"已多次造成漏改返工，所以卡片族只保留这一份实现：
 *      - 动态页：作者行 + DynamicCardBody + 统计行
 *      - 详情页：作者行 + DynamicCardBody（不再另写一套媒体条）
 * 组件**自带图片预览**（含缩略图"一镜到底"飞入）与跳转，不依赖页面状态；
 * 点赞状态由父页用 `like` 传入（@ObjectLink：改字段只刷新胶囊，不重建卡片）。
 *
 * ⚠️ 动态页首屏性能相关：这里不要加 @Reusable（与评论条目同理，@ObjectLink 绑定链复用不可靠），
 *    也不要往里加任何"每次 build 都新建对象/数组"的写法。
 */
@Component
export struct DynamicCardBody {
  @Prop item: SpaceDynamicItem;
  /** 点赞状态（父页按动态 id 缓存同一实例传入；视频卡内的点赞胶囊用它） */
  @ObjectLink like: ObservableDynLike;
  /** 点击"卡片本体"（非图片/媒体）时回调：动态页传"进详情页"，详情页不传（点了不做事） */
  onTapSelf?: () => void;
  onToggleLike?: () => void;
  /**
   * ⭐ 图片预览**必须交回页面**：全屏预览浮层（FullImagePreview）要靠 `expandSafeArea` 铺满整屏，
   *    放进卡片组件里会被滚动容器限制尺寸与层级 ⇒ 缩略图"一镜到底"飞入会飞错位置。
   *    组件只负责：算出预览 URL/缩略图 id/点击索引 + 读取缩略图矩形，全部回调给页面。
   * @param urls     预览图地址（压缩图，1600w）
   * @param thumbIds 每张图对应的缩略图组件 id（与 urls 对齐，关闭时飞回当前位置）
   * @param index    初始索引
   * @param ox/oy/ow/oh 缩略图相对窗口的 vp 矩形（全 0 = 预览浮层退化为中心缩放）
   */
  onPreview?: (urls: string[], thumbIds: string[], index: number,
    ox: number, oy: number, ow: number, oh: number) => void;

  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 15;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = true;

  // 图片预览状态不放在本组件：见 onPreview 注释（浮层必须挂在页面根节点才能铺满屏）

  private getCardBg(): string {
    return cardItemBg(this.isDarkMode, this.cardTransparentStyle, this.cardBgOpacity);
  }

  private getCardBorderColor(): string {
    return cardItemBorder(this.isDarkMode, this.cardTransparentStyle,
      this.cardBorderOpacity, this.cardBorderFollowTheme, this.customThemeColor);
  }

  /** 播放动态里的视频（详情预热与转场重叠，与动态页原实现一致） */
  private playDynVideo(video: DynVideoInfo | null): void {
    if (!video || !video.bvid) {
      this.getUIContext().getPromptAction().showToast({ message: '无法播放该动态视频', duration: 1500 });
      return;
    }
    prefetchVideoDetail(video.bvid);
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/VideoPlayerPage',
      params: { bvid: video.bvid, title: video.title, coverUrl: video.cover, cid: 0 }
    }).catch(() => {});
  }

  /** 打开转发源（原文）的详情页；原文没有 idStr 时退回播放原文视频 */
  private openOrigDetail(it: SpaceDynamicItem): void {
    const orig: SpaceDynamicItem | null = it.orig;
    if (orig && orig.idStr) {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/DynamicDetailPage',
        params: { dynIdStr: orig.idStr, preload: orig }
      }).catch(() => {});
      return;
    }
    this.playDynVideo(it.orig?.video ?? null);
  }

  @Builder
  dynTextSegmentsBuilder(item: SpaceDynamicItem, isCenter: boolean, bottomMargin: number) {
    DynamicTextContent({
      segments: item.textSegments,
      isCenter: isCenter,
      bottomMargin: bottomMargin
    })
  }

  /** 动态：视频类型（上图下文全宽封面：封面占满整行、高度适中 + 标题与统计在下方；封面圆角跟随卡片圆角选项） */
  @Builder
  dynVideoCard(item: SpaceDynamicItem) {
    Column() {
      if (item.text) {
        this.dynTextSegmentsBuilder(item, true, 12)
      }
      if (item.video) {
        Column() {
          // ⭐ 封面：全宽、比例 2:1（高度由 Stack 的 aspectRatio 显式约束），信息条贴死底边
          //    容器级 alignContent + 子组件 align 双保险（与 HomePage 轮播图同款）；文字底部对齐消除悬空
          Stack({ alignContent: Alignment.BottomStart }) {
            Image(resizeImageUrl(item.video.cover, 1280))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .borderRadius(this.cardListBorderRadius)
              .backgroundColor('#E8E8E8')
            Row({ space: 8 }) {
              if (item.video.durationText) {
                Text(item.video.durationText)
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#B0000000')
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(4)
              }
              Text(`${fmtCount(item.video.play)}播放`)
                .fontSize(12).fontColor('#FFFFFF')
                .fontWeight(FontWeight.Bold)
                .textShadow({ radius: 2, color: '#99000000', offsetX: 0, offsetY: 1 })
                .padding({ bottom: 2 })
              Text(`${fmtCount(item.video.danmaku)}弹幕`)
                .fontSize(12).fontColor('#FFFFFF')
                .fontWeight(FontWeight.Bold)
                .textShadow({ radius: 2, color: '#99000000', offsetX: 0, offsetY: 1 })
                .padding({ bottom: 2 })
              Blank()
              // ⭐ 播放按钮：tvdasd 图标，信息条靠右（封面右下角），70% 不透明
              Image($r('app.media.tvdasd'))
                .width(54).height(54)
                .fillColor('#FFFFFF')
                .opacity(0.7)
                .margin({ right: 8 })
            }
            .width('100%')
            // ⭐ 底部对齐：文字/按钮贴 Row 底部 = 封面底边；bottom padding 上移微呼吸
            .align(Alignment.BottomStart)
            .padding({ left: 14, right: 8, bottom: 4 })
            .alignItems(VerticalAlign.Bottom)
          }
          .width('100%')
          .aspectRatio(2 / 1)
          // 标题（最多 2 行）
          Text(item.video.title)
            .fontSize(13)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(18)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 12 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .onClick(() => { this.playDynVideo(item.video); })

        // ⭐ 统计行刻意放在「可点播放区域」之外（兄弟节点）：若点赞胶囊嵌在 playDynVideo 的 onClick
        //    内部，点它会连带触发整块播放（嵌套 TapGesture 的仲裁不保证只给最内层）。
        //    视觉位置与原实现一致（width 100% + 居中 + margin top 12）。
        Row({ space: 16 }) {
          DynLikePill({ like: this.like, onToggle: () => { if (this.onToggleLike) this.onToggleLike(); } })
          Row({ space: 4 }) {
            Image($r('app.media.share_zf'))
              .width(16).height(16)
              .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            Text(fmtCount(item.forwardCount)).fontSize(11).fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
          }
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(16)
          .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)')
          .alignItems(VerticalAlign.Center)
          Row({ space: 4 }) {
            Image($r('app.media.message_on_message'))
              .width(16).height(16)
              .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            Text(fmtCount(item.commentCount)).fontSize(11).fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
          }
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(16)
          .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)')
          .alignItems(VerticalAlign.Center)
          // ⭐ 评论胶囊 → 详情页（评论区在那边）
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => { if (this.onTapSelf) { this.onTapSelf(); } })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 12 })
      }
    }
    .width('100%')
  }

  /**
   * 多图网格显示数量：5 张只显示 4 张（2×2），7/8 张只显示 6 张（2×3），其余最多 9 张
   */
  private maxDisplayCount(count: number): number {
    let maxCount: number = Math.min(count, 9);
    if (count === 5) {
      maxCount = 4;
    } else if (count === 7 || count === 8) {
      maxCount = 6;
    }
    return maxCount;
  }

  /**
   * 将图片列表按行分组：
   * 2/4 张 → 每行 2 个（4 张为 2×2）；其余 → 每行 3 个（最多 9 张 = 3×3）
   */
  private chunkImages(images: DynImageInfo[]): DynImageInfo[][] {
    const rows: DynImageInfo[][] = [];
    const maxCount: number = this.maxDisplayCount(images.length);
    const cols: number = (maxCount === 2 || maxCount === 4) ? 2 : 3;
    for (let i: number = 0; i < maxCount; i += cols) {
      const row: DynImageInfo[] = [];
      for (let j: number = i; j < Math.min(i + cols, maxCount); j++) {
        row.push(images[j]);
      }
      rows.push(row);
    }
    return rows;
  }

  /**
   * 多图网格四角单圆角：
   * 左上图 topLeft、右上图 topRight、左下图 bottomLeft、右下图 bottomRight；
   * 额外：某行最后一个图片且下一行没有该列（下方空白，如 5 张第 3 张、7 张第 6 个）→ 该图右下角是网格右边缘拐点，补 bottomRight
   * @param rows 分好行的图片数组
   * @param rowIndex 当前行索引（0 起）
   * @param colIndex 当前列索引（0 起）
   */
  private gridCornerRadius(rows: DynImageInfo[][], rowIndex: number, colIndex: number): DynCornerRadius {
    const r: number = this.cardListBorderRadius;
    const rowCount: number = rows.length;
    const rowLen: number = rows[rowIndex].length;
    const corner: DynCornerRadius = {};
    const isRowLast: boolean = colIndex === rowLen - 1;
    const isLastRow: boolean = rowIndex === rowCount - 1;
    // 右下：本行最后一个，且（最后一行 或 下一行没有该列 → 右边缘拐点）
    const nextRowHasCol: boolean = rowIndex + 1 < rowCount && rows[rowIndex + 1].length > colIndex;
    const isBottomRight: boolean = isRowLast && (isLastRow || !nextRowHasCol);
    const isCornerCell: boolean = (rowIndex === 0 && colIndex === 0) ||
      (rowIndex === 0 && colIndex === rowLen - 1) ||
      (rowIndex === rowCount - 1 && colIndex === 0) || isBottomRight;
    if (isCornerCell) {
      // 四角图：对应单角用卡片圆角 r（保持外部轮廓圆角），其余三角小圆角 4（与内部图一致，不尖锐）
      corner.topLeft = (rowIndex === 0 && colIndex === 0) ? r : 4;
      corner.topRight = (rowIndex === 0 && colIndex === rowLen - 1) ? r : 4;
      corner.bottomLeft = (rowIndex === rowCount - 1 && colIndex === 0) ? r : 4;
      corner.bottomRight = isBottomRight ? r : 4;
    } else {
      // ⭐ 内部图片：很小的圆角（原为直角 0），轻微圆润不过分（用户需求，其他不变）
      const small: number = 4;
      corner.topLeft = small;
      corner.topRight = small;
      corner.bottomLeft = small;
      corner.bottomRight = small;
    }
    return corner;
  }

  /**
   * 是否为超长图（高/宽 > 16:9）：单图时用 3:4 竖版展示并显示「长图」标识
   */
  private isTallImage(img: DynImageInfo): boolean {
    return img.width > 0 && img.height > 0 && img.height / img.width > 16 / 9;
  }

  /**
   * 原图宽高比（宽/高）：超长图按原比例撑高后，由外层容器裁剪出顶部区域
   */
  private originalImageAspectRatio(img: DynImageInfo): number {
    if (img.width > 0 && img.height > 0) {
      return img.width / img.height;
    }
    return 1;
  }

  /**
   * 单图宽高比：
   * 普通图按原比例完整显示；超长图（高/宽 > 16:9）用 3:4 竖版展示
   */
  private singleImageAspectRatio(img: DynImageInfo): number {
    if (this.isTallImage(img)) {
      return 3 / 4;
    }
    if (img.width > 0 && img.height > 0) {
      return img.width / img.height;
    }
    return 16 / 9;
  }

  /** 超长图「长图」标识：底部居中半透明胶囊（透明可透出图片；点击穿透到图片，避免拦截展开预览） */
  @Builder
  tallImageBadge() {
    Text('长图')
      .fontSize(13)
      .fontColor('#FFFFFF')
      .fontWeight(FontWeight.Medium)
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor('rgba(0,0,0,0.45)')
      .margin({ bottom: 10 })
      // ⭐ 底部居中：作为 Stack 子组件用 align 覆盖容器 alignContent(Top)（position 无 bottom，Edges 才支持）
      .align(Alignment.Bottom)
      // ⭐ 点击穿透：胶囊只是标识，点击它应触发外层 Stack 的 onClick 打开预览
      .hitTestBehavior(HitTestMode.None)
  }

  /** 超出数量 +N 胶囊：最右下角图片叠加显示（与「长图」胶囊同尺寸，白字） */
  @Builder
  overflowBadge(count: number) {
    Text('+' + count.toString())
      .fontSize(13)
      .fontColor('#FFFFFF')
      .fontWeight(FontWeight.Medium)
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor('rgba(0,0,0,0.45)')
      .margin({ bottom: 10 })
  }

  /**
   * 图片超出显示数量（原图数 - 显示数），>0 时需要在最右下角叠加 +N
   */
  private overflowCount(total: number): number {
    return total - this.maxDisplayCount(total);
  }

  /**
   * 是否应在该图叠加 +N 胶囊：图片超出显示数量，且该图是网格最右下角
   */
  private shouldShowOverflowBadge(total: number, rows: DynImageInfo[][], rowIndex: number, colIndex: number): boolean {
    if (this.overflowCount(total) <= 0) return false;
    return rowIndex === rows.length - 1 && colIndex === rows[rowIndex].length - 1;
  }

  /** 仅当图片超出显示数量时，在最右下角图片上叠加 +N 胶囊 */
  @Builder
  overflowBadgeIfNeeded(total: number, rows: DynImageInfo[][], rowIndex: number, colIndex: number) {
    if (this.shouldShowOverflowBadge(total, rows, rowIndex, colIndex)) {
      this.overflowBadge(this.overflowCount(total))
    }
  }

  /** 点击图文图片：打开全屏预览（压缩图，左右滑动切换；预览 UI 由通用 FullImagePreview 组件渲染） */
  private openImagePreview(images: DynImageInfo[], src: string, thumbId: string): void {
    if (images.length === 0) return;
    // ⭐ 先用原图匹配点击索引（压缩后 URL 与原图不同，indexOf 会失效）
    let idx = -1;
    for (let i = 0; i < images.length; i++) {
      if (images[i].src === src) {
        idx = i;
        break;
      }
    }
    // ⭐ 预览图用压缩图（1600w）：原图 10MB+ 每次滑动重新下载近 1 秒（日志实证），压缩后秒开
    const urls: string[] = [];
    const thumbIds: string[] = [];
    for (const img of images) {
      urls.push(resizeImageUrl(img.src, 1600));
      thumbIds.push(`dyn_thumb_${img.src}`);
    }
    // ⭐ 一镜到底：读缩略图矩形（相对窗口 px → vp）后交给页面；读取失败全 0（页面会退化为中心缩放）
    let ox: number = 0;
    let oy: number = 0;
    let ow: number = 0;
    let oh: number = 0;
    try {
      const info = this.getUIContext().getComponentUtils().getRectangleById(thumbId);
      ox = this.getUIContext().px2vp(info.windowOffset.x);
      oy = this.getUIContext().px2vp(info.windowOffset.y);
      ow = this.getUIContext().px2vp(info.size.width);
      oh = this.getUIContext().px2vp(info.size.height);
    } catch (e) {
      ox = 0;
      oy = 0;
      ow = 0;
      oh = 0;
    }
    if (this.onPreview) {
      this.onPreview(urls, thumbIds, idx >= 0 ? idx : 0, ox, oy, ow, oh);
    }
  }

  /** 动态：图文类型（单图原比例完整显示/超长图 3:4；多图 2/4 张两列、其余三列九宫格；圆角跟随卡片圆角选项） */
  @Builder
  dynDrawCard(item: SpaceDynamicItem) {
    Column() {
      if (item.text) {
        this.dynTextSegmentsBuilder(item, true, 12)
      }
      if (item.images.length === 1) {
        // ⭐ 单图：普通图原比例完整显示；超长图（高/宽 > 16:9）用 3:4 竖版 + 顶部对齐 + 底部「长图」胶囊。
        // 顶部对齐实现：内层 Image 按原图比例撑高，外层 Stack 固定 3:4 并 clip + alignContent(Top) 裁剪出顶部
        // 圆角必须在外层 Stack（Image 底部超出 Stack 会被直角裁掉，放外层 clip 才能四角都圆）
        // ⚠️ onClick 必须挂在外层 Stack（内层 Image 会被胶囊 overlay/子组件覆盖拦截点击）；
        //    胶囊用 Stack 子组件 + hitTestBehavior(None)，不能用 .overlay()（空 builder 也拦截点击）
        Stack() {
          Image(resizeImageUrl(item.images[0].src, 800))
            .width('100%')
            .aspectRatio(this.originalImageAspectRatio(item.images[0]))
            .objectFit(ImageFit.Cover)
            .backgroundColor('#E8E8E8')
          // 超长图底部「长图」胶囊（点击穿透，不拦截下方图片点击）
          if (this.isTallImage(item.images[0])) {
            // ⚠️ 不依赖 .align() 覆盖外层 Stack 的 alignContent(Top)（当前版本上失效，胶囊会跑到图片顶部且无上边距）：
            //    内层 Column 撑满 3:4 可视区，justifyContent(End) 把胶囊推到底部，margin bottom 10 生效
            Column() {
              Blank()
              this.tallImageBadge()
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.Center)
            .hitTestBehavior(HitTestMode.None)
          }
        }
        .width('100%')
        .aspectRatio(this.singleImageAspectRatio(item.images[0]))
        .alignContent(Alignment.Top)
        .borderRadius(this.cardListBorderRadius)
        .clip(true)
        .id(`dyn_thumb_${item.images[0].src}`)
        .onClick(() => { this.openImagePreview(item.images, item.images[0].src, `dyn_thumb_${item.images[0].src}`); })
      } else if (item.images.length > 1) {
        // ⭐ 多图：2/4 张每行 2 个（4 张为 2×2），其余每行 3 个（最多 9 张 = 3×3）；
        // 圆角：仅四角图加对应单角（左上/右上/左下/右下），内部图片不加圆角
        Column() {
          ForEach(this.chunkImages(item.images), (row: DynImageInfo[], rowIndex: number) => {
            Row({ space: 6 }) {
              ForEach(row, (img: DynImageInfo, colIndex: number) => {
                Image(resizeImageUrl(img.src, 400))
                  // ⭐ layoutWeight 均分行宽：消除固定百分比（49%/31%）+ 固定间距导致的左右不对称
                  .layoutWeight(1)
                  .aspectRatio(1)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(this.gridCornerRadius(this.chunkImages(item.images), rowIndex, colIndex))
                  .backgroundColor('#E8E8E8')
                  // ⭐ 超出数量：最右下角图片叠加 +N 胶囊（与「长图」胶囊同尺寸、靠下，如 5 张显示 4 张 → +1）
                  .overlay(this.overflowBadgeIfNeeded(item.images.length, this.chunkImages(item.images), rowIndex, colIndex), { align: Alignment.Bottom })
                  // ⭐ 点击放大显示原图（全屏预览，左右滑动切换）
                  .id(`dyn_thumb_${img.src}`)
                  .onClick(() => { this.openImagePreview(item.images, img.src, `dyn_thumb_${img.src}`); })
              }, (img: DynImageInfo, colIndex: number) => `img_${img.src}_${colIndex}`)
            }
            .width('100%')
            .margin({ bottom: rowIndex < this.chunkImages(item.images).length - 1 ? 6 : 0 })
          }, (row: DynImageInfo[]) => row[0].src)
        }
        .width('100%')
      }
    }
    .width('100%')
  }

  /** 动态：专栏/通用卡片类型（majorType=COMMON，如专栏文章；点击打开跳转链接） */
  @Builder
  dynCommonCard(item: SpaceDynamicItem) {
    Column() {
      if (item.text) {
        this.dynTextSegmentsBuilder(item, false, 8)
      }
      if (item.common) {
        Row() {
          if (item.common.cover) {
            Image(resizeImageUrl(item.common.cover, 320))
              .width(84).height(56)
              .objectFit(ImageFit.Cover)
              .borderRadius(6)
              .backgroundColor('#E8E8E8')
          }
          Column() {
            Text(item.common.title)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .lineHeight(18)
              .width('100%')
            if (item.common.desc) {
              Text(item.common.desc)
                .fontSize(11)
                .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .lineHeight(15)
                .width('100%')
                .margin({ top: 3 })
            }
          }
          .layoutWeight(1)
          .margin({ left: 8 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .borderRadius(8)
        .backgroundColor(this.isDarkMode ? '#2A2A2A' : '#F5F6F7')
        .padding({ left: 10, right: 10 })
        // ⭐ 点卡片进动态详情页（jumpUrl 是外部 http 链接，pushUrl 只认应用内路由，所以不直跳外链）
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => { if (this.onTapSelf) { this.onTapSelf(); } })
      }
    }
    .width('100%')
  }

  /** 番剧卡封面（数据源兼容：番剧 majorType=ARCHIVE 时只有 video，common 为 null 时用 video 兜底） */
  private pgcCoverOf(item: SpaceDynamicItem): string {
    return (item.common?.cover ?? item.video?.cover) ?? '';
  }

  /** 番剧卡标题（video 兜底） */
  private pgcTitleOf(item: SpaceDynamicItem): string {
    return (item.common?.title ?? item.video?.title) ?? '';
  }

  /** 番剧卡描述（video 兜底） */
  private pgcDescOf(item: SpaceDynamicItem): string {
    return (item.common?.desc ?? item.video?.desc) ?? '';
  }

  /** 动态：番剧/影视卡片（DYNAMIC_TYPE_PGC，major.pgc/season 解析为 common；竖版海报适配番剧封面） */
  @Builder
  dynPgcCard(item: SpaceDynamicItem) {
    Column() {
      if (item.text) {
        this.dynTextSegmentsBuilder(item, true, 8)
      }
      if (this.pgcCoverOf(item) || this.pgcTitleOf(item)) {
        // ---- 横版封面（16:9，动态页卡片统一横版比例）----
        Stack({ alignContent: Alignment.BottomStart }) {
          Image(resizeImageUrl(this.pgcCoverOf(item), 1280))
            .width('100%')
            .aspectRatio(16 / 9)
            .objectFit(ImageFit.Cover)
            .backgroundColor(this.isDarkMode ? '#333333' : '#E8E8E8')
            .borderRadius(this.cardListBorderRadius)

          // 底部渐变遮罩
          Row()
            .width('100%')
            .height(30)
            .position({ bottom: 0 })
            .linearGradient({
              direction: GradientDirection.Bottom,
              colors: [['#00000000', 0], ['#66000000', 1]]
            })

          // ⭐ 播放图标：tvdasd（与视频投稿卡同款），封面右下角，70% 不透明
          Image($r('app.media.tvdasd'))
            .width(54)
            .height(54)
            .fillColor(Color.White)
            .opacity(0.7)
            .position({ bottom: 8, right: 8 })
        }
        .width('100%')
        .borderRadius(this.cardListBorderRadius)
        .clip(true)

        // ---- 标题 ----
        Text(this.pgcTitleOf(item))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(20)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 8, left: 2, right: 2 })

        // ---- 描述 ----
        if (this.pgcDescOf(item)) {
          Text(this.pgcDescOf(item))
            .fontSize(12)
            .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(17)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 4, left: 2, right: 2 })
        }
      }
    }
    .width('100%')
    .padding(8)
    // ⚠️ 背景跟随卡片样式（透明样式 → 主题色+透明度；实心 → 深/浅灰）
    .backgroundColor(this.getCardBg())
    .borderRadius(this.cardListBorderRadius)
    // ⚠️ 边框跟随卡片样式（宽度/透明度/跟随主题色）
    .border({ width: this.cardBorderWidth, color: this.getCardBorderColor() })
    .clip(true)
    .shadow({ radius: 4, color: '#10000000', offsetY: 2 })
    // ⭐ 点击应用内跳转播放页（与投稿/番剧页一致，见 openPgcLink）
    .onClick(() => { this.openPgcLink(item); })
  }

  /** 点击番剧卡：优先用解析保留的 seasonId/epId，其次从 jumpUrl 解析，应用内跳转 VideoPlayerPage 播放 */
  private openPgcLink(item: SpaceDynamicItem): void {
    // ⭐ 优先用解析时保留的 id（major.pgc/season 的 season_id/ep_id，季接口才能取到 cid）
    let seasonId: number = item.common?.seasonId ?? 0;
    let epId: number = item.common?.epId ?? 0;
    // ⭐ 解析未保留时，从 jumpUrl 中的 /ss<数字>（季 id）或 /ep<数字>（分集 id）兜底
    const url = item.common?.jumpUrl ?? '';
    if (seasonId <= 0) {
      const ssIdx = url.indexOf('/ss');
      if (ssIdx >= 0) {
        seasonId = this.parseLeadingNumber(url.substring(ssIdx + 3));
      }
    }
    if (epId <= 0) {
      const epIdx = url.indexOf('/ep');
      if (epIdx >= 0) {
        epId = this.parseLeadingNumber(url.substring(epIdx + 3));
      }
    }
    if (seasonId <= 0 && epId <= 0) {
      promptAction.showToast({ message: '暂无详情链接', duration: 1500 });
      return;
    }
    // ⭐ 应用内跳转：优先 seasonId（与 PgcChannelPage.enterSeason 一致，传 mediaId），否则 epId
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/VideoPlayerPage',
      params: {
        mediaId: seasonId > 0 ? seasonId : 0,
        epId: epId,
        title: item.common?.title ?? '',
        coverUrl: item.common?.cover ?? ''
      }
    });
  }

  /** 提取字符串开头的连续数字（用于解析 jumpUrl 中的 id），无数字返回 0 */
  private parseLeadingNumber(s: string): number {
    let num: number = 0;
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c >= 48 && c <= 57) {
        num = num * 10 + (c - 48);
      } else {
        break;
      }
    }
    return num;
  }

  /** 动态：纯文本类型 */
  @Builder
  dynTextCard(item: SpaceDynamicItem) {
    Column() {
      this.dynTextSegmentsBuilder(item, false, 0)
    }
    .width('100%')
    // ⭐ 点正文进详情页（长文在详情页不截断、且能看/发评论）
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(() => { if (this.onTapSelf) { this.onTapSelf(); } })
  }

  /** 动态：转发类型（显示转发源摘要） */
  @Builder
  dynForwardCard(item: SpaceDynamicItem) {
    Column() {
      if (item.text) {
        this.dynTextSegmentsBuilder(item, false, 8)
      }
      if (item.orig) {
        Row() {
          if (item.orig.video) {
            Image(resizeImageUrl(item.orig.video.cover, 240))
              .width(64).height(40)
              .objectFit(ImageFit.Cover)
              .borderRadius(6)
              .backgroundColor('#E8E8E8')
          }
          Column() {
            if (item.orig.video) {
              Text(item.orig.video.title)
                .fontSize(12)
                .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .lineHeight(17)
                .width('100%')
            } else {
              Text(item.orig.text)
                .fontSize(12)
                .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .lineHeight(17)
                .width('100%')
            }
            Text(`@${item.orig.authorName || '原动态'}`)
              .fontSize(10)
              .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
              .margin({ top: 4 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 8 })
        }
        .width('100%')
        .padding(10)
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)')
        .borderRadius(10)
        .alignItems(VerticalAlign.Center)
        // ⭐ 点原文引用块：进**原文**的详情页（转发源本身也是一条动态，有 idStr）；缺失时退回播放原文视频
        .onClick(() => { this.openOrigDetail(item); })
      }
    }
    .width('100%')
    // ⭐ 点转发卡其余区域：进本条转发动态的详情页
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(() => { if (this.onTapSelf) { this.onTapSelf(); } })
  }

  /** 动态：不支持的类型占位 */
  @Builder
  dynUnsupportedCard(item: SpaceDynamicItem) {
    Column() {
      if (item.text) {
        this.dynTextSegmentsBuilder(item, false, 8)
      }
      Text('暂不支持此动态类型')
        .fontSize(12)
        .fontColor('#999999')
        .padding({ top: 8, bottom: 8 })
    }
    .width('100%')
  }

  build() {
    Column() {
        if (this.item.type.startsWith('DYNAMIC_TYPE_PGC')) {
          // 番剧/影视：竖版海报卡（即使 video 已填充）
          this.dynPgcCard(this.item)
        } else if (this.item.video) {
          this.dynVideoCard(this.item)
        } else if (this.item.images.length > 0) {
          this.dynDrawCard(this.item)
        } else if (this.item.common) {
          this.dynCommonCard(this.item)
        } else if (this.item.type === 'DYNAMIC_TYPE_WORD') {
          this.dynTextCard(this.item)
        } else if (this.item.type === 'DYNAMIC_TYPE_FORWARD') {
          this.dynForwardCard(this.item)
        } else if (this.item.text) {
          // 兜底：其他类型但正文非空 → 文字卡（番剧/专栏等不至于显示"暂不支持"）
          this.dynTextCard(this.item)
        } else {
          this.dynUnsupportedCard(this.item)
        }
    }
    .width('100%')
    // ⭐ 卡片主体**所有非交互区域**（正文文字、各块之间的空隙、留白）→ 进动态详情页。
    //    ⚠️ 2026-09-18 用户报"有些卡片点击后打不开，只有点图标（评论胶囊）才能进详情页"：
    //       因为各分支只给"自己的交互区域"挂了 onClick ——
    //         · 图文卡 dynDrawCard **一处都没有**（图片只开预览浮层，正文是死区）；
    //         · 视频卡 dynVideoCard 只覆盖"封面+标题"块（点了直接播放），正文区是死区；
    //         · 专栏卡 dynCommonCard 只覆盖灰底内容块，上方正文是死区；
    //         · dynUnsupportedCard 完全没有。
    //       所以在**组件根**统一兜底：一处覆盖全部类型，也覆盖将来新增的类型。
    //    ✅ 已有明确行为的子区域靠"子组件手势优先"胜出，行为不变：
    //       图片 → 预览浮层、视频封面 → 播放、转发原文块 → 原文详情、话题/@ → 搜索 / UP 空间。
    //    ⚠️ 详情页也复用本组件但不传 onTapSelf ⇒ 详情页里点卡片主体不做事（符合预期）。
    .onClick(() => { if (this.onTapSelf) { this.onTapSelf(); } })
  }
}
