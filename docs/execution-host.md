# Execution hosts

Memex can operate a separately running execution host from the native app, its responsive web interface, and the opt-in control MCP. The host retains the existing SQACPHost provider transports and Rust runtime while viewing clients disconnect. Closing a browser or detaching the native viewer does not interrupt its provider process. Stopping the host process does.

The historical index, native transcript ownership, retrieval MCP, and machine-federated search remain separate. A configured retrieval machine is **not** permission to execute on that machine.

## Start and pair

Build `MemexExecutionHost` with the same `MEMEX_AGENT_RUNTIME_ROOT` and matching `MEMEX_AGENT_RUNTIME_LIBRARY` used by the native app. It is a Swift package executable product alongside `Memex`. A build without SQACPHost reports that runtime execution is unavailable. It never substitutes simulated provider output.

Run it on the execution machine, granting each workspace explicitly:

```sh
MemexExecutionHost --root /Users/me/.memex --workspace /Users/me/Code/project
memex web --listen 127.0.0.1:6363
```

The root defaults to `~/.memex`. Repeat `--workspace` for additional folders. The host will not create or operate conversations outside those registered folders. Removing a workspace from the startup arguments revokes its execution grant, including old schedule entries. Provider binaries are resolved from the host's `PATH`; Codex keeps `CODEX_HOME`, Claude keeps `CLAUDE_CONFIG_DIR`, and Claude additionally requires `MEMEX_CLAUDE_HELPER` pointing at the packaged SDK helper. These are host-local settings and are not accepted from remote clients.

The host creates `state/execution/` with mode 0700, an owner-only Unix socket, a stable host identity, and `control-token` with mode 0600. The token is an execution pairing credential. Obtain it locally on the execution machine and enter it in **Execution hosts** in the native app or **Active conversations** in the web UI. Do not send it as conversation context. Native pairings store the token in Keychain. The web client retains it in the current tab's session storage; drafts and outgoing intents are saved separately in local storage.

For access from another machine, use HTTPS at a trusted reverse proxy or an SSH tunnel to the loopback web server. The server continues to reject unauthenticated control requests and non-loopback direct listeners. With a TLS reverse proxy, keep its upstream HTTP Host header pointed at the loopback listener and start the web server with `MEMEX_CONTROL_PUBLIC_ORIGIN=https://your-exact-host.example`. This grants that exact HTTPS browser origin access to the control route only; it never trusts request-supplied forwarded headers, and the execution bearer token is still required. An SSH tunnel needs no origin configuration. Never expose the Unix socket or disable these checks. A mobile browser can use the same HTTPS web UI; it has the create/read/send/stop/queue/configuration/approval and schedule controls.

In the native pairing form, enter the **exact Memex machine identifier** used by the historical record, plus the gateway URL and execution token. Remote resume verifies host identity, provider, native session ID, exact transcript path, and original workspace before connecting. A native ID alone is insufficient. Local source files and executables are never opened by the remote adapter.

## Delivery and recovery

Every mutation has a client-generated `commandId`. The host persists the exact request before crossing a provider boundary. Retrying that ID with the same request returns the existing receipt; changing its contents is an error. Keep the original `issuedAt` as well as the command ID when retrying provider commands.

Native and web clients persist outgoing requests before network dispatch. A timeout leaves that request available for inspection and exact retry. A host receipt marked `completed` means the host operation was accepted, not that the agent's turn finished. The `deliveries` and runtime turn snapshot establish provider acknowledgement and terminal status.

After a host restart, sessions remain disconnected until explicitly resumed, undispatched queues are held, and a command that crossed the provider boundary without a recorded outcome is marked uncertain. Resuming the queue only rearms held, undispatched entries. It does not replay uncertain entries. Stop holds the queue even if the provider rejects interruption. Provider-native history remains the evidence for resolving an uncertain send.

Schedules use the same durable queue and provider dispatch as interactive messages. CRUD, pause/resume, and run-now are available through the native connection view, web UI, and control API. Choose either an interval of 60 seconds to one year (with an optional first run timestamp), or a fixed local `HH:mm` time on selected ISO weekdays (Monday 1 through Sunday 7) in an explicit timezone. The saved timezone governs execution even when the host or viewer changes its system timezone. Editing a prompt without changing recurrence preserves its due time and paused state.

