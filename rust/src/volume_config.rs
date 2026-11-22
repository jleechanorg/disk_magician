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
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    packaged_configuration(&env::current_exe()?, crate_dir.parent())
}

fn packaged_configuration(executable: &Path, source_package: Option<&Path>) -> io::Result<Value> {
    // A relocated installation owns its colocated config. A development
    // build with CARGO_TARGET_DIR outside the tree still belongs to its source package.
    let is_package = |directory: &&Path| {
        directory.join("config.json.template").is_file()
            || directory.join("disk_magician.sh").is_file()
    };
    let package = executable
        .ancestors()
        .skip(1)
        .find(is_package)
        .or_else(|| source_package.filter(is_package));
    if let Some(package) = package {
        for candidate in ["config.json", "config.json.template"] {
            let path = package.join(candidate);
            if path.is_file() {
                return json_file(&path);
            }
        }
    }
    serde_json::from_str(include_str!("../../config.json.template")).map_err(io::Error::other)
}
