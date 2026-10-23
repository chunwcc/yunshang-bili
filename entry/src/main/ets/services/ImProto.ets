/**
 * B站 IM 私信 protobuf 编解码器（手写最小实现，无第三方库）
 *
 * 仅实现 B 站 IM 接口（bilibili.im.interface.v1 / bilibili.im.type）用到的
 * wire format：varint（int32/int64）、length-delimited（string/message）。
 * int64 用 number 承载（JS number 可精确表示 2^53 内整数，B站 uid/seqno 实测安全）。
 */
import { util } from '@kit.ArkTS';

/** protobuf wire type 常量 */
export class WireType {
  /** varint：int32/int64/uint32/bool/enum */
  static readonly VARINT: number = 0;
  /** 64-bit：fixed64/sfixed64/double */
  static readonly FIXED64: number = 1;
  /** length-delimited：string/bytes/嵌套 message/打包的 repeated */
  static readonly LENGTH_DELIMITED: number = 2;
  /** 32-bit：fixed32/sfixed32/float */
  static readonly FIXED32: number = 5;
}

/**
 * protobuf 写入器：把字段追加到字节缓冲
 */
export class ProtoWriter {
  private bytes: number[] = [];

  /**
   * 写入一个 varint（支持到 2^53 的整数）
   */
  writeVarint(value: number): void {
    let v = Math.floor(value);
    while (v >= 0x80) {
      this.bytes.push((v & 0x7f) | 0x80);
      v = Math.floor(v / 128);
    }
    this.bytes.push(v);
  }

  /**
   * 写入字段 tag（field 号 + wire type）
   */
  writeTag(field: number, wireType: number): void {
    this.writeVarint((field << 3) | wireType);
  }

  /**
   * 写入 int32/int64 字段（wire type 0）
   */
  writeIntField(field: number, value: number): void {
    if (value === 0) {
      return;
    }
    this.writeTag(field, WireType.VARINT);
    this.writeVarint(value);
  }

  /**
   * 写入 string 字段（wire type 2）
   */
  writeStringField(field: number, value: string): void {
    if (value.length === 0) {
      return;
    }
    this.writeTag(field, WireType.LENGTH_DELIMITED);
    const encoder = util.TextEncoder.create();
    const utf8 = encoder.encodeInto(value);
    this.writeVarint(utf8.length);
    for (let i = 0; i < utf8.length; i++) {
      this.bytes.push(utf8[i]);
    }
  }

  /**
   * 写入嵌套 message 字段（wire type 2，先写子消息字节）
   */
  writeMessageField(field: number, message: Uint8Array): void {
    this.writeTag(field, WireType.LENGTH_DELIMITED);
    this.writeVarint(message.length);
    for (let i = 0; i < message.length; i++) {
      this.bytes.push(message[i]);
    }
  }

  /**
   * 写入原始字节（用于整段拼接）
   */
  writeBytes(raw: number[]): void {
    for (let i = 0; i < raw.length; i++) {
      this.bytes.push(raw[i]);
    }
  }

  /**
   * 输出为 Uint8Array
   */
  toUint8Array(): Uint8Array {
    const out = new Uint8Array(this.bytes.length);
    for (let i = 0; i < this.bytes.length; i++) {
      out[i] = this.bytes[i];
    }
    return out;
  }
}

/**
 * protobuf 读取器：按字段遍历解析
 */
export class ProtoReader {
  private data: Uint8Array;
  private pos: number = 0;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  /**
   * 是否已读完
   */
  isEnd(): boolean {
    return this.pos >= this.data.length;
  }

  /**
   * 剩余未读字节数
   */
  remaining(): number {
    return this.data.length - this.pos;
  }

  /**
   * 读取下一个 tag，返回 [field, wireType]；-1 表示结束
   */
  readTag(): number[] {
    if (this.pos >= this.data.length) {
      return [-1, -1];
    }
    const tag = this.readVarint();
    return [tag >>> 3, tag & 0x7];
  }

  /**
   * 读取 varint（支持到 2^53；用乘法避免 32 位位移溢出）
   */
  readVarint(): number {
    let value = 0;
    let shift = 0;
    while (true) {
      const b = this.data[this.pos];
      this.pos++;
      value += (b & 0x7f) * Math.pow(2, shift);
      if ((b & 0x80) === 0) {
        break;
      }
      shift += 7;
    }
    return value;
  }

  /**
   * 读取 length-delimited 的字节段（用于 string / message / bytes）
   */
  readBytes(): Uint8Array {
    const len = this.readVarint();
    const start = this.pos;
    this.pos += len;
    return this.data.slice(start, start + len);
  }

  /**
   * 读取 string 字段值
   */
  readString(): string {
    const bytes = this.readBytes();
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(bytes);
  }

  /**
   * 跳过未知字段
   */
  skipField(wireType: number): void {
    switch (wireType) {
      case WireType.VARINT:
        this.readVarint();
        break;
      case WireType.LENGTH_DELIMITED:
        this.readBytes();
        break;
      case WireType.FIXED64:
        this.pos += 8;
        break;
      case WireType.FIXED32:
        this.pos += 4;
        break;
      default:
        // 未知 wire type：无法解析，跳到末尾避免死循环
        this.pos = this.data.length;
        break;
    }
  }
}
