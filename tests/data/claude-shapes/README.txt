Recorded shapes of Claude Code in stream-json mode, for tests/fake-claude.py (the fake's drift test).

CLI: 2.1.330 (Claude Code), recorded 2026-11-22 on macOS, signed in to a claude.ai subscription.
The 2.1.289 recordings (2026-10-12) are kept where 2.1.330 did not change them (see "Files").
Case letters (a) to (j) are those of task 1 of the phase 1 plan; (k) and (l) were added.

Pinned command line (rhun's)

  claude --output-format stream-json --verbose --input-format stream-json --include-partial-messages
    --permission-prompt-tool=stdio
    --setting-sources=user,project,local          (trusted folder)
      | --setting-sources=user                    (folder not trusted)
    --max-thinking-tokens=31999
    --session-id=UUID                             (a new conversation)
      | --resume=ID                               (an existing one)
      | --resume=SRC --fork-session --session-id=UUID   (a copy)

  No -p (decision 1). cwd: the conversation's folder. Environment: the login environment plus
  CLAUDE_CODE_ENTRYPOINT=rhun and MCP_CONNECTION_NONBLOCKING=true, without CLAUDECODE,
  CLAUDE_CODE_CHILD_SESSION, TRACEPARENT, TRACESTATE. The recordings ran with only HOME, PATH, USER,
  LANG, TMPDIR and those two forced values.
  First line on stdin: {"type":"control_request","request_id":"r1","request":{"subtype":"initialize","hooks":null}}
  A prompt: {"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]},
             "parent_tool_use_id":null,"session_id":""}

Decisions, each with its evidence

1. -p is not needed: (b), the line without -p, got the initialize answer, a reply and result success,
   exit 0, with the same shapes as (a) with -p. rhun leaves it out (the extension does).
2. Flag forms: --permission-prompt-tool=stdio and --max-thinking-tokens=31999 (with =) are taken, and
   so is the two-argument form (initialize answered both ways, no prompt sent). --permission-prompts
   host was not needed. Both flags are still missing from --help (../claude/help-2.1.330.txt).
3. The = form delivers can_use_tool: (c) two Bash requests, (i) ExitPlanMode then Write, (j)
   AskUserQuestion, (l) a Bash request an interrupt withdrew.
4. Answers carrying "toolUseID" (the request's tool_use_id) are accepted: in (c) the allow ran the
   command (tool_result "(Bash completed with no output)"), the deny gave a tool_result with is_error
   true and our message, and result.permission_denials named that call; (i) and (j) went on after allows.
5. Plan: set_permission_mode {"mode":"default"} sent before allowing ExitPlanMode makes Claude leave
   plan mode: (i) answered {"mode":"default"}, then system/status permissionMode "default"; after the
   allow Claude called Write, which asked (can_use_tool Write, as default mode does), and the file was
   made. Before ExitPlanMode, in plan mode, Claude wrote its plan to <config>/plans/NAME.md with Write
   without asking.
6. Transcript path: the slug comes from the resolved working directory. (a) was started in
   /tmp/...repo (/tmp is a symbolic link to /private/tmp): its file is
   <config>/projects/-private-tmp-...-repo/<id>.jsonl; (f) the same with PWD naming the /tmp path.
   system/init's cwd and the session record's cwd are the resolved path too. /var/folders against
   /private/var/folders is the same case (/var is a link to /private/var).
7. system/init arrives only after the first prompt (C4 holds): in (a), 4.5 s after the initialize
   answer only system/commands_changed had come; system/init came 80 ms after the prompt. The
   initialize answer has pid but no session id.
8. --session-id=UUID makes the id ours from the start: <config>/sessions/<pid>.json has it right after
   initialize, system/init reports it, and <id>.jsonl does not exist before the first prompt (the
   prompt creates it) (f). (g) --resume=SRC --fork-session --session-id=UUID: the copy gets our id the
   same way; its file holds SRC's history, then the new turn. (e) --resume=ID keeps ID and replays
   nothing on stdout.
9. The initialize answer's keys (2.1.330): commands, agents, output_style, available_output_styles,
   user_output_styles_dir, models, account, pid, claude_code_version, current_permission_mode,
   hook_on_failure_supported, hooks_when_unanswered_kept, other_hook_ask_outranks_host, feedback_mode,
   analytics_disabled, remote_control_auto_enable, remote_control_auto_connect_default,
   remote_control_available, remote_control_auto_on_by_default, ide_rc_auto_enable_gate,
   fast_mode_state, fast_mode_disabled_reason, session_state, capabilities. account: email,
   organization, subscriptionType, apiProvider. The control_response has pending_permission_requests
   and pending_user_dialog_requests beside it.

Phase 2 findings (CLI 2.1.330, recorded 2026-11-23 on macOS, same subscription)

Command line of these runs: the pinned one plus --replay-user-messages (and the flag each finding
names), --permission-mode=default unless said, environment as above plus
CLAUDE_CODE_QUESTION_PREVIEW_FORMAT=markdown; initialize carried "promptSuggestions":true (false where
said) and "supportedDialogKinds":["fable_overage_consent_prompt","auto_mode_server_fallback"].

10. Permission modes. set_permission_mode answers {"mode":M} for default, acceptEdits, plan, auto,
    dontAsk, then system/status {status null, permissionMode M}; asked for the mode already in force it
    answers but sends no status line. bypassPermissions in a process started without
    --allow-dangerously-skip-permissions: error "Cannot set permission mode to bypassPermissions because
    the session was not launched with --dangerously-skip-permissions"; with the flag: the answer, the
    status line, then system/commands_changed (also on leaving bypass). At a start,
    --permission-mode=bypassPermissions is taken WITHOUT the flag (current_permission_mode
    bypassPermissions), and that process may later switch away and back by request. auto at a start
    with or without the flag: current_permission_mode auto. So the bypass gate is rhun's alone.
11. get_settings answers {effective, sources:[{source, settings}], served_settings_state, applied};
    errors is absent when there are none (the CLI's schema: each error {message, path}; the extension's
    webview reads .file). applied: model (the resolved id, "claude-opus-5-5"), effort, advisor, ultracode,
    ultracodeRequested, ultracodeAvailable (true here), ultrathinkAvailable, outsideFileTool* flags.
    effective has model and effortLevel only where a source sets them; no showThinkingSummaries,
    disableAutoMode or permissions.disableBypassPermissionsMode on this account, so their effect is not
    recorded. applied.effort follows the model: the user's top-level effortLevel was xhigh while
    applied.effort was high from modelSettings.<model>.effortLevel. apply_flag_settings,
    set_max_thinking_tokens and set_model answer a success with no "response" member.
12. update_settings: localSettings takes outputStyle and refuses model, effortLevel, fastMode,
    alwaysThinkingEnabled, showThinkingSummaries ("update_settings keys not allowed: KEY");
    projectSettings, policySettings, flagSettings and session are "update_settings: unsupported source
    S"; userSettings refuses model and takes effortLevel, which it writes to
    modelSettings.<resolved model>.effortLevel, not to the top-level key (seen in get_settings' sources at
    once and in a new process). No request persists a model.
13. Model and effort, session only: --model=sonnet --effort=low at a start gave applied
    {model claude-sonnet-5-5, effort low} and system/init model claude-sonnet-5-5 while effective and
    sources still held the user's (opus, xhigh); apply_flag_settings {"settings":{"model":"sonnet"}} on
    a running process gave applied model claude-sonnet-5-5 with effort medium (the new model's own),
    {"effortLevel":"low"} gave effort low, sources gained a flagSettings entry, the next turn's
    system/init and assistant messages named claude-sonnet-5-5; userSettings in sources was unchanged
    before, after and in a new process, which was back to claude-opus-5-5 / high.
    apply_flag_settings {"settings":{"ultracode":true}} set applied.ultracode and ultracodeRequested,
    false cleared them (no prompt was sent with it on).
    Rule rhun follows: model: rhun's own per project, passed as --model=VALUE at each start and sent as
    apply_flag_settings {"settings":{"model":VALUE}} while running; effort: the same with --effort=LEVEL
    and {"effortLevel":LEVEL}. Neither persists anything; update_settings is never sent.
14. Thinking: set_max_thinking_tokens {max_thinking_tokens 0}, {31999, thinking_display "summarized"} and
    {31999, thinking_display null} each answered success without a member; --thinking=disabled (in
    place of --max-thinking-tokens) was taken at a start. The current models (default, opus, fable,
    sonnet, haiku: the 5.x ones) have supportsThinkingOff false; only older ones (sonnet-5, opus-5,
    opus-4.x, haiku-4-5) have it true.
15. Bash in default mode (touch a.txt): can_use_tool with description (Claude's), permission_suggestions
    [addRules Bash "touch a.txt" allow localSettings, addDirectories [cwd] session, setMode acceptEdits
    session], blocked_path (the file); no suppress_always_allow_rule, default_to_no or decision_reason*.
    The addRules echoed with localSettings wrote {"permissions":{"allow":["Bash(touch a.txt)"]}} to
    .claude/settings.local.json, and the same command again ran without asking. An allow whose
    updatedInput.command was "touch c.txt" ran that one (c.txt made, b.txt not); Claude was not told.
16. Edit (notes.txt): description "notes.txt", no blocked_path, the only suggestion setMode acceptEdits
    session; echoed, it gave system/status permissionMode acceptEdits and the next Edit did not ask;
    nothing was written. WebFetch https://example.com: suggestion [{type addRules, destination
    localSettings, rules [WebFetch "domain:example.com"], behavior allow}] (in that field order),
    description the URL; here it was asked from a subagent (the account's own web-fetch agent), so the
    request also had agent_id. Echoed with session: no file written, the same fetch again did not ask.
17. Messages during a turn (shape files 12 to 14). Every user message written with a "uuid" gets
    command_lifecycle {command_uuid, state} as it is read: queued, then started as its turn begins,
    then completed, or cancelled when an interrupt ended its turn; a message without a uuid gets none.
    This is the same with and without --replay-user-messages. A message written during a turn is not
    joined to it: it waits and gets its own turn, its own system/init (2.1.330 sends system/init at
    every turn, not only the first), its own result whose user_message_uuid is its uuid (null without
    one). With --replay-user-messages each message comes back as it starts (after started, system/init
    and the requesting status) as a user record with its content blocks, isReplay true and the uuid
    sent (one of the CLI's own when none was sent); without the flag nothing comes back. interrupt
    without cancel_queued while one was held: {"still_queued":[its uuid]}, the running turn ended
    (aborted_streaming, lifecycle cancelled), then the held one started and ran.
18. With --replay-user-messages every control_response rhun writes (the can_use_tool answers) comes back
    on stdout verbatim, about 7 ms later, before the tool's result (15-permission-replay): a reader must
    ignore control responses whose request_id is not one of its own requests.
19. initialize accepted promptSuggestions and supportedDialogKinds and its answer has the keys of
    decision 9 (nothing echoes them). models carry value, resolvedModel, displayName, description,
    supportsEffort, supportedEffortLevels (low, medium, high, xhigh, max; low, medium, high, max on
    4.6), supportsAdaptiveThinking, supportsFastMode (opus and fable), supportsAutoMode,
    supportsThinkingOff; no unavailable_models, no Ultracode flag on any model (it is
    get_settings.applied.ultracodeAvailable). fast_mode_state "off", fast_mode_disabled_reason
    "sdk_opt_in_required". commands entries: name, description, argumentHint, aliases (some), builtin.
    prompt_suggestion {type, suggestion, uuid, session_id} came after the result and the lifecycle's
    completed, after some turns only (4 times in about 15 turns), never with promptSuggestions false.
20. rate_limit_event seen only as {status "allowed", resetsAt, rateLimitType "seven_day", overageStatus,
    overageDisabledReason, isUsingOverage, unifiedWindows {seven_day {utilization, resetsAt, status}}},
    once per turn; warning and rejected were not seen (the fake's are the schema's).
21. result.usage: input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens,
    output_tokens_details, server_tool_use, service_tier, cache_creation {ephemeral_1h_input_tokens,
    ephemeral_5m_input_tokens} (all the cache written was 1-hour), inference_geo, iterations, speed.
    modelUsage per model: inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens,
    webSearchRequests, costUSD, contextWindow 1000000, maxOutputTokens 128000, thinkingTokens,
    cacheCreationEphemeral5mInputTokens, cacheCreationEphemeral1hInputTokens. system/init has
    fast_mode_state and ultrathink_available (false), and no effort member; result has fast_mode_state.
22. Commands typed (17-slash): /context, /cost and /status get system/init, an assistant record of model
    "<synthetic>" with the text (and local_command_source "<local-command-stdout>TEXT
    </local-command-stdout>"), then a result with num_turns 0, no terminal_reason and local_command
    ("context", "cost"; none for /status); no requesting status, no replay, no
    system/local_command_output. /status answers "/status isn't available in this environment.".
    /cost is an alias of usage (the commands list has usage with aliases cost and stats, context,
    compact; no status). /compact: system/status compacting, status null with compact_result success,
    system/init, compact_boundary {compact_metadata {trigger manual, pre_tokens, post_tokens, ...}},
    the summary as a user string (isReplay false, isSynthetic true), "<local-command-stdout>Compacted
    </local-command-stdout>" as a replayed user string, a result with result "" and local_command
    "compact".
23. AskUserQuestion with two questions (one multiSelect) and previews: options {label, description,
    preview} with preview a Markdown string (Claude put them only on the single-choice question);
    answered "red, blue" and an Other text, the tool_result is 'The user answered: "Q1"="red, blue",
    "Q2"="tiny, my own answer". Read the answers carefully ...' and Claude repeated both. This time the
    request came after message_stop (03 had it before message_delta).
24. ExitPlanMode (--permission-mode=plan): a deny whose message was the extension's rejection text, the
    reason and "\n\nComments on the plan:\n[Re: \"QUOTE\"] COMMENT" with interrupt false: the
    tool_result carried that text and Claude planned again in the same turn (a second ExitPlanMode).
    set_permission_mode default, then an allow with userFeedback and userComments in updatedInput: the
    tool_result "User has approved your plan. ... ## Approved Plan: ..." (it does not quote the
    feedback), then a Write that asked. A deny with interrupt true ends the turn: for ExitPlanMode
    "[Request interrupted by user]" and result aborted_streaming, for the Write "[Request interrupted
    by user for tool use]" and aborted_tools. get_plan: {"exists":false} before, {exists, content,
    path} once Claude had written <config>/plans/NAME.md (path is that file).
25. request_user_dialog could not be provoked cheaply and was not tried. From the CLI binary's schemas
    (text in the installed 2.1.330 executable): the request is {subtype, dialog_kind, payload,
    tool_use_id?}, the answer {behavior "completed"|"cancelled", result?}. auto_mode_server_fallback:
    payload {gatewayHost?, title, paragraphs [string], helpUrl}, result "continue" | "interrupt" |
    "cancelled". fable_overage_consent_prompt: payload {overagesEnabled bool, modelName?, model?,
    leftOutOf? "plan"|"seat", endedOn? (a date string of at most 10 or false), member? true, request?
    {greyed?}, balanceCents? number|null, currency? string|null}, result "consent" | "switch_default" |
    "request_admin" | "cancelled"; a decline is reported as system/model_consent_fallback {choice,
    original_model, original_model_name?, fallback_model, persisted_as_default, content}. The schema
    says a kind is only sent where initialize declared it, and that a host must NOT answer a kind it did
    not declare ("never with {behavior: "cancelled"}, which is a real settlement treated as the user
    dismissing the dialog"; an error answer is discarded and the dialog stays pending until the CLI's
    deadline or a control_cancel_request).
26. (Found by tests/claude-real.py, 2026-11-23.) A command's description in initialize's commands can hold
    line ends: the claude-api skill's has several ("...\nTRIGGER ...\nSKIP ..."); of about 200 commands
    on this machine (built-ins, skills, plugins) 40 have descriptions over 400 bytes, the longest about
    1400. rhun's menu row is one line, so line ends and other control characters become spaces when a
    command is kept (as the extension's one-line row shows them); the fake's
    FAKE_CLAUDE_COMMANDS_CHANGED knows that skill by name.

Phase 3 findings (CLI 2.1.330, recorded 2026-11-23 on macOS, same subscription)

Numbering: the phase 3 plan (2026-11-23-claude-chat-phase3.md) calls these 26 to 36, but 26 was taken
above, so each is one higher here: the plan's 26 is 27 (the file), 27 is 28 (tools), 28 is 29 (thinking),
29 is 30 (compaction), 30 is 31 (local commands), 31 is 32 (hooks), 32 is 33 (images), 33 is 34
(subagents and tasks), 34 is 35 (results), 35 is 36 (error and denial texts), 36 is 37 (other system
records). Where a task of that plan says "finding N", read N+1.

Command line of these runs: phase 2's (the pinned one, --replay-user-messages, --permission-mode=default),
--session-id=UUID, --model=haiku --effort=low unless said; environment HOME, PATH, USER, LANG, TMPDIR and
rhun's three forced values (CLAUDE_CODE_ENTRYPOINT=rhun, MCP_CONNECTION_NONBLOCKING=true,
CLAUDE_CODE_QUESTION_PREVIEW_FORMAT=markdown); initialize {"hooks":null,"promptSuggestions":false,
"supportedDialogKinds":[the two],"perTaskStopAffordance":true,"forwardNestedSubagentToolCalls":true} (one
run of 34 without the last two). Every can_use_tool was allowed with updatedInput unless said. The
maintainer's user settings applied (sources user,project,local): their Stop hooks, a plugin's SessionStart
hook and a PreToolUse hook that rewrites some Bash commands show in these records; the hooks and rules a
finding names were in the temporary repository's .claude/settings.local.json.

27. The conversation's file, <config>/projects/<slug>/<id>.jsonl, one JSON object a line.
    Types seen (17 runs): user, assistant, system (subtypes stop_hook_summary, informational,
    local_command, compact_boundary), attachment (attachment.type date, environment, instructions,
    skill_listing, deferred_tools_delta, deferred_tools_record, mcp_instructions_delta, session_context,
    model, credential_org, prompt_snapshot, total_tokens_reminder, hook_success, hook_additional_context,
    queued_command, remote_session_change, agent_listing_delta, file, invoked_skills,
    command_permissions), queue-operation, session-owner, atis-latch, api-request, api-request-shape,
    api-request-blob, ai-title, last-prompt, tools-used, cost-state (appended at exit). No summary,
    file-history-snapshot or custom-title line was written in these runs. A reader takes user, assistant
    and system lines and skips every other type BY TYPE: api-request-blob is {type, sessionId, hash,
    message} with message a copy of an API request's messages (tool_use, tool_result, text and thinking
    blocks): a reader that takes any line with a message doubles every call.
    Every user, assistant and system line has parentUuid, isSidechain (false or absent), uuid,
    timestamp, userType, entrypoint ("rhun"), cwd, sessionId, version, gitBranch (orders: file-keys.txt).
    timestamp is ISO 8601 UTC with milliseconds, "2026-11-23T17:57:35.378Z", on every user, assistant,
    system, attachment and queue-operation line (session-owner, atis-latch, ai-title, last-prompt,
    tools-used have none). The line's uuid is the CLI's own; the uuid rhun sent with a message is the
    prompt line's turnAttributionKey.
    A prompt: user, message {role, content: the blocks as sent}, promptId, permissionMode, promptSource,
    turnOrigin ("sdk"), turnPosition {promptIndex, turnIndex}, turnAttributionKey.
    An assistant message is ONE LINE PER CONTENT BLOCK (107 lines, every one with one block), as the
    stream's assistant records are (C3): message {model, id, type, role, content [one block], container,
    stop_reason, stop_sequence, stop_details, usage, input_transformations, diagnostics,
    context_management} with apiBlockIndex 0, 1, ..., requestId, requestRef, requestedModel,
    promptCacheRequested, advisorModel, effort, perTurnEffort, madeBy; the lines of one message share
    message.id. A thinking line adds thinkingDurationMs and thinkingDisplay, a tool_use line
    toolInputStreamMs and wireToolInputs. THINKING IS SAVED, text included (29).
    A tool's result: user, message.content [one tool_result block], toolUseResult, sourceToolAssistantUUID
    (the uuid of the line with the call), permissionDecision, sandboxed (Bash). The block and toolUseResult
    equal the stream's block and tool_use_result key for key (21 of 21 compared). When a message's later
    call streams after an earlier call's result (28), the file has them in that order too: call, result,
    call, result.
    Stream to file: tool_use_result -> toolUseResult; tool_result_meta -> none (permissionDecision);
    thinking_duration_ms -> thinkingDurationMs; thinking_display -> thinkingDisplay; compact_metadata
    {snake_case} -> compactMetadata {camelCase} (30); logical_parent_uuid -> logicalParentUuid; a local
    command's <synthetic> assistant record -> system/local_command (31); parent_tool_use_id -> nothing (a
    subagent's lines are in its own file, 34). Only in the stream: stream_event, system/init, status,
    thinking_tokens, task_*, background_tasks_changed, hook_started/hook_response, permission_denied,
    command_lifecycle, rate_limit_event, result. Only in the file: attachments (a PostToolUse hook's text,
    32), stop_hook_summary (32), local_command, isMeta user lines (a custom command's body, the local
    command caveat, an image's "[Image: source: PATH]"), the bookkeeping types.
    Lines are never changed or moved: the (offset, length, hash) of every line before /compact, after it,
    after two more turns, and before and after an interrupt: every earlier line kept its offset and bytes;
    compaction and the interrupt only appended. A row may keep the offset and length of its line.
28. Tools. system/init.tools (every run, built-in names): Task, Artifact, ArtifactComments, ArtifactData,
    AskUserQuestion, Bash, CronCreate, CronDelete, CronList, DesignSync, Edit, EnterPlanMode,
    EnterWorktree, ExitPlanMode, ExitWorktree, ListAgents, Monitor, NotebookEdit, PushNotification, Read,
    RemoteTrigger, ReportFindings, ScheduleWakeup, SendMessage, SendToProject, SendToProjectContext,
    Skill, TaskStop, ToolSearch, WebSearch, Workflow, Write; no mcp__ tools (they are deferred). NOT
    listed: MultiEdit (absent from this build), Glob, Grep, WebFetch, TodoWrite, the task tools. The list
    says Task; the call is named "Agent" in every run. Deferred tools (120 here, mostly MCP) are fetched
    with ToolSearch {query "select:NAME,NAME" | words, max_results}: content [{type tool_reference,
    tool_name}] or the string "No matching deferred tools found. ..."; tool_use_result {matches, query,
    total_deferred_tools[, failed_mcp_servers]}. Glob and Grep are not offered with a 5.x model unless a
    --tools or --allowedTools list names them (the binary's searchToolsOptIn; recorded with
    --allowedTools=Glob,Grep). Calls of one message run as they stream: the first Read's result came
    before the second Read's assistant record and before message_stop (18-tools).
    Input keys in the order sent; content; is_error; the structured result (tool_use_result):
    - Read {file_path[, offset, limit]}: content "1\tone\n2\ttwo\n..." (number, TAB, line), no is_error key;
      {type "text", file {filePath, content, numLines, startLine, totalLines}} (offset 2, limit 3: startLine
      2, numLines 3). dot.png: content [{type image, source {type base64, data, media_type image/png}}],
      {type "image", file {base64, type "image/png", originalSize, dimensions {originalWidth,
      originalHeight, displayWidth, displayHeight}}} (the image is in both). Missing: is_error true,
      "File does not exist. Note: your current working directory is CWD." (no <tool_use_error>), result
      the string "Error: " + content.
    - Edit {replace_all, file_path, old_string, new_string} (replace_all first, false when not asked):
      "The file PATH has been updated successfully. (file state is current in your context — no need to
      Read it back)"; with replace_all "The file PATH has been updated. All occurrences were successfully
      replaced."; no is_error key; {filePath, oldString, newString, originalFile, structuredPatch [{oldStart,
      oldLines, newStart, newLines, lines [" ctx", "-old", "+new"]}], userModified, replaceAll[,
      contentNotInModelContext]}. Not found: is_error, "<tool_use_error>String to replace not found in
      file.\nString: X</tool_use_error>", result "Error: String to replace not found in file.\nString: X".
    - Write {file_path, content}: new: "File created successfully at: PATH (file state is current ...)",
      {type "create", filePath, content, structuredPatch [], originalFile null, userModified}; existing: "The
      file PATH has been updated successfully. (...)", {type "update", ..., structuredPatch [hunks],
      originalFile "the old text"}.
    - Bash {command, description[, timeout][, run_in_background]}: content the output, is_error false
      present; {stdout, stderr, interrupted, isImage, noOutputExpected[, backgroundTaskId,
      backgroundedByUser]}; "echo err 1>&2" gave content "err" and stdout "err", stderr "" (stderr is merged).
      Failing: is_error true, "Exit code 1\nls: missing-dir: No such file or directory", result "Error: " +
      content. run_in_background: "Command running in background with ID: ID. Output is being written to:
      $TMPDIR/claude-UID/<slug>/<id>/tasks/ID.output. You will be notified ...", + backgroundTaskId; its task
      records (34). A plain "sleep 30" got is_error "<tool_use_error>Blocked: standalone sleep 30. ...
      </tool_use_error>" (a guard of this installation).
    - Grep {pattern, output_mode}: content "a.py:1:LINE\n..." / {mode, numFiles, filenames [], content,
      numLines, totalLines}; files_with_matches "Found 1 file\na.py" / {mode, filenames, numFiles,
      totalFiles}; count "a.py:8\n\nFound 8 total occurrences across 1 file." / {mode, numFiles, filenames
      [], content "a.py:8", numMatches}. No is_error key.
    - Glob {pattern}: "a.py" (relative, a line each) or "No files found"; {filenames, durationMs, numFiles,
      truncated, totalMatches, countIsComplete}.
    - WebFetch {url, prompt}: Claude did not call it itself: Agent {description, subagent_type "web-fetch",
      prompt} (a built-in agent) did, which asked (can_use_tool with agent_id, finding 16); content
      "Fetched https://example.com/ from a non-preapproved source (HTTP 200 OK, text/html, 172
      characters).\n<fetched-web-content>\n...", no structured result (no subagent result has one).
    - WebSearch {query, mode "standard"}: asked nothing; content one string "Web search results for query:
      \"Q\"\n\nLinks: [{\"title\":...,\"url\":...},...]\n\n..."; no search result blocks reach the stream;
      {query, results [{tool_use_id "srvtoolu_...", content [{title, url}]}, ...], durationSeconds,
      searchCount}.
    - Skill and NotebookEdit are listed but were not called: no recording; MultiEdit does not exist.
    The todo tools (open point 9). The binary: TodoWrite is enabled when CLAUDE_CODE_ENABLE_TASKS is false
    AND a "todo tools" gate holds; TaskCreate, TaskGet, TaskUpdate and TaskList when it is not false AND
    the gate holds. The gate: the model is one of an old list (claude-3*, opus-4-0 to 4-7, sonnet-4-0 to
    4-6, haiku-4-5) or unknown, a --tools / --allowedTools list names one of the five, a background
    session, or CLAUDE_CODE_ENABLE_TODO_TOOLS=1. Recorded (haiku 5.5): rhun's environment as it is: NEITHER
    (init.tools has none, ToolSearch "select:TodoWrite" found nothing, Claude wrote the list as text);
    with CLAUDE_CODE_ENABLE_TASKS=0 added: NEITHER, the same. With CLAUDE_CODE_ENABLE_TODO_TOOLS=1 and
    CLAUDE_CODE_ENABLE_TASKS=0: init.tools lists TodoWrite; with CLAUDE_CODE_ENABLE_TODO_TOOLS=1 alone:
    TaskCreate, TaskGet, TaskList, TaskUpdate (deferred both times: ToolSearch first). TodoWrite {todos
    [{content, status pending|in_progress|completed, activeForm}]}, the whole list every call: "Todos have
    been modified successfully. Ensure that you continue to use the todo list to track your progress.
    Please proceed with the current tasks if applicable", {oldTodos, newTodos}. TaskCreate {subject,
    description}: "Task #1 created successfully: a", {task {id "1", subject, description}}; TaskUpdate
    {taskId, status}: "Updated task #1 status", {success, taskId, updatedFields ["status"], statusChange
    {from, to}}: one item a call, never the list; the tasks are kept in ~/.claude/tasks/<session id>/.
    A conversation of an older model, or made with those settings, holds either form.
