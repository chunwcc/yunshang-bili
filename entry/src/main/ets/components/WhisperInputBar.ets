// WhisperInputBar.ets — 沉浸光感胶囊输入框（无按压点光源）
// ⚠️ 布局方案（2026-09-23 HdsTabs 真材质版）：胶囊由 HdsTabs barFloatingStyle 承载（barWidth
//    要求数值）→ onAreaChange 测胶囊行全长，barW() = 行全长 - 发送按钮占位 - 8；
//    发送按钮容器占位宽度 buttonSpaceVp 由 Animator 逐帧驱动（0↔60vp），胶囊每帧跟随让位。
//    表情面板：真材质设备走 bindPopup 弹层通道（systemMaterial + radius 22 圆角矩形，
//    与播放器提示胶囊同款）；6.1 老机走页内 HdsTabs 面板兜底（形状是系统自绘胶囊）。
import { promptAction, Animator, AnimatorResult } from '@kit.ArkUI';
import { hdsMaterial, HdsTabs } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { logInfo, logError, errMsg } from '../utils/Logger';
import { MaterialUtil } from '../utils/MaterialUtil';
import { VibrateUtils } from '../utils/VibrateUtils';
import { ImGrpcService } from '../services/ImGrpcService';

import { HdsMiniBarButton } from './infra/HdsMiniBarButton';

import { ChatEmote, ChatEmoteItem, ChatEmotePackage } from '../utils/ChatEmote';

/** 图片格式探测结果（B站图床上传用） */
class ImageTypeInfo {
  /** 扩展名（jpg | png | gif） */
  ext: string = '';
  /** MIME 类型 */
  mime: string = '';
}

@Component
export struct WhisperInputBar {
  /** 对方 uid（UP主 mid） */
  @Prop talkerId: number = 0;
  /** 发送成功回调（父组件用于刷新消息列表） */
  onSent: () => void = () => {};
  /** 表情面板开/关回调（父页据此记录面板状态，拦截返回键） */
  onEmoteChange: (open: boolean) => void = () => {};
  /** 发送中 */
  @State isSending: boolean = false;
  /** 图片上传/发送中 */
  @State isUploading: boolean = false;
  /** 输入内容非空时显示发送按钮 */
  @State showSend: boolean = false;
  /** 输入内容是否非空（控制自绘占位文案显隐） */
  @State hasContent: boolean = false;
  /** 发送按钮容器占位宽度（vp）：0=完全收起 74=完全展开；Animator 逐帧写入，胶囊 layoutWeight 跟随让位 */
  @State buttonSpaceVp: number = 0;
  /** 我自己的 mid */
  @State myMid: number = 0;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  /** ⭐ 是否显示表情面板（页面内渲染，动画展开/收起） */
  @State showEmote: boolean = false;
  /** 表情面板高度（0=收起，Animator 逐帧驱动与消息区同步伸缩） */
  @State emoteH: number = 0;
  /** 表情面板高度 Animator（逐帧驱动，收起确保动画） */
  private emoteAnimator: AnimatorResult | null = null;
  /** 外部收面板信号（返回键/点击消息区时由父页置位） */
  @StorageLink('closeEmoteSignal') @Watch('onCloseEmoteSignal') closeEmoteSignal: number = 0;
  /** 当前选中表情分类索引 */
  @State emotePkgIdx: number = 0;
  /** 表情表是否已加载（加载后触发面板重建） */
  @State emoteReady: boolean = false;
  /** 输入框控制器 */
  private richEditorController: RichEditorController = new RichEditorController();
  /** 串行动画 token：新触发递增使旧的 setTimeout 回调作废（同 Index 胶囊切换模式） */
  private capsuleAnimToken: number = 0;
  /** 当前是否处于收窄目标态（动画开始即翻转，防连续打字重入） */
  private spaceNarrow: boolean = false;
  /** 按钮占位宽度 Animator（新动画前 cancel 旧动画，实现打断衔接） */
  private spaceAnimator: AnimatorResult | null = null;
  /** ⭐ 胶囊/面板宽度（vp）：onAreaChange 测量行宽得到——HdsTabs barWidth 必须传数值
   *    （'100%' 会溢出屏幕，见红线）；发送按钮让位动画时胶囊宽由 barW() 逐帧扣减 */
  @State capsuleW: number = 0;
  /** ⭐ 表情面板弹层通道（播放器提示同款）：bindPopup + systemMaterial + radius 圆角矩形，
   *    仅真材质可用设备（7.0/API 26+）走；6.1 老机保留页内 HdsTabs 面板兜底。
   *    ⚠️ 26.0.0 弹层新字段在老系统会打挂子树（见红线），选项须按能力分支构造 */
  @State emotePopupVisible: boolean = false;
  private emoteUsePopup: boolean = MaterialUtil.available();

