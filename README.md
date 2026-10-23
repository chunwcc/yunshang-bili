<div align="center">
  <img src="docs/logo.png" alt="云上太学" width="160">

# 云上太学

**一个基于 HarmonyOS / ArkTS 的第三方 bilibili 客户端**，用于学习 ArkTS 声明式 UI、Stage 模型、自定义渲染与流媒体播放的工程实践。

`HarmonyOS` `ArkTS` `bilibili` `第三方客户端`

---

</div>

> ⚠️ **本项目为非官方的第三方实现，与 bilibili 官方无任何关联，也未获得其授权。**
> 项目名称与图标均为独立设计，**不包含** bilibili 的商标或官方素材。

---

## 一、重要声明（请先阅读）

### 1. 本仓库不附带任何真实凭据

签名相关常量已抽离到独立文件，仓库只提供占位符模板：

| 文件 | 说明 |
|---|---|
| `entry/src/main/ets/utils/AppKeys.example.ets` | 占位符模板（入库） |
| `entry/src/main/ets/utils/AppKeys.ets` | 真实凭据（已在 `.gitignore` 中排除，需自行创建） |

首次构建前先复制模板：

```bash
cp entry/src/main/ets/utils/AppKeys.example.ets entry/src/main/ets/utils/AppKeys.ets
```

然后编辑 `AppKeys.ets`，填入你自己准备好的凭据。

**签名算法本身完整保留**（`SignUtils.ets` 中的 WBI 与 AppSign 实现），但仓库不附带任何真实凭据值。若你需要调用相关接口，请自行准备合规的凭据。

### 2. 关于「仅供学习」

本仓库发布的是**学习用途的客户端实现**，请勿用于：

- 批量抓取、下载或二次分发受版权保护的内容
- 绕开付费墙、大会员权限等商业化限制
- 任何违反 bilibili 用户协议或适用法律的用途

使用者需自行承担其行为的一切后果。本项目的作者不对任何第三方的使用方式负责。

### 3. 默认登录方式已调整为 Web 扫码

为让开源版本**开箱即用、无需额外凭据即可登录**，`QrCodeLoginPage` 的 `isTvMode` 默认值设为 `false`，
走公开接口 `passport.bilibili.com/x/passport-login/web/qrcode`。

---

## 二、功能概览

- 首页推荐流、热门、分区频道
- 视频播放（DASH / FLV，支持续播、倍速、画质切换）
- 弹幕渲染（滚动 / 顶部 / 底部 / 逆向，支持屏蔽规则与样式设置）
- 番剧影视（PGC）选集与分集进度上报
- 评论、回复、点赞、投币、收藏
- 动态、直播、私信、消息中心
- 搜索、历史记录、离线缓存、观看历史

详见 [docs/功能清单.md](docs/功能清单.md)。

### 界面预览

| 播放页（竖屏 / 横屏） | 首页（竖屏 / 横屏） |
|:---:|:---:|
| ![播放页-竖屏](docs/screenshots/player-portrait.jpg) | ![首页-竖屏](docs/screenshots/home-portrait.jpg) |
| ![播放页-横屏](docs/screenshots/player-landscape.jpg) | ![首页-横屏](docs/screenshots/home-landscape.jpg) |

> 截图中的视频画面、封面、弹幕与「bilibili」字样水印均来自 bilibili 平台的内容，
> 版权归其原作者 / bilibili 所有，仅作界面演示之用。

---

## 三、构建

### 环境要求

- DevEco Studio（建议 5.0+）
- HarmonyOS SDK：`compileSdkVersion 26.0.0`，`compatibleSdkVersion 6.1.0(23)`
- Node.js 与 hvigor（随 DevEco Studio 安装）

### 步骤

1. 用 DevEco Studio 打开本目录，等待依赖同步完成
2. **配置签名**：`File → Project Structure → Signing Configs`，使用你自己的证书
   （仓库内的 `build-profile.json5` 未包含签名配置，构建者需自行配置）
3. 连接设备或启动模拟器
4. `Build → Build Hap(s)/APP(s) → Build APP(s)`，或直接运行

命令行构建：

```bash
# 请替换为你本机的 SDK / Node 路径
export JAVA_HOME="<DevEco Studio 安装目录>/jbr"
export DEVECO_SDK_HOME="<HarmonyOS SDK 目录>"
node hvigorw.js --mode module -p module=entry@default -p product=default \
  -p requiredDeviceType=phone assembleHap --analyze=normal --no-daemon
```

---

## 四、目录结构

```
AppScope/                 应用级配置与图标
entry/src/main/ets/
  ├── api/                B 站各业务接口封装
  ├── components/         可复用 UI 组件
  ├── model/              数据模型
  ├── pages/              页面
  ├── services/           弹幕渲染、DASH 转播、离线缓存等服务
  └── utils/              签名、日志、工具
docs/                     设计与排查文档
```

---

## 五、第三方代码声明

本项目包含以下**源自第三方**的组件，均已在文件头注明来源，各自的许可条款优先于本项目的 MIT：

| 文件 | 来源 | 许可 |
|---|---|---|
| `entry/src/main/ets/components/infra/HdsMiniBarButton.ets` | `ceshi/HdsButton_Component-main`（SummerKaze） | Apache-2.0 |
| `entry/src/main/ets/components/HdsTitleBarSegment.ets` | `DeadlinerNEXT/DeadlinerNEXT` | 参见其上游仓库 |

> `DeadlinerNEXT` 上游仓库在整理本文档时已无法访问（404）。
> 若你是该组件的作者或知晓其许可条款，请通过 Issue 联系，
> 我将按你的要求补充声明或移除该组件。

其余代码均为本项目独立实现。开发过程中**参考**了
[PiliPlus](https://github.com/qinshah/PiliPlus) 的接口设计与参数处理方式，
但其为 Dart/Flutter 实现，本项目为 ArkTS 重写，**未复制其源码**。

---

## 六、许可

本项目自身代码使用 **MIT License**，详见 [LICENSE](LICENSE)。

> 本仓库按「原样」提供，不提供任何真实凭据。
> 使用者基于本仓库进行二次开发、打包或分发的行为，由使用者自行负责，与本仓库作者无关。
