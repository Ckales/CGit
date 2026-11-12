//! Safe, previewable patch import using an isolated temporary index.
//!
//! This module intentionally does not stage changes in the user's real index.

use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

static PATCH_IMPORT_SESSIONS: OnceLock<Mutex<HashMap<String, PatchImportSession>>> =
    OnceLock::new();
static PATCH_IMPORT_SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct PatchImportSession {
    root: PathBuf,
    git_dir: PathBuf,
    common_dir: PathBuf,
    real_index: PathBuf,
    real_objects: PathBuf,
    _temp_dir: TempDir,
    temp_worktree: PathBuf,
    temp_index: PathBuf,
    temp_objects: PathBuf,
    temp_lfs: PathBuf,
    index_snapshot: Option<Vec<u8>>,
    head_snapshot: Option<String>,
    worktree_snapshots: Vec<(PathBuf, FsSnapshot)>,
    touched_paths: Vec<PathBuf>,
    binary_paths: HashSet<PathBuf>,
    conflict_paths: Vec<PathBuf>,
}

struct TempDir(PathBuf);

impl TempDir {
    fn create() -> Result<Self, String> {
        let base = std::env::temp_dir();
        for _ in 0..16 {
            let sequence = PATCH_IMPORT_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|e| format!("读取系统时间失败：{e}"))?
                .as_nanos();
            let path = base.join(format!(
                "cgit-patch-import-{}-{nanos:x}-{sequence:x}",
                std::process::id()
            ));
            match std::fs::create_dir(&path) {
                Ok(()) => {
                    set_private_dir_permissions(&path)?;
                    return Ok(Self(path));
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(format!("创建补丁临时目录失败：{error}")),
            }
        }
        Err("无法分配唯一的补丁临时目录".to_string())
    }

    fn path(&self) -> &Path {
        &self.0
    }

    fn cleanup(&self) -> Result<(), String> {
        match std::fs::remove_dir_all(&self.0) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!("清理补丁临时目录失败：{error}")),
        }
    }
}

struct FinishBackup {
    temp_dir: TempDir,
    index_bytes: Vec<u8>,
    paths: Vec<PathBuf>,
    existing_paths: HashMap<PathBuf, bool>,
}

