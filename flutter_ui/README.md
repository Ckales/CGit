# CGit Flutter 界面

CGit 的 Flutter 桌面界面，Git 核心逻辑位于 `crates/cgit-core`。

## 环境要求

- [Flutter](https://docs.flutter.dev/get-started/install/macos) 3.x（Dart 3.5 或更高）
- Xcode 15 或更高版本
- CocoaPods：`brew install cocoapods`
- [Rust](https://www.rust-lang.org/tools/install) 工具链

## 运行

```bash
cd flutter_ui
flutter pub get
flutter run -d macos
```

可以通过参数直接打开指定仓库：

```bash
flutter run -d macos --dart-entrypoint-args /path/to/repo
```

不带参数时，依次尝试命令行参数、最近打开的仓库和当前目录。

## 构建

```bash
flutter build macos --release
```

产物位于 `build/macos/Build/Products/Release/CGit.app`。

> `macos/Runner/*.entitlements` 中关闭了 App Sandbox，CGit 需要对任意路径调用 `git`。重新执行 `flutter create` 会恢复沙盒，导致无法读取仓库。

## 测试

```bash
flutter analyze
flutter test
```

修改 `cgit-core` 的函数签名后，需要重新生成桥接代码：

```bash
flutter_rust_bridge_codegen generate
```
