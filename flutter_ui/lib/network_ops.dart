import 'git.dart';
import 'git_text.dart';

/// Fetch / pull / push, with the decisions that are not just "call the command".
///
/// Kept out of the widget because these are business rules with real edge cases
/// — a rejected push is recoverable, an auth failure is not — and they are worth
/// testing without a screen.

/// What to do when a push is rejected because the remote moved ahead.
enum UpdateStrategy { merge, rebase }

String? strategyArg(UpdateStrategy? s) => switch (s) {
      null => null, // --ff-only
      UpdateStrategy.merge => 'merge',
      UpdateStrategy.rebase => 'rebase',
    };

/// git's own words for a few failures ("could not read Username…", a PAT
/// without `workflow` scope) do not say what to do about them, so those get a
/// sentence. Null for everything else — git explains its own failures better
/// than we can, and the raw text is always shown alongside.
String? networkErrorHint(String raw) {
  final text = raw.trim();
  // GitHub refuses a push that touches .github/workflows unless the token has
  // the `workflow` scope; the file it names is the one that tripped it.
  final workflow = RegExp(
          r'refusing to allow an? (?:Personal Access Token|OAuth App) to create or update workflow `([^`]+)`')
      .firstMatch(text);
  if (workflow != null) {
    return '推送被 GitHub 拒绝：当前 Token 没有 workflow 权限，不能修改 ${workflow[1]}。'
        '请在 GitHub 给该 Token 勾选 workflow（细粒度 Token 为 Workflows: Read and write），'
        '再到设置 → Git 信息 → 远程认证重新保存';
  }
  final auth = authFailureInfo(text);
  if (auth == null) return null;
  if (auth.kind == 'github-403') {
    return 'GitHub 当前使用账号 ${auth.username}，没有该仓库的推送权限。'
        '请到设置 → Git 信息 → 远程认证切换账号';
  }
  return '远程认证失败，请到设置 → Git 信息 → 远程认证检查凭据';
}

/// IDEA's wording for where a push lands: `main → origin : main`.
String pushTargetText(Tracking t) {
  final branch = t.branch;
  if (branch == null) return 'HEAD 不在分支上';
  final upstream = t.upstream;
  if (upstream == null) return '$branch → origin : $branch（新分支）';
  final cut = upstream.indexOf('/');
  // A remote name always precedes the branch; without a slash the config is
  // malformed, and echoing it verbatim beats inventing a remote.
  if (cut < 0) return '$branch → $upstream';
  return '$branch → ${upstream.substring(0, cut)} : ${upstream.substring(cut + 1)}';
}

/// Push, treating "the remote moved ahead" as something to resolve rather than
/// report: update with the chosen method, then push again. Every other failure
/// — no auth, a refusing hook, a protected branch — still throws.
///
/// [chooseStrategy] is only consulted when git config is silent about
/// `pull.rebase`; it returns null when the user backs out, which aborts the
/// retry and rethrows the original rejection.
Future<String> pushWithRetry(
  Git git, {
  required Future<UpdateStrategy?> Function() chooseStrategy,
  void Function(String message)? onProgress,
}) async {
  try {
    return (await git.push()).trim();
  } on GitError catch (e) {
    if (!isPushRejected(e.message)) rethrow;

    UpdateStrategy? strategy;
    final configured = await _pullRebaseQuietly(git);
    if (configured != null) {
      strategy = configured ? UpdateStrategy.rebase : UpdateStrategy.merge;
    } else {
      strategy = await chooseStrategy();
      if (strategy == null) rethrow; // the user declined to update
    }

    onProgress?.call(
      '落后于远端，正在${strategy == UpdateStrategy.rebase ? '变基' : '合并'}更新…',
    );
    await git.pull(strategy: strategyArg(strategy));
    return (await git.push()).trim();
  }
}

/// An unreadable git config is not worth a message — fall through and ask.
Future<bool?> _pullRebaseQuietly(Git git) async {
  try {
    return await git.pullRebase();
  } on GitError {
    return null;
  }
}
