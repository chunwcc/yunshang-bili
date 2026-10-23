/**
 * EntryAbility.ets
 * 主 Ability — 按官方 MusicCard 模式重写
 *
 * 新增功能：
 * 1. callee.on('playByAction') — 接收卡片播放/暂停控制命令
 * 2. callee.on('requestUpdatePlayCard') — 接收卡片数据拉取请求
 * 3. 播放状态变化时 → FormUtils.updatePlayControlCards() 批量推送
 * 4. AppStorage 共享播放状态（供卡片 call 响应时读取）
 */
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, router } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { rpc } from '@kit.IPCKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import FormUtils from '../utils/FormUtils';
import { PlayerService } from '../services/PlayerService';
import { AppScaleService } from '../services/AppScaleService';
import { errMsg } from '../utils/Logger';
import { setErrorLogContext, appendErrorLog } from '../utils/ErrorLogCollector';
import { BiliLinkParser, BiliLinkResult } from '../utils/BiliLinkParser';
import errorManager from '@ohos.app.ability.errorManager';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  private pendingUri: string | null = null;

  // ==================== Callee 处理器 ====================

  /** 播放控制（卡片发来的播放/暂停命令） */
  private playByActionCall(data: rpc.MessageSequence): MyParcelable {
    try {
      const params: Record<string, string> = JSON.parse(data.readString());
      const playActionType = params['playActionType'] as string;
      const formId = params['formId'] as string;
      const ps = PlayerService.getInstance();

      if (playActionType === '0') {
        // 暂停
        if (ps.hasActivePlayer) {
          ps.pause();
        }
      } else if (playActionType === '1') {
        // 播放
        if (ps.hasActivePlayer) {
          ps.play();
        }
      }
      // 更新后推送状态到该卡片
      if (formId) {
        FormUtils.updateSingleCard(this.context, formId);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'playByActionCall error: %{public}s', JSON.stringify(e));
    }
    return new MyParcelable(0);
  }

  /** 卡片请求数据更新（卡片首次加载或刷新时触发） */
  private requestUpdatePlayCard(data: rpc.MessageSequence): MyParcelable {
    try {
      const params: Record<string, string> = JSON.parse(data.readString());
      const formId = params['formId'] as string;
      if (formId) {
        FormUtils.updateSingleCard(this.context, formId);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'requestUpdatePlayCard error: %{public}s', JSON.stringify(e));
    }
    return new MyParcelable(0);
  }

  // ==================== 生命周期 ====================

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    AppStorage.setOrCreate('appContext', this.context);
    PlayerService.setAppContext(this.context);
    setErrorLogContext(this.context);
    this.registerGlobalErrorHandler();
    this.loadCardSettings();
    this.registerCalleeHandlers();
    PersistentStorage.persistProp('statusBarHeight', 40);

    if (want.uri && want.uri.length > 0) {
      this.pendingUri = want.uri;
      hilog.info(DOMAIN, TAG, 'onCreate received deep link: %{public}s', want.uri);
    }
  }

  /** 注册全局异常处理器 — 未捕获的 JS 异常写入错误日志文件 */
  private registerGlobalErrorHandler(): void {
    try {
      errorManager.on('globalErrorOccurred', (err: Error) => {
        const stack = (err as Error).stack ?? '';
        appendErrorLog('FATAL', 'errorManager', `name: ${err.name}, message: ${err.message}, stack: ${stack}`);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'register errorManager failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 注册 callee 处理器（匹配 ActionUtils 中的 CallMethod） */
  private registerCalleeHandlers(): void {
    try {
      this.callee.on('playByAction', (data: rpc.MessageSequence): MyParcelable => {
        return this.playByActionCall(data);
      });
      this.callee.on('requestUpdatePlayCard', (data: rpc.MessageSequence): MyParcelable => {
        return this.requestUpdatePlayCard(data);
      });
      hilog.info(DOMAIN, TAG, 'callee handlers registered');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'register callee failed: %{public}s', JSON.stringify(e));
    }
  }

  onDestroy(): void {
    // 应用退出前更新卡片为"无播放"状态
    this.updateCardsOnExit();
    try {
      this.callee.off('playByAction');
      this.callee.off('requestUpdatePlayCard');
    } catch (_e) {
      // ignore
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  /** 应用退出时通知所有卡片 */
  private updateCardsOnExit(): void {
    const isPlay = AppStorage.get<boolean>('cardIsPlay') ?? false;
    if (isPlay) {
      FormUtils.updateCardPlayStatus(this.context, false);
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onNewWant');
    if (want.uri && want.uri.length > 0) {
      hilog.info(DOMAIN, TAG, 'onNewWant received deep link: %{public}s', want.uri);
      this.handleDeepLink(want.uri);
    }
  }

  private handleDeepLink(uri: string): void {
    const result = BiliLinkParser.parse(uri);
    if (!result) {
      hilog.info(DOMAIN, TAG, 'deep link not recognized: %{public}s', uri);
      return;
    }

    if (result.page === '__shortlink__') {
      this.resolveShortLink(uri);
      return;
    }

    hilog.info(DOMAIN, TAG, 'deep link navigating to: %{public}s, params: %{public}s', result.page, JSON.stringify(result.params));
    try {
      router.pushUrl({ url: result.page, params: result.params });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'deep link navigation failed: %{public}s', JSON.stringify(e));
    }
  }

  private async resolveShortLink(url: string): Promise<void> {
    try {
      const httpRequest = http.createHttp();
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'Mozilla/5.0' },
        connectTimeout: 5000,
        readTimeout: 5000
      });
      httpRequest.destroy();

      const location = response.header?.['location'] as string ?? '';
      if (location && location.length > 0) {
        hilog.info(DOMAIN, TAG, 'short link redirected to: %{public}s', location);
        this.handleDeepLink(location);
      } else {
        hilog.info(DOMAIN, TAG, 'short link no redirect, responseCode=%{public}d', response.responseCode);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'short link resolve failed: %{public}s', JSON.stringify(e));
    }
  }


  // ==================== 窗口/UI 配置 ====================

  private async loadCardSettings(): Promise<void> {
    try {
      const pref = await preferences.getPreferences(this.context, 'my_app_settings');
      const cardMargin = await pref.get('cardMargin', 12) as number;
      AppStorage.setOrCreate('cardMargin', cardMargin);
      const cardBorderRadius = await pref.get('cardBorderRadius', 20) as number;
      AppStorage.setOrCreate('cardBorderRadius', cardBorderRadius);
      const cardListBorderRadius = await pref.get('cardListBorderRadius', 12) as number;
      AppStorage.setOrCreate('cardListBorderRadius', cardListBorderRadius);
      const cardListMargin = await pref.get('cardListMargin', 12) as number;
      AppStorage.setOrCreate('cardListMargin', cardListMargin);
      // ⭐ 加载全局关闭动画开关（避免重启后失效）
      const disableAnimations = await pref.get('da', false) as boolean;
      AppStorage.setOrCreate('da', disableAnimations);
      // ⭐ 加载屏幕旋转锁定（避免重启后视频页回退为自动旋转）
      const orientationLock = await pref.get('screenOrientationLock', '自动旋转') as string;
      AppStorage.setOrCreate('screenOrientationLock', orientationLock);
      // ⭐ 加载震动反馈开关（避免重启后震动失效或无法关闭）
      const vibrateEnabled = await pref.get('vibrateEnabled', true) as boolean;
      AppStorage.setOrCreate('vibrateEnabled', vibrateEnabled);
      // ⭐ 注册 bgp（后台播放开关）为持久化 AppStorage 属性：重启后仍保留（直播/点播共用）。
      //    必须入口注册，否则直接重启进直播页时 persistProp 未执行，@StorageLink('bgp') 只能拿默认 false
      PersistentStorage.persistProp('bgp', false);
      // ⭐ 注册 autoPip（回到桌面自动画中画开关）：同样必须入口注册，重启后仍保留
      PersistentStorage.persistProp('autoPip', true);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Failed to load card settings: %{public}s', JSON.stringify(e));
    }
  }

  private async setupImmersiveWindow(): Promise<void> {
    try {
      const windowClass = await window.getLastWindow(this.context);
      // ★ 在 loadContent 之前设置全屏布局，避免首帧渲染有 117px 避让区
      await windowClass.setWindowLayoutFullScreen(true);
      const sysBarProps: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        statusBarContentColor: '#FFFFFF',
        navigationBarColor: '#00000000',
        navigationBarContentColor: '#FFFFFF',
      };
      await windowClass.setWindowSystemBarProperties(sysBarProps);
      await windowClass.setSpecificSystemBarEnabled('navigationIndicator', true);
      // ★ 按用户偏好和全屏状态设置状态栏显隐
      const isFullscreen: boolean = AppStorage.get<boolean>('isFullscreen') ?? false;
      const hideStatusBar: boolean = AppStorage.get<boolean>('hideStatusBar') ?? false;
      const isLandscape: boolean = AppStorage.get<boolean>('isLandscape') ?? false;
      if (isFullscreen || isLandscape || hideStatusBar) {
        await windowClass.setWindowSystemBarEnable(['navigation']);
        AppStorage.set('statusBarHeight', 0);
      } else {
        await windowClass.setWindowSystemBarEnable(['status', 'navigation']);
        // 竖屏显示状态栏时恢复高度
        const avoidArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const realHeight: number = windowClass.getUIContext().px2vp(avoidArea.topRect.height);
        AppStorage.set('statusBarHeight', realHeight > 0 ? realHeight : 40);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to setup immersive: %{public}s', errMsg(err));
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    // ★ 在 loadContent 之前设置全屏模式，避免首帧渲染时状态栏/胶囊闪烁
    // （首帧 statusBarHeight 由 onCreate 中持久化的默认值 40 兜底，不再依赖异步 getWindowAvoidArea）
    this.setupImmersiveWindow();
    windowStage.loadContent('pages/Index', (err, data) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', errMsg(err) ?? '');
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content. Data: %{public}s', JSON.stringify(data) ?? '');
      this.applyOrientationLockFromPrefs();
      AppStorage.setOrCreate('appWindowStage', windowStage);
      this.applyAppScale(windowStage);

      if (this.pendingUri) {
        const uri = this.pendingUri;
        this.pendingUri = null;
        setTimeout(() => { this.handleDeepLink(uri); }, 500);
      }
    });
  }

  /** 启动时应用「应用比例调节」的自定义比例（system 模式由 engine 默认跟随，无需调用） */
  private async applyAppScale(windowStage: window.WindowStage): Promise<void> {
    await AppScaleService.applyFromPrefsAtStartup(this.context, windowStage);
  }

  /** 从 Preferences 读取并应用屏幕旋转锁定（冷启动时调用，保证重启后立即生效） */
  private async applyOrientationLockFromPrefs(): Promise<void> {
    try {
      const pref = await preferences.getPreferences(this.context, 'my_app_settings');
      const lock = await pref.get('screenOrientationLock', '自动旋转') as string;
      AppStorage.setOrCreate('screenOrientationLock', lock);
      const windowClass = await window.getLastWindow(this.context);
      let orientation: window.Orientation;
      switch (lock) {
        case '锁定竖屏':
          orientation = window.Orientation.PORTRAIT;
          break;
        case '锁定横屏':
          orientation = window.Orientation.AUTO_ROTATION_LANDSCAPE;
          break;
        default:
          orientation = window.Orientation.AUTO_ROTATION;
          break;
      }
      await windowClass.setPreferredOrientation(orientation);
      hilog.info(DOMAIN, TAG, 'Applied orientation lock: %{public}s', lock);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Failed to apply orientation lock: %{public}s', JSON.stringify(e));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
    AppStorage.set('appInBackground', false);
    this.setupImmersiveWindow();
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
    AppStorage.set('appInBackground', true);
    AppStorage.set('appBackgroundTimestamp', Date.now());
  }
}

/** callee 返回类型 */
class MyParcelable implements rpc.Parcelable {
  num: number;

  constructor(num: number) {
    this.num = num;
  }

  marshalling(dataOut: rpc.MessageSequence): boolean {
    dataOut.writeInt(this.num);
    return true;
  }

  unmarshalling(dataIn: rpc.MessageSequence): boolean {
    this.num = dataIn.readInt();
    return true;
  }
}
