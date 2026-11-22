use diskm_shadow::scan::{self, AgeKind};
use diskm_shadow::scratch_index::{AgeTimeField, Cursor, Page, Query, ScratchIndex};
use serde_json::{json, Value};
use std::env;
use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{self, Write};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::DirBuilderExt;
use std::path::{Component, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const NANOS_PER_SECOND: i64 = 1_000_000_000;

pub(super) fn dispatch(args: &[OsString]) -> Option<ExitCode> {
    let refresh = match args.first()?.to_str()? {
        "scratch-index" => true,
        "scratch-search" => false,
        _ => return None,
    };
    let args = &args[1..];
    if args
        .iter()
        .any(|argument| argument == "--help" || argument == "-h")
    {
        println!("{}", super::USAGE);
        return Some(ExitCode::SUCCESS);
    }
    let options = match Options::parse(args, refresh) {
        Ok(options) => options,
        Err(error) => {
            eprintln!("diskm: {error}");
            return Some(ExitCode::from(2));
        }
    };
    Some(match run(options, refresh) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("diskm: {error}");
            ExitCode::FAILURE
        }
    })
}

struct Options {
    root_key: String,
    state_dir: PathBuf,
    root_path: Option<PathBuf>,
    cutoff: Option<i64>,
    prefix: Option<PathBuf>,
    kind: Option<AgeKind>,
    time: AgeTimeField,
    limit: usize,
    all: bool,
    cursor: Option<Cursor>,
    deadline: Duration,
    max_entries: usize,
}

fn now_ns() -> Result<i64, Box<dyn Error>> {
    Ok(i64::try_from(
        SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos(),
    )?)
}

fn seconds_ns(value: i64) -> Result<i64, Box<dyn Error>> {
    value
        .checked_mul(NANOS_PER_SECOND)
        .ok_or_else(|| "timestamp out of range".into())
}

impl Options {
    fn parse(args: &[OsString], refresh: bool) -> Result<Self, Box<dyn Error>> {
        let mut args = args.iter();
        if refresh && args.next().map(OsString::as_os_str) != Some(OsStr::new("refresh")) {
            return Err("expected scratch-index refresh".into());
        }
        let mut state_dir = env::var_os("DISK_MAGICIAN_STATE_DIR").map(PathBuf::from);
        let mut options = Self {
            root_key: "scratch".into(),
            state_dir: PathBuf::new(),
            root_path: None,
            cutoff: None,
            prefix: None,
            kind: None,
            time: AgeTimeField::EffectiveModified,
            limit: 100,
            all: false,
            cursor: None,
            deadline: Duration::from_secs(120),
            max_entries: usize::MAX,
        };
        let mut specified_limit = false;
        let mut specified_cutoff = false;
        while let Some(argument) = args.next() {
            let name = argument.to_str().ok_or("invalid option")?;
            if !refresh && name == "--all" {
                options.all = true;
                continue;
            }
            let value = args
                .next()
                .ok_or_else(|| format!("{name} requires a value"))?;
            let utf8 = || value.to_str().ok_or("option value must be UTF-8");
            match name {
                "--root" => {
                    options.root_key = utf8()?.to_owned();
                    if !matches!(options.root_key.as_str(), "scratch" | "system-tmp") {
                        return Err("--root must be scratch or system-tmp".into());
                    }
                }
                "--state-dir" => state_dir = Some(PathBuf::from(value)),
                "--root-path" if refresh => options.root_path = Some(PathBuf::from(value)),
                "--deadline-ms" if refresh => {
                    options.deadline = Duration::from_millis(utf8()?.parse()?)
                }
                "--max-entries" if refresh => options.max_entries = utf8()?.parse()?,
                "--older-than" | "--before-epoch" if !refresh => {
                    specified_cutoff = true;
                    if options.cutoff.is_some() {
                        return Err("choose one age cutoff".into());
                    }
                    options.cutoff = Some(if name == "--before-epoch" {
                        seconds_ns(utf8()?.parse()?)?
                    } else {
                        let hours: i64 = utf8()?
                            .strip_suffix('h')
                            .ok_or("--older-than expects hours such as 6h")?
                            .parse()?;
                        if hours <= 0 {
                            return Err("age must be positive".into());
                        }
                        let hours = hours.checked_mul(3600).ok_or("age out of range")?;
                        now_ns()?
                            .checked_sub(seconds_ns(hours)?)
                            .ok_or("cutoff out of range")?
                    });
                }
                "--type" if !refresh => {
                    options.kind = match utf8()? {
                        "any" => None,
                        "file" => Some(AgeKind::File),
                        "directory" => Some(AgeKind::Directory),
                        "symlink" => Some(AgeKind::Symlink),
                        _ => return Err("--type must be any, file, directory or symlink".into()),
                    };
                }
                "--time" if !refresh => {
                    options.time = match utf8()? {
                        "modified" => AgeTimeField::EffectiveModified,
                        "created" => AgeTimeField::Created,
                        _ => return Err("--time must be modified or created".into()),
                    };
                }
                "--prefix" if !refresh => {
                    let path = PathBuf::from(value);
                    if path.as_os_str().is_empty()
                        || path
                            .components()
                            .any(|part| !matches!(part, Component::Normal(_)))
                    {
                        return Err(
                            "--prefix must be a root-relative path without dot components".into(),
                        );
                    }
                    options.prefix = Some(path);
                }
                "--limit" if !refresh => {
                    options.limit = utf8()?.parse()?;
                    specified_limit = true;
                }
                "--cursor" if !refresh => options.cursor = Some(serde_json::from_str(utf8()?)?),
                _ => return Err(format!("invalid option {name}").into()),
            }
        }
        if !refresh && options.cursor.is_some() && specified_cutoff {
            return Err(
                "--cursor pins the original cutoff; omit --older-than and --before-epoch".into(),
            );
        }
        if !refresh && (options.limit == 0 || (options.all && specified_limit)) {
            return Err("choose a positive --limit or --all".into());
        }
        if !refresh && options.cutoff.is_none() {
            options.cutoff = options
                .cursor
                .as_ref()
                .map(|cursor| cursor.cutoff_epoch_nanos);
            if options.cutoff.is_none() {
                return Err("specify --older-than or --before-epoch".into());
            }
        }
        options.state_dir = state_dir
            .or_else(|| {
                env::var_os("HOME").map(|home| PathBuf::from(home).join(".disk_magician_state"))
            })
            .ok_or("set --state-dir or HOME")?;
        Ok(options)
    }
}

