import 'package:cgit_flutter/ai_settings.dart';
import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/prefs.dart';
import 'package:cgit_flutter/settings_sheet.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AGENTS.md: "HTTPS tokens cross the Rust seam only through stdin to
/// `git credential approve`. Never place them in command arguments, return
/// values, application preferences, or error output."
///
/// These pin the UI half of that: the token field is write-only, a saved token
/// is never read back into it, and what the sheet displays about a stored
/// credential says only that one exists.
///
/// They also pin the shape of the dialog itself — five panes, matching the
/// Tauri one. A pane quietly going missing is how this port drifted the first
/// time: every backend command had a caller, so nothing failed, and 拉取策略 and
/// 历史每页条数 simply had no way to be set.
class _FakeGit implements Git {
  _FakeGit({this.hasCredential = false, this.storedUsername = ''});

  final bool hasCredential;
  final String storedUsername;

  final saved = <(String username, String token)>[];
  int testCalls = 0;

  @override
  String get repo => '/fake';

  @override
  Future<Identity> identity() async =>
      const Identity(name: 'Ada', email: 'ada@example.com');

  @override
  Future<GitCredentialInfo> credential() async => GitCredentialInfo(
        remote: 'origin',
        transport: 'https',
        host: 'github.com',
        repository: 'me/app',
        username: storedUsername,
        helper: 'osxkeychain',
        hasCredential: hasCredential,
      );

  @override
  Future<GitCredentialInfo> saveCredential(
      String username, String token) async {
    saved.add((username, token));
    return credential();
  }

  @override
  Future<String> testCredential() async {
    testCalls++;
    return '推送权限正常';
  }

  @override
  Future<void> setIdentity(String name, String email,
      {bool global = false}) async {}

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} not needed here');
}

/// The look the dialog last applied, so the preview and its undo are visible.
class Look {
  bool? dark;
  int? fontSize;
}

late Prefs prefs;
late Look look;
int savedCount = 0;

