// FavoritesApi.ets - 收藏夹相关 API（独立文件，避免 BilibiliApi.ets 过大导致解析问题）
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { extractMidFromCookie, extractCsrfFromCookie } from './FeedbackService';

// ========== 收藏夹相关类型定义 ==========

/** 收藏夹上的计数信息 */
export interface FavCntInfo {
  play: number;
  danmaku: number;
}

/** 收藏夹文件夹 */
export interface FavFolderItem {
  id: number;
  title: string;
  cover?: string;
  covers?: string[];
  media_count: number;
}

/** 收藏夹内的资源（视频） */
export interface FavResourceItem {
  id: number;
  bvid: string;
  title: string;
  cover: string;
  duration: number;
  cnt_info?: FavCntInfo;
}

// ========== 局部类型/工具 ==========

interface ApiResponse<T> {
  code: number;
  message?: string;
  data?: T;
}

function getCookieHeader(): string {
  const cookie = AppStorage.get<string>('biliCookie') ?? '';
  return cookie;
}

// ========== 响应类型 ==========

interface FavFolderListResponse {
  count: number;
  list: FavFolderItem[];
}

interface FavResourceListResponse {
  info: FavFolderItem;
  medias: FavResourceItem[];
  has_more: boolean;
}

// ========== API 函数 ==========

/**
 * 获取用户创建的收藏夹列表
 * @param upMid 用户 mid
 * @param page 页码（从1开始）
 * @param pageSize 每页数量（默认20）
 */
export async function getCreatedFavFolders(upMid: number, page: number = 1, pageSize: number = 20): Promise<FavFolderItem[] | null> {
  const cookie = getCookieHeader();
  const url = `https://api.bilibili.com/x/v3/fav/folder/created/list?pn=${page}&ps=${pageSize}&up_mid=${upMid}`;
  const headers: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36',
    'Referer': 'https://www.bilibili.com/',
    'Cookie': cookie,
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
  };

  try {
    const httpRequest = http.createHttp();
    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: 10000,
      readTimeout: 10000
    });
    httpRequest.destroy();

    if (response.responseCode === 200) {
      const json = JSON.parse(response.result as string) as ApiResponse<FavFolderListResponse>;
      if (json.code === 0 && json.data) {
        return json.data.list as FavFolderItem[];
      }
      logWarn(`[getCreatedFavFolders] API错误: code=${json.code}, msg=${json.message}`);
    }
    return null;
  } catch (err) {
    logError(`[getCreatedFavFolders] 异常: ${err}`);
    return null;
  }
}

/**
 * 获取用户订阅的收藏夹列表
 */
export async function getCollectedFavFolders(page: number = 1, pageSize: number = 20): Promise<FavFolderItem[] | null> {
  const cookie = getCookieHeader();
  const url = `https://api.bilibili.com/x/v3/fav/folder/collected/list?pn=${page}&ps=${pageSize}`;
  const headers: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36',
    'Referer': 'https://www.bilibili.com/',
    'Cookie': cookie,
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
  };

  try {
    const httpRequest = http.createHttp();
    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: 10000,
      readTimeout: 10000
    });
    httpRequest.destroy();

    if (response.responseCode === 200) {
      const json = JSON.parse(response.result as string) as ApiResponse<FavFolderListResponse>;
      if (json.code === 0 && json.data) {
        return json.data.list as FavFolderItem[];
      }
      logWarn(`[getCollectedFavFolders] API错误: code=${json.code}, msg=${json.message}`);
    }
    return null;
  } catch (err) {
    logError(`[getCollectedFavFolders] 异常: ${err}`);
    return null;
  }
}

/**
 * 获取收藏夹信息
 */
export async function getFavFolderInfo(mediaId: number): Promise<FavFolderItem | null> {
  const cookie = getCookieHeader();
  const url = `https://api.bilibili.com/x/v3/fav/folder/info?media_id=${mediaId}`;
  const headers: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36',
    'Referer': 'https://www.bilibili.com/',
    'Cookie': cookie,
    'Accept': 'application/json, text/plain, */*'
  };

  try {
    const httpRequest = http.createHttp();
    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: 10000,
      readTimeout: 10000
    });
    httpRequest.destroy();

    if (response.responseCode === 200) {
      const json = JSON.parse(response.result as string) as ApiResponse<FavFolderItem>;
      if (json.code === 0 && json.data) {
        return json.data as FavFolderItem;
      }
    }
    return null;
  } catch (err) {
    logError(`[getFavFolderInfo] 异常: ${err}`);
    return null;
  }
}

