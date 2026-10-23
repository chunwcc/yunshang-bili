// PreferencesUtil.ets - 数据持久化工具
import { preferences } from '@kit.ArkData';

class PreferencesUtil {
  private pref: preferences.Preferences | null = null;

  async init(context: Context) {
    this.pref = await preferences.getPreferences(context, 'my_app_settings');
  }

  async putColumnCount(value: number) {
    if (this.pref) {
      await this.pref.put('homeColumnCount', value);
      await this.pref.flush();
    }
  }

  async getColumnCount(defaultValue: number = 2): Promise<number> {
    if (this.pref) {
      return (await this.pref.get('homeColumnCount', defaultValue)) as number;
    }
    return defaultValue;
  }
}

export const prefUtil = new PreferencesUtil();