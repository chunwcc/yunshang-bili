/**
 * Logger.ts
 * 日志统一封装 — 将 console.* 迁移到 hilog（HarmonyOS 官方推荐）
 * 固定 format 为 '%{public}s'，原始内容作为参数传入，规避 hilog 的 % 占位符陷阱
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appendErrorLog } from './ErrorLogCollector';

const DOMAIN = 0x0000;
const TAG = 'Bilibili';

/**
 * 输出 INFO 级别日志
 * @param args 任意数量参数，以空格连接后输出
 */
export function logInfo(...args: Object[]): void {
  const msg = args.join(' ');
  hilog.info(DOMAIN, TAG, '%{public}s', msg);
  appendErrorLog('INFO', TAG, msg);
}

/**
 * 输出 WARN 级别日志
 * @param args 任意数量参数，以空格连接后输出
 */
export function logWarn(...args: Object[]): void {
  const msg = args.join(' ');
  hilog.warn(DOMAIN, TAG, '%{public}s', msg);
  appendErrorLog('WARN', TAG, msg);
}

/**
 * 输出 ERROR 级别日志
 * @param args 任意数量参数，以空格连接后输出
 */
export function logError(...args: Object[]): void {
  const msg = args.join(' ');
  hilog.error(DOMAIN, TAG, '%{public}s', msg);
  appendErrorLog('ERROR', TAG, msg);
}

/**
 * 错误对象转可读字符串
 * ⚠️ 不要用 JSON.stringify(err)：对 Error 会返回 {}，看不到 message/code
 */
export function errMsg(err: Object): string {
  if (err instanceof Error) {
    const e = err as Error;
    return e.message || String(err);
  }
  return String(err);
}
