import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'BiliLinkParser';

export class BiliLinkResult {
  page: string = '';
  params: Record<string, Object> = {};

  constructor(page: string, params: Record<string, Object>) {
    this.page = page;
    this.params = params;
  }
}

export class BiliLinkParser {
  static parse(uri: string): BiliLinkResult | null {
    if (!uri || uri.length === 0) {
      return null;
    }

    try {
      if (uri.startsWith('bilibili://')) {
        return BiliLinkParser.parseBilibiliScheme(uri);
      } else if (uri.startsWith('http://') || uri.startsWith('https://')) {
        return BiliLinkParser.parseHttpUrl(uri);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'parse error: %{public}s, uri: %{public}s', JSON.stringify(e), uri);
    }

    return null;
  }

  private static parseBilibiliScheme(uri: string): BiliLinkResult | null {
    const pathPart = uri.substring('bilibili://'.length);
    const slashIdx = pathPart.indexOf('/');
    const host = slashIdx > 0 ? pathPart.substring(0, slashIdx) : pathPart;
    const rest = slashIdx > 0 ? pathPart.substring(slashIdx + 1) : '';
    const queryIdx = rest.indexOf('?');
    const pathBody = queryIdx > 0 ? rest.substring(0, queryIdx) : rest;
    const queryStr = queryIdx > 0 ? rest.substring(queryIdx + 1) : '';
    const queryParams = BiliLinkParser.parseQuery(queryStr);

    switch (host) {
      case 'video': {
        const aid = parseInt(pathBody, 10);
        if (aid > 0) {
          const params: Record<string, Object> = {};
          params['aid'] = aid;
          if (queryParams['page']) {
            params['page'] = queryParams['page'];
          }
          return new BiliLinkResult('pages/VideoPlayerPage', params);
        }
        break;
      }
      case 'pgc':
      case 'bangumi': {
        if (pathBody.startsWith('season/ep/')) {
          const epId = parseInt(pathBody.substring('season/ep/'.length), 10);
          if (epId > 0) {
            const params: Record<string, Object> = {};
            params['epId'] = epId;
            return new BiliLinkResult('pages/VideoPlayerPage', params);
          }
        } else if (pathBody.startsWith('season/')) {
          const seasonId = parseInt(pathBody.substring('season/'.length), 10);
          if (seasonId > 0) {
            const params: Record<string, Object> = {};
            params['seasonId'] = seasonId;
            return new BiliLinkResult('pages/VideoPlayerPage', params);
          }
        } else if (pathBody.startsWith('ep/')) {
          const epId = parseInt(pathBody.substring('ep/'.length), 10);
          if (epId > 0) {
            const params: Record<string, Object> = {};
            params['epId'] = epId;
            return new BiliLinkResult('pages/VideoPlayerPage', params);
          }
        }
        break;
      }
      case 'live': {
        const roomId = parseInt(pathBody, 10);
        if (roomId > 0) {
          const params: Record<string, Object> = {};
          params['roomId'] = roomId;
          return new BiliLinkResult('pages/LivePage', params);
        }
        break;
      }
      case 'space': {
        const mid = parseInt(pathBody, 10);
        if (mid > 0) {
          const params: Record<string, Object> = {};
          params['mid'] = mid;
          return new BiliLinkResult('pages/UpSpacePage', params);
        }
        break;
      }
      case 'search': {
        const keyword = queryParams['keyword'] as string;
        if (keyword) {
          const params: Record<string, Object> = {};
          params['keyword'] = keyword;
          return new BiliLinkResult('pages/SearchPage', params);
        }
        break;
      }
      case 'article': {
        const articleId = parseInt(pathBody, 10);
        if (articleId > 0) {
          const params: Record<string, Object> = {};
          params['articleId'] = articleId;
          return new BiliLinkResult('pages/ArticlePage', params);
        }
        break;
      }
      case 'root':
      case 'history':
      case 'rank':
      case 'following': {
        return new BiliLinkResult('pages/Index', {});
      }
      default:
        break;
    }

    hilog.info(DOMAIN, TAG, 'unhandled bilibili scheme: host=%{public}s, path=%{public}s', host, pathBody);
    return null;
  }

