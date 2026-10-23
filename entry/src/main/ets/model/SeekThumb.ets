import { image } from '@kit.ImageKit';

/**
 * 进度调节缩略图状态（播放页 → VideoControls 单向传递）
 *
 * ⚠️ 每次变化都要**整体替换新实例**（而不是改字段）：`@Link` 对类对象的字段修改不会触发刷新，
 *   只有重新赋值整个对象才会（与 DanmakuConfig 同一套约定）。
 *   播放页的 `updateSeekThumb_()` / `hideSeekThumb_()` 都是 new 一个新对象再赋值。
 */
export class SeekThumb {
  /** 当前格子的位图；undefined = 暂无（未加载 / 该视频没有缩略图 / 已释放） */
  pm: image.PixelMap | undefined = undefined;
  /** 是否显示（拖动/滑动期间为 true，与提示胶囊同生共死） */
  show: boolean = false;
  /** 单元格宽高比（按高度推算显示宽度；接口给的是每格像素尺寸，通常 160×90） */
  aspect: number = 16 / 9;
}
