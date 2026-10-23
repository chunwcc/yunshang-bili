/**
 * FormRdbHelper.ts
 * 播控卡片 RDB 持久化管理 — 直接复制自官方 MusicCard 示例
 */
import { relationalStore } from '@kit.ArkData';
import { logInfo, logWarn, logError } from '../utils/Logger';
import { RdbUtils } from './RdbUtils';

const TAG = 'FormRdbHelper';

export interface FormRecord {
  formId: string;
  formName: string;
  formDimension: string;
}

const SQL_CREATE_TABLE = 'CREATE TABLE IF NOT EXISTS FormInfoTable(formId STRING PRIMARY KEY, formName STRING, formDimension STRING)';
const TABLE_NAME = 'FormInfoTable';

export class FormRdbHelper {
  private static instance: FormRdbHelper;
  private rdbUtils: RdbUtils;

  private constructor() {
    this.rdbUtils = new RdbUtils(TABLE_NAME, SQL_CREATE_TABLE);
  }

  static getInstance(): FormRdbHelper {
    if (!FormRdbHelper.instance) {
      FormRdbHelper.instance = new FormRdbHelper();
    }
    return FormRdbHelper.instance;
  }

  async insertForm(context: Context, record: FormRecord): Promise<void> {
    try {
      const valueBucket: relationalStore.ValuesBucket = {
        'formId': record.formId,
        'formName': record.formName,
        'formDimension': record.formDimension,
      };
      await this.rdbUtils.insertData(context, valueBucket);
    } catch (e) {
      // 重复插入时忽略（PRIMARY KEY 冲突）
      logWarn(TAG, 'insertForm (可能重复):', JSON.stringify(e));
    }
  }

  async deleteForm(context: Context, formId: string): Promise<void> {
    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_NAME);
      predicates.equalTo('formId', formId);
      await this.rdbUtils.deleteData(context, predicates);
    } catch (e) {
      logError(TAG, 'deleteForm error:', JSON.stringify(e));
    }
  }

  async queryFormByName(context: Context, formName: string): Promise<FormRecord[]> {
    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_NAME);
      predicates.contains('formName', formName);
      const resultSet = await this.rdbUtils.query(context, predicates);
      const list: FormRecord[] = [];
      while (resultSet.goToNextRow()) {
        list.push({
          formId: resultSet.getString(resultSet.getColumnIndex('formId')),
          formName: resultSet.getString(resultSet.getColumnIndex('formName')),
          formDimension: resultSet.getString(resultSet.getColumnIndex('formDimension')),
        });
      }
      resultSet.close();
      return list;
    } catch (e) {
      logError(TAG, 'queryFormByName error:', JSON.stringify(e));
      return [];
    }
  }
}
