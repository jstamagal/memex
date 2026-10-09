//! Configured JSONL stores share one parser and one source slot. The configured
//! label remains the persisted identity; the slot is only for progress counters.
use super::{IndexParseOutput, IndexParseState, ParseDiagnostics, ParserVersions, SourceFile};
use crate::config::CustomSourceConfig;
use crate::types::{Record, RecordLinks, SourceKind};
use anyhow::{Result, anyhow};
use globset::Glob;
use serde_json::Value;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock, RwLock};

pub const VERSIONS: ParserVersions = ParserVersions {
    identity: 1,
    index: 1,
    usage: 0,
};

type Registry = HashMap<&'static str, Arc<CustomSourceConfig>>;
static SOURCES: OnceLock<RwLock<Registry>> = OnceLock::new();
fn sources() -> &'static RwLock<Registry> {
    SOURCES.get_or_init(|| RwLock::new(HashMap::new()))
}

pub fn register(configs: &[CustomSourceConfig]) -> Result<()> {
    let mut names = std::collections::HashSet::new();
    for config in configs {
        if config.name.is_empty()
            || config.name == "custom"
            || !config
                .name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
            || crate::types::SourceKind::ALL
                .iter()
                .any(|kind| kind.label() == config.name)
            || !names.insert(&config.name)
        {
            return Err(anyhow!(
                "invalid or duplicate custom source name: {}",
                config.name
            ));
        }
        if config.roots.is_empty() {
            return Err(anyhow!("custom source {} needs roots", config.name));
        }
        Glob::new(&config.glob)?;
        if config.session_id != "stem" && !valid_pointer(&config.session_id) {
            return Err(anyhow!(
                "invalid JSON pointer {:?} in {}",
                config.session_id,
                config.name
            ));
        }
        for pointer in [&config.role, &config.text]
            .into_iter()
            .chain(
                [
                    config.cwd.as_ref(),
                    config.agent.as_ref(),
                    config.ts.as_ref(),
                    config.id.as_ref(),
                    config.parent.as_ref(),
                    config.tool_name.as_ref(),
                    config.tool_input.as_ref(),
                    config.tool_output.as_ref(),
                    config.reasoning.as_ref(),
                    config.tool_calls.as_ref(),
                    config.tool_call_name.as_ref(),
                    config.tool_call_input.as_ref(),
                    config.tool_call_id.as_ref(),
                ]
                .into_iter()
                .flatten(),
            )
            .chain(config.metadata.iter())
        {
            if !valid_pointer(pointer) {
                return Err(anyhow!(
                    "invalid JSON pointer {pointer:?} in {}",
                    config.name
                ));
            }
        }
        if let Some(parts) = &config.text_parts
            && (!valid_pointer(&parts.type_key) || !valid_pointer(&parts.text_key))
        {
            return Err(anyhow!("invalid text_parts pointer in {}", config.name));
        }
    }
    let mut registry = sources().write().expect("custom source registry poisoned");
    for config in configs {
        let name = registry
            .get_key_value(config.name.as_str())
            .map(|(key, _)| *key)
            .unwrap_or_else(|| Box::leak(config.name.clone().into_boxed_str()));
        registry.insert(name, Arc::new(config.clone()));
    }
    Ok(())
}

fn valid_pointer(pointer: &str) -> bool {
    if !pointer.is_empty() && !pointer.starts_with('/') {
        return false;
    }
    let bytes = pointer.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'~' {
            if !matches!(bytes.get(i + 1), Some(b'0' | b'1')) {
                return false;
            }
            i += 1;
        }
        i += 1;
    }
    true
}

pub fn kind(name: &str) -> Option<SourceKind> {
    sources()
        .read()
        .ok()?
        .get_key_value(name)
        .map(|(key, _)| SourceKind::Custom(key))
}

pub fn config(name: &str) -> Option<Arc<CustomSourceConfig>> {
    sources().read().ok()?.get(name).cloned()
}

pub fn discover(
    configs: &[CustomSourceConfig],
    mut walk: Option<&mut crate::ingest::directories::StampedWalk>,
) -> Vec<SourceFile> {
    let mut files = Vec::new();
    for config in configs {
        let Some(source) = kind(&config.name) else {
            continue;
        };
        let Ok(pattern) = Glob::new(&config.glob) else {
            continue;
        };
        let matcher = pattern.compile_matcher();
        for root in &config.roots {
            let root = expand_root(root);
            for path in super::common::files_under(&root, walk.as_deref_mut()) {
                if path
                    .strip_prefix(&root)
                    .is_ok_and(|relative| matcher.is_match(relative))
                {
                    files.push(SourceFile { source, path });
                }
            }
        }
    }
    files
}

