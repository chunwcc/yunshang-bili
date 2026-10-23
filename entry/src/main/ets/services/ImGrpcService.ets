/**
 * B站 IM 私信 gRPC 服务层
 *
 * B 站 app 网关的 gRPC 是"伪 gRPC"：普通 HTTP POST + Content-Type: application/grpc，
 * body = 5 字节帧头（1 字节压缩标志 + 4 字节大端长度）+ protobuf 数据。
 * 响应成功以响应头 Grpc-Status: 0 判断；响应帧 flag=1 时 payload 为 gzip 压缩。
 *
 * 参考：PiliPlusX 的 lib/grpc/grpc_req.dart + lib/grpc/im.dart
 */
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { ProtoWriter, ProtoReader, WireType } from '../services/ImProto';
import { ImMessage, ImMsgType } from '../model/ImMessage';
import { extractCsrfFromCookie } from '../api/FeedbackService';
import { AppSign } from '../utils/SignUtils';
import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';

/** 拉取会话历史消息的结果 */
export class ImFetchResult {
  /** 消息列表（新→旧） */
  messages: ImMessage[] = [];
  /** 是否还有更多（0=有更多, 1=已到底） */
  hasMore: number = 0;
  /** 本页最小 seqno */
  minSeqno: number = 0;
  /** 本页最大 seqno */
  maxSeqno: number = 0;
}

/** 聊天图片上传结果（upload_bfs 返回） */
export class ChatImageUploadResult {
  /** 图床 URL（https 化后，直接用于图片消息 content.url） */
  url: string = '';
  /** 图片宽度（像素） */
  width: number = 0;
  /** 图片高度（像素） */
  height: number = 0;
}

/** 私聊会话（会话列表项） */
export class ImSession {
  /** 对方 uid */
  talkerUid: number = 0;
  /** 会话名（对方昵称） */
  sessionName: string = '';
  /** 对方头像 URL（来自 account_info.picUrl） */
  face: string = '';
  /** 最后一条消息文本 */
  lastMsg: string = '';
  /** 未读数 */
  unread: number = 0;
  /** 最近消息时间（秒） */
  timestamp: number = 0;
  /** 是否置顶 */
  isPinned: boolean = false;
  /** 是否免打扰 */
  isMuted: boolean = false;
}

/** 会话列表结果 */
export class ImSessionListResult {
  sessions: ImSession[] = [];
  /** 是否有更多 */
  hasMore: boolean = false;
  /** 分页 offset 原始字节（下次请求原样带回） */
  offsetBytes: Uint8Array | null = null;
}

/** 消息页四类通知未读数（RspTotalUnread.msgFeedUnread.unread） */
export class ImUnreadCount {
  at: number = 0;
  like: number = 0;
  reply: number = 0;
  sysMsg: number = 0;
}

/**
 * IM gRPC 服务
 */
export class ImGrpcService {
  /** app 网关基础地址 */
  private static readonly APP_BASE: string = 'https://app.bilibili.com';
  /** IM 接口路径前缀 */
  private static readonly IM_INTERFACE: string = '/bilibili.im.interface.v1.ImInterface';
  /** 会话列表接口路径前缀 */
  private static readonly IM_APP: string = '/bilibili.app.im.v1.im';
  /** 已读回执 REST 地址（tUrl） */
  private static readonly ACK_URL: string = 'https://api.vc.bilibili.com/session_svr/v1/session_svr/update_ack';

  /**
   * 获取登录 Cookie 头（复用 AppStorage 里的 biliCookie + buvid3）
   */
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
   * 获取 app 端 access_key（B 站 app gRPC 网关认证凭证）
   * ⚠️ 登录时已保存到 AppStorage('biliAccessKey')，缺失返回空串
   */
  private static getAccessKey(): string {
    return AppStorage.get<string>('biliAccessKey') || '';
  }

  /**
   * base64 编码（Uint8Array → base64 字符串）
   */
  private static base64Encode(bytes: Uint8Array): string {
    const helper = new util.Base64Helper();
    const encoded = helper.encodeSync(bytes);
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(encoded);
  }

  /**
   * 构造 x-bili-device-bin（Device protobuf，字段参考 PiliPlusX metadata/device.proto）
   */
  private static buildDeviceBin(buvid: string): string {
    const w = new ProtoWriter();
    w.writeIntField(1, 5);                      // app_id
    w.writeIntField(2, 2001100);                // build
    w.writeStringField(3, buvid);               // buvid
    w.writeStringField(4, 'android_hd');        // mobi_app
    w.writeStringField(5, 'android');           // platform
    w.writeStringField(6, 'android');           // device
    w.writeStringField(7, 'master');            // channel
    w.writeStringField(8, 'android');           // brand
    w.writeStringField(9, 'android');           // model
    w.writeStringField(10, '15');               // osver
    w.writeStringField(13, '2.0.1');            // version_name
    return ImGrpcService.base64Encode(w.toUint8Array());
  }

  /**
   * 构造 x-bili-metadata-bin（Metadata protobuf，含 access_key）
   */
  private static buildMetadataBin(accessKey: string, buvid: string): string {
    const w = new ProtoWriter();
    if (accessKey) {
      w.writeStringField(1, accessKey);         // access_key
    }
    w.writeStringField(2, 'android_hd');        // mobi_app
    w.writeStringField(3, 'android');           // device
    w.writeIntField(4, 2001100);                // build
    w.writeStringField(5, 'master');            // channel
    w.writeStringField(6, buvid);               // buvid
    w.writeStringField(7, 'android');           // platform
    return ImGrpcService.base64Encode(w.toUint8Array());
  }

