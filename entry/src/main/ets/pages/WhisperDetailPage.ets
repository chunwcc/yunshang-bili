// WhisperDetailPage.ets — 私聊会话页（跟UP主聊天）
import { router, LengthMetrics, curves, window, KeyboardAvoidMode } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';
import { ImGrpcService, ImFetchResult } from '../services/ImGrpcService';
import { getUserFaceByMid, getUserInfo } from '../api/BilibiliApi';
import { ImMessage, ImMsgType } from '../model/ImMessage';
import { WhisperInputBar } from '../components/WhisperInputBar';
import { FullImagePreview } from '../components/FullImagePreview';
import { ChatEmote, ChatTextSegment } from '../utils/ChatEmote';

/** 单条消息 UI 模型（含显示侧字段） */
class ChatItem {
  msg: ImMessage = new ImMessage();
  /** 是否自己发送（决定气泡左右） */
  isMine: boolean = false;
  /** 显示文本 */
  text: string = '';
  /** 图片 URL（图片消息） */
  picUrl: string = '';
  /** 视频分享消息（分享的视频卡片） */
  videoTitle: string = '';
  videoCover: string = '';
  videoBvid: string = '';
  videoView: string = '';
  videoTimes: string = '';
}

/** 图片 URL 追加压缩参数（hdslb 图床）：预览用 1600w 压缩图，秒开（同动态页） */
function resizeImageUrl(url: string, width: number): string {
  if (!url || !url.includes('hdslb.com')) {
    return url;
  }
  // ⚠️ 原实现 `!url.includes('@')`：URL 已带后缀时**整段跳过压缩** → 原图整张解码
  const at: number = url.indexOf('@');
  const base: string = (at > url.lastIndexOf('/') && url.indexOf('?') < 0) ? url.substring(0, at) : url;
  return base + `@${width}w`;
}

@Entry
@Component
struct WhisperDetailPage {
  /** 对方 uid（UP主 mid） */
  @State talkerId: number = 0;
  /** 对方昵称 */
  @State talkerName: string = '';
  /** 对方头像 */
  @State talkerFace: string = '';
  /** 我自己的头像（getUserInfo 异步补取） */
  @State myFace: string = '';
  /** 我自己的 mid */
  @State myMid: number = 0;
  /** 消息列表（旧→新，底部最新） */
  @State messages: ChatItem[] = [];
  /** 加载中 */
  @State isLoading: boolean = true;
  /** 加载失败 */
  @State loadError: string = '';
  /** 是否还有更早的消息 */
  @State hasMore: boolean = true;
  /** 是否正在加载更早消息 */
  @State isLoadingMore: boolean = false;
  /** 游标：当前最旧消息的 seqno */
  private endSeqno: number | null = null;
  /** 是否已自动已读 */
  private acked: boolean = false;
  @StorageLink('navIndicatorHeight') navIndicatorHeight: number = 0;
  /** 状态栏高度（vp，EntryAbility 启动时换算好，无需本页重新读窗口 px 值） */
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  /** 全局壁纸设置（与首页/消息页一致：builtin 内置 / custom 自定义图片 / 纯色） */
  @StorageLink('wallpaper') wallpaper: string = 'builtin';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;
  @StorageLink('wallpaperColor') wallpaperColor: string = '#007DFF';
  /** 全局主题色（与首页/消息页一致，设置页可改） */
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  /** 卡片样式（与消息页会话列表一致）：透明风格开关 + 背景透明度 */
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  @State imageLoadFailed: boolean = false;
  /** 表情表是否已加载（加载完成后重渲染消息，替换 [xxx] 表情为图片） */
  @State emoteReady: boolean = false;
  /** 表情面板是否打开（返回键拦截用） */
  @State emoteOpen: boolean = false;
  /** 键盘高度（px→vp，仅用于键盘弹起时触发一次滚底） */
  @State keyboardH: number = 0;

