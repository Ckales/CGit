import 'package:cgit_flutter/batch_commit_sheet.dart';
import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Batch commit is not atomic, so what matters is which repos it touches: only
/// ones with something to record, staging only when asked, and a failure in
/// one repo neither stopping the rest nor being reported as success.

/// A repo that records calls into a shared log, prefixed with its path.
class _FakeGit implements Git {
  _FakeGit(this.repo, this.changes, this.log, {this.commitError});

  @override
  final String repo;
  List<FileStatus> changes;
  final List<String> log;
  final String? commitError;

  @override
  Future<List<FileStatus>> status() async => changes;

  @override
  Future<String> stageAll({List<String> files = const []}) async {
    log.add('$repo:stageAll');
    changes = [
      for (final f in changes)
        FileStatus(path: f.path, status: f.status, staged: true),
    ];
    return '';
  }

  @override
  Future<String> commit(String message,
      {bool amend = false, String? author, bool signoff = false}) async {
    log.add('$repo:commit:$message');
    if (commitError != null) throw GitError(commitError!);
    changes = [];
    return '';
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} not needed here');
}

const _staged = FileStatus(path: 'a.py', status: 'M', staged: true);
const _unstaged = FileStatus(path: 'b.py', status: 'M', staged: false);

const _repos = [
  RepoRef(path: '/w/api', name: 'api', branch: 'main'),
  RepoRef(path: '/w/admin', name: 'admin', branch: 'dev'),
  RepoRef(path: '/w/clean', name: 'clean', branch: 'main'),
];

Widget _host(Widget child) => MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(children: [child]),
        ),
      ),
    );

Finder get _messageBox =>
    find.ancestor(of: find.text('提交说明'), matching: find.byType(TextField));

void main() {
  late List<String> log;
  late Map<String, _FakeGit> gits;
  String? done;
  var changedCalls = 0;

  Future<void> pump(WidgetTester tester, {String? adminError}) async {
    log = [];
    done = null;
    changedCalls = 0;
    gits = {
      '/w/api': _FakeGit('/w/api', [_staged, _unstaged], log),
      '/w/admin':
          _FakeGit('/w/admin', [_unstaged], log, commitError: adminError),
      '/w/clean': _FakeGit('/w/clean', [], log),
    };
    await tester.pumpWidget(_host(BatchCommitSheet(
      repos: _repos,
      gitFor: (path) => gits[path]!,
      onClose: () {},
      onChanged: () async => changedCalls++,
      onDone: (summary) => done = summary,
    )));
    await tester.pumpAndSettle();
  }

  testWidgets('without 暂存全部, only repos with staged changes commit',
      (tester) async {
    await pump(tester);
    expect(find.text('提交 1 个仓库'), findsOneWidget);

    await tester.enterText(_messageBox, 'feat: x');
    await tester.tap(find.text('提交 1 个仓库'));
    await tester.pumpAndSettle();

    expect(log, ['/w/api:commit:feat: x']);
    expect(done, '已在 1 个仓库提交');
  });

  testWidgets('暂存全部 stages first, and skips repos with nothing to stage',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('提交前暂存全部改动（含未跟踪文件）'));
    await tester.pump();
    expect(find.text('提交 2 个仓库'), findsOneWidget);

    await tester.enterText(_messageBox, 'feat: y');
    await tester.tap(find.text('提交 2 个仓库'));
    await tester.pumpAndSettle();

    expect(log, [
      '/w/api:stageAll',
      '/w/api:commit:feat: y',
      '/w/admin:stageAll',
      '/w/admin:commit:feat: y',
    ]);
    expect(done, '已在 2 个仓库提交');
  });

  testWidgets('a failing repo does not stop the others and keeps the sheet open',
      (tester) async {
    await pump(tester, adminError: 'pre-commit hook failed');
    await tester.tap(find.text('提交前暂存全部改动（含未跟踪文件）'));
    await tester.pump();

    await tester.enterText(_messageBox, 'feat: z');
    await tester.tap(find.text('提交 2 个仓库'));
    await tester.pumpAndSettle();

    expect(log, contains('/w/api:commit:feat: z'));
    expect(log, contains('/w/admin:commit:feat: z'));
    expect(done, isNull);
    expect(changedCalls, 1);
    expect(find.text('pre-commit hook failed'), findsOneWidget);
    expect(find.text('1 个仓库提交失败，1 个已提交'), findsOneWidget);
    // The committed repo is unticked, so a retry reaches only the failed one.
    expect(find.text('提交 1 个仓库'), findsOneWidget);
  });

  testWidgets('an empty message commits nothing', (tester) async {
    await pump(tester);
    await tester.tap(find.text('提交 1 个仓库'));
    await tester.pump();

    expect(log, isEmpty);
    expect(find.text('提交说明不能为空'), findsOneWidget);
  });
}