  /**
   * 构造 x-bili-network-bin（Network protobuf：WIFI）
   */
  private static buildNetworkBin(): string {
    const w = new ProtoWriter();
    w.writeIntField(1, 1);                      // type = WIFI
    return ImGrpcService.base64Encode(w.toUint8Array());
  }

  /**
   * 构造 x-bili-locale-bin（Locale protobuf：zh-Hans-CN / Asia/Shanghai）
   */
  private static buildLocaleBin(): string {
    const cLocale = new ProtoWriter();
    cLocale.writeStringField(1, 'zh');          // language
    cLocale.writeStringField(2, 'Hans');        // script
    cLocale.writeStringField(3, 'CN');          // region
    const sLocale = new ProtoWriter();
    sLocale.writeStringField(1, 'zh');
    sLocale.writeStringField(2, 'Hans');
    sLocale.writeStringField(3, 'CN');
    const w = new ProtoWriter();
    w.writeMessageField(1, cLocale.toUint8Array()); // c_locale
    w.writeMessageField(2, sLocale.toUint8Array()); // s_locale
    w.writeStringField(4, 'Asia/Shanghai');         // timezone
    return ImGrpcService.base64Encode(w.toUint8Array());
  }

  /**
   * 构造 x-bili-fawkes-req-bin（FawkesReq protobuf）
   */
  private static buildFawkesBin(): string {
    const w = new ProtoWriter();
    w.writeStringField(1, 'android_hd');        // appkey
    w.writeStringField(2, 'prod');              // env
    w.writeStringField(3, ImGrpcService.hex(8)); // session_id
    return ImGrpcService.base64Encode(w.toUint8Array());
  }

  /**
   * 构造 B 站 app 网关 gRPC 所需的完整设备头（对齐 PiliPlusX grpcHeaders）
   */
  private static buildGrpcHeaders(): Record<string, string> {
    const buvid = ImGrpcService.getDeviceId();
    const accessKey = ImGrpcService.getAccessKey();
    const timestamp = Date.now().toString(16);
    const random = Math.random().toString(16).substring(2, 10);
    const headers: Record<string, string> = {
      'x-bili-gaia-vtoken': '',
      'x-bili-aurora-zone': '',
      'x-bili-trace-id': `${timestamp}:${random}:0:0`,
      'buvid': buvid,
      'bili-http-engine': 'cronet',
      'x-bili-device-bin': ImGrpcService.buildDeviceBin(buvid),
      'x-bili-network-bin': ImGrpcService.buildNetworkBin(),
      'x-bili-locale-bin': ImGrpcService.buildLocaleBin(),
      'x-bili-exps-bin': '',
      'x-bili-fawkes-req-bin': ImGrpcService.buildFawkesBin(),
      'x-bili-metadata-bin': ImGrpcService.buildMetadataBin(accessKey, buvid)
    };
    return headers;
  }

  /**
   * 获取当前登录用户 mid（从 Cookie 的 DedeUserID 提取）
   * 未登录返回 0
   */
  static getMyMid(): number {
    const cookie = AppStorage.get<string>('biliCookie') || '';
    const idx = cookie.indexOf('DedeUserID=');
    if (idx < 0) {
      return 0;
    }
    const rest = cookie.substring(idx + 'DedeUserID='.length);
    const end = rest.indexOf(';');
    const idStr = end >= 0 ? rest.substring(0, end) : rest;
    const mid = Number.parseInt(idStr, 10);
    return isNaN(mid) ? 0 : mid;
  }

  /**
   * 生成设备 ID（UUID v4 风格，与 BilibiliApi 的 getDeviceId 一致）
   */
  private static getDeviceId(): string {
    let deviceId = AppStorage.get<string>('biliDeviceId');
    if (!deviceId) {
      deviceId = ImGrpcService.hex(8) + '-' + ImGrpcService.hex(4) + '-' +
        ImGrpcService.hex(4) + '-' + ImGrpcService.hex(4) + '-' + ImGrpcService.hex(12) + 'infoc';
      AppStorage.setOrCreate('biliDeviceId', deviceId);
    }
    return deviceId;
  }

  private static hex(len: number): string {
    let out = '';
    for (let i = 0; i < len; i++) {
      out += Math.floor(Math.random() * 16).toString(16);
    }
    return out;
  }

  /**
   * 构造 gRPC 请求帧：5 字节头（flag=0 不压缩）+ protobuf
   * 请求侧始终不压缩（gRPC identity 编码，服务端必须支持）
   */
  private static buildFrame(proto: Uint8Array): ArrayBuffer {
    const frame = new ArrayBuffer(5 + proto.length);
    const view = new DataView(frame);
    const bytes = new Uint8Array(frame);
    bytes[0] = 0;
    view.setUint32(1, proto.length, false); // 大端
    bytes.set(proto, 5);
    return frame;
  }

  /**
   * 解析 gRPC 响应帧，返回 protobuf 字节（flag=1 时 gzip 解压）
   * ⚠️ 防御：若整个 body 是 HTTP 层 gzip（魔数 0x1f 0x8b），先整体解压再解析帧
   */
  private static async parseFrame(data: ArrayBuffer): Promise<Uint8Array> {
    let bytes = new Uint8Array(data);
    // HTTP 层 gzip 防御（鸿蒙 http 对 ARRAY_BUFFER 不自动解压 Content-Encoding）
    if (bytes.length > 2 && bytes[0] === 0x1f && bytes[1] === 0x8b) {
      bytes = await ImGrpcService.gzipDecompress(bytes);
    }
    if (bytes.length < 5) {
      throw new Error('gRPC 响应帧过短');
    }
    const buf = ImGrpcService.toArrayBuffer(bytes);
    const view = new DataView(buf);
    const compressed = bytes[0] === 1;
    const len = view.getUint32(1, false);
    const payload = bytes.slice(5, 5 + len);
    if (compressed) {
      return ImGrpcService.gzipDecompress(payload);
    }
    return payload;
  }

