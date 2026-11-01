// ThemeController.ts — 深浅色模式切换工具函数
// 封装系统 setColorMode 调用与状态同步
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { ColorModePref, ThemePersist } from './ThemePersist';

const setColorMode = (context: common.Context, colorMode: ConfigurationConstant.ColorMode) => {
  try {
    const appContext = context.getApplicationContext();
    appContext.setColorMode(colorMode);
  } catch (err) {
    console.error(`setColorMode failed: ${JSON.stringify(err)}`);
  }
}

export const setAutoColorMode = (context: common.Context) => {
  setColorMode(context, ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
}

export const setDarkColorMode = (context: common.Context) => {
  setColorMode(context, ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
}

export const setLightColorMode = (context: common.Context) => {
  setColorMode(context, ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
}
