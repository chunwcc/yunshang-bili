import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = '[DashProbe]';

export interface InitSegmentInfo {
  initRange: string;
  indexRange: string;
  contentLength: number;
  /** ⭐ moov 内 mdhd 解析出的媒体时基（真实 timescale） */
  timescale: number;
  /** ⭐ sidx 条目列表（每项是 moof/mdat 子段的大小），SegmentTemplate 虚拟分段用 */
  segments: Array<SegmentEntry>;
  /** ⭐ 探测已下载的头部字节（覆盖 initRange=0-moovEnd），转播站 init 路由命中时零回源 */
  headBuffer?: ArrayBuffer;
}

export interface SegmentEntry {
  /** 字节长度（含 moof+mdat） */
  size: number;
  /** 时长（按 media timescale） */
  duration: number;
  /** 相对 sidx 首个引用起点（+sidx 的 firstOffset 之前）的累计字节偏移；首个为 0 */
  fileOffset: number;
  /** sidx earliestPresentationTime 首个条目（用于校验） */
  startTime: number;
}

/** 探测胜出的结果：既给出 info，也给出「哪个 CDN 给的」——后续回源全部走它 */
export interface ProbeWinner {
  info: InitSegmentInfo | null;
  /** 胜出 URL（全部失败时回落到首个候选） */
  url: string;
  /** 探测耗时（毫秒），仅用于日志对比 */
  costMs: number;
}

/** 竞速候选上限：baseUrl + backupUrl 前 3 个；再多只是多花 4KB 请求数 */
const MAX_RACE_CANDIDATES = 4;

/**
 * ⭐ 多 CDN 竞速探测：并行探测 baseUrl + backupUrl，取最先成功的那个。
 *
 * 为什么需要：B 站 playurl 对同一视频会下发多个 CDN 候选，而各节点速度差异极大 ——
 * 实测同一轮日志里 `150.139.*` 约 3.3MB/s，`144.123.*` 只有 0.7~1MB/s（差 3~4 倍）。
 * 旧实现只用 `baseUrl`（CDN 由 B 站排第一的那个决定），碰上慢节点时：
 * 4K 首段 6.5MB 要 6~9 秒、seek 段（8~10MB/段）更糟 ⇒ 起播 10 秒级。
 *
 * 只探测文件头（4KB 起、必要时升级窗口），成本极低；胜出者同时把 headBuffer 带回来，
 * 后续 init 请求零回源。
 */
export async function probeFastestInitSegment(
  urls: Array<string>,
  referer: string,
  userAgent: string,
  cookie: string
): Promise<ProbeWinner> {
  const candidates: Array<string> = [];
  for (let i = 0; i < urls.length && candidates.length < MAX_RACE_CANDIDATES; i++) {
    const u: string = urls[i];
    if (u && candidates.indexOf(u) < 0) {
      candidates.push(u);
    }
  }
  if (candidates.length === 0) {
    return { info: null, url: '', costMs: 0 };
  }
  if (candidates.length === 1) {
    const t0 = Date.now();
    const info = await probeM4sInitSegment(candidates[0], referer, userAgent, cookie);
    return { info: info, url: candidates[0], costMs: Date.now() - t0 };
  }

  const startAt = Date.now();
  const winner: ProbeWinner = await new Promise<ProbeWinner>((resolve: (w: ProbeWinner) => void) => {
    let pending: number = candidates.length;
    let settled: boolean = false;
    const fail = (): void => {
      if (settled) {
        return;
      }
      pending--;
      if (pending <= 0) {
        settled = true;
        resolve({ info: null, url: candidates[0], costMs: Date.now() - startAt });
      }
    };
    for (let i = 0; i < candidates.length; i++) {
      const u: string = candidates[i];
      probeM4sInitSegment(u, referer, userAgent, cookie).then((info: InitSegmentInfo | null) => {
        if (settled) {
          return;
        }
        if (info) {
          settled = true;
          const cost = Date.now() - startAt;
          console.info(`${TAG} CDN 竞速胜出(${cost}ms, 候选${candidates.length}): ${u.substring(0, 56)}...`);
          resolve({ info: info, url: u, costMs: cost });
        } else {
          fail();
        }
      }).catch((_e: Error) => {
        fail();
      });
    }
  });
  return winner;
}

