/**
 * DlnaService.ets
 * 自建 DLNA 控制点（Control Point）—— 发现局域网内的 MediaRenderer 并把视频推过去播放。
 *
 * ⭐ 为什么不用系统投播（AVCastPicker）：
 *   鸿蒙系统投播的**设备发现走分布式软总线**（softbus，蓝牙/BLE 心跳广播 + Cast+ 建链），
 *   它面向华为生态设备（鸿蒙手机/平板/智慧屏/华为音箱）。
 *   实测（真机日志 + 同网段对照探测）：
 *     · Macast 在同一网段周期性广播 `NOTIFY * HTTP/1.1 / NTS: ssdp:alive`，是健康的 DLNA 接收端；
 *     · 系统日志里只有 `softbus_server ... srvType=HB`（蓝牙心跳），**没有任何 SSDP/UPnP 发现动作**；
 *     · 于是 AVCastPicker 弹出的设备列表里永远没有 Macast。
 *   ⇒ 系统投播不去听 239.255.255.250，改它的参数（sessionType 等）无济于事，只能自己实现控制点。
 *
 * 使用方式：
 *   1. DlnaService.startDiscovery(cb)  开始搜索（会持续监听 NOTIFY）
 *   2. DlnaService.stopDiscovery()
 *   3. DlnaService.setAVTransportURI(dev, url, title) 推送播放
 *   4. DlnaService.play / pause / stop / seek
 */
import { socket } from '@kit.NetworkKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';

const TAG = 'Dlna';

/** SSDP 组播地址与端口（UPnP 固定） */
const SSDP_GROUP: string = '239.255.255.250';
const SSDP_PORT: number = 1900;
/** 搜索目标：所有设备 + 渲染器（两种都发，不同厂商响应不同） */
const SSDP_ST_ALL: string = 'ssdp:all';
const SSDP_ST_RENDERER: string = 'urn:schemas-upnp-org:device:MediaRenderer:1';

/** 一个被发现的 DLNA 渲染设备 */
export interface DlnaDevice {
  /** 设备唯一名（来自 description.xml 的 UDN，用于去重） */
  udn: string;
  /** 展示名（friendlyName） */
  name: string;
  /** 设备 IP（描述文件所在主机） */
  ip: string;
  /** 描述文件完整 URL，如 http://192.168.3.46:47162/description.xml */
  location: string;
  /** AVTransport 控制 URL（已拼成绝对地址） */
  avTransportControlUrl: string;
  /** 首次发现时间（ms），用于排序/判断是否过期 */
  foundAt: number;
}

/**
 * 启动搜索：
 *   ⭐ 发现机制**以监听 NOTIFY 为主**，M-SEARCH 只作为辅助。
 *
 *   ⚠️ 千万别"优化"成只发 M-SEARCH：真机实测 Macast(0.7) **不回应** M-SEARCH
 *      （我用标准 SSDP 客户端在 192.168.3.x 网段发 ssdp:all / MediaRenderer:1 均无响应），
 *      但它**会周期性主动广播** `NOTIFY * HTTP/1.1` + `NTS: ssdp:alive`。
 *      只发查询的实现会永远搜不到它 —— 这个坑排查成本很高，务必保留 NOTIFY 监听。
 *
 *   两条路径互为补充：NOTIFY 覆盖"只广播不应答"的设备，M-SEARCH 覆盖"只应答不广播"的设备。
 */
export class DlnaService {
  private static ms: socket.MulticastSocket | null = null;
  private static devices: Map<string, DlnaDevice> = new Map();
  private static onUpdate: ((list: DlnaDevice[]) => void) | null = null;
  private static discovering: boolean = false;
  /** M-SEARCH 重发定时器（设备可能错过第一次查询） */
  private static searchTimer: number = -1;

  /** 已发现设备列表（按发现顺序） */
  static getDevices(): DlnaDevice[] {
    return Array.from(DlnaService.devices.values());
  }

