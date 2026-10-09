use super::{IndexParseOutput, IndexParseState, ParseDiagnostics, ParserVersions, SourceFile};
use crate::types::{Record, RecordLinks, SourceKind};
use anyhow::Result;
use serde_json::Value;
use std::fs::File;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

pub const VERSIONS: ParserVersions = ParserVersions {
    identity: 1,
    index: 1,
    usage: 1,
};

pub fn sessions_roots() -> Vec<PathBuf> {
    match std::env::var_os("BITCHTEA_SESSIONS_DIR") {
        Some(value) => value
            .to_string_lossy()
            .split(',')
            .map(str::trim)
            .filter(|part| !part.is_empty())
            .map(PathBuf::from)
            .collect(),
        None => vec![super::common::home().join(".bitchtea/.bitchtea/sessions")],
    }
}

pub fn matches_path(path: &str) -> bool {
    path.replace('\\', "/")
        .contains("/.bitchtea/.bitchtea/sessions/")
}

pub fn discover(walk: Option<&mut crate::ingest::directories::StampedWalk>) -> Vec<SourceFile> {
    super::common::jsonl_files_with(sessions_roots(), walk)
        .into_iter()
        .map(|path| SourceFile {
            source: SourceKind::Bitchtea,
            path,
        })
        .collect()
}

pub fn session_id_from_path(path: &Path) -> String {
    path.file_stem()
        .and_then(|part| part.to_str())
        .unwrap_or_default()
        .to_string()
}

fn nonempty(value: Option<&Value>) -> Option<&str> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

fn content_text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Object(object)) => {
            content_text(object.get("data").or_else(|| object.get("text")))
        }
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|item| {
                let kind = item.get("type").and_then(Value::as_str)?;
                let data = item.get("data")?;
                match kind {
                    "text" => nonempty(data.get("text")).map(str::to_owned),
                    _ => None,
                }
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "record projection carries transcript and tool fields"
)]
fn emit_record(
    emit: &mut impl FnMut(Record) -> Result<()>,
    next_doc_id: &AtomicU64,
    path: &str,
    session_id: &str,
    project: &str,
    ts: u64,
    turn_id: &mut u32,
    role: &str,
    text: String,
    tool_name: Option<String>,
    tool_input: Option<String>,
    tool_output: Option<String>,
    links: RecordLinks,
) -> Result<()> {
    if text.trim().is_empty() && tool_name.is_none() {
        return Ok(());
    }
    emit(Record {
        source: SourceKind::Bitchtea,
        doc_id: next_doc_id.fetch_add(1, Ordering::SeqCst),
        ts,
        project: project.to_string(),
        session_id: session_id.to_string(),
        turn_id: *turn_id,
        role: role.to_string(),
        text,
        tool_name,
        tool_input,
        tool_output,
        links,
        source_path: path.to_string(),
    })?;
    *turn_id += 1;
    Ok(())
}

