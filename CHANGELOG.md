# Changelog

All notable behavior and architecture changes to Limare are recorded here. Entries before the 2026-10-09 identity cleanup use the old names (Minis Mac, MinisMac, org.openminis.MinisMac) as they were at the time.

## Unreleased

## 0.1.1 — 2026-10-16

- Pass connected MCP servers' initialize instructions into model requests, including deferred tools, with a per-server 4,096-character bound.
- Launch configured stdio MCP servers with the user's normal rights so they can access their own configuration and logs.
- Run Full access and approved escalated shell commands without the shell sandbox.
- Bound output-pipe draining to two seconds after a command exits, even when escaped descendants keep a pipe open.
- Isolate development builds from the public Sparkle feed and show their source identity.
- Select helper signing by build channel and explicitly preserve the release channel during nested Developer ID signing.
- Align the website's new-conversation state and download status with the native app.


### Daily-use fixes from the website-build conversation (2026-10-13)

- `file_list` lists images, PDFs and other binary files. They were hidden, so a folder of screenshots looked empty although `file_read` opens images. Only content search still skips binary files.
- `file_search` given a file path searches that file, as grep and rg do. It returned no results, so searching the plan for "6.5" or "K1" found nothing.
- Closing the Files tab forgets the file it showed; opening Files again shows the tree alone. It used to come back with the last file open.
- A file card for a file registered from the workspace opens the file itself while it is still there, as a file link does in Codex: the same tab as the tree's, with the current content. The stored copy opens only once the file is gone. It used to open the copy in a second tab with the same name.
- A message sent while a run is working is framed for the model as Claude Code frames a queued message ("The user sent the following message while you were working … Please address this message and continue with your tasks."), so the model answers it and goes on. Asked "how far along are you?", the model reported progress and ended the run. The message is marked `sentWhileWorking`; the transcript shows the user's own words.
- The agent prompt adds Claude Code's rule on reporting outcomes faithfully: a check that was not run is reported as not run, not as passed.
- "Ask for approval" follows Codex's on-request policy: a shell command runs in the sandbox without asking, and only a command that asks to run outside it (`require_escalated`) waits for approval. The command-text heuristics (`sudo`, `rm -rf`, `curl`… marked high-risk or networked) are gone; an escalation is shown as high-risk because it leaves the sandbox. The sandbox's writable folder is the workspace, as Codex's writable root is the session's working directory, not each command's `cwd`, which every command used to be approved for. The Permissions page takes its descriptions from the modes themselves.
- The built-in browser opens local files, as a browser does: `file://` URLs, absolute paths and `~/` paths, from browser_use or the address bar. WebKit may read the file's folder, so a built page finds its scripts and styles; folders, missing files and Limare's reserved paths are refused. It used to refuse everything but http and https.
- The shell sandbox follows Codex further. Full access and an approved `require_escalated` command run outside the sandbox, as Codex's danger-full-access and escalations do: they may open apps and URLs (`open http://localhost:5173`), use AppleScript and other macOS services, not only write anywhere. Only the denials on Limare's reserved paths stay; the Keychain is guarded by its own access control. The sandbox itself allows inbound network, as Codex's network policy does, so a dev server can listen: `vite` and `python -m http.server` failed with `listen EPERM`, and in Full access `open` and `osascript` failed, so Limare could not show the user a page it built.
- Compact command, as Claude Code's `/compact`: type `/compact` in the composer, or choose Compact Conversation in the conversation's menu. The conversation's model writes a summary of everything so far; later requests send that summary instead of the whole history, and the transcript is unchanged. It reuses automatic compaction's summarizer, validation and derived state, forced to one stage up to the latest message, with 5 minutes and 4,000 output tokens for the summary; a deterministic summary stands in if the model's is rejected. Automatic compaction only starts near the context window, which for a 1M-token model left a 145K-token conversation resent in full on every request. A banner shows progress and the token estimate before and after.
- While the model has not answered yet, the spinner says which model it is waiting for and for how long, and after a failed attempt (an HTTP 524 from a relay, a dropped connection) that it is retrying, with the reason and the attempt, as Claude Code's and Codex's status lines do. A relay taking two minutes per request and timing out with 524 looked like Limare had hung: only a spinner showed, while it retried in silence.