impl Drop for TempDir {
    fn drop(&mut self) {
        if !self.0.as_os_str().is_empty() {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

#[cfg(unix)]
fn set_private_dir_permissions(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("限制补丁临时目录权限失败：{e}"))
}

#[cfg(not(unix))]
fn set_private_dir_permissions(_path: &Path) -> Result<(), String> {
    Ok(())
}

#[derive(Clone)]
struct SessionGitEnv {
    git_dir: PathBuf,
    common_dir: PathBuf,
    worktree: PathBuf,
    index: PathBuf,
    objects: PathBuf,
    alternate_objects: PathBuf,
    lfs_storage: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum FsSnapshot {
    Missing,
    Directory(u64, u64),
    File {
        oid: String,
        mode: u32,
        identity: (u64, u64),
    },
    Symlink(PathBuf, (u64, u64)),
}

fn sessions() -> &'static Mutex<HashMap<String, PatchImportSession>> {
    PATCH_IMPORT_SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Prepare a patch in a temporary worktree and index, returning a preview and session token.
pub fn prepare_patch_import(path: String, patch: String) -> Result<String, String> {
    let root = repo_worktree_root(&path)?;
    let git_dir = PathBuf::from(git_path_output(
        &root,
        &["rev-parse", "--absolute-git-dir"],
    )?);
    let common_dir = resolve_git_path(
        &root,
        &git_path_output(&root, &["rev-parse", "--git-common-dir"])?,
    );
    let real_index = resolve_git_path(
        &root,
        &git_path_output(&root, &["rev-parse", "--git-path", "index"])?,
    );
    let real_objects = resolve_git_path(
        &root,
        &git_path_output(&root, &["rev-parse", "--git-path", "objects"])?,
    );

    let numstat = run_git_input(&root, &["apply", "--numstat", "-z"], None, patch.as_bytes())?;
    ensure_git_success(&numstat, "解析补丁失败")?;
    let (touched_paths, binary_paths) = parse_numstat_paths(&numstat.stdout)?;
    if touched_paths.is_empty() {
        return Err("补丁中没有可应用的文件".to_string());
    }
    for relative in &touched_paths {
        validate_worktree_path(&root, relative)?;
    }

    let index_snapshot = read_optional_file(&real_index)?;
    let head_snapshot = git_head(&root)?;
    let worktree_snapshots = snapshot_paths(&root, &touched_paths)?;

    let temp_dir = TempDir::create()?;
    let temp_worktree = temp_dir.path().join("worktree");
    let temp_index = temp_dir.path().join("index");
    let temp_objects = temp_dir.path().join("objects");
    let temp_lfs = temp_dir.path().join("lfs");
    std::fs::create_dir(&temp_worktree).map_err(|e| format!("创建补丁工作区失败：{e}"))?;
    std::fs::create_dir(&temp_objects).map_err(|e| format!("创建补丁对象目录失败：{e}"))?;
    std::fs::create_dir(&temp_lfs).map_err(|e| format!("创建补丁 LFS 目录失败：{e}"))?;

    let mut session = PatchImportSession {
        root: root.clone(),
        git_dir,
        common_dir,
        real_index,
        real_objects,
        _temp_dir: temp_dir,
        temp_worktree,
        temp_index,
        temp_objects,
        temp_lfs,
        index_snapshot,
        head_snapshot,
        worktree_snapshots,
        touched_paths,
        binary_paths,
        conflict_paths: Vec::new(),
    };

    let env = session.env(session.temp_worktree.clone());
    if let Some(index) = &session.index_snapshot {
        std::fs::write(&session.temp_index, index).map_err(|e| format!("复制临时索引失败：{e}"))?;
    } else {
        let output = run_git(&session.root, &["read-tree", "--empty"], Some(&env))?;
        ensure_git_success(&output, "初始化临时索引失败")?;
    }

    for relative in &session.touched_paths {
        copy_attribute_files(&session.root, &session.temp_worktree, relative)?;
        copy_worktree_entry(&session.root, &session.temp_worktree, relative)?;
    }
    let add_args = git_add_args(&session.touched_paths);
    let output = run_git_strings(&session.root, &add_args, Some(&env))?;
    ensure_git_success(&output, "准备补丁工作区失败")?;

    let apply = run_git_input(
        &session.root,
        &["apply", "--3way", "--index", "--binary"],
        Some(&env),
        patch.as_bytes(),
    )?;
    let stages = unmerged_stages(&session, &env)?;
    if !apply.status.success() && stages.is_empty() {
        return Err(git_failure("应用补丁预览失败", &apply));
    }

    session.conflict_paths = stages.keys().cloned().collect();
    let previews = preview_files(&session, &env, &stages)?;
    let token = new_session_token();
    let response = json!({
        "token": token,
        "files": previews,
    });
    let serialized =
        serde_json::to_string(&response).map_err(|e| format!("序列化补丁预览失败：{e}"))?;

    let mut active = sessions()
        .lock()
        .map_err(|_| "补丁会话锁不可用".to_string())?;
    active.insert(token, session);
    Ok(serialized)
}

/// Apply the prepared result to the worktree after verifying that its targets did not change.
pub fn finish_patch_import(path: String, token: String, resolutions: String) -> Result<(), String> {
    let root = repo_worktree_root(&path)?;
    let mut active = sessions()
        .lock()
        .map_err(|_| "补丁会话锁不可用".to_string())?;
    let result = {
        let session = active
            .get(&token)
            .ok_or_else(|| "补丁预览会话不存在或已过期".to_string())?;
        if session.root != root {
            return Err("补丁预览属于另一个仓库".to_string());
        }
        let backup = backup_finish_state(session)?;
        match finish_session(session, &resolutions) {
            Ok(()) => Ok(()),
            Err(error) => match restore_finish_state(session, &backup) {
                Ok(()) => Err(error),
                Err(restore_error) => {
                    Err(format!("{error}；恢复补丁预览状态失败：{restore_error}"))
                }
            },
        }
    };
    if result.is_ok() {
        active.remove(&token);
    }
    result
}

/// Discard a preview session and remove its isolated worktree, index, and objects.
pub fn discard_patch_import(token: String) -> Result<(), String> {
    let mut active = sessions()
        .lock()
        .map_err(|_| "补丁会话锁不可用".to_string())?;
    let session = active
        .get(&token)
        .ok_or_else(|| "补丁预览会话不存在或已过期".to_string())?;
    session._temp_dir.cleanup()?;
    active.remove(&token);
    Ok(())
}

fn finish_session(session: &PatchImportSession, resolutions_json: &str) -> Result<(), String> {
    verify_snapshot(session)?;
    let resolutions: Value = serde_json::from_str(resolutions_json)
        .map_err(|e| format!("冲突解决数据不是有效 JSON：{e}"))?;
    let resolutions = resolutions
        .as_object()
        .ok_or_else(|| "冲突解决数据必须是对象".to_string())?;
    let env = session.env(session.temp_worktree.clone());
    let stages = unmerged_stages(session, &env)?;
    let conflict_keys: HashSet<String> = stages
        .keys()
        .map(|path| path.to_string_lossy().into_owned())
        .collect();
    for key in resolutions.keys() {
        if !conflict_keys.contains(key) {
            return Err(format!("补丁冲突路径不匹配：{key}"));
        }
    }

    for (relative, path_stages) in &stages {
        let key = relative
            .to_str()
            .ok_or_else(|| "补丁路径不是有效 UTF-8".to_string())?;
        let resolution = resolutions
            .get(key)
            .and_then(Value::as_object)
            .ok_or_else(|| format!("冲突「{key}」尚未解决"))?;
        apply_resolution(session, &env, relative, path_stages, resolution)?;
    }

    if !unmerged_stages(session, &env)?.is_empty() {
        return Err("仍有未解决的补丁冲突".to_string());
    }
    apply_result_to_worktree(session)
}

fn apply_resolution(
    session: &PatchImportSession,
    env: &SessionGitEnv,
    relative: &Path,
    stages: &HashMap<u8, String>,
    resolution: &serde_json::Map<String, Value>,
) -> Result<(), String> {
    validate_worktree_path(&session.root, relative)?;
    let content = resolution.get("content").and_then(Value::as_str);
    let side = resolution.get("side").and_then(Value::as_str);
    if content.is_some() == side.is_some() {
        return Err(format!(
            "冲突「{}」必须恰好提供 content 或 side",
            relative.display()
        ));
    }

    if let Some(content) = content {
        if session.binary_paths.contains(relative) {
            return Err(format!(
                "二进制冲突「{}」只能选择文件版本",
                relative.display()
            ));
        }
        let target = session.temp_worktree.join(relative);
        write_text_resolution(&target, content)?;
        let args = git_add_args(std::slice::from_ref(&relative.to_path_buf()));
        let output = run_git_strings(&session.root, &args, Some(env))?;
        return ensure_git_success(&output, "保存冲突解决结果失败");
    }

    let side = side.unwrap();
    let stage = match side {
        "ours" => 2,
        "theirs" => 3,
        _ => return Err(format!("冲突「{}」的 side 值无效", relative.display())),
    };
    if stages.contains_key(&stage) {
        let path = relative
            .to_str()
            .ok_or_else(|| "补丁路径不是有效 UTF-8".to_string())?;
        let pathspec = format!(":(literal){path}");
        let args = [
            "checkout",
            if stage == 2 { "--ours" } else { "--theirs" },
            "--",
            &pathspec,
        ];
        let output = run_git(&session.root, &args, Some(env))?;
        ensure_git_success(&output, "恢复冲突文件版本失败")?;
    } else {
        remove_file_if_present(&session.temp_worktree.join(relative))?;
    }
    let args = git_add_args(std::slice::from_ref(&relative.to_path_buf()));
    let output = run_git_strings(&session.root, &args, Some(env))?;
    ensure_git_success(&output, "记录冲突文件版本失败")
}

fn apply_result_to_worktree(session: &PatchImportSession) -> Result<(), String> {
    verify_snapshot(session)?;
    let env = session.env(session.root.clone());
    let index_paths = stage_zero_paths(session, &session.env(session.temp_worktree.clone()))?;
    let touched: HashSet<PathBuf> = session.touched_paths.iter().cloned().collect();
    let mut checkout_paths: Vec<PathBuf> = index_paths.intersection(&touched).cloned().collect();
    let mut delete_paths: Vec<PathBuf> = touched.difference(&index_paths).cloned().collect();
    checkout_paths.sort();
    delete_paths.sort();

    let backup_dir = TempDir::create()?;
    let backup_root = backup_dir.path();
    let mut backup_exists = HashMap::new();
    for relative in &session.touched_paths {
        let source = session.root.join(relative);
        let backup = backup_root.join(relative);
        let exists = copy_entry_for_rollback(&source, &backup)?;
        backup_exists.insert(relative.clone(), exists);
    }
    verify_snapshot(session)?;

    for relative in &delete_paths {
        if let Err(error) = remove_file_if_present(&session.root.join(relative)) {
            return match rollback_worktree(session, backup_root, &backup_exists) {
                Ok(()) => Err(format!("删除补丁目标失败：{error}")),
                Err(rollback_error) => Err(format!(
                    "删除补丁目标失败：{error}；回滚工作区失败：{rollback_error}"
                )),
            };
        }
    }

    if !checkout_paths.is_empty() {
        let mut path_input = Vec::new();
        for relative in &checkout_paths {
            let path = relative
                .to_str()
                .ok_or_else(|| "补丁路径不是有效 UTF-8".to_string())?;
            path_input.extend_from_slice(path.as_bytes());
            path_input.push(0);
        }
        let output = run_git_input(
            &session.root,
            &["checkout-index", "--force", "--stdin", "-z"],
            Some(&env),
            &path_input,
        );
        match output {
            Ok(output) if output.status.success() => {}
            Ok(output) => {
                let error = git_failure("写入补丁文件失败", &output);
                return match rollback_worktree(session, backup_root, &backup_exists) {
                    Ok(()) => Err(error),
                    Err(rollback_error) => {
                        Err(format!("{error}；回滚工作区失败：{rollback_error}"))
                    }
                };
            }
            Err(error) => {
                return match rollback_worktree(session, backup_root, &backup_exists) {
                    Ok(()) => Err(error),
                    Err(rollback_error) => {
                        Err(format!("{error}；回滚工作区失败：{rollback_error}"))
                    }
                };
            }
        }
    }
    Ok(())
}

fn rollback_worktree(
    session: &PatchImportSession,
    backup_root: &Path,
    backup_exists: &HashMap<PathBuf, bool>,
) -> Result<(), String> {
    let mut errors = Vec::new();
    for relative in &session.touched_paths {
        let target = session.root.join(relative);
        if let Err(error) = remove_file_if_present(&target) {
            errors.push(error);
            continue;
        }
        if backup_exists.get(relative).copied().unwrap_or(false) {
            if let Err(error) = copy_worktree_entry(backup_root, &session.root, relative) {
                errors.push(error);
            }
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("；"))
    }
}

fn backup_finish_state(session: &PatchImportSession) -> Result<FinishBackup, String> {
    let index_bytes =
        std::fs::read(&session.temp_index).map_err(|e| format!("备份补丁临时索引失败：{e}"))?;
    let temp_dir = TempDir::create()?;
    let mut paths = session.touched_paths.clone();
    for path in &session.conflict_paths {
        if !paths.contains(path) {
            paths.push(path.clone());
        }
    }
    paths.sort();
    let mut existing_paths = HashMap::new();
    for relative in &paths {
        let source = session.temp_worktree.join(relative);
        let backup = temp_dir.path().join(relative);
        let exists = copy_entry_for_rollback(&source, &backup)?;
        existing_paths.insert(relative.clone(), exists);
    }
    Ok(FinishBackup {
        temp_dir,
        index_bytes,
        paths,
        existing_paths,
    })
}

fn restore_finish_state(session: &PatchImportSession, backup: &FinishBackup) -> Result<(), String> {
    std::fs::write(&session.temp_index, &backup.index_bytes)
        .map_err(|e| format!("恢复补丁临时索引失败：{e}"))?;
    let mut errors = Vec::new();
    for relative in &backup.paths {
        let target = session.temp_worktree.join(relative);
        if let Err(error) = remove_file_if_present(&target) {
            errors.push(error);
            continue;
        }
        if backup
            .existing_paths
            .get(relative)
            .copied()
            .unwrap_or(false)
        {
            if let Err(error) =
                copy_worktree_entry(backup.temp_dir.path(), &session.temp_worktree, relative)
            {
                errors.push(error);
            }
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("；"))
    }
}

fn verify_snapshot(session: &PatchImportSession) -> Result<(), String> {
    if read_optional_file(&session.real_index)? != session.index_snapshot {
        return Err("真实索引在预览后发生变化，请重新预览补丁".to_string());
    }
    if git_head(&session.root)? != session.head_snapshot {
        return Err("当前分支在预览后发生变化，请重新预览补丁".to_string());
    }
    for (relative, expected) in &session.worktree_snapshots {
        let current = snapshot_path(&session.root, relative)?;
        if &current != expected {
            return Err(format!("预览后的目标路径发生变化：{}", relative.display()));
        }
    }
    Ok(())
}

fn preview_files(
    session: &PatchImportSession,
    env: &SessionGitEnv,
    stages: &HashMap<PathBuf, HashMap<u8, String>>,
) -> Result<Vec<Value>, String> {
    let mut paths: Vec<PathBuf> = session.touched_paths.clone();
    for path in stages.keys() {
        if !paths.contains(path) {
            paths.push(path.clone());
        }
    }
    paths.sort();
    paths.dedup();

    let index_paths = stage_zero_paths(session, env)?;
    let mut files = Vec::new();
    for relative in paths {
        let conflict_stages = stages.get(&relative);
        let conflict = conflict_stages.is_some();
        let target = session.temp_worktree.join(&relative);
        let content_bytes = read_worktree_entry(&target)?;
        let ours_bytes = if let Some(path_stages) = conflict_stages {
            stage_content(session, env, path_stages.get(&2))?
        } else {
            None
        };
        let theirs_bytes = if let Some(path_stages) = conflict_stages {
            stage_content(session, env, path_stages.get(&3))?
        } else {
            None
        };
        let base_bytes = if let Some(path_stages) = conflict_stages {
            stage_content(session, env, path_stages.get(&1))?
        } else {
            None
        };
        let binary = session.binary_paths.contains(&relative)
            || content_bytes.as_deref().is_some_and(is_binary)
            || ours_bytes.as_deref().is_some_and(is_binary)
            || theirs_bytes.as_deref().is_some_and(is_binary)
            || base_bytes.as_deref().is_some_and(is_binary);
        let content = if binary {
            String::new()
        } else {
            content_bytes
                .as_deref()
                .map(decode_text)
                .transpose()?
                .unwrap_or_default()
        };
        let ours = if binary {
            String::new()
        } else {
            ours_bytes
                .as_deref()
                .map(decode_text)
                .transpose()?
                .unwrap_or_default()
        };
        let theirs = if binary {
            String::new()
        } else {
            theirs_bytes
                .as_deref()
                .map(decode_text)
                .transpose()?
                .unwrap_or_default()
        };
        let base = if binary {
            None
        } else {
            base_bytes.as_deref().map(decode_text).transpose()?
        };
        files.push(json!({
            "path": relative.to_string_lossy(),
            "conflict": conflict,
            "content": content,
            "ours": ours,
            "theirs": theirs,
            "base": base,
            "binary": binary,
            "deleted": !index_paths.contains(&relative),
        }));
    }
    Ok(files)
}

fn stage_content(
    session: &PatchImportSession,
    env: &SessionGitEnv,
    oid: Option<&String>,
) -> Result<Option<Vec<u8>>, String> {
    let Some(oid) = oid else { return Ok(None) };
    let output = run_git(&session.root, &["cat-file", "blob", oid], Some(env))?;
    ensure_git_success(&output, "读取冲突版本失败")?;
    Ok(Some(output.stdout))
}

fn decode_text(bytes: &[u8]) -> Result<String, String> {
    String::from_utf8(bytes.to_vec()).map_err(|_| "补丁文本不是有效 UTF-8".to_string())
}

fn is_binary(bytes: &[u8]) -> bool {
    bytes.contains(&0) || std::str::from_utf8(bytes).is_err()
}

fn unmerged_stages(
    session: &PatchImportSession,
    env: &SessionGitEnv,
) -> Result<HashMap<PathBuf, HashMap<u8, String>>, String> {
    let output = run_git(&session.root, &["ls-files", "--unmerged", "-z"], Some(env))?;
    ensure_git_success(&output, "读取补丁冲突状态失败")?;
    parse_index_stages(&output.stdout)
}

fn stage_zero_paths(
    session: &PatchImportSession,
    env: &SessionGitEnv,
) -> Result<HashSet<PathBuf>, String> {
    let output = run_git(&session.root, &["ls-files", "--stage", "-z"], Some(env))?;
    ensure_git_success(&output, "读取补丁索引结果失败")?;
    let stages = parse_index_stages(&output.stdout)?;
    Ok(stages
        .into_iter()
        .filter_map(|(path, entries)| entries.contains_key(&0).then_some(path))
        .collect())
}

fn parse_index_stages(output: &[u8]) -> Result<HashMap<PathBuf, HashMap<u8, String>>, String> {
    let mut result: HashMap<PathBuf, HashMap<u8, String>> = HashMap::new();
    for record in output
        .split(|byte| *byte == 0)
        .filter(|record| !record.is_empty())
    {
        let tab = record
            .iter()
            .position(|byte| *byte == b'\t')
            .ok_or_else(|| "git ls-files 返回了无法识别的索引记录".to_string())?;
        let metadata = &record[..tab];
        let name = &record[tab + 1..];
        let fields: Vec<&[u8]> = metadata
            .split(|byte| byte.is_ascii_whitespace())
            .filter(|field| !field.is_empty())
            .collect();
        if fields.len() != 3 {
            return Err("git ls-files 返回了不完整的索引记录".to_string());
        }
        let oid = std::str::from_utf8(fields[1])
            .map_err(|_| "索引对象 ID 不是有效文本".to_string())?
            .to_string();
        let stage = std::str::from_utf8(fields[2])
            .map_err(|_| "索引阶段不是有效文本".to_string())?
            .parse::<u8>()
            .map_err(|_| "索引阶段值无效".to_string())?;
        let name = std::str::from_utf8(name).map_err(|_| "补丁路径不是有效 UTF-8".to_string())?;
        let relative = validate_relative_path(name)?;
        result.entry(relative).or_default().insert(stage, oid);
    }
    Ok(result)
}

fn parse_numstat_paths(output: &[u8]) -> Result<(Vec<PathBuf>, HashSet<PathBuf>), String> {
    let records: Vec<&[u8]> = output.split(|byte| *byte == 0).collect();
    let mut paths = Vec::new();
    let mut binary_paths = HashSet::new();
    let mut index = 0;
    while index < records.len() {
        let record = records[index];
        index += 1;
        if record.is_empty() {
            continue;
        }
        let mut fields = record.splitn(3, |byte| *byte == b'\t');
        let added = fields
            .next()
            .ok_or_else(|| "git apply 返回了不完整的 numstat 记录".to_string())?;
        let deleted = fields
            .next()
            .ok_or_else(|| "git apply 返回了不完整的 numstat 记录".to_string())?;
        let name = fields
            .next()
            .ok_or_else(|| "git apply 返回了无法识别的 numstat 记录".to_string())?;
        let binary = added == b"-" || deleted == b"-";
        if name.is_empty() {
            let old_name = records
                .get(index)
                .ok_or_else(|| "补丁重命名记录缺少旧路径".to_string())?;
            let new_name = records
                .get(index + 1)
                .ok_or_else(|| "补丁重命名记录缺少新路径".to_string())?;
            index += 2;
            let old_path = path_from_bytes(old_name)?;
            let new_path = path_from_bytes(new_name)?;
            if binary {
                binary_paths.insert(old_path.clone());
                binary_paths.insert(new_path.clone());
            }
            paths.push(old_path);
            paths.push(new_path);
        } else {
            let path = path_from_bytes(name)?;
            if binary {
                binary_paths.insert(path.clone());
            }
            paths.push(path);
        }
    }
    let mut unique = HashSet::new();
    paths.retain(|path| unique.insert(path.clone()));
    Ok((paths, binary_paths))
}

fn path_from_bytes(bytes: &[u8]) -> Result<PathBuf, String> {
    let value = std::str::from_utf8(bytes).map_err(|_| "补丁路径不是有效 UTF-8".to_string())?;
    validate_relative_path(value)
}

fn validate_relative_path(value: &str) -> Result<PathBuf, String> {
    if value.is_empty() || value.contains('\0') {
        return Err("补丁包含空路径或非法路径".to_string());
    }
    let path = PathBuf::from(value);
    if path.is_absolute() {
        return Err(format!("拒绝仓库外的补丁路径：{value}"));
    }
    for component in path.components() {
        match component {
            Component::Normal(name) if name.to_string_lossy().eq_ignore_ascii_case(".git") => {
                return Err("拒绝修改 Git 元数据路径".to_string());
            }
            Component::Normal(_) => {}
            _ => return Err(format!("补丁路径不安全：{value}")),
        }
    }
    Ok(path)
}

fn validate_worktree_path(root: &Path, relative: &Path) -> Result<(), String> {
    let value = relative
        .to_str()
        .ok_or_else(|| "补丁路径不是有效 UTF-8".to_string())?;
    validate_relative_path(value)?;
    let components: Vec<_> = relative.components().collect();
    let mut current = root.to_path_buf();
    for (index, component) in components.iter().enumerate() {
        let Component::Normal(name) = component else {
            return Err(format!("补丁路径不安全：{value}"));
        };
        current.push(name);
        let metadata = match std::fs::symlink_metadata(&current) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => break,
            Err(error) => return Err(format!("检查补丁路径失败：{error}")),
        };
        let final_component = index + 1 == components.len();
        if !final_component && (metadata.file_type().is_symlink() || !metadata.is_dir()) {
            return Err(format!("补丁路径的父目录不是安全目录：{value}"));
        }
        if final_component
            && (metadata.is_dir() || !metadata.is_file() && !metadata.file_type().is_symlink())
        {
            return Err(format!("补丁目标不是普通文件：{value}"));
        }
    }
    Ok(())
}

fn snapshot_paths(root: &Path, paths: &[PathBuf]) -> Result<Vec<(PathBuf, FsSnapshot)>, String> {
    let mut snapshots = HashMap::new();
    for path in paths {
        validate_worktree_path(root, path)?;
        let mut prefix = PathBuf::new();
        for component in path.components() {
            let Component::Normal(name) = component else {
                return Err(format!("补丁路径不安全：{}", path.display()));
            };
            prefix.push(name);
            snapshots.insert(prefix.clone(), snapshot_path(root, &prefix)?);
        }
    }
    let mut result: Vec<_> = snapshots.into_iter().collect();
    result.sort_by(|left, right| left.0.cmp(&right.0));
    Ok(result)
}

fn snapshot_path(root: &Path, relative: &Path) -> Result<FsSnapshot, String> {
    validate_worktree_path(root, relative)?;
    let full = root.join(relative);
    let metadata = match std::fs::symlink_metadata(&full) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(FsSnapshot::Missing)
        }
        Err(error) => return Err(format!("读取补丁目标状态失败：{error}")),
    };
    if metadata.file_type().is_symlink() {
        return std::fs::read_link(full)
            .map(|target| FsSnapshot::Symlink(target, file_identity(&metadata)))
            .map_err(|e| format!("读取补丁目标链接失败：{e}"));
    }
    if metadata.is_dir() {
        let (device, inode) = directory_identity(&metadata);
        return Ok(FsSnapshot::Directory(device, inode));
    }
    if !metadata.is_file() {
        return Err(format!("拒绝补丁目标上的特殊文件：{}", relative.display()));
    }
    let name = relative
        .to_str()
        .ok_or_else(|| "补丁路径不是有效 UTF-8".to_string())?;
    let output = run_repo_git(root, &["hash-object", "--no-filters", "--", name])?;
    ensure_git_success(&output, "计算补丁目标快照失败")?;
    let oid = output_text(&output.stdout);
    Ok(FsSnapshot::File {
        oid,
        mode: file_mode(&metadata),
        identity: file_identity(&metadata),
    })
}

