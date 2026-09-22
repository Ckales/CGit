# flutter_ui — CGit 的 Flutter Desktop 前端

和 `src/`（vanilla JS + WebKit）是同一个 app 的两套界面实现，**共用同一份 Rust 后端**。

```
crates/cgit-core/     全部 Git 逻辑（gix + git CLI），零前端依赖，26 个测试
├── src-tauri/        Tauri 前端：80 个 #[tauri::command] 薄包装
└── flutter_ui/rust/  Flutter 前端：flutter_rust_bridge 薄包装
```

两个前端都只做「翻译」，不含任何 Git 规则。任何行为变更都发生在 `cgit-core`——测试在那里，
两边同时受益，也就不会漂移。

## 构建

需要 **Xcode 15 及以上**（Flutter 3.47.5 的硬要求，见其源码 `xcode.dart:24`
`xcodeRequiredVersion => Version(15, null, null)`）。不需要最新版 Xcode，也不需要 macOS 26。
App Store 只提供最新版，旧版去 developer.apple.com/download/all 取。

**CocoaPods 是必需的**：cargokit 通过 podspec 把 Rust 静态库挂进 Xcode 构建。

```bash
brew install cocoapods
cd flutter_ui && flutter pub get
flutter run -d macos --dart-entrypoint-args /path/to/repo
```

仓库路径从 argv 取，默认当前目录。文件选择器还没做（需要 `file_selector` 插件）。

### macos/ 必须入库

`macos/Runner/*.entitlements` 里**关闭了 App Sandbox**。沙盒进程无法对任意路径执行 `git`
子进程，症状是界面完全正常但读不到任何仓库数据——很容易误判成代码 bug。

早期版本把 `macos/` 当成 `flutter create` 的产物忽略掉了，那是错的：Flutter 官方模板本来就把
平台目录入库，并用 `macos/.gitignore` 排除 `ephemeral/`、`Pods/`、`xcuserdata/` 这些真生成物。

如果哪天重新 `flutter create --platforms=macos .`，沙盒会被带回来，需要重做一次：

```bash
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" macos/Runner/DebugProfile.entitlements
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" macos/Runner/Release.entitlements
```

Tauri 版本来就不开沙盒，所以这是对等配置。真要上 Mac App Store 得反过来：保留沙盒 + 用
NSOpenPanel 让用户手选目录拿 security-scoped bookmark，argv 传路径那套就不能用了——这个约束
Tauri 版同样要面对，不是 Flutter 独有的。

### 改了 Rust 之后

`cgit-core` 的函数签名变了，就要重新生成绑定：

```bash
cd flutter_ui && flutter_rust_bridge_codegen generate
```

生成物（`lib/src/rust/`、`rust/src/frb_generated.rs`）**入库**，所以普通构建不需要装
codegen 工具。

## 验证

```bash
cd flutter_ui && flutter analyze && flutter test   # 不需要 Xcode
cd crates/cgit-core && cargo test                  # 后端逻辑
```

当前：`flutter analyze` 干净，`flutter test` 52 passed，`cargo test` 26 passed。

**已在原生窗口验证**：Impeller (Metal) 后端、真实仓库数据、中文在 UI 与等宽字体下的渲染、
深色/浅色主题、DAG 泳道、ref 标签、分栏与统一 diff、行内高亮、点选行暂存、提交弹窗输入。

**仍未验证**：大文件 diff 的滚动性能（见下方取舍第 1 条）。

## 目前实现到哪

已接到界面的 core 命令：**17 / 81**。绑定全部生成，但多数还没铺到 UI 上。

已有：仓库/分支/远端/标签列表、历史与 DAG、分栏与统一 diff、行内高亮、点击 + ⇧ 范围选行、
按选中行暂存/取消暂存、提交弹窗（暂存、取消暂存、提交）、明暗主题、可拖分隔条。

还没做：冲突合并界面、blame、stash、远端凭据、AI 提交说明、右键菜单、推送/拉取/抓取、
补丁导出、编辑器集成、多仓库切换、提交搜索与过滤、reset/revert/cherry-pick、交互式 rebase、
标签与远端管理、偏好持久化、release 打包、完整快捷键（现只有 ⌘↵ / ⌘R / Esc 三个）。

## 已知的框架取舍（代码里都有对应注释）

1. **跨行文本选择**：DOM 白送；Flutter 要 `SelectionArea`，且它只覆盖已构建的 widget，
   所以 diff 行只能 eager 构建，不能用 `ListView.builder` 懒加载。**大文件 diff 有性能上限，
   这是这套实现唯一真正的架构约束。**
2. **行号不可选**：CSS 一句 `user-select: none`；Flutter 要包 `SelectionContainer.disabled`。
3. **hover 高亮**：CSS 一条 `:hover` 规则；Flutter 每行要 `MouseRegion` + `setState`，
   而且没有 `filter: brightness()`，只能叠一层半透明色。
4. **斜纹占位格**：CSS 一行 `repeating-linear-gradient`；Flutter 要写 `CustomPainter`。
5. **Material 祖先**：这个界面不用 `Scaffold`，而 `Scaffold` 正是通常提供 `Material` 的那一层。
   `TextField` 强依赖它，缺了会渲染成红色报错块而不是输入框——`main.dart` 根部那个
   `Material(type: MaterialType.transparency)` 就是为此。
6. **DAG 泳道**：唯一 Flutter 更短的地方——`CustomPainter` 比每行内联 SVG 干净。

## 不再支持 web

早期为了在没装 Xcode 时能看界面，做过一个走固定样本数据的 web 构建。数据层统一到
`cgit-core` 之后它被移除了：浏览器没有 FFI，维持一份平行的假数据实现要跟着 81 个命令走，
代价大于收益。需要的话 `git log` 里能找回来。
