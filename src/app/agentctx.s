# The editor's context for a message (generic). Task 8 of phase 4 fills this file: the selection chip in the
# footer, what goes with the next message (the selection or the open file), the mention commands' delivery.
# Phase 4's task 2 made the two hooks agentext_send calls, so no later task edits agentext_send:
#
#   agctx_part(AS*, AP*) -> eax 1 added   at Send: the selection's or the open file's part (MPF_AUTO), when the
#                                       chip shows and differs from what this conversation last sent: nothing yet
#   agctx_sent(AS*)                     a prompt was taken (sent, queued or held): what went is remembered:
#                                       nothing yet
.include "rhun.inc"

.text

# FN agctx_part(AS*, AP*) -> eax 1 when a part was added (task 8)
FN agctx_part
    xor eax, eax
    ret

# FN agctx_sent(AS*): the context that went with the prompt is remembered (task 8)
FN agctx_sent
    ret
