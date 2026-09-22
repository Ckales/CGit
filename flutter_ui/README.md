# flutter_ui — CGit 的 Flutter Desktop UI 对照实现

和 `src/`（vanilla JS + WebKit）实现同一个界面，用来实测两套 UI 框架的差别。
Rust 后端不动：`src-tauri/src/lib.rs` 里的 gix 逻辑原样保留。

## 验证状态

Flutter 3.47.5 / Dart 3.13.4（已装）。以下两步**不需要 Xcode**，当前全绿：

```bash
cd flutter_ui && flutter pub get && flutter analyze && flutter test
```

- `flutter analyze` — No issues found
- `flutter test` — 25 passed（19 条逻辑移植自 `test/git-text.test.js`，6 条 widget 测试覆盖分栏渲染与选行暂存）

## 不装 Xcode 看界面：走 web

```bash
cd flutter_ui && flutter create --platforms=web --project-name cgit_flutter .
flutter run -d chrome          # 或 -d web-server --web-port=8791
```

web 上没有 `dart:io`，所以数据层换成固定样本：`lib/git.dart` 用条件导出在
`git_io.dart`（走 git CLI）和 `git_web.dart`（样本数据，取自本仓库真实输出）之间切换，
上层代码不知道自己拿到的是哪个。

**web 能验证**：布局、配色、DAG 泳道、分栏/统一 diff、行内高亮、点选行暂存、主题切换。
**web 验证不了**：macOS 上的字体渲染、窗口边框、滚动手感，以及真实 git 数据。

## macOS 桌面版

Flutter 3.47.5 要求 **Xcode 15 及以上**（源码 `xcode.dart:24`
`xcodeRequiredVersion => Version(15, null, null)`），不需要最新版 Xcode，也不需要 macOS 26。
这台机器 macOS 15.7.5 装 Xcode 16.x 即可。App Store 只提供最新版，旧版去
developer.apple.com/download/all 取。

| 缺什么 | 影响 | 怎么装 |
|---|---|---|
| 完整 Xcode | 开窗口 / 出包 | App Store 装，然后 `sudo xcode-select -s /Applications/Xcode.app` + `sudo xcodebuild -license accept` |
| CocoaPods | 只在用到插件时需要 | `brew install cocoapods` |

装好后生成 macOS 平台壳（`macos/` 不入库，是 `flutter create` 的产物）并指定仓库：

```bash
cd flutter_ui && flutter create --platforms=macos --project-name cgit_flutter .
flutter run -d macos --dart-entrypoint-args /path/to/repo
```

### 必须关掉 App Sandbox

`flutter create` 生成的 `macos/Runner/*.entitlements` **默认开启 App Sandbox**，
而沙盒进程无法对任意路径执行 `git` 子进程 —— 症状是界面正常但读不到任何仓库数据。
`macos/` 是 gitignored 的生成产物，所以**每次重新 `flutter create` 都要重做一遍**：

```bash
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" macos/Runner/DebugProfile.entitlements
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" macos/Runner/Release.entitlements
```

Tauri 版本来就不开沙盒，所以这是对等配置。真要上 Mac App Store 得反过来：保留沙盒 +
用 NSOpenPanel 让用户手选目录拿 security-scoped bookmark，argv 传路径那套就不能用了 ——
这个约束 Tauri 版同样要面对，不是 Flutter 独有的。

### 已在原生窗口验证

Impeller (Metal) 后端，真实仓库数据。确认正常：中文在 UI 字体和等宽字体里的渲染、
深色主题、DAG 泳道、ref 标签、分栏 diff 与行内高亮、提交列表与文件列表。

**仍未验证**：中文输入法（需要人在键盘前用输入法实打，无法自动化）、
大文件 diff 的滚动性能（`SelectionArea` 强制 eager 构建带来的天花板）。

## 实现了什么

对照的重点放在 diff 视图——那是 `src/main.js` 4447 行里的主体，也是两套框架差别最大的地方。

- `lib/git_text.dart` — `src/git-text.js` 的逐函数移植（分栏配对、行内 diff、部分暂存、DAG 布局）
- `lib/diff_view.dart` — 并排 / 统一双视图、行内高亮、点击 + ⇧ 范围选行、按选中行暂存
- `lib/history_view.dart` — 提交历史 + DAG 泳道（CustomPainter）
- `lib/main.dart` — 工具栏 / 侧栏 / 历史 / 差异 / 状态栏 + 可拖分隔条
- `lib/commit_sheet.dart` — 提交弹窗（暂存、取消暂存、提交）
- `lib/theme.dart` — `styles.css` 的 CSS 变量转成 Dart 常量，明暗两套
- `test/git_text_test.dart` — `test/git-text.test.js` 的逐条移植

## 没实现什么（以及为什么）

**数据层走 git CLI，没接 flutter_rust_bridge。** `lib/git.dart` 直接 `Process.run('git', …)`，
返回结构刻意和 `lib.rs` 里 serialize 的 struct 一一对应。真要换框架时，这个文件换成 frb
生成的绑定即可，`lib.rs` 里的 gix 逻辑一行不用动——那是机械改 80 个 `#[tauri::command]`
包装层，不是重写后端。跳过它是因为它不产生任何 UI 差异，却会吃掉这次对比的大部分时间。

**没做文件选择器。** 需要 `file_selector` 插件，插件要 CocoaPods，CocoaPods 要 Xcode。
仓库路径改从 argv 取。

**没移植的功能**：冲突合并界面、blame、stash、远端凭据、AI 生成提交说明、
右键菜单、推送/拉取/抓取、补丁导出、编辑器集成、偏好持久化。
`git-text.js` 里对应的纯函数（`parseConflicts` / `assembleConflict` / `aiEndpoint` /
`isPushRejected` / `authFailureInfo` / `pathTree` / `nextChangeTarget`）也一并没移植。
这些都是「照着抄一遍」的量，不改变对比结论。

## 已知的框架取舍（代码里标了注释的地方）

1. **跨行文本选择**：DOM 白送；Flutter 要 `SelectionArea`，且它只覆盖已构建的 widget，
   所以 diff 行只能 eager 构建，不能用 `ListView.builder` 懒加载。大文件 diff 会有性能上限。
2. **行号不可选**：CSS 一句 `user-select: none`；Flutter 要包 `SelectionContainer.disabled`。
3. **hover 高亮**：CSS 一条 `:hover` 规则；Flutter 每行要 `MouseRegion` + `setState`，
   而且没有 `filter: brightness()`，只能叠一层半透明色。
4. **斜纹占位格**：CSS 一行 `repeating-linear-gradient`；Flutter 要写 `CustomPainter`。
5. **DAG 泳道**：这是唯一 Flutter 更短的地方——`CustomPainter` 比每行内联 SVG 干净。
