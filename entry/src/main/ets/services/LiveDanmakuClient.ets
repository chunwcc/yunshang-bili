/**
 * LiveDanmakuClient.ets — B站直播弹幕 WebSocket 客户端
 *
 * 协议：16 字节大端包头
 *   totalSize u32 | headerSize u16(16) | protoVer u16 | op u32 | seq u32
 * 认证 op=7（protover=1 明文 JSON，避开 zlib/brotli）
 * 心跳 op=2 每 30s；op=8 认证成功；op=5 消息；op=3 人气值
 *
 * 注意：认证包里 protover 用 1 时服务端下发**未压缩** JSON；
 * 若实测收到 protover=2/3 的帧，需要补 zlib 解压（见 warnCompressed）。
 */
import { webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { getLiveDanmuInfo, LiveDanmuHost, getLiveCookieString } from '../api/LiveDanmakuApi';
import { extractMidFromCookie } from '../api/FeedbackService';
import { LiveMessage, LiveMsgType } from '../model/LiveMessage';
import { logInfo, logWarn, logError } from '../utils/Logger';

type MsgHandler = (msg: LiveMessage) => void;

interface AuthBody {
  uid: number;
  roomid: number;
  protover: number;
  platform: string;
  type: number;
  key: string;
}
type StatsHandler = (online: number) => void;
type StateHandler = (state: string) => void;

export class LiveDanmakuClient {
  private ws: webSocket.WebSocket | null = null;
  private roomId: number = 0;
  private uid: number = 0;
  private token: string = '';
  private hosts: LiveDanmuHost[] = [];
  private hostIndex: number = 0;
  private heartbeatTimer: number = -1;
  private reconnectTimer: number = -1;
  private reconnectCount: number = 0;
  private manualClose: boolean = false;
  private connecting: boolean = false;
  private seq: number = 0;
  private warnedCompressed: boolean = false;
  private msgCount: number = 0;
  /** 已出现过的命令类型（每种只打一行日志，排查"聊天为空"用） */
  private seenCmds: Set<string> = new Set<string>();

  private onMsg: MsgHandler | null = null;
  private onStats: StatsHandler | null = null;
  private onState: StateHandler | null = null;

  async connect(roomId: number, onMsg: MsgHandler, onStats: StatsHandler, onState: StateHandler): Promise<void> {
    this.roomId = roomId;
    this.onMsg = onMsg;
    this.onStats = onStats;
    this.onState = onState;
    this.manualClose = false;
    this.reconnectCount = 0;
    await this.open();
  }

  close(): void {
    this.manualClose = true;
    this.stopHeartbeat();
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.seq++;
    const ws = this.ws;
    this.ws = null;
    if (ws) {
      try {
        ws.close();
      } catch (_e) {}
    }
    this.setState('closed');
  }

  // ==================== 连接 ====================

  private async open(): Promise<void> {
    if (this.manualClose || this.connecting) {
      return;
    }
    this.connecting = true;
    this.setState('connecting');
    try {
      const info = await getLiveDanmuInfo(this.roomId);
      if (this.manualClose) {
        return;
      }
      if (!info || !info.token || info.hosts.length === 0) {
        logWarn('[LiveDanmaku] 获取弹幕 token 失败');
        this.scheduleReconnect();
        return;
      }
      this.token = info.token;
      this.hosts = info.hosts;
      const mid: string = extractMidFromCookie(getLiveCookieString());
      this.uid = parseInt(mid, 10);
      if (!this.uid || this.uid <= 0) {
        this.uid = 0;
      }
      this.openSocket();
    } catch (e) {
      logError(`[LiveDanmaku] open 异常: ${e}`);
      this.scheduleReconnect();
    } finally {
      this.connecting = false;
    }
  }

  private openSocket(): void {
    const ws = webSocket.createWebSocket();
    this.ws = ws;
    const mySeq: number = ++this.seq;
    const host: LiveDanmuHost = this.hosts[this.hostIndex % this.hosts.length];
    const url: string = `wss://${host.host}:${host.wssPort}/sub`;
    logInfo(`[LiveDanmaku] 连接 ${url}`);

    ws.on('open', () => {
      if (mySeq !== this.seq) {
        return;
      }
      logInfo('[LiveDanmaku] WebSocket 已连接，发送认证包');
      this.sendAuth();
      this.startHeartbeat();
      this.reconnectCount = 0;
      this.setState('open');
    });
    ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (mySeq !== this.seq || err) {
        return;
      }
      this.onData(value);
    });
    ws.on('close', () => {
      if (mySeq !== this.seq || this.manualClose) {
        return;
      }
      logWarn('[LiveDanmaku] WebSocket 已关闭');
      this.stopHeartbeat();
      this.setState('reconnecting');
      this.scheduleReconnect();
    });
    ws.on('error', (e: BusinessError) => {
      if (mySeq !== this.seq || this.manualClose) {
        return;
      }
      logWarn(`[LiveDanmaku] WebSocket 错误: ${e ? e.message : 'unknown'}`);
      this.stopHeartbeat();
      this.setState('reconnecting');
      this.scheduleReconnect();
    });

    try {
      ws.connect(url, (e: BusinessError, ok: boolean) => {
        if (e) {
          logWarn(`[LiveDanmaku] connect 失败: ${e.message}`);
          if (mySeq === this.seq && !this.manualClose) {
            this.scheduleReconnect();
          }
        }
      });
    } catch (e) {
      logError(`[LiveDanmaku] connect 异常: ${e}`);
      this.scheduleReconnect();
    }
  }

  private scheduleReconnect(): void {
    if (this.manualClose) {
      return;
    }
    if (this.reconnectCount >= 5) {
      logWarn('[LiveDanmaku] 重连次数已达上限，停止');
      this.setState('closed');
      return;
    }
    const delay: number = 1000 * Math.pow(2, this.reconnectCount);
    this.reconnectCount++;
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
    }
    logInfo(`[LiveDanmaku] ${delay}ms 后重连（第 ${this.reconnectCount} 次）`);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.open();
    }, delay);
  }

  // ==================== 协议包 ====================

  private sendAuth(): void {
    const authBody: AuthBody = {
      uid: this.uid,
      roomid: this.roomId,
      protover: 1,
      platform: 'web',
      type: 2,
      key: this.token
    };
    const auth: string = JSON.stringify(authBody);
    const body: Uint8Array = new util.TextEncoder().encode(auth);
    this.sendPacket(7, 1, body);
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.sendHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      this.sendHeartbeat();
    }, 30000);
  }

  private sendHeartbeat(): void {
    this.sendPacket(2, 1, new Uint8Array(0));
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  private sendPacket(op: number, protoVer: number, body: Uint8Array): void {
    const ws = this.ws;
    if (!ws) {
      return;
    }
    const total: number = 16 + body.length;
    const buf = new ArrayBuffer(total);
    const dv = new DataView(buf);
    dv.setUint32(0, total);
    dv.setUint16(4, 16);
    dv.setUint16(6, protoVer);
    dv.setUint32(8, op);
    dv.setUint32(12, 1);
    if (body.length > 0) {
      new Uint8Array(buf).set(body, 16);
    }
    try {
      ws.send(buf);
    } catch (e) {
      logWarn(`[LiveDanmaku] 发送 op=${op} 失败: ${e}`);
    }
  }

  // ==================== 收包 ====================

  private onData(value: string | ArrayBuffer): void {
    if (typeof value === 'string') {
      this.handleJson(value);
      return;
    }
    this.processBuffer(value);
  }

  private processBuffer(buffer: ArrayBuffer): void {
    const bytes = new Uint8Array(buffer);
    if (bytes.length < 16) {
      return;
    }
    let offset: number = 0;
    while (offset + 16 <= bytes.length) {
      const dv = new DataView(buffer, offset);
      const total: number = dv.getUint32(0);
      const headerSize: number = dv.getUint16(4);
      const protoVer: number = dv.getUint16(6);
      const op: number = dv.getUint32(8);
      if (total < 16 || offset + total > bytes.length) {
        break;
      }
      if (op === 8) {
        logInfo('[LiveDanmaku] 认证成功，开始心跳');
      } else if (op === 5) {
        const body = new Uint8Array(buffer, offset + headerSize, total - headerSize);
        if (protoVer === 0 || protoVer === 1) {
          this.handleJson(util.TextDecoder.create('utf-8').decodeToString(body));
        } else if (protoVer === 2) {
          // ⭐ 实测认证 protover=1 时服务端仍下发 zlib（protoVer=2）帧
          this.inflateZlib(body).then((out: Uint8Array | null) => {
            if (out && out.length > 0) {
              this.processBuffer(this.toArrayBuffer(out));
            }
          }).catch((e: Error) => {
            logWarn(`[LiveDanmaku] zlib 解压失败: ${e.message}`);
          });
        } else if (!this.warnedCompressed) {
          this.warnedCompressed = true;
          logWarn(`[LiveDanmaku] 收到不支持的压缩帧 protoVer=${protoVer}`);
        }
      }
      offset += total;
    }
  }

  private toArrayBuffer(data: Uint8Array): ArrayBuffer {
    return data.slice().buffer as ArrayBuffer;
  }

  /** zlib(deflate) 解压：用 Zip.uncompress2 的 buffer 接口，避免手写 ZStream */
  private async inflateZlib(data: Uint8Array): Promise<Uint8Array | null> {
    const zip = zlib.createZipSync();
    const src: ArrayBuffer = this.toArrayBuffer(data);
    let capacity: number = Math.max(8192, src.byteLength * 8);
    for (let attempt = 0; attempt < 3; attempt++) {
      const dest = new ArrayBuffer(capacity);
      const info = await zip.uncompress2(dest, src, src.byteLength);
      if (info.status === zlib.ReturnStatus.OK) {
        return new Uint8Array(dest, 0, info.destLength);
      }
      if (info.status === zlib.ReturnStatus.BUF_ERROR) {
        capacity *= 4;
        continue;
      }
      throw new Error(`uncompress2 失败: ${info.status}`);
    }
    throw new Error('uncompress2 输出缓冲不足');
  }

  // ==================== 消息解析 ====================

  private handleJson(text: string): void {
    let obj: Record<string, Object>;
    try {
      obj = JSON.parse(text) as Record<string, Object>;
    } catch (_e) {
      return;
    }
    const cmd: string = obj['cmd'] as string;
    if (!cmd) {
      return;
    }
    // 诊断：每种命令类型只记录一次，用来判断"聊天为空"是没人说话还是解析漏了
    const cmdBase: string = cmd.split(':')[0];
    if (!this.seenCmds.has(cmdBase)) {
      this.seenCmds.add(cmdBase);
      logInfo(`[LiveDanmaku] 收到命令类型: ${cmdBase}`);
    }
    if (cmd.startsWith('DANMU_MSG')) {
      this.parseDanmaku(obj);
    } else if (cmd === 'SEND_GIFT') {
      this.parseGift(obj);
    } else if (cmd === 'SUPER_CHAT_MESSAGE') {
      this.parseSuperChat(obj);
    }
    // ONLINE_RANK_COUNT 的 count 是在线榜人数（常为 9999 占位），不能当真实在线人数用
  }

  private parseDanmaku(obj: Record<string, Object>): void {
    const info = obj['info'] as Object[];
    if (!info || info.length < 2) {
      return;
    }
    const text = info[1] as string;
    if (!text) {
      return;
    }
    let uname: string = '';
    let uid: number = 0;
    let color: number = 0xFFFFFF;
    let mode: number = 1;
    let id: string = '';
    let medalName: string = '';
    let medalLevel: number = 0;

    const first = info[0] as Object[];
    if (first && first.length > 15) {
      const payload = first[15] as Record<string, Object>;
      if (payload) {
        const user = payload['user'] as Record<string, Object>;
        if (user) {
          const base = user['base'] as Record<string, Object>;
          if (base) {
            const n = base['name'] as string;
            if (n) {
              uname = n;
            }
          }
          const u = user['uid'] as number;
          if (typeof u === 'number') {
            uid = u;
          }
          const medal = user['medal'] as Record<string, Object>;
          if (medal) {
            const mn = medal['name'] as string;
            const ml = medal['level'] as number;
            if (mn) {
              medalName = mn;
            }
            if (typeof ml === 'number') {
              medalLevel = ml;
            }
          }
        }
        const extraStr = payload['extra'] as string;
        if (extraStr) {
          try {
            const extra = JSON.parse(extraStr) as Record<string, Object>;
            const c = extra['color'] as number;
            const m = extra['mode'] as number;
            const eid = extra['id_str'] as string;
            if (typeof c === 'number') {
              color = c;
            }
            if (typeof m === 'number') {
              mode = m;
            }
            if (eid) {
              id = eid;
            }
          } catch (_e) {}
        }
      }
    }

    if (!uname && info.length > 2) {
      const u = info[2] as Object[];
      if (u) {
        if (typeof u[0] === 'number') {
          uid = u[0] as number;
        }
        if (typeof u[1] === 'string') {
          uname = u[1] as string;
        }
      }
    }
    if (color === 0xFFFFFF && first && first.length > 3 && typeof first[3] === 'number') {
      color = first[3] as number;
    }
    if (mode === 1 && first && first.length > 1 && typeof first[1] === 'number') {
      mode = first[1] as number;
    }

    const msg = new LiveMessage(LiveMsgType.DANMAKU);
    msg.id = id;
    msg.uid = uid;
    msg.uname = uname || '匿名';
    msg.text = text;
    msg.color = color;
    msg.mode = mode;
    msg.medalName = medalName;
    msg.medalLevel = medalLevel;
    this.emit(msg);
  }

  private parseGift(obj: Record<string, Object>): void {
    const data = obj['data'] as Record<string, Object>;
    if (!data) {
      return;
    }
    const msg = new LiveMessage(LiveMsgType.GIFT);
    const uname = data['uname'] as string;
    const action = data['action'] as string;
    const giftName = data['giftName'] as string;
    const num = data['num'] as number;
    msg.uname = uname || '匿名';
    msg.giftName = giftName || '';
    msg.num = typeof num === 'number' ? num : 1;
    msg.text = `${msg.uname} ${action || '赠送了'} ${msg.giftName} ×${msg.num}`;
    this.emit(msg);
  }

  private parseSuperChat(obj: Record<string, Object>): void {
    const data = obj['data'] as Record<string, Object>;
    if (!data) {
      return;
    }
    const user = data['user_info'] as Record<string, Object>;
    const msg = new LiveMessage(LiveMsgType.SUPER_CHAT);
    if (user) {
      const uname = user['uname'] as string;
      if (uname) {
        msg.uname = uname;
      }
    }
    const price = data['price'] as number;
    if (typeof price === 'number') {
      msg.price = price;
    }
    const text = data['message'] as string;
    msg.text = text || '';
    this.emit(msg);
  }

  private emit(msg: LiveMessage): void {
    this.msgCount++;
    if (this.msgCount === 1 || this.msgCount % 100 === 0) {
      logInfo(`[LiveDanmaku] 已接收 ${this.msgCount} 条消息`);
    }
    if (this.onMsg) {
      this.onMsg(msg);
    }
  }

  private setState(state: string): void {
    if (this.onState) {
      this.onState(state);
    }
  }
}
