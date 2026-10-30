# CGit

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20preview-lightgrey.svg)](#下载与安装)

CGit 是一款轻量的 Git 桌面客户端，提供变更、提交、历史、分支和冲突处理界面。

**[下载最新版](https://github.com/Ckales/CGit/releases/latest)** · [查看所有版本](https://github.com/Ckales/CGit/releases)

## 下载与安装

- **macOS 12+**：下载 `.dmg`，将 `CGit.app` 拖到“应用程序”。安装包同时包含 Apple Silicon 和 Intel 版本。
- **Windows x64（预览）**：下载 `CGit-版本号-windows-x64-Setup.exe` 并运行安装向导。默认安装到当前用户目录，无需管理员权限；安装后从开始菜单启动，可在 Windows 设置中卸载。后续版本运行安装包即可覆盖升级。

两端均需安装可从命令行调用的 [Git](https://git-scm.com/downloads)；Windows 请安装 Git for Windows。未公证的 macOS 包首次打开时可能被 Gatekeeper 阻止，确认下载来源后可在“系统设置 → 隐私与安全性”中允许打开。

## 功能

- 查看、暂存、丢弃文件和部分 diff；支持普通提交、修正提交和补丁导入导出。
- 查看提交图、分支与标签，按哈希、说明、作者和日期搜索，查看文件历史与逐行归属。
- 管理分支、远端、标签和 stash；支持抓取、拉取、推送与克隆。
- 处理 merge、rebase、cherry-pick、revert 和冲突；可打开包含多个仓库的工作区。
- 启动时检查 GitHub 上的新版本，发现后可在应用内直接前往下载。
- 可选用 AI 根据已暂存的 diff 生成提交说明。

## 实现方案

界面使用 Flutter，Git 核心由 Rust 实现，两者通过 flutter_rust_bridge 连接。`gix` 负责可支持的本地读取；网络操作，以及索引、工作区、引用和历史的修改，交给系统 Git CLI，以沿用用户已有的 credential helper、SSH、hooks、签名和 Git LFS 配置。

界面偏好和可选的 AI Token 保存在本机。仅在使用 AI 生成功能时，CGit 会把系统提示词和**已暂存的 diff** 发给用户配置的 OpenAI-compatible `/chat/completions` 服务。HTTPS 远端 Token 交由 Git 当前配置的 credential helper 保存，不进入应用偏好。

## 发布与开发

推送与 `pubspec.yaml`、两个 `Cargo.toml` 和 `flutter_ui/lib/update_check.dart` 中 `appVersion` 一致的 `vX.Y.Z` 标签后，GitHub Actions 自动构建 macOS DMG 和 Windows EXE 安装包，并创建待人工检查的 Release 草稿。签名和公证凭据只通过 GitHub Secrets 提供；未配置时仍会生成未公证的 DMG。

从源码运行、测试和构建请看 [Flutter 开发说明](flutter_ui/README.md)。欢迎在 [Issues](https://github.com/Ckales/CGit/issues) 反馈问题或提交 Pull Request。

## 许可证

[MIT](LICENSE.md)
