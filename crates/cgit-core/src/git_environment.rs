use std::ffi::{OsStr, OsString};
use std::fs::OpenOptions;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// 给所有 Git 子进程补齐 GUI 启动时缺失的工具路径，不修改应用的全局环境。
pub(super) fn apply(command: &mut Command) {
    static PATH: OnceLock<OsString> = OnceLock::new();
    command.env("PATH", PATH.get_or_init(resolve_path));
}

fn resolve_path() -> OsString {
    let inherited = std::env::var_os("PATH").unwrap_or_default();
    let shell = std::env::var_os("SHELL").unwrap_or_else(|| "/bin/zsh".into());
    let shell_path = match login_shell_path(&shell, Duration::from_secs(3)) {
        Ok(path) => path,
        Err(error) => {
            eprintln!("CGit: 无法读取登录 shell PATH：{error}；保留现有路径并补入标准工具目录");
            OsString::new()
        }
    };
    let home = std::env::var_os("HOME").map(PathBuf::from);
    merge_paths(&inherited, &shell_path, home.as_deref())
}

/// 保持已有 PATH 的优先级，补入用户 shell、自定义目录及常见安装位置并去重。
fn merge_paths(inherited: &OsStr, shell_path: &OsStr, home: Option<&Path>) -> OsString {
    let mut paths: Vec<PathBuf> = if inherited.is_empty() {
        Vec::new()
    } else {
        std::env::split_paths(inherited).collect()
    };
    let mut additional: Vec<PathBuf> = std::env::split_paths(shell_path).collect();
    if let Some(home) = home {
        additional.push(home.join(".local/bin"));
        additional.push(home.join("bin"));
    }
    for directory in [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ] {
        additional.push(PathBuf::from(directory));
    }
    for directory in additional {
        if !directory.as_os_str().is_empty() && !paths.contains(&directory) {
            paths.push(directory);
        }
    }
    match std::env::join_paths(paths) {
        Ok(path) => path,
        Err(error) => {
            eprintln!("CGit: 无法合并 Git PATH：{error}；保留现有路径");
            inherited.to_owned()
        }
    }
}

/// 只读取 PATH；输出写入立即取消目录链接的临时文件，避免启动脚本撑满管道。
fn login_shell_path(shell: &OsStr, timeout: Duration) -> Result<OsString, String> {
    let filename = std::env::temp_dir().join(format!("cgit-shell-path-{}", super::temp_token()));
    let mut output = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&filename)
        .map_err(|error| error.to_string())?;
    std::fs::remove_file(&filename).map_err(|error| error.to_string())?;
    let mut child = Command::new(shell)
        .args([
            "-ilc",
            "/usr/bin/printf '\\000CGIT_PATH\\000'; /usr/bin/printenv PATH; /usr/bin/printf '\\000'",
        ])
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(output.try_clone().map_err(|error| error.to_string())?)
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| error.to_string())?;

    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(Some(status)) => return Err(format!("shell 退出状态为 {status}")),
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(10));
            }
            result => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(match result {
                    Err(error) => error.to_string(),
                    _ => "探测超时".to_string(),
                });
            }
        }
    }

    output
        .seek(SeekFrom::Start(0))
        .map_err(|error| error.to_string())?;
    let mut bytes = Vec::new();
    output
        .take(64 * 1024)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    let mut fields = bytes.split(|byte| *byte == 0);
    while let Some(field) = fields.next() {
        if field == b"CGIT_PATH" {
            let path = fields.next().ok_or("shell 未返回 PATH")?;
            fields.next().ok_or("shell PATH 输出被截断")?;
            let path = path.strip_suffix(b"\n").unwrap_or(path);
            if path.is_empty() {
                return Err("shell 返回了空 PATH".to_string());
            }
            return Ok(OsString::from_vec(path.to_vec()));
        }
    }
    Err("shell 未返回 PATH 标记".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn inherited_order_and_custom_shell_paths_are_preserved() {
        let result = merge_paths(
            OsStr::new("/custom/git:/usr/bin:/bin"),
            OsStr::new("/usr/bin:/custom helper/bin:/custom/git"),
            Some(Path::new("/Users/test user")),
        );
        let paths: Vec<PathBuf> = std::env::split_paths(&result).collect();
        assert_eq!(paths[0], Path::new("/custom/git"));
        assert_eq!(paths[1], Path::new("/usr/bin"));
        assert_eq!(paths[2], Path::new("/bin"));
        assert_eq!(paths[3], Path::new("/custom helper/bin"));
        assert_eq!(
            paths
                .iter()
                .filter(|path| *path == Path::new("/usr/bin"))
                .count(),
            1
        );
        assert!(paths.contains(&PathBuf::from("/Users/test user/.local/bin")));
        assert!(paths.contains(&PathBuf::from("/Users/test user/bin")));
        assert!(paths.contains(&PathBuf::from("/opt/homebrew/bin")));
        assert!(paths.contains(&PathBuf::from("/usr/local/bin")));
    }

    #[test]
    fn missing_shell_path_still_includes_standard_tool_directories() {
        let result = merge_paths(OsStr::new(""), OsStr::new(""), None);
        let paths: Vec<PathBuf> = std::env::split_paths(&result).collect();
        assert!(!paths.contains(&PathBuf::new()));
        assert!(paths.contains(&PathBuf::from("/opt/homebrew/sbin")));
        assert!(paths.contains(&PathBuf::from("/usr/local/sbin")));
    }

    #[test]
    fn slow_shell_is_stopped_without_blocking_git() {
        let filename =
            std::env::temp_dir().join(format!("cgit-slow-shell-{}", crate::temp_token()));
        std::fs::write(&filename, "#!/bin/sh\nexec /bin/sleep 60\n").unwrap();
        std::fs::set_permissions(&filename, std::fs::Permissions::from_mode(0o700)).unwrap();
        let started = Instant::now();
        let result = login_shell_path(filename.as_os_str(), Duration::from_millis(50));
        std::fs::remove_file(filename).unwrap();
        assert_eq!(result.unwrap_err(), "探测超时");
        assert!(started.elapsed() < Duration::from_secs(2));
    }
}
