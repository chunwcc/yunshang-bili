/**
 * EntryFormAbility.ets
 * 播控卡片 ExtensionAbility
 * 在 onAddForm 时将 formId 写入 RDB，供主进程查询
 */
import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import FormUtils from '../utils/FormUtils';
import { FormRdbHelper } from '../database/FormRdbHelper';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    if (!want || !want.parameters) {
      return formBindingData.createFormBindingData('');
    }

    const formId: string = (want.parameters[formInfo.FormParam.IDENTITY_KEY] as string) || '';
    const formName: string = (want.parameters[formInfo.FormParam.NAME_KEY] as string) || '';
    const formDimension: string = (want.parameters[formInfo.FormParam.DIMENSION_KEY] as string) || '2*2';

    // 保存到 RDB（跨进程共享）
    if (formId && formName) {
      FormRdbHelper.getInstance().insertForm(this.context, {
        formId: formId,
        formName: formName,
        formDimension: formDimension,
      });
    }

    // 推送 isNeedRequestUpdate 标记
    if (formId) {
      FormUtils.updateCardNeedUpdate(formId, true);
    }

    return formBindingData.createFormBindingData({
      'formId': formId,
      'title': 'Bilibili',
      'cover': '',
      'isPlay': false,
      'currentTime': 0,
      'duration': 0,
      'hasPlayer': false,
      'imageColorHex': '18191d',
      'imageColor': 'rgba(76, 72, 68, 1)',
    });
  }

  onRemoveForm(formId: string): void {
    if (formId) {
      FormRdbHelper.getInstance().deleteForm(this.context, formId);
    }
  }
}
