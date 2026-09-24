// Twice on purpose: unprefixed so the generated types can be named bare, and
// prefixed so calls like `rust.commit(...)` do not collide with this class's
// own methods of the same name.
import 'dart:typed_data';

import 'op_log.dart';
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

/* The live data layer: every call crosses into cgit-core. There is no second implementation of any Git rule here —
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
    final message = e is String ? e : e.toString();
    OpLog.error(message);
    throw GitError(message);
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

  Future<List<RemoteInfo>> remotes() =>
      _guard(() => rust.getRemotes(path: repo));

  Future<List<FileStatus>> status() => _guard(() => rust.getStatus(path: repo));

  /// `limit` is `usize` in core, which frb maps to BigInt. Converting here keeps
  /// that out of the UI rather than changing core's signature.
  Future<List<GraphCommit>> graph({int limit = 200}) =>
      _guard(() => rust.getGraph(path: repo, limit: BigInt.from(limit)));

  Future<Hunks> hunks(String file, {required bool staged}) =>
      _guard(() => rust.getHunks(path: repo, file: file, staged: staged));

  Future<List<FileStatus>> commitFiles(String oid) =>
      _guard(() => rust.getCommitFiles(path: repo, oid: oid));

  /// A commit's diff arrives as one patch string; the caller splits it into
  /// hunks with splitPatchText.
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

  /// Per-line authorship of the *committed* version of a file — core reads the
  /// HEAD blob, not the worktree, so line numbers cannot drift out of step with
  /// the blame result.
  Future<List<BlameLine>> blame(String file) =>
      _guard(() => rust.getBlame(path: repo, file: file));

  /// Throw away a file's uncommitted changes. Nothing in git gets these back,
  /// which is why every caller confirms first.
  Future<void> discard(String file) =>
      _guard(() => rust.discardChanges(path: repo, file: file));

  /// Check out any ref — a branch, a remote branch, a tag or a sha. Core
  /// shells out so git can DWIM `origin/foo` into a local tracking branch and
  /// detach HEAD cleanly for a tag.
  Future<String> checkoutRef(String refName) =>
      _guard(() => rust.checkoutRef(path: repo, refName: refName));

  /// One file's history, newest first.
  Future<List<CommitInfo>> fileHistory(String file, {int limit = 100}) =>
      _guard(() => rust.getFileHistory(
            path: repo,
            file: file,
            limit: BigInt.from(limit),
          ));

  Future<String> pushTag(String name) =>
      _guard(() => rust.pushTag(path: repo, name: name));

  /// Clone into `dir`, streaming git's progress lines. The stream completes
  /// when the clone does; the created worktree path arrives as the last value.
  static Stream<String> clone(String url, String dir) =>
      watch_api.cloneRepo(url: url, dir: dir);

  /// An editor's app icon as PNG bytes, or null when it cannot be read —
  /// apps that pack icons into Assets.car (Xcode) have none to extract, and a
  /// missing icon is a text-only button, not an error.
  static Future<Uint8List?> editorIcon(String name) async {
    try {
      return await rust.editorIcon(name: name);
    } catch (_) {
      return null;
    }
  }

  /* ---------- interactive rebase ---------- */

  /// Commits in `base..HEAD`, oldest first — the order an interactive rebase
  /// edits them in.
  Future<List<TodoCommit>> rebaseTodo(String base) =>
      _guard(() => rust.getRebaseTodo(path: repo, base: base));

  /// Run `git rebase -i` non-interactively: core feeds the todo through
  /// GIT_SEQUENCE_EDITOR and pops `messages` for each reword, so the two must
  /// be in the same order.
  Future<String> rebaseInteractive({
    required String base,
    required String todo,
    required List<String> messages,
    required bool autostash,
  }) =>
      _guard(() => rust.rebaseInteractive(
            path: repo,
            base: base,
            todo: todo,
            messages: messages,
            autostash: autostash,
          ));

  /* ---------- identity and credentials ---------- */

  Future<Identity> identity() => _guard(() => rust.getIdentity(path: repo));

  Future<void> setIdentity(String name, String email, {bool global = false}) =>
      _guard(() => rust.setIdentity(
            path: repo,
            name: name,
            email: email,
            global: global,
          ));

  /// What the credential helper holds for this remote. Reports *whether* a
  /// credential exists, never the credential itself — the returned struct has
  /// no token field, by design.
  Future<GitCredentialInfo> credential() =>
      _guard(() => rust.getGitCredential(path: repo));

  /// Hand a token to `git credential approve`.
  ///
  /// Core passes it on stdin and nowhere else: not in argv, not in the return
  /// value, not in an error string. This wrapper keeps that intact by taking
  /// the token straight from the field and forgetting it — it is never stored
  /// in preferences, never logged, and never held in state.
  Future<GitCredentialInfo> saveCredential(String username, String token) =>
      _guard(() => rust.saveGitCredential(
            path: repo,
            username: username,
            token: token,
          ));

  /// Ask the remote whether the stored credential actually grants push access.
  Future<String> testCredential() =>
      _guard(() => rust.testGitCredential(path: repo));

  /* ---------- commit messages ---------- */

  /// The staged diff, which is what an AI message should describe — an empty
  /// `file` means everything staged.
  Future<String> stagedDiff({String file = ''}) =>
      _guard(() => rust.getStagedDiff(path: repo, file: file));

  /// Working directory vs index. Used as the fallback when [hunks] comes back
  /// empty: an untracked, newly added or binary file has no hunks to stage, but
  /// it does have content worth showing.
  Future<String> unstagedDiff({String file = ''}) =>
      _guard(() => rust.getUnstagedDiff(path: repo, file: file));

  /// Recent commit messages, for the "reuse a past message" picker.
  Future<List<String>> recentMessages({int limit = 30}) => _guard(
      () => rust.getCommitMessages(path: repo, limit: BigInt.from(limit)));

  /// HEAD's message, which is what `--amend` starts from.
  Future<String> headMessage() => _guard(() => rust.getHeadMessage(path: repo));

  /// One non-streaming round against an OpenAI-compatible endpoint. Core makes
  /// the request with curl rather than from the UI process, so relay services
  /// that mishandle CORS preflights and plain-http endpoints both still work.
  static Future<String> aiChat({
    required String url,
    required String token,
    required String model,
    required String system,
    required String user,
  }) =>
      _guard(() => rust.aiChat(
            url: url,
            token: token,
            model: model,
            system: system,
            user: user,
          ));

  /* ---------- search and remotes ---------- */

  /// Filter history by message and/or author. An empty query and author means
  /// "everything", which is how the UI returns to the unfiltered graph without
  /// a separate call.
  Future<List<CommitInfo>> searchCommits({
    String query = '',
    String author = '',
    int limit = 200,
  }) =>
      _guard(() => rust.searchCommits(
            path: repo,
            query: query,
            author: author,
            limit: BigInt.from(limit),
          ));

  Future<List<String>> remoteBranches() =>
      _guard(() => rust.getRemoteBranches(path: repo));

  Future<String> addRemote(String name, String url) =>
      _guard(() => rust.addRemote(path: repo, name: name, url: url));

  Future<String> removeRemote(String name) =>
      _guard(() => rust.removeRemote(path: repo, name: name));

  Future<String> deleteRemoteBranch(String remote, String branch) =>
      _guard(() => rust.deleteRemoteBranch(
            path: repo,
            remote: remote,
            branch: branch,
          ));

  /* ---------- patches ---------- */

  /// Apply a patch to the *worktree* — core's `apply_patch`, not `apply_hunk`.
  /// git applies all or nothing, so a patch that does not fit leaves the tree
  /// untouched rather than half-applied.
  Future<void> applyPatchFile(String patch) =>
      _guard(() => rust.applyPatch(path: repo, patch: patch));

  Future<String> readPatchFile(String file) =>
      _guard(() => rust.readPatchFile(file: file));

  Future<String> readClipboard() => _guard(() => rust.readClipboard());

  /// Every local change as one patch.
  Future<String> createPatch() => _guard(() => rust.createPatch(path: repo));

  /* ---------- editors ---------- */

  /// Which editors are actually installed. Core matches known .app names by
  /// prefix, so JetBrains Toolbox installs ("IntelliJ IDEA Ultimate.app") are
  /// recognised; anything off the list is not.
  static Future<List<String>> editors() => _guard(() => rust.listEditors());

  /// An empty `editor` hands the file to the system default.
  Future<void> openInEditor(String file, {String editor = ''}) =>
      _guard(() => rust.openInEditor(path: repo, file: file, editor: editor));

  /// Open the project and a file in one `open` call — two calls race on a cold
  /// start and the file can land in a different window.
  ///
  /// `project` is what the editor should treat as the project root, which in a
  /// multi-repo workspace is the workspace folder rather than [repo].
  Future<void> openProjectWithFile(
    String file, {
    String? project,
    String editor = '',
  }) =>
      _guard(() => rust.openProjectWithFile(
            project: project ?? repo,
            path: repo,
            file: file,
            editor: editor,
          ));

  Future<void> openProject({String editor = ''}) =>
      _guard(() => rust.openPath(path: repo, editor: editor));

  /* ---------- history ---------- */

  /// Move HEAD to `oid`. 'soft' keeps the index and worktree, 'mixed' resets the
  /// index, 'hard' throws away uncommitted work — the caller confirms that one.
  Future<String> resetTo(String oid, String mode) =>
      _guard(() => rust.resetTo(path: repo, oid: oid, mode: mode));

  /// A new commit that undoes `oid`, leaving history intact.
  Future<String> revert(String oid) =>
      _guard(() => rust.revertCommit(path: repo, oid: oid));

  Future<String> cherryPick(String oid) =>
      _guard(() => rust.cherryPick(path: repo, oid: oid));

  /// Tag `oid`, or HEAD when it is null.
  Future<String> createTag(String name, {String message = '', String? oid}) =>
      _guard(() => rust.createTag(
            path: repo,
            name: name,
            message: message,
            oid: oid,
          ));

  /// One commit as a patch. Core uses `format-patch`, not `diff`, so the commit
  /// message rides along in Subject and the other end can `git am` it into a
  /// commit rather than only `git apply` it into the worktree.
  Future<String> commitPatch(String oid) =>
      _guard(() => rust.createCommitPatch(path: repo, oid: oid));

  /// Goes through core rather than Flutter's own Clipboard.
  Future<void> copyToClipboard(String text) =>
      _guard(() => rust.writeClipboard(text: text));

  Future<String> deleteTag(String name) =>
      _guard(() => rust.deleteTag(path: repo, name: name));

  /// Write a patch to disk. Core does the writing.
  Future<void> savePatch(String file, String content) =>
      _guard(() => rust.savePatch(file: file, content: content));

  /* ---------- branches ---------- */

  /// Checkout goes through the git CLI in core, so post-checkout hooks and the
  /// LFS smudge filter still run and local changes are carried across the way
  /// git decides — not the way we would have to re-derive.
  Future<void> checkout(String name) =>
      _guard(() => rust.checkoutBranch(path: repo, name: name));

  Future<void> createBranch(String name,
          {String? base, bool checkout = true}) =>
      _guard(() => rust.createBranch(
            path: repo,
            name: name,
            checkout: checkout,
            base: base,
          ));

  Future<void> deleteBranch(String name) =>
      _guard(() => rust.deleteBranch(path: repo, name: name));

  Future<void> renameBranch(String name, String newName) =>
      _guard(() => rust.renameBranch(path: repo, name: name, newName: newName));

  /// Fast-forward a branch to its upstream without checking it out. A diverged
  /// branch is reported rather than quietly rewritten.
  Future<String> updateBranch(String name) =>
      _guard(() => rust.updateBranch(path: repo, name: name));

  /// Push one branch without checking it out.
  Future<String> pushBranch(String name) =>
      _guard(() => rust.pushBranch(path: repo, name: name));

  /* ---------- stash ---------- */

  Future<List<StashEntry>> stashList() =>
      _guard(() => rust.stashList(path: repo));

  /// An empty message lets git write its own ("WIP on main: …").
  Future<String> stashSave({String message = ''}) =>
      _guard(() => rust.stashSave(path: repo, message: message));

  /// Stash only the staged files; cgit-core refuses partly staged ones.
  Future<String> stashStaged({String message = ''}) =>
      _guard(() => rust.stashStaged(path: repo, message: message));

  /// Apply and remove in one step, which is what "pop" means to git.
  Future<String> stashPop(int index) =>
      _guard(() => rust.stashPop(path: repo, index: BigInt.from(index)));

  Future<String> stashDrop(int index) =>
      _guard(() => rust.stashDrop(path: repo, index: BigInt.from(index)));

  /* ---------- network ---------- */

  /// Where HEAD stands against its upstream: branch, upstream, ahead, behind.
  Future<Tracking> tracking() =>
      _guard(() => rust.getBranchTracking(path: repo));

  /// The files a push would carry — what HEAD has and the upstream does not.
  Future<List<FileStatus>> pushFiles() =>
      _guard(() => rust.getPushFiles(path: repo));

  Future<String> fetch() => _guard(() => rust.gitFetch(path: repo));

  /// `strategy` is null (--ff-only), 'merge' or 'rebase'.
  Future<String> pull({String? strategy}) =>
      _guard(() => rust.gitPull(path: repo, strategy: strategy));

  Future<String> push() => _guard(() => rust.gitPush(path: repo));

  /// `--force-with-lease`, not `--force`: it refuses to clobber commits that
  /// landed on the remote since our last fetch.
  Future<String> pushForce() => _guard(() => rust.gitPushForce(path: repo));

  /// How git itself would resolve `pull.rebase` for the current branch.
  /// Null means git config is silent — the cue to ask the user.
  Future<bool?> pullRebase() => _guard(() => rust.getPullRebase(path: repo));

  /* ---------- conflicts ---------- */

  /// Paths still carrying conflict markers in the index.
  Future<List<String>> conflicts() =>
      _guard(() => rust.getConflicts(path: repo));

  /// Which multi-step operation the repo is in the middle of, or "none".
  /// The UI needs it to offer the *matching* continue/abort: `git merge --abort`
  /// fails outright during a cherry-pick.
  Future<String> repoState() => _guard(() => rust.getRepoState(path: repo));

  Future<String> readFile(String file) =>
      _guard(() => rust.readWorktreeFile(path: repo, file: file));

  /// Resolve a whole file to one side — the fallback for conflicts with no text
  /// markers (binary, add/add).
  Future<void> resolveSide(String file, String side) =>
      _guard(() => rust.resolveConflict(path: repo, file: file, side: side));

  /// Write the merged result and mark the file resolved.
  Future<void> resolveWith(String file, String content) => _guard(
      () => rust.resolveWithContent(path: repo, file: file, content: content));

  /// Rewrite a file's markers in "merge" or "diff3" style. diff3 is the only way
  /// to get per-block common-ancestor text, and it regenerates the file from the
  /// index — so it discards manual edits, and the caller must confirm first.
  Future<String> setConflictStyle(String file, String style) =>
      _guard(() => rust.setConflictStyle(path: repo, file: file, style: style));

  /// continue / abort / skip on the in-progress merge, rebase, cherry-pick or
  /// revert. `op` comes from [repoState].
  Future<String> opAction(String op, String action) =>
      _guard(() => rust.opAction(path: repo, op: op, action: action));

  Future<String> mergeBranch(String name) =>
      _guard(() => rust.mergeBranch(path: repo, name: name));

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
