import 'dart:async';

import 'package:cgit_flutter/diff_view.dart';
import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/git_text.dart';
import 'package:cgit_flutter/main.dart';
import 'package:cgit_flutter/prefs.dart';
import 'package:cgit_flutter/src/rust/frb_generated.dart'
    show RustLib, RustLibApi;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _patch(String file) => '@@ -1,160 +1,160 @@\n${[
      for (var i = 0; i < 160; i++)
        if (i % 20 == (file == 'a.dart' ? 2 : 12)) ...[
          '-$file old $i',
          '+$file new $i'
        ] else
          ' $file context $i',
    ].join('\n')}\n';

class _GitApi extends RustLibApi {
  final watch = StreamController<String>.broadcast();
  bool working = false;
  bool multi = false;
  bool changed = false;

  String patch(String file) => changed
      ? _patch(file).replaceFirst('context 0', 'updated context 0')
      : _patch(file);

  @override
  Future<Workspace> crateApiWatchOpenWorkspace({required String path}) async =>
      Workspace(root: '/demo', repos: [
        const RepoRef(path: '/demo', name: 'demo', branch: 'main'),
        if (multi) const RepoRef(path: '/other', name: 'other', branch: 'main'),
      ]);

  @override
  Stream<String> crateApiWatchWatchRepo({required String path}) => watch.stream;

  @override
  Future<List<BranchInfo>> crateApiGitGetBranches(
          {required String path}) async =>
      [const BranchInfo(name: 'main', isCurrent: true)];

  @override
  Future<Tracking> crateApiGitGetBranchTracking({required String path}) async =>
      Tracking(
          branch: 'main',
          upstream: '',
          ahead: BigInt.zero,
          behind: BigInt.zero);

  @override
  Future<String> crateApiGitGitFetch({required String path}) async => '';

  @override
  Future<List<FileStatus>> crateApiGitGetStatus({required String path}) async =>
      working ? files : [];

  List<FileStatus> get files => [
        for (final file in ['a.dart', 'b.dart'])
          FileStatus(path: file, status: 'modified', staged: false)
      ];

  @override
  Future<Identity> crateApiGitGetIdentity({required String path}) async =>
      const Identity(name: 'Tester', email: 'tester@example.test');

  @override
  Future<Hunks> crateApiGitGetHunks(
          {required String path,
          required String file,
          required bool staged}) async =>
      Hunks(header: '', hunks: [patch(file)]);

  @override
  Future<List<GraphCommit>> crateApiGitGetGraph(
          {required String path,
          required BigInt limit,
          String? refName}) async =>
      [
        const GraphCommit(
            id: 'abc1234',
            summary: 'navigation fixture',
            author: 'a',
            time: 0,
            parents: [],
            refs: [])
      ];

  @override
  Future<List<FileStatus>> crateApiGitGetCommitFiles(
          {required String path, required String oid}) async =>
      files;

  @override
  Future<String> crateApiGitGetCommitDiff(
          {required String path,
          required String oid,
          required String file}) async =>
      patch(file);

  @override
  Future<List<String>> crateApiGitGetConflicts({required String path}) async =>
      [];

  @override
  Future<String> crateApiGitGetRepoState({required String path}) async =>
      'none';

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
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _GitApi();
  RustLib.initMock(api: api);
  tearDownAll(api.watch.close);

  Future<ScrollableState> openDiff(WidgetTester tester,
      {DiffMode mode = DiffMode.split,
      bool working = false,
      bool docked = false}) async {
    api.working = working;
    api.multi = docked;
    api.changed = false;
    SharedPreferences.setMockInitialValues({'cgit.diffView': mode.name});
    final prefs = await Prefs.load();
    await tester.pumpWidget(CGitApp(startPath: '/demo', prefs: prefs));
    await tester.pumpAndSettle();
    await tester.tap(docked
        ? find.byTooltip('/demo\n右键切换分支')
        : find.text(working ? '提交' : 'navigation fixture'));
    await tester.pumpAndSettle();
    if (working) await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();
    return tester.state<ScrollableState>(find
        .descendant(
            of: find.byType(DiffPane), matching: find.byType(Scrollable))
        .first);
  }

