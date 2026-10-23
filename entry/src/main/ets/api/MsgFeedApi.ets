/**
 * B站 消息中心四类通知 REST API（回复我的 / @我 / 收到的赞 / 系统通知）
 * 参考 PiliPlusX 的 lib/http/msg.dart + lib/http/api.dart
 */
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';

/** 通知列表项（通用模型，字段按各接口尽力解析） */
export class MsgFeedItem {
  id: number = 0;
  time: number = 0;
  mid: number = 0;
  uname: string = '';
  avatar: string = '';
  content: string = '';
  bvid: string = '';
  aid: number = 0;
  rawItem: string = '';
  videoTitle: string = '';
  commentRootId: number = 0;
  commentSecondaryId: number = 0;
}

/** 通知列表分页结果 */
export class MsgFeedListResult {
  items: MsgFeedItem[] = [];
  /** 是否还有更多 */
  isEnd: boolean = false;
  /** 下一页游标 id */
  cursor: number = 0;
  /** 下一页游标时间 */
  cursorTime: number = 0;
}

/** 通知类型 */
export class MsgFeedType {
  /** 回复我的 */
  static readonly REPLY: number = 1;
  /** @我 */
  static readonly AT: number = 2;
  /** 收到的赞 */
  static readonly LIKE: number = 3;
  /** 系统通知 */
  static readonly SYS: number = 4;
}

/**
 * 消息中心四类通知 API
 */
export class MsgFeedApi {
  /** 获取登录 Cookie 头 */
  private static getCookieHeader(): string {
    const cookie = AppStorage.get<string>('biliCookie') || '';
    const deviceId = AppStorage.get<string>('biliDeviceId') || '';
    let cookieHeader = cookie;
    if (deviceId) {
      if (cookieHeader) {
        cookieHeader += `; buvid3=${deviceId}`;
      } else {
        cookieHeader = `buvid3=${deviceId}`;
      }
    }
    return cookieHeader;
  }

