//! Safe, previewable patch import using an isolated temporary index.
//!
//! This module intentionally does not stage changes in the user's real index.

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
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
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
            "diff --git a/f b/f\nindex {base_oid}..{target_oid} 100644\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-{before}+{after}+"
        )
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

        let preview: Value = serde_json::from_str(&prepare_patch_import(
            dir.to_string_lossy().into_owned(),
            patch,
        ).unwrap()).unwrap();
        assert_eq!(preview["files"][0]["path"], "f");
        assert_eq!(preview["files"][0]["conflict"], false);
        assert_eq!(preview["files"][0]["content"], "patched\n");
        finish_patch_import(
            dir.to_string_lossy().into_owned(),
            preview["token"].as_str().unwrap().to_owned(),
            "{}".into(),
        ).unwrap();

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

        let preview: Value = serde_json::from_str(&prepare_patch_import(
            dir.to_string_lossy().into_owned(),
            patch(&base, &target, "base", "theirs"),
        ).unwrap()).unwrap();
        assert_eq!(preview["files"][0]["conflict"], true);
        assert_eq!(preview["files"][0]["ours"], "ours\n");
        assert_eq!(preview["files"][0]["theirs"], "theirs\n");
        let resolutions = serde_json::json!({"f": {"content": "merged\n"}}).to_string();
        finish_patch_import(
            dir.to_string_lossy().into_owned(),
            preview["token"].as_str().unwrap().to_owned(),
            resolutions,
        ).unwrap();

        assert_eq!(std::fs::read_to_string(dir.join("f")).unwrap(), "merged\n");
        assert_eq!(std::fs::read(dir.join(".git/index")).unwrap(), real_index);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn finish_refuses_when_a_touched_file_changes_after_preview() {
        let dir = repo();
        commit_file(&dir, "f", "base\n");
        let base = git(&dir, &["hash-object", "f"]);
        std::fs::write(dir.join("incoming"), "patched\n").unwrap();
        let target = git(&dir, &["hash-object", "-w", "incoming"]);
        let preview: Value = serde_json::from_str(&prepare_patch_import(
            dir.to_string_lossy().into_owned(),
            patch(&base, &target, "base", "patched"),
        ).unwrap()).unwrap();
        std::fs::write(dir.join("f"), "new local edit\n").unwrap();

        let err = finish_patch_import(
            dir.to_string_lossy().into_owned(),
            preview["token"].as_str().unwrap().to_owned(),
            "{}".into(),
        ).unwrap_err();
        assert!(err.contains("预览后"), "{err}");
        assert_eq!(std::fs::read_to_string(dir.join("f")).unwrap(), "new local edit\n");
        discard_patch_import(preview["token"].as_str().unwrap()).unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }
}
