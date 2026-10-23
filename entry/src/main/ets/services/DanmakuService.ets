/**
 * 弹幕数据获取服务
 * 支持HTTP分段加载和WebSocket实时弹幕
 */
import { http, webSocket } from '@kit.NetworkKit'
import { logInfo, logWarn, logError } from '../utils/Logger';
import { util } from '@kit.ArkTS'
import { DanmakuItem, DanmakuItemInit, DanmakuType, DanmakuSegment, DanmakuSegmentInit } from '../model/DanmakuItem'
import { DanmakuGrpcParser } from './DanmakuGrpcParser'
import { AppSign } from '../utils/SignUtils'

// B站弹幕API响应接口
interface DanmakuApiResponse {
  code: number
  message: string
  data: DanmakuApiData
}

interface DanmakuApiData {
  dm: DanmakuApiItem[]
}

interface DanmakuApiItem {
  id: number
  progress: number
  mode: number
  fontsize: number
  color: number
  midHash: string
  content: string
  ctime: number
  weight: number
  pool: number
}

// WebSocket弹幕消息
interface WsDanmakuMessage {
  cmd: string
  info: Object[]
}

export class DanmakuService {
  private static readonly SEGMENT_DURATION = 360000  // 6分钟（毫秒）
  private static readonly BASE_URL = 'https://api.bilibili.com'
  private static readonly DM_SEG_URL = 'https://api.bilibili.com/x/v2/dm/web/seg.so'

  private httpRequest: http.HttpRequest | null = null
  private cookie: string = ''
  private wsConnection: webSocket.WebSocket | null = null

  constructor() {
    this.httpRequest = http.createHttp()
  }

  /**
   * 设置Cookie（用于登录态）
   */
  setCookie(cookie: string): void {
    this.cookie = cookie
  }

  /**
   * 获取弹幕分段索引
   * 根据视频时长计算需要加载的分段数量
   */
  calculateSegmentCount(duration: number): number {
    // duration: 毫秒
    const segmentCount = Math.ceil(duration / DanmakuService.SEGMENT_DURATION)
    return Math.max(1, segmentCount)
  }

  /**
   * 加载指定分段的弹幕
   * @param cid 视频cid
   * @param segmentIndex 分段索引（从1开始）
   * @param apiSource 弹幕数据源 'xml' | 'grpc'
   */
  async loadDanmakuSegment(cid: number, segmentIndex: number, apiSource?: string): Promise<DanmakuSegment> {
    // ⭐ gRPC Protobuf 模式：全量分段加载
    if (apiSource === 'grpc') {
      return this.loadDanmakuSegmentGrpc(cid, segmentIndex)
    }

    // XML 模式（原有逻辑）
    const init: DanmakuSegmentInit = {
      segmentIndex: segmentIndex,
      startTime: (segmentIndex - 1) * DanmakuService.SEGMENT_DURATION,
      endTime: segmentIndex * DanmakuService.SEGMENT_DURATION
    }
    const segment = new DanmakuSegment(init)

    try {
      // 第一段：尝试加载真实弹幕
      if (segmentIndex === 1) {
        logInfo(`[DanmakuService] 尝试加载真实弹幕: cid=${cid}`)
        const realItems = await this.loadXmlDanmaku(cid)
        if (realItems.length > 0) {
          segment.items = realItems
          segment.loaded = true
          logInfo(`[DanmakuService] 真实弹幕加载成功，共 ${realItems.length} 条`)
          return segment
        }
        logWarn('[DanmakuService] 真实弹幕加载失败，使用模拟数据')
      }
      
      // 非第一段：不生成模拟数据（真实弹幕已在第一段全部加载）
      if (segmentIndex > 1) {
        segment.items = []
        segment.loaded = true
        logInfo(`[DanmakuService] 分段 ${segmentIndex} 跳过（真实弹幕已在第一段加载）`)
        return segment
      }
      
      // 第一段且真实弹幕加载失败
      segment.items = []
      segment.loaded = true
      logWarn(`[DanmakuService] 分段 ${segmentIndex} 无可用弹幕`)
    } catch (error) {
      logError(`[DanmakuService] 分段 ${segmentIndex} 加载异常: ${error}`)
    }

    return segment
  }

