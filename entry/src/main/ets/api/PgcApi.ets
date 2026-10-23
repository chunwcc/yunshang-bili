/**
 * PgcApi.ets — 番剧/影视（PGC）信息流 API
 *
 * 数据源：/pgc/season/index/result（无需登录）
 * - season_type=1 番剧（含国创）
 * - season_type=2 影视（电影/电视剧/纪录片）
 * - type=1 综合排序
 */
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError } from '../utils/Logger';

// ==================== 接口定义 ====================

/** 番剧/影视季卡片 */
export interface PgcSeason {
  seasonId: number;    // 季 id（/pgc/view/web/season 使用）
  mediaId: number;     // 媒资 id
  title: string;
  subTitle: string;    // 副标题（如「羁绊连结，传承信念」）
  cover: string;
  score: string;       // 评分字符串（"9.7"，无评分时为空）
  indexShow: string;   // 集数/上映信息（"全8话"、"2022年6月30日上映"）
  badge: string;       // 角标（"独家"/"大会员"/""）
  seasonType: number;  // 1=番剧 2=影视
  isFinish: number;    // 是否完结
  epId: number;        // 最新分集 ep_id（first_ep）
}

/** 索引筛选条件的单个选项值（如年份「2025」、地区「日本」） */
export interface PgcIndexValue {
  keyword: string;     // 提交给接口的参数值
  name: string;        // 展示名
}

/** 索引筛选维度（如 年份/地区/类型），每个维度一组选项 */
export interface PgcIndexFilter {
  field: string;       // 参数名（如 year、area、season_type）
  name: string;        // 维度名（如「年份」「地区」）
  values: PgcIndexValue[];
}

/** 索引排序项（如 综合/最新/评分） */
export interface PgcIndexOrder {
  field: string;       // 参数名（如 order）
  name: string;        // 排序名（如「综合排序」「最新发布」）
  sort: string;        // 排序值
}

/** 索引条件接口返回 */
export interface PgcIndexCondition {
  filter: PgcIndexFilter[];
  order: PgcIndexOrder[];
}

// ==================== 常量和请求头 ====================

const PGC_BASE = 'https://api.bilibili.com';

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
 * 获取番剧索引的筛选条件（动态维度 + 排序）
 * 接口：/pgc/season/index/condition（无需登录）
 * @param seasonType 1=番剧（含国创） 2=影视（电影/电视剧/纪录片）
 * @returns 筛选条件（filter 维度组 + order 排序项），失败返回空结构
 */
export async function fetchPgcIndexCondition(
  seasonType: number = 1
): Promise<PgcIndexCondition> {
  const httpRequest = http.createHttp();
  try {
    const url = `${PGC_BASE}/pgc/season/index/condition?season_type=${seasonType}&type=0`;
    logInfo(`[PgcApi] 请求番剧索引条件: ${url}`);

    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: getHeaders(),
      connectTimeout: 10000,
      readTimeout: 10000
    });

    if (response.responseCode !== 200) {
      logWarn(`[PgcApi] 索引条件HTTP ${response.responseCode}`);
      return { filter: [], order: [] };
    }

    const body = JSON.parse(response.result as string) as Record<string, Object>;
    if (body['code'] !== 0) {
      logWarn(`[PgcApi] 索引条件API错误: code=${body['code']}, msg=${body['message']}`);
      return { filter: [], order: [] };
    }

    const data = body['data'] as Record<string, Object> || {};
    const rawFilter = data['filter'] as Array<Record<string, Object>> || [];
    const rawOrder = data['order'] as Array<Record<string, Object>> || [];

    const filter: PgcIndexFilter[] = rawFilter.map((f: Record<string, Object>): PgcIndexFilter => {
      const rawValues = f['values'] as Array<Record<string, Object>> || [];
      return {
        field: String(f['field'] ?? ''),
        name: String(f['name'] ?? ''),
        values: rawValues.map((v: Record<string, Object>): PgcIndexValue => ({
          keyword: String(v['keyword'] ?? ''),
          name: String(v['name'] ?? '')
        }))
      };
    }).filter((f: PgcIndexFilter) => f.field.length > 0 && f.values.length > 0);

    const order: PgcIndexOrder[] = rawOrder.map((o: Record<string, Object>): PgcIndexOrder => ({
      field: String(o['field'] ?? ''),
      name: String(o['name'] ?? ''),
      sort: String(o['sort'] ?? '')
    })).filter((o: PgcIndexOrder) => o.field.length > 0);

    logInfo(`[PgcApi] 索引条件: ${filter.length} 个维度, ${order.length} 个排序`);
    return { filter, order };
  } catch (err) {
    logError(`[PgcApi] 索引条件异常: ${err}`);
    return { filter: [], order: [] };
  } finally {
    httpRequest.destroy();
  }
}

