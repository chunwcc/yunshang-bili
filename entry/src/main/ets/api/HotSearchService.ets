import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { HttpConstants } from './HttpConstants';

/**
 * Bilibili 热搜条目
 */
export interface HotSearchItem {
  keyword: string;
  showName: string;
  tagLabel: string;    // word_type 映射的标签文字："新" | "热" | "梗" | "话题" | "独家" | "直播" | ""
  iconUrl: string;     // API 返回的自定义图标 URL（如小绿瓶等促销图片），空字符串表示无图标
  wordType: number;    // B站 API word_type 字段：4=新 5=热 7=直播 8=无标签 9=梗 11=话题 12=独家
  rank: number;
}

/**
 * 获取 Bilibili 热搜关键词（含标签图标）
 * 接口: https://s.search.bilibili.com/main/hotword
 */
export async function fetchHotSearch(): Promise<HotSearchItem[]> {
  const url: string = 'https://s.search.bilibili.com/main/hotword';
  const httpRequest: http.HttpRequest = http.createHttp();
  try {
    const response: http.HttpResponse = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://www.bilibili.com/',
      },
      connectTimeout: 10000,
      readTimeout: 10000
    });
    if (response.responseCode !== 200) {
      logWarn(`热搜 HTTP ${response.responseCode}`);
      return [];
    }
    const result: Record<string, Object> = JSON.parse(response.result as string) as Record<string, Object>;
    const code: number = result['code'] as number;
    if (code !== 0) {
      logWarn(`热搜 code=${code}`);
      return [];
    }
    const list: Object[] = result['list'] as Object[];
    if (!list || list.length === 0) return [];
    const items: HotSearchItem[] = [];
    for (let i: number = 0; i < list.length && i < 15; i++) {
      const item: Record<string, Object> = list[i] as Record<string, Object>;
      const keyword: string = (item['show_name'] || item['keyword']) as string || '';
      if (!keyword) continue;
      const wordType: number = (item['word_type'] as number) || 0;
      // 根据 word_type 映射标签文字（B站 API word_type 字段）
      // 参考 PiliPlus 实现：https://github.com/qinshah/PiliPlus
      const wordTypeLabelMap: Record<number, string> = {
        4: '新',
        5: '热',
        7: '直播',
        8: '',
        9: '梗',
        11: '话题',
        12: '独家',
      };
      const tagLabel: string = wordTypeLabelMap[wordType] ?? '';
      // API 的 icon 字段是自定义图片 URL（如促销活动的小绿瓶图片），保留原始值
      const iconUrl: string = (item['icon'] as string) || '';
      items.push({ keyword, showName: keyword, tagLabel, iconUrl, wordType, rank: i + 1 });
    }
    return items;
  } catch (err) {
    logError(`热搜异常: ${err}`);
    return [];
  } finally {
    httpRequest.destroy();
  }
}

/**
 * 获取 Bilibili 搜索建议（自动补全）
 * 接口: https://s.search.bilibili.com/main/suggest?term={关键词}
 */
export async function fetchSearchSuggestions(term: string): Promise<string[]> {
  const encoded: string = encodeURIComponent(term);
  const url: string = `https://s.search.bilibili.com/main/suggest?term=${encoded}`;
  const httpRequest: http.HttpRequest = http.createHttp();
  try {
    const response: http.HttpResponse = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://www.bilibili.com/',
      },
      connectTimeout: 10000,
      readTimeout: 10000
    });
    if (response.responseCode !== 200) {
      logWarn(`搜索建议 HTTP ${response.responseCode}`);
      return [];
    }
    const result: Record<string, Object> = JSON.parse(response.result as string) as Record<string, Object>;
    const code: number = result['code'] as number;
    if (code !== 0) {
      logWarn(`搜索建议 code=${code}`);
      return [];
    }
    const tagList: Object[] = (result['result'] as Record<string, Object>)?.['tag'] as Object[] || [];
    if (tagList.length === 0) return [];
    const words: string[] = [];
    for (let i: number = 0; i < tagList.length; i++) {
      const item: Record<string, Object> = tagList[i] as Record<string, Object>;
      const value: string = item['value'] as string;
      if (value) words.push(value);
    }
    return words;
  } catch (err) {
    logError(`搜索建议异常: ${err}`);
    return [];
  } finally {
    httpRequest.destroy();
  }
}

