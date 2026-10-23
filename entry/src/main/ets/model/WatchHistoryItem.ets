// WatchHistoryItem.ets - 观看历史数据模型（适配B站API）

/**
 * B站视频UP主信息
 */
export interface BiliOwner {
  mid: number;             // UP主mid
  name: string;            // UP主名称
  face: string;            // UP主头像
}

/**
 * B站视频统计信息
 */
export interface BiliStat {
  view: number;            // 播放量
  danmaku: number;         // 弹幕数
}

/**
 * B站历史记录API返回的单条数据结构
 * 注意：B站返回的是视频详情格式，不是专门的历史记录格式
 */
export interface HistoryItem {
  // 视频基本信息
  aid?: number;            // 视频aid
  bvid?: string;           // 视频bvid
  title: string;           // 视频标题
  pic?: string;            // 封面URL（视频详情格式）
  cover?: string;          // 封面URL（历史记录格式）
  covers?: string[];       // 封面URL数组
  duration?: number;       // 视频总时长（秒）
  
  // UP主信息（视频详情格式）
  owner?: BiliOwner;
  
  // 历史记录特有字段
  uri?: string;            // bvid://BVxxxxx 格式
  history?: HistoryDetail; // 历史详情（包含进度）
  kid?: number;            // 视频oid（aid）- 历史记录格式
  oid?: number;            // ⭐ 目标 avID（**不是 cid**；cid 在 history.cid）
  view_at?: number;        // 观看时间（时间戳）
  progress?: number;       // ⭐ 播放进度（秒，**顶层字段**；-1 表示已看完）
  
  // 兼容旧格式的字段
  author_name?: string;    // UP主名称
  author_face?: string;    // UP主头像
  author_mid?: number;     // UP主mid
  
  // 其他字段
  badge?: string;          // 徽章文本
  show_title?: string;     // 显示标题
  dt?: number;             // 业务类型（2=视频）
  stat?: BiliStat;         // 统计信息
  // ⭐ 以下均为 /x/v2/history 记录【顶层】字段（实测 2026-09-14 导出原样核对）
  /** ⭐ 真正的 cid（历史记录顶层直接给，不在 history 对象里） */
  cid?: number;
  /** ⭐ 业务类型（顶层）：'archive'=投稿，'pgc'=番剧/影视，'live'/'article' 等 */
  business?: string;
  /** ⭐ 播放业务类型：3=投稿 4=番剧/影视 10=课程 */
  type?: number;
  /** 番剧子类型（0=番剧, 1=电影, 2=纪录片, 3=国创, 4=综艺, 5=电视剧） */
  sub_type?: number;
  /** ⭐ 番剧扩展信息：PGC 记录的分集 id / 季 id 都在这里（无需再靠 bvid 反查） */
  bangumi?: HistoryBangumi;
  /** ⭐ 分 P 信息（实测历史接口顶层带 page.cid，可作为 cid 的备用来源） */
  page?: HistoryVideoPage;
}

/** 历史记录里的分 P 信息（顶层 page 字段） */
export interface HistoryVideoPage {
  cid?: number;
  page?: number;
  part?: string;
  duration?: number;
}

/**
 * ⭐ 历史记录里的番剧扩展块（/x/v2/history 顶层 bangumi 字段）
 * 实测：ep733335 的记录中 `bangumi.ep_id=733335`、`bangumi.season.season_id=28747`，
 * 而 `history` 对象**根本不存在** —— 所以 epId/seasonId 应从这里的取。
 */
export interface HistoryBangumi {
  ep_id?: number;
  title?: string;
  long_title?: string;
  /** ⭐ PGC 记录的顶层 kid 也等于 season_id（实测 kid=28747） */
  season?: HistoryBangumiSeason;
}

/** 番剧季信息（嵌套在 HistoryBangumi 中） */
export interface HistoryBangumiSeason {
  season_id?: number;
  title?: string;
  season_type?: number;
  is_finish?: number;
  newest_ep_id?: number;
  newest_ep_index?: string;
}

/**
 * 历史详情（嵌套在HistoryItem中）
 */
export interface HistoryDetail {
  /** ⭐ 目标 id：稿件/剧集为 avID（**不是 cid**），直播为 roomId，文章为 cvID，文集为 rlID */
  oid?: number;
  /** ⭐ 观看到的 cid（稿件/剧集共用；才是真正的 cid） */
  cid?: number;
  /** 兼容旧字段（B 站 history 对象内不含 progress/duration，见 fromBilibiliHistory 注释） */
  progress?: number;
  duration?: number;
  /** ⭐ 业务类型（'pgc'=番剧/影视，'archive'=投稿视频，'live'/'article'）：B 站云端历史用此字段识别 PGC */
  business?: string;
  /** ⭐ PGC 分集 id（番剧历史直接返回，无需解析 uri——history.epid 是正确字段） */
  epid?: number;
  /** 观看的分 P 序号（仅稿件视频） */
  page?: number;
}

/**
 * 历史列表分页信息
 */
