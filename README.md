# CGit

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.md)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](#系统要求)

CGit 是一款面向 macOS 的 Git 图形客户端，交互参考 JetBrains IDE 内置的 Git 工具，但以独立、轻量的桌面应用形式提供。界面使用 Flutter 构建，Git 核心逻辑由 Rust 实现，两者通过 flutter_rust_bridge 连接。

> 当前为早期版本，仅支持 macOS，暂未提供签名和公证的官方安装包。

## 功能

### 日常修改与提交

- 查看已暂存、未暂存、未跟踪和冲突文件
- 暂存或取消暂存文件、hunk、单行及连续行范围
- 暂存全部、按路径过滤、丢弃工作区改动
- 并排/统一 diff、双侧行号和词级高亮
- 普通提交、修正提交、Sign-off、临时覆盖作者
- 导入、导出工作区补丁和指定提交补丁
- 可选的 AI 提交说明生成

### 历史与代码阅读

- 图形化提交 DAG、分支和标签标记
- 按提交说明和作者搜索
- 查看提交文件及逐文件 diff
- 文件历史（跟随重命名）和逐行归属（blame）

### 分支与远端协作

- 创建、切换、重命名和删除本地分支
- 查看跟踪关系及领先/落后数量
- 克隆、抓取、拉取、推送和 `--force-with-lease`
- 管理远端、远端分支和标签
- 创建、弹出和删除 stash

### 合并与历史改写

- Merge、revert、cherry-pick 和 soft/mixed/hard reset
- 交互式 rebase：pick、reword、squash、fixup、drop 和 autostash
- 三方冲突视图、ours/theirs、手动编辑及继续/中止/跳过操作

### 多仓库工作区

打开一个自身没有 `.git`、但子目录包含多个仓库的文件夹，即可作为工作区使用：

- 变更列表、普通提交和冲突面板覆盖工作区内的仓库
- 抓取对全部仓库执行
- 分支、历史、stash、远端、标签、拉取、推送和修正提交跟随当前选中的仓库
- 普通提交只处理已有暂存内容的仓库；某个仓库失败不会回滚其他仓库

## 系统要求

- macOS
- [Git](https://git-scm.com/) 命令行工具
- [Flutter](https://docs.flutter.dev/get-started/install/macos) 3.x（Dart 3.5 或更高）
- [Rust](https://www.rust-lang.org/tools/install) 1.95 或更高版本
- Xcode 15 或更高版本
- CocoaPods：`brew install cocoapods`

AI 提交说明功能还会调用 macOS 自带的 `curl`。

## 从源码运行

```bash
git clone https://github.com/Ckales/CGit.git
cd CGit/flutter_ui
flutter pub get
flutter run -d macos
```

首次运行需要编译 Rust 依赖，耗时会明显长于后续启动。

## 构建

```bash
cd flutter_ui
flutter build macos --release
```

构建产物位于 `flutter_ui/build/macos/Build/Products/Release/CGit.app`。

仓库目前没有配置 Developer ID 签名、公证或自动更新。从源码生成的应用复制到其他 Mac 后，可能被 Gatekeeper 拦截。

## Git 行为

CGit 的本地读取主要使用 [gitoxide](https://github.com/GitoxideLabs/gitoxide) 的 `gix`。网络操作以及会修改索引、工作区或历史的操作调用系统 `git`，以保持与命令行一致的行为，包括：

- credential helper 和 SSH 密钥
- Git hooks
- `commit.gpgsign`
- Git LFS clean/smudge filters

因此，CGit 不单独保存远端仓库密码。

对于 HTTPS 远端，可以在“设置 → Git 信息 → 远程认证”查看 Git 当前解析到的账号、切换用户名和 Personal Access Token，并用 dry-run 测试真实推送权限。Token 通过 Git credential helper 写入系统钥匙串，不会进入 CGit 的应用配置。

## 配置与隐私

界面偏好、最近仓库路径和 AI 服务配置（含 AI Token）保存在应用的 `shared_preferences` 中，不在项目仓库内。

使用 AI 生成功能时，CGit 会把系统提示词和**已暂存的 diff** 发送到你配置的 OpenAI-compatible `/chat/completions` 服务。请不要把含敏感代码的 diff 发给不可信服务。

Git 用户名和邮箱由 Git 自己管理，写入当前仓库的 `.git/config` 或全局 `~/.gitconfig`。

## 常用快捷键

| 快捷键 | 操作 |
| --- | --- |
| `⌘ O` | 打开仓库或工作区 |
| `⌘ ↵` | 打开提交窗口 / 执行提交 |
| `⌘ T` / `⌘ L` / `⌘ P` | 抓取 / 拉取 / 推送 |
| `⌘ R` | 刷新 |
| `⌘ N` | 新建分支 |
| `⌘ S` | 创建 stash |
| `⌘ ,` | 打开设置 |
| `Esc` | 关闭当前菜单或弹窗 |

## 开发

```bash
(cd crates/cgit-core && cargo test)
(cd flutter_ui && flutter analyze && flutter test)
```

项目结构：

```text
crates/cgit-core/       Git 核心逻辑（gix + git CLI）
flutter_ui/lib/         Flutter 界面
flutter_ui/rust/        flutter_rust_bridge 绑定
flutter_ui/test/        界面与文本逻辑测试
```

## 参与贡献

欢迎通过 [Issues](https://github.com/Ckales/CGit/issues) 报告问题或提出建议，也欢迎提交 Pull Request。

提交 Pull Request 前请确保上述测试通过。

## 许可证

CGit 使用 [MIT License](LICENSE.md)。
