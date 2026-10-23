/**
 * 关于软件页面
 */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { readErrorLog, clearErrorLog, getErrorLogSize } from '../utils/ErrorLogCollector';

@Entry
@Component
struct AboutPage {
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  private readonly appVersion: string = '1.3.7';
  @State cacheSizeText: string = '计算中…';
  @State btnScale: number = 1;
  @State logBtnScale: number = 1;
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
      }).then((r) => { if (r.index === 1) { clearErrorLog(); this.refreshLogSize(); } });
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

  build() {
    Column() {
      // 标题栏
      Row() {
        Image($r('app.media.ic_public_arrow_left_filled'))
          .width(24)
          .height(24)
          .fillColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .onClick(() => this.getUIContext().getRouter().back())

        Text('关于软件')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .margin({ left: 16 })

        Blank()
      }
      .width('100%')
      .padding({ top: 16 + this.statusBarHeight, left: 16, right: 16, bottom: 16 })
      .backgroundColor(this.isDarkMode ? '#1C1C1E' : '#FFFFFF')

      // 主体内容
      Column() {
        // 应用图标
        Image($r('app.media.icon'))
          .width(80)
          .height(80)
          .borderRadius(20)
          .margin({ bottom: 20 })

        // 应用名称
        Text('云上太学')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#1C1C1E')
          .margin({ bottom: 8 })

        // 版本号
        Text('v' + this.appVersion)
          .fontSize(14)
          .fontColor(this.isDarkMode ? '#8E8E93' : '#8E8E93')
          .margin({ bottom: 4 })

        Text('Build 1000022')
          .fontSize(11)
          .fontColor(this.isDarkMode ? '#636366' : '#C7C7CC')

        // ⭐ 清除缓存按钮
        Column() {
          Row() {
            Text('清除缓存')
              .fontSize(16)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            Blank()
            Text(this.cacheSizeText)
              .fontSize(14)
              .fontColor('#8E8E93')
              .margin({ right: 8 })
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .margin({ top: 24 })
        .borderRadius(14)
        .backgroundColor(this.isDarkMode ? '#1C1C1E' : '#FFFFFF')
        .scale({ x: this.btnScale, y: this.btnScale })
        .animation({ duration: 120, curve: Curve.EaseOut })
        .onTouch((event: TouchEvent) => {
          animateTo({ duration: 80, curve: Curve.EaseOut }, () => {
            this.btnScale = event.type === TouchType.Down ? 0.96 : 1;
          });
        })
        .onClick(() => this.clearCache())

        // ⭐ DASH PoC 验证入口（验证后可整体移除）
        Column() {
          Row() {
            Text('DASH PoC 验证')
              .fontSize(16)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            Blank()
            Text('单播放器 DASH 双流')
              .fontSize(12)
              .fontColor('#8E8E93')
              .margin({ right: 8 })
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .margin({ top: 12 })
        .borderRadius(14)
        .backgroundColor(this.isDarkMode ? '#1C1C1E' : '#FFFFFF')
        .onClick(() => this.getUIContext().getRouter().pushUrl({ url: 'pages/DashPocPage' }))

        // ⭐ 提取错误日志
        Column() {
          Row() {
            Text('提取错误日志')
              .fontSize(16)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            Blank()
            Text(this.logSizeText)
              .fontSize(14)
              .fontColor('#8E8E93')
              .margin({ right: 8 })
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .margin({ top: 12 })
        .borderRadius(14)
        .backgroundColor(this.isDarkMode ? '#1C1C1E' : '#FFFFFF')
        .scale({ x: this.logBtnScale, y: this.logBtnScale })
        .animation({ duration: 120, curve: Curve.EaseOut })
        .onTouch((event: TouchEvent) => {
          animateTo({ duration: 80, curve: Curve.EaseOut }, () => {
            this.logBtnScale = event.type === TouchType.Down ? 0.96 : 1;
          });
        })
        .onClick(() => this.extractErrorLog())
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      // 底部版权信息
      Column() {
        Text('开发学习，不对外传播。')
          .fontSize(14)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
          .textAlign(TextAlign.Center)
          .opacity(0.5)
      }
      .width('100%')
      .padding({ bottom: 40 })
    }
    .backgroundColor(this.isDarkMode ? '#000000' : '#F5F5F5')
    .height('100%')
    .width('100%')
  }
}
