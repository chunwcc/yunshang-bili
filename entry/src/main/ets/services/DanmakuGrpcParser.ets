/**
 * 弹幕 gRPC Protobuf 二进制解析器
 * 解析 B 站 DmSegMobileReply protobuf 格式
 *
 * proto 定义：
 *   message DmSegMobileReply { repeated DanmakuElem elems = 1; int32 state = 2; }
 *   message DanmakuElem {
 *     int64  id       = 1;  // varint
 *     int32  progress = 2;  // varint (毫秒)
 *     int32  mode     = 3;  // varint
 *     int32  fontsize = 4;  // varint
 *     uint32 color    = 5;  // varint
 *     string midHash  = 6;  // length-delimited
 *     string content  = 7;  // length-delimited
 *     int64  ctime    = 8;  // varint
 *     int32  weight   = 9;  // varint
 *     int32  pool     = 11; // varint
 *   }
 */
import { DanmakuItem, DanmakuItemInit, DanmakuType } from '../model/DanmakuItem'
import { logInfo, logWarn, logError } from '../utils/Logger';
import { util } from '@kit.ArkTS'

// wire type 常量
const WIRETYPE_VARINT = 0
const WIRETYPE_LENGTH_DELIMITED = 2

// 读取结果接口（避免解构赋值，ArkTS 禁止）
interface ReadVarintResult {
  value: number
  newOffset: number
}

interface ReadLengthResult {
  value: Uint8Array
  newOffset: number
}

interface SkipVarintResult {
  newOffset: number
}

export class DanmakuGrpcParser {

  /**
   * 解析 DmSegMobileReply 二进制数据
   * @param data ArrayBuffer（来自 HTTP ArrayBuffer 响应）
   * @returns DanmakuItem[] 弹幕列表
   */
  static parseSegReply(data: ArrayBuffer): DanmakuItem[] {
    const items: DanmakuItem[] = []
    const bytes = new Uint8Array(data)
    let offset = 0

    try {
      while (offset < bytes.length) {
        // 读取 tag (field_number << 3 | wire_type)
        const tagResult = DanmakuGrpcParser.readVarint(bytes, offset)
        const tag = tagResult.value
        offset = tagResult.newOffset

        const fieldNumber = tag >> 3
        const wireType = tag & 0x07

        if (fieldNumber === 1 && wireType === WIRETYPE_LENGTH_DELIMITED) {
          // elems 字段：repeated DanmakuElem，每个是 length-delimited 子消息
          const elemResult = DanmakuGrpcParser.readLengthDelimited(bytes, offset)
          const elemBytes = elemResult.value
          offset = elemResult.newOffset
          const item = DanmakuGrpcParser.parseDanmakuElem(elemBytes)
          if (item) {
            items.push(item)
          }
        } else if (fieldNumber === 2 && wireType === WIRETYPE_VARINT) {
          // state 字段：跳过
          const skipResult = DanmakuGrpcParser.skipVarint(bytes, offset)
          offset = skipResult.newOffset
        } else {
          // 未知字段，跳过
          offset = DanmakuGrpcParser.skipField(bytes, offset, wireType)
        }
      }
    } catch (error) {
      logError(`[DanmakuGrpcParser] 解析错误: ${error}`)
    }

    // 按时间排序
    items.sort((a: DanmakuItem, b: DanmakuItem) => a.time - b.time)
    return items
  }