#[cfg(unix)]
fn file_identity(metadata: &std::fs::Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (metadata.dev(), metadata.ino())
}

#[cfg(not(unix))]
fn file_identity(metadata: &std::fs::Metadata) -> (u64, u64) {
    use std::time::UNIX_EPOCH;
    let modified = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or_default();
    (metadata.len(), modified)
}

#[cfg(unix)]
fn directory_identity(metadata: &std::fs::Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (metadata.dev(), metadata.ino())
}

#[cfg(not(unix))]
fn directory_identity(metadata: &std::fs::Metadata) -> (u64, u64) {
    use std::time::UNIX_EPOCH;
    let modified = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or_default();
    (metadata.len(), modified)
}

#[cfg(unix)]
fn file_mode(metadata: &std::fs::Metadata) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    metadata.permissions().mode() & 0o7777
}

#[cfg(not(unix))]
fn file_mode(metadata: &std::fs::Metadata) -> u32 {
    u32::from(metadata.permissions().readonly())
}

fn copy_attribute_files(root: &Path, destination: &Path, relative: &Path) -> Result<(), String> {
    let mut parent = PathBuf::new();
    for component in relative.parent().into_iter().flat_map(Path::components) {
        let Component::Normal(name) = component else {
            continue;
        };
        parent.push(name);
        let attributes = parent.join(".gitattributes");
        copy_attribute_file(root, destination, &attributes)?;
    }
    copy_attribute_file(root, destination, Path::new(".gitattributes"))
}