/**
 * 探测 m4s 初始化分段的 Range。
 * B 站长视频（>10 分钟 1080p）的 moov/sidx 索引表可达数百 KB，因此按
 * 4KB → 64KB → 512KB → 2MB 递增探测；任一档命中 moov 且 moov/sidx
 * 都完整包含在窗口内即返回，否则升级到更大窗口重试；
 * 全失败再回退到文件尾部探测（moof/mdat 结尾的变体）。
 */
export async function probeM4sInitSegment(
  m4sUrl: string,
  referer: string,
  userAgent: string,
  cookie: string
): Promise<InitSegmentInfo | null> {
  const ladder: number[] = [4096, 65536, 524288, 2097152];
  for (let i = 0; i < ladder.length; i++) {
    const r = await probeRangeScan(m4sUrl, referer, userAgent, cookie, ladder[i]);
    if (r.info) {
      if (!r.needsLarger) {
        return r.info;
      }
      console.warn(`${TAG} moov/sidx 被 ${ladder[i]} 窗口截断，升级探测`);
      continue;
    }
    console.warn(`${TAG} moov not in first ${ladder[i]} bytes`);
  }

  console.warn(`${TAG} moov not found in header, trying tail probe`);
  return await probeTail(m4sUrl, referer, userAgent, cookie);
}

/** 单档探测结果：info 命中即返回；needsLarger 表示 moov/sidx 被窗口截断需更大窗口 */
interface ProbeScanResult {
  info: InitSegmentInfo | null;
  needsLarger: boolean;
}

/** 单档 Range 探测：扫 [0, probeSize) 窗口，命中 moov 头即构造 Range 结果 */
async function probeRangeScan(
  m4sUrl: string,
  referer: string,
  userAgent: string,
  cookie: string,
  probeSize: number
): Promise<ProbeScanResult> {
  const headers: Record<string, string> = {
    'User-Agent': userAgent,
    'Referer': referer,
    'Origin': 'https://www.bilibili.com',
    'Range': `bytes=0-${probeSize - 1}`
  };
  if (cookie) {
    headers['Cookie'] = cookie;
  }

  try {
    const httpRequest = http.createHttp();
    const response = await httpRequest.request(m4sUrl, {
      method: http.RequestMethod.GET,
      header: headers,
      // ⭐ 修复：默认 STRING 会把二进制结果解码为字符串导致扫描失败
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 15000
    });
    httpRequest.destroy();

    if (response.responseCode !== 206 && response.responseCode !== 200) {
      console.error(`${TAG} probe HTTP ${response.responseCode}`);
      return { info: null, needsLarger: false };
    }

    const buf = response.result as ArrayBuffer;
    const view = new Uint8Array(buf);

    let moovEnd = -1;
    let moovStart = -1;
    let sidxStart = -1;
    let sidxEnd = -1;
    let needsLarger = false;
    let offset = 0;
    while (offset + 8 <= view.length) {
      const boxSize = readBoxSize(view, offset);
      const boxType = readBoxType(view, offset);
      console.info(`${TAG} probe ${probeSize} box@${offset}: ${boxType} size=${boxSize}`);
      const boxEnd = offset + boxSize;

      if (boxType === 'moov') {
        moovStart = offset;
        moovEnd = offset + boxSize - 1;
        // ⭐ moov/sidx 盒子越出窗口：当前档只看到头部，数据不可信 → 升级重试
        if (boxEnd > view.length) {
          needsLarger = true;
        }
      } else if (boxType === 'sidx') {
        sidxStart = offset;
        sidxEnd = offset + boxSize - 1;
        if (boxEnd > view.length) {
          needsLarger = true;
        }
      }

      if (boxSize === 0 || boxSize === 1) {
        break;
      }
      offset += boxSize;
    }

    if (moovEnd < 0) {
      return { info: null, needsLarger: false };
    }

    // ⭐ 解析 moov 内 mdhd 的真实 timescale（视频轨/音频轨可能不同）
    let timescale: number = parseMdhdTimescale(view, moovStart);
    if (timescale <= 0) {
      timescale = 1000; // 兜底：多数 mp4 默认
    }
    console.info(`${TAG} timescale=${timescale}`);

    // 解析 content-range 里的全量大小（206 才有；无则用 content-length）
    const headerObj = response.header as Record<string, string>;
    const contentLength = Number(headerObj['content-length']) || 0;
    const contentRange = headerObj['content-range'] || '';
    const rangeParts = contentRange.split('/');
    const fullContentLength = rangeParts.length > 1 ? Number(rangeParts[1]) || contentLength : contentLength;
    if (fullContentLength > 0 && moovEnd >= fullContentLength) {
      console.warn(`${TAG} moovEnd(${moovEnd}) >= total(${fullContentLength}), clamp`);
      moovEnd = fullContentLength - 1;
    }

    // ⭐ init = ftyp+moov 边界；sidx 单独作为 indexRange（不吸收进 init）
    const initRange = `0-${moovEnd}`;
    const indexRange = sidxEnd >= 0 ? `${moovEnd + 1}-${sidxEnd}` : '';
    console.info(`${TAG} initRange=${initRange}, indexRange=${indexRange}, totalSize=${fullContentLength}`);

    // ⭐ 解析 sidx 条目：SegmentTemplate 虚拟分段依赖字节偏移映射
    const parse = parseSidxEntries(view, sidxStart, sidxEnd, fullContentLength);
    if (!parse.complete) {
      needsLarger = true;
    }
    const segments = parse.segments;
    console.info(`${TAG} sidx 条目数=${segments.length}`);

    // ⭐ sidx 被窗口截断（条目表不全）时信息不可信，升级窗口重试
    if (needsLarger) {
      return { info: null, needsLarger: true };
    }

    const result: InitSegmentInfo = {
      initRange: initRange,
      indexRange: indexRange,
      contentLength: fullContentLength,
      timescale: timescale,
      segments: segments,
      // ⭐ 探测窗口必然完整覆盖 initRange（moov 被窗口截断时已升级重试），
      //    把已下载头部带回，转播站可免一次 init 回源
      headBuffer: buf
    };
    return { info: result, needsLarger: false };
  } catch (err) {
    console.error(`${TAG} probe(${probeSize}) error: ${(err as BusinessError).message}`);
    return { info: null, needsLarger: false };
  }
}

