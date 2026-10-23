import { http } from '@kit.NetworkKit';
import { logInfo, logWarn } from '../utils/Logger';
import { HttpConstants } from './HttpConstants';

/**
 * B站「视频缩略图」数据（进度条拖动预览用）
 *
 * `image` 是**精灵图**（多张格子拼图），`index` 是每格的起始秒数（升序）：
 *   第 i 格 = index[i] 秒的画面，行优先排列（col = i % imgXLen, row = i / imgXLen）
 *
 * 实测（BV1GJ411x7h7 / cid=137649199 / 213s）：
 *   img_x_len=10 img_y_len=10 img_x_size=160 img_y_size=90
 *   index = [0, 0, 5, 11, 17, ...]（33 项，**纯秒数**）
 *   精灵图 1600×900 = 10×10 × 160×90（与 img_x_size/img_y_size 一致）
 */
export interface VideoShotData {
  /** 网格列数（通常 10） */
  imgXLen: number;
  /** 网格行数（通常 10） */
  imgYLen: number;
  /** **单元格**像素宽（通常 160；个别视频返回 0，由服务层按整图推导兜底） */
  imgXSize: number;
  /** **单元格**像素高（通常 90） */
  imgYSize: number;
  /** 精灵图 URL 列表（长视频多张，每张 imgXLen*imgYLen 格） */
  image: string[];
  /** 每格起始秒数（升序，可能含重复值） */
  index: number[];
}

/**
 * 拉取视频缩略图信息
 * 接口: https://api.bilibili.com/x/player/videoshot?bvid=&cid=&index=1
 *
 * ⭐ **不需要 wbi 签名**：实测匿名（仅 UA/Referer）即可 code=0（参考实现 PiliPlus 同样不签名）
 * ⭐ 番剧/付费/直播等内容没有缩略图，会返回非 0 code —— 属正常情况，按"无缩略图"降级处理
 */
export async function fetchVideoShot(bvid: string, cid: number): Promise<VideoShotData | undefined> {
  if (!bvid || cid <= 0) return undefined;
  const url: string = `${HttpConstants.webBaseUrl}/x/player/videoshot?bvid=${bvid}&cid=${cid}&index=1`;
  const httpRequest: http.HttpRequest = http.createHttp();
  try {
    const response: http.HttpResponse = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': HttpConstants.USER_AGENT_WEB,
        'Referer': `https://www.bilibili.com/video/${bvid}`
      },
      connectTimeout: 8000,
      readTimeout: 8000
    });
    if (response.responseCode !== 200) {
      logWarn(`[VideoShot] HTTP ${response.responseCode} cid=${cid}`);
      return undefined;
    }
    const result: Record<string, Object> = JSON.parse(response.result as string) as Record<string, Object>;
    const code: number = (result['code'] as number) ?? -1;
    if (code !== HttpConstants.RESPONSE_CODE_SUCCESS) {
      logInfo(`[VideoShot] code=${code} cid=${cid}（该视频无缩略图，正常降级）`);
      return undefined;
    }
    const data: Record<string, Object> = result['data'] as Record<string, Object>;
    if (!data) return undefined;
    const rawImage: string[] = (data['image'] as string[]) ?? [];
    const rawIndex: number[] = (data['index'] as number[]) ?? [];
    if (rawImage.length === 0 || rawIndex.length === 0) {
      logInfo(`[VideoShot] index 为空 cid=${cid}`);
      return undefined;
    }
    // 协议相对 URL（//i0.hdslb.com/...）补上 https:
    const images: string[] = [];
    for (let i: number = 0; i < rawImage.length; i++) {
      const u: string = rawImage[i];
      if (!u) continue;
      images.push(u.startsWith('//') ? `https:${u}` : u);
    }
    if (images.length === 0) return undefined;

    const shot: VideoShotData = {
      imgXLen: Math.max(1, (data['img_x_len'] as number) ?? 10),
      imgYLen: Math.max(1, (data['img_y_len'] as number) ?? 10),
      imgXSize: (data['img_x_size'] as number) ?? 0,
      imgYSize: (data['img_y_size'] as number) ?? 0,
      image: images,
      index: rawIndex
    };
    logInfo(`[VideoShot] 就绪 cid=${cid} 格数=${rawIndex.length} 精灵图=${images.length}张 ` +
      `单元格=${shot.imgXSize}x${shot.imgYSize} 网格=${shot.imgXLen}x${shot.imgYLen}`);
    return shot;
  } catch (e) {
    logWarn(`[VideoShot] 请求异常 cid=${cid}: ${JSON.stringify(e)}`);
    return undefined;
  } finally {
    httpRequest.destroy();
  }
}
