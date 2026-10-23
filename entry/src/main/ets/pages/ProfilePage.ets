// ProfilePage.ets - 显示壁纸 + 消除白边（透明背景 + expandSafeArea）
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { hdsMaterial } from '@kit.UIDesignKit';
import { VibrateUtils } from '../utils/VibrateUtils';
import { StatusBarUtils } from '../utils/StatusBarUtils';
import { applyWallpaperMode, loadWallpaperModes, persistWallpaperMode } from '../utils/WallpaperTheme';
import { applyCardStyleModeArchive } from '../utils/CardStyleMode';
import { preferences } from '@kit.ArkData';
import { PersonalizationPage } from './PersonalizationPage';
import { AppScaleService, SCALE_MODE_SYSTEM, SCALE_MODE_CUSTOM } from '../services/AppScaleService';
import { window } from '@kit.ArkUI';
import { CardStyleSheet } from './CardStyleSheet';
import { getUserInfo, UserInfo } from '../api/BilibiliApi';
import { HdsMiniBarButton } from '../components/infra/HdsMiniBarButton';

PersistentStorage.persistProp('phoneLayoutToggle', false)

interface QualityItem {
  qn: number;
  label: string;
}

interface ActionButton {
  value: string;
  fontColor: string;
  action: () => void;
}

const QUALITY_LIST: QualityItem[] = [
  { qn: 16, label: '360P' },
  { qn: 32, label: '480P' },
  { qn: 64, label: '720P' },
  { qn: 80, label: '1080P' },
  { qn: 112, label: '1080P+' },
  { qn: 116, label: '1080P60' },
  { qn: 120, label: '4K' }
];

const DEFAULT_QN: number = 116;

/** 档位点定义：值 + 系统档位名 */
interface ScaleStep {
  v: number;
  name: string;
}

/** 界面缩放档位：对应系统「显示和亮度→界面缩放」档位 */
const UI_SCALE_STEPS: ScaleStep[] = [
  { v: 0.9, name: '小' },
  { v: 1.0, name: '标准' },
  { v: 1.1, name: '大' },
  { v: 1.2, name: '特大' }
];
/** 文字大小档位：对应系统「显示和亮度→字体大小」档位（用关怀/放大显示官方档位表） */
const FONT_SCALE_STEPS: ScaleStep[] = [
  { v: 0.85, name: '小' },
  { v: 1.0, name: '标准' },
  { v: 1.15, name: '大' },
  { v: 1.3, name: '特大' },
  { v: 1.45, name: '超大' }
];

function labelByQn(qn: number): string {
  const item = QUALITY_LIST.find(q => q.qn === qn);
  return item ? item.label : '1080P60';
}

@Component({ freezeWhenInactive: true })
export struct ProfilePage {
  @State isPersonalizationSheetShow: boolean = false;
  @State isCardStyleSheetShow: boolean = false;
  @State isAppScaleSheetShow: boolean = false;
  /** 应用比例调节（跟随系统 / 自定义界面缩放+文字大小） */
  @State appScaleMode: string = SCALE_MODE_SYSTEM;
  /** 调整过滑杆但未点「保持并重启」 */
  @State appScaleDirty: boolean = false;
  /** 上次已保存的滑杆值（退出时还原用） */
  @State appUiScaleSaved: number = 1;
  @State appFontScaleSaved: number = 1;
  /** 上次已保存的模式（关闭开关后取消可还原） */
  @State appScaleModeSaved: string = SCALE_MODE_SYSTEM;
  @State appUiScale: number = 1;
  @State appFontScale: number = 1;
  @State carouselExpanded: boolean = false;
  @State carouselTitleExpanded: boolean = false;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  // 预览用：卡片样式全局键（与信息流卡实时一致）
  @StorageLink('cardListBorderRadius') cardListBorderRadius: number = 12;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = true;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 25;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = true;
  @StorageLink('cardBorderFollowPlayCount') cardBorderFollowPlayCount: boolean = false;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 70;
  @StorageLink('cardCustomColor') cardCustomColor: string = '';
  @StorageLink('cardListMargin') cardListMargin: number = 12;
  @StorageLink('cardCapsuleShow') cardCapsuleShow: boolean = true;
  @StorageLink('cardCapsuleFollowTheme') cardCapsuleFollowTheme: boolean = false;
  @StorageLink('cardCapsuleSize') cardCapsuleSize: number = 12;
  @StorageLink('cardCapsuleRadius') cardCapsuleRadius: number = 7;
  @StorageLink('cardCapsuleColor') cardCapsuleColor: string = '';
  @StorageLink('cardPlayCountShow') cardPlayCountShow: boolean = true;
  @StorageLink('cardPlayCountIcon') cardPlayCountIcon: boolean = true;
  @StorageLink('cardPlayCountSize') cardPlayCountSize: number = 12;
  @StorageLink('cardPlayCountColorMode') cardPlayCountColorMode: string = 'level';
  @StorageLink('cardPlayCountColor') cardPlayCountColor: string = '';
  @StorageLink('wallpaper') wallpaper: string = 'builtin';
  @StorageLink('customWallpaper') customWallpaper: string = '';
  @StorageLink('wallpaperBlur') wallpaperBlur: number = 0;
  @StorageLink('wallpaperDarkness') wallpaperDarkness: number = 50;
  @StorageLink('customThemeColor') customThemeColor: string = '#007DFF';
  @StorageLink('biliCookie') biliCookie: string = '';
  @StorageLink('hideStatusBar') hideStatusBar: boolean = true;
  @StorageLink('showSearchDiscovery') showSearchDiscovery: boolean = true;
  @StorageLink('showRefreshSeparator') showRefreshSeparator: boolean = true;
  @StorageLink('phoneLayoutToggle') phoneLayoutToggle: boolean = false;
  @StorageLink('shrinkVideoOnScroll') shrinkVideoOnScroll: boolean = false;
  // ⭐ 消息页 Tab 自动隐藏（默认关闭）
  @StorageLink('msgTabAutoHide') msgTabAutoHide: boolean = false;
  // ⭐ 回桌面自动画中画（默认开启，播放页武装/解除共用此持久化 key）
  @StorageLink('autoPip') autoPip: boolean = true;
  // ⭐ 一级 Tab 显隐（默认显示）— 隐藏后底栏图标与页面一起消失
  @StorageLink('showDynamicsTab') showDynamicsTab: boolean = true;
  @StorageLink('showWhisperTab') showWhisperTab: boolean = true;
  // ⭐ 动态页点击切换分类（默认打开）
  @StorageLink('dynFilterTapOnly') dynFilterTapOnly: boolean = true;
  // ⭐ 首页点击切换分类（默认关闭）
  @StorageLink('homeFilterTapOnly') homeFilterTapOnly: boolean = false;
  @StorageLink('showHomeCarouselPortrait') showHomeCarouselPortrait: boolean = true;
  @StorageLink('showHomeCarouselLandscape') showHomeCarouselLandscape: boolean = true;
  @StorageLink('showCarouselBgPortrait') showCarouselBgPortrait: boolean = true;
  @StorageLink('showCarouselBgLandscape') showCarouselBgLandscape: boolean = true;
  // ⭐ 轮播背景圆角（0-40vp，默认 30）：仅作用于首页背景层顶部两角
  @StorageLink('carouselBgRadius') carouselBgRadius: number = 30;
  // ⭐ 轮播图标题胶囊自定义：字体大小/粗细/胶囊宽高（宽为百分比 20-100，默认 85）
  @StorageLink('carouselTitleFontSize') carouselTitleFontSize: number = 15;
  @StorageLink('carouselTitleFontWeight') carouselTitleFontWeight: string = 'medium';
  @StorageLink('carouselTitleCapsuleWidth') carouselTitleCapsuleWidth: number = 85;
  @StorageLink('carouselTitleCapsuleHeight') carouselTitleCapsuleHeight: number = 36;
  @StorageLink('carouselTitleLetterSpacing') carouselTitleLetterSpacing: number = 1;
  @StorageLink('defaultVideoQn') @Watch('onVideoQnChange') defaultVideoQn: number = DEFAULT_QN;
  @StorageLink('recommendApiSource') recommendApiSource: string = 'App';
  @StorageLink('danmakuApiSource') danmakuApiSource: string = 'grpc';
  @State qualityLabel: string = labelByQn(DEFAULT_QN);
  @StorageProp('refreshHomeFlag') @Watch('onLoginStateChanged') refreshHomeFlag: number = 0;

  /** UI 状态：直接用 @State 驱动渲染，避免 getter 不被重新求值的问题 */
  @State isLoggedIn: boolean = false;
  @State userDisplayName: string = '未登录用户';
  @State userAvatarUrl: string = ''; // 用户头像URL
  @State userMid: number = 0;        // 当前登录用户 mid（点击头像进入个人空间）

  /**
   * refreshHomeFlag 变化时（登录/登出后），强制更新 UI 状态。
   * 规避 Tab 嵌套场景下 @StorageLink 不自动刷新及 getter 不重新计算的问题。
   */
  private async onLoginStateChanged(): Promise<void> {
    const cookie = AppStorage.get<string>('biliCookie') ?? '';
    const loggedIn = cookie.includes('SESSDATA');
    logInfo(`[ProfilePage] refreshHomeFlag=${this.refreshHomeFlag}, Cookie长度=${cookie.length}, 有SESSDATA=${loggedIn}`);
    this.isLoggedIn = loggedIn;

    if (loggedIn) {
      // 调用API获取用户信息
      const userInfo = await getUserInfo();
      if (userInfo && userInfo.isLogin) {
        this.userDisplayName = userInfo.uname;
        this.userAvatarUrl = userInfo.face;
        this.userMid = userInfo.mid;
        // ⭐ 缓存成功获取的资料：冷启动先显示缓存再后台刷新
        this.persistCachedProfile(userInfo.uname, userInfo.face, userInfo.mid);
        logInfo(`[ProfilePage] 获取用户信息成功: ${userInfo.uname}`);
      } else {
        // API失败时使用备用方案：缓存优先（头像/名称立即可用），无缓存才退回 cookie DedeUserID
        let cachedName: string = '';
        let cachedFace: string = '';
        if (this.dataPreferences) {
          try {
            cachedName = await this.dataPreferences.get('userProfileName', '') as string;
            cachedFace = await this.dataPreferences.get('userProfileFace', '') as string;
          } catch (_e) { /* 读取失败不阻断 */ }
        }
        const match = cookie.match(/DedeUserID=(\d+)/);
        this.userDisplayName = cachedName || (match ? `B站用户: ${match[1]}` : '已登录用户');
        this.userAvatarUrl = cachedFace;
        this.userMid = match ? parseInt(match[1], 10) : 0;
      }
    } else {
      this.userDisplayName = '未登录用户';
      this.userAvatarUrl = '';
      this.userMid = 0;
      // ⭐ 登出：清缓存，避免下次冷启动闪现旧资料
      this.clearCachedProfile();
    }
  }

