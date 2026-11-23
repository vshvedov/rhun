# The spinner line after the last row while the open conversation works: its frames, the driver's verbs,
# the typewriter; the one tick of 120 ms for everything drawn that moves (phase 3 task 5 builds it; until
# then there is no spinner line and no tick). Generic: the verbs are the driver's (DRV_verbs).
#
#   agspin_h(AS*) -> eax            its height (0: none)
#   agspin_draw(AS*, x, y, w)       drawn after the last row, before the queued rows
#   agspin_seen()                   something drawn this frame moves: the tick goes on
#   agspin_phase() -> eax           the tick's count (a running dot's blink)
#   agspin_timeout() -> eax ms|-1   the time to the next tick, -1 none
#   agspin_tick()                   the tick: a frame when something moving was drawn
#   agspin_dump(sb)                 print-agent-spinner
#   agspin_set(AS*, cstr or 0, static)   the driver's words in place of a verb (ev_spin)
.include "rhun.inc"

.text

FN agspin_h
    xor eax, eax
    ret

FN agspin_draw
    ret

FN agspin_seen
    ret

FN agspin_phase
    xor eax, eax
    ret

FN agspin_timeout
    mov eax, -1
    ret

FN agspin_tick
    ret

FN agspin_dump
    ret

FN agspin_set
    ret