  /**
   * gzip 解压（zlib inflate，windowBits=31 表示 gzip 格式）
   * @ohos.zlib 的 inflate 系列是 Zip 实例方法，用 createZipSync 获取实例
   */
  private static async gzipDecompress(data: Uint8Array): Promise<Uint8Array> {
    const zip = zlib.createZipSync();
    const strm = await zip.getZStream();
    const inputBuf = ImGrpcService.toArrayBuffer(data);
    let outCapacity = Math.max(1024, inputBuf.byteLength * 2);
    let nextOut = new ArrayBuffer(outCapacity);
    strm.nextIn = inputBuf;
    strm.availableIn = inputBuf.byteLength;
    strm.nextOut = nextOut;
    strm.availableOut = outCapacity;
    const initStatus = await zip.inflateInit2(strm, 31);
    if (initStatus !== zlib.ReturnStatus.OK) {
      throw new Error(`gzip inflateInit2 失败: ${initStatus}`);
    }
    try {
      let status = await zip.inflate(strm, zlib.CompressFlushMode.FINISH);
      // 输出缓冲不足（BUF_ERROR）时扩容并继续
      while (status === zlib.ReturnStatus.BUF_ERROR) {
        const used = strm.totalOut ?? 0;
        outCapacity = used * 2 + 1024;
        const grown = new ArrayBuffer(outCapacity);
        if (used > 0) {
          const src = new Uint8Array(nextOut, 0, used);
          new Uint8Array(grown).set(src, 0);
        }
        nextOut = grown;
        strm.nextOut = nextOut;
        strm.availableOut = outCapacity - used;
        status = await zip.inflate(strm, zlib.CompressFlushMode.FINISH);
      }
      if (status !== zlib.ReturnStatus.STREAM_END) {
        throw new Error(`gzip inflate 失败: ${status}`);
      }
      const total = strm.totalOut ?? 0;
      return new Uint8Array(nextOut.slice(0, total));
    } finally {
      await zip.inflateEnd(strm);
    }
  }

