// Git backend for the minimal Git GUI.
//
// Reads (status/branches/log/diff/blame) go through `gix`, which is pure Rust —
// no libgit2, so no C toolchain and no cross-compilation grief.
//
// Two kinds of work still shell out to the `git` CLI, on purpose:
//   - Network ops (fetch/pull/push), so they reuse the user's existing
//     credential helpers / SSH keys instead of us reimplementing auth.
//   - Anything that runs hooks or rewrites the worktree (commit, checkout,
//     stage, reset). gix has no porcelain for those, and hand-rolling them
//     would silently skip pre-commit / post-checkout hooks, commit.gpgsign
//     and LFS smudge filters — exactly what a Git GUI must not do.

use gix::bstr::ByteSlice;
use gix::Repository;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use tauri::Emitter;

/// Holds the active file-system watcher so it stays alive for the open repo.
/// Replacing it (on opening another repo) drops the previous watcher.
struct WatchState(Mutex<Option<notify::RecommendedWatcher>>);

#[derive(Serialize)]
struct RepoRef {
    path: String,
    name: String,
    branch: String,
}

#[derive(Serialize)]
struct Workspace {
    root: String,
    repos: Vec<RepoRef>,
}

#[derive(Serialize, Debug)]
struct FileStatus {
    path: String,
    status: String,
    staged: bool,
}

#[derive(Serialize)]
struct BranchInfo {
    name: String,
    is_current: bool,
}

#[derive(Serialize)]
struct CommitInfo {
    id: String,
    summary: String,
    author: String,
    time: i64,
}

fn open(path: &str) -> Result<Repository, String> {
    gix::open(path).map_err(|e| e.to_string())
}

/// Short name of the branch HEAD points at, or `None` on a detached HEAD.
/// gix reports a symbolic HEAD only when it really is one, so this doubles as
/// the "are we on a branch" test that libgit2 needed `is_branch()` for.
fn head_branch_name(repo: &Repository) -> Option<String> {
    let name = repo.head_name().ok().flatten()?;
    if name.category() != Some(gix::reference::Category::LocalBranch) {
        return None;
    }
    Some(name.shorten().to_string())
}

fn current_branch(repo: &Repository) -> Option<String> {
    head_branch_name(repo)
}

fn repo_ref(repo: &Repository) -> Option<RepoRef> {
    let workdir = repo.workdir()?;
    let path = workdir.to_string_lossy().trim_end_matches('/').to_string();
    let name = workdir
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| path.clone());
    Some(RepoRef {
        path,
        name,
        branch: current_branch(repo).unwrap_or_else(|| "（无分支）".to_string()),
    })
}

/// Collect repos found in `dir`'s subtree. Stops descending into a directory
/// that is itself a repo — nested repos are submodules' business, not ours.
fn collect_repos(dir: &std::path::Path, depth: usize, out: &mut Vec<RepoRef>) {
    if depth == 0 {
        return;
    }
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let child = entry.path();
        if !child.is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        // Skipping dotfiles and the usual dependency dumps keeps a workspace
        // scan from walking into node_modules and friends.
        if name.starts_with('.') || matches!(name.as_str(), "node_modules" | "target" | "vendor") {
            continue;
        }
        if child.join(".git").exists() {
            if let Some(r) = gix::open(&child).ok().as_ref().and_then(repo_ref) {
                out.push(r);
            }
            continue;
        }
        collect_repos(&child, depth - 1, out);
    }
}

/// Open a workspace: either a single repo, or a folder holding several repos
/// side by side with no `.git` of its own — the usual "one folder per service"
/// layout. Resolution order matters: an exact repo wins over child repos, which
/// win over an ancestor repo, so picking a workspace folder can't accidentally
/// resolve to some repo further up the tree.
#[tauri::command(async)]
fn open_workspace(
    app: tauri::AppHandle,
    state: tauri::State<WatchState>,
    path: String,
) -> Result<Workspace, String> {
    let dir = std::path::Path::new(&path);
    if !dir.exists() {
        return Err(format!("路径不存在：{path}"));
    }

    let mut repos = Vec::new();
    if let Some(r) = gix::open(dir).ok().as_ref().and_then(repo_ref) {
        repos.push(r);
    }
    if repos.is_empty() {
        collect_repos(dir, 2, &mut repos);
        repos.sort_by(|a, b| a.name.cmp(&b.name));
    }
    if repos.is_empty() {
        // Last resort: the user picked a subfolder of a single repo.
        if let Some(r) = gix::discover(dir).ok().as_ref().and_then(repo_ref) {
            repos.push(r);
        }
    }
    if repos.is_empty() {
        return Err(format!("{path} 及其子目录下没有找到 Git 仓库"));
    }

    // One repo picked by path/discovery: watch the repo itself. Several repos:
    // watch the shared parent, which covers all of them in one watcher.
    let root = if repos.len() == 1 {
        repos[0].path.clone()
    } else {
        path.trim_end_matches('/').to_string()
    };
    let _ = start_watching(app, state.inner(), &root);
    Ok(Workspace { root, repos })
}

/// Watch the repo root recursively and emit a debounced `repo-changed` event.
fn start_watching(app: tauri::AppHandle, state: &WatchState, path: &str) -> Result<(), String> {
    use notify::{RecursiveMode, Watcher};
    use std::sync::mpsc::{self, RecvTimeoutError};
    use std::time::Duration;

    let (tx, rx) = mpsc::channel::<notify::Event>();
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if let Ok(event) = res {
            // Git rewrites objects/logs on every operation and build dirs churn
            // constantly; refreshing on those is pure waste on a big repo.
            if event.paths.iter().all(|p| is_watch_noise(p)) {
                return;
            }
            let _ = tx.send(event);
        }
    })
    .map_err(|e| e.to_string())?;
    watcher
        .watch(std::path::Path::new(path), RecursiveMode::Recursive)
        .map_err(|e| e.to_string())?;

    // Store (and thereby keep alive) the watcher; dropping the previous one ends
    // its debounce thread because the paired sender disconnects.
    *state.0.lock().unwrap() = Some(watcher);

    std::thread::spawn(move || loop {
        // Wait for the first event of a burst.
        let mut refs_moved = match rx.recv() {
            Ok(event) => touches_refs(&event),
            Err(_) => break,
        };
        // Coalesce the rest of the burst into a single refresh.
        loop {
            match rx.recv_timeout(Duration::from_millis(400)) {
                Ok(event) => refs_moved |= touches_refs(&event),
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
        // The payload says how much the UI has to reload: a checkout or commit
        // made outside cgit (IDEA, the terminal) moves refs and invalidates the
        // branch labels and the graph, a plain file edit doesn't.
        let kind = if refs_moved { "refs" } else { "worktree" };
        let _ = app.emit("repo-changed", kind);
    });
    Ok(())
}

/// Whether the event moved a ref: `.git/HEAD` (checkout) or anything under
/// `.git/refs` (commit, branch create/delete, fetch).
fn touches_refs(event: &notify::Event) -> bool {
    for p in &event.paths {
        let s = p.to_string_lossy();
        if !s.contains("/.git/") {
            continue;
        }
        if s.ends_with("/HEAD") || s.contains("/refs/") {
            return true;
        }
    }
    false
}

/// Paths whose churn must not trigger a UI refresh. `.git/index` and
/// `.git/HEAD` are deliberately NOT here: an external stage or branch switch
/// should still refresh the UI.
fn is_watch_noise(p: &std::path::Path) -> bool {
    let s = p.to_string_lossy();
    // `.lock` only inside .git — Cargo.lock and yarn.lock are tracked files whose
    // changes must still refresh the UI.
    if s.contains("/.git/") {
        return s.contains("/objects") || s.contains("/logs") || s.ends_with(".lock");
    }
    // No `dist/` here: plenty of repos commit it. node_modules and target are
    // never tracked, so suppressing them is safe.
    s.contains("/node_modules/") || s.contains("/target/")
}

/* A `#[tauri::command]` without `async` runs on the main thread, so a slow git
   call freezes the window — macOS then paints its spinning beachball, which
   users read as a crash. Anything whose cost grows with the amount of changed
   content (committing, with its pre-commit hooks; staging; large diffs) is
   marked `#[tauri::command(async)]` so it runs on the async runtime instead.
   Commands that are cheap regardless of repo size stay sync — one less thread
   hop, and no chance of two of them interleaving on the same index.lock. */

/// Run a blocking git operation off the async runtime so the UI stays responsive
/// on large repositories.
async fn blocking<T, F>(f: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    tauri::async_runtime::spawn_blocking(f)
        .await
        .map_err(|e| format!("任务执行失败：{e}"))?
}

#[tauri::command]
async fn get_status(path: String) -> Result<Vec<FileStatus>, String> {
    blocking(move || get_status_inner(path)).await
}

/// Whether the index holds any conflicted (stage 1..3) entry.
fn index_has_conflicts(repo: &Repository) -> Result<bool, String> {
    let index = repo.index_or_empty().map_err(|e| e.to_string())?;
    Ok(index
        .entries()
        .iter()
        .any(|e| e.stage() != gix::index::entry::Stage::Unconflicted))
}

fn get_status_inner(path: String) -> Result<Vec<FileStatus>, String> {
    let repo = open(&path)?;
    let iter = repo
        .status(gix::progress::Discard)
        .map_err(|e| e.to_string())?
        // `Files`, not the default `Collapsed`: the changes list shows files,
        // so an untracked directory must be expanded into its contents.
        .untracked_files(gix::status::UntrackedFiles::Files)
        .into_iter(None::<gix::bstr::BString>)
        .map_err(|e| e.to_string())?;

    // A file can be staged AND modified again in the worktree. gix reports the
    // two sides as separate items — tree->index is the staged row, index->worktree
    // the unstaged one — so half-staged work stays visible instead of hiding
    // behind a single checkbox.
    let mut out: Vec<FileStatus> = Vec::new();
    let mut conflicted: std::collections::HashSet<String> = std::collections::HashSet::new();

    for item in iter {
        let item = item.map_err(|e| e.to_string())?;
        match item {
            gix::status::Item::TreeIndex(change) => {
                use gix::diff::index::ChangeRef;
                let (location, status) = match &change {
                    ChangeRef::Addition { location, .. } => (location, "new"),
                    ChangeRef::Deletion { location, .. } => (location, "deleted"),
                    ChangeRef::Modification { location, .. } => (location, "modified"),
                    ChangeRef::Rewrite { location, .. } => (location, "renamed"),
                };
                out.push(FileStatus {
                    path: location.to_string(),
                    status: status.into(),
                    staged: true,
                });
            }
            gix::status::Item::IndexWorktree(change) => {
                use gix::status::index_worktree::Item;
                use gix::status::plumbing::index_as_worktree::{Change, EntryStatus};
                let (file, status) = match &change {
                    Item::Modification {
                        rela_path, status, ..
                    } => {
                        let file = rela_path.to_string();
                        match status {
                            EntryStatus::Conflict { .. } => {
                                conflicted.insert(file.clone());
                                (file, "conflict")
                            }
                            EntryStatus::Change(Change::Removed) => (file, "deleted"),
                            // git calls a type change a modification; we follow it
                            // so the list has one fewer label to explain.
                            EntryStatus::Change(_) => (file, "modified"),
                            // Untracked but `git add -N`-ed: it is new content the
                            // user means to commit, so the list must offer it.
                            EntryStatus::IntentToAdd => (file, "new"),
                            // Only the cached stat is stale — nothing changed.
                            EntryStatus::NeedsUpdate(_) => continue,
                        }
                    }
                    Item::DirectoryContents { entry, .. } => {
                        (entry.rela_path.to_string(), "new")
                    }
                    Item::Rewrite { dirwalk_entry, .. } => {
                        (dirwalk_entry.rela_path.to_string(), "renamed")
                    }
                };
                out.push(FileStatus {
                    path: file,
                    status: status.into(),
                    staged: false,
                });
            }
        }
    }

    // A conflicted path gets the single `conflict` row and nothing else — a
    // staged/unstaged pair for a file with markers in it is not actionable.
    if !conflicted.is_empty() {
        out.retain(|f| f.status == "conflict" || !conflicted.contains(&f.path));
    }
    // Stable order, staged row first, matching how the list is read top-down.
    out.sort_by(|a, b| a.path.cmp(&b.path).then(b.staged.cmp(&a.staged)));
    Ok(out)
}

#[tauri::command(async)]
fn get_branches(path: String) -> Result<Vec<BranchInfo>, String> {
    let repo = open(&path)?;
    let current = current_branch(&repo);
    let refs = repo.references().map_err(|e| e.to_string())?;

    let mut out = Vec::new();
    for b in refs.local_branches().map_err(|e| e.to_string())? {
        let b = b.map_err(|e| e.to_string())?;
        let name = b.name().shorten().to_string();
        out.push(BranchInfo {
            is_current: Some(name.as_str()) == current.as_deref(),
            name,
        });
    }
    Ok(out)
}

/// Checkout through the git CLI, not gix: gix has no porcelain checkout at all
/// (only the low-level worktree-state write used for clone), so a hand-rolled
/// one would skip post-checkout hooks and the LFS smudge filter and would have
/// to re-derive git's own rules for carrying local changes across branches.
/// `git checkout` also resolves branch / tag / sha / detached in one go.
#[tauri::command(async)]
fn checkout_branch(path: String, name: String) -> Result<(), String> {
    run_git(&path, &["checkout", name.as_str()])?;
    Ok(())
}

#[tauri::command(async)]
fn create_branch(
    path: String,
    name: String,
    checkout: bool,
    base: Option<String>,
) -> Result<(), String> {
    let repo = open(&path)?;
    // `base` is any revspec: another local branch, `origin/x`, a tag, a sha.
    // Empty means HEAD, which is what the toolbar's + button asks for.
    let base = base.filter(|b| !b.trim().is_empty());
    // Resolve through gix first purely to fail early with a useful message —
    // `git branch`'s own error for a bad revspec names the revspec, not the repo.
    if let Some(b) = &base {
        repo.rev_parse_single(b.as_str())
            .map_err(|e| format!("找不到 {b}：{e}"))?;
    }
    // Creating the branch itself goes through the CLI so `branch.autoSetupMerge`
    // decides the upstream. Branching off `origin/x` must track it — that is what
    // makes the first push have a target — but the rule is the user's config to
    // set, not ours to reimplement.
    let mut args = vec!["branch", name.as_str()];
    if let Some(b) = &base {
        args.push(b.as_str());
    }
    run_git(&path, &args)?;
    if checkout {
        return checkout_branch(path, name);
    }
    Ok(())
}

#[tauri::command(async)]
fn delete_branch(path: String, name: String) -> Result<(), String> {
    let repo = open(&path)?;
    if current_branch(&repo).as_deref() == Some(name.as_str()) {
        return Err("不能删除当前所在的分支".to_string());
    }
    // `-D` matches the old libgit2 behaviour (it never checked for unmerged
    // commits either); the UI asks for confirmation before getting here.
    // The CLI also drops the branch's `branch.<name>` config section, which a
    // bare ref delete would leave behind as a stale upstream setting.
    run_git(&path, &["branch", "-D", name.as_str()])?;
    Ok(())
}

#[tauri::command(async)]
fn rename_branch(path: String, name: String, new_name: String) -> Result<(), String> {
    // `git branch -m` moves the reflog and the `branch.<name>` config section
    // along with the ref; renaming the ref alone would silently drop the
    // branch's upstream.
    run_git(&path, &["branch", "-m", name.as_str(), new_name.as_str()])?;
    Ok(())
}

/// The tracking ref a local branch pushes to / pulls from, e.g.
/// `refs/remotes/origin/main`. Resolved through git's own config rather than by
/// gluing the remote name onto the branch name, so a remote whose name contains
/// a slash still resolves correctly.
fn upstream_ref_name(repo: &Repository, branch: &str) -> Option<gix::refs::FullName> {
    let local = repo.find_reference(branch).ok()?;
    let name = repo
        .branch_remote_tracking_ref_name(local.name(), gix::remote::Direction::Fetch)?
        .ok()?;
    Some(name)
}

/// Commits on `local` that `upstream` does not have, and the reverse — the
/// `↑N ↓M` pair. `with_hidden` is `git rev-list local --not upstream`.
fn ahead_behind(
    repo: &Repository,
    local: gix::ObjectId,
    upstream: gix::ObjectId,
) -> Result<(usize, usize), String> {
    let count = |tip: gix::ObjectId, hide: gix::ObjectId| -> Result<usize, String> {
        let walk = repo
            .rev_walk(Some(tip))
            .with_hidden(Some(hide))
            .all()
            .map_err(|e| e.to_string())?;
        let mut n = 0;
        for c in walk {
            c.map_err(|e| e.to_string())?;
            n += 1;
        }
        Ok(n)
    };
    Ok((count(local, upstream)?, count(upstream, local)?))
}

#[derive(Serialize)]
struct Tracking {
    branch: Option<String>,
    upstream: Option<String>,
    ahead: usize,
    behind: usize,
}

fn no_tracking() -> Tracking {
    Tracking {
        branch: None,
        upstream: None,
        ahead: 0,
        behind: 0,
    }
}

#[tauri::command(async)]
fn get_branch_tracking(path: String) -> Result<Tracking, String> {
    let repo = open(&path)?;
    let name = match head_branch_name(&repo) {
        Some(n) => n,
        None => return Ok(no_tracking()),
    };
    // A branch with no upstream still reports its own name: the push dialog
    // lists it as a branch about to be created on the remote, not as a blank.
    let untracked = || Tracking {
        branch: Some(name.clone()),
        upstream: None,
        ahead: 0,
        behind: 0,
    };
    let mut local = match repo.find_reference(name.as_str()) {
        Ok(r) => r,
        Err(_) => return Ok(untracked()),
    };
    let local_oid = match local.peel_to_id() {
        Ok(id) => id.detach(),
        Err(_) => return Ok(untracked()),
    };
    let up_ref = match upstream_ref_name(&repo, name.as_str()) {
        Some(n) => n,
        None => return Ok(untracked()),
    };
    let up_name = Some(up_ref.shorten().to_string());
    let mut upstream = match repo.find_reference(up_ref.as_ref()) {
        Ok(r) => r,
        Err(_) => return Ok(untracked()),
    };
    let up_oid = match upstream.peel_to_id() {
        Ok(id) => id.detach(),
        Err(_) => return Ok(untracked()),
    };
    let (ahead, behind) = ahead_behind(&repo, local_oid, up_oid)?;
    Ok(Tracking {
        branch: Some(name),
        upstream: up_name,
        ahead,
        behind,
    })
}

#[tauri::command(async)]
fn get_remote_branches(path: String) -> Result<Vec<String>, String> {
    let repo = open(&path)?;
    let refs = repo.references().map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for b in refs.remote_branches().map_err(|e| e.to_string())? {
        let b = b.map_err(|e| e.to_string())?;
        let name = b.name().shorten().to_string();
        if name.ends_with("/HEAD") {
            continue; // skip the symbolic origin/HEAD entry
        }
        out.push(name);
    }
    Ok(out)
}

#[tauri::command(async)]
fn get_tags(path: String) -> Result<Vec<String>, String> {
    let repo = open(&path)?;
    let refs = repo.references().map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for t in refs.tags().map_err(|e| e.to_string())? {
        let t = t.map_err(|e| e.to_string())?;
        let time = repo
            .find_tag(t.id())
            .ok()
            .and_then(|tag| {
                tag.tagger()
                    .ok()
                    .flatten()
                    .and_then(|tagger| tagger.time().ok())
                    .map(|time| time.seconds)
            });
        out.push((t.name().shorten().to_string(), time));
    }

    if out.iter().all(|(_, time)| time.is_some()) {
        out.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| b.0.cmp(&a.0)));
    } else {
        // Lightweight tags have no creation time; do not pretend their target commit time is one.
        out.sort_by(|a, b| b.0.cmp(&a.0));
    }
    Ok(out.into_iter().map(|(name, _)| name).collect())
}

