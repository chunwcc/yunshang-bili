import { CommentItem, CommentMember, CommentContent } from '../api/BilibiliApi';

/**
 * 可观察的评论数据模型
 * 将评论的运行时状态直接挂载到数据对象上，避免维护多个Map
 */
@Observed
export class ObservableComment {
  // 基础评论数据（使用 @Track 标记，因为会在 UI 中访问）
  @Track rpid: number = 0;
  @Track oid: number = 0;
  @Track type: number = 0;
  @Track mid: number = 0;
  @Track root: number = 0;
  @Track parent: number = 0;
  @Track dialog: number = 0;
  @Track count: number = 0;
  @Track rcount: number = 0;
  @Track state: number = 0;
  @Track fansgrade: number = 0;
  @Track attr: number = 0;
  @Track ctime: number = 0;
  @Track like: number = 0;
  @Track action: number = 0;
  @Track member: CommentMember | null = null;
  @Track content: CommentContent | null = null;
  @Track ipLocation: string = '';            // IP 属地，如 "上海"
  @Track replies: ObservableComment[] = [];

  // 运行时状态（使用 @Track 标记，实现细粒度更新）
  @Track expanded: boolean = false;           // 是否展开回复
  @Track replyPage: number = 1;               // 回复当前页码
  @Track hasMoreReplies: boolean = false;     // 是否还有更多回复
  @Track loadingReplies: boolean = false;     // 是否正在加载回复

  /**
   * 从 CommentItem 创建 ObservableComment
   */
  static from(item: CommentItem): ObservableComment {
    const obs = new ObservableComment();
    obs.rpid = item.rpid;
    obs.oid = item.oid;
    obs.type = item.type;
    obs.mid = item.mid;
    obs.root = item.root;
    obs.parent = item.parent;
    obs.dialog = item.dialog;
    obs.count = item.count;
    obs.rcount = item.rcount;
    obs.state = item.state;
    obs.fansgrade = item.fansgrade ?? 0;
    obs.attr = item.attr ?? 0;
    obs.ctime = item.ctime;
    obs.like = item.like;
    obs.action = item.action;
    obs.member = item.member;
    obs.content = item.content;
    // 属地可能出现在 ip_location / location / reply_control.location 三个位置，
    // 且可能自带 "IP属地:" 前缀（如 "IP属地：上海"），统一剥离只保留地区
    obs.ipLocation = (item.ip_location ?? item.location ?? item.reply_control?.location ?? '').replace(/^IP属地[:：]?\s*/, '');
    
    // 转换回复列表
    if (item.replies && item.replies.length > 0) {
      obs.replies = item.replies.map(reply => ObservableComment.from(reply));
    }
    
    // 判断是否还有更多回复需要加载
    obs.hasMoreReplies = item.rcount > (item.replies?.length ?? 0);
    
    return obs;
  }

  /**
   * 更新回复列表
   */
  updateReplies(newReplies: CommentItem[]): void {
    // 使用Map去重
    const replyMap = new Map<number, ObservableComment>();
    
    // 先添加新回复
    for (let i = 0; i < newReplies.length; i++) {
      replyMap.set(newReplies[i].rpid, ObservableComment.from(newReplies[i]));
    }
    
    // 再添加旧回复（补充可能遗漏的）
    for (let i = 0; i < this.replies.length; i++) {
      if (!replyMap.has(this.replies[i].rpid)) {
        replyMap.set(this.replies[i].rpid, this.replies[i]);
      }
    }
    
    this.replies = Array.from(replyMap.values());
    this.hasMoreReplies = this.rcount > this.replies.length;
  }

  /**
   * 转换回 CommentItem（用于API调用等场景）
   */
  toCommentItem(): CommentItem {
    const result: CommentItem = {
      rpid: this.rpid,
      oid: this.oid,
      type: this.type,
      mid: this.mid,
      root: this.root,
      parent: this.parent,
      dialog: this.dialog,
      count: this.count,
      rcount: this.rcount,
      state: this.state,
      fansgrade: this.fansgrade,
      attr: this.attr,
      ctime: this.ctime,
      like: this.like,
      action: this.action,
      member: this.member!,
      content: this.content!,
      ip_location: this.ipLocation !== '' ? this.ipLocation : undefined
    };
    
    // 转换回复列表
    if (this.replies.length > 0) {
      result.replies = [];
      for (let i = 0; i < this.replies.length; i++) {
        result.replies.push(this.replies[i].toCommentItem());
      }
    }
    
    return result;
  }
}
