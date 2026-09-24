//! The generated-from-core command surface.
//!
//! One thin `pub fn` per command, exactly as src-tauri/src/lib.rs does for the
//! webview. Keeping both frontends at the same thinness is what stops the two
//! from drifting: any behaviour change has to happen in cgit-core, where the
//! tests are.

use flutter_rust_bridge::frb;

// Imported by bare name because the generated code refers to the mirrored
// types as `crate::api::git::<Name>`.
pub use cgit_core::{
    BlameLine, BranchInfo, CommitInfo, CredentialTarget, FileStatus, GitCredentialInfo,
    GraphCommit, Hunks, Identity, RemoteInfo, RepoRef, StashEntry, TodoCommit, Tracking, Workspace,
};

/* ---------- types crossing the FFI seam ---------- */

#[frb(mirror(RepoRef))]
pub struct _RepoRef {
    pub path: String,
    pub name: String,
    pub branch: String,
}

#[frb(mirror(Workspace))]
pub struct _Workspace {
    pub root: String,
    pub repos: Vec<RepoRef>,
}

#[frb(mirror(FileStatus))]
pub struct _FileStatus {
    pub path: String,
    pub status: String,
    pub staged: bool,
}

#[frb(mirror(BranchInfo))]
pub struct _BranchInfo {
    pub name: String,
    pub is_current: bool,
}

#[frb(mirror(CommitInfo))]
pub struct _CommitInfo {
    pub id: String,
    pub summary: String,
    pub author: String,
    pub time: i64,
}

#[frb(mirror(Tracking))]
pub struct _Tracking {
    pub branch: Option<String>,
    pub upstream: Option<String>,
    pub ahead: usize,
    pub behind: usize,
}

#[frb(mirror(RemoteInfo))]
pub struct _RemoteInfo {
    pub name: String,
    pub url: String,
}

#[frb(mirror(BlameLine))]
pub struct _BlameLine {
    pub oid: String,
    pub author: String,
    pub summary: String,
    pub content: String,
}

#[frb(mirror(GraphCommit))]
pub struct _GraphCommit {
    pub id: String,
    pub summary: String,
    pub author: String,
    pub time: i64,
    pub parents: Vec<String>,
    pub refs: Vec<String>,
}

#[frb(mirror(Hunks))]
pub struct _Hunks {
    pub header: String,
    pub hunks: Vec<String>,
}

#[frb(mirror(StashEntry))]
pub struct _StashEntry {
    pub index: usize,
    pub message: String,
}

#[frb(mirror(TodoCommit))]
pub struct _TodoCommit {
    pub oid: String,
    pub summary: String,
}

#[frb(mirror(CredentialTarget))]
pub struct _CredentialTarget {
    pub remote: String,
    pub transport: String,
    pub host: String,
    pub repository: String,
    pub url: String,
}

#[frb(mirror(GitCredentialInfo))]
pub struct _GitCredentialInfo {
    pub remote: String,
    pub transport: String,
    pub host: String,
    pub repository: String,
    pub username: String,
    pub helper: String,
    pub has_credential: bool,
}

#[frb(mirror(Identity))]
pub struct _Identity {
    pub name: String,
    pub email: String,
}

/* ---------- commands ---------- */

pub fn get_status(path: String) -> Result<Vec<cgit_core::FileStatus>, String> {
    cgit_core::get_status(path)
}

pub fn get_branches(path: String) -> Result<Vec<cgit_core::BranchInfo>, String> {
    cgit_core::get_branches(path)
}

pub fn checkout_branch(path: String, name: String) -> Result<(), String> {
    cgit_core::checkout_branch(path, name)
}

pub fn create_branch(
    path: String,
    name: String,
    checkout: bool,
    base: Option<String>,
) -> Result<(), String> {
    cgit_core::create_branch(path, name, checkout, base)
}

pub fn delete_branch(path: String, name: String) -> Result<(), String> {
    cgit_core::delete_branch(path, name)
}

pub fn rename_branch(path: String, name: String, new_name: String) -> Result<(), String> {
    cgit_core::rename_branch(path, name, new_name)
}

pub fn get_branch_tracking(path: String) -> Result<cgit_core::Tracking, String> {
    cgit_core::get_branch_tracking(path)
}

pub fn get_remote_branches(path: String) -> Result<Vec<String>, String> {
    cgit_core::get_remote_branches(path)
}

pub fn get_tags(path: String) -> Result<Vec<String>, String> {
    cgit_core::get_tags(path)
}

pub fn create_tag(
    path: String,
    name: String,
    message: String,
    oid: Option<String>,
) -> Result<String, String> {
    cgit_core::create_tag(path, name, message, oid)
}

pub fn delete_tag(path: String, name: String) -> Result<String, String> {
    cgit_core::delete_tag(path, name)
}