  private static parseHttpUrl(url: string): BiliLinkResult | null {
    const schemeEnd = url.indexOf('://');
    if (schemeEnd < 0) {
      return null;
    }
    const afterScheme = url.substring(schemeEnd + 3);
    const slashIdx = afterScheme.indexOf('/');
    const hostPart = slashIdx > 0 ? afterScheme.substring(0, slashIdx) : afterScheme;
    const pathPart = slashIdx > 0 ? afterScheme.substring(slashIdx) : '';
    const queryIdx = pathPart.indexOf('?');
    const pathname = queryIdx > 0 ? pathPart.substring(0, queryIdx) : pathPart;
    const queryStr = queryIdx > 0 ? pathPart.substring(queryIdx + 1) : '';
    const queryParams = BiliLinkParser.parseQuery(queryStr);

    if (hostPart === 'b23.tv') {
      const params: Record<string, Object> = {};
      params['url'] = url;
      return new BiliLinkResult('__shortlink__', params);
    }

    if (hostPart.endsWith('bilibili.com') || hostPart.endsWith('bilibili.cn') || hostPart.endsWith('bilibili.tv')) {
      if (pathname.startsWith('/video/')) {
        const seg = pathname.substring('/video/'.length);
        if (seg.startsWith('BV') || seg.startsWith('bv')) {
          const bvid = seg.split('/')[0];
          const params: Record<string, Object> = {};
          params['bvid'] = bvid;
          return new BiliLinkResult('pages/VideoPlayerPage', params);
        } else if (seg.startsWith('av') || seg.startsWith('AV')) {
          const aid = parseInt(seg.substring(2), 10);
          if (aid > 0) {
            const params: Record<string, Object> = {};
            params['aid'] = aid;
            return new BiliLinkResult('pages/VideoPlayerPage', params);
          }
        }
      }

      if (pathname.startsWith('/bangumi/play/')) {
        const seg = pathname.substring('/bangumi/play/'.length);
        if (seg.startsWith('ep')) {
          const epId = parseInt(seg.substring(2), 10);
          if (epId > 0) {
            const params: Record<string, Object> = {};
            params['epId'] = epId;
            return new BiliLinkResult('pages/VideoPlayerPage', params);
          }
        } else if (seg.startsWith('ss')) {
          const seasonId = parseInt(seg.substring(2), 10);
          if (seasonId > 0) {
            const params: Record<string, Object> = {};
            params['seasonId'] = seasonId;
            return new BiliLinkResult('pages/VideoPlayerPage', params);
          }
        }
      }

      if (hostPart.startsWith('space.')) {
        const mid = parseInt(pathname.replace(/^\//, ''), 10);
        if (mid > 0) {
          const params: Record<string, Object> = {};
          params['mid'] = mid;
          return new BiliLinkResult('pages/UpSpacePage', params);
        }
      }

      if (hostPart.startsWith('live.')) {
        const roomId = parseInt(pathname.replace(/^\//, ''), 10);
        if (roomId > 0) {
          const params: Record<string, Object> = {};
          params['roomId'] = roomId;
          return new BiliLinkResult('pages/LivePage', params);
        }
      }

      if (hostPart.startsWith('search.')) {
        const keyword = queryParams['keyword'] as string;
        if (keyword) {
          const params: Record<string, Object> = {};
          params['keyword'] = keyword;
          return new BiliLinkResult('pages/SearchPage', params);
        }
      }

      if (hostPart.startsWith('t.')) {
        return new BiliLinkResult('pages/DynamicsPage', {});
      }
    }

    hilog.info(DOMAIN, TAG, 'unhandled http url: host=%{public}s, path=%{public}s', hostPart, pathname);
    return null;
  }

  private static parseQuery(queryStr: string): Record<string, string> {
    const result: Record<string, string> = {};
    if (!queryStr) {
      return result;
    }
    const pairs = queryStr.split('&');
    for (const pair of pairs) {
      const eqIdx = pair.indexOf('=');
      if (eqIdx > 0) {
        const key = pair.substring(0, eqIdx);
        const value = pair.substring(eqIdx + 1);
        result[key] = decodeURIComponent(value);
      }
    }
    return result;
  }
}
