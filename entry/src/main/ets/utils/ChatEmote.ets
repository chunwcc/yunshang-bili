// ChatEmote.ets — 聊天表情工具（B站表情表加载 + 文本分段解析）
// 表情表来源：x/emote/user/panel/web?business=reply（评论同款表情面板），
//   必须带登录 Cookie（未登录时 packages=null）；key 为 [doge] 形式文本
import { http } from '@kit.NetworkKit';
import { logInfo, logWarn } from './Logger';

/** 聊天文本分段：文字段 emoteUrl 为空；表情段 emoteUrl 为表情图片地址 */
export interface ChatTextSegment {
  text: string;
  emoteUrl: string;
}

/** 表情面板条目：text 为 [doge] 形式，url 为表情图地址 */
export interface ChatEmoteItem {
  text: string;
  url: string;
}

/** 表情包（分类）：name 为分类名，emotes 为该分类下表情 */
export interface ChatEmotePackage {
  id: number;
  name: string;
  url: string; // 分类封面图标
  type: number; // 4=文字表情包
  emotes: ChatEmoteItem[];
}

export class ChatEmote {
  /** 表情 key（含方括号）→ 图片 URL */
  private static emoteMap: Map<string, string> = new Map<string, string>();
  /** 图片 URL → key（富文本输入框发送时把图片反向还原为 [xx] 文本） */
  private static emoteUrlMap: Map<string, string> = new Map<string, string>();
  /** 按表情包分组的表情列表（供表情面板分类显示） */
  private static packages: ChatEmotePackage[] = [];
  /** 是否已加载成功（失败不标记，保留重试机会） */
  private static loaded: boolean = false;

  /** 是否已加载成功 */
  static isLoaded(): boolean {
    return ChatEmote.loaded;
  }

  /** ⭐ 表情列表（供表情面板显示）：按键序返回 { text, url } */
  static getList(): ChatEmoteItem[] {
    const list: ChatEmoteItem[] = [];
    ChatEmote.emoteMap.forEach((url: string, text: string) => {
      list.push({ text, url });
    });
    return list;
  }

  /** ⭐ 按表情包分类的表情列表 */
  static getPackages(): ChatEmotePackage[] {
    return ChatEmote.packages;
  }

  /** ⭐ key → 图片 URL */
  static getUrlByText(text: string): string {
    return ChatEmote.emoteMap.get(text) ?? '';
  }

  /** ⭐ 图片 URL → key（富文本发送时把图还原为 [xx]） */
  static getTextByUrl(url: string): string {
    return ChatEmote.emoteUrlMap.get(url) ?? '';
  }