  /**
   * 请求一个通知接口（GET + cookie，返回 JSON）
   * ⚠️ msgfeed 系列接口不需要 WBI 签名（参考 PiliPlusX msgFeedReplyMe 等直接 queryParameters）
   */
  private static async getJson(url: string, params: Record<string, string>): Promise<Record<string, Object> | null> {
    const queryParts: string[] = [];
    const keys = Object.keys(params);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value = params[key];
      if (value !== '' && value !== '0' && value !== 'null') {
        queryParts.push(`${key}=${encodeURIComponent(value)}`);
      }
    }
    const queryStr = queryParts.join('&');
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(`${url}?${queryStr}`, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/',
          'Cookie': MsgFeedApi.getCookieHeader()
        },
        connectTimeout: 15000,
        readTimeout: 15000
      });
      if (response.responseCode === 200) {
        const json: Record<string, Object> = JSON.parse(response.result as string) as Record<string, Object>;
        if (json['code'] === 0) {
          return json;
        }
        logWarn(`[MsgFeedApi] ${url} code=${json['code']} message=${json['message']}`);
      }
    } catch (err) {
      logError(`[MsgFeedApi] ${url} 异常: ${errMsg(err)}`);
    } finally {
      httpRequest.destroy();
    }
    return null;
  }

  /**
   * 拉取一类通知列表
   * @param type 通知类型
   * @param cursor 游标 id（首页传 0）
   * @param cursorTime 游标时间（首页传 0）
   */
  static async fetchList(type: number, cursor: number, cursorTime: number): Promise<MsgFeedListResult> {
    const result = new MsgFeedListResult();
    try {
      let url = 'https://api.bilibili.com';
      const params: Record<string, string> = {
        'platform': 'web',
        'mobi_app': 'web',
        'build': '0',
        'web_location': '333.40164'
      };
      if (type === MsgFeedType.REPLY) {
        url += '/x/msgfeed/reply';
        params['reply_time'] = cursorTime.toString();
      } else if (type === MsgFeedType.AT) {
        url += '/x/msgfeed/at';
        params['at_time'] = cursorTime.toString();
      } else if (type === MsgFeedType.LIKE) {
        url += '/x/msgfeed/like';
        params['like_time'] = cursorTime.toString();
      } else {
        // 系统通知走 message.bilibili.com
        url = 'https://message.bilibili.com/x/sys-msg/query_notify_list';
        params['page_size'] = '20';
        params['cursor'] = cursor.toString();
      }
      if (cursor > 0) {
        params['id'] = cursor.toString();
      }
      const json = await MsgFeedApi.getJson(url, params);
      if (!json) {
        return result;
      }
      // ⚠️ 系统通知：data 直接是数组（PiliPlusX msgFeedNotify 里 res.data['data'] as List）
      if (type === MsgFeedType.SYS) {
        const list = json['data'] as Object[] | null;
        if (list) {
          for (let i = 0; i < list.length; i++) {
            const item = MsgFeedApi.parseSysItem(list[i]);
            if (item.id > 0) {
              result.items.push(item);
            }
          }
        }
        // 游标：取最后一项的 cursor 值（下次请求 cursor=该值）
        if (result.items.length > 0) {
          const lastRaw = list ? list[list.length - 1] as Record<string, Object> : null;
          if (lastRaw) {
            result.cursor = (lastRaw['cursor'] as number) || 0;
          }
        }
        return result;
      }
      const data = json['data'] as Record<string, Object> | null;
      if (!data) {
        return result;
      }
      // ⚠️ 收到的赞：结构是 data.latest.items + data.total.items（PiliPlusX MsgLikeData）
      if (type === MsgFeedType.LIKE) {
        const latest = data['latest'] as Record<string, Object> | null;
        if (latest) {
          const items = latest['items'] as Object[] | null;
          if (items) {
            for (let i = 0; i < items.length; i++) {
              const item = MsgFeedApi.parseItem(items[i]);
              if (item.id > 0) {
                result.items.push(item);
              }
            }
          }
        }
        const total = data['total'] as Record<string, Object> | null;
        if (total) {
          const items = total['items'] as Object[] | null;
          if (items) {
            for (let i = 0; i < items.length; i++) {
              const item = MsgFeedApi.parseItem(items[i]);
              if (item.id > 0) {
                result.items.push(item);
              }
            }
          }
          const cursorObj = total['cursor'] as Record<string, Object> | null;
          if (cursorObj) {
            result.cursor = (cursorObj['id'] as number) || 0;
            result.cursorTime = (cursorObj['time'] as number) || 0;
            result.isEnd = cursorObj['is_end'] === true;
          }
        }
        logInfo(`[MsgFeedApi] LIKE 返回 ${result.items.length} 条`);
        return result;
      }
      // 通用结构（回复/@）：data.cursor + data.items
      const cursorObj = data['cursor'] as Record<string, Object> | null;
      if (cursorObj) {
        result.cursor = (cursorObj['id'] as number) || 0;
        result.cursorTime = (cursorObj['time'] as number) || 0;
        result.isEnd = cursorObj['is_end'] === true;
      }
      const items = data['items'] as Object[] | null;
      if (items) {
        for (let i = 0; i < items.length; i++) {
          const item = MsgFeedApi.parseItem(items[i]);
          if (item.id > 0) {
            result.items.push(item);
          }
        }
      }
      logInfo(`[MsgFeedApi] type=${type} 返回 ${result.items.length} 条`);
      return result;
    } catch (err) {
      logError(`[MsgFeedApi] fetchList type=${type} 异常: ${errMsg(err)}`);
      return result;
    }
  }

  /**
   * 解析通用通知 item（尽力提取 id/time/用户/内容）
   */
  private static parseItem(obj: Object): MsgFeedItem {
    const item = new MsgFeedItem();
    const rec = obj as Record<string, Object>;
    item.id = (rec['id'] as number) || 0;
    item.time = (rec['time'] as number) || 0;
    // ⚠️ @我 的时间字段是 at_time（PiliPlusX MsgAtItem.atTime）
    if (item.time <= 0) {
      item.time = (rec['at_time'] as number) || 0;
    }
    // 内层 item（回复/@/赞都有嵌套 item）
    const inner = rec['item'] as Record<string, Object> | null;
    if (inner) {
      item.rawItem = JSON.stringify(inner);
      item.content = (inner['source_content'] as string) || (inner['title'] as string) || '';
      item.videoTitle = (inner['title'] as string) || '';
      // 从 uri / native_uri 中提取 bvid 和 aid
      // uri 格式: "https://www.bilibili.com/video/BV1op8g6AEPu"
      // native_uri 格式: "bilibili://video/117115587794526?page=0&comment_root_id=..."
      const uri = (inner['uri'] as string) || '';
      const nativeUri = (inner['native_uri'] as string) || '';
      if (uri) {
        const bvMatch = uri.match(/\/video\/(BV[\w]+)/);
        if (bvMatch && bvMatch.length > 1) {
          item.bvid = bvMatch[1];
        }
      }
      if (nativeUri) {
        const aidMatch = nativeUri.match(/video\/(\d+)/);
        if (aidMatch && aidMatch.length > 1) {
          item.aid = parseInt(aidMatch[1], 10) || 0;
        }
        const rootMatch = nativeUri.match(/comment_root_id=(\d+)/);
        if (rootMatch && rootMatch.length > 1) {
          item.commentRootId = parseInt(rootMatch[1], 10) || 0;
        }
        const secondaryMatch = nativeUri.match(/comment_secondary_id=(\d+)/);
        if (secondaryMatch && secondaryMatch.length > 1) {
          item.commentSecondaryId = parseInt(secondaryMatch[1], 10) || 0;
        }
      }
      // reply 结构（回复我的：用户信息在 reply.member 里）
      const reply = inner['reply'] as Record<string, Object> | null;
      if (reply) {
        item.content = (reply['content'] as string) || item.content;
        const member = reply['member'] as Record<string, Object> | null;
        if (member) {
          item.uname = (member['uname'] as string) || '';
          item.avatar = (member['avatar'] as string) || '';
          item.mid = (member['mid'] as number) || 0;
        }
      }
      // @我 / 赞 结构：source 里可能有用户和 bvid
      const source = inner['source'] as Record<string, Object> | null;
      if (source) {
        const author = source['author'] as Record<string, Object> | null;
        if (author) {
          item.uname = (author['name'] as string) || item.uname;
          item.mid = (author['mid'] as number) || item.mid;
        }
        const owner = source['owner'] as Record<string, Object> | null;
        if (owner) {
          item.uname = (owner['name'] as string) || item.uname;
          item.mid = (owner['mid'] as number) || item.mid;
        }
        if (!item.bvid) {
          item.bvid = (source['bvid'] as string) || item.bvid;
        }
        if (!item.aid) {
          const sourceAid = source['aid'];
          if (typeof sourceAid === 'number') {
            item.aid = sourceAid;
          } else if (typeof sourceAid === 'string') {
            item.aid = parseInt(sourceAid as string, 10) || 0;
          }
        }
      }
      // 赞结构：user_info
      const userInfo = inner['user_info'] as Record<string, Object> | null;
      if (userInfo) {
        item.uname = (userInfo['uname'] as string) || item.uname;
        item.avatar = (userInfo['avatar'] as string) || item.avatar;
        item.mid = (userInfo['mid'] as number) || item.mid;
      }
    }
    // ⚠️ @我 结构：顶层 user 对象（PiliPlusX MsgAtItem.user: mid/nickname/avatar）
    const topUser = rec['user'] as Record<string, Object> | null;
    if (topUser) {
      item.uname = (topUser['nickname'] as string) || item.uname;
      item.avatar = (topUser['avatar'] as string) || item.avatar;
      item.mid = (topUser['mid'] as number) || item.mid;
      if (!item.content) {
        item.content = `${item.uname}在内容中@了你`;
      }
    }
    // ⚠️ 赞结构：顶层 users 数组（PiliPlusX MsgLikeItem.users）
    const users = rec['users'] as Object[] | null;
    if (users && users.length > 0) {
      const u = users[0] as Record<string, Object>;
      item.uname = (u['nickname'] as string) || item.uname;
      item.avatar = (u['avatar'] as string) || item.avatar;
      if (!item.content) {
        item.content = `${item.uname}赞了你的内容`;
      }
    }

    return item;
  }

  /**
   * 解析系统通知 item（PiliPlusX MsgSysItem: id/cursor/title/content/time_at）
   */
  private static parseSysItem(obj: Object): MsgFeedItem {
    const item = new MsgFeedItem();
    const rec = obj as Record<string, Object>;
    item.id = (rec['id'] as number) || 0;
    item.time = (rec['time_at'] as number) || 0;
    item.content = (rec['title'] as string) || '';
    const content = rec['content'] as string;
    if (content) {
      // content 可能是 JSON（{"web": "..."}），PiliPlusX 里解析 web 字段
      try {
        const parsed: Record<string, Object> = JSON.parse(content) as Record<string, Object>;
        const web = parsed['web'] as string;
        if (web) {
          item.content = web;
        }
      } catch (err) {
        item.content = content;
      }
    }
    item.rawItem = JSON.stringify(rec);
    return item;
  }
}
