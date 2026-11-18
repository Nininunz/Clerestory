---
title: 安装 OpenYoink
description: 通过 Homebrew 或 GitHub Release 安装 OpenYoink，并处理首次启动提示。
---

# 安装 OpenYoink

## 系统要求

- macOS 15 Sequoia 或更高版本
- Apple Silicon 或 Intel Mac

## Fork release status

This is the Nininunz fork of [OpenYoink](https://github.com/MuQY1818/OpenYoink).
Download the signed and notarized [1.0.0 DMG](https://github.com/Nininunz/OpenYoink/releases/download/v1.0.0/OpenYoink-1.0.0.dmg). Open it and copy OpenYoink to Applications. Quit other OpenYoink copies before launching.
Upstream Homebrew packages install the upstream app, not this fork.

The fork has a separate bundle identity and update-signing key. Existing upstream
settings and shelf data are not automatically migrated. See the
[release and migration checklist](https://github.com/Nininunz/OpenYoink/blob/main/docs/FORK_RELEASE.md).

## 启动后在哪里？

OpenYoink 是菜单栏应用，不显示 Dock 图标。启动后请在屏幕右上方菜单栏寻找 OpenYoink 图标，从那里可以打开暂存架和设置。

下一步：[完成第一次拖入与拖出](./quick-start)。

