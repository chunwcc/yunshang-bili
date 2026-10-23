/**
 * 动画工具 - 提供全局动画启用/禁用的统一检查
 *
 * 在 PersonalizationPage 中设置 AppStorage('da') 来控制全局动画开关。
 * 各组件在使用 animateTo 前应调用 isAnimationEnabled() 检查。
 */
export function isAnimationEnabled(): boolean {
  const disabled: boolean = AppStorage.get<boolean>('da') ?? false;
  return !disabled;
}

/**
 * 禁用所有动画（强制设置 da=true 并持久化到 Preferences）
 * 由 PersonalizationPage 开关调用
 */
export function disableAllAnimations(): void {
  AppStorage.set('da', true);
}

/**
 * 启用所有动画
 */
export function enableAllAnimations(): void {
  AppStorage.set('da', false);
}