Missed intervals coalesce into one occurrence. For local-time schedules, a time that does not exist during a spring daylight-saving transition is skipped; an autumn repeated time runs only at its first occurrence. A local-time occurrence missed by at least 60 seconds is skipped and recorded in `lastSkippedAt`, with the next run recomputed in its timezone. It is never replayed as a catch-up burst. Held queues and disconnected sessions prevent provider delivery until resumed. Schedule run-now uses the same durable queue and does not silently release a held queue.

## Managed worktrees

The native host view, web client, and control MCP expose worktree creation, listing, archive, reattachment, and clean-checkout removal. Creation requires the exact root of a repository already granted by `--workspace`; a grant to a nested project folder does not grant the rest of its repository. The caller selects an existing `baseRef`, or leaves it empty to use the repository's recorded remote default. The host creates a unique branch and checkout below its private execution state directory. The source checkout's dirty, untracked, and ignored files are never copied, stashed, reset, or committed.

Created worktrees appear in `workspace.list` and can be passed as `workspaceId` when creating a hosted conversation. This derived authority depends on the original repository grant and a verified host-owned manifest and Git relationship. Removing the parent repository from startup grants prevents new execution or lifecycle mutations through its managed worktrees. No method accepts an arbitrary destination path or adopts an unrelated directory as host-owned.

Archive hides the workspace from the new-conversation picker and retains all files, including dirty and ignored content. Existing conversations retain their original location. Reattach unhides an existing checkout without resetting files, or recreates a removed clean checkout from its retained branch. Cleanup refuses any retained hosted conversation referencing the checkout, even when disconnected, as well as staged, unstaged, untracked, ignored, symlink-replaced, foreign, or locked worktrees. Cleanup leaves the branch, commits, and ownership record for reattachment. It never removes native provider history. Failed preparation retains its manifest and any created resources for inspection. Worktree mutations use the same durable command receipts and uncertain-outcome handling as provider commands.

Fork and delegate currently use an explicitly labeled **context handoff** into a newly created native conversation. They retain the parent relationship and do not claim to clone provider-native history or merge Git branches. The original session remains untouched.

## API

POST `/api/control` with `Authorization: Bearer <control-token>` and a JSON envelope:

```json
{"id":"client-request-id","method":"conversation.send","params":{"hostId":"paired-host-id","conversationId":"host-thread-id","commandId":"stable-command-id","issuedAt":"2026-10-05T12:00:00Z","text":"Inspect the current change"}}
```

Responses contain the same `id` and either `result` or `error: {code,message}`. `host.info` discovers the host ID and capabilities. Every other method requires the exact `hostId`. Existing history cookies, bootstrap sessions, OAuth retrieval tokens, and the history bearer token never authorize this endpoint.

