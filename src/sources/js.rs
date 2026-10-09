//! The Python js harness: append-only JSONL sessions.
use super::{IndexParseOutput, IndexParseState, ParseDiagnostics, ParserVersions, SourceFile};
use crate::types::{Record, RecordLinks, SourceKind};
use crate::usage::{TokenBuckets, UsageEvent};
use anyhow::Result;
use memchr::memchr;
use simd_json::BorrowedValue;
use simd_json::prelude::*;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

pub const VERSIONS: ParserVersions = ParserVersions {
    identity: 1,
    index: 1,
    usage: 1,
};

pub fn roots() -> Vec<PathBuf> {
    let home = super::common::home();
    let configured = std::env::var_os("JS_SESSIONS_DIR").map(|value| {
        value
            .to_string_lossy()
            .split(',')
            .map(str::trim)
            .filter(|part| !part.is_empty())
            .map(|part| {
                part.strip_prefix("~/")
                    .map(|relative| home.join(relative))
                    .unwrap_or_else(|| PathBuf::from(part))
            })
            .collect::<Vec<_>>()
    });
    configured
        .filter(|roots| !roots.is_empty())
        .unwrap_or_else(|| vec![home.join(".js/sessions")])
}

pub fn matches_path(path: &str) -> bool {
    path.replace('\\', "/").contains("/.js/sessions/")
        || roots().iter().any(|root| Path::new(path).starts_with(root))
}

pub fn discover(walk: Option<&mut crate::ingest::directories::StampedWalk>) -> Vec<SourceFile> {
    super::common::jsonl_files_with(roots(), walk)
        .into_iter()
        .filter(|path| {
            !path
                .file_name()
                .and_then(|s| s.to_str())
                .is_some_and(|s| s.starts_with('.'))
        })
        .map(|path| SourceFile {
            source: SourceKind::Js,
            path,
        })
        .collect()
}

pub fn session_id_from_path(path: &Path) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string()
}

fn sidecar_header(path: &Path) -> (Option<String>, Option<String>, Option<String>) {
    let Ok(file) = File::open(path.with_extension("txt")) else {
        return (None, None, None);
    };
    use std::io::{BufRead, BufReader};
    let mut agent = None;
    let mut cwd = None;
    let mut model = None;
    for line in BufReader::new(file).lines().map_while(Result::ok).take(6) {
        if let Some(rest) = line.strip_prefix("agent: ") {
            agent = rest.split_whitespace().next().map(str::to_string);
            cwd = rest
                .split("dir: ")
                .nth(1)
                .and_then(|s| s.split("   ").next())
                .map(str::trim)
                .map(str::to_string);
        } else if let Some(rest) = line.strip_prefix("models: ") {
            model = rest.split_whitespace().next().map(str::to_string);
        }
    }
    (agent, cwd, model)
}

/// The latest metadata row mirrors the harness catalog; the text header helps old logs.
pub fn metadata(path: &Path) -> (String, Option<String>, Option<String>, Option<String>) {
    let (mut agent, mut cwd, mut model) = sidecar_header(path);
    let mut title = None;
    if let Ok(file) = File::open(path)
        && let Ok(mmap) = super::common::map_sequential(&file)
    {
        let mut offset = 0;
        while offset < mmap.len() {
            let slice = &mmap[offset..];
            let rel = memchr(b'\n', slice).unwrap_or(slice.len());
            let line = &slice[..rel];
            offset += rel + usize::from(rel < slice.len());
            if memchr::memmem::find(line, b"session_metadata").is_none()
                && memchr::memmem::find(line, b"\"kind\":\"title\"").is_none()
                && memchr::memmem::find(line, b"model_switch").is_none()
            {
                continue;
            }
            let Ok(value) = serde_json::from_slice::<serde_json::Value>(line) else {
                continue;
            };
            match value.get("kind").and_then(|v| v.as_str()) {
                Some("session_metadata") => {
                    if let Some(value) = value.get("agent").and_then(|v| v.as_str()) {
                        agent = Some(value.to_string());
                    }
                    if let Some(value) = value.get("cwd").and_then(|v| v.as_str()) {
                        cwd = Some(value.to_string());
                    }
                    if let Some(value) = value.get("model").and_then(|v| v.as_str()) {
                        model = Some(value.to_string());
                    }
                }
                Some("title") => {
                    if let Some(value) = value.get("title").and_then(|v| v.as_str()) {
                        title = Some(value.to_string());
                    }
                }
                Some("model_switch") => {
                    if let Some(value) = value.pointer("/stamp/model").and_then(|v| v.as_str()) {
                        model = Some(value.to_string());
                    }
                }
                _ => {}
            }
        }
    }
    (
        agent.unwrap_or_else(|| "defaultagent".into()),
        cwd,
        model,
        title,
    )
}