  /**
   * 开始搜索设备。
   * @param onUpdate 设备列表变化时回调（新增/更新都会触发）
   */
  static async startDiscovery(onUpdate: (list: DlnaDevice[]) => void): Promise<void> {
    DlnaService.onUpdate = onUpdate;
    if (DlnaService.discovering) {
      // 已在搜索：先把已知设备报给新回调，再继续监听
      onUpdate(DlnaService.getDevices());
      return;
    }
    DlnaService.discovering = true;
    DlnaService.devices.clear();

    try {
      const ms = socket.constructMulticastSocketInstance();
      DlnaService.ms = ms;

      ms.on('message', (info: socket.SocketMessageInfo) => {
        DlnaService.handleSsdpMessage(info);
      });

      await ms.bind({ address: '0.0.0.0', port: SSDP_PORT, family: 1 });
      // 加入组播组才能收到 239.255.255.250 上的数据
      try {
        await ms.addMembership({ address: SSDP_GROUP, port: SSDP_PORT, family: 1 });
        logInfo(`[${TAG}] 已加入组播组 ${SSDP_GROUP}:${SSDP_PORT}，监听设备宣告`);
      } catch (e) {
        logWarn(`[${TAG}] addMembership 失败（部分机型不需显式加组）: ${errMsg(e)}`);
      }

      // 辅助：主动查询（对只应答不广播的设备有效）
      DlnaService.sendSearch();
      // 前 12 秒每 3 秒补发一次（设备可能刚唤醒错过第一次）
      DlnaService.searchTimer = setInterval(() => { DlnaService.sendSearch(); }, 3000);
      setTimeout(() => {
        if (DlnaService.searchTimer !== -1) {
          clearInterval(DlnaService.searchTimer);
          DlnaService.searchTimer = -1;
        }
      }, 12000);
    } catch (e) {
      DlnaService.discovering = false;
      logError(`[${TAG}] 启动搜索失败: ${errMsg(e)}`);
      // ⚠️ ArkTS 不允许 throw 任意类型（arkts-limited-throw），这里记日志即可，
      //    调用方靠"列表为空 + scanning 标志"判断失败，不必靠异常传播。
    }
  }

  /** 发一次 M-SEARCH（两种 ST 各发一次） */
  private static sendSearch(): void {
    const ms = DlnaService.ms;
    if (!ms) return;
    for (const st of [SSDP_ST_ALL, SSDP_ST_RENDERER]) {
      const req = 'M-SEARCH * HTTP/1.1\r\n'
        + `HOST: ${SSDP_GROUP}:${SSDP_PORT}\r\n`
        + 'MAN: "ssdp:discover"\r\n'
        + 'MX: 3\r\n'
        + `ST: ${st}\r\n\r\n`;
      ms.send({ data: req, address: { address: SSDP_GROUP, port: SSDP_PORT, family: 1 } })
        .catch((e: BusinessError) => {
          logWarn(`[${TAG}] M-SEARCH(${st}) 发送失败: ${errMsg(e)}`);
        });
    }
  }

  /** 处理收到的 SSDP 报文（NOTIFY 与 M-SEARCH 响应都是同格式的 HTTP 头） */
  private static handleSsdpMessage(info: socket.SocketMessageInfo): void {
    let text: string = '';
    try {
      // ArrayBuffer -> string（设备回的都是 ASCII 头）
      const buf = new Uint8Array(info.message as ArrayBuffer);
      let s = '';
      for (let i = 0; i < buf.length; i++) { s += String.fromCharCode(buf[i]); }
      text = s;
    } catch (e) {
      return;
    }
    if (text.indexOf('HTTP/1.1') < 0) return;

    // 只要渲染器（NT 或 ST 里带 MediaRenderer），其余（路由器/打印机）忽略
    const isRenderer = /MediaRenderer/i.test(text);
    if (!isRenderer) return;

    const location = DlnaService.header(text, 'LOCATION') || DlnaService.header(text, 'Location');
    if (!location || location.length === 0) return;

    // 用 location 去重（同一个设备会反复宣告）
    const key = location;
    if (DlnaService.devices.has(key)) return;

    const ip = DlnaService.ipFromUrl(location);
    if (ip.length === 0) return;

    logInfo(`[${TAG}] 发现渲染器 location=${location}`);
    // 先占位（保证列表立刻出现），再异步补详情
    const dev: DlnaDevice = {
      udn: '',
      name: ip,
      ip: ip,
      location: location,
      avTransportControlUrl: '',
      foundAt: Date.now()
    };
    DlnaService.devices.set(key, dev);
    DlnaService.notify();
    DlnaService.fetchDescription(dev);
  }

