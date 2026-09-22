//! The two calls that report progress while they run.
//!
//! The Tauri frontend turns core's callbacks into webview events
//! (`repo-changed`, `clone-progress`); here they become Dart streams. That is
//! the whole difference between the two frontends at this seam — core takes a
//! plain `Fn(&str)` and neither mechanism leaks into it.

use std::sync::OnceLock;

use crate::frb_generated::StreamSink;

/// The live file-system watcher. It has to outlive the call that starts it, and
/// unlike Tauri there is no `manage()` to hold it, so it lives here. Opening
/// another repo replaces the watcher, which drops the previous one.
fn watch_state() -> &'static cgit_core::WatchState {
    static WATCH: OnceLock<cgit_core::WatchState> = OnceLock::new();
    WATCH.get_or_init(cgit_core::WatchState::new)
}

/// Open a workspace. Unlike the Tauri command this does not start watching —
/// core keeps the two apart, and Dart calls [`watch_repo`] with the resolved
/// root when it wants change notifications.
pub fn open_workspace(path: String) -> Result<cgit_core::Workspace, String> {
    cgit_core::open_workspace(path)
}

/// Watch `path` and push "refs" or "worktree" into the stream on every
/// debounced burst. "refs" means HEAD or a ref moved, so branch labels and the
/// graph are stale too; "worktree" means only file contents changed.
///
/// The sink is moved into core's callback and lives as long as the watcher.
pub fn watch_repo(path: String, sink: StreamSink<String>) -> Result<(), String> {
    cgit_core::start_watching(watch_state(), &path, move |kind| {
        // A closed stream (the Dart side stopped listening) is not an error
        // worth surfacing — the next open_repo replaces this watcher anyway.
        let _ = sink.add(kind.to_string());
    })
}

/// Clone into `dir`, streaming git's progress lines, and return the path of the
/// created working copy.
pub fn clone_repo(url: String, dir: String, sink: StreamSink<String>) -> Result<String, String> {
    cgit_core::clone_repo(url, dir, |text| {
        let _ = sink.add(text.to_string());
    })
}
