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
- ../claude/help-2.1.330.txt is `claude --help` of the recorded CLI; help-2.1.289.txt the earlier one.

How they were made: a throwaway recorder (not kept) ran the real CLI in an empty temporary git
repository with the pinned line, wrote each line the CLI sent as {"dir":"in","msg":...} and each line
sent to it as {"dir":"out","msg":...}; then `tools/claude-shapes.py REC.jsonl` gave each shape file and
`tools/claude-shapes.py --keys REC.jsonl...` keys.txt. The prompts were "Reply with the word ok" and a
few as small (touch a file, count, ask red or blue, plan one file); 12 in all.
