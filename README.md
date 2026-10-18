# Zhihu++ iOS

[Zhihu++](https://github.com/LumosBW/zhihu-plus-plus) 的 iOS 版本实现，使用 SwiftUI 原生编写，无第三方依赖。

Zhihu++ 是一个去广告、占用低的知乎第三方 Android 客户端，原作者为 [@zly2006](https://github.com/zly2006)（原项目：[zly2006/zhihu-plus-plus](https://github.com/zly2006/zhihu-plus-plus)）。本项目的签名算法、接口、过滤规则和功能设计都参照并移植自 Android 版，没有原作者的开源分享就不会有这个 iOS 版本，在此衷心感谢原作者及所有贡献者。

> 本应用由开源社区开发和维护，不由知乎官方开发并运营。与原项目一致，本项目以 [AGPL-3.0](LICENSE) 协议开源。

## 运行

1. 用 Xcode 16 及以上打开 `ZhihuPlusPlus.xcodeproj`
2. 在 Signing & Capabilities 中选择自己的 Team（真机运行需要）
3. 选择模拟器或真机，⌘R 运行

最低系统版本 iOS 17。工程使用 Xcode 16 的文件夹同步（`ZhihuPlusPlus/` 目录下新增的文件会自动加入编译）。

## 侧载安装（SideStore，无需付费开发者账号）

```bash
./scripts/build-ipa.sh
```

生成未签名的 `build/ZhihuPlusPlus.ipa`，传到手机后在 SideStore 中点 My Apps →「+」选择该文件安装，签名与每 7 天续签由 SideStore 完成。

## 功能

| 模块 | 说明 | 对应 Android 实现 |
| --- | --- | --- |
| 首页推荐 | 「推荐」（网页版算法）/「发现」（App 算法）两个标签，过滤广告、软文 | `HomeFeedViewModel` |
| 热榜 | 知乎热榜 | `HotListViewModel` |
| 日报 | 知乎日报，自动跳转到原始回答 | `DailyScreen` |
| 搜索 | 热搜、搜索历史、综合搜索 | `SearchViewModel` |
| 回答 / 文章 | WKWebView 渲染正文；回答连续滚动，每条独立赞同、收藏、评论、关注和分享；图片全屏查看与无水印保存 | `ArticleViewModel` |
| 问题 | 问题详情、回答列表（默认/时间排序）、关注问题 | `QuestionFeedViewModel` |
| 想法 | 想法正文与图片 | `PinScreen` |
| 评论 | 评论/子评论、点赞、发表与回复 | `RootCommentViewModel` |
| 用户主页 | 资料、回答、文章、关注用户、收藏夹 | `PeopleScreen` |
| 内容过滤 | 屏蔽词、屏蔽用户、质量过滤、盐选付费内容屏蔽 | `ContentFilterExtensions` |
| 登录 | 网页登录、手动 Cookie 登录；Cookie 保存在钥匙串 | `WebLoginPane` |
| 风控验证 | 遇到 40352 风控时在应用内打开验证页并同步 Cookie | `configureRiskControlWebView` |

## 代码结构

```
ZhihuPlusPlus/
├── App/            应用入口、Tab 与路由分发
├── Core/
│   ├── ZhihuSignature.swift  x-zse-96 签名（移植自 ZseSigner.kt / ZhihuFetchSignature.kt）
│   ├── ZhihuClient.swift     HTTP 客户端：Cookie、UA、签名、错误/风控解析
│   ├── ZhihuAPI.swift        接口地址与互动操作
│   ├── PagedLoader.swift     通用分页加载（paging.next / is_end）
│   ├── ContentFilter.swift   本地过滤规则
│   ├── Router.swift          路由与知乎链接解析
│   └── AccountStore / AppSettings / Keychain / HTML / JSONValue
├── Models/         Feed、回答、问题、评论、用户等模型（宽松 JSON 解析）
└── Views/          Feed、Content、Account、Components
```

## 已验证

- `x-zse-96` 签名与 Android 仓库内的 Rust 参考实现 `rs-zse-sign` 的输出逐字节一致
- 各模型解析器通过 Android 仓库 `shared/src/jvmTest/resources` 中的真实接口样本校验（含 19 位想法 ID 不丢精度）

## 尚未移植

本地推荐算法、AI 内容过滤（ONNX）、手机号/扫码登录、多账号、通知与私信、内容创作、朗读、视频播放。
