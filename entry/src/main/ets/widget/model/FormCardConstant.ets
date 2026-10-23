/**
 * FormCardConstant.ets
 * 播控卡片常量：事件类型、方法名、路由类型等
 */
export const ENTRY_ABILITY = 'EntryAbility';

export enum FormCarAction {
  CALL = 'call',
  ROUTER = 'router',
}

export enum FormCardName {
  CONTROL_2X2 = 'PlayControlCard2x2',
  CONTROL_2X4 = 'PlayControlCard2x4',
}

export enum PlayActionType {
  PAUSE = '0',
  PLAY = '1',
  PREVIOUS = '2',
  NEXT = '3',
}

export enum RouterType {
  PLAYER = '1',
}

export enum CallMethod {
  REQUEST_UPDATE_CARD = 'requestUpdatePlayCard',
  PLAY_BY_ACTION = 'playByAction',
}

export enum CollectAction {
  COLLECTED = '1',
  UNCOLLECTED = '0',
}