29. Thinking. Haiku 5.5 thought in most tool turns with the default display: content_block_start
    {type thinking, thinking "", signature ""} with top-level thinking_display "updates", thinking_delta
    {thinking "", estimated_tokens N} between system/thinking_tokens records, signature_delta, the
    assistant record {thinking "", signature} with thinking_duration_ms and thinking_display "updates";
    the file keeps "" and thinkingDurationMs. After set_max_thinking_tokens {31999, thinking_display
    "summarized"} (success, no member; Haiku, --effort=high): 35 thinking_delta records WITH text (a
    summary, 393 characters in all) and no estimated_tokens, each followed by thinking_tokens
    {estimated_tokens 4, 6, ... 114, estimated_tokens_delta}, one last thinking_tokens 489 (+375),
    signature_delta, the assistant record with the whole text, thinking_duration_ms 3109, thinking_display
    "summarized" (19-thinking); the file has the same text, thinkingDurationMs 3109, thinkingDisplay
    "summarized". Sonnet 5.5 at medium effort did not think on "Think carefully about 17 * 23" (two turns,
    with and without "summarized": no thinking block, thinking_tokens 0). A subagent's thinking records
    have thinking "" and no thinking_duration_ms or thinking_display. redacted_thinking was not seen.
30. Compaction (/compact after four turns, the last /context). Stream: lifecycle started, system/status
    compacting, SessionStart hooks (hook_name "SessionStart:compact"), status null with compact_result
    success, system/init, compact_boundary {compact_metadata {trigger "manual", pre_tokens, post_tokens,
    cumulative_dropped_tokens, duration_ms, preserved_segment {head_uuid, anchor_uuid, tail_uuid},
    preserved_messages {anchor_uuid, uuids, all_uuids}}, logical_parent_uuid}, the summary as a user
    string (isReplay false, isSynthetic true; "This session is being continued from a previous
    conversation that ran out of context. The summary below covers the earlier portion of the
    conversation. ..."), then THE /context ASSISTANT RECORD AGAIN, same uuid as before (the preserved
    segment sent again), the replayed "<local-command-stdout>Compacted </local-command-stdout>", the
    replayed "/compact" command string (with its earlier timestamp), result success "" with local_command
    "compact" and no terminal_reason (20-compact). A stream reader must drop a record whose uuid it has
    seen. Phase 2's /compact (17-slash) sent nothing again and had no preserved_segment: when it is sent is
    not known. File: system/compact_boundary (parentUuid null, logicalParentUuid, content "Conversation
    compacted", level info, isMeta false, compactMetadata {trigger, preTokens, preCompactOrganizations,
    preCompactOrganizationsCoverStart, durationMs, preservedSegment {headUuid, anchorUuid, tailUuid},
    preservedMessages, postTokens, cumulativeDroppedTokens}), the summary user string with
    isCompactSummary true and isVisibleInTranscriptOnly true, the caveat (31), the /compact command
    string, "<local-command-stdout>Compacted </local-command-stdout>", attachments; nothing is repeated
    and nothing earlier changes (27). Lines from there on carry "slug". An automatic compaction was not
    provoked.
