// CommentInputBar.ets — 评论输入栏（自 WhisperInputBar 改造）
// ⚠️ 与私信输入栏的差异：发送通道改为 onSend 回调（父页走 /x/v2/reply/add），
//    图片选择后只加入草稿（发送时由父页上传，不走 IM 的 biz=im 图床），
//    表情面板开合信号改为组件内状态（不再用 AppStorage closeEmoteSignal 防串扰）
// ⚠️ 布局方案（继承自 WhisperInputBar）：胶囊 layoutWeight(1) 吃满剩余宽度；
//    发送按钮容器在文档流内，占位宽度 buttonSpaceVp 由 Animator 逐帧驱动（0↔74vp）
// ⚠️ 材质（2026-09-24 用户定）：本组件输入区**不走系统沉浸光感**——输入胶囊与发送按钮
//    统一使用自绘半透明玻璃（glassBg / glassStroke），两者必须永远保持同一套配方。
//    （发送按钮原先走 HdsMiniBarButton 的 HdsTabs 系统材质，与胶囊的纯色半透明观感割裂）
import { promptAction, uiMaterial, RectShape, Animator, AnimatorResult } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { logError, errMsg } from '../utils/Logger';
import { VibrateUtils } from '../utils/VibrateUtils';

import { ChatEmote, ChatEmoteItem, ChatEmotePackage } from '../utils/ChatEmote';

/** 评论图片草稿（相册已选、尚未上传） */
export class CommentImageDraft {
  /** 沙箱内绝对路径 */
  path: string = '';
  /** 扩展名（jpg | png | gif） */
  ext: string = '';
  /** MIME 类型 */
  mime: string = '';
}

/** 图片格式探测结果 */
class ImageTypeInfo {
  /** 扩展名（jpg | png | gif） */
  ext: string = '';
  /** MIME 类型 */
  mime: string = '';
}

/**
 * ⭐ 评论输入栏控制器：把"收起表情面板"的能力暴露给**父页**。
 *
 * 使用场景：表情面板展开时，**侧滑返回 / 返回键**的语义应当是"先收起面板"，
 * 而不是退出页面 / 关掉整个输入弹层（父页在 `onWillDismiss` 的 `PRESS_BACK` 分支里用）。
 *
 * 为什么用控制器、而不是"父页自己记一份开合状态"：面板是否展开的**真值在组件内部**
 * （`showEmote` / `emoteH`）。父页自己记一份就会失步 —— 内部因别的原因收起时
 * （点输入框 `onFocus` 瞬时收起、半模态收起重建…）父页仍以为开着，
 * 表现为"返回键第一下没反应、要按两次"。直接问组件本体永远一致。
 *
 * 用法：
 * ```ts
 * private emoteCtrl: CommentInputBarCtrl = new CommentInputBarCtrl();
 * CommentInputBar({ ctrl: this.emoteCtrl, ... })
 * // 返回键分支：
 * if (a.reason === DismissReason.PRESS_BACK && this.emoteCtrl.collapseEmote()) {
 *   return;   // 面板本来开着 → 已收起，吞掉本次返回
 * }
 * ```
 */
export class CommentInputBarCtrl {
  /** 收起实现（由 CommentInputBar 在 aboutToAppear 注册、aboutToDisappear 注销） */
  private collapseImpl: () => boolean = (): boolean => false;

  /** 注册收起实现（仅组件内部调用） */
  bindImpl(impl: () => boolean): void {
    this.collapseImpl = impl;
  }

  /** 注销（仅组件内部调用）：避免父页误调到已销毁实例 */
  unbind(): void {
    this.collapseImpl = (): boolean => false;
  }

  /**
   * 收起表情面板。
   * @returns true = 面板本来展开、本次已收起（调用方应**吞掉**这次返回）；
   *          false = 面板本来就没开（调用方继续走原本的返回逻辑）
   */
  collapseEmote(): boolean {
    try {
      return this.collapseImpl();
    } catch (_e) {
      return false;
    }
  }
}