/** sidx 解析结果：segments 为已解析条目；complete 表示条目表完整包含在窗口内 */
interface SidxParseResult {
  segments: Array<SegmentEntry>;
  complete: boolean;
}

/**
 * 解析 sidx box 的引用条目。
 * 结构：size(4)+type(4)+version/flags(4)+reference_id(4)+timescale(4)+
 *       earliest_pt+first_offset+v0(16)|v1(24)+reserved(2)+reference_count(2)+
 *       entries[reference_count] 每条 12 字节：
 *         referenced_size(31bit)+type(1bit) | subsegment_duration(32bit) |
 *         starts_with_SAP(1bit)+SAP_type(3bit)+SAP_delta_time(28bit)
 * ⭐ 注意：reserved(2)+count(2) 在 first_offset 之后；
 *   v0: count 位于 box+30，entries 从 box+32
 *   v1: count 位于 box+38，entries 从 box+40
 * ⭐ 条目步长是 12 字节（含 SAP 字段），不是 8 字节——按 8 字节步进时
 *   第 2 条起会读到第 1 条的 SAP 字段(0x90000000 之类)导致 size 全错。
 * 返回每个子段的字节长度/时长；fileOffset 为 sidx 后首字节的相对偏移。
 */
function parseSidxEntries(
  view: Uint8Array,
  sidxStart: number,
  sidxEnd: number,
  fullContentLength: number
): SidxParseResult {
  const segments: Array<SegmentEntry> = [];
  const bad: SidxParseResult = { segments: segments, complete: false };
  if (sidxStart < 0 || sidxEnd < sidxStart || sidxEnd >= view.length) {
    return bad;
  }
  const version = view[sidxStart + 8];
  let entryOffset: number;
  let firstOffset: number;
  if (version === 0) {
    if (sidxStart + 32 > view.length) {
      console.warn(`${TAG} sidx v0 窗口不足 (len=${view.length})`);
      return bad;
    }
    firstOffset = readUint32(view, sidxStart + 24);
    entryOffset = sidxStart + 30; // reserved(2) 之后
  } else {
    if (sidxStart + 40 > view.length) {
      console.warn(`${TAG} sidx v1 窗口不足 (len=${view.length})`);
      return bad;
    }
    // v1: earliest_pt(8)+first_offset(8) 共 24 → count 在 +38
    firstOffset = readUint32(view, sidxStart + 32);
    entryOffset = sidxStart + 38;
  }
  if (entryOffset + 2 > view.length) {
    console.warn(`${TAG} sidx count 越界 (entryOffset=${entryOffset})`);
    return bad;
  }
  const count = ((view[entryOffset] << 8) | view[entryOffset + 1]);
  entryOffset += 2;
  console.info(`${TAG} sidx v${version} count=${count} firstOffset=${firstOffset} entries@end=${entryOffset}`);
  // ⭐ 条目表是否完整落在窗口内（每条 12 字节）；不完整则外层升级探测窗口
  const ENTRY_STRIDE = 12;
  const complete = entryOffset + count * ENTRY_STRIDE <= view.length;

  let cum = firstOffset;
  for (let i = 0; i < count && entryOffset + ENTRY_STRIDE <= view.length; i++) {
    // ⭐ size 为低 31bit（最高位 reference_type），按 31 位取
    const size = (readUint32(view, entryOffset) & 0x7FFFFFFF);
    const duration = readUint32(view, entryOffset + 4);
    // ⭐ 跳过 12 字节条目（SAP 字段位于 +8..+11）
    entryOffset += ENTRY_STRIDE;
    const entry: SegmentEntry = {
      size: size,
      duration: duration,
      fileOffset: sidxEnd + 1 + cum,
      startTime: 0
    };
    segments.push(entry);
    cum += size;
  }
  const parsed: SidxParseResult = { segments: segments, complete: complete };
  return parsed;
}

