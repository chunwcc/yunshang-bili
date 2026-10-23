// StatusBarUtils.ets - 状态栏颜色管理工具 + 隐藏/显示控制
import { window } from '@kit.ArkUI';
import { logInfo, logWarn, logError } from './Logger';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

export class StatusBarUtils {
  /**
   * 更新状态栏文字颜色（背景透明）
   * @param context UIAbilityContext
   * @param isDarkMode true=深色模式(白字), false=浅色模式(黑字)
   */
  static async updateStatusBarColor(context: common.UIAbilityContext, isDarkMode: boolean) {
    try {
      const windowClass: window.Window = await window.getLastWindow(context);
      // 确保沉浸式布局开启（EntryAbility 已设置，此处作为二次保障）
      await windowClass.setWindowLayoutFullScreen(true);
      const sysBarProps: window.SystemBarProperties = {
        statusBarColor: '#00000000',               // 状态栏完全透明
        statusBarContentColor: isDarkMode ? '#FFFFFF' : '#000000',
        navigationBarColor: '#00000000',            // 导航栏完全透明，消除底部白边/黑边
      };
      await windowClass.setWindowSystemBarProperties(sysBarProps);
      logInfo(`状态栏已更新: ${isDarkMode ? '深色模式(白字)' : '浅色模式(黑字)'}`);
    } catch (error) {
      let err = error as BusinessError;
      logError(`更新状态栏失败: ${err.code} - ${err.message}`);
    }
  }

  /**
   * 隐藏或显示状态栏
   * 始终保持全屏布局模式，让窗口内容延伸到系统栏后方，消除白边
   * @param context UIAbilityContext
   * @param hide true=隐藏状态栏，false=显示状态栏
   */
  static async setStatusBarHidden(context: common.UIAbilityContext, hide: boolean) {
    try {
      const windowClass: window.Window = await window.getLastWindow(context);
      
      // 始终保持全屏布局，让内容延伸到状态栏/导航栏后方，避免出现白边
      await windowClass.setWindowLayoutFullScreen(true);
      
      // ★ 无论显隐状态，强制设置状态栏/导航栏背景透明
      // 防止用户下滑呼出通知面板时状态栏区域出现白色背景
      const sysBarProps: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
      };
      await windowClass.setWindowSystemBarProperties(sysBarProps);
      
      // 只切换状态栏内容的显隐
      await windowClass.setSpecificSystemBarEnabled('status', !hide);
      // 导航栏始终保持显示
      await windowClass.setSpecificSystemBarEnabled('navigationIndicator', true);
      
      logInfo(`状态栏已${hide ? '隐藏' : '显示'}（全屏布局保持开启）`);
    } catch (error) {
      let err = error as BusinessError;
      logError(`设置状态栏隐藏/显示失败: ${err.code} - ${err.message}`);
    }
  }
}