pub(crate) fn parse_index_records(
    path: &Path,
    state: IndexParseState,
    next_doc_id: &AtomicU64,
    mut emit: impl FnMut(Record) -> Result<()>,
) -> Result<IndexParseOutput> {
    let mut reader = BufReader::new(File::open(path)?);
    reader.seek(SeekFrom::Start(state.offset))?;
    let mut offset = state.offset;
    let mut turn_id = state.turn_id;
    let mut diagnostics = ParseDiagnostics::default();
    let session_id = session_id_from_path(path);
    let source_path = path.to_string_lossy().into_owned();
    let mut session_cwd = None;
    let mut project = SourceKind::Bitchtea.label().to_string();
    let mut line = Vec::new();
    loop {
        line.clear();
        let bytes = reader.read_until(b'\n', &mut line)?;
        if bytes == 0 {
            break;
        }
        if line.last() != Some(&b'\n') {
            // Leave a partially written tail for the next incremental refresh.
            break;
        }
        offset += bytes as u64;
        let value: Value = match serde_json::from_slice(&line) {
            Ok(value) => value,
            Err(_) => {
                diagnostics.malformed_json_lines += 1;
                continue;
            }
        };
        let Some(obj) = value.as_object() else {
            diagnostics.non_object_json_lines += 1;
            continue;
        };
        if let Some(cwd) = nonempty(obj.get("cwd")) {
            session_cwd = Some(cwd.to_string());
            project = super::common::project_from_path(cwd);
        }
        let ts = nonempty(obj.get("ts"))
            .and_then(super::common::parse_iso_millis)
            .unwrap_or(0);
        let message = obj.get("msg").unwrap_or(&value);
        let role = nonempty(message.get("role")).unwrap_or("");
        let links = RecordLinks {
            event_id: nonempty(obj.get("id")).map(str::to_owned),
            parent_event_id: nonempty(obj.get("parent_id")).map(str::to_owned),
            conversation_kind: Some("main".to_string()),
            ..RecordLinks::default()
        };
        let text = content_text(message.get("content"));
        if matches!(role, "user" | "assistant" | "system") {
            emit_record(
                &mut emit,
                next_doc_id,
                &source_path,
                &session_id,
                &project,
                ts,
                &mut turn_id,
                role,
                text,
                None,
                None,
                None,
                links.clone(),
            )?;
        }
        if let Some(parts) = message.get("content").and_then(Value::as_array) {
            for part in parts {
                let kind = part.get("type").and_then(Value::as_str).unwrap_or("");
                let data = part.get("data").unwrap_or(part);
                if kind == "tool-call" {
                    let name = nonempty(data.get("tool_name").or_else(|| data.get("name")))
                        .map(str::to_owned);
                    let input = data
                        .get("input")
                        .or_else(|| data.get("arguments"))
                        .map(|v| {
                            if let Some(s) = v.as_str() {
                                s.to_string()
                            } else {
                                v.to_string()
                            }
                        });
                    let mut tool_links = links.clone();
                    tool_links.event_id =
                        nonempty(data.get("tool_call_id").or_else(|| data.get("id")))
                            .map(str::to_owned);
                    tool_links.parent_event_id = links.event_id.clone();
                    emit_record(
                        &mut emit,
                        next_doc_id,
                        &source_path,
                        &session_id,
                        &project,
                        ts,
                        &mut turn_id,
                        "tool_use",
                        input.clone().unwrap_or_default(),
                        name,
                        input,
                        None,
                        tool_links,
                    )?;
                } else if kind == "tool-result" {
                    let output = content_text(data.get("output").or_else(|| data.get("content")))
                        .trim()
                        .to_string();
                    let mut tool_links = links.clone();
                    tool_links.parent_event_id =
                        nonempty(data.get("tool_call_id")).map(str::to_owned);
                    emit_record(
                        &mut emit,
                        next_doc_id,
                        &source_path,
                        &session_id,
                        &project,
                        ts,
                        &mut turn_id,
                        "tool_result",
                        output.clone(),
                        None,
                        None,
                        Some(output),
                        tool_links,
                    )?;
                }
            }
        }
        if let Some(calls) = obj.get("tool_calls").and_then(Value::as_array) {
            for call in calls {
                let function = call.get("function").unwrap_or(call);
                let name = nonempty(function.get("name")).map(str::to_owned);
                let input = nonempty(function.get("arguments")).map(str::to_owned);
                let mut tool_links = links.clone();
                tool_links.event_id = nonempty(call.get("id")).map(str::to_owned);
                tool_links.parent_event_id = links.event_id.clone();
                emit_record(
                    &mut emit,
                    next_doc_id,
                    &source_path,
                    &session_id,
                    &project,
                    ts,
                    &mut turn_id,
                    "tool_use",
                    input.clone().unwrap_or_default(),
                    name,
                    input,
                    None,
                    tool_links,
                )?;
            }
        }
        if role == "tool" {
            let output = content_text(message.get("content"));
            let mut tool_links = links;
            if let Some(call_id) = nonempty(obj.get("tool_call_id")) {
                tool_links.parent_event_id = Some(call_id.to_string());
            }
            emit_record(
                &mut emit,
                next_doc_id,
                &source_path,
                &session_id,
                &project,
                ts,
                &mut turn_id,
                "tool_result",
                output.clone(),
                nonempty(obj.get("tool_name")).map(str::to_owned),
                None,
                Some(output),
                tool_links,
            )?;
        }
    }
    Ok(IndexParseOutput {
        offset,
        turn_id,
        legacy_turn_id: None,
        pending_tool_calls: state.pending_tool_calls,
        session_id: Some(session_id),
        diagnostics,
        session_cwd,
    })
}

