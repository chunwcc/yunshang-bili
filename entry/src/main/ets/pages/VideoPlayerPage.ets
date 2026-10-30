// VideoPlayerPage.ets
import { router, curves, SegmentButton, SegmentButtonOptions, componentUtils, display, KeyboardAvoidMode, LengthMetrics, PiPWindow } from '@kit.ArkUI';

import { logInfo, logWarn, logError, errMsg } from '../utils/Logger';
import { getVideoPlayUrl, invalidatePlayUrlCache, PlayUrlResult, getVideoDetail, getVideoComments, getCommentReplies, VideoDetail, VideoDetailOwner, VideoDetailStat, CommentItem, getVideoUserStatus, VideoPageItem, getFollowStatus, modifyFollow, clearFollowedMidsCache, getUserInfo, UserInfo, getPgcPlayUrl, getPgcSeasonInfo, getPgcEpisodeInfo, getPgcSeasonInfoByEpId, PgcSeasonInfo, PgcEpisode, getRelatedVideos, addVideoComment, uploadCommentImage, sendDanmakuVideo, SeasonEpisode, SeasonSection, UgcSeason } from '../api/BilibiliApi';
import { CommentInputBar, CommentImageDraft, CommentInputBarCtrl } from '../components/CommentInputBar';
import { RecommendItem } from '../model/RecommendItem';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { VibrateUtils } from '../utils/VibrateUtils';
import { MaterialUtil } from '../utils/MaterialUtil';
import { window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import deviceInfo from '@ohos.deviceInfo';
import { StatusBarUtils } from '../utils/StatusBarUtils';
import { applyCardStyleModeArchive } from '../utils/CardStyleMode';
import AVCastPicker from '@ohos.multimedia.avCastPicker';
import { AVCastPickerState } from '@ohos.multimedia.avCastPickerParam';
import { motion } from '@kit.MultimodalAwarenessKit';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import { http } from '@kit.NetworkKit';
import { VideoControls } from '../components/VideoControls';
import { ImmersiveLightWrapper } from '../components/ImmersiveLightWrapper';
import { HdsMiniBarButton } from '../components/infra/HdsMiniBarButton';
import { HdsGlassBar } from '../components/infra/HdsGlassBar';

import { predecodeImage, getCachedPixelMap, clearImageCache } from '../utils/ImageCache';
import { image } from '@kit.ImageKit';
import { WatchHistoryHelper, MIN_HEARTBEAT_PROGRESS_SEC } from '../model/WatchHistoryHelper';
import { WatchHistoryItem } from '../model/WatchHistoryItem';
import { reportWatch, UserBehaviorService } from '../services/UserBehaviorService';
import { VideoShotService, SeekThumbFrame } from '../services/VideoShotService';
import { SeekThumb } from '../model/SeekThumb';
import { ObservableComment } from '../model/ObservableComment';
import { CommentDataSource } from '../model/CommentDataSource';
import { CommentItemComponent } from '../components/CommentItemComponent';
import { TextSelectionDialog } from '../components/TextSelectionDialog';
// ⭐ 弹幕组件
import { DanmakuView } from '../components/DanmakuView';
import { DanmakuSettingSheet } from '../components/DanmakuSettingSheet';
import { DanmakuConfig, DanmakuConfigInit, DanmakuItem, DanmakuType, DanmakuItemInit } from '../model/DanmakuItem';
// ⭐ 实况窗
import { LiveViewHelper } from '../services/LiveViewHelper';
// ⭐ DASH 转播站组装器（双流场景替代双 AVPlayer）
import { DashPlayerBridge } from '../services/DashPlayerBridge';
import { PlayerService, DashServerHandle } from '../services/PlayerService';
// ⭐ 离线缓存
import { OfflineCacheService } from '../services/OfflineCacheService';
import { OfflineCacheItem, CacheStatus } from '../model/OfflineCacheItem';
// ⭐ 本地文件播放需用文件描述符（createMediaSourceWithFd），fileUri 路径形式 AVPlayer 不识别
import { fileIo as fs } from '@kit.CoreFileKit';
/**
 * ⭐ 4K 快速起播开关（用户决定默认关闭，2026-10-18）
 *
 * 开启时：4K 视频先用 1080P+ 出帧（快 3~5 秒），首帧后 2 秒预热、约 5~8 秒切回 4K。
 * 关闭时：起播直接按设置里的最高画质加载（首帧慢，但不存在"看到一半切档卡一下"）。
 *
 * 为什么关：单播放器架构下换轨必须重建 AVPlayer，切换必然中断 1~3 秒，
 * 实测无法做到无感（AVPlayer 不支持播放中切轨，见 DashPlayerBridge 的多 Representation 实验）。
 */
const FAST_START_4K: boolean = false;

// B站视频详情API响应接口
interface VideoDetailView {
  bvid: string;
  title: string;
  pic: string;
  aid: number;
}
interface VideoDetailData {
  View: VideoDetailView;
}
interface VideoDetailResponse {
  code: number;
  message: string;
  data: VideoDetailData;
}

/**
 * 关灯短视频 feed 的单条数据。
 * 只存切换播放需要的字段；详情（VD）到达后再回填 title/cover/owner/stat。
 */
interface ShortVideoFeedItem {
  bvid: string;
  cid: number;
  aid: number;
  title: string;
  cover: string;
  ownerName: string;
  ownerFace: string;
  duration: number;
  playCount: number;
  danmakuCount: number;
  pubdate: number;
}

interface VC { bvid: string; cid: number; title: string; cover: string; ownerName?: string; ownerFace?: string; duration?: number; pubdate?: number; view?: number; subTitle?: string; score?: string; indexShow?: string; badge?: string }
interface QI { qn: number; label: string }
interface SO { label: string; mode: string }
// ⭐ 画风选项（色彩风格）
interface CO { label: string; mode: string }
// ⭐ 更多菜单项（后续功能扩展：缓存、定时等）
interface MO { label: string; icon: Resource; action: () => void }
// 最小化视频播放状态
interface MinimizedVideoState {
  bvid: string;
  cid: number;
  title: string;
  cover: string;
  currentTime: number;
  duration: number;
  isPlaying: boolean;
  quality: number;
  qualityLabel: string;
  volume: number;
  mute: boolean;
  isLandscapeVertical: boolean;  // ⭐ 横屏竖屏视频模式状态
  videoAspectRatio: number;       // ⭐ 视频宽高比
  aid: number;                    // ⭐ 分集 aid（PGC 评论 oid；恢复播放页时补详情/评论）
  epId: number;                   // ⭐ PGC 分集 id
  seasonId: number;               // ⭐ PGC 季 id
}

// ⚠️ 不要用 PersistentStorage 持久化 defaultVideoQn（原为 persistProp('defaultVideoQn', 116)）：
//    它会把“上一次运行的内存值”固化，与用户在设置里保存到 preferences 的值冲突 ——
//    实测「默认 4K」被快速起播的自动升档写成 1080P 后，重启仍读到 1080P，
//    而 preferences 里明明还是 4K。权威来源改为 preferences（Index.aboutToAppear 启动时恢复）。
// ⚠️ 必须判空后再写：AppStorage.setOrCreate 是「存在则更新」，
//    无条件调用会把 Index 刚恢复的 120 覆盖成兜底值 116（实测踩过）。
if (AppStorage.get<number>('defaultVideoQn') === undefined) {
  AppStorage.setOrCreate<number>('defaultVideoQn', 116);
}
PersistentStorage.persistProp('bgp', false)
PersistentStorage.persistProp('phoneLayoutToggle', false)
PersistentStorage.persistProp('lightsOffHideOnly', false)
PersistentStorage.persistProp('lightsOffShowBtn', false)
PersistentStorage.persistProp('lightsOffDanmakuOutside', true)

// ⭐「弹幕设置」面板的持久化 key（存 Preferences 'VPS' 库，值为 JSON 字符串）
const DM_SETTING_KEY: string = 'danmakuDisplaySettings'

/**
 * Bilibili CDN 图片缩放辅助：在 URL 后追加 `@Ww` 参数缩放到指定宽度
 * 仅对 hdslb.com 域名生效，其他 URL 原样返回
 */
function imageUrlResize(url: string, width: number): string {
  if (!url || !url.includes('hdslb.com')) {
    return url;
  }
  // ⚠️ 原实现 `!url.includes('@')`：URL 已带后缀时**整段跳过压缩** → 原图整张解码
  const at: number = url.indexOf('@');
  const base: string = (at > url.lastIndexOf('/') && url.indexOf('?') < 0) ? url.substring(0, at) : url;
  return base + `@${width}w`;
}

@Entry
@Component
struct VideoPlayerPage {
  @State vi: VC = { bvid: '', cid: 0, title: '', cover: '' }
  // ⭐ 从路由参数中获取的 aid（用于 saveWatchHistory，不依赖异步加载的 this.vd）
  private aidFromParams_: number = 0
  // ⭐ PGC（番剧/影视）播放状态：epId_=分集id, seasonId_=季id, isPgc_=是否PGC源
  private epId_: number = 0
  private seasonId_: number = 0
  @State isPgc_: boolean = false
  // ⭐ 离线播放：本地缓存文件路径（非空时 initP 走本地播放，跳过网络取流）
  private offlineVideoPath_: string = ''
  private offlineAudioPath_: string = ''
  // ⭐ 离线播放：已打开的本地文件 fd（release 时必须关闭）
  private offlineVideoFd_: fs.File | null = null
  private offlineAudioFd_: fs.File | null = null
  // ⭐ PGC 选集：与 vd.pages 下标一一对应的 ep_id 列表（切集时更新 epId_）
  private pgcEpIds_: number[] = []
  // ⭐ PGC 选集：与 vd.pages 下标一一对应的分集 aid 列表（番剧评论 oid 必须用 aid，不能用 ep_id）
  private pgcAids_: number[] = []
  private av: media.AVPlayer | null = null; private avAudio: media.AVPlayer | null = null; private sId: string = ''
  private xc: XComponentController = new XComponentController()
  private nativeSurfaceId_: string = ''
  /** ⭐ DASH 转播站桥（DASH 双流场景用；FLV/离线时为 null） */
  private dashBridge_: DashPlayerBridge | null = null
  /** ⭐ 恢复接管时从 PlayerService 取回的转播站句柄（页面退出停服用） */
  private dashHandle_: DashServerHandle | null = null
  /** ⭐ 当前播放为 DASH 转播站模式（音画引擎内同步，skip 手动对齐） */
  private isDashStream_: boolean = false
  /** GL 渲染管线已禁用（当前设备/OS 不支持 OH_NativeImage 帧拦截） */
  private isGLInitialized_: boolean = false
  private glXcSurfaceId_: string = ''
  private glRenderTimer_: number = -1
  private mw: window.Window | null = null
  /** 进入页面时的原始窗口亮度，-1 = 系统自动亮度，>=0 = 手动亮度值 */
  private originalBrightness_: number = -1
  @State ld: boolean = true; @State err: string = ''; @Watch('onPlayChanged') @State play: boolean = true
  @State ct: number = 0; @State dur: number = 0; @State rt: number = 1.0
  @State mute: boolean = false; @State vol: number = 0.8; @State bri: number = 0.5
  @State cv: boolean = false; @State lk: boolean = false
  @State @Watch('onTransitionFlip') fs: boolean = false
  // ⭐ 评论区转场渐显：转场期间（全屏/旋转）评论区移出布局；全部转场结束后 0→1 渐显回来
  @State commentFade: number = 1
  // ⭐ 常驻播放器层矩形（非全屏由分支占位槽 onAreaChange 跟踪；全屏为整屏）
  @State ovX: number = 0
  @State ovY: number = 0
  @State ovW: number = 0
  @State ovH: number = 0
  // 内容 Column 全局锚点（占位槽全局坐标减去锚点 → Column 内坐标，即常驻层 position 坐标系）
  private ovAnchorX: number = 0
  private ovAnchorY: number = 0
  // ⭐ fs 期间内容分支冻结键（'portrait'|'lv'|'isLs'），进入全屏前快照
  private preFsBranch: string = 'portrait'
  // ⭐ 进出全屏连续几何插值：起点快照 + 方向（0=无 1=进入 2=退出）
  private fsLerpSnapX: number = 0
  private fsLerpSnapY: number = 0
  private fsLerpSnapW: number = 0
  private fsLerpSnapH: number = 0
  private fsLerpSnapVW: number = 0
  private fsLerpSnapVH: number = 0
  private fsLerpDir: number = 0
  // ⭐ 旋转进行中标志：旋转期间跳过评论头像预解码；退出全屏插值等待旋转完成
  @State @Watch('onTransitionFlip') rotationInProgress: boolean = false
  @State gh: boolean = false; @State ght: string = ''
  @State ghp: number = -1
  @State ghtType: string = ''
  // ⭐ 本次进度调节的**起点秒数**（拖动进度条 = 按下时的位置；视频区手势 = 手指落下的位置）。
  //   提示胶囊右侧据此显示"相对位移"（+10S 绿 / -10S 红）。-1 表示无效（不显示）
  @State ghb: number = -1
  @State bh: boolean = false; @State bhi: ResourceStr | undefined = undefined
  @State bht: string = ''; private bt: number = -1
  @State ub: boolean = false; private ubt: number = -1
  private handlingUnlockClick: boolean = false  // 防止解锁按钮点击事件冲突
  @State rh: boolean = false; @State rht: string = ''; private rhtm: number = -1
  // ⭐ 实况窗节流定时器
  private lvTimer_: number = -1
  // ⭐ 声画同步：恢复后自动检测视频落后并 2x 追赶
  private videoSpeedFixTimer_: number = -1
  private isSpeed2x_: boolean = false
  // ⭐ 上次声画同步 seek 的时间戳，防止频繁 seek 导致画面反复跳跃
  private lastSyncSeekTime_: number = 0
  // ⭐ seek 冷却期：上次 seek 后多久内不再 seek（毫秒）
  private readonly SYNC_SEEK_COOLDOWN_: number = 8000
  // ⭐ 2x 追赶期间不再切换为 seek，避免画面抽搐
  private isSpeedFixIn2xPhase_: boolean = false
  @State sm: string = 'auto'; @State vw: number = 0; @State vh: number = 0
  @State ar: number = 16 / 9; @State cw: number = 0; @State ch: number = 0
  @State lsvw: number = 0; @State lsvh: number = 0
  /** ⭐ cardMargin 安全化：Preferences/AppStorage 可能出现 NaN/undefined/字符串，统一兜底为 12 */
  private safeCM(): number {
    const v = Number(this.cardMargin);
    if (!Number.isFinite(v)) return 12;
    return v;
  }

  /** ⭐ 播放页竖屏评论区：单图的适配框（见 CommentContentRenderer.picBoxW 注释）。0 = 不启用。 */
  private commentPicBoxW(): number {
    if (this.cw <= 0) return 0;
    // 评论正文可用宽：窗口宽 − 卡片左右边距 − 头像列(40)与间距(10)
    return Math.max(1, this.cw - 2 * this.safeCM() - 50);
  }
  private commentPicBoxH(): number {
    if (this.ch <= 0) return 0;
    return Math.max(120, this.ch * 0.45);
  }
  // XComponent 尺寸/位置计算（每个分支独立使用）
  /**
   * ⭐ 缩小（vidShrink > 0）时视频的显式几何。取代原先散落在 13 处的同一套表达式。
   *
   * 形态：缩到最小的终值由「小窗样式」决定（个性化 → 视频页动画）：
   *   circle（默认）= 直径 SHRINK_DIAMETER 的正圆；square = 同尺寸小圆角方窗；
   *   ratio = 保持画面比例的小矩窗；hidden = 收到 1vp（不显示小窗，只留还原浮标）。
   * 圆形要不变形，下面三件事必须同时满足：
   *   ① 容器/占位槽缩成**正方形**（`shrinkSlotW/H`）—— 圆是方框裁出来的，方框不方就裁不出正圆；
   *   ② 圆角取方框的**一半 = 正圆**（`shrinkRadius`），且随 vidShrink 从 cardBorderRadius 连续过渡，
   *      这样是"方角矩形慢慢收成圆形"而不是末帧突然变圆；
   *   ③ 视频本体**放大到盖满方框**（`shrinkFillW/H`，按 max 比例缩放）—— 否则 16:9 画面放进正方形
   *      会上下留黑边，裁成圆后圆里就是两道黑。多出的部分由容器的圆形 clip 裁掉（同封面圆形头像）。
   *      ⚠️ 这一条与 ① ② 是一体的：只做 ① ② 会得到"圆里带黑边"。
   *
   * 全部用 `vidShrink` 线性插值，所以 **vidShrink=0 时与旧的正常尺寸逐值相等**，非缩小态不受影响。
   *
   * ⚠️ 历史坑（改这里前先读）：原式宽只缩 30%、高缩 85%，盒子变成约 8:1 的横条而画面是 16:9，
   *    于是两侧各约三分之一是黑边；顶部还从 50 线性降到 10，被前置挖孔挡住。
   *    `shrinkVideoTop` 的"不低于顶部安全区"就是为后者加的，别再压回 10。
   */
  /** 圆形小窗直径（vp）的**出厂默认值**：实际值由「个性化 → 视频页动画 → 小窗大小」决定 */
  private readonly SHRINK_DIAMETER: number = 120;
  /** 正方形样式的圆角（vp）：圆角方窗，不是正圆（12 太方正，用户要求再大些 → 30） */
  private readonly SHRINK_SQUARE_RADIUS: number = 30;
  /** 等比样式的圆角（vp） */
  private readonly SHRINK_RATIO_RADIUS: number = 10;
  /** 缩小时的方框边长（不缩时夹在可用宽度内，避免小屏溢出） */
  private shrinkCircleD(): number {
    // ⭐ 尺寸可由用户调（AppStorage 'shrinkWindowSize'）：这里再夹一次范围，
    //    防止 Preferences 里存了脏值把 surface 弄成非法尺寸；窄屏还要再被 videoDisplayWidth 夹一次。
    const raw = Number.isFinite(this.shrinkWindowSize) ? this.shrinkWindowSize : this.SHRINK_DIAMETER;
    const size = Math.max(60, Math.min(240, raw));
    return Math.min(size, this.videoDisplayWidth);
  }
  /**
   * ⭐ 缩到最小后的**目标宽**（vp）：由「个性化 → 视频页动画 → 缩小后的小窗样式」决定
   *   circle/square → 120（正方形边长）；ratio → 120（等比时以宽为基准）；
   *   hidden → 1（等价于收起；**不能给 0** —— surface 尺寸非法会被系统杀掉，
   *   本文件其它路径也一律用 Math.max(1, ...) 兜底）。
   */
  private shrinkTargetW(): number {
    if (this.shrinkWindowStyle === 'hidden') return 1;
    return this.shrinkCircleD();
  }
  /**
   * ⭐ 缩到最小后的**目标高**（vp）：
   *   circle/square → 与宽相同（正方形，靠圆角半径区分为正圆 / 方窗）；
   *   ratio → 按画面真实比例 d × vh/vw（此时 fillScale 恰好等于该比例，视频正好铺满、无裁切）；
   *   hidden → 1。
   */
  private shrinkTargetH(): number {
    if (this.shrinkWindowStyle === 'hidden') return 1;
    const d = this.shrinkCircleD();
    if (this.shrinkWindowStyle === 'ratio') {
      const vw = Math.max(1, this.videoDisplayWidth);
      const vh = Math.max(1, this.videoDisplayHeight);
      return Math.max(1, d * vh / vw);
    }
    return d;
  }
  /** 缩小时的容器/占位槽宽：从视频原宽插值到目标宽 */
  private shrinkSlotW(): number {
    return this.videoDisplayWidth + (this.shrinkTargetW() - this.videoDisplayWidth) * this.vidShrink;
  }
  /** 缩小时的容器/占位槽高：从视频原高插值到目标高 */
  private shrinkSlotH(): number {
    return this.videoDisplayHeight + (this.shrinkTargetH() - this.videoDisplayHeight) * this.vidShrink;
  }
  /**
   * 缩小时的视频本体尺寸（盖满方框用）：按 `max(宽比, 高比)` 缩放。
   * vidShrink=0 时比例恰为 1 → 与正常尺寸逐值相等，正常态零影响。
   */
  private fillScale(): number {
    const w = this.shrinkSlotW();
    const h = this.shrinkSlotH();
    const vw = Math.max(1, this.videoDisplayWidth);
    const vh = Math.max(1, this.videoDisplayHeight);
    return Math.max(w / vw, h / vh);
  }
  private shrinkFillW(): number {
    return Math.max(1, this.videoDisplayWidth * this.fillScale());
  }
  private shrinkFillH(): number {
    return Math.max(1, this.videoDisplayHeight * this.fillScale());
  }
  /**
   * 缩小时的圆角：随 vidShrink 从卡片圆角连续过渡到样式对应的终值。
   *   circle → 边长一半（裁出正圆）；square → 12；ratio → 10；hidden → 0。
   */
  private shrinkRadius(): number {
    let r: number;
    if (this.shrinkWindowStyle === 'circle') {
      r = this.shrinkCircleD() / 2;
    } else if (this.shrinkWindowStyle === 'square') {
      r = this.SHRINK_SQUARE_RADIUS;
    } else if (this.shrinkWindowStyle === 'ratio') {
      r = this.SHRINK_RATIO_RADIUS;
    } else {
      r = 0;
    }
    const from = Number.isFinite(this.cardBorderRadius) ? this.cardBorderRadius : 20;
    return from + (r - from) * this.vidShrink;
  }
  /**
   * ⭐ 常驻播放层的透明度：**只**在「隐藏」样式下随缩小淡出。
   *   为什么需要：隐藏样式把目标尺寸收到 1vp（不能给 0 —— surface 尺寸非法会被系统杀），
   *   但 1vp 的黑底 + 盖满的视频仍会在屏幕上留一个肉眼可见的小点，所以必须整体淡出。
   *   圆形 / 正方形 / 等比 恒为 1（那三种本来就要看见小窗）。
   */
  private shrinkPlateOpacity(): number {
    if (this.shrinkWindowStyle !== 'hidden') return 1;
    return Math.max(0, 1 - this.vidShrink);
  }

  /** ⭐ 是否处于缩小态（阈值 0.5）：弹幕显隐、渲染开关都以它为准 */
  private isVidShrunk(): boolean {
    return this.vidShrink > 0.5;
  }
  private shrinkVideoTop(): number {
    const sb = Number(AppStorage.get<number>('statusBarHeight'));
    const safeTop = (Number.isFinite(sb) && sb > 0) ? sb : 40;   // 与 SmartGrip 取安全区的兜底值一致
    return Math.max(safeTop, 50 - 40 * this.vidShrink);
  }
  get xcW() {
    if (this.fs) return this.videoDisplayWidth;
    if (this.isLs || this.isLandscapeVertical) return this.lsvw;
    return this.shrinkSlotW(); // videoDisplayWidth 已含 cardMargin 扣减
  }
  get xcH() {
    if (this.fs) return this.videoDisplayHeight;
    if (this.isLs || this.isLandscapeVertical) return this.lsvh;
    return this.shrinkSlotH();
  }
  get xcRx() {
    if (this.fs) return (this.cw - this.videoDisplayWidth) / 2;
    if (this.isLandscapeVertical) {
      // 竖屏横看：Flex 布局，左侧按钮栏固定 80vp
      // 非镜像：按钮在左，播放器 x = 80
      // 镜像：按钮在右，播放器 x = cw - lsvw - 80
      return this.isLayoutSwapped ? (this.cw - this.lsvw - 80) : 80;
    }
    if (this.isLs) {
      // 横屏非全屏：Flex 布局
      // 非镜像：左边距 cardMargin
      // 镜像：播放器在右侧，x = cw - lsvw
      return this.isLayoutSwapped ? (this.cw - this.lsvw) : this.cardMargin;
    }
    return this.cardMargin; // portrait: left padding
  }
  get xcRy() {
    if (this.fs) return (this.ch - this.videoDisplayHeight) / 2;
    if (this.isLs || this.isLandscapeVertical) return this.cardMargin;
    return this.shrinkVideoTop(); // portrait: top padding
  }
  /**
   * ⭐ 关灯短视频（v2 沉浸胶囊版）：仅「竖屏 UGC 关灯、非全屏」启用。
   * - PGC 保持原关灯布局（bvid 为空，related/feed 走不通）；
   * - 全屏交给现有 toggleFS 分支；
   * - 横屏/竖屏横看保持原布局，避免和旋转逻辑打架。
   */
  private isShortVideo(): boolean {
    return this.isLightsOff && !this.isPgc_ && !this.fs && !this.isLs && !this.isLandscapeVertical;
  }
  /** 视频卡尺寸：左右 12、上下 88（= (707-176)/2），与设计稿 416×531 对齐 */
  private shortCardW(): number {
    return Math.max(1, this.cw - 24);
  }
  private shortCardH(): number {
    return Math.max(1, this.ch - 176);
  }
  private shortCardX(): number {
    return Math.max(0, (this.cw - this.shortCardW()) / 2);
  }
  private shortCardY(): number {
    return Math.max(0, (this.ch - this.shortCardH()) / 2);
  }

  /** ⭐ 关灯模式：视频 fit 放大填满屏幕（保留最小边距），XComponent 实际改尺寸重绘放大 */
  private loVideoWidth(): number {
    if (this.isLightsOff) {
      const m = this.safeCM();
      const av = Math.max(1, this.cw - 2 * m);
      const ah = Math.max(1, this.ch - 2 * m);
      const arV = Number.isFinite(this.ar) && this.ar > 0 ? this.ar : 16 / 9;
      if (av / ah > arV) {
        return ah * arV;
      }
      return av;
    }
    if (this.fs) return this.videoDisplayWidth;
    if (this.isLs || this.isLandscapeVertical) return this.lsvw;
    return this.shrinkFillW(); // videoDisplayWidth 已含 cardMargin 扣减
  }
  private loVideoHeight(): number {
    if (this.isLightsOff) {
      const m = this.safeCM();
      const av = Math.max(1, this.cw - 2 * m);
      const ah = Math.max(1, this.ch - 2 * m);
      const arV = Number.isFinite(this.ar) && this.ar > 0 ? this.ar : 16 / 9;
      if (av / ah > arV) {
        return ah;
      }
      return av / arV;
    }
    if (this.fs) return this.videoDisplayHeight;
    if (this.isLs || this.isLandscapeVertical) return this.lsvh;
    return this.shrinkFillH();
  }

  /** ⭐ 常驻播放器层矩形：非全屏跟踪占位槽；全屏为整屏；进出全屏期间在两者间连续插值 */
  private ovRectX(): number {
    // 短视频：常驻层固定在视频卡矩形。拖动时整层淡出、由卡片 UI 的封面承接滑动
    // （XComponent 是原生 SURFACE，移动/裁剪它会出现整块黑屏）
    if (this.isShortVideo()) return this.shortCardX();
    if (this.fsEntering) return this.fsLerpSnapX;
    if (!this.fs) return this.ovX;
    if (this.fsLerpDir === 1) return this.fsLerpSnapX * (1 - this.fsLerpT());
    if (this.fsLerpDir === 2) return this.ovX * (1 - this.fsPanProgress);
    return 0;
  }
  private ovRectY(): number {
    if (this.isShortVideo()) return this.shortCardY();
    if (this.fsEntering) return this.fsLerpSnapY;
    if (!this.fs) return this.ovY;
    if (this.fsLerpDir === 1) return this.fsLerpSnapY * (1 - this.fsLerpT());
    if (this.fsLerpDir === 2) return this.ovY * (1 - this.fsPanProgress);
    return 0;
  }
  private ovRectW(): number {
    if (this.isShortVideo()) return this.shortCardW();
    if (this.fsEntering) return Math.max(1, this.fsLerpSnapW);
    if (!this.fs) return Math.max(1, this.ovW);
    if (this.fsLerpDir === 1) return Math.max(1, this.fsLerpSnapW + (this.cw - this.fsLerpSnapW) * this.fsLerpT());
    if (this.fsLerpDir === 2) return Math.max(1, this.cw + (this.ovW - this.cw) * (1 - this.fsPanProgress));
    return Math.max(1, this.cw);
  }
  private ovRectH(): number {
    if (this.isShortVideo()) return this.shortCardH();
    if (this.fsEntering) return Math.max(1, this.fsLerpSnapH);
    if (!this.fs) return Math.max(1, this.ovH);
    if (this.fsLerpDir === 1) return Math.max(1, this.fsLerpSnapH + (this.ch - this.fsLerpSnapH) * this.fsLerpT());
    if (this.fsLerpDir === 2) return Math.max(1, this.ch + (this.ovH - this.ch) * (1 - this.fsPanProgress));
    return Math.max(1, this.ch);
  }
  /** ⭐ 常驻层内视频实际尺寸（复刻各分支原 XComponent 尺寸表达式；⚠ 不可经 get xcW/xcH 取——getter 在普通方法中返回 undefined）
     进出全屏期间连续插值，NaN/非正值兜底防 surface 被杀 */
  private ovVideoW(): number {
    if (this.isShortVideo()) return this.shortCardW();
    let t: number;
    if (this.fs) {
      // ⭐ 退出动画（dir=2）终点=非全屏目标尺寸（横屏=lsvw，竖屏=updatePortraitSize 已重算）：
      //    动画末帧与 fs=false 后的实际尺寸一致 → 不再突缩
      t = this.fsLerpDir === 2 ? (this.isLs ? this.lsvw : this.videoDisplayWidth) : this.videoDisplayWidth;
    } else if (this.isLightsOff && !this.isLandscapeVertical) {
      t = this.loVideoWidth();
    } else if (this.isLs || this.isLandscapeVertical) {
      t = this.lsvw;
    } else {
      // ⭐ videoDisplayWidth 已含 cardMargin 扣减（updatePortraitSize: cw-2*cardMargin），这里不再重复减
      t = this.shrinkFillW();
    }
    if (!Number.isFinite(t) || t <= 0) {
      logWarn(`[FSDBG] ovVideoW invalid t=${t} fs=${this.fs} dir=${this.fsLerpDir} lo=${this.isLightsOff} lv=${this.isLandscapeVertical} ls=${this.isLs} cm=${this.cardMargin} lsvw=${this.lsvw} vdw=${this.videoDisplayWidth} shrink=${this.vidShrink} cw=${this.cw} ch=${this.ch}`);
      t = this.isLs || this.isLandscapeVertical ? this.lsvw : Math.max(1, this.cw - 2 * this.safeCM());
    }
    if (!this.fs || this.fsLerpDir === 0) return Math.max(1, t);
    if (this.fsLerpDir === 1) return Math.max(1, this.fsLerpSnapVW + (t - this.fsLerpSnapVW) * this.fsLerpT());
    return Math.max(1, t + (this.fsLerpSnapVW - t) * this.fsPanProgress);
  }
  private ovVideoH(): number {
    if (this.isShortVideo()) return this.shortCardH();
    let t: number;
    if (this.fs) {
      // ⭐ 退出动画（dir=2）终点=非全屏目标尺寸（横屏=lsvh，竖屏=updatePortraitSize 已重算）
      t = this.fsLerpDir === 2 ? (this.isLs ? this.lsvh : this.videoDisplayHeight) : this.videoDisplayHeight;
    } else if (this.isLightsOff && !this.isLandscapeVertical) {
      t = this.loVideoHeight();
    } else if (this.isLs || this.isLandscapeVertical) {
      t = this.lsvh;
    } else {
      t = this.shrinkFillH();
    }
    if (!Number.isFinite(t) || t <= 0) {
      logWarn(`[FSDBG] ovVideoH invalid t=${t} fs=${this.fs} dir=${this.fsLerpDir} lo=${this.isLightsOff} lv=${this.isLandscapeVertical} ls=${this.isLs} cm=${this.cardMargin} lsvh=${this.lsvh} vdh=${this.videoDisplayHeight} shrink=${this.vidShrink} cw=${this.cw} ch=${this.ch}`);
      t = this.isLs || this.isLandscapeVertical ? this.lsvh : Math.max(1, this.ch - 2 * this.safeCM());
    }
    if (!this.fs || this.fsLerpDir === 0) return Math.max(1, t);
    if (this.fsLerpDir === 1) return Math.max(1, this.fsLerpSnapVH + (t - this.fsLerpSnapVH) * this.fsLerpT());
    return Math.max(1, t + (this.fsLerpSnapVH - t) * this.fsPanProgress);
  }
  /**
   * ⭐ 全屏相关的圆角随过渡进度插值（原先都是 `fs ? A : B` 的布尔突变）。
   *
   * 为什么需要（真机现象："退出全屏后最后四个黑色的圆角会突然收起"）：
   *   退出全屏时几何（ovRect* / ovVideoW·H）是**逐帧连续插值**的，而圆角只在 fs 翻转的
   *   最后一帧从全屏值直接跳到非全屏值 —— 于是整个播放层带着圆角一路缩小、四角外侧一直是
   *   容器的纯黑底（color_player_background = #000000），末帧那四块黑色圆角被一刀切掉。
   *   ⚠️ 圆角属性写在 .animation() 之后，本就不受那条 120ms 隐式动画管辖 —— 这也是它表现为
   *      "瞬跳"而非"缓动"的原因；改成跟进度逐帧取值后，不需要任何隐式动画。
   *
   * @param fsRadius     全屏态的圆角
   * @param normalRadius 非全屏态（目标）的圆角
   *
   * 进度取值刻意与几何的分支保持一致（对照 ovVideoW / ovRectW 的同款判断）：
   *   dir=1 进入：用 fsLerpT()（手势中途接管时它才是相对本次过渡的真实进度）
   *   dir=2 退出：用 fsPanProgress（该分支的几何就是拿它算的：1=全屏 → 0=非全屏）
   *   dir=0 无过渡：直接取稳态值（瞬时切换时几何也是瞬跳，两者一致）
   */
  private fsLerpRadius(fsRadius: number, normalRadius: number): number {
    if (!this.fs) {
      return normalRadius;
    }
    if (this.fsLerpDir === 1) {
      return normalRadius + (fsRadius - normalRadius) * this.fsLerpT();
    }
    if (this.fsLerpDir === 2) {
      return normalRadius + (fsRadius - normalRadius) * Math.min(1, Math.max(0, this.fsPanProgress));
    }
    return fsRadius;
  }
  /** ⭐ 全屏黑板/视频背景随动画进度渐显渐隐：进入 0→黑、退出黑→0（仅插值期间），
     避免进/出全屏瞬间整屏或四周"先黑一片"、结束帧突变消失 */
  private ovPlateBg(): ResourceColor {
    if (!this.fs) return $r('app.color.color_player_background');
    if (this.fsLerpDir === 0) return $r('app.color.color_player_background');
    const p = Math.min(1, Math.max(0, this.fsPanProgress));
    const alpha = this.fsLerpDir === 1 ? p : (1 - p);
    return `rgba(0, 0, 0, ${alpha.toFixed(3)})`;
  }
  /** ⭐ 快照插值起点：进入时=当前槽矩形与视频尺寸，退出时=全屏矩形与全屏视频尺寸 */
  private captureFSSnapshot(): void {
    this.fsLerpSnapX = this.ovRectX();
    this.fsLerpSnapY = this.ovRectY();
    this.fsLerpSnapW = this.ovRectW();
    this.fsLerpSnapH = this.ovRectH();
    this.fsLerpSnapVW = this.ovVideoW();
    this.fsLerpSnapVH = this.ovVideoH();
    logInfo(`[FSDBG] snapshot fs=${this.fs} dir=${this.fsLerpDir} P=${this.fsPanProgress.toFixed(3)} rect=(${this.fsLerpSnapX.toFixed(1)},${this.fsLerpSnapY.toFixed(1)},${this.fsLerpSnapW.toFixed(1)},${this.fsLerpSnapH.toFixed(1)}) vid=(${this.fsLerpSnapVW.toFixed(1)},${this.fsLerpSnapVH.toFixed(1)}) ctx: ovW=${this.ovW.toFixed(1)} ovH=${this.ovH.toFixed(1)} VDW=${this.videoDisplayWidth.toFixed(1)} VDH=${this.videoDisplayHeight.toFixed(1)} ar=${this.ar.toFixed(3)} shrink=${this.vidShrink.toFixed(2)} isLs=${this.isLs} lsvw=${this.lsvw.toFixed(1)} lsvh=${this.lsvh.toFixed(1)} cw=${this.cw.toFixed(1)} ch=${this.ch.toFixed(1)} cardMargin=${this.cardMargin} isLightsOff=${this.isLightsOff} isLV=${this.isLandscapeVertical}`);
  }
  /**
   * ⭐ 常驻层弹幕画布尺寸 = **播放器区域**（不是整个常驻层，也不是视频画面本身）。
   *
   * 三者的区别（真机横屏 2120×1320 = 833×519vp 实测）：
   *   · 常驻层               = [0,0,2120,1320]（全屏态）/ 视频槽（非全屏态）
   *   · **播放器区域（要的就是它）** = 全屏＝整屏；横屏/竖屏横看＝视频槽；竖屏＝视频区
   *   · 视频画面             = 播放器区域内按画幅适配后的那块画面（4:3 全屏时只有 692×519vp）
   *
   * ⚠️ 踩过的两个坑，别再来回改：
   *   ① 原先非全屏分支返回 `this.cw/ch`（**窗口**宽高）而组件是 `.width('100%')` 铺满常驻层 ⇒
   *      传参与 surface 两套尺寸，横屏下弹幕画到右侧评论栏上（"右侧堆着一堆弹幕"）；
   *   ② 修 ① 时把全屏也收成了"视频画面"⇒ **左右黑边里没有弹幕**，用户反馈"非播放区域被裁掉了"。
   *   ⇒ 正确的口径就是"播放器区域"：全屏时黑边属于播放器，弹幕应当铺满；非全屏时不得越出视频槽。
   */
  private ovDanmakuCW(): number {
    if (this.isShortVideo()) return this.shortCardW();
    if (this.fs) return Math.max(1, this.cw);
    if (this.isLs || this.isLandscapeVertical) return Math.max(1, this.lsvw);
    if (this.isLightsOff && !this.isLandscapeVertical) return Math.max(1, this.loVideoWidth());
    return Math.max(1, this.videoDisplayWidth);
  }
  private ovDanmakuCH(): number {
    if (this.isShortVideo()) return this.shortCardH();
    if (this.fs) return Math.max(1, this.ch);
    if (this.isLs || this.isLandscapeVertical) return Math.max(1, this.lsvh);
    if (this.isLightsOff && !this.isLandscapeVertical) return Math.max(1, this.loVideoHeight());
    return Math.max(1, this.videoDisplayHeight);
  }
  /** 弹幕层在常驻层内的偏移：播放器区域在常驻层里是居中的（Stack 默认 Center 对齐） */
  private ovDanmakuX(): number {
    // 短视频：弹幕跟随视频一起在“视频卡舞台”内部，舞台已定位到卡矩形 ⇒ 偏移 0
    if (this.isShortVideo()) return 0;
    return Math.max(0, (this.ovRectW() - this.ovDanmakuCW()) / 2);
  }
  private ovDanmakuY(): number {
    if (this.isShortVideo()) return 0;
    return Math.max(0, (this.ovRectH() - this.ovDanmakuCH()) / 2);
  }
  /** ⭐ 首次 build 前同步估算常驻层矩形（首帧后由占位槽 onAreaChange 精确接管） */
  private initOverlayRectSync(): void {
    if (this.isLandscapeVertical) {
      this.ovW = this.lsvw;
      this.ovH = this.lsvh;
      this.ovX = this.isLayoutSwapped ? (this.cw - this.lsvw - 80 - this.cardMargin) : (80 + this.cardMargin);
      this.ovY = this.cardMargin;
    } else if (this.isLs) {
      this.ovW = this.lsvw;
      this.ovH = this.lsvh;
      this.ovX = this.isLayoutSwapped ? (this.cw - this.lsvw - this.cardMargin) : this.cardMargin;
      this.ovY = this.cardMargin;
    } else {
      const slotW = this.shrinkSlotW();
      this.ovW = slotW;
      this.ovH = this.shrinkSlotH();
      this.ovX = this.cardMargin + (this.cw - 2 * this.cardMargin - slotW) / 2;
      this.ovY = this.shrinkVideoTop();
    }
  }

  /**
   * ⭐ 「缩小 / 还原视频」的统一动画入口。
   * 三个触发点（悬浮按钮 / 评论上滑 / 滚动触发）与三处自动还原（切 tab、转横屏、左右滑切 tab）
   * 全部改走这里，保证行为一致。
   *
   * ⚠️ 用 `animateTo` 而不是自己 setInterval 逐帧推进 —— 这一点试错过两轮，别再改回去：
   *    逐帧推进虽然能让所有消费方读到同一个连续值（同步最好），但 **JS 定时器不对齐 vsync**，
   *    每次 tick 各自找时机渲染，帧间隔在 14/18/22ms 之间抖 → 观感是 judder（真机"卡卡的"），
   *    而且日志里每帧都会出现 `RSNode::AddChild(video_xcSurface)`。`animateTo` 是渲染侧动画、
   *    由 vsync 驱动，节奏天然均匀。
   *
   * 三层同步靠的是下面三件事，而不是逐帧推进：
   *   ① 全部 8 个写入点都走本方法 —— 同一个 animateTo 作用域，时长曲线完全一致；
   *   ② `shrinkAnimating` 期间把常驻播放层那两条隐式 `.animation()` 的时长改成与本方法**同参**
   *      （SHRINK_ANIM_DURATION + EaseOut）。⚠️ 不是降为 0：节点自带的 `.animation()` 会**覆盖**
   *      外层 animateTo —— 写 120 时它先到位、写 0 时它瞬跳，两者都不同步；只有同参才对齐；
   *   ③ 弹幕画布在动画期间冻结尺寸（`dmFreezeW/H`）—— 否则画布每帧重建 surface；
   *      同时整段关掉弹幕渲染（见下）。
   *   容器矩形仍走 onAreaChange 异步路径，跨一帧，但每帧只差总位移的约 3%，看不出来。
   */
  /**
   * ⭐ 缩小后自动暂停 / 还原后继续（个性化「缩小后暂停播放」开关）。
   *   - 只在**由本开关触发**的暂停上恢复：用户缩小前本来就是暂停态时不自动播放；
   *   - **不动 `userPaused_`**：那是「用户主动暂停」的语义，被别处用于自动播放判定，
   *     这里若改写它会造成"还原后不自动播放"之类的连带 bug。
   */
  private applyShrinkPause(shrunk: boolean): void {
    if (!this.shrinkPauseOnMinimize) return;
    if (!this.av) return;
    if (shrunk) {
      if (!this.play) return;
      this.shrinkPausedByPref_ = true;
      this.av.pause();
      this.avAudio?.pause();
      this.play = false;
      LiveViewHelper.updatePlayState(false);
    } else {
      if (!this.shrinkPausedByPref_) return;
      this.shrinkPausedByPref_ = false;
      this.av.play();
      this.avAudio?.play();
      this.play = true;
      LiveViewHelper.updatePlayState(true);
    }
  }

  private animateVidShrink(target: number): void {
    // 重入：上一次动画若还在飞，先把它留下的状态补回来（弹幕开关、冻结），再从当前值继续。
    // ⚠️ 用代数号而不是定时器句柄：animateTo 的 onFinish 可能在新一轮已开始之后才触发，
    //    靠句柄无法区分，会导致新一轮的冻结/关闭被旧的收尾误清掉。
    this.shrinkAnimGen++;
    const gen = this.shrinkAnimGen;
    if (this.shrinkAnimating) {
      this.danmakuConfig.enable = this.isDanmakuEnabled;
    }
    const from = this.vidShrink;
    const to = Math.min(1, Math.max(0, target));
    if (Math.abs(to - from) < 0.001) {
      this.vidShrink = to;
      this.shrinkAnimating = false;
      this.dmFreezeW = 0;
      this.dmFreezeH = 0;
      this.applyShrinkPause(to > 0.5);
      return;
    }
    this.shrinkAnimating = true;
    // ⭐ 冻结弹幕画布尺寸（原因见 dmFreezeW 注释）：抓当前尺寸，动画期间不再跟随容器变化
    this.dmFreezeW = this.ovDanmakuCW();
    this.dmFreezeH = this.ovDanmakuCH();
    // ⭐ 关掉弹幕渲染循环：渲染循环是 60fps 的画布重绘，会和几何动画抢主线程。
    //    ⚠️ 不只是"动画这 300ms"—— 缩小态**全程**都要关（缩小后小窗很小（默认 120vp 正圆），弹幕看不到还占主线程），
    //       所以收尾时按目标状态决定是否恢复：目标是缩小就保持关闭，否则恢复用户原值。
    // ⚠️ 这里**不记录**"动画前的 enable"再恢复 —— 缩小态下 enable 本身已是 false，
    //    若在"还原动画"开始时记录，记到的就是被自己关掉的值，还原后弹幕永远回不来（真机踩过）。
    //    恢复一律以用户开关 `isDanmakuEnabled` 为准：它由 syncDanmakuEnabled 同步维护，
    //    语义就是"用户想不想显示弹幕"，且不受本动画的临时关闭污染。
    this.danmakuConfig.enable = false;

    const finish = (): void => {
      if (this.shrinkAnimGen !== gen) return;   // 已被更新的一轮取代，不要动它的状态
      this.vidShrink = to;                      // 收尾落到精确目标值（阈值判断依赖它）
      this.shrinkAnimating = false;
      this.dmFreezeW = 0;
      this.dmFreezeH = 0;
      // 缩小态：保持关闭；还原态：恢复**用户开关**（不是"动画前的值"——见下面那段注释）
      this.danmakuConfig.enable = (to > 0.5) ? false : this.isDanmakuEnabled;
      // ⭐ 缩小后暂停播放（在动画收尾时执行：动画期间还在播，缩到位才停）
      this.applyShrinkPause(to > 0.5);
    };
    try {
      this.getUIContext().animateTo(
        { duration: this.SHRINK_ANIM_DURATION, curve: Curve.EaseOut, onFinish: finish },
        () => { this.vidShrink = to; });
    } catch (_) {
      finish();
    }
  }

  /** ⭐ 内容 Column 全局锚点（旋转/分屏等导致页面偏移时保证常驻层坐标系正确） */
  private onColumnArea = (o: Area, n: Area) => {
    const gp = n.globalPosition;
    if (!gp) return;
    const ax = gp.x as number;
    const ay = gp.y as number;
    setTimeout(() => {
      this.ovAnchorX = ax;
      this.ovAnchorY = ay;
    }, 0);
  };
  /** ⭐ 分支占位槽：把当前分支视频容器的实际布局矩形同步给常驻播放器层 */
  private onSlotArea = (o: Area, n: Area) => {
    const w = n.width as number;
    const h = n.height as number;
    if (w <= 0 || h <= 0) return;
    const gp = n.globalPosition;
    const x = (gp ? (gp.x as number) : 0) - this.ovAnchorX;
    const y = (gp ? (gp.y as number) : 0) - this.ovAnchorY;
    if (x !== this.ovX || y !== this.ovY || w !== this.ovW || h !== this.ovH) {
      logInfo(`[FSDBG] slot rect=(${x.toFixed(1)},${y.toFixed(1)},${w.toFixed(1)},${h.toFixed(1)}) fs=${this.fs}`);
      // ⭐ 延迟到本帧渲染结束后应用（onAreaChange 期间改 @State 属渲染中改状态）
      setTimeout(() => {
        this.ovX = x;
        this.ovY = y;
        this.ovW = w;
        this.ovH = h;
      }, 0);
    }
  };

  /** ⭐ 内容分支键：非全屏时取当前布局状态；fs 期间冻结为进入前的快照分支 */
  private contentBranchKey(): string {
    if (this.fs) return this.preFsBranch;
    return this.isLandscapeVertical ? 'lv' : (this.isLs ? 'isLs' : 'portrait');
  }

  /** ⭐ 转场状态翻转（fs / rotationInProgress 任一变化）：转场中评论区瞬时隐藏并移出布局；
     全部转场结束后（非全屏且旋转完成）渐显回来 */
  private onTransitionFlip(): void {
    // ⭐ 全屏/旋转期间暂停封面流光定时器（封面 linearGradient 每帧重算抢主线程，影响全屏动画帧率）；
    //   转场结束后若封面仍显示（视频未就绪）则恢复流光
    if (this.fs || this.rotationInProgress) {
      if (this.coverGlowTimer) {
        clearInterval(this.coverGlowTimer);
        this.coverGlowTimer = 0;
      }
      this.commentFade = 0;
      return;
    }
    if (!this.coverGlowTimer && !this.contentVisible) {
      this.coverGlowTimer = setInterval(() => { this.coverGlowAngle = (this.coverGlowAngle + 3) % 360; }, 16);
    }
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
        this.commentFade = 1;
      });
    }, 0);
  }

  /** ⭐ 视频就绪（封面永久隐藏）后停止流光定时器，避免定时器空转 */
  private onContentVisibleChange(): void {
    if (this.contentVisible && this.coverGlowTimer) {
      clearInterval(this.coverGlowTimer);
      this.coverGlowTimer = 0;
    }
  }

  /** ⭐ 评论区转场可见性：转场期间（全屏/旋转中）移出布局（不参与重排），结束后渐显 */
  private commentAreaVis(): Visibility {
    return (this.fs || this.rotationInProgress) ? Visibility.None : Visibility.Visible;
  }
  /** ⭐ 进入全屏前快照当前内容分支（fs 期间冻结渲染，退出后分支条件不变 → 零重挂载） */
  private snapshotPreFsBranch(): void {
    this.preFsBranch = this.isLandscapeVertical ? 'lv' : (this.isLs ? 'isLs' : 'portrait');
  }
  /** ⭐ 内容分支常驻渲染：与常驻播放器层配合，旋转只改几何不换子树 */
  @Builder
  buildContentBranch() {
    if (this.contentBranchKey() === 'lv') {
      this.buildLandscapeVertical()
    } else if (this.contentBranchKey() === 'isLs') {
      this.buildLandscape()
    } else {
      this.buildPortraitLayout()
    }
  }

  /** ⭐ 关灯+竖屏非全屏（本布局分支内必为竖屏）+横画幅，且开启"关灯视频外弹幕"：弹幕平移到视频下方空白区 */
  private isLightsOffDanmakuOutside(): boolean {
    return this.isLightsOff && this.ar >= 1 && this.lightsOffDanmakuOutside;
  }
  /** ⭐ 关灯+竖屏横看（竖屏视频横屏非全屏）且开启"关灯视频外弹幕"：弹幕平移到右侧空白区 */
  private isLightsOffDanmakuRight(): boolean {
    return this.isLightsOff && this.isLandscapeVertical && this.ar < 1 && this.lightsOffDanmakuOutside;
  }
  @State sp: boolean = false; @State qp: boolean = false; @State mp: boolean = false; @State mpb: boolean = false; @State cacheQnPopup: boolean = false; @State colorStylePopup: boolean = false; @State ip: boolean = false; @State cp: boolean = false  // ⭐ cp=全屏评论浮层开关
  // ⭐ 缓存提示条（可点击跳转缓存列表页）：visible=显示, done=是否已完成, paused=是否已暂停
  @State cacheHintVisible: boolean = false
  @State cacheHintDone: boolean = false
  @State cacheHintPaused: boolean = false
  // ⭐ 缓存提示条拖拽位置（可随意拖动，位置持久化）
  @StorageLink('cacheHintLeft') cacheHintLeft: number = 16
  @StorageLink('cacheHintBottom') cacheHintBottom: number = 96
  // ⭐ 缓存提示条拖拽状态
  @State private cacheHintDragStartX: number = 0
  @State private cacheHintDragStartY: number = 0
  // ⭐ 提示条关闭按钮点击标志（ClickEvent 无 stopPropagation，阻止冒泡触发跳转）
  private hintCloseClicked_: boolean = false
  @State cs: string = 'original' // 当前画风：original/vivid/leica/film
  @State icp: boolean = false  // instantClosePopup：退出全屏时弹窗瞬间关闭，不播放退出动画
  @State sw: number = 300; @State qn: number = 116; @State ql: string = '1080P60'
  @State qs: boolean = false; @State vd: VideoDetail | null = null
  @State relatedVideos: RecommendItem[] = []; @State relatedLoading: boolean = false; @State relatedPressedId: string = ''
  // ⭐ 关灯短视频 feed（v2 沉浸胶囊版）
  //    items = 当前视频 + 相关推荐；index 指向当前；dragY 只驱动视频卡（胶囊固定）。
  @State shortItems: ShortVideoFeedItem[] = []
  @State shortIndex: number = 0
  @State shortDragY: number = 0
  @State shortSettling: boolean = false
  @State shortSwitching: boolean = false
  @State shortCover: string = ''
  private shortGen: number = 0
  private shortFetching: boolean = false
  private shortCommentsAid: number = 0
  private shortTouchX: number = 0
  // ⭐ 相关推荐限量渲染：详情卡是异构 Scroll，无法整体改 List（LazyForEach 在 Scroll 里不生效）——
  //    首屏只挂载前 10 条，"展开更多"递增；旋转/全屏重布局负载与列表总长解耦
  @State relatedRenderCount: number = 10
  // ⭐ 评论区限量渲染：只挂载前 commentRenderCount 条，"展开更多评论"递增（负载与评论总数解耦）
  @State commentRenderCount: number = 20
  @State commentLoadLatch: boolean = false  // 加载更多后置位，离开底部才复位，防止 onScrollFrameBegin 连环触发下一页
  private commentRenderCountFull: number = 20  // 旋转前保存累积渲染配额，旋转结束恢复
  @State ldc: boolean = false; @State ldd: boolean = false
  @State commentCursor: number = 0; @State hm: boolean = true; @State at: number = 0
  // 限流状态
  @State rateLimited: boolean = false;
  // ⭐ 评论加载更多锁（防止滚动到底部重复触发）
  @State isLoadingMore: boolean = false;
  // ⭐ 排序切换防抖
  @State sortChangePending: boolean = false;
  private sortChangeTimer: number | undefined = undefined;
  // 评论数据源（用于 LazyForEach）
  private commentDataSource: CommentDataSource = new CommentDataSource();
  // ⭐ 延迟评论区加载（等页面入场动画完成后才加载）
  @State commentsInitialized: boolean = false;
  // 回复分页状态（已整合到 ObservableComment 中，此处保留用于兼容）
  @State replyPageMap: Map<number, number> = new Map();
  // ⭐ B站登录状态
  @StorageLink('biliCookie') biliCookie: string = '';
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('customThemeColor') @Watch('rebuildSegmentOptions') customThemeColor: string = '#007DFF';
  @StorageLink('videoBgMode') videoBgMode: string = 'cover';
  @StorageLink('videoBgColor') videoBgColor: string = '#007DFF';
  @StorageLink('shrinkVideoOnScroll') shrinkVideoOnScroll: boolean = false;
  // ⭐ 缩小后的小窗样式（个性化 → 视频页动画）：circle / square / ratio / hidden
  @StorageLink('shrinkWindowStyle') shrinkWindowStyle: string = 'circle';
  // ⭐ 缩小后自动暂停播放（还原时按需继续）
  @StorageLink('shrinkPauseOnMinimize') shrinkPauseOnMinimize: boolean = false;
  // ⭐ 缩小后小窗的尺寸（vp，个性化 → 视频页动画 → 小窗大小）
  @StorageLink('shrinkWindowSize') shrinkWindowSize: number = 120;
  @StorageLink('cardTransparentStyle') cardTransparentStyle: boolean = false;
  @StorageLink('playerFollowTheme') @Watch('rebuildSegmentOptions') playerFollowTheme: boolean = false;
  @StorageLink('cardBgBlurAmount') cardBgBlurAmount: number = 24;
  @StorageLink('cardBgDarkness') cardBgDarkness: number = 50;
  @StorageLink('videoBgCustomWallpaper') videoBgCustomWallpaper: string = '';
  @StorageLink('videoBgCustomWallpaperBlur') videoBgCustomWallpaperBlur: number = 0;
  @StorageLink('videoBgCustomWallpaperDarkness') videoBgCustomWallpaperDarkness: number = 50;
  @StorageLink('cardTransparentStyleVideo') cardTransparentStyleVideo: boolean = false;
  @StorageLink('cardStyleVideoDetail') cardStyleVideoDetail: boolean = true;
  @StorageLink('cardStyleVideoCommentSection') cardStyleVideoCommentSection: boolean = true;
  @StorageLink('cardBorderWidth') cardBorderWidth: number = 1.5;
  @StorageLink('cardCustomColor') cardCustomColor: string = '';
  @StorageLink('cardMargin') @Watch('onCardMarginChange') cardMargin: number = 12;
  @StorageLink('cardBorderRadius') cardBorderRadius: number = 20;
  @StorageLink('cardStyleVideoDescription') cardStyleVideoDescription: boolean = true;
  @StorageLink('cardStyleVideoSegmentBtn') cardStyleVideoSegmentBtn: boolean = true;
  @StorageLink('cardStyleVideoInteractBtns') cardStyleVideoInteractBtns: boolean = true;
  @StorageLink('cardStyleVideoNavBtns') cardStyleVideoNavBtns: boolean = true;
  @StorageLink('cardBorderFollowTheme') cardBorderFollowTheme: boolean = false;
  @StorageLink('cardBorderOpacity') cardBorderOpacity: number = 40;
  @StorageLink('cardBgOpacity') cardBgOpacity: number = 30;
  // ⭐ 全屏切换动画开关（统一为视频连续缩放平移；关闭=瞬时切换）
  @StorageLink('fsAnimOn') fsAnimOn: boolean = true;
  // ⭐ 页面加载动画模式
  @StorageLink('pageEnterAnim') pageEnterAnim: string = 'none';
  // ⭐ 页面加载动画最终参数（固定不可调）
  private readonly PE_ENTER_DURATION: number = 400;   // 名义时长 ms
  private readonly PE_ENTER_VELOCITY: number = 0.5;   // 弹簧初速：越大冲得越猛/回弹感越强
  private readonly PE_ENTER_DAMPING: number = 13;     // 弹簧阻尼：越大回弹越少
  @State pageEnterProgress: number = 0
  // ⭐ 全屏切换动画时长（ms，固定）
  private readonly FS_ANIM_DURATION: number = 200;
  // ⭐ 全屏手势回弹刚度（固定）
  private readonly FS_SPRING_STIFFNESS: number = 28;
  // ⭐ PC/2in1 屏幕窗口固定不旋转：全屏走"窗口内全屏"分支（跳过旋转 API，手动切横屏布局）
  private readonly isPcDevice: boolean = deviceInfo.deviceType === '2in1' || deviceInfo.deviceType === 'pc';
  private pcPreFsIsLs: boolean = false;  // PC 进入全屏前的 isLs，退出时恢复
  @StorageLink('da') da: boolean = false;

  // ═══ 页面加载动画计算方法（由 pageEnterProgress 驱动，0→1）═══
  private calcPageEnterScaleX(): number {
    const P = this.pageEnterProgress;
    if (this.pageEnterAnim === 'none') return 1;
    if (this.pageEnterAnim === 'scaleFade') return P;
    if (this.pageEnterAnim === 'cardStack') return 0.9 + 0.1 * P;
    if (this.pageEnterAnim === 'flip') return P;
    if (this.pageEnterAnim === 'minimizeCorner') return P;
    if (this.pageEnterAnim === 'diagonal') return P;
    return 0.85 + 0.15 * P;
  }
  private calcPageEnterScaleY(): number {
    const P = this.pageEnterProgress;
    if (this.pageEnterAnim === 'none') return 1;
    if (this.pageEnterAnim === 'scaleFade') return P;
    if (this.pageEnterAnim === 'cardStack') return 0.9 + 0.1 * P;
    if (this.pageEnterAnim === 'flip') return 1;
    if (this.pageEnterAnim === 'minimizeCorner') return P;
    if (this.pageEnterAnim === 'diagonal') return P;
    return 0.85 + 0.15 * P;
  }
  private calcPageEnterOffsetX(): number {
    if (this.pageEnterAnim === 'none') return 0;
    if (this.pageEnterAnim === 'slideLeftRight') return (1 - this.pageEnterProgress) * this.cw;
    if (this.pageEnterAnim === 'diagonal') return (1 - this.pageEnterProgress) * this.cw * 0.3;
    return 0;
  }
  private calcPageEnterOffsetY(): number {
    const P = this.pageEnterProgress;
    if (this.pageEnterAnim === 'none') return 0;
    if (this.pageEnterAnim === 'cardStack') return (1 - P) * this.ch * 0.3;
    if (this.pageEnterAnim === 'slideUpDown') return (1 - P) * this.ch;
    if (this.pageEnterAnim === 'diagonal') return (1 - P) * this.ch * 0.3;
    if (this.pageEnterAnim === 'minimizeCorner') return (1 - P) * (this.ch / 2);
    return 0;
  }
  private calcPageEnterOpacity(): number {
    if (this.pageEnterAnim === 'none') return 1;
    if (this.pageEnterAnim === 'scaleFade' || this.pageEnterAnim === 'blurFade') return this.pageEnterProgress;
    return 1;
  }
  private calcPageEnterBlur(): number {
    if (this.pageEnterAnim === 'none') return 0;
    if (this.pageEnterAnim === 'blurFade') return (1 - this.pageEnterProgress) * 15;
    return 0;
  }

  @State isBiliLoggedIn: boolean = false;
  @State hasMoreRepliesMap: Map<number, boolean> = new Map();
  @State loadingRepliesMap: Map<number, boolean> = new Map();
  // ⭐ SegmentButton 的 options 参数是 @ObjectLink，必须传状态变量（编译强制）；
  //   主题色/跟随开关变化由 @Watch('rebuildSegmentOptions') 重建保证生效
  @State tabOpt: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [{ text: '详情' }, { text: '评论' }],
    fontColor: $r('app.color.color_player_text_secondary'),
    selectedFontColor: $r('app.color.color_player_text'),
    fontWeight: FontWeight.Normal,
    selectedFontWeight: FontWeight.Medium,
    backgroundColor: Color.Transparent,
    selectedBackgroundColor: this.playerFollowTheme ? this.customThemeColor : $r('app.color.color_bilibili_pink'),
    fontSize: 14,
    selectedFontSize: 14,
    buttonPadding: { top: 8, right: 16, bottom: 8, left: 16 },
  })
  @State tabSelIdx: number[] = [0]
  @State swipeProgress: number = 0   // 滑动偏移进度: 0=详情, -1=评论(左滑), 1=右滑
  @State isSwiping: boolean = false   // 是否正在执行滑动手势
  @State isLs: boolean = false
  @State isAnimatingToFS: boolean = false
  @State fsEntering: boolean = false  // 进入全屏旋转期间常驻层固定在快照位置
  @State fsPanProgress: number = 0
  @State fsLerpStartP: number = 0  // 全屏插值动画起点(手势全屏时=当前fsPanProgress,点击全屏时=0)
  private fsLerpT(): number { if (this.fsLerpStartP >= 1) return 1; return Math.min(1, Math.max(0, (this.fsPanProgress - this.fsLerpStartP) / (1 - this.fsLerpStartP))); }
  private fsHapticPrev: number = 0
  private detailScroller: Scroller = new Scroller()
  private commentScroller: ListScroller = new ListScroller()  // 评论区滚动控制器（List 专用）
  private fsCommentScroller: ListScroller = new ListScroller() // 全屏评论浮层专用（与竖屏 List 隔离，避免同屏双 List 共用 scroller 互相污染滚动状态）
  @State detailScrollAtTop: boolean = true
  @State isLandscapeVertical: boolean = false
  @StorageLink('phoneLayoutToggle') phoneLayoutToggle: boolean = false
  @State landShowDetail: boolean = true  // 直板机布局开启时：true=详情卡片, false=评论区
  @State @Watch('onContentVisibleChange') contentVisible: boolean = false;
  @State coverGlowAngle: number = 0  // ⭐ 封面跑马灯流光角度
  private coverGlowTimer: number = 0  // ⭐ 流光动画定时器
  @State hdCoverReady: boolean = false  // ⭐ 1080w 封面预解码完成；未完成时封面回退原始 URL 秒显，避免黑屏
  // ⭐ 评论输入弹层（写评论/回复共用）
  @State commentSheetVisible: boolean = false;
  @State commentSheetMode: string = 'new'  // 'new' = 写评论 | 'reply' = 回复
  @State replyRoot: number = 0
  @State replyParent: number = 0
  @State replyTargetName: string = ''
  // ⭐ 发弹幕弹层
  @State showDanmakuSheet: boolean = false
  // ⭐「更多 → 弹幕设置」详细面板（PiliPlus showSetDanmaku 同款）
  @State showDanmakuSettingSheet: boolean = false
  private dmSettingApplyTimer: number = 0   // 「应用设置」防抖句柄
  private dmSettingVersion: number = 0      // 递增版本号 → AppStorage → DanmakuView @Watch
  @State dmMode: number = 1            // B站弹幕模式：1=滚动 4=底部 5=顶部
  @State selfDanmakuList: DanmakuItem[] = []  // 自发弹幕（发送成功后注入弹幕层上屏）
  @State expandedCommentIds: Set<number> = new Set()  // 当前展开的评论ID集合（支持多评论同时展开）
  private savedScrollOffsetMap: Map<number, number> = new Map()  // 每个展开评论记录的滚动位置
  @State repliesVersion: number = 0  // 用于强制ForEach刷新

  // ⭐ 智感握持 - 安全区域原始值（px→vp转换后）
  @State private gripSafeAreaBottom: number = 80;   // 默认值，仅兜底
  @State private gripSafeAreaRight: number = 24;    // 默认值，仅兜底
  @State private gripSafeAreaLeft: number = 24;     // 默认值，仅兜底
  // ⭐ 延迟加载评论：等页面入场动画完成后才加载
  private pendingCommentAid: number = 0;
  // ⭐ PGC 季信息复用缓存：ensurePgcContext() 为补 seasonId/aid 已经完整拉过一次季接口，
  //   而季接口在 API 层【没有缓存】，若不留下这份结果，接下来填详情卡片/评论会再发一次
  //   完全相同的请求（多 100~300ms 的无谓等待）。存下来给 fillPgcDetailFromSeason() 复用。
  private pgcSeasonInfoCache_: PgcSeasonInfo | null = null;
  // ⭐ 评论定位：从消息通知跳转时，滚动到指定评论
  private commentRootId_: number = 0;
  private commentSecondaryId_: number = 0;
  // ⭐ 智感握持 - 最终计算出的按钮定位（随热区和方向动态变化）
  @State private smartGripBottom: number = 120;     // 底部边距(vp)
  @State private smartGripRight: number = 32;       // 右侧边距(vp)
  @State private smartGripLeft: number = -1;        // 左侧边距(vp, -1=不启用)
  // ⭐ 智感握持 - 当前握持状态（LEFT_HAND_HELD/RIGHT_HAND_HELD…）
  @State private hand: number = 16;                 // motion.HoldingHandStatus.UNKNOWN_STATUS
  // ⭐ 智感握姿开关
  @StorageLink('smartGripEnabled') smartGripEnabled: boolean = true;
  @StorageLink('floatBtnFollowTheme') floatBtnFollowTheme: boolean = true;
  // ⭐ 拖拽自定义按钮位置（智感握姿关闭时生效）
  @StorageLink('videoShrinkBtnSide') videoShrinkBtnSide: string = 'right';
  @StorageLink('videoShrinkBtnY') videoShrinkBtnY: number = 120;
  @StorageLink('videoLightBtnSide') videoLightBtnSide: string = 'right';
  @StorageLink('videoLightBtnY') videoLightBtnY: number = 120;
  // ⭐ 缩小按钮拖拽状态
  @State private shrinkDragStartY: number = 0;
  @State private shrinkDragOffsetX: number = 0;
  @State private shrinkIsDragging: boolean = false;
  @State private shrinkDragDeltaY: number = 0;
  private shrinkTouchStartWX: number = 0;
  private shrinkTouchStartWY: number = 0;
  private shrinkTouchMoved: boolean = false;
  private commentSwipeStartY: number = 0;
  private commentSwipeTriggered: boolean = false;
  // ⭐ 关灯按钮拖拽状态
  @State private lightDragStartY: number = 0;
  @State private lightDragOffsetX: number = 0;
  @State private lightIsDragging: boolean = false;
  @State private maxFloatBtnBottom: number = 592; // 按钮顶部距屏幕顶部至少80vp
  // 是否已监听握持事件（防止重复监听）
  private gripListenerSubscribed: boolean = false;

  // ⭐ 互动状态（点赞、投币、收藏）
  @State isLiked: boolean = false
  @State isCoined: boolean = false
  @State isFavorited: boolean = false
  @State likeCount: number = 0
  @State coinCount: number = 0
  @State favoriteCount: number = 0
  // ⭐ 关注状态
  @State isFollowed: boolean = false
  @State followScale: number = 1
  @State followPressed: boolean = false
  // ⭐ 按钮动画状态
  @State likeScale: number = 1
  @State coinScale: number = 1
  @State favoriteScale: number = 1
  @State darkModeScale: number = 1  // 深色模式切换缩放
  @State darkModePressed: boolean = false  // 深色模式按钮点击变色
  @State episodeScale: number = 1  // 选集图标缩放
  @State episodePressed: boolean = false  // 选集按钮点击变色
  // ⭐ 最小化到悬浮按钮动画状态
  @State minimizeScale: number = 1
  @State minimizePressed: boolean = false
  // ⭐ 返回按钮动画状态（横屏竖屏模式左下角）
  @State backBtnScale: number = 1
  @State backBtnPressed: boolean = false

  // ⭐ 后台播放开关（持久化）
  @StorageLink('bgp') bgp: boolean = false
  // ⭐ 监听 onBackground 时间戳，确认切后台后恢复播放
  @StorageLink('appBackgroundTimestamp') @Watch('onAppBackgroundConfirmed') appBgTimestamp: number = 0
  // ⭐ 应用是否已切后台（EntryAbility.onBackground/onForeground 维护）：区分「跳页」与「真后台」
  @StorageLink('appInBackground') appInBackground: boolean = false
  // ── 画中画（自动小窗 · 页面模式）：回桌面时播放中自动弹小窗，以本页 XComponent 为小窗载体 ──
  @StorageLink('autoPip') autoPip: boolean = true
  private pipCtrl_: PiPWindow.PiPController | null = null
  private pipCreating_: boolean = false
  private pipActive_: boolean = false // 小窗展示中（ABOUT_TO_START ~ STOPPED/还原）

  // ⭐ 选集状态
  @State currentPageIndex: number = 0  // 当前分P索引
  @State showEpisodeSheet: boolean = false  // 选集弹窗显示状态
  // ⭐ 选集列表 scroller（弹窗打开时定位到当前播放集数）
  private episodeScroller_: Scroller = new Scroller()
  // ⭐ 选集分段：当前所在段索引（0=1-20, 1=21-40...），用于分段栏高亮
  @State episodeSegment: number = 0

  // ⭐ 合集状态
  @State seasonScale: number = 1  // 合集按钮缩放
  @State seasonPressed: boolean = false  // 合集按钮点击变色
  @State showSeasonSheet: boolean = false  // 合集弹窗显示状态
  private seasonScroller_: Scroller = new Scroller()
  @State seasonSectionIndex: number = 0  // 当前合集分区索引

  // ⭐ 屏幕旋转模式状态
  @State rotationMode: string = 'auto'  // 'auto' | 'portrait' | 'landscape'
  @State rotationScale: number = 1  // 旋转按钮缩放动画
  @State rotationPressed: boolean = false  // 旋转按钮点击变色
  @State isLayoutSwapped: boolean = false  // 是否切换布局（横屏非全屏模式）
  @State layoutSwapScale: number = 1  // 布局切换按钮缩放动画
  @State layoutSwapPressed: boolean = false  // 布局切换按钮点击变色
  // ⭐ 全屏控制栏镜像状态（与 VideoControls 双向绑定）：比例/画质/更多弹窗跟随镜像换侧
  @State isMirrorControls: boolean = false
  @State detailCommentBtnScale: number = 1  // 详情·评论按钮缩放动画
  @State detailCommentBtnPressed: boolean = false  // 详情·评论按钮点击变色
  @State lsPanProgress: number = 0  // 横屏左滑切换布局手势进度：0→1

  // ⭐ 竖屏评论区上滑视频缩小状态
  @State vidShrink: number = 0  // 0=正常大小, 1=完全缩小到迷你尺寸（由 animateVidShrink 统一驱动）
  /**
   * ⭐ 缩小/还原动画进行中标志。**只用于把常驻播放层那两条隐式 `.animation()` 的时长
   * 改成与共享 animateTo 同参**（SHRINK_ANIM_DURATION + EaseOut）：
   * 节点自带的 `.animation()` 会覆盖外层 animateTo，不改就会各走各的（播放器 120ms 先到位）。
   * 必须是 @State —— 它是 `.animation()` 的参数，改了要能触发重渲染。
   */
  @State shrinkAnimating: boolean = false
  /**
   * 缩小/还原动画的代数号。animateTo 的 onFinish 可能在新一轮动画已经开始之后才触发，
   * 靠定时器句柄区分不了，会让旧一轮的收尾误清新一轮的冻结/弹幕开关状态。
   */
  private shrinkAnimGen: number = 0
  /** ⭐ 本次缩小是否由「缩小后暂停播放」触发的暂停（还原时据此决定是否继续） */
  private shrinkPausedByPref_: boolean = false
  private readonly SHRINK_ANIM_DURATION: number = 300
  /**
   * ⭐ 缩小/还原动画期间弹幕层的**冻结尺寸**（vp，0 = 不冻结、尺寸跟随容器）。
   *
   * 为什么必须冻结：`DanmakuView` 的 `Canvas` 是 `.width('100%')`（跟随本层容器），而缩小动画期间
   * 容器矩形是**每帧都在变**的（animateTo 驱动 + onAreaChange 回填），画布尺寸于是也跟着每帧变，
   * 而 `Canvas.onReady` 每次尺寸变化都会重新初始化：
   * `TrackManager 初始化轨道` + `RSCanvasDrawingNode::ResetSurface`（重建 GPU surface）。
   * 真机日志实测 300ms 内发生 **19 次**，必然掉帧。
   * 冻结后画布尺寸只在动画起、止各变一次；动画期间多出来的部分由外层容器的 `clip(true)` 裁掉
   * （观感是"弹幕被盒子边缘裁走"而不是随视频一起缩小）。
   */
  private dmFreezeW: number = 0
  private dmFreezeH: number = 0
  // ⚠️ 刻意**不持有**"缩小前的弹幕开关"快照：缩小态下 enable 已被置 false，
  //    记快照会把"被自己关掉的值"当成用户设置，导致还原后弹幕不恢复。一律以 isDanmakuEnabled 为准。
  @State vidShrinkRestoreScale: number = 1  // 缩小恢复按钮点击弹性缩放
  @State floatBtnOpacity: number = 0  // 悬浮按钮延迟淡入
  @State floatBtnScale: number = 0  // 悬浮按钮弹入缩放
  @State floatBtnOffsetY: number = 12  // 悬浮按钮弹入Y偏移
  private commentScrollY: number = 0  // 记录评论区滚动位置（不触发渲染）

  // ⭐ 横屏非全屏竖屏模式：评论区上滑详情卡片缩小状态
  @State detailShrinkVP: number = 0  // 0=正常, 1=缩小到只显示标题

  // ⭐ 心跳上报定时器（每15秒上报一次观看进度）
  private heartbeatTimer: number = -1;
  private readonly HEARTBEAT_INTERVAL: number = 15000;  // 15秒
  private lastHeartbeatTime: number = 0;  // 上次心跳时的播放进度

  // ⭐ 评论排序状态：2=最热，1=最新
  @State commentSort: number = 2
  // ⭐ 排序栏版本号：每次切换排序时递增，强制刷新 UI
  @State sortBarVersion: number = 0
  // ⭐ 评论排序分段按钮选项（@State 理由同 tabOpt）
  @State commentSortOpt: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [{ text: '最热' }, { text: '最新' }],
    fontColor: $r('app.color.color_player_text_secondary'),
    selectedFontColor: '#FFFFFF',
    fontWeight: FontWeight.Regular,
    selectedFontWeight: FontWeight.Medium,
    backgroundColor: Color.Transparent,
    selectedBackgroundColor: this.playerFollowTheme ? this.customThemeColor : $r('app.color.color_bilibili_pink'),
    fontSize: 12,
    selectedFontSize: 12,
    buttonPadding: { top: 9, right: 16, bottom: 9, left: 16 },
  })
  @State commentSortSelIdx: number[] = [0]

  /** ⭐ 主题色/跟随开关变化时重建分段按钮 options（字段初始化器只拿到默认主题色，
      必须重建才能生效；aboutToAppear 首帧前同步调用一次，保证首次 build 即用正确主题色） */
  private rebuildSegmentOptions(): void {
    this.tabOpt = SegmentButtonOptions.capsule({
      buttons: [{ text: '详情' }, { text: '评论' }],
      fontColor: $r('app.color.color_player_text_secondary'),
      selectedFontColor: $r('app.color.color_player_text'),
      fontWeight: FontWeight.Normal,
      selectedFontWeight: FontWeight.Medium,
      backgroundColor: Color.Transparent,
      selectedBackgroundColor: this.playerFollowTheme ? this.customThemeColor : $r('app.color.color_bilibili_pink'),
      fontSize: 14,
      selectedFontSize: 14,
      buttonPadding: { top: 8, right: 16, bottom: 8, left: 16 },
    });
    this.commentSortOpt = SegmentButtonOptions.capsule({
      buttons: [{ text: '最热' }, { text: '最新' }],
      fontColor: $r('app.color.color_player_text_secondary'),
      selectedFontColor: '#FFFFFF',
      fontWeight: FontWeight.Regular,
      selectedFontWeight: FontWeight.Medium,
      backgroundColor: Color.Transparent,
      selectedBackgroundColor: this.playerFollowTheme ? this.customThemeColor : $r('app.color.color_bilibili_pink'),
      fontSize: 12,
      selectedFontSize: 12,
      buttonPadding: { top: 9, right: 16, bottom: 9, left: 16 },
    });
  }

  // ⭐ 弹幕开关状态
  @State isDanmakuEnabled: boolean = true  // 弹幕开关（默认开启）
  @State danmakuConfig: DanmakuConfig = new DanmakuConfig()  // 弹幕配置

  // ⭐ 详情卡片整卡下拉关灯状态（仿右滑全屏：整张卡片跟随手指下滑）
  private detailPullTouchAnchor: number = -1; // 本次下拉的触摸起点纵坐标（-1=未启动整卡下拉）
  private detailPullLastTouchY: number = -1; // 原始触摸纵坐标（上滑取消检测，不受手势竞争影响）
  private detailPullTouchStartX: number = -1; // 触摸按下点的横坐标（横向占优判定）
  private detailPullTouchStartY: number = -1; // 触摸按下点的纵坐标（横向占优判定）
  private detailPullTouchAtTop: boolean = false; // 按下时内容是否已在顶部（每次触摸仅查询一次）
  private detailPullPeakTouchY: number = -1; // 本次拖动触摸纵坐标峰值（累计回滑取消参照）
  private detailPullCanceled: boolean = false; // 回滑已取消（松手弹回，不触发关灯）
  private detailPullDragEngaged: boolean = false; // 本次触摸发生过整卡下拉（松手前锁定内部滚动）
  @State detailPullDrop: number = 0; // 下拉进度 0→1（卡片整体下移）
  @State detailPullHintPhase: number = 0; // 0=隐藏, 1=下拉关灯, 2=释放关灯

  // ⭐ 关灯模式（除视频区域外全黑）
  @State isLightsOff: boolean = false;
  @State lightBtnScale: number = 1;  // 开灯按钮点击弹性缩放
  @State lightbulbRotation: number = 0;  // 开灯图标旋转
  @StorageLink('lightsOffHideOnly') lightsOffHideOnly: boolean = false;  // 关灯模式仅隐藏组件（保留背景）
  @StorageLink('lightsOffShowBtn') lightsOffShowBtn: boolean = false;  // 关灯后显示开灯按钮（默认关闭）
  @StorageLink('lightsOffDanmakuOutside') lightsOffDanmakuOutside: boolean = true;  // 关灯视频外弹幕（默认开启）
  // ⭐ 关灯背景：封面/壁纸放大 + 模糊 + 压暗（仿 FullImagePreview rgba(0,0,0,0.72)）
  @State loBgScale: number = 1;
  @State loBgBlur: number = 0;
  @State loBgDim: number = 0;  // 0~0.72
  // ⭐ 开灯按钮自动隐藏
  @State lightBtnVisible: boolean = true;
  private lightBtnTimer_: number = -1;

  /** 关灯背景素材：优先当前背景模式（wallpaper 自定义壁纸，否则封面） */
  private lightsOffBgSrc(): string {
    if (this.videoBgMode === 'wallpaper' && this.videoBgCustomWallpaper) return 'file://' + this.videoBgCustomWallpaper;
    return imageUrlResize(this.vi.cover, 1080);
  }

  // ⭐ 触觉反馈
  private lsHapticPrev_: number = 0; // 左滑布局切换手势上次进度值（双向穿越阈值检测）
  private triggerHaptic(): void {
    VibrateUtils.vibrateTime(15);
  }


  // ⭐ 互动方法
  private async toggleLike(): Promise<void> {
    if (!this.vd) return;

    // 点击动画
    this.likeScale = 0.8;
    setTimeout(() => { this.likeScale = 1.2; }, 80);
    setTimeout(() => { this.likeScale = 1; }, 160);

    const prevIsLiked = this.isLiked;
    const prevLikeCount = this.likeCount;
    const newIsLiked = !this.isLiked;
    this.isLiked = newIsLiked;
    this.likeCount = newIsLiked ? this.likeCount + 1 : Math.max(0, this.likeCount - 1);

    // 上报互动行为到B站API
    const success = await UserBehaviorService.reportInteraction({
      bvid: this.vi.bvid,
      aid: this.vd.aid,
      type: 'like',
      action: newIsLiked ? 'add' : 'cancel'
    });

    if (success) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: newIsLiked ? '点赞成功' : '取消点赞', duration: 1500 });
      } catch (err) {
        logWarn(`showToast 异常: ${errMsg(err)}`);
      }
      logInfo(`[互动] ${newIsLiked ? '点赞' : '取消点赞'}: ${this.vi.bvid}`);
    } else {
      this.isLiked = prevIsLiked;
      this.likeCount = prevLikeCount;
      logWarn(`[互动] ⚠️ 点赞API失败，已回滚: ${this.vi.bvid}`);
    }

    try {
      VibrateUtils.vibrateTime(50);
    } catch (e) {
      logWarn(`震动失败: ${e}`);
    }
  }

  private async tripleAction(): Promise<void> {
    if (!this.vd) return;

    this.likeScale = 0.8;
    this.coinScale = 0.8;
    this.favoriteScale = 0.8;
    setTimeout(() => {
      this.likeScale = 1.2;
      this.coinScale = 1.2;
      this.favoriteScale = 1.2;
    }, 80);
    setTimeout(() => {
      this.likeScale = 1;
      this.coinScale = 1;
      this.favoriteScale = 1;
    }, 160);

    const prevIsLiked = this.isLiked;
    const prevIsCoined = this.isCoined;
    const prevIsFavorited = this.isFavorited;
    const prevLikeCount = this.likeCount;
    const prevCoinCount = this.coinCount;
    const prevFavoriteCount = this.favoriteCount;

    this.isLiked = true;
    this.likeCount += 1;
    this.isCoined = true;
    this.coinCount += 2;
    this.isFavorited = true;
    this.favoriteCount += 1;

    const success = await UserBehaviorService.reportInteraction({
      bvid: this.vi.bvid,
      aid: this.vd.aid,
      type: 'triple',
      action: 'add'
    });

    if (success) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '一键三连成功', duration: 1500 });
      } catch (err) {
        logWarn(`showToast 异常: ${errMsg(err)}`);
      }
      logInfo(`[互动] ✅ 一键三连: ${this.vi.bvid}`);
    } else {
      this.isLiked = prevIsLiked;
      this.isCoined = prevIsCoined;
      this.isFavorited = prevIsFavorited;
      this.likeCount = prevLikeCount;
      this.coinCount = prevCoinCount;
      this.favoriteCount = prevFavoriteCount;
      logWarn(`[互动] ⚠️ 三连API失败，已回滚: ${this.vi.bvid}`);
    }

    try {
      VibrateUtils.vibrateTime(150);
    } catch (e) {
      logWarn(`震动失败: ${e}`);
    }
  }

  private async toggleCoin(multiply: number = 1): Promise<void> {
    if (!this.vd) return;

    // 点击动画
    this.coinScale = 0.8;
    setTimeout(() => { this.coinScale = 1.2; }, 80);
    setTimeout(() => { this.coinScale = 1; }, 160);

    if (this.isCoined) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '已投币，不能取消', duration: 1500 });
      } catch (err) {
        logWarn(`showToast 异常: ${errMsg(err)}`);
      }
      return;
    }

    const prevIsCoined = this.isCoined;
    const prevCoinCount = this.coinCount;
    this.isCoined = true;
    this.coinCount = this.coinCount + multiply;

    // 上报互动行为
    const coinAid = this.vd?.aid || 0;
    const success = await UserBehaviorService.reportInteraction({
      bvid: this.vi.bvid,
      aid: coinAid,
      multiply: multiply,
      type: 'coin',
      action: 'add'
    });

    if (success) {
      // API成功
      try {
        this.getUIContext().getPromptAction().showToast({ message: multiply === 2 ? '投币x2成功' : '投币成功', duration: 1500 });
      } catch (err) {
        logWarn(`showToast 异常: ${errMsg(err)}`);
      }
      logInfo(`[互动] ✅ 投币x${multiply}: ${this.vi.bvid}`);
    } else {
      // API失败 → 回滚UI状态
      this.isCoined = prevIsCoined;
      this.coinCount = prevCoinCount;
      logWarn(`[互动] ⚠️ 投币API失败，已回滚: ${this.vi.bvid}`);
    }

    // 震动反馈
    try {
      VibrateUtils.vibrateTime(80);
    } catch (e) {
      logWarn(`震动失败: ${e}`);
    }
  }

  private async toggleFavorite(): Promise<void> {
    if (!this.vd) return;

    // 点击动画
    this.favoriteScale = 0.8;
    setTimeout(() => { this.favoriteScale = 1.2; }, 80);
    setTimeout(() => { this.favoriteScale = 1; }, 160);

    const newIsFavorited = !this.isFavorited;
    this.isFavorited = newIsFavorited;
    this.favoriteCount = newIsFavorited ? this.favoriteCount + 1 : Math.max(0, this.favoriteCount - 1);

    // 上报互动行为
    await UserBehaviorService.reportInteraction({
      bvid: this.vi.bvid,
      aid: this.vd.aid,  // 传入aid用于收藏API
      type: 'favorite',
      action: newIsFavorited ? 'add' : 'cancel'
    });

    // 震动反馈
    try {
      VibrateUtils.vibrateTime(50);
    } catch (e) {
      logWarn(`震动失败: ${e}`);
    }

    try {
      this.getUIContext().getPromptAction().showToast({ message: newIsFavorited ? '收藏成功' : '取消收藏', duration: 1500 });
    } catch (err) {
      logWarn(`showToast 异常: ${errMsg(err)}`);
    }
    logInfo(`[互动] ${newIsFavorited ? '收藏' : '取消收藏'}: ${this.vi.bvid}`);
  }

  // —— 开灯按钮自动隐藏/显示 ——
  private startLightBtnTimer(): void {
    this.clearLightBtnTimer();
    this.lightBtnTimer_ = setTimeout(() => {
      this.lightBtnVisible = false;
    }, 5000);
  }
  private clearLightBtnTimer(): void {
    if (this.lightBtnTimer_ !== -1) {
      clearTimeout(this.lightBtnTimer_);
      this.lightBtnTimer_ = -1;
    }
  }
  private toggleLightBtn(): void {
    if (this.lightBtnVisible) {
      this.lightBtnVisible = false;
      this.clearLightBtnTimer();
    } else {
      this.lightBtnVisible = true;
      this.startLightBtnTimer();
    }
  }

  // —— 切换深色/浅色模式 ——
  private async toggleDarkMode(): Promise<void> {
    // 点击动画 + 变色反馈
    this.darkModeScale = 0.9;
    this.darkModePressed = true;
    setTimeout(() => {
      this.darkModeScale = 1;
      this.darkModePressed = false;
    }, 150);

    const newMode = !this.isDarkMode;
    this.isDarkMode = newMode;
    AppStorage.setOrCreate<boolean>('isDarkMode', newMode);

    // 同步系统色彩模式，让颜色资源自动适配
    try {
      const uiContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      uiContext.getApplicationContext().setColorMode(
        newMode ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
      );
      await StatusBarUtils.updateStatusBarColor(uiContext, newMode);
    } catch (e) {
      logError(`切换系统色彩模式失败: ${e}`);
    }

    // 持久化到 Preferences
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context;
      preferences.getPreferences(ctx, 'my_app_settings').then((pref) => {
        pref.put('isDarkMode', newMode).then(() => {
          pref.flush();
        });
        // 卡片样式「深浅色独立」：装载新模式档案（播放页背景已入档，此处装载后立即生效）
        if (AppStorage.get<boolean>('cardStylePerMode') === true) {
          applyCardStyleModeArchive(pref, newMode);
        }
      });
    } catch (e) {
      logError(`保存深色模式设置失败: ${e}`);
    }

    // 震动反馈
    try {
      VibrateUtils.vibrateTime(50);
    } catch (e) {
      logWarn(`震动失败: ${e}`);
    }

    try {
      this.getUIContext().getPromptAction().showToast({ message: newMode ? '已切换深色模式' : '已切换浅色模式', duration: 1500 });
    } catch (err) {
      logWarn(`showToast 异常: ${errMsg(err)}`);
    }
    logInfo(`[互动] 深色模式: ${newMode}`);
  }

  // —— 最小化到右下悬浮按钮 ——
  private minimizeToFloating(): void {
    // 点击动画
    this.minimizeScale = 0.9;
    this.minimizePressed = true;
    setTimeout(() => {
      this.minimizeScale = 1;
      this.minimizePressed = false;
    }, 150);
    this.triggerHaptic();

    // 保存当前播放状态到 AppStorage
    const minimizeState: MinimizedVideoState = {
      bvid: this.vi.bvid,
      cid: this.vi.cid,
      title: this.vi.title,
      cover: this.vi.cover,
      currentTime: this.ct,
      duration: this.dur,
      isPlaying: this.play,
      quality: this.qn,
      qualityLabel: this.ql,
      volume: this.vol,
      mute: this.mute,
      isLandscapeVertical: this.isLandscapeVertical,  // ⭐ 保存横屏竖屏视频模式
      videoAspectRatio: this.ar,                       // ⭐ 保存视频宽高比
      aid: this.vd?.aid ?? this.aidFromParams_,        // ⭐ 分集 aid（PGC 评论 oid）
      epId: this.epId_,                                // ⭐ PGC 分集 id
      seasonId: this.seasonId_,                        // ⭐ PGC 季 id
    };
    logInfo(`[Minimize] 保存播放状态: bvid=${this.vi.bvid}, title=${this.vi.title}, ct=${this.ct}s`);
    AppStorage.set('minimizedVideoState', JSON.stringify(minimizeState));
    // ⭐ 触发浮窗出现（aboutToAppear 会执行 animateIn 从右侧回弹滑入）
    AppStorage.set('videoMinimized', true);
    logInfo('[Minimize] AppStorage 状态已设置: videoMinimized=true');

    // ⭐ 将播放器转移到 PlayerService 跨页面存活（不 pause，音频继续播放）
    if (this.av || this.avAudio) {
      // 先移除旧监听器，避免转移后回调引用已销毁的页面实例
      if (this.av) {
        this.av.off('stateChange');
        this.av.off('timeUpdate');
        this.av.off('error');
        this.av.off('videoSizeChange');
      }
      if (this.avAudio) {
        this.avAudio.off('stateChange');
        this.avAudio.off('seekDone');
        this.avAudio.off('error');
      }
      const ps = PlayerService.getInstance();
      ps.takeoverPlayer(this.av, this.avAudio, minimizeState);
      // ⭐ DASH 转播站桥整体移交 PlayerService（桥实现 DashServerHandle=stop()），
      //    浮窗继续消费；页面置空避免 release 停服
      if (this.dashBridge_) {
        ps.setDashServer(this.dashBridge_);
        logInfo('[Minimize] 转播站桥已移交 PlayerService');
        this.dashBridge_ = null;
      }
      logInfo('[Minimize] 播放器已转移至 PlayerService，监听器已清除');
      // 置空页面内引用 → aboutToDisappear → release() 跳过
      this.av = null;
      this.avAudio = null;
    }

    // 结束实况窗（后台播放模式保留后台任务，保证切后台后继续播放）
    if (!this.bgp) {
      LiveViewHelper.end();
    } else {
      logInfo('[Minimize] 后台播放模式：保留实况窗和后台任务');
    }

    // ⭐ 保存观看历史再退出
    this.saveWatchHistory();

    // 返回上一页
    router.back();
  }

  /**
   * 从最小化恢复 — 重新绑定 XComponent surface 并续播
   * 由 aboutToAppear 接管 PlayerService 后延时调用
   */
  /**
   * ⭐ PGC（番剧/影视）详情卡片 + 评论填充：按 epId 补 vd（标题/简介/制作方/统计/选集列表）
   *    和评论区 oid（= 当前分集的 aid）。
   *
   * 为什么必须有一条【独立于 cid】的路径（2026-09-15 修回归）：
   *   1. `loadD()` 对 PGC 直接 return（PGC 没有 bvid），所以 UGC 那条 "bvid→vd→评论" 的路走不通；
   *   2. PGC 的 vd/评论填充原先只写在 aboutToAppear 里 `if (!this.vi.cid || this.vi.cid <= 0)`
   *      的反查块【内部】—— 一旦来源页把 cid 一起带进来（观看历史那版补了 `cid: item.cid`），
   *      守卫为假 → 整块被跳过 → vd 从未赋值、pendingCommentAid 也从未设置
   *      → 详情卡片空、评论区空（实测回归：点番剧进去只有播放器）；
   *   3. `ensurePgcContext()` 只补 seasonId/aid，不碰 vd/评论，没有任何兜底能救回来。
   *   现在改为在 aboutToAppear 里无条件调用，靠下面"vd 已有则早退"来避免重复请求，
   *   所以 cid=0 的入口（首页番剧卡等）走完反查块后到这里会立即返回，行为不变。
   *
   * 季信息优先复用 ensurePgcContext() 留下的缓存（零网络），仅浮窗恢复等路径才会真正发请求。
   */
  private async fillPgcDetailFromSeason(): Promise<void> {
    if (this.epId_ <= 0) return;
    if (this.vd && this.vd.pages && this.vd.pages.length > 0) return;  // 已有详情，无需重拉
    let pgcInfo: PgcSeasonInfo | null = this.pgcSeasonInfoCache_;
    if (!pgcInfo) {
      pgcInfo = await getPgcSeasonInfoByEpId(this.epId_);
      if (pgcInfo) {
        this.pgcSeasonInfoCache_ = pgcInfo;
      }
    }
    if (!pgcInfo || pgcInfo.episodes.length <= 0) return;
    let matchedEp: PgcEpisode | null = null;
    for (const ep of pgcInfo.episodes) {
      if (ep.id === this.epId_) {
        matchedEp = ep;
        break;
      }
    }
    const targetEp: PgcEpisode = matchedEp ?? pgcInfo.episodes[0];
    if (targetEp.cid && targetEp.cid > 0 && (!this.vi.cid || this.vi.cid <= 0)) {
      this.vi.cid = targetEp.cid;
    }
    this.seasonId_ = pgcInfo.seasonId;
    if (!this.vi.title && pgcInfo.title) this.vi.title = pgcInfo.title;
    if (!this.vi.cover && pgcInfo.cover) this.vi.cover = pgcInfo.cover;
    const owner: VideoDetailOwner = {
      mid: pgcInfo.upInfo.mid || 0,
      name: pgcInfo.upInfo.uname || (pgcInfo.staff || pgcInfo.actors || ''),
      face: pgcInfo.upInfo.avatar || ''
    };
    const stat: VideoDetailStat = {
      aid: 0,
      view: pgcInfo.stat.view,
      danmaku: pgcInfo.stat.danmaku,
      reply: pgcInfo.stat.reply,
      favorite: pgcInfo.stat.favorite,
      coin: pgcInfo.stat.coin,
      share: 0,
      like: pgcInfo.stat.like,
      dislike: 0
    };
    const pages: VideoPageItem[] = [];
    const pgcEpIds: number[] = [];
    const pgcAids: number[] = [];
    for (let i = 0; i < pgcInfo.episodes.length; i++) {
      const ep = pgcInfo.episodes[i];
      pages.push({
        cid: ep.cid || 0,
        page: i + 1,
        part: (ep.long_title || ep.title || `第${i + 1}话`),
        duration: ep.duration ? Math.floor(ep.duration / 1000) : 0,
        cover: ep.cover || ''
      });
      pgcEpIds.push(ep.id || 0);
      pgcAids.push(ep.aid || 0);
    }
    this.pgcEpIds_ = pgcEpIds;
    this.pgcAids_ = pgcAids;
    const targetEpAid = targetEp.aid || (pgcAids.length > 0 ? pgcAids[0] : 0);
    // ⭐ 历史记录/点赞等依赖 aidFromParams_（浮窗恢复路由 aid=0 时由分集 aid 补齐）
    this.aidFromParams_ = targetEpAid;
    const pgcDetail: VideoDetail = {
      bvid: '',
      aid: targetEpAid,
      title: pgcInfo.title,
      desc: pgcInfo.desc || `${pgcInfo.actors || ''} ${pgcInfo.staff || ''}`.trim(),
      pic: pgcInfo.cover,
      pubdate: pgcInfo.pubdate,
      ctime: pgcInfo.pubdate,
      duration: 0,
      owner: owner,
      stat: stat,
      cid: this.vi.cid,
      pages: pages
    };
    this.vd = pgcDetail;
    this.likeCount = stat.like;
    this.coinCount = stat.coin;
    this.favoriteCount = stat.favorite;
    // ⭐ 选集/历史记录定位到当前分集（第 N 话），而非第一集
    const matchedEpIdx = this.pgcEpIds_.indexOf(this.epId_);
    this.currentPageIndex = matchedEpIdx >= 0 ? matchedEpIdx : 0;
    // ⭐ PGC 评论 oid = 分集 aid
    this.commentCursor = 0;
    this.commentDataSource.clear();
    this.pendingCommentAid = targetEpAid;
    if (this.commentsInitialized && targetEpAid > 0) {
      this.loadC(targetEpAid);
      this.pendingCommentAid = 0;
    }
    logInfo(`[VideoPlayer] PGC 详情/评论填充: epId=${this.epId_}, seasonId=${this.seasonId_}, cid=${this.vi.cid}, 评论aid=${targetEpAid}, 集数=${pages.length}`);
  }

  private async resumeFromMinimized(): Promise<void> {
    if (!this.av) {
      logWarn('[VideoPlayer] resumeFromMinimized: 无播放器');
      return;
    }
    // ⭐ 兜底：播放器已被系统释放，回退到标准初始化流程
    if (this.av.state === 'released') {
      logWarn('[VideoPlayer] resumeFromMinimized: 播放器已释放，回退到标准初始化');
      this.err = '恢复播放失败，请重新打开';
      this.ld = false;
      return;
    }
    this.sId = this.xc.getXComponentSurfaceId();
    if (!this.sId) {
      logWarn('[VideoPlayer] resumeFromMinimized: surfaceId 未就绪');
      setTimeout(() => this.resumeFromMinimized(), 300);
      return;
    }
    try {
      logInfo(`[VideoPlayer] 恢复播放: surfaceId=${this.sId}, state=${this.av.state}`);
      // 不 seek — 原版行为：设 surface 后解码器从停滞位置自然加速追赶
      this.av.surfaceId = (this.nativeSurfaceId_ || this.sId);

      // 更新时长
      this.dur = (this.av.duration || 0) / 1000;

      // ⭐ 创建实况窗：不阻塞恢复播放（fire-and-forget，内部已全 try/catch）
      LiveViewHelper.setControlHandlers({
        // ⭐ 显式语义：play 仅在未播放时播放，pause 仅在播放中暂停
        // （旧版 play/pause 都调 togglePP，后台已暂停时点通知栏"暂停"反而触发播放）
        play: () => { if (!this.play) { this.togglePP(); } },
        pause: () => { if (this.play) { this.togglePP(); } },
        seek: (time: number) => { this.seek(time / 1000, false); },
      });
      LiveViewHelper.create(this.getUIContext().getHostContext() as common.Context, this.vi.title, this.vi.cover,
        this.vi.bvid, this.dur, this.vd?.owner?.name ?? '').catch(() => {});

      // 恢复播放
      if (this.av.state === 'paused') {
        await this.av.play();
        logInfo('[VideoPlayer] 播放器恢复播放');
        if (this.avAudio && this.avAudio.state === 'paused') {
          await this.avAudio.play();
        }
      } else if (this.av.state === 'playing') {
        logInfo('[VideoPlayer] 播放器已在播放状态');
      }

      this.play = true;
      this.ld = false;

      // ⭐ 设置 contentVisible=true，让 UI 从加载态切换到播放器界面
      // 正常流程中由 stateChange → 'prepared' 回调设置，但 PS 恢复时不会经过该回调
      if (!this.contentVisible) {
        if (this.pageEnterAnim !== 'none') {
          this.pageEnterProgress = 0;
        }
        animateTo({ duration: 0 }, () => {
          this.contentVisible = true;
        });
        if (this.pageEnterAnim !== 'none') {
          animateTo({
            // ⭐ 页面加载回弹动画（固定参数）
            duration: this.PE_ENTER_DURATION,
            curve: curves.springCurve(this.PE_ENTER_VELOCITY, 1, Math.round(this.FS_SPRING_STIFFNESS * 2.1), this.PE_ENTER_DAMPING),
            onFinish: () => {
              this.commentsInitialized = true;
              if (this.pendingCommentAid > 0) {
                this.loadC(this.pendingCommentAid);
                this.pendingCommentAid = 0;
              }
              this.scheduleFloatBtnFadeIn();
            }
          }, () => {
            this.pageEnterProgress = 1;
          });
        } else {
          this.commentsInitialized = true;
          if (this.pendingCommentAid > 0) {
            this.loadC(this.pendingCommentAid);
            this.pendingCommentAid = 0;
          }
          this.scheduleFloatBtnFadeIn();
        }
      }

      // 同步音量：播放器内部增益固定 1.0，音量完全由系统媒体音量控制（避免 v² 双重衰减）
      try { this.av.setVolume(1.0); if (this.mute) this.setSystemVolume(0); } catch (e) {}
      // ⭐ 启动声画同步检测：5 秒后开始监视视频是否落后音频
      this.startVideoSpeedSync();
    } catch (e) {
      logError(`[VideoPlayer] resumeFromMinimized 恢复失败: ${e}`);
      this.err = '恢复播放失败';
    }
  }

  /**
   * 启动声画同步检测
   * 恢复后等待解码器稳定，检测视频是否落后音频，若落后则 2x 加速追赶
   */
  private startVideoSpeedSync(delayMs: number = 8000): void {
    this.cancelVideoSpeedSync();
    this.videoSpeedFixTimer_ = setTimeout(() => {
      this.videoSpeedFixTimer_ = -1;
      this.checkAndSyncSpeed();
    }, delayMs);
  }

  /**
   * 首次快速同步：播放启动后立即做一次声画对齐（不等定时器）
   * 用于初始加载场景，尽早缩小差距
   */
  private async initialSyncCheck(): Promise<void> {
    if (!this.av || !this.avAudio || this.av.state === 'released') {
      return;
    }
    // 等 300ms 让播放器稳定
    await new Promise<void>(r => setTimeout(r, 300));
    let videoPos: number = 0;
    let audioPos: number = 0;
    try { videoPos = this.av.currentTime; } catch (_e) {}
    try { audioPos = this.avAudio.currentTime; } catch (_e) {}
    if (videoPos <= 0 || audioPos <= 0) {
      return;
    }
    const diffMs: number = audioPos - videoPos;
    if (diffMs > 3000) {
      const seekTarget: number = Math.max(1000, audioPos - 500);
      try {
        this.av.seek(seekTarget, media.SeekMode.SEEK_PREV_SYNC);
        this.lastSyncSeekTime_ = Date.now();
        logInfo(`[VideoPlayer] 初始同步: 差距 ${(diffMs / 1000).toFixed(1)}s，seek 到 ${seekTarget}ms`);
      } catch (_e) {}
    } else if (diffMs > 800) {
      try { this.av.setSpeed(this.rateToSpeedIdx(2.0)); } catch (_e) {}
      this.isSpeed2x_ = true;
      this.isSpeedFixIn2xPhase_ = true;
      logInfo(`[VideoPlayer] 初始同步: 差距 ${(diffMs / 1000).toFixed(1)}s，2x 加速`);
    }
  }

  /**
   * 取消声画同步检测
   */
  private cancelVideoSpeedSync(): void {
    if (this.videoSpeedFixTimer_ !== -1) {
      clearTimeout(this.videoSpeedFixTimer_);
      clearInterval(this.videoSpeedFixTimer_);
      this.videoSpeedFixTimer_ = -1;
    }
    if (this.isSpeed2x_) {
      try { this.av?.setSpeed(this.rateToSpeedIdx(1.0)); } catch (_e) {}
      this.isSpeed2x_ = false;
      this.isSpeedFixIn2xPhase_ = false;
    }
  }

  /**
   * 重新排程声画同步检查（每 5 秒一次）
   */
  private rescheduleSpeedCheck_(): void {
    if (this.videoSpeedFixTimer_ !== -1) {
      clearInterval(this.videoSpeedFixTimer_);
    }
    this.videoSpeedFixTimer_ = setInterval(() => this.checkAndSyncSpeed(), 5000);
  }

  /**
   * 检查声画同步状态：视频落后音频则加速追赶，追上后恢复
   */
  private checkAndSyncSpeed(): void {
    if (!this.av || !this.avAudio) {
      return;
    }
    if (this.av.state === 'released' || this.avAudio.state === 'released') {
      return;
    }
    if (!this.play) {
      this.cancelVideoSpeedSync();
      return;
    }

    // ⭐ 用户已手动设置非 1.0 倍速（如长按加速 2x），同步系统不应篡改
    if (Math.abs(this.rt - 1.0) > 0.01) {
      this.rescheduleSpeedCheck_();
      return;
    }

    let videoPos: number = 0;
    let audioPos: number = 0;
    try { videoPos = this.av.currentTime; } catch (_e) {}
    try { audioPos = this.avAudio.currentTime; } catch (_e) {}

    if (videoPos <= 0 || audioPos <= 0) {
      this.rescheduleSpeedCheck_();
      return;
    }

    const diffMs: number = audioPos - videoPos;

    // ✅ 已同步（差距 < 300ms，双向判断），恢复 1x
    // ⭐ 必须用绝对值：音频落后视频时 diffMs 为负，旧逻辑恒进此分支导致永不修复
    if (Math.abs(diffMs) < 300) {
      if (this.isSpeed2x_) {
        try { this.av.setSpeed(this.rateToSpeedIdx(1.0)); } catch (_e) {}
        this.isSpeed2x_ = false;
        this.isSpeedFixIn2xPhase_ = false;
        logInfo('[VideoPlayer] 声画同步: 已追平，恢复 1x');
      }
      this.rescheduleSpeedCheck_();
      return;
    }

    // 2x 追赶阶段：坚持 2x 直到追平，不中途切换为 seek
    if (this.isSpeedFixIn2xPhase_) {
      // 差距仍在 300ms 以上，继续 2x 追赶
      if (this.isSpeed2x_) {
        // 已经在 2x，什么都不做
      } else {
        // 意外恢复 1x（如用户操作），重新启用 2x
        try { this.av.setSpeed(this.rateToSpeedIdx(2.0)); } catch (_e) {}
        this.isSpeed2x_ = true;
      }
      this.rescheduleSpeedCheck_();
      return;
    }

    // ⭐ 音频落后视频（diffMs < 0）：seek 音频前进追视频（音频 seek 开销远小于视频）
    if (diffMs < -3000 && (Date.now() - this.lastSyncSeekTime_) > this.SYNC_SEEK_COOLDOWN_) {
      const audioSeekTarget: number = Math.max(1000, videoPos - 500);
      try {
        this.avAudio?.seek(audioSeekTarget, media.SeekMode.SEEK_PREV_SYNC);
        this.lastSyncSeekTime_ = Date.now();
        logInfo(`[VideoPlayer] 声画同步: 音频落后 ${(-diffMs / 1000).toFixed(1)}s，音频 seek 到 ${audioSeekTarget}ms`);
      } catch (_e) {}
      this.rescheduleSpeedCheck_();
      return;
    }

    // 非 2x 阶段，差距 > 3s 且 seek 冷却期已过 → seek（视频落后音频）
    if (diffMs > 3000 && (Date.now() - this.lastSyncSeekTime_) > this.SYNC_SEEK_COOLDOWN_) {
      const seekTarget: number = Math.max(1000, audioPos - 500);
      try {
        this.av.seek(seekTarget, media.SeekMode.SEEK_PREV_SYNC);
        this.lastSyncSeekTime_ = Date.now();
        logInfo(`[VideoPlayer] 声画同步: 差距 ${(diffMs / 1000).toFixed(1)}s，seek 到 ${seekTarget}ms`);
      } catch (_e) {}
      this.rescheduleSpeedCheck_();
      return;
    }

    // 差距 > 1s 且不在 2x 阶段 → 启动 2x 追赶（仅视频落后音频时，音频 2x 会变调）
    if (diffMs > 1000 && !this.isSpeed2x_) {
      try { this.av.setSpeed(this.rateToSpeedIdx(2.0)); } catch (_e) {}
      this.isSpeed2x_ = true;
      this.isSpeedFixIn2xPhase_ = true;
      logInfo(`[VideoPlayer] 声画同步: 视频落后 ${(diffMs / 1000).toFixed(1)}s，2x 加速追赶`);
    }

    this.rescheduleSpeedCheck_();
  }

  // ⭐ 切换关注状态
  private async toggleFollow(): Promise<void> {
    if (!this.vd) return;

    // 点击动画
    this.followScale = 0.8;
    setTimeout(() => { this.followScale = 1.2; }, 80);
    setTimeout(() => { this.followScale = 1; }, 160);

    const newIsFollowed = !this.isFollowed;

    // 调用API修改关注状态
    const success = await modifyFollow(this.vd.owner.mid, newIsFollowed ? 1 : 2);

    if (success) {
      this.isFollowed = newIsFollowed;
      clearFollowedMidsCache();  // 同步清空 SearchPage 的缓存
      try {
        if (!this.fs) { this.getUIContext().getPromptAction().showToast({ message: newIsFollowed ? '关注成功' : '取消关注', duration: 1500 }); }
      } catch (err) {
        logWarn(`showToast 异常: ${errMsg(err)}`);
      }
    } else {
      try {
        if (!this.fs) { this.getUIContext().getPromptAction().showToast({ message: '操作失败，请重试', duration: 1500 }); }
      } catch (err) {
        logWarn(`showToast 异常: ${errMsg(err)}`);
      }
    }

    // 震动反馈
    try {
      VibrateUtils.vibrateTime(50);
    } catch (e) {
      logWarn(`震动失败: ${e}`);
    }

    logInfo(`[互动] ${newIsFollowed ? '关注' : '取消关注'}: UP主 ${this.vd.owner.name} (mid=${this.vd.owner.mid})`);
  }

  // ⭐ 切换屏幕旋转模式（二态循环：自由 ↔ 锁定当前方向）
  private toggleRotationMode(): void {
    // 点击动画
    this.rotationScale = 0.9;
    this.rotationPressed = true;
    setTimeout(() => {
      this.rotationScale = 1;
      this.rotationPressed = false;
    }, 150);

    // 触觉反馈
    this.triggerHaptic();

    // 二态切换：自由 ↔ 锁定当前方向
    if (this.rotationMode === 'auto') {
      // 自由 → 锁定到当前物理方向
      this.rotationMode = this.isLs ? 'landscape' : 'portrait';
    } else {
      // 锁定 → 自由
      this.rotationMode = 'auto';
    }

    // 更新AppStorage和实际旋转模式
    let lockMode: string;
    let toastMsg: string;

    switch (this.rotationMode) {
      case 'portrait':
        lockMode = '锁定竖屏';
        toastMsg = '锁定竖屏';
        break;
      case 'landscape':
        lockMode = '锁定横屏';
        toastMsg = '锁定横屏';
        break;
      case 'auto':
      default:
        lockMode = '自动旋转';
        toastMsg = '自由旋转';
        break;
    }

    // 保存到AppStorage
    AppStorage.setOrCreate<string>('screenOrientationLock', lockMode);
    this.so_ = lockMode;

    // 应用旋转模式
    this.applyRotationMode();

    // 提示
    try {
      this.getUIContext().getPromptAction().showToast({ message: toastMsg, duration: 1500 });
    } catch (err) {
      logWarn(`showToast 异常: ${errMsg(err)}`);
    }
    logInfo(`[旋转模式] 切换为: ${lockMode}`);
  }

  // ⭐ 应用旋转模式
  private async applyRotationMode(): Promise<void> {
    if (!this.mw) return;

    try {
      let orientation: window.Orientation;

      switch (this.rotationMode) {
        case 'portrait':
          orientation = window.Orientation.PORTRAIT;
          break;
        case 'landscape':
          // 允许横屏之间旋转
          orientation = window.Orientation.AUTO_ROTATION_LANDSCAPE;
          break;
        case 'auto':
        default:
          orientation = window.Orientation.AUTO_ROTATION;
          break;
      }

      await this.mw.setPreferredOrientation(orientation);
    } catch (e) {
      logError(`[旋转模式] 应用失败: ${e}`);
    }
  }

  // ⭐ 获取旋转模式图标
  private getRotationIcon(): Resource {
    switch (this.rotationMode) {
      case 'portrait':
        return $r('app.media.rectangle_portrait_rotate');
      case 'landscape':
        return $r('app.media.rectangle_rotate');
      case 'auto':
      default:
        return $r('app.media.arrow_counterclockwise');
    }
  }

  // ⭐ 切换布局（横屏非全屏模式）
  private toggleLayoutSwap(): void {
    // ⭐ 兜底自愈：fsEntering 的语义是"进入全屏旋转期间把常驻层钉在快照矩形上"，
    //   非全屏且不在旋转中却为 true 一定是被某条手势回弹路径漏掉的脏值（见 startFSAnimation 回弹分支注释）。
    //   脏值的唯一表现就是本节要修的 bug：布局换了、视频画面不换位置。这里再拦一道，
    //   让任何历史/将来漏掉的路径在用户下一次点「切换布局」时也能自愈。
    if (!this.fs && !this.rotationInProgress && this.fsEntering) {
      logWarn('[布局切换] 检测到 fsEntering 脏值（手势回弹未复位），先复位再切换布局');
      this.fsEntering = false;
    }
    this.layoutSwapScale = 0.9;
    this.layoutSwapPressed = true;
    setTimeout(() => {
      this.layoutSwapScale = 1;
      this.layoutSwapPressed = false;
    }, 150);
    this.triggerHaptic();
    // ⭐ 使用 animateTo 平滑切换布局（弹簧动画）
    animateTo({ duration: 400, curve: curves.springMotion(0.35, 0.75) }, () => {
      this.isLayoutSwapped = !this.isLayoutSwapped;
    });
    try {
      this.getUIContext().getPromptAction().showToast({
        message: this.isLayoutSwapped ? '镜像布局' : '标准布局',
        duration: 1500
      });
    } catch (err) {
      logWarn(`showToast 异常: ${errMsg(err)}`);
    }
    logInfo(`[布局切换] isLayoutSwapped: ${this.isLayoutSwapped}`);
  }

  // ⭐ 获取旋转模式文字
  private getRotationText(): string {
    switch (this.rotationMode) {
      case 'portrait':
        return '竖屏';
      case 'landscape':
        return '横屏';
      case 'auto':
      default:
        return '自由';
    }
  }

  /**
   * ⭐ 异步读取弹幕数据源设置（grpc / xml）
   * 从 aboutToAppear 里挪出来的：以前用 `await preferences.getPreferences(...)` 写在
   * aboutToAppear 最前面，把整个同步段（参数解析/尺寸/initW/loadD）都堵在后面，
   * 现在改为 fire-and-forget，这里只负责"晚一点把值补上"。
   */
  private async refreshDanmakuApiSource(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(ctx, 'my_app_settings');
      const savedApiSource = await pref.get('danmakuApiSource', 'grpc') as string;
      if (savedApiSource === 'grpc' || savedApiSource === 'xml') {
        if (this.danmakuConfig.apiSource !== savedApiSource) {
          // ⚠️ 只改字段，**绝不整体替换对象**：DanmakuController 在构造时拿走了 config 的引用，
          //    换成新对象后，控制器 / 渲染器 / 轨道管理 / 过滤器仍指向旧对象 —— 之后对配置字段的
          //    任何修改都会静默失效（连弹幕开关用的 config.enable 都传不进去）。
          this.danmakuConfig.apiSource = savedApiSource;
        }
        AppStorage.set('danmakuApiSource', savedApiSource);
        logInfo(`[VideoPlayer] 弹幕数据源异步校正: ${savedApiSource}`);
      }
    } catch (e) {
      logError(`[VideoPlayer] 读取danmakuApiSource异常: ${e}`);
    }
  }

  // ⭐ 加载弹幕开关状态（从Preferences读取）
  private async loadDanmakuEnabledState(): Promise<void> {
    try {
      const pf = await preferences.getPreferences(this.getUIContext().getHostContext() as common.Context, 'VPS');
      const savedValue = await pf.get('danmakuEnabled', true); // 默认开启
      this.syncDanmakuEnabled(savedValue as boolean);
      // 同步到AppStorage（用于其他组件访问）
      AppStorage.setOrCreate<boolean>('danmakuEnabled', this.isDanmakuEnabled);
      logInfo(`[弹幕] 从本地存储加载状态: ${this.isDanmakuEnabled ? '开启' : '关闭'}`);
    } catch (e) {
      logError('加载弹幕开关状态失败', e);
      // 失败时使用默认值
      this.syncDanmakuEnabled(true);
    }
  }

  /**
   * 同步弹幕开关：@State 管 UI 显隐，**config.enable 管渲染链停帧**，两者必须一起改。
   *
   * ⚠️ 背景：DanmakuView 现在改为【常驻挂载】，开关不再卸载/重建组件
   *    （原先每次开启都新建 controller → 重新下载弹幕分段，万条弹幕约 4 秒空窗 + 重复流量）。
   *    只靠 visibility 隐藏的话，canvas 仍会以 60fps 绘制一块看不见的画面 ——
   *    所以必须同步 config.enable，渲染器与自调度链都靠它提前返回 / 停帧。
   */
  private syncDanmakuEnabled(v: boolean): void {
    this.isDanmakuEnabled = v
    this.danmakuConfig.enable = v
  }

  // ⭐ 切换弹幕开关
  private async toggleDanmaku(): Promise<void> {
    this.cancelDelayHide();
    this.syncDanmakuEnabled(!this.isDanmakuEnabled);

    // ⭐ 持久化弹幕开关状态到本地存储
    AppStorage.setOrCreate<boolean>('danmakuEnabled', this.isDanmakuEnabled);
    try {
      const pf = await preferences.getPreferences(this.getUIContext().getHostContext() as common.Context, 'VPS');
      await pf.put('danmakuEnabled', this.isDanmakuEnabled);
      await pf.flush();
    } catch (e) { logError('保存弹幕开关失败', e); }

    // 触觉反馈
    this.triggerHaptic();

    // 提示
    try {
      this.getUIContext().getPromptAction().showToast({
        message: this.isDanmakuEnabled ? '弹幕已开启' : '弹幕已关闭',
        duration: 1500
      });
    } catch (err) {
      logWarn(`showToast 异常: ${errMsg(err)}`);
    }

    logInfo(`[弹幕] ${this.isDanmakuEnabled ? '开启' : '关闭'}`);
  }

  // ⭐ 弹幕模式标签
  private dmModeLabel(mode: number): string {
    return mode === 4 ? '底部' : mode === 5 ? '顶部' : '滚动';
  }

  // ⭐ B站弹幕 mode → 内部类型
  private dmModeToType(mode: number): DanmakuType {
    return mode === 4 ? DanmakuType.BOTTOM : mode === 5 ? DanmakuType.TOP : DanmakuType.ROLL;
  }

  /**
   * 发送弹幕（POST /x/v2/dm/post），成功后注入本地弹幕流立即上屏
   * @param msg 弹幕文本（CommentInputBar 已还原表情标记）
   * @returns true=发送成功（由 onSend 返回，父层关弹层）
   */
  private async doSendDanmaku(msg: string): Promise<boolean> {
    const text = msg.trim();
    if (!text) {
      return false;
    }
    try {
      const result = await sendDanmakuVideo(this.vi.cid, this.vd?.bvid ?? '', text, Math.floor(this.ct * 1000), this.dmMode);
      logInfo(`[sendDanmaku] ${result.ok ? '成功' : '失败'} code=${result.code}, dmid=${result.dmid}`);
      if (result.ok) {
        // 本地注入，立即上屏
        const progress = Math.floor(this.ct * 1000);
        const init: DanmakuItemInit = {
          id: result.dmid || Date.now(),
          content: text,
          time: progress,
          type: this.dmModeToType(this.dmMode),
          color: 16777215,
          fontSize: 25,
          sendTime: Date.now(),
          pool: 0,
          weight: 10
        };
        this.selfDanmakuList = [...this.selfDanmakuList, new DanmakuItem(init)];
        this.showDanmakuSheet = false;
        try {
          this.getUIContext().getPromptAction().showToast({ message: '弹幕发送成功', duration: 1500 });
        } catch (_) {}
        return true;
      }
      try {
        this.getUIContext().getPromptAction().showToast({ message: result.message || '弹幕发送失败', duration: 1800 });
      } catch (_) {}
      return false;
    } catch (err) {
      logError(`[sendDanmaku] 异常: ${err}`);
      try {
        this.getUIContext().getPromptAction().showToast({ message: '网络异常，请稍后再试', duration: 1800 });
      } catch (_) {}
      return false;
    }
  }

  // ⭐ 发弹幕弹层内容：模式选择 + 评论输入栏（表情面板 + 发送按钮复用）
  @Builder
  dmSheetContent() {
    Column() {
      Text('发弹幕')
        .fontSize(16)
        .fontColor($r('app.color.color_player_text'))
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 6, bottom: 10 })

      // 弹幕模式：滚动 / 底部 / 顶部
      Row() {
        ForEach([1, 4, 5], (m: number) => {
          Text(this.dmModeLabel(m))
            .fontSize(13)
            .fontColor(this.dmMode === m ? Color.White : $r('app.color.color_player_text_secondary'))
            .padding({ left: 16, right: 16, top: 7, bottom: 7 })
            .backgroundColor(this.dmMode === m
              ? (this.playerFollowTheme ? this.customThemeColor : '#FB7299')
              : (this.isDarkMode ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.06)'))
            .borderRadius(15)
            .margin({ right: 10 })
            .onClick(() => { this.dmMode = m; })
        }, (m: number) => m.toString())
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ bottom: 12 })

      // ⭐ 复用评论输入栏：表情面板 + 发送按钮（禁图片按钮）
      CommentInputBar({
        ctrl: this.dmSheetEmoteCtrl,
        placeholder: '发个友善的弹幕吧（最多100字）',
        showImageButton: false,
        onSend: async (content: string, pictures: CommentImageDraft[]) => {
          if (pictures.length > 0) {
            try {
              this.getUIContext().getPromptAction().showToast({ message: '弹幕不支持图片', duration: 1500 });
            } catch (_) {}
            return false;
          }
          return await this.doSendDanmaku(content);
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 8 })
    .backgroundColor(this.sheetRootBg(this.isDarkMode ? '#1C1C1E' : Color.White))
    .borderRadius({ topLeft: 20, topRight: 20 })
  }

  /**
   * ⭐ 半模态面板内容根底色：设备支持沉浸光感材质时必须全透明
   * （材质层在 backgroundColor 之下，不透明底会把玻璃整层盖住——MaterialUtil 硬要求①）。
   * 不支持材质时原样返回，走原来的不透明降级底色。
   */
  private sheetRootBg(base: ResourceColor): ResourceColor {
    return MaterialUtil.sheetMaterial() !== undefined ? Color.Transparent : base;
  }

  updateIsLandscapeVertical(): void { this.isLandscapeVertical = this.isLs && !this.fs && this.ar < 1; }

  /** 预先解码头像（48w，轻量），避免分支切换时触发 JPEG 解码 */
  private predecodeKeyImages(): void {
    if (this.vd?.owner?.face) {
      predecodeImage(imageUrlResize(this.vd.owner.face, 48));
    }
  }

  /** ⭐ 预解码 1080w 封面（重）：延后到首帧后（startRenderFrame 触发），避免与起播抢下载/解码线程 */
  private predecodeCover(): void {
    // 1080w：背景封面 + 加载占位封面共用（全屏清晰显示，避免 320w 拉伸模糊）
    const coverUrlHd = imageUrlResize(this.vi.cover, 1080);
    if (coverUrlHd) {
      predecodeImage(coverUrlHd).then(() => { this.hdCoverReady = true; });
    }
  }

  /** 封面源：1080w 高清预解码完成后用缓存 PixelMap；未就绪时回退到列表页原始 URL（框架缓存内秒显，防黑屏） */
  private coverSrc(): string | image.PixelMap | undefined {
    if (this.hdCoverReady) {
      const pm = getCachedPixelMap(imageUrlResize(this.vi.cover, 1080));
      if (pm) return pm;
    }
    return this.vi.cover || undefined;
  }

  // ⭐ 播放页导航按钮与横屏布局度量：按钮行尺寸与 buildLandscape 同源，
  //    改按钮大小时 updateLSVSize 的高度预留自动跟随
  private readonly NAV_BTN_SIZE: number = 51;          // 圆形导航按钮直径（宽=高，圆角=直径/2）
  private readonly NAV_BTN_CAPSULE_W: number = 90;     // "详情·评论"胶囊按钮宽度（高同 NAV_BTN_SIZE）
  private readonly NAV_BTN_ROW_MARGIN: number = 6;     // 按钮行上下外边距
  private readonly LAND_VIDEO_W_RATIO: number = 0.67;  // 横屏视频宽度占屏宽比例

  updateLSVSize(): void {
    if (!this.isLs) return;
    const arV = Number.isFinite(this.ar) && this.ar > 0 ? this.ar : 9 / 16;
    if (this.ar < 1) {
      // 竖屏视频：高度占满，宽度按实际宽高比
      const videoH = this.ch - 2 * this.cardMargin;
      this.lsvh = videoH;
      this.lsvw = videoH * arV;
    } else {
      // 横屏视频：宽度按比例占屏宽，高度按实际宽高比；超出可用高度时以高度限制大小
      // 可用高度预留视频下方按钮行空间（NAV_BTN_SIZE + 上下 NAV_BTN_ROW_MARGIN），
      // 否则近1:1/4:3视频会把按钮行（深浅色切换等）挤出屏幕
      const btnRowH = this.NAV_BTN_SIZE + 2 * this.NAV_BTN_ROW_MARGIN;
      const maxH = Math.max(1, this.ch - 2 * this.cardMargin - btnRowH);
      this.lsvw = this.cw * this.LAND_VIDEO_W_RATIO;
      this.lsvh = this.lsvw / arV;
      if (this.lsvh > maxH) {
        this.lsvh = maxH;
        this.lsvw = maxH * arV;
      }
    }
  }

  @State videoDisplayWidth: number = 0
  @State videoDisplayHeight: number = 0

  private readonly ql_: QI[] = [{ qn: 16, label: '360P' }, { qn: 32, label: '480P' },
    { qn: 64, label: '720P' }, { qn: 80, label: '1080P' },
    { qn: 112, label: '1080P+' }, { qn: 116, label: '1080P60' }, { qn: 120, label: '4K' }]
  // ⭐ 动态画质列表（来自服务器 accept_quality/accept_description，与官方版对齐）
  // 非空时优先于 ql_ 用于清晰度弹窗；切视频时重建引用触发重渲染
  @State aq: QI[] = []

  /**
   * 将服务器返回的画质列表写入动态列表（新建引用触发重渲染）
   * B站 accept_description 与 accept_quality 同序一一对应
   */
  private applyAcceptQuality(result: PlayUrlResult): void {
    const aq = result.acceptQuality;
    const ad = result.acceptDescription;
    if (aq && ad && aq.length > 0 && aq.length === ad.length) {
      const list: QI[] = [];
      for (let i = 0; i < aq.length; i++) {
        const item: QI = { qn: aq[i], label: ad[i] };
        list.push(item);
      }
      this.aq = list;
    }
  }

  /** 当前清晰度弹窗列表：优先服务器动态列表，空则用硬编码兜底 */
  private getQlList(): QI[] {
    return this.aq.length > 0 ? this.aq : this.ql_;
  }

  /** 根据 qn 获取清晰度文案（动态列表优先，硬编码兜底） */
  private getQlLabel(qn: number): string {
    const it = this.getQlList().find(q => q.qn === qn);
    return it ? it.label : `${qn}`;
  }
  private readonly sl_: SO[] = [{ label: '自动', mode: 'auto' }, { label: '拉伸', mode: 'stretch' },
    { label: '填充', mode: 'fill' }, { label: '等高', mode: 'fitHeight' }, { label: '等宽', mode: 'fitWidth' }]
  // ⭐ 画风选项
  private readonly cl_: CO[] = [{ label: '原图', mode: 'original' }, { label: '鲜艳', mode: 'vivid' },
    { label: '徕卡', mode: 'leica' }, { label: '胶片', mode: 'film' }]
  // ⭐ 更多菜单项（后续功能扩展：缓存、定时等）
  private readonly mo_: MO[] = [
    { label: '缓存', icon: $r('app.media.ic_public_folder'), action: () => { this.startCacheCurrentVideo(); } },
    // ⭐ 弹幕设置：打开 PiliPlus showSetDanmaku 同款详细面板（见 components/DanmakuSettingSheet.ets）
    { label: '弹幕设置', icon: $r('app.media.danmfas'), action: () => { this.openDanmakuSettingSheet(); } },
    { label: '投屏', icon: $r('app.media.ic_public_wireless_projection'), action: () => {} },
  ]
  // ⭐ 画风对应的颜色滤镜参数
  private get saturateVal_(): number {
    if (this.cs === 'vivid') return 1.5;
    if (this.cs === 'leica') return 0.85;
    if (this.cs === 'film') return 0.8;
    return 1.0;
  }
  private get contrastVal_(): number {
    if (this.cs === 'vivid') return 1.15;
    if (this.cs === 'leica') return 1.3;
    if (this.cs === 'film') return 0.9;
    return 1.0;
  }
  private get brightnessVal_(): number {
    if (this.cs === 'leica') return 0.88;
    if (this.cs === 'film') return 0.95;
    return 1.0;
  }
  private get sepiaVal_(): number {
    if (this.cs === 'film') return 0.55;
    return 0;
  }
  private get colorBlendVal_(): string {
    if (this.cs === 'leica') return 'rgba(60,30,10,0.12)';
    return 'rgba(0,0,0,0)';
  }
  private readonly rr_: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
  private ct_: number = -1; private gt_: number = -1; private lt_: number = -1
  private dt_: number = -1; private pb_: number = 0
  private dtwcv_: boolean = false // 双击用wcv_快照，防止第二击onTD覆盖
  private hc_: number = -1 // 延迟隐藏控制栏的timer（200ms），按钮回调中取消
  private sx_: number = 0; private sy_: number = 0; private st_: number = 0
  private screenH_: number = 0  // 屏幕高度(vp)，用于手势灵敏度计算
  private density_: number = 3.0  // 屏幕密度(vp→px转换)
  /** ⭐ 设备媒体音量最大档位（readSystemVolume 时刷新） */
  private maxVol_: number = 15
  /** ⭐ AudioVolumeManager 实例（供 streamVolumeChange 监听/注销） */
  private volMgr_: audio.AudioVolumeManager | null = null
  /** ⭐ 是否已注册系统音量变化监听 */
  private volListening_: boolean = false
  private sk_: boolean = false; private sg_: boolean = false; private gm_: string = ''
  // ⭐ seek 补提交目标（last-wins）：seek 在途时到来的新目标记在这里，由 finally 补一次
  //   原先是直接 return 丢弃，表现为"点进度条点两次才生效 / 松手后跳回去"
  private pendingSeekTarget_: number = -1
  // ⭐ 进度条拖动中标记：拖动期间冻结 ct、抑制控制栏自动隐藏，并让播放器手势与
  //   PanGesture（右滑进全屏）让位。stopPropagation 只能拦 onTouch，拦不住父节点的手势对象
  private sliderDragging_: boolean = false
  // ⭐ 进度条**触摸窗口**标记：从交互上报开始，一直保持到手指真正抬起（onVT 收到 Up/Cancel）。
  //   不能只用 sliderDragging_：提交发生在 onChange 的 End/Click，而实测它**早于** onTouch Up
  //     （序列：Begin → Down → Click → End → Up）
  //   若在提交时就撤守卫，Up 会掉进播放器的 onTU：
  //     1) onTU 第一行 `if (sk_ && av) { sk_ = false; seek(ct,...) }` 会把**在途 seek 的 sk_ 提前解冻**
  //        → timeUpdate 立刻把 ct 写回旧播放位置 → 表现为「时间显示没跳到目标」；
  //     2) onTD 因守卫没跑过，ml_ 是上一次手势的陈旧值 → Up 走"单击视频区"分支
  //        → 200ms 后隐藏控制栏、250ms 后再尝试显示 → 表现为「控制栏收缩一下」。
  private seekBarTouch_: boolean = false
  // 上述标记的看门狗：万一 Up/Cancel 没送达（系统抢事件），避免守卫永久生效把播放器手势锁死
  private seekBarTouchTimer_: number = -1
  // ⭐ 进度调节缩略图（拖动/滑动目标位置的画面）：
  //   与提示胶囊（gh/ght/ghp）同生共死 —— sGH() 时更新，提示 800ms 超时隐藏时一并隐藏。
  //   每次变化整体替换实例（@Link 对类对象改字段不触发刷新）
  @State thumb_: SeekThumb = new SeekThumb()
  // 缩略图请求令牌：拖动期间会连发多次异步查询，只有最后一次的结果才允许写回（否则会闪回旧帧）
  private shotToken_: number = 0
  // ⭐ 进度条按下瞬间的时间，用于判断"点了一下但没改位置"（不提交无意义的 seek）
  private seekDragAnchor_: number = -1
  // ⭐ 本次进度条手势已提交的目标：点滑轨会依次触发 Begin/Click/End，
  //   用它做"同一目标只提交一次"去重（-1 表示本次手势尚未提交）
  private lastSeekBarCommitV_: number = -1
  // ⭐ 手势 seek 的档位震动记录（与音量/亮度每 10% 震一次的手感对齐）
  private lastSeekHapticPct_: number = -1
  private os_: number = 1.0; private lp_: boolean = false
  private sz_: number = 0; private sv_: number = 0; private sb_: number = 0
  private ml_: boolean = false; private la_: boolean = false; private wcv_: boolean = false
  // ⭐ 全屏时顶部区域触摸标记：触摸起点在状态栏区域时跳过播放器手势，避免与下拉状态栏冲突
  private topAreaTouch_: boolean = false
  private swipeTimer_: number = -1 // 竖屏左右滑切换的延迟清理 timer
  private dtp_: boolean = false
  private initPInProgress_: boolean = false; // 防止重复初始化播放器
  private rc_: number = 0; private readonly mr_: number = 3; private ry_: boolean = false
  private rt_: number = -1; private so_: string = '自动旋转'
  private sh_: boolean = false; private sr_: boolean = false; private sti_: number = -1
  private fsAnimTimer_: number = -1
  private fsExitRetry_: number = 0  // 退出全屏时等待 isLs 稳定的重试计数
  private lastHapticPct_: number = -1 // 上次震动时的百分比 (0-100)，拖动时按档位震动
  // ⭐ 初始播放进度（从历史记录恢复）
  private initialProgress_: number = 0
  // ⭐ 4K 快速起播：本次为「先出帧」而降到的低档（0=未降级）
  private fastStartQn_: number = 0
  // ⭐ 4K 快速起播：首帧已出后要升回的目标档（0=无需升级）
  private upgradeQn_: number = 0
  // ⭐ 4K 快速起播：升级定时器
  private upgradeTimer_: number = -1
  // ⭐ 快速起播的自动升档正在执行（用于阻止它把 actualQn 写回用户的默认画质设置）
  private autoUpgradeInProgress_: boolean = false
  // ⭐ 长按文本选取弹窗（简介等）：openCustomDialog 返回的对话框 id，用于关闭
  private textSelectDialogId_: number = -1
  // ⭐ seek完成Promise的resolve函数
  private videoSeekResolve_: (() => void) | null = null
  private audioSeekResolve_: (() => void) | null = null
  // ⭐ 视频第一帧渲染完成的resolve函数
  private startRenderFrameResolve_: (() => void) | null = null
  // ⭐ 音视频同步定时器
  private syncTimer_: number = 0
  // ⭐ 上次视频位置（用于检测卡顿）
  private lastVideoPos_: number = 0
  // ⭐ 上次同步时间（避免频繁同步）
  private lastSyncTime_: number = 0
  // ⭐ 音频是否被静音（用于同步）
  private audioMutedForSync_: boolean = false

  // ⭐ 启动音视频同步定时器
  private startSyncTimer() {
    if (this.syncTimer_) return;
    this.syncTimer_ = setInterval(() => {
      this.syncAudioVideo();
    }, 300); // 每300ms同步一次（更频繁）
  }

  // ⭐ 停止同步定时器
  private stopSyncTimer() {
    if (this.syncTimer_) {
      clearInterval(this.syncTimer_);
      this.syncTimer_ = 0;
    }
    // 恢复音频（如果被静音）
    if (this.audioMutedForSync_ && this.avAudio) {
      this.avAudio.setVolume(1.0);
      this.audioMutedForSync_ = false;
    }
  }

  // ⭐ 音视频同步逻辑（更激进的策略）
  private async syncAudioVideo() {
    if (!this.av || !this.avAudio || !this.play) return;

    // 限制同步频率：至少间隔500ms（更频繁）
    const now = Date.now();
    if (now - this.lastSyncTime_ < 500) return;

    try {
      // 获取视频和音频的当前播放位置
      const videoPos = await this.av.currentTime;
      const audioPos = await this.avAudio.currentTime;

      // 计算差异（毫秒）
      const diff = audioPos - videoPos;
      const absDiff = Math.abs(diff);

      // 死区：差异小于200ms，不做调整
      if (absDiff < 200) {
        this.lastSyncTime_ = now;
        return;
      }

      logWarn(`[Sync] 音视频偏差 ${absDiff.toFixed(0)}ms，重新同步`);

      // ===== 直接 seek 音频到视频位置（不暂停）=====
      // 这样可以减少卡顿，同时保持同步
      await this.avAudio.seek(videoPos, media.SeekMode.SEEK_CLOSEST);

      this.lastSyncTime_ = now;
    } catch (e) {
      // 同步失败，忽略
    }
  }

  async aboutToAppear() {
    logInfo('[VPP] aboutToAppear 开始');
    // ⭐ 同步预判 PGC（番剧/影视）：在任何 await 之前设 isPgc_，避免首次 build 用 16:9 渲染后跳到 3:4
    try {
      const _p0 = router.getParams() as Record<string, Object>;
      if (_p0) {
        const _ep = typeof _p0['epId'] === 'number' ? _p0['epId'] : parseInt(_p0['epId'] as string, 10) || 0;
        const _mid = typeof _p0['mediaId'] === 'number' ? _p0['mediaId'] : parseInt(_p0['mediaId'] as string, 10) || 0;
        if (_ep > 0 || _mid > 0) this.isPgc_ = true;
      }
    } catch (_e) { }
    // ⭐ 首帧前同步重建分段按钮 options（非 @State 字段，主题色需在首次 build 前应用）
    this.rebuildSegmentOptions();
    // ⭐ 注册系统音量变化监听（音量键调节时同步 app 内滑块）
    // ⭐ 启动封面跑马灯流光动画（setInterval 驱动 angle 持续变化；首帧后由 onContentVisibleChange 停止）
    this.coverGlowTimer = setInterval(() => { this.coverGlowAngle = (this.coverGlowAngle + 3) % 360; }, 16);
    this.so_ = AppStorage.get<string>('screenOrientationLock') ?? '自动旋转';
    this.sh_ = AppStorage.get<boolean>('hideStatusBar') ?? false;
    // @StorageLink('bgp') 自动同步持久化值，无需手动读取

    // ⭐ 同步读取弹幕开关状态（从 AppStorage，避免异步加载前的默认 true 闪一下）
    const savedDmk = AppStorage.get<boolean>('danmakuEnabled');
    if (savedDmk !== undefined) {
      this.syncDanmakuEnabled(savedDmk);
    }

    // ⭐ 弹幕数据源设置
    // ⚠️ 这里【绝不能 await Preferences】：aboutToAppear 的 await 会让它后面的整段
    //   （路由参数解析 / 屏幕尺寸计算 / initW / loadD）推迟到"首帧渲染之后"才执行，
    //   首帧因此拿不到 cid、拿不到标题封面，等参数到位后再整体重排一次 —— 这是所有
    //   入口共有的固定起播延迟（实测该 await 占 ~20-40ms，且把网络发起也一起推迟）。
    //   弹幕数据源要到弹幕真正加载时才用得上，所以：先同步取 AppStorage 里的缓存值
   //   （HomePage 启动时已回填），再异步用 Preferences 校正。
   //   ⚠️ 校正时只能改 danmakuConfig 的**字段**，不能 `this.danmakuConfig = new DanmakuConfig()`：
   //      DanmakuController 持有构造时传入的那个对象引用，整体替换会让它从此读不到新配置。
    const cachedDmkSource = AppStorage.get<string>('danmakuApiSource');
    if (cachedDmkSource === 'grpc' || cachedDmkSource === 'xml') {
      // ⚠️ 同上：只改字段，不换对象（DanmakuController 持有的是构造时传进去的那个引用）
      this.danmakuConfig.apiSource = cachedDmkSource;
    }
    this.refreshDanmakuApiSource();
    this.loadDanmakuDisplaySettings();
    logInfo('[VPP] 同步段继续（弹幕数据源改异步，不阻塞参数解析）');

    // ⭐ 同步获取显示方向与尺寸，确保首次 build() 使用正确的 isLs/cw/ch/lsvw（不等 async initW）
    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      this.cw = this.getUIContext().px2vp(defaultDisplay.width);
      this.ch = this.getUIContext().px2vp(defaultDisplay.height);
      this.sw = this.cw;
      this.screenH_ = this.ch;
      this.isLs = defaultDisplay.width > defaultDisplay.height;
      this.maxFloatBtnBottom = this.isLs ? 392 : 592;
      this.updateIsLandscapeVertical();
      this.updateLSVSize();       // ← 必须同步调用，否则 lsvw/lsvh=0 → xcW=0 → 视频容器宽度为0
      this.updateVideoSize();     // ← 同步计算 videoDisplayWidth/Height
      this.initOverlayRectSync(); // ⭐ 首帧前估算常驻播放器层矩形（首帧后由占位槽精确接管）
    } catch (_e) { }

    // ⭐ 初始化旋转模式状态
    const lockMode = this.so_;
    if (lockMode === '锁定竖屏') {
      this.rotationMode = 'portrait';
    } else if (lockMode === '锁定横屏') {
      this.rotationMode = 'landscape';
    } else {
      this.rotationMode = 'auto';
    }

    const p = router.getParams() as Record<string, Object>;
    let aidFromParams = 0;
    if (p) {
      this.vi.bvid = (p['bvid'] as string) || '';
      this.vi.cid = typeof p['cid'] === 'number' ? p['cid'] : parseInt(p['cid'] as string, 10);
      this.vi.title = (p['title'] as string) || '';
      this.vi.cover = (p['coverUrl'] as string) || '';
      this.vi.ownerName = (p['ownerName'] as string) || '';
      this.vi.ownerFace = (p['ownerFace'] as string) || '';
      this.vi.duration = typeof p['duration'] === 'number' ? p['duration'] : (parseInt(p['duration'] as string, 10) || 0);
      this.vi.pubdate = typeof p['pubdate'] === 'number' ? p['pubdate'] : (parseInt(p['pubdate'] as string, 10) || 0);
      this.vi.view = typeof p['view'] === 'number' ? p['view'] : (parseInt(p['view'] as string, 10) || 0);
      this.vi.subTitle = (p['subTitle'] as string) || '';
      this.vi.score = (p['score'] as string) || '';
      this.vi.indexShow = (p['indexShow'] as string) || '';
      this.vi.badge = (p['badge'] as string) || '';
      // ⭐ 离线播放：本地缓存文件路径（非空时跳过网络取流）
      this.offlineVideoPath_ = (p['offlineVideoPath'] as string) || '';
      this.offlineAudioPath_ = (p['offlineAudioPath'] as string) || '';
      aidFromParams = typeof p['aid'] === 'number' ? p['aid'] : parseInt(p['aid'] as string, 10) || 0;
      this.commentRootId_ = typeof p['commentRootId'] === 'number' ? p['commentRootId'] : parseInt(p['commentRootId'] as string, 10) || 0;
      this.commentSecondaryId_ = typeof p['commentSecondaryId'] === 'number' ? p['commentSecondaryId'] : parseInt(p['commentSecondaryId'] as string, 10) || 0;
      // ⭐ PGC（番剧/影视）：支持 mediaId（季id，搜索跳转）或 epId（分集id）
      const mediaIdParam = typeof p['mediaId'] === 'number' ? p['mediaId'] : parseInt(p['mediaId'] as string, 10) || 0;
      const epIdParam = typeof p['epId'] === 'number' ? p['epId'] : parseInt(p['epId'] as string, 10) || 0;
      // ⭐ seasonId 可随 epId 一起传：省掉一次季接口反查，也避免 PGC 心跳缺 sid（会被 B 站静默丢弃）
      const seasonIdParam = typeof p['seasonId'] === 'number' ? p['seasonId'] : parseInt(p['seasonId'] as string, 10) || 0;
      if (epIdParam > 0) {
        this.epId_ = epIdParam;
        this.isPgc_ = true;
        if (seasonIdParam > 0) {
          this.seasonId_ = seasonIdParam;
        }
        // 只传 epId 未传 cid 时，需要反查 cid。
        // ⭐ 两个反查接口【并行】发起：getPgcEpisodeInfo 对本 App 的剧集 epId 实测常返回
        //   `[getPgcEpisodeInfo] data 为空`（例 epId=1231578 白等 ~190ms），串行会让每次进入
        //   播放页都多等这一整段；季接口 getPgcSeasonInfoByEpId 才是有数据的那个，且其返回
        //   还要用来填 vd/选集列表，所以以季接口为主、分集接口仅作 cid 兜底。
        if (!this.vi.cid || this.vi.cid <= 0) {
          logInfo(`[VPP] step1+step2 并行反查: epId=${epIdParam}`);
          const epInfoP: Promise<PgcEpisode | null> = getPgcEpisodeInfo(epIdParam);
          const pgcInfoP: Promise<PgcSeasonInfo | null> = getPgcSeasonInfoByEpId(epIdParam);
          const epInfo: PgcEpisode | null = await epInfoP;
          logInfo(`[VPP] step1: getPgcEpisodeInfo 完成`);
          if (epInfo && epInfo.cid && epInfo.cid > 0) {
            this.vi.cid = epInfo.cid;
            logInfo(`[VideoPlayer] PGC epId=${epIdParam} 分集接口取到 cid=${this.vi.cid}`);
          }
          // ⭐ 无论分集接口是否给到 cid，都继续用季接口结果补详情/选集：
          //   原实现只在"分集接口失败"时才填 vd，分集接口成功的场景详情卡与选集按钮是空的。
          //   这个 await 命中的是上面已并行发起的请求，通常已返回，几乎不额外耗时。
          const pgcInfo: PgcSeasonInfo | null = await pgcInfoP;
          logInfo(`[VPP] step2: getPgcSeasonInfoByEpId 完成`);
          if (pgcInfo && pgcInfo.episodes.length > 0) {
            // 优先找匹配的 epId 分集，找不到用第一集
            let matchedEp: PgcEpisode | null = null;
            for (const ep of pgcInfo.episodes) {
              if (ep.id === epIdParam) {
                matchedEp = ep;
                break;
              }
            }
            const targetEp: PgcEpisode = matchedEp ?? pgcInfo.episodes[0];
            if (targetEp.cid && targetEp.cid > 0) {
              this.vi.cid = targetEp.cid;
            }
            this.seasonId_ = pgcInfo.seasonId;
            if (!this.vi.title && pgcInfo.title) {
              this.vi.title = pgcInfo.title;
            }
            if (!this.vi.cover && pgcInfo.cover) {
              this.vi.cover = pgcInfo.cover;
            }
            // ⭐ 填充详情卡片数据（vd）：标题/简介/制作方/统计/分集列表（对齐 mediaId 分支）
            const owner: VideoDetailOwner = {
              mid: pgcInfo.upInfo.mid || 0,
              name: pgcInfo.upInfo.uname || (pgcInfo.staff || pgcInfo.actors || ''),
              face: pgcInfo.upInfo.avatar || ''
            };
            const stat: VideoDetailStat = {
              aid: 0,
              view: pgcInfo.stat.view,
              danmaku: pgcInfo.stat.danmaku,
              reply: pgcInfo.stat.reply,
              favorite: pgcInfo.stat.favorite,
              coin: pgcInfo.stat.coin,
              share: 0,
              like: pgcInfo.stat.like,
              dislike: 0
            };
            const pages: VideoPageItem[] = [];
            const pgcEpIds: number[] = [];
            const pgcAids: number[] = [];
            for (let i = 0; i < pgcInfo.episodes.length; i++) {
              const ep = pgcInfo.episodes[i];
              pages.push({
                cid: ep.cid || 0,
                page: i + 1,
                part: (ep.long_title || ep.title || `第${i + 1}话`),
                // ⭐ PGC season 接口 duration 为毫秒（UGC 为秒），转秒后再供 formatDuration 显示
                duration: ep.duration ? Math.floor(ep.duration / 1000) : 0,
                cover: ep.cover || ''
              });
              pgcEpIds.push(ep.id || 0);
              pgcAids.push(ep.aid || 0);
            }
            this.pgcEpIds_ = pgcEpIds;
            this.pgcAids_ = pgcAids;
            // ⭐ 番剧评论 oid 用当前分集的 aid（不能用 ep_id，否则查到的评论是错的）
            const targetEpAid = targetEp.aid || (pgcAids.length > 0 ? pgcAids[0] : 0);
            // ⭐ 历史记录/点赞等依赖 aidFromParams_（路由 aid=0 时由分集 aid 补齐）
            this.aidFromParams_ = targetEpAid;
            const pgcDetail: VideoDetail = {
              bvid: '',
              aid: targetEpAid,
              title: pgcInfo.title,
              desc: pgcInfo.desc || `${pgcInfo.actors || ''} ${pgcInfo.staff || ''}`.trim(),
              pic: pgcInfo.cover,
              pubdate: pgcInfo.pubdate,
              ctime: pgcInfo.pubdate,
              duration: 0,
              owner: owner,
              stat: stat,
              cid: this.vi.cid,
              pages: pages
            };
            this.vd = pgcDetail;
            // 互动统计初始化（点赞/投币/收藏数）
            this.likeCount = stat.like;
            this.coinCount = stat.coin;
            this.favoriteCount = stat.favorite;
            // ⭐ 选集/历史记录定位到当前分集（第 N 话），而非第一集
            const matchedEpIdx = this.pgcEpIds_.indexOf(this.epId_);
            this.currentPageIndex = matchedEpIdx >= 0 ? matchedEpIdx : 0;
            // ⭐ PGC 评论加载：不走 loadD（无 bvid），手动设置评论 oid（=分集 aid）
            this.commentCursor = 0;
            this.commentDataSource.clear();
            this.pendingCommentAid = targetEpAid;
            if (this.commentsInitialized && targetEpAid > 0) {
              this.loadC(targetEpAid);
              this.pendingCommentAid = 0;
            }
            logInfo(`[VideoPlayer] PGC epId=${epIdParam} 季接口回退: seasonId=${this.seasonId_}, cid=${this.vi.cid}, 评论aid=${targetEpAid}, title=${this.vi.title}`);
          }
        }
      } else if (mediaIdParam > 0) {
        // 只有 mediaId：先获取季信息取第一集
        this.seasonId_ = mediaIdParam;
        this.isPgc_ = true;
        logInfo(`[VPP] step3: getPgcSeasonInfo(mediaId=${mediaIdParam}) 开始`);
        const pgcInfo: PgcSeasonInfo | null = await getPgcSeasonInfo(mediaIdParam);
        logInfo(`[VPP] step3: getPgcSeasonInfo 完成`);
        if (pgcInfo && pgcInfo.episodes.length > 0) {
          const firstEp = pgcInfo.episodes[0];
          if (firstEp.id && firstEp.id > 0) {
            this.epId_ = firstEp.id;
          }
          if (firstEp.cid && firstEp.cid > 0) {
            this.vi.cid = firstEp.cid;
          }
          if (!this.vi.title && pgcInfo.title) {
            this.vi.title = pgcInfo.title;
          }
          if (!this.vi.cover && pgcInfo.cover) {
            this.vi.cover = pgcInfo.cover;
          }
          // ⭐ 填充详情卡片数据（vd）：标题/简介/制作方/统计/分集列表
          const owner: VideoDetailOwner = {
            mid: pgcInfo.upInfo.mid || 0,
            name: pgcInfo.upInfo.uname || (pgcInfo.staff || pgcInfo.actors || ''),
            face: pgcInfo.upInfo.avatar || ''
          };
          const stat: VideoDetailStat = {
            aid: 0,
            view: pgcInfo.stat.view,
            danmaku: pgcInfo.stat.danmaku,
            reply: pgcInfo.stat.reply,
            favorite: pgcInfo.stat.favorite,
            coin: pgcInfo.stat.coin,
            share: 0,
            like: pgcInfo.stat.like,
            dislike: 0
          };
          const pages: VideoPageItem[] = [];
          const pgcEpIds: number[] = [];
          const pgcAids: number[] = [];
          for (let i = 0; i < pgcInfo.episodes.length; i++) {
            const ep = pgcInfo.episodes[i];
            pages.push({
              cid: ep.cid || 0,
              page: i + 1,
              part: (ep.long_title || ep.title || `第${i + 1}话`),
              // ⭐ PGC season 接口 duration 为毫秒（UGC 为秒），转秒后再供 formatDuration 显示
              duration: ep.duration ? Math.floor(ep.duration / 1000) : 0,
              // ⭐ 分集封面（选集弹窗显示）
              cover: ep.cover || ''
            });
            pgcEpIds.push(ep.id || 0);
            pgcAids.push(ep.aid || 0);
          }
          this.pgcEpIds_ = pgcEpIds;
          this.pgcAids_ = pgcAids;
          // ⭐ 番剧评论 oid 用该集的 aid（不能用 ep_id，否则查到的评论是错的）
          const firstEpAid = pgcAids.length > 0 ? pgcAids[0] : 0;
          const pgcDetail: VideoDetail = {
            bvid: '',
            aid: firstEpAid,  // 番剧评论 oid = 分集 aid
            title: pgcInfo.title,
            desc: pgcInfo.desc || `${pgcInfo.actors || ''} ${pgcInfo.staff || ''}`.trim(),
            pic: pgcInfo.cover,
            pubdate: pgcInfo.pubdate,
            ctime: pgcInfo.pubdate,
            duration: 0,
            owner: owner,
            stat: stat,
            cid: this.vi.cid,
            pages: pages
          };
          this.vd = pgcDetail;
          // 互动统计初始化（点赞/投币/收藏数）
          this.likeCount = stat.like;
          this.coinCount = stat.coin;
          this.favoriteCount = stat.favorite;
          this.currentPageIndex = 0;
          // ⭐ PGC 评论加载：不走 loadD（无 bvid），手动设置评论 oid（=分集 aid）
          this.commentCursor = 0;
          this.commentDataSource.clear();
          this.pendingCommentAid = firstEpAid;
          if (this.commentsInitialized && firstEpAid > 0) {
            // 入场动画已完成 → 直接加载
            this.loadC(firstEpAid);
            this.pendingCommentAid = 0;
          }
          logInfo(`[VideoPlayer] PGC季信息: mediaId=${mediaIdParam}, 共${pgcInfo.episodes.length}集, 取第一集 epId=${this.epId_}, cid=${this.vi.cid}, title=${this.vi.title}, 制作方=${owner.name}, 播放=${stat.view}`);
          // ⭐ seasonId 以接口返回为准修正：路由 mediaId 可能是 media_id 而非 season_id
          //   （实测 media_id 当 sid 也能落库，但用真实 season_id 更稳）
          if (pgcInfo.seasonId > 0 && pgcInfo.seasonId !== this.seasonId_) {
            logInfo(`[VideoPlayer] seasonId 修正: ${this.seasonId_} → ${pgcInfo.seasonId}`);
            this.seasonId_ = pgcInfo.seasonId;
          }
        } else {
          logWarn(`[VideoPlayer] PGC季信息获取失败 mediaId=${mediaIdParam}`);
        }
        // 季信息第一集缺 cid 时兜底
        if (this.epId_ > 0 && (!this.vi.cid || this.vi.cid <= 0)) {
          logInfo(`[VPP] step4: getPgcEpisodeInfo 兜底(epId=${this.epId_}) 开始`);
          const epInfo = await getPgcEpisodeInfo(this.epId_);
          logInfo(`[VPP] step4: getPgcEpisodeInfo 兜底完成`);
          if (epInfo && epInfo.cid && epInfo.cid > 0) {
            this.vi.cid = epInfo.cid;
            logInfo(`[VideoPlayer] PGC epId=${this.epId_} 分集接口兜底取到 cid=${this.vi.cid}`);
          }
        }
      }
      // ⭐⭐ PGC 必须保证 seasonId / aid / cid 齐全（进页就解析，不等到心跳/退出）：
      //   B 站的 type=4 心跳缺 sid 会被**静默丢弃**（code=0 但云端 progress 不动），
      //   表现为"播放时正常、退出后官方历史变 0、重进只能定位到集"。
      //   epId 入口（HomePage 番剧卡 / 动态页 / UP空间页）原先只在 cid 缺失时才查季接口，
      //   走了分集接口快路就把 seasonId 漏掉了，所以这里统一兜底。
      if (this.isPgc_ && this.epId_ > 0) {
        await this.ensurePgcContext();
        // ⭐⭐ PGC 详情卡片 + 评论：必须在上面那个反查块【之外】、无条件调用。
        //   反查块被 `!cid || cid<=0` 守卫，来源页把 cid 一起带进来时（观看历史）整块被跳过，
        //   vd / pendingCommentAid 就永远填不上 —— 表现为"点番剧进去只有播放器，没有详情卡和评论"。
        //   这里的季信息刚刚被 ensurePgcContext 缓存，调用是零网络的纯同步填充。
        await this.fillPgcDetailFromSeason();
      }
      // ⭐ 获取初始播放进度（从历史记录恢复）
      this.initialProgress_ = typeof p['initialProgress'] === 'number' ? p['initialProgress'] : 0;
      logInfo(`[VideoPlayer] 路由参数: bvid=${this.vi.bvid}, aid=${aidFromParams}, pgc=${this.isPgc_}, epId=${this.epId_}, seasonId=${this.seasonId_}, initialProgress=${this.initialProgress_}`);
      if (this.initialProgress_ > 0) {
        logInfo(`[VideoPlayer] 从历史记录恢复播放进度: ${this.initialProgress_}秒`);
      }
    }

    // ⭐ 清除最小化标志（PlayerService 接管了恢复逻辑，旧状态仅用于清理）
    AppStorage.set('videoMinimized', false);

    // ⭐ 检查 PlayerService — 不匹配的播放器先释放
    const ps = PlayerService.getInstance();
    if (ps.hasActivePlayer && ps.playerState && ps.playerState.bvid !== this.vi.bvid) {
      logInfo('[VideoPlayer] PlayerService 中的播放器属于不同视频，释放');
      ps.release();
    }

    // ⭐ 检查 PlayerService 是否有存活播放器（从最小化恢复时无缝续播）
    if (ps.hasActivePlayer && ps.playerState && ps.playerState.bvid === this.vi.bvid) {
      logInfo('[VideoPlayer] 接管 PlayerService 已有播放器，跳过网络请求');
      // 从保存的状态恢复播放参数
      this.vi.bvid = ps.playerState.bvid;
      this.vi.cid = ps.playerState.cid;
      this.vi.title = ps.playerState.title;
      this.vi.cover = ps.playerState.cover;
      // ⭐ 恢复 PGC/详情参数（浮窗恢复时路由参数为空，否则下方参数校验失败跳过详情/评论加载）
      this.aidFromParams_ = ps.playerState.aid;
      this.epId_ = ps.playerState.epId;
      this.seasonId_ = ps.playerState.seasonId;
      this.isPgc_ = this.epId_ > 0;
      // ⭐ 使用 AVPlayer 当前实时进度（播放器一直在后台运行），而非最小化时的快照
      const realTimeMs: number = ps.videoPlayer ? ps.videoPlayer.currentTime : 0;
      this.initialProgress_ = realTimeMs / 1000;
      logInfo(`[VideoPlayer] 实时进度: ${realTimeMs}ms = ${this.initialProgress_}s (快照: ${ps.playerState.currentTime}s)`);
      this.qn = ps.playerState.quality;
      this.ql = ps.playerState.qualityLabel;
      this.vol = ps.playerState.volume;
      this.mute = ps.playerState.mute;
      this.play = ps.playerState.isPlaying;
      // ⭐ 恢复横屏竖屏视频模式和宽高比
      this.isLandscapeVertical = ps.playerState.isLandscapeVertical;
      this.ar = ps.playerState.videoAspectRatio;

      // 接管播放器引用
      this.av = ps.videoPlayer;
      this.avAudio = ps.audioPlayer;

      // ⭐ DASH 转播站句柄从 PlayerService 取回（桥已移交；句柄的 stop() 供页面退出停服）
      //    播放器恢复后继续消费转播站流，server 生命周期此刻归本页面。
      const dashServer = ps.takeDashServer();
      this.dashHandle_ = dashServer;
      this.isDashStream_ = dashServer !== null;
      if (dashServer) {
        logInfo('[VideoPlayer] 恢复接管：转播站句柄已取回（服务继续运行）');
      } else {
        this.isDashStream_ = false;
      }

      // 清除 PlayerService 状态
      ps.hasActivePlayer = false;
      ps.videoPlayer = null;
      ps.audioPlayer = null;
      ps.playerState = null;

      // 注册新页面的事件监听器
      this.setupL();
      this.setupAudioL();

      // 延迟绑定 XComponent surface 并恢复播放（build 后 surface 才就绪）
      setTimeout(() => {
        this.resumeFromMinimized();
      }, 500);

      // ⭐ 浮窗恢复：PGC 补详情/评论（loadD 仅 UGC，bvid 空时直接 return，不会加载 PGC 详情）
      if (this.isPgc_ && this.epId_ > 0) {
        this.fillPgcDetailFromSeason();
      }
    }

    // ⭐ 智感握持初始化（在所有早返回之前执行，确保所有路径都订阅）
    // 动态请求手势权限（需真机HarmonyOS 6+）
    this.requestGesturePermission();
    // 初始化智感握持位置（查询系统安全区域）
    this.initSmartGripPosition();
    // 订阅握持状态变化
    this.subscribeGripChanges();

    // 检查参数有效性：需要bvid、aid、或 PGC（epId_）
    if (!this.vi.bvid && !aidFromParams && !(this.isPgc_ && this.epId_ > 0)) {
      this.err = '参数错误：缺少视频ID';
      this.ld = false;
      return;
    }

    // ⭐ PGC（番剧/影视）模式：跳过 bvid/aid 转换，直接使用 epId_ + cid
    // 无需 return：下方公共流程（qn/音量/弹幕状态/initW/loadD/心跳）对 PGC 同样适用
    if (this.isPgc_) {
      if (!this.vi.cid || this.vi.cid <= 0) {
        logWarn('[VideoPlayer] PGC cid 无效，尝试从 epId 获取 cid');
      }
      logInfo(`[VideoPlayer] PGC 模式: epId=${this.epId_}, seasonId=${this.seasonId_}, cid=${this.vi.cid}, title=${this.vi.title}`);
    }

    // ⭐ 默认画质必须在 aid/bvid 分支【之前】应用：
    //    aid 入口（首页卡片/推荐/搜索）会 `initFromAid() → return`，
    //    旧位置在 return 之后 ⇒ 从首页进播放页永远用初始值 116，
    //    用户在设置里选的 4K（defaultVideoQn=120）形同虚设（实测 BV1qaJ86aEBd）。
    const dq = AppStorage.get<number>('defaultVideoQn');
    if (dq !== undefined) {
      this.qn = dq;
      const it = this.ql_.find(q => q.qn === dq);
      this.ql = it ? it.label : '1080P60';
      logInfo(`[VideoPlayer] 应用默认画质: qn=${dq} (${this.ql})`);
    }

    // 如果没有bvid、或者bvid是数字（实际上是aid），通过aid获取视频信息
    // 心跳上报需要真实的BV格式bvid，否则B站API返回-400
    const isNumericBvid: boolean = /^\d+$/.test(this.vi.bvid);
    if ((!this.vi.bvid || isNumericBvid) && aidFromParams) {
      if (isNumericBvid) {
        logInfo('[VideoPlayer] bvid是数字格式(实际是aid)，通过aid获取真实bvid:', aidFromParams);
      } else {
        logInfo('[VideoPlayer] 通过aid获取视频信息:', aidFromParams);
      }
      logInfo(`[VPP] 走 initFromAid 分支, aid=${aidFromParams}`);
      this.initFromAid(aidFromParams);
      return;
    }

    if (isNaN(this.vi.cid)) {
      this.vi.cid = 0;  // 默认cid，后续会通过API获取
    }
    this.readSystemVolume();
    const sm = AppStorage.get<boolean>('globalMuted');
    if (sm !== undefined) this.mute = sm;
    // ⭐ 读取弹幕开关状态（优先从Preferences读取持久化值）
    this.loadDanmakuEnabledState();
    // ⭐ 读取控制栏镜像布局状态
    this.loadMirrorControlsState();
    this.loadSM();
    logInfo('[VPP] 走 bvid 主分支, 即将调用 initW/loadD/checkBiliLoginStatus');
    this.initW().then(() => {
      logInfo('[VPP] initW 完成');
      if (this.mw) this.manageSB();
      // ⭐ initW 已设置 isLs/cw/ch 并调用了 updateIsLandscapeVertical + updateVideoSize
      // 这里只确保系统栏状态正确
    });
    this.activateAudioSession();
    this.resetCT();
    logInfo('[VPP] 即将调用 loadD');
    this.loadD();
    // ⭐ 启动心跳定时器
    this.startHeartbeat();
    // ⭐ 检测B站登录状态（调用API验证）
    logInfo('[VPP] 即将调用 checkBiliLoginStatus');
    this.checkBiliLoginStatus();
    // ⭐ 封面预解码已延后到首帧后（startRenderFrame → predecodeCover），此处不再与起播抢资源
    logInfo('[VPP] aboutToAppear 同步部分完成');
  }

  /** 尝试初始化 GL 渲染管线 — 已禁用（当前设备/OS 不支持帧拦截） */
  private tryInitGL_(xcSurfaceId: string): void {
    logInfo(`[VideoFilter] GL disabled, using direct XComponent rendering`);
    return;
  }

  private startGLRenderLoop(): void { /* 已禁用 */ }
  private stopGLRenderLoop(): void { /* 已禁用 */ }
  private releaseGL_(): void { /* 已禁用 */ }

  // ⭐ 检测B站登录状态（调用API验证）
  private async checkBiliLoginStatus(): Promise<void> {
    logInfo('[VPP] checkBiliLoginStatus 开始');
    try {
      // 先快速检查Cookie是否含SESSDATA
      if (!this.biliCookie.includes('SESSDATA')) {
        this.isBiliLoggedIn = false;
        logInfo('[VideoPlayer] Cookie无SESSDATA，未登录');
        return;
      }
      // Cookie有SESSDATA，再调用API验证
      logInfo('[VPP] checkBiliLoginStatus: 调用 getUserInfo 开始');
      const userInfo = await getUserInfo();
      logInfo('[VPP] checkBiliLoginStatus: getUserInfo 完成');
      if (userInfo && userInfo.isLogin) {
        this.isBiliLoggedIn = true;
        logInfo('[VideoPlayer] API验证登录成功, mid=' + userInfo.mid);
      } else {
        this.isBiliLoggedIn = false;
        logInfo('[VideoPlayer] API验证登录失败，Cookie已失效');
      }
    } catch (err) {
      logError('[VideoPlayer] 检测登录状态异常: ' + err);
      // 保底：用Cookie判断
      this.isBiliLoggedIn = this.biliCookie.includes('SESSDATA');
    }
    logInfo('[VPP] checkBiliLoginStatus 完成');
  }

  // ⭐ 智感握持 - 查询系统安全区域（异步，仅查询原始px值）
  private async initSmartGripPosition(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      // 获取底部导航指示器（手势横条 → 决定按钮底部边距）
      const navArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const bottomPx = navArea?.bottomRect?.height ?? 0;
      this.gripSafeAreaBottom = this.getUIContext().px2vp(bottomPx) + 8; // 略高于手势横条，避免冲突
      // 获取侧边手势区域（返回手势 → 决定按钮右侧/左侧边距）
      const gestureArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM_GESTURE);
      const rightPx = gestureArea?.rightRect?.width ?? 0;
      this.gripSafeAreaRight = (rightPx > 0 ? this.getUIContext().px2vp(rightPx) : 0) + 16;
      const leftPx = gestureArea?.leftRect?.width ?? 0;
      this.gripSafeAreaLeft = (leftPx > 0 ? this.getUIContext().px2vp(leftPx) : 0) + 16;
      // 获取系统避让区（状态栏/刘海/挖孔）左侧安全区 → 全屏时左侧锁定按钮避开前置摄像头
      const sysArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const sysLeftPx = sysArea?.leftRect?.width ?? 0;
      const sysLeftSafe: number = sysLeftPx > 0 ? this.getUIContext().px2vp(sysLeftPx) : 0;
      AppStorage.setOrCreate('safeAreaLeft', sysLeftSafe);
      logInfo(`[SmartGrip] TYPE_SYSTEM leftSafe=${sysLeftSafe}vp`);
    } catch (e) {
      logWarn('[SmartGrip] 安全区域查询失败，使用默认值');
    }
    // 无论是否查询成功，都用当前容器尺寸重算按钮位置
    this.recalcSmartGripPosition();
  }

  /** 全屏后重新查询左侧安全区（规避前置摄像头/挖孔） */
  private async refreshSafeAreaLeft(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(context);
      const sysArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      // 横屏时优先用 leftRect，部分设备把前置挖孔报在 topRect 中
      const leftPx = sysArea?.leftRect?.width ?? 0;
      const topPx = sysArea?.topRect?.width ?? 0;
      const rawPx = leftPx > topPx ? leftPx : topPx;
      const safeVp: number = rawPx > 0 ? this.getUIContext().px2vp(rawPx) : 0;
      // 如果系统没返回安全区，用 statusBarHeight 作为兜底（与前置挖孔宽度大致相当）
      const sbHeight: number = AppStorage.get<number>('statusBarHeight') ?? 40;
      const fallback: number = sbHeight > 0 ? sbHeight : 40;
      const finalValue: number = safeVp > 0 ? safeVp : fallback;
      AppStorage.setOrCreate('safeAreaLeft', finalValue);
      logInfo(`[SafeArea] 全屏左侧安全区=${finalValue}vp (left=${leftPx} top=${topPx} fallback=${fallback})`);
    } catch (e) {
      logWarn('[SafeArea] 查询失败', e);
    }
  }

  // ⭐ 智感握持 - 根据方向+容器尺寸+握持手计算拇指热区按钮位置（同步，可频繁调用）
  private recalcSmartGripPosition(): void {
    const bottomSafe = this.gripSafeAreaBottom;
    const screenH = this.ch > 0 ? this.ch : 800; // 兜底

    // 计算通用底部边距
    if (this.isLs) {
      // 横屏/全屏 → 拇指握持在屏幕右侧，按钮在右下角的20%高度区
      this.smartGripBottom = Math.max(bottomSafe + 24, screenH * 0.20);
    } else {
      // 竖屏 → 拇指自然在右下角，按钮在底部15%高度区（比之前6%更高）
      this.smartGripBottom = Math.max(bottomSafe + 12, screenH * 0.15);
    }

    // ⭐ 根据握持手切换按钮左右位置
    // 两边始终保持有效值，避免 position 跳变触发平移动画
    this.smartGripLeft = this.gripSafeAreaLeft + 16;
    this.smartGripRight = this.gripSafeAreaRight + 8;
  }

  // ⭐ 订阅握持状态变化（motion.on 智感握持）
  private subscribeGripChanges(): void {
    if (this.gripListenerSubscribed) return;
    if (!this.smartGripEnabled) return;
    try {
      motion.on('holdingHandChanged', (data: motion.HoldingHandStatus) => {
        if (data !== this.hand && (data === motion.HoldingHandStatus.LEFT_HAND_HELD || data === motion.HoldingHandStatus.RIGHT_HAND_HELD)) {
          this.hand = data;
          this.recalcSmartGripPosition();
          logInfo(`[SmartGrip] motion握持状态变化: ${data}`);
        }
      });
      logInfo('[SmartGrip] 已订阅motion握持变化事件');
      this.gripListenerSubscribed = true;
    } catch (err) {
      const error = err as BusinessError;
      logError(`[SmartGrip] motion订阅失败. Code: ${error.code}, message: ${error.message}`);
      // 不设置 gripListenerSubscribed = true，让后续 onPageShow 可以重试
    }
  }

  // ⭐ 动态申请手势检测权限（敏感权限，需运行时请求）
  private async requestGesturePermission(): Promise<void> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      await atManager.requestPermissionsFromUser(this.getUIContext().getHostContext() as common.UIAbilityContext,
        ['ohos.permission.DETECT_GESTURE']);
      logInfo('[SmartGrip] 手势权限已授权');
    } catch (e) {
      const err = e as BusinessError;
      logWarn(`[SmartGrip] 手势权限被拒绝: ${err.code}`);
    }
  }

  // ⭐ 取消订阅握持状态变化
  private unsubscribeGripChanges(): void {
    if (!this.gripListenerSubscribed) return;
    // motion.off('holdingHandChanged') 是全局操作，会移除所有页面的监听器
    // 因此让 Index.ets 管理全局生命周期，本页只复位标记
    this.gripListenerSubscribed = false;
    logInfo('[SmartGrip] 标记已取消（保留全局监听）');
  }

  /**
   * 通过aid初始化视频信息
   * 当历史记录只有aid没有bvid时使用
   */
  /**
   * ⭐ aid 入口（App 推荐 feed 只有 aid，没有真 bvid）
   * 旧实现自己 `http.createHttp()` 打 `/x/web-interface/view/detail?aid=`，解析出 bvid 后
   *   loadD 又打了一次 `/x/web-interface/view?bvid=` —— **同一个稿件请求两次**，且都在起播关键路径上。
   * 现在改走带缓存 + 请求去重的 getVideoDetail(aid)：
   *   - 来源页"点卡片"时预热过就命中缓存/复用在飞请求，0 网络；
   *   - 返回里的 cid 一并写进 vi.cid：cid 是起播硬前提，越早拿到越早能发 playurl；
   *   - loadD 随后用 bvid 再查会命中同一条缓存，不再重复请求。
   */
  private async initFromAid(aid: number) {
    logInfo('[initFromAid] 开始获取视频信息, aid:', aid);
    try {
      const d: VideoDetail | null = await getVideoDetail(String(aid));
      if (!d || !d.bvid) {
        logError('[initFromAid] 获取视频信息失败');
        this.err = '获取视频信息失败';
        this.ld = false;
        logInfo('[VPP] initFromAid 完成');
        return;
      }
      this.vi.bvid = d.bvid;
      if (!this.vi.title && d.title) this.vi.title = d.title;
      if (!this.vi.cover && d.pic) this.vi.cover = d.pic;
      if ((!this.vi.cid || this.vi.cid <= 0) && d.cid && d.cid > 0) {
        this.vi.cid = d.cid;
      }
      if ((!this.vi.cid || this.vi.cid <= 0) && d.pages && d.pages.length > 0) {
        this.vi.cid = d.pages[0].cid || 0;
      }
      logInfo(`[initFromAid] 获取到bvid: ${this.vi.bvid}, cid=${this.vi.cid}`);

      // 继续正常的初始化流程
      // ⭐ 默认画质已在 aboutToAppear 的公共段应用（aid 分支之前），此处不再重复读，
      //    否则两处读取的时机差异会让「首页入口用 116、历史入口用 120」这种不一致重现。
      this.readSystemVolume();
      const sm = AppStorage.get<boolean>('globalMuted');
      if (sm !== undefined) this.mute = sm;
      this.loadSM();
      this.initW().then(() => {
        if (this.mw) this.manageSB();
        // ⭐ initW 已设置 isLs/cw/ch 并调用了 updateIsLandscapeVertical + updateVideoSize
      });
      this.activateAudioSession();
      this.resetCT();
      // ⭐ loadD 此时会命中详情缓存（0 网络）：只负责填 vd / 初始化评论与互动态
      this.loadD();
      this.loadDanmakuEnabledState();
      // ⭐ 读取控制栏镜像布局状态（aid 入口在 aboutToAppear 已提前 return，这里补一次）
      this.loadMirrorControlsState();
      this.startHeartbeat();
    } catch (e) {
      logError('[initFromAid] 异常:', JSON.stringify(e));
      this.err = '加载失败';
      this.ld = false;
    }
    logInfo('[VPP] initFromAid 完成');
  }

  // ⭐ 用户是否主动点击了暂停（区别于系统 onPageHide 暂停）
  private userPaused_: boolean = false
  // ⭐ 后台播放：onPageHide 中暂时暂停，onBackground 确认后恢复
  private bgpPausedByPageHide_: boolean = false

  /**
   * ⭐ 屏幕常亮：播放中保持屏幕不锁，暂停/隐藏/退出时关闭（防止播放中被自动锁屏）
   */
  private updateKeepScreen(): void {
    this.mw?.setWindowKeepScreenOn(this.play).catch(() => {});
  }

  /** play 状态变化时同步屏幕常亮 */
  private onPlayChanged(): void {
    this.updateKeepScreen();
  }

  /**
   * 页面隐藏时（切后台/跳转其他页面）：根据后台播放开关决定是否暂停
   * bgp=true：保持播放（用户期望音频继续），不区分切后台还是页面跳转
   * bgp=false：暂停播放，防止音频重叠
   */
  onPageHide(): void {
    // ⭐ 页面隐藏即释放屏幕常亮（后台播放/跳页时屏幕可正常锁屏）
    this.mw?.setWindowKeepScreenOn(false).catch(() => {});
    // ⭐ 自动画中画：切后台且武装中 → 保持播放，画面随 XComponent 迁入系统小窗
    if (this.appInBackground && this.pipCtrl_ && this.pipArmAllowed_()) {
      logInfo('[VideoPlayer] onPageHide → 自动小窗模式，保持播放');
      return;
    }
    // 播放器已转移至 PlayerService（最小化场景），页面不再控制播放
    if (PlayerService.getInstance().hasActivePlayer) {
      logInfo('[VideoPlayer] onPageHide → 播放器已转移至 PlayerService，跳过');
      return;
    }
    if (!this.play || !this.av) {
      return;
    }
    if (this.bgp) {
      // ⭐ 后台播放仅针对「真正切后台」：已确认（onBackground 先行）则保持播放；
      // 页面跳转（pushUrl 覆盖本页，如进个人空间/切换视频）不触发 onBackground，
      // 先暂停，等待 onBackground 确认后再恢复，避免新旧视频声音重叠
      if (this.appInBackground) {
        logInfo('[VideoPlayer] onPageHide → 后台播放模式（已切后台），保持播放');
        return;
      }
      logInfo('[VideoPlayer] onPageHide → 后台播放模式：先暂停，onBackground 确认后恢复');
      this.bgpPausedByPageHide_ = true;
      this.av.pause();
      this.avAudio?.pause();
      this.play = false;
      LiveViewHelper.updatePlayState(false);
      return;
    }
    // 暂停播放，防止切换到其他页面后旧视频仍在播放
    logInfo('[VideoPlayer] onPageHide → 暂停播放');
    this.av.pause();
    this.avAudio?.pause();
    this.play = false;
    LiveViewHelper.updatePlayState(false);
  }

  /**
   * onBackground 确认回调（通过 @Watch 监听 appBackgroundTimestamp 变化触发）
   * 备用方案：用于 bgpPausedByPageHide_ 被设置的极少数兜底场景
   */
  onAppBackgroundConfirmed(): void {
    if (this.appBgTimestamp === 0) return;
    if (this.bgpPausedByPageHide_) {
      this.bgpPausedByPageHide_ = false;
      if (this.bgp && this.av) {
        logInfo('[VideoPlayer] onBackground 确认 → 后台播放模式，恢复播放');
        if (this.av.state === 'paused') {
          this.av.play();
          this.avAudio?.play();
          this.play = true;
        }
        LiveViewHelper.updatePlayState(true);
      }
    }
    // ⭐ 自动画中画：切后台后同步武装；bgp 恢复播放是异步的，安排重试补武装
    this.updatePipAutoArm_();
    this.armPipWhenPlaying_(5);
  }

  /**
   * 页面显示时恢复播放（从后台/其他页面返回时）
   */
  onPageShow(): void {
    // 清除 bgp 暂停标记（如果是页面跳转场景，onBackground 不会触发，标记仍存在）
    if (this.bgpPausedByPageHide_) {
      this.bgpPausedByPageHide_ = false;
      // 页面跳转回来（非后台），此时播放已被 onPageHide 暂停，按需恢复
    }
    if (!this.play && !this.userPaused_ && this.av && this.av.state === 'paused') {
      logInfo('[VideoPlayer] onPageShow → 恢复播放');
      this.av.play();
      this.avAudio?.play();
      this.play = true;
    }
    // ⭐ 屏幕常亮：回到页面按当前播放状态恢复
    this.updateKeepScreen();
    // ⭐ 自动画中画：页面恢复可见，重新评估武装状态
    this.updatePipAutoArm_();
    // ⭐ 从缓存页返回时同步缓存提示条：暂停后「继续」走的是 resume() 的新下载，
    // 最初 svc.download 的回调已结束，须按条目真实状态刷新完成文案
    this.syncCacheHintStatus();
    // ⭐ 页面恢复时重新订阅智感握持（上次订阅失败时可重试）
    if (!this.gripListenerSubscribed) {
      this.subscribeGripChanges();
    }
    // ⭐ 从后台切回来时强制恢复系统栏状态
    // onForeground → setupImmersiveWindow 依赖 AppStorage.isLandscape，
    // 但横屏时窗口实际尺寸可能仍是竖屏，导致 isLandscape=false → 错误显示状态栏。
    // 页面自身知道 fs/isLs 真实状态，force=true 强制覆盖。
    logInfo('[VideoPlayer] onPageShow → manageSB(force=true)');
    if (this.mw) this.manageSB(true);
    // ⭐ 延迟 1s 再次强制恢复，覆盖系统在窗口完全显示后（~568ms）才发的避让区通知
    setTimeout(() => {
      logInfo('[VideoPlayer] onPageShow → delayed manageSB');
      if (this.mw) this.manageSB(true);
    }, 1000);
  }

  aboutToDisappear() {
    // ⭐ 进度调节缩略图：先松开 UI 引用再整体释放位图（避免释放后仍被组件引用）
    this.shotToken_++;
    this.thumb_ = new SeekThumb();
    VideoShotService.release();
    // ⭐ 注销系统音量变化监听
    if (this.coverGlowTimer) { clearInterval(this.coverGlowTimer); this.coverGlowTimer = 0; }
    // ⭐ 缩小/还原动画（animateVidShrink）：页面销毁时若动画还没收尾，弹幕是被关着的状态，
    //    必须补恢复（后台播放场景下 controller/配置可能被 PlayerService 继续持有）。
    //    非定时器动画，无需 clearInterval；代数号自增即可让迟到的 onFinish 失效。
    if (this.shrinkAnimating) {
      this.shrinkAnimGen++;
      this.shrinkAnimating = false;
      this.dmFreezeW = 0;
      this.dmFreezeH = 0;
      this.danmakuConfig.enable = this.isDanmakuEnabled;
    }
    this.unregisterVolumeListener();
    // ⭐ 页面销毁时清除全屏标志
    AppStorage.set('isFullscreen', false);
    // ⭐ 释放 GL 渲染资源
    this.releaseGL_();
    // ⭐ 停止心跳定时器
    this.stopHeartbeat();
    // ⭐ 停止音视频同步定时器
    this.stopSyncTimer();
    // ⭐ 取消声画同步（2x 追赶）
    this.cancelVideoSpeedSync();
    this.saveWatchHistory();
    this.reportWatchBehavior();  // ⭐ 上报观看行为
    this.clrT();
    this.clearLightBtnTimer(); // ⭐ 清除开灯按钮自动隐藏定时器
    this.release();
    this.restoreS();
    if (this.mw) this.mw.setWindowBrightness(this.originalBrightness_);
    // ⭐ 页面销毁时关闭屏幕常亮，避免占用窗口资源
    if (this.mw) this.mw.setWindowKeepScreenOn(false).catch(() => {});
    if (this.fsAnimTimer_ !== -1) {
      clearTimeout(this.fsAnimTimer_);
      this.fsAnimTimer_ = -1;
    }
    // ⭐ 取消智感握持监听
    this.unsubscribeGripChanges();
    // ⭐ 结束实况窗（后台播放模式保留后台任务和媒体会话）
    if (!this.bgp) {
      LiveViewHelper.end();
    } else {
      logInfo('[VideoPlayer] aboutToDisappear → 后台播放模式，保留实况窗和后台任务');
      // ⭐ 不清除控制回调——FloatingVideoButton 已在 minimize 过程中通过
      //   registerLiveViewHandlers() 用 PlayerService 重新注册了有效回调
    }
    // ⭐ 清除实况窗节流定时器
    if (this.lvTimer_ !== -1) {
      clearTimeout(this.lvTimer_);
      this.lvTimer_ = -1;
    }
    // ⭐ 释放预解码的图像缓存
    clearImageCache();
  }

  /**
   * ⭐ 启动心跳定时器
   * 每15秒向B站上报一次观看进度，让推荐算法实时学习用户偏好
   */
  private startHeartbeat(): void {
    if (this.heartbeatTimer !== -1) return;

    this.heartbeatTimer = setInterval(() => {
      this.sendHeartbeat();
    }, this.HEARTBEAT_INTERVAL);

    logInfo(`[心跳] 已启动心跳定时器，间隔${this.HEARTBEAT_INTERVAL / 1000}秒`);
  }

  /**
   * ⭐ 停止心跳定时器
   */
  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
      logInfo('[心跳] 已停止心跳定时器');
    }
  }

  /**
   * ⭐ 发送心跳
   * 只有当播放进度有变化时才上报，避免无效请求
   */
  private async sendHeartbeat(): Promise<void> {
    // 条件检查：必须有视频信息、正在播放、有进度变化
    // ⭐ PGC（番剧/影视）bvid 为空：改判 epId，走番剧专用上报（type=4 + epid/sid + csrf）
    const isPgc: boolean = this.isPgc_ && this.epId_ > 0;
    if ((!this.vi.bvid && !isPgc) || !this.play || this.ct <= 0 || this.dur <= 0) return;

    // 检查进度是否有变化（至少变化5秒才上报）
    if (Math.abs(this.ct - this.lastHeartbeatTime) < 5) return;

    this.lastHeartbeatTime = this.ct;

    try {
      const watchTime = Math.floor(this.ct);
      const duration = Math.floor(this.dur);
      const cid = this.vi.cid || 0;
      const progress = Math.floor((watchTime / duration) * 100);

      // ⭐ 番剧/影视：进度必须按分集上报（type=4 + epid/sid），否则 B 站只记「看过这一集」而位置丢失
      if (isPgc) {
        logInfo(`[心跳] 上报番剧进度: epId=${this.epId_}, ${watchTime}秒/${duration}秒`);
        await this.reportPgcHeartbeat(watchTime);
        return;
      }

      logInfo(`[心跳] 上报进度: ${this.vi.bvid}, ${watchTime}秒/${duration}秒 (${progress}%)`);

      // 调用上报服务
      await reportWatch(this.vi.bvid, cid, duration, watchTime);
    } catch (err) {
      logError(`[心跳] 上报失败: ${err}`);
    }
  }

  /**
   * ⭐ 确保 PGC（番剧/影视）上报所需的上下文齐全：seasonId（季 id）+ 当前分集 aid/cid
   *
   * **为什么必须有**：B 站的 `/x/click-interface/web/heartbeat` 在 `type=4` 时**缺 sid 会静默丢弃**
   * —— 返回 `code=0`（看起来成功）但云端 `progress` 保持 0。用真机 Cookie 对拍实测：
   *   缺 sid → progress 不动；补 sid（season_id 或 media_id 均可，只要非 0）→ 立即落库。
   * 于是所有 PGC 上报前都必须先拿到 sid，否则用户看到的正是
   * "播放时位置正常、退出后官方历史变 0、再进只能定位到集"。
   *
   * 为什么容易缺：只有 `mediaId` 入口（番剧频道页/搜索/HomePage 季卡）会把 seasonId_ 直接赋值；
   * 而 `epId` 入口原先**只在 cid 缺失时**才去查季接口，走了分集接口快路就漏掉 seasonId_
   * （HomePage 番剧卡、动态页、UP空间页都只传 epId）。
   *
   * @returns true 表示 context 可用（seasonId 已知）
   */
  private async ensurePgcContext(): Promise<boolean> {
    const needSeason: boolean = this.seasonId_ <= 0;
    const needAid: boolean = (this.vd?.aid ?? 0) <= 0 && this.aidFromParams_ <= 0;
    const needCid: boolean = (this.vi.cid || 0) <= 0;
    if (!needSeason && !needAid && !needCid) return true;
    if (this.epId_ <= 0) return false;
    try {
      const info: PgcSeasonInfo | null = await getPgcSeasonInfoByEpId(this.epId_);
      if (!info) {
        logWarn(`[PGC] 季信息反查失败 (epId=${this.epId_})：seasonId 仍为 ${this.seasonId_}，进度会被 B 站丢弃`);
        return this.seasonId_ > 0;
      }
      // ⭐ 留下这份完整季信息：本方法只为 seasonId/aid 而来，但它是唯一一次季接口请求，
      //   详情卡片（vd）与评论同样需要它，缓存后调用方可以零网络复用（季接口无 API 缓存）。
      this.pgcSeasonInfoCache_ = info;
      if (this.seasonId_ <= 0 && info.seasonId > 0) {
        this.seasonId_ = info.seasonId;
        logInfo(`[PGC] 反查补全 seasonId=${this.seasonId_} (epId=${this.epId_})`);
      }
      // 定位当前分集，补齐 aid / cid（上报要求 epid 与 aid 指向同一分集）
      let matched: PgcEpisode | null = null;
      for (let i = 0; i < info.episodes.length; i++) {
        if (info.episodes[i].id === this.epId_) {
          matched = info.episodes[i];
          break;
        }
      }
      if (matched === null && info.episodes.length > 0) {
        matched = info.episodes[0];
      }
      if (matched !== null) {
        const epCid: number = matched.cid ?? 0;
        const epAid: number = matched.aid ?? 0;
        if ((this.vi.cid || 0) <= 0 && epCid > 0) {
          this.vi.cid = epCid;
        }
        if (epAid > 0 && (this.vd?.aid ?? 0) <= 0 && this.aidFromParams_ <= 0) {
          this.aidFromParams_ = epAid;
          logInfo(`[PGC] 反查补全 aid=${epAid} (epId=${this.epId_})`);
        }
      }
    } catch (e) {
      logError(`[PGC] 季信息反查异常: ${errMsg(e)}`);
    }
    return this.seasonId_ > 0;
  }

  /**
   * ⭐ 上报番剧/影视（PGC）观看进度
   * 走 /x/click-interface/web/heartbeat，带 aid + cid + epid + sid + type=4 + csrf，
   * 这样历史记录里该分集的观看位置才能被记住（否则重进只能定位到"哪一集"，定位不到时间）。
   */
  private async reportPgcHeartbeat(watchTime: number): Promise<void> {
    const cookie = AppStorage.get<string>('biliCookie') || '';
    if (!cookie) return;
    if (this.epId_ <= 0) return;
    // ⭐ 绝不上报"还没真正看过"的进度。
    //   为什么致命：B 站对同一部番剧**只保留一条历史记录**（键 kid = 心跳的 sid = season_id），
    //   这一季任何一集的心跳都会覆盖这唯一一条。切集时播放器把进度重置成 0（floor(0.4)=0），
    //   若照发就把整季记录清零 —— 实测云端会立刻变成 `ep=新集, progress=0`，
    //   连原来那集的续播点都查不回来（playurl 返回 watch_progress 回落 0）。
    //   这正是用户报的"退出播放页后官方历史变成 0、再进去只能定位到集却定位不到时间"。
    const played: number = Math.max(0, Math.floor(watchTime));
    if (played < MIN_HEARTBEAT_PROGRESS_SEC) {
      logInfo(`[心跳] PGC 进度仅 ${played}s（<${MIN_HEARTBEAT_PROGRESS_SEC}s），跳过一次上报，`
        + `避免覆盖整季共用记录 (epId=${this.epId_})`);
      return;
    }
    // ⭐ sid 是 PGC 心跳的硬前提（缺了 B 站静默丢弃），先确保上下文齐全
    const ok: boolean = await this.ensurePgcContext();
    if (!ok) {
      logError(`[心跳] PGC 上报无法取得 seasonId (epId=${this.epId_})，本次跳过（否则进度会被静默丢弃）`);
      return;
    }
    const cid: number = this.vi.cid || 0;
    const aid: number = this.vd?.aid ?? this.aidFromParams_;
    if (aid <= 0 || cid <= 0) {
      logWarn(`[心跳] PGC 上报缺少 aid/cid (aid=${aid}, cid=${cid}, epId=${this.epId_})，跳过`);
      return;
    }
    const item = new WatchHistoryItem();
    item.aid = aid;
    item.cid = cid;
    item.bvid = this.vi.bvid;
    item.title = this.vi.title || (this.vd?.title ?? '');
    item.playProgress = played;
    item.totalDuration = Math.floor(this.dur);
    item.watchedAt = Math.floor(Date.now() / 1000);
    item.epId = this.epId_;
    item.seasonId = this.seasonId_;

    const helper = WatchHistoryHelper.getInstance();
    helper.setCookie(cookie);
    await helper.saveWatchRecord(item);
  }

  /**
   * ⭐ 用 playurl 返回的服务端续播点恢复播放位置
   *
   * 为什么需要：历史记录的 progress 只覆盖「从历史记录进入」这一条路径；从番剧页 / 推荐 / 搜索
   * 进入时路由不带进度。B 站 playurl 会**按 cid（番剧按分集）**返回该视频自己的观看位置
   * （UGC: data.last_play_time；PGC: result.play_view_business_info.user_status.watch_progress），
   * 据此恢复即可 —— 番剧/影视多集续播正是靠这一点（每集各有一份续播点，无需跨集传参）。
   *
   * 优先级：路由进度（历史记录，更精确）> 服务端续播点。已在片尾的位置忽略，避免打开即结束。
   */
  private applyServerResumePoint(result: PlayUrlResult): void {
    if (this.initialProgress_ > 0) return;   // 路由已带进度，尊重它
    const ms: number = result.lastPlayTimeMs ?? 0;
    if (ms <= 0) return;
    const sec: number = ms / 1000;
    if (this.dur > 0 && sec >= this.dur - 3) {
      logInfo(`[VideoPlayer] 服务端续播点 ${sec}s 已到片尾，忽略`);
      return;
    }
    this.initialProgress_ = sec;
    logInfo(`[VideoPlayer] 服务端续播点恢复播放位置: ${sec}s (pgc=${this.isPgc_}, epId=${this.epId_})`);
  }

  private saveWatchHistory(): void {
    // ⭐ 放开 PGC（番剧 bvid 为空但 epId 有效）：投稿靠 bvid，PGC 靠 epId
    //   ⚠️ 阈值必须是 MIN_HEARTBEAT_PROGRESS_SEC 而不是 `> 0`：打开页面就退出时 ct≈0.4，
    //   `ct <= 0` 拦不住，floor 后变成 played_time=0 会把该视频/该季原有进度抹掉
    if ((!this.vi.bvid && !(this.isPgc_ && this.epId_ > 0)) || this.ct < MIN_HEARTBEAT_PROGRESS_SEC) return;

    // 获取Cookie
    const cookie = AppStorage.get<string>('biliCookie') || '';
    if (!cookie) {
      logWarn('[saveWatchHistory] 用户未登录，无法保存观看历史');
      return;
    }

    // ⭐ PGC（番剧/影视）：统一交给 reportPgcHeartbeat —— 它会先确保 seasonId 已解析。
    //   缺 sid 的 type=4 心跳会被 B 站**静默丢弃**（返回 code=0 但云端 progress 不变），
    //   这正是"播放时正常、退出后官方历史变 0"的原因，所以这里绝不能少 sid 就发。
    if (this.isPgc_ && this.epId_ > 0) {
      this.reportPgcHeartbeat(Math.floor(this.ct))
        .catch((e: Error) => logError(`[saveWatchHistory] PGC 进度上报异常: ${e.message}`));
      return;
    }

    // 获取aid（从VideoDetail中获取，或从bvid转换）
    // 注意：B站API需要aid而不是bvid
    let aid = this.vd?.aid || 0;
    if (!aid && this.vi.bvid) {
      // 如果没有aid，尝试从bvid转换（简化处理，实际应该调用API转换）
      logWarn('[saveWatchHistory] 缺少aid，无法上报到B站');
      return;
    }

    const item = new WatchHistoryItem();
    item.aid = aid;
    item.cid = this.vi.cid || 0;
    item.bvid = this.vi.bvid;
    item.title = this.vi.title || (this.vd?.title ?? '');
    item.coverUrl = this.vi.cover || '';
    item.playProgress = this.ct;
    item.totalDuration = this.dur;
    item.watchedAt = Math.floor(Date.now() / 1000); // B站使用秒级时间戳
    item.ownerName = this.vd?.owner?.name ?? '';
    // ⭐ PGC（番剧）历史记录：保存 epId/seasonId，恢复播放时走 PGC 路径（bvid 为空）
    item.epId = this.epId_;
    item.seasonId = this.seasonId_;

    // 设置Cookie并保存
    const helper = WatchHistoryHelper.getInstance();
    helper.setCookie(cookie);
    helper.saveWatchRecord(item);
  }

  /**
   * ⭐ 上报观看行为到B站推荐系统
   * 这是实现个性化推荐的关键！
   */
  private async reportWatchBehavior(): Promise<void> {
    // ⭐ PGC（番剧/影视）不走这里：本方法发的是 type=3（投稿）心跳，番剧分集的 bvid 带过去会被
    //   B 站按投稿记成一条 business="archive" 的**垃圾历史记录**（实测 aid=827109138 就是这样
    //   在历史里多出一条 progress=0 的 archive 项）。番剧进度由 reportPgcHeartbeat（type=4 + epid/sid）负责。
    if (this.isPgc_) return;
    // ⭐ 阈值守卫：快速划过 / 打开即退出时 ct≈0.4，floor 后 played_time=0 会把该视频原有进度抹掉
    if (!this.vi.bvid || this.ct < MIN_HEARTBEAT_PROGRESS_SEC || this.dur <= 0) return;

    try {
      const watchTime = Math.floor(this.ct);
      const duration = Math.floor(this.dur);
      const cid = this.vi.cid || 0;

      logInfo(`[行为上报] 视频播放结束: ${this.vi.bvid}, 观看${watchTime}秒/总长${duration}秒`);

      // 上报观看行为
      await reportWatch(this.vi.bvid, cid, duration, watchTime);

      logInfo('[行为上报] ✅ 观看行为上报成功');
    } catch (err) {
      logError(`[行为上报] ❌ 上报失败: ${err}`);
    }
  }

  // ⭐★ 提示弹层**转交**过来的返回（2026-09-24 真机实证，修"侧滑返回被吃掉"）：
  //   四个提示（seek / 音量 / 亮度 / 长按加速）走 bindPopup 弹层，而弹层默认挂在
  //   **应用窗口根节点层** ⇒ 它属于 OverlayManager 的返回键路由，会把返回键 / 系统侧滑返回
  //   **吃掉**（hilog：`OnBackPressed called` → `Overlay consumed backpressed event`；
  //   这正是官方架构指南《侧滑无法关闭弹窗》给的判据）。此时本页 `onBackPress()`
  //   **根本不会被调用** ⇒ 该退全屏的没退、该返回的没返回，要按两次返回。
  //   ⚠️ 只把弹层 `onWillDismiss` 设成 `false` 没用：那只能挡住"弹层自己关"，
  //      挡不住事件进 Overlay 路由（实测 hide popup 改由我们自己的 800ms 定时器收，
  //      但 `Overlay consumed backpressed event` 照旧）。
  //   ✅ 现在四个弹层用 `onWillDismiss` 的**函数形式**，官方文档保证侧滑/返回键/路由跳转/Esc
  //      都会以 `reason === DismissReason.PRESS_BACK` 回调进来，回调里调这里把返回转交页面。
  private ovBackTs_: number = 0;
  /**
   * ⭐ 输入弹层的表情面板控制器（见 CommentInputBarCtrl）：
   *    表情面板展开时，侧滑返回/返回键应**先收起面板**，而不是把整个输入弹层关掉。
   *    两个弹层各自一份（评论/回复 与 发弹幕 的输入栏是两个独立实例）。
   */
  private cmSheetEmoteCtrl: CommentInputBarCtrl = new CommentInputBarCtrl();
  private dmSheetEmoteCtrl: CommentInputBarCtrl = new CommentInputBarCtrl();
  private onOverlayBack_(): void {
    if (this.isLightsOff) { this.turnLightsOn(); return; }
    if (this.fs) { this.toggleFS(); return; }
    // ⚠️ 防重入：官方文档把"路由跳转"也算作 PRESS_BACK 的触发源 ⇒ 我们主动 router.back()
    //   有可能再打回同一个回调（双重返回）；800ms 内的重复调用一律丢弃。
    //   用户的"第二次滑动"此时页面早已退出，不会被误吞。
    const now: number = Date.now();
    if (now - this.ovBackTs_ < 800) return;
    this.ovBackTs_ = now;
    this.goBack();
  }

  onBackPress(): boolean {
    // ⭐ 关灯模式下，返回（含侧滑返回）改为开灯，不退出页面
    if (this.isLightsOff) {
      this.turnLightsOn();
      return true;
    }
    // 如果是全屏模式，退出全屏
    if (this.fs) {
      this.toggleFS();
      return true;
    }
    return false;
  }

  /** ⭐ 开灯：恢复背景与视频尺寸（关灯模式下通过返回/侧滑触发） */
  private turnLightsOn(): void {
    // ⭐ 与 toggleFS 同理：页面不发生跳转但要重新显示背景/视频 ⇒ 提示收掉，
    //   且与开灯动画同帧启动（不要在触摸被取消那一刻提前收，见 onTC）
    this.clearGestureHint_();
    this.clearLightBtnTimer();
    animateTo({ duration: 300, curve: Curve.Ease }, () => {
      this.isLightsOff = false;
      this.loBgScale = 1;
      this.loBgBlur = 0;
      this.loBgDim = 0;
    });
    // ⭐ 开灯：恢复状态栏（竖屏恢复，横屏仍隐藏）
    setTimeout(() => { this.manageSB(true); }, 50);
    // ⭐ 退出短视频：恢复用户设置的缩放模式（短视频内强制完整显示）
    try {
      if (this.av) this.av.videoScaleType = this.getVideoScaleType();
    } catch (e) {
      logWarn(`[ShortVideo] 恢复 scaleType 失败: ${errMsg(e)}`);
    }
  }

  private async restoreS() {
    if (!this.mw) return;
    try {
      // 横屏时全局隐藏状态栏，不恢复
      const isLandscape = AppStorage.get<boolean>('isLandscape') ?? false;
      if (!isLandscape && !this.sh_) {
        await this.mw.setWindowSystemBarEnable(['status', 'navigation']);
      }
      // 恢复用户在个性化设置中的屏幕方向锁定
      const lock = AppStorage.get<string>('screenOrientationLock') ?? '自动旋转';
      let orientation: window.Orientation;
      switch (lock) {
        case '锁定竖屏':
          orientation = window.Orientation.PORTRAIT;
          break;
        case '锁定横屏':
          // 允许横屏之间旋转
          orientation = window.Orientation.AUTO_ROTATION_LANDSCAPE;
          break;
        default:
          orientation = window.Orientation.AUTO_ROTATION;
          break;
      }
      await this.mw.setPreferredOrientation(orientation);
    } catch (e) { }
  }

  private async loadSM() {
    try {
      const pf = await preferences.getPreferences(this.getUIContext().getHostContext() as common.Context, 'VPS');
      this.sm = await pf.get('sm', 'auto') as string;
    } catch (e) { }
  }

  private async saveSM() {
    try {
      const pf = await preferences.getPreferences(this.getUIContext().getHostContext() as common.Context, 'VPS');
      await pf.put('sm', this.sm);
      await pf.flush();
    } catch (e) { }
  }

  private async loadD() {
    logInfo('[VPP] loadD 开始');
    // ⭐ PGC（番剧）不在此加载详情：vd.pages（分集列表）由 PGC 分支按季接口填充，
    //   若 bvid 非空（历史记录 PGC 场景）仍走 UGC 详情会覆盖 vd.pages → 选集按钮消失
    if (!this.vi.bvid || this.isPgc_) {
      logInfo('[VPP] loadD 跳过（PGC 或无 bvid）');
      return;
    }
    // 重置评论相关状态（切换视频时清除旧状态）
    this.expandedCommentIds.clear();
    this.savedScrollOffsetMap.clear();
    this.replyPageMap.clear();
    this.hasMoreRepliesMap.clear();
    this.loadingRepliesMap.clear();
    this.repliesVersion = 0;
    this.commentCursor = 0;
    this.commentDataSource.clear();
    this.ldd = true;
    this.floatBtnOpacity = 0;
    this.floatBtnScale = 0;
    this.floatBtnOffsetY = 12;
    try {
      const d = await getVideoDetail(this.vi.bvid);
      if (d) {
        this.vd = d;
        // ⭐ 预解码 up 主头像
        this.predecodeKeyImages();
        if (!this.vi.title && d.title) this.vi.title = d.title;
        if (!this.vi.cover && d.pic) this.vi.cover = d.pic;
        if (!this.vi.cid && d.pages && d.pages.length > 0) {
          this.vi.cid = d.pages[0].cid;
          // 只有在播放器未初始化且未在初始化中时才调用initP
          if (!this.av && !this.initPInProgress_) this.initP();
        }
        // ⭐ 根据当前cid确定分P索引
        if (d.pages && d.pages.length > 0) {
          const idx = d.pages.findIndex(p => p.cid === this.vi.cid);
          this.currentPageIndex = idx >= 0 ? idx : 0;
        }

        // ⭐ 初始化互动状态
        this.likeCount = d.stat.like;
        this.coinCount = d.stat.coin;
        this.favoriteCount = d.stat.favorite;

        // ⭐ 获取关注状态
        if (d.owner.mid) {
          this.isFollowed = await getFollowStatus(d.owner.mid);
          logInfo(`[关注状态] 已关注=${this.isFollowed}, UP主mid=${d.owner.mid}`);
        }

        // ⭐ 从视频详情中获取用户的互动状态（req_user字段）
        if (d.req_user) {
          this.isLiked = d.req_user.like || false;
          this.isCoined = (d.req_user.coin && d.req_user.coin > 0) || false;
          this.isFavorited = d.req_user.favorite || false;
          logInfo(`[互动状态] 已点赞=${this.isLiked}, 已投币=${this.isCoined}, 已收藏=${this.isFavorited}`);
        } else {
          // req_user未返回，尝试单独查询用户互动状态
          logInfo('[互动状态] req_user未返回，尝试单独查询...');
          const userStatus = await getVideoUserStatus(this.vi.bvid, d.aid);
          if (userStatus) {
            this.isLiked = userStatus.like;
            this.isCoined = userStatus.coin > 0;
            this.isFavorited = userStatus.favorite;
            logInfo(`[互动状态] 单独查询结果: 已点赞=${this.isLiked}, 已投币=${this.isCoined}, 已收藏=${this.isFavorited}`);
          } else {
            this.isLiked = false;
            this.isCoined = false;
            this.isFavorited = false;
            logInfo('[互动状态] 未获取到用户互动状态（可能未登录）');
          }
        }

        // ⭐ 延迟加载评论区：等页面入场动画完成后才加载
        this.pendingCommentAid = d.aid;

        // ⭐ 加载相关视频
        this.fetchRelatedVideos(d.bvid);
      }
    } catch (e) { }
    finally {
      this.ldd = false;
      logInfo('[VPP] loadD 完成');
    }
  }

  private scheduleFloatBtnFadeIn(): void {
    this.floatBtnOpacity = 0;
    this.floatBtnScale = 0;
    this.floatBtnOffsetY = 12;
    setTimeout(() => {
      if (!this.ldd) {
        this.floatBtnOpacity = 1;
        this.floatBtnScale = 1;
        this.floatBtnOffsetY = 0;
      }
    }, 500);
  }

  private async fetchRelatedVideos(bvid: string): Promise<void> {
    this.relatedLoading = true;
    try {
      const videos = await getRelatedVideos(bvid);
      this.relatedVideos = videos;
      this.relatedRenderCount = 10;  // ⭐ 新视频重置限量渲染
    } catch (e) {
      logError(`[RelatedVideos] 获取相关视频失败: ${e}`);
      this.relatedVideos = [];
      this.relatedRenderCount = 10;
    } finally {
      this.relatedLoading = false;
    }
  }

  // ═══════════════════════ 关灯短视频 feed（v2 沉浸胶囊版） ═══════════════════════

  /** 当前正在播的这条 → feed item */
  private shortCurrentItem(): ShortVideoFeedItem {
    return {
      bvid: this.vi.bvid,
      cid: this.vi.cid,
      aid: this.vd?.aid ?? 0,
      title: this.vd?.title || this.vi.title,
      cover: this.vi.cover,
      ownerName: this.vd?.owner?.name ?? this.vi.ownerName ?? '',
      ownerFace: this.vd?.owner?.face ?? this.vi.ownerFace ?? '',
      duration: this.vd?.duration ?? this.vi.duration ?? 0,
      playCount: this.vd?.stat?.view ?? this.vi.view ?? 0,
      danmakuCount: this.vd?.stat?.danmaku ?? 0,
      pubdate: this.vd?.pubdate ?? this.vi.pubdate ?? 0
    };
  }

  private shortFromRelated(r: RecommendItem): ShortVideoFeedItem {
    return {
      bvid: r.id,
      cid: r.cid,
      aid: r.aid,
      title: r.title,
      cover: r.coverUrl,
      ownerName: r.ownerName,
      ownerFace: r.ownerFace,
      duration: r.duration,
      playCount: r.playCount,
      danmakuCount: r.danmakuCount,
      pubdate: r.pubdate
    };
  }

  /** 进入关灯短视频：当前视频 + 已加载的相关推荐 */
  private buildShortFeed(): void {
    if (this.isPgc_ || !this.vi.bvid) return;
    const out: ShortVideoFeedItem[] = [];
    const seen: Set<string> = new Set<string>();
    const cur: ShortVideoFeedItem = this.shortCurrentItem();
    if (cur.bvid) {
      out.push(cur);
      seen.add(cur.bvid);
    }
    for (const r of this.relatedVideos) {
      if (!r.id || seen.has(r.id)) continue;
      seen.add(r.id);
      out.push(this.shortFromRelated(r));
    }
    this.shortItems = out;
    let idx: number = 0;
    for (let i = 0; i < out.length; i++) {
      if (out[i].bvid === this.vi.bvid) { idx = i; break; }
    }
    this.shortIndex = idx;
  }

  private enterShortVideoMode(): void {
    if (this.isPgc_ || !this.vi.bvid) return;
    this.buildShortFeed();
    this.shortDragY = 0;
    this.shortSettling = false;
    this.shortSwitching = false;
    this.shortCover = '';
    // 进入短视卡片：完整显示，不按用户的填充模式裁剪
    try {
      if (this.av) this.av.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
    } catch (e) {
      logWarn(`[ShortVideo] 设置 scaleType 失败: ${errMsg(e)}`);
    }
    this.prefetchShortNext();
    logInfo(`[ShortVideo] 进入: items=${this.shortItems.length}, index=${this.shortIndex}, bvid=${this.vi.bvid}`);
  }

  private shortItem(): ShortVideoFeedItem | undefined {
    return this.shortItems[this.shortIndex];
  }
  private shortTitle(): string {
    return this.vd?.title || this.vi.title || this.shortItem()?.title || '';
  }
  private shortDesc(): string {
    return this.vd?.desc || '';
  }
  private shortOwnerName(): string {
    return this.vd?.owner?.name || this.vi.ownerName || this.shortItem()?.ownerName || '';
  }
  private shortOwnerFace(): string {
    return this.vd?.owner?.face || this.vi.ownerFace || this.shortItem()?.ownerFace || '';
  }
  private shortOwnerInitial(): string {
    const n: string = this.shortOwnerName();
    return n.length > 0 ? n.substring(0, 1) : 'UP';
  }
  private shortTag1(): string {
    return this.vd?.tname || '';
  }
  private shortTag2(): string {
    return this.vd?.owner?.name || this.shortItem()?.ownerName || '';
  }
  private shortDuration(): number {
    return this.dur > 0 ? this.dur : (this.shortItem()?.duration ?? 0);
  }
  private shortMeta(): string {
    const it: ShortVideoFeedItem | undefined = this.shortItem();
    const pub: number = this.vd?.pubdate ?? it?.pubdate ?? 0;
    const view: number = this.vd?.stat?.view ?? it?.playCount ?? 0;
    const dm: number = this.vd?.stat?.danmaku ?? it?.danmakuCount ?? 0;
    const parts: string[] = [];
    if (pub > 0) parts.push(this.fmtTA(pub));
    if (view > 0) parts.push(`${this.fmtN(view)}播放`);
    if (dm > 0) parts.push(`${this.fmtN(dm)}弹幕`);
    return parts.join(' · ');
  }
  private shortTheme(): ResourceColor {
    return this.playerFollowTheme ? this.customThemeColor : ('#FB7299');
  }
  private shortNeighborItem(dir: number): ShortVideoFeedItem | undefined {
    const i: number = this.shortIndex + dir;
    return i >= 0 && i < this.shortItems.length ? this.shortItems[i] : undefined;
  }
  private shortNeighborCover(dir: number): string {
    return this.shortNeighborItem(dir)?.cover ?? '';
  }
  private shortNeighborTitle(dir: number): string {
    return this.shortNeighborItem(dir)?.title ?? '';
  }
  private shortNeighborOwner(dir: number): string {
    const it: ShortVideoFeedItem | undefined = this.shortNeighborItem(dir);
    return it && it.ownerName.length > 0 ? '@' + it.ownerName : '';
  }
  private shortNeighborMeta(dir: number): string {
    const it: ShortVideoFeedItem | undefined = this.shortNeighborItem(dir);
    if (!it) return '';
    const parts: string[] = [];
    if (it.playCount > 0) parts.push(`${this.fmtN(it.playCount)}播放`);
    if (it.danmakuCount > 0) parts.push(`${this.fmtN(it.danmakuCount)}弹幕`);
    return parts.join(' · ');
  }

  /** 粗略文本宽（vp）：数字 6 / 小数点 3 / 中文 11；用于胶囊自适应宽度 */
  private shortTextW(s: string): number {
    let w: number = 0;
    for (let i = 0; i < s.length; i++) {
      const c: string = s.charAt(i);
      if (c >= '0' && c <= '9') {
        w += 6;
      } else if (c === '.') {
        w += 3;
      } else {
        w += 11;
      }
    }
    return w;
  }
  private shortFollowW(): number {
    return this.isFollowed ? 26 : 40;
  }
  /** 左上 UP 胶囊自适应宽（只放头像+名字；关注已拆成独立的圆形玻璃按钮） */
  private shortUpW(): number {
    const nameW: number = Math.min(84, this.shortTextW(this.shortOwnerName()));
    return Math.max(96, Math.min(168, 8 + 30 + 7 + nameW));
  }
  /** 关注圆钮左边距：UP 胶囊容器（x=4, 宽 upW+16）之后再空 8 */
  private shortFollowX(): number {
    return 4 + this.shortUpW() + 16;
  }
  private shortStatItemW(kind: string): number {
    const count: number = kind === 'like' ? this.likeCount : (kind === 'coin' ? this.coinCount : this.favoriteCount);
    return 15 + 3 + this.shortTextW(this.fmtN(count)) + 12;
  }
  /** 右上胶囊自适应宽：三个条目 + 左右 4 */
  private shortStatsW(): number {
    return 8 + this.shortStatItemW('like') + this.shortStatItemW('coin') + this.shortStatItemW('fav');
  }
  /** 底部胶囊自适应宽：40+140+40+40+40 + 4×6 间距 + 左右 8 */
  private shortBottomW(): number {
    return 340;
  }
  private shortBottomX(): number {
    return Math.max(0, (this.cw - this.shortBottomW()) / 2);
  }

  /** 切条前落库：>=5s 才写，避免把已有进度抹成 0 */
  private flushShortProgress(): void {
    if (this.ct >= MIN_HEARTBEAT_PROGRESS_SEC) {
      this.saveWatchHistory();
      this.reportWatchBehavior().catch((e: Error): void => {
        logWarn(`[ShortVideo] 行为上报失败: ${e.message}`);
      });
      logInfo(`[ShortVideo] 切条前落库: ${this.vi.bvid}, ${Math.floor(this.ct)}s`);
    }
  }

  /** 预取下一条：详情 + playurl（playurl 缓存 60s，切过去通常还在有效期内） */
  private prefetchShortNext(): void {
    const idx: number = this.shortIndex + 1;
    if (idx >= this.shortItems.length) return;
    const next: ShortVideoFeedItem = this.shortItems[idx];
    if (!next.bvid) return;
    getVideoDetail(next.bvid).then((d: VideoDetail | null): void => {
      if (!d) return;
      const cur: ShortVideoFeedItem | undefined = this.shortItems[idx];
      if (!cur || cur.bvid !== next.bvid) return;
      cur.cid = d.cid && d.cid > 0 ? d.cid : ((d.pages && d.pages.length > 0) ? d.pages[0].cid : cur.cid);
      cur.aid = d.aid;
      cur.title = d.title || cur.title;
      cur.cover = d.pic || cur.cover;
      cur.ownerName = d.owner?.name ?? cur.ownerName;
      cur.ownerFace = d.owner?.face ?? cur.ownerFace;
      cur.duration = d.duration;
      cur.playCount = d.stat.view;
      cur.danmakuCount = d.stat.danmaku;
      cur.pubdate = d.pubdate;
      this.shortItems = this.shortItems.slice();
      if (cur.cid > 0) {
        getVideoPlayUrl(cur.bvid, cur.cid, this.qn).catch((e: Error): void => {
          logWarn(`[ShortVideo] 预取 playurl 失败: ${e.message}`);
        });
      }
    }).catch((e: Error): void => {
      logWarn(`[ShortVideo] 预取详情失败: ${e.message}`);
    });
  }

  private updateShortItem(target: number, d: VideoDetail): void {
    const it: ShortVideoFeedItem | undefined = this.shortItems[target];
    if (!it) return;
    it.cid = this.vi.cid;
    it.aid = d.aid;
    it.title = this.vi.title || it.title;
    it.cover = this.vi.cover || it.cover;
    it.ownerName = d.owner?.name ?? it.ownerName;
    it.ownerFace = d.owner?.face ?? it.ownerFace;
    it.duration = d.duration;
    it.playCount = d.stat.view;
    it.danmakuCount = d.stat.danmaku;
    it.pubdate = d.pubdate;
    this.shortItems = this.shortItems.slice();
  }

  /** 列表不够时，按最后一条再拉一页相关推荐 */
  private async ensureShortFeedAhead(): Promise<boolean> {
    if (this.shortIndex + 1 < this.shortItems.length) return true;
    if (this.shortFetching) return false;
    const last: ShortVideoFeedItem | undefined = this.shortItems.length > 0
      ? this.shortItems[this.shortItems.length - 1] : undefined;
    if (!last || !last.bvid) return false;
    this.shortFetching = true;
    try {
      const list: RecommendItem[] = await getRelatedVideos(last.bvid);
      const seen: Set<string> = new Set<string>();
      for (const it of this.shortItems) seen.add(it.bvid);
      const add: ShortVideoFeedItem[] = [];
      for (const r of list) {
        if (!r.id || seen.has(r.id)) continue;
        seen.add(r.id);
        add.push(this.shortFromRelated(r));
      }
      if (add.length > 0) {
        this.shortItems = this.shortItems.concat(add);
        logInfo(`[ShortVideo] 追加相关推荐: +${add.length}, 共 ${this.shortItems.length}`);
      }
      return this.shortIndex + 1 < this.shortItems.length;
    } catch (e) {
      logError(`[ShortVideo] 相关推荐获取失败: ${errMsg(e)}`);
      return false;
    } finally {
      this.shortFetching = false;
    }
  }

  /**
   * 切到 feed 的第 target 条。
   * 顺序：落库 → release → 等上一次 initP 收尾 → 第二次 release → 换 vi → 详情 → initP。
   * 第二次 release 是为了收掉"上一次 initP 在等待期间又建出来的播放器"。
   */
  private async loadShortItem(target: number): Promise<void> {
    if (target < 0 || target >= this.shortItems.length) return;
    const item: ShortVideoFeedItem = this.shortItems[target];
    if (!item || !item.bvid) return;
    if (this.vi.bvid === item.bvid && this.shortIndex === target) return;

    const gen: number = ++this.shortGen;
    this.flushShortProgress();

    this.shortIndex = target;
    this.shortDragY = 0;
    this.shortSwitching = true;
    this.shortCover = item.cover;
    this.vd = null;
    this.vi = { bvid: item.bvid, cid: item.cid, title: item.title, cover: item.cover };
    this.likeCount = 0;
    this.coinCount = 0;
    this.favoriteCount = 0;
    this.isLiked = false;
    this.isCoined = false;
    this.isFavorited = false;
    this.isFollowed = false;
    this.ct = 0;
    this.dur = 0;
    this.lastHeartbeatTime = 0;
    this.initialProgress_ = 0;
    this.err = '';
    this.ld = true;
    this.currentPageIndex = 0;
    this.commentCursor = 0;
    this.commentRenderCount = 20;
    this.commentDataSource.clear();
    this.pendingCommentAid = 0;
    this.shortCommentsAid = 0;
    this.expandedCommentIds.clear();
    this.savedScrollOffsetMap.clear();
    this.replyPageMap.clear();
    this.hasMoreRepliesMap.clear();
    this.loadingRepliesMap.clear();
    this.repliesVersion = 0;

    this.release();
    LiveViewHelper.end();

    // initPInProgress_ 会让新的 initP 直接 return —— 等旧的一轮收尾
    for (let i = 0; i < 150 && this.initPInProgress_; i++) {
      await new Promise<void>((r: () => void): void => {
        setTimeout(r, 20);
      });
      if (gen !== this.shortGen) return;
    }
    this.release();

    const d: VideoDetail | null = await getVideoDetail(item.bvid);
    if (gen !== this.shortGen) return;
    if (!d) {
      this.err = '获取视频详情失败';
      this.ld = false;
      logWarn(`[ShortVideo] 详情为空: ${item.bvid}`);
      return;
    }

    this.vd = d;
    this.vi.cid = d.cid && d.cid > 0 ? d.cid : ((d.pages && d.pages.length > 0) ? d.pages[0].cid : item.cid);
    this.vi.title = d.title || item.title;
    this.vi.cover = d.pic || item.cover;
    this.likeCount = d.stat.like;
    this.coinCount = d.stat.coin;
    this.favoriteCount = d.stat.favorite;
    this.isLiked = d.req_user?.like ?? false;
    this.isCoined = (d.req_user?.coin ?? 0) > 0;
    this.isFavorited = d.req_user?.favorite ?? false;
    this.pendingCommentAid = d.aid;

    if (!d.req_user) {
      const st = await getVideoUserStatus(this.vi.bvid, d.aid);
      if (gen !== this.shortGen) return;
      if (st) {
        this.isLiked = st.like;
        this.isCoined = st.coin > 0;
        this.isFavorited = st.favorite;
      }
    }
    if (d.owner && d.owner.mid > 0) {
      const followed: boolean = await getFollowStatus(d.owner.mid);
      if (gen !== this.shortGen) return;
      this.isFollowed = followed;
    }

    this.updateShortItem(target, d);
    this.fetchRelatedVideos(d.bvid);
    this.prefetchShortNext();

    await this.initP();
    logInfo(`[ShortVideo] 换源完成: index=${target}, bvid=${item.bvid}, cid=${this.vi.cid}`);
  }

  private settleShortDrag(target: number): void {
    this.shortSettling = true;
    animateTo({ duration: 240, curve: Curve.EaseOut }, (): void => {
      this.shortDragY = target;
    });
    setTimeout((): void => {
      this.shortSettling = false;
    }, 255);
  }

  /** 手势松手：越过阈值就滑出并换源，否则回弹 */
  private async finishShortDrag(): Promise<void> {
    const h: number = this.shortCardH();
    const y: number = this.shortDragY;
    if (Math.abs(y) < h * 0.18) {
      this.settleShortDrag(0);
      return;
    }
    const dir: number = y < 0 ? 1 : -1;
    if (dir === 1) {
      const ok: boolean = await this.ensureShortFeedAhead();
      if (!ok) {
        this.settleShortDrag(0);
        return;
      }
    }
    const target: number = this.shortIndex + dir;
    if (target < 0 || target >= this.shortItems.length) {
      this.settleShortDrag(0);
      return;
    }
    this.shortSettling = true;
    animateTo({ duration: 250, curve: Curve.EaseOut }, (): void => {
      this.shortDragY = -dir * h;
    });
    setTimeout((): void => {
      this.shortDragY = 0;
      this.shortSettling = false;
      this.loadShortItem(target);
    }, 265);
  }

  /** 评论区：开灯 + 切到评论面板 + 首次加载评论 */
  private openShortComments(): void {
    const aid: number = this.pendingCommentAid > 0 ? this.pendingCommentAid : (this.vd?.aid ?? 0);
    this.switchTab(1);
    this.turnLightsOn();
    if (aid > 0 && this.shortCommentsAid !== aid && this.commentDataSource.totalCount() === 0) {
      this.shortCommentsAid = aid;
      this.pendingCommentAid = 0;
      this.loadC(aid);
    }
  }

  /**
   * 胶囊内的触摸分发（照 yunjianBJ 笔记页工具栏：玻璃收触摸 → 内容 onTouch 只记坐标、
   * 不消费 → HDS 材质拿到按压形变/光斑；Up 时按落点分发动作）。
   * ⛔ 不要在内容按钮上挂 onClick：按钮吃掉触摸，HDS 就收不到，形变/光效全没。
   */
  private onShortUpTouch(e: TouchEvent): void {
    if (e.type === TouchType.Down || e.type === TouchType.Move) {
      if (e.touches.length > 0) this.shortTouchX = e.touches[0].x;
      return;
    }
    if (e.type !== TouchType.Up) return;
    logInfo(`[ShortVideo] 左上胶囊点击 x=${this.shortTouchX.toFixed(1)}，关注=${this.isFollowed}`);
    this.toggleFollow();
  }

  private onShortStatsTouch(e: TouchEvent): void {
    if (e.type === TouchType.Down || e.type === TouchType.Move) {
      if (e.touches.length > 0) this.shortTouchX = e.touches[0].x;
      return;
    }
    if (e.type !== TouchType.Up) return;
    const likeW: number = this.shortStatItemW('like');
    const coinW: number = this.shortStatItemW('coin');
    const x: number = this.shortTouchX;
    logInfo(`[ShortVideo] 右上胶囊点击 x=${x.toFixed(1)} likeW=${likeW} coinW=${coinW}`);
    if (x < 4 + likeW) {
      this.toggleLike();
    } else if (x < 4 + likeW + coinW) {
      this.toggleCoin(1);
    } else {
      this.toggleFavorite();
    }
  }

  private onShortBottomTouch(e: TouchEvent): void {
    if (e.type === TouchType.Down || e.type === TouchType.Move) {
      if (e.touches.length > 0) this.shortTouchX = e.touches[0].x;
      return;
    }
    if (e.type !== TouchType.Up) return;
    const x: number = this.shortTouchX;
    logInfo(`[ShortVideo] 底部胶囊点击 x=${x.toFixed(1)}`);
    if (x < 51) {
      this.turnLightsOn();
    } else if (x < 197) {
      this.showDanmakuSheet = true;
    } else if (x < 243) {
      this.toggleDanmaku();
    } else if (x < 289) {
      this.openShortComments();
    } else {
      this.toggleFS();
    }
  }

  private onRelatedVideoClick(item: RecommendItem): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/VideoPlayerPage',
      params: {
        bvid: item.id,
        aid: item.aid,
        cid: item.cid,
        title: item.title,
        ownerName: item.ownerName,
        duration: item.duration,
        pubdate: item.pubdate,
        view: item.playCount,
        coverUrl: item.coverUrl
      }
    }).catch((err: Error) => { logError(`跳转相关视频失败: ${err.message}`); });
  }

  private async loadC(aid: number) {
    this.commentRenderCount = 20;  // ⭐ 新视频重置评论区限量渲染
    this.ldc = true;
    this.rateLimited = false;
    try {
      // 映射排序模式：commentSort=2(最热)→mode=3, commentSort=1(最新)→mode=2
      const mode: number = this.commentSort === 2 ? 3 : 2;
      logInfo(`[loadC] 开始加载评论: aid=${aid}, cursor=${this.commentCursor}, mode=${mode}`);
      const result = await getVideoComments(aid, this.commentCursor, 20, mode);
      logInfo(`[loadC] 评论加载结果: ${result ? (result.comments ? result.comments.length : 0) : 0}条`);
      if (result === null) {
        // 被限流，保留 hm 为 true 以便用户重试
        logWarn('[loadC] API限流，标记限流状态');
        this.rateLimited = true;
        try {
          this.getUIContext().getPromptAction().showToast({ message: '评论被限流，请等待片刻后重试', duration: 2000 });
        } catch (err) {
          logWarn(`showToast 异常: ${errMsg(err)}`);
        }
      } else if (result.comments && result.comments.length > 0) {
        // 转换为 ObservableComment
        const observableComments = result.comments.map(item => ObservableComment.from(item));

        if (this.commentCursor === 0) {
          this.commentDataSource.setComments(observableComments);
        } else {
          this.commentDataSource.appendComments(observableComments);
        }

        this.commentCursor = result.nextCursor;
        this.hm = !result.isEnd;
        // ⭐ 从消息通知跳转时，滚动到指定评论
        if (this.commentRootId_ > 0) {
          this.scrollToTargetComment();
        }
        // ⭐ 逐个预解码评论头像（间隔 50ms），避免 30 张并发 CPU 软解导致的掉帧
        // 旋转期间跳过（rotationInProgress=true），避免与窗口旋转抢解码资源
        if (!this.rotationInProgress) {
          for (const c of observableComments) {
            if (c.member?.avatar) {
              predecodeImage(imageUrlResize(c.member.avatar, 48));
            }
            await new Promise<void>(r => setTimeout(r, 50));
          }
        }
      } else {
        this.hm = false;
        // 如果是第一页且没有评论，可能是Cookie失效或API错误
        if (this.commentCursor === 0) {
          logWarn('[loadC] 第一页评论为空，可能Cookie失效或API限流');
        }
      }
    } catch (e) {
      logError(`[loadC] 加载评论异常: ${e}`);
      // 加载失败时，如果是第一页，提示用户
      if (this.commentCursor === 0) {
        try {
          this.getUIContext().getPromptAction().showToast({ message: '评论加载失败，请检查网络或重新登录', duration: 2000 });
        } catch (err) {
          logWarn(`showToast 异常: ${errMsg(err)}`);
        }
      }
    }
    finally {
      this.ldc = false;
    }
  }

  private async scrollToTargetComment(): Promise<void> {
    if (this.commentRootId_ <= 0) return;
    // 先在当前已加载的评论中查找
    let index = this.commentDataSource.findCommentIndexByRoot(this.commentRootId_);
    if (index < 0 && this.commentSecondaryId_ > 0) {
      index = this.commentDataSource.findCommentIndex(this.commentSecondaryId_);
    }
    if (index >= 0) {
      logInfo(`[scrollToTargetComment] 在当前页找到评论 rootId=${this.commentRootId_}, index=${index}`);
      this.commentScroller.scrollToIndex(index, false, ScrollAlign.CENTER);
      this.commentRootId_ = 0;
      this.commentSecondaryId_ = 0;
      return;
    }
    // 当前页未找到，切换到"最新"排序重新加载评论（消息通知中的回复通常在最新排序的前几页）
    if (this.vd && this.vd.aid && this.commentSort !== 1) {
      logInfo(`[scrollToTargetComment] 当前页未找到，切换到最新排序重新加载 rootId=${this.commentRootId_}`);
      this.commentSort = 1;  // 1 = 最新排序
      this.commentCursor = 0;
      this.commentDataSource.clear();
      await this.loadC(this.vd.aid);
      // 加载完后再查找
      index = this.commentDataSource.findCommentIndexByRoot(this.commentRootId_);
      if (index < 0 && this.commentSecondaryId_ > 0) {
        index = this.commentDataSource.findCommentIndex(this.commentSecondaryId_);
      }
      if (index >= 0) {
        logInfo(`[scrollToTargetComment] 最新排序找到评论 index=${index}`);
        this.commentScroller.scrollToIndex(index, false, ScrollAlign.CENTER);
        this.commentRootId_ = 0;
        this.commentSecondaryId_ = 0;
        return;
      }
      // 最新排序第一页也没找到，继续加载更多页
      for (let page = 0; page < 5; page++) {
        if (!this.hm || this.ldc) break;
        await this.loadMC();
        index = this.commentDataSource.findCommentIndexByRoot(this.commentRootId_);
        if (index < 0 && this.commentSecondaryId_ > 0) {
          index = this.commentDataSource.findCommentIndex(this.commentSecondaryId_);
        }
        if (index >= 0) {
          logInfo(`[scrollToTargetComment] 最新排序第${page + 2}页找到评论 index=${index}`);
          this.commentScroller.scrollToIndex(index, false, ScrollAlign.CENTER);
          this.commentRootId_ = 0;
          this.commentSecondaryId_ = 0;
          return;
        }
      }
    }
    logInfo(`[scrollToTargetComment] 未能定位评论 rootId=${this.commentRootId_}, secId=${this.commentSecondaryId_}`);
  }

  private async loadMC() {
    if (!this.hm || this.ldc || !this.vd || this.isLoadingMore) return;
    this.isLoadingMore = true;
    // 映射排序模式
    const mode: number = this.commentSort === 2 ? 3 : 2;
    try {
      logInfo(`[loadMC] 加载更多评论: aid=${this.vd.aid}, cursor=${this.commentCursor}, mode=${mode}`);
      const result = await getVideoComments(this.vd.aid, this.commentCursor, 20, mode);
      logInfo(`[loadMC] 更多评论结果: ${result ? (result.comments ? result.comments.length : 0) : 0}条`);
      if (result === null) {
        // 限流，hm 保持不变，下次可继续重试
        logWarn('[loadMC] 被限流');
        this.rateLimited = true;
        try {
          this.getUIContext().getPromptAction().showToast({ message: '加载更多评论被限流，请稍后重试', duration: 1500 });
        } catch (err) {
          logWarn(`showToast 异常: ${errMsg(err)}`);
        }
      } else if (result.comments && result.comments.length > 0) {
        // 转换为 ObservableComment 并追加
        const observableComments = result.comments.map(item => ObservableComment.from(item));
        this.commentDataSource.appendComments(observableComments);
        this.commentRenderCount += observableComments.length;  // 上拉加载更多后同步放开渲染配额，新评论立即进入 ForEach 渲染范围
        this.commentCursor = result.nextCursor;
        this.hm = !result.isEnd;
        this.rateLimited = false;
      } else {
        this.hm = false;
      }
    } catch (e) {
      logError(`[loadMC] 加载更多评论异常: ${e}`);
    } finally {
      this.isLoadingMore = false;
    }
  }

  // ⭐ 切换评论排序（最热/最新），带 300ms 防抖防止快速点击触发限流
  private switchCommentSort(sort: number) {
    if (sort === this.commentSort) return;
    if (this.sortChangeTimer !== undefined) {
      clearTimeout(this.sortChangeTimer);
    }
    this.sortChangeTimer = setTimeout(() => {
      this.sortChangeTimer = undefined;
      this._doSwitchCommentSort(sort);
    }, 300);
  }

  private _doSwitchCommentSort(sort: number) {
    logInfo(`[switchCommentSort] 排序切换: ${this.commentSort} → ${sort}`);
    this.commentSort = sort;
    this.commentCursor = 0;
    this.expandedCommentIds.clear();
    this.savedScrollOffsetMap.clear();
    this.repliesVersion++;
    this.sortBarVersion++;
    this.commentDataSource.clear();
    if (this.vd) {
      this.loadC(this.vd.aid);
    }
  }

  /** ⭐ 评论区限量渲染：只返回前 commentRenderCount 条（与相关推荐同款思路，负载与总长解耦） */
  private commentSlice(): ObservableComment[] {
    const total = this.commentDataSource.totalCount();
    const n = Math.min(this.commentRenderCount, total);
    const out: ObservableComment[] = [];
    for (let i = 0; i < n; i++) {
      out.push(this.commentDataSource.getData(i));
    }
    return out;
  }

  // ⭐ 展开评论 — 只加载第一页回复，后续通过"展开更多回复"按钮分页加载
  // 避免一次性循环加载所有页导致被 B站 API 限流
  private async expandCommentAndLoadFirstPage(comment: ObservableComment) {
    logInfo('[expandComment] 开始执行（仅加载第一页）');
    const rpid = comment.rpid;

    // ⭐ 记录当前滚动位置到该评论的专属位置映射中
    try {
      const offset = this.commentScroller.currentOffset();
      this.savedScrollOffsetMap.set(rpid, offset?.yOffset ?? 0);
    } catch (e) {
      this.savedScrollOffsetMap.set(rpid, 0);
    }
    logInfo(`[expandComment] 记录评论 ${rpid} 的展开前位置: ${this.savedScrollOffsetMap.get(rpid)}`);

    const existingReplies = comment.replies || [];
    const rcount = comment.rcount || 0;

    // 如果总回复数 <= 现有回复数，不需要加载，直接展开
    if (rcount <= existingReplies.length) {
      logInfo('[expandComment] 无需加载更多');
      comment.hasMoreReplies = false;
      this._addToExpanded(rpid);
      return;
    }

    // 检查是否正在加载
    if (comment.loadingReplies || !this.vd) return;

    comment.loadingReplies = true;
    try {
      // ⭐ 只加载第一页，不再循环加载全部
      logInfo('[expandComment] 加载第1页回复');
      const replies = await getCommentReplies(this.vd.aid, rpid, 1, 20);
      logInfo(`[expandComment] 第1页返回${replies ? replies.length : 0}条`);

      if (replies && replies.length > 0) {
        const commentIndex = this.commentDataSource.findCommentIndex(rpid);
        if (commentIndex !== -1) {
          const oldComment = this.commentDataSource.getData(commentIndex);
          oldComment.updateReplies(replies);
          oldComment.replyPage = 1;
          // ⭐ 如果还有更多页，标记 hasMoreReplies=true，让"展开更多回复"按钮出现
          oldComment.hasMoreReplies = replies.length >= 20 && rcount > replies.length;

          this.commentDataSource.notifyDataChange(commentIndex);
          this._addToExpanded(rpid);
        }
      } else {
        comment.hasMoreReplies = false;
      }
    } catch (err) {
      logError(`[expandComment] 加载失败: ${err}`);
      comment.hasMoreReplies = false;
    } finally {
      comment.loadingReplies = false;
    }
  }

  // ⭐ 将评论ID加入展开集合
  private _addToExpanded(rpid: number): void {
    const newSet = new Set<number>(this.expandedCommentIds);
    newSet.add(rpid);
    this.expandedCommentIds = newSet;
    this.repliesVersion++;
  }

  // ⭐ 统一的收起评论逻辑：从展开集合中移除，并恢复该评论展开前记录的滚动位置
  private _doRemoveExpandedComment(rpid: number): void {
    if (!this.expandedCommentIds.has(rpid)) return;
    logInfo(`[_doRemoveExpandedComment] 收起评论 ${rpid}`);
    // 恢复该评论展开时记录的位置
    const savedOffset = this.savedScrollOffsetMap.get(rpid);
    if (savedOffset !== undefined) {
      try {
        this.commentScroller.scrollTo({ xOffset: 0, yOffset: savedOffset, animation: { duration: 300 } });
      } catch (e) {
        this.commentScroller.scrollBy(0, savedOffset);
      }
    }
    this.savedScrollOffsetMap.delete(rpid);
    const newSet = new Set<number>(this.expandedCommentIds);
    newSet.delete(rpid);
    this.expandedCommentIds = newSet;
    this.repliesVersion++;
  }

  // 加载更多回复
  private async loadMoreReplies(comment: ObservableComment) {
    logInfo('[loadMoreReplies] 开始执行');
    if (!this.vd) {
      logWarn('[loadMoreReplies] vd为空');
      return;
    }
    const rpid = comment.rpid;
    logInfo(`[loadMoreReplies] rpid=${rpid}`);

    // 检查是否正在加载
    if (comment.loadingReplies) {
      logInfo('[loadMoreReplies] 正在加载中');
      return;
    }

    // 获取当前页码
    let page = comment.replyPage || 0;

    // 如果是第一次加载（page=0），加载第1页
    // 否则加载下一页
    if (page === 0) {
      page = 1;
    } else {
      page++;
    }

    logInfo(`[loadMoreReplies] 加载第${page}页`);

    // 设置加载状态
    comment.loadingReplies = true;

    try {
      logInfo(`[loadMoreReplies] 调用API: aid=${this.vd.aid}, rpid=${rpid}, page=${page}`);
      const replies = await getCommentReplies(this.vd.aid, rpid, page, 20);
      logInfo(`[loadMoreReplies] API返回${replies ? replies.length : 0}条`);

      if (replies && replies.length > 0) {
        // 找到对应评论并追加回复
        const commentIndex = this.commentDataSource.findCommentIndex(rpid);
        logInfo(`[loadMoreReplies] 评论索引=${commentIndex}`);
        if (commentIndex !== -1) {
          const oldComment = this.commentDataSource.getData(commentIndex);

          // 合并新旧回复并更新
          const existingReplyIds = new Set(oldComment.replies.map(r => r.rpid));
          const newRepliesToAdd = replies.filter(r => !existingReplyIds.has(r.rpid));
          const allReplies = [...oldComment.replies.map(r => r.toCommentItem()), ...newRepliesToAdd];
          oldComment.updateReplies(allReplies);
          oldComment.replyPage = page;
          oldComment.hasMoreReplies = replies.length >= 20;

          // 通知数据变化
          this.commentDataSource.notifyDataChange(commentIndex);
          this.repliesVersion++;
        }
      } else {
        comment.hasMoreReplies = false;
      }
    } catch (e) {
      logError('加载回复失败:', e);
    } finally {
      comment.loadingReplies = false;
    }
  }

  switchTab = (i: number) => {
    // 如果正在滑动手势中，切换到新的tab时需要重置手势状态
    if (this.isSwiping) {
      this.isSwiping = false;
      this.swipeProgress = 0;
    }
    // 先更新tabSelIdx — SegmentButton用自己的内置动画驱动指示器过渡
    // 不要放入animateTo，否则组件会跳过内置动画导致指示器跳变
    this.tabSelIdx = [i];
    this.getUIContext()?.animateTo({ duration: 350, curve: Curve.FastOutSlowIn }, () => {
      this.at = i;
    });
    // 切换到非评论tab时，动画恢复视频大小
    if (i !== 1 && this.vidShrink > 0) {
      this.animateVidShrink(0);
    }
  }

  // 详情卡片水平偏移量（百分比）
  getDetailOffset = (): string => {
    if (this.isSwiping) {
      // 跟随手指：at=0时从0%→-100%，at=1时从-100%→0%
      const base = this.at === 0 ? 0 : -100;
      return `${base + this.swipeProgress * 100}%`;
    }
    return this.at === 0 ? '0%' : '-100%';
  }

  // 评论区水平偏移量（百分比）
  getCommentOffset = (): string => {
    if (this.isSwiping) {
      // 跟随手指：at=0时从100%→0%，at=1时从0%→100%
      const base = this.at === 1 ? 0 : 100;
      return `${base + this.swipeProgress * 100}%`;
    }
    return this.at === 1 ? '0%' : '100%';
  }

  // 获取切换tab的容器宽度，用于将offsetX归一化到[-1, 1]
  getLayoutWidth = (): number => {
    // 竖屏典型宽度（父容器padding左右各12）
    return 360;
  }

  private clrT() {
    [this.ct_, this.gt_, this.lt_, this.dt_, this.bt, this.ubt, this.rhtm,
      this.rt_, this.sti_].forEach(t => { if (t !== -1) clearTimeout(t) });
    this.ct_ = this.gt_ = this.lt_ = this.dt_ = this.bt = this.ubt = this.rhtm =
      this.rt_ = this.sti_ = -1;
  }

  private schedAH() {
    if (this.ct_ !== -1) clearTimeout(this.ct_);
    if (this.cv && !this.lk && !this.ip) this.ct_ = setTimeout(() => {
      if (!this.lk && !this.ip) { this.cv = false; this.ct_ = -1; }
    }, 15000);
  }

  private resetCT() {
    if (this.lk || !this.cv) return;
    if (this.ct_ !== -1) { clearTimeout(this.ct_); this.ct_ = -1; }
    this.schedAH();
  }

  private showCR() {
    if (this.lk) return;
    // 取消任何待处理的延迟隐藏
    this.cancelDelayHide();
    if (!this.cv) this.cv = true;
    if (this.ct_ !== -1) { clearTimeout(this.ct_); this.ct_ = -1; }
    this.schedAH();
  }

  // 取消延迟隐藏控制栏（按钮回调调用，阻止onTU中的延迟隐藏生效）
  private cancelDelayHide() {
    if (this.hc_ !== -1) { clearTimeout(this.hc_); this.hc_ = -1; }
  }

  /**
   * ⭐ 进度条交互回调（由 VideoControls 的 Slider 在 onChange 的 Begin/Moving/End/Click
   * 以及 onTouch 的 Cancel 上调用）。约定：`active=true` 表示"交互进行中"，`false` 表示"交互结束"。
   *
   * `active=true`（Begin / Moving）：
   * 1. 冻结 ct：进度条由独立组件持有，原先拖动时页面侧 sk_ 仍为 false，
   *    timeUpdate（约 1 次/秒）会把 ct 写回真实播放位置 —— 而 Slider 的 value 就绑在 ct 上，
   *    于是拇指被"拉回"、时间数字跳动。
   * 2. 置 ip：抑制 schedAH() 的 15 秒自动隐藏，否则长视频上连续拖动时控制栏会在手指底下消失。
   *
   * `active=false`（End / Click，以及 onTouch 的 Cancel）：
   * 3. 提交**一次** seek。原先 Click 与 End 都调 seekTo → 一次点击发起两次 seek；
   *    现在用"同一目标只提交一次"去重（点滑轨会依次触发 Begin/Click/End）。
   * 4. 锚点取**交互开始那一刻的 ct**（不是回调传进来的值）：点击滑轨时 Begin 的 value 可能
   *    已经是跳转后的新值，用它当锚点会把"位移判定"算成没动，从而吞掉提交。
   *
   * ⚠️ 不要改回"用 onTouch 的 Up 提交"：官方事件模型中触摸事件派发先于手势识别回调，
   *    点击滑轨时 Up 早于 Slider 自身的 click-jump，那时 value 还是旧值，提交必然失效（已实测复现）。
   */
  private onSeekBarInteract_ = (active: boolean, time: number): void => {
    // ⭐ 开启/续期"进度条触摸窗口"：从第一次上报一直到手指抬起（由 onVT 在 Up/Cancel 时撤销）。
    //   提交（End/Click）早于 Up，所以这里不能只依赖 sliderDragging_ —— 详见 seekBarTouch_ 字段注释。
    this.seekBarTouch_ = true;
    if (this.seekBarTouchTimer_ !== -1) clearTimeout(this.seekBarTouchTimer_);
    this.seekBarTouchTimer_ = setTimeout(() => {
      this.seekBarTouch_ = false;
      this.seekBarTouchTimer_ = -1;
    }, 1500);

    // ⭐ 拖动/点击底部进度条也弹「时间 + 小进度条」提示，与视频区手势 seek 的手感保持一致：
    //   - 拖动期间每条 Moving 上报都会续期（与手势路径同频，sGH 本来就是这么用的），
    //     所以整段拖动期间常驻，松手后 800ms 自然淡出；
    //   - 点击滑轨时 End/Click 那次上报会让提示闪一下，确认"已跳到目标"；
    //   - 时长未知时不弹（与手势路径的 dur<=0 守卫一致），避免"拖了像没反应"。
    if (this.dur > 0) {
      this.sGH(this.formatDuration(Math.round(time)), time / this.dur, 'seek');
      // ⭐ 缩略图预览：与上面的提示胶囊同一套显隐（sGH 超时隐藏时会一并隐藏）
      this.updateSeekThumb_(time);
    }

    if (active) {
      // Moving 阶段会以 ~90 次/秒高频上报，已在交互中就直接返回，避免重复写状态
      if (this.sliderDragging_) return;
      this.sliderDragging_ = true;
      this.seekDragAnchor_ = this.ct;   // ⭐ 锚点 = 交互开始前的位置
      // ⭐ 提示胶囊右侧"相对位移"的起点（= 拖动锚点；必须在 sGH 之前写好，否则首帧会拿旧值算）
      this.ghb = this.seekDragAnchor_;
      this.lastSeekBarCommitV_ = -1;    // 新手势：清空"已提交目标"去重记录
      this.sk_ = true;    // 冻结 ct，阻止 timeUpdate 回写
      this.ip = true;     // 抑制自动隐藏
      if (this.ct_ !== -1) { clearTimeout(this.ct_); this.ct_ = -1; }
      this.cancelDelayHide();
      return;
    }
    // ---- 交互结束 ----
    // ⚠️ 这里**只有"本次没有提交 seek"才允许自己解冻 sk_**：若刚提交的 seek 仍在途（sg_ 为 true），
    //   sk_ 归 seek() 的 finally 复位。否则 timeUpdate 会立刻把 ct 写回**旧播放位置** ——
    //   Slider 的 value 与时间文本随之回退，用户看到的现象是"点了/拖了进度条，时间没有跳到目标"。
    if (Math.abs(time - this.lastSeekBarCommitV_) < 0.25) {
      // 同一手势的重复上报（Click 之后紧跟 End，值相同）→ 只收尾，不再 seek
      this.sliderDragging_ = false;
      this.ip = false;
      if (!this.sg_) this.sk_ = false;
      if (this.cv) this.resetCT();
      return;
    }
    const anchor = this.seekDragAnchor_ >= 0 ? this.seekDragAnchor_ : this.ct;
    this.seekDragAnchor_ = -1;
    this.sliderDragging_ = false;
    this.ip = false;
    // 位置没变（点了一下滑块但没移动）→ 不提交，避免无意义的 seek + 画面闪一下
    if (Math.abs(time - anchor) < 0.25) {
      if (!this.sg_) this.sk_ = false;
      if (this.cv) this.resetCT();
      return;
    }
    this.lastSeekBarCommitV_ = time;
    // 播放器未就绪时 seek() 会直接 return（不会进入它的 finally 复位 sk_）→ 这里兜底解冻，
    // 否则 sk_ 永久为 true、ct 被冻结、进度条彻底不刷新
    if (!this.av) {
      if (!this.sg_) this.sk_ = false;
      if (this.cv) this.resetCT();
      return;
    }
    // 提交一次；seek 内部会接管 sk_ 并在完成后复位
    this.seek(time, false, true);
    if (this.cv) this.resetCT();
  }

  // ⭐ 镜像切换回调（VideoControls 按钮点击触发）：取消 200ms 延迟隐藏 + 持久化镜像布局状态
  private async onMirrorToggle(): Promise<void> {
    this.cancelDelayHide();
    try {
      const pf = await preferences.getPreferences(this.getUIContext().getHostContext() as common.Context, 'VPS');
      await pf.put('mirrorControls', this.isMirrorControls);
      await pf.flush();
    } catch (e) {
      logError('保存镜像布局状态失败', e);
    }
  }

  // ⭐ 加载控制栏镜像状态（从Preferences读取，默认标准布局）
  private async loadMirrorControlsState(): Promise<void> {
    try {
      const pf = await preferences.getPreferences(this.getUIContext().getHostContext() as common.Context, 'VPS');
      const savedValue = await pf.get('mirrorControls', false);
      this.isMirrorControls = savedValue as boolean;
      logInfo(`[镜像] 从本地存储加载状态: ${this.isMirrorControls ? '镜像' : '标准'}`);
    } catch (e) {
      logError('加载镜像布局状态失败', e);
      this.isMirrorControls = false;
    }
  }

  private sBH(img: ResourceStr | undefined, txt: string) {
    if (this.bt !== -1) clearTimeout(this.bt);
    this.bhi = img;
    this.bht = txt;
    this.bh = true;
    this.bt = setTimeout(() => { this.bh = false; this.bt = -1; }, 2000);
  }

  private sGH(txt: string, progress: number = -1, type: string = '') {
    this.ght = txt;
    this.gh = true;
    this.ghp = progress;
    this.ghtType = type;
    if (this.gt_ !== -1) clearTimeout(this.gt_);
    this.gt_ = setTimeout(() => {
      this.gh = false;
      this.gt_ = -1;
      // ⭐ 缩略图与提示胶囊同生共死：提示淡出时一并隐藏，不用再单独维护一个计时器
      this.hideSeekThumb_();
    }, 800);
  }

  /**
   * ⭐ 更新进度调节缩略图（拖动进度条 / 视频区左右滑动时调用）
   *
   * 拖动期间会以 ~90 次/秒的节奏调用，所以：
   * - 结果按"令牌"取最后一次：拖动时异步请求会并发返回，只认最新的，否则画面会闪回旧帧；
   * - 查不到时不改 `pm`（沿用上一张），避免网络/解码期间缩略图闪白。
   */
  private updateSeekThumb_(sec: number): void {
    const bvid: string = this.vd?.bvid ?? '';
    const cid: number = this.vi.cid;
    if (!bvid || !cid || cid <= 0) return;
    const token: number = ++this.shotToken_;
    VideoShotService.getFrame(bvid, cid, sec).then((frame: SeekThumbFrame | undefined) => {
      if (token !== this.shotToken_) return;   // 已有更新的请求，丢弃这次结果
      // 同一张位图且已在显示中 → 不必重建对象，省掉一次无意义的组件刷新
      if (frame && frame.pm === this.thumb_.pm && this.thumb_.show) return;
      const t: SeekThumb = new SeekThumb();
      if (frame) {
        t.pm = frame.pm;
        t.aspect = frame.aspect;
      } else {
        t.pm = this.thumb_.pm;                 // 拿不到就沿用上一张（不闪白）
        t.aspect = this.thumb_.aspect;
      }
      t.show = true;
      this.thumb_ = t;
    }).catch(() => {
    });
  }

  /** 隐藏缩略图（提示胶囊淡出时调用）。保留位图，下次拖动可直接显示、不用等解码 */
  private hideSeekThumb_(): void {
    this.shotToken_++;                         // 让在途结果失效
    if (!this.thumb_.show) return;
    const t: SeekThumb = new SeekThumb();
    t.pm = this.thumb_.pm;
    t.aspect = this.thumb_.aspect;
    t.show = false;
    this.thumb_ = t;
  }

  /**
   * ⭐ 预取缩略图列表（起播后延迟调用）。
   * 延迟是为了避开起播阶段的解码/网络竞争；精灵图不在此时下载，等真正拖动时再按需取。
   */
  private prefetchVideoShot_(): void {
    const bvid: string = this.vd?.bvid ?? '';
    const cid: number = this.vi.cid;
    if (!bvid || !cid || cid <= 0) return;
    // 换集/换视频：先松开上一集的位图引用，再整体释放缓存
    this.hideSeekThumb_();
    this.thumb_ = new SeekThumb();
    VideoShotService.setOwner(bvid, cid);
    setTimeout(() => {
      VideoShotService.prefetch(bvid, cid);
    }, 1500);
  }


  private tglUB() {
    logInfo('[VideoPlayer] tglUB called, current ub:', this.ub);
    // 在锁定状态下，点击屏幕切换解锁按钮的显示/隐藏状态
    if (this.ub) {
      // 如果按钮当前显示，则立即隐藏
      this.ub = false;
      logInfo('[VideoPlayer] Hide unlock button immediately');
      // 清除现有定时器
      if (this.ubt !== -1) { clearTimeout(this.ubt); this.ubt = -1; }
    } else {
      // 如果按钮当前隐藏，则显示并设置5秒后自动隐藏
      this.ub = true;
      logInfo('[VideoPlayer] Show unlock button');
      // 清除现有定时器
      if (this.ubt !== -1) { clearTimeout(this.ubt); this.ubt = -1; }
      // 设置5秒后自动隐藏
      this.ubt = setTimeout(() => {
        logInfo('[VideoPlayer] Auto-hide unlock button after 5 seconds');
        this.ub = false;
        this.ubt = -1;
      }, 5000);
    }
  }

  private manageSB(force: boolean = false) {
    if (!this.mw) return;
    if (!force && this.fs) return;
    try {
      if (this.fs) {
        // ⭐ 全屏模式：无论横竖屏都隐藏状态栏
        this.mw.setWindowSystemBarEnable([]);
      } else if (this.sh_) {
        this.mw.setWindowSystemBarEnable([]);
      } else if (this.isLightsOff) {
        // ⭐ 关灯模式：隐藏状态栏（竖屏也隐藏，横屏本就隐藏）
        this.mw.setWindowSystemBarEnable([]);
      } else {
        if (this.isLs) {
          this.mw.setWindowSystemBarEnable([]);
        } else {
          this.mw.setWindowSystemBarEnable(['status', 'navigation']);
        }
      }
    } catch (e) { }
  }

  async initW() {
    logInfo('[VPP] initW 开始');
    try {
      this.mw = await window.getLastWindow(this.getUIContext().getHostContext() as common.Context);
      // ⭐ 窗口背景色与页面底色一致：旋转瞬间不再露出系统默认底色（闪白）
      try {
        this.mw.setWindowBackgroundColor('#000000');
      } catch (_e) { }
      // ⭐ 窗口就绪后立即按当前播放状态设置屏幕常亮（onPageShow 早于 mw 就绪，不能依赖那次调用）
      this.updateKeepScreen();
      const b = this.mw.getWindowProperties().brightness;
      this.originalBrightness_ = b;
      if (b !== -1) this.bri = b;
      const r = this.mw.getWindowProperties().windowRect;
      this.sw = this.getUIContext().px2vp(r.width);
      this.cw = this.getUIContext().px2vp(r.width);
      this.ch = this.getUIContext().px2vp(r.height);
      this.screenH_ = this.getUIContext().px2vp(r.height);
      // ⭐ 根据窗口尺寸设置横竖屏状态（onAreaChange 在此之前可能尚未触发）
      this.isLs = r.width > r.height;
      this.maxFloatBtnBottom = this.isLs ? 392 : 592;
      this.updateIsLandscapeVertical();
      this.updateLSVSize();       // ← 补充：确保 lsvw/lsvh 正确
      this.updateVideoSize();
    } catch (e) { }
    logInfo('[VPP] initW 函数体完成');
  }

  private async activateAudioSession() {
    try {
      const audioManager = audio.getAudioManager();
      const sessionManager = audioManager.getSessionManager();
      const strategy: audio.AudioSessionStrategy = {
        concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS
      };
      await sessionManager.activateAudioSession(strategy);
    } catch (e) { }
  }

  /**
   * 释放播放器 — 如果 av/avAudio 已被转移到 PlayerService 则跳过
   */
  release() {
    // ⭐ 停止同步定时器
    this.stopSyncTimer();
    // ⭐ 自动画中画：先解除武装再关小窗（防止页面销毁后回桌面系统拉起空白小窗）
    try { this.pipCtrl_?.setAutoStartEnabled(false); } catch (e) { }
    if (this.pipActive_ && this.pipCtrl_) {
      this.pipCtrl_.stopPiP().catch(() => { });
      this.pipActive_ = false;
    }
    // ⭐ 4K 快速起播的升级定时器：释放时必须清掉，否则会在页面销毁后再去切档
    if (this.upgradeTimer_ >= 0) {
      clearTimeout(this.upgradeTimer_);
      this.upgradeTimer_ = -1;
    }
    this.upgradeQn_ = 0;
    if (this.av) {
      this.av.off('stateChange');
      this.av.off('timeUpdate');
      this.av.off('error');
      this.av.off('videoSizeChange');
      this.av.release();
      this.av = null;
    }
    if (this.avAudio) {
      this.avAudio.off('stateChange');
      this.avAudio.off('error');
      this.avAudio.release();
      this.avAudio = null;
    }
    // ⭐ DASH 转播站桥：页面持有则停；恢复接管存的句柄同样停
    if (this.dashBridge_) {
      this.dashBridge_.stopIfRunning();
      this.dashBridge_ = null;
    }
    if (this.dashHandle_) {
      this.dashHandle_.stop();
      this.dashHandle_ = null;
    }
    this.isDashStream_ = false;
    // ⭐ 离线播放：关闭本地文件 fd
    if (this.offlineVideoFd_) {
      try { fs.closeSync(this.offlineVideoFd_); } catch (e) { }
      this.offlineVideoFd_ = null;
    }
    if (this.offlineAudioFd_) {
      try { fs.closeSync(this.offlineAudioFd_); } catch (e) { }
      this.offlineAudioFd_ = null;
    }
  }

  async initP() {
    // 防止重复初始化
    // ⭐ 先设置标志，防止竞态条件
    this.initPInProgress_ = true;

    if (this.av) {
      logInfo('[VideoPlayer] Player already initialized, skipping');
      this.initPInProgress_ = false;
      return;
    }

    // 如果 cid 为 0，等待 loadD 获取 cid
    if (!this.vi.cid) {
      logInfo('[VideoPlayer] cid is 0, waiting for loadD to fetch cid');
      // 等待最多 5 秒
      // ⭐ 20ms 粒度（原 100ms）：cid 可能在任意时刻到手（详情 RTT / PGC 反查 / 缓存命中），
      //   100ms 轮询意味着"cid 已到却要等下一个整百毫秒才发 playurl"，平均白等 ~50ms
      for (let i = 0; i < 250; i++) {
        await new Promise<void>(resolve => setTimeout(resolve, 20));
        if (this.vi.cid) break;
      }
      if (!this.vi.cid) {
        logError('[VideoPlayer] Failed to get cid after waiting');
        this.err = '获取视频CID失败';
        this.ld = false;
        this.initPInProgress_ = false;
        return;
      }
    }
    try {
      // ⭐ 离线播放：本地缓存文件（用 fdSrc 属性，兼容 API 24/26；createMediaSourceWithUrl/Fd 均不跨版本通用）
      if (this.offlineVideoPath_) {
        this.av = await media.createAVPlayer();
        if (!this.av) throw new Error('no player');
        this.setupL();
        // 打开本地视频文件获取 fd 并作为数据源
        this.offlineVideoFd_ = fs.openSync(this.offlineVideoPath_, fs.OpenMode.READ_ONLY);
        const vFd: media.AVFileDescriptor = { fd: this.offlineVideoFd_.fd, offset: 0 };
        this.av.fdSrc = vFd;
        if (this.offlineAudioPath_) {
          this.avAudio = await media.createAVPlayer();
          if (this.avAudio) {
            this.setupAudioL();
            this.offlineAudioFd_ = fs.openSync(this.offlineAudioPath_, fs.OpenMode.READ_ONLY);
            const aFd: media.AVFileDescriptor = { fd: this.offlineAudioFd_.fd, offset: 0 };
            this.avAudio.fdSrc = aFd;
          }
        }
      } else {
      // ⭐ 4K 快速起播：4K + 有续播点时先用 1080P+ 请求，首帧出得早（见 pickFastStartQn）
      const startQn: number = this.pickFastStartQn();
      const result: PlayUrlResult = this.isPgc_
        ? await getPgcPlayUrl(this.epId_, this.vi.cid, startQn, this.seasonId_)
        : await getVideoPlayUrl(this.vi.bvid, this.vi.cid, startQn);
      const url = result.url;
      if (!url) throw new Error('no url');
      // ⭐ 服务端续播点兜底：路由未带进度（从番剧页/推荐/搜索进入）时，用该集自己的观看位置恢复
      this.applyServerResumePoint(result);
      // 更新为服务器实际返回的画质（可能被降级）
      this.qn = result.actualQn || this.qn;
      this.applyAcceptQuality(result);
      this.av = await media.createAVPlayer();
      if (!this.av) throw new Error('no player');
      this.setupL();
      // ⭐ DASH 双流：走「探测→MPD→转播站→单 AVPlayer」，替代双 AVPlayer 手动同步
      if (result.audioUrl && result.dash) {
        this.isDashStream_ = true;
        this.dashBridge_ = new DashPlayerBridge();
        const playerUrl = await this.dashBridge_.buildAndStart(
          result.dash, 'https://www.bilibili.com/',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          AppStorage.get<string>('biliCookie') || '',
          // ⭐ 起播位（续播点）传给转播站做「分段预取」：起播时为 0 无副作用，
          //    有续播点时把覆盖该时刻的分段在 prepare 期间先拉好，seek 时直接命中缓存
          Math.max(0, Math.round(this.initialProgress_ * 1000)));
        if (!playerUrl) {
          this.err = 'DASH 转播站启动失败';
          logError(`[VideoPlayer] dashBridge.buildAndStart 失败`);
          this.release();
          this.initPInProgress_ = false;
          return;
        }
        const src = media.createMediaSourceWithUrl(playerUrl, {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/'
        });
        await this.av.setMediaSource(src);
      } else {
        this.isDashStream_ = false;
        const src = media.createMediaSourceWithUrl(url, {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/'
        });
        await this.av.setMediaSource(src);
        if (result.audioUrl) {
          this.avAudio = await media.createAVPlayer();
          if (this.avAudio) {
            this.setupAudioL();
            const audioSrc = media.createMediaSourceWithUrl(result.audioUrl, {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
              'Referer': 'https://www.bilibili.com/'
            });
            await this.avAudio.setMediaSource(audioSrc);
          }
        }
      }
      }
    } catch (e) {
      this.err = e instanceof Error ? e.message : 'init fail';
      this.ld = false;
    } finally {
      this.initPInProgress_ = false;
    }
  }

  private setupAudioL() {
    if (!this.avAudio) return;
    this.avAudio.on('stateChange', async (st: string) => {
      if (st === 'initialized') {
        await this.avAudio?.prepare();
      } else if (st === 'prepared') {
        try { this.avAudio?.setVolume(1.0); if (this.mute) this.setSystemVolume(0); } catch (e) { }
        // ⭐ 同步播放速率（关键！否则音频可能以错误速度播放）
        try {
          await this.avAudio?.setSpeed(this.rateToSpeedIdx(this.rt));
          logInfo(`[VideoPlayer] 音频播放器设置播放速率: ${this.rt}x`);
        } catch (e) { }
        // ⭐ 不在这里自动播放，由视频播放器的prepared状态统一控制
        // 但需要确保音频播放器处于正确的seek位置
      }
    });
    // ⭐ 注册seekDone回调，用于同步等待seek完成
    this.avAudio.on('seekDone', (pos: number) => {
      logInfo(`[VideoPlayer] audio seekDone: ${pos}ms`);
      if (this.audioSeekResolve_) {
        this.audioSeekResolve_();
        this.audioSeekResolve_ = null;
      }
    });
    this.avAudio.on('error', (e: BusinessError) => { });
  }

  private setupL() {
    if (!this.av) return;
    this.av.on('stateChange', async (st: string) => {
      switch (st) {
        case 'initialized':
          if (this.sId) {
            await this.bindS();
          } else {
            const id = this.xc.getXComponentSurfaceId();
            if (id) {
              this.sId = id;
              logInfo('[VideoPlayer] 兜底获取 surfaceId 成功');
              await this.bindS();
            } else {
              logWarn('[VideoPlayer] initialized 但 surfaceId 未就绪，延迟重试...');
              setTimeout(async () => {
                const retryId = this.xc.getXComponentSurfaceId();
                if (retryId && this.av && this.av.state === 'initialized') {
                  this.sId = retryId;
                  logInfo('[VideoPlayer] 延迟重试获取 surfaceId 成功');
                  await this.bindS();
                } else {
                  logError('[VideoPlayer] 延迟重试失败，surfaceId 仍不可用');
                }
              }, 500);
            }
          }
          break;
        case 'prepared':
          // ⭐ 短视频换源：新视频已就绪 → 收起切换期的封面，露出首帧
          this.shortSwitching = false;
          this.shortCover = '';
          this.ld = false;
          this.dur = (this.av?.duration || 0) / 1000;
          // ⭐ 进度调节缩略图：起播后延迟预取列表（失败/无缩略图的视频静默降级）
          this.prefetchVideoShot_();
          // ⭐ 注册媒体控制回调（通知栏播放/暂停/拖动 -> 控制视频）
          LiveViewHelper.setControlHandlers({
            // ⭐ 显式语义：play 仅在未播放时播放，pause 仅在播放中暂停
            // （旧版 play/pause 都调 togglePP，后台已暂停时点通知栏"暂停"反而触发播放）
            play: () => { if (!this.play) { this.togglePP(); } },
            pause: () => { if (this.play) { this.togglePP(); } },
            seek: (time: number) => { this.seek(time / 1000, false); },
          });
          // ⭐ 创建实况窗：不阻塞起播（fire-and-forget，内部已全 try/catch；媒体会话在首帧后数百 ms 内就绪）
          LiveViewHelper.create(this.getUIContext().getHostContext() as common.Context, this.vi.title, this.vi.cover, this.vi.bvid, this.dur, this.vd?.owner?.name ?? '').catch(() => {});
          try { this.av?.setVolume(1.0); if (this.mute) this.setSystemVolume(0); } catch (e) { }
          try {
            // 根据用户选择的缩放模式动态设置 videoScaleType
            // ⭐ 关灯短视频：卡片内一律完整显示（SCALED_ASPECT），不能按用户的"填充/等高"
            //    设置去裁剪 —— 横屏视频塞进竖屏卡会被裁成竖屏，用户明确不接受。
            const scaleType = this.isShortVideo()
              ? media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT
              : this.getVideoScaleType();
            this.av!.videoScaleType = scaleType;
          } catch (e) { }
          // ⭐ 如果有初始进度，跳转到该位置
          if (this.initialProgress_ > 0 && this.dur > 0 && this.initialProgress_ < this.dur) {
            logInfo(`[VideoPlayer] 跳转到历史进度: ${this.initialProgress_}秒`);
            const seekPos = this.initialProgress_;
            this.initialProgress_ = 0; // 只使用一次
            // 同时seek视频和音频播放器，确保音画同步
            try {
              // 创建等待seekDone的Promise
              const videoSeekDone = new Promise<void>(resolve => { this.videoSeekResolve_ = resolve; });
              const audioSeekDone = this.avAudio
                ? new Promise<void>(resolve => { this.audioSeekResolve_ = resolve; })
                : Promise.resolve();

              // 执行seek操作
              // ⭐ 恢复历史进度必须用 SEEK_CLOSEST：默认 SEEK_PREV_SYNC 会退到上一关键帧，
              //   长 GOP 片源上"续播点"能偏出十几秒，用户感知为"记录的时间对不上"
              this.av?.seek(seekPos * 1000, media.SeekMode.SEEK_CLOSEST);
              if (this.avAudio) {
                this.avAudio.seek(seekPos * 1000, media.SeekMode.SEEK_CLOSEST);
              }

              // 等待两个seekDone回调，最多等待2秒
              let seekTimedOut = false;
              const timeout = new Promise<void>(resolve => setTimeout(() => {
                seekTimedOut = true;
                resolve();
              }, 2000));
              await Promise.race([Promise.all([videoSeekDone, audioSeekDone]), timeout]);
              // ⭐ 超时分支同样要摘掉 resolve，否则残留 resolver 会被后续 seekDone 误触发
              this.videoSeekResolve_ = null;
              this.audioSeekResolve_ = null;

              // ⚠️ 这行日志必须区分「真完成」与「2 秒兜底超时」：
              //    原先无论哪个分支都打"都完成"，于是排查「进播放页慢」时会被它误导成
              //    "seek 已完成，慢在别处" —— 实测这里打完之后 811ms 才收到真正的 seekDone。
              logInfo(seekTimedOut
                ? `[VideoPlayer] seek 等待超时(2s)，先继续；seekDone 可能稍后才到`
                : `[VideoPlayer] 两个seekDone都完成`);

              // 创建等待startRenderFrame的Promise
              const startRenderFrameDone = new Promise<void>(resolve => { this.startRenderFrameResolve_ = resolve; });

              // 先播放视频
              await this.av?.play();

              // 等待视频第一帧渲染完成（最多等待3秒）
              const renderTimeout = new Promise<void>(resolve => setTimeout(resolve, 3000));
              await Promise.race([startRenderFrameDone, renderTimeout]);

              logInfo(`[VideoPlayer] 视频第一帧已渲染，开始播放音频`);


              // ⭐ 播放音频（不再seek，直接播放）
              if (this.avAudio) {
                await this.avAudio.play();
              }
              this.play = true;

              // ⭐ 首次快速同步：不等定时器，立刻检查
              this.initialSyncCheck();

              // ⭐ 启用声画同步监控（初始加载）
              this.startVideoSpeedSync(500);
            } catch (e) {
              logError(`[VideoPlayer] seek失败: ${e}`);
              // seek失败，尝试直接播放
              if (!this.qs && !this.sg_) {
                await this.av?.play();
                this.play = true;
              }
            }
          } else if (!this.qs && !this.sg_) {
            await this.av?.play();
            // ⭐ 同时播放音频
            if (this.avAudio) {
              await this.avAudio.play();
            }
            this.play = true;
            // ⭐ 启用声画同步监控
            this.startVideoSpeedSync();
          }
          if (!this.contentVisible) {
            if (this.pageEnterAnim !== 'none') {
              this.pageEnterProgress = 0;
            }
            animateTo({ duration: 0 }, () => {
              this.contentVisible = true;
            });
            if (this.pageEnterAnim !== 'none') {
              animateTo({
                // ⭐ 页面加载回弹动画（固定参数）
            duration: this.PE_ENTER_DURATION,
            curve: curves.springCurve(this.PE_ENTER_VELOCITY, 1, Math.round(this.FS_SPRING_STIFFNESS * 2.1), this.PE_ENTER_DAMPING),
                onFinish: () => {
                  this.commentsInitialized = true;
                  if (this.pendingCommentAid > 0) {
                    this.loadC(this.pendingCommentAid);
                    this.pendingCommentAid = 0;
                  }
                  this.scheduleFloatBtnFadeIn();
                }
              }, () => {
                this.pageEnterProgress = 1;
              });
            } else {
              this.commentsInitialized = true;
              if (this.pendingCommentAid > 0) {
                this.loadC(this.pendingCommentAid);
                this.pendingCommentAid = 0;
              }
              this.scheduleFloatBtnFadeIn();
            }
          }
          break;
        case 'playing':
        case 'paused':
          // ⭐ 自动画中画：以真实播放状态驱动武装（自动起播不经 togglePP，
          //   进入 playing 即武装，确保回桌面时 auto-start 已就绪）
          this.updatePipAutoArm_();
          break;
        case 'completed':
          this.play = false;
          this.updatePipAutoArm_();
          break;
        case 'error':
          this.err = '播放器内部错误';
          this.ld = false;
          this.sr_ = false;
          // ⭐ 播放器内部错误：作废本视频 playurl 缓存，避免下次重试命中坏地址
          invalidatePlayUrlCache(this.vi.bvid, this.vi.cid, this.qn);
          break;
      }
    });
    // ⭐ 注册seekDone回调，用于同步等待seek完成
    this.av.on('seekDone', (pos: number) => {
      logInfo(`[VideoPlayer] video seekDone: ${pos}ms`);
      if (this.videoSeekResolve_) {
        this.videoSeekResolve_();
        this.videoSeekResolve_ = null;
      }
    });
    // ⭐ 注册startRenderFrame回调，用于检测视频第一帧渲染完成
    this.av.on('startRenderFrame', () => {
      logInfo(`[VideoPlayer] video startRenderFrame - 第一帧已渲染`);
      if (this.startRenderFrameResolve_) {
        this.startRenderFrameResolve_();
        this.startRenderFrameResolve_ = null;
      }
      // ⭐ 首帧后：1080w 封面预解码挪到这里，不再与起播抢网络/解码线程
      this.predecodeCover();
      // ⭐ 4K 快速起播（默认关闭）：开启时才在首帧后安排升回 4K
      if (FAST_START_4K) {
        this.scheduleUpgradeToWantedQn();
      }
    });
    this.av.on('timeUpdate', (t: number) => {
      if (!this.sk_) {
        this.ct = t / 1000;
        // ⭐ 实况窗：更新进度（每 5 秒节流一次）
        if (this.lvTimer_ === -1) {
          this.lvTimer_ = setTimeout(() => {
            this.lvTimer_ = -1;
            LiveViewHelper.updateProgress(this.ct);
          }, 5000);
        }
      }
    });
    this.av.on('error', (e: BusinessError) => {
      if (e.code !== 5400102) { this.err = `播放错误:${e.message}`; this.ld = false; }
    });
    this.av.on('videoSizeChange', (w: number, h: number) => {
      logInfo(`[VideoPlayer] videoSizeChange: ${w}x${h}`);
      this.vw = w;
      this.vh = h;
      if (w > 0 && h > 0) {
        this.ar = w / h;
        this.updateIsLandscapeVertical();
        this.updateLSVSize();
        this.updateVideoSize();
        // ⭐ 自动画中画：同步小窗宽高比
        try { this.pipCtrl_?.updateContentSize(w, h); } catch (e) { }
      } else {
        // 视频尺寸为0，可能是DASH模式下视频流尚未就绪
        logWarn('[VideoPlayer] Video size is 0x0, video stream may not be ready');
      }
    });
  }

  private async bindS() {
    const surfaceId = this.nativeSurfaceId_ || this.sId;
    if (!this.av || !surfaceId) {
      logWarn('[VideoPlayer] bindS: player or surfaceId is null');
      return;
    }
    try {
      logInfo(`[VideoPlayer] Binding surface: ${surfaceId}, player state: ${this.av.state}`);
      this.av.surfaceId = surfaceId;
      if (this.av.state === 'initialized') {
        await this.av.prepare();
        logInfo('[VideoPlayer] Player prepared successfully');
      }
    } catch (e) {
      logError('[VideoPlayer] bindS error:', e);
      this.err = e instanceof Error ? e.message : '渲染失败';
    }
  }

  onXC = () => {
    const id = this.xc.getXComponentSurfaceId();
    if (!id) return;

    // 尝试初始化 GL（即使 surface 未变化也可能首次异步就绪）
    this.tryInitGL_(id);

    // 如果Surface ID没有变化且播放器已绑定，则跳过
    if (id === this.sId && this.av && this.av.state !== 'idle') {
      return;
    }

    this.sId = id;

    // ⭐ 自动画中画：创建画中画控制器（以本页 XComponent 为小窗载体）
    this.ensurePipController_();

    // 初始化播放器（如果尚未初始化）
    if (!this.av && !this.initPInProgress_) {
      this.initP();
    } else if (this.av && this.av.state === 'initialized') {
      // 播放器已存在且已初始化，绑定Surface
      this.bindS();
    }
    // ⭐ XComponent 常驻单实例：surface 不再随布局分支切换重建，无需换 surface/强制出帧兜底
  }

  // ═══════════════════ 画中画（自动小窗 · 页面模式）═══════════════════
  // 以本页 XComponent 为小窗载体：回桌面时播放中由系统自动拉起，画面随组件迁入小窗。
  // 仅播放中的本页可武装 setAutoStartEnabled；暂停/页面销毁即解除（防空白小窗）。

  /** 是否允许武装「回桌面自动小窗」：开关开 + 真实播放中 + 小窗未开 */
  private pipArmAllowed_(): boolean {
    return this.autoPip && this.play && this.av?.state === 'playing' && !this.pipActive_;
  }

  /** 同步自动小窗武装状态（播放状态/切后台/页面显隐变化后调用） */
  private updatePipAutoArm_(): void {
    try {
      this.pipCtrl_?.setAutoStartEnabled(this.pipArmAllowed_());
    } catch (e) {
      logWarn('[PiP] setAutoStartEnabled 失败:', e);
    }
  }

  /** bgp 恢复播放是异步的：等 av 真实进入 playing 后补武装（最多重试 retries 次 × 200ms） */
  private armPipWhenPlaying_(retries: number): void {
    if (!this.pipCtrl_ || this.pipActive_ || !this.autoPip || !this.play) return;
    if (this.av && this.av.state === 'playing') {
      this.updatePipAutoArm_();
      return;
    }
    if (retries <= 0) return;
    setTimeout(() => this.armPipWhenPlaying_(retries - 1), 200);
  }

  /** 同步小窗面板播放/暂停按钮状态 */
  private syncPipControlStatus_(): void {
    if (!this.pipActive_ || !this.pipCtrl_) return;
    try {
      this.pipCtrl_.updatePiPControlStatus(PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
        this.play ? PiPWindow.PiPControlStatus.PLAY : PiPWindow.PiPControlStatus.PAUSE);
    } catch (e) { }
  }

  /** 创建（幂等）画中画控制器：以本页 XComponent 为小窗载体 */
  private async ensurePipController_(): Promise<void> {
    if (this.pipCtrl_ || this.pipCreating_) return;
    if (!PiPWindow.isPiPEnabled()) {
      logWarn('[PiP] 当前设备不支持画中画');
      return;
    }
    this.pipCreating_ = true;
    try {
      const config: PiPWindow.PiPConfiguration = {
        context: this.getUIContext().getHostContext() as common.UIAbilityContext,
        componentController: this.xc,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        contentWidth: this.vw > 0 ? this.vw : 1280,
        contentHeight: this.vh > 0 ? this.vh : 720,
      };
      this.pipCtrl_ = await PiPWindow.create(config);
      this.pipCtrl_.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
        this.onPipStateChange_(state, reason);
      });
      this.pipCtrl_.on('controlPanelActionEvent', (event: PiPWindow.PiPActionEventType, status?: number) => {
        if (event !== 'playbackStateChanged') return;
        const playing = status === 1;
        logInfo(`[PiP] playbackStateChanged: playing=${playing}`);
        // 小窗面板播放/暂停：经 togglePP 与页面状态同步
        if (playing !== this.play) {
          this.togglePP();
        }
      });
      logInfo('[PiP] 画中画控制器创建成功（页面 XComponent 模式）');
      this.updatePipAutoArm_();
    } catch (e) {
      logError('[PiP] 创建画中画控制器失败:', e);
    } finally {
      this.pipCreating_ = false;
    }
  }

  /** 画中画生命周期状态变化 */
  private onPipStateChange_(state: PiPWindow.PiPState, reason: string): void {
    logInfo(`[PiP] stateChange: ${state}, reason: ${reason}`);
    if (state === PiPWindow.PiPState.ABOUT_TO_START || state === PiPWindow.PiPState.STARTED) {
      this.pipActive_ = true;
    } else if (state === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
      this.pipActive_ = false;
    } else if (state === PiPWindow.PiPState.STOPPED) {
      this.pipActive_ = false;
      // ⭐ 小窗被用户关闭（拖删/关闭按钮）且应用仍在后台：未开后台播放则暂停，避免"幽灵音频"
      if ((reason === 'dragDelete' || reason === 'panelActionDelete') && this.appInBackground && !this.bgp) {
        this.av?.pause();
        this.avAudio?.pause();
        this.play = false;
        LiveViewHelper.updatePlayState(false);
        logInfo('[PiP] 小窗被关闭，已暂停播放');
      }
    } else if (state === PiPWindow.PiPState.ERROR) {
      this.pipActive_ = false;
    }
    this.updatePipAutoArm_();
  }

  async togglePP() {
    if (!this.av) return;
    if (this.play) {
      this.userPaused_ = true;    // 用户主动暂停
      await this.av.pause();
      await this.avAudio?.pause();
      this.play = false;
    } else {
      this.userPaused_ = false;   // 用户主动播放
      await this.av.play();
      await this.avAudio?.play();
      this.play = true;
    }
    // ⭐ 实况窗：更新播放状态
    LiveViewHelper.updatePlayState(this.play);
    // ⭐ 自动画中画：同步小窗面板播放/暂停按钮状态 + 武装状态
    this.syncPipControlStatus_();
    this.updatePipAutoArm_();
    this.cancelDelayHide();
    if (this.cv) this.resetCT();
  }

  /**
   * 速率值 → PlaybackSpeed 枚举索引映射
   * HarmonyOS AVPlayer.setSpeed() 接受枚举整型索引，而非直接浮点值。
   * AVPlaybackSpeed: 0=0.75x, 1=1.0x, 2=1.25x, 3=1.75x, 4=2.0x, 5=0.5x, 6=1.5x, 7=3.0x
   */
  private rateToSpeedIdx(rate: number): number {
    if (rate <= 0.625) return 5;  // 0.5x
    if (rate <= 0.875) return 0;  // 0.75x
    if (rate <= 1.125) return 1;  // 1.0x
    if (rate <= 1.375) return 2;  // 1.25x
    if (rate <= 1.625) return 6;  // 1.5x
    if (rate <= 1.875) return 3;  // 1.75x
    if (rate <= 2.5) return 4;    // 2.0x
    return 7;                     // 3.0x
  }

  async setRate(r: number, sh: boolean = true) {
    if (!this.av) return;
    this.rt = r;
    // ⭐ 弹幕速度跟随播放倍速（官方/PiliPlus：滚动时长 `duration / playbackSpeed`）。
    //   不联动的话 2 倍速播放时弹幕还是 1 倍速的爬行感，与官方明显不同。
    //   ⚠️ 只能改字段、不能整体替换 danmakuConfig 对象（controller/renderer 持有旧引用）。
    this.danmakuConfig.speed = r;
    try {
      const speedIdx: number = this.rateToSpeedIdx(r);
      await this.av.setSpeed(speedIdx);
      await this.avAudio?.setSpeed(speedIdx);
    } catch (e) { }
    this.cancelDelayHide();
    if (this.cv) this.resetCT();
  }

  toggleMute() {
    if (!this.av) return;
    this.mute = !this.mute;
    const v = this.mute ? 0 : this.vol;
    const s = this.av.state;
    if (s === 'prepared' || s === 'playing' || s === 'paused' || s === 'completed') {
      try {
        this.av.setVolume(1.0);
        this.avAudio?.setVolume(1.0);
      } catch (e) { }
    }
    this.setSystemVolume(v);
    if (!this.mute) this.vol = v;
    AppStorage.setOrCreate('globalVolume', this.vol);
    AppStorage.setOrCreate('globalMuted', this.mute);
    this.cancelDelayHide();
    if (this.cv) this.resetCT();
  }

  private setSystemVolume(vol: number): void {
    // 设置系统媒体音量：档位范围动态获取，不硬编码 15（设备档位不同会导致实际音量偏小）
    try {
      const v: number = Math.round(vol * this.maxVol_);
      audio.getAudioManager().setVolume(audio.AudioVolumeType.MEDIA, v);
    } catch (_e) {}
  }

  private async readSystemVolume(): Promise<void> {
    try {
      const mgr = audio.getAudioManager().getVolumeManager();
      const maxVol: number = mgr.getMaxVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
      this.maxVol_ = maxVol > 0 ? maxVol : 15;
      const sysVol: number = mgr.getVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC);
      this.vol = maxVol > 0 ? Math.min(1, Math.max(0, sysVol / maxVol)) : 0.7;
      AppStorage.setOrCreate('globalVolume', this.vol);
    } catch (_e) {
      this.vol = AppStorage.get<number>('globalVolume') ?? 0.7;
    }
  }

  /** ⭐ 注册系统音量变化监听（音量键调节时同步 app 内滑块/手势起点） */
  private registerVolumeListener(): void {
    try {
      const mgr = audio.getAudioManager().getVolumeManager();
      this.volMgr_ = mgr;
      if (this.volListening_) return;
      // 注：本机 SDK 中 streamVolumeChange 的签名与官方文档示例不一致，改用编译确认存在的 volumeChange
      mgr.on('volumeChange', (ev: audio.VolumeEvent) => {
        // 不依赖事件字段（避免版本差异），直接重读系统音量同步 UI
        try {
          if (this.maxVol_ > 0) {
            const sysVol: number = this.volMgr_?.getVolumeByStream(audio.StreamUsage.STREAM_USAGE_MUSIC) ?? 0;
            this.vol = Math.min(1, Math.max(0, sysVol / this.maxVol_));
            AppStorage.setOrCreate('globalVolume', this.vol);
          }
        } catch (_e2) {}
      });
      this.volListening_ = true;
    } catch (_e) {}
  }

  /** ⭐ 注销系统音量变化监听 */
  private unregisterVolumeListener(): void {
    try {
      if (this.volMgr_ && this.volListening_) {
        this.volMgr_.off('volumeChange');
        this.volListening_ = false;
      }
    } catch (_e) {}
  }

  toggleLock() {
    this.cancelDelayHide();
    logInfo('[VideoPlayer] toggleLock called, current lk:', this.lk, 'ub:', this.ub, 'cv:', this.cv);
    this.lk = !this.lk;
    logInfo('[VideoPlayer] toggleLock after toggle, new lk:', this.lk);
    if (this.lk) {
      if (this.ct_ !== -1) clearTimeout(this.ct_);
      this.cv = false;
      // 锁定后立即显示解锁按钮5秒钟
      this.ub = true;
      logInfo('[VideoPlayer] Locked: cv=false, ub=true');
      if (this.ubt !== -1) { clearTimeout(this.ubt); this.ubt = -1; }
      this.ubt = setTimeout(() => {
        logInfo('[VideoPlayer] Hide unlock button after 5 seconds');
        this.ub = false;
        this.ubt = -1;
      }, 5000);
      this.sBH($r('app.media.ic_public_unlock'), '已锁定');
    } else {
      this.cv = true;
      this.ub = false;
      logInfo('[VideoPlayer] Unlocked: cv=true, ub=false');
      if (this.ubt !== -1) { clearTimeout(this.ubt); this.ubt = -1; }
      this.resetCT();
      this.sBH($r('app.media.ic_public_lock'), '已解锁');
    }
  }

  toggleBackgroundPlayback() {
    this.bgp = !this.bgp;
    AppStorage.set<boolean>('bgp', this.bgp);
    // 持久化到 Preferences（进程重启后仍保留）
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      preferences.getPreferences(context, 'my_app_settings').then((pref) => {
        pref.put('bgp', this.bgp);
        pref.flush();
      });
    } catch (e) {
      logError('[bgp] 持久化保存失败', e);
    }
    this.sBH($r('app.media.headphones_fill'), this.bgp ? '后台播放已开启' : '后台播放已关闭');
    this.cancelDelayHide();
    if (this.cv) this.resetCT();
  }

  // ⭐ 长按文本选取弹窗内容（可选中 → 复制/搜索）
  @Builder
  textSelectDialog(title: string, text: string) {
    TextSelectionDialog({
      title: title,
      text: text,
      onSearchText: (keyword: string) => {
        if (this.textSelectDialogId_ >= 0) {
          this.getUIContext().getPromptAction().closeCustomDialog(this.textSelectDialogId_);
          this.textSelectDialogId_ = -1;
        }
        this.getUIContext().getRouter().pushUrl({
          url: 'pages/SearchPage',
          params: { keyword: keyword }
        }).catch((err: Error) => {
          logWarn(`[VideoPlayer] 搜索页跳转失败: ${errMsg(err)}`);
        });
      }
    })
  }

  /** 打开文本选取弹窗（long press 用） */
  private showTextSelection(title: string, text: string) {
    if (!text || text.length === 0) return;
    this.getUIContext().getPromptAction().openCustomDialog({
      builder: () => {
        this.textSelectDialog(title, text);
      },
      autoCancel: true,
      // ⭐ 沉浸光感（官方"对话框通道"）：THICK 玻璃 + 无光效（复用面板材质配置）
      backgroundColor: Color.Transparent,
      systemMaterial: MaterialUtil.sheetMaterial()
    }).then((id: number) => {
      this.textSelectDialogId_ = id;
    }).catch((err: Error) => {
      logWarn(`[VideoPlayer] 文本弹窗打开失败: ${errMsg(err)}`);
    });
  }

  /** 超时兜底辅助（Promise.race 用，避免 await 永久悬挂） */
  private delayMs_(ms: number): Promise<void> {
    return new Promise<void>(resolve => setTimeout(resolve, ms));
  }

  /**
   * 跳转到指定位置。
   * @param v    目标秒数
   * @param rs   完成后是否重置控制栏自动隐藏计时
   * @param fast 交互路径（点/拖进度条、手势松手）：用 SEEK_CLOSEST + 更短的首帧等待，
   *             音画微偏差交给 syncAudioVideo 与"按实际帧对齐音频"兜底，
   *             避免原先恒等 3 秒首帧等待造成的"点一下卡一下"
   */
  async seek(v: number, rs: boolean = true, fast: boolean = false) {
    if (!this.av) return;
    // ⭐ last-wins：seek 在途时不直接丢弃（原 `if (sg_) return` 会把用户的第二次操作吞掉），
    //   改为记录目标、由 finally 补提交
    if (this.sg_) {
      this.pendingSeekTarget_ = v;
      this.ct = v;
      return;
    }
    // 用户手动 seek 时取消自动声画同步
    this.cancelVideoSpeedSync();
    this.ct = v;
    this.sg_ = true;
    this.sk_ = true;
    const wp = this.play || this.av.state === 'playing';
    // ⭐ 首帧等待与音频再对齐等待的上限：交互路径收紧（原先恒为 3000/500ms）
    const renderWait = fast ? 600 : 3000;
    const reseekWait = fast ? 300 : 500;
    try {
      if (wp) {
        await Promise.all([this.av.pause(), this.avAudio?.pause()]);
        this.play = false;
      }
      // ⭐ 创建等待 seekDone 的 Promise（依赖 setupL/setupAudioL 中注册的 on('seekDone') 回调）
      const videoSeekDone = new Promise<void>(resolve => { this.videoSeekResolve_ = resolve; });
      const audioSeekDone = this.avAudio
        ? new Promise<void>(resolve => { this.audioSeekResolve_ = resolve; })
        : Promise.resolve();
      // ⭐ 交互 seek 用 SEEK_CLOSEST（跳最近帧）；默认 SEEK_PREV_SYNC 只跳上一关键帧，
      //   长 GOP 片源上会明显"跳不到点"
      this.av.seek(v * 1000, fast ? media.SeekMode.SEEK_CLOSEST : media.SeekMode.SEEK_PREV_SYNC);
      this.avAudio?.seek(v * 1000);
      if (wp) {
        // ⭐ 关键修复：seekDone 必须配超时兜底。原先这里是无超时 await，一旦 seekDone 不回调
        //   （音频播放器已释放但引用仍在、seek 到相同位置、DASH waiting 态等），
        //   sg_ / sk_ 就永不复位 → 之后所有 seek 被静默丢弃，且 timeUpdate 被 sk_ 挡住
        //   → 进度条彻底冻结。
        await Promise.race([videoSeekDone, this.delayMs_(fast ? 900 : 1500)]);
        this.videoSeekResolve_ = null;
        await Promise.race([audioSeekDone, this.delayMs_(fast ? 500 : 1000)]);
        this.audioSeekResolve_ = null;
        await this.av!.play();
        // ⭐ 等视频第一帧渲染后，读取视频实际位置，再对齐音频
        // DASH 双流下视频 seek 只对齐到关键帧（实际位置可能略早于目标），
        // startRenderFrame 时 currentTime 才稳定；此时读到的位置是真实值。
        // 与初始进度路径（initialProgress_）同一套已验证逻辑。
        const startRenderFrameDone = new Promise<void>(resolve => { this.startRenderFrameResolve_ = resolve; });
        await Promise.race([startRenderFrameDone, this.delayMs_(renderWait)]);
        if (this.startRenderFrameResolve_) {
          this.startRenderFrameResolve_ = null;  // 超时未触发时清理，避免悬挂
        }
        const actualPos: number = this.av!.currentTime;
        if (this.avAudio && Math.abs(actualPos - v * 1000) > 50) {
          logInfo(`[VideoPlayer] seek后按实际帧对齐音频: 目标=${v * 1000}ms, 实际=${actualPos}ms`);
          const audioReseekDone = new Promise<void>(resolve => { this.audioSeekResolve_ = resolve; });
          // ⭐ 对齐到视频**实际**帧位置：必须用 SEEK_CLOSEST 精确落点，
          //   默认 SEEK_PREV_SYNC 会退到前一个关键帧，反而在"对齐"这一步又造出偏差
          this.avAudio.seek(actualPos, media.SeekMode.SEEK_CLOSEST);
          await Promise.race([audioReseekDone, this.delayMs_(reseekWait)]);
          if (this.audioSeekResolve_) {
            this.audioSeekResolve_ = null;
          }
        }
        await this.avAudio?.play();
        this.play = true;
      }
    } catch (_e) { } finally {
      this.sk_ = false;
      this.sg_ = false;
      // ⭐ seek 刚完成：重置同步节流，避免 syncAudioVideo 在视频 currentTime 稳定前
      // 读到旧值并把音频 seek 回错误位置
      this.lastSyncTime_ = Date.now();
      // ⭐ 补提交在途期间被挡下的目标（last-wins）
      const pending = this.pendingSeekTarget_;
      this.pendingSeekTarget_ = -1;
      if (pending >= 0 && Math.abs(pending - v) > 0.2) {
        // 异步延后一拍，避免在 finally 内递归重入
        setTimeout(() => { this.seek(pending, rs, fast); }, 0);
      }
    }
    this.cancelDelayHide();
    if (rs && this.cv) this.resetCT();
  }

  applyFSResistance(raw: number): number {
    const c = Math.max(0, Math.min(1, raw));
    // ⭐ 重阻尼：幂次 1.5，初段明显拖不动、越拉越重（下拉关灯与右滑全屏共用此曲线）
    return Math.min(1, Math.pow(c, 1.5));
  }

  private fireHaptic(durationMs: number = 15) {
    try {
      VibrateUtils.vibrateTime(durationMs);
    } catch (e) { }
  }

  updateFSPanProgress(raw: number) {
    const resisted = this.applyFSResistance(raw);
    this.fsPanProgress = resisted;
    if ((this.fsHapticPrev < 0.62 && resisted >= 0.62) ||
      (this.fsHapticPrev >= 0.62 && resisted < 0.62)) {
      this.fireHaptic(18);
    }
    this.fsHapticPrev = resisted;
  }

  async startFSAnimation() {
    if (this.fs || this.isAnimatingToFS) return;
    if (this.fsAnimTimer_ !== -1) {
      clearTimeout(this.fsAnimTimer_);
      this.fsAnimTimer_ = -1;
    }
    // ⭐ 快照当前内容分支：fs 期间冻结渲染该分支，避免旋转切分支导致重挂载+解码风暴
    this.snapshotPreFsBranch();
    // ⭐ 快照插值起点（进入前的槽矩形，须在旋转开始前捕捉）
    this.captureFSSnapshot();
    this.fsEntering = true;
    this.fsHapticPrev = 0;
    // ⭐ 'none' 模式：瞬时切换，无过渡动画
    if (!this.fsAnimOn) {
      await this.prepareFullscreenEnvironment();
      this.pcSyncLayoutToFs(true);  // ⭐ PC：窗口内全屏
      this.fs = true;
      this.fsPanProgress = 1;  // ⭐ 瞬时切换也须置全屏进度，否则视频区域仍按非全屏尺寸渲染
      this.fsEntering = false;  // ⭐ 必须重置，否则 ovRectW/ovVideoW 持续返回快照值卡在非全屏
      this.updateVideoSize();  // ⭐ 全屏尺寸重算（黑板常挂载后不再有 onAreaChange 触发）
      this.isAnimatingToFS = false;
      if (this.mw) this.manageSB(true);
      return;
    }
    this.isAnimatingToFS = true;
    const reached = this.fsPanProgress >= 0.62;
    if (reached) {
      // ⭐ 等待系统旋转完成后再翻转全屏（和点击全屏一致）
      await this.prepareFullscreenEnvironment();
      this.fsEntering = false;
      this.pcSyncLayoutToFs(true);  // ⭐ PC：窗口内全屏
      // ⭐ 从当前手势位置继续动画到全屏(不重置fsPanProgress避免详情卡闪现)
      this.fsLerpStartP = this.fsPanProgress;
      this.fsLerpDir = 1;
      this.fs = true;
      this.updateIsLandscapeVertical();
      this.updateVideoSize();  // ⭐ 全屏尺寸重算（黑板常挂载后不再有 onAreaChange 触发）
      this.refreshSafeAreaLeft();
      if (this.mw) this.manageSB(true);
      logInfo(`[FSDBG] enter(gesture): fs=true P=${this.fsPanProgress} dir=${this.fsLerpDir} ovVideo=(${this.ovVideoW().toFixed(1)},${this.ovVideoH().toFixed(1)}) ovRect=(${this.ovRectW().toFixed(1)},${this.ovRectH().toFixed(1)}) animDur=${this.FS_ANIM_DURATION} da=${this.da}`);
      animateTo({ duration: this.FS_ANIM_DURATION, curve: Curve.FastOutSlowIn }, () => {
        this.fsPanProgress = 1;
      });
      this.fsAnimTimer_ = setTimeout(() => {
        this.isAnimatingToFS = false;
        this.fsAnimTimer_ = -1;
      }, this.FS_ANIM_DURATION);
      return;
    }
    // ⭐ 回弹（P 在 0.3~0.62 之间）：没有发生旋转，几何必须立即回到真实槽矩形 ⇒ 复位 fsEntering。
    //   ⚠️ 这是「右滑没到全屏阈值 → 再左滑切换布局 → 视频区域不跟着换位置」的真凶：
    //      上面 captureFSSnapshot() 之后已把 fsEntering 置 true（语义是"旋转期间把常驻层钉在快照矩形上"），
    //      而 ovRectX/Y/W/H 与 ovVideoW/H 在 fsEntering 为 true 时**恒返回快照值**。
    //      旧实现只在 reached 分支（5513）和瞬切分支（5502）复位，回弹分支漏了 ⇒ 常驻层永久钉在
    //      手势开始前的矩形上：占位槽已经移到右侧（日志 `[FSDBG] slot rect=(266.5,...)`），
    //      视频画面却留在左边不动（容器仍是 `[FSDBG] snapshot ... rect=(7.8,7.8,...)`）。
    //      而且只有之后成功进一次全屏才会被复位，属于"卡到下次全屏"的隐性故障。
    this.fsEntering = false;
    animateTo({
      duration: 700,
      curve: curves.springCurve(0.08, 1.3, this.FS_SPRING_STIFFNESS, 10)
    }, () => {
      this.fsPanProgress = 0;
      this.isAnimatingToFS = false;
      this.fsAnimTimer_ = -1;
    });
  }

  /** ⭐ PC/2in1：无旋转回调，手动切换布局方向（fsOn=true 进入横屏全屏，false 恢复进入前方向） */
  private pcSyncLayoutToFs(fsOn: boolean): void {
    if (!this.isPcDevice) return;
    if (fsOn) {
      this.pcPreFsIsLs = this.isLs;
      this.isLs = true;
    } else {
      this.isLs = this.pcPreFsIsLs;
    }
    this.updateIsLandscapeVertical();
  }

  // ⭐ 预准备多窗口横屏环境（配合 preferMultiWindowOrientation: landscape_auto）
  private async prepareFullscreenEnvironment(): Promise<void> {
    if (!this.mw || this.isPcDevice) return;  // ⭐ PC：窗口不旋转，跳过旋转准备（窗口内全屏）
    try {
      // 告知系统应用进入横屏全屏播放状态（小窗模式下将切换为横向悬浮窗）
      await this.mw.enableLandscapeMultiWindow();
      // 设置方向为横屏（允许横屏间旋转）
      await this.mw.setPreferredOrientation(
        this.ar >= 1 ? window.Orientation.AUTO_ROTATION_LANDSCAPE
                     : window.Orientation.AUTO_ROTATION_PORTRAIT
      );
    } catch (_e) {
      logError('prepareFullscreenEnvironment 失败', _e);
    }
  }

  // ⭐ 退出全屏后恢复系统栏、屏幕方向和多窗口横屏状态
  private async restoreOrientationAndBars(): Promise<void> {
    await this.restoreOrientationOnly();
    if (this.mw) {
      this.manageSB();
    }
  }

  // ⭐ 仅恢复屏幕方向和多窗口横屏状态（不管理状态栏），用于退出全屏动画期间提前执行
  private async restoreOrientationOnly(): Promise<void> {
    if (!this.mw || this.isPcDevice) return;  // ⭐ PC：无旋转概念，跳过恢复
    try {
      // 告知系统退出横屏全屏播放状态（小窗恢复为竖向悬浮窗）
      await this.mw.disableLandscapeMultiWindow();
      const lock = AppStorage.get<string>('screenOrientationLock') ?? '自动旋转';
      let orientation: window.Orientation;
      switch (lock) {
        case '锁定竖屏':
          orientation = window.Orientation.PORTRAIT;
          break;
        case '锁定横屏':
          orientation = window.Orientation.AUTO_ROTATION_LANDSCAPE;
          break;
        default:
          orientation = window.Orientation.AUTO_ROTATION;
          break;
      }
      if (lock === '锁定竖屏') {
        this.isLs = false;
        this.isLandscapeVertical = false;
      }
      await this.mw.setPreferredOrientation(orientation);
    } catch (_e) {}
  }

  // ⭐ 带动画进入全屏（常驻层几何插值，surface 不重建）
  private async enterFullscreenAnimated(): Promise<void> {
    if (this.fs || this.isAnimatingToFS) return;
    this.isAnimatingToFS = true;
    if (this.fsAnimTimer_ !== -1) {
      clearTimeout(this.fsAnimTimer_);
      this.fsAnimTimer_ = -1;
    }
    if (!this.mw) { this.isAnimatingToFS = false; return; }

    // ⭐ 快照当前内容分支：fs 期间冻结渲染该分支，避免旋转切分支导致重挂载+解码风暴
    this.snapshotPreFsBranch();
    // ⭐ 快照插值起点（进入前的槽矩形，须在旋转开始前捕捉）
    this.captureFSSnapshot();
    this.fsEntering = true;
    // ⭐ 等待系统环境准备完成（旋转、状态栏），避免旋转黑帧泄露
    await this.prepareFullscreenEnvironment();
    this.fsEntering = false;
    this.fsLerpStartP = 0;
    // ⭐ PC：无旋转回调 → 手动切横屏布局（窗口内全屏）
    this.pcSyncLayoutToFs(true);

    // ⭐ 动画关闭：瞬时切换，无过渡动画
    if (!this.fsAnimOn) {
      this.fs = true;
      this.updateIsLandscapeVertical();
      this.updateVideoSize();  // ⭐ 全屏尺寸重算（黑板常挂载后不再有 onAreaChange 触发）
      this.fsPanProgress = 1;
      this.isAnimatingToFS = false;
      return;
    }

    // ⭐ 翻转全屏状态：常驻层从快照矩形连续缩放平移至全屏矩形（统一动画，无 surface 重建）
    this.fsLerpDir = 1;
    this.fs = true;
    this.updateIsLandscapeVertical();
    this.updateVideoSize();  // ⭐ 全屏尺寸重算（黑板常挂载后不再有 onAreaChange 触发）
    logInfo(`[FSDBG] enter(click): fs=true P=${this.fsPanProgress} dir=${this.fsLerpDir} ovVideo=(${this.ovVideoW().toFixed(1)},${this.ovVideoH().toFixed(1)}) ovRect=(${this.ovRectW().toFixed(1)},${this.ovRectH().toFixed(1)}) animDur=${this.FS_ANIM_DURATION} da=${this.da}`);

    if (this.da) {
      this.fsPanProgress = 1;
      this.isAnimatingToFS = false;
      return;
    }

    animateTo({ duration: this.FS_ANIM_DURATION, curve: Curve.FastOutSlowIn }, () => {
      this.fsPanProgress = 1;
    });

    // 动画结束后清理动画状态
    await new Promise<void>(resolve => {
      this.fsAnimTimer_ = setTimeout(() => {
        this.isAnimatingToFS = false;
        this.fsAnimTimer_ = -1;
        resolve();
      }, this.FS_ANIM_DURATION);
    });
  }

  // ⭐ 退出全屏（优化：先动画驱动 fsPanProgress，再切换布局避免 XComponent 闪黑）
  private async exitFullscreenAnimated(): Promise<void> {
    if (!this.fs || this.isAnimatingToFS) return;
    this.isAnimatingToFS = true;
    if (this.fsAnimTimer_ !== -1) {
      clearTimeout(this.fsAnimTimer_);
      this.fsAnimTimer_ = -1;
    }
    if (!this.mw) { this.isAnimatingToFS = false; return; }

    // ⭐ 弹窗瞬间关闭
    this.icp = true;
    this.sp = false;
    this.qp = false;
    this.mp = false;
    this.mpb = false;
    this.cacheQnPopup = false;
    this.colorStylePopup = false;
    this.cp = false;
    this.ip = false;
    this.showEpisodeSheet = false;
    setTimeout(() => { this.icp = false; }, 0);
    if (this.cv) this.resetCT();

    // ⭐ 动画关闭：瞬时切换，无过渡动画
    if (!this.fsAnimOn) {
      this.fsPanProgress = 0;  // ⭐ 复位全屏进度，避免非全屏布局读到残值
      this.restoreOrientationOnly();
      this.fs = false;
      this.pcSyncLayoutToFs(false);  // ⭐ PC：恢复进入前布局方向
      this.updateIsLandscapeVertical();
      this.updateVideoSize();  // ⭐ 恢复非全屏视频尺寸（fs 期间被全屏 fit 覆盖）
      await new Promise<void>(resolve => {
        setTimeout(() => {
          if (this.mw) this.manageSB();
          this.isAnimatingToFS = false;
          this.fsAnimTimer_ = -1;
          resolve();
        }, 50);
      });
      return;
    }

    // ⭐ 快照全屏插值起点 → 提前旋转窗口 → 等旋转稳定 → 视频连续缩放平移回槽矩形
    this.captureFSSnapshot();
    this.fsLerpDir = 2;
    logInfo(`[FSDBG] exit: dir=2 P=${this.fsPanProgress} ovVideo=(${this.ovVideoW().toFixed(1)},${this.ovVideoH().toFixed(1)}) ovRect=(${this.ovRectW().toFixed(1)},${this.ovRectH().toFixed(1)}) plateVis=${this.fs && this.fsLerpDir !== 2}`);
    await this.restoreOrientationOnly();
    // ⭐ 等旋转完成再开始几何插值（旋转期间视频随窗口旋转持续渲染，无黑屏）
    await this.waitRotationStable();
    // ⭐ PC：无旋转 → 提前恢复进入前布局方向，使插值目标矩形按原布局计算
    this.pcSyncLayoutToFs(false);
    // ⭐ 恢复非全屏视频尺寸（fs 期间 videoDisplayWidth 被全屏 fit 覆盖，退出插值目标需要竖屏尺寸）
    if (!this.isLs) {
      this.updatePortraitSize();
    } else {
      // ⭐ 横屏退出：动画开始前刷新 lsvw/lsvh 为恢复后窗口的目标值——
      //    否则动画终点沿用旧值，fs=false 后 XComponent 跳到新 lsvw → 末帧又"缩一下"
      this.updateLSVSize();
      // ⭐ 退出全屏到横屏时，提前设置目标 ov 值——动画期间 ovRectX/ovRectW 用 ovX/ovW 插值，
      //    若沿用旧值（进入前竖屏portrait的ovX），动画终点与fs=false后initOverlayRectSync跳变
      if (this.ar < 1) {
        this.ovW = this.lsvw; this.ovH = this.lsvh;
        this.ovX = this.isLayoutSwapped ? (this.cw - this.lsvw - 80 - this.cardMargin) : (80 + this.cardMargin);
        this.ovY = this.cardMargin;
      } else {
        this.ovW = this.lsvw; this.ovH = this.lsvh;
        this.ovX = this.isLayoutSwapped ? (this.cw - this.lsvw - this.cardMargin) : this.cardMargin;
        this.ovY = this.cardMargin;
      }
    }
    logInfo(`[FSDBG] exit: rotation stable, start lerp P=${this.fsPanProgress} animDur=${this.FS_ANIM_DURATION} da=${this.da} plateVis=${this.fs && this.fsLerpDir !== 2} ovRect=(${this.ovRectW().toFixed(1)},${this.ovRectH().toFixed(1)})`);
    if (this.da) {
      this.fsPanProgress = 0;
    } else {
      animateTo({ duration: this.FS_ANIM_DURATION, curve: Curve.FastOutSlowIn }, () => {
        this.fsPanProgress = 0;
      });
    }
    await new Promise<void>(resolve => {
      this.fsAnimTimer_ = setTimeout(() => {
        this.fs = false;
        this.fsLerpStartP = 0;
        this.updateIsLandscapeVertical();
        this.updateVideoSize();  // ⭐ 恢复非全屏视频尺寸（fs 期间被全屏 fit 覆盖）
        // ⭐ 同步重算占位槽矩形：避免 fs=false 后 onAreaChange 异步更新 ovW/ovH 造成末帧几何跳变
        this.initOverlayRectSync();
        this.fsLerpDir = 0;
        logInfo(`[FSDBG] exit: fs=false P=${this.fsPanProgress} plateVis=${this.fs && this.fsLerpDir !== 2} ovRect=(${this.ovRectW().toFixed(1)},${this.ovRectH().toFixed(1)}) ovVideo=(${this.ovVideoW().toFixed(1)},${this.ovVideoH().toFixed(1)})`);
        // 恢复系统栏（屏幕方向已在提前阶段恢复）
        if (this.mw) this.manageSB();
        this.isAnimatingToFS = false;
        this.fsAnimTimer_ = -1;
        resolve();
      }, this.FS_ANIM_DURATION);
    });
  }

  /** ⭐ 等待旋转完成（rotationInProgress 清除）再开始退出插值；锁定横屏跳过（窗口不旋转） */
  private waitRotationStable(): Promise<void> {
    return new Promise<void>(resolve => {
      if (this.isPcDevice) { resolve(); return; }  // ⭐ PC：无旋转，直接继续
      const lock = AppStorage.get<string>('screenOrientationLock') ?? '自动旋转';
      if (lock === '锁定横屏') { resolve(); return; }
      const tryCheck = (retries: number): void => {
        if (!this.rotationInProgress || retries <= 0) { resolve(); return; }
        this.fsAnimTimer_ = setTimeout(() => { tryCheck(retries - 1); }, 100);
      };
      tryCheck(15);
    });
  }

  async toggleFS() {
    this.cancelDelayHide();
    // ⭐ 全屏切换会整体改变布局（提示的锚点/尺寸全都按旧布局算的）⇒ 手势提示必须收掉，
    //   而且**在这一刻收**才正确：它的 110ms 淡出与全屏转场同帧启动 = "直接换内容"。
    //   （触摸被系统取消时不清提示、只在这里清 —— 见 onTC 的长注释）
    this.clearGestureHint_();
    if (!this.mw || this.isAnimatingToFS) return;
    // ⭐ 全屏控制栏的"上一集/下一集"按钮可见性完全由这两个值决定，日志留痕便于排查
    logInfo(`[VideoPlayer] toggleFS: 分集数=${this.vd?.pages?.length ?? 0}, 当前索引=${this.currentPageIndex}, `
      + `hasNext=${this.hasNextEpisode()}, hasPrev=${this.currentPageIndex > 0}`);
    if (!this.fs) {
      await this.enterFullscreenAnimated();
    } else {
      await this.exitFullscreenAnimated();
    }
  }
  goBack() {
    if (this.fs) {
      this.toggleFS().finally(() => setTimeout(() => router.back(), 300));
    } else {
      this.release();
      router.back();
    }
  }

  goHome() {
    AppStorage.setOrCreate<boolean>('goHome', true);
    if (this.fs) {
      this.toggleFS().finally(() => setTimeout(() => router.back({ url: 'pages/Index' }), 300));
    } else {
      this.release();
      router.back({ url: 'pages/Index' });
    }
  }

  /**
   * ⭐ 4K 快速起播：判断本次起播是否要先降档。
   *
   * 为什么需要（实测 BV1qaJ86aEBd，4K）：
   *   4K（15Mbps）每 5 秒段 8~10MB，AVPlayer seek 后要预读 4 段 ≈ 40MB；
   *   在 8MB/s 的链路上物理下限就是 4~5 秒（tap→首帧 8.2s）。
   *   换成 1080P+ 后每段 ~3MB，同样 4 段只要 12MB —— 首帧能早 4 秒以上。
   * 出帧后由 scheduleUpgradeToWantedQn() 在后台升回 4K（那时用户已经在看内容了）。
   *
   * ⚠️ 不再要求“必须有续播点”：入口为首页/推荐时 initialProgress_ 恒为 0，
   *    真正的续播点要等 playurl 返回才知道，用旧条件会把这条路径整段漏掉。
   */
  private pickFastStartQn(): number {
    const want: number = this.qn;
    // ⭐ 开关关闭时直接按设置的最高画质请求（用户决定：宁可首帧慢，也不要播放中切档中断）
    if (!FAST_START_4K || want < 120) {
      return want;
    }
    // 用户可在设置里关掉（AppStorage 开关，默认开启）
    if (AppStorage.get<boolean>('fastStart4KDisabled') === true) {
      return want;
    }
    // ⚠️ 不能只在「路由已带进度」时降级：从首页/推荐/相关视频进来时
    //    initialProgress_ 恒为 0，真正的续播点是 playurl 返回后才拿到的
    //    （实测 BV1qaJ86aEBd 从首页进入：initialProgress=0，服务端续播点 60s，
    //     于是旧条件判成“不用降级”，又走了 7.16 秒的 4K 全量路径）。
    //    即使从 0:00 起播，4K 首段 6.5MB vs 1080P 2MB 也仍然值得降。
    const fallback: number = 112;   // 1080P+；服务端不支持时 getVideoPlayUrl 内部会再降
    this.fastStartQn_ = fallback;
    this.upgradeQn_ = want;
    logInfo(`[VideoPlayer] 4K 快速起播: 先用 qn=${fallback} 出帧（续播点未知也降级），随后自动升级到 qn=${want}`);
    return fallback;
  }

  /**
   * ⭐ 首帧已出后，把画质升回目标档（4K）——**先把目标档的分段预取进共享缓存，再切播放器**。
   *
   * 为什么这样做：切档必须重建 AVPlayer（新 MPD / 新 init 段），中断无法避免；
   * 但中断里最贵的是「重新下载 8~10MB/段的 4K 数据」（实测 4.6s）。
   * 现在提前用一个临时 DashPlayerBridge 把当前播放位置附近的 4K 分段拉进
   * DashMediaServer 的**进程级共享缓存**（cache/inflight 已改 static），
   * 正式切换时 prepare/seek 直接命中 ⇒ 中断只剩解码器重建那一下。
   */
  private scheduleUpgradeToWantedQn(): void {
    const target: number = this.upgradeQn_;
    if (!target || this.upgradeTimer_ >= 0) {
      return;
    }
    const delayMs: number = 2000;
    logInfo(`[VideoPlayer] 首帧已出，${delayMs}ms 后开始预热 ${target}（预取完再切档）`);
    this.upgradeTimer_ = setTimeout(() => {
      this.upgradeTimer_ = -1;
      if (!this.av || this.qs || this.ld) {
        logInfo('[VideoPlayer] 升级画质跳过: 播放器未就绪/正在切档');
        return;
      }
      if (this.qn === target) {
        logInfo('[VideoPlayer] 升级画质跳过: 已是目标画质');
        return;
      }
      this.prefetchUpgradeTarget(target).then(() => {
        if (!this.av || this.qs || this.ld) {
          logInfo('[VideoPlayer] 升级画质取消: 预热期间播放器已变化');
          return;
        }
        if (this.qn === target) {
          return;
        }
        logInfo(`[VideoPlayer] 快速起播完成，升级画质 ${this.qn} -> ${target}`);
        this.upgradeQn_ = 0;
        // ⭐ 标记为“自动升档”：switchQ 里据此跳过 defaultVideoQn 持久化
        this.autoUpgradeInProgress_ = true;
        this.switchQ(target).catch((e: Error) => logError(`[VideoPlayer] 升级画质失败: ${e}`))
          .finally(() => { this.autoUpgradeInProgress_ = false; });
      });
    }, delayMs);
  }

  /**
   * ⭐ 预热目标画质：用临时 bridge 拉起转播站，把「当前播放位置」附近的 4K 分段
   * 下载进 DashMediaServer 的静态缓存，然后停掉临时转播站（缓存保留）。
   * 失败不影响播放（切档时会走原来的冷下载路径）。
   */
  private async prefetchUpgradeTarget(target: number): Promise<void> {
    if (!this.vi.cid || this.vi.cid <= 0) {
      return;
    }
    const posMs: number = Math.max(0, Math.round(this.ct * 1000));
    let warm: DashPlayerBridge | null = null;
    try {
      const r: PlayUrlResult = this.isPgc_
        ? await getPgcPlayUrl(this.epId_, this.vi.cid, target, this.seasonId_)
        : await getVideoPlayUrl(this.vi.bvid, this.vi.cid, target);
      if (!r.dash) {
        return;
      }
      warm = new DashPlayerBridge();
      await warm.buildAndStart(
        r.dash, 'https://www.bilibili.com/',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        AppStorage.get<string>('biliCookie') || '', posMs);
      logInfo(`[VideoPlayer] ${target} 预热: 转播站已就绪(pos=${this.ct}s)，等待分段落地`);
      // 目标段 8~10MB，给 2.5s 让预取把「当前段 + 起始段」拉完（超出也在播放器侧回源）
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => resolve(), 2500);
      });
      logInfo(`[VideoPlayer] ${target} 预热完成，准备切档`);
    } catch (e) {
      logWarn(`[VideoPlayer] ${target} 预热失败: ${e}`);
    } finally {
      if (warm) {
        // 只停临时转播站；静态缓存里的分段保留给正式切档复用
        await warm.stopIfRunning();
      }
    }
  }

  async switchQ(n: number) {
    if (this.qs || n === this.qn) return;
    // ⭐ 用户手动切了画质 → 放弃快速起播的自动升级（手动优先）
    this.upgradeQn_ = 0;
    if (this.upgradeTimer_ >= 0) {
      clearTimeout(this.upgradeTimer_);
      this.upgradeTimer_ = -1;
    }
    this.qs = true;
    const st = this.ct;
    const wp = this.play;
    this.release();
    this.ld = true;
    try {
      const result: PlayUrlResult = this.isPgc_
        ? await getPgcPlayUrl(this.epId_, this.vi.cid, n, this.seasonId_)
        : await getVideoPlayUrl(this.vi.bvid, this.vi.cid, n);
      const url = result.url;
      if (!url) throw new Error('no url');
      this.av = await media.createAVPlayer();
      if (!this.av) throw new Error('no player');
      this.setupL();
      // ⭐ DASH 双流：转播站（与 initP 同一链路）；FLV 直连
      if (result.audioUrl && result.dash) {
        this.isDashStream_ = true;
        this.dashBridge_ = new DashPlayerBridge();
        const playerUrl = await this.dashBridge_.buildAndStart(
          result.dash, 'https://www.bilibili.com/',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          AppStorage.get<string>('biliCookie') || '',
          // ⭐ 切画质后下面会 seek 回 st（第 5451 行 `this.av.seek(st * 1000)`），
          //    把该时刻的分段在 prepare 期间先拉好，否则切一次画质就要重付一次冷分段下载
          Math.max(0, Math.round(st * 1000)));
        if (!playerUrl) {
          this.err = 'DASH 转播站启动失败';
          logError(`[VideoPlayer] switchQ buildAndStart 失败`);
          this.release();
          this.qs = false;
          return;
        }
        const src = media.createMediaSourceWithUrl(playerUrl, {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/'
        });
        await this.av.setMediaSource(src);
      } else {
        this.isDashStream_ = false;
        const src = media.createMediaSourceWithUrl(url, {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://www.bilibili.com/'
        });
        await this.av.setMediaSource(src);
        if (result.audioUrl) {
          this.avAudio = await media.createAVPlayer();
          if (this.avAudio) {
            this.setupAudioL();
            const audioSrc = media.createMediaSourceWithUrl(result.audioUrl, {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
              'Referer': 'https://www.bilibili.com/'
            });
            await this.avAudio.setMediaSource(audioSrc);
          }
        }
      }
      if (this.sId) {
        this.av.surfaceId = (this.nativeSurfaceId_ || this.sId);
        if (this.av.state === 'initialized') await this.av.prepare();
      }
      this.qn = result.actualQn || n;
      this.applyAcceptQuality(result);
      this.ql = this.getQlLabel(this.qn);
      // ⭐ 只持久化【用户主动、且服务端如其所愿】的切换：
      //    1) 自动升级（4K 快速起播）不能改用户设置 —— 否则「默认 4K 的用户看了几个
      //       不支持 4K 的视频后，defaultVideoQn 被永久改成 1080P」（实测 16:48 发生）；
      //    2) 服务端降级（请求 120 实际给 112）同样不覆盖用户意愿。
      if (!this.autoUpgradeInProgress_ && this.qn === n) {
        AppStorage.set<number>('defaultVideoQn', this.qn);
      }
      await new Promise<void>(r => {
        const iv = setInterval(() => {
          if (this.av && (this.av.state === 'prepared' || this.av.state === 'playing')) {
            clearInterval(iv);
            r();
          }
        }, 100);
        setTimeout(() => { clearInterval(iv); r(); }, 10000);
      });
      if (st > 0 && this.av) {
        this.av.seek(st * 1000);
        this.avAudio?.seek(st * 1000);
      }
      if (wp && this.av) {
        await this.av.play();
        await this.avAudio?.play();
      }
      this.sBH(undefined, this.ql);
    } catch (e) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '画质切换失败' });
      } catch (err) {
        logWarn(`showToast 异常: ${errMsg(err)}`);
      }
      this.retry();
    } finally {
      this.qs = false;
    }
  }

  private retry() {
    if (this.ry_) return;
    if (this.rc_ >= this.mr_) {
      this.err = '播放失败，已达到最大重试次数';
      this.ld = false;
      return;
    }
    this.ry_ = true;
    this.rc_++;
    this.ld = true;
    this.err = '';
    if (this.rt_ !== -1) clearTimeout(this.rt_);
    this.rt_ = setTimeout(async () => {
      this.rt_ = -1;
      this.release();
      this.ry_ = false;
      await this.initP();
    }, 1000);
  }

  fmtT = (s: number): string => {
    if (isNaN(s)) s = 0;
    const sec = Math.floor(s);
    const m = Math.floor(sec / 60);
    const rs = sec % 60;
    return `${m.toString().padStart(2, '0')}:${rs.toString().padStart(2, '0')}`;
  }

  fmtTA = (ts: number): string => {
    const d = Math.floor(Date.now() / 1000) - ts;
    if (d < 60) return '刚刚';
    if (d < 3600) return `${Math.floor(d / 60)}分钟前`;
    if (d < 86400) return `${Math.floor(d / 3600)}小时前`;
    if (d < 2592000) return `${Math.floor(d / 86400)}天前`;
    const dt = new Date(ts * 1000);
    return `${dt.getFullYear()}-${(dt.getMonth() + 1).toString().padStart(2, '0')}-${dt.getDate().toString().padStart(2, '0')}`;
  }

  fmtN = (n: number): string => {
    if (n >= 10000) return `${(n / 10000).toFixed(1)}万`;
    return n.toString();
  }

  // 根据播放量返回颜色
  getPlayCountColor = (count: number): string => {
    if (count >= 10000000) return '#FF0000';
    if (count >= 3000000) return '#C2185B';
    if (count >= 1000000) return '#FF8C00';
    if (count >= 100000) return '#FFB800';
    if (count >= 50000) return '#4A90D9';
    return '#999999';
  }

  // 获取 LV 等级背景色
  getLevelBgColor = (level: number): string => {
    switch (level) {
      case 0: return '#9E9E9E';
      case 1: return '#62D560';
      case 2: return '#62D560';
      case 3: return '#40B5FF';
      case 4: return '#FFB800';
      case 5: return '#FF8C00';
      case 6: return '#FF4444';
      default: return '#9E9E9E';
    }
  }

  private updatePortraitSize() {
    const containerWidth = this.cw - 2 * this.cardMargin;
    const containerHeight = this.ch;
    if (containerWidth <= 0 || containerHeight <= 0) return;
    const videoAspect = this.ar || 16 / 9;
    let dw = containerWidth;
    let dh = containerHeight;
    // ⭐ 与横屏一致：容器严格按视频真实宽高比适配（SCALED_ASPECT 自动模式 → 无黑边）
    if (containerWidth / containerHeight > videoAspect) {
      dh = containerHeight;
      dw = containerHeight * videoAspect;
    } else {
      dw = containerWidth;
      dh = containerWidth / videoAspect;
    }
    // 竖屏视频时，限制高度不超过屏幕高度的60%
    if (videoAspect < 1 && dh > containerHeight * 0.6) {
      dh = containerHeight * 0.6;
      dw = dh * videoAspect;
    }
    this.videoDisplayWidth = Math.max(1, dw);
    this.videoDisplayHeight = Math.max(1, dh);
  }

  /** cardMargin 变化时重新计算竖屏视频尺寸 */
  onCardMarginChange(): void {
    if (!this.isLs && !this.fs) {
      this.updatePortraitSize();
    }
  }

  private updateVideoSizeByScaleMode() {
    const containerWidth = this.cw;
    const containerHeight = this.ch;
    if (containerWidth <= 0 || containerHeight <= 0) return;
    const videoAspect = this.ar || 16 / 9;
    let dw = containerWidth;
    let dh = containerHeight;
    switch (this.sm) {
      case 'stretch':
        // 拉伸模式：使用完整容器尺寸，不受padding影响
        dw = this.cw;
        dh = this.ch;
        break;
      case 'fill':
        if (containerWidth / containerHeight > videoAspect) {
          dh = containerWidth / videoAspect;
        } else {
          dw = containerHeight * videoAspect;
        }
        break;
      case 'fitHeight':
        dw = containerHeight * videoAspect;
        dh = containerHeight;
        break;
      case 'fitWidth':
        dw = containerWidth;
        dh = containerWidth / videoAspect;
        break;
      default:
        if (containerWidth / containerHeight > videoAspect) {
          dw = containerHeight * videoAspect;
        } else {
          dh = containerWidth / videoAspect;
        }
        break;
    }
    this.videoDisplayWidth = Math.max(1, dw);
    this.videoDisplayHeight = Math.max(1, dh);
  }

  // 根据当前缩放模式获取对应的 VideoScaleType
  private getVideoScaleType(): media.VideoScaleType {
    switch (this.sm) {
      case 'stretch':
        // 拉伸模式：强制拉伸视频至窗口大小，不保持宽高比
        return media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
      case 'fill':
      case 'fitHeight':
        // 填充模式/等高模式：保持宽高比，裁剪填充
        return media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP;
      case 'auto':
      case 'fitWidth':
      default:
        // ⭐ 自动模式：保持宽高比完整显示（与横屏一致，全屏竖屏不再裁剪填充）
        return media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT;
    }
  }

  private updateVideoSize() {
    if (!this.isLs && !this.fs) { this.updatePortraitSize(); return; }
    if (this.cw <= 0 || this.ch <= 0) return;
    const hPad = (!this.isLs && !this.fs) ? 24 : 0;
    const containerWidth = this.cw - hPad;
    const containerHeight = this.ch;
    const videoAspect = this.ar || 16 / 9;
    let dw = containerWidth;
    let dh = containerHeight;
    switch (this.sm) {
      case 'stretch':
        // 拉伸模式：忽略视频宽高比，直接拉伸到容器大小
        dw = this.cw;
        dh = this.ch;
        break;
      case 'fill':
        if (containerWidth / containerHeight > videoAspect) {
          dh = containerWidth / videoAspect;
        } else {
          dw = containerHeight * videoAspect;
        }
        break;
      case 'fitHeight':
        dw = containerHeight * videoAspect;
        dh = containerHeight;
        break;
      case 'fitWidth':
        dw = containerWidth;
        dh = containerWidth / videoAspect;
        break;
      default:
        // ⭐ 自动模式：保持视频真实宽高比完整显示（横屏/竖屏全屏统一，不留裁剪）
        if (containerWidth / containerHeight > videoAspect) {
          dw = containerHeight * videoAspect;
        } else {
          dh = containerWidth / videoAspect;
        }
        break;
    }
    this.videoDisplayWidth = Math.max(1, dw);
    this.videoDisplayHeight = Math.max(1, dh);
  }

  private onCA = (o: Area, n: Area) => {
    const w = n.width as number;
    const h = n.height as number;
    // ⭐ onAreaChange 在布局阶段回调：@State 更新延迟到本帧渲染结束后，避免“渲染中改状态”
    //    框架报错与评论区/详情卡闪烁（onSlotArea/onColumnArea 同理）
    setTimeout(() => {
      const was = this.isLs;
      this.cw = w;
      this.ch = h;
      // ⭐ 横竖屏切换：XComponent 常驻单实例，surface 不再重建，直接切换布局；
      //    rotationInProgress 供退出全屏插值等待旋转完成 + 旋转期间暂停评论头像预解码
      if (w > h !== was) {
        this.rotationInProgress = true;
        this.commentRenderCountFull = this.commentRenderCount;
        this.commentRenderCount = 20;  // 旋转期间降到20：旧分支卸载多余条目，transition退场只淡出20条不卡
        this.applyOrientationState(w, h, was);
        setTimeout(() => {
          this.rotationInProgress = false;
          // 分批恢复累积配额，避免一次性 ForEach 增量挂载 N-20 条卡顿
          const target = this.commentRenderCountFull;
          const step = () => {
            if (this.commentRenderCount < target) {
              this.commentRenderCount = Math.min(this.commentRenderCount + 20, target);
              setTimeout(step, 30);
            }
          };
          step();
        }, 450);
      } else {
        // 尺寸变化但方向未翻转：直接同步更新布局
        this.applyOrientationState(w, h, was);
      }
    }, 0);
  }

  /** 根据新的窗口尺寸更新方向相关布局状态（isLs → build 分支切换） */
  private applyOrientationState(w: number, h: number, was: boolean): void {
    this.isLs = w > h;
    this.updateIsLandscapeVertical();
    // ⭐ force：旋转后重新管理状态栏（全屏 fs=true 时非 force 的 manageSB 直接 return，
    //   旋转会重置系统状态栏显示——force 确保全屏/横屏旋转后仍隐藏状态栏）
    if (this.isLs !== was) this.manageSB(true);
    this.updateVideoSize();
    if (this.isLs) {
      this.updateLSVSize();
      // 切到横屏时恢复视频大小（竖屏评论区上滑的缩小模式不适用于横屏）
      if (this.vidShrink > 0) {
        this.animateVidShrink(0);
      }
    }
    // ⭐ 方向/尺寸变化时重新计算拇指热区位置
    this.recalcSmartGripPosition();
  }

  private onVT = (e: TouchEvent) => {
    // ⭐ 关灯短视频：视频卡自带触摸层（点击暂停 / 上滑切换），旧的亮度/音量/seek 手势整体让位
    if (this.isShortVideo()) return;
    // ⭐ 进度条交互期间播放器手势必须整体让位。
    //   `sliderDragging_` 覆盖「按下 → 提交」，`seekBarTouch_` 再覆盖「提交 → 手指抬起」那一小段
    //   （提交发生在 onChange 的 End/Click，实测早于 onTouch Up，详见字段注释）。
    //   官方明确"终止冒泡并不会中断父组件对手势的响应处理"，所以父节点的 PanGesture 只能靠
    //   页面侧显式 return 让位（几处 PanGesture 里都加了同样的守卫）。
    if (this.sliderDragging_ || this.seekBarTouch_) {
      // ⭐ 触摸真正结束（Up/Cancel）时才撤窗口标记 —— 提交那一刻就撤会让 Up 掉进 onTU，
      //   导致在途 seek 被提前解冻（时间显示回退）+ 控制栏闪一下
      if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.seekBarTouch_ = false;
        if (this.seekBarTouchTimer_ !== -1) {
          clearTimeout(this.seekBarTouchTimer_);
          this.seekBarTouchTimer_ = -1;
        }
      }
      return;
    }
    if (this.lk) {
      // 锁定状态下不处理触摸事件，由Stack的onClick统一处理解锁按钮的显示/隐藏/解锁
      // 不return，允许事件继续传播到子组件（如解锁按钮Row的onClick）
    } else {
      // 非锁定状态下的触摸处理
      switch (e.type) {
        case TouchType.Down:
          // ⭐ 全屏时，触摸起点在顶栏实测高度内（fullscreenTopBarHeight 由 VideoControls 写入，横屏/竖屏/密度自适应）→ 跳过播放器手势，防止点击穿透误触发单击隐藏控制栏
          const topBarBottom = (AppStorage.get<number>('fullscreenTopBarHeight') ?? 96) + 16;
          if (this.fs && e.touches.length > 0 && e.touches[0].windowY < topBarBottom) {
            this.topAreaTouch_ = true;
            return;
          }
          this.topAreaTouch_ = false;
          this.onTD(e);
          break;
        case TouchType.Move:
          if (this.topAreaTouch_) return;
          this.onTM(e);
          break;
        case TouchType.Up:
          if (this.topAreaTouch_) { this.topAreaTouch_ = false; return; }
          this.onTU(e);
          break;
        case TouchType.Cancel:
          if (this.topAreaTouch_) { this.topAreaTouch_ = false; return; }
          this.onTC();
          break;
      }
    }
  }

  private onTD(e: TouchEvent) {
    const t = e.touches[0];
    this.sx_ = t.windowX;
    this.sy_ = t.windowY;
    this.st_ = this.ct;
    this.sv_ = this.vol;
    this.sb_ = this.bri;
    this.ml_ = false;
    this.la_ = false;
    this.dtp_ = false;
    this.wcv_ = this.cv;

    // 双击检测：如果上次抬起到这次按下在250ms内，视为双击
    if (this.dt_ !== -1) {
      clearTimeout(this.dt_);
      this.dt_ = -1;
      this.dtp_ = true;

      // 立即触发双击：暂停/播放
      this.togglePP();

      // 清除之前可能设置的延迟隐藏timer
      this.cancelDelayHide();

      // 无需撤销控制栏——dt_已被清除，cv从未被设为true，绝无闪现
      return;
    }

    // 第一次点击，设置长按计时器
    this.lt_ = setTimeout(() => {
      if (!this.ml_ && !this.lk) {
        this.la_ = true;
        this.lp_ = true;
        this.os_ = this.rt;
        this.setRate(2.0, false);
        // 直接设置手势提示，不用 sGH（sGH 会 800ms 后自动隐藏）
        this.ght = '长按加速';
        this.gh = true;
        this.ghp = -1;
        this.ghtType = '';
        if (this.gt_ !== -1) { clearTimeout(this.gt_); this.gt_ = -1; }
      }
    }, 500);
  }

  private onTM(e: TouchEvent) {
    if (e.touches.length === 0) return;
    const t = e.touches[0];
    const dx = t.windowX - this.sx_;
    const dy = this.sy_ - t.windowY;
    const adx = Math.abs(dx);
    const ady = Math.abs(dy);
    if (adx > 10 || ady > 10) {
      this.ml_ = true;
      if (this.lt_ !== -1) { clearTimeout(this.lt_); this.lt_ = -1; }
    }
    if (this.la_) return;
    if (this.gm_ === '') {
      // ⭐ 位移阈值 25→10vp：快速短滑（move 少、位移小）也能触发手势，避免被点击吞掉
      // 方向判定放宽：adx >= ady*0.8 视为水平主导（容忍手指轻微纵向抖动），垂直主导才走音量/亮度
      if (adx > 10 || ady > 10) {
        if (adx >= ady * 0.8) {
          this.gm_ = 'seek';
          this.lastSeekHapticPct_ = -1;  // 重置档位震动追踪，让拖动中第一次反馈正常触发
          this.triggerHaptic();  // 触觉反馈：开始拖拽进度
        } else {
          // 根据播放器模式确定触控区域中心点
          let centerX: number;
          if (this.isLandscapeVertical) {
            // 横屏非全屏竖屏视频：播放器起始x=150vp，宽度=lsvw
            centerX = 150 + this.lsvw / 2;
          } else {
            // 其他模式：使用屏幕宽度的一半
            centerX = this.cw / 2;
          }
          if (t.windowX < centerX) {
            this.gm_ = 'brightness';
          } else {
            this.gm_ = 'volume';
          }
          // 重置档位震动追踪，让拖动过程中的第一次震动正常触发
          this.lastHapticPct_ = -1;
          this.triggerHaptic();  // 触觉反馈：开始调节音量/亮度
        }
      } else return;
    }
    if (this.gm_ === 'seek') {
      // ⭐ 时长未知（加载中 / 直播）时不能按比例换算：原先 nt 恒等于按下位置，
      //   却照样弹手势提示并震动，看起来"拖了没反应"
      if (this.dur <= 0) return;
      // ⭐ 提示胶囊右侧"相对位移"的起点 = 手指落下时的播放位置
      //   （st_ 在 onTD 里记录，整个手势内不变；重复赋值开销可忽略）
      this.ghb = this.st_;
      // ⭐ 灵敏度按时长自适应：原先固定 dur * 0.3 —— 2 小时视频整屏宽滑 = 36 分钟，
      //   1vp ≈ 35 秒，想微调 5 秒物理上做不到
      const secPerScreen = this.dur <= 600 ? this.dur * 0.5
        : (this.dur <= 3600 ? this.dur * 0.3 : Math.max(this.dur * 0.12, 600));
      // ⭐ 分母用播放器实际可滑动宽度：横屏非全屏竖屏视频模式下播放器只有 lsvw 宽、起点 x=150，
      //   用整屏宽 cw 会让该模式的手感与其它模式不一致
      //   （音量/亮度区域判定已区分该模式，见上方 centerX，seek 这里原先漏了）
      const trackW = this.isLandscapeVertical ? Math.max(1, this.lsvw) : Math.max(1, this.cw);
      let nt = this.st_ + (dx / trackW) * secPerScreen;
      nt = Math.min(Math.max(nt, 0), this.dur);
      this.ct = nt;
      this.sk_ = true;
      // ⭐ 档位震动：与音量/亮度"每跨越 10% 震一次"的手感对齐
      //   （原先 seek 全程只在手势起点震一次，三种手势反馈不对称）
      const seekPct = Math.round(nt / this.dur * 100);
      if (this.lastSeekHapticPct_ === -1 || Math.abs(seekPct - this.lastSeekHapticPct_) >= 10) {
        this.fireHaptic(10);
        this.lastSeekHapticPct_ = seekPct;
      }
      this.sGH(`${this.formatDuration(Math.round(nt))}`, nt / this.dur, 'seek');
      // ⭐ 缩略图预览：显示目标位置的画面（与提示胶囊同一套显隐）
      this.updateSeekThumb_(nt);
    } else if (this.gm_ === 'volume') {
      // 灵敏度：screenH_ 与 dy 同单位（vp），直接用高度×系数
      // ×0.7 让满屏滑动 ≈ 143%变化（边界clamp到0~1），手势更灵敏
      const volSensitivity = this.screenH_ > 0 ? this.screenH_ * 0.7 : 700
      let v = this.sv_ + dy / volSensitivity;
      v = Math.min(1, Math.max(0, v));
      this.vol = v;
      if (this.av) {
        const s = this.av.state;
        if (s === 'prepared' || s === 'playing' || s === 'paused' || s === 'completed')
          try { this.av.setVolume(1.0); } catch (e) { }
      }
      if (this.avAudio) {
        try { this.avAudio.setVolume(1.0); } catch (e) { }
      }
      this.setSystemVolume(v);
      this.mute = (v === 0);
      AppStorage.setOrCreate('globalVolume', this.vol);
      AppStorage.setOrCreate('globalMuted', this.mute);
      this.sGH(`${Math.round(v * 100)}%`, v, 'volume');
      // 每跨越10%档位震动一次
      const volPct = Math.round(v * 100);
      if (this.lastHapticPct_ === -1 || Math.abs(volPct - this.lastHapticPct_) >= 10) {
        this.fireHaptic(12);
        this.lastHapticPct_ = volPct;
      }
    } else if (this.gm_ === 'brightness') {
      // 灵敏度：screenH_ 与 dy 同单位（vp），直接用高度×系数
      // ×0.7 让满屏滑动 ≈ 143%变化（边界clamp到0~1），手势更灵敏
      const briSensitivity = this.screenH_ > 0 ? this.screenH_ * 0.7 : 700
      let b = this.sb_ + dy / briSensitivity;
      b = Math.min(1, Math.max(0, b));
      this.bri = b;
      this.mw?.setWindowBrightness(b);
      this.sGH(`${Math.round(b * 100)}%`, b, 'brightness');
      // 每跨越10%档位震动一次
      const briPct = Math.round(b * 100);
      if (this.lastHapticPct_ === -1 || Math.abs(briPct - this.lastHapticPct_) >= 10) {
        this.fireHaptic(12);
        this.lastHapticPct_ = briPct;
      }
    }
  }

  private onTU(e: TouchEvent) {
    // 保存长按状态，用于后续判断
    const wasLongPress = this.la_;
    const wasMoved = this.ml_;

    if (this.lp_) {
      this.lp_ = false;
      this.setRate(this.os_, false);
    }
    if (this.lt_ !== -1) { clearTimeout(this.lt_); this.lt_ = -1; }
    this.la_ = false;
    // 长按结束时隐藏加速提示
    if (wasLongPress) {
      if (this.gt_ !== -1) { clearTimeout(this.gt_); this.gt_ = -1; }
      this.gh = false;
    }
    // ⭐ 手势拖动结束：走交互快速路径（SEEK_CLOSEST + 更短首帧等待）
    if (this.sk_ && this.av) { this.sk_ = false; this.seek(this.ct, false, true); }

    // 单击处理：控制栏已显示时200ms后隐藏，按钮回调可取消
    if (!this.dtp_ && !wasMoved && !wasLongPress) {
      if (this.cv) {
        this.ip = false;
        // 取消之前待处理的延迟隐藏
        this.cancelDelayHide();
        // 200ms后隐藏控制栏，按钮的onClick可以在之前取消
        this.hc_ = setTimeout(() => {
          this.cv = false;
          this.hc_ = -1;
        }, 200);
      } else {
        // 不立即显示控制栏——由dt_超时（250ms）确认无双击后再显示，彻底避免闪现
        this.cancelDelayHide();
        if (this.ct_ !== -1) { clearTimeout(this.ct_); this.ct_ = -1; }
      }

      // 设置250ms双击等待窗口
      if (this.dt_ !== -1) { clearTimeout(this.dt_); }
      this.dtwcv_ = this.wcv_;  // 标记本次单击时cv的状态：false→dt_负责显示，true→dt_纯等待双击
      this.dt_ = setTimeout(() => {
        this.dt_ = -1;
        // 如果cv尚未显示且本次单击时cv为false，说明是"单击显示"场景
        if (!this.cv && !this.dtwcv_) {
          this.cv = true;
          this.schedAH();
        }
      }, 250);
    }
    this.gm_ = '';
    this.ml_ = false;
  }

  private onTC() {
    if (this.lp_) {
      this.lp_ = false;
      this.setRate(this.os_, false);
    }
    if (this.lt_ !== -1) { clearTimeout(this.lt_); this.lt_ = -1; }
    const wasLongPress: boolean = this.la_;
    this.la_ = false;
    // ⭐ 触摸被取消时**只有长按加速提示必须立刻收**（2026-09-24 按用户反馈重构，见下）
    //   理由：长按提示是 onTD 的 lt_ 分支**直接** `gh = true` 的，同时把 `gt_` 清成 -1
    //   ⇒ 它**根本没有 800ms 自动隐藏定时器**，只能靠 onTU/onTC 显式清，不清就永久留在屏幕上。
    if (wasLongPress) {
      if (this.gt_ !== -1) { clearTimeout(this.gt_); this.gt_ = -1; }
      this.gh = false;
    }
    // ⛔⛔ **普通手势提示（seek 填充条 / 音量·亮度竖条）不要在这里清**。
    //
    //   用户反馈：「音量/亮度竖条 / seek 填充条 / 长按加速胶囊 **显示时右滑会先退出**这些提示」。
    //   这里的"右滑"是**系统侧滑返回**。时序是这样的（这是问题的全部根因）：
    //     ① 手指从屏幕左边缘往右滑 → 系统**在识别到返回手势的那一刻**就给播放器发一次
    //        `TouchType.Cancel`（触摸流被系统接管）⇒ 走到这里；
    //     ② 而 `onBackPress()`（本页 = 退出全屏 / 开灯 / 页面 pop）要等**手指抬起并越过阈值**
    //        才触发。
    //   ① 和 ② 之间隔着整段拖动（几百毫秒）—— 原先这里无条件 `gh = false`，提示在①就
    //   **淡出干净**了，而屏幕此时还没有任何转场 ⇒ 用户看到的就是
    //   「提示先退出去 → 中间空一下 → 才轮到转场」。
    //   ⇒ 正解：**取消不当作"手势结束"**，提示保持显示，交给 sGH 的 800ms 自然超时
    //   （手指没再给新数据就一直亮着，符合"松手后残留一会儿"的既有手感）；
    //   真正离开（退出全屏 / 开灯）时由 `clearGestureHint_()` 在**转场同一帧**收掉 ⇒ 无缝交接。
    //   ⚠️ 所以这里也**不能**去清 `gt_` —— 那个定时器正是"没人管我时自己淡出"的保障。
    //   ⚠️ 侧滑返回到一半又放回（手势中止）时，页面没走、提示也还在 ⇒ 行为正确。
    //  其余真·取消（按 Home 键 / 折叠屏折叠 / 手写笔介入 / 来电打断）同理：多留 ≤800ms 无害，
    //  应用已不可见或即将不可见。
    if (this.gm_ === 'seek' && this.sk_ && this.av && this.dur > 0) {
      this.sk_ = false;
      this.seek(this.ct, false, true);
    }
    this.gm_ = '';
    this.sk_ = false;
    this.ml_ = false;
  }

  /**
   * ⭐ 立刻收掉手势提示（含 800ms 自动隐藏定时器与 seek 缩略图）。
   *
   * 只在"用户**真的要离开**当前画面"时调用：退出/进入全屏、关灯→开灯、页面 pop。
   * 目的是把提示的退场动画（弹层淡出 + 内容卷帘收起）**并进转场**：两者同一帧启动 ⇒ 读起来是"直接换内容"，
   * 而不是"提示先退出去、中间空一下、才轮到转场"（见 onTC 的长注释）。
   * ⚠️ 不要拿它当 onTC 的替代 —— 触摸被系统取消并不等于用户要离开。
   */
  private clearGestureHint_(): void {
    if (this.gt_ !== -1) { clearTimeout(this.gt_); this.gt_ = -1; }
    this.gh = false;
    this.hideSeekThumb_();
  }

  // ⭐ 镜像布局：比例/画质/更多弹窗跟随全屏控制栏镜像（面板改从左侧滑入、关闭区换到右侧）
  private mirrorPopup(): boolean {
    return this.isMirrorControls && this.fs;
  }

  @Builder
  bSP() {
    Stack() {
      // ⭐ 点击关闭区域 — 透明（镜像布局时在右侧）
      Column().width(this.isLs ? '60%' : '50%').height('100%')
        .position(this.mirrorPopup() ? { right: 0, top: 0 } : { left: 0, top: 0 })
        .onClick(() => { this.sp = false; this.ip = false; if (this.cv) this.resetCT(); });

      // ⭐ 渐变背景 — 加宽 + 多段渐变（镜像布局时滑入方向与渐变反向）
      Column() {
        // 标题（白色，不跟随系统主题）
        Text('画面比例').fontSize(16).fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
          .padding({ left: 4, right: 4, top: 0, bottom: 12 })
          .offset({ x: this.mirrorPopup() ? 14 : -14, y: -12 });

        // 每个选项是独立圆角矩形，依次从右侧滑入
        ForEach(this.sl_, (it: SO, index: number) => {
          Row() {
            Text(it.label).fontSize(15)
              .fontColor(this.sm === it.mode ? this.playerFollowTheme ? this.customThemeColor : '#FB7299' : Color.White)
              .fontWeight(this.sm === it.mode ? FontWeight.Bold : FontWeight.Normal);
          }
          .height(48)
          .justifyContent(FlexAlign.Center)
          .padding({ left: 36, right: 36 })
          .backgroundColor(this.sm === it.mode ? this.playerFollowTheme ? '#' + this.opacityToHexAlpha(15) + this.customThemeColor.slice(1) : 'rgba(255, 85, 170, 0.15)' : 'rgba(0, 0, 0, 0.35)')
          .border({ width: this.sm === it.mode ? 1.5 : 0, color: this.playerFollowTheme ? this.customThemeColor : '#FB7299' })
          .borderRadius(12)
          .margin({ bottom: 12 })
          .onClick(() => {
            const previousMode = this.sm;
            this.sm = it.mode;
            const isSwitchingToStretch = it.mode === 'stretch';
            const isSwitchingFromStretch = previousMode === 'stretch' && it.mode !== 'stretch';

            if (isSwitchingToStretch) {
              try { if (this.av) { this.av.videoScaleType = this.getVideoScaleType(); } } catch (e) { }
            }
            this.saveSM();
            this.sp = false;
            this.ip = false;
            if (this.cv) this.resetCT();
            animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
              if (!isSwitchingFromStretch) {
                try { if (this.av) { this.av.videoScaleType = this.getVideoScaleType(); } } catch (e) { }
              }
              this.updateVideoSize();
            });
            if (isSwitchingFromStretch) {
              setTimeout(() => {
                try { if (this.av) { this.av.videoScaleType = this.getVideoScaleType(); } } catch (e) { }
              }, 200);
            }
          })
          // 进入：从右侧较远位置依次滑入；退出：依次向右滑出
          .transition(
            this.icp ? TransitionEffect.IDENTITY :
              TransitionEffect.asymmetric(
                TransitionEffect.translate({ x: this.mirrorPopup() ? -60 : 60 }).combine(TransitionEffect.opacity(0))
                  .animation({ duration: 450, curve: Curve.EaseOut, delay: index * 100 }),
                TransitionEffect.translate({ x: this.mirrorPopup() ? -40 : 40 }).combine(TransitionEffect.opacity(0))
                  .animation({ duration: 300, curve: Curve.EaseIn, delay: index * 100 })
              )
          )
          .offset({ x: this.mirrorPopup() ? 14 : -14 });
        }, (it: SO) => it.mode);
      }
      .width(this.isLs ? '30%' : '50%')
      .height('100%')
      .linearGradient({
        direction: this.mirrorPopup() ? GradientDirection.Left : GradientDirection.Right,
        colors: [
          ['rgba(0,0,0,0)', 0],
          ['rgba(0,0,0,0)', 0.25],
          ['rgba(0,0,0,0.95)', 1]
        ]
      })
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 60, left: this.mirrorPopup() ? 50 : 48, right: this.mirrorPopup() ? 48 : 50 })
      .position(this.mirrorPopup() ? { left: 0, top: 0 } : { right: 0, top: 0 });
    }
    .width('100%').height('100%')
    .transition(
      this.icp ? TransitionEffect.IDENTITY :
        TransitionEffect.asymmetric(
          TransitionEffect.translate({ x: this.mirrorPopup() ? '-100%' : '100%' }).combine(TransitionEffect.opacity(0))
            .animation({ duration: 400, curve: Curve.EaseOut }),
          TransitionEffect.opacity(0)
            .animation({ duration: 700, curve: Curve.EaseIn })
        )
    );
  }

  @Builder
  bCP() {
    Stack() {
      // ⭐ 点击关闭区域 — 透明（镜像布局时在右侧）
      Column().width(this.isLs ? '60%' : '50%').height('100%')
        .position(this.mirrorPopup() ? { right: 0, top: 0 } : { left: 0, top: 0 })
        .onClick(() => { this.colorStylePopup = false; this.ip = false; if (this.cv) this.resetCT(); });

      // ⭐ 渐变背景 — 加宽 + 多段渐变（镜像布局时滑入方向与渐变反向）
      Column() {
        // 标题（白色，不跟随系统主题）
        Text('画风').fontSize(16).fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
          .padding({ left: 4, right: 4, top: 0, bottom: 12 })
          .offset({ x: this.mirrorPopup() ? 14 : -14, y: -12 });

        // 每个选项是独立圆角矩形，依次从右侧滑入
        ForEach(this.cl_, (it: CO, index: number) => {
          Row() {
            Text(it.label).fontSize(15)
              .fontColor(this.cs === it.mode ? this.playerFollowTheme ? this.customThemeColor : '#FB7299' : Color.White)
              .fontWeight(this.cs === it.mode ? FontWeight.Bold : FontWeight.Normal);
          }
          .height(48)
          .justifyContent(FlexAlign.Center)
          .padding({ left: 36, right: 36 })
          .backgroundColor(this.cs === it.mode ? this.playerFollowTheme ? '#' + this.opacityToHexAlpha(15) + this.customThemeColor.slice(1) : 'rgba(255, 85, 170, 0.15)' : 'rgba(0, 0, 0, 0.35)')
          .border({ width: this.cs === it.mode ? 1.5 : 0, color: this.playerFollowTheme ? this.customThemeColor : '#FB7299' })
          .borderRadius(12)
          .margin({ bottom: 12 })
          .onClick(() => {
            this.cs = it.mode;
            this.colorStylePopup = false;
            this.ip = false;
            if (this.cv) this.resetCT();
          })
          // 进入：从右侧较远位置依次滑入；退出：依次向右滑出
          .transition(
            this.icp ? TransitionEffect.IDENTITY :
              TransitionEffect.asymmetric(
                TransitionEffect.translate({ x: this.mirrorPopup() ? -60 : 60 }).combine(TransitionEffect.opacity(0))
                  .animation({ duration: 450, curve: Curve.EaseOut, delay: index * 100 }),
                TransitionEffect.translate({ x: this.mirrorPopup() ? -40 : 40 }).combine(TransitionEffect.opacity(0))
                  .animation({ duration: 300, curve: Curve.EaseIn, delay: index * 100 })
              )
          )
          .offset({ x: this.mirrorPopup() ? 14 : -14 });
        }, (it: CO) => it.mode);
      }
      .width(this.isLs ? '30%' : '50%')
      .height('100%')
      .linearGradient({
        direction: this.mirrorPopup() ? GradientDirection.Left : GradientDirection.Right,
        colors: [
          ['rgba(0,0,0,0)', 0],
          ['rgba(0,0,0,0)', 0.25],
          ['rgba(0,0,0,0.95)', 1]
        ]
      })
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 60, left: this.mirrorPopup() ? 50 : 48, right: this.mirrorPopup() ? 48 : 50 })
      .position(this.mirrorPopup() ? { left: 0, top: 0 } : { right: 0, top: 0 });
    }
    .width('100%').height('100%')
    .transition(
      this.icp ? TransitionEffect.IDENTITY :
        TransitionEffect.asymmetric(
          TransitionEffect.translate({ x: this.mirrorPopup() ? '-100%' : '100%' }).combine(TransitionEffect.opacity(0))
            .animation({ duration: 400, curve: Curve.EaseOut }),
          TransitionEffect.opacity(0)
            .animation({ duration: 700, curve: Curve.EaseIn })
        )
    );
  }

  @Builder
  bQP() {
    Stack() {
      // 左侧点击区域 — 透明，仅用于点击关闭弹窗
      Column().width(this.isLs ? '60%' : '50%').height('100%')
        .position(this.mirrorPopup() ? { right: 0, top: 0 } : { left: 0, top: 0 })
        .onClick(() => { this.qp = false; this.ip = false; if (this.cv) this.resetCT(); });

      // ⭐ 渐变背景 — 加宽 + 多段渐变（镜像布局时滑入方向与渐变反向）
      Column() {
        // 标题（白色，不跟随系统主题）
        Text('画质选择').fontSize(16).fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
          .padding({ left: 4, right: 4, top: 0, bottom: 12 })
          .offset({ x: this.mirrorPopup() ? 14 : -14, y: -12 });

        // 每个选项是独立圆角矩形，依次从右侧滑入
        ForEach(this.aq.length > 0 ? this.aq : this.ql_, (it: QI, index: number) => {
          Row() {
            Text(it.label).fontSize(15)
              .fontColor(this.qn === it.qn ? this.playerFollowTheme ? this.customThemeColor : '#FB7299' : Color.White)
              .fontWeight(this.qn === it.qn ? FontWeight.Bold : FontWeight.Normal);
          }
          .height(48)
          .justifyContent(FlexAlign.Center)
          .padding({ left: 36, right: 36 })
          .backgroundColor(this.qn === it.qn ? this.playerFollowTheme ? '#' + this.opacityToHexAlpha(15) + this.customThemeColor.slice(1) : 'rgba(255, 85, 170, 0.15)' : 'rgba(0, 0, 0, 0.35)')
          .border({ width: this.qn === it.qn ? 1.5 : 0, color: this.playerFollowTheme ? this.customThemeColor : '#FB7299' })
          .borderRadius(12)
          .margin({ bottom: 12 })
          .onClick(() => { this.qp = false; this.ip = false; this.switchQ(it.qn); })
          // 进入：从右侧较远位置依次滑入；退出：依次向右滑出
          .transition(
            this.icp ? TransitionEffect.IDENTITY :
              TransitionEffect.asymmetric(
                TransitionEffect.translate({ x: this.mirrorPopup() ? -40 : 40 }).combine(TransitionEffect.opacity(0))
                  .animation({ duration: 300, curve: Curve.EaseIn, delay: index * 100 }),
                TransitionEffect.translate({ x: this.mirrorPopup() ? -40 : 40 }).combine(TransitionEffect.opacity(0))
                  .animation({ duration: 300, curve: Curve.EaseIn, delay: index * 100 })
              )
          )
          .offset({ x: this.mirrorPopup() ? 14 : -14 });
        }, (it: QI) => it.qn.toString());
      }
      .width(this.isLs ? '30%' : '50%')
      .height('100%')
      .linearGradient({
        direction: this.mirrorPopup() ? GradientDirection.Left : GradientDirection.Right,
        colors: [
          ['rgba(0,0,0,0)', 0],
          ['rgba(0,0,0,0)', 0.25],
          ['rgba(18,18,22,0.88)', 1]
        ]
      })
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 60, left: this.mirrorPopup() ? 50 : 48, right: this.mirrorPopup() ? 48 : 50 })
      .position(this.mirrorPopup() ? { left: 0, top: 0 } : { right: 0, top: 0 });
    }
    .width('100%').height('100%')
    .transition(
      this.icp ? TransitionEffect.IDENTITY :
        TransitionEffect.asymmetric(
          TransitionEffect.translate({ x: this.mirrorPopup() ? '-100%' : '100%' }).combine(TransitionEffect.opacity(0))
            .animation({ duration: 400, curve: Curve.EaseOut }),
          TransitionEffect.opacity(0)
            .animation({ duration: 700, curve: Curve.EaseIn })
        )
    );
  }

  @Builder
  bMP() {
    Stack() {
      // 左侧点击区域 — 透明，仅用于点击关闭弹窗
      Column().width(this.isLs ? '60%' : '50%').height('100%')
        .position(this.mirrorPopup() ? { right: 0, top: 0 } : { left: 0, top: 0 })
        .onClick(() => { this.mp = false; this.ip = false; if (this.cv) this.resetCT(); });

      // ⭐ 渐变背景 — 加宽 + 多段渐变（镜像布局时滑入方向与渐变反向）
      Column() {
        // 标题（白色，不跟随系统主题）
        Text('更多').fontSize(16).fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
          .padding({ left: 4, right: 4, top: 0, bottom: 12 })
          .offset({ x: this.mirrorPopup() ? 14 : -14, y: -12 });

        // 每个选项是独立圆角矩形，依次从右侧滑入
        ForEach(this.mo_, (it: MO, index: number) => {
          if (it.label === '投屏') {
            Stack() {
              Row() {
                Image(it.icon).width(20).height(20).fillColor(Color.White).margin({ right: 12 });
                Text(it.label).fontSize(15).fontColor(Color.White);
              }
              .height(48)
              .justifyContent(FlexAlign.Center)

              AVCastPicker({
                sessionType: 'video',
                onStateChange: (state: AVCastPickerState) => {
                  if (state === AVCastPickerState.STATE_DISAPPEARING) {
                    this.mp = false; this.ip = false; if (this.cv) this.resetCT();
                  }
                }
              })
                .opacity(0)
                .width('100%')
                .height(48)
            }
            .width('100%')
            .height(48)
            .padding({ left: 36, right: 36 })
            .backgroundColor('rgba(0, 0, 0, 0.35)')
            .borderRadius(12)
            .margin({ bottom: 12 })
            .clip(true)
            .transition(
              this.icp ? TransitionEffect.IDENTITY :
                TransitionEffect.asymmetric(
                  TransitionEffect.translate({ x: this.mirrorPopup() ? -40 : 40 }).combine(TransitionEffect.opacity(0))
                    .animation({ duration: 300, curve: Curve.EaseIn, delay: index * 100 }),
                  TransitionEffect.translate({ x: this.mirrorPopup() ? -40 : 40 }).combine(TransitionEffect.opacity(0))
                    .animation({ duration: 300, curve: Curve.EaseIn, delay: index * 100 })
                )
            )
            .offset({ x: this.mirrorPopup() ? 14 : -14 });
          } else {
            Row() {
              Image(it.icon).width(20).height(20).fillColor(Color.White).margin({ right: 12 });
              Text(it.label).fontSize(15).fontColor(Color.White);
            }
            .width('100%')
            .height(48)
            .justifyContent(FlexAlign.Center)
            .padding({ left: 36, right: 36 })
            .backgroundColor('rgba(0, 0, 0, 0.35)')
            .borderRadius(12)
            .margin({ bottom: 12 })
            .onClick(() => {
              this.mp = false;
              this.ip = false;
              if (this.cv) this.resetCT();
              it.action();
            })
            .transition(
              this.icp ? TransitionEffect.IDENTITY :
                TransitionEffect.asymmetric(
                  TransitionEffect.translate({ x: this.mirrorPopup() ? -40 : 40 }).combine(TransitionEffect.opacity(0))
                    .animation({ duration: 300, curve: Curve.EaseIn, delay: index * 100 }),
                  TransitionEffect.translate({ x: this.mirrorPopup() ? -40 : 40 }).combine(TransitionEffect.opacity(0))
                    .animation({ duration: 300, curve: Curve.EaseIn, delay: index * 100 })
                )
            )
            .offset({ x: this.mirrorPopup() ? 14 : -14 });
          }
        }, (it: MO) => it.label);
      }
      .width(this.isLs ? '30%' : '50%')
      .height('100%')
      .linearGradient({
        direction: this.mirrorPopup() ? GradientDirection.Left : GradientDirection.Right,
        colors: [
          ['rgba(0,0,0,0)', 0],
          ['rgba(0,0,0,0)', 0.25],
          ['rgba(18,18,22,0.88)', 1]
        ]
      })
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 60, left: this.mirrorPopup() ? 50 : 48, right: this.mirrorPopup() ? 48 : 50 })
      .position(this.mirrorPopup() ? { left: 0, top: 0 } : { right: 0, top: 0 });
    }
    .width('100%').height('100%')
    .transition(
      this.icp ? TransitionEffect.IDENTITY :
        TransitionEffect.asymmetric(
          TransitionEffect.translate({ x: this.mirrorPopup() ? '-100%' : '100%' }).combine(TransitionEffect.opacity(0))
            .animation({ duration: 400, curve: Curve.EaseOut }),
          TransitionEffect.opacity(0)
            .animation({ duration: 700, curve: Curve.EaseIn })
        )
    );
  }

  // ⭐ 缓存当前视频（「更多」菜单触发 → 先选清晰度）
  private startCacheCurrentVideo(): void {
    if (!this.vi || !this.vi.bvid || this.vi.cid <= 0) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '当前视频无法缓存', duration: 1500 });
      } catch (err) {
        logWarn(`showToast 异常: ${errMsg(err)}`);
      }
      return;
    }
    // ⭐ 弹出清晰度选择弹窗（选项来自服务器动态列表 aq，空则硬编码兜底）
    this.cacheQnPopup = true;
    this.ip = true;
  }

  // ⭐ 按所选清晰度开始缓存
  private startCacheWithQuality(qn: number): void {
    const svc = OfflineCacheService.getInstance();
    // ⭐ 惰性初始化：注入沙箱 filesDir（首次缓存前必须 init，否则目录创建失败）
    try {
      svc.init(this.getUIContext().getHostContext() as common.Context);
    } catch (err) {
      logWarn(`[OfflineCache] init 异常: ${errMsg(err)}`);
    }
    const item: OfflineCacheItem = {
      bvid: this.vi.bvid,
      cid: this.vi.cid,
      title: this.vi.title || '未命名视频',
      cover: this.vi.cover || '',
      quality: qn > 0 ? qn : 116,
      qualityLabel: this.getQlLabel(qn),
      status: CacheStatus.WAIT,
      totalBytes: 0,
      downloadedBytes: 0,
      videoPath: '',
      audioPath: '',
      createTime: Date.now(),
      updateTime: Date.now()
    };
    // ⭐ 显示可点击的缓存提示条（开始：正在缓存）
    this.cacheHintVisible = true;
    this.cacheHintDone = false;
    this.cacheHintPaused = false;
    svc.download(item, (d: number, t: number) => {
      logInfo(`[缓存] ${item.title} ${d}/${t}`);
    }).then((ok: boolean) => {
      if (ok) {
        // ⭐ 缓存完成：提示条保留，文案切换为「缓存完成·点击查看」，手动关闭
        this.cacheHintDone = true;
        this.cacheHintPaused = false;
      } else {
        // ⭐ 区分「被暂停」与「真失败」：缓存中被暂停（列表页/播放页触发 pause）不算失败
        const fresh = svc.getCachedItem(item.bvid, item.cid);
        if (fresh && fresh.status === CacheStatus.PAUSED) {
          // ⭐ 暂停：文案切换为「已暂停·点击查看」，保留提示条，不弹「缓存失败」
          this.cacheHintDone = false;
          this.cacheHintPaused = true;
        } else {
          // 失败：隐藏提示条
          this.cacheHintVisible = false;
        }
      }
      if (ok) {
        try {
          this.getUIContext().getPromptAction().showToast({ message: '缓存完成', duration: 2000 });
        } catch (err) {
          logWarn(`showToast 异常: ${errMsg(err)}`);
        }
      }
    });
  }

  // ⭐ 跳转到离线缓存列表页（提示条点击）
  private goToOfflineCachePage(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/OfflineCachePage' }).catch((err: Error) => {
      logWarn(`[OfflineCache] 跳转缓存页失败: ${errMsg(err)}`);
    });
  }

  // ⭐ 按当前视频的缓存条目真实状态刷新提示条（完成→文案切换；暂停→已暂停；失败→保持可见待处理）
  private syncCacheHintStatus(): void {
    try {
      if (!this.cacheHintVisible || !this.vi || !this.vi.bvid || this.vi.cid <= 0) {
        return;
      }
      const fresh = OfflineCacheService.getInstance().getCachedItem(this.vi.bvid, this.vi.cid);
      if (fresh) {
        this.cacheHintDone = fresh.status === CacheStatus.COMPLETED;
        this.cacheHintPaused = fresh.status === CacheStatus.PAUSED;
      }
    } catch (e) {
      logWarn(`[VideoPlayer] 同步缓存提示条异常: ${JSON.stringify(e)}`);
    }
  }

  // ⭐ 更多弹窗内容（bindSheet 半模态，样式与选集弹窗一致）
  @Builder
  moreSheetContent() {
    Column() {
      // 标题
      Text('更多').fontSize(16).fontColor($r('app.color.color_player_text'))
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 4 })
      // 菜单项
      Column() {
        ForEach(this.mo_, (it: MO, index: number) => {
          if (it.label === '投屏') {
            Stack() {
              Row() {
                Image(it.icon).width(20).height(20).fillColor($r('app.color.color_player_text')).margin({ right: 12 });
                Text(it.label).fontSize(15).fontColor($r('app.color.color_player_text'));
              }
              .width('100%')
              .height(48)
              .justifyContent(FlexAlign.Center)

              AVCastPicker({
                sessionType: 'video',
                onStateChange: (state: AVCastPickerState) => {
                  if (state === AVCastPickerState.STATE_DISAPPEARING) {
                    this.mpb = false; this.ip = false; if (this.cv) this.resetCT();
                  }
                }
              })
                .opacity(0)
                .width('100%')
                .height(48)
            }
            .width('100%')
            .height(48)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
            .borderRadius(20)
            .margin({ bottom: 10 })
            .clip(true)
          } else {
            Row() {
              Image(it.icon).width(20).height(20).fillColor($r('app.color.color_player_text')).margin({ right: 12 });
              Text(it.label).fontSize(15).fontColor($r('app.color.color_player_text'));
            }
            .width('100%')
            .height(48)
            .justifyContent(FlexAlign.Center)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
            .borderRadius(20)
            .margin({ bottom: 10 })
            .onClick(() => {
              this.mpb = false;
              this.ip = false;
              if (this.cv) this.resetCT();
              it.action();
            })
          }
        }, (it: MO) => it.label)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.sheetRootBg($r('app.color.color_comment_background')))
  }

  // ⭐ 弹幕设置面板内容（bindSheet 半模态）
  @Builder
  danmakuSettingSheetContent() {
    Column() {
      DanmakuSettingSheet({
        config: $danmakuConfig,
        onChanged: () => { this.notifyDanmakuSettingsChanged(); },
        onClose: () => { this.showDanmakuSettingSheet = false; }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.sheetRootBg($r('app.color.color_comment_background')))
  }

  /** 打开「弹幕设置」面板 */
  private openDanmakuSettingSheet(): void {
    this.cancelDelayHide();
    this.showDanmakuSettingSheet = true;
  }

  /**
   * ⭐ 面板里任意一项被改动后的统一出口。
   *
   * 为什么必须 debounce 200ms：拖滑块时 `Slider.onChange(Moving)` 每秒几十次回调，
   *   而每一次"应用"都会让 renderer 清空文本宽度/字体缓存并让 trackManager 重算轨道
   *   （DragBar 拖满一屏 = 几十次全量重建），主线程会被吃满、弹幕出现明显卡顿。
   *   合并到"手停下来"之后执行一次，观感上是"松手即生效"。
   *
   * ① AppStorage('danmakuSettingVersion')++ → `DanmakuView` 的 @Watch →
   *   `controller.applyDisplaySettings()` → 按新字号/显示区/行高重算轨道几何（就地，不重建弹幕）；
   * ② 落盘 Preferences，下次进任意视频自动沿用。
   */
  private notifyDanmakuSettingsChanged(): void {
    if (this.dmSettingApplyTimer) {
      clearTimeout(this.dmSettingApplyTimer)
    }
    this.dmSettingApplyTimer = setTimeout(() => {
      this.dmSettingApplyTimer = 0
      this.dmSettingVersion += 1
      AppStorage.setOrCreate<number>('danmakuSettingVersion', this.dmSettingVersion)
      this.saveDanmakuDisplaySettings()
    }, 200)
  }

  /**
   * 持久化弹幕显示设置（JSON 字符串存单个 key，避免为每个字段建一条 Preferences 记录）
   */
  private async saveDanmakuDisplaySettings(): Promise<void> {
    try {
      const c = this.danmakuConfig
      // 手动拼串：规避 ArkTS 里 Record<string, Object> 对 boolean/number 装箱的类型限制
      const json = '{"blockWeight":' + c.blockWeight +
        ',"showScroll":' + c.showScroll +
        ',"showTop":' + c.showTop +
        ',"showBottom":' + c.showBottom +
        ',"showAdvanced":' + c.showAdvanced +
        ',"blockColorful":' + c.blockColorful +
        ',"displayArea":' + c.displayArea +
        ',"opacity":' + c.opacity +
        ',"fontSize":' + c.fontSize +
        ',"fullScreenFontScale":' + c.fullScreenFontScale +
        ',"lineHeight":' + c.lineHeight +
        ',"fontWeight":' + c.fontWeight +
        ',"borderWidth":' + c.borderWidth +
        ',"scrollDuration":' + c.scrollDuration +
        ',"staticDuration":' + c.staticDuration +
        ',"varyFontSize":' + c.varyFontSize +
        ',"massiveMode":' + c.massiveMode +
        ',"static2Scroll":' + c.static2Scroll +
        ',"scrollFixedVelocity":' + c.scrollFixedVelocity +
        '}'
      const ctx = this.getUIContext().getHostContext() as common.Context
      const pf = await preferences.getPreferences(ctx, 'VPS')
      await pf.put(DM_SETTING_KEY, json)
      await pf.flush()
    } catch (e) {
      logWarn(`[VideoPlayer] 保存弹幕设置失败: ${errMsg(e)}`)
    }
  }

  /**
   * ⭐ 读取持久化的弹幕显示设置（fire-and-forget，不阻塞首帧）。
   * 逐字段写回 —— **绝不整体替换 danmakuConfig 对象**（见 danmakuConfig 声明处注释）。
   */
  private async loadDanmakuDisplaySettings(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.Context
      const pf = await preferences.getPreferences(ctx, 'VPS')
      const raw = await pf.get(DM_SETTING_KEY, '') as string
      if (!raw || raw.length < 2) {
        return
      }
      const o = JSON.parse(raw) as DanmakuConfigInit
      const c = this.danmakuConfig
      if (o.blockWeight !== undefined) c.blockWeight = Math.round(Math.min(11, Math.max(0, o.blockWeight)))
      if (o.showScroll !== undefined) c.showScroll = !!o.showScroll
      if (o.showTop !== undefined) c.showTop = !!o.showTop
      if (o.showBottom !== undefined) c.showBottom = !!o.showBottom
      if (o.showAdvanced !== undefined) c.showAdvanced = !!o.showAdvanced
      if (o.blockColorful !== undefined) c.blockColorful = !!o.blockColorful
      if (o.displayArea !== undefined) c.displayArea = Math.min(1, Math.max(0.1, o.displayArea))
      if (o.opacity !== undefined) c.opacity = Math.min(1, Math.max(0, o.opacity))
      // ⚠️ 量程必须覆盖默认字号 28：早期版本上限 32 曾把 37 静默钳到 32（Slider 的隐含约束，这里同源）
      if (o.fontSize !== undefined) c.fontSize = Math.round(Math.min(48, Math.max(12, o.fontSize)))
      if (o.fullScreenFontScale !== undefined) c.fullScreenFontScale = Math.min(2, Math.max(1, o.fullScreenFontScale))
      if (o.lineHeight !== undefined) c.lineHeight = Math.min(2.5, Math.max(1, o.lineHeight))
      if (o.fontWeight !== undefined) c.fontWeight = Math.min(900, Math.max(100, Math.round(o.fontWeight / 100) * 100))
      if (o.borderWidth !== undefined) c.borderWidth = Math.min(5, Math.max(0, o.borderWidth))
      if (o.scrollDuration !== undefined) c.scrollDuration = Math.min(20000, Math.max(3000, Math.round(o.scrollDuration)))
      if (o.staticDuration !== undefined) c.staticDuration = Math.min(10000, Math.max(1000, Math.round(o.staticDuration)))
      if (o.varyFontSize !== undefined) c.varyFontSize = !!o.varyFontSize
      if (o.massiveMode !== undefined) c.massiveMode = !!o.massiveMode
      if (o.static2Scroll !== undefined) c.static2Scroll = !!o.static2Scroll
      if (o.scrollFixedVelocity !== undefined) c.scrollFixedVelocity = !!o.scrollFixedVelocity
      logInfo('[VideoPlayer] 已恢复弹幕显示设置')
    } catch (e) {
      logWarn(`[VideoPlayer] 读取弹幕设置失败: ${errMsg(e)}`)
    }
  }

  // ⭐ 缓存画质选择弹窗内容（bindSheet 半模态，样式与更多弹窗一致）
  @Builder
  cacheQnSheetContent() {
    Column() {
      // 标题
      Text('选择缓存画质').fontSize(16).fontColor($r('app.color.color_player_text'))
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 4 })
      // 画质选项
      Column() {
        ForEach(this.getQlList(), (it: QI, index: number) => {
          Row() {
            Text(it.label).fontSize(15)
              .fontColor(this.qn === it.qn ? this.playerFollowTheme ? this.customThemeColor : '#FB7299' : $r('app.color.color_player_text'))
              .fontWeight(this.qn === it.qn ? FontWeight.Bold : FontWeight.Normal);
          }
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .backgroundColor(this.qn === it.qn ? this.playerFollowTheme ? '#' + this.opacityToHexAlpha(15) + this.customThemeColor.slice(1) : 'rgba(255, 85, 170, 0.15)' : this.getComponentBg(this.cardStyleVideoNavBtns))
          .borderRadius(20)
          .margin({ bottom: 10 })
          .onClick(() => {
            this.cacheQnPopup = false;
            this.ip = false;
            if (this.cv) this.resetCT();
            this.startCacheWithQuality(it.qn);
          })
        }, (it: QI) => it.qn.toString())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.sheetRootBg($r('app.color.color_comment_background')))
  }

  // ⭐ 整卡下拉关灯：全部由原始触摸坐标驱动——卡片双向跟随手指（下拉下移、回滑上移），
  //    回滑累计回落 ≥6vp 记为"已取消"，松手只弹回不关灯
  private onDetailPullTouch(e: TouchEvent) {
    if (this.isLightsOff) return;
    // ⭐ 水平手势进行中（右滑全屏/左滑切换）→ 屏蔽下拉关灯，避免横向手势带动下拉
    if (this.fsPanProgress > 0.01 || Math.abs(this.swipeProgress) > 0.02) return;
    if (e.type === TouchType.Down) {
      this.detailPullLastTouchY = e.touches.length > 0 ? e.touches[0].y : -1;
      this.detailPullTouchStartX = e.touches.length > 0 ? e.touches[0].x : -1;
      this.detailPullTouchStartY = e.touches.length > 0 ? e.touches[0].y : -1;
      this.detailPullPeakTouchY = -1;
      this.detailPullDragEngaged = false; // 新触摸：解除上一根手指的惯性锁定
      // ⭐ 顶部判断只在按下时做一次：避免每个移动事件都跨进原生查询（普通滑动卡顿的根源）
      this.detailPullTouchAtTop = this.detailScroller.currentOffset().yOffset <= 0;
      return;
    }
    if (e.type === TouchType.Move && e.touches.length > 0) {
      const t = e.touches[0];
      const y = t.y;
      // ⭐ 横向位移占优（右滑全屏/左滑切换的识别前帧）→ 屏蔽下拉并复位，不依赖手势回调时序
      if (this.detailPullTouchStartX > 0 && Math.abs(t.x - this.detailPullTouchStartX) > Math.abs(y - this.detailPullTouchStartY) * 1.2) {
        this.detailPullTouchAnchor = -1;
        this.detailPullPeakTouchY = -1;
        if (this.detailPullDrop > 0 || this.detailPullHintPhase > 0) this.springBackDetailPull();
        this.detailPullLastTouchY = y;
        return;
      }
      if (y > this.detailPullPeakTouchY) this.detailPullPeakTouchY = y;
      if (!this.detailPullTouchAtTop) {
        // 按下时内容未到顶：正常滚动，不启动整卡下拉
        this.detailPullTouchAnchor = -1;
        this.detailPullPeakTouchY = -1;
        this.detailPullLastTouchY = y;
        return;
      }
      if (this.detailPullTouchAnchor === -1) this.detailPullTouchAnchor = y;
      const raw = Math.max(0, (y - this.detailPullTouchAnchor) / 250);
      // ⭐ 阻尼曲线（与右滑全屏 applyFSResistance 一致）：滑动越长阻尼越大，跟手更线性稳定
      const drop = Math.min(1, this.applyFSResistance(raw));
      this.detailPullDrop = drop; // 卡片跟随手指（双向）
      if (drop > 0.01) this.detailPullDragEngaged = true;
      const phase = drop < 0.01 ? 0 : (drop >= 0.3 ? 2 : 1);
      if (phase !== this.detailPullHintPhase) {
        const prev = this.detailPullHintPhase;
        if (phase === 2) this.fireHaptic(18); // 越过"释放关灯"阈值
        else if (prev === 2) this.fireHaptic(15); // 回拖放弃
        this.detailPullHintPhase = phase;
      }
      // ⭐ 上滑取消：已就绪且从触摸峰值累计回落 ≥6vp（慢速回滑也有效）；取消后卡片仍跟随手指
      if (!this.detailPullCanceled && drop >= 0.3 && this.detailPullPeakTouchY > 0 && y < this.detailPullPeakTouchY - 6) {
        this.detailPullCanceled = true;
        this.detailPullHintPhase = 0;
        this.fireHaptic(15);
      }
      this.detailPullLastTouchY = y;
    }
    if (e.type === TouchType.Up) {
      const wasEngaged = this.detailPullDragEngaged;
      if (this.detailPullCanceled || this.detailPullDrop < 0.3) {
        // 已取消 / 未达阈值 → 平滑弹回（卡片已跟随手指回到原位附近）
        this.springBackDetailPull();
      } else {
        this.doLightsOff();
      }
      if (wasEngaged) {
        // ⭐ 发生过整卡下拉/取消 → 用带动画的 scrollTo 强制接管滚动引擎，结束惯性（甩动不会带动内容）；
        //    detailPullDragEngaged 保留到下次 Down 再清，抬起后的惯性帧也被锁定挡死
        this.detailScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: 200, curve: Curve.EaseOut } });
      }
      this.detailPullCanceled = false;
      this.detailPullTouchAnchor = -1;
      this.detailPullPeakTouchY = -1;
      this.detailPullLastTouchY = -1;
      this.detailPullTouchStartX = -1;
      this.detailPullTouchStartY = -1;
      // 注：detailPullDragEngaged 保留到下次 Down 再清
    } else if (e.type === TouchType.Cancel) {
      // 触摸被中断（如右滑全屏抢占）→ 仅弹回，不触发关灯
      this.springBackDetailPull();
      if (this.detailPullDragEngaged) {
        this.detailScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: { duration: 200, curve: Curve.EaseOut } });
      }
      this.detailPullCanceled = false;
      this.detailPullTouchAnchor = -1;
      this.detailPullPeakTouchY = -1;
      this.detailPullLastTouchY = -1;
      this.detailPullTouchStartX = -1;
      this.detailPullTouchStartY = -1;
      // 注：detailPullDragEngaged 保留到下次 Down 再清
    }
  }

  // ⭐ 松手触发关灯：卡片弹回的同时进入关灯
  private doLightsOff() {
    this.detailPullHintPhase = 0;
    animateTo({ duration: 600, curve: curves.springMotion(0.6, 0.8) }, () => {
      this.detailPullDrop = 0; // 卡片弹回的同时进入关灯
      this.isLightsOff = true;
      this.lightbulbRotation = 0; // 重置灯泡角度，从 180° 转回 0°
      // 关灯短视频（UGC）没有独立的开灯按钮：底部胶囊的「返回」负责开灯
      this.lightBtnVisible = this.isPgc_ ? this.lightsOffShowBtn : false;
      if (this.isPgc_) this.startLightBtnTimer();   // 启动5秒自动隐藏
      // ⭐ 背景压暗：当前背景 + 模糊 + 黑色压暗
      this.loBgScale = 1;
      this.loBgBlur = 150;
      this.loBgDim = 0.72;
    });
    this.enterShortVideoMode();
    // ⭐ 关灯：隐藏状态栏（竖屏也隐藏）
    setTimeout(() => { this.manageSB(true); }, 50);
  }

  // ⭐ 卡片平滑弹回（未达阈值 / 上滑取消 / 触摸中断）
  private springBackDetailPull() {
    this.detailPullHintPhase = 0;
    this.getUIContext()?.animateTo({ duration: 350, curve: curves.springMotion(0.3, 0.7) }, () => {
      this.detailPullDrop = 0;
    });
  }

  @Builder
  bDetailCard() {
    Column() {
      Stack({ alignContent: Alignment.Top }) {
        // ⭐ 下拉关灯提示（卡片外侧：悬于卡片上缘上方，随卡片整体下滑露出）
        if (this.detailPullHintPhase > 0) {
          Column() {
            Image($r('app.media.lightbulb_slash'))
              .width(24).height(24)
              .fillColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
              .opacity(this.detailPullHintPhase === 2 ? 1 : 0.6)
            if (this.detailPullHintPhase === 2) {
              Row({ space: 8 }) {
                Text('上滑取消')
                  .fontSize(12).fontColor($r('app.color.color_player_text_secondary'))
                Text('|')
                  .fontSize(12).fontColor($r('app.color.color_player_text_secondary'))
                  .opacity(0.3)
                Text('释放关灯')
                  .fontSize(13).fontColor($r('app.color.color_player_text_secondary'))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .margin({ top: 16 })
              .transition(TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.Ease }))
            } else {
              Text('下拉关灯')
                .fontSize(13).fontColor($r('app.color.color_player_text_secondary'))
                .margin({ top: 16 })
                .transition(TransitionEffect.OPACITY.animation({ duration: 250, curve: Curve.Ease }))
            }
          }
          .width('100%')
          .height(56)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .offset({ y: -56 }) // 悬于卡片上缘外侧（不占布局，随整卡位移被"露"出）
          .hitTestBehavior(HitTestMode.None)
          .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.FastOutSlowIn }))
        }
        Column() {
        Scroll(this.detailScroller) {
          Column() {
            // ⭐ 视频内容区域
            if (this.vd) {
              Column() {
                Text(this.vd.title || this.vi.title).fontSize(17).fontColor($r('app.color.color_player_text'))
                  .fontWeight(FontWeight.Bold).maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                  .textAlign(TextAlign.Center).margin({ bottom: 11 });
                Row() {
                  Row() {
                    Image(getCachedPixelMap(imageUrlResize(this.vd.owner.face, 48)) ?? imageUrlResize(this.vd.owner.face, 48)).width(36).height(36).borderRadius(18).objectFit(ImageFit.Cover).margin({ top: 5 })
                      .onClick(() => {
                        this.getUIContext().getRouter().pushUrl({
                          url: 'pages/UpSpacePage',
                          params: {
                            mid: this.vd?.owner?.mid ?? 0,
                            upName: this.vd?.owner?.name ?? '',
                            upFace: this.vd?.owner?.face ?? ''
                          }
                        });
                      });
                    Column() {
                      Row() {
                        Text(this.vd.owner.name).fontSize(14).fontColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink')).maxLines(1)
                          .onClick(() => {
                            this.getUIContext().getRouter().pushUrl({
                              url: 'pages/UpSpacePage',
                              params: {
                                mid: this.vd?.owner?.mid ?? 0,
                                upName: this.vd?.owner?.name ?? '',
                                upFace: this.vd?.owner?.face ?? ''
                              }
                            });
                          });
                      }.alignItems(VerticalAlign.Center);
                      // ⭐ 关注按钮
                      Row() {
                        Image($r('app.media.checkmark_circle_fill'))
                          .width(16)
                          .height(16)
                          .fillColor(this.isFollowed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                          .scale({ x: this.followScale, y: this.followScale })
                          .animation({ duration: 100, curve: Curve.EaseOut })
                        Text(this.isFollowed ? '已关注' : '关注')
                          .fontSize(13)
                          .fontColor(this.isFollowed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                          .margin({ left: 4 })
                      }
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .borderRadius(12)
                      .backgroundColor(this.getComponentBg(this.cardStyleVideoInteractBtns))
                      .margin({ top: 4 })
                      .onClick(() => this.toggleFollow())
                    }.alignItems(HorizontalAlign.Start).margin({ left: 10 });
                  }
                  .layoutWeight(1);
                  // ⭐ 日期/弹幕/播放量：直板机布局时换行显示，避免拥挤
                  if (!(this.phoneLayoutToggle && this.isLs && !this.fs)) {
                    Row() {
                      Text(`${this.fmtTA(this.vd.pubdate)}`).fontSize(11).fontColor($r('app.color.color_player_text_secondary')).margin({ right: 8 });
                      Text(`${this.fmtN(this.vd.stat.danmaku)}弹幕`).fontSize(12).fontColor($r('app.color.color_player_text_secondary')).margin({ right: 12 });
                      Text(`${this.fmtN(this.vd.stat.view)}播放`).fontSize(12).fontColor(this.getPlayCountColor(this.vd.stat.view));
                    }
                  }
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .margin({ bottom: this.phoneLayoutToggle && this.isLs && !this.fs ? 4 : 12 });
                // ⭐ 直板机布局：日期/弹幕/播放量单独一行
                if (this.phoneLayoutToggle && this.isLs && !this.fs) {
                  Row() {
                    Text(`${this.fmtTA(this.vd.pubdate)}`).fontSize(11).fontColor($r('app.color.color_player_text_secondary')).margin({ right: 8 });
                    Text(`${this.fmtN(this.vd.stat.danmaku)}弹幕`).fontSize(12).fontColor($r('app.color.color_player_text_secondary')).margin({ right: 12 });
                    Text(`${this.fmtN(this.vd.stat.view)}播放`).fontSize(12).fontColor(this.getPlayCountColor(this.vd.stat.view));
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.Center)
                  .margin({ bottom: 10 });
                }

                // ⭐ 互动按钮区域（横屏非全屏竖屏模式下已移到左侧，此处隐藏避免重复）
                if (!this.isLandscapeVertical) {
                  if (this.cw >= 480) {
                    // 宽屏（平板/阔折叠）：单行显示所有按钮
                    Flex({
                      direction: (this.isLs && this.isLayoutSwapped) ? FlexDirection.RowReverse : FlexDirection.Row,
                      justifyContent: FlexAlign.Center
                    }) {
                      // ⭐ 布局切换按钮（独立圆形，在旋转按钮左侧，仅横屏非全屏模式显示）
                      if (this.isLs && !this.phoneLayoutToggle) {
                        Column() {
                          Image($r('app.media.ic_gallery_collage'))
                            .width(18)
                            .height(18)
                            .fillColor(this.layoutSwapPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .scale({ x: this.layoutSwapScale, y: this.layoutSwapScale })
                            .animation({ duration: 100, curve: Curve.EaseOut })
                          Text('切换')
                            .fontSize(10)
                            .fontColor(this.layoutSwapPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .margin({ top: 3 })
                        }
                        .width(this.NAV_BTN_SIZE)
                        .height(this.NAV_BTN_SIZE)
                        .borderRadius(this.NAV_BTN_SIZE / 2)
                        .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .margin({ left: 6, right: 6 })
                        .onClick(() => this.toggleLayoutSwap())
                      }

                      // ⭐ 旋转模式切换按钮（独立圆形）
                      if (!this.phoneLayoutToggle || !this.isLs || this.fs) {
                        Column() {
                          Image(this.getRotationIcon())
                            .width(18)
                            .height(18)
                            .fillColor(this.rotationPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .scale({ x: this.rotationScale, y: this.rotationScale })
                            .animation({ duration: 100, curve: Curve.EaseOut })
                          Text(this.getRotationText())
                            .fontSize(10)
                            .fontColor(this.rotationPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .margin({ top: 3 })
                        }
                        .width(this.NAV_BTN_SIZE)
                        .height(this.NAV_BTN_SIZE)
                        .borderRadius(this.NAV_BTN_SIZE / 2)
                        .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .margin({ left: 6, right: 6 })
                        .onClick(() => this.toggleRotationMode())
                      }

                      // 点赞、投币、收藏胶囊
                      Row() {
                        // 点赞按钮
                        Column() {
                          Image($r('app.media.ic_public_thumbsup_filled'))
                            .width(18)
                            .height(18)
                            .fillColor(this.isLiked ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .scale({ x: this.likeScale, y: this.likeScale })
                            .animation({ duration: 100, curve: Curve.EaseOut })
                          Text(`${this.fmtN(this.likeCount)}`)
                            .fontSize(10)
                            .fontColor(this.isLiked ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .margin({ top: 3 })
                        }
                        .padding({ top: 6, bottom: 6, left: 14, right: 14 })
                        .onClick(() => this.toggleLike())
                        .gesture(
                          LongPressGesture({ repeat: false, duration: 500 })
                            .onAction(() => this.tripleAction())
                        )

                        // 投币按钮
                        Column() {
                          Image($r('app.media.ic_public_highlight_filled'))
                            .width(18)
                            .height(18)
                            .fillColor(this.isCoined ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .scale({ x: this.coinScale, y: this.coinScale })
                            .animation({ duration: 100, curve: Curve.EaseOut })
                          Text(`${this.fmtN(this.coinCount)}`)
                            .fontSize(10)
                            .fontColor(this.isCoined ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .margin({ top: 3 })
                        }
                        .padding({ top: 6, bottom: 6, left: 14, right: 14 })
                        .onClick(() => this.toggleCoin(1))
                        .gesture(
                          LongPressGesture({ repeat: false, duration: 500 })
                            .onAction(() => this.toggleCoin(2))
                        )

                        // 收藏按钮
                        Column() {
                          Image($r('app.media.heart_square_stack_fill'))
                            .width(18)
                            .height(18)
                            .fillColor(this.isFavorited ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .scale({ x: this.favoriteScale, y: this.favoriteScale })
                            .animation({ duration: 100, curve: Curve.EaseOut })
                          Text(`${this.fmtN(this.favoriteCount)}`)
                            .fontSize(10)
                            .fontColor(this.isFavorited ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .margin({ top: 3 })
                        }
                        .padding({ top: 6, bottom: 6, left: 14, right: 14 })
                        .onClick(() => this.toggleFavorite())
                      }
                      .justifyContent(FlexAlign.Center)
                      .padding({ left: 6, right: 6, top: 4, bottom: 4 })
                      .borderRadius(50)
                      .backgroundColor(this.getComponentBg(this.cardStyleVideoInteractBtns))
                      .margin({ left: 6, right: 6 })

                      // 深色/浅色模式切换按钮（独立圆形）
                      if (!this.phoneLayoutToggle || !this.isLs || this.fs) {
                        Column() {
                          Image(this.isDarkMode ? $r('app.media.ic_settings_darkmode') : $r('app.media.sun_min'))
                            .width(18)
                            .height(18)
                            .fillColor(this.darkModePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .scale({ x: this.darkModeScale, y: this.darkModeScale })
                            .animation({ duration: 100, curve: Curve.EaseOut })
                          Text(this.isDarkMode ? '深色' : '浅色')
                            .fontSize(10)
                            .fontColor(this.darkModePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .margin({ top: 3 })
                        }
                        .width(this.NAV_BTN_SIZE)
                        .height(this.NAV_BTN_SIZE)
                        .borderRadius(this.NAV_BTN_SIZE / 2)
                        .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .margin({ left: 6, right: 6 })
                        .onClick(() => this.toggleDarkMode())
                      }

                      // 最小化到悬浮按钮
                      if (!this.phoneLayoutToggle || !this.isLs || this.fs) {
                        Column() {
                          Image($r('app.media.media_center'))
                            .width(18)
                            .height(18)
                            .fillColor(this.minimizePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .scale({ x: this.minimizeScale, y: this.minimizeScale })
                            .animation({ duration: 100, curve: Curve.EaseOut })
                          Text('浮窗')
                            .fontSize(10)
                            .fontColor(this.minimizePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .margin({ top: 3 })
                        }
                        .width(this.NAV_BTN_SIZE)
                        .height(this.NAV_BTN_SIZE)
                        .borderRadius(this.NAV_BTN_SIZE / 2)
                        .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .margin({ left: 6, right: 6 })
                        .onClick(() => this.minimizeToFloating())
                      }

                      // 选集按钮（独立圆形，仅多P视频显示）
                      if ((!this.phoneLayoutToggle || !this.isLs || this.fs) && this.vd.pages && this.vd.pages.length > 1) {
                        Column() {
                          Image($r('app.media.externaldrive_fill_3'))
                            .width(18)
                            .height(18)
                            .fillColor(this.episodePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .scale({ x: this.episodeScale, y: this.episodeScale })
                            .animation({ duration: 100, curve: Curve.EaseOut })
                          Text('选集')
                            .fontSize(10)
                            .fontColor(this.episodePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .margin({ top: 3 })
                        }
                        .width(this.NAV_BTN_SIZE)
                        .height(this.NAV_BTN_SIZE)
                        .borderRadius(this.NAV_BTN_SIZE / 2)
                        .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                        .justifyContent(FlexAlign.Center)
                        .alignItems(HorizontalAlign.Center)
                        .margin({ left: 6, right: 6 })
                        .onClick(() => {
                          this.episodeScale = 0.9;
                          this.episodePressed = true;
                          setTimeout(() => {
                            this.episodeScale = 1;
                            this.episodePressed = false;
                          }, 150);
                          this.triggerHaptic();
                           this.showEpisodeSheet = true;
                         })
                       }
                       // ⭐ 合集按钮（选集右侧，仅UGC合集显示；直板机横屏时隐藏，按钮已在下方按钮行）
                       if ((!this.phoneLayoutToggle || !this.isLs || this.fs) && this.vd?.ugc_season?.id && this.vd.ugc_season.sections && this.vd.ugc_season.sections.length > 0) {
                         Column() {
                           Image($r('app.media.heji'))
                             .width(18)
                             .height(18)
                             .fillColor(this.seasonPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                             .scale({ x: this.seasonScale, y: this.seasonScale })
                             .animation({ duration: 100, curve: Curve.EaseOut })
                           Text('合集')
                             .fontSize(10)
                             .fontColor(this.seasonPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                             .margin({ top: 3 })
                         }
                         .width(this.NAV_BTN_SIZE)
                         .height(this.NAV_BTN_SIZE)
                         .borderRadius(this.NAV_BTN_SIZE / 2)
                         .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                         .justifyContent(FlexAlign.Center)
                         .alignItems(HorizontalAlign.Center)
                         .margin({ left: 6, right: 6 })
                         .onClick(() => {
                           this.seasonScale = 0.9;
                           this.seasonPressed = true;
                           setTimeout(() => {
                             this.seasonScale = 1;
                             this.seasonPressed = false;
                           }, 150);
                           this.triggerHaptic();
                           this.showSeasonSheet = true;
                         })
                       }
                     }
                    .width('100%')
                    .margin({ bottom: 16 })
                  } else {
                    // 直板机窄屏（cw < 480）：按钮/胶囊合并进同一个可换行 Flex——
                    // 界面缩放后空间足够时「浮窗/选集」自动并入第一排，不足时自动折行；
                    // ⭐ 窄分区间距收紧（胶囊列 padding 14→10、圆形按钮 margin 6→4），
                    //    让「切换+自由+胶囊+浅色+浮窗」在常见计数（含 4 位数字/6.数万）下一排放得下
                    Flex({
                      direction: (this.isLs && this.isLayoutSwapped) ? FlexDirection.RowReverse : FlexDirection.Row,
                      wrap: FlexWrap.Wrap,
                      justifyContent: FlexAlign.Center,
                      space: { cross: LengthMetrics.vp(8) }
                    }) {
                        // 布局切换按钮（仅横屏非全屏模式显示）
                        if (this.isLs && !this.phoneLayoutToggle) {
                          Column() {
                            Image($r('app.media.ic_gallery_collage'))
                              .width(18).height(18)
                              .fillColor(this.layoutSwapPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .scale({ x: this.layoutSwapScale, y: this.layoutSwapScale })
                              .animation({ duration: 100, curve: Curve.EaseOut })
                            Text('切换')
                              .fontSize(10)
                              .fontColor(this.layoutSwapPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .margin({ top: 3 })
                          }
                          .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                          .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                          .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                          .margin({ left: 4, right: 4 })
                          .onClick(() => this.toggleLayoutSwap())
                        }

                        // 旋转模式切换按钮
                        if (!this.phoneLayoutToggle || !this.isLs || this.fs) {
                          Column() {
                            Image(this.getRotationIcon())
                              .width(18).height(18)
                              .fillColor(this.rotationPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .scale({ x: this.rotationScale, y: this.rotationScale })
                              .animation({ duration: 100, curve: Curve.EaseOut })
                            Text(this.getRotationText())
                              .fontSize(10)
                              .fontColor(this.rotationPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .margin({ top: 3 })
                          }
                          .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                          .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                          .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                          .margin({ left: 4, right: 4 })
                          .onClick(() => this.toggleRotationMode())
                        }

                        // 点赞、投币、收藏胶囊
                        Row() {
                          // 点赞按钮
                          Column() {
                            Image($r('app.media.ic_public_thumbsup_filled'))
                              .width(18).height(18)
                              .fillColor(this.isLiked ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .scale({ x: this.likeScale, y: this.likeScale })
                              .animation({ duration: 100, curve: Curve.EaseOut })
                            Text(`${this.fmtN(this.likeCount)}`)
                              .fontSize(10)
                              .fontColor(this.isLiked ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .margin({ top: 3 })
                          }
                          .padding({ top: 6, bottom: 6, left: 10, right: 10 })
                          .onClick(() => this.toggleLike())
                          .gesture(
                            LongPressGesture({ repeat: false, duration: 500 })
                              .onAction(() => this.tripleAction())
                          )

                          // 投币按钮
                          Column() {
                            Image($r('app.media.ic_public_highlight_filled'))
                              .width(18).height(18)
                              .fillColor(this.isCoined ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .scale({ x: this.coinScale, y: this.coinScale })
                              .animation({ duration: 100, curve: Curve.EaseOut })
                            Text(`${this.fmtN(this.coinCount)}`)
                              .fontSize(10)
                              .fontColor(this.isCoined ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .margin({ top: 3 })
                          }
                          .padding({ top: 6, bottom: 6, left: 10, right: 10 })
                          .onClick(() => this.toggleCoin(1))
                          .gesture(
                            LongPressGesture({ repeat: false, duration: 500 })
                              .onAction(() => this.toggleCoin(2))
                          )

                          // 收藏按钮
                          Column() {
                            Image($r('app.media.heart_square_stack_fill'))
                              .width(18).height(18)
                              .fillColor(this.isFavorited ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .scale({ x: this.favoriteScale, y: this.favoriteScale })
                              .animation({ duration: 100, curve: Curve.EaseOut })
                            Text(`${this.fmtN(this.favoriteCount)}`)
                              .fontSize(10)
                              .fontColor(this.isFavorited ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .margin({ top: 3 })
                          }
                          .padding({ top: 6, bottom: 6, left: 10, right: 10 })
                          .onClick(() => this.toggleFavorite())
                        }
                        .justifyContent(FlexAlign.Center)
                        .padding({ left: 6, right: 6, top: 4, bottom: 4 })
                        .borderRadius(50)
                        .backgroundColor(this.getComponentBg(this.cardStyleVideoInteractBtns))
                        .margin({ left: 4, right: 4 })

                        // 深色/浅色模式切换按钮
                        if (!this.phoneLayoutToggle || !this.isLs || this.fs) {
                          Column() {
                            Image(this.isDarkMode ? $r('app.media.ic_settings_darkmode') : $r('app.media.sun_min'))
                              .width(18).height(18)
                              .fillColor(this.darkModePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .scale({ x: this.darkModeScale, y: this.darkModeScale })
                              .animation({ duration: 100, curve: Curve.EaseOut })
                            Text(this.isDarkMode ? '深色' : '浅色')
                              .fontSize(10)
                              .fontColor(this.darkModePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .margin({ top: 3 })
                          }
                          .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                          .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                          .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                          .margin({ left: 4, right: 4 })
                          .onClick(() => this.toggleDarkMode())
                        }

                      // ⭐ 最小化到悬浮按钮
                      if (!this.phoneLayoutToggle || !this.isLs || this.fs) {
                        Column() {
                          Image($r('app.media.media_center'))
                            .width(18).height(18)
                            .fillColor(this.minimizePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .scale({ x: this.minimizeScale, y: this.minimizeScale })
                            .animation({ duration: 100, curve: Curve.EaseOut })
                          Text('浮窗')
                            .fontSize(10)
                            .fontColor(this.minimizePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                            .margin({ top: 3 })
                        }
                        .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                        .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                        .margin({ left: 4, right: 4 })
                        .onClick(() => this.minimizeToFloating())

                        // 选集按钮（仅多P视频显示）
                        if ((!this.phoneLayoutToggle || !this.isLs || this.fs) && this.vd.pages && this.vd.pages.length > 1) {
                          Column() {
                            Image($r('app.media.externaldrive_fill_3'))
                              .width(18).height(18)
                              .fillColor(this.episodePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .scale({ x: this.episodeScale, y: this.episodeScale })
                              .animation({ duration: 100, curve: Curve.EaseOut })
                            Text('选集')
                              .fontSize(10)
                              .fontColor(this.episodePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .margin({ top: 3 })
                          }
                          .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                          .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                          .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                          .margin({ left: 4, right: 4 })
                          .onClick(() => {
                            this.episodeScale = 0.9;
                            this.episodePressed = true;
                            setTimeout(() => {
                              this.episodeScale = 1;
                              this.episodePressed = false;
                            }, 150);
                            this.triggerHaptic();
                            this.showEpisodeSheet = true;
                          })
                        }

                        // 合集按钮（选集右侧，仅UGC合集显示）
                        if (this.vd?.ugc_season?.id && this.vd.ugc_season.sections && this.vd.ugc_season.sections.length > 0) {
                          Column() {
                            Image($r('app.media.heji'))
                              .width(18).height(18)
                              .fillColor(this.seasonPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .scale({ x: this.seasonScale, y: this.seasonScale })
                              .animation({ duration: 100, curve: Curve.EaseOut })
                            Text('合集')
                              .fontSize(10)
                              .fontColor(this.seasonPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                              .margin({ top: 3 })
                          }
                          .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                          .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                          .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                          .margin({ left: 4, right: 4 })
                          .onClick(() => {
                            this.seasonScale = 0.9;
                            this.seasonPressed = true;
                            setTimeout(() => {
                              this.seasonScale = 1;
                              this.seasonPressed = false;
                            }, 150);
                            this.triggerHaptic();
                            this.showSeasonSheet = true;
                          })
                        }
                      }
                      }
                      .width('100%')
                      .margin({ bottom: 16 })
                  }
                }  // end if !isLandscapeVertical

                if (this.vd.desc) {
                  Row() {
                    Text(this.vd.desc).fontSize(13).fontColor(this.isDarkMode ? $r('app.color.color_player_text_desc') : '#000000')
                      .lineHeight(20)
                      .textAlign(TextAlign.Center)
                      .width('100%')
                      .padding(16)
                      .backgroundColor(this.getComponentBg(this.cardStyleVideoDescription))
                      .border(this.getComponentBorder(this.cardStyleVideoDescription))
                      .borderRadius(20);
                  }
                  .gesture(LongPressGesture().onAction(() => {
                    this.showTextSelection('文本工具 · 简介', this.vd?.desc ?? '');
                  }))
                }

                if (this.relatedLoading) {
                  Row() {
                    LoadingProgress().width(24).height(24).color($r('app.color.color_player_text_secondary'))
                  }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 16, bottom: 16 })
                }

                if (!this.relatedLoading && this.relatedVideos.length > 0) {
                  Column() {
                    ForEach(this.relatedVideos.slice(0, this.relatedRenderCount), (item: RecommendItem) => {
                      // ⭐ 直板机布局·横屏非全屏·横屏视频（详情卡在右侧唯一适用）：推荐视频用上下结构（封面在上）
                      if (this.phoneLayoutToggle && this.isLs && !this.fs && !this.isLandscapeVertical) {
                        Column() {
                          Stack({ alignContent: Alignment.BottomEnd }) {
                            Image(item.coverUrl)
                              .width('100%')
                              .aspectRatio(16 / 9)
                              .objectFit(ImageFit.Cover)
                              .backgroundColor(this.isDarkMode ? '#2A2A2A' : '#F0F0F0')
                            Text(this.formatDuration(item.duration))
                              .fontSize(10).fontColor('#FFFFFF')
                              .backgroundColor('#80000000')
                              .borderRadius(4)
                              .padding({ left: 3, right: 3, top: 1, bottom: 1 })
                              .margin({ right: 4, bottom: 4 })
                          }
                          .width('100%')
                          .borderRadius(Math.round(this.cardBorderRadius * 0.5))
                          .clip(true)

                          Text(item.title)
                            .fontSize(13)
                            .fontColor(this.isDarkMode ? '#E0E0E0' : '#000000')
                            .maxLines(2)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                            .lineHeight(18)
                            .width('100%')
                            .textAlign(TextAlign.Center)
                            .margin({ top: 16 })

                          Row() {
                            Text(item.ownerName)
                              .fontSize(11)
                              .fontColor(this.isDarkMode ? '#999999' : '#666666')
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                              .layoutWeight(1)
                            Row({ space: 8 }) {
                              Text(`${this.fmtN(item.playCount)}播放`)
                                .fontSize(11).fontColor(this.isDarkMode ? '#999999' : '#666666')
                              Text(`${this.fmtN(item.danmakuCount)}弹幕`)
                                .fontSize(11).fontColor(this.isDarkMode ? '#999999' : '#666666')
                            }
                          }.width('100%').margin({ top: 4 })
                        }
                        .width('100%')
                        .padding({ left: 12, right: 12, top: 12, bottom: 6 })
                        .backgroundColor(this.getComponentBg(this.cardStyleVideoDescription))
                        .border(this.getComponentBorder(this.cardStyleVideoDescription))
                        .borderRadius(Math.round(this.cardBorderRadius * 0.5))
                        .margin({ top: 6, bottom: 6 })
                        .scale({ x: this.relatedPressedId === item.id ? 0.96 : 1, y: this.relatedPressedId === item.id ? 0.96 : 1 })
                        .animation({ duration: 120, curve: Curve.EaseOut })
                        .onClick(() => { this.onRelatedVideoClick(item) })
                        .onTouch((e: TouchEvent) => {
                          if (e.type === TouchType.Down) { this.relatedPressedId = item.id; }
                          else if (e.type === TouchType.Up || e.type === TouchType.Cancel) { this.relatedPressedId = ''; }
                        })
                      } else {
                        // 其他布局：保持原样（封面左 120×68，信息在右）
                        Row() {
                          Stack({ alignContent: Alignment.BottomEnd }) {
                            Image(item.coverUrl)
                              .width(120).height(68)
                              .objectFit(ImageFit.Cover)
                              .borderRadius(Math.round(this.cardBorderRadius * 0.5))
                              .backgroundColor(this.isDarkMode ? '#2A2A2A' : '#F0F0F0')
                            Text(this.formatDuration(item.duration))
                              .fontSize(10).fontColor('#FFFFFF')
                              .backgroundColor('#80000000')
                              .borderRadius({ topLeft: 2, topRight: 2, bottomLeft: 2, bottomRight: 2 })
                              .padding({ left: 3, right: 3, top: 1, bottom: 1 })
                              .margin({ right: 4, bottom: 4 })
                          }.width(120).height(68)

                          Column() {
                            Text(item.title)
                              .fontSize(13)
                              .fontColor(this.isDarkMode ? '#E0E0E0' : '#000000')
                              .maxLines(2)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                              .lineHeight(18)
                              .width('100%')
                              .textAlign(TextAlign.Center)
                              .margin({ top: 2 })
                            Blank()
                            Row() {
                              Text(item.ownerName)
                                .fontSize(11)
                                .fontColor(this.isDarkMode ? '#999999' : '#666666')
                                .layoutWeight(1)
                              Row({ space: 8 }) {
                                Text(`${this.fmtN(item.playCount)}播放`)
                                  .fontSize(11).fontColor(this.isDarkMode ? '#999999' : '#666666')
                                Text(`${this.fmtN(item.danmakuCount)}弹幕`)
                                  .fontSize(11).fontColor(this.isDarkMode ? '#999999' : '#666666')
                              }
                            }.width('100%').margin({ bottom: 4 })
                          }.layoutWeight(1).height(68).padding({ left: 10, right: 10 })
                          .justifyContent(FlexAlign.SpaceBetween)
                          .alignItems(HorizontalAlign.Center)
                        }.width('100%')
                        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                        .backgroundColor(this.getComponentBg(this.cardStyleVideoDescription))
                        .border(this.getComponentBorder(this.cardStyleVideoDescription))
                        .borderRadius(Math.round(this.cardBorderRadius * 0.5))
                        .margin({ top: 6, bottom: 6 })
                        .scale({ x: this.relatedPressedId === item.id ? 0.96 : 1, y: this.relatedPressedId === item.id ? 0.96 : 1 })
                        .animation({ duration: 120, curve: Curve.EaseOut })
                        .onClick(() => { this.onRelatedVideoClick(item) })
                        .onTouch((e: TouchEvent) => {
                          if (e.type === TouchType.Down) { this.relatedPressedId = item.id; }
                          else if (e.type === TouchType.Up || e.type === TouchType.Cancel) { this.relatedPressedId = ''; }
                        })
                      }
                    }, (item: RecommendItem) => item.id)
                    // ⭐ 限量渲染展开更多：未挂载的推荐视频按需递增（每次 +10）
                    if (this.relatedVideos.length > this.relatedRenderCount) {
                      Button(`展开更多（还有 ${this.relatedVideos.length - this.relatedRenderCount} 条）`)
                        .fontSize(12)
                        .fontColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                        .backgroundColor('transparent')
                        .border({
                          width: 1,
                          color: this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'),
                          radius: 999
                        })
                        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                        .margin({ top: 6, bottom: 6 })
                        .onClick(() => {
                          this.triggerHaptic();
                          this.relatedRenderCount += 10;
                        })
                    }
                  }
                  .width('100%')
                  .padding({ top: 4, bottom: 4 })
                  .margin({ top: 12 })
                }
              }.width('100%').padding({ top: 13, bottom: 12 });
            }
          }
        }
        .scrollBar(BarState.Off)
        // ⭐ 整卡下拉关灯：内容到顶后的下拉由整卡下移接管，关闭内部回弹避免双重移动
        .edgeEffect(EdgeEffect.None)
        .onScrollFrameBegin((offset: number) => {
          // ⭐ 整卡下拉/回滑期间锁定内部滚动：内容相对卡片保持不动（卡片整体仍随手指滑动）
          //    发生过下拉的本次触摸（含回滑到顶部后）持续锁定，手指松开工恢复正常滚动
          if (this.detailPullDrop > 0 || this.detailPullDragEngaged) return { offsetRemain: 0 };
          return { offsetRemain: offset };
        })
      }
      .width('100%')
      .padding(this.isLightsOff ? { left: 0, right: 0 } : { left: 20, right: 20 })
      .backgroundColor(this.isLs ? 'transparent' : this.getCardContainerBg(this.cardStyleVideoDetail))
      .border(this.isLs ? { width: 0, color: Color.Transparent } : this.getCardContainerBorder(this.cardStyleVideoDetail))
      .borderRadius(this.cardBorderRadius)
      .clip(this.isLightsOff ? false : true)
      .constraintSize({ maxHeight: '100%' })
      }
      .width('100%')
    }
    .width('100%')
    // ⭐ 上滑取消：监听原始触摸坐标（内部手势竞争时 gesture 偏移不可靠）
    .onTouch((e: TouchEvent) => { this.onDetailPullTouch(e); })
  }

  /**
   * 弹幕组件Builder - 统一管理弹幕实例，避免重复创建
   */
  @Builder
  buildDanmakuView(canvasWidth: number, canvasHeight: number) {
    DanmakuView({
      cid: this.vi.cid,
      aid: this.vd?.aid || 0,
      duration: this.dur * 1000,  // 转换为毫秒
      isPlaying: this.play,
      currentTime: this.ct * 1000,  // 转换为毫秒
      config: $danmakuConfig,
        selfDanmaku: $selfDanmakuList,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight
    })
  }
  
  // ═══════════════════════ 关灯短视频覆盖层（v2 沉浸胶囊版）═══════════════════════

  /** 视频卡底部信息：标题 / 描述 / 标签 / 时间·播放·弹幕 */
  @Builder
  shortCardInfo() {
    Column() {
      Text(this.shortTitle())
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ bottom: 7 })
      if (this.shortDesc().length > 0) {
        Text(this.shortDesc())
          .fontSize(11.5)
          .lineHeight(17)
          .fontColor('rgba(255,255,255,0.82)')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ bottom: 9 })
      }
      Row({ space: 6 }) {
        if (this.shortTag1().length > 0) {
          Text('#' + this.shortTag1())
            .fontSize(9.5)
            .fontColor('rgba(255,255,255,0.92)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 150 })
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor('rgba(255,255,255,0.14)')
            .border({ width: 0.5, color: 'rgba(255,255,255,0.24)' })
            .borderRadius(999)
        }
        if (this.shortTag2().length > 0) {
          Text('#' + this.shortTag2())
            .fontSize(9.5)
            .fontColor('rgba(255,255,255,0.92)')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 170 })
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor('rgba(255,255,255,0.14)')
            .border({ width: 0.5, color: 'rgba(255,255,255,0.24)' })
            .borderRadius(999)
        }
      }
      .width('100%')
      .margin({ bottom: 8 })
      if (this.shortMeta().length > 0) {
        Text(this.shortMeta())
          .fontSize(10)
          .fontColor('rgba(255,255,255,0.6)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  @Builder
  shortStatButton(kind: string) {
    Row({ space: 3 }) {
      if (kind === 'like') {
        Image($r('app.media.ic_public_thumbsup_filled'))
          .width(15).height(15)
          .fillColor(this.isLiked ? this.shortTheme() : 'rgba(255,255,255,0.92)')
      } else if (kind === 'coin') {
        Image($r('app.media.ic_public_highlight_filled'))
          .width(15).height(15)
          .fillColor(this.isCoined ? '#FFB800' : 'rgba(255,255,255,0.92)')
      } else {
        Image($r('app.media.heart_square_stack_fill'))
          .width(15).height(15)
          .fillColor(this.isFavorited ? '#FF9F43' : 'rgba(255,255,255,0.92)')
      }
      Text(kind === 'like' ? this.fmtN(this.likeCount) : (kind === 'coin' ? this.fmtN(this.coinCount) : this.fmtN(this.favoriteCount)))
        .fontSize(10.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(kind === 'like'
          ? (this.isLiked ? this.shortTheme() : 'rgba(255,255,255,0.92)')
          : (kind === 'coin'
            ? (this.isCoined ? '#FFB800' : 'rgba(255,255,255,0.92)')
            : (this.isFavorited ? '#FF9F43' : 'rgba(255,255,255,0.92)')))
    }
    .height(40)
    .width(this.shortStatItemW(kind))
    .justifyContent(FlexAlign.Center)
    // ⛔ 不挂 onClick：触摸交给胶囊内容 Row 的 onTouch 分发，HDS 才能拿到按压形变/光斑
  }

  /** 左上：UP 头像 + 名字（展示；关注已拆成右侧独立圆钮） */
  @Builder
  shortUpContent() {
    Row({ space: 7 }) {
      if (this.shortOwnerFace().length > 0) {
        Image(getCachedPixelMap(imageUrlResize(this.shortOwnerFace(), 48)) ?? imageUrlResize(this.shortOwnerFace(), 48))
          .width(30).height(30)
          .borderRadius(15)
          .objectFit(ImageFit.Cover)
      } else {
        Text(this.shortOwnerInitial())
          .width(30).height(30)
          .borderRadius(15)
          .backgroundColor(this.shortTheme())
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor(Color.White)
          .textAlign(TextAlign.Center)
      }
      Text(this.shortOwnerName())
        .fontSize(12.5)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width(this.shortUpW()).height('100%')
    .padding({ left: 4, right: 4 })
    .alignItems(VerticalAlign.Center)
  }

  /** 关注圆钮内容：灰色/主题色图标（玻璃圆由外层 HdsGlassBar 提供，整圆可点） */
  @Builder
  shortFollowContent() {
    Row() {
      Image($r('app.media.checkmark_circle_fill'))
        .width(22).height(22)
        .fillColor(this.isFollowed ? this.shortTheme() : 'rgba(255,255,255,0.45)')
    }
    .width(40).height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  /** 右上：点赞 / 投币 / 收藏（内容画在 HDS 玻璃的 tabBar 里） */
  @Builder
  shortStatsContent() {
    Row() {
      this.shortStatButton('like')
      this.shortStatButton('coin')
      this.shortStatButton('fav')
    }
    .width(this.shortStatsW()).height('100%')
    .padding({ left: 4, right: 4 })
    .alignItems(VerticalAlign.Center)
    .onTouch((e: TouchEvent): void => { this.onShortStatsTouch(e); })
  }

  /** 下方：返回 / 发弹幕 / 弹幕开关 / 评论区 / 全屏（内容画在 HDS 玻璃的 tabBar 里） */
  @Builder
  shortBottomContent() {
    Row() {
      Stack() {
        Image($r('app.media.return_453')).width(20).height(20).fillColor('#FFFFFF')
      }
      .width(40).height(40).borderRadius(20)

      Row({ space: 6 }) {
        Image($r('app.media.danmfas')).width(16).height(16).fillColor(this.shortTheme())
        Text('发弹幕').fontSize(11.5).fontWeight(FontWeight.Bold).fontColor(Color.White)
      }
      .width(140).height(40).borderRadius(20)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Color.Transparent)

      Stack() {
        Image($r('app.media.chat_bubble_text_square_solid'))
          .width(20).height(20)
          .fillColor(this.isDanmakuEnabled ? '#FFFFFF' : 'rgba(255,255,255,0.45)')
        Column()
          .width(6).height(6).borderRadius(3)
          .backgroundColor(this.isDanmakuEnabled ? '#34C759' : '#6B7280')
          .position({ x: 27, y: 8 })
      }
      .width(40).height(40).borderRadius(20)

      Stack() {
        Image($r('app.media.message')).width(20).height(20).fillColor('#FFFFFF')
      }
      .width(40).height(40).borderRadius(20)

      Stack() {
        Image($r('app.media.full_screen_32')).width(20).height(20).fillColor('#FFFFFF')
      }
      .width(40).height(40).borderRadius(20)
    }
    .width(this.shortBottomW()).height('100%')
    .padding({ left: 8, right: 8 })
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.SpaceBetween)
    .onTouch((e: TouchEvent): void => { this.onShortBottomTouch(e); })
  }

  /** 上/下一条：只渲染封面 + 标题，跟着手指滑入视频卡 */
  @Builder
  shortNeighbor(dir: number) {
    if (this.shortNeighborItem(dir) !== undefined) {
      Stack({ alignContent: Alignment.BottomStart }) {
        if (this.shortNeighborCover(dir).length > 0) {
          Image(this.shortNeighborCover(dir))
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
        } else {
          Column().width('100%').height('100%').backgroundColor('#111318')
        }
        Column()
          .width('100%').height(this.shortCardH() * 0.5)
          .linearGradient({ angle: 180, colors: [['#00000000', 0], ['#E6080604', 1]] })
          .position({ x: 0, y: this.shortCardH() * 0.5 })
        Column() {
          Text(this.shortNeighborTitle(dir))
            .fontSize(15).fontWeight(FontWeight.Bold).fontColor(Color.White)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.shortNeighborOwner(dir).length > 0) {
            Text(this.shortNeighborOwner(dir))
              .fontSize(11).fontColor('rgba(255,255,255,0.82)')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%').margin({ top: 4 })
          }
          if (this.shortNeighborMeta(dir).length > 0) {
            Text(this.shortNeighborMeta(dir))
              .fontSize(9).fontColor('rgba(255,255,255,0.55)')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%').margin({ top: 3 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 })
        .alignItems(HorizontalAlign.Start)
      }
      .width(this.shortCardW()).height(this.shortCardH())
      .position({ x: this.shortCardX(), y: this.shortCardY() })
      .translate({ y: dir * this.shortCardH() + this.shortDragY })
      .borderRadius(24)
      .clip(true)
      .backgroundColor('#000000')
      // 静止时只显示当前卡；上下滑时才把上/下一条露出来（避免卡底与底栏之间露出下一条的边）
      .opacity(this.shortDragY === 0 ? 0 : 1)
      .hitTestBehavior(HitTestMode.None)
    }
  }

  /** 当前视频卡的 UI 层：封面（换源中）/ 暗色渐变 / 信息 / 中央播放；触摸挂在本层 Stack 上 */
  @Builder
  shortCardLayer() {
    Stack() {
      // 拖动/换源期间用封面承接（XComponent 是原生 SURFACE，不能跟着位移）
      if ((this.shortSwitching || this.shortDragY !== 0) &&
        (this.shortSwitching ? this.shortCover : this.vi.cover).length > 0) {
        Image(this.shortSwitching ? this.shortCover : this.vi.cover)
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
          .hitTestBehavior(HitTestMode.None)
      }
      Column()
        .width('100%').height(this.shortCardH() * 0.58)
        .linearGradient({ angle: 180, colors: [['#00000000', 0], ['#C70A0806', 0.62], ['#F00A0806', 1]] })
        .position({ x: 0, y: this.shortCardH() * 0.42 })
        .hitTestBehavior(HitTestMode.None)
      Stack({ alignContent: Alignment.BottomStart }) {
        this.shortCardInfo()
      }
      .width('100%').height('100%')
      .hitTestBehavior(HitTestMode.None)

      if (!this.play) {
        Column({ space: 9 }) {
          Stack() {
            Image($r('app.media.play_fill')).width(25).height(25).fillColor(Color.White)
          }
          .width(64).height(64)
          .borderRadius(32)
          .backgroundColor('rgba(20,16,12,0.28)')
          .border({ width: 1.5, color: 'rgba(255,255,255,0.66)' })
          .shadow({ radius: 18, color: 'rgba(0,0,0,0.35)', offsetY: 8 })
          Text(this.shortDuration() > 0 ? `轻点播放 · ${this.fmtT(this.shortDuration())}` : '轻点播放')
            .fontSize(9.5)
            .fontColor('rgba(255,255,255,0.86)')
        }
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%').height('100%')
    .borderRadius(24)
    .clip(true)
    // 触摸兜底：卡片本身收触摸（子层全部 None），点击暂停 / 上下滑切换
    .backgroundColor('#01000000')
    .onClick((): void => {
      logInfo(`[ShortVideo] 卡片点击 togglePP, play=${this.play}`);
      this.togglePP();
    })
    .gesture(
      PanGesture({ direction: PanDirection.Vertical, distance: 8 })
        .onActionUpdate((event: GestureEvent): void => {
          if (this.shortSettling) return;
          this.shortDragY = event.offsetY;
        })
        .onActionEnd((): void => {
          logInfo(`[ShortVideo] 拖动结束 dragY=${this.shortDragY.toFixed(1)}`);
          this.finishShortDrag();
        })
        .onActionCancel((): void => {
          this.settleShortDrag(0);
        })
    )
  }

  @Builder
  buildShortVideoChrome() {
    Stack() {
      // 三组沉浸光感胶囊：内容画在 HdsTabs 的 tabBar 里、玻璃收触摸（hitThrough:false）
      // ⇒ 系统按压形变 + 光斑；动作由内容 Row 的 onTouch 按落点分发。
      Stack() {
        HdsGlassBar({
          barWidth: this.shortUpW(), barHeight: 40, contentPadding: 4,
          hitThrough: true, onButtonClick: (): void => {}
        }) {
          this.shortUpContent()
        }
      }
      .width(this.shortUpW() + 16).height(56)
      .position({ x: 4, y: 18 })

      // 关注：独立圆形玻璃按钮，直径 = 左侧胶囊高度 40
      Stack() {
        HdsGlassBar({
          barWidth: 40, barHeight: 40, contentPadding: 4,
          hitThrough: false, onButtonClick: (): void => { this.toggleFollow(); }
        }) {
          this.shortFollowContent()
        }
      }
      .width(56).height(56)
      .position({ x: this.shortFollowX(), y: 18 })

      Stack() {
        HdsGlassBar({
          barWidth: this.shortStatsW(), barHeight: 40, contentPadding: 4,
          hitThrough: false, onButtonClick: (): void => {}
        }) {
          this.shortStatsContent()
        }
      }
      .width(this.shortStatsW() + 16).height(56)
      .position({ x: this.cw - 4 - (this.shortStatsW() + 16), y: 18 })

      Stack() {
        HdsGlassBar({
          barWidth: this.shortBottomW(), barHeight: 56, contentPadding: 4,
          hitThrough: false, onButtonClick: (): void => {}
        }) {
          this.shortBottomContent()
        }
      }
      .width(this.shortBottomW() + 16).height(72)
      .position({ x: this.shortBottomX() - 8, y: this.ch - 76 })

      // ⭐ 卡片 UI 舞台放在**最上层**：上下滑时卡片从顶栏/底栏**上面**推出去，
      //    不会被上下胶囊挡住（用户反馈的“有遮挡、不到屏幕边缘”）。
      //    静止时卡片在卡位，舞台整体 Transparent，胶囊照常收触摸。
      Stack() {
        Stack() {
          this.shortCardLayer()
        }
        .width(this.shortCardW()).height(this.shortCardH())
        .position({ x: this.shortCardX(), y: this.shortCardY() })
        .translate({ y: this.shortDragY })

        this.shortNeighbor(-1)
        this.shortNeighbor(1)
      }
      .width('100%').height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%').height('100%')
  }

  // ═══ 常驻播放器层：XComponent 单实例（全文件唯一），跨布局分支常驻，只改几何不改挂载 ═══
  @Builder
  buildPlayerOverlay() {
    Stack() {
      XComponent({ id: 'video_xc', type: XComponentType.SURFACE, controller: this.xc })
        .onLoad(this.onXC)
        .width(this.ovVideoW())
        .height(this.ovVideoH())
        // ⚠️ 这里必须写成"缩小动画期间 = SHRINK_ANIM_DURATION"，**不能写 0**。
        //    实测结论：节点自带的 .animation() 会**覆盖**外层 animateTo（不是相反）——
        //      duration 写 120 → 这一层只走 120ms，比详情卡/评论区先到位（最初的现象）；
        //      duration 写 0   → 这一层直接瞬跳到位，反而更不同步。
        //    所以只能让它与 animateVidShrink 里那条共享 animateTo **完全同参**（300ms + EaseOut）。
        //    其余场景（旋转/分支切换）仍走 120ms，保持不变。
        .animation({
          duration: this.isShortVideo()
            ? (this.shortSettling ? 250 : 0)
            : (this.shrinkAnimating ? this.SHRINK_ANIM_DURATION : 120),
          curve: Curve.EaseOut
        }) // ⭐ 短视频拖动：跟手 0ms、松手 250ms；其余场景保持原值
        .constraintSize({ minWidth: 1, minHeight: 1 }) // ⭐ 窗口模式切换瞬时 0 尺寸布局时保底，防 surface 被杀
        .borderRadius(this.isShortVideo() ? 24 : this.fsLerpRadius(this.cardBorderRadius, 0))
        .clip(true)
        .backgroundColor(this.ovPlateBg())
        .shadow(this.isShortVideo()
          ? { radius: 24, color: 'rgba(0,0,0,0.55)', offsetY: 14 }
          : { radius: 0, color: Color.Transparent, offsetY: 0 })

      // ⭐ 封面占位（视频未就绪时显示，与视频区域同尺寸，16:9 不裁切）
      if (!this.contentVisible && this.vi.cover) {
        Image(this.coverSrc())
          .width(this.ovVideoW())
          .height(this.ovVideoH())
          .objectFit(ImageFit.Cover)
          .borderRadius(this.isShortVideo() ? 24 : this.fsLerpRadius(this.cardBorderRadius, 0))
          .clip(true)
      }
      // ⭐ 弹幕层（叠加在视频上；关灯+视频外弹幕由分支内的外移实例承接）
      //   挂载条件只保留"数据可用性 + 布局分支"，【开关状态不再参与卸载】。
      //   原先 `isDanmakuEnabled` 在这里 → 开关弹幕 = 组件销毁重建 = 新建 controller
      //   + 重新下载弹幕分段（万条弹幕约 4 秒空窗 + 重复流量）。
      //   现在常驻挂载，显隐用 visibility，停帧用 config.enable（渲染链自带该判断）。
      //   ⚠️ 必须用 Hidden 而不是 None：None 会让 Canvas 量不到尺寸，
      //      onCanvasReady 走进"尺寸无效"分支，canvasReady 永远为 false → 弹幕永不初始化。
      if (this.vi.cid > 0 &&
        (this.isShortVideo() ||
          (!(this.isLightsOffDanmakuOutside() && !this.isLs && !this.fs) && !this.isLightsOffDanmakuRight()))) {
        // ⭐ 弹幕层自己的定位容器：**尺寸 = 播放器区域**（全屏＝整屏，含左右黑边），居中于常驻层。
        //    之前直接铺满常驻层 → 非全屏横屏下会越出视频槽，把弹幕画到右侧评论栏上。
        Stack() {
          DanmakuView({
            cid: this.vi.cid,
            aid: this.vd?.aid || 0,
            duration: this.dur * 1000,
            currentTime: this.ct * 1000,
            isPlaying: this.play,
            cookie: AppStorage.get<string>('biliCookie') || '',
            // ⚠️ 传参必须与容器同源（同一个 ovDanmakuCW/CH），否则又是两套尺寸
            canvasWidth: this.ovDanmakuCW(),
            canvasHeight: this.ovDanmakuCH(),
            config: $danmakuConfig,
            selfDanmaku: $selfDanmakuList,
          })
            .width('100%')
            .height('100%')
          // ⭐ **缩小态全程**隐藏弹幕（不只是那 300ms 动画期间）：缩小后是个 120vp 的小窗（默认正圆），
          //    弹幕在里面既看不清也只剩几条，还会持续占主线程 —— 用户明确要求缩小时不显示弹幕。
          //    配合 animateVidShrink 里把 config.enable 也置 false（停掉渲染循环，而不只是不绘制）。
            //    ⚠️ 用 Hidden 而不是 None —— None 会让 Canvas 量不到尺寸，canvasReady 永远为 false，
            //       弹幕就再也初始化不起来了（见上方挂载条件的注释）。
            .visibility(this.isDanmakuEnabled && !this.isVidShrunk() ? Visibility.Visible : Visibility.Hidden)
        }
        // ⭐ 缩小/还原动画期间用冻结尺寸（见 dmFreezeW 注释）：画布尺寸逐帧变化会让 ArkUI
        //    每帧重建 surface + 重建轨道（实测 300ms 内 19 次 → 掉帧）。
        .width(this.shrinkAnimating && this.dmFreezeW > 0 ? this.dmFreezeW : this.ovDanmakuCW())
        .height(this.shrinkAnimating && this.dmFreezeH > 0 ? this.dmFreezeH : this.ovDanmakuCH())
        .position({
          x: this.shrinkAnimating && this.dmFreezeW > 0
            ? Math.max(0, (this.ovRectW() - this.dmFreezeW) / 2)
            : this.ovDanmakuX(),
          y: this.shrinkAnimating && this.dmFreezeH > 0
            ? Math.max(0, (this.ovRectH() - this.dmFreezeH) / 2)
            : this.ovDanmakuY()
        })
        .clip(true)   // 兜底：任何情况下都不画到视频画面外
      }
      VideoControls({
        isPlaying: $play,
        videoTitle: this.vd?.title || this.vi.title || '',
        videoOwnerFace: this.vd?.owner?.face ? imageUrlResize(this.vd.owner.face, 48) : '',
        videoOwnerName: this.vd?.owner?.name ?? '',
        isFollowed: this.isFollowed,
        followColor: this.playerFollowTheme ? this.customThemeColor : '#FB7299',
        toggleFollow: () => { this.toggleFollow(); },
        currentTime: $ct,
        duration: $dur,
        isControlsVisible: $cv,
        isLocked: $lk,
        isFullscreen: $fs,
        isMirrorControls: $isMirrorControls,
        isMuted: $mute,
        playbackRate: $rt,
        showGestureHint: $gh,
        gestureHintMainText: $ght,
        gestureHintProgress: $ghp,
        gestureHintType: $ghtType,
        // ⭐ 本次进度调节的起点秒数（提示胶囊右侧显示 +10S / -10S 用）
        gestureHintBase: $ghb,
        // ⭐ 进度调节缩略图（与上面那组提示同源；无缩略图的视频该对象恒为 show=false，不占位）
        thumb: $thumb_,
        showBottomHint: $bh,
        bottomHintImage: $bhi,
        bottomHintText: $bht,
        showUnlockButton: this.ub,
        // ⭐ 提示弹层把"返回"转交回本页（弹层吃掉了系统返回键/侧滑，见 VideoControls 弹层注释）
        onOverlayBack: () => { this.onOverlayBack_(); },
        onBackPress: () => { if (this.fs) { this.toggleFS(); } else { this.goBack(); } },
        onHomePress: () => { this.goHome(); },
        togglePlayPause: () => { this.togglePP(); },
        seekTo: (time: number) => { this.seek(time, false, true); },
        // ⭐ 进度条交互（Slider 的 Down / Up / Cancel）：拖动中冻结 ct 并抑制控制栏自动隐藏，
        //   松手统一提交一次。详见 onSeekBarInteract_
        onSeekBarInteract: this.onSeekBarInteract_,
        formatTime: this.fmtT,
        setPlaybackRate: (rate: number) => { this.setRate(rate); },
        toggleLock: () => { this.handlingUnlockClick = true; this.toggleLock(); },
        onMirrorToggle: () => { this.onMirrorToggle(); },
        toggleMute: () => { this.toggleMute(); },
        hasNextEpisode: this.hasNextEpisode(),
        hasPreviousEpisode: this.currentPageIndex > 0,
        togglePreviousEpisode: () => { this.cancelDelayHide(); this.triggerHaptic(); this.switchEpisode(this.currentPageIndex - 1); },
        toggleNextEpisode: () => { this.cancelDelayHide(); this.triggerHaptic(); this.switchEpisode(this.currentPageIndex + 1); },
        toggleFullscreen: () => { this.toggleFS(); },
        showColorStyleOptions: () => { /* 暂禁用，等 SDK 更新后启用 */ },
        showScaleOptions: () => { this.cancelDelayHide(); if (!this.sp) { this.cv = false; } this.sp = !this.sp; this.ip = this.sp; },
        showQualityOptions: () => { this.cancelDelayHide(); if (!this.qp) { this.cv = false; } this.qp = !this.qp; this.ip = this.qp; },
        // ⭐ 更多菜单
        onMorePress: () => {
          this.cancelDelayHide();
          if (this.fs) {
            if (!this.mp) { this.cv = false; }
            this.mp = !this.mp;
            this.ip = this.mp;
          } else {
            if (!this.mpb) { this.cv = false; }
            this.mpb = !this.mpb;
            this.ip = this.mpb;
          }
        },
        // ⭐ 弹幕开关
        isDanmakuEnabled: $isDanmakuEnabled,
        toggleDanmaku: () => { this.toggleDanmaku(); },
        onDanmakuPress: () => { this.showDanmakuSheet = true; },
        onEpisodePress: () => { this.cancelDelayHide(); this.triggerHaptic(); this.showEpisodeSheet = true; },
        // ⭐ 全屏评论浮层开关：打开时 ip=true + cancelDelayHide 保控制栏不自动隐藏，关闭后恢复延迟隐藏
        onCommentPress: () => { this.cancelDelayHide(); this.cp = !this.cp; this.ip = this.cp; if (!this.cp && this.cv) { this.resetCT(); } this.cv = !this.cp; },
        hasMultipleEpisodes: (this.vd?.pages?.length ?? 0) > 1,
        isBackgroundPlayback: $bgp,
        qualityLabel: this.ql,
        toggleBackgroundPlayback: () => { this.toggleBackgroundPlayback(); }
      }).width('100%').height('100%')
        .opacity(this.isShortVideo() ? 0 : (this.fs && this.isLightsOff ? 0 : 1))
        .hitTestBehavior(this.isShortVideo() ? HitTestMode.None : (this.fs && this.isLightsOff ? HitTestMode.Block : HitTestMode.Default))
        .animation({ duration: 300 })

      // ⭐ 手势提示（原全屏/竖屏分支各自挂载，现统一在常驻层；关灯短视频不显示）
      if (this.rh && !this.isShortVideo() && (!this.isLightsOff || !this.fs)) {
        Column() {
          Text(this.rht).fontSize(24).fontColor($r('app.color.color_player_text'))
            .fontWeight(FontWeight.Bold).opacity(0.9)
            .padding({ left: 20, right: 20, top: 12, bottom: 12 })
            .backgroundColor($r('app.color.color_overlay_dark')).borderRadius(16);
        }.width('100%').height('100%').justifyContent(FlexAlign.Center);
      }
    }
    .position({ x: this.ovRectX(), y: this.ovRectY() })
    .width(this.ovRectW())
    .height(this.ovRectH())
    // ⚠️ 同 XComponent：缩小/还原期间必须与共享 animateTo **同参**（300ms + EaseOut），不能写 0。
    //    原因见 XComponent 那条注释 —— 节点自带的 .animation() 覆盖外层 animateTo，
    //    写 0 会让这一层瞬跳、写 120 会让它先到位，两者都不同步。
    .animation({
      duration: this.isShortVideo()
        ? (this.shortSettling ? 250 : 0)
        : (this.shrinkAnimating ? this.SHRINK_ANIM_DURATION : 120),
      curve: Curve.EaseOut
    }) // ⭐ 短视频：整层 position 跟手，松手 250ms 与卡片 UI 同步
    // ⭐ 透明度必须在 .animation() 之后：这样它由外层 animateTo 驱动，与 vidShrink 同步 300ms 淡出；
    //    若写在 .animation() 之前，会被那条 120ms 的隐式动画接管而先到位。
    .opacity(this.isShortVideo() && this.shortDragY !== 0 ? 0 : this.shrinkPlateOpacity())
    // ⭐ 圆角：非全屏时改由 shrinkRadius() 给值 —— 缩小时它随 vidShrink 从卡片圆角连续过渡到
    //    方框边长的一半（= 正圆），配合 shrinkSlotW/H 的正方形外框裁出圆形小窗。
    //    全屏时仍走原来的 fsLerpRadius（20 ↔ 卡片圆角）。非缩小时两者取值相同，行为不变。
    .borderRadius(this.isShortVideo() ? 24 : (this.fs ? this.fsLerpRadius(20, this.cardBorderRadius) : this.shrinkRadius()))
    .clip(true)
    .backgroundColor(this.isShortVideo() ? Color.Transparent : $r('app.color.color_player_background'))
    .renderGroup(true) // ⭐ 离屏渲染，让颜色滤镜作用于视频表面（常开，避免切换时重建渲染子树导致抖动）
    .saturate(this.saturateVal_)
    .contrast(this.contrastVal_)
    .brightness(this.brightnessVal_)
    .sepia(this.sepiaVal_)
    .colorBlend(this.colorBlendVal_)
    .onTouch(this.onVT)
    .onClick(() => { if (this.lk) { this.tglUB(); } })
    // ⭐ 横屏/竖屏横看：右滑进全屏——手势起点在视频上时由常驻层识别（视频区已不再属于分支容器）
    .gesture(
      PanGesture({ direction: PanDirection.Right, distance: 20 })
        .onActionUpdate((event: GestureEvent) => {
          if (this.fs || (!this.isLs && !this.isLandscapeVertical)) return;
          // ⭐ 进度条交互中让位（官方：stopPropagation 只拦 onTouch，拦不住父节点的手势对象）
          if (this.sliderDragging_) return;
          if (this.gm_ === 'seek') return;
          let p = Math.min(1, Math.pow(event.offsetX / 195, 1.2));
          if (p > 0.02) this.updateFSPanProgress(p);
        })
        .onActionEnd(() => {
          if (this.fs || (!this.isLs && !this.isLandscapeVertical)) return;
          if (this.gm_ === 'seek') {
            animateTo({ duration: 260, curve: Curve.EaseOut }, () => { this.fsPanProgress = 0; });
            return;
          }
          if (this.fsPanProgress > 0.3) this.startFSAnimation();
          else animateTo({ duration: 260, curve: Curve.EaseOut }, () => { this.fsPanProgress = 0; });
        })
        .onActionCancel(() => {
          if (this.fs || (!this.isLs && !this.isLandscapeVertical)) return;
          animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.fsPanProgress = 0; });
          this.fireHaptic(18);
        })
    )
  }

  // ⭐ 横屏非全屏布局（自 build() 抽出，供内容分支常驻渲染复用）
  @Builder
  buildLandscape() {
    // 横屏非全屏模式（横屏视频）
    Flex({ direction: this.isLayoutSwapped ? FlexDirection.RowReverse : FlexDirection.Row }) {
      // 左侧区域：播放器 + 详情卡片
      Column() {
        Stack() {
          // ⭐ 播放器已移至常驻层：占位槽保持原布局尺寸，由 onAreaChange 把实际矩形同步给常驻层
        }
        .width(this.isLightsOff ? this.loVideoWidth() : this.lsvw)
        .height(this.isLightsOff ? this.loVideoHeight() : this.lsvh)
        .clip(true)
        .borderRadius(this.cardBorderRadius)
        .onAreaChange(this.onSlotArea)
        .margin({ top: this.cardMargin, bottom: 0 })   // 播放器上下边距

        // ⭐ 直板机布局开关→详情/评论区切换
        if (this.phoneLayoutToggle) {
          // 剩余区域垂直居中按钮行
          Column() {
            if (this.isLayoutSwapped && this.isLs) {
              // 镜像反转顺序：合集 → 选集 → 浮窗 → 浅色 → 详情·评论 → 自由 → 切换
              Row({ space: 6 }) {
                // ⭐ 合集按钮（镜像反转后位于选集左侧，与正常顺序"选集→合集"对称）
                if (this.vd?.ugc_season?.id && this.vd.ugc_season.sections && this.vd.ugc_season.sections.length > 0) {
                  Column() {
                    Image($r('app.media.heji'))
                      .width(18).height(18)
                      .fillColor(this.seasonPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                      .scale({ x: this.seasonScale, y: this.seasonScale })
                      .animation({ duration: 100, curve: Curve.EaseOut })
                    Text('合集')
                      .fontSize(10)
                      .fontColor(this.seasonPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                      .margin({ top: 3 })
                  }
                  .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                  .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                  .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                  .margin({ left: 4, right: 4 })
                  .onClick(() => { this.seasonScale = 0.85; this.seasonPressed = true; setTimeout(() => { this.seasonScale = 1; this.seasonPressed = false; }, 150); this.showSeasonSheet = true; })
                }

                // 选集按钮（独立圆形，仅多P视频显示）
                if (this.vd?.pages && this.vd.pages.length > 1) {
                  Column() {
                    Image($r('app.media.externaldrive_fill_3'))
                      .width(18).height(18)
                      .fillColor(this.episodePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                      .scale({ x: this.episodeScale, y: this.episodeScale })
                      .animation({ duration: 100, curve: Curve.EaseOut })
                    Text('选集')
                      .fontSize(10)
                      .fontColor(this.episodePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                      .margin({ top: 3 })
                  }
                  .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                  .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                  .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                  .margin({ left: 4, right: 4 })
                   .onClick(() => { this.episodeScale = 0.85; this.episodePressed = true; setTimeout(() => { this.episodeScale = 1; this.episodePressed = false; }, 150); this.showEpisodeSheet = true; })
                 }


                 // 最小化到悬浮按钮
                Column() {
                  Image($r('app.media.media_center'))
                    .width(18).height(18)
                    .fillColor(this.minimizePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .scale({ x: this.minimizeScale, y: this.minimizeScale })
                    .animation({ duration: 100, curve: Curve.EaseOut })
                  Text('浮窗').fontSize(10)
                    .fontColor(this.minimizePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .margin({ top: 3 })
                }
                .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .margin({ left: 4, right: 4 })
                .onClick(() => this.minimizeToFloating())

                // 深色/浅色模式切换按钮（独立圆形）
                Column() {
                  Image(this.isDarkMode ? $r('app.media.ic_settings_darkmode') : $r('app.media.sun_min'))
                    .width(18).height(18)
                    .fillColor(this.darkModePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .scale({ x: this.darkModeScale, y: this.darkModeScale })
                    .animation({ duration: 100, curve: Curve.EaseOut })
                  Text(this.isDarkMode ? '深色' : '浅色').fontSize(10)
                    .fontColor(this.darkModePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .margin({ top: 3 })
                }
                .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .margin({ left: 4, right: 4 })
                .onClick(() => this.toggleDarkMode())

                // 详情·评论胶囊按钮
                Column() {
                  Image(this.landShowDetail ? $r('app.media.message') : $r('app.media.form'))
                    .width(18).height(18)
                    .fillColor(this.detailCommentBtnPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .scale({ x: this.detailCommentBtnScale, y: this.detailCommentBtnScale })
                    .animation({ duration: 100, curve: Curve.EaseOut })
                  Text('详情·评论').fontSize(10)
                    .fontColor(this.detailCommentBtnPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .margin({ top: 3 })
                }
                .width(this.NAV_BTN_CAPSULE_W).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .margin({ left: 4, right: 4 })
                .onClick(() => {
                  this.detailCommentBtnScale = 0.9;
                  this.detailCommentBtnPressed = true;
                  setTimeout(() => { this.detailCommentBtnScale = 1; this.detailCommentBtnPressed = false; }, 150);
                  this.triggerHaptic();
                  animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
                    this.landShowDetail = !this.landShowDetail;
                  });
                })

                // ⭐ 旋转模式切换按钮（自由）
                Column() {
                  Image(this.getRotationIcon())
                    .width(18).height(18)
                    .fillColor(this.rotationPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .scale({ x: this.rotationScale, y: this.rotationScale })
                    .animation({ duration: 100, curve: Curve.EaseOut })
                  Text(this.getRotationText()).fontSize(10)
                    .fontColor(this.rotationPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .margin({ top: 3 })
                }
                .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .margin({ left: 4, right: 4 })
                .onClick(() => this.toggleRotationMode())

                // ⭐ 布局切换按钮（圆形，仅横屏非全屏模式显示）
                if (this.isLs) {
                  Column() {
                    Image($r('app.media.ic_gallery_collage'))
                      .width(18).height(18)
                      .fillColor(this.layoutSwapPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                      .scale({ x: this.layoutSwapScale, y: this.layoutSwapScale })
                      .animation({ duration: 100, curve: Curve.EaseOut })
                    Text('切换').fontSize(10)
                      .fontColor(this.layoutSwapPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                      .margin({ top: 3 })
                  }
                  .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                  .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                  .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                  .margin({ left: 4, right: 4 })
                  .onClick(() => this.toggleLayoutSwap())
                }
              }
              .margin({ top: this.NAV_BTN_ROW_MARGIN, bottom: this.NAV_BTN_ROW_MARGIN })
              .transition(TransitionEffect.asymmetric(
                TransitionEffect.translate({ x: 30 }).combine(TransitionEffect.opacity(0))
                  .animation({ duration: 250, curve: Curve.EaseOut }),
                TransitionEffect.translate({ x: -30 }).combine(TransitionEffect.opacity(0))
                  .animation({ duration: 200, curve: Curve.EaseIn })
              ))
            } else {
              // 原顺序：切换 → 自由 → 详情·评论 → 浅色 → 浮窗 → 选集
              Row({ space: 6 }) {
                // ⭐ 布局切换按钮（圆形，仅横屏非全屏模式显示）
                if (this.isLs) {
                  Column() {
                    Image($r('app.media.ic_gallery_collage'))
                      .width(18).height(18)
                      .fillColor(this.layoutSwapPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                      .scale({ x: this.layoutSwapScale, y: this.layoutSwapScale })
                      .animation({ duration: 100, curve: Curve.EaseOut })
                    Text('切换').fontSize(10)
                      .fontColor(this.layoutSwapPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                      .margin({ top: 3 })
                  }
                  .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                  .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                  .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                  .margin({ left: 4, right: 4 })
                  .onClick(() => this.toggleLayoutSwap())
                }

                // ⭐ 旋转模式切换按钮（自由）
                Column() {
                  Image(this.getRotationIcon())
                    .width(18).height(18)
                    .fillColor(this.rotationPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .scale({ x: this.rotationScale, y: this.rotationScale })
                    .animation({ duration: 100, curve: Curve.EaseOut })
                  Text(this.getRotationText()).fontSize(10)
                    .fontColor(this.rotationPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .margin({ top: 3 })
                }
                .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .margin({ left: 4, right: 4 })
                .onClick(() => this.toggleRotationMode())

                // 详情·评论胶囊按钮
                Column() {
                  Image(this.landShowDetail ? $r('app.media.message') : $r('app.media.form'))
                    .width(18).height(18)
                    .fillColor(this.detailCommentBtnPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .scale({ x: this.detailCommentBtnScale, y: this.detailCommentBtnScale })
                    .animation({ duration: 100, curve: Curve.EaseOut })
                  Text('详情·评论').fontSize(10)
                    .fontColor(this.detailCommentBtnPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .margin({ top: 3 })
                }
                .width(this.NAV_BTN_CAPSULE_W).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .margin({ left: 4, right: 4 })
                .onClick(() => {
                  this.detailCommentBtnScale = 0.9;
                  this.detailCommentBtnPressed = true;
                  setTimeout(() => { this.detailCommentBtnScale = 1; this.detailCommentBtnPressed = false; }, 150);
                  this.triggerHaptic();
                  animateTo({ duration: 250, curve: Curve.EaseOut }, () => {
                    this.landShowDetail = !this.landShowDetail;
                  });
                })

                // 深色/浅色模式切换按钮（独立圆形）
                Column() {
                  Image(this.isDarkMode ? $r('app.media.ic_settings_darkmode') : $r('app.media.sun_min'))
                    .width(18).height(18)
                    .fillColor(this.darkModePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .scale({ x: this.darkModeScale, y: this.darkModeScale })
                    .animation({ duration: 100, curve: Curve.EaseOut })
                  Text(this.isDarkMode ? '深色' : '浅色').fontSize(10)
                    .fontColor(this.darkModePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .margin({ top: 3 })
                }
                .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .margin({ left: 4, right: 4 })
                .onClick(() => this.toggleDarkMode())

                // 最小化到悬浮按钮
                Column() {
                  Image($r('app.media.media_center'))
                    .width(18).height(18)
                    .fillColor(this.minimizePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .scale({ x: this.minimizeScale, y: this.minimizeScale })
                    .animation({ duration: 100, curve: Curve.EaseOut })
                  Text('浮窗').fontSize(10)
                    .fontColor(this.minimizePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                    .margin({ top: 3 })
                }
                .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .margin({ left: 4, right: 4 })
                .onClick(() => this.minimizeToFloating())

                // 选集按钮（独立圆形，仅多P视频显示）
                if (this.vd?.pages && this.vd.pages.length > 1) {
                  Column() {
                    Image($r('app.media.externaldrive_fill_3'))
                      .width(18).height(18)
                      .fillColor(this.episodePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                      .scale({ x: this.episodeScale, y: this.episodeScale })
                      .animation({ duration: 100, curve: Curve.EaseOut })
                    Text('选集').fontSize(10)
                      .fontColor(this.episodePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                      .margin({ top: 3 })
                  }
                  .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                  .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                  .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                  .margin({ left: 4, right: 4 })
                   .onClick(() => { this.episodeScale = 0.85; this.episodePressed = true; setTimeout(() => { this.episodeScale = 1; this.episodePressed = false; }, 150); this.showEpisodeSheet = true; })
                 }
                 // ⭐ 合集按钮（选集右侧，仅UGC合集显示）
                 if (this.vd?.ugc_season?.id && this.vd.ugc_season.sections && this.vd.ugc_season.sections.length > 0) {
                   Column() {
                     Image($r('app.media.heji'))
                       .width(18).height(18)
                       .fillColor(this.seasonPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                       .scale({ x: this.seasonScale, y: this.seasonScale })
                       .animation({ duration: 100, curve: Curve.EaseOut })
                     Text('合集').fontSize(10)
                       .fontColor(this.seasonPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                       .margin({ top: 3 })
                   }
                   .width(this.NAV_BTN_SIZE).height(this.NAV_BTN_SIZE).borderRadius(this.NAV_BTN_SIZE / 2)
                   .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
                   .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                   .margin({ left: 4, right: 4 })
                   .onClick(() => { this.seasonScale = 0.85; this.seasonPressed = true; setTimeout(() => { this.seasonScale = 1; this.seasonPressed = false; }, 150); this.showSeasonSheet = true; })
                 }
               }
              .margin({ top: this.NAV_BTN_ROW_MARGIN, bottom: this.NAV_BTN_ROW_MARGIN })
              .transition(TransitionEffect.asymmetric(
                TransitionEffect.translate({ x: -30 }).combine(TransitionEffect.opacity(0))
                  .animation({ duration: 250, curve: Curve.EaseOut }),
                TransitionEffect.translate({ x: 30 }).combine(TransitionEffect.opacity(0))
                  .animation({ duration: 200, curve: Curve.EaseIn })
              ))
            }
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .opacity((1 - Math.pow(this.fsPanProgress, 0.8)) * (this.isLightsOff ? 0 : 1))
          .hitTestBehavior(this.isLightsOff ? HitTestMode.Block : HitTestMode.Default)
        } else {
          Column() { this.bDetailCard() }
          .width(this.lsvw)
          .layoutWeight(1)
          // ⭐ 卡片置于视频区域之下：外侧的下拉关灯提示只会出现在视频下方的缝隙中（不盖在视频上）
          .zIndex(-1)
          .margin({ top: this.cardMargin, bottom: this.cardMargin })
          .backgroundColor(this.getCardContainerBg(this.cardStyleVideoDetail))
          .border(this.getCardContainerBorder(this.cardStyleVideoDetail))
          .borderRadius(this.cardBorderRadius)
          // ⭐ 不裁切子内容：让外侧的下拉关灯提示可以悬在卡片上缘上方（圆角由内层 borderRadius+clip 处理）
          .scale({
            x: 1 - this.fsPanProgress * 0.1,
            y: 1 - this.fsPanProgress * 0.1,
            centerX: '50%',
            centerY: '50%'
          })
          .opacity((1 - Math.pow(this.fsPanProgress, 0.8)) * (this.isLightsOff ? 0 : 1))
          .hitTestBehavior(this.isLightsOff ? HitTestMode.Block : HitTestMode.Default)
          // ⭐ 整卡下拉关灯：卡片可见本体跟随手指下滑
          .translate({ y: this.detailPullDrop * 120 })
        }
      }
      .flexShrink(0)
      // 关键：播放器区域的外边距（镜像时左右交换）
      .margin({
        left: this.isLayoutSwapped ? 0 : this.cardMargin,
        right: this.isLayoutSwapped ? this.cardMargin : 0
      })
      .animation({ duration: 400, curve: curves.springMotion(0.35, 0.75) })

      // 右侧区域：直板机布局开关→切换详情/评论区；关闭→保持原评论区
      Column() {
        if (this.phoneLayoutToggle) {
          if (this.landShowDetail) {
            Column() { this.bDetailCard() }
            .layoutWeight(1)
            // ⭐ 不裁切子内容：让外侧的下拉关灯提示可以悬在卡片上缘上方（圆角由内层 borderRadius+clip 处理）
            .transition(TransitionEffect.opacity(0).animation({ duration: 200 }))
            // ⭐ 整卡下拉关灯：只移动卡片本身，评论区不跟随
            .translate({ y: this.detailPullDrop * 120 })
          } else {
            this.buildLandscapeCommentsSection()
          }
        } else {
          this.buildLandscapeCommentsSection()
        }
      }
      .layoutWeight(1)
      .backgroundColor(this.getCardContainerBg(this.cardStyleVideoCommentSection))
      .border(this.getCardContainerBorder(this.cardStyleVideoCommentSection))
      .borderRadius(this.cardBorderRadius)
      .clip(true)
      .margin({ left: this.cardMargin, right: this.cardMargin, top: this.cardMargin, bottom: this.cardMargin })   // 评论区四周边距
      .scale({
        x: 1 - this.fsPanProgress * 0.1,
        y: 1 - this.fsPanProgress * 0.1,
        centerX: '50%',
        centerY: '50%'
      })
      .opacity((1 - Math.pow(this.fsPanProgress, 0.8)) * (this.isLightsOff ? 0 : 1))
      .hitTestBehavior(this.isLightsOff ? HitTestMode.Block : HitTestMode.Default)
      // ⭐ 横屏非全屏：左滑评论区 → 超过阈值触发布局切换，不足阈值回弹（类似右滑全屏逻辑）
      .translate({ x: -this.lsPanProgress * 150 })  // 左滑评论区跟随手指偏移（阻力曲线在 progress 中控制）
      .gesture(
        PanGesture({ direction: PanDirection.Left, distance: 20 })
          .onActionStart(() => {
            this.lsHapticPrev_ = 0;
          })
          .onActionUpdate((event: GestureEvent) => {
            let dist = Math.abs(event.offsetX);
            // 满进度距离 220vp（比原来 150 更大 → 阻力更大）
            // 再施加二次阻力曲线（和全屏手势 applyFSResistance 一致）
            let raw = Math.min(1, dist / 220);
            let p = raw * (1.1 - raw * 0.1);
            // 双向阈值穿越震动（和全屏手势一致）：穿越 0.35 时提醒
            if ((this.lsHapticPrev_ < 0.35 && p >= 0.35) ||
              (this.lsHapticPrev_ >= 0.35 && p < 0.35)) {
              this.fireHaptic(18);
            }
            this.lsHapticPrev_ = p;
            this.lsPanProgress = p;
          })
          .onActionEnd(() => {
            if (this.lsPanProgress > 0.35) {
              // 立即清除 translate，由 Flex 弹簧动画接管布局切换
              this.lsPanProgress = 0;
              this.toggleLayoutSwap();
            } else {
              this.getUIContext()?.animateTo({ duration: 300, curve: curves.springMotion(0.3, 0.7) }, () => {
                this.lsPanProgress = 0;
              });
            }
          })
          .onActionCancel(() => {
            this.getUIContext()?.animateTo({ duration: 250, curve: curves.springMotion(0.3, 0.7) }, () => {
              this.lsPanProgress = 0;
            });
            this.fireHaptic(25);  // 触觉反馈：手势被中断取消（增强震动时长）
          })
      )
    }
    .animation({ duration: 350, curve: Curve.FastOutSlowIn })
    .width('100%')
    .height('100%')
    .clip(true)
    .onAreaChange(this.onCA)
    .gesture(
      PanGesture({ direction: PanDirection.Right, distance: 20 })
        .onActionUpdate((event: GestureEvent) => {
          // ⭐ 进度条交互中让位（官方：stopPropagation 只拦 onTouch，拦不住父节点的手势对象）
          if (this.sliderDragging_) return;
          if (this.gm_ === 'seek') return;
          let p = Math.min(1, Math.pow(event.offsetX / 195, 1.2));
          if (p > 0.02) this.updateFSPanProgress(p);
        })
        .onActionEnd(() => {
          if (this.gm_ === 'seek') {
            animateTo({ duration: 260, curve: Curve.EaseOut }, () => { this.fsPanProgress = 0; });
            return;
          }
          if (this.fsPanProgress > 0.3) this.startFSAnimation();
          else animateTo({ duration: 260, curve: Curve.EaseOut }, () => { this.fsPanProgress = 0; });
        })
        .onActionCancel(() => {
          animateTo({ duration: 200, curve: Curve.EaseOut }, () => { this.fsPanProgress = 0; });
          this.fireHaptic(18);
        })
    )
  }

  @Builder
  buildPortraitLayout() {
    Column() {
      Column() {
        Stack() {
          // ⭐ 播放器已移至常驻层：占位槽保持原布局尺寸，由 onAreaChange 把实际矩形同步给常驻层
        }
        .width(this.isLightsOff ? this.loVideoWidth() : this.shrinkSlotW())
        .height(this.isLightsOff ? this.loVideoHeight() : this.shrinkSlotH())
        .borderRadius(this.cardBorderRadius)
        .clip(true)
        .onAreaChange(this.onSlotArea)

        // ⭐ 关灯+横画幅：弹幕平铺到视频下方空白区域（其余情况仍叠在视频上）
        // 同主实例：开关不参与卸载，改用 visibility（Hidden 而非 None，原因见 buildPlayerOverlay）
        if (this.vi.cid > 0 && this.isLightsOffDanmakuOutside() && !this.isShortVideo()) {
          DanmakuView({
            cid: this.vi.cid,
            aid: this.vd?.aid || 0,
            duration: this.dur * 1000,
            currentTime: this.ct * 1000,
            isPlaying: this.play,
            cookie: AppStorage.get<string>('biliCookie') || '',
            canvasWidth: this.cw,
            canvasHeight: this.ch,
            config: $danmakuConfig,
            selfDanmaku: $selfDanmakuList,
          })
            .width('100%')
            .layoutWeight(1)
            .visibility(this.isDanmakuEnabled ? Visibility.Visible : Visibility.Hidden)
        }
      }
      .width('100%')
      .height(this.isLightsOff ? this.ch : undefined)
      .padding(this.isLightsOff
        ? (this.ar < 1 ? { top: 0, left: 0, right: 0 } : { top: this.ch * 0.12, left: 0, right: 0 })
        : { top: this.shrinkVideoTop(), left: this.cardMargin, right: this.cardMargin })
      .alignItems(HorizontalAlign.Center)
      // 关灯时：竖屏视频(ar<1)居中；横屏视频(ar>=1)靠上一点
      .justifyContent(this.isLightsOff ? (this.ar < 1 ? FlexAlign.Center : FlexAlign.Start) : FlexAlign.Start)
      .flexShrink(0)

      Row() {
        SegmentButton({
          options: this.tabOpt,
          selectedIndexes: $tabSelIdx,
          onItemClicked: (idx: number) => { this.switchTab(idx); }
        })
          .width(180)
          .backgroundColor(this.cardTransparentStyleVideo && this.cardStyleVideoSegmentBtn
            ? (this.isDarkMode
              ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
              : `rgba(255,255,255,${this.cardBgOpacity / 100})`)
            : $r('app.color.color_player_surface'))
          .borderRadius(24)
          .clip(true)
          .hitTestBehavior(this.isLightsOff ? HitTestMode.Block : HitTestMode.Default)

        Blank()

        // ⭐ 发弹幕 + 弹幕开关 合并胶囊（与左侧分段按钮对称，间距/样式受卡片风格控制）
        Row({ space: 8 }) {
          // 发弹幕
          Row() {
            Image($r('app.media.danmfas'))
              .width(16)
              .height(16)
              .fillColor($r('app.color.color_player_text'))
              .margin({ right: 4 })
            Text('发弹幕')
              .fontSize(12)
              .fontColor($r('app.color.color_player_text'))
          }
          .onClick(() => {
            try { VibrateUtils.vibrateTime(10); } catch (_) {}
            this.showDanmakuSheet = true;
          })

          // 细分隔线
          Divider()
            .vertical(true)
            .height(18)
            .strokeWidth(1)
            .color('rgba(128,128,128,0.25)')

          // 弹幕开关（开启亮色/关闭次级色）
          Image($r('app.media.chat_bubble_text_square_solid'))
            .width(24)
            .height(24)
            .fillColor(this.isDanmakuEnabled ? $r('app.color.color_player_text') : $r('app.color.color_player_text_secondary'))
            .padding({ left: 2, right: 2 })
            .onClick(() => {
              try { VibrateUtils.vibrateTime(10); } catch (_) {}
              this.toggleDanmaku();
            })
        }
        .height(40)
        .padding({ left: 12, right: 12 })
        .borderRadius(24)
        .clip(true)
        .backgroundColor(this.cardTransparentStyleVideo && this.cardStyleVideoSegmentBtn
          ? (this.isDarkMode
            ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
            : `rgba(255,255,255,${this.cardBgOpacity / 100})`)
          : $r('app.color.color_player_surface'))
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(VerticalAlign.Center)
      .padding({ left: this.cardMargin, right: this.cardMargin })
      .margin({ top: this.cardMargin })
      .flexShrink(0)
      .scale({
        x: 1 - this.fsPanProgress * 0.35,
        y: 1 - this.fsPanProgress * 0.35,
        centerX: '50%',
        centerY: '50%'
      })
      .opacity((1 - Math.pow(this.fsPanProgress, 0.8)) * (this.isLightsOff ? 0 : 1))

      // 内容区域（Stack + translate 实现手指跟随滑动切换）
      Stack() {
        if (this.err && this.err.trim().length > 0) {
          Text(this.err).fontSize(14).fontColor($r('app.color.color_error'))
            .width('100%').textAlign(TextAlign.Center).padding(16)
            .zIndex(10);
        }

        // 详情卡片（始终渲染，通过偏移控制可见性）
        if (this.vd) {
          Column() {
            this.bDetailCard()
          }
          .width('100%')
          .padding({ left: this.cardMargin, right: this.cardMargin, top: this.cardMargin, bottom: this.cardMargin })
          .hitTestBehavior(this.at === 0 || this.isSwiping ? HitTestMode.Default : HitTestMode.None)
          .priorityGesture(
            PanGesture({ direction: PanDirection.Right, distance: 10 })
              .onActionUpdate((event: GestureEvent) => {
                if (this.sliderDragging_) return;
                if (this.gm_ === 'seek') return;
                // ⭐ 竖屏右滑单独增强阻尼：输入幂次 1.5（横屏为 1.2），叠加共享阻力曲线后总阻尼更重
                let p = Math.min(1, Math.pow(event.offsetX / 185, 1.5));
                if (p > 0.02) this.updateFSPanProgress(p);
              })
              .onActionEnd(() => {
                if (this.gm_ === 'seek') {
                  if (this.fsPanProgress !== 0) this.fsPanProgress = 0;
                  return;
                }
                if (this.fsPanProgress > 0.3) {
                  this.startFSAnimation();
                } else {
                  if (this.fsPanProgress !== 0) this.fsPanProgress = 0;
                }
              })
          )
          .translate({ x: this.getDetailOffset(), y: this.detailPullDrop * 120 })
          .scale({
            x: 1 - this.fsPanProgress * 0.08,
            y: 1 - this.fsPanProgress * 0.08,
            centerX: '50%',
            centerY: '20%'
          })
          .opacity((1 - Math.pow(this.fsPanProgress, 0.8)) * (this.isLightsOff ? 0 : 1))
          .hitTestBehavior(this.isLightsOff ? HitTestMode.Block : (this.at === 0 || this.isSwiping ? HitTestMode.Default : HitTestMode.None))
        }

        // 评论区（始终渲染，通过偏移控制可见性）
        Column() {
          this.commentAreaCore(true, false, true)
        }
        .width('100%')
        .height('100%')
        .padding({ left: this.cardMargin, right: this.cardMargin, top: this.cardMargin, bottom: this.cardMargin })
        .hitTestBehavior(this.at === 1 || this.isSwiping ? HitTestMode.Default : HitTestMode.None)
        .translate({ x: this.getCommentOffset() })
        .onTouch((event: TouchEvent) => {
          if (this.at !== 1 || this.fs || this.isLs) return;
          const shrinkEnabled: boolean = AppStorage.get<boolean>('shrinkVideoOnScroll') ?? false;
          if (!shrinkEnabled || this.vidShrink > 0.5) return;
          if (event.type === TouchType.Down) {
            this.commentSwipeStartY = event.touches[0].windowY;
            this.commentSwipeTriggered = false;
          } else if (event.type === TouchType.Move && !this.commentSwipeTriggered) {
            const offYpx = event.touches[0].windowY - this.commentSwipeStartY;
            const offYvp = this.getUIContext().px2vp(offYpx);
            if (offYvp <= -80) {
              this.commentSwipeTriggered = true;
              this.triggerHaptic();
              this.animateVidShrink(1);
            }
          }
        })
      }
      .align(Alignment.Top)
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      // ⭐ 卡片层置于分段栏之下：外侧的下拉关灯提示只会出现在卡片下移露出的缝隙中（不盖在分段栏上）
      .zIndex(-1)
      .scale({
        x: 1 - this.fsPanProgress * 0.2,
        y: 1 - this.fsPanProgress * 0.2,
        centerX: '50%',
        centerY: '50%'
      })
      .opacity((1 - Math.pow(this.fsPanProgress, 0.8)) * (this.isLightsOff ? 0 : 1))
      .hitTestBehavior(this.isLightsOff ? HitTestMode.Block : HitTestMode.Default)
      .gesture(
        PanGesture({ direction: this.at === 0 ? PanDirection.Left : PanDirection.Right, distance: 10 })
          .onActionStart(() => {
            // ⭐ 进度条交互中让位：本条 PanGesture 的 distance 只有 10，是全局最容易抢到触摸的一条。
            //   实测：在进度条上**向左**拖会被它抢走并触发"视频区↔评论/推荐区"面板切换
            //   （向右拖不触发，因为 at===0 时它只认 Left），结果拖动进度条变成了切换面板。
            //   必须在 onActionStart 就返回：只拦 onActionUpdate 不够，因为 Start 已经置了 isSwiping。
            if (this.sliderDragging_) return;
            // 取消上一个手势待执行的清理，避免旧 timeout 中途抢断新手势
            clearTimeout(this.swipeTimer_);
            this.swipeTimer_ = -1;
            this.isSwiping = true;
            this.swipeProgress = 0;
          })
          .onActionUpdate((event: GestureEvent) => {
            if (this.sliderDragging_) return;
            if (!this.isSwiping) return;
            // 线性跟手（类华为控制栏）：1:1 跟随手指，无非线性摩擦
            const raw = event.offsetX / this.getLayoutWidth();
            const absRaw = Math.min(1, Math.abs(raw));
            const linear = Math.pow(absRaw, 1.0) * Math.sign(raw);
            if (this.at === 0) {
              this.swipeProgress = Math.max(-1, Math.min(0, linear));
            } else {
              this.swipeProgress = Math.max(0, Math.min(1, linear));
            }
          })
          .onActionEnd(() => {
            if (!this.isSwiping) return;
            const adx = Math.abs(this.swipeProgress);
            if (adx > 0.12) {
              this.triggerHaptic();
              const targetTab = this.at === 0 ? 1 : 0;
              const oldProgress = this.swipeProgress;
              // tabSelIdx先一步更新，让SegmentButton用自己的内置动画驱动指示器过渡
              this.tabSelIdx = [targetTab];
              // ⭐ 立即更新 at：让 PanGesture({ direction: at===0 ? Left : Right }) 在下次 build 中即时生效
              this.at = targetTab;
              // ⭐ 同步补偿 swipeProgress，使视觉位置不跳变：
              //    at=0→1：旧视觉 0+oldP*100，新视觉 -100+(oldP+1)*100 = 同位置 ✓
              //    at=1→0：旧视觉 -100+oldP*100，新视觉 0+(oldP-1)*100 = 同位置 ✓
              this.swipeProgress = oldProgress + (targetTab === 0 ? -1 : 1);
              if (this.da) {
                this.swipeProgress = 0;
                this.isSwiping = false;
              } else {
                this.getUIContext()?.animateTo({ duration: 450, curve: curves.springMotion(0.25, 0.88) }, () => {
                  this.swipeProgress = 0;
                });
                this.swipeTimer_ = setTimeout(() => {
                  this.isSwiping = false;
                  this.swipeProgress = 0;
                  if (targetTab !== 1 && this.vidShrink > 0) {
                    this.animateVidShrink(0);
                  }
                }, 450);
              }
            } else {
              // ⭐ 弹簧回弹：带弹性阻尼感，不触发切换
              if (this.da) {
                this.swipeProgress = 0;
                this.isSwiping = false;
              } else {
                this.getUIContext()?.animateTo({ duration: 400, curve: curves.springMotion(0.25, 0.88) }, () => {
                  this.swipeProgress = 0;
                });
                this.swipeTimer_ = setTimeout(() => {
                  this.isSwiping = false;
                }, 400);
              }
            }
          })
      )
    }
    .width('100%').height('100%')
    .onAreaChange(this.onCA)
  }
  @Builder
  buildLandscapeVertical() {
    Flex({ direction: this.isLayoutSwapped ? FlexDirection.RowReverse : FlexDirection.Row }) {
      // ========== 左侧按钮区域（固定宽度，竖排互动按钮） ==========
      Column() {
        // ⭐ 左上角返回按钮
        Column() {
          Image($r('app.media.return_453'))
            .width(34).height(34)
            .fillColor(this.backBtnPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
            .scale({ x: this.backBtnScale, y: this.backBtnScale })
            .animation({ duration: 100, curve: Curve.EaseOut })
        }
        .width(52).height(52).borderRadius(26)
        .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 16, bottom: 10 })
        .onClick(() => {
          this.backBtnScale = 0.9;
          this.backBtnPressed = true;
          setTimeout(() => { this.backBtnScale = 1; this.backBtnPressed = false; }, 150);
          this.triggerHaptic();
          this.goBack();
        })
        Scroll() {
          Column() {
            // ⭐ 布局切换按钮
            if (this.isLs) {
              Column() {
                Image($r('app.media.ic_gallery_collage'))
                  .width(20).height(20)
                  .fillColor(this.layoutSwapPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                  .scale({ x: this.layoutSwapScale, y: this.layoutSwapScale })
                  .animation({ duration: 100, curve: Curve.EaseOut })
                Text('切换').fontSize(9)
                  .fontColor(this.layoutSwapPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                  .margin({ top: 2 })
              }
              .width(52).height(52).borderRadius(26)
              .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .margin({ bottom: 10 })
              .onClick(() => this.toggleLayoutSwap())
            }

            // ⭐ 旋转模式切换按钮
            Column() {
              Image(this.getRotationIcon())
                .width(20).height(20)
                .fillColor(this.rotationPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                .scale({ x: this.rotationScale, y: this.rotationScale })
                .animation({ duration: 100, curve: Curve.EaseOut })
              Text(this.getRotationText()).fontSize(9)
                .fontColor(this.rotationPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                .margin({ top: 2 })
            }
            .width(52).height(52).borderRadius(26)
            .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin({ bottom: 10 })
            .onClick(() => this.toggleRotationMode())

            // 点赞、投币、收藏（垂直胶囊）
            Column() {
              // 点赞
              Column() {
                Image($r('app.media.ic_public_thumbsup_filled'))
                  .width(22).height(22)
                  .fillColor(this.isLiked ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                  .scale({ x: this.likeScale, y: this.likeScale })
                  .animation({ duration: 100, curve: Curve.EaseOut })
                Text(`${this.fmtN(this.likeCount)}`).fontSize(9)
                  .fontColor(this.isLiked ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                  .margin({ top: 2 })
              }
              .padding({ top: 10, bottom: 10 })
              .width('100%')
              .onClick(() => this.toggleLike())
              .gesture(
                LongPressGesture({ repeat: false, duration: 500 })
                  .onAction(() => this.tripleAction())
              )

              Divider().width('60%').color($r('app.color.color_player_text_secondary')).opacity(0.3)

              // 投币
              Column() {
                Image($r('app.media.ic_public_highlight_filled'))
                  .width(22).height(22)
                  .fillColor(this.isCoined ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                  .scale({ x: this.coinScale, y: this.coinScale })
                  .animation({ duration: 100, curve: Curve.EaseOut })
                Text(`${this.fmtN(this.coinCount)}`).fontSize(9)
                  .fontColor(this.isCoined ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                  .margin({ top: 2 })
              }
              .padding({ top: 10, bottom: 10 })
              .width('100%')
              .onClick(() => this.toggleCoin(1))
              .gesture(
                LongPressGesture({ repeat: false, duration: 500 })
                  .onAction(() => this.toggleCoin(2))
              )

              Divider().width('60%').color($r('app.color.color_player_text_secondary')).opacity(0.3)

              // 收藏
              Column() {
                Image($r('app.media.heart_square_stack_fill'))
                  .width(22).height(22)
                  .fillColor(this.isFavorited ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                  .scale({ x: this.favoriteScale, y: this.favoriteScale })
                  .animation({ duration: 100, curve: Curve.EaseOut })
                Text(`${this.fmtN(this.favoriteCount)}`).fontSize(9)
                  .fontColor(this.isFavorited ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                  .margin({ top: 2 })
              }
              .padding({ top: 10, bottom: 10 })
              .width('100%')
              .onClick(() => this.toggleFavorite())
            }
            .width(52)
            .backgroundColor(this.getComponentBg(this.cardStyleVideoInteractBtns))
            .borderRadius(30)
            .alignItems(HorizontalAlign.Center)
            .margin({ bottom: 10 })

            // 深色/浅色模式切换按钮
            Column() {
              Image(this.isDarkMode ? $r('app.media.ic_settings_darkmode') : $r('app.media.sun_min'))
                .width(20).height(20)
                .fillColor(this.darkModePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                .scale({ x: this.darkModeScale, y: this.darkModeScale })
                .animation({ duration: 100, curve: Curve.EaseOut })
              Text(this.isDarkMode ? '深色' : '浅色').fontSize(9)
                .fontColor(this.darkModePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                .margin({ top: 2 })
            }
            .width(52).height(52).borderRadius(26)
            .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin({ bottom: 10 })
            .onClick(() => this.toggleDarkMode())

            // 最小化到悬浮按钮
            Column() {
              Image($r('app.media.media_center'))
                .width(20).height(20)
                .fillColor(this.minimizePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                .scale({ x: this.minimizeScale, y: this.minimizeScale })
                .animation({ duration: 100, curve: Curve.EaseOut })
              Text('浮窗').fontSize(9)
                .fontColor(this.minimizePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                .margin({ top: 2 })
            }
            .width(52).height(52).borderRadius(26)
            .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin({ bottom: 10 })
            .onClick(() => this.minimizeToFloating())

            // 选集按钮
            if (this.vd && this.vd.pages && this.vd.pages.length > 1) {
              Column() {
                Image($r('app.media.externaldrive_fill_3'))
                  .width(20).height(20)
                  .fillColor(this.episodePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                  .scale({ x: this.episodeScale, y: this.episodeScale })
                  .animation({ duration: 100, curve: Curve.EaseOut })
                Text('选集').fontSize(9)
                  .fontColor(this.episodePressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                  .margin({ top: 2 })
              }
              .width(52).height(52).borderRadius(26)
              .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .onClick(() => {
                this.episodeScale = 0.9;
                this.episodePressed = true;
                setTimeout(() => { this.episodeScale = 1; this.episodePressed = false; }, 150);
                this.triggerHaptic();
                this.showEpisodeSheet = true;
              })
            }
            // ⭐ 合集按钮（选集右侧，仅UGC合集显示）
            if (this.vd?.ugc_season?.id && this.vd.ugc_season.sections && this.vd.ugc_season.sections.length > 0) {
              Column() {
                Image($r('app.media.heji'))
                  .width(20).height(20)
                  .fillColor(this.seasonPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                  .scale({ x: this.seasonScale, y: this.seasonScale })
                  .animation({ duration: 100, curve: Curve.EaseOut })
                Text('合集').fontSize(9)
                  .fontColor(this.seasonPressed ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary'))
                  .margin({ top: 2 })
              }
              .width(52).height(52).borderRadius(26)
              .backgroundColor(this.getComponentBg(this.cardStyleVideoNavBtns))
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .onClick(() => {
                this.seasonScale = 0.9;
                this.seasonPressed = true;
                setTimeout(() => { this.seasonScale = 1; this.seasonPressed = false; }, 150);
                this.triggerHaptic();
                this.showSeasonSheet = true;
              })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 16, bottom: 16 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width(80)
      .height('100%')
      .flexShrink(0)
      // ⭐ 动画绑定：缩放 + 透明度随 fsPanProgress 变化
      .scale({
        x: 1 - this.fsPanProgress * 0.3,
        y: 1 - this.fsPanProgress * 0.3,
        centerX: '50%',
        centerY: '50%'
      })
      .opacity((1 - Math.pow(this.fsPanProgress, 1.2)) * (this.isLightsOff ? 0 : 1))
      .hitTestBehavior(this.isLightsOff ? HitTestMode.Block : HitTestMode.Default)

      // ========== 播放器区域（9:16竖屏视频） ==========
      Column() {
        Stack() {
          // ⭐ 播放器已移至常驻层：占位槽保持原布局尺寸
        }
        .width(this.lsvw)
        .height(this.lsvh)
        .clip(true)
        .borderRadius(this.cardBorderRadius)
        .onAreaChange(this.onSlotArea)
        .margin({ top: this.cardMargin, bottom: this.cardMargin })
      }
      .margin({ left: this.cardMargin })
      .flexShrink(0)

      // ========== 右侧内容区域（详情卡片 + 评论区） ==========
      // ⭐ 关键修复：添加 .scale 和 .opacity 动画，与 fsPanProgress 绑定
      Stack() {
        Column() {
        // 详情卡片：正常模式显示全部，缩小模式只显示标题
        Column() {
          if (this.detailShrinkVP > 0.5) {
            // 缩小模式：只显示标题 + 展开提示
            Row() {
              Text(this.vd?.title || this.vi.title)
                .fontSize(16)
                .fontColor($r('app.color.color_player_text'))
                .fontWeight(FontWeight.Bold)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Image($r('app.media.chevron_right'))
                .width(14).height(14)
                .fillColor($r('app.color.color_player_text_secondary'))
                .margin({ left: 8 })
            }
            .width('100%')
            .height('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .onClick(() => {
              if (this.da) {
                this.detailShrinkVP = 0;
              } else {
                animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
                  this.detailShrinkVP = 0;
                });
              }
            })
          } else {
            this.bDetailCard()
          }
        }
        .width('100%')
        .height(this.detailShrinkVP > 0.5 ? 56 : undefined)
        .layoutWeight(this.detailShrinkVP > 0.5 ? undefined : 35)
        .margin({ top: this.cardMargin })
        .backgroundColor(this.getCardContainerBg(this.cardStyleVideoDetail))
        .border(this.getCardContainerBorder(this.cardStyleVideoDetail))
        .borderRadius(this.cardBorderRadius)
        // ⭐ 不裁切子内容：让外侧的下拉关灯提示可以悬在卡片上缘上方（圆角由内层 borderRadius+clip 处理）
        .opacity(this.isLightsOff ? 0 : 1)
        // ⭐ 整卡下拉关灯：卡片可见本体（背景+边框）跟随手指下滑
        .translate({ y: this.detailPullDrop * 120 })

        Column() {
          if (true) {
            // ⭐ List 真懒加载（Scroll+Column 中 LazyForEach 不生效，全量挂载导致转场抖动）
            List({ scroller: this.commentScroller }) {
              ListItem() { Column() { this.commentSortBar() }.width('100%').padding({ left: 12, right: 12 }) }
              if (this.ldc && this.commentDataSource.totalCount() === 0) {
                ListItem() {
                  Column() { LoadingProgress().width(20).height(20).color(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink')); }
                  .width('100%').height(80).justifyContent(FlexAlign.Center)
                }
              } else if (this.commentDataSource.totalCount() > 0) {
                LazyForEach(this.commentDataSource, (c: ObservableComment, i: number) => {
                  ListItem() {
                    Column() {
                      CommentItemComponent({
                        picBoxW: this.commentPicBoxW(), picBoxH: this.commentPicBoxH(),
                        comment: c,
                        isLast: i === this.commentDataSource.totalCount() - 1,
                        videoDetail: this.vd,
                        isExpanded: this.expandedCommentIds.has(c.rpid),
                        repliesVersion: this.repliesVersion,
                        onExpandComment: (comment: ObservableComment) => {
                          this.expandCommentAndLoadFirstPage(comment);
                        },
                        onCollapseComment: (rpid: number) => { this._doRemoveExpandedComment(rpid); },
                        onLoadMoreReplies: (comment: ObservableComment) => {
                          this.loadMoreReplies(comment);
                        },
                        onReplyTap: (root: number, parent: number, targetName: string) => {
                          this.openCommentSheet('reply', root, parent, targetName);
                        }
                      })
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12 })
                  }
                }, (c: ObservableComment, i: number) => c.rpid > 0 ? c.rpid.toString() : 'empty_' + i)
                if (this.hm && this.expandedCommentIds.size === 0) {
                  ListItem() {
                    Column() {
                      Row() {
                        if (this.ldc) {
                          LoadingProgress().width(16).height(16).color(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'));
                          Text('加载中...').fontSize(12).fontColor($r('app.color.color_player_text_secondary')).margin({ left: 6 });
                        } else {
                          Text('上拉加载更多').fontSize(12).fontColor($r('app.color.color_player_text_secondary'));
                        }
                      }
                      .width('100%').justifyContent(FlexAlign.Center)
                      .padding({ top: 12, bottom: 12 })
                    }
                    .width('100%').padding({ left: 12, right: 12 })
                  }
                }
              } else if (this.rateLimited) {
                ListItem() {
                  Column() {
                    Text('评论被限流，请等待片刻')
                      .fontSize(14)
                      .fontColor($r('app.color.color_player_text_secondary'))
                      .margin({ bottom: 16 });
                    Button() {
                      Row({ space: 4 }) {
                        Image($r('app.media.arrow_clockwise'))
                          .width(14)
                          .height(14)
                          .fillColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                        Text('点击重试')
                          .fontSize(12)
                          .fontColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                      }
                      .alignItems(VerticalAlign.Center)
                    }
                    .backgroundColor('rgba(251, 114, 153, 0.15)')
                    .borderRadius(999)
                    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                    .onClick(() => {
                      if (this.vd) {
                        this.commentCursor = 0;
                        this.loadC(this.vd.aid);
                      }
                    })
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.Center)
                  .alignItems(HorizontalAlign.Center)
                  .padding({ top: 40, bottom: 40, left: 12, right: 12 })
                }
              } else {
                ListItem() {
                  Column() {
                    Text('暂无评论').fontSize(14).fontColor($r('app.color.color_player_text_secondary'))
                    Button('重新加载')
                      .fontSize(12)
                      .fontColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                      .backgroundColor('transparent')
                      .border({ width: 1, color: this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'), radius: 4 })
                      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                      .margin({ top: 12 })
                      .onClick(() => {
                        if (this.vd) {
                          this.commentCursor = 0;
                          this.loadC(this.vd.aid);
                        }
                      })
                  }
                  .width('100%')
                  .justifyContent(FlexAlign.Center)
                  .alignItems(HorizontalAlign.Center)
                  .margin({ top: 40 })
                  .padding({ left: 12, right: 12 })
                }
              }
              ListItem() { Column().width('100%').height(0) }
            }
            .listDirection(Axis.Vertical)
            .width('100%')
            .height('100%')
            .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)

            .visibility(this.commentAreaVis())
            .opacity(this.commentFade)
            .onWillScroll((xOffset: number, yOffset: number) => {
              if (yOffset > 15 && this.detailShrinkVP < 0.5) {
                if (this.da) {
                  this.detailShrinkVP = 1;
                } else {
                  animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
                    this.detailShrinkVP = 1;
                  });
                }
              }
            })
            .onScrollStop(() => {
              if (this.detailShrinkVP > 0.5) {
                const finalY = this.commentScroller.currentOffset().yOffset;
                if (finalY <= 5) {
                  if (this.da) {
                    this.detailShrinkVP = 0;
                  } else {
                    animateTo({ duration: 300, curve: Curve.EaseOut }, () => {
                      this.detailShrinkVP = 0;
                    });
                  }
                }
              }
            })
            .onReachEnd(() => {
              if (this.hm && this.expandedCommentIds.size === 0 && !this.ldc && this.commentDataSource.totalCount() > 0) {
                this.loadMC();
              }
            })
          }
        }
        .width('100%')
        .layoutWeight(65)
        .backgroundColor(this.getCardContainerBg(this.cardStyleVideoCommentSection))
        .border(this.getCardContainerBorder(this.cardStyleVideoCommentSection))
        .borderRadius(this.cardBorderRadius)
        .clip(true)
        .margin({ top: this.cardMargin, bottom: this.cardMargin })

        .opacity(this.isLightsOff ? 0 : 1)
        .animation({ duration: 300 })
        // ⭐ 左滑评论区 → 切换标准/镜像布局（和横屏非全屏手势一致）
        .gesture(
          PanGesture({ direction: PanDirection.Left, distance: 20 })
            .onActionStart(() => {
              this.lsHapticPrev_ = 0;
            })
            .onActionUpdate((event: GestureEvent) => {
              let dist = Math.abs(event.offsetX);
              let raw = Math.min(1, dist / 220);
              let p = raw * (1.1 - raw * 0.1);
              if ((this.lsHapticPrev_ < 0.35 && p >= 0.35) ||
                (this.lsHapticPrev_ >= 0.35 && p < 0.35)) {
                this.fireHaptic(18);
              }
              this.lsHapticPrev_ = p;
              this.lsPanProgress = p;
            })
            .onActionEnd(() => {
              if (this.lsPanProgress > 0.35) {
                // 立即清除 translate，由 Flex 弹簧动画接管布局切换
                this.lsPanProgress = 0;
                this.toggleLayoutSwap();
              } else {
                this.getUIContext()?.animateTo({ duration: 300, curve: curves.springMotion(0.3, 0.7) }, () => {
                  this.lsPanProgress = 0;
                });
              }
            })
            .onActionCancel(() => {
              this.getUIContext()?.animateTo({ duration: 250, curve: curves.springMotion(0.3, 0.7) }, () => {
                this.lsPanProgress = 0;
              });
              this.fireHaptic(25);
            })
        )
        }
        .width('100%')
        .height('100%')

        // ⭐ 关灯+竖屏横看：弹幕平铺到右侧空白区（Stack 覆盖层，画布尺寸随容器，不再用 position）
        // 同主实例：开关不参与卸载，改用 visibility（Hidden 而非 None，原因见 buildPlayerOverlay）
        if (this.isLightsOffDanmakuRight() && this.vi.cid > 0 && !this.isShortVideo()) {
          DanmakuView({
            cid: this.vi.cid,
            aid: this.vd?.aid || 0,
            duration: this.dur * 1000,
            currentTime: this.ct * 1000,
            isPlaying: this.play,
            cookie: AppStorage.get<string>('biliCookie') || '',
            canvasWidth: this.cw,
            canvasHeight: this.ch,
            config: $danmakuConfig,
            selfDanmaku: $selfDanmakuList,
          })
            .width('100%')
            .height('100%')
            .visibility(this.isDanmakuEnabled ? Visibility.Visible : Visibility.Hidden)
        }
      }
      .layoutWeight(1)
      .padding({ left: this.cardMargin, right: this.cardMargin })
      // ⭐ 详情卡片和评论区整体随左滑手势偏移
      .translate({ x: -this.lsPanProgress * 150 })
      // ⭐ 动画绑定：缩放 + 透明度随 fsPanProgress 变化
      .scale({
        x: 1 - this.fsPanProgress * 0.1,
        y: 1 - this.fsPanProgress * 0.1,
        centerX: '50%',
        centerY: '50%'
      })
      .opacity(1 - Math.pow(this.fsPanProgress, 0.8))
      .hitTestBehavior(this.isLightsOff ? HitTestMode.Block : HitTestMode.Default)
    }
    .width('100%')
    .height('100%')
    .onAreaChange(this.onCA)
    .parallelGesture(
      PanGesture({ direction: PanDirection.Right, distance: 20 })
        .onActionUpdate((event: GestureEvent) => {
          // ⭐ 进度条交互中让位（官方：stopPropagation 只拦 onTouch，拦不住父节点的手势对象）
          if (this.sliderDragging_) return;
          if (this.gm_ === 'seek') return;
          let p = Math.min(1, Math.pow(event.offsetX / 195, 1.2));
          if (p > 0.02) this.updateFSPanProgress(p);
        })
        .onActionEnd(() => {
          if (this.gm_ === 'seek') {
            animateTo({ duration: 260, curve: Curve.EaseOut }, () => { this.fsPanProgress = 0; });
            return;
          }
          if (this.fsPanProgress > 0.3) this.startFSAnimation();
          else animateTo({ duration: 260, curve: Curve.EaseOut }, () => { this.fsPanProgress = 0; });
        })
    )
  }

  // ⭐ 横屏评论区（直板机布局开关共用）—— List 真懒加载（Scroll+Column 中 LazyForEach 不生效）
  @Builder
  buildLandscapeCommentsSection() {
    List({ scroller: this.commentScroller }) {
      ListItem() { Column() { this.commentSortBar() }.width('100%').padding({ left: 12, right: 12 }) }
      if (this.commentDataSource.totalCount() > 0) {
        LazyForEach(this.commentDataSource, (c: ObservableComment, i: number) => {
          ListItem() {
            Column() {
              CommentItemComponent({
                picBoxW: this.commentPicBoxW(), picBoxH: this.commentPicBoxH(),
                comment: c,
                isLast: i === this.commentDataSource.totalCount() - 1,
                videoDetail: this.vd,
                isExpanded: this.expandedCommentIds.has(c.rpid),
                repliesVersion: this.repliesVersion,
                onExpandComment: (comment: ObservableComment) => {
                  this.expandCommentAndLoadFirstPage(comment);
                },
                onCollapseComment: (rpid: number) => { this._doRemoveExpandedComment(rpid); },
                onLoadMoreReplies: (comment: ObservableComment) => {
                  this.loadMoreReplies(comment);
                },
                onReplyTap: (root: number, parent: number, targetName: string) => {
                  this.openCommentSheet('reply', root, parent, targetName);
                }
              })
            }
            .width('100%')
            .padding({ left: 12, right: 12 })
          }
        }, (c: ObservableComment, i: number) => c.rpid > 0 ? c.rpid.toString() : 'empty_' + i)
        if (this.hm) {
          ListItem() {
            Column() {
              Row() {
                if (this.ldc) {
                  LoadingProgress().width(16).height(16).color(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'));
                  Text('加载中...').fontSize(12).fontColor($r('app.color.color_player_text_secondary')).margin({ left: 6 });
                } else {
                  Text('上拉加载更多').fontSize(12).fontColor($r('app.color.color_player_text_secondary'));
                }
              }
              .width('100%').justifyContent(FlexAlign.Center)
              .padding({ top: 12, bottom: 12 })
            }
            .width('100%').padding({ left: 12, right: 12 })
          }
        }
      } else if (this.ldc) {
        ListItem() {
          Column() { LoadingProgress().width(20).height(20).color(('app.color.color_bilibili_pink')); }
          .width('100%').height(80).justifyContent(FlexAlign.Center)
        }
      } else if (this.rateLimited) {
        ListItem() {
          Column() {
            Text('评论被限流，请等待片刻')
              .fontSize(13)
              .fontColor(('app.color.color_player_text_secondary'))
              .margin({ bottom: 16 });
            Button() {
              Row({ space: 4 }) {
                Image($r('app.media.arrow_clockwise'))
                  .width(14)
                  .height(14)
                  .fillColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                Text('点击重试')
                  .fontSize(12)
                  .fontColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
              }
              .alignItems(VerticalAlign.Center)
            }
            .backgroundColor('rgba(251, 114, 153, 0.15)')
            .borderRadius(999)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .onClick(() => {
              if (this.vd) {
                this.commentCursor = 0;
                this.loadC(this.vd.aid);
              }
            })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 40, bottom: 40, left: 12, right: 12 })
        }
      } else {
        ListItem() {
          Column() {
            Text('暂无评论').fontSize(13).fontColor(('app.color.color_player_text_secondary'))
            Button('重新加载')
              .fontSize(12)
              .fontColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
              .backgroundColor('transparent')
              .border({ width: 1, color: this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'), radius: 4 })
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin({ top: 12 })
              .onClick(() => {
                if (this.vd) {
                  this.commentCursor = 0;
                  this.loadC(this.vd.aid);
                }
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .margin({ top: 40 })
          .padding({ left: 12, right: 12 })
        }
      }
      ListItem() { Column().width('100%').height(0) }
    }
    .listDirection(Axis.Vertical)
    .layoutWeight(1)
    .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)

    .onReachEnd(() => {
      if (this.hm && !this.ldc && this.commentDataSource.totalCount() > 0) {
        this.loadMC();
      }
    })
  }

  // ⭐ 评论排序按钮组（最热 / 最新）
  @Builder
  commentSheetContent() {
    Column() {
      CommentInputBar({
        ctrl: this.cmSheetEmoteCtrl,
        placeholder: this.commentSheetMode === 'reply' ? `回复 @${this.replyTargetName}：` : '发一条友善的评论',
        showImageButton: this.commentSheetMode !== 'reply',
        onSend: (content: string, pictures: CommentImageDraft[]) => {
          return this.handleCommentSend(content, pictures);
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .backgroundColor(this.sheetRootBg(this.isDarkMode ? '#242424' : '#FFFFFF'))
  }

  /** 发送评论/回复：图片草稿先逐张上传图床，随文本一起提交；成功返回 true（父层关弹层） */
  private async handleCommentSend(content: string, pictures: CommentImageDraft[]): Promise<boolean> {
    const aid = this.vd?.aid || 0;
    if (!aid) {
      this.getUIContext().getPromptAction().showToast({ message: '评论失败：缺少视频ID' });
      return false;
    }
    // 图片先逐张上传到图床，得到 URL/宽高后再随评论提交
    let picturesJson = '';
    if (pictures.length > 0) {
      const imgs: string[] = [];
      for (const p of pictures) {
        const up = await uploadCommentImage(p.path, p.mime, p.ext);
        if (!up || !up.url) {
          this.getUIContext().getPromptAction().showToast({ message: '图片上传失败' });
          return false;
        }
        imgs.push(JSON.stringify({ img_src: up.url, img_width: up.width, img_height: up.height }));
      }
      picturesJson = '[' + imgs.join(',') + ']';
    }
    const res = await addVideoComment(aid, content, this.replyRoot, this.replyParent, picturesJson);
    if (!res.ok) {
      this.getUIContext().getPromptAction().showToast({ message: res.message || '发表失败，请稍后再试', duration: 2000 });
      return false;
    }
    this.getUIContext().getPromptAction().showToast({ message: this.commentSheetMode === 'reply' ? '回复成功' : '评论成功' });
    this.commentSheetVisible = false;
    this.replyRoot = 0;
    this.replyParent = 0;
    this.replyTargetName = '';
    // ⭐ 游标归零后重载第一页，保持当前排序（最热/最新）
    this.commentCursor = 0;
    this.loadC(aid);
    return true;
  }

  /** 打开评论输入弹层（写评论或回复），未登录先拦截 */
  private openCommentSheet(mode: string, root: number, parent: number, targetName: string): void {
    if (!this.biliCookie.includes('SESSDATA')) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录' });
      return;
    }
    this.commentSheetMode = mode;
    this.replyRoot = root;
    this.replyParent = parent;
    this.replyTargetName = targetName;
    this.commentSheetVisible = true;
  }

  /** ⭐ 评论区核心（排序栏+List+LazyForEach+加载更多/空态/限态）：竖屏分支与全屏评论浮层共用；
   *  hideOnTransition=true（竖屏）：转场期移出布局+渐显；浮层传 false（显隐由浮层自身条件挂载控制） */
  @Builder
  commentAreaCore(hideOnTransition: boolean, useFsScroller: boolean, cardShell: boolean) {
    Column() {
      List({ scroller: useFsScroller ? this.fsCommentScroller : this.commentScroller }) {
        ListItem() { Column() { this.commentSortBar() }.width('100%').padding({ left: 12, right: 12 }) }
        if (this.commentDataSource.totalCount() > 0) {
          LazyForEach(this.commentDataSource, (c: ObservableComment, i: number) => {
            ListItem() {
              Column() {
                CommentItemComponent({
                  picBoxW: this.commentPicBoxW(), picBoxH: this.commentPicBoxH(),
                  comment: c,
                  isLast: i === this.commentDataSource.totalCount() - 1,
                  videoDetail: this.vd,
                  isExpanded: this.expandedCommentIds.has(c.rpid),
                  repliesVersion: this.repliesVersion,
                  onExpandComment: (comment: ObservableComment) => {
                    this.expandCommentAndLoadFirstPage(comment);
                  },
                  onCollapseComment: (rpid: number) => { this._doRemoveExpandedComment(rpid); },
                  onLoadMoreReplies: (comment: ObservableComment) => {
                    this.loadMoreReplies(comment);
                  },
                  onReplyTap: (root: number, parent: number, targetName: string) => {
                    this.openCommentSheet('reply', root, parent, targetName);
                  }
                })
              }
              .width('100%')
              .padding({ left: 12, right: 12 })
            }
          }, (c: ObservableComment, i: number) => c.rpid > 0 ? c.rpid.toString() : 'empty_' + i)
          if (this.hm) {
            ListItem() {
              Column() {
                Row() {
                  if (this.ldc) {
                    LoadingProgress().width(16).height(16).color(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'));
                    Text('加载中...').fontSize(12).fontColor($r('app.color.color_player_text_secondary')).margin({ left: 6 });
                  } else {
                    Text('上拉加载更多').fontSize(12).fontColor($r('app.color.color_player_text_secondary'));
                  }
                }
                .width('100%').justifyContent(FlexAlign.Center)
                .padding({ top: 12, bottom: 12 })
              }
              .width('100%').padding({ left: 12, right: 12 })
            }
          }
        } else if (this.ldc) {
          ListItem() {
            Column() { LoadingProgress().width(20).height(20).color(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink')); }
            .width('100%').height(80).justifyContent(FlexAlign.Center)
          }
        } else if (this.rateLimited) {
          ListItem() {
            Column() {
              Text('评论被限流，请等待片刻')
                .fontSize(13)
                .fontColor($r('app.color.color_player_text_secondary'))
                .margin({ bottom: 16 });
              Button() {
                Row({ space: 4 }) {
                  Image($r('app.media.arrow_clockwise'))
                    .width(14)
                    .height(14)
                    .fillColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                  Text('点击重试')
                    .fontSize(12)
                    .fontColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                }
                .alignItems(VerticalAlign.Center)
              }
              .backgroundColor('rgba(251, 114, 153, 0.15)')
              .borderRadius(999)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .onClick(() => {
                if (this.vd) {
                  this.commentCursor = 0;
                  this.loadC(this.vd.aid);
                }
              })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 40, bottom: 40, left: 12, right: 12 })
          }
        } else {
          ListItem() {
            Column() {
              Text('暂无评论').fontSize(13).fontColor($r('app.color.color_player_text_secondary'))
              Button('重新加载')
                .fontSize(12)
                .fontColor(this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                .backgroundColor('transparent')
                .border({ width: 1, color: this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'), radius: 4 })
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .margin({ top: 12 })
                .onClick(() => {
                  if (this.vd) {
                    this.commentCursor = 0;
                    this.loadC(this.vd.aid);
                  }
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 40 })
            .padding({ left: 12, right: 12 })
          }
        }
        ListItem() { Column().width('100%').height(0) }
      }
      .listDirection(Axis.Vertical)
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)

      .visibility(hideOnTransition ? this.commentAreaVis() : Visibility.Visible)
      .opacity(hideOnTransition ? this.commentFade : 1)
      .onWillScroll((xOffset: number, yOffset: number) => {
        if (this.at === 1 && !this.fs && !this.isLs) {
          const shrinkEnabled: boolean = AppStorage.get<boolean>('shrinkVideoOnScroll') ?? false;
          if (shrinkEnabled && yOffset > 15 && this.vidShrink < 0.5) {
            this.triggerHaptic();
            this.animateVidShrink(1);
          }
        }
      })
      .onReachEnd(() => {
        if (this.hm && !this.ldc && this.commentDataSource.totalCount() > 0) {
          this.loadMC();
        }
      })
    }
    .width('100%')
    .height('100%')
    // cardShell=true（竖屏页）：评论卡片外壳（背景/边框/圆角/clip）；浮层传 false——裁剪交给面板自身，内容可滚到面板边缘
    .backgroundColor(cardShell ? this.getCardContainerBg(this.cardStyleVideoCommentSection) : Color.Transparent)
    .border(cardShell ? this.getCardContainerBorder(this.cardStyleVideoCommentSection) : { width: 0 })
    .borderRadius(cardShell ? this.cardBorderRadius : 0)
    .clip(cardShell)
    .backdropBlur(useFsScroller ? 25 : 0)
  }

  /** ⭐ 全屏评论浮层：直接显示评论卡片（commentAreaCore 自带卡片外壳），横向右侧竖条/竖向底部横条；
   *  简单条件显隐，不做布局属性动画（避免与 fsPanProgress 全屏动画叠加掉帧） */
  @Builder
  fsCommentPanel() {
    Stack() {
      // 关闭点击区 — 透明占满，点击空白关闭
      Column()
        .width('100%')
        .height('100%')
        .onClick(() => { this.cp = false; this.ip = false; this.cv = true; if (this.cv) this.resetCT(); });

      // 评论卡片（commentAreaCore 自带卡片背景+圆角+clip）
      Column() {
        this.commentAreaCore(false, true, true)
      }
      .width(this.cw > this.ch ? this.cw / 3 : '100%')
      .height(this.cw > this.ch ? '100%' : this.ch / 3)
      .position(this.cw > this.ch
        ? (this.mirrorPopup() ? { left: 0, top: 0 } : { right: 0, top: 0 })
        : { left: 0, bottom: 0 })
    }
    .width('100%')
    .height('100%')
    .transition(
      this.cw > this.ch
        ? TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
            .combine(TransitionEffect.translate({ x: this.mirrorPopup() ? '-100%' : '100%' }).animation({ duration: 300, curve: Curve.EaseInOut }))
        : TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
            .combine(TransitionEffect.translate({ y: '100%' }).animation({ duration: 300, curve: Curve.EaseInOut }))
    )
  }


  @Builder
  commentSortBar() {
    Row() {
      SegmentButton({
        options: this.commentSortOpt,
        selectedIndexes: $commentSortSelIdx,
        onItemClicked: (idx: number) => {
          this.switchCommentSort(idx === 0 ? 2 : 1);
        }
      })
        .width(160)
        .backgroundColor(this.cardTransparentStyleVideo && this.cardStyleVideoSegmentBtn
          ? (this.isDarkMode
            ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
            : `rgba(255,255,255,${this.cardBgOpacity / 100})`)
          : $r('app.color.color_player_surface'))
        .borderRadius(24)
        .clip(true)
        // ⭐ 写评论入口（message_199.svg，圆形底衬）：打开评论输入弹层
        Column() {
          Image($r('app.media.message_199'))
            .width(20)
            .height(20)
            .fillColor(this.customThemeColor)
        }
        .width(36)
        .height(36)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .borderRadius(18)
        .backgroundColor(this.cardTransparentStyleVideo && this.cardStyleVideoSegmentBtn
          ? (this.isDarkMode
            ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
            : `rgba(255,255,255,${this.cardBgOpacity / 100})`)
          : $r('app.color.color_player_surface'))
        .margin({ left: 14 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.88 })
        .onClick(() => {
          this.triggerHaptic();
          this.openCommentSheet('new', 0, 0, '');
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 16, bottom: 8 })
    .transition({ type: TransitionType.Insert, opacity: 0 })
    .transition({ type: TransitionType.Delete, opacity: 0 })
    .id('sortBar_' + this.sortBarVersion)
  }

  /** ⭐ 加载等待期预览信息区：封面+时长+UP主+播放量（与视频页背景模式无关，纯色/自定义下也显示） */
  @Builder
  VideoLoadingPreviewInfo() {
    if (this.isLs && this.isPgc_) {
      // ⭐ 横屏番剧/影视：封面左侧 + 标题评分右侧
      Row() {
        Stack() {
          Image(this.coverSrc()).width('100%').height('100%')
            .objectFit(ImageFit.Cover).borderRadius(28).clip(true)
        }
        .padding({ left: 2, right: 2, top: 2, bottom: 2 })
        .margin({ left: 22, top: 22, bottom: 22 })
        .borderRadius(30).clip(true)
        .linearGradient({ angle: this.coverGlowAngle, colors: [['#00000000', 0], ['#00000000', 0.35], ['#40FFFFFF', 0.50], ['#FFFFFF', 0.65], ['#40FFFFFF', 0.80], ['#00000000', 0.95], ['#00000000', 1]] })
        .height('85%')
        .aspectRatio(3 / 4)

        Column() {
          Text(this.vi.title || '')
            .fontSize(22).fontColor(Color.White).fontWeight(FontWeight.Bold)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
          if (this.vi.score) {
            Text(`${this.vi.score}分`)
              .fontSize(18).fontColor('#FFD700').fontWeight(FontWeight.Bold)
              .margin({ top: 10 })
          }
          if (this.vi.indexShow) {
            Text(this.vi.indexShow)
              .fontSize(15).fontColor('rgba(255,255,255,0.7)')
              .margin({ top: 8 })
          }
          if (this.vi.badge) {
            Text(this.vi.badge)
              .fontSize(14).fontColor('rgba(255,255,255,0.9)')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(4)
              .backgroundColor('rgba(251,114,153,0.8)')
              .margin({ top: 8 })
          }
        }
        .margin({ left: 16, right: 22 })
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1)
      }
      .width('100%').height('100%')
      .alignItems(VerticalAlign.Center)
    } else if (this.isLs && !this.isPgc_) {
      // ⭐ 横屏普通视频：封面左侧 + 信息区右侧
      Row() {
        Stack() {
          Image(this.coverSrc()).width('100%').height('100%')
            .objectFit(ImageFit.Cover).borderRadius(28).clip(true)
        }
        .padding({ left: 2, right: 2, top: 2, bottom: 2 })
        .margin({ left: 22, top: 22, bottom: 22 })
        .borderRadius(30).clip(true)
        .linearGradient({ angle: this.coverGlowAngle, colors: [['#00000000', 0], ['#00000000', 0.35], ['#40FFFFFF', 0.50], ['#FFFFFF', 0.65], ['#40FFFFFF', 0.80], ['#00000000', 0.95], ['#00000000', 1]] })
        .width('58%')
        .aspectRatio(16 / 9)

        Column() {
          Row() {

            // 左栏：时长
            Column() {
              if ((this.vd ? this.vd.duration : (this.vi.duration ?? 0)) > 0) {
                Row() {
                  Text(`${this.formatDuration(this.vd ? this.vd.duration : (this.vi.duration ?? 0))}`)
                  .fontSize(13).fontColor('rgba(255,255,255,0.85)').fontWeight(FontWeight.Bold).letterSpacing(1)
                  Text(`丨`).fontSize(11).fontColor(`rgba(255,255,255,0.5)`).margin({ left: 6 })
                }
              }
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.End)

            // 中栏：UP主名字
            Text(this.vd?.owner?.name || this.vi.ownerName || '')
              .fontSize(14)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Bolder)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '40%' })
              .margin({ left: 6, right: 6 })

            // 右栏：播放量
            Column() {
              if ((this.vd ? this.vd.stat.view : (this.vi.view ?? 0)) > 0) {
                Row() {
                  Text(`丨`).fontSize(11).fontColor(`rgba(255,255,255,0.5)`).margin({ right: 6 })
                  Text(`${this.fmtN(this.vd ? this.vd.stat.view : (this.vi.view ?? 0))}`)
                    .fontSize(13).fontColor('rgba(255,255,255,0.85)').fontWeight(FontWeight.Bold).letterSpacing(1)
                  Image($r('app.media.play_fill'))
                    .width(14).height(14)
                    .fillColor('rgba(255,255,255,0.85)')
                    .margin({ left: 4 })
                }
              }
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Start)
            .alignItems(HorizontalAlign.Start)
          }
            .alignItems(VerticalAlign.Center)
          .width('100%')
        }
        .margin({ left: 16, right: 22 })
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
      .width('100%').height('100%')
      .alignItems(VerticalAlign.Center)
    } else {
    Column() {
      Stack() {
        Image(this.coverSrc()).width('100%').aspectRatio(this.isPgc_ ? 3 / 4 : 16 / 9)
          .objectFit(ImageFit.Cover).borderRadius(28).clip(true)
      }
      .padding({ left: 2, right: 2, top: 2, bottom: 2 })
      .margin({ left: 22, right: 22 })
      .borderRadius(30).clip(true)
      .linearGradient({ angle: this.coverGlowAngle, colors: [['#00000000', 0], ['#00000000', 0.35], ['#40FFFFFF', 0.50], ['#FFFFFF', 0.65], ['#40FFFFFF', 0.80], ['#00000000', 0.95], ['#00000000', 1]] })
      // ⭐ 竖屏番剧/影视：封面底部标题+评分
      if (this.isPgc_) {
        Column() {
          Text(this.vi.title || '')
            .fontSize(16).fontColor(Color.White).fontWeight(FontWeight.Bold)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%').textAlign(TextAlign.Center)
          Row() {
            if (this.vi.score) {
              Text(`${this.vi.score}分`)
                .fontSize(14).fontColor('#FFD700').fontWeight(FontWeight.Bold)
            }
            if (this.vi.indexShow) {
              Text(this.vi.indexShow)
                .fontSize(12).fontColor('rgba(255,255,255,0.7)')
                .margin({ left: this.vi.score ? 10 : 0 })
            }
          }
          .margin({ top: 6 })
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .padding({ left: 22, right: 22 })
        .margin({ top: 12 })
        .alignItems(HorizontalAlign.Center)
      }
      // ⭐ UP主信息：仅普通视频显示（番剧/影视只显示封面图）
      if (!this.isPgc_) {
        Row() {

          // 左栏：时长贴中心
          Column() {
            if ((this.vd ? this.vd.duration : (this.vi.duration ?? 0)) > 0) {
              Row() {
                Text(`${this.formatDuration(this.vd ? this.vd.duration : (this.vi.duration ?? 0))}`)
                .fontSize(13).fontColor('rgba(255,255,255,0.85)').fontWeight(FontWeight.Bold).letterSpacing(1)
                Text(`丨`).fontSize(11).fontColor(`rgba(255,255,255,0.5)`).margin({ left: 6 })
              }
            }
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.End)
          .alignItems(HorizontalAlign.End)

          // 中栏：UP主名字居中
          Text(this.vd?.owner?.name || this.vi.ownerName || '')
            .fontSize(14)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Bolder)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '40%' })
            .margin({ left: 6, right: 6 })

          // 右栏：播放量贴中心
          Column() {
            if ((this.vd ? this.vd.stat.view : (this.vi.view ?? 0)) > 0) {
              Row() {
                Text(`丨`).fontSize(11).fontColor(`rgba(255,255,255,0.5)`).margin({ right: 6 })
                Text(`${this.fmtN(this.vd ? this.vd.stat.view : (this.vi.view ?? 0))}`)
                  .fontSize(13).fontColor('rgba(255,255,255,0.85)').fontWeight(FontWeight.Bold).letterSpacing(1)
                Image($r('app.media.play_fill'))
                  .width(14).height(14)
                  .fillColor('rgba(255,255,255,0.85)')
                  .margin({ left: 4 })
              }
            }
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Start)
          .alignItems(HorizontalAlign.Start)
        }
          .alignItems(VerticalAlign.Center)
        .width('100%')
        .padding({ left: 22, right: 22 })
        .margin({ top: 16 })
      }
    }
    .offset({ y: !this.isLs ? (this.isPgc_ ? -20 : -180) : 0 })
    }
  }


  build() {
    Stack() {
      // ⭐ 关灯背景：当前封面/壁纸 + 模糊 + 黑色压暗（仿 FullImagePreview rgba(0,0,0,0.72)）
      // 常驻渲染（opacity 控制显隐），避免关灯时首次插入 Image 解码导致最后一帧闪烁
      if (this.videoBgMode === 'wallpaper' || this.vi.cover) {
        Image(this.lightsOffBgSrc())
          .width('100%').height('100%')
          .objectFit(ImageFit.Cover)
          .blur(this.loBgBlur)
          .scale({ x: this.loBgScale, y: this.loBgScale })
          .opacity(this.isLightsOff && !this.lightsOffHideOnly ? 1 : 0)
        Column()
          .width('100%').height('100%')
          .backgroundColor(`rgba(0,0,0,${this.loBgDim})`)
          .opacity(this.isLightsOff && !this.lightsOffHideOnly ? 1 : 0)
      }
      // 背景图（模糊/壁纸/纯色）
      if (this.videoBgMode === 'wallpaper' && !(this.isLightsOff && !this.lightsOffHideOnly)) {
        // 自定义壁纸背景
        if (this.videoBgCustomWallpaper) {
          Image('file://' + this.videoBgCustomWallpaper)
            .width('100%').height('100%')
            .objectFit(ImageFit.Cover)
            .blur(this.videoBgCustomWallpaperBlur);
        } else {
          Column().width('100%').height('100%').backgroundColor(this.videoBgColor);
        }
        // 壁纸明暗覆盖层
        if (this.videoBgCustomWallpaperDarkness < 50) {
          Column()
            .width('100%').height('100%')
            .backgroundColor(`rgba(0,0,0,${(50 - this.videoBgCustomWallpaperDarkness) / 50})`);
        } else if (this.videoBgCustomWallpaperDarkness > 50) {
          Column()
            .width('100%').height('100%')
            .backgroundColor(`rgba(255,255,255,${(this.videoBgCustomWallpaperDarkness - 50) / 50})`);
        }
      } else if (this.vi.cover && this.videoBgMode !== 'custom_color' && !(this.isLightsOff && !this.lightsOffHideOnly)) {
        // ⭐ 封面背景必须始终渲染：旋转时内容区 opacity=0 已不可见，若再隐藏封面会露出纯黑背景（黑屏）
        // 1080w 未解码时回退原始 URL（List 页刚显示过，框架缓存内秒显），避免开屏黑闪
        Stack() {
          Image(this.coverSrc()).width('100%').height('100%')
            .objectFit(ImageFit.Cover).blur(this.cardBgBlurAmount * (1 + Math.pow(this.fsPanProgress, 0.7) * 3) + 30)
        }
        .alignContent(this.isLs ? Alignment.Start : Alignment.Center)
      } else if (this.videoBgMode === 'custom_color' && !(this.isLightsOff && !this.lightsOffHideOnly)) {
        Column().width('100%').height('100%').backgroundColor(this.videoBgColor);
      } else if (!(this.isLightsOff && !this.lightsOffHideOnly)) {
        Column().width('100%').height('100%').backgroundColor($r('app.color.color_player_background'));
      }
      // ⭐ 加载等待期预览信息区（封面+时长+UP主+播放量）：与视频页背景模式无关，纯色/自定义下也显示
      if (!this.contentVisible && this.vi.cover) {
        Stack() {
          this.VideoLoadingPreviewInfo()
        }
        .width('100%').height('100%')
        .alignContent(this.isLs ? Alignment.Start : Alignment.Center)
      }
      // 背景明暗覆盖层
      if (this.cardBgDarkness < 50) {
        Column()
          .width('100%').height('100%')
          .backgroundColor(`rgba(0,0,0,${(50 - this.cardBgDarkness) / 50})`);
      } else if (this.cardBgDarkness > 50) {
        Column()
          .width('100%').height('100%')
          .backgroundColor(`rgba(255,255,255,${(this.cardBgDarkness - 50) / 50})`);
      }

      // ⭐ 更多弹窗挂载容器（独立节点，与选集弹窗 bindSheet 分离）
      Column().width(1).height(1).opacity(0).hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.mpb, this.moreSheetContent(), {
          // ⭐ 高度按菜单项数量算：标题区 ~110 + 每项 48+10，避免新增菜单项后最后一项被裁切
          height: 110 + this.mo_.length * 58,
          backgroundColor: Color.Transparent,
          systemMaterial: MaterialUtil.sheetMaterial(),
          dragBar: true,
          showClose: false,
          onDisappear: () => {
            this.mpb = false;
          }
        })

      // ⭐ 弹幕设置面板挂载容器（与「更多」弹窗分离，避免 mpb/mp 关闭联动）
      Column().width(1).height(1).opacity(0).hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.showDanmakuSettingSheet, this.danmakuSettingSheetContent(), {
          height: SheetSize.LARGE,
          backgroundColor: Color.Transparent,
          systemMaterial: MaterialUtil.sheetMaterial(),
          dragBar: true,
          showClose: false,
          onDisappear: () => {
            this.showDanmakuSettingSheet = false;
            this.saveDanmakuDisplaySettings();
          }
        })

      // ⭐ 缓存画质弹窗挂载容器（另一个独立节点，与 mpb/选集弹窗均分离）
      Column().width(1).height(1).opacity(0).hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.cacheQnPopup, this.cacheQnSheetContent(), {
          // ⭐ 高度按画质选项数量动态计算，避免底部选项被裁切（标题~36 + 选项数*(48+10) + 底部留白）
          height: 90 + this.getQlList().length * 58,
          backgroundColor: Color.Transparent,
          systemMaterial: MaterialUtil.sheetMaterial(),
          dragBar: true,
          showClose: false,
          onDisappear: () => {
            this.cacheQnPopup = false;
          }
        })

      // ⭐ 评论输入弹窗挂载容器（写评论/回复共用，与 mpb/缓存弹窗分离）
      Column().width(1).height(1).opacity(0).hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.commentSheetVisible, this.commentSheetContent(), {
          height: SheetSize.FIT_CONTENT,
          backgroundColor: Color.Transparent,
          systemMaterial: MaterialUtil.sheetMaterial(),
          dragBar: true,
          showClose: false,
          // ⭐ 弹层自身做键盘避让（在输入法上方自动平移+可滚动）；页面不再改
          //    键盘模式（之前 NONE 会阻断弹层收到键盘高度，导致输入框被盖住）
          keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL,
          // ⭐ 表情面板展开时，返回（侧滑/返回键）应当**先收起面板**、不关整个输入弹层。
          //    ⚠️ 官方文档：注册 onWillDismiss 后弹层不再自动关，必须自己决定是否 dismiss()
          //       ⇒ 非 PRESS_BACK 的原因（下拉关闭/点遮罩）显式调 a.dismiss()，关闭行为不变。
          //    📌 唯一副作用：注册了 onWillDismiss 又未注册 onWillSpringBackWhenDismiss 时，
          //       **下拉关闭会先回弹再关**（官方默认流程）；这是使用该回调的既定代价。
          onWillDismiss: (a: DismissSheetAction): void => {
            if (a.reason === DismissReason.PRESS_BACK && this.cmSheetEmoteCtrl.collapseEmote()) {
              return;   // 面板本来开着 → 已收起，弹层保持打开
            }
            a.dismiss();
          },
          onAppear: () => {
            // ⭐ 弹层出现后自动聚焦输入框，展开系统输入法
            setTimeout(() => {
              try {
                this.getUIContext().getFocusController().requestFocus('comment_rich_editor');
              } catch (_) {}
            }, 30);
          },
          onDisappear: () => {
            this.commentSheetVisible = false;
          }
        })

      // ⭐ 发弹幕弹窗挂载容器（与评论弹窗分离）
      Column().width(1).height(1).opacity(0).hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.showDanmakuSheet, this.dmSheetContent(), {
          height: SheetSize.FIT_CONTENT,
          // ⭐ 原先没写 options 底色（走 sheet 默认白底），现在内容根改条件透明后必须显式透明，
          //    否则 sheet 默认底色会画在材质之上把玻璃盖住
          backgroundColor: Color.Transparent,
          systemMaterial: MaterialUtil.sheetMaterial(),
          dragBar: true,
          showClose: false,
          keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL,
          // ⭐ 同评论弹层：表情面板展开时返回先收面板，不关整个弹层；
          //    非 PRESS_BACK 的原因显式 a.dismiss()（见评论弹层的注释：下拉会先回弹，官方默认流程）
          onWillDismiss: (a: DismissSheetAction): void => {
            if (a.reason === DismissReason.PRESS_BACK && this.dmSheetEmoteCtrl.collapseEmote()) {
              return;   // 面板本来开着 → 已收起，弹层保持打开
            }
            a.dismiss();
          },
          onDisappear: () => {
            this.showDanmakuSheet = false;
          }
        })

      // ⭐ 合集弹窗挂载容器（独立节点，与选集弹窗 bindSheet 分离）
      Column().width(1).height(1).opacity(0).hitTestBehavior(HitTestMode.None)
        .bindSheet($$this.showSeasonSheet, this.seasonSheetContent(), {
          height: 400,
          backgroundColor: Color.Transparent,
          systemMaterial: MaterialUtil.sheetMaterial(),
          dragBar: true,
          showClose: false,
          onAppear: () => {
            setTimeout(() => {
              this.seasonScroller_.scrollToIndex(this.seasonCurrentEpisodeIndex(), true);
            }, 150);
          },
          onDisappear: () => {
            this.showSeasonSheet = false;
          }
        })

      // 主要内容区域（初始为缩小 + 透明，加载完成后居中弹出）
      // ⭐ 用 Stack 而非 Column：全屏黑板需要真正盖住内容分支（Column 流式布局会把黑板排到内容下方）
      Stack() {
        // ⭐ 内容分支常驻渲染：fs 期间冻结在进入前的分支（preFsBranch 快照），
        // 旋转不再切分支 → 详情页零重挂载、无封面重解码风暴；冻结分支被下方背景板盖住
        this.buildContentBranch()
        // ⭐ 全屏背景板：常挂载保持子树稳定（挂载/卸载会使常驻层兄弟位置变化导致重建抖动），
        //    仅全屏时可见；退出插值期间提前隐藏，让内容渐显过程可见；并承接窗口旋转回调 onCA
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(this.ovPlateBg())
          .visibility(this.fs && this.fsLerpDir !== 2 ? Visibility.Visible : Visibility.Hidden)
          .onAreaChange(this.onCA)
        // ⭐ 常驻播放器层（XComponent 单实例，跨分支常驻，几何随状态驱动）
        this.buildPlayerOverlay()
      }
      .opacity(this.fs ? 1 : (this.contentVisible ? this.calcPageEnterOpacity() : 0))
      .scale({
        x: this.fs ? 1 : (this.contentVisible ? this.calcPageEnterScaleX() : 1),
        y: this.fs ? 1 : (this.contentVisible ? this.calcPageEnterScaleY() : 1)
      })
      .offset({
        x: this.fs ? 0 : (this.contentVisible ? this.calcPageEnterOffsetX() : 0),
        y: this.fs ? 0 : (this.contentVisible ? this.calcPageEnterOffsetY() : 0)
      })
      .blur(this.fs ? 0 : (this.contentVisible ? this.calcPageEnterBlur() : 0))
      .onAreaChange(this.onColumnArea)
      // 全屏切换动画由常驻播放器层几何插值实现（见 buildPlayerOverlay）

      // ⭐ 视频缩小/恢复悬浮按钮（沉浸光感版，仅竖屏评论区）
      if (!this.isLs && !this.fs && !this.isLightsOff) {
        if (this.smartGripEnabled) {
          // ── 智感握姿 ON：左右双按钮 ──
          // 左侧按钮（左手握持时显示）
          Stack() {
            HdsMiniBarButton({
              barWidth: 48,
              barHeight: 48,
              contentPadding: 0,
              containerSize: { width: 48, height: 48 },
              barBottomMargin: 0,
              barOverlap: true,
              barPosition: BarPosition.End
            }) {
              Image(this.vidShrink > 0.5 ? $r('app.media.chevron_down') : $r('app.media.full_screen_fill'))
                .width(20).height(20)
                .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : (this.isDarkMode ? Color.White : Color.Black))
            }
            Column()
              .width(48).height(48)
              .hitTestBehavior(HitTestMode.Block)
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.shrinkTouchStartWX = event.touches[0].windowX;
                  this.shrinkTouchStartWY = event.touches[0].windowY;
                  this.shrinkDragStartY = this.videoShrinkBtnY;
                  this.shrinkTouchMoved = false;
                  this.shrinkIsDragging = true;
                } else if (event.type === TouchType.Move) {
                  const offYpx = event.touches[0].windowY - this.shrinkTouchStartWY;
                  if (Math.abs(offYpx) > 5) {
                    this.shrinkTouchMoved = true;
                  }
                  this.videoShrinkBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.shrinkDragStartY - Math.round(this.getUIContext().px2vp(offYpx))));
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.shrinkIsDragging = false;
                  if (this.shrinkTouchMoved) {
                    AppStorage.set('videoShrinkBtnY', this.videoShrinkBtnY);
                    this.saveVideoFloatBtnPrefs();
                  } else if (event.type === TouchType.Up) {
                    this.triggerHaptic();
                    animateTo({ duration: 100, curve: Curve.FastOutLinearIn }, () => {
                      this.vidShrinkRestoreScale = 0.8;
                    });
                    setTimeout(() => {
                      animateTo({ duration: 300, curve: curves.springMotion(0.4, 0.8) }, () => {
                        this.vidShrinkRestoreScale = 1;
                      });
                    }, 100);
                    this.animateVidShrink(this.vidShrink > 0.5 ? 0 : 1);
                  }
                }
              })
          }
          .position({ bottom: this.videoShrinkBtnY, left: this.smartGripLeft })
          .opacity(this.hand === 1 ? this.floatBtnOpacity : 0)
          .translate({ x: this.hand === 1 ? 0 : -20, y: this.floatBtnOffsetY })
          .hitTestBehavior(this.hand === 1 ? HitTestMode.Default : HitTestMode.None)
          .scale({ x: this.vidShrinkRestoreScale * this.floatBtnScale, y: this.vidShrinkRestoreScale * this.floatBtnScale })
          .animation(this.shrinkIsDragging ? { duration: 0 } : { duration: 300, curve: curves.springMotion(0.3, 0.4) })
          // 右侧按钮（右手/默认握持时显示）
          Stack() {
            HdsMiniBarButton({
              barWidth: 48,
              barHeight: 48,
              contentPadding: 0,
              containerSize: { width: 48, height: 48 },
              barBottomMargin: 0,
              barOverlap: true,
              barPosition: BarPosition.End
            }) {
              Image(this.vidShrink > 0.5 ? $r('app.media.chevron_down') : $r('app.media.full_screen_fill'))
                .width(20).height(20)
                .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : (this.isDarkMode ? Color.White : Color.Black))
            }
            Column()
              .width(48).height(48)
              .hitTestBehavior(HitTestMode.Block)
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.shrinkTouchStartWX = event.touches[0].windowX;
                  this.shrinkTouchStartWY = event.touches[0].windowY;
                  this.shrinkDragStartY = this.videoShrinkBtnY;
                  this.shrinkTouchMoved = false;
                  this.shrinkIsDragging = true;
                } else if (event.type === TouchType.Move) {
                  const offYpx = event.touches[0].windowY - this.shrinkTouchStartWY;
                  if (Math.abs(offYpx) > 5) {
                    this.shrinkTouchMoved = true;
                  }
                  this.videoShrinkBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.shrinkDragStartY - Math.round(this.getUIContext().px2vp(offYpx))));
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.shrinkIsDragging = false;
                  if (this.shrinkTouchMoved) {
                    AppStorage.set('videoShrinkBtnY', this.videoShrinkBtnY);
                    this.saveVideoFloatBtnPrefs();
                  } else if (event.type === TouchType.Up) {
                    this.triggerHaptic();
                    animateTo({ duration: 100, curve: Curve.FastOutLinearIn }, () => {
                      this.vidShrinkRestoreScale = 0.8;
                    });
                    setTimeout(() => {
                      animateTo({ duration: 300, curve: curves.springMotion(0.4, 0.8) }, () => {
                        this.vidShrinkRestoreScale = 1;
                      });
                    }, 100);
                    this.animateVidShrink(this.vidShrink > 0.5 ? 0 : 1);
                  }
                }
              })
          }
          .position({ bottom: this.videoShrinkBtnY, right: this.smartGripRight })
          .opacity(this.hand !== 1 ? this.floatBtnOpacity : 0)
          .translate({ x: this.hand !== 1 ? 0 : 20, y: this.floatBtnOffsetY })
          .hitTestBehavior(this.hand !== 1 ? HitTestMode.Default : HitTestMode.None)
          .scale({ x: this.vidShrinkRestoreScale * this.floatBtnScale, y: this.vidShrinkRestoreScale * this.floatBtnScale })
          .animation(this.shrinkIsDragging ? { duration: 0 } : { duration: 300, curve: curves.springMotion(0.3, 0.4) })
        } else {
          // ── 智感握姿 OFF：单个可拖拽按钮 ──
          Stack() {
            HdsMiniBarButton({
              barWidth: 48,
              barHeight: 48,
              contentPadding: 0,
              containerSize: { width: 48, height: 48 },
              barBottomMargin: 0,
              barOverlap: true,
              barPosition: BarPosition.End
            }) {
              Image(this.vidShrink > 0.5 ? $r('app.media.chevron_down') : $r('app.media.full_screen_fill'))
                .width(20).height(20)
                .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : (this.isDarkMode ? Color.White : Color.Black))
            }
            Column()
              .width(48).height(48)
              .hitTestBehavior(HitTestMode.Block)
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.shrinkTouchStartWX = event.touches[0].windowX;
                  this.shrinkTouchStartWY = event.touches[0].windowY;
                  this.shrinkDragStartY = this.videoShrinkBtnY;
                  this.shrinkDragOffsetX = 0;
                  this.shrinkTouchMoved = false;
                  this.shrinkIsDragging = true;
                } else if (event.type === TouchType.Move) {
                  const offYpx = event.touches[0].windowY - this.shrinkTouchStartWY;
                  const offXpx = event.touches[0].windowX - this.shrinkTouchStartWX;
                  if (Math.abs(offYpx) > 5 || Math.abs(offXpx) > 5) {
                    this.shrinkTouchMoved = true;
                  }
                  this.videoShrinkBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.shrinkDragStartY - Math.round(this.getUIContext().px2vp(offYpx))));
                  this.shrinkDragOffsetX = Math.round(this.getUIContext().px2vp(offXpx));
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.shrinkIsDragging = false;
                  if (this.shrinkTouchMoved) {
                    const totalOffsetX: number = this.shrinkDragOffsetX;
                    let newSide: string = this.videoShrinkBtnSide;
                    let sideChanged: boolean = false;
                    if (totalOffsetX < -60) {
                      newSide = 'left';
                      sideChanged = true;
                    } else if (totalOffsetX > 60) {
                      newSide = 'right';
                      sideChanged = true;
                    }
                    if (sideChanged || totalOffsetX !== 0) {
                      animateTo({ duration: 300, curve: Curve.Ease }, () => {
                        this.shrinkDragOffsetX = 0;
                        if (sideChanged) {
                          this.videoShrinkBtnSide = newSide;
                        }
                      });
                    } else {
                      this.shrinkDragOffsetX = 0;
                    }
                    AppStorage.set('videoShrinkBtnSide', this.videoShrinkBtnSide);
                    AppStorage.set('videoShrinkBtnY', this.videoShrinkBtnY);
                    this.saveVideoFloatBtnPrefs();
                  } else {
                    this.shrinkDragOffsetX = 0;
                    if (event.type === TouchType.Up) {
                      this.triggerHaptic();
                      animateTo({ duration: 100, curve: Curve.FastOutLinearIn }, () => {
                        this.vidShrinkRestoreScale = 0.8;
                      });
                      setTimeout(() => {
                        animateTo({ duration: 300, curve: curves.springMotion(0.4, 0.8) }, () => {
                          this.vidShrinkRestoreScale = 1;
                        });
                      }, 100);
                      this.animateVidShrink(this.vidShrink > 0.5 ? 0 : 1);
                    }
                  }
                }
              })
          }
          .width(48).height(48)
          .opacity(this.floatBtnOpacity)
          .position(this.videoShrinkBtnSide === 'left'
            ? { bottom: this.videoShrinkBtnY, left: 32 }
            : { bottom: this.videoShrinkBtnY, right: 32 })
          .scale({ x: this.vidShrinkRestoreScale * this.floatBtnScale, y: this.vidShrinkRestoreScale * this.floatBtnScale })
          .animation(this.shrinkIsDragging ? { duration: 0 } : { duration: 300, curve: curves.springMotion(0.3, 0.4) })
          .translate({ x: this.shrinkDragOffsetX, y: this.floatBtnOffsetY })
        }
      }
      // ⭐ 比例/画质底部弹窗
      if (this.sp && !this.isLightsOff) { this.bSP() }
      if (this.colorStylePopup && !this.isLightsOff) { /* bCP() 暂禁用 */ }
      if (this.qp && !this.isLightsOff) { this.bQP() }
      // ⭐ 更多菜单
      if (this.mp && !this.isLightsOff) { this.bMP() }
      // ⭐ 全屏评论浮层（复用评论区核心；转场期随条件卸载隐藏，退出全屏自动关闭）
      if (this.cp && this.fs && !this.rotationInProgress) { this.fsCommentPanel() }


      // ⭐ 缓存提示条（可点击跳转离线缓存列表页；完成时文案切换；右侧关闭按钮）
      if (this.cacheHintVisible) {
        Row() {
          // 图标：下载中为转圈，完成后为对勾，暂停为黄色圆形白色暂停
          if (this.cacheHintDone) {
            Image($r('app.media.checkmark_circle_fill'))
              .width(18).height(18)
              .fillColor('#34C759')
          } else if (this.cacheHintPaused) {
            Image($r('app.media.pause_circle_fill'))
              .width(18).height(18)
              .fillColor('#FFD60A')
          } else {
            LoadingProgress()
              .width(18).height(18)
              .color('#FFFFFF')
          }
          Text(this.cacheHintDone ? '缓存完成·点击查看' : (this.cacheHintPaused ? '已暂停·点击查看' : '正在缓存·点击查看'))
            .fontSize(13)
            .fontColor(Color.White)
            .margin({ left: 8 })
          // ⭐ 红色圆圈+白色叉号关闭按钮（18×18 与左侧状态图标左右对称；ClickEvent 无 stopPropagation，用标志位阻止冒泡跳转）
          Column() {
            Image($r('app.media.xmark_circle_fill'))
              .width(18).height(18)
              .fillColor('#FF453A')
          }
          .width(24).height(24)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .margin({ left: 10 })
          .onClick(() => {
            this.hintCloseClicked_ = true;
            this.cacheHintVisible = false;
          })
        }
        .padding({ left: 16, right: 12, top: 8, bottom: 8 })
        .backgroundColor('rgba(0,0,0,0.7)')
        .borderRadius(20)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          if (this.hintCloseClicked_) {
            this.hintCloseClicked_ = false;
            return;
          }
          this.goToOfflineCachePage();
        })
        .position({ bottom: this.cacheHintBottom, left: this.cacheHintLeft })
        .zIndex(20)
        .gesture(
          // ⭐ 提示条可随意拖动（水平+垂直），拖动结束位置持久化
          PanGesture({ direction: PanDirection.All, distance: 5 })
            .onActionStart(() => {
              this.cacheHintDragStartX = this.cacheHintLeft;
              this.cacheHintDragStartY = this.cacheHintBottom;
            })
            .onActionUpdate((event: GestureEvent) => {
              // 水平边界：左侧 8，右侧留 8；垂直边界：底部 20，顶部到状态栏下
              const maxLeft = Math.max(8, this.cw - 220 - 8);
              this.cacheHintLeft = Math.max(8, Math.min(maxLeft, this.cacheHintDragStartX + Math.round(event.offsetX)));
              this.cacheHintBottom = Math.max(20, Math.min(this.maxFloatBtnBottom, this.cacheHintDragStartY - Math.round(event.offsetY)));
            })
            .onActionEnd(() => {
              AppStorage.set('cacheHintLeft', this.cacheHintLeft);
              AppStorage.set('cacheHintBottom', this.cacheHintBottom);
              this.saveCacheHintPrefs();
            })
        )
      }
      // ⭐ 关灯模式下的开灯按钮（智感握持定位，悬浮按钮）
      // 分两套点击方案：
      //   1. 按钮可见时 → 四边死区覆盖层，只黑边区域切换显隐，视频区域不受影响
      //   2. 按钮隐藏后 → 全屏透明覆盖层，点任何位置都能重新显示按钮
      // ⭐ 仅当"开灯按钮显示"设置开启时渲染开灯按钮区域；关闭时靠侧滑返回开灯
      if (this.isLightsOff && this.lightsOffShowBtn && !this.isShortVideo()) {
        if (this.lightBtnVisible) {
          // ── 方案1：按钮可见 → 四边死区覆盖层（视频区域不覆盖） ──
          // 顶部死区（视频上方黑边）
          if (this.xcRy > 0) {
            Column()
              .width('100%')
              .height(this.xcRy)
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => {
                this.triggerHaptic();
                this.toggleLightBtn();
              })
          }
          // 底部死区（视频下方黑边）
          if (this.ch - this.xcRy - this.xcH > 0) {
            Column()
              .width('100%')
              .height(this.ch - this.xcRy - this.xcH)
              .position({ top: this.xcRy + this.xcH })
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => {
                this.triggerHaptic();
                this.toggleLightBtn();
              })
          }
          // 左侧死区（视频左边黑边）
          if (this.xcRx > 0) {
            Column()
              .width(this.xcRx)
              .height(this.xcH)
              .position({ top: this.xcRy })
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => {
                this.triggerHaptic();
                this.toggleLightBtn();
              })
          }
          // 右侧死区（视频右边黑边）
          if (this.cw - this.xcRx - this.xcW > 0) {
            Column()
              .width(this.cw - this.xcRx - this.xcW)
              .height(this.xcH)
              .position({ left: this.xcRx + this.xcW, top: this.xcRy })
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => {
                this.triggerHaptic();
                this.toggleLightBtn();
              })
          }
        } else {
          // ── 方案2：按钮已隐藏 → 全屏透明覆盖层，点任意位置重新显示按钮 ──
          Column()
            .width('100%').height('100%')
            .hitTestBehavior(HitTestMode.Transparent)
            .onClick(() => {
              this.triggerHaptic();
              this.toggleLightBtn();
            })
        }
        if (this.lightBtnVisible) {
          if (this.isLs) {
            // 横屏：智感握姿不生效，始终可拖拽
            Button() {
              Image($r('app.media.lightbulb'))
                .width(24).height(24)
                .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : Color.White)
                .rotate({ angle: this.lightbulbRotation })
            }
            .width(48).height(48)
            .borderRadius(24)
            .backgroundColor('rgba(255,255,255,0.15)')
            .shadow({ radius: 16, color: '#40000000', offsetY: 4 })
            .scale({ x: this.lightBtnScale, y: this.lightBtnScale })
            .position(this.videoLightBtnSide === 'left'
              ? { bottom: this.videoLightBtnY, left: 32 }
              : { bottom: this.videoLightBtnY, right: 32 })
            .animation(this.lightIsDragging ? { duration: 0 } : { duration: 300, curve: Curve.Ease })
            .translate({ x: this.lightDragOffsetX })
            .gesture(
              PanGesture({ direction: PanDirection.All, distance: 5 })
                .onActionStart(() => {
                  this.lightIsDragging = true;
                  this.lightDragStartY = this.videoLightBtnY;
                  this.lightDragOffsetX = 0;
                })
                .onActionUpdate((event: GestureEvent) => {
                  this.videoLightBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.lightDragStartY - Math.round(event.offsetY)));
                  this.lightDragOffsetX = Math.round(event.offsetX);
                })
                .onActionEnd(() => {
                  this.lightIsDragging = false;
                  const totalOffsetX: number = this.lightDragOffsetX;
                  let newSide: string = this.videoLightBtnSide;
                  let sideChanged: boolean = false;
                  if (totalOffsetX < -60) {
                    newSide = 'left';
                    sideChanged = true;
                  } else if (totalOffsetX > 60) {
                    newSide = 'right';
                    sideChanged = true;
                  }
                  if (sideChanged || totalOffsetX !== 0) {
                    animateTo({ duration: 300, curve: Curve.Ease }, () => {
                      this.lightDragOffsetX = 0;
                      if (sideChanged) {
                        this.videoLightBtnSide = newSide;
                      }
                    });
                  } else {
                    this.lightDragOffsetX = 0;
                  }
                  AppStorage.set('videoLightBtnSide', this.videoLightBtnSide);
                  AppStorage.set('videoLightBtnY', this.videoLightBtnY);
                  this.saveVideoFloatBtnPrefs();
                })
            )
            .onClick(() => {
              this.triggerHaptic();
              this.clearLightBtnTimer();
              animateTo({ duration: 100, curve: Curve.FastOutLinearIn }, () => {
                this.lightBtnScale = 0.8;
              });
              setTimeout(() => {
                animateTo({ duration: 300, curve: curves.springMotion(0.4, 0.8) }, () => {
                  this.lightBtnScale = 1;
                });
              }, 100);
              animateTo({ duration: 600, curve: curves.springMotion(0.6, 0.8) }, () => {
                this.lightbulbRotation = 180;
              });
              setTimeout(() => {
                animateTo({ duration: 300, curve: Curve.Ease }, () => {
                  this.isLightsOff = false;
                  this.loBgScale = 1;
                  this.loBgBlur = 0;
                  this.loBgDim = 0;
                });
                this.manageSB(true);
              }, 620);
            })
          } else {
            // 竖屏：左右按钮淡入淡出
            if (this.smartGripEnabled) {
              // ── 智感握姿 ON：左右双按钮 ──
              Button() {
                Image($r('app.media.lightbulb'))
                  .width(24).height(24)
                  .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : Color.White)
                  .rotate({ angle: this.lightbulbRotation })
              }
              .width(48).height(48)
              .borderRadius(24)
              .backgroundColor('rgba(255,255,255,0.15)')
              .position({ bottom: this.videoLightBtnY, left: this.smartGripLeft })
              .opacity(this.hand === 1 ? 1 : 0)
              .translate({ x: this.hand === 1 ? 0 : -20 })
              .hitTestBehavior(this.hand === 1 ? HitTestMode.Default : HitTestMode.None)
              .shadow({ radius: 16, color: '#40000000', offsetY: 4 })
              .scale({ x: this.lightBtnScale, y: this.lightBtnScale })
              .animation(this.lightIsDragging ? { duration: 0 } : { duration: 300, curve: curves.springMotion(0.3, 0.4) })
              .gesture(
                PanGesture({ direction: PanDirection.Vertical, distance: 5 })
                  .onActionStart(() => {
                    this.lightIsDragging = true;
                    this.lightDragStartY = this.videoLightBtnY;
                  })
                  .onActionUpdate((event: GestureEvent) => {
                    this.videoLightBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.lightDragStartY - Math.round(event.offsetY)));
                  })
                  .onActionEnd(() => {
                    this.lightIsDragging = false;
                    AppStorage.set('videoLightBtnY', this.videoLightBtnY);
                    this.saveVideoFloatBtnPrefs();
                  })
              )
              .onClick(() => {
                this.triggerHaptic();
                this.clearLightBtnTimer();
                animateTo({ duration: 100, curve: Curve.FastOutLinearIn }, () => {
                  this.lightBtnScale = 0.8;
                });
                setTimeout(() => {
                  animateTo({ duration: 300, curve: curves.springMotion(0.4, 0.8) }, () => {
                    this.lightBtnScale = 1;
                  });
                }, 100);
                animateTo({ duration: 600, curve: curves.springMotion(0.6, 0.8) }, () => {
                  this.lightbulbRotation = 180;
                });
                setTimeout(() => {
                  animateTo({ duration: 300, curve: Curve.Ease }, () => {
                    this.isLightsOff = false;
                    this.loBgScale = 1;
                    this.loBgBlur = 0;
                    this.loBgDim = 0;
                  });
                  this.manageSB(true);
                }, 620);
              })
              // 右侧按钮
              Button() {
                Image($r('app.media.lightbulb'))
                  .width(24).height(24)
                  .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : Color.White)
                  .rotate({ angle: this.lightbulbRotation })
              }
              .width(48).height(48)
              .borderRadius(24)
              .backgroundColor('rgba(255,255,255,0.15)')
              .position({ bottom: this.videoLightBtnY, right: this.smartGripRight })
              .opacity(this.hand !== 1 ? 1 : 0)
              .translate({ x: this.hand !== 1 ? 0 : 20 })
              .hitTestBehavior(this.hand !== 1 ? HitTestMode.Default : HitTestMode.None)
              .shadow({ radius: 16, color: '#40000000', offsetY: 4 })
              .scale({ x: this.lightBtnScale, y: this.lightBtnScale })
              .animation(this.lightIsDragging ? { duration: 0 } : { duration: 300, curve: curves.springMotion(0.3, 0.4) })
              .gesture(
                PanGesture({ direction: PanDirection.Vertical, distance: 5 })
                  .onActionStart(() => {
                    this.lightIsDragging = true;
                    this.lightDragStartY = this.videoLightBtnY;
                  })
                  .onActionUpdate((event: GestureEvent) => {
                    this.videoLightBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.lightDragStartY - Math.round(event.offsetY)));
                  })
                  .onActionEnd(() => {
                    this.lightIsDragging = false;
                    AppStorage.set('videoLightBtnY', this.videoLightBtnY);
                    this.saveVideoFloatBtnPrefs();
                  })
              )
              .onClick(() => {
                this.triggerHaptic();
                this.clearLightBtnTimer();
                animateTo({ duration: 100, curve: Curve.FastOutLinearIn }, () => {
                  this.lightBtnScale = 0.8;
                });
                setTimeout(() => {
                  animateTo({ duration: 300, curve: curves.springMotion(0.4, 0.8) }, () => {
                    this.lightBtnScale = 1;
                  });
                }, 100);
                animateTo({ duration: 600, curve: curves.springMotion(0.6, 0.8) }, () => {
                  this.lightbulbRotation = 180;
                });
                setTimeout(() => {
                  animateTo({ duration: 300, curve: Curve.Ease }, () => {
                    this.isLightsOff = false;
                    this.loBgScale = 1;
                    this.loBgBlur = 0;
                    this.loBgDim = 0;
                  });
                  this.manageSB(true);
                }, 620);
              })
            } else {
              // ── 智感握姿 OFF：单个可拖拽按钮 ──
              Button() {
                Image($r('app.media.lightbulb'))
                  .width(24).height(24)
                  .fillColor(this.floatBtnFollowTheme ? this.customThemeColor : Color.White)
                  .rotate({ angle: this.lightbulbRotation })
              }
              .width(48).height(48)
              .borderRadius(24)
              .backgroundColor('rgba(255,255,255,0.15)')
              .shadow({ radius: 16, color: '#40000000', offsetY: 4 })
              .scale({ x: this.lightBtnScale, y: this.lightBtnScale })
              .position(this.videoLightBtnSide === 'left'
                ? { bottom: this.videoLightBtnY, left: 32 }
                : { bottom: this.videoLightBtnY, right: 32 })
              .animation(this.lightIsDragging ? { duration: 0 } : { duration: 300, curve: Curve.Ease })
              .translate({ x: this.lightDragOffsetX })
              .gesture(
                PanGesture({ direction: PanDirection.All, distance: 5 })
                  .onActionStart(() => {
                    this.lightIsDragging = true;
                    this.lightDragStartY = this.videoLightBtnY;
                    this.lightDragOffsetX = 0;
                  })
                  .onActionUpdate((event: GestureEvent) => {
                    this.videoLightBtnY = Math.max(20, Math.min(this.maxFloatBtnBottom, this.lightDragStartY - Math.round(event.offsetY)));
                    this.lightDragOffsetX = Math.round(event.offsetX);
                  })
                  .onActionEnd(() => {
                    this.lightIsDragging = false;
                    const totalOffsetX: number = this.lightDragOffsetX;
                    let newSide: string = this.videoLightBtnSide;
                    let sideChanged: boolean = false;
                    if (totalOffsetX < -60) {
                      newSide = 'left';
                      sideChanged = true;
                    } else if (totalOffsetX > 60) {
                      newSide = 'right';
                      sideChanged = true;
                    }
                    if (sideChanged || totalOffsetX !== 0) {
                      animateTo({ duration: 300, curve: Curve.Ease }, () => {
                        this.lightDragOffsetX = 0;
                        if (sideChanged) {
                          this.videoLightBtnSide = newSide;
                        }
                      });
                    } else {
                      this.lightDragOffsetX = 0;
                    }
                    AppStorage.set('videoLightBtnSide', this.videoLightBtnSide);
                    AppStorage.set('videoLightBtnY', this.videoLightBtnY);
                    this.saveVideoFloatBtnPrefs();
                  })
              )
              .onClick(() => {
                this.triggerHaptic();
                this.clearLightBtnTimer();
                animateTo({ duration: 100, curve: Curve.FastOutLinearIn }, () => {
                  this.lightBtnScale = 0.8;
                });
                setTimeout(() => {
                  animateTo({ duration: 300, curve: curves.springMotion(0.4, 0.8) }, () => {
                    this.lightBtnScale = 1;
                  });
                }, 100);
                animateTo({ duration: 600, curve: curves.springMotion(0.6, 0.8) }, () => {
                  this.lightbulbRotation = 180;
                });
                setTimeout(() => {
                  animateTo({ duration: 300, curve: Curve.Ease }, () => {
                    this.isLightsOff = false;
                    this.loBgScale = 1;
                    this.loBgBlur = 0;
                    this.loBgDim = 0;
                  });
                  this.manageSB(true);
                }, 620);
              })
            }
          }
        }
      }
      // ⭐ 关灯短视频覆盖层：放在**页面根 Stack 的最后**，不在常驻播放器层内。
      //    HdsTabs 的系统材质浮栏进到 transform/renderGroup 子层里会错位、收不到触摸；
      //    放到根层末尾（盖过开灯按钮的透明全屏层）后与笔记页工具栏同一条路径。
      if (this.isShortVideo()) {
        this.buildShortVideoChrome()
      }
    }.width('100%').height('100%').backgroundColor(this.isLightsOff && !this.lightsOffHideOnly ? Color.Black : $r('app.color.color_player_background'))
    .bindSheet($$this.showEpisodeSheet, this.episodeSheetContent(), {
      height: this.vd?.pages && this.vd.pages.length > 4 ? 400 : 280,
      backgroundColor: Color.Transparent,
      systemMaterial: MaterialUtil.sheetMaterial(),
      dragBar: true,
      showClose: false,
      onAppear: () => {
        // ⭐ 弹窗出现后定位到当前播放的集数（延迟等 List 布局完成），并高亮所在分段
        setTimeout(() => {
          if (this.vd?.pages && this.currentPageIndex >= 0 && this.currentPageIndex < this.vd.pages.length) {
            this.episodeSegment = Math.floor(this.currentPageIndex / 20);
            this.episodeScroller_.scrollToIndex(this.currentPageIndex, true);
          }
        }, 150);
      },
      onDisappear: () => {
        this.showEpisodeSheet = false;
      }
    })

  }

  // ⭐ 选集弹窗内容
  @Builder
  episodeSheetContent() {
    Column() {
      // ⭐ 顶部 8vp 空白占位（避免第一项贴弹窗顶部）
      Column().width('100%').height(8)
      Row() {
        // ⭐ 左侧分段快速定位（每 20 集一段：1-20 / 21-40 / 41-60...），集数多时方便跳段
        if (this.vd?.pages && this.vd.pages.length > 20) {
          Scroll() {
            Column({ space: 6 }) {
              ForEach(this.episodeSegList(), (seg: number) => {
                Text(this.episodeSegLabel(seg))
                  .fontSize(11)
                  .fontWeight(this.episodeSegment === seg ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.episodeSegment === seg
                    ? (this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                    : $r('app.color.color_player_text_secondary'))
                  .padding({ left: 8, right: 8, top: 7, bottom: 7 })
                  .backgroundColor(this.episodeSegment === seg ? $r('app.color.color_comment_selected') : Color.Transparent)
                  .borderRadius(14)
                  .onClick(() => {
                    this.triggerHaptic();
                    this.episodeSegment = seg;
                    // ⭐ 切段后 List 只渲染本段 20 集，回到段内顶部
                    this.episodeScroller_.scrollToIndex(0, false);
                  })
              }, (seg: number) => seg.toString())
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 8, bottom: 8 })
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .width(64)
          .height('100%')
        }
        // 选集列表（⭐ 只渲染当前分段内的集数）
        if (this.vd?.pages && this.vd.pages.length > 1) {
          List({ scroller: this.episodeScroller_ }) {
          ForEach(this.episodeSegPages(), (page: VideoPageItem, localIndex: number) => {
            ListItem() {
              Row() {
                // ⭐ 分集封面缩略图（PGC 分集有封面）
                if (page.cover) {
                  Image(page.cover)
                    .width(72).height(44)
                    .objectFit(ImageFit.Cover)
                    .borderRadius(6)
                    .backgroundColor('#E8E8E8')
                    .margin({ right: 8 })
                }
                Text(`P${page.page}`).fontSize(14).fontColor(
                  this.isCurrentEpisode(localIndex) ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary')
                ).width(36)
                Text(page.part).fontSize(14).fontColor(
                  this.isCurrentEpisode(localIndex) ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text')
                ).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).margin({ left: 4 })
                Text(this.formatDuration(page.duration)).fontSize(12)
                  .fontColor($r('app.color.color_player_text_secondary')).margin({ left: 8 })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .backgroundColor(this.isCurrentEpisode(localIndex) ?
                $r('app.color.color_comment_selected') : Color.Transparent)
              .borderRadius(20)
              .onClick(() => {
                if (!this.isCurrentEpisode(localIndex)) {
                  this.triggerHaptic();
                  this.switchEpisode(this.episodeSegGlobalIndex(localIndex));
                  this.showEpisodeSheet = false;
                }
              })
            }
          }, (page: VideoPageItem) => page.cid.toString())
        }
        // ⭐ Row 中 List 仅用 layoutWeight(1) 撑满右侧（不再 width('100%')，避免按整行宽计算超宽）
        .layoutWeight(1)
        .padding({ left: 8, right: 8 })
        .height('100%')
        .scrollBar(BarState.Off)
      }
      }
      // ⭐ Row 撑满 Column 剩余高度：否则 List 高度自适应内容会撑破弹窗，底部占位被挤出
      .layoutWeight(1)
      .width('100%')
      // ⭐ 底部 8vp 空白占位（避免最后一项贴弹窗底部）
      Column().width('100%').height(8)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.sheetRootBg($r('app.color.color_comment_background')))
  }

  // ⭐ 合集弹窗内容
  @Builder
  seasonSheetContent() {
    Column() {
      Column().width('100%').height(8)
      // 合集标题
      if (this.vd?.ugc_season?.title) {
        Text(this.vd.ugc_season.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.color_player_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 16, right: 16, bottom: 12 })
      }
      Row() {
        // 分区 Tab（多分区时显示）
        if (this.vd?.ugc_season?.sections && this.vd.ugc_season.sections.length > 1) {
          Scroll() {
            Column({ space: 6 }) {
              ForEach(this.vd.ugc_season.sections, (section: SeasonSection, index: number) => {
                Text(section.title || `分区${index + 1}`)
                  .fontSize(11)
                  .fontWeight(this.seasonSectionIndex === index ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.seasonSectionIndex === index
                    ? (this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink'))
                    : $r('app.color.color_player_text_secondary'))
                  .padding({ left: 8, right: 8, top: 7, bottom: 7 })
                  .backgroundColor(this.seasonSectionIndex === index ? $r('app.color.color_comment_selected') : Color.Transparent)
                  .borderRadius(14)
                  .onClick(() => {
                    this.triggerHaptic();
                    this.seasonSectionIndex = index;
                    this.seasonScroller_.scrollToIndex(0, false);
                  })
              }, (section: SeasonSection, index: number) => `${index}`)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 8, bottom: 8 })
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .width(64)
          .height('100%')
        }
        // 当前分区的分集列表
        if (this.vd?.ugc_season?.sections && this.vd.ugc_season.sections.length > 0) {
          List({ scroller: this.seasonScroller_ }) {
            ForEach(this.seasonCurrentEpisodes(), (ep: SeasonEpisode, localIndex: number) => {
              ListItem() {
                Row() {
                  if (ep.arc?.pic || ep.cover) {
                    Image(ep.arc?.pic || ep.cover)
                      .width(72).height(44)
                      .objectFit(ImageFit.Cover)
                      .borderRadius(6)
                      .backgroundColor('#E8E8E8')
                      .margin({ right: 8 })
                  }
                  Text(`${localIndex + 1}`).fontSize(14).fontColor(
                    this.isCurrentSeasonEpisode(ep) ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text_secondary')
                  ).width(36)
                   Text(ep.title || '').fontSize(14).fontColor(
                    this.isCurrentSeasonEpisode(ep) ? this.playerFollowTheme ? this.customThemeColor : ('app.color.color_bilibili_pink') : $r('app.color.color_player_text')
                  ).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).margin({ left: 4 })
                  Text(this.formatDuration(ep.duration || ep.arc?.duration || 0)).fontSize(12)
                    .fontColor($r('app.color.color_player_text_secondary')).margin({ left: 8 })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                .backgroundColor(this.isCurrentSeasonEpisode(ep) ? $r('app.color.color_comment_selected') : Color.Transparent)
                .borderRadius(20)
                .onClick(() => {
                  if (!this.isCurrentSeasonEpisode(ep)) {
                    this.triggerHaptic();
                    this.switchSeasonEpisode(ep);
                    this.showSeasonSheet = false;
                  }
                })
              }
            }, (ep: SeasonEpisode) => `${ep.aid}-${ep.cid}-${ep.bvid}`)
          }
          .layoutWeight(1)
          .padding({ left: 8, right: 8 })
          .height('100%')
          .scrollBar(BarState.Off)
        }
      }
      .layoutWeight(1)
      .width('100%')
      Column().width('100%').height(8)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.sheetRootBg($r('app.color.color_comment_background')))
  }

  // ⭐ 切换分P
  /** ⭐ 是否有下一集（多P分P / 番剧分集） */
  private hasNextEpisode(): boolean {
    return this.vd?.pages ? this.currentPageIndex + 1 < this.vd.pages.length : false;
  }

  /** ⭐ 选集分段数（每 20 集一段） */
  private episodeSegCount(): number {
    return this.vd?.pages ? Math.ceil(this.vd.pages.length / 20) : 0;
  }

  // ⭐ 合集辅助方法

  /** 当前分区的分集列表 */
  private seasonCurrentEpisodes(): SeasonEpisode[] {
    if (!this.vd?.ugc_season?.sections || this.vd.ugc_season.sections.length === 0) return [];
    const section = this.vd.ugc_season.sections[this.seasonSectionIndex];
    if (!section || !section.episodes) return [];
    return section.episodes;
  }

  /** 当前播放分集在合集中的索引 */
  private seasonCurrentEpisodeIndex(): number {
    const episodes = this.seasonCurrentEpisodes();
    if (episodes.length === 0) return 0;
    for (let i = 0; i < episodes.length; i++) {
      const ep = episodes[i];
      if (ep.cid && ep.cid === this.vi.cid) return i;
      if (ep.bvid && ep.bvid === this.vi.bvid) return i;
      if (ep.aid && ep.aid === this.vd?.aid) return i;
    }
    return 0;
  }

  /** 是否为当前播放分集 */
  private isCurrentSeasonEpisode(ep: SeasonEpisode): boolean {
    if (ep.cid && ep.cid === this.vi.cid) return true;
    if (ep.bvid && ep.bvid === this.vi.bvid) return true;
    if (ep.aid && ep.aid === this.vd?.aid) return true;
    return false;
  }

  /** 切换合集分集 */
  private async switchSeasonEpisode(ep: SeasonEpisode): Promise<void> {
    this.release();
    this.currentPageIndex = 0;
    if (ep.cid) this.vi.cid = ep.cid;
    if (ep.bvid) this.vi.bvid = ep.bvid;
    if (ep.aid) {
      if (this.vd) this.vd.aid = ep.aid;
      this.aidFromParams_ = ep.aid;
    }
    if (ep.title) this.vi.title = ep.title;
    if (ep.arc?.pic) this.vi.cover = ep.arc.pic;
    if (ep.duration) {
      this.vi.duration = ep.duration;
    } else if (ep.arc?.duration) {
      this.vi.duration = ep.arc.duration;
    }
    // 重置评论
    this.commentCursor = 0;
    this.commentDataSource.clear();
    if (ep.aid) {
      this.loadC(ep.aid);
    }
    // ⭐ 切集：清掉上一集的进度，改由新一集的 playurl 续播点恢复（否则会把上一集的位置带过来）
    this.initialProgress_ = 0;
    // 重新加载视频
    await this.initP();
  }

  /** ⭐ 选集分段索引列表（0, 1, 2...） */
  private episodeSegList(): number[] {
    const n = this.episodeSegCount();
    const list: number[] = [];
    for (let i = 0; i < n; i++) {
      list.push(i);
    }
    return list;
  }

  /** ⭐ 当前分段内的 pages 子集（List 只渲染本段，最多 20 集） */
  private episodeSegPages(): VideoPageItem[] {
    if (!this.vd?.pages) return [];
    const start = this.episodeSegStart(this.episodeSegment);
    const end = Math.min(start + 20, this.vd.pages.length);
    const list: VideoPageItem[] = [];
    for (let i = start; i < end; i++) {
      list.push(this.vd.pages[i]);
    }
    return list;
  }

  /** ⭐ 段内索引 → 全局索引（切集用全局索引） */
  private episodeSegGlobalIndex(localIndex: number): number {
    return this.episodeSegStart(this.episodeSegment) + localIndex;
  }

  /** ⭐ 该段内项是否为当前播放集（高亮判断） */
  private isCurrentEpisode(localIndex: number): boolean {
    return this.currentPageIndex === this.episodeSegGlobalIndex(localIndex);
  }

  /** ⭐ 分段起始集索引（第 seg 段从 seg*20 开始） */
  private episodeSegStart(seg: number): number {
    return seg * 20;
  }

  /** ⭐ 分段标签（1-20 / 21-40 / 41-60...） */
  private episodeSegLabel(seg: number): string {
    const start = this.episodeSegStart(seg) + 1;
    const end = Math.min(this.episodeSegStart(seg) + 20, this.vd?.pages?.length ?? 0);
    return `${start}-${end}`;
  }

  private async switchEpisode(index: number): Promise<void> {
    if (!this.vd?.pages || index === this.currentPageIndex) return;
    const page = this.vd.pages[index];
    if (!page) return;

    // ⭐ 切集前先按**旧 epId** 把这一集的进度落库一次。
    //   必须放在改动 epId_ / release() 之前：否则 epId_ 已指向新集、ct 又被播放器重置成 0，
    //   上报就退化成"新集 0 秒"，而 B 站整季只有一条记录，会把上一集的位置直接清零
    //   （详见 reportPgcHeartbeat 的说明）。放这里还能把最多 15s 的心跳间隔损失补回来。
    if (this.isPgc_ && this.epId_ > 0 && this.ct >= MIN_HEARTBEAT_PROGRESS_SEC) {
      try {
        await this.reportPgcHeartbeat(this.ct);
        logInfo(`[VideoPlayer] 切集前落库上一集进度: epId=${this.epId_}, ${Math.floor(this.ct)}秒`);
      } catch (e) {
        logError(`[VideoPlayer] 切集前落库上一集进度失败: ${errMsg(e)}`);
      }
    }

    // 释放当前播放器
    this.release();

    this.currentPageIndex = index;
    this.vi.cid = page.cid;
    // ⭐ PGC 选集：同步更新 epId_（取流用）与评论 oid（vd.aid=分集 aid）
    if (this.isPgc_) {
      const newEpId = index >= 0 && index < this.pgcEpIds_.length ? this.pgcEpIds_[index] : 0;
      const newEpAid = index >= 0 && index < this.pgcAids_.length ? this.pgcAids_[index] : 0;
      if (newEpId > 0) {
        this.epId_ = newEpId;
        logInfo(`[VideoPlayer] PGC 切集: 第${index + 1}话 epId=${this.epId_}, cid=${this.vi.cid}, 评论oid=${newEpAid}`);
      }
      // ArkTS 不允许对象展开，显式重建 vd 并更新 aid
      const curVd = this.vd;
      if (curVd) {
        const newVd: VideoDetail = {
          bvid: curVd.bvid,
          aid: newEpAid,  // 番剧评论 oid = 分集 aid
          title: curVd.title,
          desc: curVd.desc,
          pic: curVd.pic,
          pubdate: curVd.pubdate,
          ctime: curVd.ctime,
          duration: curVd.duration,
          owner: curVd.owner,
          stat: curVd.stat,
          cid: curVd.cid,
          pages: curVd.pages,
          req_user: curVd.req_user
        };
        this.vd = newVd;
      }
      // 切集后评论需要重新加载（oid 变了）
      this.commentCursor = 0;
      this.commentDataSource.clear();
      if (newEpAid > 0) {
        this.loadC(newEpAid);
      }
    }
    // ⭐ 切集：清掉上一集的进度，改由新一集的 playurl 续播点恢复（否则会把上一集的位置带过来）
    this.initialProgress_ = 0;
    // ⭐ 进度与心跳基准一并归零：新集在真正播到阈值前，绝不能带着上一集的秒数参与任何上报
    //   （PGC 整季共用一条历史记录，带错秒数会覆盖掉正确位置）
    this.ct = 0;
    this.lastHeartbeatTime = 0;
    // 重新加载视频
    await this.initP();
  }

  // ⭐ 格式化时长
  private formatDuration(seconds: number): string {
    const min = Math.floor(seconds / 60);
    const sec = seconds % 60;
    return `${min}:${sec.toString().padStart(2, '0')}`;
  }

  private opacityToHexAlpha(opacity: number): string {
    const clamped = Math.max(0, Math.min(100, opacity));
    const hex = Math.round(clamped / 100 * 255).toString(16).toUpperCase();
    return hex.length < 2 ? '0' + hex : hex;
  }

  private getCommentSelectedBg(): string {
    if (this.cardCustomColor && this.cardCustomColor !== '#007DFF') {
      if (this.cardTransparentStyle) {
        return '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1);
      }
      return this.cardCustomColor;
    }
    if (this.cardTransparentStyle) {
      return this.isDarkMode
        ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
        : `rgba(255,255,255,${this.cardBgOpacity / 100})`;
    }
    return this.isDarkMode ? '#1A1A1A' : '#E0E0E0';
  }

  private getComponentBg(componentEnabled: boolean): string {
    if (this.cardCustomColor && this.cardCustomColor !== '#007DFF') {
      if (this.cardTransparentStyleVideo && componentEnabled) {
        return '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1);
      }
      return this.cardCustomColor;
    }
    if (this.cardTransparentStyleVideo && componentEnabled) {
      return this.isDarkMode
        ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
        : `rgba(255,255,255,${this.cardBgOpacity / 100})`;
    }
    return this.isDarkMode ? '#1A1A1A' : '#E0E0E0';
  }

  private getCommentSelectedBorder(): BorderOptions {
    if (this.cardTransparentStyle) {
      return {
        width: this.cardBorderWidth,
        color: this.cardBorderFollowTheme
          ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1))
          : (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)')
      };
    }
    return { width: 0, color: Color.Transparent };
  }

  private getComponentBorder(componentEnabled: boolean): BorderOptions {
    if (this.cardTransparentStyleVideo && componentEnabled) {
      return {
        width: this.cardBorderWidth,
        color: this.cardBorderFollowTheme
          ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1))
          : (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)')
      };
    }
    return { width: 0, color: Color.Transparent };
  }

  private getCardContainerBg(componentEnabled: boolean): string {
    if (this.cardCustomColor && this.cardCustomColor !== '#007DFF') {
      if (this.cardTransparentStyleVideo && componentEnabled) {
        return '#' + this.opacityToHexAlpha(this.cardBgOpacity) + this.cardCustomColor.slice(1);
      }
      return this.cardCustomColor;
    }
    if (this.cardTransparentStyleVideo && componentEnabled) {
      return this.isDarkMode
        ? `rgba(0,0,0,${this.cardBgOpacity / 100})`
        : `rgba(255,255,255,${this.cardBgOpacity / 100})`;
    }
    return this.isDarkMode ? '#2C2C2C' : '#E8E8E8';
  }

  private getCardContainerBorder(componentEnabled: boolean): BorderOptions {
    if (this.cardTransparentStyleVideo && componentEnabled) {
      return {
        width: this.cardBorderWidth,
        color: this.cardBorderFollowTheme
          ? ('#' + this.opacityToHexAlpha(this.cardBorderOpacity) + this.customThemeColor.slice(1))
          : (this.isDarkMode ? `rgba(255,255,255,${this.cardBorderOpacity / 100})` : 'rgba(255,255,255,0.25)')
      };
    }
    return { width: 0, color: Color.Transparent };
  }

  private async saveVideoFloatBtnPrefs(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('videoShrinkBtnSide', this.videoShrinkBtnSide);
      await pref.put('videoShrinkBtnY', this.videoShrinkBtnY);
      await pref.put('videoLightBtnSide', this.videoLightBtnSide);
      await pref.put('videoLightBtnY', this.videoLightBtnY);
      await pref.flush();
    } catch (e) {
      logError('保存视频页悬浮按钮位置失败', e);
    }
  }

  // ⭐ 持久化缓存提示条拖拽位置
  private async saveCacheHintPrefs(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const pref = await preferences.getPreferences(context, 'my_app_settings');
      await pref.put('cacheHintLeft', this.cacheHintLeft);
      await pref.put('cacheHintBottom', this.cacheHintBottom);
      await pref.flush();
    } catch (e) {
      logError('保存缓存提示条位置失败', e);
    }
  }
}