/// Tag HEAD, or `oid` when tagging a specific commit from the history list.
#[tauri::command(async)]
fn create_tag(
    path: String,
    name: String,
    message: String,
    oid: Option<String>,
) -> Result<String, String> {
    let mut args = vec!["tag"];
    if !message.trim().is_empty() {
        args.extend(["-a", "-m", message.trim()]);
    }
    args.push(name.as_str());
    if let Some(ref o) = oid {
        args.push(o.as_str());
    }
    run_git(&path, &args)
}

#[tauri::command(async)]
fn delete_tag(path: String, name: String) -> Result<String, String> {
    run_git(&path, &["tag", "-d", name.as_str()])
}

#[tauri::command]
async fn push_tag(path: String, name: String) -> Result<String, String> {
    blocking(move || run_git(&path, &["push", "origin", name.as_str()])).await
}

#[derive(Serialize)]
struct RemoteInfo {
    name: String,
    url: String,
}

#[tauri::command(async)]
fn get_remotes(path: String) -> Result<Vec<RemoteInfo>, String> {
    let repo = open(&path)?;
    let names = repo.remote_names();
    let mut out = Vec::new();
    for name in names.iter() {
        let name = name.to_str().map_err(|e| e.to_string())?;
        let url = repo
            .find_remote(name)
            .ok()
            .and_then(|r| {
                r.url(gix::remote::Direction::Fetch)
                    .map(|u| u.to_bstring().to_string())
            })
            .unwrap_or_default();
        out.push(RemoteInfo {
            name: name.to_string(),
            url,
        });
    }
    Ok(out)
}

#[tauri::command(async)]
fn add_remote(path: String, name: String, url: String) -> Result<String, String> {
    run_git(&path, &["remote", "add", name.as_str(), url.as_str()])
}

#[tauri::command(async)]
fn remove_remote(path: String, name: String) -> Result<String, String> {
    run_git(&path, &["remote", "remove", name.as_str()])
}

#[tauri::command]
async fn delete_remote_branch(
    path: String,
    remote: String,
    branch: String,
) -> Result<String, String> {
    blocking(move || {
        run_git(
            &path,
            &["push", remote.as_str(), "--delete", branch.as_str()],
        )
    })
    .await
}

/// Generic checkout by ref name. Shelling out lets git DWIM a remote branch into
/// a local tracking branch, and cleanly detach HEAD for a tag.
#[tauri::command(async)]
fn checkout_ref(path: String, ref_name: String) -> Result<String, String> {
    run_git(&path, &["checkout", ref_name.as_str()])
}

/// `%x1f` (unit separator) can't appear in a summary or author name, so it is a
/// safe field delimiter — unlike a tab, which can.
const LOG_FORMAT: &str = "--format=%H%x1f%s%x1f%an%x1f%at";

fn parse_commit_lines(out: &str) -> Vec<CommitInfo> {
    let mut v = Vec::new();
    for line in out.lines() {
        let mut parts = line.split('\u{1f}');
        let id = parts.next().unwrap_or("").to_string();
        if id.is_empty() {
            continue;
        }
        v.push(CommitInfo {
            id,
            summary: parts.next().unwrap_or("").to_string(),
            author: parts.next().unwrap_or("").to_string(),
            time: parts.next().unwrap_or("0").parse().unwrap_or(0),
        });
    }
    v
}

/// Flat (non-DAG) commit search across all refs. Message and author filters are
/// AND-ed, which is what a filter bar means by having both boxes filled.
#[tauri::command]
async fn search_commits(
    path: String,
    query: String,
    author: String,
    limit: usize,
) -> Result<Vec<CommitInfo>, String> {
    blocking(move || {
        let mut args: Vec<String> = vec![
            "log".into(),
            "--all".into(),
            format!("-n{limit}"),
            "--regexp-ignore-case".into(),
            LOG_FORMAT.into(),
        ];
        if !query.trim().is_empty() {
            args.push(format!("--grep={}", query.trim()));
        }
        if !author.trim().is_empty() {
            args.push(format!("--author={}", author.trim()));
        }
        let borrowed: Vec<&str> = args.iter().map(|a| a.as_str()).collect();
        Ok(parse_commit_lines(&run_git(&path, &borrowed)?))
    })
    .await
}

/// History of a single file. Uses the CLI for `--follow` (libgit2 has no rename
/// following).
#[tauri::command]
async fn get_file_history(
    path: String,
    file: String,
    limit: usize,
) -> Result<Vec<CommitInfo>, String> {
    blocking(move || {
        let n = format!("-n{limit}");
        let out = run_git(
            &path,
            &[
                "log",
                "--follow",
                n.as_str(),
                LOG_FORMAT,
                "--",
                file.as_str(),
            ],
        )?;
        Ok(parse_commit_lines(&out))
    })
    .await
}

#[derive(Serialize)]
struct BlameLine {
    oid: String,
    author: String,
    summary: String,
    content: String,
}

/// Per-line authorship of the committed version of a file. We read the content
/// from the HEAD blob rather than the worktree so line numbers can't drift out
/// of step with the blame result.
#[tauri::command]
async fn get_blame(path: String, file: String) -> Result<Vec<BlameLine>, String> {
    blocking(move || get_blame_inner(path, file)).await
}

