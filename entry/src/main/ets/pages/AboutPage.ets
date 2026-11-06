/**
 * 关于软件
 * 只保留三块内容：应用信息、借鉴与学习、贡献者（默认收起，每人一行摘要）、欢迎加入共同开发。
 * 贡献者的完整清单在 ContributorsPage。
 */
import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { logWarn } from '../utils/Logger';
import { HdsCircleBackButton } from '../components/infra/HdsCircleBackButton';
import {
  ContributorItem, LearnedProject, CONTRIBUTORS, LEARNED_PROJECTS, GITHUB_REPO_URL
} from '../model/ContributorData';

@Entry
@Component
struct AboutPage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  private readonly appVersion: string = '1.3.8';
  private readonly appBuild: string = '1000023';

  /** 入场动画：标题与各卡片依次浮起（复用首页卡片入场那套弹簧曲线） */
  @State titleShown: boolean = false;
  @State headerShown: boolean = false;
  @State learnedShown: boolean = false;
  @State devsShown: boolean = false;
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
    this.headerShown = false;
    this.learnedShown = false;
    this.devsShown = false;
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
   * ⚠️ 不能只用 aboutToAppear：从开发人员页返回时本页还在路由栈里，
   * aboutToAppear 不会再次执行，动画就只播第一次。
   */
  onPageShow(): void {
    this.clearAnimTimers();
    this.resetAnimState();
    // 先让"隐藏态"渲染一帧，下一帧再置真，动画才会真正插值
    this.animTimers.push(setTimeout(() => { this.titleShown = true; }, 16));
    this.animTimers.push(setTimeout(() => { this.headerShown = true; }, 90));
    this.animTimers.push(setTimeout(() => { this.learnedShown = true; }, 180));
    this.animTimers.push(setTimeout(() => { this.devsShown = true; }, 270));
    this.animTimers.push(setTimeout(() => { this.ctaShown = true; }, 360));
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
        logWarn(`[AboutPage] 打开链接失败: ${e.message}`);
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '无法打开链接', duration: 1200 });
    }
  }

  /** 进入贡献者完整清单 */
  private goToContributors(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/ContributorsPage' })
      .catch((err: Error) => {
        this.getUIContext().getPromptAction().showToast({ message: '打开失败', duration: 1200 });
        logWarn(`[AboutPage] 跳转贡献者页失败: ${err.message}`);
      });
  }

  /** 分组标题 */
  @Builder
  GroupLabel(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor('#8E8E93')
      .width('100%')
      .margin({ left: 4, bottom: 6 })
  }

  /** 借鉴项目：正方形磁贴（图标 + 名称） */
  @Builder
  ProjectTile(p: LearnedProject) {
    Column() {
      Image(p.icon)
        .width(60)
        .height(60)
        .borderRadius(16)
        .objectFit(ImageFit.Cover)
      Text(p.name)
        .fontSize(12)
        .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        .margin({ top: 10 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(144)
    .height(144)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(20)
    .backgroundColor(this.isDarkMode ? '#1C1C1E' : '#FFFFFF')
    .clickEffect({ level: 2, scale: 0.94 })
    .onClick(() => this.openUrl(p.url))
  }

  /** 开发人员一行摘要（默认收起状态），点击进入完整清单 */
  @Builder
  ContributorRow(c: ContributorItem, showDivider: boolean) {
    Column() {
      if (showDivider) {
        Divider()
          .strokeWidth(0.5)
          .color(this.isDarkMode ? 'rgba(84,84,88,0.42)' : 'rgba(60,60,67,0.13)')
          .margin({ left: 66 })
      }
      Row() {
        Image(c.avatar)
          .width(44)
          .height(44)
          .borderRadius(22)
          .objectFit(ImageFit.Cover)
          .alt($r('app.media.icon'))
        Row() {
          Text(c.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          if (c.role.length > 0) {
            Text(c.role)
              .fontSize(9)
              .fontColor(this.isDarkMode ? '#0A84FF' : '#007DFF')
              .borderRadius(8)
              .borderWidth(1)
              .borderColor(this.isDarkMode ? '#0A84FF' : '#007DFF')
              .padding({ left: 5, right: 5 })
              .margin({ left: 6 })
              .opacity(0.85)
          }
        }
        .layoutWeight(1)
        .margin({ left: 12 })
        .alignItems(VerticalAlign.Center)

        Image($r('app.media.chevron_right'))
          .width(14)
          .height(14)
          .fillColor('#B8B8BD')
          .opacity(0.85)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
      .clickEffect({ level: 2, scale: 0.97 })
      .onClick(() => this.goToContributors())
    }
    .width('100%')
  }

  /** 应用信息卡：图标在左、名称/版本/名称由来在右（渐变底，深浅色各一套） */
  @Builder
  AppHeaderCard() {
    Row() {
      Image($r('app.media.icon'))
        .width(76)
        .height(76)
        .borderRadius(19)
        .objectFit(ImageFit.Cover)

      Column() {
        Text('云上太学')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text('v' + this.appVersion + ' · Build ' + this.appBuild)
          .fontSize(11)
          .fontColor('#8E8E93')
          .margin({ top: 5 })
        Text('名称由来：B站大学')
          .fontSize(11)
          .fontColor('#8E8E93')
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 16 })
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 28, bottom: 28 })
    .borderRadius(18)
    .margin({ bottom: 18 })
    // 深浅色统一用深色卡片：浅色模式下同样深底白字，与「欢迎加入」卡片互为呼应
    .linearGradient({
      angle: 150,
      colors: [['#1B1F2A', 0.0], ['#241C2A', 1.0]]
    })
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

        Text('关于软件')
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
          // ── 应用信息 ──
          Column() {
            this.AppHeaderCard()
          }
          .width('100%')
          .opacity(this.headerShown ? 1 : 0)
          .scale({ x: this.headerShown ? 1 : 0.92, y: this.headerShown ? 1 : 0.92 })
          .translate({ y: this.headerShown ? 0 : 40 })
          .animation({ duration: 900, curve: curves.springCurve(0.15, 1, 80, 12) })

          // ── 借鉴与学习 ──
          Column() {
            this.GroupLabel('借鉴与学习')
            // 正方形磁贴左对齐排列，不拉伸成横条
            Row({ space: 10 }) {
              ForEach(LEARNED_PROJECTS, (p: LearnedProject) => {
                this.ProjectTile(p)
              }, (p: LearnedProject) => p.name)
            }
            .width('100%')
          }
          .width('100%')
          .opacity(this.learnedShown ? 1 : 0)
          .scale({ x: this.learnedShown ? 1 : 0.92, y: this.learnedShown ? 1 : 0.92 })
          .translate({ y: this.learnedShown ? 0 : 40 })
          .animation({ duration: 900, curve: curves.springCurve(0.15, 1, 80, 12) })

          // ── 开发人员（默认收起：每人一行摘要）──
          Column() {
            Column() {
              this.GroupLabel('开发人员')
            }
            .width('100%')
            .margin({ top: 16 })

            Column() {
              ForEach(CONTRIBUTORS, (c: ContributorItem, idx: number) => {
                this.ContributorRow(c, idx > 0)
              }, (c: ContributorItem) => c.handle)
            }
            .width('100%')
            .borderRadius(14)
            .backgroundColor(this.isDarkMode ? '#1C1C1E' : '#FFFFFF')
            .clip(true)
          }
          .width('100%')
          .opacity(this.devsShown ? 1 : 0)
          .scale({ x: this.devsShown ? 1 : 0.92, y: this.devsShown ? 1 : 0.92 })
          .translate({ y: this.devsShown ? 0 : 40 })
          .animation({ duration: 900, curve: curves.springCurve(0.15, 1, 80, 12) })

          // ── 欢迎加入共同开发学习 ──
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
          .margin({ top: 16 })
          .opacity(this.ctaShown ? 1 : 0)
          .scale({ x: this.ctaShown ? 1 : 0.92, y: this.ctaShown ? 1 : 0.92 })
          .translate({ y: this.ctaShown ? 0 : 40 })
          .animation({ duration: 900, curve: curves.springCurve(0.15, 1, 80, 12) })
          .clickEffect({ level: 2, scale: 0.96 })
          .onClick(() => this.openUrl(GITHUB_REPO_URL))

          // ── 底部声明 ──
          Text('本项目仅供开发学习，不对外传播')
            .fontSize(11)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            .opacity(this.ctaShown ? 0.42 : 0)
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ top: 26, bottom: 28 })
            .animation({ duration: 900, curve: Curve.EaseOut })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8 })
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
