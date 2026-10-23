/**
 * ActionUtils.ets
 * 卡片事件工具（postCardAction 封装）
 * 与官方 MusicCard 示例一致的接口
 */
import { CallMethod, ENTRY_ABILITY, FormCarAction } from './FormCardConstant';

class ActionUtils {
  /** 播放控制（call 事件，后台拉起 EntryAbility） */
  public playByAction(component: Object, type: string, formId: string): void {
    postCardAction(component, {
      action: FormCarAction.CALL,
      abilityName: ENTRY_ABILITY,
      params: {
        method: CallMethod.PLAY_BY_ACTION,
        playActionType: type,
        formId: formId,
      },
    });
  }

  /** 请求更新卡片数据（call 事件） */
  public updateControlCardAction(component: Object, formId: string): void {
    postCardAction(component, {
      action: FormCarAction.CALL,
      abilityName: ENTRY_ABILITY,
      params: {
        method: CallMethod.REQUEST_UPDATE_CARD,
        formId: formId,
      },
    });
  }

  /** 卡片主动请求数据（aboutToAppear 时调用） */
  public requestCardUpdate(component: Object, formId: string): void {
    this.updateControlCardAction(component, formId);
  }

  /** 打开播放页（router 事件，拉起应用前台） */
  public jumpPlayPage(component: Object): void {
    postCardAction(component, {
      action: FormCarAction.ROUTER,
      abilityName: ENTRY_ABILITY,
    });
  }
}

export default new ActionUtils();
