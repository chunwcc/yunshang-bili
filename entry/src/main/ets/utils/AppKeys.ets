/**
 * B站客户端签名密钥（本地文件 · 不入库）
 * 仓库只提供 AppKeys.example.ets 模板；本文件为工作区本地副本，
 * 内容依据删除前构建产物（modules.abc 字符串常量）忠实还原。
 */
export interface AppKeyConfig {
  appkey: string;
  appsec: string;
}

export const APP_KEYS: Record<string, AppKeyConfig> = {
  'android': {
    appkey: 'YOUR_ANDROID_APPKEY_HERE',
    appsec: 'YOUR_ANDROID_APPSEC_HERE'
  } as AppKeyConfig,
  'ios': {
    appkey: 'YOUR_IOS_APPKEY_HERE',
    appsec: 'YOUR_IOS_APPSEC_HERE'
  } as AppKeyConfig,
  'web': {
    appkey: 'YOUR_WEB_APPKEY_HERE',
    appsec: 'YOUR_WEB_APPSEC_HERE'
  } as AppKeyConfig,
  'android_hd': {
    appkey: 'YOUR_ANDROID_HD_APPKEY_HERE',
    appsec: 'YOUR_ANDROID_HD_APPSEC_HERE'
  } as AppKeyConfig,
  'tv': {
    appkey: 'YOUR_TV_APPKEY_HERE',
    appsec: 'YOUR_TV_APPSEC_HERE'
  } as AppKeyConfig
};