/**
 * 获取番剧/影视列表
 * @param seasonType 1=番剧（含国创） 2=影视（电影/电视剧/纪录片）
 * @param page 页码（从1开始）
 * @param pageSize 每页数量（默认20）
 */
export async function fetchPgcSeasons(
  seasonType: number = 1,
  page: number = 1,
  pageSize: number = 20
): Promise<PgcSeason[]> {
  return fetchPgcSeasonsByParams(seasonType, page, pageSize, {});
}

/**
 * 按筛选参数获取番剧/影视列表（番剧索引页使用）
 * @param seasonType 1=番剧（含国创） 2=影视（电影/电视剧/纪录片）
 * @param page 页码（从1开始）
 * @param pageSize 每页数量（默认20）
 * @param params 额外筛选参数（如 order、year、area、type 等，来自索引条件接口）
 */
export async function fetchPgcSeasonsByParams(
  seasonType: number = 1,
  page: number = 1,
  pageSize: number = 20,
  params: Record<string, string> = {}
): Promise<PgcSeason[]> {
  const httpRequest = http.createHttp();
  try {
    // ⭐ 索引模式用 type=0（综合），配合各维度筛选参数
    let url = `${PGC_BASE}/pgc/season/index/result?season_type=${seasonType}&page=${page}&pagesize=${pageSize}&type=0`;
    const keys: string[] = Object.keys(params);
    for (const key of keys) {
      const val: string = params[key];
      if (val && val.length > 0) {
        url += `&${key}=${encodeURIComponent(val)}`;
      }
    }
    logInfo(`[PgcApi] 请求番剧索引列表: season_type=${seasonType}, page=${page}`);

    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: getHeaders(),
      connectTimeout: 10000,
      readTimeout: 10000
    });

    if (response.responseCode !== 200) {
      logWarn(`[PgcApi] HTTP ${response.responseCode}`);
      return [];
    }

    const body = JSON.parse(response.result as string) as Record<string, Object>;
    if (body['code'] !== 0) {
      logWarn(`[PgcApi] API错误: code=${body['code']}, msg=${body['message']}`);
      return [];
    }

    const data = body['data'] as Record<string, Object> || {};
    const rawList = data['list'] as Array<Record<string, Object>> || [];

    return rawList.map((item: Record<string, Object>): PgcSeason => {
      const firstEp = item['first_ep'] as Record<string, Object> || {};
      const cover = String(item['cover'] ?? '');
      return {
        seasonId: Number(item['season_id'] ?? 0),
        mediaId: Number(item['media_id'] ?? 0),
        title: String(item['title'] ?? ''),
        subTitle: String(item['subTitle'] ?? ''),
        cover: cover.startsWith('http') ? cover : `https:${cover}`,
        score: String(item['score'] ?? ''),
        indexShow: String(item['index_show'] ?? ''),
        badge: String(item['badge'] ?? ''),
        seasonType: Number(item['season_type'] ?? seasonType),
        isFinish: Number(item['is_finish'] ?? 0),
        epId: Number(firstEp['ep_id'] ?? 0)
      };
    });
  } catch (err) {
    logError(`[PgcApi] 异常: ${err}`);
    return [];
  } finally {
    httpRequest.destroy();
  }
}
