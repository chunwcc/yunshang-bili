/**
 * FormUtils.ts
 * 播控卡片管理工具类（单例）
 * 使用 RDB 跨进程查询 formId（与官方 MusicCard 示例一致）
 */
import { formBindingData, formProvider } from '@kit.FormKit';
import { logInfo, logWarn, logError } from './Logger';
import { BusinessError } from '@kit.BasicServicesKit';
import { FormRdbHelper } from '../database/FormRdbHelper';

const TAG = 'FormUtils';

class FormUtils {
  async queryPlayControlCards(context: Context): Promise<string[]> {
    const records = await FormRdbHelper.getInstance().queryFormByName(context, 'PlayControlCard');
    return records.map((r) => r.formId);
  }

  updateCardNeedUpdate(formId: string, needUpdate: boolean): void {
    this.updateForm(formId, { 'isNeedRequestUpdate': needUpdate });
  }

  async updatePlayControlCards(context: Context, isPlay: boolean, title: string, cover: string,
    currentTime: number, duration: number, hasPlayer: boolean): Promise<void> {
    const ids = await this.queryPlayControlCards(context);
    if (ids.length === 0) {
      return;
    }
    const formData: Record<string, Object> = {
      'isPlay': isPlay,
      'title': title || 'Bilibili',
      'cover': cover || '',
      'currentTime': currentTime,
      'duration': duration,
      'hasPlayer': hasPlayer,
      'imageColorHex': '18191d',
      'imageColor': 'rgba(76, 72, 68, 1)',
    };
    for (const formId of ids) {
      this.updateForm(formId, formData);
    }
  }

  async updateSingleCard(context: Context, formId: string): Promise<void> {
    const isPlay: boolean = AppStorage.get<boolean>('cardIsPlay') ?? false;
    const title: string = AppStorage.get<string>('cardTitle') ?? 'Bilibili';
    const cover: string = AppStorage.get<string>('cardCover') ?? '';
    const currentTime: number = AppStorage.get<number>('cardCurrentTime') ?? 0;
    const duration: number = AppStorage.get<number>('cardDuration') ?? 0;
    const hasPlayer: boolean = AppStorage.get<boolean>('cardHasPlayer') ?? false;

    this.updateForm(formId, {
      'isPlay': isPlay,
      'title': title,
      'cover': cover,
      'currentTime': currentTime,
      'duration': duration,
      'hasPlayer': hasPlayer,
      'imageColorHex': '18191d',
      'imageColor': 'rgba(76, 72, 68, 1)',
    });
  }

  async updateCardProgress(context: Context, currentTime: number, duration: number, isPlay: boolean): Promise<void> {
    const ids = await this.queryPlayControlCards(context);
    for (const formId of ids) {
      this.updateForm(formId, { 'currentTime': currentTime, 'duration': duration, 'isPlay': isPlay });
    }
  }

  async updateCardPlayStatus(context: Context, isPlay: boolean): Promise<void> {
    const ids = await this.queryPlayControlCards(context);
    for (const formId of ids) {
      this.updateForm(formId, { 'isPlay': isPlay });
    }
  }

  private updateForm(formId: string, updateData: Object): void {
    const formMsg = formBindingData.createFormBindingData(updateData);
    formProvider.updateForm(formId, formMsg).catch((error: BusinessError) => {
      if (error.code !== 16500002 && error.code !== 16501001) {
        logWarn(TAG, 'updateForm error:', error.code, error.message);
      }
    });
  }
}

export default new FormUtils();
