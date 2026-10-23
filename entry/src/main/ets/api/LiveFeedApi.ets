/**
 * LiveFeedApi.ets — 直播信息流API v2
 * 使用 room/v3/Area/getRoomList 接口（无需登录）
 */
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError } from '../utils/Logger';

// ==================== 接口定义 ====================

/** 直播信息流中的直播间卡片 */
export interface LiveFeedRoom {
  roomId: number;
  uid: number;
  title: string;
  uname: string;
  face: string;
  cover: string;
  online: number;
  areaId: number;
  areaName: string;
  parentAreaId: number;
  parentAreaName: string;
  tagName?: string;
}

/** 直播分区（RoomList 兼容的子分区） */
export interface LiveArea {
  id: number;       // 子分区ID，传 getRoomList 用 (0=全部)
  name: string;     // 显示名称
  parentName: string;
}

// ==================== 常量和请求头 ====================

const LIVE_BASE = 'https://api.live.bilibili.com';

function getHeaders(): Record<string, string> {
  const cookie = AppStorage.get<string>('biliCookie') || '';
  return {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Xiaomi13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36 BiliApp/6770600',
    'Referer': 'https://live.bilibili.com/',
    'Origin': 'https://live.bilibili.com',
    // ⚠️ 游客态也不要写 buvid3=undefined：非法设备指纹会被 WAF 拦（见 BilibiliApi.getCookieHeader）
    'Cookie': cookie || `b_nut=${Math.floor(Date.now() / 1000)}; PVID=1`
  };
}

// ==================== API 方法 ====================

/**
 * 获取直播推荐列表（全部）
 * 使用 room/v3/Area/getRoomList?area_id=0 (无需登录)
 */
export async function fetchRecommendedLiveRooms(
  page: number = 1,
  pageSize: number = 30
): Promise<LiveFeedRoom[]> {
  return fetchLiveRoomsByArea(0, page, pageSize);
}

/**
 * 按子分区获取直播间列表 (room/v3/Area/getRoomList)
 * @param subAreaId 子分区ID（0=全部）
 * @param page 页码
 * @param pageSize 每页数量
 */
export async function fetchLiveRoomsByArea(
  subAreaId: number = 0,
  page: number = 1,
  pageSize: number = 30
): Promise<LiveFeedRoom[]> {
  const httpRequest = http.createHttp();
  try {
    const url = `${LIVE_BASE}/room/v3/Area/getRoomList?area_id=${subAreaId}&page=${page}&page_size=${pageSize}`;
    logInfo(`[LiveFeedApi] 请求直播列表: area_id=${subAreaId}, page=${page}`);

    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: getHeaders(),
      connectTimeout: 10000,
      readTimeout: 10000
    });

    if (response.responseCode !== 200) {
      logWarn(`[LiveFeedApi] HTTP ${response.responseCode}`);
      return [];
    }

    const body = JSON.parse(response.result as string) as Record<string, Object>;
    if (body['code'] !== 0) {
      logWarn(`[LiveFeedApi] API错误: code=${body['code']}, msg=${body['message']}`);
      return [];
    }

    const data = body['data'] as Record<string, Object> || {};
    const rawList = data['list'] as Array<Record<string, Object>> || [];

    return rawList.map((item: Record<string, Object>): LiveFeedRoom => ({
      roomId: Number(item['roomid'] ?? 0),
      uid: Number(item['uid'] ?? 0),
      title: String(item['title'] ?? ''),
      uname: String(item['uname'] ?? ''),
      face: String(item['face'] ?? ''),
      cover: String(item['cover'] ?? item['user_cover'] ?? ''),
      online: Number(item['online'] ?? 0),
      areaId: Number(item['area_id'] ?? item['area_v2_id'] ?? 0),
      areaName: String(item['area_name'] ?? item['area_v2_name'] ?? ''),
      parentAreaId: Number(item['parent_id'] ?? item['area_v2_parent_id'] ?? 0),
      parentAreaName: String(item['parent_name'] ?? item['area_v2_parent_name'] ?? ''),
      tagName: item['tag_name'] ? String(item['tag_name']) : undefined
    }));
  } catch (err) {
    logError(`[LiveFeedApi] 异常: ${err}`);
    return [];
  } finally {
    httpRequest.destroy();
  }
}

/**
 * 获取关注的UP主中正在直播的房间（需要登录 Cookie）
 * 使用 /xlive/web-ucenter/user/following 接口（bilibili-API-collect: follow_up_live.md）
 * 返回 data.list 中 live_status=1（直播中）的房间，按接口顺序排列
 * @param page 页码
 * @param pageSize 每页数量
 */
