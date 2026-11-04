import 'package:cgit_flutter/ai_settings.dart';
import 'package:cgit_flutter/commit_sheet.dart';
import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _api = RepoRef(path: '/workspace/api', name: 'api', branch: 'main');
const _web = RepoRef(path: '/workspace/web', name: 'web', branch: 'main');

Finder get _messageBox =>
    find.ancestor(of: find.text('提交说明'), matching: find.byType(TextField));

typedef _AiCall = ({
  String url,
  String token,
  String model,
  String system,
  String user,
});

Future<AiSettings> _configuredAi() async {
  SharedPreferences.setMockInitialValues({});
  final ai = await AiSettings.load();
  await ai.setBaseUrl('https://ai.example.test/v1');
  await ai.setModel('test-model');
  await ai.setPrompt('test prompt');
  await ai.writeToken('test-token');
  return ai;
}

Widget _host(Widget child) => MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(children: [child]),
        ),
      ),
    );

class _FakeGit implements Git {
  _FakeGit(this.repo, this.staged, this.unstaged);

  @override
  final String repo;
  final Map<String, String> staged;
  final Map<String, String> unstaged;
  final List<String> reads = [];

  @override
  Future<Identity> identity() async =>
      const Identity(name: 'Test User', email: 'test@example.test');

  @override
  Future<String> stagedDiff({String file = ''}) async {
    reads.add('staged:$file');
    return staged[file] ?? '';
  }

  @override
  Future<String> unstagedDiff({String file = ''}) async {
    reads.add('unstaged:$file');
    return unstaged[file] ?? '';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not expected');
}

CommitSheet _sheet({
  required List<RepoChanges> groups,
  required RepoRef active,
  required Map<String, _FakeGit> git,
  required AiSettings ai,
  required Future<String> Function({
    required String url,
    required String token,
    required String model,
    required String system,
    required String user,
  }) aiChat,
}) =>
    CommitSheet(
      groups: groups,
      active: active,
      diffPane: const SizedBox(),
      onClose: () {},
      onChanged: () async {},
      onPickFile: (_, __) {},
      onCommitAndPush: (_) async {},
      onCreatePatch: ({required bool toClipboard}) async {},
      gitFor: (path) => git[path]!,
      ai: ai,
      aiChat: aiChat,
    );

Future<void> _generate(WidgetTester tester) async {
  await tester.tap(find.byTooltip('用 AI 生成提交说明'));
  await tester.pumpAndSettle();
}

Future<void> _toggleRootFile(WidgetTester tester, String path) async {
  final row = find.byTooltip(path);
  await tester.tapAt(tester.getTopLeft(row) + const Offset(27, 13));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sends selected unstaged diff and skips unchecked staged diff',
      (tester) async {
    final ai = await _configuredAi();
    final apiGit = _FakeGit('/workspace/api', {
      'staged.txt': 'STAGED ONLY SENTINEL',
    }, {
      'working.txt': 'UNSTAGED DIFF',
    });
    final calls = <_AiCall>[];

    await tester.pumpWidget(_host(_sheet(
      groups: [
        (
          repo: _api,
          changes: const [
            FileStatus(path: 'staged.txt', status: 'M', staged: true),
            FileStatus(path: 'working.txt', status: 'M', staged: false),
          ],
        ),
      ],
      active: _api,
      git: {'/workspace/api': apiGit},
      ai: ai,
      aiChat: ({
        required url,
        required token,
        required model,
        required system,
        required user,
      }) async {
        calls.add((
          url: url,
          token: token,
          model: model,
          system: system,
          user: user,
        ));
        return 'generated';
      },
    )));

    await tester.tap(find.byTooltip('取消勾选').first);
    await tester.tap(find.byTooltip('勾选提交').last);
    await tester.pump();
    await _generate(tester);

    expect(calls, hasLength(1));
    expect(calls.single.user, contains('UNSTAGED DIFF'));
    expect(calls.single.user, isNot(contains('STAGED ONLY SENTINEL')));
    expect(calls.single.url, 'https://ai.example.test/v1/chat/completions');
    expect(calls.single.token, 'test-token');
    expect(calls.single.model, 'test-model');
    expect(calls.single.system, 'test prompt');
    expect(tester.widget<TextField>(_messageBox).controller!.text, 'generated');
    expect(apiGit.reads, ['unstaged:working.txt']);
  });

