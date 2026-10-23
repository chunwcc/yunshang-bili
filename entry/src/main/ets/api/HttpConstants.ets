/**
 * B站API基础URL常量
 * 参考PiliPlus项目的HttpString类
 */
export class HttpConstants {
  // ==================== API基础URL ====================
  
  // 移动端API基础URL
  static readonly appBaseUrl: string = 'https://app.bilibili.com';
  
  // Web端API基础URL
  static readonly webBaseUrl: string = 'https://api.bilibili.com';
  
  // 直播API基础URL
  static readonly liveBaseUrl: string = 'https://api.live.bilibili.com';
  
  // 通行证/登录API基础URL
  static readonly passBaseUrl: string = 'https://passport.bilibili.com';
  
  // 私信/消息API基础URL
  static readonly tUrl: string = 'https://api.vc.bilibili.com';
  
  // 消息中心API基础URL
  static readonly messageBaseUrl: string = 'https://message.bilibili.com';
  
  // 账户API基础URL
  static readonly accountBaseUrl: string = 'https://account.bilibili.com';
  
  // 商城API基础URL
  static readonly mallBaseUrl: string = 'https://mall.bilibili.com';
  
  // 用户空间API基础URL
  static readonly spaceBaseUrl: string = 'https://space.bilibili.com';
  
  // 主站API基础URL
  static readonly mainBaseUrl: string = 'https://www.bilibili.com';
  
  // 接口API基础URL
  static readonly interfaceBaseUrl: string = 'https://interface.bilibili.com';

  // ==================== API路径常量 ====================
  
  // 视频播放地址API
  static readonly videoPlayUrlPath: string = '/x/player/playurl';
  
  // 移动端视频播放地址API
  static readonly mobileVideoPlayUrlPath: string = '/x/v2/playurl';
  
  // 搜索API
  static readonly searchPath: string = '/x/web-interface/search/type';
  
  // 搜索发现推荐API（App端）
  static readonly searchRecommendPath: string = '/x/v2/search/recommend';
  
  // 推荐视频API
  static readonly recommendPath: string = '/x/web-interface/index/top/feed/rcmd';
  
  // 热门视频API
  static readonly popularPath: string = '/x/web-interface/popular';
  
  // 视频信息API
  static readonly videoInfoPath: string = '/x/web-interface/view';
  
  // 二维码登录API
  static readonly qrCodeLoginPath: string = '/x/passport-tv-login/qrcode/auth_code';
  
  // 二维码登录状态查询API
  static readonly qrCodeLoginStatusPath: string = '/x/passport-tv-login/qrcode/poll';
  
  // ==================== 画质常量 (qn) ====================
  
  // 自动选择（默认）
  static readonly QUALITY_AUTO: number = 0;
  
  // 360P
  static readonly QUALITY_360P: number = 16;
  
  // 480P
  static readonly QUALITY_480P: number = 32;
  
  // 720P
  static readonly QUALITY_720P: number = 64;
  
  // 720P 60帧
  static readonly QUALITY_720P_60FPS: number = 74;
  
  // 1080P
  static readonly QUALITY_1080P: number = 80;
  
  // 1080P 高码率
  static readonly QUALITY_1080P_HIGH: number = 112;
  
  // 1080P 60帧
  static readonly QUALITY_1080P_60FPS: number = 116;
  
  // 4K
  static readonly QUALITY_4K: number = 120;
  
  // HDR
  static readonly QUALITY_HDR: number = 125;
  
  // 杜比视界
  static readonly QUALITY_DOLBY_VISION: number = 126;
  
  // 8K
  static readonly QUALITY_8K: number = 127;
  
  // ==================== 视频格式常量 (fnval) ====================
  
  // FLV格式（旧格式）
  static readonly FORMAT_FLV: number = 0;
  
  // MP4格式
  static readonly FORMAT_MP4: number = 1;
  
  // DASH格式（音频视频分离）
  static readonly FORMAT_DASH: number = 16;
  
  // 4K格式
  static readonly FORMAT_4K: number = 64;
  
  // HDR格式
  static readonly FORMAT_HDR: number = 128;
  
  // 杜比视界格式
  static readonly FORMAT_DOLBY_VISION: number = 256;
  
  // 杜比音频格式
  static readonly FORMAT_DOLBY_AUDIO: number = 512;
  
  // 8K格式
  static readonly FORMAT_8K: number = 1024;
  
  // AV1编码格式
  static readonly FORMAT_AV1: number = 2048;
  
  // 常用组合：FLV + 全DASH格式
  static readonly FORMAT_FLV_AND_DASH: number = 4049; // 1 | 16 | 64 | 128 | 256 | 512 | 1024 | 2048
  
  // 常用组合：仅DASH格式
  static readonly FORMAT_DASH_ONLY: number = 16;
  
  // 常用组合：FLV格式
  static readonly FORMAT_FLV_ONLY: number = 1;
  
  // ==================== 平台常量 ====================
  
  static readonly PLATFORM_ANDROID: string = 'android';
  static readonly PLATFORM_IOS: string = 'ios';
  static readonly PLATFORM_WEB: string = 'web';
  static readonly PLATFORM_TV: string = 'android_tv_yst';
  
