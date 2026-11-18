---
title: 常见问题
description: 解决 OpenYoink 无法启动、更新失败、拖放不生效和文件不可用等问题。
---

# 常见问题

## 启动后看不到窗口

OpenYoink 是菜单栏应用，不显示 Dock 图标。请检查屏幕右上方菜单栏，并尝试按默认快捷键 `⌘⇧Space`。

## Installation and updates

This fork has not published a signed release yet. See [installation status](./install).
The fork's updater only trusts its own signing key. Upstream packages and update
feeds are not interchangeable with this fork. Report fork issues to
[Nininunz/OpenYoink](https://github.com/Nininunz/OpenYoink/issues).

## 拖动时暂存架没有出现

- 打开“设置 → 触发”，确认拖拽触发已启用。
- 检查当前应用是否在“忽略的应用”列表中。
- 侧边模式下确认拉环没有被关闭。
- Island 模式下把鼠标移动到当前屏幕顶部中央，而不是另一台显示器。

## 卡片显示文件不可用

原文件可能已被移动或删除，或者所在外接磁盘当前离线。重新连接磁盘后，bookmark 可能自动恢复；OpenYoink 不会凭旧路径访问一个未经授权的新文件。

## 网页不接受拖出的文件

目标网站最终决定是否接受拖放。OpenYoink 同时提供现代文件 URL 和 Chromium 兼容表示，但部分网页上传控件只允许点击选择文件。可以尝试：

- 拖到上传区域的正中央。
- 先拖到 Finder，再使用网站的“选择文件”。
- 在 GitHub Issue 中附上浏览器版本和网站地址。

## 反馈问题时请提供

- macOS 版本与 Mac 型号
- OpenYoink 版本
- 侧边模式还是 Island 模式
- 来源应用、目标应用和内容类型
- 可重复的操作步骤

