/**
 * 贡献者信息
 * 头像使用构建期下载到本地资源（resources/base/media/avatar_*.png）的图片，
 * 不走网络：断网可显示、进页面零 RTT。新增贡献者时按下面三步：
 *   1. curl -sL "https://github.com/<用户名>.png?size=200" -o entry/src/main/resources/base/media/avatar_<用户名>.png
 *   2. 在 CONTRIBUTORS 里追加一条（avatar 写 $r('app.media.avatar_<用户名>')）
 *   3. 用用户可见文案确认页面已引用（AboutPage / ContributorsPage）
 */

export interface ContributorItem {
  /** GitHub 显示名 */
  name: string;
  /** GitHub 用户名（用于跳转主页） */
  handle: string;
  /** 是否为项目发起者：发起者卡片只显示头像 / 名称 / 账号 / 角标 */
  isFounder: boolean;
  /** 角标文案，显示在名字右侧；空字符串表示不显示 */
  role: string;
  /** 详情页里的逐条贡献（发起者不列） */
  works: string[];
  /** 本地头像资源 */
  avatar: Resource;
}

/** 本项目借鉴学习的开源项目 */
export interface LearnedProject {
  /** 显示名称 */
  name: string;
  url: string;
  /** 本地图标资源（构建期已裁成圆角方形） */
  icon: Resource;
}

export const GITHUB_REPO_URL: string = 'https://github.com/chunwcc/yunshang-bili';
export const GITHUB_ISSUES_URL: string = 'https://github.com/chunwcc/yunshang-bili/issues/new/choose';
export const CONTRIBUTING_URL: string = 'https://github.com/chunwcc/yunshang-bili/blob/main/CONTRIBUTING.md';

export const CONTRIBUTORS: ContributorItem[] = [
  {
    name: 'Kshan',
    handle: 'chunwcc',
    isFounder: true,
    role: '发起者',
    works: [
      '项目发起与整体架构 · 前端设计与交互',
      '播放器 / DASH 转播与画质选轨',
      '弹幕渲染引擎（滚动·顶部·底部·逆向）',
      '番剧选集与分集进度上报',
      '开源化整理（文档 / 许可 / 脱敏）'
    ],
    avatar: $r('app.media.avatar_kshan')
  } as ContributorItem,
  {
    name: 'cycoe',
    handle: 'cycoe',
    isFounder: false,
    role: '',
    works: [
      '回桌面自动画中画小窗（XComponent 模式）',
      '个人空间粉丝 / 关注列表页',
      '私信页刷新与回顶',
      '长按视频卡片弹窗重构 + 保存封面',
      '修复 1:1 横屏视频控件显示不全'
    ],
    avatar: $r('app.media.avatar_cycoe')
  } as ContributorItem
];

export const LEARNED_PROJECTS: LearnedProject[] = [
  {
    name: '流心播放器',
    url: 'https://github.com/Yebingiscn/SweetVideo',
    icon: $r('app.media.learn_sweetvideo')
  } as LearnedProject,
  {
    name: 'PiliPlus',
    url: 'https://github.com/dev4harmony/PiliPlus',
    icon: $r('app.media.learn_piliplus')
  } as LearnedProject
];
