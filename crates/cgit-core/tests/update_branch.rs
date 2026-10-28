use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

struct Fixture {
    root: PathBuf,
    remote: PathBuf,
    work: PathBuf,
    before: String,
    after: String,
}

fn git(path: &std::path::Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout)
        .unwrap()
        .trim_end()
        .to_string()
}

impl Fixture {
    fn new() -> Self {
        static SEQ: AtomicUsize = AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "cgit-update-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
        let remote = root.join("remote.git");
        // Reuse existing history: these tests never stage, commit or push.
        git(
            &root,
            &[
                "clone",
                "--bare",
                "--no-hardlinks",
                source.to_str().unwrap(),
                "remote.git",
            ],
        );
        // Select an existing change even when the latest commit only adds files.
        let after = git(
            &remote,
            &["log", "-1", "--no-merges", "--diff-filter=M", "--format=%H"],
        );
        let before = git(&remote, &["rev-parse", &format!("{after}~1")]);
        git(&remote, &["update-ref", "refs/heads/offline", &before]);
        git(&remote, &["symbolic-ref", "HEAD", "refs/heads/offline"]);
        git(&root, &["clone", "remote.git", "work"]);
        let work = root.join("work");
        git(&remote, &["update-ref", "refs/heads/offline", &after]);
        Self {
            root,
            remote,
            work,
            before,
            after,
        }
    }

    fn update(&self, branch: &str) -> Result<String, String> {
        cgit_core::update_branch(self.work.to_str().unwrap(), branch)
    }

    fn other_branch(&self) {
        git(
            &self.work,
            &["branch", "--track", "other", "origin/offline"],
        );
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn update_current_branch_fast_forwards_worktree_and_index() {
    let f = Fixture::new();
    f.update("offline").unwrap();
    assert_eq!(git(&f.work, &["rev-parse", "HEAD"]), f.after);
    assert_eq!(
        git(&f.work, &["symbolic-ref", "--short", "HEAD"]),
        "offline"
    );
    assert_eq!(git(&f.work, &["status", "--porcelain"]), "");
}

#[test]
fn update_current_branch_preserves_overlapping_local_edits() {
    let f = Fixture::new();
    let changed = git(
        &f.remote,
        &[
            "diff",
            "--name-only",
            "-z",
            "--diff-filter=M",
            &f.before,
            &f.after,
        ],
    );
    let file = changed
        .split('\0')
        .next()
        .expect("fixture history must change a file");
    std::fs::write(f.work.join(file), "local edit\n").unwrap();
    let error = f.update("offline").unwrap_err();
    assert!(error.contains("would be overwritten"), "{error}");
    assert_eq!(git(&f.work, &["rev-parse", "HEAD"]), f.before);
    assert_eq!(
        std::fs::read_to_string(f.work.join(file)).unwrap(),
        "local edit\n"
    );
}

#[test]
fn update_unchecked_branch_keeps_current_worktree_unchanged() {
    let f = Fixture::new();
    f.other_branch();
    // A same-named tag must not make the destination ambiguous.
    git(&f.work, &["update-ref", "refs/tags/other", &f.before]);
    std::fs::write(f.work.join("local-untracked.txt"), "keep me").unwrap();
    let status = git(&f.work, &["status", "--porcelain"]);
    f.update("other").unwrap();
    assert_eq!(git(&f.work, &["rev-parse", "refs/heads/other"]), f.after);
    assert_eq!(
        git(&f.work, &["rev-parse", "refs/remotes/origin/offline"]),
        f.after
    );
    assert_eq!(git(&f.work, &["rev-parse", "HEAD"]), f.before);
    assert_eq!(git(&f.work, &["rev-parse", "refs/tags/other"]), f.before);
    assert_eq!(git(&f.work, &["status", "--porcelain"]), status);
}

#[test]
fn update_branch_in_another_worktree_reports_path_without_touching_it() {
    let f = Fixture::new();
    f.other_branch();
    let linked = f.root.join("另一个 worktree\nwith newline");
    git(
        &f.work,
        &["worktree", "add", linked.to_str().unwrap(), "other"],
    );
    std::fs::write(linked.join("local.txt"), "keep me").unwrap();
    let error = f.update("other").unwrap_err();
    assert!(error.contains(linked.to_str().unwrap()), "{error}");
    assert!(error.contains("请在该工作区"), "{error}");
    assert_eq!(git(&linked, &["rev-parse", "HEAD"]), f.before);
    assert_eq!(
        std::fs::read_to_string(linked.join("local.txt")).unwrap(),
        "keep me"
    );
}

#[test]
fn update_unchecked_branch_refuses_non_fast_forward() {
    let f = Fixture::new();
    f.other_branch();
    git(&f.work, &["update-ref", "refs/heads/other", &f.after]);
    git(&f.remote, &["update-ref", "refs/heads/offline", &f.before]);
    assert!(f.update("other").is_err());
    assert_eq!(git(&f.work, &["rev-parse", "other"]), f.after);
}

#[test]
fn update_current_branch_does_not_rewind_local_history() {
    let f = Fixture::new();
    f.update("offline").unwrap();
    git(&f.remote, &["update-ref", "refs/heads/offline", &f.before]);
    f.update("offline").unwrap();
    assert_eq!(git(&f.work, &["rev-parse", "HEAD"]), f.after);
    assert_eq!(git(&f.work, &["status", "--porcelain"]), "");
}

#[test]
fn update_without_upstream_reports_branch_name() {
    let f = Fixture::new();
    git(&f.work, &["branch", "--unset-upstream", "offline"]);
    assert_eq!(f.update("offline").unwrap_err(), "offline 没有上游分支");
    assert_eq!(git(&f.work, &["rev-parse", "HEAD"]), f.before);
}

#[test]
fn update_current_branch_from_linked_worktree_updates_its_files() {
    let f = Fixture::new();
    f.other_branch();
    let linked = f.root.join("linked");
    git(
        &f.work,
        &["worktree", "add", linked.to_str().unwrap(), "other"],
    );
    cgit_core::update_branch(linked.to_str().unwrap(), "other").unwrap();
    assert_eq!(git(&linked, &["rev-parse", "HEAD"]), f.after);
    assert_eq!(git(&linked, &["status", "--porcelain"]), "");
    assert_eq!(git(&f.work, &["rev-parse", "HEAD"]), f.before);
}

#[test]
fn update_unchecked_branch_from_detached_head_keeps_head_detached() {
    let f = Fixture::new();
    git(&f.work, &["checkout", "--detach"]);
    f.update("offline").unwrap();
    assert_eq!(git(&f.work, &["rev-parse", "refs/heads/offline"]), f.after);
    assert_eq!(git(&f.work, &["rev-parse", "HEAD"]), f.before);
    assert_eq!(git(&f.work, &["rev-parse", "--abbrev-ref", "HEAD"]), "HEAD");
    assert_eq!(git(&f.work, &["status", "--porcelain"]), "");
}
