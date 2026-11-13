import 'dart:async';
import 'dart:io' show Platform;

import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/main.dart';
import 'package:cgit_flutter/prefs.dart';
import 'package:cgit_flutter/src/rust/frb_generated.dart'
    show RustLib, RustLibApi;
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repos = [
  RepoRef(path: '/workspace/api', name: 'api', branch: 'main'),
  RepoRef(path: '/workspace/web', name: 'web', branch: 'main'),
];

class _GitApi extends RustLibApi {
  var fetched = Completer<void>();
  List<RepoRef> repos = _repos;
  int fetches = 0;
  final fetchGates = <String, Completer<void>>{};
  final branchUpdates = <String>[];
  final branchPushes = <String>[];
  final createdBranches = <String>[];
  final currentBranches = <String, String>{};
  final pulls = <String>[];
  final pullFailures = <String, String>{};
  final updated = <String>{};
  Completer<void>? pullGate;
  Completer<void>? branchUpdateGate;
  String? fetchFailure;

  void reset() {
    fetched = Completer<void>();
    repos = _repos;
    fetches = 0;
    fetchGates.clear();
    branchUpdates.clear();
    branchPushes.clear();
    createdBranches.clear();
    currentBranches.clear();
    pulls.clear();
    pullFailures.clear();
    updated.clear();
    pullGate = null;
    branchUpdateGate = null;
    fetchFailure = null;
  }

  @override
  Future<Workspace> crateApiWatchOpenWorkspace({required String path}) async =>
      Workspace(root: '/workspace', repos: repos);

  @override
  Stream<String> crateApiWatchWatchRepo({required String path}) =>
      const Stream.empty();

  @override
  Future<List<BranchInfo>> crateApiGitGetBranches(
          {required String path}) async =>
      [BranchInfo(name: currentBranches[path] ?? 'main', isCurrent: true)];

  @override
  Future<Tracking> crateApiGitGetBranchTracking({required String path}) async {
    return Tracking(
      branch: 'main',
      upstream: 'origin/main',
      ahead: BigInt.zero,
      behind: fetched.isCompleted && !updated.contains(path)
          ? BigInt.from(3)
          : BigInt.zero,
    );
  }

  @override
  Future<String> crateApiGitGitFetch({required String path}) async {
    fetches++;
    await (fetchGates[path] ?? fetched).future;
    if (fetchFailure != null) throw fetchFailure!;
    return '';
  }

  @override
  Future<String> crateApiGitUpdateBranch(
      {required String path, required String name}) async {
    branchUpdates.add('$path:$name');
    if (branchUpdateGate != null) await branchUpdateGate!.future;
    return 'Updated $path';
  }

  @override
  Future<String> crateApiGitPushBranch(
      {required String path, required String name}) async {
    branchPushes.add('$path:$name');
    return 'Pushed $path';
  }

  @override
  Future<void> crateApiGitCreateBranch(
      {required String path,
      required String name,
      required bool checkout,
      String? base}) async {
    createdBranches.add('$path:$name:$base:$checkout');
    if (checkout) currentBranches[path] = name;
  }

  @override
  Future<String> crateApiGitGitPull(
      {required String path, String? strategy}) async {
    expect(strategy, isNull, reason: 'keep the default ff-only strategy');
    pulls.add(path);
    if (pullGate != null) await pullGate!.future;
    final failure = pullFailures[path];
    if (failure != null) throw failure;
    updated.add(path);
    return 'Updated $path';
  }

  @override
  Future<List<FileStatus>> crateApiGitGetStatus({required String path}) async =>
      [];

  @override
  Future<List<GraphCommit>> crateApiGitGetGraph(
          {required String path,
          required BigInt limit,
          String? refName}) async =>
      [];

  @override
  Future<List<String>> crateApiGitGetConflicts({required String path}) async =>
      [];

  @override
  Future<String> crateApiGitGetRepoState({required String path}) async => '';

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
  SharedPreferences.setMockInitialValues({});
  final api = _GitApi();
  RustLib.initMock(api: api);
  setUp(api.reset);