31. Local commands. /context, stream: system/init, the <synthetic> assistant (finding 22), result, and
    AFTER the assistant the replayed user string "<command-name>/context</command-name>\n
    <command-message>context</command-message>\n            <command-args></command-args>" (twelve
    spaces before the second and third tags), then the result; no system/local_command_output. Finding
    22's /context (phase 2, also with --replay-user-messages) had no such replay: what decides is not
    known, and the fake keeps 17-slash's shape. File: a user string
    "<local-command-caveat>The command below was run directly in Claude Code, not sent to you as a
    request, ...</local-command-caveat>" with isMeta true, the command string (no isMeta), and
    system/local_command {content "<local-command-stdout>TEXT</local-command-stdout>", level info, isMeta
    false, contextUsage}: no assistant line. A custom command (.claude/commands/hi.md, "Reply with the
    word hi."): stream: requesting, the replayed user string "<command-message>hi</command-message>\n
    <command-name>/hi</command-name>" (message first, no <command-args>), the reply; file: that string,
    then a user line with the file's text, isMeta true, turnCompanion true; the reply's line has
    attributionSkill "hi". "!echo hi" was sent as a prompt and Claude ran Bash "echo hi" itself: stream
    input has no shell mode; no <bash-input> or <bash-stdout> record exists.
32. Hooks (repository's .claude/settings.local.json: SessionStart "echo hi"; UserPromptSubmit a script that
    prints hi, or exits 2 with "Blocked by the test hook" on BLOCKME; PostToolUse on Read printing
    hookSpecificOutput.additionalContext). Without --include-hook-events only SessionStart's records:
    system/hook_started {hook_id, hook_name "SessionStart:startup", hook_event "SessionStart"} for every
    SessionStart hook (the user's own too), then hook_response {hook_id, hook_name, hook_event, output,
    stdout, stderr, exit_code, outcome "success"} in completion order, all BEFORE the initialize answer,
    and again as "SessionStart:compact" during /compact. With --include-hook-events also UserPromptSubmit's
    started/response (between lifecycle started and system/init) and Stop's (hook_name "Stop", before the
    result) (22-hooks); no hook_progress. PostToolUse's additionalContext reaches no stream record; the
    file has attachment hook_success {hookName "PostToolUse:Read", toolUseID, hookEvent, content, stdout,
    stderr, exitCode, command, durationMs} and attachment hook_additional_context {content ["The test hook
    saw this read."], hookName, toolUseID, hookEvent}. A blocking UserPromptSubmit: lifecycle started,
    system/init, system/informational {content "UserPromptSubmit operation blocked by hook:\n[COMMAND]: Blocked by the
    test hook\n\n\nOriginal prompt: BLOCKME reply ok", level "warning", prevent_continuation true,
    prompt_submit_outcome {kind "blocked_by_hook", prompt_kept}}, result success with the same text,
    num_turns 0, no terminal_reason; no requesting status, no replay, no prompt line in the file, which has
    system/informational (preventContinuation, promptSubmitEnding {ending {kind, reason}, promptKept
    false}). A user's Stop hooks add system/stop_hook_summary {hookCount, hookInfos [{command,
    durationMs}], hookErrors, failedHookErrorIndexes, hookAdditionalContext, preventedContinuation,
    stopReason, hasOutput, level "suggestion", toolUseID} to the file after every turn (none without Stop
    hooks: the file-*.txt shapes leave it out).
