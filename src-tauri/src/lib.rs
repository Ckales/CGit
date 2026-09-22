// Tauri frontend for CGit.
//
// All Git logic lives in the `cgit-core` crate, which knows nothing about Tauri
// so the Flutter frontend can link the same code. What stays here is only what
// is Tauri's job: the command registry, the window, and turning core callbacks
// into webview events.
//
// Every command is `#[tauri::command(async)]` over a synchronous core call:
// core is sync on purpose, and each frontend decides how to get off the UI
// thread. A plain `#[tauri::command]` would run on the main thread and freeze
// the window on a slow git operation.

use tauri::Emitter;

/// Open a workspace and watch it, turning core's change callback into the
/// `repo-changed` event the webview listens for.
#[tauri::command(async)]
fn open_workspace(
    app: tauri::AppHandle,
    state: tauri::State<cgit_core::WatchState>,
    path: String,
) -> Result<cgit_core::Workspace, String> {
    let workspace = cgit_core::open_workspace(path)?;
    let emitter = app.clone();
    let _ = cgit_core::start_watching(state.inner(), &workspace.root, move |kind| {
        let _ = emitter.emit("repo-changed", kind);
    });
    Ok(workspace)
}

/// Clone, forwarding git's progress lines as `clone-progress` events.
#[tauri::command(async)]
fn clone_repo(app: tauri::AppHandle, url: String, dir: String) -> Result<String, String> {
    cgit_core::clone_repo(url, dir, |text| {
        let _ = app.emit("clone-progress", text.to_string());
    })
}

#[tauri::command(async)]
fn get_status(path: String) -> Result<Vec<cgit_core::FileStatus>, String> {
    cgit_core::get_status(path)
}

#[tauri::command(async)]
fn get_branches(path: String) -> Result<Vec<cgit_core::BranchInfo>, String> {
    cgit_core::get_branches(path)
}

#[tauri::command(async)]
fn checkout_branch(path: String, name: String) -> Result<(), String> {
    cgit_core::checkout_branch(path, name)
}

#[tauri::command(async)]
fn create_branch(
    path: String,
    name: String,
    checkout: bool,
    base: Option<String>,
) -> Result<(), String> {
    cgit_core::create_branch(path, name, checkout, base)
}

#[tauri::command(async)]
fn delete_branch(path: String, name: String) -> Result<(), String> {
    cgit_core::delete_branch(path, name)
}

#[tauri::command(async)]
fn rename_branch(path: String, name: String, new_name: String) -> Result<(), String> {
    cgit_core::rename_branch(path, name, new_name)
}

#[tauri::command(async)]
fn get_branch_tracking(path: String) -> Result<cgit_core::Tracking, String> {
    cgit_core::get_branch_tracking(path)
}

#[tauri::command(async)]
fn get_remote_branches(path: String) -> Result<Vec<String>, String> {
    cgit_core::get_remote_branches(path)
}

#[tauri::command(async)]
fn get_tags(path: String) -> Result<Vec<String>, String> {
    cgit_core::get_tags(path)
}

#[tauri::command(async)]
fn create_tag(
    path: String,
    name: String,
    message: String,
    oid: Option<String>,
) -> Result<String, String> {
    cgit_core::create_tag(path, name, message, oid)
}

#[tauri::command(async)]
fn delete_tag(path: String, name: String) -> Result<String, String> {
    cgit_core::delete_tag(path, name)
}

#[tauri::command(async)]
fn push_tag(path: String, name: String) -> Result<String, String> {
    cgit_core::push_tag(path, name)
}

#[tauri::command(async)]
fn get_remotes(path: String) -> Result<Vec<cgit_core::RemoteInfo>, String> {
    cgit_core::get_remotes(path)
}

#[tauri::command(async)]
fn add_remote(path: String, name: String, url: String) -> Result<String, String> {
    cgit_core::add_remote(path, name, url)
}

