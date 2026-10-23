// TextSelectionDialog.ets - 长按文本选取弹窗（选取文字 → 搜索；识别链接 → 分段浏览/打开）
// 供「视频简介」「评论卡片」长按触发：系统磨砂毛玻璃材质（自动适配深浅色），
// 文本区可选中文字；点击回形针识别链接后，顶部出现「简介 / 链接」分段切换，
// 链接经单独滚动区浏览、点击打开系统浏览器
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { VibrateUtils } from '../utils/VibrateUtils';
import { pasteboard } from '@kit.BasicServicesKit';
import { logWarn } from '../utils/Logger';
import { MaterialUtil } from '../utils/MaterialUtil';

@Component
export struct TextSelectionDialog {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('playerFollowTheme') playerFollowTheme: boolean = false;
  @Prop title: string = '';
  @Prop text: string = '';
  /** 搜索回调：传入选中文字（未选中则为全文） */
  onSearchText: (keyword: string) => void = (_k: string) => {};
  @State selectedText: string = '';
  // ⭐ 分段视图：'text' = 简介文本；'links' = 链接列表
  @State activeSection: string = 'text';
  // ⭐ 是否已识别链接（显示分段按钮）
  @State showLinks: boolean = false;
  // ⭐ 当前选中的链接（点击选中后右侧显示「复制/打开」图标；再点收起）
  @State activeLink: string = '';
  // ⭐ 一条一条复制：下次复制的链接序号（0 起，循环）
  @State nextCopyIndex: number = 0;
  // ⭐ 文本区高度：按屏幕高度动态计算（横屏矮屏防弹窗上下被裁），默认 280
  @State dynScrollH: number = 280;