fn copy_attribute_file(root: &Path, destination: &Path, relative: &Path) -> Result<(), String> {
    let source = root.join(relative);
    let metadata = match std::fs::symlink_metadata(&source) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("读取 Git 属性文件失败：{error}")),
    };
    if metadata.is_dir() {
        return Err(format!("Git 属性路径不是文件：{}", relative.display()));
    }
    let target = destination.join(relative);
    create_parent_dirs(&target)?;
    if metadata.file_type().is_symlink() {
        let contents = std::fs::read(&source).map_err(|e| format!("复制 Git 属性文件失败：{e}"))?;
        std::fs::write(target, contents).map_err(|e| format!("复制 Git 属性文件失败：{e}"))
    } else {
        std::fs::copy(source, target)
            .map(|_| ())
            .map_err(|e| format!("复制 Git 属性文件失败：{e}"))
    }
}

fn copy_worktree_entry(root: &Path, destination: &Path, relative: &Path) -> Result<(), String> {
    let source = root.join(relative);
    let target = destination.join(relative);
    let metadata = match std::fs::symlink_metadata(&source) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("读取补丁工作区文件失败：{error}")),
    };
    if metadata.is_dir() || !metadata.is_file() && !metadata.file_type().is_symlink() {
        return Err(format!("拒绝复制特殊补丁目标：{}", relative.display()));
    }
    create_parent_dirs(&target)?;
    if metadata.file_type().is_symlink() {
        create_symlink(
            &std::fs::read_link(&source).map_err(|e| e.to_string())?,
            &target,
        )?;
    } else {
        std::fs::copy(&source, &target).map_err(|e| format!("复制补丁工作区文件失败：{e}"))?;
        std::fs::set_permissions(&target, metadata.permissions())
            .map_err(|e| format!("复制补丁文件权限失败：{e}"))?;
    }
    Ok(())
}