#[tauri::command(async)]
fn remove_remote(path: String, name: String) -> Result<String, String> {
    cgit_core::remove_remote(path, name)
}

#[tauri::command(async)]
fn delete_remote_branch(path: String, remote: String, branch: String) -> Result<String, String> {
    cgit_core::delete_remote_branch(path, remote, branch)
}

#[tauri::command(async)]
fn checkout_ref(path: String, ref_name: String) -> Result<String, String> {
    cgit_core::checkout_ref(path, ref_name)
}

#[tauri::command(async)]
fn get_commit_messages(path: String, limit: usize) -> Result<Vec<String>, String> {
    cgit_core::get_commit_messages(path, limit)
}

#[tauri::command(async)]
fn search_commits(
    path: String,
    query: String,
    author: String,
    limit: usize,
) -> Result<Vec<cgit_core::CommitInfo>, String> {
    cgit_core::search_commits(path, query, author, limit)
}

#[tauri::command(async)]
fn get_file_history(
    path: String,
    file: String,
    limit: usize,
) -> Result<Vec<cgit_core::CommitInfo>, String> {
    cgit_core::get_file_history(path, file, limit)
}

#[tauri::command(async)]
fn get_blame(path: String, file: String) -> Result<Vec<cgit_core::BlameLine>, String> {
    cgit_core::get_blame(path, file)
}

#[tauri::command(async)]
fn get_graph(path: String, limit: usize) -> Result<Vec<cgit_core::GraphCommit>, String> {
    cgit_core::get_graph(path, limit)
}

#[tauri::command(async)]
fn stage_file(path: String, file: String) -> Result<(), String> {
    cgit_core::stage_file(path, file)
}

#[tauri::command(async)]
fn unstage_file(path: String, file: String) -> Result<(), String> {
    cgit_core::unstage_file(path, file)
}

#[tauri::command(async)]
fn stage_all(path: String, files: Vec<String>) -> Result<String, String> {
    cgit_core::stage_all(path, files)
}

#[tauri::command(async)]
fn unstage_all(path: String, files: Vec<String>) -> Result<String, String> {
    cgit_core::unstage_all(path, files)
}

#[tauri::command(async)]
fn commit(
    path: String,
    message: String,
    amend: bool,
    author: Option<String>,
    signoff: bool,
) -> Result<String, String> {
    cgit_core::commit(path, message, amend, author, signoff)
}

#[tauri::command(async)]
fn get_head_message(path: String) -> Result<String, String> {
    cgit_core::get_head_message(path)
}

#[tauri::command(async)]
fn get_unstaged_diff(path: String, file: String) -> Result<String, String> {
    cgit_core::get_unstaged_diff(path, file)
}

#[tauri::command(async)]
fn get_staged_diff(path: String, file: String) -> Result<String, String> {
    cgit_core::get_staged_diff(path, file)
}

#[tauri::command(async)]
fn discard_changes(path: String, file: String) -> Result<(), String> {
    cgit_core::discard_changes(path, file)
}

#[tauri::command(async)]
fn get_commit_files(path: String, oid: String) -> Result<Vec<cgit_core::FileStatus>, String> {
    cgit_core::get_commit_files(path, oid)
}

#[tauri::command(async)]
fn get_push_files(path: String) -> Result<Vec<cgit_core::FileStatus>, String> {
    cgit_core::get_push_files(path)
}

#[tauri::command(async)]
fn get_commit_diff(path: String, oid: String, file: String) -> Result<String, String> {
    cgit_core::get_commit_diff(path, oid, file)
}

#[tauri::command(async)]
fn get_hunks(path: String, file: String, staged: bool) -> Result<cgit_core::Hunks, String> {
    cgit_core::get_hunks(path, file, staged)
}

#[tauri::command(async)]
fn apply_hunk(path: String, patch: String, reverse: bool) -> Result<(), String> {
    cgit_core::apply_hunk(path, patch, reverse)
}

#[tauri::command(async)]
fn stash_save(path: String, message: String) -> Result<String, String> {
    cgit_core::stash_save(path, message)
}

