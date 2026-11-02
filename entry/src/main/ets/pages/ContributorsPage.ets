/**
 * 贡献者页
 * 从「关于软件 → 贡献者」进入，逐人列出各自做了什么。
 * 关于页里贡献者分组默认收起，只显示一行摘要；完整清单在这里。
 */
import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { logWarn } from '../utils/Logger';
import { HdsCircleBackButton } from '../components/infra/HdsCircleBackButton';
import {
  ContributorItem, LearnedProject, CONTRIBUTORS, GITHUB_REPO_URL
} from '../model/ContributorData';

@Entry
@Component
struct ContributorsPage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;

  /** 入场动画：标题与各卡片依次浮起（复用首页卡片入场那套弹簧曲线） */
  @State titleShown: boolean = false;
  @State founderShown: boolean = false;
  @State listShown: boolean = false;
  @State ctaShown: boolean = false;

  /** 入场动画的定时器，离开页面时要清掉，避免往已隐藏的组件写状态 */
  private animTimers: number[] = [];

  private clearAnimTimers(): void {
    for (const t of this.animTimers) {
      clearTimeout(t);
    }
    this.animTimers = [];
  }

  private resetAnimState(): void {
    this.titleShown = false;
    this.founderShown = false;
    this.listShown = false;
    this.ctaShown = false;
  }

  /**
   * 页面被盖住时立刻清空动画状态。
   * ⚠️ 这是"返回时不闪一下"的关键：如果留到 onPageShow 再清，
   * 返回的首帧会先用上次动画结束后的"已显示"状态渲染一帧，
   * 然后才变空白重新入场 —— 视觉上就是「闪一下」。
   */
  onPageHide(): void {
    this.clearAnimTimers();
    this.resetAnimState();
  }

  /**
   * 每次页面可见时播放入场动画。
   * ⚠️ 不能只用 aboutToAppear：从别的页面返回时本页还在路由栈里，
   * aboutToAppear 不会再次执行，动画就只播第一次。
   */
  onPageShow(): void {
    this.clearAnimTimers();
    this.resetAnimState();
    // 先让"隐藏态"渲染一帧，下一帧再置真，动画才会真正插值
    this.animTimers.push(setTimeout(() => { this.titleShown = true; }, 16));
    this.animTimers.push(setTimeout(() => { this.founderShown = true; }, 90));
    this.animTimers.push(setTimeout(() => { this.listShown = true; }, 200));
    this.animTimers.push(setTimeout(() => { this.ctaShown = true; }, 320));
  }

  aboutToDisappear(): void {
    this.clearAnimTimers();
  }

  /** 打开外部链接（系统浏览器） */
  private openUrl(url: string): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      }).catch((e: Error) => {
        this.getUIContext().getPromptAction().showToast({ message: '无法打开链接', duration: 1200 });
        logWarn(`[ContributorsPage] 打开链接失败: ${e.message}`);
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开链接', duration: 1200 });
    }
  }

  /** 头像：网络/资源失败时退回首字母圆 */
  @Builder
  Avatar(c: ContributorItem, size: number) {
    Image(c.avatar)
      .width(size)
      .height(size)
      .borderRadius(size / 2)
      .objectFit(ImageFit.Cover)
      .alt($r('app.media.icon'))
  }

  /** 发起者卡片：只显示头像 / 名称 / 账号 / 角标 */
  @Builder
  FounderCard(c: ContributorItem) {
    Row() {
      Image(c.avatar)
        .width(64)
        .height(64)
        .borderRadius(32)
        .objectFit(ImageFit.Cover)
        .alt($r('app.media.icon'))
      Column() {
        Row() {
          Text(c.name)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          if (c.role.length > 0) {
            Text(c.role)
              .fontSize(10)
              .fontColor(this.isDarkMode ? '#0A84FF' : '#007DFF')
              .borderRadius(9)
              .borderWidth(1)
              .borderColor(this.isDarkMode ? '#0A84FF' : '#007DFF')
              .padding({ left: 6, right: 6 })
              .margin({ left: 6 })
              .opacity(0.85)
          }
        }
        .alignItems(VerticalAlign.Center)

        Text('@' + c.handle)
          .fontSize(12)
          .fontColor('#8E8E93')
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 14 })
    }
    .width('100%')
    .padding(16)
    .borderRadius(14)
    .backgroundColor(this.isDarkMode ? '#1C1C1E' : '#FFFFFF')
    .clickEffect({ level: 2, scale: 0.96 })
    .onClick(() => this.openUrl('https://github.com/' + c.handle))
  }

  /** 普通开发人员卡片 */
  @Builder
  ContributorCard(c: ContributorItem) {
    Column() {
      Row() {
        this.Avatar(c, 46)
        Column() {
          Row() {
            Text(c.name)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            if (c.role.length > 0) {
              Text(c.role)
                .fontSize(10)
                .fontColor(this.isDarkMode ? '#0A84FF' : '#007DFF')
                .borderRadius(9)
                .borderWidth(1)
                .borderColor(this.isDarkMode ? '#0A84FF' : '#007DFF')
                .padding({ left: 6, right: 6 })
                .margin({ left: 6 })
                .opacity(0.85)
            }
            Blank()
          }
          .width('100%')
          Text('@' + c.handle)
            .fontSize(11)
            .fontColor('#8E8E93')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .margin({ left: 10 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Column() {
        ForEach(c.works, (w: string) => {
          Row() {
            Text('·')
              .fontSize(12)
              .fontColor('#8E8E93')
              .margin({ right: 6 })
            Text(w)
              .fontSize(12)
              .fontColor(this.isDarkMode ? 'rgba(255,255,255,0.78)' : 'rgba(0,0,0,0.72)')
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ bottom: 4 })
        }, (w: string) => w)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(14)
    .borderRadius(14)
    .backgroundColor(this.isDarkMode ? '#1C1C1E' : '#FFFFFF')
    .clickEffect({ level: 2, scale: 0.96 })
    .onClick(() => this.openUrl('https://github.com/' + c.handle))
  }

  build() {
    Column() {
      // 标题栏（背景与页面一致，不做色块遮罩）
      Row() {
        HdsCircleBackButton({
          buttonSize: 36,
          iconSize: 20,
          isDarkMode: this.isDarkMode,
          onBack: (): void => {
            this.getUIContext().getRouter().back();
          }
        })

        Text('开发人员')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .margin({ left: 8 })
          .opacity(this.titleShown ? 1 : 0)
          .translate({ x: this.titleShown ? 0 : -20 })
          .animation({ duration: 600, curve: curves.springCurve(0.15, 1, 80, 10) })

        Blank()
      }
      .width('100%')
      .padding({ top: 6 + this.statusBarHeight, left: 8, right: 16, bottom: 6 })

      Scroll() {
        Column() {
          // ── 发起者 ──
          Column() {
            ForEach(CONTRIBUTORS.filter((c: ContributorItem) => c.isFounder), (c: ContributorItem) => {
              Column() {
                this.FounderCard(c)
              }
              .width('100%')
            }, (c: ContributorItem) => c.handle)
          }
          .width('100%')
          .opacity(this.founderShown ? 1 : 0)
          .scale({ x: this.founderShown ? 1 : 0.92, y: this.founderShown ? 1 : 0.92 })
          .translate({ y: this.founderShown ? 0 : 40 })
          .animation({ duration: 900, curve: curves.springCurve(0.15, 1, 80, 12) })

          // ── 其他开发人员 ──
          Column() {
            Text('感谢以下开发者为这个项目做出的贡献')
              .fontSize(12)
              .fontColor('#8E8E93')
              .width('100%')
              .margin({ top: 14, bottom: 10 })

            ForEach(CONTRIBUTORS.filter((c: ContributorItem) => !c.isFounder), (c: ContributorItem) => {
              Column() {
                this.ContributorCard(c)
              }
              .width('100%')
              .margin({ bottom: 10 })
            }, (c: ContributorItem) => c.handle)
          }
          .width('100%')
          .opacity(this.listShown ? 1 : 0)
          .scale({ x: this.listShown ? 1 : 0.92, y: this.listShown ? 1 : 0.92 })
          .translate({ y: this.listShown ? 0 : 40 })
          .animation({ duration: 900, curve: curves.springCurve(0.15, 1, 80, 12) })

          // 欢迎加入共同开发学习
          // 深浅色互为反色：深色模式白底黑字，浅色模式黑底白字
          Row() {
            Column() {
              Text('欢迎加入共同开发学习')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isDarkMode ? '#000000' : '#FFFFFF')
              Text('有想法、发现 bug、想要新功能，提 Issue 或 PR 都可以')
                .fontSize(11)
                .fontColor(this.isDarkMode ? 'rgba(0,0,0,0.62)' : 'rgba(255,255,255,0.78)')
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text('GitHub')
              .fontSize(12)
              .fontColor(this.isDarkMode ? '#000000' : '#FFFFFF')
              .opacity(0.9)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 18, bottom: 18 })
          .borderRadius(14)
          .backgroundColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .margin({ top: 4, bottom: 24 })
          .opacity(this.ctaShown ? 1 : 0)
          .scale({ x: this.ctaShown ? 1 : 0.92, y: this.ctaShown ? 1 : 0.92 })
          .translate({ y: this.ctaShown ? 0 : 40 })
          .animation({ duration: 900, curve: curves.springCurve(0.15, 1, 80, 12) })
          .clickEffect({ level: 2, scale: 0.96 })
          .onClick(() => this.openUrl(GITHUB_REPO_URL))
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .backgroundColor(this.isDarkMode ? '#000000' : '#F5F5F5')
    .height('100%')
    .width('100%')
  }
}
