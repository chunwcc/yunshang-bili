/**
 * 签名工具类
 * 参考PiliPlus项目的WBI签名和AppSign实现
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { logInfo, logWarn, logError } from './Logger';
import { http } from '@kit.NetworkKit';
import { APP_KEYS } from './AppKeys';

// 类型定义
export interface WbiSignResult {
  w_rid: string;
  wts: string;
}

export interface WbiKeys {
  img_key: string;
  sub_key: string;
}

interface NavWbiImg {
  img_url: string;
  sub_url: string;
}

interface NavData {
  wbi_img: NavWbiImg | null;
}

interface NavResponse {
  code: number;
  data: NavData | null;
}

// 移动端API参数接口
export interface MobileApiParams {
  bvid: string;
  cid: string;
  qn: string;
  fnval: string;
  fourk: string;
  fnver: string;
  platform: string;
  otype: string;
  build: string;
  mobi_app: string;
  device: string;
  ts: string;
  device_name?: string;
  device_model?: string;
  network?: string;
  local_id?: string;
  actionKey?: string;
}

// 参数映射类，用于替代Record<string, string>
class ParamMap {
  private map: Map<string, string> = new Map();

  set(key: string, value: string): void {
    this.map.set(key, value);
  }

  get(key: string): string | undefined {
    return this.map.get(key);
  }

  has(key: string): boolean {
    return this.map.has(key);
  }

  keys(): string[] {
    return Array.from(this.map.keys());
  }

  entries(): [string, string][] {
    return Array.from(this.map.entries());
  }

  toObject(): Record<string, string> {
    const obj: Record<string, string> = {} as Record<string, string>;
    this.map.forEach((value, key) => {
      obj[key] = value;
    });
    return obj;
  }

  static fromObject(obj: Record<string, string>): ParamMap {
    const paramMap = new ParamMap();
    Object.keys(obj).forEach(key => {
      paramMap.set(key, obj[key]);
    });
    return paramMap;
  }
}

/**
 * WBI签名工具类
 * 用于生成B站Web端API的签名
 */