#[tauri::command(async)]
fn stash_list(path: String) -> Result<Vec<cgit_core::StashEntry>, String> {
    cgit_core::stash_list(path)
}

#[tauri::command(async)]
fn stash_pop(path: String, index: usize) -> Result<String, String> {
    cgit_core::stash_pop(path, index)
}

#[tauri::command(async)]
fn stash_drop(path: String, index: usize) -> Result<String, String> {
    cgit_core::stash_drop(path, index)
}

#[tauri::command(async)]
fn reset_to(path: String, oid: String, mode: String) -> Result<String, String> {
    cgit_core::reset_to(path, oid, mode)
}

#[tauri::command(async)]
fn revert_commit(path: String, oid: String) -> Result<String, String> {
    cgit_core::revert_commit(path, oid)
}

#[tauri::command(async)]
fn cherry_pick(path: String, oid: String) -> Result<String, String> {
    cgit_core::cherry_pick(path, oid)
}

#[tauri::command(async)]
fn merge_branch(path: String, name: String) -> Result<String, String> {
    cgit_core::merge_branch(path, name)
}

#[tauri::command(async)]
fn get_repo_state(path: String) -> Result<String, String> {
    cgit_core::get_repo_state(path)
}

#[tauri::command(async)]
fn op_action(path: String, op: String, action: String) -> Result<String, String> {
    cgit_core::op_action(path, op, action)
}

#[tauri::command(async)]
fn get_conflicts(path: String) -> Result<Vec<String>, String> {
    cgit_core::get_conflicts(path)
}

#[tauri::command(async)]
fn set_conflict_style(path: String, file: String, style: String) -> Result<String, String> {
    cgit_core::set_conflict_style(path, file, style)
}

#[tauri::command(async)]
fn resolve_conflict(path: String, file: String, side: String) -> Result<(), String> {
    cgit_core::resolve_conflict(path, file, side)
}

#[tauri::command(async)]
fn resolve_with_content(path: String, file: String, content: String) -> Result<(), String> {
    cgit_core::resolve_with_content(path, file, content)
}

#[tauri::command(async)]
fn read_worktree_file(path: String, file: String) -> Result<String, String> {
    cgit_core::read_worktree_file(path, file)
}

#[tauri::command(async)]
fn open_in_editor(path: String, file: String, editor: String) -> Result<(), String> {
    cgit_core::open_in_editor(path, file, editor)
}

#[tauri::command(async)]
fn open_project_with_file(
    project: String,
    path: String,
    file: String,
    editor: String,
) -> Result<(), String> {
    cgit_core::open_project_with_file(project, path, file, editor)
}

#[tauri::command(async)]
fn open_path(path: String, editor: String) -> Result<(), String> {
    cgit_core::open_path(path, editor)
}

#[tauri::command(async)]
fn list_editors() -> Vec<String> {
    cgit_core::list_editors()
}

#[tauri::command(async)]
fn editor_icon(name: String) -> Result<Vec<u8>, String> {
    cgit_core::editor_icon(name)
}

#[tauri::command(async)]
fn create_patch(path: String) -> Result<String, String> {
    cgit_core::create_patch(path)
}

#[tauri::command(async)]
fn create_commit_patch(path: String, oid: String) -> Result<String, String> {
    cgit_core::create_commit_patch(path, oid)
}

#[tauri::command(async)]
fn write_clipboard(text: String) -> Result<(), String> {
    cgit_core::write_clipboard(text)
}

#[tauri::command(async)]
fn save_patch(file: String, content: String) -> Result<(), String> {
    cgit_core::save_patch(file, content)
}

#[tauri::command(async)]
fn read_patch_file(file: String) -> Result<String, String> {
    cgit_core::read_patch_file(file)
}

#[tauri::command(async)]
fn apply_patch(path: String, patch: String) -> Result<(), String> {
    cgit_core::apply_patch(path, patch)
}

