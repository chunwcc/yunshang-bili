/**
 * B站客户端签名密钥（占位符模板 · 可提交）
 *
 * 用法：把本文件复制为 AppKeys.ets，然后填入你自己准备好的凭据。
 *   cp AppKeys.example.ets AppKeys.ets
 *
 * 仓库不附带任何真实凭据值。若你需要调用相关接口，请自行准备合规的凭据。
 */
export interface AppKeyConfig {
  appkey: string;
  appsec: string;
}

export const APP_KEYS: Record<string, AppKeyConfig> = {
  'android': {
    appkey: 'YOUR_ANDROID_APPKEY',
    appsec: 'YOUR_ANDROID_APPSEC'
  } as AppKeyConfig,
  'ios': {
    appkey: 'YOUR_IOS_APPKEY',
    appsec: 'YOUR_IOS_APPSEC'
  } as AppKeyConfig,
  'web': {
    appkey: 'YOUR_WEB_APPKEY',
    appsec: 'YOUR_WEB_APPSEC'
  } as AppKeyConfig,
  'android_hd': {
    appkey: 'YOUR_ANDROID_HD_APPKEY',
    appsec: 'YOUR_ANDROID_HD_APPSEC'
  } as AppKeyConfig,
  'tv': {
    appkey: 'YOUR_TV_APPKEY',
    appsec: 'YOUR_TV_APPSEC'
  } as AppKeyConfig
};