/**
 * 获取收藏夹内的资源列表（视频/番剧等）
 * @param mediaId 收藏夹 mlid
 * @param page 页码（从1开始）
 * @param pageSize 每页数量（默认20）
 * @param order 排序方式：mtime=最近收藏, view=最多播放, pubtime=最近投稿
 * @param keyword 搜索关键词（可选）
 */
export async function getFavFolderResources(mediaId: number, page: number = 1, pageSize: number = 20, order: string = 'mtime', keyword: string = ''): Promise<FavResourceListResponse | null> {
  const cookie = getCookieHeader();
  let url = `https://api.bilibili.com/x/v3/fav/resource/list?media_id=${mediaId}&pn=${page}&ps=${pageSize}&order=${order}&type=0&platform=web`;
  if (keyword) {
    url += `&keyword=${encodeURIComponent(keyword)}`;
  }
  const headers: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36',
    'Referer': 'https://www.bilibili.com/',
    'Cookie': cookie,
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
  };

  try {
    const httpRequest = http.createHttp();
    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: 10000,
      readTimeout: 15000
    });
    httpRequest.destroy();

    if (response.responseCode === 200) {
      const json = JSON.parse(response.result as string) as ApiResponse<FavResourceListResponse>;
      if (json.code === 0 && json.data) {
        return json.data as FavResourceListResponse;
      }
      logWarn(`[getFavFolderResources] API错误: code=${json.code}, msg=${json.message}`);
    }
    return null;
  } catch (err) {
    logError(`[getFavFolderResources] 异常: ${err}`);
    return null;
  }
}

/**
 * 批量操作收藏夹资源（收藏/取消收藏）
 * @param rid 资源 ID（视频为 aid）
 * @param type 资源类型（2=视频）
 * @param addMediaIds 要加入的收藏夹 mlid 列表（多个用逗号分隔）
 * @param delMediaIds 要移除的收藏夹 mlid 列表（多个用逗号分隔）
 */
export async function batchDealFavResource(rid: number, type: number = 2, addMediaIds?: string, delMediaIds?: string): Promise<boolean> {
  const cookie = getCookieHeader();
  const csrf = extractCsrfFromCookie(cookie);
  const mid = extractMidFromCookie(cookie);
  if (!csrf || mid === '0') {
    logWarn('[batchDealFavResource] 未登录');
    return false;
  }

  let formData = `rid=${rid}&type=${type}&csrf=${csrf}`;
  if (addMediaIds) {
    formData += `&add_media_ids=${addMediaIds}`;
  }
  if (delMediaIds) {
    formData += `&del_media_ids=${delMediaIds}`;
  }

  const headers: Record<string, string> = {
    'Content-Type': 'application/x-www-form-urlencoded',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36',
    'Referer': 'https://www.bilibili.com/',
    'Cookie': cookie,
    'X-Bili-Mid': mid
  };

  try {
    const httpRequest = http.createHttp();
    const response = await httpRequest.request('https://api.bilibili.com/x/v3/fav/resource/batch-deal', {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: formData,
      connectTimeout: 10000,
      readTimeout: 10000
    });
    httpRequest.destroy();

    if (response.responseCode === 200) {
      const json = JSON.parse(response.result as string) as ApiResponse<null>;
      if (json.code === 0) {
        logInfo(`[batchDealFavResource] 操作成功: rid=${rid}, add=${addMediaIds}, del=${delMediaIds}`);
        return true;
      }
      logWarn(`[batchDealFavResource] API错误: code=${json.code}, msg=${json.message}`);
    }
    return false;
  } catch (err) {
    logError(`[batchDealFavResource] 异常: ${err}`);
    return false;
  }
}

/**
 * 格式化的时长（秒→mm:ss）
 */
export function formatDuration(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${s.toString().padStart(2, '0')}`;
}

/**
 * 格式化数字（万单位）
 */
export function formatCount(count: number): string {
  if (count >= 10000) {
    return (count / 10000).toFixed(1) + '万';
  }
  return String(count);
}
