# CGit

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.md)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](#系统要求)

JetBrains工具里git提交工具是最好用的Git工具，但是在AI时代，JetBrains工具显得过于笨重了，很多时候不会再频繁的打开JetBrains了，但是市面上没有一款Git工具是可以做到JetBrains这么优秀的（不愧是旧时代的王），于是我用AI写了一款效果能到达JetBrains Git 90%功能的Git GUI：CGit。界面使用原生 HTML/CSS/JavaScript，桌面能力由 Tauri 和 Rust 提供。

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
- [Node.js](https://nodejs.org/) 20.19 或更高版本
- [Rust](https://www.rust-lang.org/tools/install) 1.95 或更高版本
- Xcode Command Line Tools：`xcode-select --install`

AI 提交说明功能还会调用 macOS 自带的 `curl`。

## 从源码运行

```bash
git clone https://github.com/Ckales/CGit.git
cd CGit
npm install
npm run tauri dev
```

首次运行需要编译 Rust 依赖，耗时会明显长于后续启动。

## 构建

```bash
npm run tauri build
```

构建产物位于 `src-tauri/target/release/bundle/`，macOS 下通常包括：

- `macos/cgit.app`
- `dmg/cgit_0.1.0_<arch>.dmg`

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

界面偏好、最近仓库路径和可选 AI 配置保存在应用 WebView 的 `localStorage` 中，不在项目仓库内：

- `cgit.prefs`：主题、字号、布局、编辑器、AI 地址、模型、提示词和 Token
- `cgit.recentRepos`：最近打开的仓库路径

AI Token 当前以明文保存在本机 WebKit LocalStorage。使用 AI 生成功能时，CGit 会把系统提示词和**已暂存的 diff** 发送到你配置的 OpenAI-compatible `/chat/completions` 服务。请勿在不可信设备上保存 Token，也不要把含敏感代码的 diff 发给不可信服务。

Git 用户名和邮箱由 Git 自己管理，写入当前仓库的 `.git/config` 或全局 `~/.gitconfig`。

## 常用快捷键

| 快捷键 | 操作 |
| --- | --- |
| `⌘ O` | 打开仓库或工作区 |
| `⌘ ↵` | 打开提交窗口 / 执行提交 |
| `⇧ ⌘ ↵` | 提交并推送 |
| `⌘ T` / `⌘ L` / `⌘ P` | 抓取 / 拉取 / 推送 |
| `⌘ R` | 刷新 |
| `⌘ N` | 新建分支 |
| `⌘ S` | 创建 stash |
| `⌘ ,` | 打开设置 |
| `Esc` | 关闭当前菜单或弹窗 |

## 开发

```bash
npm test
(cd src-tauri && cargo test)
npm run build
```

项目结构：

```text
src/main.js             前端界面和 Tauri 调用
src/styles.css          界面样式
src/git-text.js         可独立测试的文本、diff 和图形算法
test/                   Node.js 单元测试
src-tauri/src/lib.rs    Rust 后端和 Git 操作
```

## 参与贡献

欢迎通过 [Issues](https://github.com/Ckales/CGit/issues) 报告问题或提出建议，也欢迎提交 Pull Request。

提交代码前请运行与改动范围对应的测试。涉及 `src/git-text.js` 的纯逻辑变更应在 `test/` 中补充回归用例；涉及 Rust Git 行为的变更应在 `src-tauri/src/lib.rs` 的测试模块中覆盖。

## 许可证

CGit 使用 [MIT License](LICENSE.md)。