  /** 取 HTTP 头字段值（不区分大小写） */
  private static header(text: string, name: string): string {
    const lines = text.split('\r\n');
    const lower = name.toLowerCase();
    for (let i = 0; i < lines.length; i++) {
      const idx = lines[i].indexOf(':');
      if (idx < 0) continue;
      const k = lines[i].substring(0, idx).trim().toLowerCase();
      if (k === lower) return lines[i].substring(idx + 1).trim();
    }
    return '';
  }

  /** 从 URL 里取主机 IP */
  private static ipFromUrl(url: string): string {
    // http://192.168.3.46:47162/description.xml
    const m = url.match(/^https?:\/\/([^/:]+)/i);
    return m ? m[1] : '';
  }

  /** 拉取 description.xml，解析出 friendlyName 与 AVTransport 控制地址 */
  private static fetchDescription(dev: DlnaDevice): void {
    let req: http.HttpRequest | null = null;
    try {
      req = http.createHttp();
      req.request(dev.location, {
        method: http.RequestMethod.GET,
        header: { 'Content-Type': 'text/xml; charset="utf-8"' },
        connectTimeout: 5000,
        readTimeout: 5000
      }).then((resp: http.HttpResponse) => {
        const body = typeof resp.result === 'string' ? resp.result : '';
        DlnaService.parseDescription(dev, body);
      }).catch((e: BusinessError) => {
        logWarn(`[${TAG}] 拉取描述文件失败 ${dev.location}: ${errMsg(e)}`);
      }).finally(() => {
        if (req) { try { req.destroy(); } catch (_) {} }
      });
    } catch (e) {
      logWarn(`[${TAG}] 创建 HTTP 失败: ${errMsg(e)}`);
    }
  }

  /** 解析 description.xml（只取需要的字段，避免引入 XML 解析库） */
  private static parseDescription(dev: DlnaDevice, xml: string): void {
    const friendly = DlnaService.tag(xml, 'friendlyName');
    const udn = DlnaService.tag(xml, 'UDN');
    if (friendly.length > 0) dev.name = friendly;
    if (udn.length > 0) dev.udn = udn;

    // 找 AVTransport 服务的 controlURL（相对路径，需要拼上 location 的 host:port）
    const ctrl = DlnaService.avTransportControl(xml);
    if (ctrl.length > 0) {
      dev.avTransportControlUrl = DlnaService.absoluteUrl(dev.location, ctrl);
    }
    logInfo(`[${TAG}] 设备就绪: ${dev.name} AVTransport=${dev.avTransportControlUrl}`);
    DlnaService.notify();
  }

  /** 取 <tag>...</tag> 的文本 */
  private static tag(xml: string, name: string): string {
    const re = new RegExp('<' + name + '[^>]*>([\\s\\S]*?)</' + name + '>', 'i');
    const m = xml.match(re);
    return m ? m[1].trim() : '';
  }

  /** 从描述 XML 里定位 AVTransport 的 controlURL */
  private static avTransportControl(xml: string): string {
    // 逐个 <service> 块找含 AVTransport 的那个
    const blocks = xml.match(/<service>[\s\S]*?<\/service>/gi) || [];
    for (let i = 0; i < blocks.length; i++) {
      const b = blocks[i];
      if (b.indexOf('AVTransport') < 0) continue;
      const c = DlnaService.tag(b, 'controlURL');
      if (c.length > 0) return c;
    }
    return '';
  }

