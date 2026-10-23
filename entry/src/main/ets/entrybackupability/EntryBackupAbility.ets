import { BackupExtensionAbility } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export default class EntryBackupAbility extends BackupExtensionAbility {
  async onBackup(): Promise<void> {
    hilog.info(0x0000, 'testTag', 'onBackup');
  }

  async onRestore(): Promise<void> {
    hilog.info(0x0000, 'testTag', 'onRestore');
  }
}