| Methods | Parameters beyond `hostId` |
| --- | --- |
| `host.info` | None |
| `workspace.list` | None; returns startup-registered roots and active host-owned worktrees derived from those grants |
| `worktree.list` | Optional startup repository `workspaceId`; returns owned active/archived/removed/failed records and `referencedBy` hosted conversation IDs |
| `worktree.create` | `commandId`, startup repository `workspaceId`, optional existing `baseRef`; generated destination and branch only |
| `worktree.archive` | `commandId`, `worktreeId`, optional `archived` (defaults true); retains all files |
| `worktree.reattach` | `commandId`, `worktreeId`; restores the retained branch if clean checkout was removed, otherwise preserves existing files |
| `worktree.cleanup` | `commandId`, `worktreeId`; refuses retained conversation references and all dirty/ignored files, retains branch and manifest |
| `conversation.list` | None |
| `conversation.create` | `commandId`, `provider`, `workspaceId`, optional `title`; never sends the first prompt |
| `conversation.import` | `commandId`, `provider`, `nativeSessionId`, `sourcePath`, `workspaceId`, optional `title`; source must be an existing native JSONL transcript inside the configured provider home |
| `conversation.resume` | `commandId`, `conversationId` |
| `conversation.read` | `conversationId` |
| `conversation.wait` | `conversationId`, optional `afterSequence`, `timeoutSeconds` (maximum 30) |
| `conversation.send`, `.steer`, `.interrupt`, `.model`, `.configuration`, `.approval`, `.userInput` | `commandId`, `issuedAt`, `conversationId`; `text`, `optionId`, `requestId`, `promptContent` as appropriate |
| `conversation.queue.add` | Same prompt fields as send |
| `conversation.queue.list` | `conversationId` |
| `conversation.queue.edit`, `.cancel`, `.promote` | `commandId`, `conversationId`, `queuedCommandId`; edit also takes `text` |
| `conversation.queue.reorder` | `commandId`, `conversationId`, every undispatched `commandIds` exactly once |
| `conversation.queue.resume` | `commandId`, `conversationId`; uncertain entries stay held |
| `conversation.fork`, `.delegate` | `commandId`, parent `conversationId`, optional `title`, `provider`, `workspaceId`, `text` |
| `command.read` | Original `commandId` |
| `schedule.list` | None |
| `schedule.upsert` | `commandId`, `scheduleId`, `conversationId`, `text`, optional `paused`; either `intervalSeconds` plus optional `nextRunAt` (RFC3339), or `wallClock: {localTime:"09:00", weekdays:[1,2,3,4,5], timeZone:"America/Los_Angeles"}` |
| `schedule.pause` | `commandId`, `scheduleId`, `paused` |
| `schedule.delete`, `schedule.run` | `commandId`, `scheduleId` |
| `browser.describe` | `conversationId`; requires attached desktop and explicit per-chat browser grant |
| `browser.dispatch` | `commandId`, `conversationId`, `request` containing the exact desktop host/grant/chat/tab identities returned by describe |

Conversation catalog response fields retain Swift identity names (`nativeSessionID`, `providerInstanceID`, `workspaceID`). Request parameter names use `nativeSessionId` and `workspaceId`. A read returns `{conversation,thread,presentation,operations,ready,connected,running,actions,controls,deliveries,queue,queueHeld,warning}`. `presentation` is the existing lossless conversation service representation, while `thread` is the Rust runtime projection. Do not concatenate them as duplicate transcripts.

Control request bodies are limited to 4 MiB, responses to 32 MiB, socket concurrency to eight requests. Long polling is bounded and does not hold the host state lock while waiting. Unsupported provider actions return an explicit failure; provider capability lists govern which controls are enabled.

## Control MCP and browser boundaries

`memex-control --root /Users/me/.memex` is a separate, opt-in stdio MCP server. Starting it grants the caller same-user execution authority over that root. Its `control` tool accepts the method and params above. The ordinary `memex mcp` server remains retrieval-only.

The native app may attach `desktop.sock` under the same private execution directory. Browser operations are limited to app-owned tabs with an explicit live UI grant. Grants are scoped to the desktop instance, exact conversation, tab, and capability, and do not survive app restart. `browser.describe` reveals no ungranted tabs. The execution host derives the exact native conversation key rather than accepting an arbitrary application target. Browser actions have durable host command receipts; unknown outcomes are not automatically retried. There is no general-purpose remote application or shell-control endpoint.

## Verification

The focused regression suites are `MemexExecutionHostCoreTests` (including `HostWorktreeTests` and `HostWallClockScheduleTests`), `ExecutionHostAdapterTests`, Rust `execution_host` tests, and `web/tests/execution.spec.ts`. They cover stable IDs, namespace/workspace boundaries, duplicate creation/send, stop-held queues, uncertain-delivery recovery, interval coalescing, local weekdays/timezones and DST, worktree ownership/cleanup/reattachment, private pairing token requirements, pre-fetch web outbox persistence, first-send configuration, and mobile controls. Tests use disposable Git repositories, real runtime imports, loopback HTTP and private socket fixtures, and fake execution providers. They do not establish successful execution against an installed provider. A real-provider execution smoke check has not yet been performed.
