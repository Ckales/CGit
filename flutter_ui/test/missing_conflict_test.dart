import 'dart:async';

import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/main.dart';
import 'package:cgit_flutter/merge_view.dart' show MergeWindow;
import 'package:cgit_flutter/prefs.dart';
import 'package:cgit_flutter/src/rust/frb_generated.dart'
    show RustLib, RustLibApi;
import 'package:flutter/material.dart' show TextField;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _missingFile = 'tests/test_project_data_access.py';

class _MissingConflictApi extends RustLibApi {
  final staged = <String>[];
  final deleted = <String>[];
  final writes = <String>[];
  final events = StreamController<String>.broadcast();
  bool unresolved = true;
  String? content;
  String? readError;
  ConflictVersions versions = const ConflictVersions();

  @override
  Future<Workspace> crateApiWatchOpenWorkspace({required String path}) async =>
      const Workspace(root: '/demo', repos: [
        RepoRef(path: '/demo', name: 'demo', branch: 'test'),
      ]);

  @override
  Stream<String> crateApiWatchWatchRepo({required String path}) =>
      events.stream;

  @override
  Future<List<BranchInfo>> crateApiGitGetBranches(
          {required String path}) async =>
      [BranchInfo(name: 'test', isCurrent: true)];

  @override
  Future<Tracking> crateApiGitGetBranchTracking({required String path}) async =>
      Tracking(
          branch: 'test',
          upstream: '',
          ahead: BigInt.zero,
          behind: BigInt.zero);

  @override
  Future<List<FileStatus>> crateApiGitGetStatus({required String path}) async =>
      unresolved
          ? [
              const FileStatus(
                  path: _missingFile, status: 'conflict', staged: false)
            ]
          : [];

  @override
  Future<List<GraphCommit>> crateApiGitGetGraph(
          {required String path,
          required BigInt limit,
          String? refName}) async =>
      [];

  @override
  Future<List<String>> crateApiGitGetConflicts({required String path}) async =>
      unresolved ? [_missingFile] : [];

  @override
  Future<String> crateApiGitGetRepoState({required String path}) async =>
      'merge';

  @override
  Future<List<String>> crateApiGitGetTags({required String path}) async => [];

  @override
  Future<List<RemoteInfo>> crateApiGitGetRemotes(
          {required String path}) async =>
      [];

  @override
  Future<List<StashEntry>> crateApiGitStashList({required String path}) async =>
      [];

  @override
  Future<List<String>> crateApiGitGetRemoteBranches(
          {required String path}) async =>
      [];

  @override
  Future<String> crateApiGitReadWorktreeFile(
          {required String path, required String file}) async =>
      throw 'No such file or directory (os error 2)';

  @override
  Future<String?> crateApiGitReadConflictWorktree(
      {required String path, required String file}) async {
    if (readError != null) throw readError!;
    return content;
  }

  @override
  Future<ConflictVersions> crateApiGitGetConflictVersions(
          {required String path, required String file}) async =>
      versions;

  @override
  Future<String?> crateApiGitMergeSource({required String path}) async =>
      'apps';

  @override
  Future<void> crateApiGitResolveDeletedConflict(
      {required String path, required String file}) async {
    if (content != null) throw '文件已恢复，请重新检查';
    if (!unresolved) throw '该文件已无冲突';
    deleted.add(file);
    unresolved = false;
  }

  @override
  Future<void> crateApiGitResolveWithContent(
      {required String path,
      required String file,
      required String content}) async {
    writes.add(content);
    unresolved = false;
  }

