// Twice on purpose: unprefixed so the generated types can be named bare, and
// prefixed so calls like `rust.commit(...)` do not collide with this class's
// own methods of the same name.
import 'src/rust/api/git.dart';
import 'src/rust/api/git.dart' as rust;
import 'src/rust/api/watch.dart' as watch_api;
import 'src/rust/frb_generated.dart' show RustLib;

export 'src/rust/api/git.dart'
    show
        BlameLine,
        BranchInfo,
        CommitInfo,
        FileStatus,
        GitCredentialInfo,
        GraphCommit,
        Hunks,
        Identity,
        RemoteInfo,
        RepoRef,
        StashEntry,
        TodoCommit,
        Tracking,
        Workspace;

/* The live data layer: every call crosses into cgit-core, the same crate the
   Tauri app calls. There is no second implementation of any Git rule here —
   this file only binds the repo path so call sites do not repeat it, and
   converts the one type that does not cross the FFI seam cleanly. */

/// Must run before any binding. The macOS build links the Rust code into
/// `cgit_rust.framework`; this is what opens it.
Future<void> initGitBridge() => RustLib.init();

/// The browser has no working directory, so the fixture build hardcodes one.
/// Here it is genuinely the process's.
String get defaultRepoPath => '.';

class GitError implements Exception {
  GitError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns the `Result<_, String>` that every core function returns into a Dart
/// exception, so call sites see one failure shape rather than two.
Future<T> _guard<T>(Future<T> Function() call) async {
  try {
    return await call();
  } catch (e) {
    // Core returns Result<_, String>, and frb surfaces that String as the
    // thrown object — it is already the message meant for the user.
    throw GitError(e is String ? e : e.toString());
  }
}

class Git {
  Git(this.repo);
  final String repo;

  /* ---------- reads ---------- */

  Future<List<BranchInfo>> branches() =>
      _guard(() => rust.getBranches(path: repo));

  /// The checked-out branch, or empty on a detached HEAD. Core reports it as a
  /// flag on the branch list rather than as its own command, so this derives it
  /// instead of adding a second source of truth.
  Future<String> currentBranch() async {
    final list = await branches();
    for (final b in list) {
      if (b.isCurrent) return b.name;
    }
    return '';
  }

  Future<List<String>> tags() => _guard(() => rust.getTags(path: repo));

  Future<List<RemoteInfo>> remotes() => _guard(() => rust.getRemotes(path: repo));

  Future<List<FileStatus>> status() => _guard(() => rust.getStatus(path: repo));

  /// `limit` is `usize` in core, which frb maps to BigInt. Converting here keeps
  /// that out of the UI rather than changing core's signature for both frontends.
  Future<List<GraphCommit>> graph({int limit = 200}) =>
      _guard(() => rust.getGraph(path: repo, limit: BigInt.from(limit)));

  Future<Hunks> hunks(String file, {required bool staged}) =>
      _guard(() => rust.getHunks(path: repo, file: file, staged: staged));

  Future<List<FileStatus>> commitFiles(String oid) =>
      _guard(() => rust.getCommitFiles(path: repo, oid: oid));

  /// A commit's diff arrives as one patch string; the caller splits it into
  /// hunks with splitPatchText, exactly as the Tauri frontend does.
  Future<String> commitDiff(String oid, String file) =>
      _guard(() => rust.getCommitDiff(path: repo, oid: oid, file: file));

  /* ---------- staging ---------- */

  Future<void> stage(String file) =>
      _guard(() => rust.stageFile(path: repo, file: file));

  Future<void> unstage(String file) =>
      _guard(() => rust.unstageFile(path: repo, file: file));

  /// An empty `files` stages the whole worktree; a non-empty one stages exactly
  /// those paths, so a filtered changes list stages what the user can see
  /// rather than everything behind the filter.
  Future<String> stageAll({List<String> files = const []}) =>
      _guard(() => rust.stageAll(path: repo, files: files));

  Future<String> unstageAll({List<String> files = const []}) =>
      _guard(() => rust.unstageAll(path: repo, files: files));

  /// Stage (or with `reverse`, unstage) exactly the lines in a rebuilt hunk.
  ///
  /// This is `apply_hunk`, which applies to the index. Core's `apply_patch` is a
  /// different feature — it applies a patch file to the worktree — and reaching
  /// for it here would silently write the user's selection into their files
  /// instead of staging it.
  Future<void> applyHunk(String patch, {required bool reverse}) =>
      _guard(() => rust.applyHunk(path: repo, patch: patch, reverse: reverse));

  /* ---------- writes ---------- */

  Future<String> commit(
    String message, {
    bool amend = false,
    String? author,
    bool signoff = false,
  }) =>
      _guard(() => rust.commit(
            path: repo,
            message: message,
            amend: amend,
            author: author,
            signoff: signoff,
          ));

  /* ---------- watching ---------- */

  /// "refs" when the change moved HEAD or a ref (branch labels and the graph are
  /// stale too), "worktree" when only file contents changed.
  Stream<String> watch() => watch_api.watchRepo(path: repo);

  /* ---------- opening ---------- */

  /// Resolve a path to a workspace: one repo, or a folder of sibling repos.
  /// Returns null when there is no repository there.
  static Future<Workspace?> discover(String start) async {
    try {
      return await watch_api.openWorkspace(path: start);
    } catch (_) {
      return null;
    }
  }
}