export interface HistoryPage {
  pn: number;              // 页码
  ps: number;              // 每页数量
}

/**
 * 历史列表数据
 */
export interface HistoryData {
  list?: HistoryItem[];
  page?: HistoryPage;
}

/**
 * B站历史列表API响应结构
 * 注意：data可能是HistoryData对象，也可能是HistoryItem数组
 */
export interface HistoryListResponse {
  code: number;
  message: string;
  ttl: number;
  data?: HistoryData | HistoryItem[];
}

/**
 * 观看历史项（用于UI展示）
 * 将B站API返回的HistoryItem转换为本地展示模型
 */
export class WatchHistoryItem {
  id: number = 0;              // 本地ID（用于UI列表）
  aid: number = 0;             // 视频aid（用于删除）
  cid: number = 0;             // 视频cid
  bvid: string = '';           // 视频bvid
  title: string = '';          // 视频标题
  coverUrl: string = '';       // 封面URL
  ownerName: string = '';      // UP主名称
  ownerMid: number = 0;        // UP主mid
  ownerFace: string = '';      // UP主头像
  playProgress: number = 0;    // 播放进度(秒)
  totalDuration: number = 0;   // 总时长(秒)
  watchedAt: number = 0;       // 最后观看时间戳(秒)
  epId: number = 0;            // ⭐ PGC 分集 id（番剧历史恢复播放用，0=非 PGC）
  seasonId: number = 0;        // ⭐ PGC 季 id
  // ⭐ 是否 PGC（番剧/影视）记录：来自接口顶层 business==='pgc' / bangumi.ep_id / type===4。
  //   历史页用它决定"要不要在跳转前反查 epId"——非 PGC 记录绝不能反查，
  //   那是一次纯浪费的网络往返，且发生在 pushUrl 之前，直接拖慢进播放页。
  isPgc: boolean = false;