33. Images. Read of dot.png: 28. A user message [image {source base64 png}, text] written by the
    recorder: replayed as user {content [image, text], isReplay true}; file: a prompt line with both
    blocks and imagePasteIds [1], then a user line isMeta true, "[Image: source:
    $TMPDIR/claude-UID/<slug>/<id>/images/1.png]" (the CLI stored the image there).
34. Subagents and tasks. The agent tool is "Agent" {description, prompt[, subagent_type][,
    run_in_background]}. A general-purpose agent ran in the background even when not asked
    (is_backgrounded true); the built-in web-fetch agent ran in the foreground.
    Background: the Agent call; system/background_tasks_changed {tasks [{task_id, run_id, task_type
    "local_agent", subagent_type, description}]}; system/task_started {task_id, run_id, tool_use_id,
    description, subagent_type, is_backgrounded, spawn_depth 1, task_type, prompt}; the call's result at
    once: content [{type text, text "Async agent launched successfully. ... agentId: ID ... output_file:
    PATH ..."}] and {isAsync true, status "async_launched", agentId, description, resolvedModel, prompt,
    outputFile, canReadOutputFile, canContinueAgent} (NO call count). The turn goes on and may end while
    the agent works. The agent's records carry parent_tool_use_id (the Agent call's id), agent_id (the
    task_id) and subagent_type and task_description where keys.txt has them, and come without
    stream_event: user text {its prompt} (the foreground agent's only), assistant tool_use, user tool_result (no tool_use_result), assistant
    thinking, assistant text (its report), with system/task_progress {task_id, run_id, tool_use_id,
    description "Running DESC", subagent_type, usage {total_tokens, tool_uses, duration_ms},
    last_tool_name} after each call; then task_updated {patch {status "completed", end_time}},
    task_notification {task_id, run_id, tool_use_id, status "completed", output_file, summary[, usage]},
    background_tasks_changed {tasks []}, and the main agent gets a turn by itself: system/init, sometimes
    the <task-notification> user string replayed (with origin), a reply and a second result (with origin
    {kind "task-notification", ...}). In agent-noflags the agent's first call came before the turn's
    result, the rest after it (21-agent). Foreground (web-fetch): task_started is_backgrounded false, the
    agent's records, task_progress, task_updated, task_notification, then the call's result: content
    [{type text, text REPORT}] and {status "completed", prompt, agentId, agentType, toolsUsed, ...,
    content, resolvedModel, totalDurationMs, totalTokens, totalToolUseCount, usage, toolStats,
    canContinueAgent}: totalToolUseCount is the count; for a background agent the count is usage.tool_uses
    of its task records, or its file's lines.
    Without perTaskStopAffordance and forwardNestedSubagentToolCalls the same prompt gave the same kinds of
    records (the agent's calls and text with parent_tool_use_id, the task records): nothing visibly lost
    for an agent of depth 1. A nested agent (spawn_depth 2) was not provoked, so what forwardNested adds
    is NOT KNOWN.
    On disk the agent's records are NOT in the conversation's file (no isSidechain true line there in any
    run): they are in <config>/projects/<slug>/<session id>/subagents/agent-<agentId>.jsonl, agentId the
    task_id and the result's agentId ("a" and 16 hex digits), with agent-<agentId>.meta.json {agentType,
    isBuiltIn, [launchedWithDefaults,] description, toolUseId (the Agent call's id), spawnDepth,
    requestShape "foreground"|"background", requestNonInteractive, model, pickedEffortModel, finished |
    stoppedByUser}. Its lines: user string (the prompt), assistant lines (one block a line), user
    tool_result lines (no toolUseResult), each with isSidechain true and agentId, the parent's sessionId,
    and no parent_tool_use_id: the link is the file's name and meta.json's toolUseId (file-subagent).
    The parent's file has the call, its result and, for a background agent, the later <task-notification>
    user string (origin {kind "task-notification", producer, runId}, promptSource "system", turnOrigin
    "task_notification"): <task-id>, <tool-use-id>, <output-file>, <status> (completed, killed),
    <summary>, <note>.
    stop_task {task_id} on a running background agent: answer success with response {}; task_updated
    {patch {status "killed", end_time}}, task_notification {status "stopped"}, background_tasks_changed
    [], the agent's user text "[Request interrupted by user]" with its parent_tool_use_id, then the main
    agent's own turn; meta.json stoppedByUser true. background_tasks {tool_use_id} on a running foreground
    Bash ("sleep 20; echo done"): answer {backgrounded true}, background_tasks_changed with the task,
    task_updated {patch {is_backgrounded true}}, the call's result at once: "Command was manually
    backgrounded by user with ID: ID. Output is being written to: PATH. ...", + backgroundTaskId,
    backgroundedByUser; later task_updated completed, task_notification. For a call that had already
    ended: {backgrounded false}. A foreground Bash has task_started {is_backgrounded false, task_type
    "local_bash"} and task_notification {status completed, output_file "", summary} (no task_updated).
    Claude's own TaskStop {task_id} on a finished task: is_error "<tool_use_error>Task ID is not running
    (status: completed)</tool_use_error>".
35. Results. success: stop_reason end_turn, terminal_reason completed, num_turns the API calls; a turn
    with a rule's denial: success with permission_denials [{tool_name, tool_use_id, tool_input}]; Stop
    during a call: error_during_execution, stop_reason tool_use, terminal_reason aborted_tools, errors
    ["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"]; --max-turns 1 is
    taken (not in --help): error_max_turns, stop_reason tool_use, terminal_reason max_turns, errors
    ["Reached maximum number of turns (1)"], num_turns 2; a blocked prompt and local commands: success,
    stop_reason null, no terminal_reason, num_turns 0. Both error runs exited 1 at EOF. Not provoked,
    from the binary's schemas: assistant.error is one of authentication_failed, oauth_org_not_allowed,
    account_on_hold, verification_required, billing_error, rate_limit, overloaded, invalid_request,
    model_not_found, server_error, unknown, max_output_tokens, cloud_credential_error;
    system/api_retry {attempt, max_retries, retry_delay_ms, error_status (null for a connection error),
    error (that enum), no_response? {waited_ms, retry_wait_ms}}; system/api_error {error {message,
    status?, request_id?, formatted, connection {code, message, is_ssl_error} | null, is_network_down,
    rate_limits {resets_at?, rate_limit_type?} | null}, retry_in_ms, retry_attempt, max_retries};
    terminal_reason one of blocking_limit, rapid_refill_breaker, prompt_too_long, image_error,
    model_error, api_error, malformed_tool_use_exhausted, aborted_streaming, aborted_tools,
    stop_hook_prevented, hook_stopped, tool_deferred, max_turns, background_requested, completed,
    budget_exhausted, structured_output_retry_exhausted, tool_deferred_unavailable, turn_setup_failed.
36. Error and denial texts (the bundle's Yb, Xb, cTt, dA, HIe, GEn @5214522-5217700). A tool's own error
    is "<tool_use_error>TEXT</tool_use_error>" (Edit not found, TaskStop, the sleep guard) or plain (Read:
    "File does not exist. ...", Bash: "Exit code N\n..."), is_error true either way. A rule's denial
    (permissions.deny "Bash(touch d3.txt)" in the repository): system/permission_denied {tool_name,
    tool_use_id, decision_reason_type "rule", message} (stream only), then tool_result is_error
    "Permission to use Bash with command touch d3.txt has been denied." (not in GEn, no Xb prefix: W7
    shows it as OUT; U7: no reason note), and Claude stopped. A denial answered through can_use_tool:
    the tool_result's content is the message rhun sent, verbatim (finding 4; with a reason, finding 24):
    Yb gives Yb (in GEn: nothing shown, state denied), Xb + REASON gives that (U7: the note "Reason:
    REASON"); not recorded again here (the rule's denial made Claude stop before the two asked ones). A
    call stopped while it ran (interrupt during "sleep 20; echo done"): is_error true, content exactly
    the bundle's cTt (Yb + " Correction to the text above: this call was stopped while running, not
    refused before it ran. ..."), tool_use_result the string "User rejected tool use", then the user text
    "[Request interrupted by user for tool use]" (Xk). HIe and dA were not seen.
37. Other system records in these runs: informational (32), permission_denied (36), compact_boundary
    (30), thinking_tokens (29), task_started, task_progress, task_updated, task_notification,
    background_tasks_changed (34), status, init, hook_started, hook_response, commands_changed; in the file
    only: stop_hook_summary, local_command. Not seen in 17 runs: turn_duration, notification,
    local_command_output, the top-level tool_progress and tool_use_summary, api_retry, api_error.
    command_lifecycle states: queued, started, completed, cancelled; no record anywhere carried ran_ahead.

Other things learned

- Without --permission-mode the user's settings decide (C1 holds): with defaultMode auto there,
  current_permission_mode was "auto" and system/init said the same. (c) and (l) passed
  --permission-mode=default to get requests; even then a read-only command (printf) ran unasked.
- AskUserQuestion is offered, and asks, without CLAUDE_CODE_ENABLE_ASK_USER_QUESTION_TOOL, in auto mode
  too (j).
- system/commands_changed (the whole command list, skills included) follows the initialize answer by
  about 300 ms: before system/init or after it, depending on when the first prompt went out.
  tools/claude-shapes.py skips it for that reason; keys.txt has its field order.
- Interrupt (d): the answer {"still_queued":[]} in 7 ms; the partial block as assistant with
  "aborted": true; the user line "[Request interrupted by user]"; then, new in 2.1.330, the cut block's
  content_block_stop, a message_delta without a stop reason (its fields in another order) and a
  message_stop with abandoned_blocks {api_message_id, from_block_index}; then result
  error_during_execution / aborted_streaming, which now reports total_cost_usd and modelUsage.
  Closing stdin after it: exit 1 (C9 holds).
- Interrupt with a request waiting (l): control_cancel_request before the interrupt's answer, then the
  rejected tool_result, "[Request interrupted by user for tool use]", result aborted_tools (C10 holds).
- AskUserQuestion (j): the request comes before message_delta; answered at once, the tool_result came
  before message_delta/message_stop too (2.1.289, answered later, had it after them). ExitPlanMode's
  request came after message_stop. A reader must take both orders.
- Unknown --resume id (k): no initialize answer, one result error_during_execution "No conversation
  found with session ID: ID" whose session_id is ID, exit 1.
- set_permission_mode answers first, then sends its system/status line.
- The session record's entrypoint is the CLAUDE_CODE_ENTRYPOINT value ("rhun"); the record gained
  asksForConvertedSkills. It was gone after every exit, the status-1 exits after an interrupt included.
- New fields, always added and never reordered: api_message_id on every stream_event,
  thinking_display on an assistant thinking record, tool_result_meta on tool results; safety_stops,
  begun_message_ids, model_usage_since_last_result, credential_expires_at on result; system/init gained
  served_by_anthropic, scratchpad_path, original_cwd, additional_directories, ultrathink_available,
  ultrathink_typed_raises.
- stderr carried "[mcp-sdk] SEP-2352 ..." warnings at every start (from the user's MCP sign-ins), not
  errors.

Files

- 01-init.txt: (a), (b), (f) and (h) all give it; unchanged from 2.1.289.
- 02-permission.txt: (c), replaced (the closing message now thinks first).
- 03-ask-user-question.txt: (j), replaced (tool_result before message_delta).
- 05-interrupt.txt: (d), replaced (the cut stream is closed before the result).
- 06-interrupt-pending-permission.txt (l), 07a-resume.txt (e), 07b-fork.txt (g),
  11-resume-unknown-id.txt (k): unchanged.
- keys.txt: the field orders of every 2.1.330 recording; kinds no 2.1.330 run produced are kept from
  2.1.289: control_response error and empty success (an unknown subtype, set_model), get_context_usage
  (categories), mcp_status (mcpServers), the isReplay user string, a failed Write.
- (i) has no shape file: what it shows depends on what the model does in plan mode.
- Phase 2 (excerpts of the recordings, cut where the fake's test cuts them): 12-held.txt (a message
  held during a thinking turn, from initialize to its completed lifecycle), 13-held-interrupt.txt (the
  next part of that run: a held message, an interrupt, the held one runs, a suggestion),
  14-held-noreplay.txt (the same without --replay-user-messages, suggestions off),
  15-permission-replay.txt (Bash asked and allowed with a saved rule, with replay: the first turn),
  16-edit.txt (from the message with the Edit call to the suggestion after its result), 17-slash.txt
  (/context, /cost, /status, /compact after a first turn). The edit, WebFetch, question and plan runs
  have no other shape files: what Claude did around the requests (reads, a subagent, plan files) is
  the model's choice. keys.txt is now the union of the phase 1 lines and every phase 2 recording's.
- ../claude/help-2.1.330.txt is `claude --help` of the recorded CLI; help-2.1.289.txt the earlier one.
- Phase 3 (excerpts, made with tools/claude-shapes.py): 18-tools.txt (the first turn of the tools run: two
  Reads in one message, the first's result before the second call's record), 19-thinking.txt (the
  summarized thinking turn, --fold: thinking_tokens and thinking_delta alternated 35 times),
  20-compact.txt (from the system/init of /compact to its result), 21-agent.txt (the agent run without
  the two initialize members, from the prompt to the first result), 22-hooks.txt (--hooks, the
  --include-hook-events run from the start to the result). The file's records: file-keys.txt (the field
  order of every kind of line of every conversation file and subagent file of the runs, --file-keys),
  file-tools.txt (the tools run's first two turns), file-compact.txt (the hooks run from /hi to the
  summary), file-agent.txt and file-subagent.txt (the agent run without the two members: the
  conversation's file and the agent's file), file-thinking.txt (the summarized thinking run); the
  file-*.txt shapes leave out system/stop_hook_summary, which only the maintainer's Stop hooks write.
  keys.txt is now the union of the phase 1 and 2 lines and every phase 3 recording's.

How they were made: a throwaway recorder (not kept) ran the real CLI in an empty temporary git
repository with the pinned line, wrote each line the CLI sent as {"dir":"in","msg":...} and each line
sent to it as {"dir":"out","msg":...}; then `tools/claude-shapes.py REC.jsonl` gave each shape file and
`tools/claude-shapes.py --keys REC.jsonl...` keys.txt. The prompts were "Reply with the word ok" and a
few as small (touch a file, count, ask red or blue, plan one file); 12 in all.
Phase 2: a recorder of the same kind (not kept), one empty temporary git repository per run under the
scratch folder, 20 model prompts ("Reply with the word ok", touch a file, edit a one-line file, fetch
example.com, two questions, plan one file, count to 30 or 60) and 3 local commands, 13 starts without
a prompt; the account's email and organization, env values and anything shaped like a token redacted
in the saved lines; afterwards the runs' folders under <config>/projects and the one plan file were
deleted. Settings: the only request that wrote the user's own settings was update_settings
userSettings effortLevel (finding 12, three writes and one corrective write); its per-model value was
read before, written back and checked in a new process (userSettings equal to the first reading). No
other request with userSettings was sent; rules were saved only in the repository's
.claude/settings.local.json or the session.
Phase 3: a recorder of the same kind (not kept) that also copied each run's conversation file and its
<id>/subagents/ folder (account ids, organization ids and anything token-shaped redacted, the copies of API
requests and the instruction attachments dropped) before deleting the run's folder under
<config>/projects; 17 runs, one temporary git repository each (notes.txt of five lines, a.py of ten, a 1x1
dot.png), 31 model prompts of one sentence (haiku but for two sonnet turns), a few local commands. Nothing
wrote the user's settings: no update_settings; hooks, a deny rule and a custom command only in the
repositories' .claude/; ~/.claude/settings.json had the same SHA-256 before the first run and after the
last. Left under ~/.claude by the CLI: session-env/<id> for each run and tasks/<id> of the task tools run
(not deleted); the CLI's $TMPDIR/claude-UID/<slug> folders (task outputs, the stored image) were deleted.
