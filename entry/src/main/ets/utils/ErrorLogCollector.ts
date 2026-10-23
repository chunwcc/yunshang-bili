/**
 * ErrorLogCollector.ts
 * 错误日志收集器 — 将运行时错误写入文件，供"关于软件→提取错误日志"读取
 * 文件轮转：超过 2MB 重命名为 error_log_old.txt，重新开始
 */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';

const DOMAIN = 0x0000;
const TAG = 'ErrLogCollector';
const MAX_FILE_SIZE = 2 * 1024 * 1024;

let appContext: common.Context | null = null;

/**
 * ⭐ 停写窗口：本机 filesDir 不可写时（实测 `appendErrorLog failed: ... No such file or directory`），
 * 原实现每次日志都要做 accessSync→statSync→openSync 三次**同步失败 syscall + 抛异常**（异常开销更大），
 * 实测每条日志约 1ms、单次动态页加载 69 次失败。这里失败后短暂停写，不再逐条重试。
 */
let writeDisabledUntil = 0;
const WRITE_RETRY_BACKOFF_MS = 30000;

/** 下次做"超限轮转"检查的时间（原来每条日志都 statSync 一次，改为每 10s 一次） */
let nextSizeCheckAt = 0;
const SIZE_CHECK_INTERVAL_MS = 10000;

export function setErrorLogContext(context: common.Context): void {
  appContext = context;
  // ⭐ 上下文换了（冷启动/切换）→ 清掉停写状态，重新尝试写盘
  writeDisabledUntil = 0;
  nextSizeCheckAt = 0;
}

function getLogFilePath(): string | null {
  if (!appContext) return null;
  return appContext.filesDir + '/error_log.txt';
}

function getOldLogFilePath(): string | null {
  if (!appContext) return null;
  return appContext.filesDir + '/error_log_old.txt';
}

/**
 * 时间戳：手写格式化。
 * ⚠️ 原来用 `new Date().toLocaleString('zh-CN', {hour12:false})`，Intl 解析 locale/时区在本机是
 *   每次日志都要付的固定成本（实测每条 ~1ms 量级）→ 改为直接拼字符串，格式保持 `YYYY/MM/DD HH:mm:ss`。
 */
function nowStamp(): string {
  const d = new Date();
  const p = (n: number): string => (n < 10 ? '0' + n : n.toString());
  return `${d.getFullYear()}/${p(d.getMonth() + 1)}/${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

export function appendErrorLog(level: string, tag: string, msg: string): void {
  const now = Date.now();
  // ⭐ 已知不可写（或刚新建目录尚未生效）→ 直接返回，避免每条日志都跑一遍失败的文件操作
  if (now < writeDisabledUntil) return;
  const filePath = getLogFilePath();
  if (!filePath) return;
  try {
    const line = `[${nowStamp()}] [${level}] [${tag}] ${msg}\n`;

    // 轮转检查：每 10s 最多一次（openSync(CREATE) 本身保证文件存在，不再需要 accessSync 预检）
    if (now >= nextSizeCheckAt) {
      nextSizeCheckAt = now + SIZE_CHECK_INTERVAL_MS;
      try {
        const stat = fileIo.statSync(filePath);
        if (stat.size > MAX_FILE_SIZE) {
          const oldPath = getOldLogFilePath();
          if (oldPath) {
            try { fileIo.unlinkSync(oldPath); } catch (_) {}
            try { fileIo.renameSync(filePath, oldPath); } catch (_) {}
          }
        }
      } catch (_) {
        // 文件还不存在（首次写入）→ 正常
      }
    }

    const flag = fileIo.OpenMode.APPEND | fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY;
    const file = fileIo.openSync(filePath, flag);
    try {
      fileIo.writeSync(file.fd, line);
    } finally {
      fileIo.closeSync(file);
    }
  } catch (e) {
    // 停写一段时间，避免"每次日志 = 3 次失败 syscall + 异常"持续吃主线程
    writeDisabledUntil = now + WRITE_RETRY_BACKOFF_MS;
    hilog.error(DOMAIN, TAG, 'appendErrorLog failed: %{public}s', String(e));
  }
}

export function readErrorLog(): string {
  try {
    const filePath = getLogFilePath();
    if (!filePath) return '日志路径不可用';

    const decoder = util.TextDecoder.create('utf-8');
    let result = '';

    const oldPath = getOldLogFilePath();
    if (oldPath) {
      try {
        const stat = fileIo.statSync(oldPath);
        const file = fileIo.openSync(oldPath, fileIo.OpenMode.READ_ONLY);
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(file.fd, buf);
        fileIo.closeSync(file);
        result += '=== 旧日志 ===\n' + decoder.decodeWithStream(new Uint8Array(buf)) + '\n';
      } catch (_) {}
    }

    try {
      const stat = fileIo.statSync(filePath);
      const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      result += '=== 最新日志 ===\n' + decoder.decodeWithStream(new Uint8Array(buf));
    } catch (_) {}

    return result || '暂无错误日志';
  } catch (e) {
    return '读取日志失败: ' + String(e);
  }
}

export function clearErrorLog(): void {
  try {
    const filePath = getLogFilePath();
    if (filePath) { try { fileIo.unlinkSync(filePath); } catch (_) {} }
    const oldPath = getOldLogFilePath();
    if (oldPath) { try { fileIo.unlinkSync(oldPath); } catch (_) {} }
  } catch (_) {}
}

export function getErrorLogSize(): number {
  let total = 0;
  try {
    const filePath = getLogFilePath();
    if (filePath) { try { total += fileIo.statSync(filePath).size; } catch (_) {} }
    const oldPath = getOldLogFilePath();
    if (oldPath) { try { total += fileIo.statSync(oldPath).size; } catch (_) {} }
  } catch (_) {}
  return total;
}