  /**
   * gRPC Protobuf 分段加载弹幕
   * 使用 B 站弹幕分段接口获取全量弹幕数据
   * @param cid 视频cid
   * @param segmentIndex 分段索引（从1开始）
   */
  async loadDanmakuSegmentGrpc(cid: number, segmentIndex: number): Promise<DanmakuSegment> {
    const init: DanmakuSegmentInit = {
      segmentIndex: segmentIndex,
      startTime: (segmentIndex - 1) * DanmakuService.SEGMENT_DURATION,
      endTime: segmentIndex * DanmakuService.SEGMENT_DURATION
    }
    const segment = new DanmakuSegment(init)

    try {
      logInfo(`[DanmakuService] gRPC加载分段: cid=${cid}, segment=${segmentIndex}`)

      if (!this.httpRequest) {
        this.httpRequest = http.createHttp()
      }

      const url = `${DanmakuService.DM_SEG_URL}?type=1&oid=${cid}&segment_index=${segmentIndex}`
      logInfo(`[DanmakuService] gRPC请求: ${url}`)

      const response = await this.httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/',
          'Cookie': this.cookie
        },
        connectTimeout: 10000,
        readTimeout: 10000
      })

      logInfo(`[DanmakuService] gRPC响应: code=${response.responseCode}`)

      if (response.responseCode === 200 && response.result) {
        // 响应可能是 ArrayBuffer
        let buffer: ArrayBuffer
        if (response.result instanceof ArrayBuffer) {
          buffer = response.result as ArrayBuffer
        } else if (typeof response.result === 'object') {
          const str = String(response.result)
          if (str === '[object ArrayBuffer]') {
            buffer = response.result as ArrayBuffer
          } else {
            logWarn('[DanmakuService] gRPC响应不是ArrayBuffer，尝试文本回退')
            const items = this.parseXmlDanmaku(str)
            segment.items = items
            segment.loaded = true
            logInfo(`[DanmakuService] gRPC文本回退解析，${items.length} 条弹幕`)
            return segment
          }
        } else {
          logWarn(`[DanmakuService] gRPC未知响应类型: ${typeof response.result}`)
          segment.loaded = true
          return segment
        }

        const items = DanmakuGrpcParser.parseSegReply(buffer)
        segment.items = items
        segment.loaded = true
        logInfo(`[DanmakuService] gRPC分段 ${segmentIndex} 加载成功，共 ${items.length} 条弹幕`)
      } else {
        logWarn(`[DanmakuService] gRPC分段 ${segmentIndex} 请求失败: ${response.responseCode}`)
        segment.loaded = true
      }
    } catch (error) {
      logError(`[DanmakuService] gRPC分段 ${segmentIndex} 加载异常: ${error}`)
      segment.loaded = true
    }

    return segment
  }

  /**
   * 加载历史弹幕（旧版API，JSON格式）
   * 用于兼容不支持分段加载的场景
   */
  async loadHistoryDanmaku(cid: number, aid: number): Promise<DanmakuItem[]> {
    // 先尝试XML API（更可靠）
    const xmlItems = await this.loadXmlDanmaku(cid)
    if (xmlItems.length > 0) {
      return xmlItems
    }

    // XML失败则尝试JSON API
    try {
      const url = `${DanmakuService.BASE_URL}/x/v2/dm/history?type=1&oid=${cid}&pid=${aid}`

      logInfo(`[DanmakuService] 加载历史弹幕: ${url}`)

      if (!this.httpRequest) {
        this.httpRequest = http.createHttp()
      }

      const response = await this.httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/',
          'Cookie': this.cookie
        },
        connectTimeout: 10000,
        readTimeout: 10000
      })

      if (response.responseCode === 200) {
        const result = JSON.parse(response.result as string) as DanmakuApiResponse
        if (result.code === 0 && result.data && result.data.dm) {
          const items = this.parseJsonDanmaku(result.data.dm)
          logInfo(`[DanmakuService] 历史弹幕加载成功，共 ${items.length} 条`)
          return items
        }
      }
    } catch (error) {
      logError(`[DanmakuService] 历史弹幕加载异常: ${error}`)
    }

    return []
  }

  /**
   * 加载XML格式弹幕（使用旧版弹幕API）
   * 旧版弹幕API返回XML格式，可以直接解析
   */
  async loadXmlDanmaku(cid: number): Promise<DanmakuItem[]> {
    logInfo(`[DanmakuService] loadXmlDanmaku被调用: cid=${cid}`)
    
    // 尝试多个弹幕API端点
    const apiEndpoints = [
      `https://comment.bilibili.com/${cid}.xml`,  // 旧版弹幕API（最可靠）
      `https://api.bilibili.com/x/v2/dm/list.so?oid=${cid}`  // 备用API
    ]
    
    for (const url of apiEndpoints) {
      try {
        logInfo(`[DanmakuService] 尝试弹幕API: ${url}`)

        if (!this.httpRequest) {
          this.httpRequest = http.createHttp()
        }

        const response = await this.httpRequest.request(url, {
          method: http.RequestMethod.GET,
          header: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Referer': 'https://www.bilibili.com/',
            'Cookie': this.cookie
          },
          connectTimeout: 10000,
          readTimeout: 10000
        })

        logInfo(`[DanmakuService] 弹幕响应: code=${response.responseCode}`)

        if (response.responseCode === 200) {
          logInfo(`[DanmakuService] response.result类型: ${typeof response.result}`)
          
          let resultText = ''
          
          // 处理响应数据
          if (typeof response.result === 'string') {
            resultText = response.result as string
          } else if (response.result && typeof response.result === 'object') {
            const str = String(response.result)
            if (str === '[object ArrayBuffer]') {
              // ArrayBuffer转字符串
              const buffer = response.result as ArrayBuffer
              const decoder = util.TextDecoder.create('utf-8')
              resultText = decoder.decodeToString(new Uint8Array(buffer))
            }
          }
          
          logInfo(`[DanmakuService] 响应内容长度: ${resultText.length}`)
          logInfo(`[DanmakuService] 响应内容预览: ${resultText.substring(0, 300)}`)
          
          // 尝试XML解析
          const items = this.parseXmlDanmaku(resultText)
          if (items.length > 0) {
            logInfo(`[DanmakuService] XML弹幕加载成功，共 ${items.length} 条`)
            return items
          }
        }
      } catch (error) {
        logError(`[DanmakuService] 弹幕API加载异常: ${error}`)
      }
    }
    
    logError('[DanmakuService] 所有弹幕API都加载失败')
    return []
  }

  /**
   * 解析XML格式弹幕
   * 格式: <d p="时间,类型,字号,颜色,时间戳,池,用户Hash,弹幕ID">弹幕内容</d>
   */
  private parseXmlDanmaku(xmlText: string): DanmakuItem[] {
    const items: DanmakuItem[] = []

    try {
      // 使用正则匹配所有<d>标签
      const regex = /<d p="([^"]+)">([^<]*)<\/d>/g
      let match: RegExpExecArray | null

      while ((match = regex.exec(xmlText)) !== null) {
        const p = match[1].split(',')
        const content = match[2]

        if (p.length >= 8) {
          // B站弹幕fontSize: 18(超小)、25(小)、36(中)、45(大)、64(超大)
          // ⭐ 存【原始字号】即可：×1.5 的放大统一由 DanmakuConfig.stdFontSize 决定，
          //    轨道高度也以它为基准 —— 原先这里放大而轨道高度取 25，相邻轨道会压叠约 32%
          const rawFontSize = parseInt(p[2]) || 25
          const init: DanmakuItemInit = {
            id: parseInt(p[7]) || Date.now(),
            content: content,
            time: parseFloat(p[0]) * 1000,  // 转换为毫秒
            type: this.parseDanmakuType(parseInt(p[1])),
            color: parseInt(p[3]) || 0xFFFFFF,
            fontSize: rawFontSize,
            sendTime: parseInt(p[4]) * 1000,
            userId: p[6],
            pool: parseInt(p[5]) || 0,
            weight: 1
          }
          const item = new DanmakuItem(init)
          items.push(item)
        }
      }

      // 按时间排序
      items.sort((a: DanmakuItem, b: DanmakuItem) => a.time - b.time)
    } catch (error) {
      logError(`[DanmakuService] XML解析异常: ${error}`)
    }

    return items
  }

  /**
   * 解析JSON格式弹幕
   */
  private parseJsonDanmaku(apiItems: DanmakuApiItem[]): DanmakuItem[] {
    const items: DanmakuItem[] = []

    apiItems.forEach((apiItem: DanmakuApiItem) => {
      const init: DanmakuItemInit = {
        id: apiItem.id,
        content: apiItem.content,
        time: apiItem.progress,
        type: this.parseDanmakuType(apiItem.mode),
        color: apiItem.color,
        fontSize: apiItem.fontsize,
        sendTime: apiItem.ctime * 1000,
        userId: apiItem.midHash,
        pool: apiItem.pool,
        weight: apiItem.weight
      }
      const item = new DanmakuItem(init)
      items.push(item)
    })

    // 按时间排序
    items.sort((a: DanmakuItem, b: DanmakuItem) => a.time - b.time)
    return items
  }

  /**
   * 解析Protobuf格式弹幕
   * 注意：这里简化处理，实际需要使用protobuf库
   */
  private parseProtobufDanmaku(data: ArrayBuffer): DanmakuItem[] {
    const items: DanmakuItem[] = []
    
    try {
      const bytes = new Uint8Array(data)
      logInfo(`[DanmakuService] Protobuf数据长度: ${bytes.length}字节`)
      
      // 简化的protobuf解析
      // B站弹幕protobuf格式: 每条弹幕包含多个字段
      // 字段1: id (varint)
      // 字段2: progress/time (varint)
      // 字段3: mode (varint)
      // 字段4: fontsize (varint)
      // 字段5: color (varint)
      // 字段6: midHash (string)
      // 字段7: content (string)
      // 字段8: ctime (varint)
      // ...
      
      let i = 0
      let danmakuCount = 0
      
      while (i < bytes.length - 10) {
        // 查找弹幕开始标记（字段标记）
        // 弹幕通常以0x0a（字段1，wire type 2）开始
        if (bytes[i] === 0x0a && bytes[i + 1] > 0 && bytes[i + 1] < 100) {
          const length = bytes[i + 1]
          
          // 尝试解析这条弹幕
          try {
            const danmaku = this.parseSingleDanmaku(bytes, i + 2, length)
            if (danmaku) {
              items.push(danmaku)
              danmakuCount++
              i += length + 2
              continue
            }
          } catch (e) {
            logWarn(`[DanmakuService] Protobuf单条弹幕解析失败: ${e}`);
            // 解析失败，继续查找
          }
        }
        i++
      }
      
      // 如果上面方法没找到，尝试从文本中提取
      if (items.length === 0) {
        logInfo(`[DanmakuService] 尝试从文本提取弹幕`)
        const decoder = util.TextDecoder.create('utf-8')
        const text = decoder.decodeToString(bytes)
        
        // 查找中文弹幕内容（2-50个字符）
        const regex = /[\u4e00-\u9fa5\u3000-\u303f\uff00-\uffef0-9a-zA-Z\s,.!?;:'"()（）【】《》\-=+@#$%^&*]{2,50}/g
        const matches = text.match(regex)
        
        if (matches) {
          let time = 0
          for (const match of matches) {
            // 过滤无效内容
            if (match.length < 2 || match.length > 50) continue
            if (match.includes('http') || match.includes('bilibili')) continue
            if (/^\d+$/.test(match)) continue
            if (/^[a-f0-9]+$/i.test(match)) continue
            if (!/[\u4e00-\u9fa5]/.test(match)) continue // 必须包含中文
            
            const init: DanmakuItemInit = {
              id: Date.now() + Math.random(),
              content: match.trim(),
              time: time,
              type: DanmakuType.ROLL,
              fontSize: 25,
              color: 0xFFFFFF,
              sendTime: Date.now()
            }
            items.push(new DanmakuItem(init))
            time += 1
          }
        }
      }
      
      logInfo(`[DanmakuService] 解析出 ${items.length} 条弹幕`)
    } catch (error) {
      logError(`[DanmakuService] Protobuf解析失败: ${error}`)
    }
    
    return items
  }
  
  /**
   * 解析单条弹幕
   */
  private parseSingleDanmaku(bytes: Uint8Array, start: number, length: number): DanmakuItem | null {
    try {
      let pos = start
      const end = start + length
      
      let id = 0
      let progress = 0
      let mode = 1
      let fontSize = 25
      let color = 0xFFFFFF
      let content = ''
      
      while (pos < end) {
        const fieldByte = bytes[pos]
        const fieldNumber = fieldByte >> 3
        const wireType = fieldByte & 0x07
        pos++
        
        if (wireType === 0) {
          // Varint
          let value = 0
          let shift = 0
          while (pos < end) {
            const b = bytes[pos++]
            value |= (b & 0x7f) << shift
            shift += 7
            if ((b & 0x80) === 0) break
          }
          
          switch (fieldNumber) {
            case 1: id = value; break
            case 2: progress = value; break
            case 3: mode = value; break
            case 4: fontSize = value; break
            case 5: color = value; break
          }
        } else if (wireType === 2) {
          // Length-delimited (string)
          let strLen = 0
          let shift = 0
          while (pos < end) {
            const b = bytes[pos++]
            strLen |= (b & 0x7f) << shift
            shift += 7
            if ((b & 0x80) === 0) break
          }
          
          if (fieldNumber === 7 && strLen > 0 && strLen < 200) {
            // 字段7是弹幕内容
            const strBytes = bytes.slice(pos, pos + strLen)
            const decoder = util.TextDecoder.create('utf-8')
            content = decoder.decodeToString(strBytes)
          }
          pos += strLen
        } else {
          // 跳过其他类型
          break
        }
      }
      
      if (content && progress > 0) {
        const init: DanmakuItemInit = {
          id: id || Date.now(),
          content: content,
          time: progress / 1000, // 毫秒转秒
          type: this.parseDanmakuType(mode),
          fontSize: fontSize,
          color: color,
          sendTime: Date.now()
        }
        return new DanmakuItem(init)
      }
    } catch (e) {
      logWarn(`[DanmakuService] API弹幕项解析失败: ${e}`);
      // 解析失败
      return null
    }
    
    return null
  }

  /**
   * 解析弹幕类型
   */
  private parseDanmakuType(mode: number): DanmakuType {
    switch (mode) {
      case 1:
      case 2:
      case 3:
        return DanmakuType.ROLL
      case 4:
        return DanmakuType.BOTTOM
      case 5:
        return DanmakuType.TOP
      case 6:
        return DanmakuType.REVERSE
      case 7:
        return DanmakuType.ADVANCED
      case 8:
        return DanmakuType.SCRIPT
      case 9:
        return DanmakuType.TOP_FIXED
      default:
        return DanmakuType.ROLL
    }
  }

  /**
   * 连接WebSocket实时弹幕（直播场景）
   * @param roomId 直播间ID
   */
  async connectWebSocket(roomId: number, onDanmaku: (item: DanmakuItem) => void): Promise<void> {
    try {
      // 获取WebSocket地址
      const wsUrl = await this.getWebSocketUrl(roomId)

      logInfo(`[DanmakuService] 连接WebSocket: ${wsUrl}`)

      // 创建WebSocket连接
      // 注意：HarmonyOS WebSocket API需要单独处理
      // this.wsConnection = new WebSocket()
      // await this.wsConnection.connect(wsUrl)

      // 监听消息
      // this.wsConnection.on('message', (data: string) => {
      //   const item = this.parseWebSocketDanmaku(data)
      //   if (item) {
      //     onDanmaku(item)
      //   }
      // })

      logWarn('[DanmakuService] WebSocket连接未完全实现')
    } catch (error) {
      logError(`[DanmakuService] WebSocket连接失败: ${error}`)
    }
  }

  /**
   * 获取WebSocket地址
   */
  private async getWebSocketUrl(roomId: number): Promise<string> {
    try {
      const url = `https://api.live.bilibili.com/room/v1/Danmu/getConf?room_id=${roomId}`

      if (!this.httpRequest) {
        this.httpRequest = http.createHttp()
      }

      const response = await this.httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://live.bilibili.com/',
          'Cookie': this.cookie
        }
      })

      if (response.responseCode === 200) {
        const result = JSON.parse(response.result as string) as Record<string, Object>
        if (result['code'] === 0) {
          const data = result['data'] as Record<string, Object>
          const host = (data['host'] as string) || 'broadcastlv.chat.bilibili.com'
          const port = (data['port'] as number) || 2243
          return `wss://${host}:${port}/sub`
        }
      }
    } catch (error) {
      logError(`[DanmakuService] 获取WebSocket地址失败: ${error}`)
    }

    return ''
  }

  /**
   * 解析WebSocket弹幕消息
   */
  private parseWebSocketDanmaku(data: string): DanmakuItem | null {
    try {
      const message = JSON.parse(data) as WsDanmakuMessage

      if (message.cmd === 'DANMU_MSG') {
        const info = message.info
        if (info && info.length >= 2) {
          const content = info[1] as string
          const info0 = info[0] as Object[]
          const time = (info0[0] as number) || 0
          const color = (info0[3] as number) || 0xFFFFFF

          const init: DanmakuItemInit = {
            id: Date.now(),
            content: content,
            time: time * 1000,
            color: color
          }
          return new DanmakuItem(init)
        }
      }
    } catch (error) {
      logError(`[DanmakuService] WebSocket弹幕解析失败: ${error}`)
    }

    return null
  }

  /**
   * 销毁服务
   */
  destroy(): void {
    if (this.httpRequest) {
      this.httpRequest.destroy()
      this.httpRequest = null
    }
    // WebSocket连接清理
    // if (this.wsConnection) {
    //   this.wsConnection.close()
    //   this.wsConnection = null
    // }
  }
}