  /** ⭐ 返回键/右滑返回：表情面板打开时拦截，只关闭面板不退出页面 */
  onBackPress(): boolean {
    if (this.emoteOpen) {
      const v: number = (AppStorage.get<number>('closeEmoteSignal') ?? 0) + 1;
      AppStorage.set('closeEmoteSignal', v);
      return true;
    }
    return false;
  }
  /** ⭐ 聊天图片全屏预览（仿动态页 FullImagePreview 方案） */
  @State @Watch('onShowPreviewChange') showPreview: boolean = false;
  @State previewImageUrls: string[] = [];
  @State previewIndex: number = 0;
  @State previewOriginX: number = 0;
  @State previewOriginY: number = 0;
  @State previewOriginW: number = 0;
  @State previewOriginH: number = 0;
  @State previewThumbIds: string[] = [];
  @State previewSinkScale: number = 1.0;
  @State previewSinkY: number = 0;

  /** showPreview 变化时同步背景动画状态（打开放大 1.05，关闭恢复；同动态页） */
  onShowPreviewChange(_propName: string): void {
    this.previewSinkScale = this.showPreview ? 1.05 : 1.0;
    this.previewSinkY = 0;
  }
  /** 系统级沉浸光感材质（毛玻璃来源，探测后设置） */
  @State customMaterialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.ADAPTIVE;
  @State customMaterialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
  /** 消息列表滚动控制器（绑定 List） */
  private scroller: Scroller = new Scroller();

  /**
   * 探测设备支持的沉浸光感材质；不支持则降级 ADAPTIVE（避免系统资源解析失败闪烁）
   */
  private probeImmersiveMaterial(): void {
    try {
      const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      if (types && types.includes(hdsMaterial.MaterialType.IMMERSIVE)) {
        this.customMaterialType = hdsMaterial.MaterialType.IMMERSIVE;
      } else {
        this.customMaterialType = hdsMaterial.MaterialType.ADAPTIVE;
      }
      this.customMaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;
      logInfo(`[WhisperDetail] 沉浸光感材质类型: ${this.customMaterialType}`);
    } catch (e) {
      this.customMaterialType = hdsMaterial.MaterialType.ADAPTIVE;
      this.customMaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;
    }
  }

  /**
   * 自己消息气泡背景：跟随全局主题色；主题色过亮时压暗 25%，保证白字可读
   */
  private getMineBubbleBg(): string {
    const c: string = this.customThemeColor;
    const hex: string = c.startsWith('#') ? c.slice(1) : c;
    if (hex.length !== 6) {
      return c;
    }
    const r: number = parseInt(hex.slice(0, 2), 16);
    const g: number = parseInt(hex.slice(2, 4), 16);
    const b: number = parseInt(hex.slice(4, 6), 16);
    if (Number.isNaN(r) || Number.isNaN(g) || Number.isNaN(b)) {
      return c;
    }
    // 人眼感知亮度（YIQ 加权）
    const brightness: number = 0.299 * r + 0.587 * g + 0.114 * b;
    if (brightness <= 180) {
      return c;
    }
    const factor: number = 0.75;
    const d: (v: number) => string = (v: number): string => {
      const s: string = Math.round(v).toString(16);
      return s.length === 1 ? '0' + s : s;
    };
    return `#${d(r * factor)}${d(g * factor)}${d(b * factor)}`;
  }

  /**
   * 对方消息气泡背景：与消息页会话列表卡片一致，受卡片样式设置控制
   */
  private getCardItemBg(): string {
    if (this.cardTransparentStyle) {
      return this.isDarkMode
        ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
        : `rgba(255,255,255,${this.cardBgOpacity / 100})`;
    }
    return this.isDarkMode ? '#2C2C2C' : '#E8E8E8';
  }

  /**
   * 纯色背景色（与首页/消息页一致）：custom_color 用壁纸色，其余跟随深色模式
   */
  private getSolidBackground(): string {
    if (this.wallpaper === 'custom_color') {
      return this.wallpaperColor;
    }
    return this.isDarkMode ? '#121212' : '#FFFFFF';
  }

  /**
   * 全局壁纸明暗效果层（与首页/消息页一致）：darkness<50 加深色罩、>50 加白色罩
   */
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