pub fn session_cwd(path: &Path) -> Option<String> {
    metadata(path).1
}
pub fn session_title(path: &Path) -> Option<String> {
    metadata(path).3
}
pub fn session_agent(path: &Path) -> String {
    metadata(path).0
}

fn timestamp(value: Option<&BorrowedValue<'_>>) -> u64 {
    value
        .and_then(|v| v.as_f64())
        .filter(|v| v.is_finite() && *v >= 0.0)
        .map(|v| (v * 1000.0) as u64)
        .unwrap_or(0)
}

pub(crate) fn parse_index_records(
    path: &Path,
    state: IndexParseState,
    include_reasoning: bool,
    next_doc_id: &AtomicU64,
    mut emit: impl FnMut(Record) -> Result<()>,
) -> Result<IndexParseOutput> {
    let file = File::open(path)?;
    if file.metadata()?.len() == 0 {
        return Ok(IndexParseOutput {
            offset: 0,
            turn_id: state.turn_id,
            legacy_turn_id: None,
            pending_tool_calls: state.pending_tool_calls,
            session_id: Some(session_id_from_path(path)),
            diagnostics: ParseDiagnostics::default(),
            session_cwd: metadata(path).1,
        });
    }
    let mmap = super::common::map_sequential(&file)?;
    let mut offset = super::jsonl::resume_offset(&mmap, state.offset, |line| {
        simd_json::to_borrowed_value(&mut line.to_vec()).is_ok()
    });
    let mut turn_id = state.turn_id;
    let mut diagnostics = ParseDiagnostics::default();
    let session_id = session_id_from_path(path);
    let (_, cwd, _, _) = metadata(path);
    let project = cwd
        .as_deref()
        .map(super::common::project_from_path)
        .unwrap_or_else(|| SourceKind::Js.label().to_string());
    let source_path = path.to_string_lossy().to_string();
    let mut buf = Vec::new();
    while offset < mmap.len() {
        let line_start = offset;
        let slice = &mmap[offset..];
        let rel = memchr(b'\n', slice).unwrap_or(slice.len());
        offset += rel + usize::from(rel < slice.len());
        if rel == 0 {
            continue;
        }
        buf.clear();
        buf.extend_from_slice(&slice[..rel]);
        let value = match simd_json::to_borrowed_value(&mut buf) {
            Ok(v) => v,
            Err(_) => {
                if rel == slice.len() {
                    offset = line_start;
                    break;
                }
                diagnostics.malformed_json_lines += 1;
                continue;
            }
        };
        let Some(obj) = value.as_object() else {
            diagnostics.non_object_json_lines += 1;
            continue;
        };
        let kind = obj.get("kind").and_then(|v| v.as_str()).unwrap_or("");
        if kind != "message" {
            let text = match kind {
                "session_metadata" => {
                    let mut fields = Vec::new();
                    for key in ["agent", "model", "mode", "cwd"] {
                        if let Some(value) = obj.get(key).and_then(|v| v.as_str()) {
                            fields.push(format!("{key}: {value}"));
                        }
                    }
                    fields.join("\n")
                }
                "title" => obj
                    .get("title")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                "tags" => obj
                    .get("tags")
                    .and_then(|v| v.as_array())
                    .map(|tags| {
                        tags.iter()
                            .filter_map(|tag| tag.as_str())
                            .collect::<Vec<_>>()
                            .join(", ")
                    })
                    .unwrap_or_default(),
                "model_switch" => obj
                    .get("stamp")
                    .and_then(|stamp| stamp.get("model"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string(),
                _ => String::new(),
            };
            if !text.is_empty() {
                emit(Record {
                    source: SourceKind::Js,
                    doc_id: next_doc_id.fetch_add(1, Ordering::SeqCst),
                    ts: timestamp(obj.get("ts")),
                    project: project.clone(),
                    session_id: session_id.clone(),
                    turn_id,
                    role: "metadata".into(),
                    text,
                    tool_name: None,
                    tool_input: None,
                    tool_output: None,
                    links: RecordLinks {
                        event_id: obj.get("id").and_then(|v| v.as_str()).map(str::to_string),
                        parent_event_id: obj
                            .get("parent")
                            .and_then(|v| v.as_str())
                            .map(str::to_string),
                        source_record_type: Some(kind.to_string()),
                        conversation_kind: Some("main".into()),
                        ..RecordLinks::default()
                    },
                    source_path: source_path.clone(),
                })?;
                turn_id += 1;
            }
            if !matches!(
                kind,
                "usage" | "session_metadata" | "mark" | "tags" | "model_switch" | "title"
            ) {
                diagnostics.increment_unknown_top_level(kind);
            }
            continue;
        }
        let Some(message) = obj.get("message").and_then(|v| v.as_object()) else {
            continue;
        };
        let role = message.get("role").and_then(|v| v.as_str()).unwrap_or("");
        if !matches!(role, "user" | "assistant" | "tool") {
            diagnostics.increment_unknown_semantic(role);
            continue;
        }
        let ts = timestamp(obj.get("ts"));
        let event_id = obj.get("id").and_then(|v| v.as_str()).map(str::to_string);
        let parent = obj
            .get("parent")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        let links = RecordLinks {
            event_id: event_id.clone(),
            parent_event_id: parent.clone(),
            source_tool_use_id: message
                .get("tool_call_id")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            conversation_kind: Some("main".into()),
            ..RecordLinks::default()
        };
        let content = message
            .get("content")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        let tool_name = message
            .get("name")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        let mut push = |role: &str,
                        text: String,
                        tool_name: Option<String>,
                        tool_input: Option<String>,
                        tool_output: Option<String>,
                        links: RecordLinks|
         -> Result<()> {
            emit(Record {
                source: SourceKind::Js,
                doc_id: next_doc_id.fetch_add(1, Ordering::SeqCst),
                ts,
                project: project.clone(),
                session_id: session_id.clone(),
                turn_id,
                role: role.into(),
                text,
                tool_name,
                tool_input,
                tool_output,
                links,
                source_path: source_path.clone(),
            })?;
            turn_id += 1;
            Ok(())
        };
        if !content.is_empty() {
            push(
                role,
                content.to_string(),
                tool_name.clone(),
                None,
                (role == "tool").then(|| content.to_string()),
                links.clone(),
            )?;
        }
        if include_reasoning
            && role == "assistant"
            && let Some(reasoning) = message
                .get("reasoning_content")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
        {
            let mut reasoning_links = links.clone();
            reasoning_links.event_id = event_id.as_ref().map(|id| format!("{id}:reasoning"));
            push(
                "reasoning",
                reasoning.to_string(),
                None,
                None,
                None,
                reasoning_links,
            )?;
        }
        if let Some(calls) = message.get("tool_calls").and_then(|v| v.as_array()) {
            for call in calls {
                let Some(function) = call.get("function") else {
                    continue;
                };
                let name = function
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("tool");
                let arguments = function
                    .get("arguments")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let call_id = call.get("id").and_then(|v| v.as_str());
                let mut call_links = links.clone();
                call_links.event_id = call_id.map(str::to_string);
                call_links.parent_event_id = event_id.clone();
                call_links.source_tool_use_id = call_id.map(str::to_string);
                push(
                    "tool",
                    format!("{name} {arguments}"),
                    Some(name.into()),
                    Some(arguments.into()),
                    None,
                    call_links,
                )?;
            }
        }
    }
    Ok(IndexParseOutput {
        offset: offset as u64,
        turn_id,
        legacy_turn_id: None,
        pending_tool_calls: state.pending_tool_calls,
        session_id: Some(session_id),
        diagnostics,
        session_cwd: cwd,
    })
}

pub(crate) fn parse_usage_file(path: &Path) -> Result<Vec<UsageEvent>> {
    let file = File::open(path)?;
    if file.metadata()?.len() == 0 {
        return Ok(Vec::new());
    }
    let mmap = super::common::map_sequential(&file)?;
    let source_path: Arc<str> = Arc::from(path.to_string_lossy());
    let session_id = session_id_from_path(path);
    let project = metadata(path)
        .1
        .as_deref()
        .map(super::common::project_from_path);
    let mut events = Vec::new();
    let mut start = 0;
    let mut order = 0;
    let mut buf = Vec::new();
    while start < mmap.len() {
        let slice = &mmap[start..];
        let rel = memchr(b'\n', slice).unwrap_or(slice.len());
        start += rel + usize::from(rel < slice.len());
        buf.clear();
        buf.extend_from_slice(&slice[..rel]);
        let Ok(value) = simd_json::to_borrowed_value(&mut buf) else {
            order += 1;
            continue;
        };
        if value.get("kind").and_then(|v| v.as_str()) != Some("usage") {
            order += 1;
            continue;
        }
        let Some(call) = value.get("call") else {
            order += 1;
            continue;
        };
        let number = |key: &str| call.get(key).and_then(|v| v.as_u64()).unwrap_or(0);
        let input = number("input_tokens");
        let cache_read = number("cache_read_tokens").min(input);
        let cache_write = number("cache_write_tokens").min(input - cache_read);
        let tokens = TokenBuckets {
            raw_input: input,
            uncached_input: input - cache_read - cache_write,
            cache_read,
            cache_write,
            cache_write_1h: 0,
            output: number("output_tokens"),
            reasoning: number("reasoning_tokens"),
        };
        if tokens.total() > 0 {
            events.push(UsageEvent {
                source: "js",
                source_path: source_path.clone(),
                source_record_id: value.get("id").and_then(|v| v.as_str()).map(str::to_string),
                session_id: Some(session_id.clone()),
                request_id: None,
                message_id: None,
                timestamp_ms: timestamp(value.get("ts")),
                project: project.clone(),
                provider: call
                    .get("provider")
                    .and_then(|v| v.as_str())
                    .map(str::to_string),
                model: call
                    .get("model")
                    .and_then(|v| v.as_str())
                    .map(str::to_string),
                tokens,
                credits: None,
                token_usage_available: true,
                source_cost_usd: call.get("cost").and_then(|v| v.as_f64()),
                cost_authoritative: false,
                dedupe_confidence: "exact",
                conservative_undercount: false,
                cache_chain_excluded: false,
                sidechain: false,
                permission_review: false,
                source_order: order,
            });
        }
        order += 1;
    }
    Ok(events)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/js/session.jsonl")
    }

    #[test]
    fn js_fixture_preserves_tree_tools_metadata_and_usage() {
        let path = fixture();
        let mut records = Vec::new();
        let ids = AtomicU64::new(1);
        let parsed =
            parse_index_records(&path, IndexParseState::default(), false, &ids, |record| {
                records.push(record);
                Ok(())
            })
            .unwrap();
        assert_eq!(parsed.diagnostics.malformed_json_lines, 1);
        assert_eq!(parsed.session_cwd.as_deref(), Some("/work/alpha-beta"));
        assert_eq!(records.len(), 7);
        assert!(records.iter().all(|record| record.project == "alpha-beta"));
        assert_eq!(records[1].ts, 1_780_000_001_250);
        assert_eq!(records[1].links.parent_event_id.as_deref(), Some("start"));
        assert_eq!(
            records[2].tool_input.as_deref(),
            Some("{\"command\":\"pwd\"}")
        );
        assert_eq!(
            records[3].links.source_tool_use_id.as_deref(),
            Some("call1")
        );
        assert!(records.iter().all(|record| record.role != "reasoning"));
        assert_eq!(
            session_title(&path).as_deref(),
            Some("Falcon cache location")
        );
        assert_eq!(session_agent(&path), "research");

        let mut with_reasoning = Vec::new();
        parse_index_records(&path, IndexParseState::default(), true, &ids, |record| {
            with_reasoning.push(record);
            Ok(())
        })
        .unwrap();
        assert_eq!(
            with_reasoning
                .iter()
                .filter(|r| r.role == "reasoning")
                .count(),
            1
        );
        let usage = parse_usage_file(&path).unwrap();
        assert_eq!(usage.len(), 1);
        assert_eq!(usage[0].tokens.raw_input, 100);
        assert_eq!(usage[0].tokens.uncached_input, 20);
        assert_eq!(usage[0].tokens.cache_read, 80);
        assert_eq!(usage[0].tokens.output, 20);
    }

    #[test]
    fn js_resumes_at_last_complete_line() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("session.jsonl");
        std::fs::write(&path, concat!(
            "{\"kind\":\"message\",\"id\":\"one\",\"ts\":1.0,\"message\":{\"role\":\"user\",\"content\":\"first\"}}\n",
            "{\"kind\":\"message\",\"id\":\"two\",\"ts\":2.0,\"message\":"
        )).unwrap();
        let ids = AtomicU64::new(1);
        let mut first = Vec::new();
        let parsed =
            parse_index_records(&path, IndexParseState::default(), false, &ids, |record| {
                first.push(record);
                Ok(())
            })
            .unwrap();
        assert_eq!(first.len(), 1);
        assert!(parsed.offset < std::fs::metadata(&path).unwrap().len());
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap();
        file.write_all(b"{\"role\":\"assistant\",\"content\":\"second\"}}\n")
            .unwrap();
        let mut second = Vec::new();
        parse_index_records(
            &path,
            IndexParseState {
                offset: parsed.offset,
                turn_id: parsed.turn_id,
                ..IndexParseState::default()
            },
            false,
            &ids,
            |record| {
                second.push(record);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(second.len(), 1);
        assert_eq!(second[0].text, "second");
    }

    #[test]
    fn js_discovers_comma_separated_roots_without_sidecars_or_locks() {
        let _guard = crate::test_support::env_lock();
        let temp = tempfile::tempdir().unwrap();
        let first = temp.path().join("first");
        let second = temp.path().join("second");
        std::fs::create_dir_all(first.join("-work-one")).unwrap();
        std::fs::create_dir_all(second.join("-work-two")).unwrap();
        std::fs::write(first.join("-work-one/a.jsonl"), "{}\n").unwrap();
        std::fs::write(second.join("-work-two/b.jsonl"), "{}\n").unwrap();
        std::fs::write(second.join("-work-two/b.txt"), "agent: test\n").unwrap();
        std::fs::write(second.join("-work-two/.b.jsonl.liveness.lock"), "").unwrap();
        let value = format!("{},{}", first.display(), second.display());
        let _env = crate::test_support::EnvVarGuard::set_os(&[(
            "JS_SESSIONS_DIR",
            Some(std::ffi::OsStr::new(&value)),
        )]);
        let files = discover(None);
        assert_eq!(files.len(), 2);
        assert!(
            files
                .iter()
                .all(|file| file.path.extension().is_some_and(|ext| ext == "jsonl"))
        );
    }
}
