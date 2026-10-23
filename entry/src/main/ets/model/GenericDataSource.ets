/**
 * 通用数据源类，实现 IDataSource 接口，用于 LazyForEach 懒加载
 * 支持泛型 T，可被不同页面复用（RecommendItem / WatchHistoryItem / UpSpaceVideoItem 等）
 */
export class GenericDataSource<T> implements IDataSource {
  private data: T[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): T {
    return this.data[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  notifyDataReload(): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }

  notifyDataAdd(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataAdd(index);
    });
  }

  notifyDataDelete(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataDelete(index);
    });
  }

  notifyDataChange(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataChange(index);
    });
  }

  /** 完全替换全部数据 */
  reloadItems(allItems: T[]): void {
    this.data = allItems;
    this.notifyDataReload();
  }

  /** 追加一批数据 */
  addItems(newItems: T[]): void {
    const startIdx = this.data.length;
    this.data.push(...newItems);
    this.notifyDataAdd(startIdx);
  }

  /** 在指定位置之后插入 */
  insertItems(index: number, items: T[]): void {
    this.data.splice(index, 0, ...items);
    this.notifyDataAdd(index);
  }

  /** 删除单个元素（通过谓词匹配第一个） */
  removeItem(predicate: (item: T) => boolean): boolean {
    const idx = this.data.findIndex(predicate);
    if (idx >= 0) {
      this.data.splice(idx, 1);
      this.notifyDataDelete(idx);
      return true;
    }
    return false;
  }

  /** 删除所有满足谓词的元素（从后往前遍历，保持下标正确） */
  removeItems(predicate: (item: T) => boolean): number {
    let removed = 0;
    for (let i = this.data.length - 1; i >= 0; i--) {
      if (predicate(this.data[i])) {
        this.data.splice(i, 1);
        this.notifyDataDelete(i);
        removed++;
      }
    }
    return removed;
  }

  /** 获取原始数组引用（用于只读遍历，不触发通知） */
  getRawItems(): T[] {
    return this.data;
  }

  /** 直接设置原始数组（不触发通知，适合初始化） */
  setRawItems(items: T[]): void {
    this.data = items;
  }
}