@Component
export struct CommentInputBar {
  /** ⭐ 父页持有的控制器（见 CommentInputBarCtrl）：供父页在侧滑返回/返回键时先收面板 */
  ctrl: CommentInputBarCtrl = new CommentInputBarCtrl();
  /** 发送回调：content 为已还原表情标记（[doge] 等）的文本；pictures 为已选图片草稿；
   *  返回 true=发送成功（父页关闭弹层），false=失败（保留内容与已选图） */
  onSend: (content: string, pictures: CommentImageDraft[]) => Promise<boolean> = async () => false;
  /** 表情面板开/关回调 */
  onEmoteChange: (open: boolean) => void = () => {};
  /** 输入框占位文案 */
  @Prop placeholder: string = '发个友善的评论鼓励一下';
  /** 是否显示插入图片按钮（回复评论时隐藏，仅一级评论可用） */
  @Prop showImageButton: boolean = true;
  /**
   * ⭐ 出现时是否自动聚焦（默认 true，保持播放页/评论详情页原有行为）。
   *    传 false 时**不主动弹输入法**：适合"底部悬浮胶囊展开输入区"这类场景——
   *    用户点了胶囊只是想发评论，不该立刻被键盘顶起半屏。
   */
  @Prop autoFocus: boolean = true;
  /** 发送中 */
  @State isSending: boolean = false;
  /** 输入内容非空时显示发送按钮 */
  @State showSend: boolean = false;
  /** 输入内容是否非空（控制自绘占位文案显隐） */
  @State hasContent: boolean = false;
  /** 发送按钮容器占位宽度（vp）：Animator 逐帧写入，胶囊 layoutWeight 跟随让位 */
  @State buttonSpaceVp: number = 0;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  /** ⭐ 是否显示表情面板（页面内渲染，动画展开/收起） */
  @State showEmote: boolean = false;
  /** 表情面板高度（0=收起，Animator 逐帧驱动与消息区同步伸缩） */
  @State emoteH: number = 0;
  private emoteAnimator: AnimatorResult | null = null;
  /** 当前选中表情分类索引 */
  @State emotePkgIdx: number = 0;
  /** 表情表是否已加载（加载后触发面板重建） */
  @State emoteReady: boolean = false;
  /** 已选图片草稿（上限 9 张，发送时由父页上传） */
  @State pictureDrafts: CommentImageDraft[] = [];
  /** 输入框控制器 */
  private richEditorController: RichEditorController = new RichEditorController();
  /** 串行动画 token：新触发递增使旧的 setTimeout 回调作废 */
  private capsuleAnimToken: number = 0;
  /** 当前是否处于收窄目标态（动画开始即翻转，防连续打字重入） */
  private spaceNarrow: boolean = false;
  /** 按钮占位宽度 Animator（新动画前 cancel 旧动画，实现打断衔接） */
  private spaceAnimator: AnimatorResult | null = null;
  /** 胶囊材质对象（API 26+ systemMaterial；构造失败 = API 23，降级半透明背景） */
  private capsuleMaterialObj: uiMaterial.ImmersiveMaterial | null = null;
  /** 材质对象对应的暗色模式快照（切换后重建，materialColor 跟随主题） */
  private capsuleMaterialDark: boolean | null = null;

  aboutToAppear(): void {
    // ⭐ 注册"收起面板"实现：父页在侧滑返回/返回键时调 ctrl.collapseEmote()（见 CommentInputBarCtrl）。
    //    返回 true 表示"面板本来开着、已收起"，父页据此吞掉这次返回。
    this.ctrl.bindImpl((): boolean => {
      if (!this.showEmote) {
        return false;
      }
      this.setEmotePanel(false);
      return true;
    });
    // ⭐ 立即预加载表情表；加载完成后置 emoteReady 触发面板刷新（无需手动重试）
    ChatEmote.ensureLoaded().then(() => {
      if (ChatEmote.getPackages().length > 0) {
        this.emoteReady = true;
      }
    });
  }

  aboutToDisappear(): void {
    // ⭐ 解绑（弹层关闭会销毁本组件）：父页再调 collapseEmote() 必须返回 false，
    //    不能去碰已销毁的实例（否则返回键会被无故吞掉）。
    this.ctrl.unbind();
  }

