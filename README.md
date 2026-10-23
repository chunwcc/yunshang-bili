# 云尚B站

HarmonyOS（ArkTS）第三方哔哩哔哩客户端，学习用途。

> ⚠️ **免责声明**
> 本项目为个人学习与技术研究项目，**非哔哩哔哩官方客户端**，与哔哩哔哩无任何关联。
> 项目不提供任何成品安装包，不包含任何真实平台凭据，不提供付费内容。
> 请支持正版，遵守平台用户协议。因使用本项目产生的任何后果由使用者自行承担。

## 功能

- 首页推荐、频道、动态、直播、番剧/影视
- 视频播放（DASH，支持 4K / 1080P+ 画质切换）
- 弹幕（滚动 / 顶部 / 底部 / 逆向，支持过滤与设置）
- 评论、收藏、历史记录、私信
- 深浅色主题、沉浸光感材质、卡片样式自定义
- 画中画小窗、后台播放、DLNA 投屏

## 构建

需要 DevEco Studio（API 23 及以上）与对应 SDK。

```bash
# 1. 配置 SDK 路径
#    在项目根目录创建 local.properties，写入：
#    sdk.dir=<你的 DevEco SDK 路径>

# 2. 配置签名
#    DevEco Studio → File → Project Structure → Signing Configs
#    勾选 Automatically generate signature（需登录华为开发者账号）

# 3. 构建
hvigorw --mode module -p module=entry@default -p product=default \
        -p requiredDeviceType=phone assembleHap --no-daemon
```

## 签名密钥配置（重要）

仓库**不包含任何真实的平台签名密钥**。首次构建前需要：

```bash
# 复制模板
cp entry/src/main/ets/utils/AppKeys.example.ets entry/src/main/ets/utils/AppKeys.ets
```

然后编辑 `AppKeys.ets`，填入你自己准备好的凭据。

> `AppKeys.ets` 已在 `.gitignore` 中排除，不会被提交。
> 若你需要调用相关接口，请自行准备合规的凭据。

## 目录结构

```
entry/src/main/ets/
├── api/            # 平台接口封装（视频、直播、番剧、评论、动态等）
├── components/     # 通用 UI 组件
├── model/          # 数据模型与数据源
├── pages/          # 页面
├── services/       # 播放器、弹幕、缓存、投屏等服务
├── utils/          # 工具（签名、日志、主题、格式化）
└── widget/         # 桌面卡片
```

## 许可

本项目仅供学习交流，不提供任何形式的担保。
