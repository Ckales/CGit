# CGit 桌面界面开发

Flutter 界面位于 `lib/`，Git 逻辑位于 `../crates/cgit-core`，`rust/` 仅负责 flutter_rust_bridge 绑定。

## 环境

- Flutter stable、Rust 1.95+、系统 Git。
- macOS：Xcode、CocoaPods；Windows：Visual Studio 的“使用 C++ 的桌面开发”工作负载。

## 运行与构建

```bash
flutter pub get
flutter run -d macos       # Windows 上改为 -d windows
flutter build macos --release   # Windows 上改为 flutter build windows --release
```

指定仓库路径：`flutter run -d macos --dart-entrypoint-args /path/to/repo`。未传时打开最近使用的仓库。Windows 安装包会包含 `build/windows/x64/runner/Release/` 整个目录以及 VC++ 运行库。macOS runner 关闭了 App Sandbox，以便访问用户选择的仓库；重新生成 runner 后请核对 entitlements。

## 检查与发布

```bash
flutter analyze
flutter test
```

修改 Rust 桥接接口后，在本目录运行 `flutter_rust_bridge_codegen generate`。根目录的 [发布 workflow](../.github/workflows/release.yml) 在推送 `vX.Y.Z` 标签时构建 DMG 和 Windows EXE 安装包，并创建 Release 草稿。

Windows 构建完成后，使用 Inno Setup 6.4.3 或更高的 6.x 版本制作安装包（PowerShell，从仓库根目录运行）：

```powershell
choco install innosetup --version=6.4.3 --yes --no-progress
./flutter_ui/tool/package_windows.ps1
```

输出为 `dist/CGit-版本号-windows-x64-Setup.exe`，版本默认读取 `pubspec.yaml`。安装范围为当前用户，包含开始菜单入口、可选桌面快捷方式和卸载程序；固定的 AppId 用于后续覆盖升级。安装包不包含 Git，用户仍需自行安装 Git for Windows。CI 和发布流程均验证静默安装、重复安装以及卸载；不删除用户偏好或仓库。
