/**
 * LiveMessage.ets — 直播消息模型（弹幕 / 礼物 / SC / 系统）
 */

export enum LiveMsgType {
  DANMAKU = 0,
  GIFT = 1,
  SUPER_CHAT = 2,
  SYSTEM = 3
}

export class LiveMessage {
  id: string = '';
  type: LiveMsgType = LiveMsgType.DANMAKU;
  uid: number = 0;
  uname: string = '';
  text: string = '';
  /** 弹幕颜色（RGB 十进制，0xFFFFFF = 白） */
  color: number = 0xFFFFFF;
  /** B站直播弹幕模式：1/2/3 滚动，4 底部，5 顶部 */
  mode: number = 1;
  medalName: string = '';
  medalLevel: number = 0;
  /** 礼物 / SC 价格（金瓜子或元） */
  price: number = 0;
  giftName: string = '';
  num: number = 1;
  ts: number = 0;
  /** 自己发送的消息（本地回显） */
  self: boolean = false;

  constructor(type: LiveMsgType = LiveMsgType.DANMAKU) {
    this.type = type;
    this.ts = Date.now();
  }
}
