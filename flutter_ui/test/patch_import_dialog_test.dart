import 'package:cgit_flutter/patch_import_dialog.dart';
import 'package:cgit_flutter/git_text.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const first = 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+first\n';
const second = 'diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-old\n+second\n';
void main() {
  testWidgets('patch conflict starts from the full ancestor and bulk accepts only clean changes', (t) async {
    var writes = 0;
    await t.pumpWidget(MaterialApp(home: Theming(palette: Palette.dark,
      child: PatchImportDialog(files: splitImportPatch(first), source: '文件',
        prepare: (_) async => PreparedPatch.fromJson({
          'token': 'test', 'files': [{
            'path': 'a.txt', 'conflict': true, 'binary': false,
            'base': 'head\nbase\ncontext\nclean\ntail',
            'ours': 'head\nlocal\ncontext\nclean\ntail',
            'theirs': 'head\npatch\ncontext\nchanged\ntail',
            'content': 'head\n<<<<<<< HEAD\nlocal\n=======\npatch\n>>>>>>> incoming\ncontext\nchanged\ntail',
          }],
        }),
        finish: (_, __) async { writes++; }, discard: (_) async {},
      ),
    )));
    await t.tap(find.text('应用所选补丁'));
    await t.pumpAndSettle();
    String result() => t.widget<TextField>(find.byType(TextField)).controller!.text;
    expect(result(), 'head\nbase\ncontext\nclean\ntail');
    await t.tap(find.byTooltip('应用全部不冲突的更改'));
    await t.pumpAndSettle();
    expect(result(), 'head\nbase\ncontext\nchanged\ntail');
    expect(writes, 0);
    await t.tap(find.byTooltip('合并对方这段 → 结果'));
    await t.pumpAndSettle();
    const saved = 'head\nresolved by hand\ncontext\nchosen clean\ntail';
    await t.enterText(find.byType(TextField), saved);
    await t.tap(find.text('应用'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('解决冲突'));
    await t.pumpAndSettle();
    expect(result(), saved, reason: 'reopening must preserve an explicit resolution');
    expect(writes, 0);
  });

  testWidgets('selection stays local and leaves active preview intact', (t) async {
    String? prepared;
    var writes = 0;
    await t.pumpWidget(MaterialApp(home: Theming(palette: Palette.dark,
      child: PatchImportDialog(files: splitImportPatch(first + second), source: '剪贴板',
        prepare: (patch) async { prepared = patch; return const PreparedPatch(token: 'test', files: []); },
        finish: (_, __) async { writes++; }, discard: (_) async {},
      ),
    )));
    expect(prepared, isNull);
    await t.tap(find.byKey(const ValueKey('pick-1')));
    await t.pump();
    expect(prepared, isNull);
    expect(writes, 0);
    expect(find.text('a.txt', skipOffstage: false), findsWidgets);
    await t.tap(find.text('应用所选补丁'));
    await t.pumpAndSettle();
    expect(prepared, first);
    expect(writes, 1);
  });
  testWidgets('conflicts are resolved before writing; cancel discards session', (t) async {
    var writes = 0;
    String? discarded;
    await t.pumpWidget(MaterialApp(home: Theming(palette: Palette.dark,
      child: PatchImportDialog(files: splitImportPatch(first), source: '文件',
        prepare: (_) async => const PreparedPatch(token: 'test', files: [
          PatchImportConflict(path: 'a.txt', content: '<<<<<<< 本地\nlocal\n=======\npatch\n>>>>>>> 补丁\n', ours: 'local\n', theirs: 'patch\n'),
        ]),
        finish: (_, __) async { writes++; }, discard: (token) async { discarded = token; },
      ),
    )));
    await t.tap(find.text('应用所选补丁'));
    await t.pumpAndSettle();
    expect(writes, 0);
    expect(find.text('1 个冲突待解决，解决后再应用全部所选文件。'), findsOneWidget);
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    await t.tap(find.text('取消应用'));
    await t.pumpAndSettle();
    expect(discarded, 'test');
    expect(writes, 0);
  });
}