#[cfg(unix)]
fn create_symlink(source: &Path, target: &Path) -> Result<(), String> {
    std::os::unix::fs::symlink(source, target).map_err(|e| format!("复制补丁符号链接失败：{e}"))
}

#[cfg(not(unix))]
fn create_symlink(_source: &Path, _target: &Path) -> Result<(), String> {
    Err("当前平台不支持安全复制补丁符号链接".to_string())
}

fn create_parent_dirs(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建补丁文件目录失败：{e}"))?;
    }
    Ok(())
}

fn copy_entry_for_rollback(source: &Path, target: &Path) -> Result<bool, String> {
    let metadata = match std::fs::symlink_metadata(source) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(format!("备份补丁目标失败：{error}")),
    };
    if metadata.is_dir() || !metadata.is_file() && !metadata.file_type().is_symlink() {
        return Err(format!("拒绝备份特殊补丁目标：{}", source.display()));
    }
    create_parent_dirs(target)?;
    if metadata.file_type().is_symlink() {
        create_symlink(
            &std::fs::read_link(source).map_err(|e| e.to_string())?,
            target,
        )?;
    } else {
        std::fs::copy(source, target).map_err(|e| format!("备份补丁目标失败：{e}"))?;
        std::fs::set_permissions(target, metadata.permissions())
            .map_err(|e| format!("备份补丁目标权限失败：{e}"))?;
    }
    Ok(true)
}