  /**
   * 单次拉取表情表（失败/为空时不标记 loaded，允许下次重试）
   */
  static async ensureLoaded(): Promise<void> {
    if (ChatEmote.loaded) {
      return;
    }
    const httpRequest = http.createHttp();
    try {
      // ⚠️ 必须带登录 Cookie：未登录时该接口 packages=null，登录后返回全部表情包。
      //    注意：App 冷启动时 Cookie 可能尚未从 Preferences 恢复（Index 异步回填），
      //    因此调用方应使用 waitForLoaded 带重试等待
      const cookie = AppStorage.get<string>('biliCookie') || '';
      logInfo(`[ChatEmote] 拉取表情表 cookie长度=${cookie.length}`);
      const response = await httpRequest.request(
        'https://api.bilibili.com/x/emote/user/panel/web?business=reply', {
          method: http.RequestMethod.GET,
          header: {
            'Cookie': cookie,
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
          },
          connectTimeout: 8000,
          readTimeout: 8000
        });
      if (response.responseCode !== 200) {
        logWarn(`[ChatEmote] 表情表 HTTP ${response.responseCode}`);
        return;
      }
      const resultStr: string = typeof response.result === 'string' ? response.result : '';
      if (!resultStr) {
        logWarn('[ChatEmote] 表情表响应为空');
        return;
      }
      const json = JSON.parse(resultStr) as Record<string, Object>;
      if ((json['code'] as number) !== 0) {
        logWarn(`[ChatEmote] 表情表返回 code=${json['code']} msg=${json['message']}`);
        return;
      }
      const data = json['data'] as Record<string, Object>;
      const packages = (data['packages'] as Object[]) ?? [];
      const pkgs: ChatEmotePackage[] = [];
      for (let p = 0; p < packages.length; p++) {
        const pkg = packages[p] as Record<string, Object>;
        const id = (pkg['id'] as number) || 0;
        const name = (pkg['name'] as string) || `表情${p + 1}`;
        const emotes = (pkg['emote'] as Object[]) ?? [];
        const itemList: ChatEmoteItem[] = [];
        for (let e = 0; e < emotes.length; e++) {
          const emote = emotes[e] as Record<string, Object>;
          const text = (emote['text'] as string) || '';
          let url = (emote['url'] as string) || '';
          if (text && url) {
            if (url.startsWith('//')) {
              url = `https:${url}`;
            }
            ChatEmote.emoteMap.set(text, url);
            ChatEmote.emoteUrlMap.set(url, text);
            itemList.push({ text, url });
          }
        }
        if (itemList.length > 0) {
          let cover = (pkg['url'] as string) || '';
          if (cover.startsWith('//')) { cover = `https:${cover}`; }
          if (!cover) { cover = itemList[0].url; }
          const pkgType = (pkg['type'] as number) || 0;
          pkgs.push({ id, name, url: cover, type: pkgType, emotes: itemList });
        }
      }
      ChatEmote.packages = pkgs;
      if (ChatEmote.emoteMap.size > 0) {
        ChatEmote.loaded = true;
        logInfo(`[ChatEmote] 表情表加载完成: ${ChatEmote.emoteMap.size} 个`);
      } else {
        logWarn('[ChatEmote] 表情表为空（未登录或 Cookie 尚未恢复）');
      }
    } catch (err) {
      logWarn(`[ChatEmote] 表情表加载失败: ${err}`);
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 带重试等待表情表加载完成（冷启动 Cookie 恢复竞态、瞬时网络失败都会自动重试）
   * @param tries 最大尝试次数（含首次，每次间隔 2s）
   * @returns 最终是否加载成功
   */
  static async waitForLoaded(tries: number = 5): Promise<boolean> {
    for (let i = 0; i < tries; i++) {
      if (ChatEmote.loaded) {
        return true;
      }
      await ChatEmote.ensureLoaded();
      if (ChatEmote.loaded) {
        return true;
      }
      if (i < tries - 1) {
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 2000));
      }
    }
    return ChatEmote.loaded;
  }

  /**
   * 解析聊天文本：按表情 key 拆分为文字段/表情段（长 key 优先匹配，同 CommentContentRenderer 方案）
   */
  static parse(text: string): ChatTextSegment[] {
    if (!text) {
      return [];
    }
    if (ChatEmote.emoteMap.size === 0) {
      return [{ text: text, emoteUrl: '' }];
    }
    // 构建正则匹配所有表情 key（转义特殊字符，长 key 优先）
    const keys: string[] = [];
    ChatEmote.emoteMap.forEach((_url: string, key: string) => {
      keys.push(key);
    });
    keys.sort((a: string, b: string) => b.length - a.length);
    const escapedKeys: string[] = keys.map((k: string) => k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
    const pattern: string = escapedKeys.join('|');
    if (!pattern) {
      return [{ text: text, emoteUrl: '' }];
    }
    const segments: ChatTextSegment[] = [];
    const regex = new RegExp(`(${pattern})`, 'g');
    let lastIndex = 0;
    let match: RegExpExecArray | null;
    while ((match = regex.exec(text)) !== null) {
      if (match.index > lastIndex) {
        segments.push({ text: text.substring(lastIndex, match.index), emoteUrl: '' });
      }
      segments.push({ text: match[0], emoteUrl: ChatEmote.emoteMap.get(match[0]) ?? '' });
      lastIndex = regex.lastIndex;
    }
    if (lastIndex < text.length) {
      segments.push({ text: text.substring(lastIndex), emoteUrl: '' });
    }
    return segments.length > 0 ? segments : [{ text: text, emoteUrl: '' }];
  }
}
