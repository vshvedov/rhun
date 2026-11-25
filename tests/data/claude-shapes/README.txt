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
        [--resume-session-at=ID]                  (a fork from a message: finding 102)

  No -p (decision 1). cwd: the conversation's folder. Environment: the login environment plus
  CLAUDE_CODE_ENTRYPOINT=rhun and MCP_CONNECTION_NONBLOCKING=true (since phase 6 also
  CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true, finding 103, and for a turn cut off by quitting the two
  CLAUDE_CODE_RESUME_INTERRUPTED_TURN variables, finding 105), without CLAUDECODE,
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

Phase 4 findings (CLI 2.1.330, recorded 2026-11-23 on macOS, same subscription)

Letters are those of task 1 of the phase 4 plan (2026-11-24-claude-chat-phase4.md): (a) is 38 and 39, (b) 40, (c)
41, (d) 42, (e) 43, (f) 44, (g) 45, (h) 46, (i) 47, (j) 48, (k) 49, (l) 50, (m) 51.
Command line and environment: phase 3's (the pinned line, --replay-user-messages, --permission-mode=default,
--session-id=UUID, --model=haiku --effort=low; HOME, PATH, USER, LANG, TMPDIR and rhun's three forced values);
initialize phase 3's {"hooks":null,"promptSuggestions":false,"supportedDialogKinds":[the two],
"perTaskStopAffordance":true,"forwardNestedSubagentToolCalls":true} plus the members a finding names. 24
processes, one temporary git repository each (notes.txt "alpha\nbravo\ncharlie\ndelta\necho\n", crlf.txt the
five words with CR LF, a.py of ten lines with a syntax error on line 4, the 1x1 dot.png, a two-page two.pdf of
852 bytes, "a b.txt", src/m.c), 34 model turns of one sentence. "The answer" is the control_response rhun
wrote; with --replay-user-messages every one of them comes back on stdout (18), which the shape files show.

