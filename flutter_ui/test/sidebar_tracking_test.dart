import 'dart:async';
import 'dart:io' show Platform;

import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/main.dart';
import 'package:cgit_flutter/prefs.dart';
import 'package:cgit_flutter/src/rust/frb_generated.dart'
    show RustLib, RustLibApi;
import 'package:flutter/services.dart';
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
  final pulls = <String>[];
  final pullFailures = <String, String>{};
  final updated = <String>{};
  Completer<void>? pullGate;

  void reset() {
    fetched = Completer<void>();
    repos = _repos;
    fetches = 0;
    pulls.clear();
    pullFailures.clear();
    updated.clear();
    pullGate = null;
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
      [const BranchInfo(name: 'main', isCurrent: true)];

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
    await fetched.future;
    return '';
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
          {required String path, required BigInt limit}) async =>
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