export class WbiSign {
  // WBI签名密钥（从B站前端代码中提取）
  private static readonly MIXIN_KEY_ENC_TAB: number[] = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52
  ];

  /**
   * 获取混合密钥
   */
  private static getMixinKey(orig: string): string {
    let mixed = '';
    for (let i = 0; i < 32; i++) {
      mixed += orig[WbiSign.MIXIN_KEY_ENC_TAB[i]];
    }
    return mixed;
  }

  /**
   * 计算MD5哈希
   */
  static md5(message: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      try {
        const md5Alg = cryptoFramework.createMd('MD5');
        const bytes = new Uint8Array(message.length);
        for (let i = 0; i < message.length; i++) {
          bytes[i] = message.charCodeAt(i);
        }
        const input: cryptoFramework.DataBlob = { data: bytes };
        
        // 先调用update，然后调用digest
        md5Alg.update(input).then(() => {
          return md5Alg.digest();
        }).then((output: cryptoFramework.DataBlob) => {
          // 将字节数组转换为十六进制字符串
          const hexArray: string[] = [];
          for (let i = 0; i < output.data.length; i++) {
            const byte = output.data[i];
            hexArray.push(('0' + (byte & 0xFF).toString(16)).slice(-2));
          }
          resolve(hexArray.join(''));
        }).catch((err: Error) => {
          reject(err);
        });
      } catch (error) {
        reject(error as Error);
      }
    });
  }

  /**
   * 生成WBI签名
   * @param params 请求参数对象
   * @param imgKey img_key
   * @param subKey sub_key
   * @returns 签名结果
   */
  static async sign(params: Record<string, string>, imgKey: string, subKey: string): Promise<WbiSignResult> {
    // 获取混合密钥
    const mixinKey = WbiSign.getMixinKey(imgKey + subKey);
    
    // 生成时间戳
    const wts = Math.floor(Date.now() / 1000).toString();
    
    // 创建包含wts的新参数对象
    const paramsWithWts: Record<string, string> = {} as Record<string, string>;
    const paramKeys = Object.keys(params);
    for (let i = 0; i < paramKeys.length; i++) {
      const key = paramKeys[i];
      paramsWithWts[key as string] = params[key as string];
    }
    paramsWithWts.wts = wts;
    
    // 对参数进行排序
    const sortedKeys = Object.keys(paramsWithWts).sort();
    
    // 构建待签名字符串
    let signStr = '';
    for (let i = 0; i < sortedKeys.length; i++) {
      const key = sortedKeys[i];
      const value = paramsWithWts[key as string];
      signStr += `${key}=${encodeURIComponent(value)}&`;
    }
    signStr = signStr.slice(0, -1); // 移除最后一个&
    
    // 添加混合密钥并计算MD5
    const w_rid = await WbiSign.md5(signStr + mixinKey);
    
    return {
      w_rid: w_rid,
      wts: wts
    };
  }

  // 缓存的WBI密钥及过期时间（密钥有时效性，定期刷新）
  private static cachedKeys: WbiKeys | null = null;
  private static keysFetchTime: number = 0;
  private static readonly KEYS_TTL_MS: number = 3600000; // 1小时有效期

  /**
   * 从B站nav接口动态获取WBI密钥
   * URL示例: https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png
   * 从路径中提取 img_key 和 sub_key
   */
  static async getWbiKeys(): Promise<WbiKeys> {
    // 缓存有效则直接返回
    const now = Date.now();
    if (WbiSign.cachedKeys && (now - WbiSign.keysFetchTime) < WbiSign.KEYS_TTL_MS) {
      return WbiSign.cachedKeys;
    }

    try {
      const httpRequest = http.createHttp();
      const response = await httpRequest.request('https://api.bilibili.com/x/web-interface/nav', {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/'
        } as Record<string, string>,
        connectTimeout: 10000,
        readTimeout: 10000
      });

      if (response.responseCode === 200) {
        const json: NavResponse = JSON.parse(response.result as string) as NavResponse;
        const wbiImg = json.data?.wbi_img;
        if (wbiImg) {
          const imgUrl: string = wbiImg.img_url;
          const subUrl: string = wbiImg.sub_url;
          
          // 从URL路径中提取密钥: /bfs/wbi/xxx.png → xxx
          const imgMatch = imgUrl.match(/\/wbi\/([a-f0-9]+)\./);
          const subMatch = subUrl.match(/\/wbi\/([a-f0-9]+)\./);
          
          if (imgMatch && subMatch) {
            WbiSign.cachedKeys = {
              img_key: imgMatch[1],
              sub_key: subMatch[1]
            } as WbiKeys;
            WbiSign.keysFetchTime = now;
            logInfo(`[WbiSign] 动态获取密钥成功: img_key=${WbiSign.cachedKeys.img_key.substring(0, 8)}...`);
            return WbiSign.cachedKeys;
          }
        }
      }
      
      logWarn('[WbiSign] nav接口获取密钥失败，使用缓存或默认值');
      httpRequest.destroy();
    } catch (e) {
      logError(`[WbiSign] 获取密钥异常: ${e}`);
    }

    // 回退：优先用缓存，其次用硬编码默认值
    if (WbiSign.cachedKeys) {
      return WbiSign.cachedKeys;
    }
    return {
      img_key: '7cd084941338484aae1ad9425b84077c',
      sub_key: '4932caff0ff746eab6f01bf08b70ac45'
    } as WbiKeys;
  }
}

/**
 * AppSign签名工具类
 * 用于生成B站移动端App API的签名
 */
export class AppSign {
  // ⚠️ 密钥已移至 AppKeys.ets（本地文件，不入库）；开源仓库只提供 AppKeys.example.ets

  /**
   * 对参数进行排序并生成签名字符串
   * @param params 参数对象
   * @param appsec app密钥
   * @returns 签名字符串
   */
  static async generateSign(params: Record<string, string>, appsec: string): Promise<string> {
    // 获取所有键并排序
    const keys = Object.keys(params);
    keys.sort();
    
    // 调试：输出排序后的键
    logInfo(`[AppSign] 排序后的键: ${JSON.stringify(keys)}`);
    
    // 构建签名字符串
    let signStr = '';
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value = params[key as string];
      logInfo(`[AppSign] 参数 ${key}=${value}`);
      signStr += `${key}=${value}&`;
    }
    signStr = signStr.slice(0, -1); // 移除最后一个&
    
    // 调试：输出排序后的参数
    logInfo(`[AppSign] 排序后的参数: ${signStr}`);
    
    // 添加appsec并计算MD5
    // B站移动端API签名规则：signStr + appsec（不加&）
    const signRaw = signStr + appsec;
    logInfo(`[AppSign] 签名字符串: ${signRaw}`);
    
    const md5Result = await WbiSign.md5(signRaw);
    logInfo(`[AppSign] MD5结果: ${md5Result}`);
    