38. Image blocks. [image jpeg, image gif, image webp, text] (1x1 each, 286, 43 and 68 bytes): accepted, Claude
    counted 3. The replay ({type, message, session_id, parent_tool_use_id, uuid, timestamp, isReplay}) and the
    file's prompt line hold the blocks unchanged (same base64) for these small images; the prompt line has
    imagePasteIds [1, 2, 3] (one number per image, counted across the conversation: in another run the second
    message's single image was [2]) and a new key turnPromptId; it is followed by ONE user line
    isMeta true whose content is one text block per image, "[Image: source: /private/tmp/claude-UID/<slug>/<session
    id>/images/N.EXT]" (EXT jpg, gif, webp, png: the stored copy is the bytes rhun sent). That folder was
    /private/tmp/claude-501/... although TMPDIR named another folder (node's own cache did go to TMPDIR). The API
    request (the file's api-request-blob) carries the blocks, the prompt's text with "\n" appended, and the
    "[Image: source: ...]" texts in the same user message. An image block whose data is not an image (base64 of
    a line of text, media_type image/png) is NOT refused: the CLI replaces it, in the replay, the file and the
    request, with the text block "[Image could not be processed: Unable to resize image — image processing is
    unavailable and dimensions could not be read from the file header. Please convert the image to PNG, JPEG,
    GIF, or WebP.]"; no imagePasteIds, no isMeta line, a normal turn, and the next turn is normal too.
39. The image limit. One process each, [image png, text "Reply with the word ok."]: noise PNGs padded to the
    file size with a private ancillary chunk (prVt): 3 MiB (1000 x 1000 RGB), 5, 8 and 10 MiB (1024 x 1024
    RGBA): ALL FOUR gave a normal turn (result success, about 3.5 s). The CLI re-encoded each before sending:
    the replay and the file's prompt line hold {media_type "image/jpeg", data} of 1000 x 1000 or 1024 x 1024
    pixels and about 505 KB (673,392 base64 characters for each 1024 x 1024 one: the padding is gone); the
    images/1.png copy is the original file, byte for byte. 8000 x 8000 (a grey PNG of 226,477 bytes): normal
    turn; replayed as image/png 1932 x 1932, 35,744 bytes. So the CLI scales pixels down itself (the binary's
    defaults: maxWidth 2000, maxHeight 2000, maxBase64Size 5242880, targetRawSize 3932160, per-model
    image_limits may lower them) and re-encodes large files: pixels are limited by the CLI, not refused.
    MP_IMAGE_MAX: the largest file size that gave a normal turn is 10 MiB (10,485,760 bytes), the largest
    tried; nothing was refused. NOT known: a size above 10 MiB (rhun's own 16 MiB line limit makes 12 MiB of
    file bytes, 16 MiB of base64, the most a line can carry); whether a photo-like PNG of large dimensions that
    the CLI cannot shrink under 5 MB fails ("Unable to resize image (N base64). The image exceeds the 5 MB API
    limit and compression failed. ..." is in the binary; not provoked). Megabytes do NOT come back in the
    replay of these: the echo carries the re-encoded image.
40. Documents. [document {source {type text, media_type text/plain, data "The secret word is mango.\n"}, title
    "secret.txt"}, document {source {type base64, media_type application/pdf, data}, title "two.pdf"}, text]:
    accepted; Claude named both titles, the secret word and the text of both PDF pages ("PAGE ONE KIWI", "PAGE
    TWO PLUM"): it sees the title and reads the PDF. Replay and file: the blocks unchanged (block keys type,
    source, title as sent), no imagePasteIds, no isMeta line. A text document of 1 MiB (16,384 lines of 63
    "x"): replayed unchanged, then refused by the CLI itself before any request (usage all 0): assistant
    text with error "invalid_request" "Prompt is too long · the request is ~1095002 tokens (limit 1000000) but
    this conversation is only ~274786 tokens — the rest is system prompt, tool definitions, and attachment
    content. A single-exchange conversation cannot be compacted; reduce attached files/tools or start with
    less context.", result subtype success with is_error true, terminal_reason prompt_too_long, stop_reason
    stop_sequence; the process exited 1 at EOF. How many tokens a real text of 1 MiB counts is not known.
41. Order and emptiness. [text "<ide_selection>The user selected the lines 2 to 3 from PATH:\nbravo\ncharlie\n\n
    This may or may not be related to the current task.</ide_selection>", image png, document text
    "notes.txt", text "<terminal name=\"zsh\">\n$ echo hi\nhi\n</terminal>", text prompt]: accepted; replay,
    file and API request keep exactly that order (the file: imagePasteIds [1], then the isMeta image line).
    [image] alone (no text block): accepted, a normal turn ("I got the image, but there's no text with it").
    [text "<ide_opened_file>The user opened the file PATH in the IDE. This may or may not be related to the
    current task.</ide_opened_file>"] alone: accepted, a normal turn (Claude asked what to do with the file).
    Nothing in the CLI treats these tags specially: they reach the model as written.
42. Mentions in stream-json input: THE CLI EXPANDS THEM ITSELF. "... @notes.txt ...": no stream record but the
    replay (unchanged text), no Read call; the file gets, after the prompt line, attachment {type "file",
    filename ABSOLUTE, content {type "text", file {filePath, content, numLines, startLine, totalLines}},
    displayPath "notes.txt", savedCopyFraming {enveloped false}} (the line also has rendered and renderedRole),
    and Claude answered from it. "@notes.txt#2-3" (the extension's Alt+K form): the WHOLE file (startLine 1,
    numLines 6): "#2-3" is not read as a range. "@notes.txt#L2-3": lines 2 and 3 only (startLine 2, numLines 2,
    content "bravo\ncharlie"). "@\"a b.txt\"": attachment file "a b.txt". "@src/": attachment {type
    "directory", path, content "m.c" (the listing), displayPath "src"}. "@missing.txt": nothing at all (no
    attachment, no error). "@/ABSOLUTE/outside.txt" (outside the repository): attached, displayPath
    "../../fix/outside.txt" (relative to the cwd). Each was the first mention of its file in its process.
43. inline_pastes. The schema in the binary: inline_pastes is "Text the user pasted that is still in
    message.content where they put it: each entry one paste. ... the CLI may wrap each entry in
    <pasted_content> tags where it still stands in the last text block, or where a text block holds nothing
    else. It looks for the first 100 entries that are not blank." (an entry is a string; not an array:
    "malformed_inline_pastes", the rest past 100: "inline_pastes_cut"). Sent: content [text P2, text "Here is
    my log: " + P1 + " Reply with the word ok."], "inline_pastes":[P1, P2] beside message (P1 and P2 of four
    lines each): accepted, a normal turn; the replay, the file's prompt line and the request carry the
    REWRITTEN text: [text "\n\n<pasted_content id=\"4583\">\nP2\n</pasted_content id=\"4583\">\n", text "Here is
    my log: \n\n<pasted_content id=\"4583\">\nP1\n</pasted_content id=\"4583\">\n\n Reply with the word ok."]
    (one id for both pastes of the message; how it is chosen is not known). The file keeps no inline_pastes
    member. So the CLI takes the member and wraps the pastes; a reader of the replay or the file sees the tags.
44. The server (f). initialize with "sdkMcpServers":["rhun"]: the answer has the keys of decision 9 and nothing
    new (no sdk_mcp_manifests_parked, no mcp_servers_applied). About 0.36 s after the initialize request, and
    about 40 ms BEFORE the initialize answer, the CLI sends control_request {type, request_id (a uuid), request
    {subtype "mcp_message", server_name "rhun", message}} with message {"method":"initialize","params":
    {"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"claude-code","title":"Claude
    Code","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code",
    "version":"2.1.330"}},"jsonrpc":"2.0","id":0}; after rhun's answer (and the initialize answer)
    {"jsonrpc":"2.0","method":"notifications/initialized"}, then {"method":"tools/list","jsonrpc":"2.0","id":1},
    all before the first prompt is read. Answers taken: {"mcp_response":{"jsonrpc":"2.0","id":ID,"result":R}}
    for a request, {"mcp_response":{"jsonrpc":"2.0","result":{},"id":0}} for a notification. JSON-RPC ids count
    up per server (tools/call 2, 3, ...). system/init's mcp_servers gains {name "rhun", status "connected",
    source "sdk"} and its tools list "mcp__rhun__getDiagnostics" (listed although the tool is deferred: 46);
    mcp_status's entry {name, status "connected", serverInfo {name, version}, transport "sdk", scope "dynamic",
    source "sdk", tools [{name, annotations {readOnly true}}]}. tools/list answered 3 s late: mcp_status 0.5 s
    after the start had no rhun entry at all; a prompt sent then waited: its system/init came only after the
    answer (3.5 s), with the tool. tools/list answered with a JSON-RPC error: asked again 250, 500 and 1000 ms
    later (ids 2, 3, 4), then the server stays "connected" with tools []. The initialize answer naming
    protocolVersion "2024-11-05" (asked "2025-11-25"): accepted, connected, tools listed.
