# CGit 桌面界面开发

Flutter 界面位于 `lib/`，Git 逻辑位于 `../crates/cgit-core`，`rust/` 仅负责 flutter_rust_bridge 绑定。

## 对比与冲突处理

普通对比默认保留长行，通过底部滚动条或触控板横向滚动；分栏两侧同步移动，行号固定。工具栏可切换自动换行，切换时保留选中的暂存行。

冲突窗口使用左右参考、中间完整结果文档的布局。三方结果初始为完整共同祖先原文，冲突、单侧修改及双方相同的修改都不会自动放入结果。接受一侧即可处理该处冲突，再接受另一侧可保留双方内容；也可忽略一侧或直接编辑结果。接受／忽略按钮位于两侧参考栏靠近结果区的边缘，非冲突修改也可逐处接受或忽略。

工具栏的“合并非冲突修改”一次接受尚未处理的非冲突修改，冲突仍等待手动解决；已有手工编辑、接受和忽略决定都会保留。整次操作可一次撤销。结果也支持跨冲突选择、复制、缩进及撤销／重做（⌘Z／⇧⌘Z）。

F7／⇧F7 和顶部箭头按文件顺序遍历全部差异，包含冲突、单侧修改及双方相同的修改。打开时定位第一处并显示 `1 / 总差异数`；底部另行显示未处理冲突数量。打开或切换差异时定位代码段开头，并从行首展示，不自动选中整段；手动横向滚动仍可使用。同步滚动可关闭。

普通合并从 index 的三个 stage 读取共同祖先和两侧原文；补丁冲突从隔离会话读取这三个版本。没有祖先的 add/add 冲突从空结果开始。无法读取版本时沿用冲突标记解析；标记无法还原冲突区外的原始祖先，因此该回退不能保证上下文等于完整祖先。已有共同祖先内容显示在可收起的参考区，收起不修改文件或丢弃编辑。

文件已在外部合好、没有冲突标记但 Git index 仍有冲突时，打开窗口会保留当前工作区内容，并提供“标记为已解决”。只有用户点击后才保存并标记解决；打开或取消不会自动暂存，也不会从三方版本重新生成结果。空文件同样保留为空。

点击“应用”才保存当前结果并标记解决；未接受的正常修改保留祖先内容，不要求为了保存而接受它们。关闭窗口不会保存。补丁冲突结果先留在预览中，最终“应用到工作区”才写回。比较引擎为 CGit 自身实现，未移植 JetBrains 引擎。

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