  /**
   * Uint8Array → ArrayBuffer（拷贝，避免共享底层 buffer）
   */
  private static toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
    const out = new ArrayBuffer(bytes.length);
    new Uint8Array(out).set(bytes, 0);
    return out;
  }

  /**
   * gRPC POST 请求（application/grpc）
   * @param urlPath 接口路径（如 /bilibili.im.interface.v1.ImInterface/SendMsg）
   * @param proto protobuf 请求体
   * @returns 解析后的响应 protobuf 字节
   */
  private static async grpcPost(urlPath: string, proto: Uint8Array): Promise<Uint8Array> {
    const httpRequest = http.createHttp();
    try {
      const frame = ImGrpcService.buildFrame(proto);
      const grpcHeaders = ImGrpcService.buildGrpcHeaders();
      const headers: Record<string, string> = {
        'Content-Type': 'application/grpc',
        // ⚠️ 声明只接受未压缩响应，避免 B 站网关返回 gzip 帧（鸿蒙 http 对 ARRAY_BUFFER 不解压 HTTP 层 gzip）
        'grpc-accept-encoding': 'identity',
        // ⚠️ 同时禁用 HTTP 层压缩（Content-Encoding: gzip），否则 ARRAY_BUFFER 结果会是 gzip 字节
        'Accept-Encoding': 'identity',
        // ⚠️ B 站 app gRPC 网关用 authorization: identify_v1 <access_key> 认证（-101 未登录根因）
        'Authorization': `identify_v1 ${ImGrpcService.getAccessKey()}`,
        // ⚠️ app 网关要求 BiliDroid UA（浏览器 UA 会被识别为未登录）
        'User-Agent': 'Mozilla/5.0 BiliDroid/7.67.0 (bbcallen@gmail.com) os/android model/ONEPLUS A6000 mobi_app/android build/6740300 channel/bili',
        'Referer': 'https://www.bilibili.com/',
        'Cookie': ImGrpcService.getCookieHeader(),
        // ⚠️ app 网关设备头（-663 风控根因：缺设备指纹）
        'x-bili-gaia-vtoken': grpcHeaders['x-bili-gaia-vtoken'],
        'x-bili-aurora-zone': grpcHeaders['x-bili-aurora-zone'],
        'x-bili-trace-id': grpcHeaders['x-bili-trace-id'],
        'buvid': grpcHeaders['buvid'],
        'bili-http-engine': grpcHeaders['bili-http-engine'],
        'x-bili-device-bin': grpcHeaders['x-bili-device-bin'],
        'x-bili-network-bin': grpcHeaders['x-bili-network-bin'],
        'x-bili-locale-bin': grpcHeaders['x-bili-locale-bin'],
        'x-bili-exps-bin': grpcHeaders['x-bili-exps-bin'],
        'x-bili-fawkes-req-bin': grpcHeaders['x-bili-fawkes-req-bin'],
        'x-bili-metadata-bin': grpcHeaders['x-bili-metadata-bin']
      };
      const response = await httpRequest.request(ImGrpcService.APP_BASE + urlPath, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: frame,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 15000
      });
      if (response.responseCode !== 200) {
        throw new Error(`gRPC HTTP ${response.responseCode}`);
      }
      // ⚠️ grpc-status 在 gRPC over HTTP/2 中是 trailer 头，鸿蒙 http 的 response.header
      // 可能读不到它（返回 ''）。只要「读不到」就不报错，尝试解析 body；只有明确读到非 '0' 才报错。
      const header = response.header as Record<string, string>;
      const grpcStatus = header['grpc-status'] ?? header['Grpc-Status'] ?? '';
      if (grpcStatus !== '' && grpcStatus !== '0') {
        const msg = header['grpc-message'] || header['Grpc-Message'] || 'grpc 错误';
        throw new Error(`gRPC 错误: ${grpcStatus} ${msg}`);
      }
      const result = response.result;
      // ⚠️ 鸿蒙 http 的 ARRAY_BUFFER 结果可能是包装对象而非真 ArrayBuffer，
      // 参照 DanmakuService 的兼容处理：instanceof 失败时用 String(result) 判断
      if (result instanceof ArrayBuffer) {
        return ImGrpcService.parseFrame(result);
      }
      if (typeof result === 'object' && result !== null) {
        const str = String(result);
        if (str === '[object ArrayBuffer]') {
          return ImGrpcService.parseFrame(result as ArrayBuffer);
        }
        if (str === '[object Uint8Array]') {
          const arr = result as Uint8Array;
          const buf = ImGrpcService.toArrayBuffer(arr);
          return ImGrpcService.parseFrame(buf);
        }
      }
      throw new Error(`gRPC 响应不是 ArrayBuffer: ${typeof result}`);
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 发送文本消息
   * @param senderUid 自己 uid
   * @param receiverId 对方 uid（UP主 mid）
   * @param content 文本内容
   */
  static async sendText(senderUid: number, receiverId: number, content: string): Promise<boolean> {
    try {
      // 构造 Msg 消息
      const msgWriter = new ProtoWriter();
      msgWriter.writeIntField(1, senderUid);        // sender_uid
      msgWriter.writeIntField(2, 1);                // receiver_type = 1 (用户)
      msgWriter.writeIntField(3, receiverId);       // receiver_id
      msgWriter.writeIntField(5, ImMsgType.TEXT);   // msg_type = 1 文本
      msgWriter.writeStringField(6, JSON.stringify({ 'content': content })); // content
      msgWriter.writeIntField(8, Math.floor(Date.now() / 1000)); // timestamp(秒)
      msgWriter.writeIntField(12, 0);               // msg_status
      msgWriter.writeIntField(16, 1);               // new_face_version
      const msgBytes = msgWriter.toUint8Array();

      // 构造 ReqSendMsg
      const reqWriter = new ProtoWriter();
      reqWriter.writeMessageField(1, msgBytes);     // msg
      reqWriter.writeStringField(5, ImGrpcService.getDeviceId()); // dev_id
      const proto = reqWriter.toUint8Array();

      await ImGrpcService.grpcPost(ImGrpcService.IM_INTERFACE + '/SendMsg', proto);
      return true;
    } catch (err) {
      logError(`[ImGrpc] sendText 失败: ${errMsg(err)}`);
      return false;
    }
  }

  /**
   * 发送图片消息
   * @param senderUid 自己 uid
   * @param receiverId 对方 uid（UP主 mid）
   * @param url 图床 URL（upload_bfs 上传结果，必须是 B 站图床，否则 B 站报 21037）
   * @param width 图片宽度（像素，建议带上，否则可能显示异常）
   * @param height 图片高度（像素）
   */
  static async sendPic(senderUid: number, receiverId: number, url: string, width: number, height: number): Promise<boolean> {
    try {
      // 构造 Msg 消息（对齐官方 content 结构：{"url":..., "width":..., "height":...}）
      const msgWriter = new ProtoWriter();
      msgWriter.writeIntField(1, senderUid);        // sender_uid
      msgWriter.writeIntField(2, 1);                // receiver_type = 1 (用户)
      msgWriter.writeIntField(3, receiverId);       // receiver_id
      msgWriter.writeIntField(5, ImMsgType.PIC);    // msg_type = 2 图片
      msgWriter.writeStringField(6, JSON.stringify({ 'url': url, 'width': width, 'height': height })); // content
      msgWriter.writeIntField(8, Math.floor(Date.now() / 1000)); // timestamp(秒)
      msgWriter.writeIntField(12, 0);               // msg_status
      msgWriter.writeIntField(16, 1);               // new_face_version
      const msgBytes = msgWriter.toUint8Array();

      // 构造 ReqSendMsg
      const reqWriter = new ProtoWriter();
      reqWriter.writeMessageField(1, msgBytes);     // msg
      reqWriter.writeStringField(5, ImGrpcService.getDeviceId()); // dev_id
      const proto = reqWriter.toUint8Array();

      await ImGrpcService.grpcPost(ImGrpcService.IM_INTERFACE + '/SendMsg', proto);
      return true;
    } catch (err) {
      logError(`[ImGrpc] sendPic 失败: ${errMsg(err)}`);
      return false;
    }
  }

  /**
   * 上传聊天图片到 B 站图床（upload_bfs，biz=im 供 IM 私信使用）
   * @param filePath 沙箱内图片文件绝对路径（调用方先从相册拷贝到沙箱）
   * @param mimeType 图片 MIME（image/jpeg | image/png | image/gif）
   * @param ext 文件扩展名（jpg | png | gif，用于 multipart remoteFileName）
   * @returns 上传结果；失败时 url 为空串
   */
  static async uploadChatImage(filePath: string, mimeType: string, ext: string): Promise<ChatImageUploadResult> {
    const result = new ChatImageUploadResult();
    const httpRequest = http.createHttp();
    try {
      const cookie = ImGrpcService.getCookieHeader();
      const csrf = extractCsrfFromCookie(cookie);
      logInfo(`[ImGrpc] uploadChatImage csrf=${csrf ? csrf.substring(0, 6) + '...' : '(空)'} 含SESSDATA=${cookie.indexOf('SESSDATA') >= 0}`);
      // ⚠️ 手动拼 multipart 报文：@ohos.net.http 的 multiFormDataList 在设备上发送的表单
      //    字段缺失（服务端收不到 csrf 字段 → -111 CSRF 校验失败，实测同参数 curl 上传
      //    CSRF 可通过），改为完全自控报文格式
      const encoder = new util.TextEncoder();
      const boundary = '----ArkBiliUploadBoundary7d63a2f8';
      const src = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(filePath);
      const fileBytes = new ArrayBuffer(stat.size);
      fileIo.readSync(src.fd, fileBytes);
      fileIo.closeSync(src);
      const fileArr = new Uint8Array(fileBytes);
      const head = encoder.encode(
        `--${boundary}\r\nContent-Disposition: form-data; name="file_up"; filename="chat_img.${ext}"\r\nContent-Type: ${mimeType}\r\n\r\n`);
      const tail = encoder.encode(
        `\r\n--${boundary}\r\nContent-Disposition: form-data; name="category"\r\n\r\ndaily` +
        `\r\n--${boundary}\r\nContent-Disposition: form-data; name="biz"\r\n\r\nim` +
        `\r\n--${boundary}\r\nContent-Disposition: form-data; name="csrf"\r\n\r\n${csrf}` +
        `\r\n--${boundary}--\r\n`);
      const body = new Uint8Array(head.length + fileArr.length + tail.length);
      body.set(head, 0);
      body.set(fileArr, head.length);
      body.set(tail, head.length + fileArr.length);
      const response = await httpRequest.request('https://api.bilibili.com/x/dynamic/feed/draw/upload_bfs', {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': `multipart/form-data; boundary=${boundary}`,
          'Cookie': cookie,
          'Referer': 'https://www.bilibili.com/',
          'User-Agent': 'Mozilla/5.0 BiliDroid/7.67.0 (bbcallen@gmail.com) os/android model/ONEPLUS A6000 mobi_app/android build/6740300 channel/bili'
        },
        extraData: body.buffer,
        connectTimeout: 15000,
        readTimeout: 30000
      });
      if (response.responseCode !== 200) {
        logWarn(`[ImGrpc] uploadChatImage HTTP ${response.responseCode}`);
        return result;
      }
      const resultStr: string = typeof response.result === 'string' ? response.result : String(response.result);
      const json = JSON.parse(resultStr) as Record<string, Object>;
      if ((json['code'] as number) !== 0) {
        logWarn(`[ImGrpc] uploadChatImage 失败: code=${json['code']}, msg=${json['message']}`);
        return result;
      }
      const data = json['data'] as Record<string, Object>;
      const imageUrl: string = (data['image_url'] as string) || '';
      if (!imageUrl) {
        logWarn(`[ImGrpc] uploadChatImage 响应缺 image_url`);
        return result;
      }
      // ⚠️ B 站返回 http:// 开头的图床地址，IM 消息统一用 https 更稳
      result.url = imageUrl.startsWith('http://') ? `https://${imageUrl.substring(7)}` : imageUrl;
      result.width = (data['image_width'] as number) || 0;
      result.height = (data['image_height'] as number) || 0;
      return result;
    } catch (err) {
      logError(`[ImGrpc] uploadChatImage 失败: ${errMsg(err)}`);
      return result;
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * 拉取会话历史消息（新→旧）
   * @param talkerId 对方 uid
   * @param endSeqno 游标：拉取 seqno <= endSeqno 的旧消息；null 表示拉最新
   */
  static async fetchSessionMsgs(talkerId: number, endSeqno: number | null): Promise<ImFetchResult> {
    const result = new ImFetchResult();
    try {
      const reqWriter = new ProtoWriter();
      reqWriter.writeIntField(1, talkerId);         // talker_id
      reqWriter.writeIntField(2, 1);                // session_type = 1 (用户会话)
      if (endSeqno !== null) {
        reqWriter.writeIntField(3, endSeqno);       // end_seqno
        reqWriter.writeIntField(4, 0);              // begin_seqno = 0
      }
      reqWriter.writeIntField(5, 20);               // size = 20
      // ⚠️ PiliPlusX SyncFetchSessionMsgs 固定 devId='1'
      reqWriter.writeStringField(7, '1');           // dev_id
      const proto = reqWriter.toUint8Array();

      const rsp = await ImGrpcService.grpcPost(ImGrpcService.IM_INTERFACE + '/SyncFetchSessionMsgs', proto);
      const reader = new ProtoReader(rsp);
      const messages: ImMessage[] = [];
      while (!reader.isEnd()) {
        const tag = reader.readTag();
        if (tag[0] === -1) {
          break;
        }
        if (tag[0] === 1 && tag[1] === WireType.LENGTH_DELIMITED) {
          // messages（repeated Msg）
          const msgBytes = reader.readBytes();
          messages.push(ImGrpcService.parseMsg(msgBytes));
        } else if (tag[0] === 2 && tag[1] === WireType.VARINT) {
          result.hasMore = reader.readVarint();
        } else if (tag[0] === 3 && tag[1] === WireType.VARINT) {
          result.minSeqno = reader.readVarint();
        } else if (tag[0] === 4 && tag[1] === WireType.VARINT) {
          result.maxSeqno = reader.readVarint();
        } else {
          reader.skipField(tag[1]);
        }
      }
      result.messages = messages;
      logInfo(`[ImGrpc] fetchSessionMsgs: ${messages.length} 条, hasMore=${result.hasMore}`);
      return result;
    } catch (err) {
      logError(`[ImGrpc] fetchSessionMsgs 失败: ${errMsg(err)}`);
      return result;
    }
  }

  /**
   * 解析单条 Msg 消息
   */
  private static parseMsg(data: Uint8Array): ImMessage {
    const msg = new ImMessage();
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      switch (tag[0]) {
        case 1: // sender_uid
          if (tag[1] === WireType.VARINT) msg.senderUid = reader.readVarint();
          else reader.skipField(tag[1]);
          break;
        case 2: // receiver_type
          if (tag[1] === WireType.VARINT) msg.receiverType = reader.readVarint();
          else reader.skipField(tag[1]);
          break;
        case 3: // receiver_id
          if (tag[1] === WireType.VARINT) msg.receiverId = reader.readVarint();
          else reader.skipField(tag[1]);
          break;
        case 5: // msg_type
          if (tag[1] === WireType.VARINT) msg.msgType = reader.readVarint();
          else reader.skipField(tag[1]);
          break;
        case 6: // content
          if (tag[1] === WireType.LENGTH_DELIMITED) msg.content = reader.readString();
          else reader.skipField(tag[1]);
          break;
        case 7: // msg_seqno
          if (tag[1] === WireType.VARINT) msg.msgSeqno = reader.readVarint();
          else reader.skipField(tag[1]);
          break;
        case 8: // timestamp
          if (tag[1] === WireType.VARINT) msg.timestamp = reader.readVarint();
          else reader.skipField(tag[1]);
          break;
        case 11: // msg_key
          if (tag[1] === WireType.VARINT) msg.msgKey = reader.readVarint();
          else reader.skipField(tag[1]);
          break;
        case 12: // msg_status
          if (tag[1] === WireType.VARINT) msg.msgStatus = reader.readVarint();
          else reader.skipField(tag[1]);
          break;
        case 15: // msg_source
          if (tag[1] === WireType.VARINT) msg.msgSource = reader.readVarint();
          else reader.skipField(tag[1]);
          break;
        default:
          reader.skipField(tag[1]);
          break;
      }
    }
    return msg;
  }

  /**
   * 拉取私聊会话列表（SessionMain）
   * @param offsetBytes 上一次响应保存的分页 offset 原始字节；首次传 null
   */
  static async fetchSessionList(offsetBytes: Uint8Array | null): Promise<ImSessionListResult> {
    const result = new ImSessionListResult();
    try {
      const reqWriter = new ProtoWriter();
      if (offsetBytes !== null) {
        // SessionMainReq.paginationParams(2) = PaginationParams（原样带回 offset）
        reqWriter.writeMessageField(2, offsetBytes);
      } else {
        // ⚠️ PiliPlusX 首次请求也写入空 paginationParams 字段（tag=0x12 + len=0），空 body 可能被网关拒绝
        reqWriter.writeMessageField(2, new Uint8Array(0));
      }
      const proto = reqWriter.toUint8Array();
      const rsp = await ImGrpcService.grpcPost(ImGrpcService.IM_APP + '/SessionMain', proto);
      const reader = new ProtoReader(rsp);
      while (!reader.isEnd()) {
        const tag = reader.readTag();
        if (tag[0] === -1) {
          break;
        }
        if (tag[0] === 1 && tag[1] === WireType.LENGTH_DELIMITED) {
          // paginationParams：保存原始字节用于下次分页
          const pp = reader.readBytes();
          result.offsetBytes = ImGrpcService.parsePagination(pp, result);
        } else if (tag[0] === 5 && tag[1] === WireType.LENGTH_DELIMITED) {
          // sessions（repeated Session）
          result.sessions.push(ImGrpcService.parseSession(reader.readBytes()));
        } else {
          reader.skipField(tag[1]);
        }
      }
      logInfo(`[ImGrpc] fetchSessionList: ${result.sessions.length} 个会话, hasMore=${result.hasMore}`);
      return result;
    } catch (err) {
      logError(`[ImGrpc] fetchSessionList 失败: ${errMsg(err)}`);
      return result;
    }
  }

  /**
   * 解析 PaginationParams，返回可用于下次请求的原始字节（含 offsets 时）
   */
  private static parsePagination(data: Uint8Array, result: ImSessionListResult): Uint8Array | null {
    // 返回原始字节（其中含 offsets），并把 hasMore 解析出来
    const reader = new ProtoReader(data);
    let hasOffsets = false;
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 1 && tag[1] === WireType.LENGTH_DELIMITED) {
        hasOffsets = true; // offsets（map<int, Offset>）
        reader.skipField(tag[1]);
      } else if (tag[0] === 2 && tag[1] === WireType.VARINT) {
        result.hasMore = reader.readVarint() !== 0;
      } else {
        reader.skipField(tag[1]);
      }
    }
    return hasOffsets ? data : null;
  }

  /**
   * 解析单个 Session
   */
  private static parseSession(data: Uint8Array): ImSession {
    const s = new ImSession();
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      switch (tag[0]) {
        case 1: // id (SessionId)
          if (tag[1] === WireType.LENGTH_DELIMITED) s.talkerUid = ImGrpcService.parseSessionId(reader.readBytes());
          else reader.skipField(tag[1]);
          break;
        case 2: // sessionInfo
          if (tag[1] === WireType.LENGTH_DELIMITED) {
            const info = reader.readBytes();
            s.sessionName = ImGrpcService.parseSessionInfo(info);
            s.face = ImGrpcService.parseSessionFace(info);
            // ⚠️ 诊断日志：确认 gRPC accountInfo 是否返回头像
            if (s.face) {
              logInfo(`[ImGrpc] 会话 ${s.sessionName} 头像=${s.face}`);
            }
          } else {
            reader.skipField(tag[1]);
          }
          break;
        case 3: // unread
          if (tag[1] === WireType.LENGTH_DELIMITED) s.unread = ImGrpcService.parseUnread(reader.readBytes());
          else reader.skipField(tag[1]);
          break;
        case 4: // msgSummary
          if (tag[1] === WireType.LENGTH_DELIMITED) s.lastMsg = ImGrpcService.parseMsgSummary(reader.readBytes());
          else reader.skipField(tag[1]);
          break;
        case 5: // timestamp
          if (tag[1] === WireType.VARINT) s.timestamp = reader.readVarint();
          else reader.skipField(tag[1]);
          break;
        case 6: // isPinned
          if (tag[1] === WireType.VARINT) s.isPinned = reader.readVarint() !== 0;
          else reader.skipField(tag[1]);
          break;
        case 8: // isMuted
          if (tag[1] === WireType.VARINT) s.isMuted = reader.readVarint() !== 0;
          else reader.skipField(tag[1]);
          break;
        default:
          reader.skipField(tag[1]);
          break;
      }
    }
    return s;
  }

  /**
   * 解析 SessionInfo → 对方头像 URL
   * 真实头像在 avatar 字段 3（AvatarItem 嵌套：fallbackLayers→layers[0]→resource→resImage/resAnimation/resNativeDraw→…→url），
   * 参考 PiliPlus-ohos（bilibili/app/im/v1.pb.dart SessionInfo.avatar=3）：
   *   item.sessionInfo.avatar.fallbackLayers.layers.first.resource
   * 兜底：ava 字段 1（bilibili/im/type.pb.dart 的 SessionInfo）与 accountInfo 字段 24 → AccountInfo.picUrl 字段 2
   */
  private static parseSessionFace(data: Uint8Array): string {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 3 && tag[1] === WireType.LENGTH_DELIMITED) {
        // avatar → AvatarItem（app/im/v1.pb.dart）
        const face = ImGrpcService.parseAvatarItem(reader.readBytes());
        if (face) {
          return face;
        }
        continue;
      }
      if (tag[0] === 1 && tag[1] === WireType.LENGTH_DELIMITED) {
        // ava → AvatarItem（im/type.pb.dart 兜底）
        const face = ImGrpcService.parseAvatarItem(reader.readBytes());
        if (face) {
          return face;
        }
        continue;
      }
      if (tag[0] === 24 && tag[1] === WireType.LENGTH_DELIMITED) {
        // accountInfo（兜底）
        const face = ImGrpcService.parseAccountFace(reader.readBytes());
        if (face) {
          return face;
        }
        continue;
      }
      reader.skipField(tag[1]);
    }
    return '';
  }

  /**
   * 解析 AvatarItem → 头像 URL
   * fallbackLayers 字段 2 → LayerGroup
   */
  private static parseAvatarItem(data: Uint8Array): string {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 2 && tag[1] === WireType.LENGTH_DELIMITED) {
        // fallbackLayers → LayerGroup
        const face = ImGrpcService.parseLayerGroup(reader.readBytes());
        if (face) {
          return face;
        }
        continue;
      }
      reader.skipField(tag[1]);
    }
    return '';
  }

  /**
   * 解析 LayerGroup → 头像 URL
   * layers 字段 1（repeated Layer），取第一个
   */
  private static parseLayerGroup(data: Uint8Array): string {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 1 && tag[1] === WireType.LENGTH_DELIMITED) {
        // layers[0] → Layer
        const face = ImGrpcService.parseLayer(reader.readBytes());
        if (face) {
          return face;
        }
        continue;
      }
      reader.skipField(tag[1]);
    }
    return '';
  }

  /**
   * 解析 Layer → 头像 URL
   * resource 字段 4 → BasicLayerResource
   */
  private static parseLayer(data: Uint8Array): string {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 4 && tag[1] === WireType.LENGTH_DELIMITED) {
        // resource → BasicLayerResource
        const face = ImGrpcService.parseBasicLayerResource(reader.readBytes());
        if (face) {
          return face;
        }
        continue;
      }
      reader.skipField(tag[1]);
    }
    return '';
  }

  /**
   * 解析 BasicLayerResource → 头像 URL
   * resImage 字段 1 / resAnimation 字段 2 / resNativeDraw 字段 3 → ResourceSource
   */
  private static parseBasicLayerResource(data: Uint8Array): string {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 1 && tag[1] === WireType.LENGTH_DELIMITED) {
        // resImage.imageSrc → ResourceSource
        const face = ImGrpcService.parseResourceSource(reader.readBytes());
        if (face) {
          return face;
        }
        continue;
      }
      if (tag[0] === 2 && tag[1] === WireType.LENGTH_DELIMITED) {
        // resAnimation.webpSrc → ResourceSource
        const face = ImGrpcService.parseResourceSource(reader.readBytes());
        if (face) {
          return face;
        }
        continue;
      }
      if (tag[0] === 3 && tag[1] === WireType.LENGTH_DELIMITED) {
        // resNativeDraw.drawSrc → ResourceSource
        const face = ImGrpcService.parseResourceSource(reader.readBytes());
        if (face) {
          return face;
        }
        continue;
      }
      reader.skipField(tag[1]);
    }
    return '';
  }

  /**
   * 解析 ResourceSource → 头像 URL
   * remote 字段 3 → RemoteRes
   */
  private static parseResourceSource(data: Uint8Array): string {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 3 && tag[1] === WireType.LENGTH_DELIMITED) {
        // remote → RemoteRes
        const face = ImGrpcService.parseRemoteRes(reader.readBytes());
        if (face) {
          return face;
        }
        continue;
      }
      reader.skipField(tag[1]);
    }
    return '';
  }

  /**
   * 解析 RemoteRes → 头像 URL（url 字段 1）
   */
  private static parseRemoteRes(data: Uint8Array): string {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 1 && tag[1] === WireType.LENGTH_DELIMITED) {
        return reader.readString(); // url
      }
      reader.skipField(tag[1]);
    }
    return '';
  }

  /**
   * 解析 AccountInfo → 头像 URL（picUrl 字段 2）
   */
  private static parseAccountFace(data: Uint8Array): string {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 2 && tag[1] === WireType.LENGTH_DELIMITED) {
        return reader.readString(); // picUrl
      }
      reader.skipField(tag[1]);
    }
    return '';
  }

  /**
   * 解析 SessionId → talkerUid（取 privateId.talkerUid）
   */
  private static parseSessionId(data: Uint8Array): number {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 1 && tag[1] === WireType.LENGTH_DELIMITED) {
        // privateId
        const pid = new ProtoReader(reader.readBytes());
        while (!pid.isEnd()) {
          const pt = pid.readTag();
          if (pt[0] === -1) {
            break;
          }
          if (pt[0] === 1 && pt[1] === WireType.VARINT) {
            return pid.readVarint(); // talkerUid
          }
          pid.skipField(pt[1]);
        }
      } else {
        reader.skipField(tag[1]);
      }
    }
    return 0;
  }

  /**
   * 解析 SessionInfo → sessionName
   */
  private static parseSessionInfo(data: Uint8Array): string {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 1 && tag[1] === WireType.LENGTH_DELIMITED) {
        return reader.readString(); // sessionName
      }
      reader.skipField(tag[1]);
    }
    return '';
  }

  /**
   * 解析 Unread → number
   */
  private static parseUnread(data: Uint8Array): number {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 2 && tag[1] === WireType.VARINT) {
        return reader.readVarint(); // number
      }
      reader.skipField(tag[1]);
    }
    return 0;
  }

  /**
   * 解析 MsgSummary → rawMsg
   */
  private static parseMsgSummary(data: Uint8Array): string {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 1 && tag[1] === WireType.LENGTH_DELIMITED) {
        return reader.readString(); // rawMsg
      }
      reader.skipField(tag[1]);
    }
    return '';
  }

  /**
   * 拉取消息页四类通知未读数（GetTotalUnread）
   */
  static async fetchTotalUnread(): Promise<ImUnreadCount> {
    const result = new ImUnreadCount();
    try {
      const reqWriter = new ProtoWriter();
      reqWriter.writeIntField(1, 2);  // unread_type = 2
      reqWriter.writeIntField(2, 1);  // show_unfollow_list = 1
      const proto = reqWriter.toUint8Array();
      const rsp = await ImGrpcService.grpcPost(ImGrpcService.IM_INTERFACE + '/GetTotalUnread', proto);
      const reader = new ProtoReader(rsp);
      while (!reader.isEnd()) {
        const tag = reader.readTag();
        if (tag[0] === -1) {
          break;
        }
        if (tag[0] === 2 && tag[1] === WireType.LENGTH_DELIMITED) {
          // msgFeedUnread → unread（map<string, int64>）
          ImGrpcService.parseMsgFeedUnread(reader.readBytes(), result);
        } else {
          reader.skipField(tag[1]);
        }
      }
      return result;
    } catch (err) {
      logError(`[ImGrpc] fetchTotalUnread 失败: ${errMsg(err)}`);
      return result;
    }
  }

  /**
   * 解析 MsgFeedUnreadRsp.unread（map<string, int64>）
   */
  private static parseMsgFeedUnread(data: Uint8Array, result: ImUnreadCount): void {
    const reader = new ProtoReader(data);
    while (!reader.isEnd()) {
      const tag = reader.readTag();
      if (tag[0] === -1) {
        break;
      }
      if (tag[0] === 1 && tag[1] === WireType.LENGTH_DELIMITED) {
        // map entry：key(1, string) + value(2, int64)
        const entry = new ProtoReader(reader.readBytes());
        let key = '';
        let value = 0;
        while (!entry.isEnd()) {
          const et = entry.readTag();
          if (et[0] === -1) {
            break;
          }
          if (et[0] === 1 && et[1] === WireType.LENGTH_DELIMITED) {
            key = entry.readString();
          } else if (et[0] === 2 && et[1] === WireType.VARINT) {
            value = entry.readVarint();
          } else {
            entry.skipField(et[1]);
          }
        }
        if (key === 'at') result.at = value;
        else if (key === 'like') result.like = value;
        else if (key === 'reply') result.reply = value;
        else if (key === 'sys_msg') result.sysMsg = value;
      } else {
        reader.skipField(tag[1]);
      }
    }
  }

  /**
   * 消息标记已读（REST update_ack）
   * @param talkerId 对方 uid
   * @param ackSeqno 最大已读 seqno
   */
  static async ackSessionMsg(talkerId: number, ackSeqno: number): Promise<boolean> {
    try {
      const cookie = ImGrpcService.getCookieHeader();
      const csrf = extractCsrfFromCookie(cookie);
      const params: Record<string, string> = {
        'talker_id': talkerId.toString(),
        'session_type': '1',
        'ack_seqno': ackSeqno.toString(),
        'build': '0',
        'mobi_app': 'web',
        'csrf_token': csrf,
        'csrf': csrf
      };
      const queryStr = await AppSign.generateWebParams(params);
      const httpRequest = http.createHttp();
      try {
        const response = await httpRequest.request(`${ImGrpcService.ACK_URL}?${queryStr}`, {
          method: http.RequestMethod.GET,
          header: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Referer': 'https://www.bilibili.com/',
            'Cookie': cookie
          },
          connectTimeout: 15000,
          readTimeout: 15000
        });
        if (response.responseCode === 200) {
          const json: Record<string, Object> = JSON.parse(response.result as string) as Record<string, Object>;
          if (json['code'] === 0) {
            return true;
          }
          logWarn(`[ImGrpc] ackSessionMsg 返回 code=${json['code']}`);
        }
      } finally {
        httpRequest.destroy();
      }
      return false;
    } catch (err) {
      logError(`[ImGrpc] ackSessionMsg 失败: ${errMsg(err)}`);
      return false;
    }
  }
}
