// QrCodeLoginPage.ets — 扫码登录（纯API方案，不依赖WebView Cookie同步延迟）
import { router } from '@kit.ArkUI';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import {
  generateLoginQrCode,
  pollQrCodeStatusApi,
  generateTvLoginQrCode,
  pollTvQrCodeStatusApi,
  QrCodeStatus,
  QrCodePollResult
} from '../api/BilibiliApi';

@Entry
@Component
struct QrCodeLoginPage {
  @State qrImageUrl: string = '';
  @State statusText: string = '正在生成二维码...';
  @State statusSubText: string = '';
  @State isPolling: boolean = false;
  @State isExpired: boolean = false;
  @State isSuccess: boolean = false;
  @State isTvMode: boolean = true;  // true=TV登录(默认), false=Web扫码
  @State showNotice: boolean = true;
  private qrcodeKey: string = '';
  private initialCookies: string = '';  // generate 阶段返回的初始 Cookie，用于 poll 时保持会话
  private pollTimer: number = -1;

  async aboutToAppear(): Promise<void> {
    await this.generateQrCode();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  /** 生成登录二维码 */
  private async generateQrCode(): Promise<void> {
    this.isExpired = false;
    this.isSuccess = false;
    this.isPolling = false;
    this.statusText = '正在生成二维码...';
    this.statusSubText = '';
    this.qrImageUrl = '';
    this.initialCookies = '';

    if (this.isTvMode) {
      // ── TV端登录 ──
      const result = await generateTvLoginQrCode();
      if (!result) {
        this.statusText = '生成二维码失败';
        this.statusSubText = '请检查网络后重试';
        return;
      }
      this.qrcodeKey = result.qrcode_key; // auth_code
      this.qrImageUrl = `https://api.qrserver.com/v1/create-qr-code/?size=250x250&data=${encodeURIComponent(result.url)}`;
      this.statusText = '请使用B站客户端扫描二维码';
      this.statusSubText = '打开B站APP → 我的 → 扫一扫';
    } else {
      // ── Web端扫码登录 ──
      const result = await generateLoginQrCode();
      if (!result) {
        this.statusText = '生成二维码失败';
        this.statusSubText = '请检查网络后重试';
        return;
      }
      this.qrcodeKey = result.qrcode_key;
      this.initialCookies = result._cookies || '';
      this.qrImageUrl = `https://api.qrserver.com/v1/create-qr-code/?size=250x250&data=${encodeURIComponent(result.url)}`;
      this.statusText = '请使用B站客户端扫描二维码';
      this.statusSubText = '打开B站APP → 我的 → 扫一扫';
    }

    this.isPolling = true;
    this.startPolling();
  }

  /** 启动轮询（每2秒一次） */
  private startPolling(): void {
    this.stopPolling();
    // 首次立即轮询
    this.doPoll();
    this.pollTimer = setInterval(() => {
      this.doPoll();
    }, 2000);
  }

  /** 停止轮询 */
  private stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    this.isPolling = false;
  }

  /** 执行一次轮询 */
  private async doPoll(): Promise<void> {
    if (this.isSuccess || this.isExpired) return;

    let result: QrCodePollResult;
    if (this.isTvMode) {
      result = await pollTvQrCodeStatusApi(this.qrcodeKey);
    } else {
      result = await pollQrCodeStatusApi(this.qrcodeKey, this.initialCookies);
    }

    switch (result.status) {
      case QrCodeStatus.SUCCESS:
        this.onLoginSuccess(result.cookies, result.accessKey || '');
        break;
      case QrCodeStatus.SCANNED:
        if (this.statusText !== '已扫码，请在手机上确认登录') {
          this.statusText = '已扫码，请在手机上确认登录';
          this.statusSubText = '点击确认即可完成登录';
        }
        break;
      case QrCodeStatus.EXPIRED:
        this.onQrCodeExpired();
        break;
      case QrCodeStatus.NOT_SCANNED:
        // 保持等待状态
        break;
      default:
        logWarn(`未知轮询状态: ${result.status}`);
        break;
    }
  }