  Future<void> openWorkspace(WidgetTester tester) async {
    api.fetched.complete();
    final prefs = await Prefs.load();
    await tester.pumpWidget(CGitApp(startPath: '/workspace', prefs: prefs));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets('workspace fetch reveals behind counts in the sidebar',
      (tester) async {
    final prefs = await Prefs.load();
    await tester.pumpWidget(CGitApp(startPath: '/workspace', prefs: prefs));
    await tester.pumpAndSettle();

    expect(api.fetches, 2);
    expect(find.text('↓3'), findsNothing);

    await tester.runAsync(() async {
      api.fetched.complete();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    // Two repo rows, the current branch row, and the active repo's toolbar.
    expect(find.text('↓3'), findsNWidgets(4));
  });

  Future<void> updateCurrentBranch(WidgetTester tester) async {
    await tester.tap(find.text('main').last, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新'));
    await tester.pumpAndSettle();
  }

  testWidgets('branch update does not wait for another repos background fetch',
      (tester) async {
    api.fetchGates['/workspace/web'] = Completer<void>();
    await openWorkspace(tester);
    expect(api.fetches, 2);

    await updateCurrentBranch(tester);
    expect(api.branchUpdates, ['/workspace/api:main']);
    expect(api.fetchGates['/workspace/web']!.isCompleted, isFalse);

    api.fetchGates['/workspace/web']!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('update waits for its own fetch and keeps the clicked repo',
      (tester) async {
    final prefs = await Prefs.load();
    await tester.pumpWidget(CGitApp(startPath: '/workspace', prefs: prefs));
    await tester.pumpAndSettle();
    await updateCurrentBranch(tester);
    expect(api.branchUpdates, isEmpty);
    expect(find.textContaining('等待当前仓库抓取完成'), findsOneWidget);

    await tester.tap(find.text('web').last);
    await tester.pumpAndSettle();
    api.fetched.complete();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(api.branchUpdates, ['/workspace/api:main']);
  });

  testWidgets('toolbar pull is accepted during background fetch failure',
      (tester) async {
    final prefs = await Prefs.load();
    await tester.pumpWidget(CGitApp(startPath: '/workspace', prefs: prefs));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拉取'));
    await tester.pumpAndSettle();
    expect(find.textContaining('等待当前仓库抓取完成'), findsOneWidget);
    expect(api.pulls, isEmpty);

    api.fetchFailure = 'fatal: network unavailable';
    api.fetched.complete();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(api.pulls, ['/workspace/api', '/workspace/web']);
  });

  testWidgets('background completion does not release a running user action',
      (tester) async {
    final otherFetch = Completer<void>();
    api.fetchGates['/workspace/web'] = otherFetch;
    api.branchUpdateGate = Completer<void>();
    await openWorkspace(tester);
    await updateCurrentBranch(tester);
    expect(api.branchUpdates, ['/workspace/api:main']);

    otherFetch.complete();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拉取'));
    await tester.pumpAndSettle();
    expect(api.pulls, isEmpty);

    api.branchUpdateGate!.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.text('拉取'));
    await tester.pumpAndSettle();
    expect(api.pulls, ['/workspace/api', '/workspace/web']);
  });

  Future<void> openRepoMenu(WidgetTester tester, String repo) async {
    await tester.tap(find.text(repo).last, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
  }

  testWidgets('repo menu updates the clicked repo using its live branch',
      (tester) async {
    api.currentBranches['/workspace/web'] = 'develop';
    await openWorkspace(tester);
    await openRepoMenu(tester, 'web');
    expect(find.text("从 'develop' 新建分支…"), findsOneWidget);
    expect(find.text('web · 本地分支'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '更新');
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新').last);
    await tester.pumpAndSettle();
    expect(api.branchUpdates, ['/workspace/web:develop']);
    expect(find.text('workspace / api'), findsOneWidget);
  });

  testWidgets('repo menu push waits for the clicked repos fetch',
      (tester) async {
    final gate = Completer<void>();
    api.fetchGates['/workspace/web'] = gate;
    await openWorkspace(tester);
    await openRepoMenu(tester, 'web');
    await tester.tap(find.text('推送').last);
    await tester.pumpAndSettle();
    expect(api.branchPushes, isEmpty);
    expect(find.textContaining('等待当前仓库抓取完成'), findsOneWidget);
    gate.complete();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(api.branchPushes, ['/workspace/web:main']);
    expect(find.text('workspace / api'), findsOneWidget);
  });

  testWidgets('repo menu creates and checks out a branch only in clicked repo',
      (tester) async {
    await openWorkspace(tester);
    await openRepoMenu(tester, 'web');
    await tester.tap(find.text("从 'main' 新建分支…"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'feature/menu');
    await tester.tap(find.text('创建并检出'));
    await tester.pumpAndSettle();
    expect(api.createdBranches, ['/workspace/web:feature/menu:main:true']);
    expect(find.text('feature/menu'), findsOneWidget);
    expect(find.text('workspace / api'), findsOneWidget);
  });

  testWidgets('repo menu branch creation can be cancelled', (tester) async {
    await openWorkspace(tester);
    await openRepoMenu(tester, 'api');
    await tester.tap(find.text("从 'main' 新建分支…"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.createdBranches, isEmpty);
  });

  testWidgets('active repo menu creates and refreshes its branch',
      (tester) async {
    await openWorkspace(tester);
    await openRepoMenu(tester, 'api');
    await tester.tap(find.text("从 'main' 新建分支…"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'feature/active');
    await tester.tap(find.text('创建并检出'));
    await tester.pumpAndSettle();
    expect(api.createdBranches, ['/workspace/api:feature/active:main:true']);
    expect(find.text('feature/active'), findsWidgets);
    expect(find.text('workspace / api'), findsOneWidget);
  });

  testWidgets(
      'detached repo menu can create from HEAD and retains network actions',
      (tester) async {
    api.currentBranches['/workspace/web'] = '';
    await openWorkspace(tester);
    await openRepoMenu(tester, 'web');
    expect(find.text('更新'), findsOneWidget);
    expect(find.text('推送'), findsNWidgets(2));
    await tester.tap(find.text("从 'HEAD' 新建分支…"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'feature/detached');
    await tester.tap(find.text('创建并检出'));
    await tester.pumpAndSettle();
    expect(api.createdBranches, ['/workspace/web:feature/detached:HEAD:true']);
    expect(find.text('workspace / api'), findsOneWidget);
  });

  testWidgets('operation failures open complete details automatically',
      (tester) async {
    await openWorkspace(tester);
    final error =
        List.generate(100, (i) => 'fatal: failure line $i').join('\n');
    api.pullFailures['/workspace/api'] = error;
    await tester.tap(find.text('拉取'));
    await tester.pumpAndSettle();

    expect(find.text('操作失败'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    final details = find.descendant(
        of: find.byType(Dialog), matching: find.byType(SelectableText));
    expect(tester.widget<SelectableText>(details).data, contains(error));
    expect(find.text('确定').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    await tester.tap(find.text('查看详情'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(tester.widget<SelectableText>(details).data, contains(error));
  });

  testWidgets('pull button updates every repo after changing the selection',
      (tester) async {
    await openWorkspace(tester);
    await tester.tap(find.text('web').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('拉取'));
    await tester.pumpAndSettle();

    expect(api.pulls, ['/workspace/api', '/workspace/web']);
    expect(find.text('↓3'), findsNothing);
    expect(find.text('拉取完成。已拉取 2 个仓库'), findsOneWidget);
  });

  testWidgets('pull shortcut continues after failure and refreshes other repos',
      (tester) async {
    await openWorkspace(tester);
    api.pullFailures['/workspace/api'] = 'fatal: local changes block pull';

    final modifier = Platform.isMacOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();

    expect(api.pulls, ['/workspace/api', '/workspace/web']);
    expect(api.updated, {'/workspace/web'});
    expect(find.text('↓3'), findsNWidgets(3));
    expect(find.textContaining('api：fatal: local changes block pull'),
        findsWidgets);
  });

  testWidgets('single repo pull preserves the command output', (tester) async {
    api.repos = [_repos.first];
    await openWorkspace(tester);
    await tester.tap(find.text('拉取'));
    await tester.pumpAndSettle();

    expect(api.pulls, ['/workspace/api']);
    expect(find.text('拉取完成。Updated /workspace/api'), findsOneWidget);
  });

  testWidgets('pull stays serial and cannot be started twice while busy',
      (tester) async {
    await openWorkspace(tester);
    api.pullGate = Completer<void>();
    await tester.tap(find.text('拉取'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拉取'));
    await tester.pumpAndSettle();
    expect(api.pulls, ['/workspace/api']);

    api.pullGate!.complete();
    await tester.pumpAndSettle();
    expect(api.pulls, ['/workspace/api', '/workspace/web']);
  });
}