  /**
   * 按钮占位宽度动画（0↔74vp）：Animator 逐帧写入 buttonSpaceVp，
   * 胶囊 layoutWeight 每帧跟随让位。显式逐帧状态驱动，不依赖 animateTo 的宽度插值
   * @param onDone 动画正常完成回调（被 cancel 打断时不触发）
   */
  private animateButtonSpace(to: number, duration: number, onDone?: () => void): void {
    if (this.spaceAnimator) {
      this.spaceAnimator.cancel();
      this.spaceAnimator = null;
    }
    const from: number = this.buttonSpaceVp;
    if (Math.abs(from - to) < 0.5) {
      this.buttonSpaceVp = to;
      if (onDone) {
        onDone();
      }
      return;
    }
    logInfo(`[WhisperInputBar] 占位宽度动画 ${from} → ${to} (${duration}ms)`);
    // ⚠️ 新版 Animator API：回调挂在返回对象上（小写 onframe/onfinish/oncancel），options 不接受回调
    this.spaceAnimator = Animator.create({
      duration: duration,
      easing: 'fast-out-slow-in',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: 1,
      begin: 0,
      end: 1
    });
    this.spaceAnimator.onframe = (progress: number) => {
      this.buttonSpaceVp = from + (to - from) * progress;
    };
    this.spaceAnimator.onfinish = () => {
      this.buttonSpaceVp = to;
      this.spaceAnimator = null;
      if (onDone) {
        onDone();
      }
    };
    this.spaceAnimator.oncancel = () => {
      this.spaceAnimator = null;
    };
    this.spaceAnimator.play();
  }

  aboutToAppear(): void {
    this.myMid = ImGrpcService.getMyMid();
  }