Future<void> _pump(WidgetTester tester, {Git? git, AiSettings? ai}) async {
  look = Look();
  savedCount = 0;
  await tester.pumpWidget(
    MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              SettingsSheet(
                git: git,
                prefs: prefs,
                ai: ai,
                onClose: () {},
                onPreview: (d, f) {
                  look.dark = d;
                  look.fontSize = f;
                },
                onSaved: () => savedCount++,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openPane(WidgetTester tester, String name) async {
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

Finder _rowOf(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Row)).first;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await Prefs.load();
  });

  testWidgets('a typed ai token is saved with 保存', (tester) async {
    final ai = await AiSettings.load();
    await _pump(tester, ai: ai);
    await _openPane(tester, 'AI');
    await tester.enterText(
        find.descendant(of: _rowOf('令牌'), matching: find.byType(TextField)),
        'sk-test');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(await ai.readToken(), 'sk-test');
    expect(savedCount, 1);
  });

  group('panes', () {
    testWidgets('all five are reachable', (tester) async {
      await _pump(tester, git: _FakeGit());
      for (final name in ['通用', '外观', '编辑器', 'Git 信息', 'AI']) {
        expect(find.text(name), findsOneWidget, reason: '$name 分类页不见了');
      }
    });

    testWidgets('通用 exposes the two settings that have no other home',
        (tester) async {
      await _pump(tester, git: _FakeGit());
      // Both were persisted but unreachable before: the graph silently used
      // its own default and the pull strategy could only be changed by hand.
      expect(find.text('拉取策略'), findsOneWidget);
      expect(find.text('历史每页条数'), findsOneWidget);
    });

    testWidgets('settings open without a repository', (tester) async {
      await _pump(tester);
      await _openPane(tester, 'Git 信息');
      // The pane says why it is empty rather than vanishing.
      expect(find.text('当前没有打开仓库，身份信息不会被写入。'), findsOneWidget);
      expect(find.text('打开仓库后可查看和切换当前仓库的远程认证账号。'), findsOneWidget);
    });
  });

  group('live preview', () {
    testWidgets('主题 applies immediately and 取消 puts it back',
        (tester) async {
      await _pump(tester, git: _FakeGit());
      await _openPane(tester, '外观');

      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('浅色').last);
      await tester.pumpAndSettle();
      expect(look.dark, isFalse, reason: 'picking a theme previews it');

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(look.dark, isTrue, reason: 'cancelling restores the stored theme');
      expect(prefs.isDark, isTrue, reason: 'and never persisted it');
    });

    testWidgets('保存 persists the previewed values', (tester) async {
      await _pump(tester, git: _FakeGit());
      await _openPane(tester, '外观');

      await tester.tap(find.text('标准 (13)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('大 (15)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(prefs.fontSize, 15);
      expect(savedCount, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('credentials', () {
    testWidgets('a stored credential is never read back into the field',
        (tester) async {
      final git = _FakeGit(hasCredential: true, storedUsername: 'ada');
      await _pump(tester, git: git);
      await _openPane(tester, 'Git 信息');

      // The username is public and comes back; the token does not exist to
      // come back — core has no API that returns it.
      expect(find.text('ada'), findsWidgets);
      for (final field
          in tester.widgetList<TextField>(find.byType(TextField))) {
        expect(field.controller!.text, isNot(contains('sk-')),
            reason: 'no field may be prefilled with a secret');
      }
      // The placeholder says a credential exists without showing any of it.
      expect(find.text('••••••••'), findsOneWidget);
    });

    testWidgets('only the token field is obscured', (tester) async {
      await _pump(tester, git: _FakeGit());
      await _openPane(tester, 'Git 信息');

      final fields =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      // 用户名 / 邮箱 / 远端用户名 are plain; 访问令牌 is not.
      expect(fields.where((f) => f.obscureText).length, 1);
      expect(fields.where((f) => !f.obscureText).length, 3);
    });

    testWidgets('saving hands the token over once and then clears it',
        (tester) async {
      final git = _FakeGit();
      await _pump(tester, git: git);
      await _openPane(tester, 'Git 信息');

      final tokenField =
          find.byWidgetPredicate((w) => w is TextField && w.obscureText).first;
      await tester.enterText(_rowOf('远端用户名'), 'ada');
      await tester.enterText(tokenField, 'sk-live-token');
      await tester.tap(find.text('保存凭据并测试'));
      await tester.pumpAndSettle();

      expect(git.saved, [('ada', 'sk-live-token')]);
      // Cleared straight after: it has reached git's helper and this app has
      // no reason to keep holding it.
      expect(tester.widget<TextField>(tokenField).controller!.text, isEmpty);
      expect(git.testCalls, 1, reason: 'saving also verifies');
    });

    testWidgets('an empty token with a stored credential only tests',
        (tester) async {
      final git = _FakeGit(hasCredential: true, storedUsername: 'ada');
      await _pump(tester, git: git);
      await _openPane(tester, 'Git 信息');

      await tester.tap(find.text('保存凭据并测试'));
      await tester.pumpAndSettle();

      expect(git.saved, isEmpty, reason: 'nothing new to save');
      expect(git.testCalls, 1);
    });

    testWidgets('a missing username is refused before reaching git',
        (tester) async {
      final git = _FakeGit();
      await _pump(tester, git: git);
      await _openPane(tester, 'Git 信息');

      await tester.tap(find.text('保存凭据并测试'));
      await tester.pumpAndSettle();

      expect(find.text('请填写远端用户名'), findsOneWidget);
      expect(git.saved, isEmpty);
      expect(git.testCalls, 0);
    });

    testWidgets('the credential button acts outside 保存', (tester) async {
      final git = _FakeGit(hasCredential: true, storedUsername: 'ada');
      await _pump(tester, git: git);
      await _openPane(tester, 'Git 信息');

      await tester.tap(find.text('保存凭据并测试'));
      await tester.pumpAndSettle();

      // It reached git without the dialog being committed — which is the point:
      // it talks to the helper and the network, so it cannot wait on 保存.
      expect(git.testCalls, 1);
      expect(savedCount, 0);
    });
  });
}