45. Manifests (g). The same start with "sdkMcpServerManifests":{"rhun":{"initializeResult":{protocolVersion,
    capabilities, serverInfo},"toolsListResult":{"tools":[TOOL]}}}: the answer gains
    "sdk_mcp_manifests_parked":{"rhun":"parked"} (after other_hook_ask_outranks_host) and NO mcp_message comes at
    the start (no initialize, no notifications/initialized, no tools/list); mcp_status is "connected" with the
    tool at once; the call (46) came the same way, as tools/call id 2. It saves the three round trips.
46. A tool call (h). tools/list [{name "getDiagnostics", description, inputSchema {type object, properties
    {uri, minSeverity}}, annotations {title, readOnlyHint true}}]. "Call the getDiagnostics tool of the rhun
    server ...": the assistant's tool_use {type, id, name "mcp__rhun__getDiagnostics", input {}, caller {type
    "direct"}} (Claude passed no arguments; in two of four runs it first called ToolSearch "select:
    mcp__rhun__getDiagnostics"). In default mode can_use_tool IS asked, readOnlyHint notwithstanding: request
    {subtype, tool_name, mcp_server {name "rhun", source "sdk"}, display_name "GetDiagnostics", input,
    permission_suggestions [{type "addRules", rules [{toolName "mcp__rhun__getDiagnostics"}], behavior "allow",
    destination "localSettings"}], server_policy_ask_only false, tool_use_id}: no tool_kind, no description.
    After the allow: mcp_message {"method":"tools/call","params":{"name":"getDiagnostics","arguments":{},
    "_meta":{"claudecode/toolUseId":TOOL_USE_ID,"progressToken":ID}},"jsonrpc":"2.0","id":ID}. The answer
    {"content":[{"type":"text","text":T}]}: tool_result content is that LIST (not a string), no is_error key,
    tool_use_result the same list; the file's line the same (toolUseResult the list). With "isError":true:
    tool_result content the STRING T, is_error true, tool_use_result "Error: T"; when the tool had not been
    loaded by ToolSearch the CLI appends "\n\nThis tool's input schema was not in your prompt when you called
    it. The input schema is: SCHEMA\nIf your input does not match this schema, correct it and call the tool
    again. ..." (Claude then retried twice). Interrupt while the call's answer was held 5 s: NO
    control_cancel_request; 16 ms after the interrupt an mcp_message {"jsonrpc":"2.0","method":
    "notifications/cancelled","params":{"requestId":6,"reason":"AbortError: remote-cancel"}}, the interrupt's
    answer {still_queued []}, tool_result is_error with exactly 36's stopped-while-running text,
    tool_use_result "User rejected tool use" (the file: toolDenialKind "user-rejected"), "[Request interrupted
    by user for tool use]", result error_during_execution aborted_tools; the answer written 4 s later was
    echoed and changed nothing; the process exited 1 at EOF (C9).
47. Notifications from the CLI (i). In every run with the server (an Edit, a Write, two tool calls, an
    interrupt) the only notifications were notifications/initialized and notifications/cancelled: NO
    experiment_gates, file_updated, open_artifact or offer notifications. The binary sends experiment_gates
    and the extension's other notifications only to an SDK server named exactly "claude-vscode"
    (e.find(g => g.name === "claude-vscode")); a server named rhun gets none.