  /**
   * 按钮占位宽度动画（0↔74vp）：Animator 逐帧写入 buttonSpaceVp，
   * 胶囊 layoutWeight 每帧跟随让位。显式逐帧状态驱动，不依赖 animateTo 的宽度插值
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

  /**
   * 发送评论（文本 + 已选图片草稿一并交给父页）
   */
  private async sendMessage(): Promise<void> {
    const content = this.buildSendContent().trim();
    if (!content && this.pictureDrafts.length === 0) {
      promptAction.showToast({ message: '输入内容不能为空' });
      return;
    }
    if (this.isSending) {
      return;
    }
    this.isSending = true;
    try {
      const ok = await this.onSend(content, this.pictureDrafts.slice());
      if (ok) {
        this.clearAll();
      }
    } catch (err) {
      logError(`[CommentInputBar] 发送失败: ${errMsg(err)}`);
      promptAction.showToast({ message: '发送失败' });
    }
    this.isSending = false;
  }

  /** ⭐ 发送成功后清空输入与图片草稿（串行收起动画与 WhisperInputBar 一致） */
  private clearAll(): void {
    try {
      this.richEditorController.deleteSpans({ start: 0, end: 999999 });
    } catch (_) {}
    this.hasContent = false;
    this.pictureDrafts = [];
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

  /** ⭐ 插入表情图片到富文本输入框（并驱动"有内容→显示发送按钮"） */
  private insertEmote(emote: ChatEmoteItem): void {
    this.richEditorController.addImageSpan(emote.url, {
      offset: this.richEditorController.getCaretOffset(),
      imageStyle: { size: [26, 26] }
    });
    this.hasContent = true;
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

  /** ⭐ 把富文本内容序列化为发送文本：文字段直取，图片段还原为 [xx] 表情标记 */
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
    this.hasContent = this.richEditorController.getSpans().length > 0;
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
   * ⭐ 开/关表情面板（页面内渲染，260ms 高度动画）：
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
    this.animateEmoteH(open ? 300 : 0);
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
   * 选择图片加入草稿（选图 → 拷贝到沙箱 → 魔数探测格式；上传在父页发送时进行）
   */
  private async pickImage(): Promise<void> {
    if (this.isSending) {
      return;
    }
    if (this.pictureDrafts.length >= 9) {
      promptAction.showToast({ message: '最多选择9张图片' });
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
      const destUri = `${context.filesDir}/comment_img_${Date.now()}`;
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
      const draft = new CommentImageDraft();
      draft.path = destUri;
      draft.ext = extMime.ext;
      draft.mime = extMime.mime;
      const arr = this.pictureDrafts.slice();
      arr.push(draft);
      this.pictureDrafts = arr;
    } catch (err) {
      logError(`[CommentInputBar] 选择图片失败: ${errMsg(err)}`);
      promptAction.showToast({ message: '选择图片失败' });
    }
  }

  /** ⭐ 移除某张图片草稿 */
  private removeDraft(idx: number): void {
    const arr = this.pictureDrafts.slice();
    arr.splice(idx, 1);
    this.pictureDrafts = arr;
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
      logError(`[CommentInputBar] 探测图片格式失败: ${errMsg(err)}`);
      return null;
    }
  }

  /**
   * 胶囊材质对象：暗色模式切换后重建（materialColor 跟随主题）
   * 构造失败（API 23 无 systemMaterial）返回 null，走降级半透明背景
   */
  private getCapsuleMaterial(): uiMaterial.ImmersiveMaterial | null {
    // 7.0+ systemMaterial 仅在 Navigation 标题栏/底部 TabBar/弹窗内生效；本组件在内容区，走降级半透明玻璃
    return null;
    if (this.capsuleMaterialDark !== this.isDarkMode) {
      this.capsuleMaterialDark = this.isDarkMode;
      try {
        this.capsuleMaterialObj = new uiMaterial.ImmersiveMaterial({
          style: 0 as uiMaterial.ImmersiveStyle,
          applyShadow: false,
          materialColor: (this.isDarkMode ? 'rgba(255,255,255,0.15)' : 'rgba(255,255,255,0.65)') as ResourceColor
        });
      } catch (_) {
        this.capsuleMaterialObj = null;
      }
    }
    return this.capsuleMaterialObj;
  }

  /**
   * ⭐ 输入区玻璃底色（输入胶囊 + 发送按钮**共用同一套配方**）
   *    2026-09-24 用户要求两者必须是同一种材质 ⇒ 配色抽到一处，改一个数两处同步，
   *    避免"同款外观两份副本各自漂移"（见工程红线：同款 Builder 副本必须先 grep 全工程）。
   */
  private glassBg(): ResourceColor {
    return this.isDarkMode ? 'rgba(255,255,255,0.15)' : 'rgba(255,255,255,0.65)';
  }

  /** ⭐ 输入区玻璃描边色（与 glassBg 配对，同样两处共用） */
  private glassStroke(): ResourceColor {
    return '#33FFFFFF';
  }

  /**
   * 胶囊外壳：自绘半透明玻璃（glassBg + glassStroke）
   * ⚠️ 刻意不走系统沉浸光感：本组件在内容区，且统一配方后输入胶囊与发送按钮才是一件东西
   *    （若只给胶囊换 HdsTabs 通道，barWidth('100%') 还会溢出屏幕）。
   * ⚠️ 宽度始终 '100%'（由外层 layoutWeight 行决定，随按钮占位逐帧让位）
   * ⚠️ 发送按钮（build() 内）必须与这里保持同一套配方。
   */
  @Builder
  capsuleShell() {
    Stack() {
      this.capsuleContent()
    }
    .width('100%')
    .height(52)
    .clip(true)
    .clipShape(new RectShape({ width: '100%', height: '100%', radius: 26 }))
    .shadow({ radius: 36, color: '#10000000' })
    .backgroundColor(this.glassBg())
    .borderRadius(26)
    .border({ width: 1.5, color: this.glassStroke() })
  }

  /**
   * 胶囊内容：添加图片按钮 + 输入框（输入框 layoutWeight 跟随胶囊宽度，文字自然重排）
   */
  @Builder
  capsuleContent() {
    Row() {
      // ⭐ 左侧表情按钮：切换表情面板与系统输入法
      Button() {
        Image($r('app.media.expression'))
          .width(26).height(26)
          .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
      }
      .width(40)
      .height(40)
      .backgroundColor(Color.Transparent)
      .margin({ left: 8 })
      .enabled(!this.isSending)
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
          // ⭐ 光标设为全透明，隐藏 RichEditor 末尾闪烁光标竖线
          .caretColor(Color.Transparent)
          .margin({ left: 8, right: 8 })
          .id('comment_rich_editor')
          .defaultFocus(this.autoFocus)
          .onReady(() => {
            try {
              this.richEditorController.setTypingParagraphStyle({ textAlign: TextAlign.Center });
            } catch (_) {}
          })
          .onFocus(() => {
            if (this.showEmote) {
              // ⭐ 面板收起动画与键盘弹出/sheet 平移并发会让弹层高度与位置竞争
              //    （竖屏输入框被顶出屏幕、横屏跳动），改为瞬时收起：高度立即归零
              if (this.emoteAnimator) {
                this.emoteAnimator.cancel();
                this.emoteAnimator = null;
              }
              this.emoteH = 0;
              this.showEmote = false;
              this.onEmoteChange(false);
            }
          })
          .onDidChange((_rangeBefore: TextRange, _rangeAfter?: TextRange) => {
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
        if (!this.hasContent) {
          Text(this.placeholder)
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
      // ⭐ 右侧图片按钮（回复模式由父页传 showImageButton=false 隐藏）
      if (this.showImageButton) {
        Button() {
          Image($r('app.media.ic_chat_image'))
            .width(26).height(26)
            .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .margin({ right: 8 })
        .enabled(!this.isSending)
        .onClick(() => {
          this.pickImage();
        })
      }
    }
    .width('100%')
    .height(52)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      // ⭐ 已选图片草稿缩略图行（横向滚动，可删除）
      if (this.pictureDrafts.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.pictureDrafts, (d: CommentImageDraft, idx: number) => {
              Stack() {
                Image('file://' + d.path)
                  .width(64).height(64)
                  .borderRadius(8)
                  .objectFit(ImageFit.Cover)
                Text('×')
                  .width(18).height(18)
                  .fontSize(14)
                  .fontColor(Color.White)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('rgba(0,0,0,0.55)')
                  .borderRadius(9)
                  .position({ x: 46, y: 0 })
                  .onClick(() => {
                    this.triggerHaptic();
                    this.removeDraft(idx);
                  })
              }
              .width(64).height(64)
              .borderRadius(8)
            }, (d: CommentImageDraft, idx: number) => d.path + '_' + idx)
          }
          .padding({ bottom: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ bottom: 8 })
      }

      // 输入栏行
      Row() {
        Row() {
          this.capsuleShell()
        }
        .layoutWeight(1)
        .height(52)

        // ⚠️ 发送按钮容器：文档流内，隐藏时占位宽度 0 + clip 裁剪不占空间
        Row() {
          Row() {
            // ⭐ 发送按钮：与输入胶囊**同一套自绘半透明材质**（2026-09-24 用户要求统一）
            //    ⚠️ 原先用 HdsMiniBarButton（HdsTabs 系统沉浸光感通道）——那与胶囊的纯色半透明
            //       是两种材质，同一个 sheet 里输入框通透、按钮"实"，观感割裂。
            //    ⚠️ 配方必须与 capsuleShell() 一致：glassBg + 1.5vp glassStroke + radius 26。
            Stack() {
              Image($r('app.media.send_out'))
                .width(30).height(30)
                .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            }
            .width(52)
            .height(52)
            .clip(true)
            .clipShape(new RectShape({ width: '100%', height: '100%', radius: 26 }))
            .shadow({ radius: 36, color: '#10000000' })
            .backgroundColor(this.glassBg())
            .borderRadius(26)
            .border({ width: 1.5, color: this.glassStroke() })
            .onClick(() => {
              if (!this.showSend || this.isSending) {
                return;
              }
              this.sendMessage();
            })
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

      // ⭐ 表情面板（页面内渲染，emoteH 高度动画展开/收起；位于输入栏下方、贴容器底）
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

  /** ⭐ 表情面板（页面内弹出层：分类 tab + 表情网格 + 删除按钮；emoteH 驱动动画） */
  @Builder
  emotePanel() {
    Column() {
      if (ChatEmote.getPackages().length > 0) {
        Column() {
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

          // 当前分类表情：⭐ 左右滑动（与私信表情框同款：只设 rowsTemplate、不设 columnsTemplate，
          //    Grid 即横向滚动；每列宽度由 GridItem 内的 48 决定）
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
          // ⭐ 高度同私信表情框（4行*42 + 3*6 间距 + 上下 4/10 padding = 234）
          .height(234)
          .width('100%')
          // ⚠️ 横向滚动时 Grid 自身 padding 对滚动内容不生效（2026-09-24 用户实测）
          //    ⇒ 左右安全边距移到面板根节点上（root 8 + 这里 4 = 12vp）
          .padding({ left: 4, right: 4, top: 4, bottom: 10 })
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .height(300)
        .clip(true)
        .clipShape(new RectShape({ width: '100%', height: '100%', radius: 22 }))
        .borderRadius(22)
        .systemMaterial(this.getCapsuleMaterial())
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.15)' : 'rgba(255,255,255,0.65)')
        .border({ width: 1.5, color: '#33FFFFFF' })
        // ⭐ 左右 8vp 安全边距加在面板根上（与私信表情面板同款）：表情改为横向滚动后
        //    Grid 自身的横向 padding 不生效，靠这里保证内容在任意滚动位置都不出圆角框
        .padding({ left: 8, right: 8, top: 4 })
      } else {
        // 未加载 / 未登录
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
        .height(300)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .clip(true)
        .clipShape(new RectShape({ width: '100%', height: '100%', radius: 22 }))
        .borderRadius(22)
        .systemMaterial(this.getCapsuleMaterial())
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.15)' : 'rgba(255,255,255,0.65)')
        .border({ width: 1.5, color: '#33FFFFFF' })
      }
    }
    .width('100%')
    .height(300)
    .padding({ bottom: 12 })
  }
}
