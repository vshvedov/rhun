# Claude Code's requests as rich cards (agentcard.s) and their answers: the driver table's DRV_reply
#
#   claude_reply(AL*, AQ*, CD*) -> eax 1 written: the answer a rich card holds (0: no rich cards yet)
.include "rhun.inc"

.text

# FN claude_reply(AL*, AQ*, CD*) -> eax 0: nothing written (the cards come with their tasks)
FN claude_reply
    xor eax, eax
    ret
