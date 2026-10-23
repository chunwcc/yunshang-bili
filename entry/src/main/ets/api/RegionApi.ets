/**
 * RegionApi.ets — 分类（分区排行榜）API
 *
 * 数据源：/x/web-interface/ranking/v2?rid=X（无需登录）
 * 分区列表为 B 站主分区硬编码（rid 稳定不变）
 */
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { RecommendItem } from '../model/RecommendItem';

// ==================== 接口定义 ====================

/** 分区 Tab */
export interface RegionTab {
  rid: number;
  name: string;
}

/** B 站主分区列表（rid 为官方稳定值） */
export const REGION_TABS: RegionTab[] = [
  { rid: 1, name: '动画' },
  { rid: 3, name: '音乐' },
  { rid: 129, name: '舞蹈' },
  { rid: 4, name: '游戏' },
  { rid: 36, name: '知识' },
  { rid: 188, name: '科技' },
  { rid: 234, name: '运动' },
  { rid: 223, name: '汽车' },
  { rid: 160, name: '生活' },
  { rid: 211, name: '美食' },
  { rid: 217, name: '动物圈' },
  { rid: 119, name: '鬼畜' },
  { rid: 155, name: '时尚' },
  { rid: 202, name: '资讯' },
  { rid: 5, name: '娱乐' },
  { rid: 181, name: '影视' }
];

// ==================== 常量和请求头 ====================

const WEB_BASE = 'https://api.bilibili.com';

function getHeaders(): Record<string, string> {
  const cookie = AppStorage.get<string>('biliCookie') || '';
  return {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Xiaomi13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36 BiliApp/6770600',
    'Referer': 'https://www.bilibili.com/',
    'Origin': 'https://www.bilibili.com',
    // ⚠️ 游客态也不要写 buvid3=undefined：非法设备指纹会被 WAF 拦（见 BilibiliApi.getCookieHeader）
    'Cookie': cookie || `b_nut=${Math.floor(Date.now() / 1000)}; PVID=1`
  };
}

// ==================== API 方法 ====================

/**
 * 获取分区排行榜视频（ranking/v2）
 * @param rid 分区 id（0=全站，其余见 REGION_TABS）
 */
export async function fetchRegionRanking(rid: number = 0): Promise<RecommendItem[]> {
  const httpRequest = http.createHttp();
  try {
    const url = `${WEB_BASE}/x/web-interface/ranking/v2?rid=${rid}&type=all`;
    logInfo(`[RegionApi] 请求分区排行: rid=${rid}`);

    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: getHeaders(),
      connectTimeout: 10000,
      readTimeout: 10000
    });

    if (response.responseCode !== 200) {
      logWarn(`[RegionApi] HTTP ${response.responseCode}`);
      return [];
    }

    const body = JSON.parse(response.result as string) as Record<string, Object>;
    if (body['code'] !== 0) {
      logWarn(`[RegionApi] API错误: code=${body['code']}, msg=${body['message']}`);
      return [];
    }

    const data = body['data'] as Record<string, Object> || {};
    const rawList = data['list'] as Array<Record<string, Object>> || [];

    return rawList.map((item: Record<string, Object>): RecommendItem => {
      const rec = new RecommendItem();
      rec.id = (item['bvid'] as string) || '';
      rec.aid = Number(item['aid'] ?? 0);
      rec.title = (item['title'] as string) || '';
      const pic = item['pic'] as string;
      rec.coverUrl = pic ? (pic.startsWith('http') ? pic : `https:${pic}`) : '';
      rec.duration = Number(item['duration'] ?? 0);
      rec.pubdate = Number(item['pubdate'] ?? 0);

      const stat = item['stat'] as Record<string, number> || {};
      rec.playCount = stat['view'] || 0;
      rec.danmakuCount = stat['danmaku'] || 0;
      rec.likeCount = stat['like'] || 0;

      const owner = item['owner'] as Record<string, Object> || {};
      rec.ownerName = (owner['name'] as string) || '';
      rec.ownerFace = (owner['face'] as string) || '';
      rec.ownerMid = owner['mid'] ? String(owner['mid']) : '';

      return rec;
    });
  } catch (err) {
    logError(`[RegionApi] 异常: ${err}`);
    return [];
  } finally {
    httpRequest.destroy();
  }
}