  /** 二维码过期处理 */
  private onQrCodeExpired(): void {
    this.stopPolling();
    this.isExpired = true;
    this.statusText = '二维码已过期';
    this.statusSubText = '请点击下方按钮重新获取';
  }

  /** 登录成功处理 */
  private async onLoginSuccess(cookieStr: string, accessKey: string): Promise<void> {
    this.stopPolling();
    this.isSuccess = true;
    this.statusText = '登录成功！';
    this.statusSubText = '即将返回...';

    logInfo(`[QR登录页] 收到Cookie: ${cookieStr ? cookieStr.substring(0, 120) + '...' : '(空)'}`);
    logInfo(`[QR登录页] accessKey: ${accessKey ? accessKey.substring(0, 10) + '...' : '(空)'}`);

    try {
      // 保存 Cookie
      AppStorage.setOrCreate('biliCookie', cookieStr);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('biliCookie', cookieStr);

      // 保存 access_key（TV 登录直接有，Web 登录尝试从 API 层获取）
      const ak: string = accessKey || (AppStorage.get<string>('biliAccessKey') ?? '');
      if (ak) {
        await pref.put('biliAccessKey', ak);
        AppStorage.setOrCreate('biliAccessKey', ak);
        logInfo(`[QR登录页] access_key 已持久化: ${ak.substring(0, 10)}...`);
      }
      await pref.flush();

      // 验证保存结果
      const saved = await pref.get('biliCookie', '') as string;
      logInfo(`[QR登录页] preferences保存后验证: ${saved ? saved.substring(0, 80) + '...' : '(空)'}`);
      const appStorageVal = AppStorage.get<string>('biliCookie') ?? '';
      logInfo(`[QR登录页] AppStorage验证: ${appStorageVal ? appStorageVal.substring(0, 80) + '...' : '(空)'}`);

      // 触发首页刷新
      const flag: number = AppStorage.get<number>('refreshHomeFlag') ?? 0;
      AppStorage.set('refreshHomeFlag', flag + 1);
      this.getUIContext().getPromptAction().showToast({ message: '登录成功！' });
    } catch (err) {
      logError(`保存Cookie失败: ${err}`);
    }

    // 延迟返回上一页
    setTimeout(() => this.getUIContext().getRouter().back(), 800);
  }

  /** 重新生成二维码 */
  private refreshQrCode(): void {
    this.generateQrCode();
  }

  /** 切换到 TV 登录 */
  private switchToTvLogin(): void {
    this.stopPolling();
    this.isTvMode = true;
    this.statusText = '正在生成TV端二维码...';
    this.statusSubText = '';
    this.generateQrCode();
  }

  /** 切换到 Web 扫码登录 */
  private switchToWebQrLogin(): void {
    this.stopPolling();
    this.isTvMode = false;
    this.statusText = '正在生成二维码...';
    this.statusSubText = '';
    this.generateQrCode();
  }

  /** 切换到 WebView 登录 */
  private switchToWebLogin(): void {
    router.replaceUrl({ url: 'pages/BilibiliLoginPage' }).catch((err: Error) => {
      logError('跳转Web登录失败', err);
    });
  }