  /** ⭐ 冷启动立即渲染缓存资料（免等 nav 接口），后台再由 onLoginStateChanged 刷新 */
  private async restoreCachedProfile(): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      const cookie = AppStorage.get<string>('biliCookie') ?? '';
      if (!cookie.includes('SESSDATA')) return; // 未登录无缓存可显（登出时已清）
      const name = await this.dataPreferences.get('userProfileName', '') as string;
      const face = await this.dataPreferences.get('userProfileFace', '') as string;
      const mid = await this.dataPreferences.get('userProfileMid', 0) as number;
      if (name || face) {
        this.isLoggedIn = true;
        if (name) this.userDisplayName = name;
        if (face) this.userAvatarUrl = face;
        if (mid) this.userMid = mid;
      }
    } catch (_e) { /* 读取失败不阻断 */ }
  }

  /** ⭐ 写入用户资料缓存（Preferences）：冷启动免等待网络 */
  private async persistCachedProfile(name: string, face: string, mid: number): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('userProfileName', name);
      await this.dataPreferences.put('userProfileFace', face);
      await this.dataPreferences.put('userProfileMid', mid);
      await this.dataPreferences.flush();
    } catch (_e) { /* 写入失败不阻断 */ }
  }

  /** ⭐ 清除用户资料缓存（登出时调用） */
  private async clearCachedProfile(): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.delete('userProfileName');
      await this.dataPreferences.delete('userProfileFace');
      await this.dataPreferences.delete('userProfileMid');
      await this.dataPreferences.flush();
    } catch (_e) { /* 清除失败不阻断 */ }
  }

  @State statusBarHeight: number = 0;
  @State isLandscape: boolean = false;
  @State pressedHighlightId: string = '';
  private dataPreferences: preferences.Preferences | null = null;

  async aboutToAppear(): Promise<void> {
    await this.loadSettings();
    await this.getStatusBarHeight();
    this.listenOrientationChange();
    this.restoreCachedProfile(); // ⭐ 冷启动先显示缓存资料
    this.onLoginStateChanged(); // 初始化登录状态（后台刷新）
  }

  private listenOrientationChange(): void {
    const mainWindow = AppStorage.get<window.Window>('mainWindow');
    if (mainWindow) {
      const props = mainWindow.getWindowProperties();
      this.isLandscape = props.windowRect.width > props.windowRect.height;
      mainWindow.on('windowSizeChange', (size: window.Size) => {
        const isLandscapeNow = size.width > size.height;
        if (this.isLandscape !== isLandscapeNow) {
          this.isLandscape = isLandscapeNow;
        }
      });
    }
  }

  private async loadSettings(): Promise<void> {
    try {
      const uiContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.dataPreferences = await preferences.getPreferences(uiContext, 'my_app_settings');

      let darkMode = await this.dataPreferences.get('isDarkMode', false) as boolean;
      this.isDarkMode = darkMode;
      AppStorage.setOrCreate('isDarkMode', darkMode);

      let storedWallpaper = await this.dataPreferences.get('wallpaper', 'builtin') as string;
      let storedCustomPath = await this.dataPreferences.get('customWallpaper', '') as string;
      let storedCustomColor = await this.dataPreferences.get('customThemeColor', '#007DFF') as string;
      let storedBlur = await this.dataPreferences.get('wallpaperBlur', 0) as number;
      let storedDarkness = await this.dataPreferences.get('wallpaperDarkness', 50) as number;

      this.wallpaper = storedWallpaper;
      this.customWallpaper = storedCustomPath;
      this.customThemeColor = storedCustomColor;
      this.wallpaperBlur = storedBlur;
      this.wallpaperDarkness = storedDarkness;

      AppStorage.setOrCreate('wallpaper', storedWallpaper);
      AppStorage.setOrCreate('customWallpaper', storedCustomPath);
      AppStorage.setOrCreate('customThemeColor', storedCustomColor);
      AppStorage.setOrCreate('wallpaperBlur', storedBlur);
      AppStorage.setOrCreate('wallpaperDarkness', storedDarkness);
      // 加载深/浅两套壁纸存档（缺失回填激活值）并装载当前模式
      await loadWallpaperModes(this.dataPreferences, darkMode);

      // 初始化画质标签
      const qn = AppStorage.get<number>('defaultVideoQn') ?? DEFAULT_QN;
      this.qualityLabel = labelByQn(qn);

      // ⭐ 读取轮播图标题胶囊自定义设置（重启后恢复）
      const storedFontSize = await this.dataPreferences.get('carouselTitleFontSize', 15) as number;
      const storedFontWeight = await this.dataPreferences.get('carouselTitleFontWeight', 'medium') as string;
      // 兼容旧版本语义：旧值 0=自动60% 或固定 vp 值（160-240），统一归一为百分比 20-100（默认 85）
      const storedCapsuleWidthRaw = await this.dataPreferences.get('carouselTitleCapsuleWidth', 85) as number;
      const storedCapsuleWidth = (storedCapsuleWidthRaw >= 20 && storedCapsuleWidthRaw <= 100)
        ? storedCapsuleWidthRaw
        : 85;
      const storedCapsuleHeight = await this.dataPreferences.get('carouselTitleCapsuleHeight', 36) as number;
      const storedLetterSpacing = await this.dataPreferences.get('carouselTitleLetterSpacing', 1) as number;
      this.carouselTitleFontSize = storedFontSize;
      this.carouselTitleFontWeight = storedFontWeight;
      this.carouselTitleCapsuleWidth = storedCapsuleWidth;
      this.carouselTitleCapsuleHeight = storedCapsuleHeight;
      this.carouselTitleLetterSpacing = storedLetterSpacing;
      AppStorage.setOrCreate('carouselTitleFontSize', storedFontSize);
      AppStorage.setOrCreate('carouselTitleFontWeight', storedFontWeight);
      AppStorage.setOrCreate('carouselTitleCapsuleWidth', storedCapsuleWidth);
      AppStorage.setOrCreate('carouselTitleCapsuleHeight', storedCapsuleHeight);
      AppStorage.setOrCreate('carouselTitleLetterSpacing', storedLetterSpacing);

      // ⭐ 读取轮播背景圆角（0-40vp，默认 30，越界值夹紧）
      const storedBgRadiusRaw = await this.dataPreferences.get('carouselBgRadius', 30) as number;
      const storedBgRadius = Math.max(0, Math.min(40, Math.round(storedBgRadiusRaw)));
      this.carouselBgRadius = storedBgRadius;
      AppStorage.setOrCreate('carouselBgRadius', storedBgRadius);

      await StatusBarUtils.updateStatusBarColor(uiContext, darkMode);
    } catch (err) {
      logError(`加载设置失败: ${err}`);
    }
  }

  private async saveSettings(): Promise<void> {
    if (!this.dataPreferences) return;
    try {
      await this.dataPreferences.put('isDarkMode', this.isDarkMode);
      await this.dataPreferences.put('wallpaper', this.wallpaper);
      await this.dataPreferences.put('customWallpaper', this.customWallpaper);
      await this.dataPreferences.put('customThemeColor', this.customThemeColor);
      await this.dataPreferences.put('wallpaperBlur', this.wallpaperBlur);
      await this.dataPreferences.put('wallpaperDarkness', this.wallpaperDarkness);
      // 同步持久化当前系统模式的独立存档
      await persistWallpaperMode(this.isDarkMode, this.dataPreferences);
      await this.dataPreferences.flush();
    } catch (err) {
      logError(`保存设置失败: ${err}`);
    }
  }

  async getStatusBarHeight(): Promise<void> {
    try {
      const uiContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass: window.Window = await window.getLastWindow(uiContext);
      const avoidArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.statusBarHeight = this.getUIContext().px2vp(avoidArea.topRect.height);
    } catch (error) {
      this.statusBarHeight = 40;
    }
  }

  private async onDarkModeChange(isOn: boolean): Promise<void> {
    // 切换前：把当前激活壁纸归档到旧模式存档（若已由设置页持久化则幂等）
    if (this.dataPreferences) {
      await persistWallpaperMode(this.isDarkMode, this.dataPreferences);
    }
    this.isDarkMode = isOn;
    AppStorage.set('isDarkMode', isOn);
    // 卡片样式「深浅色独立」：切模式后装载另一模式档案
    // （对齐 CardStyleSheet.switchDarkMode；savePrefs 每次改动都归档，激活值与档案同步，直接装载即可）
    if (this.dataPreferences && AppStorage.get<boolean>('cardStylePerMode') === true) {
      await applyCardStyleModeArchive(this.dataPreferences, isOn);
    }
    // 切换后：装载新模式对应的壁纸到激活键（消费页自动生效）
    applyWallpaperMode(isOn);
    const uiContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // 同步系统级色彩模式，让 HDS组件（HdsNavigation 返回图标、菜单图标等）自动适配
    uiContext.getApplicationContext().setColorMode(
      isOn ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
    );
    await StatusBarUtils.updateStatusBarColor(uiContext, isOn);
    await this.saveSettings();

    // 震动反馈
    try {
      VibrateUtils.vibrateTime(50);
    } catch (e) {
      logWarn(`震动失败: ${e}`);
    }

    this.getUIContext().getPromptAction().showToast({ message: isOn ? '已切换深色模式' : '已切换浅色模式', duration: 1500 });
  }

  private goToWatchHistory(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/WatchHistoryPage' }).catch((err: Error) => {
      logError('跳转观看历史失败', err);
    });
  }

  private goToLogin(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/QrCodeLoginPage' }).catch((err: Error) => {
      logError('跳转扫码登录页失败', err);
      this.getUIContext().getPromptAction().showToast({ message: '登录功能暂不可用' });
    });
  }

  private async doLogout(): Promise<void> {
    AppStorage.setOrCreate('biliCookie', '');
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('biliCookie', '');
      await pref.flush();
    } catch (err) {
      logError('清除Cookie失败', err);
    }
    const flag = AppStorage.get<number>('refreshHomeFlag') ?? 0;
    AppStorage.set('refreshHomeFlag', flag + 1);
    this.getUIContext().getPromptAction().showToast({ message: '已退出B站登录' });
  }

  private goToHistory(): void {
    this.goToWatchHistory();
  }

  private goToFavorites(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/FavoritesPage' }).catch((err: Error) => {
      logError('跳转收藏页面失败', err);
      this.getUIContext().getPromptAction().showToast({ message: '收藏页面暂不可用' });
    });
  }

  private goToOfflineCache(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/OfflineCachePage' }).catch((err: Error) => {
      logError('跳转离线缓存页面失败', err);
      this.getUIContext().getPromptAction().showToast({ message: '离线缓存页面暂不可用' });
    });
  }

  private showLogoutConfirm(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '确认退出登录',
      message: '退出后将无法使用个性化推荐功能',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '确认退出', color: '#FF4444' }
      ]
    }).then((result) => {
      if (result.index === 1) {
        this.doLogout();
      }
    }).catch((err: Error) => {
      logError('显示对话框失败', err);
    });
  }

  private goToPersonalization(): void {
    this.isPersonalizationSheetShow = true;
  }

  private goToAbout(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/AboutPage' }).catch((err: Error) => {
      logError('跳转关于页面失败', err);
    });
  }

  @Builder
  PersonalizationSheetContent() {
    PersonalizationPage({ onClose: () => { this.isPersonalizationSheetShow = false; } })
  }

  // ── 应用比例调节 ──

  private async saveAppScaleSettings(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put(AppScaleService.KEY_MODE, this.appScaleMode);
      await pref.put(AppScaleService.KEY_UI_SCALE, this.appUiScale);
      await pref.put(AppScaleService.KEY_FONT_SCALE, this.appFontScale);
      await pref.flush();
    } catch (err) {
      logError(`保存应用比例失败: ${err}`);
      this.showToast('保存失败');
    }
  }

  private async applyAppScaleNow(): Promise<void> {
    await this.saveAppScaleSettings();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const windowStage = AppStorage.get<window.WindowStage>('appWindowStage') ?? null;
    const ok = AppScaleService.applyCustom(context, windowStage, this.appUiScale, this.appFontScale);
    this.showToast(ok ? '已应用' : '应用失败，请重启应用');
  }

  /** 开关直接切换生效；关闭=标记未保存，关闭弹窗时提示「重启/取消」 */
  private toggleAppScale(isOn: boolean): void {
    if (isOn) {
      this.appScaleMode = SCALE_MODE_CUSTOM;
      this.appScaleDirty = false;
      this.applyAppScaleNow();
      this.showToast('已开启自定义比例');
    } else {
      // 不立即保存：关闭需要重启才完全跟随系统，立即弹出重启提示；
      // 选「稍后」保持未保存状态，关弹窗时再提示（可还原/重启）
      this.appScaleMode = SCALE_MODE_SYSTEM;
      this.appScaleDirty = true;
      this.promptAppScaleOff();
    }
  }

  /** 关闭自定义比例：立即询问是否重启（稍后=关弹窗时再提示） */
  private promptAppScaleOff(): void {
    AlertDialog.show({
      title: '关闭自定义比例',
      message: '关闭后需重启应用才完全跟随系统字体大小与界面缩放。是否立即重启？',
      autoCancel: false,
      primaryButton: {
        value: '稍后',
        fontColor: this.isDarkMode ? '#FFFFFF' : '#000000',
        action: () => {}
      },
      secondaryButton: {
        value: '立即重启',
        fontColor: '#E84040',
        action: () => { this.persistAndRestartApp(SCALE_MODE_SYSTEM); }
      }
    });
  }

  /** 应用比例调节（保存并重启）：先确认再重启 */
  private showAppScaleApplyPrompt(): void {
    AlertDialog.show({
      title: '应用比例调节',
      message: `将保存当前比例（界面缩放 ${this.scaleStepName(this.appUiScale, UI_SCALE_STEPS)}、文字大小 ${Math.round(this.appFontScale * 100)}%）并重启应用生效。是否立即重启？`,
      autoCancel: false,
      primaryButton: {
        value: '取消',
        fontColor: this.isDarkMode ? '#FFFFFF' : '#000000',
        action: () => {}
      },
      secondaryButton: {
        value: '重启',
        fontColor: '#E84040',
        action: () => { this.persistAndRestartApp(SCALE_MODE_CUSTOM); }
      }
    });
  }

  /** 打开弹窗：读取已保存值（退出时可还原） */
  private async openAppScaleSheet(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      // 恢复上一次模式与滑杆值（否则开关每次打开都是「未开启」）
      const savedMode = await pref.get(AppScaleService.KEY_MODE, SCALE_MODE_SYSTEM) as string;
      this.appScaleMode = savedMode === SCALE_MODE_CUSTOM ? SCALE_MODE_CUSTOM : SCALE_MODE_SYSTEM;
      this.appUiScale = await pref.get(AppScaleService.KEY_UI_SCALE, 1) as number;
      this.appFontScale = await pref.get(AppScaleService.KEY_FONT_SCALE, 1) as number;
      this.appUiScaleSaved = this.appUiScale;
      this.appFontScaleSaved = this.appFontScale;
      this.appScaleModeSaved = this.appScaleMode;
    } catch (e) {
      logError(`读取应用比例失败: ${e}`);
    }
    this.isAppScaleSheetShow = true;
  }

  /** 重启应用（供开关类设置「重启/取消」提示使用） */
  private restartApplication(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const appCtx = context.getApplicationContext() as common.ApplicationContext;
      appCtx.restartApp({ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name });
    } catch (err) {
      logError(`重启应用失败: ${err}`);
      this.showToast('重启失败，请手动重启应用');
    }
  }

  /** 直板机布局切换提示：重启=保存并重启生效；取消=开关不变 */
  private showPhoneLayoutRestartPrompt(next: boolean): void {
    AlertDialog.show({
      title: next ? '开启直板机布局' : '关闭直板机布局',
      message: next
        ? '开启直板机布局后需重启应用生效。是否立即重启？'
        : '关闭直板机布局后需重启应用生效。是否立即重启？',
      autoCancel: false,
      primaryButton: {
        value: '取消',
        fontColor: this.isDarkMode ? '#FFFFFF' : '#000000',
        action: () => {}
      },
      secondaryButton: {
        value: '重启',
        fontColor: '#E84040',
        action: () => {
          const now = Date.now();
          AppStorage.set('phoneLayoutToggle_ts', now);
          AppStorage.set('phoneLayoutToggle', next);
          this.restartApplication();
        }
      }
    });
  }

  private async persistAndRestartApp(mode: string): Promise<void> {
    this.appScaleMode = mode;
    await this.saveAppScaleSettings();
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const appCtx = context.getApplicationContext() as common.ApplicationContext;
      appCtx.restartApp({ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name });
    } catch (err) {
      logError(`重启应用失败: ${err}`);
      this.showToast('重启失败，请手动重启应用');
    }
  }

  /** 滑杆值吸附到最近档位 */
  private snapToNearest(value: number, steps: ScaleStep[]): number {
    let best: number = steps[0].v;
    for (const s of steps) {
      if (Math.abs(s.v - value) < Math.abs(best - value)) {
        best = s.v;
      }
    }
    return best;
  }

  /** 当前档位名（找不到显示百分比） */
  private scaleStepName(value: number, steps: ScaleStep[]): string {
    for (const s of steps) {
      if (Math.abs(s.v - value) < 0.011) return s.name;
    }
    return Math.round(value * 100) + '%';
  }

  /** 档位点：可点击跳档，当前档位高亮（对应系统档位） */
  @Builder
  ScaleStepsPanel(steps: ScaleStep[], current: number, onPick: (v: number) => void) {
    Row() {
      ForEach(steps, (st: ScaleStep) => {
        Column() {
          Column()
            .width(9)
            .height(9)
            .borderRadius(4.5)
            .backgroundColor(Math.abs(current - st.v) < 0.011 ? this.customThemeColor
              : (this.isDarkMode ? '#4A4A4A' : '#D5D5D5'))
          Text(st.name)
            .fontSize(9)
            .fontColor(Math.abs(current - st.v) < 0.011 ? this.customThemeColor
              : (this.isDarkMode ? '#8E8E93' : '#A0A0A0'))
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => { onPick(st.v); })
      }, (st: ScaleStep) => String(st.v))
    }
    .width('100%')
    .margin({ top: 8 })
  }

  @Builder
  AppScaleSheetContent() {
    Column() {
      Row() {
        Text('应用比例调节')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        Blank()
      }
      .width('100%')
      .margin({ top: 4, bottom: 18 })

      // 开关行
      Row() {
        Column() {
          Text('自定义比例')
            .fontSize(15)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            .fontWeight(FontWeight.Medium)
          Text('关闭=跟随系统字体大小与界面缩放')
            .fontSize(11)
            .fontColor(this.isDarkMode ? '#AAAAAA' : '#888888')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.appScaleMode === SCALE_MODE_CUSTOM })
          .selectedColor(this.customThemeColor)
          .switchPointColor(Color.White)
          .scale({ x: 0.85, y: 0.85 })
          .onChange((value: boolean) => { this.toggleAppScale(value); })
      }
      .width('100%')
      .height(62)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
      .borderRadius(20)
      .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
      .margin({ bottom: 10 })

      if (this.appScaleMode === SCALE_MODE_CUSTOM) {
        Column() {
          Row() {
            Text('界面缩放')
              .fontSize(14)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            Blank()
            Text(this.scaleStepName(this.appUiScale, UI_SCALE_STEPS))
              .fontSize(13)
              .fontColor(this.customThemeColor)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ bottom: 6 })
          Slider({ value: this.appUiScale, min: UI_SCALE_STEPS[0].v, max: UI_SCALE_STEPS[UI_SCALE_STEPS.length - 1].v, step: 0.01, style: SliderStyle.InSet })
            .width('100%')
            .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
            .selectedColor(this.customThemeColor)
            .blockColor(this.customThemeColor)
            // 拖动中跟手显示；松手/点击时吸附到最近档位
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.appUiScale = this.snapToNearest(value, UI_SCALE_STEPS);
                this.appScaleDirty = true;
              } else {
                this.appUiScale = value;
                this.appScaleDirty = true;
              }
            })
          this.ScaleStepsPanel(UI_SCALE_STEPS, this.appUiScale, (v: number) => {
            this.appUiScale = v;
            this.appScaleDirty = true;
          })
        }
        .width('100%')
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(16)
        .padding({ left: 16, right: 16, top: 10, bottom: 12 })
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
        .margin({ bottom: 10 })

        Column() {
          Row() {
            Text('文字大小')
              .fontSize(14)
              .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            Blank()
            Text(`${Math.round(this.appFontScale * 100)}%`)
              .fontSize(13)
              .fontColor(this.customThemeColor)
              .fontWeight(FontWeight.Medium)
          }
          .width('100%')
          .margin({ bottom: 6 })
          Slider({ value: this.appFontScale, min: FONT_SCALE_STEPS[0].v, max: FONT_SCALE_STEPS[FONT_SCALE_STEPS.length - 1].v, step: 0.01, style: SliderStyle.InSet })
            .width('100%')
            .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
            .selectedColor(this.customThemeColor)
            .blockColor(this.customThemeColor)
            // 连续百分比调节：任意值均可
            .onChange((value: number) => {
              this.appFontScale = value;
              this.appScaleDirty = true;
            })
          this.ScaleStepsPanel(FONT_SCALE_STEPS, this.appFontScale, (v: number) => {
            this.appFontScale = v;
            this.appScaleDirty = true;
          })
        }
        .width('100%')
        .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
        .borderRadius(16)
        .padding({ left: 16, right: 16, top: 10, bottom: 12 })
        .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
        .margin({ bottom: 10 })

        Text('开启后不再跟随系统设置；恢复跟随需重启应用。')
          .fontSize(11)
          .fontColor(this.isDarkMode ? '#8E8E93' : '#999999')
          .margin({ bottom: 10 })

        Button() {
          Row() {
            Image($r('app.media.chongqi'))
              .width(16).height(16)
              .fillColor(Color.White)
              .margin({ right: 6 })
            Text('保存并重启')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
          }
        }
        .width('100%')
        .height(40)
        .backgroundColor(this.customThemeColor)
        .borderRadius(10)
        .onClick(() => { this.showAppScaleApplyPrompt(); })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 28 })
  }

  @Builder
  CardStyleSheetContent() {
    CardStyleSheet({ onClose: () => { this.isCardStyleSheetShow = false; } })
  }

  private showToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message, duration: 1500 });
  }

  private onVideoQnChange(): void {
    this.qualityLabel = labelByQn(this.defaultVideoQn);
  }

  private async saveDefaultQn(qn: number): Promise<void> {
    // 立即更新 UI（同步，在 await 之前）
    AppStorage.set('defaultVideoQn', qn);
    this.qualityLabel = labelByQn(qn);
    this.getUIContext().getPromptAction().showToast({ message: `已切换到${labelByQn(qn)}` });
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('defaultVideoQn', qn);
      await pref.flush();
    } catch (err) {
      logError(`保存默认画质失败: ${err}`);
    }
  }

  private async saveRecommendApiSource(source: string): Promise<void> {
    // 立即更新 UI（同步，在 await 之前）
    AppStorage.set('recommendApiSource', source);
    this.getUIContext().getPromptAction().showToast({ message: `已切换到${source} API` });
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('recommendApiSource', source);
      await pref.flush();
    } catch (err) {
      logError(`保存推荐API源失败: ${err}`);
    }
  }

  private showQualityPicker(): void {
    const primaryColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const cancelColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const backgroundColor = this.isDarkMode ? 'rgba(44, 44, 44, 0.95)' : 'rgba(255, 255, 255, 0.95)';

    const buttons: Array<ActionButton> = [];

    for (const item of QUALITY_LIST) {
      buttons.push({
        value: item.label,
        fontColor: primaryColor,
        action: () => {
          this.saveDefaultQn(item.qn);
        }
      });
    }

    buttons.push({
      value: '取消',
      fontColor: cancelColor,
      action: () => {}
    });

    AlertDialog.show({
      title: '选择默认画质',
      message: '进入视频全屏后可以单独切换画质',
      backgroundColor: backgroundColor,
      buttons: buttons
    });
  }

  private showRecommendApiPicker(): void {
    const primaryColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const cancelColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const backgroundColor = this.isDarkMode ? 'rgba(44, 44, 44, 0.95)' : 'rgba(255, 255, 255, 0.95)';

    AlertDialog.show({
      title: '选择推荐API源',
      message: 'Web API: 更稳定，推荐质量较高\nApp API: 更新更快，内容更丰富',
      backgroundColor: backgroundColor,
      buttons: [
        {
          value: 'Web API',
          fontColor: primaryColor,
          action: () => {
            this.saveRecommendApiSource('Web');
          }
        },
        {
          value: 'App API',
          fontColor: primaryColor,
          action: () => {
            this.saveRecommendApiSource('App');
          }
        },
        {
          value: '取消',
          fontColor: cancelColor,
          action: () => {}
        }
      ]
    });
  }

  private showDanmakuApiPicker(): void {
    const primaryColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const cancelColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const backgroundColor = this.isDarkMode ? 'rgba(44, 44, 44, 0.95)' : 'rgba(255, 255, 255, 0.95)';

    AlertDialog.show({
      title: '选择弹幕数据源',
      message: 'XML (轻量): 弹幕量较少，加载快，适合看视频不关注弹幕\ngRPC Protobuf (全量): 弹幕数据与官方一致，更完整，适合弹幕爱好者',
      backgroundColor: backgroundColor,
      buttons: [
        {
          value: 'XML (轻量)',
          fontColor: primaryColor,
          action: () => {
            this.saveDanmakuApiSource('xml');
          }
        },
        {
          value: 'gRPC Protobuf (全量)',
          fontColor: primaryColor,
          action: () => {
            this.saveDanmakuApiSource('grpc');
          }
        },
        {
          value: '取消',
          fontColor: cancelColor,
          action: () => {}
        }
      ]
    });
  }

  private async saveDanmakuApiSource(source: string): Promise<void> {
    // 立即更新 UI
    AppStorage.set('danmakuApiSource', source);
    this.getUIContext().getPromptAction().showToast({ message: `弹幕数据源已切换到${source === 'xml' ? 'XML' : 'gRPC Protobuf'}` });
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('danmakuApiSource', source);
      await pref.flush();
    } catch (err) {
      logError(`保存弹幕数据源失败: ${err}`);
    }
  }

  /** 保存轮播图标题设置项到 AppStorage + Preferences */
  private async saveCarouselTitleSetting(key: string, value: number | string): Promise<void> {
    AppStorage.set(key, value);
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put(key, value);
      await pref.flush();
    } catch (err) {
      logError(`保存轮播图标题设置失败: ${err}`);
    }
  }

  /** 保存轮播背景圆角（0-40vp）到 AppStorage + Preferences；仅在拖动结束/点击时调用，避免逐帧写盘 */
  private async saveCarouselBgRadius(value: number): Promise<void> {
    const v: number = Math.max(0, Math.min(40, Math.round(value)));
    AppStorage.set('carouselBgRadius', v);
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('carouselBgRadius', v);
      await pref.flush();
    } catch (err) {
      logError(`保存轮播背景圆角失败: ${err}`);
    }
  }

  private fontWeightLabel(weight: string): string {
    switch (weight) {
      case 'bold': return '加粗';
      case 'medium': return '中等';
      default: return '常规';
    }
  }

  /** 轮播图标题字体粗细：根据设置字符串映射为 FontWeight（预览用） */
  private resolveCarouselTitleFontWeight(): FontWeight {
    switch (this.carouselTitleFontWeight) {
      case 'bold': return FontWeight.Bold;
      case 'medium': return FontWeight.Medium;
      default: return FontWeight.Normal;
    }
  }

  /** 轮播图标题字体粗细 → 滑块索引（normal=0, medium=1, bold=2） */
  private carouselTitleWeightToIndex(weight: string): number {
    switch (weight) {
      case 'bold': return 2;
      case 'medium': return 1;
      default: return 0;
    }
  }

  /** 轮播图标题滑块索引 → 字体粗细字符串 */
  private carouselTitleWeightFromIndex(index: number): string {
    switch (index) {
      case 2: return 'bold';
      case 1: return 'medium';
      default: return 'normal';
    }
  }

  /** 文字大小选择器 */
  private showCarouselTitleFontSizePicker(): void {
    const primaryColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const cancelColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const backgroundColor = this.isDarkMode ? 'rgba(44, 44, 44, 0.95)' : 'rgba(255, 255, 255, 0.95)';
    const sizes: number[] = [12, 14, 16, 18, 20];
    const buttons: Array<ActionButton> = [];
    for (const size of sizes) {
      buttons.push({
        value: `${size}`,
        fontColor: primaryColor,
        action: () => {
          this.saveCarouselTitleSetting('carouselTitleFontSize', size);
        }
      });
    }
    buttons.push({ value: '取消', fontColor: cancelColor, action: () => {} });
    AlertDialog.show({
      title: '标题文字大小',
      message: `当前：${this.carouselTitleFontSize}`,
      backgroundColor: backgroundColor,
      buttons: buttons
    });
  }

  /** 文字粗细选择器 */
  private showCarouselTitleFontWeightPicker(): void {
    const primaryColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const cancelColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const backgroundColor = this.isDarkMode ? 'rgba(44, 44, 44, 0.95)' : 'rgba(255, 255, 255, 0.95)';
    const weights: string[] = ['normal', 'medium', 'bold'];
    const buttons: Array<ActionButton> = [];
    for (const weight of weights) {
      buttons.push({
        value: this.fontWeightLabel(weight),
        fontColor: primaryColor,
        action: () => {
          this.saveCarouselTitleSetting('carouselTitleFontWeight', weight);
        }
      });
    }
    buttons.push({ value: '取消', fontColor: cancelColor, action: () => {} });
    AlertDialog.show({
      title: '标题文字粗细',
      message: `当前：${this.fontWeightLabel(this.carouselTitleFontWeight)}`,
      backgroundColor: backgroundColor,
      buttons: buttons
    });
  }

  /** 胶囊宽度选择器（0 = 自动 60%） */
  private showCarouselTitleCapsuleWidthPicker(): void {
    const primaryColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const cancelColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const backgroundColor = this.isDarkMode ? 'rgba(44, 44, 44, 0.95)' : 'rgba(255, 255, 255, 0.95)';
    const widths: number[] = [0, 160, 180, 200, 220, 240];
    const buttons: Array<ActionButton> = [];
    for (const width of widths) {
      buttons.push({
        value: width === 0 ? '自动（60%）' : `${width}`,
        fontColor: primaryColor,
        action: () => {
          this.saveCarouselTitleSetting('carouselTitleCapsuleWidth', width);
        }
      });
    }
    buttons.push({ value: '取消', fontColor: cancelColor, action: () => {} });
    AlertDialog.show({
      title: '胶囊宽度',
      message: `当前：${this.carouselTitleCapsuleWidth === 0 ? '自动（60%）' : `${this.carouselTitleCapsuleWidth}`}`,
      backgroundColor: backgroundColor,
      buttons: buttons
    });
  }

  /** 胶囊高度选择器 */
  private showCarouselTitleCapsuleHeightPicker(): void {
    const primaryColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const cancelColor = this.isDarkMode ? '#FFFFFF' : '#000000';
    const backgroundColor = this.isDarkMode ? 'rgba(44, 44, 44, 0.95)' : 'rgba(255, 255, 255, 0.95)';
    const heights: number[] = [32, 36, 40, 44, 48];
    const buttons: Array<ActionButton> = [];
    for (const height of heights) {
      buttons.push({
        value: `${height}`,
        fontColor: primaryColor,
        action: () => {
          this.saveCarouselTitleSetting('carouselTitleCapsuleHeight', height);
        }
      });
    }
    buttons.push({ value: '取消', fontColor: cancelColor, action: () => {} });
    AlertDialog.show({
      title: '胶囊高度',
      message: `当前：${this.carouselTitleCapsuleHeight}`,
      backgroundColor: backgroundColor,
      buttons: buttons
    });
  }

  private getCardItemBg(): string {
    if (this.cardTransparentStyle) {
      return this.isDarkMode
        ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
        : `rgba(255,255,255,${this.cardBgOpacity / 100})`;
    }
    return this.isDarkMode ? '#2C2C2C' : '#E8E8E8';
  }

  @Builder
  SettingItemWithValue(icon: ResourceStr, title: string, value: string, onClick: () => void) {
    Row() {
      Image(icon)
        .width(24).height(24)
        .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
        .margin({ right: 14 })
      Text(title)
        .fontSize(16)
        .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
        .fontWeight(FontWeight.Medium)
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor($r('app.color.color_secondary_text'))
        .margin({ right: 8 })
      Circle()
        .width(8)
        .height(8)
        .fill(this.isDarkMode ? '#E5E5E5' : '#333333')
        .margin({ right: 19 })
    }
    .width('100%')
    .height(56)
    .backgroundColor(this.getCardItemBg())
    .borderRadius(20)
    .padding({ left: 16, right: 16 })
    .margin({ bottom: 16 })
    .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
    .clickEffect({ level: 2, scale: 0.93 })
    .onClick(() => { onClick(); })
  }

  /** 轮播图标题选项行：左侧标题 + 右侧当前值，点击弹出选择器 */
  @Builder
  CarouselTitleOptionRow(title: string, value: string, onClick: () => void) {
    Row() {
      Text(title)
        .fontSize(15)
        .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .flexShrink(1)
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor(this.isDarkMode ? '#BBBBBB' : '#666666')
        .margin({ right: 10 })
      Image($r('app.media.chevron_right'))
        .width(16).height(16)
        .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
    }
    .width('100%')
    .height(48)
    .padding({ left: 18, right: 18 })
    .borderRadius(17)
    .backgroundColor(this.pressedHighlightId === title
      ? (this.isDarkMode ? 'rgba(255,255,255,0.18)' : 'rgba(124,124,124,0.4)')
      : 'transparent')
    .animation({ duration: 250, curve: Curve.Friction })
    .clickEffect({ level: 2, scale: 0.93 })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressedHighlightId = title;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.pressedHighlightId = '';
      }
    })
    .onClick(() => { onClick(); })
  }

  @Builder
  SettingItemWithToggle(icon: ResourceStr, title: string, isOn: boolean, onChange: (isOn: boolean) => void, marginBottom: number = 16, desc: string = '') {
    Stack() {
      // 按压高亮层（通过 Stack padding 缩进，比卡片小一圈）
      Row() {
        Row()
          .width('100%')
          .height('100%')
          .borderRadius(17)
          .backgroundColor(this.pressedHighlightId === title ? 'rgba(124,124,124,0.4)' : 'transparent')
          .animation({ duration: 250, curve: Curve.Friction })
          .clickEffect({ level: 2, scale: 0.93 })
      }
      .width('100%')
      .height('100%')

      // 内容层
      Row() {
        Image(icon)
          .width(24).height(24)
          .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
          .margin({ right: 14 })
        Column() {
          Text(title)
            .fontSize(16)
            .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          // ⭐ 可选副标题：常驻说明文字（例如开关"关闭后的效果"）；不传 desc 时完全不占位
          if (desc.length > 0) {
            Text(desc)
              .fontSize(12)
              .fontColor(this.isDarkMode ? '#999999' : '#888888')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: isOn })
          .selectedColor(this.customThemeColor)
          .switchPointColor(Color.White)
          .onChange((value: boolean) => { onChange(value); })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 18, right: 18 })

      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12 })
      .clickEffect({ level: 2, scale: 0.93 })
    }
    .width('100%')
    // ⭐ 有副标题时略增高，保证两行文字不挤；没副标题仍是原来的 56vp
    .height(desc.length > 0 ? 66 : 56)
    .backgroundColor(this.getCardItemBg())
    .borderRadius(20)
    .padding({ left: 6, right: 6, top: 6, bottom: 6 })
    .margin({ bottom: marginBottom })
    .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressedHighlightId = title;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.pressedHighlightId = '';
      }
    })
  }

  @Builder
  SettingItem(icon: ResourceStr, title: string, onClick: () => void) {
    Stack() {
      // 按压高亮层（通过 Stack padding 缩进，比卡片小一圈）
      Row() {
        Row()
          .width('100%')
          .height('100%')
          .borderRadius(17)
          .backgroundColor(this.pressedHighlightId === title ? 'rgba(124,124,124,0.4)' : 'transparent')
          .animation({ duration: 250, curve: Curve.Friction })
          .clickEffect({ level: 2, scale: 0.93 })
      }
      .width('100%')
      .height('100%')

      // 内容层
      Row() {
        Image(icon)
          .width(24).height(24)
          .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
          .margin({ right: 14 })
        Text(title)
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
          .fontWeight(FontWeight.Medium)
        Blank()
        Circle()
          .width(8)
          .height(8)
          .fill(this.isDarkMode ? '#E5E5E5' : '#333333')
          .margin({ right: 19 })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12 })
      .clickEffect({ level: 2, scale: 0.93 })
    }
    .width('100%')
    .height(56)
    .backgroundColor(this.getCardItemBg())
    .borderRadius(20)
    .padding({ left: 6, right: 6, top: 6, bottom: 6 })
    .margin({ bottom: 16 })
    .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressedHighlightId = title;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.pressedHighlightId = '';
      }
    })
    .onClick(() => { onClick(); })
  }

  @Builder
  SettingItemWithPicker(icon: ResourceStr, title: string, onClick: () => void, marginBottom: number = 16) {
    Stack() {
      // 按压高亮层（通过 Stack padding 缩进，比卡片小一圈）
      Row() {
        Row()
          .width('100%')
          .height('100%')
          .borderRadius(17)
          .backgroundColor(this.pressedHighlightId === title ? 'rgba(124,124,124,0.4)' : 'transparent')
          .animation({ duration: 250, curve: Curve.Friction })
          .clickEffect({ level: 2, scale: 0.93 })
      }
      .width('100%')
      .height('100%')

      // 内容层
      Row() {
        Image(icon)
          .width(24).height(24)
          .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
          .margin({ right: 14 })
        Text(title)
          .fontSize(16)
          .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
          .fontWeight(FontWeight.Medium)
        Blank()
        Circle()
          .width(8)
          .height(8)
          .fill(this.isDarkMode ? '#E5E5E5' : '#333333')
          .margin({ right: 19 })
      }
      .width('100%')
      .height('100%')
      .padding({ left: 12, right: 12 })
      .clickEffect({ level: 2, scale: 0.93 })
    }
    .width('100%')
    .height(56)
    .backgroundColor(this.getCardItemBg())
    .borderRadius(20)
    .padding({ left: 6, right: 6, top: 6, bottom: 6 })
    .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
    .margin({ bottom: marginBottom })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressedHighlightId = title;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.pressedHighlightId = '';
      }
    })
    .onClick(() => { onClick(); })
  }

  @Builder
  SectionHeader(title: string) {
    Text(title)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
      .width('100%')
      .margin({ left: 24, bottom: 16 })
  }

  build() {
    Stack() {
      Scroll() {
        Column() {
          // ── 头像卡片 + 深色模式（左右并排）──
          Row({ space: 12 }) {
            // 头像卡片（占 2/3）— 跟随卡片样式透明选项
            Stack() {
              Row() {
                Row()
                  .width('100%')
                  .height('100%')
                  .borderRadius(21)
                  .backgroundColor(this.pressedHighlightId === 'avatar_card' ? 'rgba(124,124,124,0.4)' : 'transparent')
                  .animation({ duration: 250, curve: Curve.Friction })
                  .clickEffect({ level: 2, scale: 0.93 })
              }
                .width('100%')
                .height('100%')

              Row() {
                if (this.isLoggedIn && this.userAvatarUrl) {
                  Image(this.userAvatarUrl)
                    .width(56)
                    .height(56)
                    .borderRadius(28)
                    .objectFit(ImageFit.Cover)
                } else {
                  Circle({ width: 56, height: 56 })
                    .fill(this.isLoggedIn ? this.customThemeColor : (this.isDarkMode ? '#333333' : '#E0E0E0'))
                }
                Column() {
                  Text(this.userDisplayName)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.color_primary_text'))
                  if (this.isLoggedIn) {
                    Text('进入个人空间')
                      .fontSize(12)
                      .fontColor(this.customThemeColor)
                      .margin({ top: 4 })
                      .fontWeight(FontWeight.Medium)
                  } else {
                    Text('点击登录')
                      .fontSize(12)
                      .fontColor(this.customThemeColor)
                      .margin({ top: 4 })
                      .fontWeight(FontWeight.Medium)
                  }
                }
                .margin({ left: 12 })
                .alignItems(HorizontalAlign.Start)
                .constraintSize({ maxWidth: 180 })
              }
              .alignItems(VerticalAlign.Center)
              .justifyContent(FlexAlign.Center)
              .padding({ left: 12, right: 12 })
              .height('100%')
              .clickEffect({ level: 2, scale: 0.93 })
            }
            .layoutWeight(2)
            .height('100%')
            .backgroundColor(this.getCardItemBg())
            .borderRadius(24)
            .padding({ left: 6, right: 6, top: 6, bottom: 6 })
            .shadow({ radius: 16, color: '#1A000000', offsetY: 4 })
            .onTouch((e: TouchEvent) => {
              if (e.type === TouchType.Down) {
                this.pressedHighlightId = 'avatar_card';
              } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                this.pressedHighlightId = '';
              }
            })
            .onClick(() => {
              if (this.isLoggedIn) {
                this.getUIContext().getRouter().pushUrl({
                  url: 'pages/UpSpacePage',
                  params: {
                    mid: this.userMid,
                    upName: this.userDisplayName,
                    upFace: this.userAvatarUrl
                  }
                }).catch((err: Error) => {
                  logWarn(`[ProfilePage] 进入个人空间失败: ${err}`);
                });
              } else {
                this.goToLogin();
              }
            })

            // 深色模式（占 1/3）
            Stack() {
              Row() {
                Row()
                  .width('100%')
                  .height('100%')
                  .borderRadius(21)
                  .backgroundColor(this.pressedHighlightId === 'dark_mode_card' ? 'rgba(124,124,124,0.4)' : 'transparent')
                  .animation({ duration: 250, curve: Curve.Friction })
                  .clickEffect({ level: 2, scale: 0.85 })
              }
                .width('100%')
                .height('100%')

              Column() {
                Image(this.isDarkMode ? $r('app.media.ic_settings_darkmode') : $r('app.media.sun_min'))
                  .width(32).height(32)
                  .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                  .margin({ bottom: 8 })
                Text(this.isDarkMode ? '深色' : '浅色')
                  .fontSize(14)
                  .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                  .fontWeight(FontWeight.Medium)
                Text('')
                  .fontSize(16)
                  .opacity(0)
              }
              .width('100%')
              .height('100%')
              .padding({ left: 12, right: 12 })
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .clickEffect({ level: 2, scale: 0.85 })
            }
            .layoutWeight(1)
            .height('100%')
            .backgroundColor(this.getCardItemBg())
            .borderRadius(24)
            .padding({ left: 6, right: 6, top: 6, bottom: 6 })
            .shadow({ radius: 16, color: '#1A000000', offsetY: 4 })
            .onTouch((e: TouchEvent) => {
              if (e.type === TouchType.Down) {
                this.pressedHighlightId = 'dark_mode_card';
              } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                this.pressedHighlightId = '';
              }
            })
            .onClick(() => { this.onDarkModeChange(!this.isDarkMode); })
          }
          .width('100%')
          .height(160)
          .margin({ top: 20, bottom: 16 })

          // ── 快捷操作：历史记录 / 我的收藏 / 离线缓存 ──
          Row({ space: 12 }) {

            // 历史记录
            Stack() {
              Row() {
                Row()
                  .width('100%')
                  .height('100%')
                  .borderRadius(17)
                  .backgroundColor(this.pressedHighlightId === 'history_card' ? 'rgba(124,124,124,0.4)' : 'transparent')
                  .animation({ duration: 250, curve: Curve.Friction })
                  .clickEffect({ level: 2, scale: 0.85 })
              }
                .width('100%')
                .height('100%')

              Column() {
                Image($r('app.media.ic_settings_history'))
                  .width(32).height(32)
                  .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                  .margin({ bottom: 8 })
                Text('历史记录')
                  .fontSize(14)
                  .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                  .fontWeight(FontWeight.Medium)
                Text('')
                  .fontSize(16)
                  .opacity(0)
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .clickEffect({ level: 2, scale: 0.85 })
            }
            .layoutWeight(1)
            .height(140)
            .backgroundColor(this.getCardItemBg())
            .borderRadius(20)
            .padding({ left: 6, right: 6, top: 6, bottom: 6 })
            .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
            .onTouch((e: TouchEvent) => {
              if (e.type === TouchType.Down) {
                this.pressedHighlightId = 'history_card';
              } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                this.pressedHighlightId = '';
              }
            })
            .onClick(() => { this.goToWatchHistory(); })

            // 我的收藏
            Stack() {
              Row() {
                Row()
                  .width('100%')
                  .height('100%')
                  .borderRadius(17)
                  .backgroundColor(this.pressedHighlightId === 'favorites_card' ? 'rgba(124,124,124,0.4)' : 'transparent')
                  .animation({ duration: 250, curve: Curve.Friction })
                  .clickEffect({ level: 2, scale: 0.85 })
              }
                .width('100%')
                .height('100%')

              Column() {
                Image($r('app.media.ic_public_folder'))
                  .width(32).height(32)
                  .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                  .margin({ bottom: 8 })
                Text('我的收藏')
                  .fontSize(14)
                  .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                  .fontWeight(FontWeight.Medium)
                Text('')
                  .fontSize(16)
                  .opacity(0)
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .clickEffect({ level: 2, scale: 0.85 })
            }
            .layoutWeight(1)
            .height(140)
            .backgroundColor(this.getCardItemBg())
            .borderRadius(20)
            .padding({ left: 6, right: 6, top: 6, bottom: 6 })
            .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
            .onTouch((e: TouchEvent) => {
              if (e.type === TouchType.Down) {
                this.pressedHighlightId = 'favorites_card';
              } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                this.pressedHighlightId = '';
              }
            })
            .onClick(() => { this.goToFavorites(); })

            // 离线缓存（空白占位）
            Stack() {
              Row() {
                Row()
                  .width('100%')
                  .height('100%')
                  .borderRadius(17)
                  .backgroundColor(this.pressedHighlightId === 'offline_card' ? 'rgba(124,124,124,0.4)' : 'transparent')
                  .animation({ duration: 250, curve: Curve.Friction })
                  .clickEffect({ level: 2, scale: 0.85 })
              }
                .width('100%')
                .height('100%')

              Column() {
                Image($r('app.media.save'))
                  .width(32).height(32)
                  .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                  .margin({ bottom: 8 })
                Text('离线缓存')
                  .fontSize(14)
                  .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                  .fontWeight(FontWeight.Medium)
                Text('')
                  .fontSize(16)
                  .opacity(0)
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .clickEffect({ level: 2, scale: 0.85 })
            }
            .layoutWeight(1)
            .height(140)
            .backgroundColor(this.getCardItemBg())
            .borderRadius(20)
            .padding({ left: 6, right: 6, top: 6, bottom: 6 })
            .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
            .onTouch((e: TouchEvent) => {
              if (e.type === TouchType.Down) {
                this.pressedHighlightId = 'offline_card';
              } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                this.pressedHighlightId = '';
              }
            })
            .onClick(() => { this.goToOfflineCache(); })
          }
          .width('100%')
          .margin({ bottom: 16 })

          // ⭐ 节标题：个性化设置
          Text('个性化设置')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
            .width('100%')
            .margin({ left: 24, bottom: 16 })

          if (!this.isLandscape) {
            // ── 竖屏：单列（卡片 + 搜索发现 + 关于我们）──
            Column() {
              // 动画·背景·色彩（原个性化）
              Stack() {
                Row() {
                  Row()
                    .width('100%')
                    .height('100%')
                    .borderRadius(17)
                    .backgroundColor(this.pressedHighlightId === '动画·背景·色彩' ? 'rgba(124,124,124,0.4)' : 'transparent')
                    .animation({ duration: 250, curve: Curve.Friction })
                    .clickEffect({ level: 2, scale: 0.93 })
                }
                  .width('100%')
                  .height('100%')

                Row() {
                  Image($r('app.media.ic_settings_personalize'))
                    .width(24).height(24)
                    .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                    .margin({ right: 14 })
                  Column() {
                    Text('个性化')
                      .fontSize(16)
                      .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                      .fontWeight(FontWeight.Medium)
                      .margin({ bottom: 6 })
                    Text('动画·背景·色彩')
                      .fontSize(11)
                      .fontColor(this.isDarkMode ? '#BBBBBB' : '#666666')
                      .fontWeight(FontWeight.Normal)
                  }
                  .alignItems(HorizontalAlign.Start)
                  Blank()
                  Circle()
                    .width(8)
                    .height(8)
                    .fill(this.isDarkMode ? '#E5E5E5' : '#333333')
                    .margin({ right: 19 })
                }
                .width('100%')
                .height('100%')
                .padding({ left: 12, right: 12 })
                .clickEffect({ level: 2, scale: 0.93 })
              }
              .width('100%')
              .height(64)
              .padding({ left: 6, right: 6, top: 10, bottom: 10 })
              .onTouch((e: TouchEvent) => {
                if (e.type === TouchType.Down) {
                  this.pressedHighlightId = '动画·背景·色彩';
                } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                  this.pressedHighlightId = '';
                }
              })
              .onClick(() => { this.goToPersonalization(); })

              Divider()
                .height(1)
                .width('100%')
                .color(this.isDarkMode ? '#3C3C3E' : '#E0E0E0')
                .margin({ top: 2, bottom: 2 })

              // 卡片样式
              Stack() {
                Row() {
                  Row()
                    .width('100%')
                    .height('100%')
                    .borderRadius(17)
                    .backgroundColor(this.pressedHighlightId === '卡片样式' ? 'rgba(124,124,124,0.4)' : 'transparent')
                    .animation({ duration: 250, curve: Curve.Friction })
                    .clickEffect({ level: 2, scale: 0.93 })
                }
                  .width('100%')
                  .height('100%')

                Row() {
                  Image($r('app.media.transparency_lock'))
                    .width(24).height(24)
                    .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                    .margin({ right: 14 })
                  Column() {
                    Text('卡片样式')
                      .fontSize(16)
                      .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                      .fontWeight(FontWeight.Medium)
                      .margin({ bottom: 6 })
                    Text('圆角·边距·色彩')
                      .fontSize(11)
                      .fontColor(this.isDarkMode ? '#BBBBBB' : '#666666')
                      .fontWeight(FontWeight.Normal)
                  }
                  .alignItems(HorizontalAlign.Start)
                  Blank()
                  Circle()
                    .width(8)
                    .height(8)
                    .fill(this.isDarkMode ? '#E5E5E5' : '#333333')
                    .margin({ right: 19 })
                }
                .width('100%')
                .height('100%')
                .padding({ left: 12, right: 12 })
                .clickEffect({ level: 2, scale: 0.93 })
              }
              .width('100%')
              .height(64)
              .padding({ left: 6, right: 6, top: 10, bottom: 10 })
              .onTouch((e: TouchEvent) => {
                if (e.type === TouchType.Down) {
                  this.pressedHighlightId = '卡片样式';
                } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                  this.pressedHighlightId = '';
                }
              })
              .onClick(() => { this.isCardStyleSheetShow = true; })

              Divider()
                .height(1)
                .width('100%')
                .color(this.isDarkMode ? '#3C3C3E' : '#E0E0E0')
                .margin({ top: 2, bottom: 2 })

              // ── 应用比例调节（我的页面 → 卡片样式下方） ──
              Stack() {
                Row() {
                  Row()
                    .width('100%')
                    .height('100%')
                    .borderRadius(17)
                    .backgroundColor(this.pressedHighlightId === '应用比例' ? 'rgba(124,124,124,0.4)' : 'transparent')
                    .animation({ duration: 250, curve: Curve.Friction })
                    .clickEffect({ level: 2, scale: 0.93 })
                }
                  .width('100%')
                  .height('100%')

                Row() {
                  Image($r('app.media.chicun'))
                    .width(24).height(24)
                    .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                    .margin({ right: 14 })
                  Column() {
                    Text('应用比例调节')
                      .fontSize(16)
                      .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                      .fontWeight(FontWeight.Medium)
                      .margin({ bottom: 6 })
                    Text('界面缩放·文字大小')
                      .fontSize(11)
                      .fontColor(this.isDarkMode ? '#BBBBBB' : '#666666')
                      .fontWeight(FontWeight.Normal)
                  }
                  .alignItems(HorizontalAlign.Start)
                  Blank()
                  Circle()
                    .width(8)
                    .height(8)
                    .fill(this.isDarkMode ? '#E5E5E5' : '#333333')
                    .margin({ right: 19 })
                }
                .width('100%')
                .height('100%')
                .padding({ left: 12, right: 12 })
                .clickEffect({ level: 2, scale: 0.93 })
              }
              .width('100%')
              .height(64)
              .padding({ left: 6, right: 6, top: 10, bottom: 10 })
              .onTouch((e: TouchEvent) => {
                if (e.type === TouchType.Down) {
                  this.pressedHighlightId = '应用比例';
                } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                  this.pressedHighlightId = '';
                }
              })
              .onClick(() => { this.openAppScaleSheet(); })
              .bindSheet($$this.isAppScaleSheetShow, this.AppScaleSheetContent(), {
                height: '85%',
                dragBar: false,
                showClose: false,
                backgroundColor: this.isDarkMode ? '#1C1C1E' : '#F5F5F5',
                onWillDismiss: (dismissSheetAction: DismissSheetAction) => {
                  if (this.appScaleDirty) {
                    if (this.appScaleMode !== this.appScaleModeSaved) {
                      // 关闭了「自定义比例」开关：需重启才生效
                      AlertDialog.show({
                        title: '关闭自定义比例',
                        message: '关闭后需重启应用才完全跟随系统设置。是否现在重启？',
                        autoCancel: false,
                        primaryButton: {
                          value: '取消',
                          fontColor: this.isDarkMode ? '#FFFFFF' : '#000000',
                          action: () => {
                            // 维持现状：还原为已保存的自定义模式
                            this.appScaleMode = this.appScaleModeSaved;
                            this.appUiScale = this.appUiScaleSaved;
                            this.appFontScale = this.appFontScaleSaved;
                            this.appScaleDirty = false;
                            dismissSheetAction.dismiss();
                          }
                        },
                        secondaryButton: {
                          value: '重启',
                          fontColor: '#E84040',
                          action: () => { this.persistAndRestartApp(this.appScaleMode); }
                        }
                      });
                    } else {
                      // 调了滑杆未保存：取消=留在弹窗 / 退出=还原并关闭
                      AlertDialog.show({
                        title: '退出应用比例调节',
                        message: '有未应用的比例更改，退出后将丢失。是否退出？',
                        autoCancel: false,
                        primaryButton: {
                          value: '取消',
                          fontColor: this.isDarkMode ? '#FFFFFF' : '#000000',
                          action: () => {}
                        },
                        secondaryButton: {
                          value: '退出',
                          fontColor: '#E84040',
                          action: () => {
                            // 还原为上次保存值，不保存、不应用
                            this.appUiScale = this.appUiScaleSaved;
                            this.appFontScale = this.appFontScaleSaved;
                            this.appScaleDirty = false;
                            // 用系统 dismiss 完成关闭，避免手动置false双动画闪屏
                            dismissSheetAction.dismiss();
                          }
                        }
                      });
                    }
                  } else {
                    // 直接走系统关闭动画，不再手动置状态
                    dismissSheetAction.dismiss();
                  }
                }
              })
            }
            .width('100%')
            .backgroundColor(this.getCardItemBg())
            .borderRadius(20)
            .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
            .margin({ bottom: 16 })

          // ── 播放与推荐 ──
          this.SectionHeader('播放与推荐')
          this.SettingItemWithPicker($r('app.media.ic_settings_quality'), '画质', () => { this.showQualityPicker(); }, 8)
          this.SettingItemWithPicker($r('app.media.ic_settings_quality'), '推荐源', () => { this.showRecommendApiPicker(); }, 8)
          this.SettingItemWithPicker($r('app.media.ic_settings_quality'), '弹幕数据源', () => { this.showDanmakuApiPicker(); }, 8)
          // ⭐ 回桌面自动画中画开关（播放页按此 key 武装/解除自动小窗）
          this.SettingItemWithToggle($r('app.media.ic_settings_quality'), '自动小窗', this.autoPip, async (value: boolean) => {
            this.autoPip = value;
          }, 8, '播放中回到桌面自动以小窗继续播放')

          // ── 首页轮播 ──
          this.SectionHeader('首页轮播')
          Column() {
            // ── 折叠头 ──
            Row() {
              Row() {
                Image($r('app.media.ic_public_albums'))
                  .width(24).height(24)
                  .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                  .margin({ right: 14 })
                Text('轮播选项')
                  .fontSize(15)
                  .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .flexShrink(1)
                Blank()
                Image($r('app.media.ic_public_arrow_left_filled'))
                  .width(20).height(20)
                  .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                  .rotate({ angle: this.carouselExpanded ? 90 : -90 })
                  .animation({ duration: 200, curve: Curve.FastOutSlowIn })
              }
              .width('100%')
              .height(48)
              .padding({ left: 18, right: 18 })
            }
            .width('100%')
            .height(48)
            .borderRadius(17)
            .backgroundColor(this.pressedHighlightId === '轮播选项'
              ? (this.isDarkMode ? 'rgba(255,255,255,0.18)' : 'rgba(124,124,124,0.4)')
              : 'transparent')
            .animation({ duration: 250, curve: Curve.Friction })
            .clickEffect({ level: 2, scale: 0.93 })
            .onTouch((e: TouchEvent) => {
              if (e.type === TouchType.Down) {
                this.pressedHighlightId = '轮播选项';
              } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                this.pressedHighlightId = '';
              }
            })
            .onClick(() => {
              this.carouselExpanded = !this.carouselExpanded;
            })

            // ── 展开后的 4 个选项 ──
            if (this.carouselExpanded) {
              // 竖屏轮播图
              Row() {
                Row() {
                  Image($r('app.media.ic_public_devices_phone_filled'))
                    .width(24).height(24)
                    .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                    .margin({ right: 14 })
                  Text('竖屏轮播图')
                    .fontSize(15)
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .flexShrink(1)
                  Blank()
                  Toggle({ type: ToggleType.Switch, isOn: this.showHomeCarouselPortrait })
                    .selectedColor(this.customThemeColor)
                    .switchPointColor(Color.White)
                    .scale({ x: 0.85, y: 0.85 })
                    .onChange(async (value: boolean) => {
                      AppStorage.set('showHomeCarouselPortrait', value);
                      try {
                        const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
                        await p.put('showHomeCarouselPortrait', value);
                        await p.flush();
                      } catch (_) {}
                    })
                }
                .width('100%')
                .height(48)
                .padding({ left: 14, right: 14 })
                .borderRadius(17)
                .backgroundColor(this.pressedHighlightId === '竖屏轮播图'
                  ? (this.isDarkMode ? 'rgba(255,255,255,0.18)' : 'rgba(124,124,124,0.4)')
                  : 'transparent')
                .animation({ duration: 250, curve: Curve.Friction })
                .clickEffect({ level: 2, scale: 0.93 })
                .onTouch((e: TouchEvent) => {
                  if (e.type === TouchType.Down) {
                    this.pressedHighlightId = '竖屏轮播图';
                  } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                    this.pressedHighlightId = '';
                  }
                })
              }
              .width('100%')
              .height(48)

              // 竖屏轮播背景
              Row() {
                Row() {
                  Image($r('app.media.ic_settings_wallpaper'))
                    .width(24).height(24)
                    .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                    .margin({ right: 14 })
                  Text('竖屏轮播背景')
                    .fontSize(15)
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .flexShrink(1)
                  Blank()
                  Toggle({ type: ToggleType.Switch, isOn: this.showCarouselBgPortrait })
                    .selectedColor(this.customThemeColor)
                    .switchPointColor(Color.White)
                    .scale({ x: 0.85, y: 0.85 })
                    .onChange(async (value: boolean) => {
                      AppStorage.set('showCarouselBgPortrait', value);
                      try {
                        const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
                        await p.put('showCarouselBgPortrait', value);
                        await p.flush();
                      } catch (_) {}
                    })
                }
                .width('100%')
                .height(48)
                .padding({ left: 14, right: 14 })
                .borderRadius(17)
                .backgroundColor(this.pressedHighlightId === '竖屏轮播背景'
                  ? (this.isDarkMode ? 'rgba(255,255,255,0.18)' : 'rgba(124,124,124,0.4)')
                  : 'transparent')
                .animation({ duration: 250, curve: Curve.Friction })
                .clickEffect({ level: 2, scale: 0.93 })
                .onTouch((e: TouchEvent) => {
                  if (e.type === TouchType.Down) {
                    this.pressedHighlightId = '竖屏轮播背景';
                  } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                    this.pressedHighlightId = '';
                  }
                })
              }
              .width('100%')
              .height(48)

              // 横屏轮播图
              Row() {
                Row() {
                  Image($r('app.media.ic_public_devices_phone_filled'))
                    .width(24).height(24)
                    .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                    .margin({ right: 14 })
                    .rotate({ angle: 90 })
                  Text('横屏轮播图')
                    .fontSize(15)
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .flexShrink(1)
                  Blank()
                  Toggle({ type: ToggleType.Switch, isOn: this.showHomeCarouselLandscape })
                    .selectedColor(this.customThemeColor)
                    .switchPointColor(Color.White)
                    .scale({ x: 0.85, y: 0.85 })
                    .onChange(async (value: boolean) => {
                      AppStorage.set('showHomeCarouselLandscape', value);
                      try {
                        const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
                        await p.put('showHomeCarouselLandscape', value);
                        await p.flush();
                      } catch (_) {}
                    })
                }
                .width('100%')
                .height(48)
                .padding({ left: 14, right: 14 })
                .borderRadius(17)
                .backgroundColor(this.pressedHighlightId === '横屏轮播图'
                  ? (this.isDarkMode ? 'rgba(255,255,255,0.18)' : 'rgba(124,124,124,0.4)')
                  : 'transparent')
                .animation({ duration: 250, curve: Curve.Friction })
                .clickEffect({ level: 2, scale: 0.93 })
                .onTouch((e: TouchEvent) => {
                  if (e.type === TouchType.Down) {
                    this.pressedHighlightId = '横屏轮播图';
                  } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                    this.pressedHighlightId = '';
                  }
                })
              }
              .width('100%')
              .height(48)

              // 横屏轮播背景
              Row() {
                Row() {
                  Image($r('app.media.ic_settings_wallpaper'))
                    .width(24).height(24)
                    .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                    .margin({ right: 14 })
                  Text('横屏轮播背景')
                    .fontSize(15)
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .flexShrink(1)
                  Blank()
                  Toggle({ type: ToggleType.Switch, isOn: this.showCarouselBgLandscape })
                    .selectedColor(this.customThemeColor)
                    .switchPointColor(Color.White)
                    .scale({ x: 0.85, y: 0.85 })
                    .onChange(async (value: boolean) => {
                      AppStorage.set('showCarouselBgLandscape', value);
                      try {
                        const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
                        await p.put('showCarouselBgLandscape', value);
                        await p.flush();
                      } catch (_) {}
                    })
                }
                .width('100%')
                .height(48)
                .padding({ left: 14, right: 14 })
                .borderRadius(17)
                .backgroundColor(this.pressedHighlightId === '横屏轮播背景'
                  ? (this.isDarkMode ? 'rgba(255,255,255,0.18)' : 'rgba(124,124,124,0.4)')
                  : 'transparent')
                .animation({ duration: 250, curve: Curve.Friction })
                .clickEffect({ level: 2, scale: 0.93 })
                .onTouch((e: TouchEvent) => {
                  if (e.type === TouchType.Down) {
                    this.pressedHighlightId = '横屏轮播背景';
                  } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                    this.pressedHighlightId = '';
                  }
                })
              }
              .width('100%')
              .height(48)

              // 背景圆角（0-40vp，默认 30）：仅作用于首页背景层顶部两角
              Column() {
                Row() {
                  Image($r('app.media.ic_settings_wallpaper'))
                    .width(24).height(24)
                    .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                    .margin({ right: 14 })
                  Text('背景圆角')
                    .fontSize(15)
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .fontWeight(FontWeight.Medium)
                  Blank()
                  Text(`${this.carouselBgRadius}vp`)
                    .fontSize(14)
                    .fontColor(this.customThemeColor)
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')
                .height(32)

                Row() {
                  Slider({ value: this.carouselBgRadius, min: 0, max: 40, step: 1, style: SliderStyle.InSet })
                    .layoutWeight(1)
                    .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
                    .selectedColor(this.customThemeColor)
                    .blockColor('#FFFFFF')
                    .onChange((value: number, mode: SliderChangeMode) => {
                      // 拖动中只更新状态（@StorageLink 双向写回，首页实时预览）；松手/点击才落盘
                      this.carouselBgRadius = Math.round(value);
                      if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                        this.saveCarouselBgRadius(Math.round(value));
                      }
                    })
                }
                .width('100%')
                .height(32)
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .borderRadius(17)
            }
          }
          .width('100%')
          .backgroundColor(this.getCardItemBg())
          .borderRadius(20)
          .padding({ top: 4, bottom: 4 })
          .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
          .margin({ bottom: 8 })

          // ── 轮播图标题选项 ──
          Column() {
            // ── 折叠头 ──
            Row() {
              Row() {
                Image($r('app.media.ic_public_edit_filled'))
                  .width(24).height(24)
                  .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                  .margin({ right: 14 })
                Text('轮播图标题选项')
                  .fontSize(15)
                  .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .flexShrink(1)
                Blank()
                Image($r('app.media.ic_public_arrow_left_filled'))
                  .width(20).height(20)
                  .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                  .rotate({ angle: this.carouselTitleExpanded ? 90 : -90 })
                  .animation({ duration: 200, curve: Curve.FastOutSlowIn })
              }
              .width('100%')
              .height(48)
              .padding({ left: 18, right: 18 })
            }
            .width('100%')
            .height(48)
            .borderRadius(17)
            .backgroundColor(this.pressedHighlightId === '轮播图标题选项'
              ? (this.isDarkMode ? 'rgba(255,255,255,0.18)' : 'rgba(124,124,124,0.4)')
              : 'transparent')
            .animation({ duration: 250, curve: Curve.Friction })
            .clickEffect({ level: 2, scale: 0.93 })
            .onTouch((e: TouchEvent) => {
              if (e.type === TouchType.Down) {
                this.pressedHighlightId = '轮播图标题选项';
              } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                this.pressedHighlightId = '';
              }
            })
            .onClick(() => {
              this.carouselTitleExpanded = !this.carouselTitleExpanded;
            })

            // ── 展开后的 4 个选项 ──
            if (this.carouselTitleExpanded) {
              // 左右间距容器：卡片内 width('100%') + margin 会溢出，改用外层 padding 实现缩进
              Column() {
              // ── 实时预览：与首页轮播胶囊同款材质，跟随设置即时刷新 ──
              // 参考宽 400vp 模拟轮播可见宽度，barWidth = 参考宽 × 百分比 - 16（contentPadding×4），与首页逻辑一致
              Stack({ alignContent: Alignment.Center }) {
                HdsMiniBarButton({
                  barWidth: Math.max(140, Math.round(400 * this.carouselTitleCapsuleWidth / 100) - 16),
                  barHeight: this.carouselTitleCapsuleHeight,
                  contentPadding: 4,
                  materialType: hdsMaterial.MaterialType.IMMERSIVE,
                  materialLevel: hdsMaterial.MaterialLevel.EXQUISITE,
                  barOverlap: true,
                  barPosition: BarPosition.End
                }) {
                  Text('标题预览')
                    .fontSize(this.carouselTitleFontSize)
                    .fontWeight(this.resolveCarouselTitleFontWeight())
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .letterSpacing(this.carouselTitleLetterSpacing)
                    .textAlign(TextAlign.Center)
                    .width('100%')
                }
              }
              .width('100%')
              .height(72)
              .margin({ top: 4, bottom: 4 })

              // 文字大小（12-20）
              Column() {
                Row() {
                  Text('文字大小')
                    .fontSize(16)
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .fontWeight(FontWeight.Medium)
                  Blank()
                  Text(`${this.carouselTitleFontSize}`)
                    .fontSize(14)
                    .fontColor(this.customThemeColor)
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')
                .margin({ bottom: 8 })

                Row() {
                  Image($r('app.media.arrow_clockwise'))
                    .width(18).height(18)
                    .margin({ right: 8 })
                    .fillColor(this.customThemeColor)
                    .onClick(() => {
                      this.carouselTitleFontSize = 15;
                      this.saveCarouselTitleSetting('carouselTitleFontSize', 15);
                    })
                  Slider({ value: this.carouselTitleFontSize, min: 12, max: 20, step: 1, style: SliderStyle.InSet })
                    .layoutWeight(1)
                    .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
                    .selectedColor(this.customThemeColor)
                    .blockColor('#FFFFFF')
                    .onChange((value: number, mode: SliderChangeMode) => {
                      if (mode === SliderChangeMode.Moving) {
                        this.carouselTitleFontSize = Math.round(value);
                      } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                        this.carouselTitleFontSize = Math.round(value);
                        this.saveCarouselTitleSetting('carouselTitleFontSize', Math.round(value));
                      }
                    })
                }
                .width('100%')
              }
              .width('100%')
              .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
              .borderRadius(20)
              .padding({ left: 18, right: 18, top: 12, bottom: 12 })
              .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
              .margin({ bottom: 12 })

              // 文字粗细（0=常规, 1=中等, 2=加粗）
              Column() {
                Row() {
                  Text('文字粗细')
                    .fontSize(16)
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .fontWeight(FontWeight.Medium)
                  Blank()
                  Text(this.fontWeightLabel(this.carouselTitleFontWeight))
                    .fontSize(14)
                    .fontColor(this.customThemeColor)
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')
                .margin({ bottom: 8 })

                Row() {
                  Image($r('app.media.arrow_clockwise'))
                    .width(18).height(18)
                    .margin({ right: 8 })
                    .fillColor(this.customThemeColor)
                    .onClick(() => {
                      this.carouselTitleFontWeight = 'medium';
                      this.saveCarouselTitleSetting('carouselTitleFontWeight', 'medium');
                    })
                  Slider({ value: this.carouselTitleWeightToIndex(this.carouselTitleFontWeight), min: 0, max: 2, step: 1, style: SliderStyle.InSet })
                    .layoutWeight(1)
                    .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
                    .selectedColor(this.customThemeColor)
                    .blockColor('#FFFFFF')
                    .onChange((value: number, mode: SliderChangeMode) => {
                      const w = this.carouselTitleWeightFromIndex(Math.round(value));
                      this.carouselTitleFontWeight = w;
                      if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                        this.saveCarouselTitleSetting('carouselTitleFontWeight', w);
                      }
                    })
                }
                .width('100%')
              }
              .width('100%')
              .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
              .borderRadius(20)
              .padding({ left: 18, right: 18, top: 12, bottom: 12 })
              .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
              .margin({ bottom: 12 })

              // 字体间距（0-5）
              Column() {
                Row() {
                  Text('字体间距')
                    .fontSize(16)
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .fontWeight(FontWeight.Medium)
                  Blank()
                  Text(`${this.carouselTitleLetterSpacing}`)
                    .fontSize(14)
                    .fontColor(this.customThemeColor)
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')
                .margin({ bottom: 8 })

                Row() {
                  Image($r('app.media.arrow_clockwise'))
                    .width(18).height(18)
                    .margin({ right: 8 })
                    .fillColor(this.customThemeColor)
                    .onClick(() => {
                      this.carouselTitleLetterSpacing = 1;
                      this.saveCarouselTitleSetting('carouselTitleLetterSpacing', 1);
                    })
                  Slider({ value: this.carouselTitleLetterSpacing, min: 0, max: 5, step: 1, style: SliderStyle.InSet })
                    .layoutWeight(1)
                    .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
                    .selectedColor(this.customThemeColor)
                    .blockColor('#FFFFFF')
                    .onChange((value: number, mode: SliderChangeMode) => {
                      this.carouselTitleLetterSpacing = Math.round(value);
                      if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                        this.saveCarouselTitleSetting('carouselTitleLetterSpacing', Math.round(value));
                      }
                    })
                }
                .width('100%')
              }
              .width('100%')
              .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
              .borderRadius(20)
              .padding({ left: 18, right: 18, top: 12, bottom: 12 })
              .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
              .margin({ bottom: 12 })

              // 胶囊高度（32-40）
              Column() {
                Row() {
                  Text('胶囊高度')
                    .fontSize(16)
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .fontWeight(FontWeight.Medium)
                  Blank()
                  Text(`${this.carouselTitleCapsuleHeight}`)
                    .fontSize(14)
                    .fontColor(this.customThemeColor)
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')
                .margin({ bottom: 8 })

                Row() {
                  Image($r('app.media.arrow_clockwise'))
                    .width(18).height(18)
                    .margin({ right: 8 })
                    .fillColor(this.customThemeColor)
                    .onClick(() => {
                      this.carouselTitleCapsuleHeight = 36;
                      this.saveCarouselTitleSetting('carouselTitleCapsuleHeight', 36);
                    })
                  Slider({ value: this.carouselTitleCapsuleHeight, min: 32, max: 40, step: 2, style: SliderStyle.InSet })
                    .layoutWeight(1)
                    .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
                    .selectedColor(this.customThemeColor)
                    .blockColor('#FFFFFF')
                    .onChange((value: number, mode: SliderChangeMode) => {
                      this.carouselTitleCapsuleHeight = Math.round(value);
                      if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                        this.saveCarouselTitleSetting('carouselTitleCapsuleHeight', Math.round(value));
                      }
                    })
                }
                .width('100%')
              }
              .width('100%')
              .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
              .borderRadius(20)
              .padding({ left: 18, right: 18, top: 12, bottom: 12 })
              .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
              .margin({ bottom: 12 })

              // 胶囊宽度（20%-100%，占轮播可见宽度比例）
              Column() {
                Row() {
                  Text('胶囊宽度')
                    .fontSize(16)
                    .fontColor(this.isDarkMode ? '#FFFFFF' : '#000000')
                    .fontWeight(FontWeight.Medium)
                  Blank()
                  Text(`${this.carouselTitleCapsuleWidth}%`)
                    .fontSize(14)
                    .fontColor(this.customThemeColor)
                    .fontWeight(FontWeight.Medium)
                }
                .width('100%')
                .margin({ bottom: 8 })

                Row() {
                  Image($r('app.media.arrow_clockwise'))
                    .width(18).height(18)
                    .margin({ right: 8 })
                    .fillColor(this.customThemeColor)
                    .onClick(() => {
                      this.carouselTitleCapsuleWidth = 85;
                      this.saveCarouselTitleSetting('carouselTitleCapsuleWidth', 85);
                    })
                  Slider({ value: this.carouselTitleCapsuleWidth, min: 20, max: 100, step: 5, style: SliderStyle.InSet })
                    .layoutWeight(1)
                    .trackColor(this.isDarkMode ? '#3A3A3A' : '#E8E8E8')
                    .selectedColor(this.customThemeColor)
                    .blockColor('#FFFFFF')
                    .onChange((value: number, mode: SliderChangeMode) => {
                      this.carouselTitleCapsuleWidth = Math.round(value);
                      if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                        this.saveCarouselTitleSetting('carouselTitleCapsuleWidth', Math.round(value));
                      }
                    })
                }
                .width('100%')
              }
              .width('100%')
              .backgroundColor(this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.70)')
              .borderRadius(20)
              .padding({ left: 18, right: 18, top: 12, bottom: 12 })
              .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
              .margin({ bottom: 12 })
              }
              .width('100%')
              .padding({ left: 12, right: 12 })
            }
          }
          .width('100%')
          .backgroundColor(this.getCardItemBg())
          .borderRadius(20)
          .padding({ top: 4, bottom: 4 })
          .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })
          .margin({ bottom: 8 })

          // ── 功能开关 ──
          this.SectionHeader('功能开关')
          this.SettingItemWithToggle($r('app.media.ic_public_search_filled'), '搜索发现', this.showSearchDiscovery, (value: boolean) => { AppStorage.set('showSearchDiscovery', value); }, 8)
          this.SettingItemWithToggle($r('app.media.ic_public_devices_phone_filled'), '直板机布局', this.phoneLayoutToggle, (value: boolean) => {
            // 直板机布局需要在播放页/首页重新加载时生效 → 保存后重启
            this.showPhoneLayoutRestartPrompt(value);
          }, 8)
          this.SettingItemWithToggle($r('app.media.arrow_clockwise'), '上次看到这里', this.showRefreshSeparator, async (value: boolean) => {
            AppStorage.set('showRefreshSeparator', value);
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('showRefreshSeparator', value);
              await p.flush();
            } catch (_) {}
          }, 8)
          this.SettingItemWithToggle($r('app.media.message'), '消息页 Tab 自动隐藏', this.msgTabAutoHide, async (value: boolean) => {
            AppStorage.set('msgTabAutoHide', value);
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('msgTabAutoHide', value);
              await p.flush();
            } catch (_) {}
          }, 8)
          // ⭐「显示动态页」— 关闭后底部 Tab 栏与页面一起移除（重启/切换深浅色后仍保持）
          this.SettingItemWithToggle($r('app.media.discover_fill'), '显示动态页', this.showDynamicsTab, async (value: boolean) => {
            AppStorage.set('showDynamicsTab', value);
            this.getUIContext().getPromptAction().showToast({
              message: value ? '已显示动态页' : '已隐藏动态页（重启应用后底栏不再显示）',
              duration: 2000
            });
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('showDynamicsTab', value);
              await p.flush();
            } catch (_) {}
          }, 8)
          // ⭐「显示消息页」— 关闭后底部 Tab 栏与页面一起移除（重启/切换深浅色后仍保持）
          this.SettingItemWithToggle($r('app.media.message'), '显示消息页', this.showWhisperTab, async (value: boolean) => {
            AppStorage.set('showWhisperTab', value);
            this.getUIContext().getPromptAction().showToast({
              message: value ? '已显示消息页' : '已隐藏消息页（重启应用后底栏不再显示）',
              duration: 2000
            });
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('showWhisperTab', value);
              await p.flush();
            } catch (_) {}
          }, 8)
          // ⚠️「动态页点击切换分类」（默认打开）—— 打开 = 只能点顶部胶囊/分类按钮切分类；关闭 = 恢复左右横滑切分类
          this.SettingItemWithToggle($r('app.media.discover_fill'), '动态页点击切换分类', this.dynFilterTapOnly, async (value: boolean) => {
            AppStorage.set('dynFilterTapOnly', value);
            // 明确告诉用户当前效果（关闭 = 恢复横滑）
            this.getUIContext().getPromptAction().showToast({
              message: value ? '已开启：只能点击顶部按钮切换分类' : '已关闭：动态页可左右横滑切换分类',
              duration: 2000
            });
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('dynFilterTapOnly', value);
              await p.flush();
            } catch (_) {}
          }, 8, '关闭后：动态页可左右横滑切换分类')
          // ⚠️「首页点击切换分类」（默认关闭）—— 关闭 = 允许左右横滑切频道；打开 = 只能点顶部胶囊/分类按钮切频道
          this.SettingItemWithToggle($r('app.media.house'), '首页点击切换分类', this.homeFilterTapOnly, async (value: boolean) => {
            AppStorage.set('homeFilterTapOnly', value);
            // 明确告诉用户当前效果（关闭 = 恢复横滑）
            this.getUIContext().getPromptAction().showToast({
              message: value ? '已开启：只能点击顶部按钮切换分类' : '已关闭：首页可左右横滑切换分类',
              duration: 2000
            });
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('homeFilterTapOnly', value);
              await p.flush();
            } catch (_) {}
          }, 8, '关闭后：首页可左右横滑切换分类')
          this.SettingItemWithToggle($r('app.media.hand_point_up_tap_fill_1'), '上滑评论缩小视频', this.shrinkVideoOnScroll, async (value: boolean) => {
            AppStorage.set('shrinkVideoOnScroll', value);
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('shrinkVideoOnScroll', value);
              await p.flush();
            } catch (_) {}
          })

          this.SectionHeader('关于')
          this.SettingItem($r('app.media.ic_settings_about'), '关于软件', () => { this.goToAbout(); })
          if (this.isLoggedIn) {
            this.SettingItem($r('app.media.backspace_1'), '退出登录', () => { this.showLogoutConfirm(); })
          }
        } else {
            // ── 横屏：双列 ──
            Row({ space: 12 }) {
              // 左列：卡片样式 + 动画·背景·色彩（同一个卡片）
              Column() {
                // 动画·背景·色彩（原个性化）
                Stack() {
                  Row() {
                    Row()
                      .width('100%')
                      .height('100%')
                      .borderRadius(17)
                      .backgroundColor(this.pressedHighlightId === '动画·背景·色彩' ? 'rgba(124,124,124,0.4)' : 'transparent')
                      .animation({ duration: 250, curve: Curve.Friction })
                      .clickEffect({ level: 2, scale: 0.93 })
                  }
                    .width('100%')
                    .height('100%')

                  Row() {
                    Image($r('app.media.ic_settings_personalize'))
                      .width(24).height(24)
                      .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                      .margin({ right: 14 })
                    Column() {
                      Text('个性化')
                        .fontSize(16)
                        .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                        .fontWeight(FontWeight.Medium)
                        .margin({ bottom: 6 })
                      Text('动画·背景·色彩')
                        .fontSize(11)
                        .fontColor(this.isDarkMode ? '#BBBBBB' : '#666666')
                        .fontWeight(FontWeight.Normal)
                    }
                    .alignItems(HorizontalAlign.Start)
                    Blank()
                    Circle()
                      .width(8)
                      .height(8)
                      .fill(this.isDarkMode ? '#E5E5E5' : '#333333')
                      .margin({ right: 19 })
                  }
                  .width('100%')
                  .height('100%')
                  .padding({ left: 12, right: 12 })
                  .clickEffect({ level: 2, scale: 0.93 })
                }
                .width('100%')
                .height(64)
                .padding({ left: 6, right: 6, top: 10, bottom: 10 })
                .onTouch((e: TouchEvent) => {
                  if (e.type === TouchType.Down) {
                    this.pressedHighlightId = '动画·背景·色彩';
                  } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                    this.pressedHighlightId = '';
                  }
                })
                .onClick(() => { this.goToPersonalization(); })

                Divider()
                  .height(1)
                  .width('100%')
                  .color(this.isDarkMode ? '#3C3C3E' : '#E0E0E0')
                  .margin({ top: 2, bottom: 2 })

                // 卡片样式
                Stack() {
                  Row() {
                    Row()
                      .width('100%')
                      .height('100%')
                      .borderRadius(17)
                      .backgroundColor(this.pressedHighlightId === '卡片样式' ? 'rgba(124,124,124,0.4)' : 'transparent')
                      .animation({ duration: 250, curve: Curve.Friction })
                      .clickEffect({ level: 2, scale: 0.93 })
                  }
                    .width('100%')
                    .height('100%')

                  Row() {
                    Image($r('app.media.transparency_lock'))
                      .width(24).height(24)
                      .fillColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                      .margin({ right: 14 })
                    Column() {
                      Text('卡片样式')
                        .fontSize(16)
                        .fontColor(this.isDarkMode ? '#E5E5E5' : '#333333')
                        .fontWeight(FontWeight.Medium)
                        .margin({ bottom: 6 })
                      Text('圆角·边距·色彩')
                        .fontSize(11)
                        .fontColor(this.isDarkMode ? '#BBBBBB' : '#666666')
                        .fontWeight(FontWeight.Normal)
                    }
                    .alignItems(HorizontalAlign.Start)
                    Blank()
                    Circle()
                      .width(8)
                      .height(8)
                      .fill(this.isDarkMode ? '#E5E5E5' : '#333333')
                      .margin({ right: 19 })
                  }
                  .width('100%')
                  .height('100%')
                  .padding({ left: 12, right: 12 })
                  .clickEffect({ level: 2, scale: 0.93 })
                }
                .width('100%')
                .height(64)
                .padding({ left: 6, right: 6, top: 10, bottom: 10 })
                .onTouch((e: TouchEvent) => {
                  if (e.type === TouchType.Down) {
                    this.pressedHighlightId = '卡片样式';
                  } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                    this.pressedHighlightId = '';
                  }
                })
                .onClick(() => { this.isCardStyleSheetShow = true; })
              }
              .layoutWeight(1)
              .backgroundColor(this.getCardItemBg())
              .borderRadius(20)
              .shadow({ radius: 8, color: '#0D000000', offsetY: 2 })

              // 右列：播放与推荐 + 功能开关 + 关于
              Column() {
                this.SectionHeader('播放与推荐')
                this.SettingItemWithPicker($r('app.media.ic_settings_quality'), '画质', () => { this.showQualityPicker(); }, 8)
                this.SettingItemWithPicker($r('app.media.ic_settings_quality'), '推荐源', () => { this.showRecommendApiPicker(); }, 8)
          this.SettingItemWithPicker($r('app.media.ic_settings_quality'), '弹幕数据源', () => { this.showDanmakuApiPicker(); }, 8)
          // ⭐ 回桌面自动画中画开关（播放页按此 key 武装/解除自动小窗）
          this.SettingItemWithToggle($r('app.media.ic_settings_quality'), '自动小窗', this.autoPip, async (value: boolean) => {
            this.autoPip = value;
          }, 8, '播放中回到桌面自动以小窗继续播放')
                this.SectionHeader('功能开关')
                this.SettingItemWithToggle($r('app.media.ic_public_search_filled'), '搜索发现', this.showSearchDiscovery, (value: boolean) => { AppStorage.set('showSearchDiscovery', value); }, 8)
                this.SettingItemWithToggle($r('app.media.arrow_clockwise'), '上次看到这里', this.showRefreshSeparator, async (value: boolean) => {
            AppStorage.set('showRefreshSeparator', value);
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('showRefreshSeparator', value);
              await p.flush();
            } catch (_) {}
          }, 8)
          this.SettingItemWithToggle($r('app.media.message'), '消息页 Tab 自动隐藏', this.msgTabAutoHide, async (value: boolean) => {
            AppStorage.set('msgTabAutoHide', value);
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('msgTabAutoHide', value);
              await p.flush();
            } catch (_) {}
          }, 8)
          // ⭐「显示动态页」— 关闭后底部 Tab 栏与页面一起移除（重启/切换深浅色后仍保持）
          this.SettingItemWithToggle($r('app.media.discover_fill'), '显示动态页', this.showDynamicsTab, async (value: boolean) => {
            AppStorage.set('showDynamicsTab', value);
            this.getUIContext().getPromptAction().showToast({
              message: value ? '已显示动态页' : '已隐藏动态页（重启应用后底栏不再显示）',
              duration: 2000
            });
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('showDynamicsTab', value);
              await p.flush();
            } catch (_) {}
          }, 8)
          // ⭐「显示消息页」— 关闭后底部 Tab 栏与页面一起移除（重启/切换深浅色后仍保持）
          this.SettingItemWithToggle($r('app.media.message'), '显示消息页', this.showWhisperTab, async (value: boolean) => {
            AppStorage.set('showWhisperTab', value);
            this.getUIContext().getPromptAction().showToast({
              message: value ? '已显示消息页' : '已隐藏消息页（重启应用后底栏不再显示）',
              duration: 2000
            });
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('showWhisperTab', value);
              await p.flush();
            } catch (_) {}
          }, 8)
          // ⚠️「动态页点击切换分类」（默认打开）—— 打开 = 只能点顶部胶囊/分类按钮切分类；关闭 = 恢复左右横滑切分类
          this.SettingItemWithToggle($r('app.media.discover_fill'), '动态页点击切换分类', this.dynFilterTapOnly, async (value: boolean) => {
            AppStorage.set('dynFilterTapOnly', value);
            // 明确告诉用户当前效果（关闭 = 恢复横滑）
            this.getUIContext().getPromptAction().showToast({
              message: value ? '已开启：只能点击顶部按钮切换分类' : '已关闭：动态页可左右横滑切换分类',
              duration: 2000
            });
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('dynFilterTapOnly', value);
              await p.flush();
            } catch (_) {}
          }, 8, '关闭后：动态页可左右横滑切换分类')
          // ⚠️「首页点击切换分类」（默认关闭）—— 关闭 = 允许左右横滑切频道；打开 = 只能点顶部胶囊/分类按钮切频道
          this.SettingItemWithToggle($r('app.media.house'), '首页点击切换分类', this.homeFilterTapOnly, async (value: boolean) => {
            AppStorage.set('homeFilterTapOnly', value);
            // 明确告诉用户当前效果（关闭 = 恢复横滑）
            this.getUIContext().getPromptAction().showToast({
              message: value ? '已开启：只能点击顶部按钮切换分类' : '已关闭：首页可左右横滑切换分类',
              duration: 2000
            });
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('homeFilterTapOnly', value);
              await p.flush();
            } catch (_) {}
          }, 8, '关闭后：首页可左右横滑切换分类')
          this.SettingItemWithToggle($r('app.media.hand_point_up_tap_fill_1'), '上滑评论缩小视频', this.shrinkVideoOnScroll, async (value: boolean) => {
            AppStorage.set('shrinkVideoOnScroll', value);
            try {
              const p = await preferences.getPreferences(this.getUIContext().getHostContext() as common.UIAbilityContext, 'my_app_settings');
              await p.put('shrinkVideoOnScroll', value);
              await p.flush();
            } catch (_) {}
          })
                this.SectionHeader('关于')
                this.SettingItem($r('app.media.ic_settings_about'), '关于软件', () => { this.goToAbout(); })
                if (this.isLoggedIn) {
                  this.SettingItem($r('app.media.backspace_1'), '退出登录', () => { this.showLogoutConfirm(); })
                }
              }
              .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 96 })
        .clip(false)
      }
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).backgroundColor('transparent')
      .padding({ top: this.hideStatusBar ? 16 : (this.statusBarHeight + 16) })
      .bindSheet($$this.isCardStyleSheetShow, this.CardStyleSheetContent(), {
        // 卡片样式弹层：固定高度 + 内部滚动（顶部分类布局）
        height: '80%',
        dragBar: false,
        showClose: false,
        width: SheetSize.LARGE,
        backgroundColor: this.isDarkMode ? '#1C1C1E' : '#F5F5F5',
        onDisappear: () => { this.isCardStyleSheetShow = false; }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('transparent')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.isPersonalizationSheetShow, this.PersonalizationSheetContent(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      showClose: false,
      backgroundColor: this.isDarkMode ? '#1C1C1E' : '#F5F5F5',
      onDisappear: () => { this.isPersonalizationSheetShow = false; }
    })
  }
}
