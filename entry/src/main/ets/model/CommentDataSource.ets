import { ObservableComment } from './ObservableComment';
import { logInfo, logWarn, logError } from '../utils/Logger';

/**
 * 评论数据源类
 * 实现 IDataSource 接口，用于 LazyForEach 懒加载
 */
export class CommentDataSource implements IDataSource {
  private comments: ObservableComment[] = [];
  private listeners: DataChangeListener[] = [];

  /**
   * 获取数据总数
   */
  public totalCount(): number {
    return this.comments.length;
  }

  /**
   * 获取指定索引的数据
   */
  public getData(index: number): ObservableComment {
    if (index < 0 || index >= this.comments.length) {
      logError(`[CommentDataSource] getData: 索引越界 index=${index}, length=${this.comments.length}`);
      // 返回一个空的 ObservableComment 实例，避免返回 undefined
      return new ObservableComment();
    }
    return this.comments[index];
  }

  /**
   * 注册数据变化监听器
   */
  public registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  /**
   * 注销数据变化监听器
   */
  public unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /**
   * 通知数据重新加载
   */
  public notifyDataReload(): void {
    this.listeners.forEach(listener => {
      listener.onDataReloaded();
    });
  }

  /**
   * 通知数据添加（在末尾添加）
   */
  public notifyDataAdd(count: number): void {
    this.listeners.forEach(listener => {
      listener.onDataAdded(this.comments.length - count);
    });
  }

  /**
   * 通知数据变化（指定索引）
   */
  public notifyDataChange(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataChanged(index);
    });
  }

  /**
   * 通知数据删除
   */
  public notifyDataDelete(index: number): void {
    this.listeners.forEach(listener => {
      listener.onDataDeleted(index);
    });
  }

  /**
   * 设置评论数据（用于首次加载或刷新）
   */
  public setComments(comments: ObservableComment[]): void {
    this.comments = this.dedupeByRpid(comments);
    this.notifyDataReload();
  }

  /**
   * 追加评论数据（用于加载更多）
   */
  public appendComments(newComments: ObservableComment[]): void {
    const startIndex = this.comments.length;
    this.comments = this.dedupeByRpid(this.comments.concat(newComments));
    this.notifyDataAdd(this.comments.length - startIndex);
  }

  /** ⭐ 按 rpid 去重（B 站分页偶尔返回重复评论；重复 rpid 会使 LazyForEach key 冲突，导致条目与数据错位） */
  private dedupeByRpid(list: ObservableComment[]): ObservableComment[] {
    const seen = new Set<number>();
    const out: ObservableComment[] = [];
    for (const c of list) {
      if (seen.has(c.rpid)) continue;
      seen.add(c.rpid);
      out.push(c);
    }
    return out;
  }

  /**
   * 更新指定索引的评论
   */
  public updateComment(index: number, comment: ObservableComment): void {
    if (index >= 0 && index < this.comments.length) {
      this.comments[index] = comment;
      this.notifyDataChange(index);
    }
  }

  /**
   * 获取所有评论（用于兼容旧代码）
   */
  public getAllComments(): ObservableComment[] {
    return this.comments;
  }

  /**
   * 根据rpid查找评论索引
   */
  public findCommentIndex(rpid: number): number {
    return this.comments.findIndex(c => c.rpid === rpid);
  }

  /**
   * 根据root/dialog/rpid查找评论索引（用于消息通知跳转定位）
   * comment_root_id 可能对应评论的 rpid、root 或 dialog 字段
   */
  public findCommentIndexByRoot(rootId: number): number {
    return this.comments.findIndex(c => c.rpid === rootId || c.root === rootId || c.dialog === rootId);
  }

  /**
   * 根据rpid获取评论
   */
  public getCommentByRpid(rpid: number): ObservableComment | undefined {
    return this.comments.find(c => c.rpid === rpid);
  }

  /**
   * 清空数据
   */
  public clear(): void {
    this.comments = [];
    this.notifyDataReload();
  }
}
