import 'git_text.dart';
import 'git_types.dart';

/* The web build's data source. `dart:io` does not exist in a browser, so
   `flutter run -d chrome` gets canned data instead of a git subprocess.

   This exists for one reason: seeing the UI without Xcode. The macOS desktop
   build uses git_io.dart and never touches this file — lib/git.dart picks
   between them with a conditional export.

   The fixtures are real output from this repository, so the diff pane is
   rendering text git actually produced rather than something hand-written to
   look convincing. Mutations are kept in memory so the UI stays explorable. */

/// The browser has no working directory; this is only a label.
String get defaultRepoPath => '/demo/CGit';

const _patch = r'''diff --git a/src/git-text.js b/src/git-text.js
index 41d8688..8fff9b7 100644
--- a/src/git-text.js
+++ b/src/git-text.js
@@ -430,11 +430,11 @@ export function credentialAction(info, username, token) {

 /* ---------- folder tree (push dialog) ---------- */

-/** Groups `{path, status}` entries into a folder tree: folders sort before
-    files, a folder that holds nothing but one folder collapses into a single
-    row ("app/api/v1"), and every folder carries the number of files under it.
+/** Groups `{path, status}` entries into a folder tree. Folders sort before
+    files and carry the number of files below them. Single-child folder chains
+    collapse by default; interactive callers can keep every level visible.
     The root keeps an empty name — the caller labels it with the repo name. */
-export function pathTree(files) {
+export function pathTree(files, collapseSingleChild = true) {
   const root = { name: "", dirs: new Map(), files: [] };
   for (const f of files) {
     const parts = String(f.path).split("/");
@@ -445,18 +445,23 @@ export function pathTree(files) {
     }
     node.files.push(f);
   }
-  return closeTree(root);
+  return closeTree(root, collapseSingleChild);
 }

-function closeTree(node) {
+function closeTree(node, collapseSingleChild) {
   // Collapse a chain of single-child folders into one row. The root is exempt:
   // it is the repo, and swallowing "app" into it would hide a real folder.
-  while (node.name !== "" && node.files.length === 0 && node.dirs.size === 1) {
+  while (
+    collapseSingleChild &&
+    node.name !== "" &&
+    node.files.length === 0 &&
+    node.dirs.size === 1
+  ) {
     const only = [...node.dirs.values()][0];
     node = { name: `${node.name}/${only.name}`, dirs: only.dirs, files: only.files };
   }
''';

const _styles = r'''diff --git a/src/styles.css b/src/styles.css
@@ -1615,7 +1615,7 @@
 .split-row {
   display: flex;
-  align-items: center;
+  align-items: stretch;
 }

 .split-no {
''';

class Git {
  Git(this.repo);
  final String repo;

  // Mutable so staging in the UI actually moves a row between the two lists.
  static final _staged = <String>{'src/styles.css'};

  Future<String> currentBranch() async => 'dev';

  Future<List<BranchInfo>> branches() async => const [
        BranchInfo('dev', true),
        BranchInfo('main', false),
        BranchInfo('feature/blame', false),
      ];

  Future<List<String>> tags() async => const ['v0.1.0'];

  Future<List<String>> remotes() async => const ['origin'];

  Future<List<FileStatus>> status() async {
    const paths = {
      'src/git-text.js': 'M',
      'src/styles.css': 'M',
      'src/main.js': 'M',
      'test/git-text.test.js': 'M',
    };
    final out = <FileStatus>[];
    paths.forEach((path, code) {
      out.add(FileStatus(path, code, _staged.contains(path)));
    });
    return out;
  }

  Future<List<GraphCommit>> graph({int limit = 200}) async => const [
        GraphCommit(
          id: '93fbd715c37e9ece7417be0ee3eaa04fec923ec7',
          summary: 'feat: 构建文件路径搜索功能',
          author: 'Ckales',
          time: 1790064207,
          parents: ['cd8ce775a7f0327c9a537e81b2251b469820920b'],
          refs: ['dev'],
        ),
        GraphCommit(
          id: 'cd8ce775a7f0327c9a537e81b2251b469820920b',
          summary: '添加历史提交说明功能和相关样式',
          author: 'Ckales',
          time: 1789979488,
          parents: ['bb1b5464fc57c58662e6d3073deaf220842bcf23'],
          refs: ['origin/main', 'main', 'tag: v0.1.0'],
        ),
        GraphCommit(
          id: 'bb1b5464fc57c58662e6d3073deaf220842bcf23',
          summary: '更新远程认证功能与界面',
          author: 'Ckales',
          time: 1789978699,
          parents: ['593610d10e085e56ff224bfec34504e8755fe31a'],
          refs: [],
        ),
        // A merge, so the DAG painter has two lanes to draw.
        GraphCommit(
          id: '593610d10e085e56ff224bfec34504e8755fe31a',
          summary: 'build: 项目初始化',
          author: 'Ckales',
          time: 1789900000,
          parents: [
            'd79f9c5aa1b2c3d4e5f60718293a4b5c6d7e8f90',
            'a11b22c33d44e55f66071829304a5b6c7d8e9f01',
          ],
          refs: [],
        ),
        GraphCommit(
          id: 'a11b22c33d44e55f66071829304a5b6c7d8e9f01',
          summary: 'chore: 补充 .gitignore',
          author: 'Ckales',
          time: 1789890000,
          parents: ['d79f9c5aa1b2c3d4e5f60718293a4b5c6d7e8f90'],
          refs: [],
        ),
        GraphCommit(
          id: 'd79f9c5aa1b2c3d4e5f60718293a4b5c6d7e8f90',
          summary: 'Initial commit',
          author: 'Ckales',
          time: 1789880000,
          parents: [],
          refs: [],
        ),
      ];

  Future<Hunks> hunks(String file, {required bool staged}) async {
    final patch = file == 'src/styles.css' ? _styles : _patch;
    final split = splitPatchText(patch);
    return Hunks(split.header, split.hunks);
  }

  Future<List<String>> commitFiles(String oid) async =>
      const ['src/git-text.js', 'src/styles.css'];

  Future<Hunks> commitDiff(String oid, String file) async =>
      hunks(file, staged: false);

  Future<void> stage(String file) async => _staged.add(file);
  Future<void> unstage(String file) async => _staged.remove(file);

  Future<void> applyPatch(String patch, {required bool reverse}) async {
    // Nothing to apply to; the pane clears its selection either way.
  }

  Future<void> commit(String message) async {
    if (message.trim().isEmpty) throw GitError('提交说明不能为空');
    _staged.clear();
  }

  static Future<String?> discoverRoot(String start) async => start;
}