  /** 把相对 URL 拼成绝对 URL（基于 description.xml 的地址） */
  private static absoluteUrl(baseUrl: string, relative: string): string {
    if (/^https?:\/\//i.test(relative)) return relative;
    const m = baseUrl.match(/^(https?:\/\/[^/]+)/i);
    const origin = m ? m[1] : '';
    if (origin.length === 0) return relative;
    return origin + (relative.startsWith('/') ? '' : '/') + relative;
  }

  private static notify(): void {
    if (DlnaService.onUpdate) DlnaService.onUpdate(DlnaService.getDevices());
  }

  /** 停止搜索（释放组播 socket） */
  static async stopDiscovery(): Promise<void> {
    if (DlnaService.searchTimer !== -1) {
      clearInterval(DlnaService.searchTimer);
      DlnaService.searchTimer = -1;
    }
    const ms = DlnaService.ms;
    if (ms) {
      try { await ms.close(); } catch (e) { logWarn(`[${TAG}] 关闭组播 socket: ${errMsg(e)}`); }
    }
    DlnaService.ms = null;
    DlnaService.discovering = false;
    DlnaService.onUpdate = null;
    logInfo(`[${TAG}] 搜索已停止`);
  }

  // ===================== SOAP 控制 =====================

  /**
   * 推送播放地址给设备（SetAVTransportURI）。
   * @param url 设备能**直接拉取**的地址（⚠️ 必须是局域网可达的，见 DashMediaServer.start(bindAll)）
   * @param title 标题（部分接收端会显示）
   */
  static async setAVTransportURI(dev: DlnaDevice, url: string, title: string): Promise<boolean> {
    const didl = '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      + 'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      + 'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      + '<item id="0" parentID="-1" restricted="1">'
      + `<dc:title>${DlnaService.escapeXml(title)}</dc:title>`
      + '<upnp:class>object.item.videoItem</upnp:class>'
      + `<res protocolInfo="http-get:*:video/mp4:*">${DlnaService.escapeXml(url)}</res>`
      + '</item></DIDL-Lite>';
    const body = DlnaService.soapEnvelope('SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
      + `<CurrentURI>${DlnaService.escapeXml(url)}</CurrentURI>`
      + `<CurrentURIMetaData>${DlnaService.escapeXml(didl)}</CurrentURIMetaData>`);
    return DlnaService.soap(dev, 'SetAVTransportURI', body);
  }

  static async play(dev: DlnaDevice): Promise<boolean> {
    const body = DlnaService.soapEnvelope('Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
    return DlnaService.soap(dev, 'Play', body);
  }

  static async pause(dev: DlnaDevice): Promise<boolean> {
    const body = DlnaService.soapEnvelope('Pause', '<InstanceID>0</InstanceID>');
    return DlnaService.soap(dev, 'Pause', body);
  }

  static async stop(dev: DlnaDevice): Promise<boolean> {
    const body = DlnaService.soapEnvelope('Stop', '<InstanceID>0</InstanceID>');
    return DlnaService.soap(dev, 'Stop', body);
  }

  /** 跳转到指定秒（设备端 seek） */
  static async seek(dev: DlnaDevice, seconds: number): Promise<boolean> {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = Math.floor(seconds % 60);
    const t = `${DlnaService.pad(h)}:${DlnaService.pad(m)}:${DlnaService.pad(s)}`;
    const body = DlnaService.soapEnvelope('Seek',
      '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit>' + `<Target>${t}</Target>`);
    return DlnaService.soap(dev, 'Seek', body);
  }

  private static pad(n: number): string {
    return n < 10 ? ('0' + n) : String(n);
  }

  private static soapEnvelope(action: string, args: string): string {
    return '<?xml version="1.0" encoding="utf-8"?>'
      + '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      + 's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      + '<s:Body>'
      + `<u:${action} xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">${args}</u:${action}>`
      + '</s:Body></s:Envelope>';
  }

  /** 发起 SOAP 请求 */
  private static async soap(dev: DlnaDevice, action: string, body: string): Promise<boolean> {
    if (!dev.avTransportControlUrl) {
      logError(`[${TAG}] ${action} 失败：设备 ${dev.name} 无 AVTransport 控制地址`);
      return false;
    }
    let req: http.HttpRequest | null = null;
    try {
      req = http.createHttp();
      const resp = await req.request(dev.avTransportControlUrl, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'text/xml; charset="utf-8"',
          // ⭐ SOAPAction 必须带，绝大多数接收端靠它分发动作
          'SOAPAction': `"urn:schemas-upnp-org:service:AVTransport:1#${action}"`
        },
        extraData: body,
        connectTimeout: 8000,
        readTimeout: 8000
      });
      const code = resp.responseCode;
      if (code >= 200 && code < 300) {
        logInfo(`[${TAG}] ${action} 成功 -> ${dev.name}`);
        return true;
      }
      logError(`[${TAG}] ${action} 失败 code=${code} -> ${dev.name}`);
      return false;
    } catch (e) {
      logError(`[${TAG}] ${action} 异常 -> ${dev.name}: ${errMsg(e)}`);
      return false;
    } finally {
      if (req) { try { req.destroy(); } catch (_) {} }
    }
  }

  /** XML 转义（标题里可能有 & < > 会破坏报文） */
  private static escapeXml(s: string): string {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
}