fn remove_file_if_present(path: &Path) -> Result<(), String> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => Err(format!("拒绝删除目录：{}", path.display())),
        Ok(_) => std::fs::remove_file(path).map_err(|e| format!("删除文件失败：{e}")),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("检查删除目标失败：{error}")),
    }
}

fn write_text_resolution(path: &Path, content: &str) -> Result<(), String> {
    if let Ok(metadata) = std::fs::symlink_metadata(path) {
        if metadata.file_type().is_symlink() || metadata.is_dir() || !metadata.is_file() {
            return Err(format!("不能用文本解决特殊文件冲突：{}", path.display()));
        }
    }
    create_parent_dirs(path)?;
    std::fs::write(path, content).map_err(|e| format!("写入冲突解决内容失败：{e}"))
}

fn read_worktree_entry(path: &Path) -> Result<Option<Vec<u8>>, String> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => std::fs::read_link(path)
            .map(|_| Some(vec![0]))
            .map_err(|e| format!("读取补丁预览符号链接失败：{e}")),
        Ok(metadata) if metadata.is_file() => std::fs::read(path)
            .map(Some)
            .map_err(|e| format!("读取补丁预览内容失败：{e}")),
        Ok(_) => Err(format!("补丁预览目标不是普通文件：{}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("读取补丁预览状态失败：{error}")),
    }
}

fn git_add_args(paths: &[PathBuf]) -> Vec<String> {
    let mut args = vec![
        "add".to_string(),
        "--force".to_string(),
        "-A".to_string(),
        "--".to_string(),
    ];
    args.extend(
        paths
            .iter()
            .filter_map(|path| path.to_str().map(|value| format!(":(literal){value}"))),
    );
    args
}

fn repo_worktree_root(path: &str) -> Result<PathBuf, String> {
    let repository = gix::open(path).map_err(|e| format!("打开 Git 仓库失败：{e}"))?;
    let worktree = repository
        .workdir()
        .ok_or_else(|| "仓库没有工作目录".to_string())?;
    std::fs::canonicalize(worktree).map_err(|e| format!("解析仓库工作目录失败：{e}"))
}

fn resolve_git_path(root: &Path, value: &str) -> PathBuf {
    let path = PathBuf::from(value);
    if path.is_absolute() {
        path
    } else {
        root.join(path)
    }
}

fn git_path_output(root: &Path, args: &[&str]) -> Result<String, String> {
    let output = run_repo_git(root, args)?;
    ensure_git_success(&output, "读取 Git 仓库路径失败")?;
    Ok(output_text(&output.stdout))
}

fn git_head(root: &Path) -> Result<Option<String>, String> {
    let output = run_repo_git(root, &["rev-parse", "--verify", "--quiet", "HEAD"])?;
    if output.status.success() {
        return Ok(Some(output_text(&output.stdout)));
    }
    if output.status.code() != Some(1) {
        return Err(git_failure("读取当前 HEAD 失败", &output));
    }

    let symbolic_head = run_repo_git(root, &["symbolic-ref", "--quiet", "HEAD"])?;
    ensure_git_success(&symbolic_head, "读取未提交仓库的 HEAD 引用失败")?;
    let reference = output_text(&symbolic_head.stdout);
    let reference_check = run_repo_git(root, &["show-ref", "--verify", "--quiet", &reference])?;
    if reference_check.status.success() {
        return Err(git_failure("HEAD 引用存在但无法解析", &output));
    }
    if reference_check.status.code() == Some(1) {
        return Ok(None);
    }
    Err(git_failure("验证 HEAD 引用失败", &reference_check))
}

fn read_optional_file(path: &Path) -> Result<Option<Vec<u8>>, String> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("读取 Git 索引失败：{error}")),
    }
}

impl PatchImportSession {
    fn env(&self, worktree: PathBuf) -> SessionGitEnv {
        SessionGitEnv {
            git_dir: self.git_dir.clone(),
            common_dir: self.common_dir.clone(),
            worktree,
            index: self.temp_index.clone(),
            objects: self.temp_objects.clone(),
            alternate_objects: self.real_objects.clone(),
            lfs_storage: self.temp_lfs.clone(),
        }
    }
}

fn run_repo_git(root: &Path, args: &[&str]) -> Result<Output, String> {
    let mut command = super::git_cmd();
    command
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env_remove("GIT_DIR")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES");
    command.output().map_err(|e| format!("运行 git 失败：{e}"))
}

fn run_git(root: &Path, args: &[&str], env: Option<&SessionGitEnv>) -> Result<Output, String> {
    let mut command = super::git_cmd();
    let working_directory = env.map(|env| env.worktree.as_path()).unwrap_or(root);
    command
        .arg("-C")
        .arg(working_directory)
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0");
    if let Some(env) = env {
        apply_session_git_env(&mut command, env)?;
    }
    command.output().map_err(|e| format!("运行 git 失败：{e}"))
}

fn run_git_strings(
    root: &Path,
    args: &[String],
    env: Option<&SessionGitEnv>,
) -> Result<Output, String> {
    let mut command = super::git_cmd();
    let working_directory = env.map(|env| env.worktree.as_path()).unwrap_or(root);
    command
        .arg("-C")
        .arg(working_directory)
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0");
    if let Some(env) = env {
        apply_session_git_env(&mut command, env)?;
    }
    command.output().map_err(|e| format!("运行 git 失败：{e}"))
}

fn run_git_input(
    root: &Path,
    args: &[&str],
    env: Option<&SessionGitEnv>,
    input: &[u8],
) -> Result<Output, String> {
    let mut command = super::git_cmd();
    let working_directory = env.map(|env| env.worktree.as_path()).unwrap_or(root);
    command
        .arg("-C")
        .arg(working_directory)
        .args(args)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env_remove("GIT_DIR")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES")
        .env_remove("GIT_LFS_STORAGE")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(env) = env {
        apply_session_git_env(&mut command, env)?;
    }
    let mut child = command.spawn().map_err(|e| format!("运行 git 失败：{e}"))?;
    {
        let mut stdin = child.stdin.take().ok_or("无法打开 git 标准输入")?;
        stdin
            .write_all(input)
            .map_err(|e| format!("写入 git 标准输入失败：{e}"))?;
    }
    child
        .wait_with_output()
        .map_err(|e| format!("等待 git 完成失败：{e}"))
}