fn display_path(bytes: &[u8]) -> (String, Option<String>) {
    scan::path_parts_for_report(OsStr::from_bytes(bytes).as_ref())
}

fn run(options: Options, refresh: bool) -> Result<(), Box<dyn Error>> {
    let db = options.state_dir.join("scratch-age.sqlite3");
    let mut output = io::stdout().lock();
    if refresh {
        let root = if let Some(explicit) = options.root_path {
            explicit
        } else if options.root_key == "scratch" {
            diskm_shadow::verified_scratch_volume(None, false)?
                .ok_or("Scratch volume is not registered")?
        } else if cfg!(target_os = "macos") {
            PathBuf::from("/private/tmp")
        } else {
            PathBuf::from("/tmp")
        };
        if !root.is_absolute() || !fs::symlink_metadata(&root)?.is_dir() {
            return Err(
                "refresh root must be an absolute directory, without a symlink leaf".into(),
            );
        }
        let root = root.canonicalize()?;
        let generation = now_ns()?;
        let (_, scan) = scan::scan_with_age_inventory(
            &root,
            scan::ScanOptions {
                deadline: options.deadline,
                max_entries: options.max_entries,
            },
        )?;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&options.state_dir)?;
        let mut index = ScratchIndex::open(&db)?;
        let snapshot = index.publish(&options.root_key, generation, &scan)?;
        serde_json::to_writer(
            &mut output,
            &json!({
                "root": root, "generation": snapshot.generation, "coverage_complete": snapshot.scan_complete
            }),
        )?;
        writeln!(output)?;
        return Ok(());
    }

    let index = ScratchIndex::open_read_only(&db).map_err(|error| {
        format!("{error}. Use diskm scratch-index refresh to build the age index")
    })?;
    let prefix = options
        .prefix
        .as_ref()
        .map(|relative| {
            let root = index.snapshot(&options.root_key)?;
            let path = PathBuf::from(OsString::from_vec(root.root_path_bytes)).join(relative);
            Ok::<Vec<u8>, Box<dyn Error>>(path.as_os_str().as_bytes().to_vec())
        })
        .transpose()?;
    let mut query = Query {
        root_key: options.root_key,
        time_field: options.time,
        cutoff_epoch_nanos: options.cutoff.ok_or("missing age cutoff")?,
        kind: options.kind,
        path_prefix: prefix,
        limit: if options.all { 1_000 } else { options.limit },
        cursor: options.cursor,
    };
    let page = index.query(&query)?;
    write_page(&mut output, &index, &mut query, page, options.all)?;
    Ok(())
}

fn write_page(
    output: &mut impl Write,
    index: &ScratchIndex,
    query: &mut Query,
    mut page: Page,
    all: bool,
) -> Result<(), Box<dyn Error>> {
    let (root, root_bytes_hex) = display_path(&page.snapshot.root_path_bytes);
    let mut header = json!({
        "root": root, "root_bytes_hex": root_bytes_hex,
        "generation": page.snapshot.generation, "coverage_complete": page.snapshot.scan_complete,
        "gaps": page.gaps,
    })
    .to_string();
    header.pop();
    write!(output, "{header},\"entries\":[")?;
    let mut first = true;
    loop {
        for row in &page.rows {
            if !first {
                write!(output, ",")?;
            }
            first = false;
            let (path, path_bytes_hex) = display_path(&row.path_bytes);
            let row = json!({
                "path": path, "path_bytes_hex": path_bytes_hex, "kind": row.kind,
                "created_epoch_nanos": row.created_epoch_nanos,
                "modified_epoch_nanos": row.modified_epoch_nanos,
                "effective_modified_epoch_nanos": row.effective_modified_epoch_nanos,
                "allocated_bytes": row.allocated_bytes, "apparent_bytes": row.apparent_bytes,
                "coverage_complete": row.complete, "qualification": "pending",
            });
            serde_json::to_writer(&mut *output, &row)?;
        }
        if !all || page.next_cursor.is_none() {
            let next = page
                .next_cursor
                .take()
                .map(|cursor| serde_json::to_string(&cursor))
                .transpose()?;
            write!(output, "],\"next_cursor\":")?;
            serde_json::to_writer(&mut *output, &Value::from(next))?;
            writeln!(output, "}}")?;
            return Ok(());
        }
        query.cursor = page.next_cursor;
        page = index.query(query)?;
    }
}
