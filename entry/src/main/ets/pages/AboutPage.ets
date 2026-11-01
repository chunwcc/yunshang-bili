/**
 * 关于软件页面 — HDS Navigation + 沉浸式渐变标题栏 + Hivid 风格分组卡片
 */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { LengthMetrics } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { readErrorLog, clearErrorLog, getErrorLogSize } from '../utils/ErrorLogCollector';

@Entry
@Component
struct AboutPage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  private readonly appVersion: string = '1.3.7';
  @State cacheSizeText: string = '计算中…';
  @State logSizeText: string = '';

  async aboutToAppear(): Promise<void> {
    await this.calcCacheSize();
    this.refreshLogSize();
  }

  private refreshLogSize(): void {
    const size = getErrorLogSize();
    this.logSizeText = size > 0 ? this.formatSize(size) : '空';
  }

  /** 提取错误日志到剪贴板 */
  private async extractErrorLog(): Promise<void> {
    const log = readErrorLog();
    if (log === '暂无错误日志' || log.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '暂无错误日志' });
      return;
    }
    try {
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, log);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      await systemPasteboard.setData(pasteData);
      this.getUIContext().getPromptAction().showDialog({
        title: '错误日志已复制',
        message: `日志大小：${this.formatSize(log.length)}\n已复制到剪贴板，可粘贴发送给开发者。\n\n是否同时清空已提取的日志？`,
        buttons: [
          { text: '不清空', color: '#666666' },
          { text: '清空', color: '#007DFF' }
        ]
      }).then((r) => {
        if (r.index === 1) {
          clearErrorLog();
          this.refreshLogSize();
        }
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败: ' + String(e) });
    }
  }

  /** 格式化字节数 */
  private formatSize(bytes: number): string {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / 1048576).toFixed(1) + ' MB';
  }

  /** 递归计算目录大小 */
  private getDirSize(dirPath: string): number {
    let total = 0;
    try {
      const names: string[] = fileIo.listFileSync(dirPath);
      for (const name of names) {
        const fullPath: string = dirPath + '/' + name;
        try {
          const stat = fileIo.statSync(fullPath);
          if (stat.isDirectory()) {
            total += this.getDirSize(fullPath);
          } else {
            total += stat.size;
          }
        } catch (_) {}
      }
    } catch (_) {}
    return total;
  }

  /** 计算缓存总大小 */
  private async calcCacheSize(): Promise<void> {
    try {
      const context: common.Context = this.getUIContext().getHostContext() as common.Context;
      let total = 0;
      total += this.getDirSize(context.cacheDir);
      this.cacheSizeText = this.formatSize(total);
    } catch (_) {
      this.cacheSizeText = '获取失败';
    }
  }

  /** 递归清空目录 */
  private clearDir(dirPath: string): void {
    try {
      const names: string[] = fileIo.listFileSync(dirPath);
      for (const name of names) {
        const fullPath: string = dirPath + '/' + name;
        try {
          const stat = fileIo.statSync(fullPath);
          if (stat.isDirectory()) {
            this.clearDir(fullPath);
            fileIo.rmdirSync(fullPath);
          } else {
            fileIo.unlinkSync(fullPath);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /** 清除缓存 */
  private async clearCache(): Promise<void> {
    const result = await this.getUIContext().getPromptAction().showDialog({
      title: '清除缓存',
      message: '确定要清除缓存数据吗？\n（仅清除临时缓存）',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '确定', color: '#007DFF' }
      ]
    });
    if (result.index === 1) {
      try {
        const context: common.Context = this.getUIContext().getHostContext() as common.Context;
        this.clearDir(context.cacheDir);
        await this.calcCacheSize();
        this.getUIContext().getPromptAction().showToast({ message: '缓存已清除' });
      } catch (_) {
        this.getUIContext().getPromptAction().showToast({ message: '清除失败' });
      }
    }
  }

  @Builder
  CardRowItem(title: string, valueText: string, onClick: () => void, isSmallVal: boolean = false) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)

      if (valueText.length > 0) {
        Text(valueText)
          .fontSize(isSmallVal ? 12 : 14)
          .fontColor($r('sys.color.font_secondary'))
          .margin({ right: 6 })
      }

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => onClick())
  }

  build() {
    HdsNavigation() {
      Scroll() {
        Column() {
          // 应用图标与信息
          Column() {
            Image($r('app.media.icon'))
              .width(100)
              .height(100)
              .borderRadius(24)
              .objectFit(ImageFit.Contain)
              .margin({ top: 24, bottom: 16 })

            Text('云上太学')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
              .margin({ bottom: 6 })

            Text(`v${this.appVersion}`)
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
              .margin({ bottom: 28 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)

          // 核心功能维护卡片（Hivid 分组卡片风格）
          Column() {
            this.CardRowItem('清除缓存', this.cacheSizeText, () => this.clearCache())

            Divider()

            this.CardRowItem('提取错误日志', this.logSizeText, () => this.extractErrorLog())

            Divider()

            this.CardRowItem('DASH PoC 验证', '单播放器 DASH 双流', () => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/DashPocPage' });
            }, true)
          }
          .width('94%')
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(15)

          // 声明卡片
          Column() {
            Row() {
              Text('免责声明')
                .fontSize(16)
                .fontColor($r('sys.color.font_primary'))
              Blank()
              Text('开发学习交流使用，不对外传播')
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
            }
            .width('100%')
            .height(56)
            .padding({ left: 16, right: 16 })
            .alignItems(VerticalAlign.Center)

            Divider()

            Row() {
              Text('开源声明')
                .fontSize(16)
                .fontColor($r('sys.color.font_primary'))
              Blank()
              Text('遵循开源许可证规定')
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
            }
            .width('100%')
            .height(56)
            .padding({ left: 16, right: 16 })
            .alignItems(VerticalAlign.Center)
          }
          .width('94%')
          .margin({ top: 16, bottom: 40 })
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(15)
        }
        .width('100%')
        .padding({ top: this.statusBarHeight + 56, bottom: 32 })
      }
      .width('100%')
      .height('100%')
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      padding: { start: LengthMetrics.vp(16), end: LengthMetrics.vp(16) },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        },
        originalStyle: {
          backgroundStyle: { backgroundColor: 'transparent' },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            menuStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') },
            backIconStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: { backgroundColor: 'transparent' },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('sys.color.font_primary'), subTitleColor: $r('sys.color.font_secondary') },
            menuStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') },
            backIconStyle: { backgroundColor: $r('sys.color.comp_background_tertiary'), iconColor: $r('sys.color.icon_primary') }
          }
        }
      },
      content: {
        title: {
          mainTitle: '关于软件'
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
