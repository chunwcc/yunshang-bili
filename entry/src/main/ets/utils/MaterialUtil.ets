import { uiMaterial } from '@kit.ArkUI';
import deviceInfo from '@ohos.deviceInfo';
import { hdsMaterial } from '@kit.UIDesignKit';
import { logInfo, logWarn } from './Logger';

/**
 * 沉浸光感（ImmersiveMaterial）能力判断 + 材质对象工厂。
 *
 * 用途：bindSheet 的 SheetOptions.systemMaterial（26.0.0 起支持，弹窗作用域内真材质生效）。
 * 配方来源：云上视界 MediaDetailPage「音轨/字幕」菜单，2026-09-22 真机验收通过；
 * 本工程 2026-09-23 起用于播放器 7 个半模态面板。
 *
 * ⚠️ 两条硬要求（调用方必须遵守）：
 * ① 挂材质的面板**内容根背景必须全透明**——材质层在 backgroundColor 之下，不透明底会把玻璃整层盖住；
 * ② 挂了材质就**不要再叠** backgroundBlurStyle / backdropBlur。
 * 不支持材质时走原样降级（内容根画原来的不透明底色）。
 */
export class MaterialUtil {
  private static checked_: boolean = false;
  private static sheetMat_: uiMaterial.Material | null = null;
  private static pillChecked_: boolean = false;
  private static pillMat_: uiMaterial.Material | null = null;
  private static emoteChecked_: boolean = false;
  private static emoteMat_: uiMaterial.Material | null = null;

  /** 本机（系统 + 设备）是否支持沉浸光感 —— 纯能力探测，无副作用 */
  static available(): boolean {
    try {
      return deviceInfo.apiAvailable('26.0.0') && hdsMaterial.getSystemMaterialTypes().length > 0;
    } catch (e) {
      logWarn('[MaterialUtil] 取材质能力失败，按不支持处理: ' + e);
      return false;
    }
  }

  /**
   * 给 bindSheet 用的沉浸光感材质（THICK + interactive，官方菜单栏推荐档）。
   * 不支持时返回 undefined（SheetOptions.systemMaterial 传 undefined = 无材质，等价默认）。
   * 结果缓存：页面 build 时 7 个 bindSheet 都会取一次，材质对象只建一个。
   */
  static sheetMaterial(): uiMaterial.Material | undefined {
    if (MaterialUtil.checked_) {
      return MaterialUtil.sheetMat_ ?? undefined;
    }
    MaterialUtil.checked_ = true;
    try {
      if (MaterialUtil.available()) {
        MaterialUtil.sheetMat_ = new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THICK,
          // ⭐ interactive: false = 静态玻璃（2026-09-23 用户要求：播放页面板只保留玻璃磨砂，
          //   去掉按压时出现的光斑/形变）。之前 true 是跟随按压出"光感"，用户不要。
          //   胶囊（pillMaterial）仍为 true——用户已验收它的效果，勿联动改。
          interactive: false,
          // ⭐ lightEffect: null = 彻底关闭光效层（interactive:false 后真机仍有点按光，
          //   2026-09-23 用户实测确认，光源在这层；官方签名允许 LightEffectOptions | null）
          lightEffect: null
        });
        logInfo('[MaterialUtil] 已挂沉浸光感材质（THICK, 静态玻璃无光效）');
      } else {
        logInfo('[MaterialUtil] 设备不支持沉浸光感，半模态面板走降级底色');
      }
    } catch (e) {
      logWarn('[MaterialUtil] 创建沉浸光感材质失败，按不支持处理: ' + e);
    }
    return MaterialUtil.sheetMat_ ?? undefined;
  }

  /**
   * 提示胶囊专用材质（bindPopup 用，独立实例，不与半模态面板共用）。
   *
   * 背景：材质底色由系统主题驱动（深浅色切换会变色），popup 的 colorMode
   * （FOLLOW_SYSTEM/FOLLOW_TARGET）实测都拦不住。唯一钉色的旋钮是 `materialColor` ——
   * 官方语义：材质滤镜上的纯色染色层，默认 Color.Transparent；给固定色值后这层不随主题变，
   * 把主题驱动的底色压在染色层下面（视觉上大幅减弱，染色足够深时基本看不出切换）。
   *
   * ⚠️ 官方硬要求：染色**必须带透明度、不能完全不透明**，否则材质滤镜被整层盖死（玻璃感消失）。
   * 这里用 40% 黑 + REGULAR 档（用户要求对齐"之前 HdsTabs 借道版"的透亮观感：hdsMaterial 的
   * ADAPTIVE 档传不进 popup，用 REGULAR 逼近；面板材质保持 THICK 不动）。
   */
  static pillMaterial(): uiMaterial.Material | undefined {
    if (MaterialUtil.pillChecked_) {
      return MaterialUtil.pillMat_ ?? undefined;
    }
    MaterialUtil.pillChecked_ = true;
    try {
      if (MaterialUtil.available()) {
        MaterialUtil.pillMat_ = new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.REGULAR,
          interactive: true,
          lightEffect: { color: undefined },
          materialColor: '#66000000'   // 40% 黑固定染色：玻璃质感优先（用户逐级下调 80→60→40）
        });
        logInfo('[MaterialUtil] 胶囊专用材质已创建（REGULAR + materialColor 40% 黑）');
      }
    } catch (e) {
      logWarn('[MaterialUtil] 创建胶囊专用材质失败: ' + e);
    }
    return MaterialUtil.pillMat_ ?? undefined;
  }

  /**
   * 表情面板弹层专用材质（bindPopup 用，独立实例，配方同 sheetMaterial 的静态玻璃）。
   *
   * ⚠️ 血泪教训（2026-09-23 真机）：把 sheetMaterial 单例同时挂到 bindPopup 后，
   * 全工程共用该实例的提示弹窗/半模态面板**全部无法正常显示**——材质实例与挂载表面
   * 绑定，绝不能跨表面复用（pillMaterial 只配 popup、sheetMaterial 只配 sheet/dialog
   * 时各自一直正常）。⇒ 任何新表面挂材质，必须新建独立实例。
   */
  static emoteMaterial(): uiMaterial.Material | undefined {
    if (MaterialUtil.emoteChecked_) {
      return MaterialUtil.emoteMat_ ?? undefined;
    }
    MaterialUtil.emoteChecked_ = true;
    try {
      if (MaterialUtil.available()) {
        MaterialUtil.emoteMat_ = new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THICK,
          interactive: false,
          lightEffect: null
        });
        logInfo('[MaterialUtil] 表情面板专用材质已创建（THICK 静态玻璃，独立实例）');
      }
    } catch (e) {
      logWarn('[MaterialUtil] 创建表情面板专用材质失败: ' + e);
    }
    return MaterialUtil.emoteMat_ ?? undefined;
  }
}