pub(crate) fn parse_usage_file(_path: &Path) -> Result<Vec<crate::usage::UsageEvent>> {
    Ok(Vec::new())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn parses_both_eras_and_tool_events() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("2026-07-22_134611.jsonl");
        std::fs::write(&path, include_str!("../../fixtures/bitchtea.jsonl")).unwrap();
        let mut records = Vec::new();
        let parsed = parse_index_records(
            &path,
            IndexParseState::default(),
            &AtomicU64::new(1),
            |record| {
                records.push(record);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(parsed.session_id.as_deref(), Some("2026-07-22_134611"));
        assert_eq!(parsed.session_cwd, None);
        assert_eq!(records.len(), 7);
        assert_eq!(records[0].text, "find cobalt widgets");
        assert_eq!(records[2].tool_name.as_deref(), Some("bash"));
        assert_eq!(records[2].links.event_id.as_deref(), Some("call1"));
        assert_eq!(records[3].tool_output.as_deref(), Some("cobalt.txt"));
        assert_eq!(records[5].tool_name.as_deref(), Some("bash"));
        assert_eq!(records[6].text, "/work/repo");
        let resumed = parse_index_records(
            &path,
            IndexParseState {
                offset: parsed.offset,
                turn_id: parsed.turn_id,
                ..IndexParseState::default()
            },
            &AtomicU64::new(100),
            |_| panic!("already indexed"),
        )
        .unwrap();
        assert_eq!(resumed.offset, parsed.offset);
    }

    #[test]
    fn comma_separated_roots() {
        let _guard = crate::test_support::env_lock();
        let _env = crate::test_support::EnvVarGuard::set(&[(
            "BITCHTEA_SESSIONS_DIR",
            Some("/tmp/one,/tmp/two"),
        )]);
        assert_eq!(
            sessions_roots(),
            vec![PathBuf::from("/tmp/one"), PathBuf::from("/tmp/two")]
        );
    }

    #[test]
    fn malformed_lines_are_counted_and_partial_tail_is_retried() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("session.jsonl");
        std::fs::write(&path, b"not json\n{\"ts\":\"2026-07-22T13:46:11Z\",\"role\":\"user\",\"content\":\"ready\"}\n{\"role\":\"user\"").unwrap();
        let mut records = Vec::new();
        let parsed = parse_index_records(
            &path,
            IndexParseState::default(),
            &AtomicU64::new(1),
            |record| {
                records.push(record);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(parsed.diagnostics.malformed_json_lines, 1);
        assert_eq!(records.len(), 1);
        assert_eq!(parsed.offset as usize, b"not json\n{\"ts\":\"2026-07-22T13:46:11Z\",\"role\":\"user\",\"content\":\"ready\"}\n".len());
        std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b",\"content\":\"later\"}\n")
            .unwrap();
        let mut appended = Vec::new();
        let resumed = parse_index_records(
            &path,
            IndexParseState {
                offset: parsed.offset,
                turn_id: parsed.turn_id,
                ..IndexParseState::default()
            },
            &AtomicU64::new(2),
            |record| {
                appended.push(record);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(appended.len(), 1);
        assert_eq!(appended[0].text, "later");
        assert_eq!(resumed.diagnostics.malformed_json_lines, 0);
    }
}
