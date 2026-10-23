/**
 * 动态的「点赞状态」可观察对象
 *
 * ⭐ 为什么要单独抽一个对象，而不是把 liked 放进 ForEach 的 key：
 *    `ForEach` **只按 key 判等**，key 一变框架就销毁重建那一项（整张卡）——
 *    封面 Image 会被重新创建/重新加载，表现为**点个赞封面闪一下**（2026-09-18 实测）。
 *    把点赞状态挂在 @Observed 对象上、由 @ObjectLink 的子组件读取，
 *    框架只会刷新那个子组件，卡片其余部分（封面/正文/图片）完全不动。
 *
 * ⚠️ 因此 ForEach 的 key 必须是纯 idStr，**不要把 liked/count 拼进 key**。
 * 参照实现：model/ObservableComment.ets（同款 @Observed + @Track 写法）。
 */
@Observed
export class ObservableDynLike {
  @Track liked: boolean = false;
  @Track count: number = 0;

  constructor(liked: boolean, count: number) {
    this.liked = liked;
    this.count = count;
  }

  static from(liked: boolean, count: number): ObservableDynLike {
    return new ObservableDynLike(liked, count);
  }
}
