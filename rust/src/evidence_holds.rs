//! Hold Scratch and temp paths that open pull requests link to.

use crate::job_receipt::{self, Completion};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::SystemTime;

/// Values written by a refresh; any other value is a manual hold and is kept.
pub const AUTO: &str = "auto:";
pub const DEFAULT_QUERY: &str = "is:pr is:open author:@me";
const HOLDS_FILE: &str = "evidence-holds.json";
const MAX_HOLDS_BYTES: u64 = 16 * 1024 * 1024;
const CEILING: usize = 2000;
/// GitHub search never returns more than this many results.
const SEARCH_LIMIT: u64 = 1000;

pub type Holds = BTreeMap<PathBuf, String>;

/// One open pull request and every text in it that may name a path.
pub struct PullRequest {
    pub url: String,
    pub texts: Vec<String>,
}

/// Fetches every open pull request for a query; an error holds the refresh.
pub type Fetcher = fn(&str) -> io::Result<Vec<PullRequest>>;

/// (spelling found in text, canonical spelling the cleaner compares against)
pub type Root = (String, String);

fn filename_char(character: char) -> bool {
    character.is_alphanumeric() || matches!(character, '_' | '-' | '.')
}

/// Absolute paths under any root, in canonical spelling.
pub fn extract(text: &str, roots: &[Root]) -> BTreeSet<PathBuf> {
    let mut found = BTreeSet::new();
    for (spelling, canonical) in roots {
        let prefix = format!("{}/", spelling.trim_end_matches('/'));
        let mut offset = 0;
        while let Some(position) = text[offset..].find(&prefix) {
            let start = offset + position;
            offset = start + prefix.len();
            let before = text[..start].chars().next_back();
            if before.is_some_and(filename_char) {
                continue;
            }
            let tail = &text[start..];
            let closer = match before {
                Some('`') => Some('`'),
                Some('(') => Some(')'),
                Some('<') => Some('>'),
                Some(quote @ ('"' | '\'')) => Some(quote),
                _ => None,
            };
            // A path never spans lines, even inside an unterminated delimiter.
            let line_end = tail.find(['\n', '\r']).unwrap_or(tail.len());
            let tail = &tail[..line_end];
            let end = match closer {
                Some(closer) => tail.find(closer),
                None => tail.find(|character: char| {
                    character.is_whitespace()
                        || matches!(character, '`' | '"' | '\'' | ')' | ']' | '>' | '<' | '|')
                }),
            }
            .unwrap_or(tail.len());
            let mut path = &tail[..end];
            if closer.is_none() {
                path = path.trim_end_matches(['.', ',', ';', ':', '!', '?']);
            }
            let path = path.trim_end_matches('/');
            let relative = &path[prefix.len().min(path.len())..];
            if relative.is_empty() || relative.split('/').any(|part| part == "..") {
                continue;
            }
            found.insert(Path::new(canonical).join(relative));
        }
    }
    found
}

/// Keeps manual holds and replaces every automatic one with the fresh set.
pub fn merge(existing: &Holds, fresh: &BTreeMap<PathBuf, String>) -> Holds {
    let mut merged: Holds = existing
        .iter()
        .filter(|(_, value)| !value.starts_with(AUTO))
        .map(|(path, value)| (path.clone(), value.clone()))
        .collect();
    for (path, url) in fresh {
        merged
            .entry(path.clone())
            .or_insert_with(|| format!("{AUTO}{url}"));
    }
    merged
}

fn graphql(query: &str, variables: &[(&str, &str)]) -> io::Result<Value> {
    let mut command = Command::new("gh");
    command.args(["api", "graphql", "-f", &format!("query={query}")]);
    for (name, value) in variables {
        command.arg("-f").arg(format!("{name}={value}"));
    }
    let output = command
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other("gh api graphql failed"));
    }
    let value: Value = serde_json::from_slice(&output.stdout).map_err(io::Error::other)?;
    if value.get("errors").is_some_and(|errors| !errors.is_null()) {
        return Err(io::Error::other("GraphQL returned errors"));
    }
    Ok(value)
}

const SEARCH: &str = "query($q: String!, $after: String) { search(query: $q, type: ISSUE, first: 50, after: $after) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { id url body comments(first: 100) { pageInfo { hasNextPage endCursor } nodes { body } } } } } }";
const COMMENTS: &str = "query($id: ID!, $after: String) { node(id: $id) { ... on PullRequest { comments(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { body } } } } }";

fn page(connection: &Value) -> io::Result<(Vec<Value>, Option<String>)> {
    let nodes = connection["nodes"]
        .as_array()
        .ok_or_else(|| io::Error::other("missing nodes"))?
        .clone();
    let next = connection["pageInfo"]["hasNextPage"]
        .as_bool()
        .ok_or_else(|| io::Error::other("missing pageInfo"))?;
    let cursor = next
        .then(|| {
            connection["pageInfo"]["endCursor"]
                .as_str()
                .map(str::to_owned)
        })
        .flatten();
    if next && cursor.is_none() {
        return Err(io::Error::other("missing endCursor"));
    }
    Ok((nodes, cursor))
}

fn bodies(nodes: &[Value]) -> Vec<String> {
    nodes
        .iter()
        .filter_map(|node| node["body"].as_str().map(str::to_owned))
        .collect()
}

/// Civil date for days since the Unix epoch (Howard Hinnant's algorithm).
fn civil(days: i64) -> String {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}