pub fn push_tag(path: String, name: String) -> Result<String, String> {
    cgit_core::push_tag(path, name)
}

pub fn get_remotes(path: String) -> Result<Vec<cgit_core::RemoteInfo>, String> {
    cgit_core::get_remotes(path)
}

pub fn add_remote(path: String, name: String, url: String) -> Result<String, String> {
    cgit_core::add_remote(path, name, url)
}

pub fn remove_remote(path: String, name: String) -> Result<String, String> {
    cgit_core::remove_remote(path, name)
}

pub fn delete_remote_branch(
    path: String,
    remote: String,
    branch: String,
) -> Result<String, String> {
    cgit_core::delete_remote_branch(path, remote, branch)
}

pub fn checkout_ref(path: String, ref_name: String) -> Result<String, String> {
    cgit_core::checkout_ref(path, ref_name)
}

pub fn get_commit_messages(path: String, limit: usize) -> Result<Vec<String>, String> {
    cgit_core::get_commit_messages(path, limit)
}

pub fn search_commits(
    path: String,
    query: String,
    author: String,
    limit: usize,
) -> Result<Vec<cgit_core::CommitInfo>, String> {
    cgit_core::search_commits(path, query, author, limit)
}

pub fn get_file_history(
    path: String,
    file: String,
    limit: usize,
) -> Result<Vec<cgit_core::CommitInfo>, String> {
    cgit_core::get_file_history(path, file, limit)
}

pub fn get_blame(path: String, file: String) -> Result<Vec<cgit_core::BlameLine>, String> {
    cgit_core::get_blame(path, file)
}

pub fn get_graph(path: String, limit: usize) -> Result<Vec<cgit_core::GraphCommit>, String> {
    cgit_core::get_graph(path, limit)
}

pub fn stage_file(path: String, file: String) -> Result<(), String> {
    cgit_core::stage_file(path, file)
}

pub fn unstage_file(path: String, file: String) -> Result<(), String> {
    cgit_core::unstage_file(path, file)
}

pub fn stage_all(path: String, files: Vec<String>) -> Result<String, String> {
    cgit_core::stage_all(path, files)
}

pub fn unstage_all(path: String, files: Vec<String>) -> Result<String, String> {
    cgit_core::unstage_all(path, files)
}

pub fn commit(
    path: String,
    message: String,
    amend: bool,
    author: Option<String>,
    signoff: bool,
) -> Result<String, String> {
    cgit_core::commit(path, message, amend, author, signoff)
}

pub fn get_head_message(path: String) -> Result<String, String> {
    cgit_core::get_head_message(path)
}

pub fn get_unstaged_diff(path: String, file: String) -> Result<String, String> {
    cgit_core::get_unstaged_diff(path, file)
}

pub fn get_staged_diff(path: String, file: String) -> Result<String, String> {
    cgit_core::get_staged_diff(path, file)
}

pub fn discard_changes(path: String, file: String) -> Result<(), String> {
    cgit_core::discard_changes(path, file)
}

pub fn get_commit_files(path: String, oid: String) -> Result<Vec<cgit_core::FileStatus>, String> {
    cgit_core::get_commit_files(path, oid)
}

pub fn get_push_files(path: String) -> Result<Vec<cgit_core::FileStatus>, String> {
    cgit_core::get_push_files(path)
}

pub fn get_commit_diff(path: String, oid: String, file: String) -> Result<String, String> {
    cgit_core::get_commit_diff(path, oid, file)
}

pub fn get_hunks(path: String, file: String, staged: bool) -> Result<cgit_core::Hunks, String> {
    cgit_core::get_hunks(path, file, staged)
}

pub fn apply_hunk(path: String, patch: String, reverse: bool) -> Result<(), String> {
    cgit_core::apply_hunk(path, patch, reverse)
}

pub fn stash_save(path: String, message: String) -> Result<String, String> {
    cgit_core::stash_save(path, message)
}

pub fn stash_staged(path: String, message: String) -> Result<String, String> {
    cgit_core::stash_staged(path, message)
}

pub fn stash_list(path: String) -> Result<Vec<cgit_core::StashEntry>, String> {
    cgit_core::stash_list(path)
}

pub fn stash_pop(path: String, index: usize) -> Result<String, String> {
    cgit_core::stash_pop(path, index)
}

pub fn stash_drop(path: String, index: usize) -> Result<String, String> {
    cgit_core::stash_drop(path, index)
}

pub fn reset_to(path: String, oid: String, mode: String) -> Result<String, String> {
    cgit_core::reset_to(path, oid, mode)
}

pub fn revert_commit(path: String, oid: String) -> Result<String, String> {
    cgit_core::revert_commit(path, oid)
}

pub fn cherry_pick(path: String, oid: String) -> Result<String, String> {
    cgit_core::cherry_pick(path, oid)
}