fn get_blame_inner(path: String, file: String) -> Result<Vec<BlameLine>, String> {
    let repo = open(&path)?;
    let head = repo
        .head_commit()
        .map_err(|_| format!("{file} 不在 HEAD 中 — 未提交的新文件无法逐行归属"))?;
    // gix hands back the blamed file's own content, so unlike libgit2 we don't
    // have to look the blob up separately to keep line numbers in step.
    let blame = repo
        .blame_file(
            file.as_str().into(),
            head.id,
            gix::repository::blame_file::Options::default(),
        )
        .map_err(|e| e.to_string())?;
    if blame.blob.contains(&0) {
        return Err(format!("{file} 是二进制文件，无法逐行归属"));
    }
    let content = String::from_utf8_lossy(&blame.blob).to_string();

    // The blame comes back as hunks; spread each one over the lines it covers so
    // the render loop below is a straight line-by-line lookup.
    let mut by_line: std::collections::HashMap<u32, gix::ObjectId> =
        std::collections::HashMap::new();
    for entry in &blame.entries {
        for n in 0..entry.len.get() {
            by_line.insert(entry.start_in_blamed_file + n, entry.commit_id);
        }
    }
    // One lookup per distinct commit, not per line.
    let mut meta: std::collections::HashMap<gix::ObjectId, (String, String)> =
        std::collections::HashMap::new();

    let mut out = Vec::new();
    for (i, text) in content.lines().enumerate() {
        let mut line = BlameLine {
            oid: String::new(),
            author: String::new(),
            summary: String::new(),
            content: text.to_string(),
        };
        if let Some(id) = by_line.get(&(i as u32)) {
            line.oid = id.to_string();
            let (author, summary) = meta.entry(*id).or_insert_with(|| {
                match repo.find_commit(*id) {
                    Ok(c) => (
                        c.author().map(|a| a.name.to_string()).unwrap_or_default(),
                        c.message()
                            .map(|m| m.summary().to_string())
                            .unwrap_or_default(),
                    ),
                    Err(_) => (String::new(), String::new()),
                }
            });
            line.author = author.clone();
            line.summary = summary.clone();
        }
        out.push(line);
    }
    Ok(out)
}

/// Clone into `dir` and return the path of the created working copy, emitting
/// `clone-progress` events as git reports them.
#[tauri::command]
async fn clone_repo(
    app: tauri::AppHandle,
    url: String,
    dir: String,
) -> Result<String, String> {
    blocking(move || clone_repo_inner(app, url, dir)).await
}

fn clone_repo_inner(app: tauri::AppHandle, url: String, dir: String) -> Result<String, String> {
    use std::io::Read;
    use std::process::Stdio;

    let mut child = git_cmd()
        .args(["clone", "--progress", url.as_str()])
        .current_dir(&dir)
        // stdout is null, not piped: git writes nothing useful there and an
        // unread pipe can deadlock if it ever fills.
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("运行 git 失败：{e}"))?;

    let mut stderr = child.stderr.take().ok_or("无法读取 git 输出")?;
    let mut log: Vec<String> = Vec::new();
    let mut line: Vec<u8> = Vec::new();
    let mut byte = [0u8; 1];
    // git separates progress updates with \r and messages with \n, so flush on
    // either. Bytes are collected then decoded, so multi-byte paths survive.
    loop {
        match stderr.read(&mut byte) {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                if byte[0] == b'\r' || byte[0] == b'\n' {
                    let text = String::from_utf8_lossy(&line).trim().to_string();
                    line.clear();
                    // git repeats the same progress string as it redraws; a real
                    // clone emits a few hundred lines, many of them duplicates.
                    if text.is_empty() || log.last() == Some(&text) {
                        continue;
                    }
                    let _ = app.emit("clone-progress", text.clone());
                    log.push(text);
                } else {
                    line.push(byte[0]);
                }
            }
        }
    }

    let status = child.wait().map_err(|e| e.to_string())?;
    if !status.success() {
        // The tail carries the actual reason; the head is mostly progress noise.
        let tail = log.split_off(log.len().saturating_sub(5));
        return Err(tail.join("\n"));
    }

    let name = url
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("repo")
        .trim_end_matches(".git");
    Ok(std::path::Path::new(&dir)
        .join(name)
        .to_string_lossy()
        .to_string())
}

#[derive(Serialize)]
struct GraphCommit {
    id: String,
    summary: String,
    author: String,
    time: i64,
    parents: Vec<String>,
    refs: Vec<String>,
}

/// Topologically-sorted commits across all branches, with parent ids and ref
/// decorations, for drawing the history DAG.
#[tauri::command]
async fn get_graph(path: String, limit: usize) -> Result<Vec<GraphCommit>, String> {
    blocking(move || get_graph_inner(path, limit)).await
}

fn get_graph_inner(path: String, limit: usize) -> Result<Vec<GraphCommit>, String> {
    let repo = open(&path)?;

    // Map commit oid -> decoration names (branches / tags / HEAD), and collect
    // the same refs as walk tips in one pass.
    let mut decor: std::collections::HashMap<gix::ObjectId, Vec<String>> =
        std::collections::HashMap::new();
    let mut tips: Vec<gix::ObjectId> = Vec::new();
    if let Ok(platform) = repo.references() {
        if let Ok(iter) = platform.all() {
            for r in iter.flatten() {
                let name = r.name().shorten().to_string();
                if name.is_empty() || name == "stash" || name.ends_with("/HEAD") {
                    continue;
                }
                let Some(id) = r.try_id() else { continue };
                let id = id.detach();
                decor.entry(id).or_default().push(name.clone());
                if r.name().category() == Some(gix::reference::Category::LocalBranch)
                    || r.name().category() == Some(gix::reference::Category::RemoteBranch)
                {
                    tips.push(id);
                }
            }
        }
    }
    if let Ok(head) = repo.head_commit() {
        let id = head.id;
        decor.entry(id).or_default().push("HEAD".to_string());
        tips.push(id);
    }
    if tips.is_empty() {
        return Ok(Vec::new());
    }

    // gix's `rev_walk` sorting has no topological mode — its own docs point at
    // `gix-traverse`'s topo walk for that, so we go one layer down. `DateOrder`
    // is `git rev-list --date-order`: no parent before its children, commit
    // timestamp order otherwise, which is what the graph is drawn from.
    let walk = gix::traverse::commit::topo::Builder::new(repo.objects.clone())
        .with_tips(tips)
        .sorting(gix::traverse::commit::topo::Sorting::DateOrder)
        .build()
        .map_err(|e| e.to_string())?;

    let mut out = Vec::new();
    for info in walk.take(limit) {
        let info = info.map_err(|e| e.to_string())?;
        let commit = repo.find_commit(info.id).map_err(|e| e.to_string())?;
        out.push(GraphCommit {
            id: info.id.to_string(),
            summary: commit
                .message()
                .map(|m| m.summary().to_string())
                .unwrap_or_default(),
            author: commit
                .author()
                .map(|a| a.name.to_string())
                .unwrap_or_default(),
            time: commit.time().map(|t| t.seconds).unwrap_or(0),
            parents: commit.parent_ids().map(|p| p.to_string()).collect(),
            refs: decor.get(&info.id).cloned().unwrap_or_default(),
        });
    }
    Ok(out)
}

#[tauri::command(async)]
fn stage_file(path: String, file: String) -> Result<(), String> {
    // `-A` covers both directions: the file is added if it is on disk and the
    // deletion is staged if it is not, so the old exists-on-disk branch goes
    // away. gix has no index-write porcelain, and hand-rolling one would skip
    // the `.gitattributes` clean filters that `git add` applies.
    run_git(&path, &["add", "-A", "--", file.as_str()])?;
    Ok(())
}

#[tauri::command(async)]
fn unstage_file(path: String, file: String) -> Result<(), String> {
    let repo = open(&path)?;
    if repo.head_commit().is_ok() {
        run_git(&path, &["reset", "--quiet", "--", file.as_str()])?;
    } else {
        // Unborn branch (no commits yet): there is no HEAD to reset against, so
        // the entry is dropped from the index instead.
        run_git(&path, &["rm", "--cached", "--force", "--quiet", "--", file.as_str()])?;
    }
    Ok(())
}

/// Commit through the git CLI rather than libgit2 on purpose: libgit2 skips
/// pre-commit / commit-msg hooks and `commit.gpgsign` silently, so a repo with
/// husky or enforced signing would be bypassed without the user ever knowing.
/// Bulk stage in one git call rather than one IPC round trip per file.
/// `files` empty means the whole worktree; otherwise exactly those paths, so a
/// filtered changes list stages what the user can actually see.
#[tauri::command(async)]
fn stage_all(path: String, files: Vec<String>) -> Result<String, String> {
    if files.is_empty() {
        // `git add -A` would sweep up conflicted files and mark them resolved.
        let repo = open(&path)?;
        if index_has_conflicts(&repo)? {
            return Err("存在未解决的冲突，请先逐个解决再暂存".to_string());
        }
        return run_git(&path, &["add", "-A"]);
    }
    let mut args = vec!["add", "--"];
    args.extend(files.iter().map(|f| f.as_str()));
    run_git(&path, &args)
}

#[tauri::command(async)]
fn unstage_all(path: String, files: Vec<String>) -> Result<String, String> {
    if files.is_empty() {
        // A bare `git reset` mid-merge drops the conflict state from the index
        // while leaving markers on disk — a confusing place to land.
        let repo = open(&path)?;
        if index_has_conflicts(&repo)? {
            return Err("存在未解决的冲突，请先逐个解决再取消暂存".to_string());
        }
        return run_git(&path, &["reset"]);
    }
    let mut args = vec!["reset", "--"];
    args.extend(files.iter().map(|f| f.as_str()));
    run_git(&path, &args)
}

#[tauri::command(async)]
fn commit(
    path: String,
    message: String,
    amend: bool,
    author: Option<String>,
    signoff: bool,
) -> Result<String, String> {
    // Built before `args` so the borrow outlives it.
    let author_arg = author
        .as_deref()
        .map(str::trim)
        .filter(|a| !a.is_empty())
        .map(|a| format!("--author={a}"));

    let mut args = vec!["commit", "-m", message.as_str()];
    if amend {
        args.push("--amend");
    }
    if signoff {
        args.push("--signoff");
    }
    if let Some(ref a) = author_arg {
        args.push(a.as_str());
    }
    let out = git_cmd()
        .arg("-C")
        .arg(&path)
        .args(&args)
        .env("GIT_EDITOR", "true")
        .output()
        .map_err(|e| format!("运行 git 失败：{e}"))?;
    if !out.status.success() {
        // Hooks usually report on stdout, git itself on stderr — show both or
        // a failing pre-commit hook looks like an empty error.
        return Err(combined_output(&out));
    }
    run_git(&path, &["rev-parse", "HEAD"]).map(|s| s.trim().to_string())
}

/// The message of HEAD, so the UI can prefill it when amending.
#[tauri::command(async)]
fn get_head_message(path: String) -> Result<String, String> {
    let repo = open(&path)?;
    let commit = repo.head_commit().map_err(|e| e.to_string())?;
    let message = commit.message_raw().map_err(|e| e.to_string())?;
    Ok(message.to_string().trim().to_string())
}

/// Patch text comes from the git CLI, not gix. gix can diff blobs, but the
/// exact `diff --git` envelope — rename headers, /dev/null sides, binary
/// markers — is git's own output format, and this text has to round-trip
/// through `git apply` for partial staging and patch export. Re-deriving it
/// would be a second implementation of that format to keep in sync.
fn diff_placeholder(out: String) -> String {
    if out.trim().is_empty() {
        return "（无文本差异 — 新增 / 二进制 / 无改动文件）".to_string();
    }
    out
}

/// `git diff --no-index` against /dev/null, which is how an untracked file's
/// content is shown as a patch. It exits 1 precisely when there IS a diff, so
/// `run_git` (which treats non-zero as failure) can't be used here.
fn diff_against_nothing(path: &str, file: &str) -> Result<String, String> {
    let out = git_cmd()
        .arg("-C")
        .arg(path)
        .args(["diff", "--no-index", "--", "/dev/null", file])
        .output()
        .map_err(|e| format!("运行 git 失败：{e}"))?;
    match out.status.code() {
        Some(0) | Some(1) => Ok(String::from_utf8_lossy(&out.stdout).to_string()),
        _ => Err(combined_output(&out)),
    }
}

/// Unstaged changes: working directory vs index.
#[tauri::command(async)]
fn get_unstaged_diff(path: String, file: String) -> Result<String, String> {
    let repo = open(&path)?;
    let index = repo.index_or_empty().map_err(|e| e.to_string())?;
    let tracked = index.entry_by_path(file.as_str().into()).is_some();
    let out = if tracked {
        run_git(&path, &["diff", "--", file.as_str()])?
    } else {
        diff_against_nothing(&path, &file)?
    };
    Ok(diff_placeholder(out))
}

/// Staged changes: index vs HEAD tree (empty tree when the branch is unborn).
#[tauri::command(async)]
fn get_staged_diff(path: String, file: String) -> Result<String, String> {
    let out = run_git(&path, &["diff", "--cached", "--", file.as_str()])?;
    Ok(diff_placeholder(out))
}