/**
 * 搜索发现推荐项
 */
export interface SearchRecommendItem {
  keyword: string;
  showName: string;
  title: string;
  position: number;
  type: string;
}

/**
 * 获取"搜索发现"推荐词（真实API）
 * 接口: https://app.bilibili.com/x/v2/search/recommend
 * 返回 B 站个性化推荐的搜索关键词（猜你想搜）
 */
export async function fetchSearchDiscovery(): Promise<string[]> {
  const url: string = `${HttpConstants.appBaseUrl}${HttpConstants.searchRecommendPath}?platform=android&build=6740300&mobi_app=android`;
  const httpRequest: http.HttpRequest = http.createHttp();
  try {
    const response: http.HttpResponse = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': HttpConstants.USER_AGENT_ANDROID,
        'Referer': 'https://www.bilibili.com/',
      },
      connectTimeout: 10000,
      readTimeout: 10000
    });
    if (response.responseCode !== 200) {
      logWarn(`搜索发现 HTTP ${response.responseCode}`);
      return [];
    }
    const result: Record<string, Object> = JSON.parse(response.result as string) as Record<string, Object>;
    const code: number = result['code'] as number;
    if (code !== 0) {
      logWarn(`搜索发现 code=${code}`);
      return [];
    }
    const data: Record<string, Object> = result['data'] as Record<string, Object>;
    const list: Object[] = data['list'] as Object[] || [];
    if (list.length === 0) return [];
    
    const words: string[] = [];
    for (let i: number = 0; i < list.length; i++) {
      const item: Record<string, Object> = list[i] as Record<string, Object>;
      // 优先用 keyword，其次 show_name，最后 title
      const keyword: string = (item['keyword'] || item['show_name'] || item['title']) as string;
      if (keyword && words.indexOf(keyword) === -1) {
        words.push(keyword);
      }
    }
    return words;
  } catch (err) {
    logError(`搜索发现异常: ${err}`);
    return [];
  } finally {
    httpRequest.destroy();
  }
}

/**
 * 获取"搜索发现"推荐项（完整信息）
 * 返回包含 keyword/showName/title/position/type 的完整对象
 */
export async function fetchSearchRecommendItems(): Promise<SearchRecommendItem[]> {
  const url: string = `${HttpConstants.appBaseUrl}${HttpConstants.searchRecommendPath}?platform=android&build=6740300&mobi_app=android`;
  const httpRequest: http.HttpRequest = http.createHttp();
  try {
    const response: http.HttpResponse = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': HttpConstants.USER_AGENT_ANDROID,
        'Referer': 'https://www.bilibili.com/',
      },
      connectTimeout: 10000,
      readTimeout: 10000
    });
    if (response.responseCode !== 200) {
      logWarn(`搜索发现(完整) HTTP ${response.responseCode}`);
      return [];
    }
    const result: Record<string, Object> = JSON.parse(response.result as string) as Record<string, Object>;
    const code: number = result['code'] as number;
    if (code !== 0) {
      logWarn(`搜索发现(完整) code=${code}`);
      return [];
    }
    const data: Record<string, Object> = result['data'] as Record<string, Object>;
    const list: Object[] = data['list'] as Object[] || [];
    if (list.length === 0) return [];
    
    const items: SearchRecommendItem[] = [];
    for (let i: number = 0; i < list.length; i++) {
      const item: Record<string, Object> = list[i] as Record<string, Object>;
      const kw: string = (item['keyword'] || item['show_name'] || item['title']) as string;
      if (!kw || items.some(existing => existing.keyword === kw)) continue;
      items.push({
        keyword: kw,
        showName: (item['show_name'] || item['title']) as string || kw,
        title: (item['title'] || item['show_name']) as string || kw,
        position: Number(item['position']) || i + 1,
        type: (item['type'] as string) || 'guess',
      });
    }
    return items;
  } catch (err) {
    logError(`搜索发现(完整)异常: ${err}`);
    return [];
  } finally {
    httpRequest.destroy();
  }
}