  /**
   * 发送文本消息
   */
  private async sendMessage(): Promise<void> {
    const content = this.buildSendContent().trim();
    if (!content) {
      promptAction.showToast({ message: '输入内容不能为空' });
      return;
    }
    if (this.isSending) {
      return;
    }
    if (this.myMid <= 0) {
      promptAction.showToast({ message: '请先登录' });
      return;
    }
    this.isSending = true;
    try {
      const ok = await ImGrpcService.sendText(this.myMid, this.talkerId, content);
      if (ok) {
        this.richEditorController.deleteSpans({ start: 0, end: 999999 });
        this.hasContent = false;
        // ⚠️ 编程清空富文本不触发 onChange，需手动复位（串行动画：
        //    按钮先收起 300ms，完成后再收占位 450ms 撑满胶囊）
        this.spaceNarrow = false;
        const token: number = ++this.capsuleAnimToken;
        this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
          this.showSend = false;
        });
        setTimeout(() => {
          if (token !== this.capsuleAnimToken) return;
          this.animateButtonSpace(0, 450);
        }, 300);
        // 通知父组件刷新消息列表
        this.onSent();
      } else {
        promptAction.showToast({ message: '发送失败' });
      }
    } catch (err) {
      logError(`[WhisperInputBar] 发送失败: ${errMsg(err)}`);
      promptAction.showToast({ message: '发送失败' });
    }
    this.isSending = false;
  }

  /** ⭐ 插入表情图片到富文本输入框（并驱动"有内容→显示发送按钮"） */
  private insertEmote(emote: ChatEmoteItem): void {
    this.richEditorController.addImageSpan(emote.url, {
      offset: this.richEditorController.getCaretOffset(),
      imageStyle: { size: [26, 26] }
    });
    this.hasContent = true;
    // ⭐ 不清理焦点：面板作为自定义键盘，输入框失焦时面板会被系统自动关闭
    if (this.richEditorController.getSpans().length > 0 && !this.spaceNarrow) {
      this.spaceNarrow = true;
      this.capsuleAnimToken++;
      this.animateButtonSpace(60, 450, () => {
        this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
          this.showSend = true;
        });
      });
    }
  }

  /** ⭐ 把富文本内容序列化为发送文本：文字段直取，图片段还原为 [xx] */
  private buildSendContent(): string {
    let content = '';
    const spans = this.richEditorController.getSpans();
    for (let i = 0; i < spans.length; i++) {
      const span = spans[i];
      const textSpan = span as RichEditorTextSpanResult;
      if (textSpan.value) {
        content += textSpan.value;
      } else {
        const imgSpan = span as RichEditorImageSpanResult;
        content += ChatEmote.getTextByUrl(imgSpan.valueResourceStr as string) || '';
      }
    }
    return content;
  }

  /** ⭐ 删除光标前一个字符/表情（退格语义） */
  private deleteLastEmote(): void {
    const caret: number = this.richEditorController.getCaretOffset();
    if (caret > 0) {
      try {
        this.richEditorController.deleteSpans({ start: caret - 1, end: caret });
      } catch (_) {}
    }
    // ⚠️ 编程删除不触发 onChange，手动同步占位文案显隐
    this.hasContent = this.richEditorController.getSpans().length > 0;
  }

  /** ⭐ 收到收面板信号（返回键/点消息区）：收起表情面板 */
  onCloseEmoteSignal(): void {
    if (this.showEmote) {
      this.setEmotePanel(false);
    }
  }

  /** ⭐ 逐帧驱动 emoteH（Animator 确定能动画，展开/收起均平滑） */
  private animateEmoteH(to: number): void {
    if (this.emoteAnimator) {
      this.emoteAnimator.cancel();
      this.emoteAnimator = null;
    }
    const from: number = this.emoteH;
    if (Math.abs(from - to) < 0.5) {
      this.emoteH = to;
      return;
    }
    this.emoteAnimator = Animator.create({
      duration: 260,
      easing: 'ease-in-out',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: 1,
      begin: 0,
      end: 1
    });
    this.emoteAnimator.onframe = (p: number) => {
      this.emoteH = from + (to - from) * p;
    };
    this.emoteAnimator.onfinish = () => {
      this.emoteH = to;
      this.emoteAnimator = null;
    };
    this.emoteAnimator.oncancel = () => {
      this.emoteAnimator = null;
    };
    this.emoteAnimator.play();
  }

  /**
   * ⭐ 开/关表情面板：
   *    真材质设备走 bindPopup 弹层（自带出入场动画，无需高度动画）；
   *    老设备走页内渲染 260ms 高度动画。
   *    开面板前清焦点收掉系统键盘（若有）；点输入框时 onFocus 自动收面板
   */
  private setEmotePanel(open: boolean): void {
    if (open) {
      try {
        this.getUIContext().getFocusController().clearFocus();
      } catch (_) {}
    }
    this.showEmote = open;
    this.onEmoteChange(open);
    if (this.emoteUsePopup) {
      // ⭐ 面板显示在输入框上方悬浮（2026-09-24 用户定稿）：锚点（输入行）静止不动，
      //    无翻转竞态，直接状态驱动显隐（弹层自带出入场动画）
      this.emotePopupVisible = open;
    } else {
      this.animateEmoteH(open ? 300 : 0);
    }
  }

  /**
   * ⭐ 表情面板弹层选项（播放器提示胶囊同款通道）：
   *    CustomPopupOptions.systemMaterial / colorMode 是 API 26.0.0 新增字段，
   *    ⚠️ 老系统解析到会打挂整棵子树（见 VideoControls 红线）——
   *    所以新字段只在能力探测通过后动态补挂，老机拿到的选项只含老字段。
   *    ⭐ placement Top = 面板悬浮在输入框上方（2026-09-24 用户定稿）；输入栏不让位。
   *    ⚠️ popup offset y 是屏幕坐标语义（+y 恒向下），与提示胶囊的"Bottom+y=远离"不同：
   *    Top 方向 +y 压向锚点（间距被吃掉=首次无间距的根源），-8 = 向上拉开 8vp。
   *    横向 x 偏移半个宽度差，保持弹层与胶囊左缘对齐（右缘随胶囊宽自适应）。
   */
  private emotePopupOpts(): CustomPopupOptions {
    const opts: CustomPopupOptions = {
      builder: (): void => { this.emotePopupBuilder(); },
      // ⭐ 面板悬浮在输入框上方（用户定稿）
      placement: Placement.Top,
      // ⭐ 间距：Top 方向 offset 以屏幕坐标计（+y 向下=压向锚点→间距被吃掉，首次实现无间距的根源）；
      //    -8 = 向上拉开 8vp 间距
      offset: { x: (this.barW() - this.capsuleW) / 2, y: -8 },
      enableArrow: false,
      autoCancel: false,
      mask: false,
      radius: 22
    } as CustomPopupOptions;
    if (this.emoteUsePopup) {
      opts.colorMode = AnchoredColorMode.FOLLOW_TARGET;
      // ⭐ 表情面板专用材质实例（绝不与 sheetMaterial/pillMaterial 共用——材质实例与
      //   挂载表面绑定，跨表面复用会让共用它的所有弹窗失效，2026-09-23 真机实证）
      opts.systemMaterial = MaterialUtil.emoteMaterial();
    }
    return opts;
  }

  /** ⭐ 轻震动反馈 */
  private triggerHaptic(): void {
    try {
      VibrateUtils.vibrateTime(15);
    } catch (_) {}
  }

  /** ⭐ 当前选中分类的表情列表 */
  private currentEmoteList(): ChatEmoteItem[] {
    const pkgs = ChatEmote.getPackages();
    if (pkgs.length === 0) {
      return [];
    }
    return pkgs[Math.min(this.emotePkgIdx, pkgs.length - 1)].emotes;
  }

  /**
   * 选择图片并发送（选图 → 拷贝到沙箱 → 上传 B站图床 → 发送图片消息）
   */
  private async pickAndSendImage(): Promise<void> {
    if (this.isSending || this.isUploading) {
      return;
    }
    if (this.myMid <= 0) {
      promptAction.showToast({ message: '请先登录' });
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = 1;
      const photoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const photoSelectResult = await photoViewPicker.select(photoSelectOptions);
      if (photoSelectResult.photoUris.length === 0) {
        return; // 用户取消
      }
      const sourceUri = photoSelectResult.photoUris[0];
      // ⚠️ 相册 URI 是媒体库临时授权路径，上传必须先用 fileIo 拷贝到沙箱
      const destUri = `${context.filesDir}/chat_img_${Date.now()}`;
      const srcFile = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      const destFile = fileIo.openSync(destUri, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      const buffer = new ArrayBuffer(4096);
      let readLen = 0;
      while ((readLen = fileIo.readSync(srcFile.fd, buffer)) > 0) {
        fileIo.writeSync(destFile.fd, buffer.slice(0, readLen));
      }
      fileIo.closeSync(srcFile.fd);
      fileIo.closeSync(destFile.fd);
      // 读取文件头判断格式（B站图床仅支持 jpg/png/gif）
      const extMime = this.detectImageType(destUri);
      if (!extMime) {
        promptAction.showToast({ message: '仅支持 jpg/png/gif 图片' });
        return;
      }
      this.isUploading = true;
      const uploaded = await ImGrpcService.uploadChatImage(destUri, extMime.mime, extMime.ext);
      if (!uploaded.url) {
        promptAction.showToast({ message: '图片上传失败' });
        return;
      }
      const ok = await ImGrpcService.sendPic(this.myMid, this.talkerId, uploaded.url, uploaded.width, uploaded.height);
      if (ok) {
        // 通知父组件刷新消息列表
        this.onSent();
      } else {
        promptAction.showToast({ message: '发送失败' });
      }
    } catch (err) {
      logError(`[WhisperInputBar] 发送图片失败: ${errMsg(err)}`);
      promptAction.showToast({ message: '发送图片失败' });
    } finally {
      this.isUploading = false;
    }
  }

  /**
   * 探测图片格式（读文件头魔数，仅支持 jpg/png/gif）
   * @returns 格式信息；不支持返回 null
   */
  private detectImageType(filePath: string): ImageTypeInfo | null {
    try {
      const probe = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const head = new ArrayBuffer(8);
      fileIo.readSync(probe.fd, head);
      fileIo.closeSync(probe.fd);
      const bytes = new Uint8Array(head);
      // JPEG: FF D8 FF；PNG: 89 50 4E 47；GIF: 47 49 46 38
      if (bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) {
        return { ext: 'jpg', mime: 'image/jpeg' };
      }
      if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) {
        return { ext: 'png', mime: 'image/png' };
      }
      if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x38) {
        return { ext: 'gif', mime: 'image/gif' };
      }
      return null;
    } catch (err) {
      logError(`[WhisperInputBar] 探测图片格式失败: ${errMsg(err)}`);
      return null;
    }
  }

  /** ⭐ 胶囊 bar 宽度（vp）：行全长 - 发送按钮占位；按钮可见时再留 8vp 左间距。
   *    buttonSpaceVp 逐帧变化 → 胶囊逐帧让位（等价于原 layoutWeight 行的自动让位）。
   *    ⚠️ 按钮隐藏（buttonSpaceVp=0）时必须占满整行——恒扣 8 会让右边距=16+8vp≠左边距
   *    （2026-09-24 用户实测"输入框右侧边距与左侧不一致"的根源） */
  private barW(): number {
    const gap: number = this.buttonSpaceVp > 0 ? 8 : 0;
    const w: number = this.capsuleW - this.buttonSpaceVp - gap;
    return w > 52 ? w : 52;
  }

  /**
   * 胶囊外壳：HdsTabs barFloatingStyle 真材质（与悬浮按钮/搜索框同通道，2026-09-23 实证内容区可用）
   * ⚠️ barWidth 必须传数值（'100%' 溢出屏幕）→ 由 build 里胶囊行 onAreaChange 测量驱动 capsuleW
   */
  @Builder
  capsuleShell() {
    HdsTabs() {
      TabContent()
        .tabBar(this.capsuleBarContent())
        .backgroundColor(Color.Transparent)
    }
    .barWidth(this.barW())
    .barHeight(52)
    .width(this.barW())
    .height(52)
    .barOverlap(true)
    .barPosition(BarPosition.End)
    // ⚠️ IMMERSIVE 材质必须显式配 gradientMask（省略渲染成黑色遮罩，见红线）
    .barFloatingStyle({
      gradientMask: {
        maskColor: Color.Transparent
      },
      barBottomMargin: 0,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    .scrollable(false)
    .animationDuration(0)
    .backgroundColor(Color.Transparent)
    .clip(false)
  }

  /** 胶囊 bar 内容：图标 + 输入框。
   *  ⚠️ 系统自定义 tabBar 内容容器顶部自带约 3vp inset、高度比 bar 小（约 44.5/52），
   *    内容高度必须 '100%' 自适应交给系统居中——写死 52 会溢出容器（实测图标上下偏移） */
  @Builder
  capsuleBarContent() {
    Stack() {
      this.capsuleContent()
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 胶囊内容：添加图片按钮 + 输入框（输入框 layoutWeight 跟随胶囊宽度，文字自然重排）
   */
  @Builder
  capsuleContent() {
    Row() {
      // ⚠️ 左侧表情按钮：切换表情面板与系统输入法
      Button() {
        Image($r('app.media.expression'))
          .width(26).height(26)
          .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
      }
      .width(40)
      .height(40)
      .backgroundColor(Color.Transparent)
      .margin({ left: 8 })
      .enabled(!this.isSending && !this.isUploading)
      .onClick(() => {
        // ⭐ 即时开/关面板（表情表未加载完时面板显示加载中分支，加载完自动刷新）
        this.emoteReady = true;
        this.setEmotePanel(!this.showEmote);
      })
      Stack() {
        RichEditor({ controller: this.richEditorController })
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          // ⭐ 光标设为全透明，隐藏 RichEditor 末尾闪烁光标竖线（编辑定位若需可见可改回 Color.__default / '#007DFF'）
          .caretColor(Color.Transparent)
          .margin({ left: 8, right: 8 })
          .id('whisper_rich_editor')
            .onReady(() => {
            // ⭐ 输入文字段落居中（占位文案由上层自绘 Text 居中承载）
            try {
              this.richEditorController.setTypingParagraphStyle({ textAlign: TextAlign.Center });
            } catch (_) {}
          })
          .onFocus(() => {
            // ⭐ 点输入框想打字：收起表情面板（面板让位，系统键盘按 RESIZE 正常弹出）
            if (this.showEmote) {
              this.setEmotePanel(false);
            }
          })
          .onDidChange((_rangeBefore: TextRange, _rangeAfter?: TextRange) => {
          // ⚠️ 输入内容非空才显示发送按钮（以富文本 span 是否为空判断）
          const hasText: boolean = this.richEditorController.getSpans().length > 0;
          this.hasContent = hasText;
          if (hasText !== this.spaceNarrow) {
            if (hasText) {
              this.spaceNarrow = true;
              this.capsuleAnimToken++;
              this.animateButtonSpace(60, 450, () => {
                this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
                  this.showSend = true;
                });
              });
            } else {
              this.spaceNarrow = false;
              const token: number = ++this.capsuleAnimToken;
              this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
                this.showSend = false;
              });
              setTimeout(() => {
                if (token !== this.capsuleAnimToken) return;
                this.animateButtonSpace(0, 450);
              }, 300);
            }
          }
        })
        // ⭐ 自绘占位文案（点击穿透，内容为空时显示）：RichEditor 的 placeholder
        //    无独立对齐 API，居中文案由本层 Text 承载
        if (!this.hasContent) {
          Text('发个友善的评论鼓励一下')
            .fontSize(15)
            .fontColor('#999999')
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ left: 8, right: 8 })
            .hitTestBehavior(HitTestMode.None)
        }
      }
      .layoutWeight(1)
      .height(40)
      // ⚠️ 右侧图片按钮：图片图标（与左侧表情图标同风格同尺寸），无底色，图标色与输入文字一致
      Button() {
        Image($r('app.media.ic_chat_image'))
          .width(26).height(26)
          .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
      }
      .width(40)
      .height(40)
      .backgroundColor(Color.Transparent)
      .margin({ right: 8 })
      .enabled(!this.isSending && !this.isUploading)
      .onClick(() => {
        this.pickAndSendImage();
      })
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      // 输入栏行（胶囊 + 发送按钮容器；onAreaChange 测行宽驱动 barWidth）
      Row() {
        this.capsuleShell()

        // ⚠️ 发送按钮容器：文档流内，隐藏时占位宽度 0 + clip 裁剪不占空间
        Row() {
          Row() {
            HdsMiniBarButton({
              barWidth: 52,
              barHeight: 52,
              contentPadding: 0,
              containerSize: { width: 52, height: 52 },
              barBottomMargin: 0,
              barOverlap: true,
              barPosition: BarPosition.End,
              onButtonClick: (): void => {
                if (!this.showSend || this.isSending || this.isUploading) {
                  return;
                }
                this.sendMessage();
              }
            }) {
              Image($r('app.media.send_out'))
                .width(30).height(30)
                .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            }
          }
          .margin({ left: 8 })
        }
        .width(this.buttonSpaceVp)
        .height(52)
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Center)
        .scale({ x: this.showSend ? 1 : 0.6, y: this.showSend ? 1 : 0.6 })
        .opacity(this.showSend ? 1 : 0)
        .hitTestBehavior(this.showSend ? HitTestMode.Default : HitTestMode.None)
        .clip(false)
      }
      .width('100%')
      .height(52)
      .alignItems(VerticalAlign.Center)
      .id('whisper_input_row')
      // ⭐ 表情面板弹层锚点（播放器提示胶囊同款 bindPopup 通道）：真材质设备显示为
      //    systemMaterial 圆角矩形（radius 22）；老机选项不含 26.0.0 新字段、
      //    且 emoteUsePopup=false 恒不显示（走下方页内面板兜底）
      .bindPopup(this.emoteUsePopup && this.emotePopupVisible, this.emotePopupOpts())
      // ⚠️ 不能挂 layoutWeight(1)：父（根 Column）高度自适应，weight 会让行高失控
      //    （实测行被撑到 1952px，胶囊在行内垂直居中→"跑到屏幕中间"）
      // ⭐ 测量胶囊行宽 → capsuleW（HdsTabs barWidth 要求数值）。0.5vp 死区防循环刷新
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const w: number = Number(newArea.width);
        if (w > 0 && Math.abs(w - this.capsuleW) > 0.5) {
          this.capsuleW = w;
        }
      })

      // ⭐ 表情面板（仅老机兜底渲染；真材质设备走上方 bindPopup 弹层，emoteH 恒 0）
      Column() {
        if (this.emoteH > 0) {
          this.emotePanel()
        }
      }
      .width('100%')
      .height(this.emoteH)
      .margin({ top: 8 })
      .clip(true)
      .borderRadius(22)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** ⭐ 表情面板弹层内容（bindPopup builder）：外框/材质/圆角全部由 CustomPopupOptions 负责
   *  （systemMaterial + radius 22，播放器提示胶囊同款通道）——builder 只画内容，
   *  ⚠️ 内容根不要再叠不透明底色 / backgroundBlurStyle（材质层在 backgroundColor 之下，会盖住材质） */
  @Builder
  emotePopupBuilder() {
    Column() {
      if (ChatEmote.getPackages().length > 0) {
        this.emoteGridContent()
      } else {
        this.emoteLoadingContent()
      }
    }
    // ⭐ 宽度 = 胶囊实际宽度（barW，随发送按钮让位同步），与输入胶囊左右缘对齐
    .width(this.barW())
    .height(300)
    .borderRadius(22)
    .clip(true)
    // ⭐ 安全边距加在面板根上（而不是只靠 Grid 自身 padding）——Grid 的 padding 对
    //    横向滚动内容不生效，表情会滑到面板边缘、在圆角处视觉出框（2026-09-24 用户实测）；
    //    根节点 padding 让内容在任意滚动位置都距框缘 8+4=12vp
    .padding({ left: 8, right: 8 })
  }

  /** ⭐ 表情面板（老机页内兜底：分类 tab + 表情网格 + 删除按钮；emoteH 驱动动画）
   *  材质壳与输入胶囊同通道：HdsTabs barFloatingStyle（真材质、天然无点光，ADAPTIVE 档）。
   *  ⚠️ 该通道 bar 形状是系统自绘胶囊（HdsTabsFloatingStyle 无形状参数），7.0 新机嫌形状不对
   *  才换到 bindPopup 圆角矩形通道；老机不挑形状故保留 */
  @Builder
  emotePanel() {
    Column() {
      if (ChatEmote.getPackages().length > 0) {
        HdsTabs() {
          TabContent()
            .tabBar(this.emoteGridContent())
            .backgroundColor(Color.Transparent)
        }
        .barWidth(this.capsuleW > 0 ? this.capsuleW : 300)
        .barHeight(300)
        .width(this.capsuleW > 0 ? this.capsuleW : 300)
        .height(300)
        .barOverlap(true)
        .barPosition(BarPosition.End)
        // ⚠️ IMMERSIVE 材质必须显式配 gradientMask（省略渲染成黑色遮罩，见红线）
        .barFloatingStyle({
          gradientMask: {
            maskColor: Color.Transparent
          },
          barBottomMargin: 0,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .scrollable(false)
        .animationDuration(0)
        .backgroundColor(Color.Transparent)
        .clip(false)
      } else {
        // 未加载 / 未登录（同款材质壳）
        HdsTabs() {
          TabContent()
            .tabBar(this.emoteLoadingContent())
            .backgroundColor(Color.Transparent)
        }
        .barWidth(this.capsuleW > 0 ? this.capsuleW : 300)
        .barHeight(300)
        .width(this.capsuleW > 0 ? this.capsuleW : 300)
        .height(300)
        .barOverlap(true)
        .barPosition(BarPosition.End)
        .barFloatingStyle({
          gradientMask: {
            maskColor: Color.Transparent
          },
          barBottomMargin: 0,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .scrollable(false)
        .animationDuration(0)
        .backgroundColor(Color.Transparent)
        .clip(false)
      }
    }
    .width('100%')
    .height(300)
    .padding({ bottom: 12 })
  }

  /** 表情面板内容：分类 tab（横向滚动）+ 删除按钮 + 表情网格（左右滑动）。
   *  ⚠️ 高度全部 '100%' 交给系统 tabBar 容器居中（写死会溢出，见输入胶囊同款教训） */
  @Builder
  emoteGridContent() {
    Column() {
      // 分类 tab（封面图标横向滚动）+ 删除按钮
      Row() {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(ChatEmote.getPackages(), (pkg: ChatEmotePackage, idx: number) => {
              Column() {
                if (pkg.url) {
                  Image(pkg.url)
                    .width(26).height(26)
                    .objectFit(ImageFit.Contain)
                } else {
                  Text(pkg.name).fontSize(11).fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                }
              }
              .width(40).height(40)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .backgroundColor(idx === this.emotePkgIdx
                ? 'rgba(0,174,236,0.25)'
                : (this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)'))
              .borderRadius(10)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.82 })
              .onClick(() => { this.triggerHaptic(); this.emotePkgIdx = idx; })
            }, (pkg: ChatEmotePackage) => pkg.id.toString())
          }
          .padding({ left: 12, right: 12 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .height(44)
        .layoutWeight(1)

        // ⭐ 删除按钮：删除输入框最后一个表情/字符
        Column() {
          Image($r('app.media.backspace_1'))
            .width(22).height(22)
            .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        }
        .width(40).height(40)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)')
        .borderRadius(10)
        .margin({ right: 22 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.82 })
        .onClick(() => { this.triggerHaptic(); this.deleteLastEmote(); })
      }
      .width('100%')

      // 当前分类表情：⭐ 左右滑动（rowsTemplate 不设 columnsTemplate → Grid 横向滚动）
      Grid() {
        ForEach(this.currentEmoteList(), (emote: ChatEmoteItem) => {
          GridItem() {
            Column() {
              if (emote.url) {
                Image(emote.url)
                  .width(42).height(42)
                  .objectFit(ImageFit.Contain)
              } else {
                Text(emote.text)
                  .fontSize(12)
                  .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
              }
            }
            .width(48)
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.82 })
            .onClick(() => { this.triggerHaptic(); this.insertEmote(emote); })
          }
        }, (emote: ChatEmoteItem) => emote.text)
      }
      .rowsTemplate('repeat(4, 1fr)')
      .columnsGap(6)
      .rowsGap(6)
      .height(234)
      .width('100%')
      // 左右收窄为 4：面板根已有 8 安全边距（合计 12vp，见 emotePopupBuilder 注释）
      .padding({ left: 4, right: 4, top: 4, bottom: 10 })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ top: 4 })
  }

  /** 表情面板加载中/未登录内容 */
  @Builder
  emoteLoadingContent() {
    Column() {
      Text('表情加载中或未登录').fontSize(13).fontColor('#999999')
      Button() { Text('重试').fontSize(13).fontColor('#007DFF') }
        .height(32)
        .margin({ top: 8 })
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          ChatEmote.waitForLoaded().then(() => { this.emoteReady = true; });
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