  /**
   * 解析单条 DanmakuElem 子消息
   */
  private static parseDanmakuElem(bytes: Uint8Array): DanmakuItem | null {
    let offset = 0
    let id = 0
    let progress = 0
    let mode = 0
    let fontsize = 25
    let color = 0xFFFFFF
    let midHash = ''
    let content = ''
    let ctime = 0
    let weight = 0
    let pool = 0

    try {
      while (offset < bytes.length) {
        const tagResult = DanmakuGrpcParser.readVarint(bytes, offset)
        const tag = tagResult.value
        offset = tagResult.newOffset

        const fieldNumber = tag >> 3
        const wireType = tag & 0x07

        switch (fieldNumber) {
          case 1: { // id (int64, varint)
            if (wireType !== WIRETYPE_VARINT) return null
            const readResult = DanmakuGrpcParser.readVarint(bytes, offset)
            id = readResult.value; offset = readResult.newOffset
            break
          }
          case 2: { // progress (int32, varint, 单位毫秒)
            if (wireType !== WIRETYPE_VARINT) return null
            const readResult = DanmakuGrpcParser.readVarint(bytes, offset)
            progress = readResult.value; offset = readResult.newOffset
            break
          }
          case 3: { // mode (int32, varint)
            if (wireType !== WIRETYPE_VARINT) return null
            const readResult = DanmakuGrpcParser.readVarint(bytes, offset)
            mode = readResult.value; offset = readResult.newOffset
            break
          }
          case 4: { // fontsize (int32, varint)
            if (wireType !== WIRETYPE_VARINT) return null
            const readResult = DanmakuGrpcParser.readVarint(bytes, offset)
            fontsize = readResult.value; offset = readResult.newOffset
            break
          }
          case 5: { // color (uint32, varint)
            if (wireType !== WIRETYPE_VARINT) return null
            const readResult = DanmakuGrpcParser.readVarint(bytes, offset)
            color = readResult.value; offset = readResult.newOffset
            break
          }
          case 6: { // midHash (string, length-delimited)
            if (wireType !== WIRETYPE_LENGTH_DELIMITED) return null
            const readResult = DanmakuGrpcParser.readLengthDelimited(bytes, offset)
            midHash = DanmakuGrpcParser.bytesToString(readResult.value); offset = readResult.newOffset
            break
          }
          case 7: { // content (string, length-delimited)
            if (wireType !== WIRETYPE_LENGTH_DELIMITED) return null
            const readResult = DanmakuGrpcParser.readLengthDelimited(bytes, offset)
            content = DanmakuGrpcParser.bytesToString(readResult.value); offset = readResult.newOffset
            break
          }
          case 8: { // ctime (int64, varint, 时间戳秒)
            if (wireType !== WIRETYPE_VARINT) return null
            const readResult = DanmakuGrpcParser.readVarint(bytes, offset)
            ctime = readResult.value; offset = readResult.newOffset
            break
          }
          case 9: { // weight (int32, varint)
            if (wireType !== WIRETYPE_VARINT) return null
            const readResult = DanmakuGrpcParser.readVarint(bytes, offset)
            weight = readResult.value; offset = readResult.newOffset
            break
          }
          case 11: { // pool (int32, varint)
            if (wireType !== WIRETYPE_VARINT) return null
            const readResult = DanmakuGrpcParser.readVarint(bytes, offset)
            pool = readResult.value; offset = readResult.newOffset
            break
          }
          default: {
            // 跳过未知字段
            offset = DanmakuGrpcParser.skipField(bytes, offset, wireType)
            break
          }
        }
      }
    } catch (error) {
      logWarn(`[DanmakuGrpcParser] 单条弹幕解析失败: ${error}`)
      return null
    }

    // 必须有内容才能生成弹幕
    // ⭐ progress 用 < 0 而不是 <= 0：B站 允许"第 0 毫秒"发的弹幕，<= 0 会把它们全丢掉
    if (!content || progress < 0) {
      return null
    }

    const init: DanmakuItemInit = {
      id: id,
      content: content,
      time: progress,          // progress 单位已经是毫秒，不要除 1000！
      type: DanmakuGrpcParser.parseDanmakuType(mode),
      color: color,
      // ⭐ 存【原始字号】，不要在这里放大：放大系数统一由 DanmakuConfig.stdFontSize 决定，
      //    轨道高度也以它为基准（原先这里 ×1.5 而轨道高度取 25，导致相邻轨道压叠）
      fontSize: fontsize > 0 ? fontsize : 25,
      sendTime: ctime * 1000, // 秒转毫秒
      userId: midHash,
      pool: pool,
      weight: weight
    }
    return new DanmakuItem(init)
  }

  /**
   * 读取一个 varint（变长整数）
   */
  private static readVarint(bytes: Uint8Array, offset: number): ReadVarintResult {
    let value = 0
    let shift = 0
    let pos = offset
    while (pos < bytes.length) {
      const b = bytes[pos]
      value |= (b & 0x7F) << shift
      shift += 7
      pos++
      if ((b & 0x80) === 0) {
        return { value: value, newOffset: pos }
      }
    }
    throw new Error('不完整的 varint')
  }

  /**
   * 读取一个 length-delimited 字段（先读 varint 长度，再读字节数据）
   */
  private static readLengthDelimited(bytes: Uint8Array, offset: number): ReadLengthResult {
    const lenResult = DanmakuGrpcParser.readVarint(bytes, offset)
    const len = lenResult.value
    const start = lenResult.newOffset
    if (len < 0 || start + len > bytes.length) {
      throw new Error(`length-delimited 长度无效: ${len}`)
    }
    return {
      value: bytes.slice(start, start + len),
      newOffset: start + len
    }
  }

  /**
   * 跳过 varint 值（只前进偏移量）
   */
  private static skipVarint(bytes: Uint8Array, offset: number): SkipVarintResult {
    let pos = offset
    while (pos < bytes.length) {
      if ((bytes[pos] & 0x80) === 0) {
        return { newOffset: pos + 1 }
      }
      pos++
    }
    throw new Error('不完整的 varint（skip）')
  }

  /**
   * 根据 wire type 跳过字段
   */
  private static skipField(bytes: Uint8Array, offset: number, wireType: number): number {
    switch (wireType) {
      case WIRETYPE_VARINT: {
        const skipResult = DanmakuGrpcParser.skipVarint(bytes, offset)
        return skipResult.newOffset
      }
      case WIRETYPE_LENGTH_DELIMITED: {
        const readResult = DanmakuGrpcParser.readVarint(bytes, offset)
        return readResult.newOffset + readResult.value
      }
      default:
        // 无法跳过的 wire type，抛异常
        throw new Error(`不支持的 wire type: ${wireType}`)
    }
  }

  /**
   * Uint8Array 转 UTF-8 字符串
   */
  private static bytesToString(bytes: Uint8Array): string {
    const decoder = util.TextDecoder.create('utf-8')
    return decoder.decodeToString(bytes)
  }

  /**
   * 解析弹幕类型（B站 mode → DanmakuType）
   */
  private static parseDanmakuType(mode: number): DanmakuType {
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
}