#[tauri::command(async)]
fn read_clipboard() -> Result<String, String> {
    cgit_core::read_clipboard()
}

#[tauri::command(async)]
fn get_rebase_todo(path: String, base: String) -> Result<Vec<cgit_core::TodoCommit>, String> {
    cgit_core::get_rebase_todo(path, base)
}

#[tauri::command(async)]
fn rebase_interactive(
    path: String,
    base: String,
    todo: String,
    messages: Vec<String>,
    autostash: bool,
) -> Result<String, String> {
    cgit_core::rebase_interactive(path, base, todo, messages, autostash)
}

#[tauri::command(async)]
fn get_git_credential(path: String) -> Result<cgit_core::GitCredentialInfo, String> {
    cgit_core::get_git_credential(path)
}

#[tauri::command(async)]
fn save_git_credential(
    path: String,
    username: String,
    token: String,
) -> Result<cgit_core::GitCredentialInfo, String> {
    cgit_core::save_git_credential(&path, &username, &token)
}

#[tauri::command(async)]
fn test_git_credential(path: String) -> Result<String, String> {
    cgit_core::test_git_credential(path)
}

#[tauri::command(async)]
fn get_identity(path: String) -> Result<cgit_core::Identity, String> {
    cgit_core::get_identity(path)
}

#[tauri::command(async)]
fn get_pull_rebase(path: String) -> Result<Option<bool>, String> {
    cgit_core::get_pull_rebase(path)
}

#[tauri::command(async)]
fn set_identity(path: String, name: String, email: String, global: bool) -> Result<(), String> {
    cgit_core::set_identity(path, name, email, global)
}

#[tauri::command(async)]
fn ai_chat(
    url: String,
    token: String,
    model: String,
    system: String,
    user: String,
) -> Result<String, String> {
    cgit_core::ai_chat(url, token, model, system, user)
}

#[tauri::command(async)]
fn git_fetch(path: String) -> Result<String, String> {
    cgit_core::git_fetch(path)
}

#[tauri::command(async)]
fn git_pull(path: String, strategy: Option<String>) -> Result<String, String> {
    cgit_core::git_pull(path, strategy)
}

#[tauri::command(async)]
fn git_push(path: String) -> Result<String, String> {
    cgit_core::git_push(path)
}

#[tauri::command(async)]
fn update_branch(path: String, name: String) -> Result<String, String> {
    cgit_core::update_branch(&path, &name)
}

#[tauri::command(async)]
fn push_branch(path: String, name: String) -> Result<String, String> {
    cgit_core::push_branch(&path, &name)
}

#[tauri::command(async)]
fn git_push_force(path: String) -> Result<String, String> {
    cgit_core::git_push_force(path)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .runtime(tauri_runtime_wry::Wry::default())
        .manage(cgit_core::WatchState::new())
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
            create_tag,
            delete_tag,
            push_tag,
            get_remotes,
            add_remote,
            remove_remote,
            delete_remote_branch,
            checkout_ref,
            get_commit_messages,
            search_commits,
            get_file_history,
            get_blame,
            clone_repo,
            get_graph,
            stage_file,
            unstage_file,
            stage_all,
            unstage_all,
            commit,
            get_head_message,
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
            get_repo_state,
            op_action,
            get_conflicts,
            set_conflict_style,
            resolve_conflict,
            resolve_with_content,
            read_worktree_file,
            open_in_editor,
            open_project_with_file,
            open_path,
            list_editors,
            editor_icon,
            create_patch,
            create_commit_patch,
            write_clipboard,
            save_patch,
            read_patch_file,
            apply_patch,
            read_clipboard,
            get_rebase_todo,
            rebase_interactive,
            get_git_credential,
            save_git_credential,
            test_git_credential,
            get_identity,
            get_pull_rebase,
            set_identity,
            ai_chat,
            git_fetch,
            git_pull,
            git_push,
            update_branch,
            push_branch,
            git_push_force
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
