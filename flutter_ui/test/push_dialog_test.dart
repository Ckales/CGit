import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/push_dialog.dart';
import 'package:cgit_flutter/theme.dart';
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

    await tester.tap(find.byKey(const ValueKey('push-row-/w/db')));
    await tester.pump();
    expect(asked.last, '/w/db');
    expect(find.text('db  1 个文件'), findsOneWidget);
  });
}