fn apply_session_git_env(command: &mut Command, env: &SessionGitEnv) -> Result<(), String> {
    let alternate = std::env::join_paths([env.alternate_objects.as_os_str()])
        .map_err(|e| format!("设置 Git 对象只读回源路径失败：{e}"))?;
    command
        .env("GIT_DIR", &env.git_dir)
        .env("GIT_COMMON_DIR", &env.common_dir)
        .env("GIT_WORK_TREE", &env.worktree)
        .env("GIT_INDEX_FILE", &env.index)
        .env("GIT_OBJECT_DIRECTORY", &env.objects)
        .env("GIT_ALTERNATE_OBJECT_DIRECTORIES", alternate)
        .env("GIT_LFS_STORAGE", &env.lfs_storage);
    Ok(())
}

fn ensure_git_success(output: &Output, context: &str) -> Result<(), String> {
    if output.status.success() {
        Ok(())
    } else {
        Err(git_failure(context, output))
    }
}

fn git_failure(context: &str, output: &Output) -> String {
    let detail = output_text(&output.stderr);
    if detail.is_empty() {
        format!("{context}（git 退出码 {}）", output.status)
    } else {
        format!("{context}：{detail}")
    }
}

fn output_text(output: &[u8]) -> String {
    String::from_utf8_lossy(output)
        .trim_end_matches(['\r', '\n'])
        .to_string()
}

