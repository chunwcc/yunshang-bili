/**
 * ⭐ 真正的 App 端推荐 API 实现
 * 
 * 对应 PiliPlus 的 rcmdVideoListApp() 方法
 * - API 端点: https://app.bilibili.com/x/v2/feed/index
 * - 签名方式: appkey + appsec MD5（非 WBI）
 * - 返回内容和官方 App 完全一致（含竖屏视频/Story）
 */
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';
import { RecommendItem } from '../model/RecommendItem';
import { WbiSign } from '../utils/SignUtils';
import { APP_KEYS } from '../utils/AppKeys';

// ========== 辅助函数 ==========

/** 从 Cookie 中提取 DedeUserID（用户身份标识） */
function getBiliMid(cookie: string): string {
  if (!cookie) return '0';
  const match = cookie.match(/DedeUserID=(\d+)/);
  return match && match[1] ? match[1] : '0';
}

// ========== App 签名常量 ==========

/** android_hd 的 appkey / appsec（从本地密钥文件读取，不硬编码） */
const APP_KEY = APP_KEYS['android_hd'].appkey;
const APP_SEC = APP_KEYS['android_hd'].appsec;

/**
 * ⭐ 计算 App API 签名（与 PiliPlus AppSign.appSign 保持一致）
 * 
 * B站 App API 签名规则：
 * 1. 所有参数（含 appkey, ts）按 key 字典序排序
 * 2. 每个 key 和 value 分别 URL 编码
 * 3. 拼接成 key=value&key=value...
 * 4. 末尾拼接 appsec
 * 5. 取 MD5
 */
async function computeAppSign(params: Record<string, string>): Promise<void> {
  // 1. 添加 appkey 和时间戳（必须在签名前加入）
  params['appkey'] = APP_KEY;
  params['ts'] = Math.floor(Date.now() / 1000).toString();

  // 2. 按 key 字典序排序
  const keys = Object.keys(params);
  keys.sort();

  // 3. URL 编码后拼接（匹配 PiliPlus _makeQueryFromParametersDefault）
  //    ⚠️ 关键：PiliPlus 对空值不写 =，只写 key
  let signStr = '';
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const value = params[key as string];
    // 跳过 sign 自身（如果存在）
    if (key === 'sign') {
      continue;
    }
    // PiliPlus 风格：值非空才写 =value，空值只写 key
    if (value !== undefined && value !== '') {
      signStr += `${encodeURIComponent(key)}=${encodeURIComponent(value)}&`;
    } else {
      signStr += `${encodeURIComponent(key)}&`;
    }
  }
  // 去掉末尾 &
  signStr = signStr.slice(0, -1);

  // 4. 拼接 appsec 并 MD5
  const md5Input = signStr + APP_SEC;
  const sign = await WbiSign.md5(md5Input);

  // 5. 将 sign 加入参数
  params['sign'] = sign;
}

// ========== 设备指纹管理 ==========

/**
 * 生成符合B站规范的buvid3
 */
function generateBuvid3(): string {
  let stored = AppStorage.get<string>('buvid3');
  if (stored) return stored;

  const chars = '0123456789abcdef';
  let id = 'XY';
  for (let i = 0; i < 30; i++) {
    id += chars.charAt(Math.floor(Math.random() * chars.length));
  }

  AppStorage.setOrCreate('buvid3', id);
  return id;
}

/**
 * 生成Trace ID
 */
function generateTraceId(): string {
  const timestamp = Date.now().toString(16);
  const random = Math.random().toString(16).substring(2, 10);
  return `${timestamp}:${random}:0:0`;
}

// ========== 响应类型定义 ==========

interface AppApiResponse {
  code: number;
  message?: string;
  data?: AppApiData;
}

interface AppApiData {
  items?: Array<Record<string, Object>>;
}

// ========== 主函数 ==========

/**
 * ⭐ 获取推荐视频列表（真正的 App 端 API）
 * 
 * 对应 PiliPlus VideoHttp.rcmdVideoListApp()
 * 使用 https://app.bilibili.com/x/v2/feed/index 端点
 * 以 android_hd 身份请求，签名方式为 appkey + appsec MD5
 * 
 * @param freshIdx 刷新索引（从 0 开始）
 * @param pageSize 每页数量（App API 通常固定为 4 的倍数）
 */