export async function fetchFollowedLiveRooms(
  page: number = 1,
  pageSize: number = 50
): Promise<LiveFeedRoom[]> {
  const httpRequest = http.createHttp();
  try {
    const url = `${LIVE_BASE}/xlive/web-ucenter/user/following?page=${page}&pageSize=${pageSize}`;
    logInfo(`[LiveFeedApi] 请求关注直播列表: ${url}`);

    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: getHeaders(),
      connectTimeout: 10000,
      readTimeout: 10000
    });

    if (response.responseCode !== 200) {
      logWarn(`[LiveFeedApi] 关注直播HTTP ${response.responseCode}`);
      return [];
    }

    const body = JSON.parse(response.result as string) as Record<string, Object>;
    if (body['code'] !== 0) {
      logWarn(`[LiveFeedApi] 关注直播API错误: code=${body['code']}, msg=${body['message']}`);
      return [];
    }

    const data = body['data'] as Record<string, Object> || {};
    const rawList = data['list'] as Array<Record<string, Object>> || [];
    const rooms: LiveFeedRoom[] = [];

    for (const item of rawList) {
      // live_status: 0=未直播 1=直播中（2=轮播中，也保留展示）
      const liveStatus = Number(item['live_status'] ?? 0);
      if (liveStatus === 0) continue;
      rooms.push({
        roomId: Number(item['roomid'] ?? 0),
        uid: Number(item['uid'] ?? 0),
        title: String(item['title'] ?? ''),
        uname: String(item['uname'] ?? ''),
        face: String(item['face'] ?? ''),
        cover: String(item['room_cover'] ?? item['cover_from_user'] ?? ''),
        // text_small 在该接口中为在线人数字符串（直播中时），解析失败则回退 0
        online: Number(String(item['text_small'] ?? '0').replace(/[^0-9]/g, '')) || 0,
        areaId: Number(item['area_value'] ?? item['area_v2_id'] ?? 0),
        areaName: String(item['area_name_v2'] ?? ''),
        parentAreaId: Number(item['area_v2_parent_id'] ?? 0),
        parentAreaName: String(item['area_v2_parent_name'] ?? ''),
        tagName: String(item['tag_name'] ?? '') || undefined
      });
    }

    logInfo(`[LiveFeedApi] 关注直播中 ${rooms.length} 个`);
    return rooms;
  } catch (err) {
    logError(`[LiveFeedApi] 关注直播异常: ${err}`);
    return [];
  } finally {
    httpRequest.destroy();
  }
}

/**
 * 获取热门子分区列表（用作 Tab 选择）
 * 从 /room/v1/Area/getList 提取前 N 个热门子分区
 */
export async function fetchLiveAreas(): Promise<LiveArea[]> {
  const httpRequest = http.createHttp();
  try {
    const url = `${LIVE_BASE}/room/v1/Area/getList`;
    logInfo(`[LiveFeedApi] 请求分区列表: ${url}`);

    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: getHeaders(),
      connectTimeout: 10000,
      readTimeout: 10000
    });

    if (response.responseCode !== 200) {
      logWarn(`[LiveFeedApi] 分区HTTP ${response.responseCode}`);
      return fallbackAreas();
    }

    const body = JSON.parse(response.result as string) as Record<string, Object>;
    if (body['code'] !== 0) {
      logWarn(`[LiveFeedApi] 分区API错误`);
      return fallbackAreas();
    }

    const rawList = body['data'] as Array<Record<string, Object>> || [];
    const areas: LiveArea[] = [{ id: 0, name: '全部', parentName: '全部' }];
    const seenIds: Set<number> = new Set([0]);

    // 从每个父分区提取前3热门子分区
    for (const parent of rawList) {
      const parentName = String(parent['name'] ?? '');
      const subList = parent['list'] as Array<Record<string, Object>> || [];
      let count = 0;
      for (const sub of subList) {
        if (count >= 3) break;
        const subId = Number(sub['id'] ?? 0);
        const subName = String(sub['name'] ?? '');
        if (subId > 0 && subName && !seenIds.has(subId)) {
          seenIds.add(subId);
          areas.push({ id: subId, name: subName, parentName });
          count++;
        }
      }
    }

    // 如果获取太少，补后备列表
    if (areas.length <= 1) {
      return fallbackAreas();
    }
    return areas;
  } catch (err) {
    logError(`[LiveFeedApi] 分区异常: ${err}`);
    return fallbackAreas();
  } finally {
    httpRequest.destroy();
  }
}

function fallbackAreas(): LiveArea[] {
  return [
    { id: 0, name: '全部', parentName: '全部' },
    { id: 86, name: '英雄联盟', parentName: '网游' },
    { id: 329, name: '无畏契约', parentName: '网游' },
    { id: 240, name: 'APEX英雄', parentName: '网游' },
    { id: 89, name: 'CS2', parentName: '网游' },
    { id: 1, name: '娱乐', parentName: '娱乐' },
    { id: 3, name: '电台', parentName: '电台' }
  ];
}

/**
 * 格式化观看人数（如 1.2万）
 */
export function formatOnlineCount(count: number): string {
  if (count >= 10000) {
    return (count / 10000).toFixed(1) + '万';
  }
  if (count >= 1000) {
    return (count / 1000).toFixed(1) + '千';
  }
  return String(count);
}
