/**
 * RdbUtils.ts
 * 关系型数据库工具封装 — 直接复制自官方 MusicCard 示例
 */
import { relationalStore } from '@kit.ArkData';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'RdbUtils';

const STORE_CONFIG: relationalStore.StoreConfig = {
  name: 'form_data.db',
  securityLevel: relationalStore.SecurityLevel.S1,
};

export class RdbUtils {
  private rdbStore: relationalStore.RdbStore | undefined;
  private tableName: string = '';
  private sqlCreateTable: string = '';

  constructor(tableName: string, sqlCreateTable: string) {
    this.tableName = tableName;
    this.sqlCreateTable = sqlCreateTable;
  }

  public getRdbStore(context: Context): Promise<relationalStore.RdbStore> {
    return new Promise<relationalStore.RdbStore>((resolve, reject) => {
      if (this.rdbStore) {
        resolve(this.rdbStore);
        return;
      }
      relationalStore.getRdbStore(context, STORE_CONFIG).then((store) => {
        this.rdbStore = store;
        this.rdbStore.executeSync(this.sqlCreateTable);
        resolve(store);
      }).catch((err: BusinessError) => {
        logError(TAG, 'getRdbStore failed:', err.code, err.message);
        reject(err);
      });
    });
  }

  async insertData(context: Context, valuesBucket: relationalStore.ValuesBucket): Promise<number> {
    const rdbStore = await this.getRdbStore(context);
    return rdbStore.insert(this.tableName, valuesBucket);
  }

  async deleteData(context: Context, predicates: relationalStore.RdbPredicates): Promise<number> {
    const rdbStore = await this.getRdbStore(context);
    return rdbStore.delete(predicates);
  }

  async query(context: Context, predicates: relationalStore.RdbPredicates): Promise<relationalStore.ResultSet> {
    const rdbStore = await this.getRdbStore(context);
    return rdbStore.query(predicates);
  }
}