### Daily-use fixes from the website-plan conversation (2026-10-13)

- Shell commands and stdio MCP servers run with the user's login-shell PATH, read once from `$SHELL -l -i` at launch (as VS Code and Zed do). An app opened from the Dock only has `/usr/bin:/bin:/usr/sbin:/sbin`, so Homebrew tools such as node looked uninstalled. The hardcoded PATH additions for MCP servers are gone.
- The command sandbox can write `/tmp` as well as `$TMPDIR`, as in Codex's workspace-write roots; zsh writes here-documents under `/tmp`, so every `<<EOF` failed.
- A provider request that cannot reach the server (a TLS handshake cut by a proxy, a DNS or connection failure) is retried with backoff, up to five attempts, before the run fails. Only a bad URL or a rejected certificate fails at once.
- When the model's compaction summary request fails, the remaining compaction stages of that pass use the deterministic summary instead of asking the provider again. Each failed request has already been retried five times with backoff, so against a failing server a three-stage compaction made 15 requests and waited about 22 seconds before the turn's own request was sent; it now makes 5.
- The default output limit is 32,000 tokens (opencode's `OUTPUT_TOKEN_MAX`), still capped by the model's own limit. At 16,384 a thinking model writing a long file ran out mid-call and the tool reported malformed arguments. The finish reason of each request is recorded with its timing.
- `file_read` on an image file returns the image, scaled like a chat attachment, instead of "not valid UTF-8". A vision model sees it inline; other models get the reference `read_image` takes.
- Ordered list numbers render as `1.` in the text's own size instead of filled number circles (a change to the vendored MarkdownView).
- The Work Surface can expand to fill the window: the button at the end of its tab strip hides the chat column and the sidebar, and restores them.
- Fixed a crash under memory pressure (seen 2026-10-13 with Limare in the background): MarkdownView's caches of rendered text were cleared by `LRUCache` on a global queue, releasing text attachments off the main actor. They are now cleared on the main queue.
- The shell sandbox's write limit follows the permission decision, as in Codex. In Full access a command may write anywhere (it could not rename files on the Desktop, or compile with swiftc, whose module cache lives in `~/.cache`). In the other modes `shell_execute` takes Codex's `sandbox_permissions: "require_escalated"` with a `justification`; once approved, that command may write anywhere too. In every mode the sandbox still denies Limare's reserved paths, Keychain IPC and other macOS services.
- `file_write` outside the project into folders that do not exist yet creates them. It used to fail with "目录 … 已被移动或替换", because the missing parent itself was taken as the anchor.

### Third-party notices in the app (2026-10-12)

- Limare.app now carries the license and NOTICE texts of everything it ships in `Contents/Resources/Credits.html`, shown under Limare > About Limare. A build phase (`script/bundle_notices.py`) collects them from Limare's LICENSE, the vendored `deps/` packages, every pinned Swift package checkout, `LICENSES/`, the bundled helpers and the Remote Access web vendor files, and fails the build when a component has no license file.
- `deps/OpenMinisProviders/LICENSE` is the OpenMinis GPL-3.0 license, byte-identical to upstream.

### Browser tabs per conversation (2026-10-09)

- Each conversation now owns its own dedicated browser tab and `WKWebView` instance, replacing the global singleton browser runtime. Different conversations and research subagents can browse concurrently without interference, page clearing, or cross-conversation handover.
- All browser tabs share `BrowserWebsiteDataStore.shared`, ensuring that websites authenticated in one conversation remain logged-in across all conversations, even after individual tabs are closed, cleared, or evicted.
- Introduced LRU idle tab eviction with a ceiling of `maxLiveTabs = 6` to manage WebContent process memory safely. Running conversations, tabs under active user control, and the currently displayed tab are strictly protected from eviction.
- The right-hand browser work surface projects the active conversation's tab automatically, seamlessly following conversation switching. Entering a URL in the empty state immediately creates a user-controlled tab for that conversation.
- When an evicted or cleared tab is accessed again, a fresh blank tab is provided with a one-time notice (`Your previous browser page was closed (<reason>)...`), keeping agents informed of lifecycle changes without altering the `browser_use` tool signature.

### Remove experimental isolated execution (2026-10-09)

- Removed the hidden isolated execution switch, project working copies, sandboxed primary shell execution and result delivery. The feature was disabled by default and had no settings entry; project conversations now always use the existing direct execution behavior.
- Last-message retraction, archived draft recovery, anchored file writes and file-tool undo remain available. Existing isolated storage is neither read nor created and may be removed manually.

### Memory review fixes (2026-10-09)

- A missing GLOBAL.md now projects as empty memory with write guidance, so the next file write can recreate it without restarting Limare. Invalid UTF-8 and other unreadable-file errors still fail closed.
- Memory contents and date are captured once at run admission and reused across that run's provider requests. Writes become visible in the next run, avoiding memory-driven changes to the system prompt within a reply; write guidance still follows the actual tool list.

### Memory writes (2026-10-09)

- Every ordinary full conversation now receives persistent memory guidance, even when GLOBAL.md is empty. The agent saves and forgets facts with the existing file tools and reports success only after the write succeeds.
- GLOBAL.md and daily/ are exempt from file-tool workspace boundary approval. SOUL, avatars, shell commands and sensitive paths keep their existing approval rules; memory writes retain ordinary change recording and undo.
- Memory loads GLOBAL.md and up to three recent nonempty daily notes from disk on each request, with a 64 KB total content ceiling. GLOBAL keeps its beginning; daily notes keep their newest entries at the end.
- Removed the unreachable memory editor and switches. Old memoryEnabled records remain compatible; Native Children and text-only runs receive no memory, and startup no longer creates an empty daily note.

### Limare identity cleanup (2026-10-09)

- The app, Xcode project, scheme, targets and folders are Limare: `src/macos/Limare.xcodeproj`, scheme and target `Limare`, test targets `LimareTests` / `LimareUITests`, `App/LimareApp.swift`, `Limare.entitlements`.
- Bundle identifier `app.limare.Limare` (tests `app.limare.LimareTests` / `app.limare.LimareUITests`). Data lives in `~/Library/Application Support/app.limare.Limare` and `~/Library/Caches/app.limare.Limare`; UserDefaults keys use the `limare.` prefix; the log subsystem is the bundle identifier. Every store takes the data folder name from `LimareStorage.bundleIdentifier`.
- Runtime identifiers: attachment and artifact URIs are `limare://attachments/…` and `limare://artifacts/…`, the attachment staging folder is `.limare-input`, hook commands get `LIMARE_PLUGIN_ROOT` / `LIMARE_SESSION_ID` / `LIMARE_WORKSPACE`, converter and policy IDs use the `limare.` namespace, MCP client name and default User-Agent are `Limare`. Global skills are read from `~/.limare/skills` and `~/Library/Application Support/Limare/skills`.
- No migration: data written under the old identity (`org.openminis.MinisMac`) is not read. Limare starts as a new installation.
- The upstream OpenMinis iOS and Android apps, their native dependencies (iSH, PRoot, FFmpeg, LAME, talloc, rclone) and their build scripts are removed from this repository. `deps/OpenMinisProviders` stays as the attributed, hash-recorded extraction of upstream provider sources. The tokenizer vocabulary used by the context tests moved to `script/fixtures/cl100k_base.tiktoken`.
- `LICENSES/` holds the license texts of adapted third-party code: opencode (MIT), Codex (Apache-2.0 and its NOTICE) and SwiftAnthropic (MIT); the adapted files point to them. The 2026-09-12 Minis Mac architecture document moved to `docs/history/`; `docs/README.md` lists the current architecture references.

### Agent reliability (from the 2026-10-06 "Limare白屏问题原因调查" run)

- **The parent stays in charge of its subagents** (Codex `wait_agent`). `delegate_task` returns as soon as one task finishes or after `wait_seconds` (default 30, 0 returns at once; `background: true` still means 0), with each running task's progress: elapsed time, model requests, tool calls, how long its current model request has been waiting, its last actions and words. `delegation_control` gains `wait` (one task, or every running one, `timeout_seconds` 10–3600). The parent can then wait again, redirect, cancel, or do the work itself.
- Results nobody waits for are steered into a running parent's turn, or start a turn of an idle one; a stopped parent stays quiet. Stopping the parent while it waits cancels the tasks it waits for (Claude Code stops foreground subagents with the main agent); tasks it does not wait for carry on.
- At the time limit the final turn gets a grace that starts when its request actually goes out; a request still running at the end of the allowance gets the same grace. A child stopped without a report hands back what it did (its tool calls and last words), marked "No report" — an interim remark is never presented as a report again.
- Research subagents get `shell_execute` (git log, grep, tests) under the parent's permission rules, like Claude Code's Explore and Codex's explorer. Tool descriptions now say exactly what each role has.
- The delegation policy is Codex's spawn_agent guidance (Apache-2.0): delegate only when the user or AGENTS.md asks for subagents or parallel work; do the critical path yourself; never wait by reflex.
- The base system prompt is opencode's default prompt (MIT), plus opencode's environment block (working directory, whether it is a git repository, platform, date; no branch or git status) and its instruction files: `~/.config/limare/AGENTS.md` or `~/.claude/CLAUDE.md`, then the first of AGENTS.md / CLAUDE.md / CONTEXT.md from the working directory up to the git root.
- New `update_plan` tool and planning guidance (Codex).
- More than 15 MCP tools are deferred behind `tool_search` (Claude Code's tool search): their names are listed, `tool_search` loads the ones a task needs into the next requests.
- A denied tool call tells the model why (the user denied it, or the automatic reviewer's reason) instead of "Permission denied.".
- A tool name the turn did not offer is answered with the offered names instead of running; a known name in the wrong case is fixed (opencode's repair).
- An MCP tool call may take 300 seconds (Codex's tool timeout); the 30-second limit is now only for starting a server.
- `computer_use` waits briefly for a just-launched app's window and says how to open one when the app has none.
- Every completed provider request records `providerRequest.completed` with its time to first output, total time and token counts; `delegate_task` and `delegation_control` record their real duration.
- The Remote Bridge helper's network chatter goes to `Logs/remote-bridge-helper.log`; only its error lines reach `main.jsonl`, which no longer loses the app's history within hours.
- Removed seven stale phase and audit reports from the repository root; one of them misled the agent in that run.
- Review fixes:
  - `tool_search` clamps `max_results` to 1–50; a negative value used to crash the app.
  - Subagent results are system notices (`isSystemNotice`): steered into a running turn or starting a turn of their own, they never take over the ownership of the turn's file changes, and undo and retraction target the user's last request, not a notice. The flag is always saved; only messages saved before it existed are recognised by the `[Subagent results]` header, so a user message that starts with that text stays the user's. Undo records saved earlier that name a notice as their owner are undone with the request the notice continued.
  - A tool name repaired from the wrong case is written back to its tool-call record.
  - Instruction files are read only up to their 32 KiB cap.
  - Every provider request records how it ended: `providerRequest.completed`, or `providerRequest.ended` with `outcome` (retrying, discarded, failed, cancelled), its duration, time to first output and, for a failure, the error.

### Acceptance and accessibility (2026-10-07)

- A conversation in the sidebar, a permission mode, a Work Surface tab and a Skill row could be opened only with a pointer (a tap gesture has no accessibility action). They are buttons to accessibility now, with their title and selected state; the last user message offers "撤销这条消息" (undo), which was reachable only from a hover-only button.
- `--ui-test-storage-root <dir>` starts Limare on an isolated storage root (same checks as `UI_TEST_STORAGE_ROOT`), for background GUI drivers that pass arguments but not environment variables.
- A provider request that fails in transport records its URLError code and connection details (new or reused connection, when the request was sent, whether a response started) on `providerRequest.ended`. Two requests to the same gateway timed out at exactly 30 s on 2026-10-06 and 2026-10-07 although the session allows 180 s; the cause is unknown (direct requests were fast and replays did not reproduce it, which does not rule out the gateway); the next occurrence will say where the time went.
- Reading a file attaches the AGENTS.md / CLAUDE.md / CONTEXT.md of the directories between it and the working folder, nearest first (opencode's Instruction.resolve). A file is not attached again while the model's context still holds it: that is judged by the latest request as sent (after compaction and output reduction) plus what the run produced since, not by the saved history. Compacted away or changed, it is attached again.
- `@/path/to/image.png` (or `@~/…`) in a message attaches the image through the same intake as the file picker, when the model or a Vision Group takes images; otherwise the path stays text as typed. Names with spaces and text after the path on the same line work. The send belongs to the conversation, text and attachments the composer held when send was pressed: if any of them changes while the images are imported, nothing is sent and the imported copies are discarded; send is unavailable meanwhile.
- The transcript is a plain stack and scrolls to the bottom without animation, as Enchanted's does (Ollamac uses a List, exyte/Chat a UIKit table; none uses a lazy stack). The white screen appeared at exactly the two moments that scrolled with animation, a send and a turn folding into one row, while the lazy stack's estimated layout changed under the animation. Streaming updates cost the same (measured on copies of the three largest conversations: ~40 ms per update on the largest); opening the largest conversations takes ~0.3 s longer.
- Fallback for the 2026-10-05 white screen, whose cause is not found (not reproduced in three runs): when no part of any transcript row has been on screen for 0.75 s, without scrolling or layout changes meanwhile, the transcript view is rebuilt, as switching conversations does, and returns to the bottom or to the row being read; the scroll geometry is logged. "On screen" uses a near-zero visibility threshold, so a row taller than the viewport counts. The user's recording of 2026-10-07 17:04 showed the blank one second after a send and again when the finished turn folded into one row; the log had the detection, scrolling to a row did not bring the rows back, and switching conversations did. At most three rebuilds a minute.
- Removed the pre-subagent delegation system that nothing reached any more: `AgentSessionCoordinator`, `AgentRunStore`, `ResearchAgentPromptBuilder`, `PolicyEnforcedToolExecutor`, `AgentSessionPolicy` and the legacy `delegate_task` branch. Research runs saved by it still render from their tool output (without a Stop button; none can be running). Tests of the removed code went with it; the identity suite's delegation harness now wires native subagents, and A9/A9b pass through them.
- Steered subagent results no longer run `UserPromptSubmit` hooks (run start already skipped them for a notice).
- GUI acceptance through the real UI (cua-driver, in the background): in an isolated Project, Limare read the code, fixed the bug, ran the tests, delivered the change, and undo restored the file while the user's own uncommitted change stayed.
- The identity-suite checks deleted in 79ffc55 are back; every failure was in the test harness (missing image converter and Vision resolver, the old "Minis Mac" compactor prompt, a barrier timeout that never fired, a bypassed reviewer), and the app passes them all.

### Runtime fixes

- Production provider streaming uses explicit request/resource timeouts (180/3600 seconds); tests and custom callers can still inject their own URLSession.
- Stopped or failed parent runs stay quiet regardless of when their children finish. Results remain available in the Subagent panel and `delegation_control status`; only a new user run restores automatic delivery. Clearing or deleting the conversation clears this state.
- Subagent results leave the pending set only after their notice is persisted in the run queue. Missing model selection and queue persistence failures retain the results for the next completion or child delivery.
- Direct provider requests retry up to twice with backoff for HTTP 408/5xx, temporary 429 and connection failures, only before semantic output. `model.attempted` records the first wire dispatch of each candidate; `providerRequest.attempted` records every wire request attempt, and `providerRequest.retrying` records transport retries with the next per-request attempt number; cancellation and exhausted quota never retry. Groups with a fallback immediately return errors to the router without setting a provider cooldown; the router does not add a second retry layer.
- Models.dev uses the same app/home isolation rule for its default cache as other Limare storage. Custom cache paths keep priority; script runners cannot use the real user's default cache.

### Subagents

- Subagents now work the way they do in Claude Code, Codex and opencode. A subagent is a child conversation run by the ordinary run engine. It works in the parent's workspace, under the parent's permission mode and approval sheet, with the parent's tools for its role:
  - research: read tools, plus `browser_use` with `allow_web`;
  - coding: everything except `delegate_task`, `delegation_control` and `computer_use`, so a coding subagent edits and runs `xcodebuild` itself.
- **Removed, because none of the reference agents has them:**
  - the separate delegation grant ledger and its spawn approval and expiry;
  - role profiles;
  - the contained child shell, the Xcode refusal and the verification handoff;
  - parent accept/reject;
  - workspace, browser and desktop leases, including the "workspace occupied by another delegated attempt" refusal of the parent's own writes;
  - the command, receipt, event and attempt ledgers;
  - transport-level dispatch accounting.
- The app loses about 3,400 lines (4,251 deleted, 822 added); `SubagentCoordinator` and `SubagentStore` replace the control layer.
- `delegate_task` waits for its tasks by default and returns their results as its tool result. `background: true` returns at once, and the results are delivered to the parent later: an idle parent runs at once; a busy one gets them when its current run completes. A parent run that was stopped is not woken.
- **Each run has its own allowance** from `task_effort`: its turns, four tool calls per turn, and its seconds.
  - At the limit, the last request goes out without tools, with a final-turn instruction. The reply becomes a partial result.
  - A tool call over the allowance is refused without stopping the subagent.
  - The time limit is hard.
  - Checked on the real provider: 3 of 3 subagents at their limit wrote a text report.
- `delegation_control` offers `status`, `cancel` and `continue`. `continue` instructs a running task, or reruns a finished one with a fresh allowance. The task bar offers 查看, 取消 and 继续.
- After a restart, running tasks show as interrupted and can be continued. Tasks recorded by the earlier control layer are imported into the new task list (`subagent_tasks_v1.json`). The old ledger files are left untouched.
- Finished subagents move into a collapsed "已结束" group in the conversation's subagent bar.

### Computer Use

- Approving an app for a conversation is now the permission, as in Anthropic's computer-use tools; actions in that app are no longer classified and approved one by one. The local risk classifier, the model-declared `declared_side_effect_class`/`intent`, the per-action "Layer 3" prompts and the "Allow for this task" grants are removed. In practice, "Full Access" had still prompted 24 times, because only the Calculator keypad counted as a known-safe click.
- Every action result now carries the window's current elements with fresh references, and the next action can use them directly. The "one mutation per observation, call capture first" fence, which caused about a dozen failures, is gone (Playwright MCP works the same way).
- Password managers, Keychain, System Settings and password fields remain off limits; the result tells the model to ask the user.
  - These apps are refused before any approval is requested, so the user is never asked to allow an app Limare will not operate.
  - Keystrokes sent without an element (`type`, `type_text`, `key`, `hotkey`) go to the focused element, so Limare checks that element through Accessibility and refuses when it is a password field.
- If the window cannot be read after an action, the earlier element references are discarded and the result says to capture before the next element action.
- An app approved in a conversation stays approved until that conversation is cleared or deleted, or Limare quits. Switching to another conversation no longer clears every conversation's approvals (which also re-prompted a background run still using the app).
- Removed the unused v1 `computer_use` tool definition and the `admissionDecision` field from action results.
- A background failure now suggests retrying with `delivery_mode: foreground` instead of "foreground escalation for human review".
- Fixed: `drag` with `from_element`, which the tool description advertised, now works.
- Removed the unused v1 computer-use path (action runtime, observation runtime, provider projection, v1 models) and the computer-use fields it had added to permission requests, the approval sheet, the auto-reviewer and the permission evaluator. Net −3,591 lines.

### Storage and tests

- Only the Limare app itself uses `~/Library/Application Support/org.openminis.MinisMac`. Any other process that builds the stores without an explicit root (test binaries, XCTest) now gets a per-process temporary directory (`LimareStorage`). Before this, test runners that forgot to pass a root wrote run events into the user's data: 1,034 run-event folders with no conversation, 408 of them from test fixtures. They were moved to the Trash (`limare-orphaned-run-events-2026-10-06`).
- Deleting a conversation now also deletes its run events.
- Test runners compile the same sources as the app target through `script/app_sources.sh`, instead of each keeping its own folder or file list. The hand-kept lists had fallen behind: about 40 runners no longer compiled because `Services` had started to use `Presentation`.
- Removed historical scope gates that compared files against old baseline tags (batch A0 and A1, R5 decision, R6A contract, R3 decision) or failed whenever the working tree had uncommitted edits ("frozen" files), and fixed test call sites that predated the current hook, browser, attachment and artifact APIs.
- Tests that drive the real desktop or Xcode now run only with `LIMARE_LIVE=1`: the Calculator slices of computer-use stages 2/3/5/7/9, the XCUITest verifiers (batch B, batch C golden, batch G) and DISC-B01. Without it they report SKIP. The batch C runner no longer runs `killall -9 Limare`, which used to quit the user's running app.
- Removed the stage 0 computer-use feasibility spike runner and the built-in model catalog (`BuiltInModelCatalog`), which nothing has used since model facts come only from models.dev; their tests went with them.

### Fixes found while repairing the tests

- **Model group fallback on HTTP 429.** The router falls back to the next member at once on a rate limit, but the client first waited out the limit (60 s, then 120 s without a Retry-After header). While a group can still fall back and no tool has run in the attempt, a 429 now goes straight back to the router. A direct model keeps the retry.
- **Saved model facts.** Saving a new provider re-reads model facts from the registry and dropped facts whose origin was unknown. Facts passed explicitly when a model is created, without a source or provenance, now count as the provider's declaration and survive the save; catalog, registry and stored models are unaffected.
- **Workspace boundary for new files.** A file that does not exist yet was resolved without following symlinks, so a new file in a workspace under a symlinked path (for example `/tmp` → `/private/tmp`) looked outside the workspace and asked for approval. Paths now resolve through their deepest existing folder.

### Undo

- Undo of the last message and draft recovery are always on; the Settings › Experimental section (undo switch, isolated execution switch, undo storage row) is removed.
- Project conversations write to the project directly; file-tool changes stay undoable. The former internal isolated execution default was removed on 2026-10-09.

### Build and install

- Committed the macOS app's `Package.resolved`; Xcode builds (`script/build_and_run.sh`, `script/install_limare.sh`) use only the locked dependency versions, and a dependency changes only when that file is updated deliberately.
- Added `script/install_limare.sh`: builds a clean `limare/mainline` checkout from a fresh DerivedData, verifies the signature, quits the running app normally, moves the previous bundle to the Trash and installs to `/Applications/Limare.app` (`--launch` starts it in the background, `--build-only` builds any clean branch without installing).

### Mac conversation stability

- Treated a model's maximum output capability as a ceiling rather than the default output for every request; Chat Completions, Responses, and context budgeting now share the same effective request limit.
- Shortened oversized older tool results only in the provider working context when the protected recent turns would otherwise overflow, retaining complete conversation history and tool call identities.
- Allowed a model group to try another member after a context capacity failure before any tool side effect; an unrecoverable overflow now shows one actionable error instead of an empty failed assistant reply.
- Identified the current assistant as running inside Minis Mac and exposed the app's own Hooks settings in its system prompt, so requests about "this agent" default to the current app.
- Repaired stale test runner source lists and a conversation deletion test whose assertion raced with normal completion.

### Phase 3D: Memory

- Added a documented local Memory directory containing human-readable `GLOBAL.md`, `SOUL.md`, and `daily/YYYY-MM-DD.md` files without database or cloud synchronization.
- Added a per-Conversation persisted Memory toggle with backward-compatible decoding for existing Conversations.
- Added a separate global Memory switch that defaults off; injection requires both global and Conversation-level use to be enabled.
- Injected enabled Memory into the Provider system prompt with explicit file boundaries and latest-user-message precedence.
- Added an in-window Memory settings editor for viewing, editing, reloading, and saving all three documents.
- Added the independent `script/test_phase3d.sh` acceptance suite for file creation, persistence, prompt gating, and Conversation compatibility.
- Replaced the full-height empty Memory editor with a bounded, top-aligned document editor, per-document guidance, and a visible empty-state prompt.

### Phase 3C: Conversations, Projects, and Secret UX

- Added persisted Conversations and workspace-bound Projects with strict scope isolation between standalone and per-Project placeholders.
- Preserved user-named conversations even when they have no messages; cold-start cleanup now removes only redundant untouched default placeholders.
- Defined Project deletion as "delete Project only": a confirmation explains that child Conversations are retained and moved to the regular list.
- Kept Provider metadata in JSON while storing API keys only in Keychain; Provider settings and selection use persisted `hasStoredSecret` metadata without reading the secret.
- Added in-session Provider and MCP secret caching, non-interactive Keychain accessibility, and replacement-time recovery for incompatible legacy items.
- When legacy Provider metadata points to an unavailable Keychain item, the app now clears the stale configured state and asks for one explicit re-save instead of repeatedly failing or prompting.
- Added an explicit eye control that reads an API key from Keychain only on user action, supports direct editing, and toggles plain/masked display; model refresh now keeps edited keys in the form and repairs an invalid selected Model ID after a changed model list.
- Configured the daily Debug app with a stable bundle identifier and Apple Development signing; automated unsigned builds remain available explicitly via `./script/build_and_run.sh --unsigned`.
- Preserved MCP env/header Keychain references and redacted export behavior from Phase 3B.

### Phase 3A: Skills

- Added local and Workspace Skills discovery without proprietary database ownership or file copying.
- Added YAML frontmatter parser for `SKILL.md` with support for headless files, comments, and folded/literal block scalars.
- Added `SkillScanner` supporting Workspace roots (`.agents/skills`, `.claude/skills`, `.cline/skills`, `.skills`, `skills`) and global locations (`~/.agents/skills`, `~/.claude/skills`, `~/.config/skills`, etc.) with symlink deduplication.
- Added `SkillStore` managing enabled/disabled toggle states with `UserDefaults` persistence.
- Added on-demand skill disclosure in the system prompt (`<available_skills>`), instructing the model to load full instructions via `file_read` only when relevant.
- Hardened `PermissionEvaluator` to allow safe read-only access to enabled skill directories while keeping strict guards on sensitive paths.
- Added dedicated `SkillsSettingsView` in single-window Settings with search, scope filtering, enable/disable switches, instruction inspector, and "Reveal in Finder".
- Added `script/test_phase3a.sh` and verified autonomous on-demand skill reading with local CPA Gemini (`gemini-3.7-flash-high`).

### Phase 2

- Added a persisted, user-selected Workspace backed by a native folder picker and security-scoped bookmark data.
- Added direct `shell_execute`, `file_read`, `file_write`, and `file_edit` services with Workspace-aware path resolution.
- Added streaming stdout/stderr, exact exit status, bounded output, timeout, and cancellation for native zsh processes.
- Added shell environment overlays with masked values, monotonic stream timing, ANSI/control cleanup, carriage-return folding, original output byte counts, and distinct cancelled/timed-out states.
- Added Request Approval, Help Me Approve, and Full Access modes with visible approval prompts and risk descriptions.
- Added a configurable Agent tool loop with loop detection, structured diagnostic termination reasons, and expandable Tool Call cards showing input, execution state, output, duration, error, and approval state.
- Refined the main window toward the requested ChatGPT macOS hierarchy with a restrained context bar, centered transcript, and floating composer.
- Modularized Chat and Settings presentation into single-responsibility views and unified design metrics via `AppLayout`.
- Moved General, Provider, Workspace, Permission, and Log settings into the main navigation window with an in-window Back to Minis route; Settings and Command-comma no longer open a second window.
- Added explicit approval protection for sensitive Workspace paths such as environment files, private keys, credential files, `.git-credentials`, and common credential directories.
- Added native block-level Markdown rendering and automatic collapse for completed Tool Calls.
- Passed all three real-world acceptance gates through the local CPA Gemini Provider:
  - Test A: Workspace project inspection via shell listing and README read.
  - Test B: Autonomous test failure discovery, codebase inspection, `file_edit` of `PermissionEvaluator.swift`, and green re-test verification.
  - Test C: Native shell execution of `agentmemory --help` and direct connection guidance.

### Phase 1

- Added OpenAI-compatible Provider configuration with Keychain-backed API keys.
- Added `/models` discovery without provider-name filtering, plus a manual Model ID fallback.
- Added provider-neutral streaming events and an SSE chat client for `/chat/completions`.
- Added native chat, Provider settings, visible errors, cancellation, and a bounded redacted Debug Log.
- Added a deterministic build/run entrypoint and a local mock-provider integration test.
- Verified the complete UI flow against a local compatibility fixture and three real third-party Providers: local Gemini proxy, relay service, and official DeepSeek API.

### Phase 0

- Added the macOS architecture boundary, OpenMinis source reuse audit, and native shell specification.
- Recorded the decision to build a native SwiftUI thin shell beside the existing iOS app.
- No iOS application behavior changed.
