CREATE TABLE conversations (
    conversation_id TEXT PRIMARY KEY NOT NULL,
    title TEXT,
    workspace_id BIGINT NOT NULL,
    context TEXT,
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP,
    metrics TEXT
);
INSERT INTO conversations VALUES (
    'malformed-session', 'Malformed row', 1, '{bad',
    '2026-10-01 12:02:00', NULL, NULL
);
INSERT INTO conversations VALUES (
    'forge-session', 'Fix the build', 1,
    '{"conversation_id":"forge-session","messages":[{"message":{"text":{"role":"System","content":"System instructions"}}},{"message":{"text":{"role":"User","content":"Fix the build"}}},{"message":{"text":{"role":"Assistant","content":"Checking now","tool_calls":[{"name":"shell","call_id":"call-1","arguments":{"cwd":"/work/project","command":"cargo check"}}]}}},{"message":{"tool":{"name":"shell","call_id":"call-1","output":{"is_error":false,"values":[{"text":"Finished"}]}}}},{"message":{"text":{"role":"Assistant","content":"Build passed"}}},{"message":{"future_variant":{"data":"ignored"}}}]}',
    '2026-10-01 12:00:00.000000000', '2026-10-01 12:01:00.000000000',
    '{"started_at":"2026-10-01T12:00:00Z","files_changed":{}}'
);
