# Conversations and workspace tools

In-app execution requires the [optional runtime](RUNTIME.md). History browsing,
exact transcript Find, raw evidence, external resume, files, browser tabs, and
terminals remain available in the history-only build. Historical ingestion
support does not imply that a provider can be launched.

## Start and compose

Choose a provider and project on Home. A projectless conversation receives a
retained private folder. Existing projects can use their current folder or a new
Git worktree from the selected local ref; uncommitted source files are not copied.

Choose **Model and permissions…** in the composer's provider menu to open an unsent
conversation and inspect its actual settings. The **+** button attaches files;
the chooser and file/image paste or drop also open an unsent draft. The normal Home
send applies saved provider-specific choices before sending; an unconfirmed setting retains the
draft for inspection. Settings are only exposed when the provider supplies them.

Inside a conversation, the composer supports captured file and image attachments,
file/chat context, provider commands, local skills, prompt recall, and saved
prompt stashes. Terminal output, file contents, diff review, and browser context
can also be added from their workspace panes. Captured context is saved as bytes,
so a later change to the original file does not change a queued prompt.

Automatic file and skill discovery uses the local conversation's workspace and
provider home. A remote or server-owned conversation never treats its path strings
as local files; deliberately choosing a local attachment remains an upload.

## Follow-ups and recovery

While the agent works, prepare a draft, queue it, or steer if supported. Queue
controls can edit, reorder, cancel, and promote a queued prompt. Stop holds the
queue while requesting native cancellation, with acknowledgement errors and a
timeout shown explicitly. A terminal snapshot settles the stopping state.

Outgoing intent is persisted before dispatch. A crash or missing acknowledgement
does not silently turn an uncertain command into a new send. Inspect native
history and the retained request before explicitly resolving uncertainty. Reconnect
does not automatically replay it. Queued but undispatched work stays held after
recovery until explicitly resumed.

Approvals retain native decision IDs and details. Structured questions preserve
their explanatory choices and support single choice, multiple selection, and
custom answers as advertised by the provider. Stale/disconnected request controls
are disabled. Unsupported actions are not presented as universal capabilities.

Use **Back** and **Next** to review pending questions; changing steps preserves each
question's draft and does not send it. **Submit answer** replies only to that
question's original native request. **Attach text files to answer…** captures up to
10 UTF-8 files totaling 1 MB and includes their actual contents in the answer,
including when the files later change. Question drafts and these attachments stay
in the open viewer until submitted; they are not recovered after app restart.
Images, audio, video, PDF and binary answer attachments are rejected because the
current native question transports accept strings, not media blocks. Attach media
to a separate prompt instead. Codex, Claude SDK and the current ACP bridge expose
no independent asynchronous-question dismissal operation, so **Stop conversation**
remains an interruption action and is not presented as dismissing one question.

## Providers and related work

Built-in local execution uses Codex's app server and Claude Code's SDK. **Configure
providers…** adds an ACP stdio executable, arguments, and its original home. ACP
resume/configuration support is negotiated; ACP steering is not advertised.
The original launch identity remains associated with a created conversation even
if the editable provider catalog changes.

Plans show native steps and status. **Refine** and **Implement** attach the plan to
the current draft; **Implement in new conversation…** prepares a new draft with
the selected plan and captured source context. None of these actions auto-sends.
The live agent roster uses native child status and opens indexed child/parent
conversations on the same host. An unindexed child remains visibly unavailable.

The **Conversation** menu offers native fork/rewind when supported and idle, plus
**Branch with context…** for a provider transition or context branch. Branches
retain parent/child navigation. **Add context to parent draft** preserves the
parent's unsent text. Context transfer does not merge Git branches. Interrupted
history mutations retain an inspection marker instead of being blindly retried.

## Organize conversations

Use row menus or multi-selection for rename, pin, archive, restore, and **Remove
from Memex…**. Find removed and archived conversations in the sidebar's ellipsis menu;
these actions do not delete provider logs or workspace data. Manual reordering
preserves hidden rows and does not replace relevance ordering during search.

Notification preferences control completion/input alerts and sound. They are
opt-in and require macOS permission. A notification opens the exact conversation.
Quitting warns before ending active app-owned agents or live shells; independently
running execution-host sessions are detached from the viewer.

## Projects, files, and changes

**Add New Project** supports an existing folder, named new repository, or clone.
Project controls can reuse a checkout and explicitly run its setup script. Failed
setup/clone state retains its files for inspection and retry. Managed worktree
archive/reattach and cleanup check ownership, references, and dirty state.

**Files** browses the workspace, creates files/folders, edits UTF-8 text, and
previews supported Markdown, HTML, delimited data, images, PDF, audio, and video.
Edits have durable drafts and an explicit Save. Saving checks the loaded file
version; an external edit opens a comparison instead of silently overwriting it.
HTML previews do not enable script execution. Symlinks and traversal cannot be
used to edit outside the selected workspace.

**Changes** offers current, branch, and checkpoint comparisons with unified/split
display and review context capture. Its **Git** menu commits explicitly staged
changes, pushes the chosen branch, and creates a draft pull request through the
configured GitHub CLI. It does not automatically stage all files or merge PRs.

Checkpoints capture raw working-file bytes and the index, including before/after
observed local turns. Conversation rewind and file restore are separate actions.
File restore requires an owned isolated worktree, no active work, and safe path
checks; it saves a recovery snapshot before modifying files. It does not run Git
clean/smudge filters or replace overlapping ignored files.

## Browser and terminals

Browser tabs retain per-conversation state. Context controls capture selected
text, page information, annotations, or screenshots into the draft. Agent browser
access requires an explicit live grant for app-owned tabs; JavaScript evaluation
has a separate grant. Grants do not survive app restart. See the [execution-host
boundary](../../docs/execution-host.md#control-mcp-and-browser-boundaries) for the
remote bridge.

Each canonical local workspace has a terminal group. Add independent shells,
switch or split them, move the same group between drawer and side pane, and save
scrollback snapshots. Close/restart confirms when a shell is live. Switching chats
or hiding a pane preserves the processes; restarting the app preserves saved
snapshots, not the previous shell process. Remote paths cannot spawn local shells.

## Remote clients and schedules

[Execution hosts](../../docs/execution-host.md) provide separately authenticated,
service-owned sessions, a native viewer, responsive web/mobile controls, interval
schedules, and a distinct opt-in control MCP. The existing retrieval MCP keeps its
retrieval authority. Remote capabilities depend on the actual host/provider and
desktop browser grant. Native-only workspace tools are not advertised as remote
filesystem or arbitrary application access.
