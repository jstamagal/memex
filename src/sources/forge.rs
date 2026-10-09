//! ForgeCode conversations in its live, WAL-backed SQLite store.
use super::{IndexParseOutput, IndexParseState, ParseDiagnostics, ParserVersions, SourceFile};
use crate::types::{Record, RecordLinks, SourceKind};
use anyhow::{Context, Result};
use chrono::NaiveDateTime;
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

pub const VERSIONS: ParserVersions = ParserVersions {
    identity: 1,
    index: 1,
    usage: 1,
};

pub fn database_paths() -> Vec<PathBuf> {
    let paths = std::env::var("FORGE_DB")
        .ok()
        .map(|value| {
            value
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(|s| {
                    s.strip_prefix("~/")
                        .map_or_else(|| PathBuf::from(s), |tail| super::common::home().join(tail))
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_else(|| vec![super::common::home().join(".forge/.forge.db")]);
    let mut unique = Vec::new();
    for path in paths {
        if !unique.contains(&path) {
            unique.push(path);
        }
    }
    unique
}

pub fn roots() -> Vec<PathBuf> {
    database_paths()
        .into_iter()
        .filter_map(|path| path.parent().map(Path::to_path_buf))
        .collect()
}

pub fn matches_path(path: &str) -> bool {
    path.ends_with("/.forge/.forge.db")
        || path.ends_with("\\.forge\\.forge.db")
        || database_paths()
            .iter()
            .any(|db| db.to_string_lossy() == path)
}

pub fn discover() -> Vec<SourceFile> {
    database_paths()
        .into_iter()
        .filter(|path| path.is_file())
        .map(|path| SourceFile {
            source: SourceKind::Forge,
            path,
        })
        .collect()
}

fn open_read_only(path: &Path) -> Result<Connection> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .with_context(|| format!("open Forge store {}", path.display()))?;
    connection.busy_timeout(Duration::from_secs(1))?;
    Ok(connection)
}

fn timestamp(raw: &str) -> u64 {
    NaiveDateTime::parse_from_str(raw, "%Y-%m-%d %H:%M:%S%.f")
        .map(|date| date.and_utc().timestamp_millis().max(0) as u64)
        .unwrap_or(0)
}

fn cwd(context: &Value) -> Option<String> {
    context
        .get("messages")?
        .as_array()?
        .iter()
        .find_map(|entry| {
            entry
                .pointer("/message/text/tool_calls")?
                .as_array()?
                .iter()
                .find_map(|call| {
                    call.pointer("/arguments/cwd")
                        .and_then(Value::as_str)
                        .filter(|path| Path::new(path).is_absolute())
                        .map(str::to_string)
                })
        })
}

pub fn session_cwd(path: &Path, session_id: &str) -> Option<String> {
    let connection = open_read_only(path).ok()?;
    let raw: String = connection
        .query_row(
            "SELECT context FROM conversations WHERE conversation_id = ?1",
            [session_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .ok()
        .flatten()
        .flatten()?;
    cwd(&serde_json::from_str::<Value>(&raw).ok()?)
}

pub fn session_title(path: &Path, session_id: &str) -> Option<String> {
    let connection = open_read_only(path).ok()?;
    connection
        .query_row(
            "SELECT title FROM conversations WHERE conversation_id = ?1",
            [session_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .ok()
        .flatten()
        .flatten()
        .filter(|s| !s.trim().is_empty())
}

/// Current Forge metrics contain activity and file-change data, but no token
/// counters. Do not invent usage from message length or model limits.
pub(crate) fn parse_usage_file(path: &Path) -> Result<Vec<crate::usage::UsageEvent>> {
    let _ = open_read_only(path)?;
    Ok(Vec::new())
}

fn output_text(value: &Value) -> String {
    if let Some(text) = value.as_str() {
        return text.to_string();
    }
    if let Some(values) = value.get("values").and_then(Value::as_array) {
        return values
            .iter()
            .filter_map(|item| item.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n");
    }
    value.to_string()
}

pub(crate) fn parse_index_records(
    path: &Path,
    state: IndexParseState,
    _include_reasoning: bool,
    next_doc_id: &AtomicU64,
    mut emit: impl FnMut(Record) -> Result<()>,
) -> Result<IndexParseOutput> {
    let connection = open_read_only(path)?;
    let transaction = connection.unchecked_transaction()?;
    let mut statement = transaction.prepare("SELECT conversation_id, context, created_at, updated_at FROM conversations ORDER BY created_at, conversation_id")?;
    let mut rows = statement.query([])?;
    let mut diagnostics = ParseDiagnostics::default();
    let source_path = path.to_string_lossy().into_owned();
    let mut offset = 0;
    while let Some(row) = rows.next()? {
        let id: String = row.get(0)?;
        let raw: Option<String> = row.get(1)?;
        let created: String = row.get(2)?;
        let updated: Option<String> = row.get(3)?;
        let Some(raw) = raw else { continue };
        let Ok(context) = serde_json::from_str::<Value>(&raw) else {
            diagnostics.malformed_json_lines += 1;
            continue;
        };
        let Some(messages) = context.get("messages").and_then(Value::as_array) else {
            diagnostics.increment_unknown_top_level("missing_messages");
            continue;
        };
        let project = cwd(&context)
            .map(|path| super::common::project_from_path(&path))
            .unwrap_or_else(|| "forge".to_string());
        let created_ts = timestamp(&created);
        let updated_ts = updated
            .as_deref()
            .map(timestamp)
            .filter(|ts| *ts > 0)
            .unwrap_or(created_ts);
        for (ordinal, entry) in messages.iter().enumerate() {
            let ts = if ordinal == 0 { created_ts } else { updated_ts };
            offset += 1;
            let Some(message) = entry.get("message") else {
                diagnostics.increment_unknown_top_level("missing_message");
                continue;
            };
            let base = || Record {
                source: SourceKind::Forge,
                doc_id: next_doc_id.fetch_add(1, Ordering::SeqCst),
                ts,
                project: project.clone(),
                session_id: id.clone(),
                turn_id: ordinal.min(u32::MAX as usize / 8) as u32 * 8,
                role: String::new(),
                text: String::new(),
                tool_name: None,
                tool_input: None,
                tool_output: None,
                links: RecordLinks {
                    event_id: Some(format!("forge:{id}:{ordinal}")),
                    ..RecordLinks::default()
                },
                source_path: source_path.clone(),
            };
            if let Some(text) = message.get("text") {
                let role = text
                    .get("role")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                let content = text.get("content").and_then(Value::as_str).unwrap_or("");
                if !content.trim().is_empty() {
                    emit(Record {
                        role: role.clone(),
                        text: content.to_string(),
                        ..base()
                    })?;
                }
                if let Some(calls) = text.get("tool_calls").and_then(Value::as_array) {
                    for (call_ordinal, call) in calls.iter().enumerate() {
                        let name = call.get("name").and_then(Value::as_str).map(str::to_string);
                        let input = call.get("arguments").map(output_text).unwrap_or_default();
                        let call_id = call
                            .get("call_id")
                            .and_then(Value::as_str)
                            .map(str::to_string);
                        let mut record = base();
                        record.turn_id = record
                            .turn_id
                            .saturating_add((call_ordinal + 1).min(7) as u32);
                        record.role = "tool_use".to_string();
                        record.text = input.clone();
                        record.tool_name = name;
                        record.tool_input = Some(input);
                        record.links.source_tool_use_id = call_id.clone();
                        record.links.event_id = call_id;
                        emit(record)?;
                    }
                }
                if !matches!(role.as_str(), "user" | "assistant" | "system") {
                    diagnostics.increment_unknown_semantic(&role);
                }
            } else if let Some(tool) = message.get("tool") {
                let output = tool.get("output").map(output_text).unwrap_or_default();
                let call_id = tool
                    .get("call_id")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                let mut record = base();
                record.role = "tool_result".to_string();
                record.text = output.clone();
                record.tool_name = tool.get("name").and_then(Value::as_str).map(str::to_string);
                record.tool_output = Some(output);
                record.links.source_tool_use_id = call_id.clone();
                record.links.parent_event_id = call_id.clone();
                record.links.parent_tool_use_id = call_id;
                emit(record)?;
            } else {
                for key in message
                    .as_object()
                    .into_iter()
                    .flat_map(|object| object.keys())
                {
                    diagnostics.increment_unknown_semantic(key);
                }
            }
        }
    }
    drop(rows);
    drop(statement);
    transaction.commit()?;
    Ok(IndexParseOutput {
        offset,
        turn_id: 0,
        legacy_turn_id: None,
        pending_tool_calls: state.pending_tool_calls,
        session_id: None,
        diagnostics,
        session_cwd: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forge_fixture_indexes_text_calls_and_results() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join(".forge.db");
        Connection::open(&path)
            .unwrap()
            .execute_batch(include_str!("../../fixtures/forge.sql"))
            .unwrap();
        let mut records = Vec::new();
        let parsed = parse_index_records(
            &path,
            IndexParseState::default(),
            false,
            &AtomicU64::new(1),
            |record| {
                records.push(record);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(records.len(), 6);
        assert_eq!(
            records
                .iter()
                .map(|record| record.role.as_str())
                .collect::<Vec<_>>(),
            [
                "system",
                "user",
                "assistant",
                "tool_use",
                "tool_result",
                "assistant"
            ]
        );
        assert_eq!(records[0].text, "System instructions");
        assert_eq!(records[3].tool_name.as_deref(), Some("shell"));
        assert_eq!(records[4].tool_output.as_deref(), Some("Finished"));
        assert_eq!(
            records[4].links.parent_tool_use_id.as_deref(),
            Some("call-1")
        );
        assert_eq!(parsed.offset, 6);
        assert_eq!(
            parsed
                .diagnostics
                .unknown_semantic_types
                .get("future_variant"),
            Some(&1)
        );
        assert_eq!(parsed.diagnostics.malformed_json_lines, 1);
        assert_eq!(
            session_title(&path, "forge-session").as_deref(),
            Some("Fix the build")
        );
        assert_eq!(
            session_cwd(&path, "forge-session").as_deref(),
            Some("/work/project")
        );
        assert!(parse_usage_file(&path).unwrap().is_empty());
    }

    #[test]
    fn forge_reads_uncheckpointed_wal_without_writing() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join(".forge.db");
        let writer = Connection::open(&path).unwrap();
        writer
            .execute_batch(include_str!("../../fixtures/forge.sql"))
            .unwrap();
        writer
            .execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
            .unwrap();
        writer.execute("UPDATE conversations SET title = 'Updated title' WHERE conversation_id = 'forge-session'", []).unwrap();
        assert!(path.with_file_name(".forge.db-wal").exists());
        assert_eq!(
            session_title(&path, "forge-session").as_deref(),
            Some("Updated title")
        );
        let mut count = 0;
        parse_index_records(
            &path,
            IndexParseState::default(),
            false,
            &AtomicU64::new(1),
            |_| {
                count += 1;
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(count, 6);
    }
}