  build() {
    Stack() {
      Column() {
        // ── 顶部导航栏（仅有标题） ──
        Row() {
          Text(this.isTvMode ? 'TV扫码登录' : 'Web扫码登录')
            .fontSize(18).fontColor(Color.White).fontWeight(FontWeight.Medium)
            .width('100%').textAlign(TextAlign.Start).margin({ left: 20 })
        }
        .width('100%')
        .height(56)
        .padding({ left: 8, right: 8 })
        .backgroundColor('rgba(0,0,0,0.9)')

        // ── 主体内容 ──
        Column() {
          // 二维码区域
          Column() {
            if (this.qrImageUrl) {
              Image(this.qrImageUrl)
                .width(220)
                .height(220)
                .objectFit(ImageFit.Contain)
                .borderRadius(12)
                .backgroundColor(Color.White)
                .padding(8)
            } else {
              // 加载占位
              Column() {
                LoadingProgress().width(48).height(48).color('#007DFF')
              }
              .width(220)
              .height(220)
              .justifyContent(FlexAlign.Center)
              .borderRadius(12)
              .backgroundColor('rgba(255,255,255,0.1)')
            }

            // 成功动效
            if (this.isSuccess) {
              Text('✓')
                .fontSize(48)
                .fontColor('#00C853')
                .margin({ top: 16 })
            }
          }
          .margin({ top: 40 })

          // 状态文字
          Column() {
            Text(this.statusText)
              .fontSize(18)
              .fontColor(this.isSuccess ? '#00C853' : (this.isExpired ? '#FF5252' : Color.White))
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Center)

            if (this.statusSubText) {
              Text(this.statusSubText)
                .fontSize(13)
                .fontColor('#AAAAAA')
                .textAlign(TextAlign.Center)
                .margin({ top: 8 })
            }

            // 轮询中动画
            if (this.isPolling && !this.isExpired && !this.isSuccess) {
              Row() {
                LoadingProgress()
                  .width(20).height(20)
                  .color('#007DFF')
                Text('等待扫码中...')
                  .fontSize(13)
                  .fontColor('#888888')
                  .margin({ left: 8 })
              }
              .margin({ top: 16 })
            }
          }
          .margin({ top: 24 })
          .padding({ left: 24, right: 24 })

          // 操作按钮
          Column() {
            if (this.isExpired) {
              Button('重新获取二维码')
                .width('80%').height(44)
                .backgroundColor('#007DFF')
                .borderRadius(22)
                .fontColor(Color.White)
                .onClick(() => this.refreshQrCode())
            } else if (!this.isSuccess) {
              Button('重新获取')
                .width('60%').height(40)
                .backgroundColor('transparent')
                .border({ width: 1, color: '#555555' })
                .borderRadius(20)
                .fontColor('#999999')
                .onClick(() => this.refreshQrCode())
            }
          }
          .margin({ top: 32 })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)

        // ── 登录模式切换（TV / Web） ──
        Row({ space: 16 }) {
          Button() {
            Text(this.isTvMode ? 'Web扫码' : 'TV登录')
              .fontSize(14).fontColor('#007DFF')
          }
          .height(40).padding({ left: 24, right: 24 })
          .backgroundColor('rgba(0,125,255,0.1)')
          .borderRadius(20)
          .onClick(() => {
            if (this.isTvMode) {
              this.switchToWebQrLogin();
            } else {
              this.switchToTvLogin();
            }
          })

          Button() {
            Text('Web网页登录').fontSize(14).fontColor('#AAAAAA')
          }
          .height(40).padding({ left: 24, right: 24 })
          .backgroundColor('rgba(255,255,255,0.08)')
          .borderRadius(20)
          .onClick(() => this.switchToWebLogin())
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: 16 })

        // ── 底部提示 ──
        Text(this.isTvMode ? 'TV登录可获取 access_key，享受个性化推荐' : '支持账号密码 / 短信 / 扫码登录')
          .fontSize(12)
          .fontColor('#666666')
          .textAlign(TextAlign.Center)
          .padding({ bottom: 24 })
      }
      .width('100%')
      .height('100%')

      // ── 提示弹窗（覆盖层） ──
      if (this.showNotice) {
        Column() {
          Column() {
            Text('注意！')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FF4444')
              .textAlign(TextAlign.Center)
              .width('100%')
            Text('仅TV扫码登陆，推荐源为App API时可实现自己的个性化推荐（自己喜欢看的内容）。')
              .fontSize(15)
              .fontColor('#FF4444')
              .textAlign(TextAlign.Start)
              .width('100%')
              .lineHeight(22)
              .margin({ top: 12 })
            Button('我知道了')
              .width(200).height(40)
              .backgroundColor('#FF4444')
              .borderRadius(20)
              .fontColor(Color.White)
              .fontSize(15)
              .margin({ top: 20 })
              .onClick(() => {
                this.showNotice = false;
              })
          }
          .width('85%')
          .padding(24)
          .backgroundColor('#2A0000')
          .borderRadius(16)
          .border({ width: 1, color: 'rgba(255,68,68,0.3)' })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.6)')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => {
          this.showNotice = false;
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#111111')
  }
}
