/**
 * OfflineCacheItem.ts
 * 离线缓存条目模型 — 记录一个视频的缓存状态与本地文件
 */

/** 缓存状态 */
export enum CacheStatus {
  WAIT = 'wait',              // 排队等待
  DOWNLOADING = 'downloading', // 下载中
  PAUSED = 'paused',           // 已暂停（可续传）
  COMPLETED = 'completed',     // 已完成
  FAILED = 'failed'            // 失败
}

/** 缓存条目 */
export interface OfflineCacheItem {
  bvid: string;
  cid: number;
  title: string;
  cover: string;
  quality: number;        // 请求的画质 qn
  qualityLabel: string;   // 画质文案，如 1080P
  status: CacheStatus;
  totalBytes: number;
  downloadedBytes: number;
  videoPath: string;      // 本地视频文件绝对路径（空表示未下载）
  audioPath: string;      // 本地音频文件绝对路径（DASH 分离；FLV 时为空）
  createTime: number;
  updateTime: number;
}

/**
 * 缓存目录结构（参照 PiliPlus）：
 * filesDir/offline/{bvid}_{cid}/
 *   ├── entry.json     # 条目元数据（本模型序列化）
 *   ├── video.m4s      # DASH 视频轨 / FLV 完整流
 *   └── audio.m4s      # DASH 音频轨（仅 DASH 分离时存在）
 */
export const CACHE_ROOT_DIR: string = 'offline';
export const ENTRY_FILE_NAME: string = 'entry.json';
export const VIDEO_FILE_NAME: string = 'video.m4s';
export const AUDIO_FILE_NAME: string = 'audio.m4s';

/** 由 bvid+cid 生成条目目录名 */
export function cacheEntryDirName(bvid: string, cid: number): string {
  return `${bvid}_${cid}`;
}