  // ==================== 设备常量 ====================
  
  static readonly DEVICE_ANDROID: string = 'android';
  static readonly DEVICE_IOS: string = 'iphone';
  static readonly DEVICE_WEB: string = 'web';
  
  // ==================== 应用常量 ====================
  
  static readonly MOBI_APP_ANDROID: string = 'android';
  static readonly MOBI_APP_IOS: string = 'iphone';
  static readonly MOBI_APP_WEB: string = 'web';
  
  // ==================== 构建版本常量 ====================
  
  static readonly BUILD_ANDROID: string = '6740300';
  static readonly BUILD_IOS: string = '6740300';
  static readonly BUILD_WEB: string = '6740300';
  
  // ==================== 网络类型常量 ====================
  
  static readonly NETWORK_WIFI: string = 'wifi';
  static readonly NETWORK_MOBILE: string = 'mobile';
  static readonly NETWORK_UNKNOWN: string = 'unknown';
  
  // ==================== 其他常量 ====================
  
  static readonly FOURK_ENABLED: string = '1';
  static readonly FOURK_DISABLED: string = '0';
  
  static readonly FNVER: string = '0';
  static readonly OTYPE_JSON: string = 'json';
  
  // ==================== 用户代理常量 ====================
  
  static readonly USER_AGENT_ANDROID: string = 'Mozilla/5.0 BiliDroid/7.67.0 (bbcallen@gmail.com) os/android model/ONEPLUS A6000 mobi_app/android build/6740300 channel/bili';
  static readonly USER_AGENT_WEB: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static readonly USER_AGENT_IOS: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1';
  
  // ==================== 默认设备信息 ====================
  
  static readonly DEFAULT_DEVICE_NAME: string = 'OnePlus';
  static readonly DEFAULT_DEVICE_MODEL: string = 'ONEPLUS A6000';
  static readonly DEFAULT_LOCAL_ID: string = 'c0';
  
  // ==================== API响应码常量 ====================
  
  static readonly RESPONSE_CODE_SUCCESS: number = 0;
  static readonly RESPONSE_CODE_NOT_LOGIN: number = -101;
  static readonly RESPONSE_CODE_NO_PERMISSION: number = -403;
  static readonly RESPONSE_CODE_NOT_FOUND: number = -404;
  static readonly RESPONSE_CODE_SERVER_ERROR: number = -500;
  
  // ==================== 方法：获取画质描述 ====================
  
  static getQualityDescription(qn: number): string {
    switch (qn) {
      case HttpConstants.QUALITY_AUTO:
        return '自动';
      case HttpConstants.QUALITY_360P:
        return '360P';
      case HttpConstants.QUALITY_480P:
        return '480P';
      case HttpConstants.QUALITY_720P:
        return '720P';
      case HttpConstants.QUALITY_720P_60FPS:
        return '720P 60帧';
      case HttpConstants.QUALITY_1080P:
        return '1080P';
      case HttpConstants.QUALITY_1080P_HIGH:
        return '1080P 高码率';
      case HttpConstants.QUALITY_1080P_60FPS:
        return '1080P 60帧';
      case HttpConstants.QUALITY_4K:
        return '4K';
      case HttpConstants.QUALITY_HDR:
        return 'HDR';
      case HttpConstants.QUALITY_DOLBY_VISION:
        return '杜比视界';
      case HttpConstants.QUALITY_8K:
        return '8K';
      default:
        return `未知(${qn})`;
    }
  }
  
  // ==================== 方法：获取格式描述 ====================
  
  static getFormatDescription(fnval: number): string {
    const formats: string[] = [];
    
    if (fnval & HttpConstants.FORMAT_FLV) formats.push('FLV');
    if (fnval & HttpConstants.FORMAT_MP4) formats.push('MP4');
    if (fnval & HttpConstants.FORMAT_DASH) formats.push('DASH');
    if (fnval & HttpConstants.FORMAT_4K) formats.push('4K');
    if (fnval & HttpConstants.FORMAT_HDR) formats.push('HDR');
    if (fnval & HttpConstants.FORMAT_DOLBY_VISION) formats.push('杜比视界');
    if (fnval & HttpConstants.FORMAT_DOLBY_AUDIO) formats.push('杜比音频');
    if (fnval & HttpConstants.FORMAT_8K) formats.push('8K');
    if (fnval & HttpConstants.FORMAT_AV1) formats.push('AV1');
    
    return formats.length > 0 ? formats.join('|') : '未知';
  }
  
  // ==================== 方法：构建完整的API URL ====================
  
  static buildApiUrl(base: string, path: string): string {
    return `${base}${path}`;
  }
  
  // ==================== 方法：获取默认画质列表 ====================
  
  static getDefaultQualityList(): number[] {
    return [
      HttpConstants.QUALITY_1080P_60FPS,
      HttpConstants.QUALITY_1080P,
      HttpConstants.QUALITY_720P,
      HttpConstants.QUALITY_480P,
      HttpConstants.QUALITY_360P
    ];
  }
}