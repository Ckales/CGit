import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/network_ops.dart';
import 'package:flutter_test/flutter_test.dart';

/// pushWithRetry can rewrite history (it may rebase), so what matters is which
/// failures it retries and which it refuses to. A rejected push is recoverable;
/// an auth failure or a refusing hook is not, and quietly rebasing on those
/// would move the user's commits for no reason.

/// A Git that records what was called and fails on command.
class _FakeGit implements Git {
  _FakeGit({
    this.pushErrors = const [],
    this.configuredRebase,
    this.pullRebaseThrows = false,
  });

  /// Errors to throw from successive push() calls; a null entry succeeds.
  final List<String?> pushErrors;
  final bool? configuredRebase;
  final bool pullRebaseThrows;

  final calls = <String>[];
  int _pushes = 0;

  @override
  String get repo => '/fake';

  @override
  Future<String> push() async {
    final i = _pushes++;
    calls.add('push');
    final err = i < pushErrors.length ? pushErrors[i] : null;
    if (err != null) throw GitError(err);
    return '  pushed ok\n';
  }

  @override
  Future<String> pull({String? strategy}) async {
    calls.add('pull:${strategy ?? 'ff-only'}');
    return 'pulled';
  }

  @override
  Future<bool?> pullRebase() async {
    calls.add('pullRebase');
    if (pullRebaseThrows) throw GitError('config unreadable');
    return configuredRebase;
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} not needed by these tests');
}

const rejected = ' ! [rejected]  main -> main (fetch first)';
const authFailed = 'fatal: Authentication failed for https://github.com/x/y';

void main() {
  group('pushWithRetry', () {
    test('a clean push does not consult git config or pull', () async {
      final git = _FakeGit();
      final out = await pushWithRetry(git, chooseStrategy: () async => null);

      expect(out, 'pushed ok', reason: 'output is trimmed');
      expect(git.calls, ['push']);
    });

    test('a rejected push updates the configured way, then pushes again',
        () async {
      final git = _FakeGit(pushErrors: [rejected], configuredRebase: true);
      var asked = false;

      final out = await pushWithRetry(git, chooseStrategy: () async {
        asked = true;
        return UpdateStrategy.merge;
      });

      expect(out, 'pushed ok');
      expect(git.calls, ['push', 'pullRebase', 'pull:rebase', 'push']);
      expect(asked, isFalse, reason: 'git config already answered');
    });

    test('pull.rebase=false means merge, not rebase', () async {
      final git = _FakeGit(pushErrors: [rejected], configuredRebase: false);
      await pushWithRetry(git, chooseStrategy: () async => null);
      expect(git.calls, contains('pull:merge'));
    });

    test('a silent config asks the user', () async {
      final git = _FakeGit(pushErrors: [rejected], configuredRebase: null);
      final out = await pushWithRetry(
        git,
        chooseStrategy: () async => UpdateStrategy.rebase,
      );

      expect(out, 'pushed ok');
      expect(git.calls, ['push', 'pullRebase', 'pull:rebase', 'push']);
    });

    test('an unreadable config falls through to asking', () async {
      final git = _FakeGit(pushErrors: [rejected], pullRebaseThrows: true);
      await pushWithRetry(
        git,
        chooseStrategy: () async => UpdateStrategy.merge,
      );
      expect(git.calls, ['push', 'pullRebase', 'pull:merge', 'push']);
    });

    test('backing out of the strategy prompt rethrows and changes nothing',
        () async {
      final git = _FakeGit(pushErrors: [rejected], configuredRebase: null);

      await expectLater(
        pushWithRetry(git, chooseStrategy: () async => null),
        throwsA(isA<GitError>()),
      );
      expect(git.calls, ['push', 'pullRebase'],
          reason: 'declining must not pull');
    });

    test('an auth failure is never retried', () async {
      final git = _FakeGit(pushErrors: [authFailed], configuredRebase: true);

      await expectLater(
        pushWithRetry(git, chooseStrategy: () async => UpdateStrategy.rebase),
        throwsA(isA<GitError>()),
      );
      // Not recoverable by updating: rebasing here would move commits for
      // nothing and leave the push still failing.
      expect(git.calls, ['push'], reason: 'no config read, no pull, no retry');
    });

    test('a second rejection after updating is reported, not looped', () async {
      final git = _FakeGit(
        pushErrors: [rejected, rejected],
        configuredRebase: true,
      );

      await expectLater(
        pushWithRetry(git, chooseStrategy: () async => UpdateStrategy.rebase),
        throwsA(isA<GitError>()),
      );
      expect(git.calls, ['push', 'pullRebase', 'pull:rebase', 'push']);
    });
  });

  group('error wording', () {
    test('adds nothing to failures git already explains', () {
      const hook = 'remote: error: hook declined to update refs/heads/main';
      expect(networkErrorHint(hook), isNull);
    });

    test('names the GitHub account that lacks permission', () {
      const stderr = 'remote: Permission to Ckales/CGit.git denied to someuser.\n'
          'fatal: unable to access: The requested URL returned error: 403';
      final text = networkErrorHint(stderr)!;
      expect(text, contains('someuser'));
      expect(text, contains('切换账号'));
    });

    test('points a generic credential failure at the settings screen', () {
      expect(networkErrorHint(authFailed), contains('远程认证失败'));
    });

    test('explains a token missing the workflow scope', () {
      const stderr = 'To https://github.com/Ckales/CTerminal.git\n'
          ' ! [remote rejected] main -> main (refusing to allow a Personal Access '
          'Token to create or update workflow `.github/workflows/ci.yml` without '
          '`workflow` scope)\n'
          "error: failed to push some refs to 'https://github.com/Ckales/CTerminal.git'";
      final text = networkErrorHint(stderr)!;
      expect(text, contains('workflow 权限'));
      expect(text, contains('.github/workflows/ci.yml'));
    });
  });

  group('push target wording', () {
    Tracking t({String? branch, String? upstream}) => Tracking(
          branch: branch,
          upstream: upstream,
          ahead: BigInt.zero,
          behind: BigInt.zero,
        );

    test('shows remote and branch separately', () {
      expect(pushTargetText(t(branch: 'main', upstream: 'origin/main')),
          'main → origin : main');
    });

    test('keeps a differently-named upstream', () {
      expect(pushTargetText(t(branch: 'dev', upstream: 'upstream/trunk')),
          'dev → upstream : trunk');
    });

    test('marks a branch that has no upstream yet', () {
      expect(pushTargetText(t(branch: 'feature')),
          'feature → origin : feature（新分支）');
    });

    test('says so when HEAD is detached', () {
      expect(pushTargetText(t()), 'HEAD 不在分支上');
    });
  });
}