  aboutToAppear(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const h = this.getUIContext().px2vp(d.height);
      // 固定占用估算：分段(~46) + 操作区(36+10+36+12) + 弹窗 padding 32 + 余量 12
      this.dynScrollH = Math.max(120, Math.min(280, h - 178));
    } catch (_e) {
      this.dynScrollH = 280;
    }
    this.matActive = MaterialUtil.sheetMaterial() !== undefined;
  }
  // ⭐ 关闭动画：组件内先淡出再让宿主关闭（系统 closeCustomDialog 无退出动画）
  @State fading: boolean = false;
  // ⭐ 沉浸光感：宿主 openCustomDialog 挂了 systemMaterial 时为 true（aboutToAppear 探测一次）
  @State matActive: boolean = false;

  /** 提取文本中的 URL（https/http 开头；中文/中文标点/全角字符视为正文边界，并去除尾部标点） */
  private extractUrls(text: string): string[] {
    const urls: string[] = [];
    // 排除 CJK（含中文标点）与全角字符，避免「https://xxx请三连」这类正文被误并入链接
    const re = /https?:\/\/[^\s"'<>（）()\u3000-\u9fff\uFF01-\uFF5E]+/g;
    let m = re.exec(text);
    while (m !== null) {
      const clean = m[0].replace(/[),.;:!?'\]>}]+$/, '');
      if (clean && urls.indexOf(clean) < 0) {
        urls.push(clean);
      }
      m = re.exec(text);
    }
    return urls;
  }

  /** 打开外部链接（系统浏览器） */
  private openUrl(url: string) {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.startAbility({
        action: 'ohos.want.action.viewData',
        uri: url
      }).catch((e: Error) => {
        this.getUIContext().getPromptAction().showToast({ message: '无法打开链接', duration: 1200 });
        logWarn(`[TextSelectionDialog] 打开链接失败: ${e.message}`);
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开链接', duration: 1200 });
    }
  }

  /** 复制文本到剪贴板 */
  private copyText(text: string) {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.getUIContext().getPromptAction().showToast({ message: '已复制', duration: 1200 });
    } catch (_e) {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败', duration: 1200 });
    }
  }

  /** ⭐ 全部复制：识别到的所有链接按行写入剪贴板 */
  private copyAllUrls() {
    this.vibrate();
    const urls = this.extractUrls(this.text);
    if (urls.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '未发现链接', duration: 1200 });
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, urls.join('\n'));
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.getUIContext().getPromptAction().showToast({ message: `已复制${urls.length}条链接`, duration: 1200 });
    } catch (_e) {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败', duration: 1200 });
    }
  }

  /** ⭐ 复制一条：按顺序逐条复制（第1条 → 第2条 → …循环），toast 显示当前第几条 */
  private copyOneUrl() {
    this.vibrate();
    const urls = this.extractUrls(this.text);
    if (urls.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '未发现链接', duration: 1200 });
      return;
    }
    const idx = this.nextCopyIndex % urls.length;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, urls[idx]);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.getUIContext().getPromptAction().showToast({ message: `已复制第${idx + 1}/${urls.length}条`, duration: 1200 });
      this.nextCopyIndex = idx + 1;
    } catch (_e) {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败', duration: 1200 });
    }
  }

  /** 链接行点击：选中/取消选中该链接（选中后右侧显示「复制/打开」图标） */
  private linkAction(url: string) {
    this.vibrate();
    this.activeLink = this.activeLink === url ? '' : url;
  }

  /** 透明度(0-100) → 两位十六进制（选中胶囊的淡主题色背景） */
  private opacityToHexAlpha(opacity: number): string {
    const val = Math.round(opacity / 100 * 255);
    return val.toString(16).padStart(2, '0');
  }

  /** 点击反馈：短震动 */
  private vibrate() {
    try {
      VibrateUtils.vibrateTime(10);
    } catch (_e) { }
  }

  /** ⭐ 操作区按钮组切换动画：进入右移淡入，退出左移淡出 */
  private btnSwapTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.translate({ x: 12 }).combine(TransitionEffect.opacity(0))
        .animation({ duration: 200, curve: Curve.EaseOut }),
      TransitionEffect.translate({ x: -12 }).combine(TransitionEffect.opacity(0))
        .animation({ duration: 150, curve: Curve.EaseIn })
    );
  }

  @Builder
  dlgContent() {
    Column() {
      // ⭐ 分段按钮（识别到链接后显示）：简介 / 链接
      if (this.showLinks) {
        Row() {
          Text('文本')
          .fontSize(13)
          .fontWeight(this.activeSection === 'text' ? FontWeight.Bold : FontWeight.Regular)
          .fontColor(this.activeSection === 'text' ? '#FFFFFF' : (this.isDarkMode ? '#9A9A9A' : '#666666'))
          .padding({ left: 14, right: 14, top: 5, bottom: 5 })
          .borderRadius(16)
          .backgroundColor(this.activeSection === 'text'
            ? (this.playerFollowTheme ? this.customThemeColor : '#FB7299')
            : Color.Transparent)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
          .onClick(() => { this.vibrate(); this.activeSection = 'text'; })
          .margin({ right: 8 })
          Text('链接')
          .fontSize(13)
          .fontWeight(this.activeSection === 'links' ? FontWeight.Bold : FontWeight.Regular)
          .fontColor(this.activeSection === 'links' ? '#FFFFFF' : (this.isDarkMode ? '#9A9A9A' : '#666666'))
          .padding({ left: 14, right: 14, top: 5, bottom: 5 })
          .borderRadius(16)
          .backgroundColor(this.activeSection === 'links'
            ? (this.playerFollowTheme ? this.customThemeColor : '#FB7299')
            : Color.Transparent)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
          .onClick(() => { this.vibrate(); this.activeSection = 'links'; })
        }
        // ⭐ 外层大胶囊包裹（内层小胶囊：选中态主题色、未选中镂空）
        .padding({ left: 4, right: 4, top: 3, bottom: 3 })
        .borderRadius(18)
        .backgroundColor('rgba(128,128,128,0.12)')
        .width('fit-content')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 10 })
      }

      // ⭐ 内容区：简介文本 / 链接列表（共用高度，上下可滑动）
      if (this.activeSection === 'text') {
        Scroll() {
          Text(this.text)
          .fontSize(13)
          .fontColor(this.isDarkMode ? '#D0D0D0' : '#333333')
          .lineHeight(20)
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
          .onTextSelectionChange((selStart: number, selEnd: number) => {
            if (selEnd > selStart) {
              this.selectedText = this.text.substring(selStart, selEnd);
            }
          })
        }
        .height(this.dynScrollH)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .margin({ top: 10 })
      } else {
        Scroll() {
          Column({ space: 16 }) {
            ForEach(this.extractUrls(this.text), (url: string) => {
              // ⭐ 链接行：点击选中后右侧显示 fuzhi（复制）/ llq（打开）图标；再点收起
              Row() {
                Text(url)
                .fontSize(12)
                // ⭐ 未选中中性灰、选中后主题色（渐变更清晰）
                .fontColor(this.activeLink === url
                  ? (this.playerFollowTheme ? this.customThemeColor : '#FB7299')
                  : (this.isDarkMode ? '#9A9A9A' : '#666666'))
                .fontWeight(this.activeLink === url ? FontWeight.Bold : FontWeight.Regular)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick(() => { this.linkAction(url); })
                .layoutWeight(1)
                if (this.activeLink === url) {
                  Image($r('app.media.fuzhi'))
                    .width(18)
                    .height(18)
                    .fillColor(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
                    .margin({ left: 8 })
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.85 })
                    .transition(
                      TransitionEffect.OPACITY.animation({ duration: 150, curve: Curve.EaseOut })
                        .combine(TransitionEffect.translate({ x: 6 }).animation({ duration: 150, curve: Curve.EaseOut }))
                    )
                    .onClick(() => {
                      this.vibrate();
                      this.copyText(url);
                      this.activeLink = '';
                    })
                  Image($r('app.media.llq'))
                    .width(18)
                    .height(18)
                    .fillColor(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
                    .margin({ left: 14 })
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.85 })
                    .transition(
                      TransitionEffect.OPACITY.animation({ duration: 150, curve: Curve.EaseOut })
                        .combine(TransitionEffect.translate({ x: 6 }).animation({ duration: 150, curve: Curve.EaseOut }))
                    )
                    .onClick(() => {
                      this.vibrate();
                      this.openUrl(url);
                      this.activeLink = '';
                    })
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              // ⭐ 链接胶囊：未选中中性底、选中淡主题色底（与文字主题色呼应）
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .borderRadius(16)
              .backgroundColor(this.activeLink === url
                ? (this.playerFollowTheme
                  ? '#' + this.opacityToHexAlpha(12) + this.customThemeColor.slice(1)
                  : 'rgba(251,114,153,0.10)')
                : (this.isDarkMode ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)'))
            }, (url: string) => url)
          }
          .width('100%')
        }
        .height(this.dynScrollH)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .margin({ top: 10 })
      }

      // ⭐ 操作区（单行，切换带动画）：回形针固定；文本区=搜索+复制文本，链接区=逐条复制+全部复制，
      //    两组互斥切换；窄屏/横屏宽度不足时仍可自动换行，避免按钮被裁
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
          // 识别链接按钮
          Column() {
            Image($r('app.media.paperclip_45'))
            .width(20)
            .height(20)
            .fillColor('#FFFFFF')
          }
          .width(36)
          .height(36)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .borderRadius(18)
          .backgroundColor(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
          .onClick(() => {
            this.vibrate();
            const urls = this.extractUrls(this.text);
            if (urls.length === 0) {
              this.getUIContext().getPromptAction().showToast({ message: '未发现链接', duration: 1200 });
              return;
            }
            this.showLinks = true;
            this.activeSection = this.activeSection === 'links' ? 'text' : 'links';
          })
          .margin({ right: 12 })

          // ⭐ 文本区按钮组：搜索（图标 + 文字）
          if (this.activeSection === 'text') {
            Column() {
              Row({ space: 6 }) {
                Image($r('app.media.ic_public_search_filled'))
                .width(16)
                .height(16)
                .fillColor('#FFFFFF')
                Text('搜索')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
              }
              .alignItems(VerticalAlign.Center)
            }
            .width(112)
            .height(36)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .borderRadius(18)
            .backgroundColor(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
            .onClick(() => {
              this.vibrate();
              const keyword = this.selectedText || this.text;
              this.selectedText = '';
              // 先做 220ms 淡出，再回调宿主关闭弹窗
              this.fading = true;
              setTimeout(() => {
                this.onSearchText(keyword.trim());
              }, 230);
            })
            .margin({ right: 12 })
            .transition(this.btnSwapTransition())
          }

          // ⭐ 文本区按钮组：复制文本（复制完整文本）
          if (this.activeSection === 'text') {
            Column() {
              Row({ space: 6 }) {
                Image($r('app.media.wenbenfuz'))
                  .width(16)
                  .height(16)
                  .fillColor('#FFFFFF')
                Text('复制文本')
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
              }
              .alignItems(VerticalAlign.Center)
            }
            .width(120)
            .height(36)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .borderRadius(18)
            .backgroundColor(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
            .onClick(() => {
              this.vibrate();
              this.copyText(this.text);
            })
            .transition(this.btnSwapTransition())
          }

          // ⭐ 链接区按钮组：逐条复制（逐条递进）
          if (this.activeSection === 'links') {
            Column() {
              Row({ space: 6 }) {
                Image($r('app.media.fuzhi'))
                  .width(16)
                  .height(16)
                  .fillColor('#FFFFFF')
                Text('逐条复制')
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
              }
              .alignItems(VerticalAlign.Center)
            }
            .width(120)
            .height(36)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .borderRadius(18)
            .backgroundColor(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
            .onClick(() => { this.copyOneUrl(); })
            .margin({ right: 12 })
            .transition(this.btnSwapTransition())
          }

          // ⭐ 链接区按钮组：全部复制（按行全部）
          if (this.activeSection === 'links') {
            Column() {
              Row({ space: 6 }) {
                Image($r('app.media.fuzhi'))
                  .width(16)
                  .height(16)
                  .fillColor('#FFFFFF')
                Text('全部复制')
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
              }
              .alignItems(VerticalAlign.Center)
            }
            .width(120)
            .height(36)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .borderRadius(18)
            .backgroundColor(this.playerFollowTheme ? this.customThemeColor : '#FB7299')
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
            .onClick(() => { this.copyAllUrls(); })
            .transition(this.btnSwapTransition())
          }
        }
        .width('100%')
        .margin({ top: 12 })
    }
    .padding(16)
    .opacity(this.fading ? 0 : 1)
    .animation({ duration: 220, curve: Curve.EaseInOut })
    .borderRadius(20)
    .clip(true)
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.35)', offsetY: 6 })
  }

  build() {
    // ⭐ 双分支根（MaterialUtil 硬要求②：挂材质不得再叠 backgroundBlurStyle，否则双层磨砂盖住沉浸光感）：
    //   材质由宿主 openCustomDialog 的 options.systemMaterial 提供（官方"对话框通道"）；
    //   不支持沉浸光感的设备走原 COMPONENT_THICK 系统磨砂降级，外观与旧版一致。
    if (this.matActive) {
      Column() {
        this.dlgContent()
      }
      .borderRadius(20)
      .clip(true)
    } else {
      Column() {
        this.dlgContent()
      }
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .borderRadius(20)
      .clip(true)
    }
  }
}