48. Hooks (j). initialize "hooks":{"PreToolUse":[{"matcher":"Edit|Write|MultiEdit","hookCallbackIds":
    ["hook_0"]},{"matcher":"Edit|Write|Read","hookCallbackIds":["hook_1"]}],"PostToolUse":[{"matcher":
    "Edit|Write|MultiEdit","hookCallbackIds":["hook_2"],"contextOnly":true}]} with sdkMcpServers: the answer
    has "hooks_applied":true (after current_permission_mode). A callback: control_request {subtype
    "hook_callback", callback_id "hook_N", input, tool_use_id}: NO issued_at and NO deadline_ms. input keys, in
    order: session_id, transcript_path, cwd, scratchpad_dir, prompt_id, permission_mode, [agent_id,
    agent_type: a subagent's call], effort {level}, hook_event_name, tool_name, tool_input, [tool_response:
    PostToolUse], tool_use_id, [duration_ms: PostToolUse]. Read: hook_1 only, then the tool runs (no
    can_use_tool). Edit and Write: hook_0 and hook_1 sent together (hook_1 arrives while hook_0 is still
    unanswered), can_use_tool only after BOTH were answered, the tool runs, then hook_2 (its tool_input is
    the input as allowed, updatedInput included; tool_response the structured result, as tool_use_result),
    then the tool_result record. Answers {"continue":true} taken. hook_2 answered {"continue":true,
    "hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"<ide_diagnostics>[\n  {\n
    \"filePath\": ..., \"line\": 2, \"column\": 1, \"message\": \"Unknown word: BRAVO\", \"code\": \"spell\",
    \"severity\": \"Warning\"\n  }\n]</ide_diagnostics>"}}: no stream record carries it (no record held
    ide_diagnostics, no <post-tool-use-hook> text); the file has, right after the call's tool_result line
    (parentUuid that line's uuid), attachment {type "hook_additional_context", content [THE CONTEXT],
    hookName "PostToolUse:Edit", toolUseID, hookEvent "PostToolUse"} with rendered [{content
    "<system-reminder>\nPostToolUse:Edit hook additional context: THE CONTEXT\n</system-reminder>"}] and
    renderedRole "system"; no hook_success line for a callback hook. Claude mentioned the problem ("flagged
    notes.txt line 2 with a spell-check warning: Unknown word: BRAVO"). hook_0 held 65 s: the CLI waited the
    whole time (no deadline), sent tool_progress {type, tool_use_id "hook-PreToolUse-TOOL_USE_ID-heartbeat-N",
    tool_name "PreToolUse", parent_tool_use_id TOOL_USE_ID, elapsed_time_seconds 30 then 60, heartbeat true,
    uuid, session_id} every 30 s, and went on 12 ms after the answer. An answer {"weird":true}: taken
    silently, the Edit ran. A subagent's Read and Edit (Agent tool, general-purpose, foreground): the same
    callbacks with agent_id and agent_type "general-purpose"; its can_use_tool Edit has agent_id.
49. The answer to an edit (k). Edit allowed with updatedInput {file_path, old_string: the whole file,
    new_string: the whole changed file, replace_all false}: the file on disk is the new text; tool_result
    "The file PATH has been updated successfully. (file state is current ...)", tool_use_result {filePath,
    oldString, newString (the whole texts), originalFile, structuredPatch [one hunk, oldStart 1 oldLines 5,
    lines " alpha", "-bravo", "+BRAVO", " charlie", ...], userModified false, replaceAll false}. Write allowed
    with another content ("hello from rhun\n" for Claude's "hi"): that content is written, "File created
    successfully at: PATH ...", {type "create", ..., content the new text}; Claude is not told (it reported
    "hi"). deny {"message":"User cancelled the edit","interrupt":true}: tool_result is_error with the
    REJECTED text (36's Yb; our message does not appear), tool_use_result "User rejected tool use", user
    text "[Request interrupted by user for tool use]", result error_during_execution aborted_tools with
    permission_denials [{tool_name, tool_use_id, tool_input}]; the file's line has toolDenialKind
    "user-rejected", toolDenialBeforeRun true (as finding 24's Write). An allow whose file changed on disk
    before the answer (the request's input unchanged): is_error "File content has changed since it was last
    read. This commonly happens when a linter or formatter run via Bash rewrites the file. Call Read on this
    file to refresh, then retry the edit." (no <tool_use_error> tags), tool_use_result "Error: " + that, the
    file untouched; the file gets attachment edited_text_file. CRLF: the CLI reads crlf.txt as LF (Read's
    file.content and the Edit's originalFile "one\ntwo\n..."), so Edit strings are LF (Claude's were single
    words, "two" -> "TWO"); allowed as asked the file stays CR LF: b"one\r\nTWO\r\nthree\r\nfour\r\nfive\r\n";
    allowed with a whole-file updatedInput in LF only ("one\nTWO\nthree\n..." -> "one\nTWO\nTHREE\n..."):
    applied, the file b"one\r\nTWO\r\nTHREE\r\nfour\r\nfive\r\n" (the CLI matches LF text against the CR LF
    file and writes CR LF back). Not provoked: an Edit whose strings span lines in a CR LF file.
50. The note (l). initialize with "appendSystemPrompt" (a short note of rhun's own, "# rhun Editor Context" with
    the extension's link rules) and "systemPromptSnapshot":true: success, the answer's keys unchanged; without
    systemPromptSnapshot: success too. "Give me a Markdown link to line 2 of notes.txt": the reply was
    exactly "[notes.txt:2](notes.txt#L2)" (relative to the cwd, #L and the line).
51. Without the server (m). The 17 processes started without sdkMcpServers and hooks (38 to 43, 49, 50) got no
    mcp_message and no hook_callback. sdkMcpServers ["rhun"] that never answers (with
    MCP_CONNECTION_NONBLOCKING=true): the CLI sent initialize again at 30 s (JSON-RPC id 104) and gave up at
    60 s; the first prompt, written at once, waited: its system/init came 60.1 s after it, mcp_servers rhun
    "failed", then a normal reply; mcp_status {name, status "failed", transport "sdk", scope "user", source
    "sdk"}. MCP_CONNECTION_NONBLOCKING does not apply to an SDK server.

Phase 7 findings (CLI 2.1.330, recorded 2026-11-23 on macOS, the same subscription)

Numbering: 38 to 59 are other phase 7 work's; the dialogs of the first part are 60 to 66. Command line: the
pinned one with --setting-sources=user,project,local --permission-mode=default --model=haiku --effort=low;
environment HOME, PATH, USER, LANG, TMPDIR, CLAUDE_CODE_ENTRYPOINT=rhun, MCP_CONNECTION_NONBLOCKING=true;
initialize {"hooks":null}; a temporary git repository with a one-line CLAUDE.md. Two runs: read-only
requests right after initialize, then the same after one prompt ("Reply with the word ok"). Every request
here was answered without a turn and without any record around its answer. Account details (email,
organization) and the home folder are redacted in what is kept.

60. get_status: {sections: [{title, rows: [{label, value}]}]}, all values strings. "Session": Version,
    Session name (only after a turn: the conversation's title), Session ID, Session kind ("interactive"),
    Peer address ("uds:/tmp/cc-socks/PID.sock"), cwd (the resolved folder), Login method ("Claude Ultra
    account"), Organization, Email; "Environment": Model (the resolved id), MCP servers ("32 need auth, 8
    pending, 20 failed · /mcp"), Setting sources ("User settings"), Auto mode server ("Disabled"). The
    extension shows cwd as "Working folder", Peer address as "Messaging address", Session kind as
    "Session type" (webview rzn); the rest as they come.
61. get_usage: {session, subscription_type, rate_limits_available, rate_limits, behaviors}. session
    {total_cost_usd, total_api_duration_ms, total_duration_ms, total_lines_added, total_lines_removed,
    model_usage}: zeros and {} before a turn; after one model_usage {MODEL: {inputTokens, outputTokens,
    cacheReadInputTokens, cacheCreationInputTokens, webSearchRequests, costUSD, contextWindow,
    maxOutputTokens, thinkingTokens, cacheCreationEphemeral5mInputTokens,
    cacheCreationEphemeral1hInputTokens, canonicalModel, provider "firstParty", costBasis "list"}}.
    subscription_type "max" (initialize's account says "Claude Ultra": not the same words). rate_limits:
    five_hour null, seven_day {utilization 14 (an integer here), resets_at "YYYY-MM-DDTHH:MM:SS.ffffff+00:00",
    limit_dollars, used_dollars, remaining_dollars, locked_reason}, about 30 more keys null (code names),
    extra_usage {is_enabled, monthly_limit, used_credits, utilization, currency, ..., credits_can_pay},
    limits [{kind weekly_all|weekly_scoped, group, percent, severity, resets_at, scope {model {id,
    display_name}, surface}, is_active}], spend {...}, seven_day_breakdown {as_of, window_started_at, rows
    [{key, display_name, percent, percent_of_limit}]}, weekly_scoped_shares, model_scoped [{display_name
    "Fable", utilization 16, resets_at}]. behaviors {day, week}: {recommendations [{key, pct, title,
    detail?}], fix {keys, messages}, request_count, session_count, behaviors [{key, pct, count}], agents
    [{name, pct}], skills, plugins, mcp_servers}: built from this machine's logs (titles name local files);
    null with skip_behaviors true.
62. get_context_usage: {categories [{id, name, tokens, color, kind "used"|"deferred"|"buffer"|"free",
    isDeferred (deferred ones only)}], totalTokens, maxTokens, rawMaxTokens, autocompactSource
    "model-default", percentage (an integer), gridRows, model, memoryFiles [{path, type "User"|"Project",
    tokens}], mcpTools [{name, serverName, tokens, isLoaded}], mcpInstructions [{serverName, tokens}],
    agents [{agentType, source, pluginId?, path, tokens}], slashCommands {totalCommands, includedCommands,
    tokens}, skills {totalSkills, includedSkills, tokens, skillFrontmatter [{name, source, path, tokens}]},
    autoCompactThreshold, isAutoCompactEnabled, messageBreakdown {toolCallTokens, ..., attachmentsByType},
    apiUsage}. Categories here: System prompt, System tools, MCP tools, MCP server instructions, MCP tools
    (deferred), System tools (deferred), Custom agents, Memory files, Skills, Messages, Autocompact buffer,
    Free space (the free space makes the used, buffer and free add up to maxTokens). apiUsage null before a
    turn, {input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens} after one.
63. Output styles: initialize's output_style "default", available_output_styles ["default", "Proactive",
    "Concise", "Explanatory", "Learning"] (two of them this machine's), user_output_styles_dir
    "<config>/output-styles"; reload_output_styles (it only reads the style files again) answers
    {available_output_styles: [the same]}; get_settings' effective has no outputStyle while none is set.
    Picking one is update_settings localSettings {outputStyle} (finding 12): it writes the project's
    .claude/settings.local.json, so it was not tried here (the fake's).
64. get_skills_dialog: {skills: [{name, display_name, description, source "user"|"plugin"|"claude.ai sync",
    tokens, state, advertised, handles {unqualified_name?, aliases?, bare_name_reserved?}, locked_by?
    "plugin"}]}: no "dialog" member (the extension's host adds it). 133 skills, every state "on"; a plugin's
    are locked_by "plugin" (aliases: their names without the plugin), some advertised false. A name may be
    "plugin:skill" while display_name is the bare name. set_skill_state writes settings: not tried (the
    fake answers it with {skills} as above).
65. get_memory_dialog: {files [{kind "user"|"other"|"project", path, label ("User instructions", "Project
    instructions", or "L PATH" for a file a CLAUDE.md imports), description ("Saved in ~/.claude/CLAUDE.md",
    "Checked in at ./CLAUDE.md"), exists}], folders [{kind "auto", path "<config>/projects/<slug>/memory/",
    label "Open auto-memory folder", description ""}], memories [], auto_memory {enabled, toggleable, status
    "on"}, auto_dream {shown false, enabled, toggleable, status "off", detail ""}}. Asking it made the
    empty <config>/projects/<slug>/memory/ folder, with no prompt. set_memory_setting writes the user's
    settings: not tried.
66. get_settings (asked to see outputStyle): its effective member carries the user's whole permission rules,
    and a rule can hold a secret (here an allow rule's command had an API key in it). Nothing of that answer
    is kept in these recordings, and rhun reads only the members it needs from it.
    ~/.claude/settings.json had the same SHA-256 before the first run and after the last; left under
    ~/.claude: session-env/<id> of each run; the runs' folders under <config>/projects were deleted.

Phase 7 part 3 (claude-chat-p7c, 2026-11-23): one run of the installed 2.1.330 in the clean environment
tests/claude-real.py builds (a temporary git repository, --model=haiku --effort=low, no prompt), read-only
control requests only; ~/.claude/settings.json had the same SHA-256 before and after. Not kept as shape
files (the answers name the account's cloud sessions).

100. side_question {question} answers {response "ok", synthetic false}, preceded by system/
     control_request_progress {request_id, status "started", uuid, session_id} (the binary's schema adds
     status "api_retry" with attempt, max_retries, retry_delay_ms, error_status). history must be an array of
     {question, response} strings: {question, answer} was refused with the text "undefined is not an object
     (evaluating 'q.response.endsWith')"; the binary's own words for a bad one are "side_question: question
     must be a string and history an array of {question, response} strings". It needs no conversation (asked
     before any prompt) and does not touch the conversation's turn or file. The binary names an error code
     side_question_busy (as many side questions and title calls as the session may run at once) and a text
     for no answer, "(No answer available for this side question. Try again, or ask in the main
     conversation.)"; neither was provoked.
101. get_chrome_dialog answers {allowed, subscriber, wsl, installed, connected, enabled_by_default,
     at_startup, urls {install "https://claude.ai/chrome", reconnect "https://clau.de/chrome/reconnect",
     permissions "https://clau.de/chrome/permissions"}} (this account: installed false, connected false,
     enabled_by_default true, at_startup true). get_chrome_browsers answers the error "Claude in Chrome is not
     connected in this session". The initialize answer carries remote_control_available (true here),
     remote_control_auto_enable, remote_control_auto_on_by_default, remote_control_auto_connect_default
     (false) and ide_rc_auto_enable_gate; list_cloud_sessions answered {status "ok", sessions [{id, title,
     updated_at, status, environment_kind, repository {owner, name}, branch, ...}]} on this account (the cloud
     session list the Web tab and teleport would read). NOT tried, because they act on the account:
     remote_control {enabled} (it publishes the session to claude.ai/code), set_chrome_setting, teleport.
     From the binary's schema only (unrecorded): system/bridge_state {state (connected, ready, failed,
     policy_disabled...), detail, failure_kind (failed), recovered (connected), bridge_epoch}; remote_control's
     answer has bridge_session_id. The fake's remote_control follows that schema and says so.

Settings dialogs (claude-chat-p7b, 2026-11-24, CLI 2.1.330). Learned with HOME and CLAUDE_CONFIG_DIR in a
temporary folder (not signed in: control requests are answered locally without it) and a temporary git
repository; nothing touched ~/.claude (settings.json had the same SHA-256 before and after).

80. mcp_status answers {mcpServers: [{name, status, config, scope, error?, tools?}]}: [] with none; seen here
    only "failed" and "disabled" (connected, needs-auth and pending are the extension's other badges). A server added after the process started is not in it
    (the extension says "It will be available in new sessions."). A failed stdio server (/usr/bin/false)
    and an unreachable HTTP one both showed "failed"; mcp_reconnect of the failed one: error "Connection
    closed". mcp_toggle {serverName, enabled false} wrote projects[cwd].disabledMcpServers ["NAME"] in
    <config>/.claude.json and the next mcp_status said "disabled".
81. `claude mcp add --scope S --transport T [--env K=V]... [--header "H: v"]... -- NAME CMD|URL ARGS...`:
    stdout "Added stdio MCP server NAME with command: CMD ARGS to local config" (HTTP: "Added HTTP MCP server
    NAME with URL: URL to project config" and "Headers: {...}"), then "File modified: PATH"; exit 0. Local
    scope: projects[cwd].mcpServers in <config>/.claude.json ({type, command, args, env}); user: mcpServers
    there; project: <cwd>/.mcp.json ({type, url, headers}). Errors on stderr, exit 1: "MCP server NAME
    already exists in local config", "Invalid name NAME. Names can only contain letters, numbers, hyphens,
    and underscores.", `mcp remove`: "No MCP server named "NAME" in user scope".
82. get_hooks_listing answers {events [{name, summary, supportsMatcher, hookCount}], hooks [{event, matcher,
    source "localSettings"|..., sourceLabel "Local settings (.claude/settings.local.json)", type,
    displayText, commandText, contentLabel "Command", editable {matcher, config}}], eventCatalog (33 events:
    PreToolUse .. MessageDisplay, each {name, summary, supportsMatcher}), policy {disabledByPolicy,
    managedOnly, pluginOnly, allDisabled, policyHookCount}}.
83. `claude edit-hook --json`, the edit on stdin: {op "add", source, event, matcher, hook} ->
    {"ok":true}, exit 0, the hook written to that settings file ({matcher, hooks [...]} per event; no
    matcher key for ""). Remove needs the top-level event too: {op "remove", source, event, target {event,
    matcher, hook}}; without it "edit_hook: event is not a known hook event" (code bad_request). Failures
    print one line on stdout and the error on stderr, exit 1: {"ok":false,"error":"edit_hook: source must be
    userSettings, projectSettings, or localSettings","code":"bad_request"}; "that hook is no longer in
    localSettings; it may have been changed outside this dialog" (target_missing); and the refusals, which
    carry the extension's refusal member: not_a_list ("the Stop entry in localSettings is not a list; fix
    the file by hand", refusal {code "not-a-list", file PATH}), file_unloadable ("the localSettings file has
    errors and could not be loaded; fix it by hand first", {code "unloadable", file}), target_ambiguous
    ("more than one identical hook is configured for Stop in localSettings; edit the file by hand",
    {code "twins", file}). The top-level code is not the refusal's code.
84. list_permission_rules answers {state: {rules [{behavior, source, rule, description?, editability}],
    workspaceDirectories [], originalCwd, managedOnly}}. `claude edit-permission-rules --json`: {op "add",
    behavior, destination, rules [...]} -> {"ok":true,"warnings":[],"stored":[...]}; {op "remove",
    behavior, source, rule} -> {"ok":true,"warnings":[],"stored":[]} (it leaves "allow": [] behind); a rule
    with unbalanced parentheses: stderr "Malformed Tool(content) rule — Rules take the form Tool or
    Tool(content) and must end at the closing ")"; parentheses inside the content are literal", exit 1.
85. get_sandbox_dialog answers {supported, locked, overrides_locked, policy_origins [], enabled,
    enabled_in_settings, mode "auto-allow"|"regular"|"disabled", auto_allow_available, no_sandbox_allowed,
    unsandboxed_fallback, dependencies {errors, warnings}, excluded_commands, restrictions {fs_deny_read,
    fs_allow_read, fs_allow_write, fs_deny_write, network_allowed_domains, network_denied_domains,
    network_managed, unix_sockets, allow_all_unix_sockets, ignored_glob_patterns, ignored_unix_sockets}}.
    `claude edit-sandbox-settings --json` with {mode}, {excludeCommand} or {allowUnsandboxedCommands}:
    {"ok":true,"written":EDIT}; it writes .claude/settings.local.json's sandbox {enabled,
    autoAllowBashIfSandboxed, excludedCommands, allowUnsandboxedCommands}.
86. `claude plugin list --json`, `plugin list --json --available` and `plugin marketplace list --json`
    print indented JSON over many lines (a reader of the last line alone sees nothing). Installed: [{id,
    version, scope, enabled, installPath, installedAt, lastUpdated, projectPath?, projectEnabled?}].
    --available: {installed, available [{pluginId, name, description, marketplaceName, version, source
    {source "url"|"git-subdir", url, path?, sha}}]}: 3783 plugins, 2.2 MB, all from
    anthropic-plugin-directory, which marketplace list does not show ([] in a new configuration) although
    `marketplace update` names it among the "Available marketplaces"; no installCount.
87. The changes print one line of JSON on stdout (and a "✘ ..." line on stderr when they fail): install
    {command "install", outcome "ok", plugin, pluginId, scope, message "Successfully installed plugin: ID
    (scope: project)"}; failed {outcome "failed", message, failureCode "not_found"}; disable/enable {command,
    outcome, plugin, pluginId, scope, message}; update {..., updateOutcome "up_to_date", oldVersion,
    newVersion}; uninstall of one not installed: failureCode "not_installed"; marketplace remove|update of an
    unknown one: {command "marketplace-remove", marketplace, outcome "failed", message "Marketplace 'X' not
    found", failureCode "not_configured"}; marketplace add of a missing path: failureCode
    "invalid_source".
88. `plugin configure --json -- ID` prints indented {pluginId, displayName, schema, inputs, choices,
    configured, unconfigured}; for an id not installed, stderr "No installed plugin has the id "ID". Use its
    full id (name@marketplace), as `claude plugin list` shows it.", exit 1. `plugin marketplace add
    --from-link --resolve-only --json -- SRC` answers {"existing":null} for a new source. reload_plugins
    answers {commands, agents, plugins, mcpServers, error_count}.

Phase 6 part 2 (claude-chat-p6b, 2026-11-24): the installed 2.1.330 in a throwaway HOME and CLAUDE_CONFIG_DIR (so not
signed in: every prompt got the synthetic assistant "Not logged in · Please run /login" and a result with
terminal_reason api_error), a temporary git repository with a.txt, the pinned line with --replay-user-messages
--permission-mode=default, environment HOME, CLAUDE_CONFIG_DIR, PATH, USER, LANG, TMPDIR and rhun's two forced
values. A second turn with a file checkpoint was written into the file by hand (a user line, a file-history-snapshot
line naming a.txt and its backup, an assistant line), as the CLI writes them. Six runs, no model call;
~/.claude/settings.json had the same SHA-256 before and after (the user's own folder was not used).

102. Fork from a message. --resume=SRC --fork-session --session-id=NEW --resume-session-at=ID works without -p
     (--help hides the flag and says "print mode"): the copy's file, written at its first prompt as in (g), holds
     SRC's lines up to and including the entry ID, then the new turn (the new prompt's parentUuid is ID), and
     every file-history-snapshot line of SRC. export_conversation before that prompt already answers with the
     history up to ID. An ID the file does not have: no initialize answer, one result error_during_execution
     "No message found with message.uuid of: ID", exit 1 (as (k)). rhun forks from a prompt with ID the prompt
     line's parentUuid (the entry just before it); the first prompt has none: a new conversation with that
     prompt, as the extension's onCreateNewSession. (The extension copies the file itself, forkSession @1325994;
     rhun lets the CLI do it, so the copy is made only when its first prompt goes.)
103. Checkpoints. With CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true every prompt that starts a turn gets a
     file-history-snapshot line {type, messageId, snapshot {messageId, trackedFileBackups, timestamp},
     isSnapshotUpdate} whose messageId is the prompt line's uuid; a tracked file's entry is {backupFileName
     (sha256 of its absolute path, 16 hex digits, then "@vN"; null: it did not exist), version, backupTime
     [, realParentDir]}, the backup in <config>/file-history/<session id>/. In these runs the prompt line's uuid
     WAS the uuid rhun sent (and its turnAttributionKey); finding 27 saw the CLI's own there. rhun uses the
     line's uuid, which is the snapshot's messageId either way.
104. rewind_files {user_message_id, dry_run}. Right after a --resume, before any prompt: dry run {canRewind true,
     filesChanged [absolute paths], insertions, deletions} (a.txt "two\nthree" back to "one": insertions 1,
     deletions 2; an empty checkpoint: filesChanged [], 0, 0); the real one {canRewind true, skippedLinks 0}
     and the file was back. Refusals are successes: {canRewind false, error "No file checkpoint found for this
     message."} (an unknown id), {canRewind false, error "File rewinding is not enabled."} (a process started
     without the variable). The binary also names "rewindFiles: no turn received yet" and "Failed to rewind: X".
105. A turn cut off. With CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1 and CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS=
     3600000 (the extension's MJe), --resume of a file that ends in a prompt runs that turn again by itself right
     after initialize: command_lifecycle started (a command_uuid of its own), system/init, system/status
     requesting (user_message_uuids the cut prompt's uuid), then the turn; its assistant and result records carry
     user_message_uuid (the cut prompt's) and resume_reason "interrupted_turn" (the binary: or the host's
     CLAUDE_CODE_RESUME_REASON); no replay of the prompt. Without the variables nothing runs.
106. export_conversation answers {text, default_filename}: the conversation as the terminal's /export renders it
     ("\n❯ PROMPT\n  ⎿  ERROR" and "\n\n⏺ REPLY" lines) and "YYYY-MM-DD-HHMMSS-first-prompt-words.txt" (local
     time). The extension's /export NAME saves under NAME's last path part, ':' removed, ".txt" added when it has
     no extension (openExportForSaving).
107. remoteControlAtStartup (2026-11-24, CLI 2.1.330; HOME and CLAUDE_CONFIG_DIR in a temporary folder, not signed
     in, a temporary git repository; ~/.claude/settings.json had the same SHA-1 before and after). update_settings
     with it is refused: userSettings and localSettings "update_settings keys not allowed:
     remoteControlAtStartup" (true, false and null; the other sources are unsupported, finding 12), nothing written. apply_flag_settings {"settings":{"remoteControlAtStartup":
     true}} answers success and get_settings then has it in effective and in a flagSettings source. The initialize
     answer there: remote_control_available true, remote_control_auto_enable, _auto_on_by_default,
     _auto_connect_default and ide_rc_auto_enable_gate false. The binary's resolver (from its text, not run): a
     project's or local false wins, a true there is ignored ("repo-scoped settings cannot enable Remote Control;
     set it at user scope (/config)"), then policy, then the user's settings; its own /config writes the user's
     file. So the extension's host writes <config dir>/settings.json itself (s3: read, the key set, JSON with two
     blanks a level), then apply_flag_settings to the session and remote_control on the open ones as the setting
     says; rhun does the same (claude_side.s). Not tried: a real remote_control (it publishes the session).

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
- Phase 4 (made with tools/claude-shapes.py --cut-data, a line per record of BOTH directions: "DIR SHAPE", or
  "DIR SHAPE JSON" for what rhun wrote, the CLI's requests and withdrawals, user records, tool_progress and the
  echoes of rhun's mcp answers, base64 data cut to 16 characters, the run's folder written $CWD, its slug $SLUG,
  the home folder ~; runs of one shape folded; a line starting "#" names the run that follows): 23-attach.txt
  (the order run of 41 with the image alone, the opened file alone, inline_pastes and the documents; the
  not-an-image run; the 3 MiB run), 24-sdk-mcp.txt (the server run: handshake, mcp_status, a call, an isError
  call that Claude retried, a call held and interrupted), 25-sdk-hooks.txt (the hooks run from the Edit's stream
  to the result: hook_0 and hook_1, can_use_tool, hook_2 with the context, the Write), 26-edit-answer.txt (the
  edit run from its first Edit's stream: deny with interrupt, the stale allow, the two CR LF edits). keys.txt
  and file-keys.txt gained every line of the 24 recordings and their conversation files.

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
Phase 4: a recorder of the same kind (not kept), 24 processes, one temporary git repository each under the scratch
folder, 34 model turns of one sentence on haiku (the image probes one process each, each size sent once); the
in-process server was the recorder's own echo of a getDiagnostics tool (it touched nothing on disk). Nothing
wrote the user's settings: no update_settings; hooks and the server only in initialize; ~/.claude/settings.json
had the same SHA-256 before the first run and after the last. Afterwards the runs' folders under
<config>/projects and the CLI's /private/tmp/claude-UID/<slug> folders (the stored images) were deleted. Left
under ~/.claude by the CLI: session-env/<id> for each of the 24 runs and four backups/.claude.json.backup.N
files written meanwhile (not deleted).