/**
 * 在 moov(boxStart) 内找 moov > trak > mdia > mdhd，读 timescale。
 * mdhd: size(4)+type(4)+version/flags(4)+v0: creation(4)+mod(4)=time(4)+duration(4) | v1: 8+8+4+8
 * timescale 绝对偏移：v0 → box+20，v1 → box+28。找不到返回 0。
 */
function parseMdhdTimescale(view: Uint8Array, moovStart: number): number {
  if (moovStart < 0 || moovStart + 8 > view.length) {
    return 0;
  }
  const moovSize = readBoxSize(view, moovStart);
  if (moovSize <= 0 || moovStart + moovSize > view.length) {
    // moov 未被完整包含（大 box），跳过（返回 0 走兜底）
    return 0;
  }
  const moovEnd = moovStart + moovSize;
  let p = moovStart + 8;
  while (p + 8 <= moovEnd) {
    const subSize = readBoxSize(view, p);
    const subType = readBoxType(view, p);
    if (subType === 'trak' && subSize >= 8) {
      const trakEnd = p + subSize;
      let q = p + 8;
      while (q + 8 <= trakEnd) {
        const tSize = readBoxSize(view, q);
        const tType = readBoxType(view, q);
        if (tType === 'mdia' && tSize >= 8) {
          const mdiaEnd = q + tSize;
          let r = q + 8;
          while (r + 8 <= mdiaEnd) {
            const mSize = readBoxSize(view, r);
            const mType = readBoxType(view, r);
            if (mType === 'mdhd' && mSize >= 28) {
              const version = view[r + 8];
              if (version === 0 && mSize >= 24) {
                return readUint32(view, r + 20);
              } else if (version === 1 && mSize >= 32) {
                return readUint32(view, r + 28);
              }
              return 0;
            }
            if (mSize <= 0) {
              break;
            }
            r += mSize;
          }
        }
        if (tSize <= 0) {
          break;
        }
        q += tSize;
      }
    }
    if (subSize <= 0) {
      break;
    }
    p += subSize;
  }
  return 0;
}

