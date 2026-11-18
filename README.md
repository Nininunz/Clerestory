# Clerestory

**Mac 上的模块化面板。**

Clerestory 将暂存架和可配置的快捷入口集中在屏幕顶部的面板中，支持内置和外接显示器。配有实体刘海的 Mac 还可以显示独立的刘海入口，用来打开面板或查看模块状态。

[下载 Clerestory 1.0.4](https://github.com/Nininunz/Clerestory/releases/tag/v1.0.4) · [快速上手](#快速上手) · [English](README.en.md)

## 安装

Clerestory 支持运行 macOS 15 或更新版本的 Apple 芯片和 Intel Mac。打开已签名并通过 Apple 公证的 [Clerestory 1.0.4 DMG](https://github.com/Nininunz/Clerestory/releases/download/v1.0.4/Clerestory-1.0.4.dmg)，将应用拖入「应用程序」。

从旧版 OpenYoink 切换时，请使用 DMG 安装 Clerestory。Clerestory 使用独立的暂存架和偏好设置。已安装使用 Clerestory 应用标识符的版本后，可从菜单栏图标选择 **检查更新…**。详见[发行指南](docs/FORK_RELEASE.md)。

## 快速上手

| 操作 | 方法 |
| --- | --- |
| 打开面板 | 将指针移到屏幕顶部中央，点击触发区域，按 `⌘⇧Space`，或使用菜单栏图标。 |
| 添加内容 | 将文件或选中的文本拖向屏幕顶部中央，再放入暂存架。 |
| 移入文件 | 按住 `⌘` 后放下文件。请先阅读[文件安全与生命周期](#文件安全与生命周期)。 |
| 暂存剪贴板 | 启用双按暂存剪贴板后，连按两次 `⌘⇧Space`。 |
| 搜索 | 点击暂存架的搜索框，或在暂存架获得键盘焦点后按 `⌘F`。 |
| 预览 | 点击选中后按空格，或双击条目。 |
| 多选 | 点击「选择」，或按住 `⌘` 逐个切换选中状态。 |
| 移除 | 悬停后点击 **×**、按 Delete，或使用右键菜单。按 `⌘Z` 可撤销手动移除。 |

默认开启悬停、点击和拖拽唤出。可以在 **设置 → 面板** 中调整悬停延迟或关闭各项触发方式。拖拽唤出有独立开关。点击面板的图钉可让面板在指针移开后继续保持打开。

## 面板、刘海与模块

- **面板**在触发它的显示器上打开，关闭前会留在该显示器。可在 **设置 → 面板 → 快捷入口位置** 或 **快捷设置** 中排列模块快捷入口。
- **刘海**是配有实体刘海的内置屏幕上的可选入口。在 **设置 → 刘海** 中调整开关、模块顺序和循环快捷键。按住 Shift 再使用循环快捷键可反向切换。
- 默认可使用**暂存架**和**快捷设置**。其他模块可在 **设置 → 模块** 中打开**实验性模块**后按需启用，包括传输、计时器、电池、正在播放、系统状态、快速访问、剪贴板和 AI 用量。

## 文件安全与生命周期

直接拖进来的文件，Clerestory 只记住它在哪，不会移动它。移除卡片、或者打开"拖出后移除"，都不会删掉原文件。拖到 Finder 时只是请求复制一份，收不收由目标应用决定。

> [!WARNING]
> 按住 `⌘` 拖进来是"移入"：先把文件复制到应用自己的沙箱里，确认副本完好后，再把原文件挪进废纸篓。中途出错就保留原文件，按普通方式暂存。清空废纸篓之前，原文件都还能找回来。

移入的东西要等成功拖到目的地后，卡片和沙箱里的副本才会删掉，和普通卡片的"拖出后处理"设置无关。拖出被取消或失败时会原样保留，下次再试。

<details>
<summary>各类内容存在哪、什么时候清理</summary>

| 内容                   | Clerestory 怎么存                                        |
| ---------------------- | ------------------------------------------------------- |
| 文件、文件夹           | 记住原文件的位置和访问授权（sandbox bookmark），不复制  |
| 纯文本、链接           | 直接存在暂存架的数据里                                  |
| 图片、HTML、RTF        | 在应用沙箱里存成文件                                    |
| 联系人、日历事件、邮件 | 来源应用给得出数据时，存成 `.vcf`、`.ics`、`.eml`       |

原文件被挪走、删掉，或者所在的硬盘没接上，卡片会显示为不可用，等能重新找到文件时会自动恢复。

文本和链接跟着卡片走，卡片删了它们也就没了。图片、富文本、邮件这类生成出来的文件，一般在卡片移除后的下次启动时清掉；也可以去 **设置 → 存储** 手动看看、清理。

普通文件拖出去时，会同时提供文件路径和 Chromium 认得的文件名；移入的文件用 file promise，等目的地确认写好了才从架子上撤下来。具体能不能拖成功，最终还是看目标应用或网站。

</details>

## 隐私与权限

- 不用注册账号，不收集统计数据。东西都存在本机沙箱里的 `Application Support/Clerestory`。
- 开启了 App Sandbox，只能碰你自己拖进来或选中的文件。日常使用不需要辅助功能或输入监控权限。
- 唯一的后台联网是检查和下载更新（访问 GitHub Pages / Releases），可以在设置里关掉。
- 正在播放模块不联网。它优先用本地 helper 读取播放信息，退而用 AppleScript 控制 Apple Music / Spotify，这时系统可能会问你要"自动化"权限。这个模块出问题不会影响暂存架。
- AI 用量模块只访问本机的 TokenTracker（`localhost:7680`），不连外网，也不读它的文件。
- 快速访问只记住你添加的文件夹位置。取消收藏不会删除文件夹，用什么打开交给 macOS 决定。

### 剪贴板历史

剪贴板默认不记录。需要使用时，请在 **设置 → 模块** 中启用实验性的剪贴板模块，再在该模块的设置中开启记录。没打开时，只有你连按两下快捷键暂存剪贴板的那一刻才会读一次。打开之后，只记新复制的文本、HTTP(S) 链接和 PNG/TIFF 图片，不会回头翻以前的内容，也不记复制的文件。

历史以明文存在本机，不上传、不同步。普通条目可以留 30、100 或 300 条（默认 30），保留 1、7 或 30 天（默认 7 天）；另外最多收藏 30 条，不会过期。所有内容加起来上限 20 MiB。关掉记录不会删已有的历史，点"清空"才会删。

常见密码管理器标记为隐私的内容、以及你设成忽略的应用，都会跳过，但没办法认出所有敏感信息。复制密码或令牌之前，最好先暂停记录。

## 从源码构建

需要 macOS 15+ 和 Xcode 26+。

```bash
git clone https://github.com/Nininunz/Clerestory.git
cd Clerestory

xcodebuild \
  -project Clerestory.xcodeproj \
  -scheme Clerestory \
  -destination 'platform=macOS' \
  build

xcodebuild \
  -project Clerestory.xcodeproj \
  -scheme Clerestory \
  -destination 'platform=macOS' \
  test \
  -only-testing:ClerestoryTests
```

用 Swift 6、SwiftUI 和 AppKit 写的。本地构建不需要设置 `DEVELOPMENT_TEAM`；上面的测试命令只跑单元测试，不跑 UI 自动化。

发版用 [`Scripts/make-release.sh`](Scripts/make-release.sh)，可以走 Developer ID 签名加公证，也可以显式传 `--adhoc` 出社区版。签名失败时脚本会直接停下，不会悄悄降级。

## 参与进来

架构、测试、预览与发行指南见[文档索引](docs/README.md)。

在仓库根目录运行 `python3 Scripts/tree.py` 可查看源码目录结构，包括未被 Git 忽略的新文件。输出会跳过已忽略的构建产物和本地配置。

运行 `python3 Scripts/tree.py Clerestory/Island --depth 2` 可查看指定目录及其下最多两层。输出路径仍以仓库根目录为基准。

运行 `Scripts/doctor.sh` 可检查当前的 Xcode、macOS SDK 以及本地构建和测试工具。加上 `--release` 可额外检查 Developer ID 签名、Sparkle 工具和公证权限。发版检查会连接 Apple，但不会上传构建产物或打印凭据。

用着不顺手、遇到 bug 或者有想法，欢迎开 [Issue](https://github.com/Nininunz/Clerestory/issues)。报 bug 时附上 macOS 版本、Clerestory 版本和复现步骤会很有帮助；截图前留意别带上私人文件或剪贴板内容。

PR 也欢迎。改动比较大的话，先开个 Issue 聊聊；提交前请跑一遍完整的单元测试。

## 上游项目的 Star 历史

<a href="https://www.star-history.com/?repos=MuQY1818%2FOpenYoink&amp;type=date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=MuQY1818/OpenYoink&amp;type=Date&amp;theme=dark">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=MuQY1818/OpenYoink&amp;type=Date">
    <img src="https://api.star-history.com/svg?repos=MuQY1818/OpenYoink&amp;type=Date" width="800" alt="OpenYoink 在 GitHub 上的 Star 数量变化">
  </picture>
</a>

## 致谢与许可

Clerestory 基于 weijue 和贡献者开发的 [OpenYoink](https://github.com/MuQY1818/OpenYoink)，采用 [MIT 许可证](LICENSE) 开源。

自动更新靠 [Sparkle](https://sparkle-project.org/)，Star 趋势图来自 [Star History](https://www.star-history.com/)。用到的第三方组件和许可证见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

<br>

<div align="center">

© 2026 weijue · MIT License

</div>
