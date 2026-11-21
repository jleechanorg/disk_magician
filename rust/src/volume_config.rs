use serde_json::Value;
use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub(crate) fn json_file(path: &Path) -> io::Result<Value> {
    serde_json::from_slice(&fs::read(path)?).map_err(io::Error::other)
}

pub(crate) fn configuration(home: &Path) -> io::Result<Value> {
    if let Some(path) = env::var_os("DISK_MAGICIAN_CONFIG").filter(|path| !path.is_empty()) {
        return json_file(Path::new(&path));
    }
    let user = env::var_os("XDG_CONFIG_HOME")
        .map_or_else(|| home.join(".config"), PathBuf::from)
        .join("disk-magician/config.json");
    let mut overlay_state = None;
    if user.is_file() {
        let document = json_file(&user)?;
        let overlay = document.as_object().is_some_and(|doc| {
            !doc.is_empty()
                && doc
                    .keys()
                    .all(|key| matches!(key.as_str(), "snapshot_measure" | "state_repo_path"))
        });
        if !overlay {
            return Ok(document);
        }
        overlay_state = document["state_repo_path"]
            .as_str()
            .filter(|path| !path.is_empty())
            .map(|path| match path {
                "~" => home.to_path_buf(),
                path if path.starts_with("~/") => home.join(&path[2..]),
                path => home.join(path),
            });
    }
    let state = env::var_os("DISK_MAGICIAN_STATE_REPO")
        .map(PathBuf::from)
        .or(overlay_state)
        .unwrap_or_else(|| {
            env::var_os("XDG_STATE_HOME")
                .map_or_else(|| home.join(".local/state"), PathBuf::from)
                .join("disk-magician")
        });
    let config = state.join("config/config.json");
    if config.is_file() {
        return json_file(&config);
    }
    packaged_configuration(&env::current_exe()?)
}

fn packaged_configuration(executable: &Path) -> io::Result<Value> {
    // Source and installed distributions can pair the binary with the existing
    // Disk Magician package config and template, including a Cargo target dir.
    if let Some(package) = executable.ancestors().skip(1).find(|directory| {
        directory.join("config.json.template").is_file()
            || directory.join("disk_magician.sh").is_file()
    }) {
        for candidate in ["config.json", "config.json.template"] {
            let path = package.join(candidate);
            if path.is_file() {
                return json_file(&path);
            }
        }
    }
    serde_json::from_str(include_str!("../../config.json.template")).map_err(io::Error::other)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_config_precedes_the_template_even_for_a_cargo_build() {
        let root = env::temp_dir().join(format!("diskm-volume-config-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        let template = root.join("config.json.template");
        let config = root.join("config.json");
        fs::write(&template, r#"{"source":"template"}"#).unwrap();
        let executable = root.join("rust/target/debug/diskm");
        assert_eq!(
            packaged_configuration(&executable).unwrap()["source"],
            "template"
        );
        fs::write(&config, r#"{"source":"package config"}"#).unwrap();
        assert_eq!(
            packaged_configuration(&executable).unwrap()["source"],
            "package config"
        );
        fs::remove_dir_all(&root).unwrap();
    }
}