export async function getRecommendVideosOptimized(
  freshIdx: number,
  pageSize: number = 30
): Promise<RecommendItem[]> {
  const buvid = generateBuvid3();

  try {
    // ⭐ 1. 构建 App API 参数（与 PiliPlus 一致）
    //    ⚠️ 注意：HomePage 的 refreshIdx 从 2 开始（初始 1, 在 refreshData 中 ++ 后变成 2）
    //    所以这里映射: appIdx = freshIdx - 2, 且仅在 appIdx===0 时 pull=true
    const appIdx: number = freshIdx > 2 ? freshIdx - 2 : 0;
    const params: Record<string, string> = {};

    params['build'] = '2001100';
    params['c_locale'] = 'zh_CN';
    params['channel'] = 'master';
    params['column'] = '4';    // 网格列数，必须为 4（非页面大小）
    params['device'] = 'pad';
    params['device_name'] = 'android';
    params['device_type'] = '0';
    params['disable_rcmd'] = '0';
    params['flush'] = '5';
    params['fnval'] = '976';
    params['fnver'] = '0';
    params['force_host'] = '2';
    params['fourk'] = '1';
    params['guidance'] = '0';
    params['https_url_req'] = '0';
    params['idx'] = appIdx.toString();
    params['mobi_app'] = 'android_hd';
    params['network'] = 'wifi';
    params['platform'] = 'android';
    params['player_net'] = '1';
    params['pull'] = appIdx === 0 ? 'true' : 'false';
    params['qn'] = '32';
    params['recsys_mode'] = '0';
    params['s_locale'] = 'zh_CN';
    params['splash_id'] = '';
    params['statistics'] = '{"appId":5,"platform":3,"version":"2.0.1","abtest":""}';
    params['voice_balance'] = '0';

    // ⭐ 如果已登录，加入 access_key
    const accessKey = AppStorage.get<string>('biliAccessKey') || '';
    if (accessKey) {
      params['access_key'] = accessKey;
    }

    // ⭐ 2. App 签名（appkey + ts + sign，URL-encoded values matching PiliPlus）
    await computeAppSign(params);

    // ⭐ 3. 构建最终 URL（URL-encode 与签名一致）
    const queryParts: string[] = [];
    const paramKeys = Object.keys(params);
    for (let i = 0; i < paramKeys.length; i++) {
      const key = paramKeys[i];
      const value = params[key as string];
      // 与签名逻辑一致：空值不写 =
      if (value !== undefined && value !== '') {
        queryParts.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
      } else {
        queryParts.push(`${encodeURIComponent(key)}`);
      }
    }
    const url = `https://app.bilibili.com/x/v2/feed/index?${queryParts.join('&')}`;

    logInfo(`[App推荐] fresh_idx=${freshIdx}, 已登录=${!!accessKey}`);
    logInfo(`[App推荐] URL长度=${url.length}`);

    // ⭐ 4. 设置请求头
    const headers: Record<string, string> = {
      'User-Agent': 'Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android model/android_hd mobi_app/android_hd build/2001100 channel/master innerVer/2001100 osVer/15 network/2',
      'Referer': 'https://www.bilibili.com/',
      'buvid': buvid,
      'fp_local': '1111111111111111111111111111111111111111111111111111111111111111',
      'fp_remote': '1111111111111111111111111111111111111111111111111111111111111111',
      'session_id': '11111111',
      'env': 'prod',
      'app-key': 'android64',
      'x-bili-trace-id': generateTraceId(),
      'x-bili-aurora-eid': '',
      'x-bili-aurora-zone': 'sh001',
      'bili-http-engine': 'cronet',
      // ⭐ 添加用户身份标识（个性化推荐必需）
      'Cookie': AppStorage.get<string>('biliCookie') || '',
      'X-Bili-Mid': getBiliMid(AppStorage.get<string>('biliCookie') || '')
    };

    // ⭐ 5. 发起请求
    const httpRequest = http.createHttp();
    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: 10000,
      readTimeout: 15000
    });

    httpRequest.destroy();

    if (response.responseCode !== 200) {
      logWarn(`[App推荐] HTTP错误: ${response.responseCode}`);
      return [];
    }

    const jsonData: AppApiResponse = JSON.parse(response.result as string);
    if (jsonData.code !== 0) {
      logWarn(`[App推荐] API错误: code=${jsonData.code}, message=${jsonData.message}`);
      // 如果因为签名等问题失败，降级返回空，让上层使用 Web API
      return [];
    }

    const items = jsonData.data?.items;
    if (!items || items.length === 0) {
      logWarn('[App推荐] 返回数据为空');
      return [];
    }

    // ⭐ 6. 解析和过滤
    const blockedUploaders = AppStorage.get<Set<string>>('blockedUploaders') || new Set<string>();
    const result: RecommendItem[] = [];

    for (let i = 0; i < items.length; i++) {
      const item = items[i];

      // 过滤广告
      const cardGoto = (item['card_goto'] as string) || '';
      if (cardGoto === 'ad_av' || cardGoto === 'ad_web_s' || item['ad_info'] !== undefined) {
        continue;
      }

      // 过滤屏蔽的 UP 主
      const args = item['args'] as Record<string, Object>;
      if (args) {
        const upId = (args['up_id'] as number) || 0;
        if (upId > 0 && blockedUploaders.has(upId.toString())) {
          continue;
        }
      }

      // 解析为 RecommendItem
      const recommendItem = RecommendItem.fromAppApi(item);
      if (recommendItem.id) {
        result.push(recommendItem);
      }
    }

    logInfo(`[App推荐] 返回 ${result.length} 条数据（原始 ${items.length} 条）`);

    // ⭐ 7. 记录最后一个视频ID，用于下次推荐
    if (result.length > 0) {
      const lastItem = result[result.length - 1];
      AppStorage.setOrCreate('lastRecommendVideoId', lastItem.id);
    }

    return result;

  } catch (err) {
    logError(`[App推荐] 请求异常: ${errMsg(err)}`);
    return [];
  }
}

/**
 * 重置推荐会话
 */
export function resetRecommendSession(): void {
  AppStorage.setOrCreate('recommend_session_id', '');
  AppStorage.setOrCreate('lastRecommendVideoId', '');
  logInfo('[App推荐] 会话已重置');
}