/// Every open pull request whose creation date falls in `from..=to` (days
/// since the epoch). GitHub search returns at most 1,000 results, so a larger
/// range is split in half until each part fits; a single day over the limit
/// holds the refresh.
fn fetch_range(query: &str, from: i64, to: i64, requests: &mut Vec<PullRequest>) -> io::Result<()> {
    let scoped = format!("{query} created:{}..{}", civil(from), civil(to));
    let mut after: Option<String> = None;
    let mut fetched = 0u64;
    loop {
        let mut variables = vec![("q", scoped.as_str())];
        if let Some(cursor) = after.as_deref() {
            variables.push(("after", cursor));
        }
        let search = graphql(SEARCH, &variables)?;
        let search = &search["data"]["search"];
        let total = search["issueCount"]
            .as_u64()
            .ok_or_else(|| io::Error::other("missing issueCount"))?;
        if total > SEARCH_LIMIT {
            if from >= to {
                return Err(io::Error::other("one day exceeds GitHub's search limit"));
            }
            let middle = from + (to - from) / 2;
            fetch_range(query, from, middle, requests)?;
            return fetch_range(query, middle + 1, to, requests);
        }
        let (nodes, next) = page(search)?;
        for node in nodes.iter().filter(|node| node["url"].is_string()) {
            let mut texts = vec![node["body"].as_str().unwrap_or_default().to_owned()];
            let (comments, mut cursor) = page(&node["comments"])?;
            texts.extend(bodies(&comments));
            while let Some(position) = cursor.take() {
                let id = node["id"]
                    .as_str()
                    .ok_or_else(|| io::Error::other("missing id"))?;
                let (more, next) = page(
                    &graphql(COMMENTS, &[("id", id), ("after", &position)])?["data"]["node"]
                        ["comments"],
                )?;
                texts.extend(bodies(&more));
                if texts.len() > CEILING {
                    return Err(io::Error::other("comment ceiling reached"));
                }
                cursor = next;
            }
            requests.push(PullRequest {
                url: node["url"].as_str().unwrap_or_default().to_owned(),
                texts,
            });
            fetched += 1;
        }
        match next {
            Some(cursor) => after = Some(cursor),
            // Replace automatic holds only from a verified complete result.
            None if fetched == total => return Ok(()),
            None => {
                return Err(io::Error::other(
                    "fetched fewer pull requests than the search reported",
                ))
            }
        }
    }
}

/// Every open pull request for `query`, paginated through `gh api graphql`.
pub fn fetch_github(query: &str) -> io::Result<Vec<PullRequest>> {
    let today = SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_secs() as i64
        / 86_400;
    // GitHub launched in 2008; nothing can be older than 2008-01-01.
    let mut requests = Vec::new();
    fetch_range(query, 13_879, today + 1, &mut requests)?;
    Ok(requests)
}

/// Registered Scratch and system temp roots under every spelling.
pub fn default_roots() -> Vec<Root> {
    let mut roots = Vec::new();
    let mut add = |spelling: &Path| {
        if let Ok(canonical) = fs::canonicalize(spelling) {
            let canonical = canonical.to_string_lossy().into_owned();
            roots.push((spelling.to_string_lossy().into_owned(), canonical.clone()));
            roots.push((canonical.clone(), canonical));
        }
    };
    if let Ok(Some(scratch)) = crate::verified_scratch_volume(None, false) {
        add(&scratch);
    }
    add(Path::new("/tmp"));
    roots.sort();
    roots.dedup();
    roots
}

fn write_atomic(path: &Path, holds: &Holds) -> io::Result<()> {
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(&serde_json::to_vec_pretty(holds).map_err(io::Error::other)?)?;
    file.sync_all()?;
    fs::rename(&temporary, path)
}

/// Refreshes automatic holds; a failure keeps the existing file unchanged.
pub fn refresh(
    state_dir: Option<&Path>,
    query: &str,
    roots: &[Root],
    fetch: Fetcher,
) -> io::Result<(Value, u8)> {
    let started = SystemTime::now();
    let state = job_receipt::state_dir(state_dir)?;
    let path = state.join(HOLDS_FILE);
    let precondition = json!({"query": query, "roots": roots});
    let hold = |reason: &str| -> io::Result<(Value, u8)> {
        let result = json!({"status": "held", "reason": reason});
        let receipt = job_receipt::publish_terminal(
            &state,
            "evidence-holds",
            started,
            Completion::Partial(reason),
            precondition.clone(),
            result.clone(),
            json!({}),
        )?;
        Ok((json!({"result": result, "receipt": receipt}), 75))
    };
    let Ok(existing) = job_receipt::read_json_if_exists::<Holds>(&path, MAX_HOLDS_BYTES) else {
        return hold("existing_holds_unreadable");
    };
    let existing = existing.unwrap_or_default();
    let Ok(requests) = fetch(query) else {
        return hold("fetch_failed");
    };
    let mut fresh = BTreeMap::new();
    for request in &requests {
        for text in &request.texts {
            for found in extract(text, roots) {
                fresh.entry(found).or_insert_with(|| request.url.clone());
            }
        }
    }
    let merged = merge(&existing, &fresh);
    write_atomic(&path, &merged)?;
    let manual = merged
        .values()
        .filter(|value| !value.starts_with(AUTO))
        .count();
    let result = json!({"status": "refreshed", "pull_requests": requests.len(), "automatic": merged.len() - manual, "manual": manual, "path": path});
    let receipt = job_receipt::publish_terminal(
        &state,
        "evidence-holds",
        started,
        Completion::Success,
        precondition,
        result.clone(),
        json!({}),
    )?;
    Ok((json!({"result": result, "receipt": receipt}), 0))
}
