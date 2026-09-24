import 'package:cgit_flutter/commit_sheet.dart';
import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// These exist because the first version of this app shipped a commit box that
/// rendered as a red "No Material widget found" error instead of an input: the
/// app draws its own chrome instead of using Scaffold, so nothing supplied the
/// Material ancestor TextField asserts on. DiffPane had widget tests; this
/// sheet did not, so a full green suite said nothing about it.
///
/// `_host` deliberately mirrors main.dart's tree — Theming, then Material, then
/// the Stack the sheet's Positioned.fill needs — so a regression in any of those
/// layers fails here rather than only on screen.
/// The message box, told apart from the author field by its hint.
Finder get _messageBox =>
    find.ancestor(of: find.text('提交说明'), matching: find.byType(TextField));

Widget _host(Widget child) => MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(children: [child]),
        ),
      ),
    );

const _demo = RepoRef(path: '/tmp', name: 'demo', branch: 'dev');

CommitSheet _sheet({List<FileStatus>? changes}) => CommitSheet(
      groups: [
        (
          repo: _demo,
          changes: changes ??
              const [
                FileStatus(
                    path: 'src/main.js', status: 'modified', staged: true),
                FileStatus(
                    path: 'src/styles.css', status: 'modified', staged: false),
              ],
        ),
      ],
      active: _demo,
      diffPane: const SizedBox(),
      onClose: () {},
      onChanged: () async {},
      onPickFile: (_, __) {},
      onCommitAndPush: (_) async {},
      onCreatePatch: ({required bool toClipboard}) async {},
    );

/// A repo that records commits into a shared log, and can refuse them.
class _FakeGit implements Git {
  _FakeGit(this.repo, this.log, {this.commitError});

  @override
  final String repo;
  final List<String> log;
  final String? commitError;

  @override
  Future<String> commit(String message,
      {bool amend = false, String? author, bool signoff = false}) async {
    log.add('$repo:${amend ? 'amend' : 'commit'}:$message');
    if (commitError != null) throw GitError(commitError!);
    return '';
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} not needed here');
}

