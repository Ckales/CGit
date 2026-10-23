import 'dart:async';

import 'package:cgit_flutter/context_menu.dart';
import 'package:cgit_flutter/diff_view.dart';
import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/push_dialog.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The workspace push dialog: repos with commits ahead (or a branch the remote
/// lacks) come pre-checked, and the focused repo's push files are listed.

Tracking _t({String? upstream = 'origin/dev', int ahead = 0}) => Tracking(
      branch: 'dev',
      upstream: upstream,
      ahead: BigInt.from(ahead),
      behind: BigInt.zero,
    );

const _api = RepoRef(path: '/w/api', name: 'api', branch: 'dev');
const _web = RepoRef(path: '/w/web', name: 'web', branch: 'dev');
const _db = RepoRef(path: '/w/db', name: 'db', branch: 'dev');

void main() {
  test('pre-checks commits ahead and new branches, nothing else', () {
    expect(hasPushWork(_t(ahead: 2)), isTrue);
    expect(hasPushWork(_t(upstream: null)), isTrue);
    expect(hasPushWork(_t()), isFalse);
    expect(hasPushWork(null), isFalse);
    expect(
      hasPushWork(
          Tracking(upstream: null, ahead: BigInt.zero, behind: BigInt.zero)),
      isFalse,
    );
  });

  testWidgets('opens on the first repo to push and lists its files',
      (tester) async {
    final rows = <PushRow>[
      (repo: _api, tracking: _t()),
      (repo: _web, tracking: _t(ahead: 3)),
      (repo: _db, tracking: _t(ahead: 1)),
    ];
    final picked = ValueNotifier<Set<String>>({
      for (final r in rows)
        if (hasPushWork(r.tracking)) r.repo.path,
    });
    final asked = <String>[];
    final copied = <String>[];
    final diffRequests = <(String, String)>[];
    var diff = Completer<String>();
    var immediateError = false;
    await tester.pumpWidget(MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          child: PushDialogBody(
            rows: rows,
            picked: picked,
            loadFiles: (path) async {
              asked.add(path);
              return const [
                FileStatus(
                    path: 'src/a.dart', status: 'modified', staged: false),
              ];
            },
            loadDiff: (repo, path) {
              diffRequests.add((repo, path));
              if (immediateError) return Future.error(GitError('读取失败'));
              return diff.future;
            },
            fileMenu: (repo, path) => [
              MenuAction('复制文件路径', () => copied.add('$repo/$path')),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(picked.value, {'/w/web', '/w/db'});
    expect(asked, ['/w/web']);
    expect(find.text('web  1 个文件'), findsOneWidget);
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.text('↑3'), findsOneWidget);

    // A single click does not read the diff. Double-click opens it above the
    // push dialog, without changing which repos will be pushed.
    await tester.tap(find.text('a.dart'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(diffRequests, isEmpty);
    await tester.tap(find.text('a.dart'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();
    expect(diffRequests, [('/w/web', 'src/a.dart')]);
    expect(find.text('web / src/a.dart'), findsOneWidget);
    expect(find.text('载入差异中…'), findsOneWidget);
    diff.complete('diff --git a/src/a.dart b/src/a.dart\n'
        '--- a/src/a.dart\n+++ b/src/a.dart\n'
        '@@ -1 +1 @@\n-before push\n+after push\n');
    await tester.pumpAndSettle();
    expect(find.byType(DiffPane), findsOneWidget);
    expect(find.text('before push', findRichText: true), findsOneWidget);
    expect(find.text('after push', findRichText: true), findsOneWidget);
    expect(find.text('暂存此块'), findsNothing);
    expect(tester.widget<DiffPane>(find.byType(DiffPane)).onApply, isNull);
    await tester.tap(find.text('并排'));
    await tester.pumpAndSettle();
    expect(find.text('-before push'), findsOneWidget);
    expect(find.text('+after push'), findsOneWidget);
    expect(diffRequests, hasLength(1));
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(picked.value, {'/w/web', '/w/db'});

    // Right-click a file: the menu acts on that repo's file.
    await tester.tap(find.text('a.dart'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制文件路径'));
    await tester.pumpAndSettle();
    expect(copied, ['/w/web/src/a.dart']);

    // Folding a folder hides its files.
    await tester.tap(find.text('src  1 个文件'));
    await tester.pump();
    expect(find.text('a.dart'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('push-row-/w/db')));
    await tester.pump();
    expect(asked.last, '/w/db');
    expect(find.text('db  1 个文件'), findsOneWidget);

    // Switching repos keeps the same relative filename bound to the new repo.
    diff = Completer<String>();
    await tester.tap(find.text('a.dart'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();
    expect(diffRequests.last, ('/w/db', 'src/a.dart'));
    diff.complete('Binary files a/src/a.dart and b/src/a.dart differ\n');
    await tester.pumpAndSettle();
    expect(find.text('Binary files a/src/a.dart and b/src/a.dart differ\n'),
        findsOneWidget);
    expect(find.byType(DiffPane), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    diff = Completer<String>();
    await tester.tap(find.text('a.dart'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();
    diff.completeError(GitError('上游没有指向提交'));
    await tester.pumpAndSettle();
    expect(find.text('读取差异失败：上游没有指向提交'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(picked.value, {'/w/web', '/w/db'});
    immediateError = true;
    await tester.tap(find.text('a.dart'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('a.dart'));
    await tester.pumpAndSettle();
    expect(find.text('读取差异失败：读取失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    picked.dispose();
  });
}
