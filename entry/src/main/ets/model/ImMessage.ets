/**
 * B站 IM 私信消息模型（对应 bilibili.im.type Msg）
 */

/** 消息类型（B站 IM MsgType） */
export class ImMsgType {
  /** 文本消息 */
  static readonly TEXT: number = 1;
  /** 图片消息 */
  static readonly PIC: number = 2;
  /** 撤回消息 */
  static readonly DRAW_BACK: number = 5;
}

/**
 * IM 单条消息（只解析本项目用到的字段，未知字段自动跳过）
 */
export class ImMessage {
  /** 发送者 uid */
  senderUid: number = 0;
  /** 接收者类型（1=用户） */
  receiverType: number = 0;
  /** 接收者 uid */
  receiverId: number = 0;
  /** 消息类型：1文本 2图片 5撤回 */
  msgType: number = 0;
  /** 消息内容：文本为 JSON 字符串（{"content":"..."}），图片为 JSON（{"url":"..."}） */
  content: string = '';
  /** 服务端消息序号（分页游标用） */
  msgSeqno: number = 0;
  /** 发送时间（秒） */
  timestamp: number = 0;
  /** 消息 key（撤回用） */
  msgKey: number = 0;
  /** 消息状态 */
  msgStatus: number = 0;
  /** 消息来源（18=对方未关注时的首条提示） */
  msgSource: number = 0;

  /**
   * 从 protobuf 解析出的 content 字段提取纯文本
   *
   * B 站 IM 的 content 有 4 种形态：
   * 1. {"content":"你好"}（普通文本）
   * 2. {"content":[{"text":"对方主动回复或关注你前，最多发送1条消息","color_day":"#9499A0","color_nig":"#9499A0"}]}（msgType=18 系统提示）
   * 3. [{"text":"..."}]（顶层数组）
   * 4. {"content":"[\"text\":\"对方主动回复或关注你前，最多发送1条消息\",...]"}（content 值是字符串化的 JSON，实际显示为 ["text":"..."]）
   */
  getText(): string {
    if (!this.content) {
      return '';
    }
    // ① 标准 JSON 解析
    try {
      const parsed: Object = JSON.parse(this.content);
      const t = ImMessage.extractTextFromParsed(parsed);
      if (t !== '') {
        return t;
      }
    } catch (err) {
      // 非标准 JSON，走字符串提取
    }
    // ② 非标准 JSON / 提取失败：字符串提取 "text" 的值
    const raw = ImMessage.extractTextFromRaw(this.content);
    if (raw !== '') {
      return raw;
    }
    // ③ 都失败，回退原文
    return this.content;
  }

  /**
   * 从已解析的 JSON 对象/数组中递归提取 text
   * @param parsed JSON.parse 的结果
   * @returns 提取到的文本；无则返回空串
   */
  private static extractTextFromParsed(parsed: Object): string {
    // 顶层数组：[{"text":"..."}] 或 [{"text":"...","color_day":"..."}]
    if (Array.isArray(parsed)) {
      const arr = parsed as Object[];
      if (arr.length > 0) {
        const first = arr[0] as Record<string, Object>;
        const t = first['text'];
        if (typeof t === 'string') {
          return t as string;
        }
      }
      return '';
    }
    // 对象：{"content":"你好"} / {"content":[{...}]} / {"content":"[\"...\"]"}
    const obj = parsed as Record<string, Object>;
    const c = obj['content'];
    if (typeof c === 'string') {
      const cStr = c as string;
      // content 是字符串，可能是字符串化的 JSON（形态 4）
      try {
        const inner: Object = JSON.parse(cStr);
        const t = ImMessage.extractTextFromParsed(inner);
        if (t !== '') {
          return t;
        }
      } catch (err) {
        // 字符串化的非标准 JSON，走 raw 提取
      }
      // 二次解析失败：对 cStr 做字符串提取
      const raw = ImMessage.extractTextFromRaw(cStr);
      if (raw !== '') {
        return raw;
      }
      return cStr;
    }
    // content 是数组：{"content":[{"text":"..."}, ...]}
    if (Array.isArray(c)) {
      const arr = c as Object[];
      if (arr.length > 0) {
        const first = arr[0] as Record<string, Object>;
        const t = first['text'];
        if (typeof t === 'string') {
          return t as string;
        }
      }
    }
    return '';
  }

  /**
   * 从任意字符串中提取 "text" 键的值（兼容标准/非标准分隔符）
   * 兼容："text":"值" / "text": "值" / "text","值" / "text", "值"
   * @param content 原始字符串
   * @returns 提取到的文本；无则返回空串
   */
  private static extractTextFromRaw(content: string): string {
    const keys: string[] = ['"text":"', '"text": "', '"text","', '"text", "'];
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const idx = content.indexOf(key);
      if (idx >= 0) {
        const start = idx + key.length;
        const end = content.indexOf('"', start);
        if (end > start) {
          return content.substring(start, end);
        }
      }
    }
    return '';
  }

  /**
   * 图片消息取图片 URL
   */
  getPicUrl(): string {
    if (this.msgType !== ImMsgType.PIC) {
      return '';
    }
    try {
      const obj: Record<string, Object> = JSON.parse(this.content) as Record<string, Object>;
      const url = obj['url'];
      return typeof url === 'string' ? (url as string) : '';
    } catch (err) {
      return '';
    }
  }
}