fn new_session_token() -> String {
    let sequence = PATCH_IMPORT_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    format!("{}-{nanos:x}-{sequence:x}", std::process::id())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::path::Path;
    use std::process::Command;

    fn git(path: &Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .arg("-C")
            .arg(path)
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    fn repo() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "cgit-patch-import-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        git(&dir, &["init", "-q"]);
        git(&dir, &["config", "user.name", "CGit test"]);
        git(&dir, &["config", "user.email", "cgit-test@example.invalid"]);
        dir
    }

    fn commit_file(dir: &Path, name: &str, content: &str) -> String {
        std::fs::write(dir.join(name), content).unwrap();
        git(dir, &["add", "--", name]);
        git(dir, &["commit", "-qm", "base"]);
        git(dir, &["rev-parse", "HEAD"])
    }

    fn patch(base_oid: &str, target_oid: &str, before: &str, after: &str) -> String {
        format!(
            "diff --git a/f b/f\nindex {base_oid}..{target_oid} 100644\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-{before}\n+{after}\n"
        )
    }

    #[test]
    fn path_guard_rejects_outside_and_git_metadata_paths() {
        for path in [
            "../outside",
            "/absolute",
            ".git/config",
            "nested/.git/index",
        ] {
            assert!(validate_relative_path(path).is_err(), "{path}");
        }
        assert_eq!(
            validate_relative_path("src/file.rs").unwrap(),
            Path::new("src/file.rs")
        );
    }

    #[test]
    fn temporary_session_cleanup_removes_its_directory() {
        let temp_dir = TempDir::create().unwrap();
        let path = temp_dir.path().to_path_buf();
        std::fs::write(path.join("session-file"), b"temporary").unwrap();

        temp_dir.cleanup().unwrap();

        assert!(!path.exists());
        assert!(temp_dir.cleanup().is_ok());
    }

    #[test]
    fn numstat_parser_handles_spaces_and_rename_paths() {
        let output = b"2\t1\tspace name.txt\x00-\t-\tbinary.dat\x000\t0\t\x00old name.txt\x00new name.txt\x00";
        let (paths, binary_paths) = parse_numstat_paths(output).unwrap();
        assert_eq!(
            paths,
            vec![
                PathBuf::from("space name.txt"),
                PathBuf::from("binary.dat"),
                PathBuf::from("old name.txt"),
                PathBuf::from("new name.txt"),
            ],
        );
        assert_eq!(binary_paths, HashSet::from([PathBuf::from("binary.dat")]));
    }

    #[test]
    fn finish_backup_restores_temporary_index_and_conflict_file() {
        let temp_dir = TempDir::create().unwrap();
        let temp_worktree = temp_dir.path().join("worktree");
        std::fs::create_dir(&temp_worktree).unwrap();
        let temp_index = temp_dir.path().join("index");
        std::fs::write(&temp_index, b"prepared index").unwrap();
        std::fs::write(temp_worktree.join("conflict.txt"), b"prepared conflict").unwrap();

        let path = PathBuf::from("conflict.txt");
        let session = PatchImportSession {
            root: temp_dir.path().to_path_buf(),
            git_dir: temp_dir.path().to_path_buf(),
            common_dir: temp_dir.path().to_path_buf(),
            real_index: temp_dir.path().join("real-index"),
            real_objects: temp_dir.path().join("real-objects"),
            _temp_dir: temp_dir,
            temp_worktree: temp_worktree.clone(),
            temp_index: temp_index.clone(),
            temp_objects: PathBuf::new(),
            temp_lfs: PathBuf::new(),
            index_snapshot: None,
            head_snapshot: None,
            worktree_snapshots: Vec::new(),
            touched_paths: vec![path.clone()],
            binary_paths: HashSet::new(),
            conflict_paths: vec![path.clone()],
        };

        let backup = backup_finish_state(&session).unwrap();
        let backup_path = backup.temp_dir.path().to_path_buf();
        std::fs::write(&temp_index, b"resolved index").unwrap();
        std::fs::write(temp_worktree.join(&path), b"resolved conflict").unwrap();
        restore_finish_state(&session, &backup).unwrap();

        assert_eq!(std::fs::read(&temp_index).unwrap(), b"prepared index");
        assert_eq!(
            std::fs::read(temp_worktree.join(path)).unwrap(),
            b"prepared conflict"
        );
        drop(backup);
        assert!(!backup_path.exists());
    }

    #[test]
    fn preview_and_finish_apply_without_changing_real_index() {
        let dir = repo();
        commit_file(&dir, "f", "base\n");
        let base = git(&dir, &["hash-object", "f"]);
        std::fs::write(dir.join("incoming"), "patched\n").unwrap();
        let target = git(&dir, &["hash-object", "-w", "incoming"]);
        let real_index = std::fs::read(dir.join(".git/index")).unwrap();
        let patch = patch(&base, &target, "base", "patched");

        let preview: Value = serde_json::from_str(
            &prepare_patch_import(dir.to_string_lossy().into_owned(), patch).unwrap(),
        )
        .unwrap();
        assert_eq!(preview["files"][0]["path"], "f");
        assert_eq!(preview["files"][0]["conflict"], false);
        assert_eq!(preview["files"][0]["content"], "patched\n");
        finish_patch_import(
            dir.to_string_lossy().into_owned(),
            preview["token"].as_str().unwrap().to_owned(),
            "{}".into(),
        )
        .unwrap();

        assert_eq!(std::fs::read_to_string(dir.join("f")).unwrap(), "patched\n");
        assert_eq!(std::fs::read(dir.join(".git/index")).unwrap(), real_index);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn three_way_conflict_exposes_sides_and_resolves_without_staging() {
        let dir = repo();
        commit_file(&dir, "f", "base\n");
        let base = git(&dir, &["hash-object", "f"]);
        std::fs::write(dir.join("incoming"), "theirs\n").unwrap();
        let target = git(&dir, &["hash-object", "-w", "incoming"]);
        std::fs::write(dir.join("f"), "ours\n").unwrap();
        let real_index = std::fs::read(dir.join(".git/index")).unwrap();

        let preview: Value = serde_json::from_str(
            &prepare_patch_import(
                dir.to_string_lossy().into_owned(),
                patch(&base, &target, "base", "theirs"),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(preview["files"][0]["conflict"], true);
        assert_eq!(preview["files"][0]["ours"], "ours\n");
        assert_eq!(preview["files"][0]["theirs"], "theirs\n");
        assert_eq!(preview["files"][0]["base"], "base\n");
        let resolutions = serde_json::json!({"f": {"content": "merged\n"}}).to_string();
        finish_patch_import(
            dir.to_string_lossy().into_owned(),
            preview["token"].as_str().unwrap().to_owned(),
            resolutions,
        )
        .unwrap();

        assert_eq!(std::fs::read_to_string(dir.join("f")).unwrap(), "merged\n");
        assert_eq!(std::fs::read(dir.join(".git/index")).unwrap(), real_index);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn three_way_conflict_preserves_an_empty_base_blob() {
        let dir = repo();
        commit_file(&dir, "f", "");
        let base = git(&dir, &["hash-object", "f"]);
        std::fs::write(dir.join("incoming"), "theirs\n").unwrap();
        let target = git(&dir, &["hash-object", "-w", "incoming"]);
        std::fs::write(dir.join("f"), "ours\n").unwrap();
        let patch = format!(
            "diff --git a/f b/f\nindex {base}..{target} 100644\n--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+theirs\n"
        );

        let preview: Value = serde_json::from_str(
            &prepare_patch_import(dir.to_string_lossy().into_owned(), patch).unwrap(),
        )
        .unwrap();
        assert_eq!(preview["files"][0]["conflict"], true);
        assert_eq!(preview["files"][0]["base"], "");

        discard_patch_import(preview["token"].as_str().unwrap().to_owned()).unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn add_add_conflict_has_no_base_stage() {
        let dir = repo();
        std::fs::write(dir.join("f"), "ours\n").unwrap();
        std::fs::write(dir.join("incoming"), "theirs\n").unwrap();
        let target = git(&dir, &["hash-object", "-w", "incoming"]);
        let patch = format!(
            "diff --git a/f b/f\nnew file mode 100644\nindex 0000000..{target}\n--- /dev/null\n+++ b/f\n@@ -0,0 +1 @@\n+theirs\n"
        );

        let preview: Value = serde_json::from_str(
            &prepare_patch_import(dir.to_string_lossy().into_owned(), patch).unwrap(),
        )
        .unwrap();
        assert_eq!(preview["files"][0]["conflict"], true);
        assert!(preview["files"][0]["base"].is_null());

        discard_patch_import(preview["token"].as_str().unwrap().to_owned()).unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn binary_base_is_detected_without_decoding_it() {
        let dir = repo();
        commit_file(&dir, "f", "");
        std::fs::write(dir.join("base"), b"base\0binary").unwrap();
        std::fs::write(dir.join("ours"), b"ours\n").unwrap();
        std::fs::write(dir.join("theirs"), b"theirs\n").unwrap();
        let base = git(&dir, &["hash-object", "-w", "base"]);
        let ours = git(&dir, &["hash-object", "-w", "ours"]);
        let theirs = git(&dir, &["hash-object", "-w", "theirs"]);

        let temp_dir = TempDir::create().unwrap();
        let temp_worktree = temp_dir.path().join("worktree");
        let temp_objects = temp_dir.path().join("objects");
        let temp_lfs = temp_dir.path().join("lfs");
        std::fs::create_dir(&temp_worktree).unwrap();
        std::fs::create_dir(&temp_objects).unwrap();
        std::fs::create_dir(&temp_lfs).unwrap();
        std::fs::write(temp_worktree.join("f"), b"content\n").unwrap();
        let git_dir = PathBuf::from(git(&dir, &["rev-parse", "--absolute-git-dir"]));
        let real_index = git_dir.join("index");
        let real_objects = git_dir.join("objects");
        let temp_index = temp_dir.path().join("index");
        let session = PatchImportSession {
            root: dir.clone(),
            git_dir: git_dir.clone(),
            common_dir: git_dir,
            real_index,
            real_objects,
            _temp_dir: temp_dir,
            temp_worktree,
            temp_index,
            temp_objects,
            temp_lfs,
            index_snapshot: None,
            head_snapshot: None,
            worktree_snapshots: Vec::new(),
            touched_paths: vec![PathBuf::from("f")],
            binary_paths: HashSet::new(),
            conflict_paths: vec![PathBuf::from("f")],
        };
        let env = session.env(session.temp_worktree.clone());
        ensure_git_success(
            &run_git(&session.root, &["read-tree", "--empty"], Some(&env)).unwrap(),
            "初始化测试索引失败",
        )
        .unwrap();
        let stages = HashMap::from([(
            PathBuf::from("f"),
            HashMap::from([(1, base), (2, ours), (3, theirs)]),
        )]);

        let files = preview_files(&session, &env, &stages).unwrap();
        assert_eq!(files[0]["binary"], true);
        assert!(files[0]["base"].is_null());
        assert_eq!(files[0]["ours"], "");
        assert_eq!(files[0]["theirs"], "");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn finish_refuses_when_a_touched_file_changes_after_preview() {
        let dir = repo();
        commit_file(&dir, "f", "base\n");
        let base = git(&dir, &["hash-object", "f"]);
        std::fs::write(dir.join("incoming"), "patched\n").unwrap();
        let target = git(&dir, &["hash-object", "-w", "incoming"]);
        let preview: Value = serde_json::from_str(
            &prepare_patch_import(
                dir.to_string_lossy().into_owned(),
                patch(&base, &target, "base", "patched"),
            )
            .unwrap(),
        )
        .unwrap();
        std::fs::write(dir.join("f"), "new local edit\n").unwrap();

        let err = finish_patch_import(
            dir.to_string_lossy().into_owned(),
            preview["token"].as_str().unwrap().to_owned(),
            "{}".into(),
        )
        .unwrap_err();
        assert!(err.contains("预览后"), "{err}");
        assert_eq!(
            std::fs::read_to_string(dir.join("f")).unwrap(),
            "new local edit\n"
        );
        discard_patch_import(preview["token"].as_str().unwrap().to_owned()).unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }
}