    return md5Result;
  }

  /**
   * 生成移动端请求参数
   * @param params 基础参数
   * @param platform 平台类型
   * @returns 完整的请求参数字符串
   */
  static async generateMobileParams(params: MobileApiParams, platform: 'android' | 'ios' | 'web' = 'android'): Promise<string> {
    const appConfig = APP_KEYS[platform];
    if (!appConfig) {
      throw new Error(`不支持的平台: ${platform}`);
    }

    // 构建参数字典
    const paramDict: Record<string, string> = {} as Record<string, string>;
    paramDict.bvid = params.bvid;
    paramDict.cid = params.cid;
    paramDict.qn = params.qn;
    paramDict.fnval = params.fnval;
    paramDict.fourk = params.fourk;
    paramDict.fnver = params.fnver;
    paramDict.platform = params.platform;
    paramDict.otype = params.otype;
    paramDict.build = params.build;
    paramDict.mobi_app = params.mobi_app;
    paramDict.device = params.device;
    paramDict.ts = params.ts;
    paramDict.appkey = appConfig.appkey;

    // 添加可选参数
    if (params.device_name) paramDict.device_name = params.device_name;
    if (params.device_model) paramDict.device_model = params.device_model;
    if (params.network) paramDict.network = params.network;
    if (params.local_id) paramDict.local_id = params.local_id;
    if (params.actionKey) paramDict.actionKey = params.actionKey;

    // 生成签名
    const sign = await AppSign.generateSign(paramDict, appConfig.appsec);
    paramDict.sign = sign;

    // 构建查询字符串
    const queryParts: string[] = [];
    const keys = Object.keys(paramDict);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value = paramDict[key as string];
      queryParts.push(`${key}=${encodeURIComponent(value)}`);
    }

    return queryParts.join('&');
  }

  /**
   * 对参数进行签名（将sign直接写入params对象）
   * 用于TV端等移动端API请求
   * @param params 参数对象（会被修改，增加sign字段）
   * @param platform 平台类型
   */
  static async signParams(params: Record<string, string>, platform: string): Promise<void> {
    const appConfig = APP_KEYS[platform];
    if (!appConfig) {
      // TV端复用android的appkey/appsec
      const fallback = APP_KEYS['android'];
      if (!fallback) {
        throw new Error(`不支持的平台: ${platform}`);
      }
      params['appkey'] = fallback.appkey;
      const sign = await AppSign.generateSign(params, fallback.appsec);
      params['sign'] = sign;
      return;
    }
    params['appkey'] = appConfig.appkey;
    const sign = await AppSign.generateSign(params, appConfig.appsec);
    params['sign'] = sign;
  }

  /**
   * 生成Web端请求参数（使用WBI签名）
   * @param params 基础参数
   * @returns 完整的请求参数字符串
   */
  static async generateWebParams(params: Record<string, string>): Promise<string> {
    // 获取WBI密钥（实际应该从缓存或接口获取）
    const wbiKeys = await WbiSign.getWbiKeys();

    // 生成WBI签名
    const signResult = await WbiSign.sign(params, wbiKeys.img_key, wbiKeys.sub_key);

    // 构建查询字符串
    const queryParts: string[] = [];
    const paramKeys = Object.keys(params);
    for (let i = 0; i < paramKeys.length; i++) {
      const key = paramKeys[i];
      const value = params[key as string];
      queryParts.push(`${key}=${encodeURIComponent(value)}`);
    }
    
    // 添加签名参数
    queryParts.push(`w_rid=${encodeURIComponent(signResult.w_rid)}`);
    queryParts.push(`wts=${encodeURIComponent(signResult.wts)}`);

    return queryParts.join('&');
  }
}

/**
 * 请求工具类
 * 封装带签名的B站API请求
 */
export class BiliRequest {
  // 用户Cookie
  private static cookie: string = '';

  // 设备标识
  private static deviceId: string = '';

  /**
   * 设置Cookie
   */
  static setCookie(cookie: string): void {
    BiliRequest.cookie = cookie;
  }

  /**
   * 设置设备标识
   */
  static setDeviceId(deviceId: string): void {
    BiliRequest.deviceId = deviceId;
  }

  /**
   * 生成设备标识（buvid3）
   */
  static generateBuvid3(): string {
    // 生成一个随机的buvid3
    const chars = '0123456789abcdef';
    let buvid3 = '';
    for (let i = 0; i < 32; i++) {
      buvid3 += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return buvid3;
  }

  /**
   * 获取完整的Cookie头
   */
  static getCookieHeader(): string {
    let cookie = BiliRequest.cookie;

    // 添加设备标识
    if (BiliRequest.deviceId) {
      if (cookie) cookie += '; ';
      cookie += `buvid3=${BiliRequest.deviceId}`;
    }

    return cookie;
  }

  /**
   * 生成Trace ID
   */
  static generateTraceId(): string {
    // 生成一个随机的Trace ID
    const chars = '0123456789abcdef';
    let traceId = '';
    for (let i = 0; i < 32; i++) {
      traceId += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return traceId;
  }

  /**
   * 获取设备ID
   */
  static getDeviceId(): string {
    if (!BiliRequest.deviceId) {
      BiliRequest.deviceId = BiliRequest.generateBuvid3();
    }
    return BiliRequest.deviceId;
  }
}