pub fn merge_branch(path: String, name: String) -> Result<String, String> {
    cgit_core::merge_branch(path, name)
}

pub fn get_repo_state(path: String) -> Result<String, String> {
    cgit_core::get_repo_state(path)
}

pub fn op_action(path: String, op: String, action: String) -> Result<String, String> {
    cgit_core::op_action(path, op, action)
}

pub fn get_conflicts(path: String) -> Result<Vec<String>, String> {
    cgit_core::get_conflicts(path)
}

pub fn set_conflict_style(path: String, file: String, style: String) -> Result<String, String> {
    cgit_core::set_conflict_style(path, file, style)
}

pub fn resolve_conflict(path: String, file: String, side: String) -> Result<(), String> {
    cgit_core::resolve_conflict(path, file, side)
}

pub fn resolve_with_content(path: String, file: String, content: String) -> Result<(), String> {
    cgit_core::resolve_with_content(path, file, content)
}

pub fn read_worktree_file(path: String, file: String) -> Result<String, String> {
    cgit_core::read_worktree_file(path, file)
}

pub fn open_in_editor(path: String, file: String, editor: String) -> Result<(), String> {
    cgit_core::open_in_editor(path, file, editor)
}

pub fn open_project_with_file(
    project: String,
    path: String,
    file: String,
    editor: String,
) -> Result<(), String> {
    cgit_core::open_project_with_file(project, path, file, editor)
}

pub fn open_path(path: String, editor: String) -> Result<(), String> {
    cgit_core::open_path(path, editor)
}

pub fn list_editors() -> Vec<String> {
    cgit_core::list_editors()
}

pub fn editor_icon(name: String) -> Result<Vec<u8>, String> {
    cgit_core::editor_icon(name)
}

pub fn create_patch(path: String) -> Result<String, String> {
    cgit_core::create_patch(path)
}

pub fn create_commit_patch(path: String, oid: String) -> Result<String, String> {
    cgit_core::create_commit_patch(path, oid)
}

pub fn write_clipboard(text: String) -> Result<(), String> {
    cgit_core::write_clipboard(text)
}

pub fn save_patch(file: String, content: String) -> Result<(), String> {
    cgit_core::save_patch(file, content)
}

pub fn read_patch_file(file: String) -> Result<String, String> {
    cgit_core::read_patch_file(file)
}

pub fn apply_patch(path: String, patch: String) -> Result<(), String> {
    cgit_core::apply_patch(path, patch)
}

pub fn read_clipboard() -> Result<String, String> {
    cgit_core::read_clipboard()
}

pub fn get_rebase_todo(path: String, base: String) -> Result<Vec<cgit_core::TodoCommit>, String> {
    cgit_core::get_rebase_todo(path, base)
}

pub fn rebase_interactive(
    path: String,
    base: String,
    todo: String,
    messages: Vec<String>,
    autostash: bool,
) -> Result<String, String> {
    cgit_core::rebase_interactive(path, base, todo, messages, autostash)
}

pub fn get_git_credential(path: String) -> Result<cgit_core::GitCredentialInfo, String> {
    cgit_core::get_git_credential(path)
}

pub fn save_git_credential(
    path: String,
    username: String,
    token: String,
) -> Result<cgit_core::GitCredentialInfo, String> {
    cgit_core::save_git_credential(&path, &username, &token)
}

pub fn test_git_credential(path: String) -> Result<String, String> {
    cgit_core::test_git_credential(path)
}

pub fn get_identity(path: String) -> Result<cgit_core::Identity, String> {
    cgit_core::get_identity(path)
}

pub fn get_pull_rebase(path: String) -> Result<Option<bool>, String> {
    cgit_core::get_pull_rebase(path)
}

pub fn set_identity(path: String, name: String, email: String, global: bool) -> Result<(), String> {
    cgit_core::set_identity(path, name, email, global)
}

pub fn ai_chat(
    url: String,
    token: String,
    model: String,
    system: String,
    user: String,
) -> Result<String, String> {
    cgit_core::ai_chat(url, token, model, system, user)
}

pub fn git_fetch(path: String) -> Result<String, String> {
    cgit_core::git_fetch(path)
}

pub fn git_pull(path: String, strategy: Option<String>) -> Result<String, String> {
    cgit_core::git_pull(path, strategy)
}

pub fn git_push(path: String) -> Result<String, String> {
    cgit_core::git_push(path)
}

pub fn update_branch(path: String, name: String) -> Result<String, String> {
    cgit_core::update_branch(&path, &name)
}

pub fn push_branch(path: String, name: String) -> Result<String, String> {
    cgit_core::push_branch(&path, &name)
}

pub fn git_push_force(path: String) -> Result<String, String> {
    cgit_core::git_push_force(path)
}