  testWidgets('sends both selected diff sides for a partially staged path',
      (tester) async {
    final ai = await _configuredAi();
    final apiGit = _FakeGit('/workspace/api', {
      'same.txt': 'STAGED HALF',
    }, {
      'same.txt': 'WORKTREE HALF',
    });
    final users = <String>[];

    await tester.pumpWidget(_host(_sheet(
      groups: [
        (
          repo: _api,
          changes: const [
            FileStatus(path: 'same.txt', status: 'M', staged: true),
            FileStatus(path: 'same.txt', status: 'M', staged: false),
          ],
        ),
      ],
      active: _api,
      git: {'/workspace/api': apiGit},
      ai: ai,
      aiChat: ({
        required url,
        required token,
        required model,
        required system,
        required user,
      }) async {
        users.add(user);
        return 'generated';
      },
    )));

    await tester.tap(find.byTooltip('勾选全部'));
    await tester.pump();
    await _generate(tester);

    expect(users, hasLength(1));
    expect(users.single, contains('STAGED HALF'));
    expect(users.single, contains('WORKTREE HALF'));
    expect(users.single.indexOf('HEAD → 暂存区'),
        lessThan(users.single.indexOf('暂存区 → 工作区')));
    expect(apiGit.reads, ['staged:same.txt', 'unstaged:same.txt']);
  });

  testWidgets('uses selected repos and paths independently of path filtering',
      (tester) async {
    final ai = await _configuredAi();
    final apiGit = _FakeGit('/workspace/api', {
      'a-api-selected.txt': 'API SELECTED',
      'z-api-hidden.txt': 'API HIDDEN',
    }, {});
    final webGit = _FakeGit('/workspace/web', {
      'a-web-selected.txt': 'WEB SELECTED',
      'z-web-hidden.txt': 'WEB HIDDEN',
    }, {});
    final users = <String>[];

    await tester.pumpWidget(_host(_sheet(
      groups: [
        (
          repo: _api,
          changes: const [
            FileStatus(path: 'a-api-selected.txt', status: 'M', staged: true),
            FileStatus(path: 'z-api-hidden.txt', status: 'M', staged: true),
          ],
        ),
        (
          repo: _web,
          changes: const [
            FileStatus(path: 'a-web-selected.txt', status: 'M', staged: true),
            FileStatus(path: 'z-web-hidden.txt', status: 'M', staged: true),
          ],
        ),
      ],
      active: _api,
      git: {'/workspace/api': apiGit, '/workspace/web': webGit},
      ai: ai,
      aiChat: ({
        required url,
        required token,
        required model,
        required system,
        required user,
      }) async {
        users.add(user);
        return 'generated';
      },
    )));

    await _toggleRootFile(tester, 'z-api-hidden.txt');
    await _toggleRootFile(tester, 'z-web-hidden.txt');
    await tester.enterText(
      find.ancestor(of: find.text('过滤路径'), matching: find.byType(TextField)),
      'a-api-selected.txt',
    );
    await tester.pump();
    await _generate(tester);

    expect(users, hasLength(1));
    expect(users.single, contains('API SELECTED'));
    expect(users.single, contains('WEB SELECTED'));
    expect(users.single, isNot(contains('API HIDDEN')));
    expect(users.single, isNot(contains('WEB HIDDEN')));
    expect(apiGit.reads, ['staged:a-api-selected.txt']);
    expect(webGit.reads, ['staged:a-web-selected.txt']);
  });

  testWidgets('does not call AI when no change is selected', (tester) async {
    final ai = await _configuredAi();
    final apiGit = _FakeGit('/workspace/api', {'a.txt': 'DIFF'}, {});
    var calls = 0;

    await tester.pumpWidget(_host(_sheet(
      groups: [
        (
          repo: _api,
          changes: const [FileStatus(path: 'a.txt', status: 'M', staged: true)],
        ),
      ],
      active: _api,
      git: {'/workspace/api': apiGit},
      ai: ai,
      aiChat: ({
        required url,
        required token,
        required model,
        required system,
        required user,
      }) async {
        calls++;
        return 'generated';
      },
    )));

    await tester.tap(find.byTooltip('取消勾选全部'));
    await tester.pump();
    await _generate(tester);

    expect(calls, 0);
    expect(find.text('没有勾选的改动可供生成'), findsOneWidget);
    expect(apiGit.reads, isEmpty);
  });

  testWidgets('reports selected files with empty diffs without calling AI',
      (tester) async {
    final ai = await _configuredAi();
    final apiGit = _FakeGit('/workspace/api', {}, {});
    var calls = 0;

    await tester.pumpWidget(_host(_sheet(
      groups: [
        (
          repo: _api,
          changes: const [
            FileStatus(path: 'empty.txt', status: 'M', staged: true)
          ],
        ),
      ],
      active: _api,
      git: {'/workspace/api': apiGit},
      ai: ai,
      aiChat: ({
        required url,
        required token,
        required model,
        required system,
        required user,
      }) async {
        calls++;
        return 'generated';
      },
    )));

    await _generate(tester);

    expect(calls, 0);
    expect(find.text('勾选的文件没有可供生成的差异'), findsOneWidget);
    expect(apiGit.reads, ['staged:empty.txt']);
  });
}
