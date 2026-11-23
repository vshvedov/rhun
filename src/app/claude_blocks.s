# Claude Code's records into a conversation's rows: the content blocks of the stream's records and of the
# lines of a conversation's file, the tool table, results and their texts, a part's whole text from a record
# read again, a subagent's file, special user texts, system records, tasks. The only reader that knows
# Claude's tools and record shapes; the rows it makes are the generic ones of agentrows.s (agrow_*) and
# agents.s (agents_row_add, agents_reply_add, agents_row_flag). agent_drv.s reaches it through its reader
# table (readers), by AS_kind, with or without a driver.
#
#   claude_ingest(AS*, record jv, ING_*) -> eax 1 taken     a record of the stream (ING_LIVE) or a line of the
#                                                           file (ING_FILE); 0: the caller reads it itself
#   claude_text(AS*, AT*, ATX_IN..ATX_B, record jv, sb) -> eax 1   that part's whole text from its record read
#                                                           again, when the record is that call's
#   claude_kids(AS*, AT*) -> eax 1                          its subagent's calls, from their file
.include "rhun.inc"

.text

# FN claude_ingest(AS*, record jv, ING_*) -> eax 0: nothing is taken yet (phase 3 task 4 maps the records);
#   ingest_line and the stream's handlers make their rows as before
FN claude_ingest
    xor eax, eax
    ret

# FN claude_text(AS*, AT*, which, record jv, sb) -> eax 0: no whole text yet (phase 3 task 4)
FN claude_text
    xor eax, eax
    ret

# FN claude_kids(AS*, AT*) -> eax 0: no children read yet (phase 3 task 11)
FN claude_kids
    xor eax, eax
    ret