  async aboutToAppear(): Promise<void> {
    this.probeImmersiveMaterial();
    // ⭐ 官方聊天页键盘方案：RESIZE 压缩窗口高度（消息区/输入栏自然位于键盘上方），
    //    表情面板作为 RichEditor.customKeyboard 参与避让
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      const ctx = this.getUIContext().getHostContext() as common.Context;
      window.getLastWindow(ctx).then((win: window.Window) => {
        win.on('keyboardHeightChange', (h: number) => {
          const k: number = this.getUIContext().px2vp(h);
          // ⭐ 键盘/面板弹起瞬间把消息滚回底部（消息区底已由 RESIZE 抬到输入栏上方）
          if (k > 0 && this.keyboardH <= 0) {
            setTimeout(() => {
              this.scroller.scrollEdge(Edge.Bottom);
            }, 60);
          }
          this.keyboardH = k;
        });
      });
    } catch (_) {}
    ChatEmote.waitForLoaded().then(() => {
      this.emoteReady = true;
    });
    const params = router.getParams() as Record<string, Object>;
    if (params) {
      this.talkerId = (params['talkerId'] as number) || 0;
      this.talkerName = (params['name'] as string) || '';
      this.talkerFace = (params['face'] as string) || '';
    }
    this.myMid = ImGrpcService.getMyMid();
    // ⚠️ 我自己的头像异步补取（不阻塞消息加载；getUserInfo 可能被限流重试）
    this.loadMyFace();
    // ⚠️ 会话接口可能不返回头像，改用 REST 用户名片接口补取（card.data.face）
    if (!this.talkerFace && this.talkerId > 0) {
      try {
        const face = await getUserFaceByMid(this.talkerId);
        if (face) {
          this.talkerFace = face;
        }
      } catch (err) {
        logWarn(`[WhisperDetail] 获取头像失败: ${errMsg(err)}`);
      }
    }
    await this.loadHistory();
  }

  /**
   * 异步补取我自己的头像（nav 接口 face）
   */
  private async loadMyFace(): Promise<void> {
    if (this.myMid <= 0) {
      return;
    }
    try {
      const user = await getUserInfo();
      if (user && user.isLogin && user.face) {
        this.myFace = user.face;
      }
    } catch (err) {
      logWarn(`[WhisperDetail] 获取自己头像失败: ${errMsg(err)}`);
    }
  }

  aboutToDisappear(): void {
    // ⭐ 恢复系统默认 OFFSET 避让并移除监听（避免影响其它页面）
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
    } catch (_) {}
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context;
      window.getLastWindow(ctx).then((win: window.Window) => {
        win.off('keyboardHeightChange');
      });
    } catch (_) {}
    if (!this.acked && this.messages.length > 0) {
      const lastSeqno = this.messages[this.messages.length - 1].msg.msgSeqno;
      if (lastSeqno > 0) {
        ImGrpcService.ackSessionMsg(this.talkerId, lastSeqno);
      }
    }
  }

  /**
   * 拉取最新消息（首次进入 / 发送成功后）
   */
  private async loadHistory(): Promise<void> {
    if (this.myMid <= 0) {
      this.isLoading = false;
      this.loadError = '请先登录';
      return;
    }
    this.isLoading = true;
    this.loadError = '';
    try {
      const result: ImFetchResult = await ImGrpcService.fetchSessionMsgs(this.talkerId, null);
      this.hasMore = result.hasMore === 0;
      this.endSeqno = result.messages.length > 0 ? result.messages[result.messages.length - 1].msgSeqno : null;
      // 服务端返回新→旧，需要反转为旧→新（底部最新）
      const reversed: ChatItem[] = [];
      for (let i = result.messages.length - 1; i >= 0; i--) {
        reversed.push(this.toChatItem(result.messages[i]));
      }
      this.messages = reversed;
      // 自动已读：用本页最大 seqno
      if (!this.acked && result.messages.length > 0) {
        this.acked = true;
        const maxSeqno = result.messages[0].msgSeqno;
        ImGrpcService.ackSessionMsg(this.talkerId, maxSeqno);
      }
      logInfo(`[WhisperDetail] 加载 ${this.messages.length} 条消息`);
    } catch (err) {
      logError(`[WhisperDetail] 加载失败: ${errMsg(err)}`);
      this.loadError = '加载失败，请检查网络';
    }
    this.isLoading = false;
  }

  /**
   * 触底加载更早的消息（游标 endSeqno）
   */
  private async loadMore(): Promise<void> {
    if (this.isLoadingMore || !this.hasMore || this.endSeqno === null) {
      return;
    }
    this.isLoadingMore = true;
    try {
      const result: ImFetchResult = await ImGrpcService.fetchSessionMsgs(this.talkerId, this.endSeqno);
      this.hasMore = result.hasMore === 0;
      if (result.messages.length > 0) {
        this.endSeqno = result.messages[result.messages.length - 1].msgSeqno;
        const older: ChatItem[] = [];
        for (let i = result.messages.length - 1; i >= 0; i--) {
          older.push(this.toChatItem(result.messages[i]));
        }
        // 更早的消息插到最前面
        this.messages = [...older, ...this.messages];
      }
    } catch (err) {
      logWarn(`[WhisperDetail] 加载更早消息失败: ${errMsg(err)}`);
    }
    this.isLoadingMore = false;
  }

  /**
   * Msg → 展示模型
   */
  private toChatItem(msg: ImMessage): ChatItem {
    const item = new ChatItem();
    item.msg = msg;
    item.isMine = msg.senderUid === this.myMid;
    if (msg.msgType === ImMsgType.PIC) {
      item.picUrl = msg.getPicUrl();
      item.text = '';
    } else {
      item.text = msg.getText();
      item.picUrl = '';
      // ⚠️ 视频分享消息：content 或 getText 提取结果含 bvid → 解析为视频卡片（兼容嵌套/转义/直接 JSON 形态）
      const hasVideo: boolean = msg.content.indexOf('bvid') >= 0 || item.text.indexOf('bvid') >= 0;
      if (hasVideo) {
        try {
          // 解析源：优先原始 content；content 无 bvid 时用 getText 提取的文本（可能是视频 JSON）
          let raw: string = msg.content.indexOf('bvid') >= 0 ? msg.content : item.text;
          // 嵌套形态：外层 {"content":"{...}"}，content 字段是字符串化的视频 JSON
          if (raw.indexOf('"content"') >= 0) {
            const outer = JSON.parse(raw) as Record<string, Object>;
            const inner = outer['content'];
            if (typeof inner === 'string' && inner.indexOf('bvid') >= 0) {
              raw = inner;
            }
          }
          const v = JSON.parse(raw) as Record<string, Object>;
          item.videoBvid = (v['bvid'] as string) || '';
          item.videoCover = (v['cover'] as string) || '';
          item.videoTitle = (v['title'] as string) || '';
          item.videoView = this.formatCount((v['view'] as number) || 0);
          item.videoTimes = this.formatDuration((v['times'] as number) || 0);
          item.text = '';
        } catch (err) {
          logWarn(`[WhisperDetail] 视频分享解析失败: ${errMsg(err)} raw=${msg.content.substring(0, 80)}`);
        }
      }
    }
    // ⚠️ 诊断日志：msgType=18 系统提示消息解析辅助（定位乱码）
    if (msg.msgType === 18) {
      logInfo(`[WhisperDetail] 系统提示 msgType=${msg.msgType} msgSource=${msg.msgSource} senderUid=${msg.senderUid} content=${msg.content} → text=${item.text}`);
    }
    return item;
  }

  /**
   * 格式化时间（今天显示 HH:mm，否则 MM-DD HH:mm）
   */
  private formatTime(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d = new Date(ts * 1000);
    const now = new Date();
    const hh = d.getHours().toString().padStart(2, '0');
    const mm = d.getMinutes().toString().padStart(2, '0');
    const hm = `${hh}:${mm}`;
    if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()) {
      return hm;
    }
    const mo = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd = d.getDate().toString().padStart(2, '0');
    return `${mo}-${dd} ${hm}`;
  }

  /**
   * 播放量格式化：>=1万显示 x.x万，否则原数
   */
  private formatCount(count: number): string {
    if (count >= 10000) {
      return `${(count / 10000).toFixed(1)}万`;
    }
    return count.toString();
  }

  /**
   * 时长格式化：秒 → mm:ss
   */
  private formatDuration(seconds: number): string {
    if (seconds <= 0) {
      return '';
    }
    const mm = Math.floor(seconds / 60).toString().padStart(2, '0');
    const ss = (seconds % 60).toString().padStart(2, '0');
    return `${mm}:${ss}`;
  }

  /**
   * 跳转视频播放页（与收藏页同款传参：?bvid=xxx）
   */
  private openVideo(bvid: string): void {
    try {
      // ⚠️ 路由不支持 URL 查询参数（?bvid= 报 Uri error），改用 params 对象传参
      const params: Record<string, Object> = { 'bvid': bvid };
      this.getUIContext().getRouter().pushUrl({ url: 'pages/VideoPlayerPage', params: params }).catch((err: Error) => {
        logError(`[WhisperDetail] 跳转视频失败: ${errMsg(err)}`);
      });
    } catch (err) {
      logError(`[WhisperDetail] 跳转视频失败: ${errMsg(err)}`);
    }
  }

  /**
   * 聊天气泡旁的头像（对方在左 / 自己在右；未加载时显示占位圆）
   */
  @Builder
  chatAvatar(face: string) {
    Column() {
      if (face) {
        Image(face)
          .width(38).height(38)
          .borderRadius(19)
          .objectFit(ImageFit.Cover)
      } else {
        Circle()
          .width(38).height(38)
          .fill(this.isDarkMode ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.08)')
      }
    }
    .width(50)
    .alignItems(HorizontalAlign.Center)
    // ⚠️ 上移 16vp：让头像圆心明显高于气泡首行文字中心
    .translate({ y: -16 })
  }

  /**
   * 标题栏自定义内容：对方头像 + 名称居中（由 titleBar.stackBuilder 嵌入）
   */
  @Builder
  titleContentBuilder() {
    Row() {
      if (this.talkerFace) {
        Image(this.talkerFace)
          .width(28).height(28)
          .borderRadius(14)
          .objectFit(ImageFit.Cover)
      } else {
        Circle()
          .width(28).height(28)
          .fill(this.isDarkMode ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.08)')
      }
      Text(this.talkerName.length > 0 ? this.talkerName : '聊天')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        .margin({ left: 8 })
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .height('100%')
  }

  /** 聊天文本 + 表情分段渲染（Text + Span/ImageSpan 行内混排：自然换行、气泡宽度自适应） */
  @Builder
  chatTextContent(item: ChatItem) {
    Text() {
      ForEach(ChatEmote.parse(item.text), (seg: ChatTextSegment, index: number) => {
        if (seg.emoteUrl) {
          ImageSpan(seg.emoteUrl)
            .width(26)
            .height(26)
            .objectFit(ImageFit.Contain)
            .verticalAlign(ImageSpanAlignment.CENTER)
        } else {
          Span(seg.text)
        }
      }, (seg: ChatTextSegment, index: number) => `seg_${index}`)
    }
    .fontSize(15)
    .fontColor(item.isMine ? '#FFFFFF' : (this.isDarkMode ? '#E5E5E5' : '#333333'))
  }

  /** 点击聊天图片：打开全屏预览（压缩图；缩略图矩形一镜到底飞入飞回） */
  private openImagePreview(picUrl: string, thumbId: string): void {
    this.previewImageUrls = [resizeImageUrl(picUrl, 1600)];
    this.previewThumbIds = [thumbId];
    this.previewIndex = 0;
    this.captureThumbRect(thumbId);
    this.showPreview = true;
  }

  /** 记录点击缩略图相对窗口的矩形（vp），供预览一镜到底动画 */
  private captureThumbRect(thumbId: string): void {
    try {
      const info = this.getUIContext().getComponentUtils().getRectangleById(thumbId);
      this.previewOriginX = this.getUIContext().px2vp(info.windowOffset.x);
      this.previewOriginY = this.getUIContext().px2vp(info.windowOffset.y);
      this.previewOriginW = this.getUIContext().px2vp(info.size.width);
      this.previewOriginH = this.getUIContext().px2vp(info.size.height);
    } catch (e) {
      this.previewOriginX = 0;
      this.previewOriginY = 0;
      this.previewOriginW = 0;
      this.previewOriginH = 0;
    }
  }

  @Builder
  messageBubble(item: ChatItem) {
    // ⚠️ msgType=18 系统提示消息（如「对方主动回复或关注你前，最多发送1条消息」）：
    // B 站将其作为会话内消息返回（senderUid=自己），官方 UI 显示为居中灰色提示而非气泡
    if (item.msg.msgType === 18) {
      Column() {
        Text(item.text)
          .fontSize(12)
          .fontColor('#999999')
          .textAlign(TextAlign.Center)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ top: 20 })
    } else {
      Row() {
        // ⚠️ 对方消息：头像在气泡左侧；自己消息：左侧留白把气泡推向右边
        if (item.isMine) {
          Blank()
        } else {
          this.chatAvatar(this.talkerFace)
        }
        Column() {
          // 文本消息（含表情：分段渲染文字/表情图片）
          if (item.text) {
            this.chatTextContent(item)
          }
          // 图片消息（点击全屏预览）
          if (item.picUrl) {
            Image(item.picUrl)
              .width(160)
              .height(120)
              .objectFit(ImageFit.Cover)
              .borderRadius(12)
              .backgroundColor('#F0F0F0')
              .id(`chat_thumb_${item.msg.msgSeqno}`)
              .onClick(() => {
                this.openImagePreview(item.picUrl, `chat_thumb_${item.msg.msgSeqno}`);
              })
          }
          // ⚠️ 视频分享卡片（聊天气泡包裹：封面 + 标题 + 播放量/时长，点击跳转播放页）
          if (item.videoBvid) {
            Column() {
              Stack() {
                Image(item.videoCover)
                  .width('100%')
                  .height(120)
                  .objectFit(ImageFit.Cover)
                  .backgroundColor('#F0F0F0')
                Text(item.videoTimes)
                  .fontSize(10)
                  .fontColor('#FFFFFF')
                  .backgroundColor('rgba(0,0,0,0.6)')
                  .borderRadius(4)
                  .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                  .position({ bottom: 4, right: 4 })
                // ⚠️ 播放图标：ic_publi_play + 半透明
                Image($r('app.media.ic_publi_play'))
                  .width(40).height(40)
                  .opacity(0.7)
                  .position({ x: '50%', y: '50%' })
                  .translate({ x: -20, y: -20 })
              }
              .width(180)
              .height(120)
              .borderRadius(8)
              .clip(true)
              Text(item.videoTitle)
                .fontSize(13)
                .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 6 })
                .width(180)
              Text(`${item.videoView} 播放`)
                .fontSize(11)
                .fontColor('#999999')
                .margin({ top: 2 })
                .width(180)
            }
            .width(196)
            .padding(8)
            .onClick(() => {
              this.openVideo(item.videoBvid);
            })
          }
          // 时间（气泡内底部，右侧）
          Text(this.formatTime(item.msg.timestamp))
            .fontSize(10)
            .fontColor(item.isMine ? 'rgba(255,255,255,0.75)' : '#999999')
            .margin({ top: 4 })
            .alignSelf(ItemAlign.End)
        }
        // ⚠️ 气泡背景统一在此容器：文字/图片/视频 + 时间都在气泡内
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .backgroundColor(item.isMine ? this.getMineBubbleBg() : this.getCardItemBg())
        .borderRadius(12)
        .alignItems(item.isMine ? HorizontalAlign.End : HorizontalAlign.Start)
        .constraintSize({ maxWidth: '65%' })
        // ⚠️ 自己消息：头像在气泡右侧
        if (item.isMine) {
          this.chatAvatar(this.myFace)
        } else {
          Blank()
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      // ⚠️ 左右边距 16vp 与返回按钮/输入框对齐
      .padding({ left: 16, right: 16 })
      .margin({ top: 20 })
    }
  }

  build() {
    // ⚠️ HdsNavigation 顶部渐变模糊标题栏（与观看历史页同款 GRADIENT_BLUR）：
    //    静止时标题栏透明露出壁纸，滚动时渐入毛玻璃（背景保持透明，无深色背板遮挡消息）
    HdsNavigation() {
      Stack({ alignContent: Alignment.Top }) {
      // ⚠️ 聊天背景（与首页/消息页同款全局壁纸：builtin 内置 / custom 自定义图 / 纯色 + 明暗层）
      if (this.wallpaper === 'builtin') {
        Stack() {
          Image(this.isDarkMode ? $r('app.media.wallpaper_shen') : $r('app.media.wallpaper_qian'))
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
          this.wallpaperDarknessLayer()
        }
        .width('100%').height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .zIndex(0)
      } else if (this.wallpaper === 'custom' && this.customWallpaper && !this.imageLoadFailed) {
        Stack() {
          Image('file://' + this.customWallpaper)
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
            .blur(this.wallpaperBlur)
            .onError(() => {
              this.imageLoadFailed = true;
              AppStorage.set('wallpaper', 'default');
            })
            .onComplete(() => { this.imageLoadFailed = false; })
          this.wallpaperDarknessLayer()
        }
        .width('100%').height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .zIndex(0)
      } else {
        Stack() {
          Column()
            .width('100%').height('100%')
            .backgroundColor(this.getSolidBackground())
          this.wallpaperDarknessLayer()
        }
        .width('100%').height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .zIndex(0)
      }

      // ── 内容区（Stack 叠放：消息列表全高延伸到输入栏后方，气泡从磨砂输入框下方滑过）──
      Stack() {
        // 消息列表（透出背景图）
        if (this.isLoading) {
          Column() {
            LoadingProgress().width(32).height(32).color('#FF6699')
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
                this.loadHistory();
              })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 0, scroller: this.scroller, initialIndex: this.messages.length > 0 ? this.messages.length : 0 }) {
            // ⚠️ 顶部 100vp 空白占位：作为列表项随滚动（不用 padding，避免滚动裁剪死区）
            ListItem() {
              Column()
                .width('100%')
                .height(100)
            }
            ForEach(this.messages, (item: ChatItem) => {
              ListItem() {
                this.messageBubble(item)
              }
              // ⚠️ key 带上 emoteReady：表情表加载完成后 key 变化强制气泡重建，
              //    否则懒列表不会刷新已渲染的 [xxx] 文字（表情一直不显示）
            }, (item: ChatItem) => `${item.msg.msgSeqno}_${this.emoteReady ? 1 : 0}`)
            // ⚠️ 底部空白占位：随输入栏浮层遮挡高度变化（滚底后最新消息停在输入栏上方）
            ListItem() {
              Column()
                .width('100%')
                // 输入栏 52 +（表情面板展开时：间距 8 + 面板 300）+ 底部间距（键盘 5 / 平时 20）
                .height(52 + (this.emoteOpen ? 308 : 0) + (this.keyboardH > 0 ? 5 : 20))
            }
          }
          .width('100%')
          // ⭐ 全高：列表延伸到输入栏浮层后方（气泡滑过输入框下方，透过磨砂胶囊可见）
          .height('100%')
          .scrollBar(BarState.Off)
          // ⚠️ List 透明：透出底层背景图
          .backgroundColor(Color.Transparent)
          // ⭐ 点消息列表（非输入组件不夺焦）：清焦点收起键盘，并通知输入栏收表情面板
          .onClick(() => {
            try {
              this.getUIContext().getFocusController().clearFocus();
            } catch (_) {}
            const v: number = (AppStorage.get<number>('closeEmoteSignal') ?? 0) + 1;
            AppStorage.set('closeEmoteSignal', v);
          })
          .onReachEnd(() => {
            this.loadMore();
          })
        }

        // ── 底部输入栏浮层（原文档流改悬浮：气泡从输入框下方滑过）──
        // ⚠️ 全高容器 + 底对齐；hitTestBehavior(Transparent) 让空白区域点击穿透到消息列表（清焦点/收面板）
        Column() {
          Blank()
          // 外层 Row 提供左右留白；键盘弹出时贴键盘（5vp），收起时离屏底 20vp
          Row() {
          WhisperInputBar({
            talkerId: this.talkerId,
            onSent: () => {
              this.loadHistory();
            },
            onEmoteChange: (open: boolean): void => {
              this.emoteOpen = open;
              if (open) {
                // ⭐ 面板展开动画期间消息区高度逐帧缩小，分两次滚底保证最新消息贴着输入框上方
                setTimeout(() => {
                  this.scroller.scrollEdge(Edge.Bottom);
                }, 60);
                setTimeout(() => {
                  this.scroller.scrollEdge(Edge.Bottom);
                }, 200);
              }
            }
          })
            .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          // ⭐ 键盘弹出时贴键盘（5vp），收起时恢复离屏底 20vp。
          //    表情面板为弹层（显示在输入框上方悬浮，2026-09-24 用户定稿），输入栏不再让位
          .margin({ bottom: this.keyboardH > 0 ? 5 : 20 })
        }
        .width('100%')
        .height('100%')
        // ⭐ 底对齐（Blank + End 双保险，红线配方）：输入栏贴容器底
        .justifyContent(FlexAlign.End)
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .height('100%')
      .zIndex(1)

      // ⭐ 聊天图片全屏预览（缩略图点击→原图；Swiper 滑动 + 双指缩放，一镜到底飞入飞回）
      FullImagePreview({
        isShow: $showPreview,
        previewUrls: this.previewImageUrls,
        thumbIds: this.previewThumbIds,
        initialIndex: this.previewIndex,
        originX: $previewOriginX,
        originY: $previewOriginY,
        originW: $previewOriginW,
        originH: $previewOriginH,
        immersiveMode: false
      })
    }
      .width('100%')
      .height('100%')
      // ⭐ 打开预览时背景放大（iOS 式 modal 层级感），关闭恢复；弹簧曲线同预览一镜到底
      .scale({ x: this.previewSinkScale, y: this.previewSinkScale })
      .translate({ y: this.previewSinkY })
      .animation({ curve: curves.interpolatingSpring(0, 1, 228, 22) })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      padding: { start: LengthMetrics.vp(16), end: LengthMetrics.vp(16) },
      style: {
        // ★ 滚动触发的渐变模糊带（滚动 0→20vp 内渐入毛玻璃）
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        // ★ 系统级沉浸光感材质（毛玻璃来源）
        systemMaterialEffect: {
          materialType: this.customMaterialType,
          materialLevel: this.customMaterialLevel
        },
        // ★ 静止状态：常驻系统材质毛玻璃（blurRadius 强制模糊，打开即模糊不依赖滚动）
        originalStyle: {
          backgroundStyle: {
            backgroundColor: 'transparent',
            blurRadius: 20
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: this.isDarkMode ? '#FFFFFF' : '#000000'
            }
          }
        },
        // ★ 滚动状态：与静止态一致的材质毛玻璃（无跳变）
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: 'transparent',
            blurRadius: 20
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: this.isDarkMode ? '#FFFFFF' : '#000000'
            }
          }
        }
      },
      content: {
        title: { mainTitle: '' },
        stackBuilder: (): void => {
          this.titleContentBuilder();
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .mode(NavigationMode.Stack)
    // ★ 不 bindToScrollable：绑定后标题栏会参与 CoordScroll 协调滚动，滚动时随内容位移，
    //    顶部模糊会被带走消失。去掉绑定后标题栏固定，模糊由 originalStyle 半透明毛玻璃底常驻
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
  }
}