async function probeTail(
  m4sUrl: string,
  referer: string,
  userAgent: string,
  cookie: string
): Promise<InitSegmentInfo | null> {
  // 尾部探测前先取全量大小（若前面的探测都没能拿到 content-range）
  const sizeProbe = await fetchFullSize(m4sUrl, referer, userAgent, cookie);
  if (sizeProbe <= 0) {
    console.error(`${TAG} tail probe: unknown file size, cannot probe tail`);
    return null;
  }

  const fullSize = sizeProbe;
  const tailSize = Math.min(131072, fullSize);
  const tailStart = fullSize - tailSize;
  const headers: Record<string, string> = {
    'User-Agent': userAgent,
    'Referer': referer,
    'Origin': 'https://www.bilibili.com',
    'Range': `bytes=${tailStart}-${fullSize - 1}`
  };
  if (cookie) {
    headers['Cookie'] = cookie;
  }

  try {
    const httpRequest = http.createHttp();
    const response = await httpRequest.request(m4sUrl, {
      method: http.RequestMethod.GET,
      header: headers,
      // ⭐ 修复：默认 STRING 会把二进制结果解码为字符串
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 15000
    });
    httpRequest.destroy();

    if (response.responseCode !== 206 && response.responseCode !== 200) {
      console.error(`${TAG} tail probe HTTP ${response.responseCode}`);
      return null;
    }

    const buf = response.result as ArrayBuffer;
    const view = new Uint8Array(buf);

    const moovInfo = findMoovInTail(view, tailStart);
    if (!moovInfo) {
      console.error(`${TAG} tail probe: no moov found in last ${tailSize} bytes`);
      return null;
    }

    console.info(`${TAG} tail probe: moov at file offset ${moovInfo.start}-${moovInfo.end}, size=${fullSize}`);

    let timescale: number = parseMdhdTimescale(view, moovInfo.start < 0 ? -1 : moovInfo.start - 0);
    // ⭐ 尾部窗口内 moov 或许完整，直接用真实 mdhd；否则 1000 兜底
    if (timescale <= 0) {
      timescale = 1000;
    }

    const emptySegments: Array<SegmentEntry> = [];
    const result: InitSegmentInfo = {
      initRange: `${moovInfo.start}-${moovInfo.end}`,
      indexRange: '',
      contentLength: fullSize,
      timescale: timescale,
      segments: emptySegments
    };
    return result;
  } catch (err) {
    console.error(`${TAG} tail probe error: ${(err as BusinessError).message}`);
    return null;
  }
}

/** 仅用 Range: 0-0 或 0-4095 拿全量大小（Content-Range 总长） */
async function fetchFullSize(
  m4sUrl: string,
  referer: string,
  userAgent: string,
  cookie: string
): Promise<number> {
  const headers: Record<string, string> = {
    'User-Agent': userAgent,
    'Referer': referer,
    'Origin': 'https://www.bilibili.com',
    'Range': 'bytes=0-0'
  };
  if (cookie) {
    headers['Cookie'] = cookie;
  }

  try {
    const httpRequest = http.createHttp();
    const response = await httpRequest.request(m4sUrl, {
      method: http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 15000,
      readTimeout: 15000
    });
    httpRequest.destroy();
    const headerObj = response.header as Record<string, string>;
    const contentRange = headerObj['content-range'] || '';
    const rangeParts = contentRange.split('/');
    if (rangeParts.length > 1) {
      return Number(rangeParts[1]) || 0;
    }
    return Number(headerObj['content-length']) || 0;
  } catch (err) {
    console.error(`${TAG} fetchFullSize error: ${(err as BusinessError).message}`);
    return 0;
  }
}

interface MoovInfo {
  start: number;
  end: number;
}

function findMoovInTail(view: Uint8Array, fileOffset: number): MoovInfo | null {
  const len = view.length;
  let offset = 0;

  while (offset + 8 <= len) {
    const boxSize = readBoxSize(view, offset);
    const boxType = readBoxType(view, offset);

    if (boxType === 'moov' && boxSize > 0 && boxSize <= len - offset) {
      const absStart = fileOffset + offset;
      const absEnd = fileOffset + offset + boxSize - 1;
      const info: MoovInfo = { start: absStart, end: absEnd };
      return info;
    }

    if (boxSize === 0 || boxSize === 1) {
      break;
    }
    offset += boxSize;
  }

  return null;
}

function readBoxSize(view: Uint8Array, offset: number): number {
  if (offset + 4 > view.length) {
    return 0;
  }
  return ((view[offset] << 24) | (view[offset + 1] << 16) | (view[offset + 2] << 8) | view[offset + 3]) >>> 0;
}

/** 大端 4 字节无符号整数 */
function readUint32(view: Uint8Array, offset: number): number {
  if (offset + 4 > view.length) {
    return 0;
  }
  return ((view[offset] << 24) | (view[offset + 1] << 16) | (view[offset + 2] << 8) | view[offset + 3]) >>> 0;
}

function readBoxType(view: Uint8Array, offset: number): string {
  if (offset + 8 > view.length) {
    return '';
  }
  let s = '';
  for (let i = 4; i < 8; i++) {
    s += String.fromCharCode(view[offset + i]);
  }
  return s;
}