void main() {
  group('commit options', () {
    testWidgets('amending is allowed with nothing staged — it rewords HEAD',
        (tester) async {
      await tester.pumpWidget(_host(_sheet(
        changes: const [FileStatus(path: 'a.dart', status: 'M', staged: false)],
      )));

      await tester.enterText(_messageBox, '改个说明');
      await tester.tap(find.text('提交').last);
      await tester.pump();
      expect(find.text('没有已暂存的改动'), findsOneWidget);

      // With amend on, the same state is fine: there is a commit to reword.
      await tester.tap(find.text('修正提交'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修正提交').last);
      await tester.pump();
      expect(find.text('没有已暂存的改动'), findsNothing);
    });

    testWidgets('the commit button says what it will do', (tester) async {
      await tester.pumpWidget(_host(_sheet()));
      expect(find.text('提交').last, findsOneWidget);

      await tester.tap(find.text('修正提交'));
      await tester.pumpAndSettle();
      // Both the checkbox and the button now read 修正提交.
      expect(find.text('修正提交'), findsNWidgets(2));
    });

    testWidgets('AI generation stays disabled until the endpoint is set',
        (tester) async {
      await tester.pumpWidget(_host(_sheet()));

      // No AiSettings passed at all: the feature exists but cannot be used, and
      // says so by being greyed rather than by failing on click.
      final dimmed = tester.widget<Opacity>(find.descendant(
          of: find.byTooltip('用 AI 生成提交说明'),
          matching: find.byType(Opacity)));
      expect(dimmed.opacity, 0.45);
    });
  });

  testWidgets('the commit box renders a real input, not an error block',
      (tester) async {
    await tester.pumpWidget(_host(_sheet()));

    // Three fields: the path filter, the message box and the author override.
    // All must be real inputs, not the error placeholder.
    expect(find.byType(TextField), findsNWidgets(3));
    // The framework's error widget renders its message as text; if the Material
    // ancestor goes missing again this is what shows up instead of the field.
    expect(find.textContaining('No Material widget'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the commit box accepts Chinese input', (tester) async {
    await tester.pumpWidget(_host(_sheet()));

    // Not an IME test — that needs a real input method and a real window. This
    // only pins that the field holds multi-byte text and shows it back.
    await tester.enterText(_messageBox, '修复提交弹窗缺少输入框');
    await tester.pump();

    expect(find.text('修复提交弹窗缺少输入框'), findsOneWidget);
  });

  testWidgets('changes show as a tree under the repo, like the Tauri dialog',
      (tester) async {
    await tester.pumpWidget(_host(_sheet()));

    expect(find.text('demo  2 个文件'), findsOneWidget);
    expect(find.text('src  2 个文件'), findsOneWidget);
    expect(find.text('main.js'), findsOneWidget);
    expect(find.text('styles.css'), findsOneWidget);
    expect(find.text('M'), findsNWidgets(2), reason: '状态角标取首字母');
  });

  testWidgets('a path both staged and unstaged is labelled on each side',
      (tester) async {
    await tester.pumpWidget(_host(_sheet(changes: const [
      FileStatus(path: 'a.txt', status: 'modified', staged: true),
      FileStatus(path: 'a.txt', status: 'modified', staged: false),
    ])));

    expect(find.text('a.txt · 已暂存'), findsOneWidget);
    expect(find.text('a.txt · 未暂存'), findsOneWidget);
    expect(find.text('demo  1 个文件'), findsOneWidget);
  });

  testWidgets('folding a folder hides its files', (tester) async {
    await tester.pumpWidget(_host(_sheet()));

    await tester.tap(find.text('src  2 个文件'));
    await tester.pump();
    expect(find.text('main.js'), findsNothing);
  });

  testWidgets('committing an empty message is refused before touching git',
      (tester) async {
    await tester.pumpWidget(_host(_sheet()));

    // The sheet header and the button both read 提交; the button comes last.
    await tester.tap(find.text('提交').last);
    await tester.pump();

    // Git('/tmp') would throw if it were reached; the guard must fire first.
    expect(find.text('提交说明不能为空'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('committing with nothing staged is refused', (tester) async {
    await tester.pumpWidget(_host(_sheet(
      changes: const [FileStatus(path: 'src/main.js', status: 'M', staged: false)],
    )));

    await tester.enterText(_messageBox, '一些改动');
    // The sheet header and the button both read 提交; the button comes last.
    await tester.tap(find.text('提交').last);
    await tester.pump();

    expect(find.text('没有已暂存的改动'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the path filter narrows the tree', (tester) async {
    await tester.pumpWidget(_host(_sheet()));
    await tester.enterText(
        find.ancestor(
            of: find.text('过滤路径'), matching: find.byType(TextField)),
        'styles');
    await tester.pump();

    expect(find.text('styles.css'), findsOneWidget);
    expect(find.text('main.js'), findsNothing);
  });

  testWidgets('提交并推送 is behind the split arrow, not next to 提交',
      (tester) async {
    await tester.pumpWidget(_host(_sheet()));
    // Not on screen until the arrow is used — a stray click on 提交 must never
    // reach the network.
    expect(find.text('提交并推送'), findsNothing);
  });

  group('workspace', () {
    const api = RepoRef(path: '/w/api', name: 'api', branch: 'main');
    const admin = RepoRef(path: '/w/admin', name: 'admin', branch: 'dev');
    const front = RepoRef(path: '/w/front', name: 'front', branch: 'dev');
    const staged = FileStatus(path: 'a.py', status: 'M', staged: true);
    const unstaged = FileStatus(path: 'b.py', status: 'M', staged: false);

    late List<String> log;
    late List<String> pushed;
    var closed = false;

    Future<void> pump(WidgetTester tester, {String? adminError}) async {
      log = [];
      pushed = [];
      closed = false;
      final gits = {
        api.path: _FakeGit(api.path, log),
        admin.path: _FakeGit(admin.path, log, commitError: adminError),
        front.path: _FakeGit(front.path, log),
      };
      await tester.pumpWidget(_host(CommitSheet(
        groups: const [
          (repo: admin, changes: [staged]),
          (repo: front, changes: [staged, unstaged]),
          (repo: api, changes: [unstaged]),
        ],
        // The active repo need not have changes of its own.
        active: api,
        gitFor: (path) => gits[path]!,
        diffPane: const SizedBox(),
        onClose: () => closed = true,
        onChanged: () async {},
        onPickFile: (_, __) {},
        onCommitAndPush: (paths) async => pushed = paths,
        onCreatePatch: ({required bool toClipboard}) async {},
      )));
    }

    testWidgets('lists one tree per repo', (tester) async {
      await pump(tester);
      expect(find.text('admin  1 个文件'), findsOneWidget);
      expect(find.text('front  2 个文件'), findsOneWidget);
      expect(find.text('api  1 个文件'), findsOneWidget);
    });

    testWidgets('提交 commits every repo with something staged, and only those',
        (tester) async {
      await pump(tester);
      await tester.enterText(_messageBox, 'feat: x');
      await tester.tap(find.text('提交').last);
      await tester.pumpAndSettle();

      expect(log, ['/w/admin:commit:feat: x', '/w/front:commit:feat: x']);
      expect(closed, isTrue);
    });

    testWidgets('提交并推送 pushes the repos it committed', (tester) async {
      await pump(tester);
      await tester.enterText(_messageBox, 'feat: y');
      await tester.tap(find.byType(Chevron));
      await tester.pumpAndSettle();
      await tester.tap(find.text('提交并推送'));
      await tester.pumpAndSettle();

      expect(pushed, ['/w/admin', '/w/front']);
    });

    testWidgets('amend touches the active repo alone', (tester) async {
      await pump(tester);
      expect(find.text('修正提交（仅 api）'), findsOneWidget);
      await tester.enterText(_messageBox, 'reword');
      await tester.tap(find.text('修正提交（仅 api）'));
      await tester.pump();
      await tester.tap(find.text('修正提交').last);
      await tester.pumpAndSettle();

      expect(log, ['/w/api:amend:reword']);
    });

    testWidgets('a refusing repo does not stop the others; the dialog stays up',
        (tester) async {
      await pump(tester, adminError: 'pre-commit hook failed');
      await tester.enterText(_messageBox, 'feat: z');
      await tester.tap(find.text('提交').last);
      await tester.pumpAndSettle();

      expect(log, ['/w/admin:commit:feat: z', '/w/front:commit:feat: z']);
      expect(closed, isFalse);
      expect(find.textContaining('admin：pre-commit hook failed'), findsOneWidget);
      expect(find.textContaining('已提交 1 个仓库'), findsOneWidget);
    });
  });
}
