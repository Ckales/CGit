import 'dart:async';

import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/main.dart';
import 'package:cgit_flutter/prefs.dart';
import 'package:cgit_flutter/src/rust/frb_generated.dart'
    show RustLib, RustLibApi;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _GitApi extends RustLibApi {
  String currentBranch = 'main';
  final checkouts = <String>[];
  final remoteCheckouts = <String>[];
  String? checkoutFailure;
  final graphRefs = <String?>[];
  final searchRefs = <String?>[];
  final graphs = <String, Completer<List<GraphCommit>>>{};
  final searches = <String, Completer<List<CommitInfo>>>{};

  GraphCommit commit(String name) => GraphCommit(
      id: name == 'main' ? '1111111' : '2222222',
      summary: '$name history',
      author: 'Tester',
      time: 0,
      parents: const [],
      refs: const []);

  @override
  Future<Workspace> crateApiWatchOpenWorkspace({required String path}) async =>
      const Workspace(root: '/demo', repos: [
        RepoRef(path: '/demo', name: 'demo', branch: 'main'),
      ]);

  @override
  Stream<String> crateApiWatchWatchRepo({required String path}) =>
      const Stream.empty();

  @override
  Future<List<BranchInfo>> crateApiGitGetBranches(
          {required String path}) async =>
      [
        BranchInfo(name: 'main', isCurrent: currentBranch == 'main'),
        BranchInfo(name: 'feature', isCurrent: currentBranch == 'feature'),
      ];

  @override
  Future<void> crateApiGitCheckoutBranch(
      {required String path, required String name}) async {
    checkouts.add(name);
    if (checkoutFailure != null) throw checkoutFailure!;
    currentBranch = name;
  }

  @override
  Future<String> crateApiGitCheckoutRef(
      {required String path, required String refName}) async {
    remoteCheckouts.add(refName);
    currentBranch = 'feature';
    return '';
  }

  @override
  Future<Tracking> crateApiGitGetBranchTracking({required String path}) async =>
      Tracking(
          branch: currentBranch,
          upstream: '',
          ahead: BigInt.zero,
          behind: BigInt.zero);

  @override
  Future<String> crateApiGitGitFetch({required String path}) async => '';

  @override
  Future<List<FileStatus>> crateApiGitGetStatus({required String path}) async =>
      [];

  @override
  Future<List<GraphCommit>> crateApiGitGetGraph(
      {required String path, required BigInt limit, String? refName}) async {
    graphRefs.add(refName);
    if (graphs.containsKey(currentBranch)) return graphs[currentBranch]!.future;
    return [commit(refName?.split('/').last ?? currentBranch)];
  }

  @override
  Future<List<CommitInfo>> crateApiGitSearchCommits({
    required String path,
    required String query,
    required String author,
    required String hashPrefix,
    required String since,
    required String until,
    required BigInt limit,
    String? refName,
  }) async {
    searchRefs.add(refName);
    if (searches.containsKey(currentBranch)) {
      return searches[currentBranch]!.future;
    }
    return [
      CommitInfo(
          id: '3333333',
          summary: '$currentBranch result',
          author: 'Tester',
          time: 0,
          refs: const [])
    ];
  }

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
      ['origin/feature'];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _GitApi();
  RustLib.initMock(api: api);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api.currentBranch = 'main';
    api.checkouts.clear();
    api.remoteCheckouts.clear();
    api.checkoutFailure = null;
    api.graphRefs.clear();
    api.searchRefs.clear();
    api.graphs.clear();
    api.searches.clear();
  });

  Future<void> openRepo(WidgetTester tester) async {
    final prefs = await Prefs.load();
    await tester.pumpWidget(CGitApp(startPath: '/demo', prefs: prefs));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets('clicking a branch checks it out and updates its history',
      (tester) async {
    await openRepo(tester);
    expect(find.text('main history'), findsOneWidget);
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();

    expect(api.checkouts, ['feature']);
    expect(api.currentBranch, 'feature');
    expect(api.graphRefs.last, isNull);
    expect(find.text('feature history'), findsOneWidget);
    expect(find.text('main history'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clicking a remote branch checks it out before showing history',
      (tester) async {
    await openRepo(tester);
    await tester.tap(find.text('origin/feature'));
    await tester.pumpAndSettle();
    expect(api.remoteCheckouts, ['origin/feature']);
    expect(api.currentBranch, 'feature');
    expect(api.graphRefs.last, isNull);
    expect(find.text('feature history'), findsOneWidget);

    await tester.tap(find.text('main').last);
    await tester.pumpAndSettle();
    expect(api.graphRefs.last, isNull);
    expect(find.text('main history'), findsOneWidget);
    expect(api.checkouts, ['main']);
  });

  testWidgets('switching branch reruns filters within that branch',
      (tester) async {
    await openRepo(tester);
    await tester.enterText(find.byType(TextField).at(1), 'match');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(api.searchRefs.last, isNull);

    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    expect(api.searchRefs.last, isNull);
    expect(api.currentBranch, 'feature');
    expect(find.text('feature result'), findsOneWidget);

    await tester.tap(find.byTooltip('清除搜索提交说明'));
    await tester.pumpAndSettle();
    expect(find.text('feature history'), findsOneWidget);
    expect(find.text('main history'), findsNothing);
  });

  testWidgets('context menu checkout follows the newly checked out branch',
      (tester) async {
    await openRepo(tester);
    await tester.tap(find.text('feature'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('检出'));
    await tester.pumpAndSettle();
    expect(api.checkouts, ['feature']);
    expect(api.graphRefs.last, isNull);
    expect(find.text('feature history'), findsOneWidget);
  });

  testWidgets('failed checkout keeps the current branch and history',
      (tester) async {
    await openRepo(tester);
    api.checkoutFailure = 'local changes prevent checkout';
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    expect(api.currentBranch, 'main');
    expect(find.text('main history'), findsOneWidget);
    expect(find.text('feature history'), findsNothing);
    expect(find.text('local changes prevent checkout'), findsOneWidget);
  });

  testWidgets('late history responses cannot replace the latest branch',
      (tester) async {
    await openRepo(tester);
    final pending = Completer<List<GraphCommit>>();
    api.graphs['feature'] = pending;
    await tester.tap(find.text('feature'));
    await tester.pump();
    await tester.tap(find.text('main').last);
    await tester.pumpAndSettle();
    expect(find.text('main history'), findsOneWidget);

    pending.complete([api.commit('feature')]);
    await tester.pumpAndSettle();
    expect(find.text('main history'), findsOneWidget);
    expect(find.text('feature history'), findsNothing);
  });

  testWidgets('late search responses cannot replace the latest branch',
      (tester) async {
    await openRepo(tester);
    await tester.tap(find.text('feature'));
    await tester.pumpAndSettle();
    final pending = Completer<List<CommitInfo>>();
    api.searches['feature'] = pending;
    await tester.enterText(find.byType(TextField).at(1), 'match');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.tap(find.text('main').last);
    await tester.pumpAndSettle();
    expect(find.text('main result'), findsOneWidget);

    pending.complete(const [
      CommitInfo(
          id: '4444444',
          summary: 'stale search',
          author: 'Tester',
          time: 0,
          refs: [])
    ]);
    await tester.pumpAndSettle();
    expect(find.text('main result'), findsOneWidget);
    expect(find.text('stale search'), findsNothing);
  });
}
