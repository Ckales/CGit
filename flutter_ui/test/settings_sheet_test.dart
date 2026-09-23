import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/settings_sheet.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// AGENTS.md: "HTTPS tokens cross the Rust seam only through stdin to
/// `git credential approve`. Never place them in command arguments, return
/// values, application preferences, or error output."
///
/// These pin the UI half of that: the token field is write-only, a saved token
/// is never read back into it, and what the sheet displays about a stored
/// credential says only that one exists.
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
  Future<GitCredentialInfo> saveCredential(String username, String token) async {
    saved.add((username, token));
    return credential();
  }

  @override
  Future<String> testCredential() async {
    testCalls++;
    return '推送权限正常';
  }

  @override
  Future<void> setIdentity(String name, String email, {bool global = false}) async {}

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} not needed here');
}

Widget _host(Git git) => MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              SettingsSheet(git: git, ai: null, onClose: () {}),
            ],
          ),
        ),
      ),
    );

Finder _fieldAfter(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(Row),
    );

void main() {
  testWidgets('a stored credential is never read back into the field',
      (tester) async {
    final git = _FakeGit(hasCredential: true, storedUsername: 'ada');
    await tester.pumpWidget(_host(git));
    await tester.pumpAndSettle();

    // The username is public and comes back; the token does not exist to come
    // back — core has no API that returns it.
    expect(find.text('ada'), findsWidgets);
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.controller!.text, isNot(contains('sk-')),
          reason: 'no field may be prefilled with a secret');
    }
    // The hint says a credential exists without showing any of it.
    expect(find.text('已保存凭据，留空则仅测试'), findsOneWidget);
    expect(find.textContaining('已有凭据'), findsOneWidget);
  });

  testWidgets('the token field is obscured', (tester) async {
    await tester.pumpWidget(_host(_FakeGit()));
    await tester.pumpAndSettle();

    // Both secrets are obscured: the git credential token and the AI key.
    // Everything else — name, email, username, endpoint, model — is not.
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.where((f) => f.obscureText).length, 2);
    expect(fields.where((f) => !f.obscureText).length, 5);
  });

  testWidgets('saving hands the token over once and then clears it',
      (tester) async {
    final git = _FakeGit();
    await tester.pumpWidget(_host(git));
    await tester.pumpAndSettle();

    // The git credential token is the first obscured field; the AI key is the
    // second, in its own section further down.
    final tokenField =
        find.byWidgetPredicate((w) => w is TextField && w.obscureText).first;
    await tester.enterText(_fieldAfter('用户名'), 'ada');
    await tester.enterText(tokenField, 'sk-live-token');
    await tester.tap(find.text('保存并测试'));
    await tester.pumpAndSettle();

    expect(git.saved, [('ada', 'sk-live-token')]);
    // Cleared straight after: it has reached git's helper and this app has no
    // reason to keep holding it.
    expect(tester.widget<TextField>(tokenField).controller!.text, isEmpty);
    expect(git.testCalls, 1, reason: 'saving also verifies');
  });

  testWidgets('an empty token with a stored credential only tests',
      (tester) async {
    final git = _FakeGit(hasCredential: true, storedUsername: 'ada');
    await tester.pumpWidget(_host(git));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存并测试'));
    await tester.pumpAndSettle();

    expect(git.saved, isEmpty, reason: 'nothing new to save');
    expect(git.testCalls, 1);
  });

  testWidgets('a missing username is refused before reaching git',
      (tester) async {
    final git = _FakeGit();
    await tester.pumpWidget(_host(git));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存并测试'));
    await tester.pumpAndSettle();

    expect(find.text('请先填写用户名'), findsOneWidget);
    expect(git.saved, isEmpty);
    expect(git.testCalls, 0);
  });
}
