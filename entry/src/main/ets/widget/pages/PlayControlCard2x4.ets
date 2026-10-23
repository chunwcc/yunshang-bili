/**
 * PlayControlCard2x4.ets
 * 简化版：标题 + 圆形封面 + 播放/暂停按钮
 * call 事件已确认能到达 EntryAbility（见日志 playByAction）
 * 播放按钮只发 call 事件，不再同时发 router
 */
import ActionUtils from '../model/ActionUtils';
import { PlayActionType } from '../model/FormCardConstant';

let storage = new LocalStorage();

@Entry(storage)
@Component
struct PlayControlCard2x4 {
  @LocalStorageProp('formId') formId: string = '';
  @LocalStorageProp('isNeedRequestUpdate') @Watch('onNeedUpdate') isNeedRequestUpdate: boolean = false;
  @LocalStorageProp('isPlay') isPlay: boolean = false;
  @LocalStorageProp('title') title: string = 'Bilibili';
  @LocalStorageProp('cover') cover: string = '';
  @LocalStorageProp('imageColorHex') imageColorHex: string = '18191d';

  /** isNeedRequestUpdate 变化时主动请求数据 */
  onNeedUpdate(): void {
    if (this.isNeedRequestUpdate && this.formId) {
      ActionUtils.requestCardUpdate(this, this.formId);
    }
  }

  build() {
    RelativeContainer() {
      // ── 圆形封面 ──
      Column() {
        if (this.cover) {
          Image(this.cover)
            .width(80)
            .height(80)
            .borderRadius(40)
            .objectFit(ImageFit.Cover)
        } else {
          Image($r('app.media.ic_publi_play'))
            .width(80)
            .height(80)
            .borderRadius(40)
            .objectFit(ImageFit.Cover)
            .opacity(0.3)
        }
      }
      .width(80)
      .height(80)
      .borderRadius(40)
      .alignRules({
        'top': { 'anchor': '__container__', 'align': VerticalAlign.Top },
        'left': { 'anchor': '__container__', 'align': HorizontalAlign.Start }
      })
      .margin({ top: 12, left: 12 })

      // ── 标题 ──
      Text(this.title)
        .fontSize(16)
        .fontWeight(700)
        .fontColor(Color.White)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .alignRules({
          'top': { 'anchor': '__container__', 'align': VerticalAlign.Top },
          'left': { 'anchor': '__container__', 'align': HorizontalAlign.Start }
        })
        .margin({ top: 12, left: 108 })
        .id('musicTitle')

      // ── 播放/暂停按钮（只发 call 事件，不发 router） ──
      SymbolGlyph(this.isPlay ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
        .fontSize(36)
        .fontColor(['#E5FFFFFF'])
        .alignRules({
          'bottom': { 'anchor': '__container__', 'align': VerticalAlign.Bottom },
          'right': { 'anchor': '__container__', 'align': HorizontalAlign.End }
        })
        .margin({ bottom: 16, right: 16 })
        .onClick(() => {
          if (this.formId) {
            ActionUtils.playByAction(this, this.isPlay ? PlayActionType.PAUSE : PlayActionType.PLAY, this.formId);
          }
        })
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .onClick(() => { ActionUtils.jumpPlayPage(this); })
    .linearGradient({
      direction: GradientDirection.Bottom,
      repeating: false,
      colors: [[`#ff${this.imageColorHex}`, 0.0], [`#cc${this.imageColorHex}`, 0.5], [`#ff${this.imageColorHex}`, 1.0]]
    })
  }
}