  for (final presentation in ['history', 'sheet', 'docked']) {
    final working = presentation != 'history';
    for (final mode in DiffMode.values) {
      testWidgets(
          'expand and restore preserves diff state ($presentation, $mode)',
          (tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final scroll = await openDiff(tester,
            working: working, mode: mode, docked: presentation == 'docked');
        final original = tester.getSize(find.byType(DiffPane));
        if (working) {
          final field = find.ancestor(
              of: find.text('提交说明'), matching: find.byType(TextField));
          await tester.enterText(field, 'keep draft');
          await tester.tap(mode == DiffMode.split
              ? find.text('3').first
              : find.text('-a.dart old 2'));
          await tester.pump();
        }
        scroll.position.jumpTo(100);
        await tester.pump();
        await tester.tap(find.byTooltip('放大对比'));
        await tester.pumpAndSettle();
        expect(find.byType(DiffPane), findsOneWidget);
        final enlarged = tester.getSize(find.byType(DiffPane));
        expect(enlarged.width, greaterThan(original.width));
        expect(enlarged.height, greaterThan(original.height));
        expect(scroll.mounted, isTrue);
        expect(scroll.position.pixels, 100);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('还原对比'));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(DiffPane)), original);
        expect(scroll.mounted, isTrue);
        expect(scroll.position.pixels, 100);
        if (working) {
          expect(find.text('keep draft'), findsOneWidget);
          final pickedButton = find.ancestor(
              of: find.text('暂存选中行'), matching: find.byType(GestureDetector));
          expect(tester.widget<GestureDetector>(pickedButton.first).onTap,
              isNotNull);
        }
        await tester.tap(find.byTooltip('放大对比'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byTooltip('放大对比'), findsOneWidget);
        await tester.tap(find.byTooltip('放大对比'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('关闭差异区'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('还原对比'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  void expectBlockVisible(WidgetTester tester, {required bool last}) {
    final pane = tester.widget<DiffPane>(find.byType(DiffPane));
    final rows =
        changeBlockRows(pane.hunks.single, split: pane.mode == DiffMode.split);
    final key = pane.blockKeys['0:${last ? rows.last : rows.first}']!;
    final viewport = tester.getRect(find.descendant(
        of: find.byType(DiffPane),
        matching: find.byWidgetPredicate((w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.vertical)));
    final block = tester.getRect(find.byKey(key));
    expect(block.top, greaterThanOrEqualTo(viewport.top));
    expect(block.bottom, lessThanOrEqualTo(viewport.bottom));
  }

  for (final working in [false, true]) {
    testWidgets('refresh keeps both arrow directions (working=$working)',
        (tester) async {
      final scroll = await openDiff(tester, working: working);
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byTooltip('下一处改动（到底则跳下一个文件）'));
        await tester.pumpAndSettle();
      }
      final beforeDown = scroll.position.pixels;
      api.watch.add('worktree');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一处改动（到底则跳下一个文件）'));
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(beforeDown));

      api.watch.add('worktree');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final beforeUp = scroll.position.pixels;
      await tester.tap(find.byTooltip('上一处改动（到头则跳上一个文件）'));
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, lessThan(beforeUp));

      api.changed = true;
      api.watch.add('worktree');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一处改动（到底则跳下一个文件）'));
      await tester.pumpAndSettle();
      expect(find.text('第 1/8 处改动 — a.dart'), findsOneWidget);
    });
  }

  for (final mode in DiffMode.values) {
    testWidgets('$mode crosses files in both directions and stops at the ends',
        (tester) async {
      await openDiff(tester, mode: mode);
      for (var i = 0; i < 8; i++) {
        await tester.tap(find.byTooltip('下一处改动（到底则跳下一个文件）'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('下一处改动（到底则跳下一个文件）'));
      await tester.pumpAndSettle();
      expect(tester.widget<DiffPane>(find.byType(DiffPane)).hunks.single,
          contains('b.dart new'));
      expectBlockVisible(tester, last: false);

      await tester.tap(find.byTooltip('上一处改动（到头则跳上一个文件）'));
      await tester.pumpAndSettle();
      expect(tester.widget<DiffPane>(find.byType(DiffPane)).hunks.single,
          contains('a.dart new'));
      expectBlockVisible(tester, last: true);

      for (var i = 0; i < 7; i++) {
        await tester.tap(find.byTooltip('上一处改动（到头则跳上一个文件）'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('上一处改动（到头则跳上一个文件）'));
      await tester.pumpAndSettle();
      expect(find.text('已经到第一处改动了'), findsOneWidget);

      for (var i = 0; i < 16; i++) {
        await tester.tap(find.byTooltip('下一处改动（到底则跳下一个文件）'));
        await tester.pumpAndSettle();
      }
      expect(find.text('没有更多改动了'), findsOneWidget);
    });
  }

  testWidgets('opening a different file starts at its top', (tester) async {
    final scroll = await openDiff(tester);
    scroll.position.jumpTo(1200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('b.dart').last);
    await tester.pumpAndSettle();
    final newScroll = tester.state<ScrollableState>(find
        .descendant(
            of: find.byType(DiffPane), matching: find.byType(Scrollable))
        .first);
    expect(newScroll.position.pixels, 0);
  });
}