  @override
  Future<void> crateApiGitStageFile(
      {required String path, required String file}) async {
    staged.add(file);
    unresolved = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _MissingConflictApi();
  RustLib.initMock(api: api);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api.unresolved = true;
    api.staged.clear();
    api.deleted.clear();
    api.writes.clear();
    api.content = null;
    api.readError = null;
    api.versions = const ConflictVersions();
  });

  tearDownAll(() => api.events.close());

  Future<void> openRepo(WidgetTester tester) async {
    final prefs = await Prefs.load();
    await tester.pumpWidget(CGitApp(startPath: '/demo', prefs: prefs));
    await tester.pumpAndSettle();
  }

  const versions = ConflictVersions(
    base: 'head\nbase\ntail\n',
    ours: 'head\nours\ntail\n',
    theirs: 'head\ntheirs\ntail\n',
  );

  for (final content in ['', 'head\nmerged externally\ntail\n']) {
    testWidgets(
        'externally resolved ${content.isEmpty ? 'empty' : 'text'} worktree keeps its result despite unmerged index stages',
        (tester) async {
      api.content = content;
      api.versions = versions;
      await openRepo(tester);
      await tester.tap(find.text(_missingFile).first);
      await tester.pumpAndSettle();

      final editor = tester.widget<TextField>(find.descendant(
          of: find.byType(MergeWindow), matching: find.byType(TextField)));
      expect(editor.controller!.text, content);
      expect(find.text('标记为已解决'), findsOneWidget);
      expect(api.writes, isEmpty);
      expect(api.staged, isEmpty);
      expect(api.unresolved, isTrue);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(api.unresolved, isTrue);

      await tester.tap(find.text(_missingFile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('标记为已解决'));
      await tester.pumpAndSettle();

      expect(api.writes, [content]);
      expect(api.staged, isEmpty);
      expect(api.deleted, isEmpty);
      expect(find.text('合并进行中 — 冲突已解决，可继续'), findsOneWidget);
    });
  }

  testWidgets('remaining markers still open the three-way merge',
      (tester) async {
    api.content =
        'head\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> apps\ntail\n';
    api.versions = versions;
    await openRepo(tester);
    await tester.tap(find.text(_missingFile).first);
    await tester.pumpAndSettle();

    final editor = tester.widget<TextField>(find.descendant(
        of: find.byType(MergeWindow), matching: find.byType(TextField)));
    expect(editor.controller!.text, versions.base);
    expect(find.text('标记为已解决'), findsNothing);
    expect(api.writes, isEmpty);
    expect(api.unresolved, isTrue);
  });

  testWidgets(
      'missing conflict offers explicit deletion resolution without staging automatically',
      (tester) async {
    await openRepo(tester);
    await tester.tap(find.text(_missingFile).first);
    await tester.pumpAndSettle();

    expect(find.text('保留删除并标记解决'), findsOneWidget);
    expect(find.textContaining('No such file or directory'), findsNothing);
    expect(api.staged, isEmpty);
    expect(api.deleted, isEmpty);
    expect(api.writes, isEmpty);
    expect(api.unresolved, isTrue);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('合并进行中 — 1 处冲突待解决'), findsOneWidget);
    expect(api.deleted, isEmpty);
  });

  testWidgets(
      'confirming deletion resolves only that path and refreshes the banner',
      (tester) async {
    await openRepo(tester);
    await tester.tap(find.text(_missingFile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留删除并标记解决'));
    await tester.pumpAndSettle();

    expect(api.deleted, [_missingFile]);
    expect(api.staged, isEmpty);
    expect(api.writes, isEmpty);
    expect(find.text('合并进行中 — 冲突已解决，可继续'), findsOneWidget);
  });

  testWidgets(
      'an external index resolution removes the old conflict on watcher refresh',
      (tester) async {
    await openRepo(tester);
    expect(find.text('合并进行中 — 1 处冲突待解决'), findsOneWidget);
    api.unresolved = false;
    api.events.add('worktree');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('合并进行中 — 冲突已解决，可继续'), findsOneWidget);
    expect(api.deleted, isEmpty);
    expect(api.writes, isEmpty);
  });

  testWidgets(
      'opening an externally resolved stale path refreshes instead of offering deletion',
      (tester) async {
    await openRepo(tester);
    api.unresolved = false;
    await tester.tap(find.text(_missingFile).first);
    await tester.pumpAndSettle();

    expect(find.text('保留删除并标记解决'), findsNothing);
    expect(find.textContaining('No such file or directory'), findsNothing);
    expect(find.text('合并进行中 — 冲突已解决，可继续'), findsOneWidget);
    expect(api.deleted, isEmpty);
  });

  testWidgets('a restored file is not staged as a deletion after confirmation',
      (tester) async {
    await openRepo(tester);
    await tester.tap(find.text(_missingFile).first);
    await tester.pumpAndSettle();
    api.content = 'restored file\n';
    await tester.tap(find.text('保留删除并标记解决'));
    await tester.pumpAndSettle();

    expect(api.deleted, isEmpty);
    expect(api.staged, isEmpty);
    expect(api.writes, isEmpty);
    expect(find.textContaining('文件已恢复'), findsWidgets);
    expect(api.unresolved, isTrue);
  });

  testWidgets('permission errors are not treated as deleted files',
      (tester) async {
    api.readError = 'Permission denied';
    await openRepo(tester);
    await tester.tap(find.text(_missingFile).first);
    await tester.pumpAndSettle();

    expect(find.text('保留删除并标记解决'), findsNothing);
    expect(find.textContaining('Permission denied'), findsWidgets);
    expect(api.deleted, isEmpty);
  });

  testWidgets(
      'an existing empty file opens the editor rather than deletion confirmation',
      (tester) async {
    api.content = '';
    await openRepo(tester);
    await tester.tap(find.text(_missingFile).first);
    await tester.pumpAndSettle();

    expect(find.text('保留删除并标记解决'), findsNothing);
    expect(find.text('无文本冲突标记 — 整文件处理'), findsOneWidget);
    expect(api.deleted, isEmpty);
  });
}
