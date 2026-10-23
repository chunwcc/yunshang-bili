// RecommendItem.ets - 推荐/视频项数据模型

export class RecommendItem {
  id: string = '';           // bvid
  title: string = '';
  coverUrl: string = '';
  playCount: number = 0;
  danmakuCount: number = 0;
  likeCount: number = 0;     // 新增：点赞数
  ownerName: string = '';
  ownerFace: string = '';
  ownerMid: string = '';     // 新增：UP主 mid
  pubdate: number = 0;
  cid: number = 0;
  duration: number = 0;      // 新增：时长（秒）
  isFollowed: boolean = false; // B站搜索API自带关注状态（仅bili_user有效）
  // 直播专用
  online: number = 0;         // 观看人数
  // 番剧（PGC）专用
  pgcEpSize: number = 0;      // 集数（番剧搜索结果的 ep_size）
  pgcScore: number = 0;       // 评分（番剧搜索结果的 media_score.score）
  // ⭐ 番剧季 id（App 推荐 feed 的 bangumi 卡片 param 字段；>0 表示 PGC 卡片，跳转走 mediaId 入口）
  pgcSeasonId: number = 0;
  // ⭐ 番剧分集 ep_id（feed bangumi 卡片 param 的实际含义，实测：season_id/media_id 接口均 404，ep_id 接口命中）
  pgcEpId: number = 0;
  // App API 额外字段
  aid: number = 0;
  rcmdReason: string = '';    // 推荐理由
  cardGoto: string = '';      // 卡片类型

  constructor() {}

  static fromPopularApi(obj: Record<string, Object>): RecommendItem {
    const item = new RecommendItem();
    item.id = (obj['bvid'] as string) || '';
    item.title = (obj['title'] as string) || '';
    const pic = obj['pic'] as string;
    item.coverUrl = pic ? (pic.startsWith('http') ? pic : `https:${pic}`) : '';
    
    const stat = obj['stat'] as Record<string, number>;
    if (stat) {
      item.playCount = stat['view'] || 0;
      item.danmakuCount = stat['danmaku'] || 0;
      item.likeCount = stat['like'] || 0;
    }
    
    const owner = obj['owner'] as Record<string, Object>;
    if (owner) {
      item.ownerName = (owner['name'] as string) || '';
      item.ownerFace = (owner['face'] as string) || '';
      item.ownerMid = (owner['mid']?.toString()) || '';
    }
    
    item.pubdate = (obj['pubdate'] as number) || 0;
    item.duration = (obj['duration'] as number) || 0;
    
    // 获取 CID
    const pages = obj['pages'] as Array<Record<string, Object>>;
    if (pages && pages.length > 0) {
      item.cid = (pages[0]['cid'] as number) || 0;
    }
    if (!item.cid && obj['cid']) {
      item.cid = (obj['cid'] as number) || 0;
    }
    return item;
  }

  /**
   * ⭐ 解析 App 端推荐 API 返回的视频项
   * App API（https://app.bilibili.com/x/v2/feed/index）的返回格式与 Web API 不同：
   * - 封面在 `cover` 字段（非 pic）
   * - 播放/弹幕数在 `cover_left_text_1/2`（字符串格式）
   * - UP主信息在 `args.up_name` / `args.up_id`
   * - 视频时长在 `player_args.duration`（秒数）
   * - 没有单独的 `stat` / `owner` 对象
   */
  static fromAppApi(obj: Record<string, Object>): RecommendItem {
    const item = new RecommendItem();
    
    // 卡片类型过滤：跳过广告
    const cardGoto = (obj['card_goto'] as string) || (obj['goto'] as string) || '';
    item.cardGoto = cardGoto;
    
    // bvid / aid
    // ⚠️ App API 不返回 bvid 字段，只有 aid（在 player_args 中）
    const playerArgs = obj['player_args'] as Record<string, Object>;
    if (playerArgs) {
      item.aid = (playerArgs['aid'] as number) || 0;
      item.cid = (playerArgs['cid'] as number) || 0;
      item.duration = (playerArgs['duration'] as number) || 0;
    }
    // ⭐ 番剧卡片（card_goto=bangumi）：param 是分集 ep_id（实测柯南分集 5751661：
    //   season_id/media_id 接口均 -404，ep_id 接口命中）。此前把 ep_id 当 aid 传入
    //   播放页，被 initFromAid 解析成撞号的 UGC 视频
    if (cardGoto === 'bangumi') {
      const pgcParam = (obj['param'] as string) || '';
      const pgcId = parseInt(pgcParam) || 0;
      const uri = (obj['uri'] as string) || '';
      // uri 明确指向季时按季id；否则默认按分集id（feed 实测）
      if (uri.includes('bangumi/season/')) {
        item.pgcSeasonId = pgcId;
      } else {
        item.pgcEpId = pgcId;
      }
    }
    if (item.aid === 0 && item.pgcSeasonId === 0 && item.pgcEpId === 0) {
      const paramStr = (obj['param'] as string) || '';
      item.aid = parseInt(paramStr) || 0;
    }
    // id 作为唯一标识：普通视频用 aid 数字；番剧用 ss+分集/季id（非数字，防误入 UGC aid 解析）
    if (item.pgcSeasonId > 0 || item.pgcEpId > 0) {
      item.id = `ss${item.pgcSeasonId > 0 ? item.pgcSeasonId : item.pgcEpId}`;
    } else {
      item.id = item.aid > 0 ? item.aid.toString() : '';
      if (!item.id) {
        item.id = (obj['bvid'] as string) || '';
      }
    }
    
    // 标题
    item.title = (obj['title'] as string) || '';
    
    // 封面（App API 用 cover 而不是 pic）
    const cover = (obj['cover'] as string) || '';
    item.coverUrl = cover ? (cover.startsWith('http') ? cover : `https:${cover}`) : '';
    
    // args 中的 UP 主信息
    const args = obj['args'] as Record<string, Object>;
    if (args) {
      const upId = args['up_id'] as number;
      item.ownerMid = upId ? upId.toString() : '';
      item.ownerName = (args['up_name'] as string) || '';
    }
    
    // 播放/弹幕数（App API 以文字形式返回）
    const coverLeftText1 = (obj['cover_left_text_1'] as string) || '';
    const coverLeftText2 = (obj['cover_left_text_2'] as string) || '';
    item.playCount = RecommendItem.parseCountText(coverLeftText1);
    item.danmakuCount = RecommendItem.parseCountText(coverLeftText2);
    
    // 推荐理由
    const rcmdReason = obj['rcmd_reason'] as string;
    item.rcmdReason = rcmdReason || '';
    // 从推荐理由推断是否已关注
    item.isFollowed = rcmdReason === '已关注' || rcmdReason === '新关注';
    
    // 发布时间
    item.pubdate = (obj['pubdate'] as number) || 0;
    
    return item;
  }

  /**
   * 解析 App API 的统计数字文本
   * "10.5万" → 105000, "1234" → 1234, "" → 0
   */
  private static parseCountText(text: string): number {
    if (!text) return 0;
    const trimmed = text.trim();
    if (trimmed === '') return 0;
    
    // 万/亿单位处理
    if (trimmed.includes('万')) {
      const num = parseFloat(trimmed.replace('万', ''));
      return Math.round(num * 10000);
    }
    if (trimmed.includes('亿')) {
      const num = parseFloat(trimmed.replace('亿', ''));
      return Math.round(num * 100000000);
    }
    
    const num = parseInt(trimmed.replace(/,/g, ''));
    return isNaN(num) ? 0 : num;
  }
}