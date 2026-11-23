# Rich cards of driven sessions (CD, rhun.inc): permission, questions, plan, dialog. The bottom area
# (agentext.s) and the panel's keys (agents.s) ask these first; a session whose request has no rich card
# keeps the simple card (AXK). Until the cards come, no request has one.
#
#   agentcard_of(AS*) -> rax CD* or 0   the session's rich card
#   agentcard_h(AS*, w) -> eax          its height (0 without one)
#   agentcard_draw(AS*, x, y, w, h)
#   agentcard_key(AS*, keysym, cp, mods) -> eax 1 taken (only while the panel has the focus on the card)
.include "rhun.inc"

.text

# FN agentcard_of(AS*) -> rax 0: no rich cards yet
FN agentcard_of
    xor eax, eax
    ret

# FN agentcard_h(AS*, w) -> eax 0
FN agentcard_h
    xor eax, eax
    ret

# FN agentcard_draw(AS*, x, y, w, h): nothing yet
FN agentcard_draw
    ret

# FN agentcard_key(AS*, keysym, cp, mods) -> eax 0: no card takes keys yet
FN agentcard_key
    xor eax, eax
    ret
