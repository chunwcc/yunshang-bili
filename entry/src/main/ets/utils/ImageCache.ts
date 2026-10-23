import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';

const cache = new Map<string, image.PixelMap>();

/**
 * 预解码一张图片：先通过 HTTP 下载数据，再解码为 PixelMap 缓存
 * 避免后续渲染时 ArkUI Image 组件在主线程做软件 JPEG 解码（无硬件解码器时耗时 2-20ms/张）
 */
export async function predecodeImage(url: string): Promise<void> {
  if (!url || cache.has(url)) return;
  try {
    const httpReq = http.createHttp();
    const resp = await httpReq.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: 5000,
      readTimeout: 10000,
      usingProtocol: http.HttpProtocol.HTTP1_1,
      header: {
        'Referer': 'https://www.bilibili.com/',
        'User-Agent': 'Mozilla/5.0'
      }
    });
    httpReq.destroy();

    if (resp.responseCode !== 200 || !resp.result) return;

    // 将 ArrayBuffer 转为 ImageSource
    const data = resp.result as ArrayBuffer;
    const src = image.createImageSource(data);
    const pm: image.PixelMap = await src.createPixelMap();
    src.release(); // 释放 ImageSource
    cache.set(url, pm);
  } catch (_e) {
    // 预解码失败不阻塞主流程
  }
}

export function getCachedPixelMap(url: string): image.PixelMap | undefined {
  return cache.get(url);
}

export function clearImageCache(): void {
  cache.clear();
}
