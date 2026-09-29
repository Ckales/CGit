import 'dart:async';

import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/main.dart';
import 'package:cgit_flutter/prefs.dart';
import 'package:cgit_flutter/src/rust/frb_generated.dart'
    show RustLib, RustLibApi;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repos = [
  RepoRef(path: '/workspace/api', name: 'api', branch: 'main'),
  RepoRef(path: '/workspace/web', name: 'web', branch: 'main'),
];

class _GitApi extends RustLibApi {
  final fetched = Completer<void>();
  int fetches = 0;

  @override
  Future<Workspace> crateApiWatchOpenWorkspace({required String path}) async =>
      const Workspace(root: '/workspace', repos: _repos);

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
      behind: fetched.isCompleted ? BigInt.from(3) : BigInt.zero,
    );
  }

  @override
  Future<String> crateApiGitGitFetch({required String path}) async {
    fetches++;
    await fetched.future;
    return '';
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
}
