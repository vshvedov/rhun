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