pub fn matches_relative(name: &str, relative: &Path) -> bool {
    config(name)
        .and_then(|source| Glob::new(&source.glob).ok())
        .is_some_and(|glob| glob.compile_matcher().is_match(relative))
}

pub fn classify_path(path: &str) -> Option<SourceKind> {
    let path = Path::new(path);
    let registry = sources().read().ok()?;
    registry.iter().find_map(|(name, config)| {
        config.roots.iter().find_map(|root| {
            let root = expand_root(root);
            path.strip_prefix(&root)
                .ok()
                .filter(|relative| {
                    Glob::new(&config.glob)
                        .ok()
                        .is_some_and(|glob| glob.compile_matcher().is_match(relative))
                })
                .map(|_| SourceKind::Custom(name))
        })
    })
}

pub fn expand_root(root: &Path) -> PathBuf {
    root.to_str()
        .and_then(|s| s.strip_prefix("~/"))
        .map(|s| super::common::home().join(s))
        .unwrap_or_else(|| root.to_path_buf())
}

fn field<'a>(value: &'a Value, pointer: Option<&str>) -> Option<&'a Value> {
    value.pointer(pointer?)
}
fn as_text(value: &Value) -> Option<String> {
    match value {
        Value::String(s) => Some(s.clone()),
        Value::Null => None,
        _ => Some(value.to_string()),
    }
}
fn text(value: &Value, config: &CustomSourceConfig) -> String {
    match field(value, Some(&config.text)) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|part| {
                let spec = config.text_parts.as_ref()?;
                (field(part, Some(&spec.type_key)).and_then(Value::as_str)
                    == Some(&spec.type_value))
                .then(|| field(part, Some(&spec.text_key)).and_then(Value::as_str))
                .flatten()
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}
fn timestamp(value: Option<&Value>) -> u64 {
    match value {
        Some(Value::Number(number)) => number
            .as_f64()
            .filter(|n| n.is_finite() && *n >= 0.0)
            .map(|n| {
                if n >= 100_000_000_000.0 {
                    n as u64
                } else {
                    (n * 1000.0) as u64
                }
            })
            .unwrap_or(0),
        Some(Value::String(s)) => s
            .parse::<f64>()
            .ok()
            .map(|n| timestamp(Some(&Value::from(n))))
            .or_else(|| super::common::parse_iso_millis(s))
            .unwrap_or(0),
        _ => 0,
    }
}

pub fn session_cwd(path: &Path, config: &CustomSourceConfig) -> Option<String> {
    session_field(path, config.cwd.as_deref()?)
}

pub fn session_field(path: &Path, pointer: &str) -> Option<String> {
    let file = File::open(path).ok()?;
    for line in BufReader::new(file).lines().map_while(std::io::Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let Some(value) = field(&value, Some(pointer)).and_then(Value::as_str) {
            return Some(value.to_string());
        }
    }
    None
}

fn session_id(path: &Path, config: &CustomSourceConfig) -> String {
    let stem = path
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    if config.session_id == "stem" {
        return stem;
    }
    let Ok(file) = File::open(path) else {
        return stem;
    };
    for line in BufReader::new(file).lines().map_while(std::io::Result::ok) {
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let Some(id) = field(&value, Some(&config.session_id)).and_then(as_text) {
            return id;
        }
    }
    stem
}

pub(crate) fn parse_index_records(
    path: &Path,
    source: SourceKind,
    config: &CustomSourceConfig,
    state: IndexParseState,
    include_reasoning: bool,
    next_doc_id: &AtomicU64,
    mut emit: impl FnMut(Record) -> Result<()>,
) -> Result<IndexParseOutput> {
    let mut reader = BufReader::new(File::open(path)?);
    reader.seek(SeekFrom::Start(state.offset))?;
    let mut offset = state.offset;
    let mut turn_id = state.turn_id;
    let mut diagnostics = ParseDiagnostics::default();
    let session_id = session_id(path, config);
    let cwd = session_cwd(path, config);
    let project = cwd
        .as_deref()
        .map(super::common::project_from_path)
        .unwrap_or_else(|| source.label().to_string());
    let source_path = path.to_string_lossy().into_owned();
    let mut line = Vec::new();
    loop {
        let start = offset;
        line.clear();
        let bytes = reader.read_until(b'\n', &mut line)?;
        if bytes == 0 {
            break;
        }
        offset += bytes as u64;
        let value: Value = match serde_json::from_slice(&line) {
            Ok(value) => value,
            Err(_) if !line.ends_with(b"\n") => {
                offset = start;
                break;
            }
            Err(_) => {
                diagnostics.malformed_json_lines += 1;
                continue;
            }
        };
        if !value.is_object() {
            diagnostics.non_object_json_lines += 1;
            continue;
        }
        let role_value = field(&value, Some(&config.role))
            .and_then(Value::as_str)
            .unwrap_or("");
        let role = config
            .roles
            .get(role_value)
            .map(String::as_str)
            .unwrap_or(role_value);
        let body = text(&value, config);
        let ts = timestamp(field(&value, config.ts.as_deref()));
        let event_id = field(&value, config.id.as_deref()).and_then(as_text);
        let parent_id = field(&value, config.parent.as_deref()).and_then(as_text);
        let links = RecordLinks {
            event_id: event_id.clone(),
            parent_event_id: parent_id,
            conversation_kind: Some("main".into()),
            ..RecordLinks::default()
        };
        let mut push = |role: &str,
                        body: String,
                        tool_name: Option<String>,
                        tool_input: Option<String>,
                        tool_output: Option<String>,
                        links: RecordLinks|
         -> Result<()> {
            emit(Record {
                source,
                doc_id: next_doc_id.fetch_add(1, Ordering::SeqCst),
                ts,
                project: project.clone(),
                session_id: session_id.clone(),
                turn_id,
                role: role.into(),
                text: body,
                tool_name,
                tool_input,
                tool_output,
                links,
                source_path: source_path.clone(),
            })?;
            turn_id += 1;
            Ok(())
        };
        if !role.is_empty() && !body.trim().is_empty() {
            let name = field(&value, config.tool_name.as_deref()).and_then(as_text);
            let input = field(&value, config.tool_input.as_deref()).and_then(as_text);
            let output = (role == "tool_result")
                .then(|| field(&value, config.tool_output.as_deref()).and_then(as_text))
                .flatten();
            push(role, body, name, input, output, links.clone())?;
        } else if role.is_empty() {
            let metadata = config
                .metadata
                .iter()
                .filter_map(|pointer| {
                    field(&value, Some(pointer))
                        .and_then(|value| match value {
                            Value::Array(values) => Some(
                                values
                                    .iter()
                                    .filter_map(Value::as_str)
                                    .collect::<Vec<_>>()
                                    .join(", "),
                            ),
                            _ => as_text(value),
                        })
                        .filter(|s| !s.is_empty())
                        .map(|s| format!("{}: {s}", pointer.trim_start_matches('/')))
                })
                .collect::<Vec<_>>()
                .join("\n");
            if !metadata.is_empty() {
                push("metadata", metadata, None, None, None, links.clone())?;
            }
        }
        if include_reasoning
            && role == "assistant"
            && let Some(reasoning) = field(&value, config.reasoning.as_deref())
                .and_then(Value::as_str)
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
        if let Some(Value::Array(calls)) = field(&value, config.tool_calls.as_deref()) {
            for call in calls {
                let name = field(call, config.tool_call_name.as_deref())
                    .and_then(as_text)
                    .unwrap_or_else(|| "tool".into());
                let input = field(call, config.tool_call_input.as_deref())
                    .and_then(as_text)
                    .unwrap_or_default();
                let mut call_links = links.clone();
                call_links.event_id = field(call, config.tool_call_id.as_deref()).and_then(as_text);
                call_links.parent_event_id = event_id.clone();
                call_links.source_tool_use_id = call_links.event_id.clone();
                push(
                    "tool",
                    format!("{name} {input}"),
                    Some(name),
                    Some(input),
                    None,
                    call_links,
                )?;
            }
        }
    }
    Ok(IndexParseOutput {
        offset,
        turn_id,
        legacy_turn_id: None,
        pending_tool_calls: state.pending_tool_calls,
        session_id: Some(session_id),
        diagnostics,
        session_cwd: cwd,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (CustomSourceConfig, PathBuf) {
        let config: crate::config::UserConfig =
            toml::from_str(include_str!("../../fixtures/custom/config.toml")).unwrap();
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/custom/session.jsonl");
        (config.custom_sources.into_iter().next().unwrap(), path)
    }

    #[test]
    fn parser_version_ignores_role_map_insertion_order_but_tracks_changes() {
        let (mut config, _) = fixture();
        config.name = "role-order-fixture".into();
        config.roles.clear();
        config.roles.insert("human".into(), "user".into());
        config.roles.insert("bot".into(), "assistant".into());
        register(std::slice::from_ref(&config)).unwrap();
        let source = kind(&config.name).unwrap();
        let original = super::super::index_state_version(source);
        config.roles.clear();
        config.roles.insert("bot".into(), "assistant".into());
        config.roles.insert("human".into(), "user".into());
        register(std::slice::from_ref(&config)).unwrap();
        assert_eq!(super::super::index_state_version(source), original);
        config.roles.insert("bot".into(), "tool_result".into());
        register(std::slice::from_ref(&config)).unwrap();
        assert_ne!(super::super::index_state_version(source), original);
    }

    #[test]
    fn custom_fixture_maps_pointers_parts_timestamps_and_resumes() {
        let (config, path) = fixture();
        register(std::slice::from_ref(&config)).unwrap();
        let source = kind(&config.name).unwrap();
        let next_id = AtomicU64::new(1);
        let mut records = Vec::new();
        let output = parse_index_records(
            &path,
            source,
            &config,
            IndexParseState::default(),
            false,
            &next_id,
            |record| {
                records.push(record);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(output.diagnostics.malformed_json_lines, 1);
        assert_eq!(output.session_cwd.as_deref(), Some("/work/demo"));
        assert_eq!(records.len(), 3);
        assert!(
            records
                .iter()
                .all(|record| record.session_id == "configured-session" && record.source == source)
        );
        assert_eq!(records[0].ts, 1_780_000_000_250);
        assert_eq!(records[1].ts, 1_780_000_001_250);
        assert_eq!(records[1].text, "array content");
        assert_eq!(records[1].links.parent_event_id.as_deref(), Some("a"));
        assert_eq!(records[2].ts, 1_779_926_402_000);
        assert_eq!(records[2].role, "tool_result");
        assert_eq!(records[2].tool_output.as_deref(), Some("tool output"));
        assert_eq!(session_field(&path, "/agent").as_deref(), Some("testbot"));
        let user_config: crate::config::UserConfig =
            toml::from_str(include_str!("../../fixtures/custom/config.toml")).unwrap();
        let template = crate::resume::resume_template(&user_config, source, false).unwrap();
        let source_path = path.to_string_lossy();
        let source_dir = path.parent().unwrap().to_string_lossy();
        let command = crate::resume::expand_resume_template(
            &template,
            &crate::resume::ResumeSession {
                source,
                session_id: "configured-session",
                project: "demo",
                source_path: &source_path,
                source_dir: &source_dir,
            },
            "/work/demo",
        );
        assert!(command.starts_with("cd '/work/demo' && fixture --agent 'testbot' --resume '"));
        assert_eq!(SourceKind::from_label("fixture-agent"), Some(source));
        assert_eq!(serde_json::to_string(&source).unwrap(), "\"fixture-agent\"");
        assert_eq!(
            serde_json::from_str::<SourceKind>("\"fixture-agent\"").unwrap(),
            source
        );

        let temp = tempfile::tempdir().unwrap();
        let appended = temp.path().join("session.jsonl");
        std::fs::copy(&path, &appended).unwrap();
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&appended)
            .unwrap();
        file.write_all(
            b"{\"message\":{\"role\":\"bot\",\"content\":\"next\"},\"ts\":1780000003}\n",
        )
        .unwrap();
        let mut incremental = Vec::new();
        let output2 = parse_index_records(
            &appended,
            source,
            &config,
            IndexParseState {
                offset: output.offset,
                turn_id: output.turn_id,
                ..IndexParseState::default()
            },
            false,
            &next_id,
            |record| {
                incremental.push(record);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(incremental.len(), 1);
        assert_eq!(incremental[0].turn_id, 3);
        assert_eq!(incremental[0].session_id, "configured-session");
        assert_eq!(output2.offset, std::fs::metadata(&appended).unwrap().len());

        let mut with_reasoning = Vec::new();
        parse_index_records(
            &path,
            source,
            &config,
            IndexParseState::default(),
            true,
            &next_id,
            |record| {
                with_reasoning.push(record);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(
            with_reasoning
                .iter()
                .filter(|record| record.role == "reasoning")
                .count(),
            1
        );
    }
}