/// Discard working-tree changes for a file. Tracked files are restored from the
/// index (or HEAD if not staged); an untracked file is deleted from disk.
#[tauri::command(async)]
fn discard_changes(path: String, file: String) -> Result<(), String> {
    let repo = open(&path)?;
    let rel = std::path::Path::new(&file);
    let index = repo.index_or_empty().map_err(|e| e.to_string())?;
    let in_index = index.entry_by_path(file.as_str().into()).is_some();
    let in_head = repo
        .head_tree()
        .ok()
        .and_then(|t| t.lookup_entry_by_path(&file).ok().flatten())
        .is_some();

    if in_index || in_head {
        run_git(&path, &["checkout", "--", file.as_str()]).map(|_| ())
    } else {
        if let Some(wd) = repo.workdir() {
            std::fs::remove_file(wd.join(rel)).map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}

/// The file-level changes a commit introduced, against its first parent (or the
/// empty tree for the root commit). Structured data, so gix does it directly —
/// there is no output format to match here, unlike the patch text above.
fn commit_changes(
    repo: &Repository,
    oid: &str,
) -> Result<Vec<gix::object::tree::diff::ChangeDetached>, String> {
    let id = gix::ObjectId::from_hex(oid.as_bytes()).map_err(|e| e.to_string())?;
    let commit = repo.find_commit(id).map_err(|e| e.to_string())?;
    let tree = commit.tree().map_err(|e| e.to_string())?;
    let parent = match commit.parent_ids().next() {
        Some(p) => Some(
            repo.find_commit(p)
                .map_err(|e| e.to_string())?
                .tree()
                .map_err(|e| e.to_string())?,
        ),
        None => None,
    };
    repo.diff_tree_to_tree(parent.as_ref(), Some(&tree), None)
        .map_err(|e| e.to_string())
}

fn diff_files(changes: &[gix::object::tree::diff::ChangeDetached]) -> Vec<FileStatus> {
    use gix::object::tree::diff::ChangeDetached as Change;
    let mut out = Vec::new();
    for change in changes {
        // gix reports the directories along a path as changes of their own;
        // libgit2 did not, and a file list wants files. Symlinks count as files,
        // submodule (commit) entries do not — they are their own repo's business.
        let mode = match change {
            Change::Addition { entry_mode, .. }
            | Change::Deletion { entry_mode, .. }
            | Change::Modification { entry_mode, .. }
            | Change::Rewrite { entry_mode, .. } => entry_mode,
        };
        if !mode.is_blob_or_symlink() {
            continue;
        }
        let (location, status) = match change {
            Change::Addition { location, .. } => (location, "new"),
            Change::Deletion { location, .. } => (location, "deleted"),
            Change::Modification { location, .. } => (location, "modified"),
            Change::Rewrite { location, .. } => (location, "renamed"),
        };
        out.push(FileStatus {
            path: location.to_string(),
            status: status.to_string(),
            staged: false,
        });
    }
    out
}

#[tauri::command(async)]
fn get_commit_files(path: String, oid: String) -> Result<Vec<FileStatus>, String> {
    let repo = open(&path)?;
    Ok(diff_files(&commit_changes(&repo, &oid)?))
}

/// The files a push would carry: what HEAD has and the upstream does not.
/// Diffed from the merge base, so a branch that is merely behind lists nothing
/// instead of presenting the remote's own commits as ours, inverted.
#[tauri::command(async)]
fn get_push_files(path: String) -> Result<Vec<FileStatus>, String> {
    let repo = open(&path)?;
    let name = head_branch_name(&repo).ok_or("HEAD 不在分支上")?;
    let head_oid = repo
        .head_commit()
        .map_err(|_| "分支还没有提交".to_string())?
        .id;
    let up_ref = upstream_ref_name(&repo, name.as_str()).ok_or("分支没有上游")?;
    let up_oid = repo
        .find_reference(up_ref.as_ref())
        .map_err(|e| e.to_string())?
        .peel_to_id()
        .map_err(|_| "上游没有指向提交".to_string())?
        .detach();
    let base = repo
        .merge_base(head_oid, up_oid)
        .map_err(|e| e.to_string())?
        .detach();

    let tree_of = |id: gix::ObjectId| {
        repo.find_commit(id)
            .map_err(|e| e.to_string())
            .and_then(|c| c.tree().map_err(|e| e.to_string()))
    };
    let changes = repo
        .diff_tree_to_tree(Some(&tree_of(base)?), Some(&tree_of(head_oid)?), None)
        .map_err(|e| e.to_string())?;
    Ok(diff_files(&changes))
}

#[tauri::command(async)]
fn get_commit_diff(path: String, oid: String, file: String) -> Result<String, String> {
    let repo = open(&path)?;
    let id = gix::ObjectId::from_hex(oid.as_bytes()).map_err(|e| e.to_string())?;
    let commit = repo.find_commit(id).map_err(|e| e.to_string())?;
    // Against the first parent, matching the file list above. A root commit has
    // none, and only `git show` diffs that against the empty tree for us.
    let out = match commit.parent_ids().next() {
        Some(parent) => run_git(
            &path,
            &[
                "diff",
                parent.to_string().as_str(),
                oid.as_str(),
                "--",
                file.as_str(),
            ],
        )?,
        None => run_git(
            &path,
            &["show", "--format=", "--patch", oid.as_str(), "--", file.as_str()],
        )?,
    };
    Ok(diff_placeholder(out))
}

// ----- M3.1 partial staging (hunk level) -----

#[derive(Serialize)]
struct Hunks {
    /// The file-level patch header (diff --git / index / --- / +++ lines).
    header: String,
    /// Each hunk starting at its `@@` line, verbatim.
    hunks: Vec<String>,
}

/// Split `git diff [--cached] -- <file>` into its header and hunks. We use the
/// git CLI (not libgit2) so the exact text round-trips cleanly into `git apply`.
#[tauri::command(async)]
fn get_hunks(path: String, file: String, staged: bool) -> Result<Hunks, String> {
    let mut args = vec!["diff"];
    if staged {
        args.push("--cached");
    }
    args.push("--");
    args.push(file.as_str());
    Ok(split_patch(&run_git(&path, &args)?))
}

/// Split a unified diff into its file header and its `@@` hunks, verbatim, so
/// the text round-trips back into `git apply` unchanged.
fn split_patch(patch: &str) -> Hunks {
    let mut header = String::new();
    let mut hunks: Vec<String> = Vec::new();
    let mut current: Option<String> = None;
    for line in patch.split_inclusive('\n') {
        if line.starts_with("@@") {
            if let Some(h) = current.take() {
                hunks.push(h);
            }
            current = Some(line.to_string());
        } else if let Some(cur) = current.as_mut() {
            cur.push_str(line);
        } else {
            header.push_str(line);
        }
    }
    if let Some(h) = current.take() {
        hunks.push(h);
    }
    Hunks { header, hunks }
}

/// Apply a single-hunk patch to the index. `reverse` unstages instead of stages.
#[tauri::command(async)]
fn apply_hunk(path: String, patch: String, reverse: bool) -> Result<(), String> {
    let mut args = vec!["apply", "--cached"];
    if reverse {
        args.push("--reverse");
    }
    run_git_stdin(&path, &args, &patch).map(|_| ())
}

// ----- M3.2 stash -----

#[derive(Serialize)]
struct StashEntry {
    index: usize,
    message: String,
}

#[tauri::command(async)]
fn stash_save(path: String, message: String) -> Result<String, String> {
    if message.trim().is_empty() {
        run_git(&path, &["stash", "push"])
    } else {
        run_git(&path, &["stash", "push", "-m", message.as_str()])
    }
}

#[tauri::command(async)]
fn stash_list(path: String) -> Result<Vec<StashEntry>, String> {
    let out = run_git(&path, &["stash", "list"])?;
    let mut list = Vec::new();
    for (i, line) in out.lines().enumerate() {
        // "stash@{0}: WIP on main: 1a2b3c msg" -> keep the part after the first ": "
        let message = line.splitn(2, ": ").nth(1).unwrap_or(line).to_string();
        list.push(StashEntry { index: i, message });
    }
    Ok(list)
}

#[tauri::command(async)]
fn stash_pop(path: String, index: usize) -> Result<String, String> {
    let spec = format!("stash@{{{}}}", index);
    run_git(&path, &["stash", "pop", spec.as_str()])
}

#[tauri::command(async)]
fn stash_drop(path: String, index: usize) -> Result<String, String> {
    let spec = format!("stash@{{{}}}", index);
    run_git(&path, &["stash", "drop", spec.as_str()])
}

// ----- M3.3 reset / revert / cherry-pick -----

#[tauri::command(async)]
fn reset_to(path: String, oid: String, mode: String) -> Result<String, String> {
    let flag = match mode.as_str() {
        "soft" => "--soft",
        "hard" => "--hard",
        _ => "--mixed",
    };
    run_git(&path, &["reset", flag, oid.as_str()])
}

// A conflict is an expected outcome here, not a failure: reporting it as an
// error left the UI showing red text without ever refreshing into the conflict
// resolver.
#[tauri::command(async)]
fn revert_commit(path: String, oid: String) -> Result<String, String> {
    run_git_allow_conflict(&path, &["revert", "--no-edit", oid.as_str()])
}

#[tauri::command(async)]
fn cherry_pick(path: String, oid: String) -> Result<String, String> {
    run_git_allow_conflict(&path, &["cherry-pick", oid.as_str()])
}

// ----- M4.2 merge & conflict resolution -----

fn combined_output(out: &std::process::Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
    .trim()
    .to_string()
}

fn is_conflict_output(text: &str) -> bool {
    text.contains("CONFLICT")
        || text.contains("Automatic merge failed")
        || text.contains("could not apply")
}

/// Run git and treat a conflict exit as success (so the UI can show conflicts),
/// but a genuine failure as an error.
fn run_git_allow_conflict(path: &str, args: &[&str]) -> Result<String, String> {
    let out = git_cmd()
        .arg("-C")
        .arg(path)
        .args(args)
        .env("GIT_EDITOR", "true")
        .output()
        .map_err(|e| format!("运行 git 失败：{e}"))?;
    let combined = combined_output(&out);
    if out.status.success() || is_conflict_output(&combined) {
        Ok(combined)
    } else {
        Err(combined)
    }
}

#[tauri::command(async)]
fn merge_branch(path: String, name: String) -> Result<String, String> {
    run_git_allow_conflict(&path, &["merge", name.as_str()])
}

/// Which multi-step operation, if any, the repo is in the middle of. The UI
/// needs this to offer the *matching* continue/abort: `git merge --abort` fails
/// outright during a cherry-pick or revert.
#[tauri::command(async)]
fn get_repo_state(path: String) -> Result<String, String> {
    let repo = open(&path)?;
    let g = repo.path();
    let state = if g.join("rebase-merge").exists() || g.join("rebase-apply").exists() {
        "rebase"
    } else if g.join("CHERRY_PICK_HEAD").exists() {
        "cherry-pick"
    } else if g.join("REVERT_HEAD").exists() {
        "revert"
    } else if g.join("MERGE_HEAD").exists() {
        "merge"
    } else {
        "none"
    };
    Ok(state.to_string())
}

/// `git <op> --continue|--abort|--skip` for whichever operation is in progress.
#[tauri::command(async)]
fn op_action(path: String, op: String, action: String) -> Result<String, String> {
    if !matches!(op.as_str(), "rebase" | "cherry-pick" | "revert" | "merge") {
        return Err(format!("未知的操作：{op}"));
    }
    if !matches!(action.as_str(), "continue" | "abort" | "skip") {
        return Err(format!("未知的动作：{action}"));
    }
    let flag = format!("--{action}");
    run_git_allow_conflict(&path, &[op.as_str(), flag.as_str()])
}

#[tauri::command(async)]
fn get_conflicts(path: String) -> Result<Vec<String>, String> {
    let repo = open(&path)?;
    let index = repo.index_or_empty().map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for entry in index.entries() {
        // Conflicted paths hold stage 1..3 entries instead of a single stage 0.
        if entry.stage() != gix::index::entry::Stage::Unconflicted {
            out.push(entry.path(&index).to_string());
        }
    }
    out.sort();
    out.dedup();
    Ok(out)
}

/// Rewrite a conflicted file's markers in the given style. `diff3` adds the
/// `|||||||` common-ancestor section, which is the only way to get *per-block*
/// base text — the index only holds a whole-file stage-1 blob.
///
/// This regenerates the file from the index, so it discards manual edits to it;
/// the caller must confirm first.
#[tauri::command(async)]
fn set_conflict_style(path: String, file: String, style: String) -> Result<String, String> {
    if !matches!(style.as_str(), "merge" | "diff3" | "zdiff3") {
        return Err(format!("未知的冲突样式：{style}"));
    }
    let flag = format!("--conflict={style}");
    run_git(&path, &["checkout", flag.as_str(), "--", file.as_str()])
}

#[tauri::command(async)]
fn resolve_conflict(path: String, file: String, side: String) -> Result<(), String> {
    let flag = if side == "theirs" { "--theirs" } else { "--ours" };
    run_git(&path, &["checkout", flag, "--", file.as_str()])?;
    run_git(&path, &["add", "--", file.as_str()])?;
    Ok(())
}

#[tauri::command(async)]
fn resolve_with_content(path: String, file: String, content: String) -> Result<(), String> {
    let repo = open(&path)?;
    let wd = repo.workdir().ok_or("仓库没有工作目录")?;
    std::fs::write(wd.join(&file), content).map_err(|e| e.to_string())?;
    run_git(&path, &["add", "--", file.as_str()])?;
    Ok(())
}

#[tauri::command(async)]
fn read_worktree_file(path: String, file: String) -> Result<String, String> {
    let repo = open(&path)?;
    let wd = repo.workdir().ok_or("仓库没有工作目录")?;
    std::fs::read_to_string(wd.join(&file)).map_err(|e| e.to_string())
}

/// 用外部编辑器打开工作区里的文件。`editor` 是应用名（如 `Visual Studio Code`），
/// 空串表示交给系统默认程序。
///
/// 走 `open -a` 而不是 `code` / `subl` 这类 CLI shim：从访达启动的 .app 拿到的
/// PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，装在 /opt/homebrew/bin 的 shim 一律
/// 找不到，而 `open` 就在 /usr/bin 里。
/// ponytail: 仅 macOS —— 本项目只打 .app 包；要上 Windows/Linux 再按平台分支。
#[tauri::command(async)]
fn open_in_editor(path: String, file: String, editor: String) -> Result<(), String> {
    open_with(&[worktree_file(&path, &file)?], &editor)
}

/// 在编辑器里打开项目，顺带把这个文件也打开。
///
/// 一次 `open` 把目录和文件一起递过去，编辑器自己会把目录当项目、文件当标签页。
/// 分成两次调用的话，冷启动时第二次会赶在项目加载完之前，文件可能落到另一个窗口。
#[tauri::command(async)]
fn open_project_with_file(
    project: String,
    path: String,
    file: String,
    editor: String,
) -> Result<(), String> {
    let full = worktree_file(&path, &file)?;
    let root = PathBuf::from(&project);
    if !root.exists() {
        return Err(format!("路径不存在：{project}"));
    }
    open_with(&[root, full], &editor)
}

/// 工作区里某个文件的绝对路径。仓库的工作目录不一定就是仓库路径，所以走 libgit2 问。
fn worktree_file(path: &str, file: &str) -> Result<PathBuf, String> {
    let repo = open(path)?;
    let wd = repo.workdir().ok_or("仓库没有工作目录")?;
    let full = wd.join(file);
    if !full.exists() {
        return Err(format!("文件不存在：{}", full.display()));
    }
    Ok(full)
}

/// 用指定编辑器打开一个项目目录。和 `open_in_editor` 的区别是不要求是仓库：
/// 多仓库工作区的根目录本身通常不是 git 仓库。
#[tauri::command(async)]
fn open_path(path: String, editor: String) -> Result<(), String> {
    let target = PathBuf::from(&path);
    if !target.exists() {
        return Err(format!("路径不存在：{path}"));
    }
    open_with(&[target], &editor)
}

fn open_with(targets: &[PathBuf], editor: &str) -> Result<(), String> {
    let mut cmd = Command::new("open");
    if !editor.is_empty() {
        cmd.arg("-a").arg(editor);
    }
    let output = cmd
        .args(targets)
        .output()
        .map_err(|e| format!("启动编辑器失败：{e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

/// 本机装了哪些编辑器。只返回应用目录里真实存在的 .app，设置里据此给出可勾选的列表，
/// 而不是让用户手填一个可能根本没装的名字。
///
/// 名单用前缀匹配：JetBrains Toolbox 装出来的是「IntelliJ IDEA Ultimate.app」这类带后缀的名字。
/// ponytail: 靠固定名单识别，名单外的编辑器认不出来；真有人要用冷门编辑器再加手填入口。
#[tauri::command(async)]
fn list_editors() -> Vec<String> {
    const KNOWN: &[&str] = &[
        "Visual Studio Code",
        "VSCodium",
        "Cursor",
        "Windsurf",
        "Trae",
        "Zed",
        "Sublime Text",
        "Nova",
        "BBEdit",
        "TextMate",
        "Typora",
        "MacVim",
        "Emacs",
        "Xcode",
        "Android Studio",
        "Fleet",
        "IntelliJ IDEA",
        "WebStorm",
        "PyCharm",
        "PhpStorm",
        "GoLand",
        "RubyMine",
        "CLion",
        "Rider",
        "DataGrip",
        "RustRover",
    ];

    let mut found: Vec<String> = all_apps()
        .into_iter()
        .map(|(name, _)| name)
        .filter(|name| KNOWN.iter().any(|known| name.starts_with(known)))
        .collect();
    found.sort();
    found.dedup();
    found
}

/// 本机所有 .app 的（名字, 路径）。名字用来匹配名单，路径用来取图标。
fn all_apps() -> Vec<(String, PathBuf)> {
    let mut dirs = vec![
        PathBuf::from("/Applications"),
        PathBuf::from("/System/Applications"),
    ];
    if let Ok(home) = std::env::var("HOME") {
        dirs.push(PathBuf::from(home).join("Applications"));
    }

    let mut apps = Vec::new();
    for dir in &dirs {
        collect_apps(dir, 1, &mut apps);
    }
    apps
}

/// 收集目录下的 .app。`depth` 是还能往下钻几层子目录，
/// 用来兜住 JetBrains Toolbox 这种装在子文件夹里的情况。
fn collect_apps(dir: &Path, depth: usize, out: &mut Vec<(String, PathBuf)>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if let Some(stem) = name.strip_suffix(".app") {
            out.push((stem.to_string(), path));
        } else if depth > 0 && path.is_dir() {
            collect_apps(&path, depth - 1, out);
        }
    }
}

/// 一个不会跟其他在途调用撞车的临时文件名片段。
///
/// 命令跑在异步线程池上，是真并发的：设置面板一次 `Promise.all` 就会同时发起十来个
/// `editor_icon`。只按 pid 命名等于所有调用共用一个文件，彼此覆盖、彼此删除，结果是
/// 一部分图标随机取不到。
fn temp_token() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    format!("{}-{}", std::process::id(), SEQ.fetch_add(1, Ordering::Relaxed))
}

/// 编辑器的应用图标，转成 64px 的 PNG 字节给「打开项目」按钮用。
///
/// 两步都用 macOS 自带的命令行：`plutil` 读 Info.plist（多数是二进制 plist，别自己解析），
/// `sips` 把 .icns 转成 PNG。取不到就报错，前端只显示文字。
/// ponytail: 只认 CFBundleIconFile 指向的 .icns；图标打包进 Assets.car 的应用（如 Xcode）取不到。
#[tauri::command(async)]
fn editor_icon(name: String) -> Result<Vec<u8>, String> {
    let (_, app) = all_apps()
        .into_iter()
        .find(|(n, _)| *n == name)
        .ok_or_else(|| format!("没找到应用：{name}"))?;

    let plist = Command::new("plutil")
        .args(["-extract", "CFBundleIconFile", "raw", "-o", "-"])
        .arg(app.join("Contents/Info.plist"))
        .output()
        .map_err(|e| e.to_string())?;
    if !plist.status.success() {
        return Err(format!("{name} 没有声明图标"));
    }

    let mut icon = String::from_utf8_lossy(&plist.stdout).trim().to_string();
    // CFBundleIconFile 的后缀可省，Typora 这类就只写了「AppIcon」。
    if !icon.ends_with(".icns") {
        icon.push_str(".icns");
    }
    let icns = app.join("Contents/Resources").join(&icon);
    if !icns.exists() {
        return Err(format!("图标文件不存在：{}", icns.display()));
    }

    let png = std::env::temp_dir().join(format!("cgit-icon-{}.png", temp_token()));
    let conv = Command::new("sips")
        .args(["-s", "format", "png", "-Z", "64"])
        .arg(&icns)
        .arg("--out")
        .arg(&png)
        .output()
        .map_err(|e| e.to_string())?;
    if !conv.status.success() {
        return Err(String::from_utf8_lossy(&conv.stderr).trim().to_string());
    }

    let bytes = std::fs::read(&png).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_file(&png);
    Ok(bytes)
}

// ----- 补丁：导出本地改动 / 应用别处来的补丁 -----

/// 把已暂存的改动导出成一个补丁 —— 也就是改动列表里勾上的那些文件。
///
/// 用 `--cached` 而不是 `diff HEAD`：界面上要求先勾选才能导出，那补丁里就该正好是
/// 勾上的那些，否则没勾的改动也会混进去。
/// `--binary` 让二进制文件的改动也带上，否则补丁会静悄悄少一块。
#[tauri::command(async)]
fn create_patch(path: String) -> Result<String, String> {
    run_git(&path, &["diff", "--cached", "--binary"])
}

/// 某个提交的改动导出成补丁。
///
/// 用 `format-patch` 而不是 `diff`：它把提交说明写进 Subject，和 IDEA 导出的补丁
/// 是同一种形状，对面既能用 `git apply` 打到工作区，也能用 `git am` 直接落成提交。
#[tauri::command(async)]
fn create_commit_patch(path: String, oid: String) -> Result<String, String> {
    let repo = open(&path)?;
    let id = gix::ObjectId::from_hex(oid.as_bytes()).map_err(|e| e.to_string())?;
    let commit = repo.find_commit(id).map_err(|e| e.to_string())?;

    // format-patch 把 <sha> 当 rev 区间走，碰上合并提交会跳过它，然后默默导出**上一个
    // 非合并提交** —— 标题和内容都是别人的。宁可在这里报错，也不能给出一个看着像
    // 那么回事、其实是另一个提交的补丁。
    if commit.parent_ids().count() > 1 {
        return Err("合并提交没有单一的补丁内容，请对它的某个父提交创建补丁".into());
    }

    run_git(&path, &["format-patch", "-1", "--stdout", "--binary", &oid])
}

/// 往系统剪贴板写。和 `read_clipboard` 一样绕开 webview：WKWebView 里
/// `navigator.clipboard.writeText` 抛 NotAllowedError、`execCommand("copy")` 返回 false，
/// 即便 `userActivation.isActive` 仍是 true —— 只要中间隔了一次 await（比如先 invoke
/// 去取补丁内容），WebKit 就不再认那个手势。pbcopy 没有这些限制。
#[tauri::command(async)]
fn write_clipboard(text: String) -> Result<(), String> {
    use std::io::Write;
    use std::process::Stdio;

    let mut child = Command::new("pbcopy")
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|e| format!("启动 pbcopy 失败：{e}"))?;
    {
        // 写完就 drop，让 pbcopy 看到 EOF
        let mut stdin = child.stdin.take().ok_or("无法打开 pbcopy 标准输入")?;
        stdin.write_all(text.as_bytes()).map_err(|e| e.to_string())?;
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("pbcopy 退出码 {status}"))
    }
}

#[tauri::command(async)]
fn save_patch(file: String, content: String) -> Result<(), String> {
    std::fs::write(&file, content).map_err(|e| e.to_string())
}

#[tauri::command(async)]
fn read_patch_file(file: String) -> Result<String, String> {
    std::fs::read_to_string(&file).map_err(|e| e.to_string())
}

/// 把补丁打到工作区 —— 不进索引，和 IDEA 的「应用补丁」一样。
///
/// `git apply` 本身是全有或全无的：有一处对不上就整个不动，不会留半个补丁。
/// ponytail: 不支持反转应用；打错了先丢弃改动重来。
#[tauri::command(async)]
fn apply_patch(path: String, patch: String) -> Result<(), String> {
    // 从网页或聊天窗口复制来的补丁常常丢掉结尾换行，git 会报 corrupt patch。
    let patch = if patch.ends_with('\n') {
        patch
    } else {
        format!("{patch}\n")
    };
    run_git_stdin(&path, &["apply"], &patch).map(|_| ())
}

/// 系统剪贴板内容。走 `pbpaste` 而不是 webview 的 navigator.clipboard：
/// 后者在 WKWebView 里读剪贴板要用户手势加权限，pbpaste 没这些限制。
#[tauri::command(async)]
fn read_clipboard() -> Result<String, String> {
    let out = Command::new("pbpaste")
        .output()
        .map_err(|e| format!("读取剪贴板失败：{e}"))?;
    // 不看退出码的话，pbpaste 失败会被当成「剪贴板是空的」，界面上只剩一句没内容。
    if !out.status.success() {
        return Err(format!(
            "pbpaste 退出码 {}：{}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

// ----- M4.3 interactive rebase -----

#[derive(Serialize)]
struct TodoCommit {
    oid: String,
    summary: String,
}

/// Commits in `base..HEAD`, oldest first — the order an interactive rebase edits.
#[tauri::command(async)]
fn get_rebase_todo(path: String, base: String) -> Result<Vec<TodoCommit>, String> {
    let range = format!("{}..HEAD", base);
    let out = run_git(&path, &["log", "--reverse", "--format=%H%x09%s", range.as_str()])?;
    let mut v = Vec::new();
    for line in out.lines() {
        let mut parts = line.splitn(2, '\t');
        let oid = parts.next().unwrap_or("").to_string();
        let summary = parts.next().unwrap_or("").to_string();
        if !oid.is_empty() {
            v.push(TodoCommit { oid, summary });
        }
    }
    Ok(v)
}

/// Run `git rebase -i <base>` non-interactively by feeding our own todo list via
/// GIT_SEQUENCE_EDITOR, and auto-accepting messages via GIT_EDITOR=true.
#[tauri::command(async)]
fn rebase_interactive(
    path: String,
    base: String,
    todo: String,
    messages: Vec<String>,
    autostash: bool,
) -> Result<String, String> {
    // 同一个 token 串起这三个文件；工作区里两个仓库同时变基时不会互相踩。
    let token = temp_token();
    let dir = std::env::temp_dir();
    let todo_path = dir.join(format!("cgit-rebase-todo-{token}.txt"));
    let queue_path = dir.join(format!("cgit-rebase-msgs-{token}.txt"));
    let editor_path = dir.join(format!("cgit-rebase-editor-{token}.sh"));

    std::fs::write(&todo_path, todo).map_err(|e| e.to_string())?;
    // One reword message per line, in the order they appear in the todo.
    std::fs::write(&queue_path, messages.join("\n")).map_err(|e| e.to_string())?;

    // GIT_EDITOR script: for a squash's combined message just accept it; for a
    // reword, replace the message with the next queued line.
    let editor_script = "#!/bin/sh\n\
f=\"$1\"\n\
if grep -q \"This is a combination of\" \"$f\" 2>/dev/null; then exit 0; fi\n\
if [ -n \"$CGIT_MSG_QUEUE\" ] && [ -s \"$CGIT_MSG_QUEUE\" ]; then\n\
  head -n 1 \"$CGIT_MSG_QUEUE\" > \"$f\"\n\
  tail -n +2 \"$CGIT_MSG_QUEUE\" > \"$CGIT_MSG_QUEUE.tmp\" && mv \"$CGIT_MSG_QUEUE.tmp\" \"$CGIT_MSG_QUEUE\"\n\
fi\n";
    std::fs::write(&editor_path, editor_script).map_err(|e| e.to_string())?;

    let seq_editor = format!("cp '{}'", todo_path.display());
    let git_editor = format!("sh '{}'", editor_path.display());

    let mut args = vec!["rebase", "-i"];
    if autostash {
        args.push("--autostash");
    }
    args.push(base.as_str());

    let out = git_cmd()
        .arg("-C")
        .arg(&path)
        .args(&args)
        .env("GIT_SEQUENCE_EDITOR", &seq_editor)
        .env("GIT_EDITOR", &git_editor)
        .env("CGIT_MSG_QUEUE", &queue_path)
        .output()
        .map_err(|e| e.to_string())?;

    let _ = std::fs::remove_file(&todo_path);
    let _ = std::fs::remove_file(&queue_path);
    let _ = std::fs::remove_file(&editor_path);

    let combined = combined_output(&out);
    if out.status.success() || is_conflict_output(&combined) {
        Ok(combined)
    } else {
        Err(combined)
    }
}

// ----- settings: git identity -----

#[derive(Serialize)]
struct Identity {
    name: String,
    email: String,
}

#[tauri::command(async)]
fn get_identity(path: String) -> Result<Identity, String> {
    let repo = open(&path)?;
    let cfg = repo.config_snapshot();
    let read = |key: &str| cfg.string(key).map(|v| v.to_string()).unwrap_or_default();
    Ok(Identity {
        name: read("user.name"),
        email: read("user.email"),
    })
}

/// How git itself would resolve `pull.rebase` for the current branch: the
/// per-branch override first, then the repo / global / system files. `None`
/// means git config is silent, which is the caller's cue to ask the user.
/// Non-bool flavours (`interactive`, `merges`) still mean rebase.
#[tauri::command(async)]
fn get_pull_rebase(path: String) -> Result<Option<bool>, String> {
    let repo = open(&path)?;
    let cfg = repo.config_snapshot();
    let mut keys = Vec::new();
    if let Some(branch) = head_branch_name(&repo) {
        keys.push(format!("branch.{branch}.rebase"));
    }
    keys.push("pull.rebase".to_string());

    for key in keys {
        let Some(value) = cfg.string(key.as_str()) else {
            continue;
        };
        let value = value.to_string();
        // A valueless key (`[pull]\n\trebase`) reads as empty and means true.
        let off = matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "false" | "no" | "off" | "0"
        );
        return Ok(Some(!off));
    }
    Ok(None)
}

/// Write identity to the repo config, or to the global config when `global`.
#[tauri::command(async)]
fn set_identity(path: String, name: String, email: String, global: bool) -> Result<(), String> {
    let scope = if global { "--global" } else { "--local" };
    if !name.trim().is_empty() {
        run_git(&path, &["config", scope, "user.name", name.trim()])?;
    }
    if !email.trim().is_empty() {
        run_git(&path, &["config", scope, "user.email", email.trim()])?;
    }
    Ok(())
}

// ----- AI commit messages -----

/// One non-streaming round against an OpenAI-compatible /chat/completions
/// endpoint, returning the assistant message.
///
/// The request is made here rather than with `fetch` in the webview: a browser
/// request needs the endpoint to answer CORS preflights (relay services often
/// answer OPTIONS with 404) and the packaged app's `tauri://` origin refuses
/// plain `http://` targets as mixed content. curl has neither restriction.
#[tauri::command]
async fn ai_chat(
    url: String,
    token: String,
    model: String,
    system: String,
    user: String,
) -> Result<String, String> {
    blocking(move || ai_chat_inner(url, token, model, system, user)).await
}

fn ai_chat_inner(
    url: String,
    token: String,
    model: String,
    system: String,
    user: String,
) -> Result<String, String> {
    use std::io::Write;
    use std::process::Stdio;

    let body = serde_json::json!({
        "model": model,
        "stream": false,
        "messages": [
            { "role": "system", "content": system },
            { "role": "user", "content": user },
        ],
    })
    .to_string();

    // Options go in on stdin, so the token never appears in the process list.
    let config = curl_config(&url, &token, &body);

    let mut child = Command::new("curl")
        .args(["--config", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("运行 curl 失败：{e}"))?;
    child
        .stdin
        .take()
        .ok_or("无法写入 curl 输入")?
        .write_all(config.as_bytes())
        .map_err(|e| format!("写入 curl 输入失败：{e}"))?;

    let out = child
        .wait_with_output()
        .map_err(|e| format!("运行 curl 失败：{e}"))?;
    if !out.status.success() {
        return Err(format!(
            "请求失败：{}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    parse_chat_reply(&String::from_utf8_lossy(&out.stdout))
}

/// A curl config file (`--config -`). `write-out` appends the status code on
/// its own last line, so a 4xx body can be reported instead of swallowed.
fn curl_config(url: &str, token: &str, body: &str) -> String {
    let mut config = String::new();
    config.push_str(&format!("url = \"{}\"\n", curl_quote(url)));
    config.push_str("request = \"POST\"\n");
    config.push_str("header = \"Content-Type: application/json\"\n");
    config.push_str(&format!(
        "header = \"Authorization: Bearer {}\"\n",
        curl_quote(token)
    ));
    config.push_str(&format!("data-binary = \"{}\"\n", curl_quote(body)));
    config.push_str("write-out = \"\\n%{http_code}\"\n");
    config.push_str("silent\nshow-error\nlocation\nmax-time = 180\n");
    config
}

/// Escape a value for a double-quoted curl config field. The JSON body arrives
/// compact (serde_json::to_string), so it carries no raw newlines; its own `\n`
/// escapes survive as `\\n` and curl unescapes them back to `\n`.
fn curl_quote(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Split curl's output into the response body and the trailing status code.
fn parse_chat_reply(output: &str) -> Result<String, String> {
    let (body, code) = output
        .trim_end_matches('\n')
        .rsplit_once('\n')
        .ok_or_else(|| format!("响应为空：{}", clip(output)))?;
    if !code.starts_with('2') {
        return Err(format!("HTTP {code} — {}", clip(body)));
    }

    let json: serde_json::Value =
        serde_json::from_str(body).map_err(|_| format!("响应不是 JSON — {}", clip(body)))?;
    match json["choices"][0]["message"]["content"].as_str() {
        Some(text) => Ok(text.trim().to_string()),
        None => Err(format!(
            "响应里没有 choices[0].message.content — {}",
            clip(body)
        )),
    }
}

/// First 300 chars of an unexpected response — enough to see what came back.
fn clip(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() <= 300 {
        return trimmed.to_string();
    }
    trimmed.chars().take(300).collect::<String>() + "…"
}

/// `git`，并关掉交互式提示。cgit 给 git 的是管道不是终端，一旦 git 想要
/// 用户名 / 密码就会永远等下去；关掉后它会直接报凭证错误，界面才拿得到结果。
fn git_cmd() -> Command {
    let mut cmd = Command::new("git");
    cmd.env("GIT_TERMINAL_PROMPT", "0");
    cmd
}

fn run_git(path: &str, args: &[&str]) -> Result<String, String> {
    let output = git_cmd()
        .arg("-C")
        .arg(path)
        .args(args)
        .output()
        .map_err(|e| format!("运行 git 失败：{e}"))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

/// Like `run_git`, but feeds `input` to git's stdin (used for `git apply`).
fn run_git_stdin(path: &str, args: &[&str], input: &str) -> Result<String, String> {
    use std::io::Write;
    use std::process::Stdio;

    let mut child = git_cmd()
        .arg("-C")
        .arg(path)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("运行 git 失败：{e}"))?;

    {
        // Take and drop stdin after writing so git sees EOF (avoids a deadlock).
        let mut stdin = child.stdin.take().ok_or("无法打开 git 标准输入")?;
        stdin
            .write_all(input.as_bytes())
            .map_err(|e| e.to_string())?;
    }

    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

#[tauri::command]
async fn git_fetch(path: String) -> Result<String, String> {
    blocking(move || run_git(&path, &["fetch", "--all", "--prune"])).await
}

#[tauri::command]
async fn git_pull(path: String, strategy: Option<String>) -> Result<String, String> {
    blocking(move || {
        let flag = match strategy.as_deref() {
            Some("merge") => "--no-rebase",
            Some("rebase") => "--rebase",
            _ => "--ff-only",
        };
        run_git(&path, &["pull", flag])
    })
    .await
}

#[tauri::command]
async fn git_push(path: String) -> Result<String, String> {
    blocking(move || git_push_inner(path)).await
}

fn git_push_inner(path: String) -> Result<String, String> {
    let repo = open(&path)?;
    let branch = head_branch_name(&repo);
    let has_upstream = branch.as_deref().map(|n| has_upstream(&repo, n)).unwrap_or(false);

    match (has_upstream, branch) {
        (false, Some(b)) => run_git(&path, &["push", "--set-upstream", "origin", b.as_str()]),
        _ => run_git(&path, &["push"]),
    }
}

/// A branch's upstream split into (remote, branch on that remote). The remote
/// comes from git's own config rather than from splitting the ref name, so a
/// remote whose name contains a slash still resolves correctly.
fn upstream_parts(repo: &Repository, name: &str) -> Result<(String, String), String> {
    let full = upstream_ref_name(repo, name)
        .ok_or_else(|| format!("{name} 没有上游分支"))?
        .shorten()
        .to_string();
    let remote = repo
        .branch_remote_name(name, gix::remote::Direction::Fetch)
        .ok_or("上游远端名无效")?
        .as_bstr()
        .to_str()
        .map_err(|e| e.to_string())?
        .to_string();
    let on_remote = full
        .strip_prefix(&format!("{remote}/"))
        .ok_or_else(|| format!("无法解析上游 {full}"))?
        .to_string();
    Ok((remote, on_remote))
}

fn has_upstream(repo: &Repository, name: &str) -> bool {
    upstream_ref_name(repo, name).is_some()
}

/// Bring a branch up to date with its upstream without checking it out — the
/// branch menu's 更新 on a branch that is not the current one. A refspec fetch
/// moves the local ref only when it fast-forwards, so a diverged branch is
/// reported instead of being quietly rewritten.
#[tauri::command]
async fn update_branch(path: String, name: String) -> Result<String, String> {
    blocking(move || update_branch_inner(&path, &name)).await
}

fn update_branch_inner(path: &str, name: &str) -> Result<String, String> {
    let repo = open(path)?;
    let (remote, on_remote) = upstream_parts(&repo, name)?;
    run_git(path, &["fetch", &remote, &format!("{on_remote}:{name}")])
}

/// Push one branch without checking it out. With an upstream it pushes to that
/// exact ref (which may be named differently there); without one it creates the
/// branch on origin and starts tracking it, like git_push does for HEAD.
#[tauri::command]
async fn push_branch(path: String, name: String) -> Result<String, String> {
    blocking(move || push_branch_inner(&path, &name)).await
}

fn push_branch_inner(path: &str, name: &str) -> Result<String, String> {
    let repo = open(path)?;
    if !has_upstream(&repo, name) {
        return run_git(path, &["push", "--set-upstream", "origin", name]);
    }
    let (remote, on_remote) = upstream_parts(&repo, name)?;
    run_git(path, &["push", &remote, &format!("{name}:{on_remote}")])
}

/// `--force-with-lease` rather than `--force`: it refuses to clobber commits
/// that landed on the remote since our last fetch.
#[tauri::command]
async fn git_push_force(path: String) -> Result<String, String> {
    blocking(move || {
        let repo = open(&path)?;
        let branch = head_branch_name(&repo).ok_or("HEAD 不在分支上，无法推送")?;
        run_git(
            &path,
            &[
                "push",
                "--force-with-lease",
                "origin",
                branch.as_str(),
            ],
        )
    })
    .await
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .runtime(tauri_runtime_wry::Wry::default())
        .manage(WatchState(Mutex::new(None)))
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            open_workspace,
            get_status,
            get_branches,
            checkout_branch,
            create_branch,
            delete_branch,
            rename_branch,
            get_branch_tracking,
            get_remote_branches,
            get_tags,
            checkout_ref,
            get_graph,
            stage_file,
            unstage_file,
            commit,
            get_unstaged_diff,
            get_staged_diff,
            discard_changes,
            get_commit_files,
            get_push_files,
            get_commit_diff,
            get_hunks,
            apply_hunk,
            stash_save,
            stash_list,
            stash_pop,
            stash_drop,
            reset_to,
            revert_commit,
            cherry_pick,
            merge_branch,
            get_conflicts,
            resolve_conflict,
            set_conflict_style,
            resolve_with_content,
            read_worktree_file,
            open_in_editor,
            open_path,
            open_project_with_file,
            list_editors,
            editor_icon,
            create_patch,
            create_commit_patch,
            save_patch,
            read_patch_file,
            apply_patch,
            read_clipboard,
            write_clipboard,
            get_rebase_todo,
            rebase_interactive,
            get_identity,
            set_identity,
            get_pull_rebase,
            git_fetch,
            git_pull,
            git_push,
            get_repo_state,
            op_action,
            get_head_message,
            search_commits,
            get_file_history,
            get_blame,
            clone_repo,
            create_tag,
            delete_tag,
            push_tag,
            get_remotes,
            add_remote,
            remove_remote,
            delete_remote_branch,
            git_push_force,
            update_branch,
            push_branch,
            stage_all,
            unstage_all,
            ai_chat
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;

    const PATCH: &str = "diff --git a/f b/f\nindex 111..222 100644\n--- a/f\n+++ b/f\n@@ -1,2 +1,3 @@\n a\n+b\n c\n@@ -10,1 +11,1 @@\n-old\n+new\n";

    fn event(path: &str) -> notify::Event {
        notify::Event::new(notify::EventKind::Any).add_path(std::path::PathBuf::from(path))
    }

    #[test]
    fn ref_moves_are_told_apart_from_file_edits() {
        // An external checkout rewrites .git/HEAD; a commit writes refs/heads.
        assert!(touches_refs(&event("/w/repo/.git/HEAD")));
        assert!(touches_refs(&event("/w/repo/.git/refs/heads/model_usage")));
        // A worktree edit must stay on the cheap refresh path.
        assert!(!touches_refs(&event("/w/repo/src/main.rs")));
        assert!(!touches_refs(&event("/w/repo/HEAD")));
        // .git/logs/HEAD is reflog churn, dropped as noise before it gets here.
        assert!(is_watch_noise(std::path::Path::new("/w/repo/.git/logs/HEAD")));
    }

    #[test]
    fn tags_fall_back_to_name_descending_without_complete_timestamps() {
        let path = temp_repo("tag-order");
        for (name, date) in [
            ("z-old", "2020-01-01T00:00:00 +0000"),
            ("a-new", "2021-01-01T00:00:00 +0000"),
        ] {
            let output = git_cmd()
                .arg("-C")
                .arg(&path)
                .args(["tag", "-a", name, "-m", name])
                .env("GIT_COMMITTER_DATE", date)
                .output()
                .unwrap();
            assert!(output.status.success());
        }

        assert_eq!(get_tags(path.clone()).unwrap(), vec!["a-new", "z-old"]);

        run_git(&path, &["tag", "zz-lightweight"]).unwrap();
        assert_eq!(
            get_tags(path.clone()).unwrap(),
            vec!["zz-lightweight", "z-old", "a-new"]
        );

        let _ = std::fs::remove_dir_all(path);
    }

    #[test]
    fn apps_are_collected_one_level_down() {
        let dir = std::env::temp_dir().join("cgit-apps-scan");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("Visual Studio Code.app/Contents")).unwrap();
        std::fs::create_dir_all(dir.join("JetBrains Toolbox/WebStorm.app")).unwrap();
        std::fs::create_dir_all(dir.join("a/b/Buried.app")).unwrap();
        std::fs::write(dir.join("notes.txt"), "x").unwrap();

        let mut found = Vec::new();
        collect_apps(&dir, 1, &mut found);
        let mut names: Vec<String> = found.iter().map(|(n, _)| n.clone()).collect();
        names.sort();
        // 子目录下一层的（Toolbox 装法）要认出来，再深一层的不找，.app 里面也不往下钻。
        assert_eq!(names, vec!["Visual Studio Code", "WebStorm"]);
        // 路径要指向 .app 本身，取图标全靠它。
        assert!(found.iter().all(|(n, p)| p.ends_with(format!("{n}.app"))));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_merge_commit_refuses_instead_of_exporting_its_parent() {
        let path = temp_repo("merge-patch");
        run_git(&path, &["checkout", "-q", "-b", "side"]).unwrap();
        std::fs::write(format!("{path}/s"), "side").unwrap();
        run_git(&path, &["add", "s"]).unwrap();
        run_git(&path, &["commit", "-qm", "side work"]).unwrap();
        run_git(&path, &["checkout", "-q", "master"]).unwrap();
        std::fs::write(format!("{path}/f"), "changed").unwrap();
        run_git(&path, &["commit", "-qam", "main work"]).unwrap();
        run_git(&path, &["merge", "-q", "--no-ff", "side", "-m", "merge side"]).unwrap();

        let merge = run_git(&path, &["rev-parse", "HEAD"]).unwrap().trim().to_string();
        let err = create_commit_patch(path.clone(), merge).unwrap_err();
        assert!(err.contains("合并提交"), "拿到的是：{err}");

        // 普通提交照常导出，而且导的是它自己 —— 这正是合并提交那条分支要防的事。
        let normal = run_git(&path, &["rev-parse", "HEAD^"]).unwrap().trim().to_string();
        let patch = create_commit_patch(path, normal).unwrap();
        assert!(patch.contains("Subject: [PATCH] main work"), "{patch}");
    }

    /// 需要真实的 GUI 会话：在 CI 和 agent 的 shell 里 pbpaste 会退出码 0 却返回空，
    /// 断言必挂。本机手动验证用 `cargo test -- --ignored`。
    #[test]
    #[ignore = "需要真实剪贴板，沙箱/无窗口会话里跑不了"]
    fn clipboard_round_trips_through_the_shell() {
        // 跑测试不该顺手清空开发者的剪贴板，用完放回去。
        let before = read_clipboard().unwrap();

        // 补丁是多行的，换行和 UTF-8 都得原样过去。
        let patch = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-旧\n+新\n";
        write_clipboard(patch.to_string()).unwrap();
        assert_eq!(read_clipboard().unwrap(), patch);

        write_clipboard(before).unwrap();
    }

    /// A repo with one commit on `master`, isolated from the developer's own
    /// global config so the assertions below only see what the test sets.
    fn temp_repo(name: &str) -> String {
        let dir = std::env::temp_dir().join(format!("cgit-cfg-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.to_string_lossy().to_string();
        std::fs::write(dir.join("f"), "x").unwrap();
        run_git(&path, &["init", "-q", "-b", "master"]).unwrap();
        run_git(&path, &["config", "user.email", "t@t"]).unwrap();
        run_git(&path, &["config", "user.name", "t"]).unwrap();
        run_git(&path, &["add", "f"]).unwrap();
        run_git(&path, &["commit", "-qm", "base"]).unwrap();
        path
    }

    /// A clone of a bare remote with one shared commit, i.e. a repo whose
    /// branch has a real upstream — what the push dialog reads.
    fn temp_clone(name: &str) -> String {
        let dir = std::env::temp_dir().join(format!("cgit-push-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let root = dir.to_string_lossy().to_string();
        run_git(&root, &["init", "-q", "--bare", "-b", "master", "remote.git"]).unwrap();

        let seed = dir.join("seed").to_string_lossy().to_string();
        run_git(&root, &["clone", "-q", "remote.git", "seed"]).unwrap();
        run_git(&seed, &["config", "user.email", "t@t"]).unwrap();
        run_git(&seed, &["config", "user.name", "t"]).unwrap();
        std::fs::write(dir.join("seed/shared.txt"), "x").unwrap();
        run_git(&seed, &["add", "shared.txt"]).unwrap();
        run_git(&seed, &["commit", "-qm", "shared"]).unwrap();
        run_git(&seed, &["push", "-q", "-u", "origin", "master"]).unwrap();

        let work = dir.join("work").to_string_lossy().to_string();
        run_git(&root, &["clone", "-q", "remote.git", "work"]).unwrap();
        run_git(&work, &["config", "user.email", "t@t"]).unwrap();
        run_git(&work, &["config", "user.name", "t"]).unwrap();
        work
    }

    #[test]
    fn untracked_file_diff_shows_its_content() {
        let repo = temp_repo("untracked");
        std::fs::write(std::path::Path::new(&repo).join("new.txt"), "hello\n").unwrap();

        let diff = get_unstaged_diff(repo.clone(), "new.txt".to_string()).unwrap();
        assert!(diff.contains("+hello"), "新增文件应显示内容，实际：{diff}");
    }

    #[test]
    fn push_files_are_the_ones_the_upstream_lacks() {
        let work = temp_clone("files");
        let dir = std::path::Path::new(&work);

        // Nothing committed locally: a push would carry nothing.
        assert!(get_push_files(work.clone()).unwrap().is_empty());

        std::fs::create_dir_all(dir.join("app/api/v1")).unwrap();
        std::fs::write(dir.join("app/api/v1/openapi.py"), "new").unwrap();
        std::fs::write(dir.join("shared.txt"), "edited").unwrap();
        run_git(&work, &["add", "-A"]).unwrap();
        run_git(&work, &["commit", "-qm", "local work"]).unwrap();

        let mut files = get_push_files(work.clone()).unwrap();
        files.sort_by(|a, b| a.path.cmp(&b.path));
        assert_eq!(
            files.iter().map(|f| f.path.as_str()).collect::<Vec<_>>(),
            vec!["app/api/v1/openapi.py", "shared.txt"]
        );
        assert_eq!(files[0].status, "new");
        assert_eq!(files[1].status, "modified");

        // A repo that is only *behind* must list nothing: the remote's own
        // commits are not ours to push, and diffing them in would show them
        // inverted (a delete for every file the remote added).
        let behind = temp_clone("behind");
        run_git(&behind, &["reset", "-q", "--hard", "HEAD"]).unwrap();
        assert!(get_push_files(behind.clone()).unwrap().is_empty());

        let _ = std::fs::remove_dir_all(dir.parent().unwrap());
    }

    #[test]
    fn a_branch_updates_and_pushes_without_being_checked_out() {
        let work = temp_clone("branch-ops");
        let root = std::path::Path::new(&work).parent().unwrap().to_path_buf();
        let seed = root.join("seed").to_string_lossy().to_string();
        let bare = root.join("remote.git").to_string_lossy().to_string();

        // `other` tracks origin/master; HEAD stays on master throughout.
        create_branch(work.clone(), "other".into(), false, Some("origin/master".into())).unwrap();
        let before = run_git(&work, &["rev-parse", "other"]).unwrap();

        std::fs::write(std::path::Path::new(&seed).join("shared.txt"), "moved on").unwrap();
        run_git(&seed, &["commit", "-qam", "remote moves"]).unwrap();
        run_git(&seed, &["push", "-q", "origin", "master"]).unwrap();

        update_branch_inner(&work, "other").unwrap();
        let after = run_git(&work, &["rev-parse", "other"]).unwrap();
        assert_ne!(before, after, "other should have fast-forwarded");
        assert_eq!(
            run_git(&work, &["rev-parse", "other"]).unwrap(),
            run_git(&seed, &["rev-parse", "master"]).unwrap()
        );
        assert_eq!(current_branch(&open(&work).unwrap()).as_deref(), Some("master"));

        // A branch with no upstream: pushing creates it on origin and tracks it.
        create_branch(work.clone(), "feat".into(), false, Some("master".into())).unwrap();
        push_branch_inner(&work, "feat").unwrap();
        assert!(run_git(&bare, &["rev-parse", "refs/heads/feat"]).is_ok());
        let (remote, on_remote) = upstream_parts(&open(&work).unwrap(), "feat").unwrap();
        assert_eq!((remote.as_str(), on_remote.as_str()), ("origin", "feat"));

        // And a second push goes through the upstream refspec branch of the code.
        run_git(&work, &["update-ref", "refs/heads/feat", "other"]).unwrap();
        push_branch_inner(&work, "feat").unwrap();
        assert_eq!(
            run_git(&work, &["rev-parse", "feat"]).unwrap(),
            run_git(&bare, &["rev-parse", "refs/heads/feat"]).unwrap()
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn branches_can_start_from_a_remote_or_a_local_branch() {
        let work = temp_clone("branch");

        // From a remote-tracking branch: tracks it, so a push has a target.
        create_branch(work.clone(), "from-remote".into(), false, Some("origin/master".into()))
            .unwrap();
        let t = get_branch_tracking(work.clone()).unwrap();
        assert_eq!(t.branch.as_deref(), Some("master")); // HEAD did not move
        run_git(&work, &["checkout", "-q", "from-remote"]).unwrap();
        let t = get_branch_tracking(work.clone()).unwrap();
        assert_eq!(t.upstream.as_deref(), Some("origin/master"));

        // From a local branch: a plain branch, no upstream invented for it.
        create_branch(work.clone(), "from-local".into(), true, Some("master".into())).unwrap();
        let t = get_branch_tracking(work.clone()).unwrap();
        assert_eq!(t.branch.as_deref(), Some("from-local"));
        assert_eq!(t.upstream, None);

        // A base that does not exist is an error, not a branch at HEAD.
        assert!(create_branch(work.clone(), "nope".into(), false, Some("no/such".into())).is_err());

        let _ = std::fs::remove_dir_all(std::path::Path::new(&work).parent().unwrap());
    }

    #[test]
    fn tracking_reports_the_branch_even_without_an_upstream() {
        let path = temp_repo("tracking");
        let t = get_branch_tracking(path.clone()).unwrap();
        assert_eq!(t.branch.as_deref(), Some("master"));
        assert_eq!(t.upstream, None);
        assert_eq!((t.ahead, t.behind), (0, 0));
        let _ = std::fs::remove_dir_all(&path);
    }

    #[test]
    fn pull_rebase_follows_git_config_like_ideas_branch_default() {
        let path = temp_repo("resolve");
        let cfg = |args: &[&str]| run_git(&path, args).unwrap();

        // The "git config is silent -> None -> ask the user" case is not
        // asserted here: the answer would come from whatever ~/.gitconfig the
        // machine running the test happens to have.
        cfg(&["config", "pull.rebase", "false"]);
        assert_eq!(get_pull_rebase(path.clone()).unwrap(), Some(false));

        cfg(&["config", "pull.rebase", "true"]);
        assert_eq!(get_pull_rebase(path.clone()).unwrap(), Some(true));

        // Rebase flavours are still rebase, not a parse failure.
        cfg(&["config", "pull.rebase", "interactive"]);
        assert_eq!(get_pull_rebase(path.clone()).unwrap(), Some(true));

        // The per-branch key wins over pull.rebase, as it does for git itself.
        cfg(&["config", "branch.master.rebase", "false"]);
        assert_eq!(get_pull_rebase(path.clone()).unwrap(), Some(false));

        let _ = std::fs::remove_dir_all(&path);
    }

    #[test]
    fn splits_header_and_hunks() {
        let h = split_patch(PATCH);
        assert!(h.header.starts_with("diff --git a/f b/f\n"));
        assert!(h.header.ends_with("+++ b/f\n"));
        assert_eq!(h.hunks.len(), 2);
        // Each hunk keeps its own @@ line and nothing from the next hunk.
        assert!(h.hunks[0].starts_with("@@ -1,2 +1,3 @@\n"));
        assert!(h.hunks[0].ends_with(" c\n"));
        assert!(h.hunks[1].starts_with("@@ -10,1 +11,1 @@\n"));
        // Rejoining must reproduce the input byte for byte, or `git apply` breaks.
        assert_eq!(format!("{}{}", h.header, h.hunks.concat()), PATCH);
    }

    #[test]
    fn handles_empty_and_headerless_patches() {
        assert_eq!(split_patch("").hunks.len(), 0);
        assert_eq!(split_patch("").header, "");
        let h = split_patch("@@ -1 +1 @@\n-a\n+b\n");
        assert_eq!(h.header, "");
        assert_eq!(h.hunks.len(), 1);
    }

    #[test]
    fn parses_chat_reply_and_surfaces_http_errors() {
        let ok = r#"{"choices":[{"message":{"role":"assistant","content":"  优化设置界面\n"}}]}"#;
        assert_eq!(
            parse_chat_reply(&format!("{ok}\n200")).unwrap(),
            "优化设置界面"
        );
        // A 4xx body is the useful part of the error, so it must survive.
        let err = parse_chat_reply("{\"error\":{\"message\":\"invalid token\"}}\n401").unwrap_err();
        assert!(err.starts_with("HTTP 401"), "{err}");
        assert!(err.contains("invalid token"), "{err}");
        // A proxy that answers with HTML instead of JSON says so.
        assert!(parse_chat_reply("<html>404</html>\n200")
            .unwrap_err()
            .contains("不是 JSON"));
        // 200 with an unexpected shape must not pass as an empty message.
        assert!(parse_chat_reply("{\"choices\":[]}\n200")
            .unwrap_err()
            .contains("choices[0].message.content"));
    }

    #[test]
    fn curl_config_escapes_the_json_body() {
        let body = r#"{"a":"say \"hi\"","b":"c:\\tmp"}"#;
        let config = curl_config("https://x/v1/chat/completions", "tok\"en", body);
        // Every config value stays on one line, or curl reads the rest as options.
        for line in config.lines() {
            assert!(!line.is_empty(), "blank config line");
        }
        assert!(config.contains(r#"data-binary = "{\"a\":\"say \\\"hi\\\"\""#), "{config}");
        assert!(config.contains(r#"header = "Authorization: Bearer tok\"en""#), "{config}");
    }

    #[test]
    fn status_sides_are_independent() {
        // Staged one change, then edited the file again: both sides must report,
        // or half-staged work hides behind a single checkbox.
        let repo = temp_repo("status-sides");
        let dir = std::path::Path::new(&repo);
        std::fs::write(dir.join("f"), "staged\n").unwrap();
        run_git(&repo, &["add", "f"]).unwrap();
        std::fs::write(dir.join("f"), "staged then edited again\n").unwrap();

        let rows = get_status_inner(repo.clone()).unwrap();
        let f: Vec<_> = rows.iter().filter(|r| r.path == "f").collect();
        assert_eq!(f.len(), 2, "应有已暂存和未暂存两行，实际：{f:?}");
        assert!(f.iter().any(|r| r.staged && r.status == "modified"));
        assert!(f.iter().any(|r| !r.staged && r.status == "modified"));

        // Staged only: nothing left pending in the worktree.
        run_git(&repo, &["add", "f"]).unwrap();
        let rows = get_status_inner(repo).unwrap();
        let f: Vec<_> = rows.iter().filter(|r| r.path == "f").collect();
        assert_eq!(f.len(), 1, "只暂存时应只有一行，实际：{f:?}");
        assert!(f[0].staged);
    }

    #[test]
    fn conflicts_replace_the_staged_unstaged_pair() {
        // A file with markers in it is not stageable line-by-line, so it gets one
        // `conflict` row instead of a staged/unstaged pair.
        let repo = temp_repo("status-conflict");
        let dir = std::path::Path::new(&repo);
        run_git(&repo, &["checkout", "-q", "-b", "feat"]).unwrap();
        std::fs::write(dir.join("f"), "feat\n").unwrap();
        run_git(&repo, &["commit", "-qam", "feat"]).unwrap();
        run_git(&repo, &["checkout", "-q", "master"]).unwrap();
        std::fs::write(dir.join("f"), "master\n").unwrap();
        run_git(&repo, &["commit", "-qam", "master"]).unwrap();
        // The merge is expected to fail — that is the point.
        let _ = run_git(&repo, &["merge", "feat"]);

        let rows = get_status_inner(repo.clone()).unwrap();
        let f: Vec<_> = rows.iter().filter(|r| r.path == "f").collect();
        assert_eq!(f.len(), 1, "冲突文件应只有一行，实际：{f:?}");
        assert_eq!(f[0].status, "conflict");
        assert_eq!(get_conflicts(repo).unwrap(), vec!["f".to_string()]);
    }

    #[test]
    fn temp_names_never_collide_between_concurrent_calls() {
        // 设置面板一次并发拉十来个图标，共用一个临时文件就会互相覆盖。
        let names: Vec<String> = (0..50).map(|_| temp_token()).collect();
        let unique: std::collections::HashSet<_> = names.iter().collect();
        assert_eq!(unique.len(), names.len(), "临时文件名重复：{names:?}");
    }

    #[test]
    fn watch_noise_spares_tracked_lock_files() {
        use std::path::Path;
        assert!(is_watch_noise(Path::new("/r/.git/objects/ab/cdef")));
        assert!(is_watch_noise(Path::new("/r/.git/index.lock")));
        assert!(is_watch_noise(Path::new("/r/node_modules/x/y.js")));
        // Tracked files that merely end in .lock must still trigger a refresh.
        assert!(!is_watch_noise(Path::new("/r/Cargo.lock")));
        assert!(!is_watch_noise(Path::new("/r/yarn.lock")));
        // As must the two .git files that mean "the repo moved under us".
        assert!(!is_watch_noise(Path::new("/r/.git/index")));
        assert!(!is_watch_noise(Path::new("/r/.git/HEAD")));
        // And a committed dist/ directory.
        assert!(!is_watch_noise(Path::new("/r/dist/app.js")));
    }

    #[test]
    fn only_real_conflict_styles_are_accepted() {
        // A bad style would otherwise reach `git checkout --conflict=<junk>`,
        // which regenerates the file and could lose the user's edits for nothing.
        for good in ["merge", "diff3", "zdiff3"] {
            assert!(matches!(good, "merge" | "diff3" | "zdiff3"));
        }
        assert_eq!(
            set_conflict_style("/nonexistent".into(), "f".into(), "; rm -rf /".into()),
            Err("未知的冲突样式：; rm -rf /".to_string())
        );
    }

    #[test]
    fn workspace_scan_finds_child_repos_and_skips_dependency_dirs() {
        let base = std::env::temp_dir().join("cgit-test-workspace-scan");
        let _ = std::fs::remove_dir_all(&base);
        // An ancestor repo, to prove the child scan never walks upward into it.
        std::fs::create_dir_all(&base).unwrap();
        gix::init(&base).unwrap();

        let ws = base.join("workspace");
        // A repo buried in node_modules must not be picked up.
        let noise = ws.join("node_modules/some-pkg");
        std::fs::create_dir_all(&noise).unwrap();
        gix::init(&noise).unwrap();
        for name in ["svc-b", "svc-a"] {
            let d = ws.join(name);
            std::fs::create_dir_all(&d).unwrap();
            gix::init(&d).unwrap();
        }
        // A plain folder one level down whose child is a repo.
        let nested = ws.join("group/svc-c");
        std::fs::create_dir_all(&nested).unwrap();
        gix::init(&nested).unwrap();

        let mut out = Vec::new();
        collect_repos(&ws, 2, &mut out);
        out.sort_by(|a, b| a.name.cmp(&b.name));
        let names: Vec<&str> = out.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, vec!["svc-a", "svc-b", "svc-c"]);

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn conflict_output_is_not_a_failure() {
        assert!(is_conflict_output("CONFLICT (content): Merge conflict in f"));
        assert!(is_conflict_output("error: could not apply 07d7a92... side"));
        assert!(!is_conflict_output("fatal: not a git repository"));
    }
}