  /** 提取字符串开头的连续数字（解析 PGC uri 中的 ep/ss id），无数字返回 0 */
  static parseLeadingNumber(s: string): number {
    let num: number = 0;
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c >= 48 && c <= 57) {
        num = num * 10 + (c - 48);
      } else {
        break;
      }
    }
    return num;
  }

  /**
   * 从B站API返回的HistoryItem转换
   */
  static fromBilibiliHistory(item: HistoryItem): WatchHistoryItem {
    const historyItem = new WatchHistoryItem();

    // ⭐⭐ PGC（番剧/影视）识别 —— 必须先于 aid/bvid 解析，因为 PGC 记录的 kid 是 season_id 而非 aid
    //   实测导出 /x/v2/history 的 PGC 记录（ep733335）结构：
    //     { aid, bvid, cid, duration, progress, business:"pgc", type:4, sub_type:0, kid:28747,
    //       bangumi: { ep_id:733335, season: { season_id:28747, season_type:4 } } }
    //   —— **没有 history 对象**！分集/季都在 bangumi 里，business/type/kid 在顶层。
    //   旧实现只认 history.epid，拿不到就靠 bvid 反查 epId，且**从不解析 seasonId**，
    //   于是 seasonId=0 → PGC 心跳缺 sid → B 站静默丢弃进度（云端 progress 恒为 0）。
    const biz: string = item.business ?? '';
    const bangumiEpId: number = item.bangumi?.ep_id ?? 0;
    const bangumiSeasonId: number = item.bangumi?.season?.season_id ?? 0;
    const isPgcRecord: boolean = biz === 'pgc' || bangumiEpId > 0 || (item.type ?? 0) === 4;
    historyItem.isPgc = isPgcRecord;

    // 获取aid（兼容两种格式）
    // ⚠️ kid 只在【非 PGC】时才能当 aid —— PGC 记录的 kid 是 season_id（实测 kid=28747）
    historyItem.aid = item.aid || (isPgcRecord ? 0 : item.kid) || 0;

    // 获取bvid
    if (item.bvid) {
      historyItem.bvid = item.bvid;
    } else if (item.uri && item.uri.startsWith('bvid://')) {
      historyItem.bvid = item.uri.replace('bvid://', '');
    } else if (historyItem.aid > 0) {
      // 如果没有bvid但有aid，后续可以通过API转换
      historyItem.bvid = '';  // 播放时会通过aid查找
    }

    // epId：bangumi.ep_id（权威）> history.epid > uri 中的 /ep<数字>
    const pgcEpid: number = bangumiEpId > 0 ? bangumiEpId : (item.history?.epid ?? 0);
    if (pgcEpid > 0) {
      historyItem.epId = pgcEpid;
    }
    // ⭐ 只有拿到 epId 时才清空 bvid（逼历史页走 PGC 路径；分集的 av bvid 当 UGC 取流会 -404）。
    //   拿不到 epId 时保留 bvid，历史页还能靠 bvid 反查 epId。
    if (isPgcRecord && historyItem.epId > 0) {
      historyItem.bvid = '';
    }
    // seasonId：bangumi.season.season_id（权威）> 顶层 kid（PGC 记录的 kid 就是 season_id）> uri 中的 /ss<数字>
    if (bangumiSeasonId > 0) {
      historyItem.seasonId = bangumiSeasonId;
    } else if (isPgcRecord && (item.kid ?? 0) > 0) {
      historyItem.seasonId = item.kid as number;
    }
    const uriRaw: string = item.uri || '';
    const ssIdx = uriRaw.indexOf('/ss');
    if (ssIdx >= 0) {
      const uriSeasonId: number = WatchHistoryItem.parseLeadingNumber(uriRaw.substring(ssIdx + 3));
      if (uriSeasonId > 0) {
        historyItem.seasonId = uriSeasonId;
      }
    }
    const epIdx = uriRaw.indexOf('/ep');
    if (epIdx >= 0) {
      const uriEpId: number = WatchHistoryItem.parseLeadingNumber(uriRaw.substring(epIdx + 3));
      if (uriEpId > 0) {
        historyItem.epId = uriEpId;
      }
    }
    
    // 基本信息
    // ⭐ cid 优先级：顶层 cid（实测历史接口就在顶层）> history.cid > oid
    //   ⚠️ oid 是 avID/epId，**不是 cid**，只能当最后的兜底
    const topCid: number = item.cid ?? item.page?.cid ?? 0;
    if (topCid > 0) {
      historyItem.cid = topCid;
    } else if ((item.history?.cid ?? 0) > 0) {
      historyItem.cid = item.history?.cid as number;
    } else {
      historyItem.cid = item.oid || 0;
    }
    historyItem.title = item.title || item.show_title || '';
    
    // 封面（兼容多种格式）
    if (item.covers && item.covers.length > 0) {
      historyItem.coverUrl = item.covers[0];
    } else if (item.pic) {
      // 视频详情格式使用pic字段
      historyItem.coverUrl = item.pic;
    } else {
      historyItem.coverUrl = item.cover || '';
    }
    
    // UP主信息（兼容两种格式）
    if (item.owner) {
      // 视频详情格式
      historyItem.ownerName = item.owner.name || '';
      historyItem.ownerMid = item.owner.mid || 0;
      historyItem.ownerFace = item.owner.face || '';
    } else {
      // 历史记录格式
      historyItem.ownerName = item.author_name || '';
      historyItem.ownerMid = item.author_mid || 0;
      historyItem.ownerFace = item.author_face || '';
    }
    
    // ⭐⭐ 播放进度/总时长：B 站历史接口（/x/v2/history 与 /x/web-interface/history/cursor 同构）
    //   这两个字段在记录【顶层】（progress 单位为秒，-1 表示已看完；duration 为该集/该稿时长）；
    //   实测导出的记录里**根本没有 history 对象**（cid/business/type/kid/bangumi 都在顶层），
    //   旧实现写的是"只要 history 存在就只读 history.progress"→ 恒为 0：
    //   历史列表进度环不渲染、且进入播放页时 initialProgress=0 → 从 0:00 开始。
    const rawProgress: number = item.progress ?? item.history?.progress ?? 0;
    const rawDuration: number = item.duration ?? item.history?.duration ?? 0;
    historyItem.totalDuration = rawDuration > 0 ? rawDuration : 0;
    // progress = -1（已看完）→ 等价于看完整个时长，进度环走满且不再续播
    historyItem.playProgress = rawProgress >= 0
      ? rawProgress
      : historyItem.totalDuration;

    // 观看时间（B站返回的是秒级时间戳）
    historyItem.watchedAt = item.view_at || 0;
    
    return historyItem;
  }

  /** 进度百分比文本 */
  get progressText(): string {
    if (this.totalDuration <= 0) return '已观看';
    const pct = Math.round((this.playProgress / this.totalDuration) * 100);
    if (pct >= 95) return '已看完';
    return `已看 ${pct}%`;
  }

  /** 格式化观看时间 */
  get watchedAtText(): string {
    if (this.watchedAt <= 0) return '';
    // B站返回的是秒级时间戳，需要转换为毫秒
    const d = new Date(this.watchedAt * 1000);
    const now = new Date();
    const pad = (n: number) => n.toString().padStart(2, '0');
    
    if (d.toDateString() === now.toDateString()) {
      return `今天 ${pad(d.getHours())}:${pad(d.getMinutes())}`;
    }
    
    const yesterday = new Date(now);
    yesterday.setDate(yesterday.getDate() - 1);
    if (d.toDateString() === yesterday.toDateString()) {
      return `昨天 ${pad(d.getHours())}:${pad(d.getMinutes())}`;
    }
    
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  /** 格式化时长 */
  get durationText(): string {
    const duration = this.totalDuration;
    if (duration <= 0) return '';
    const minutes = Math.floor(duration / 60);
    const seconds = Math.floor(duration % 60);
    if (minutes >= 60) {
      const hours = Math.floor(minutes / 60);
      const remainMinutes = minutes % 60;
      return `${hours}:${remainMinutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
    }
    return `${minutes}:${seconds.toString().padStart(2, '0')}`;
  }
}
