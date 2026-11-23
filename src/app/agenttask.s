# Background tasks and agents of a conversation: their lines under the turn, Stop, Run in background (AS_tasks,
# AK records). Phase 3 task 11 builds it; until then a conversation has no task lines. Generic.
#
#   agtask_busy(AS*) -> eax 1     a task of it is unfinished (the idle stop asks)
#   agtask_h(AS*, w) -> eax       the height of its lines after the spinner
#   agtask_draw(AS*, x, y, w)
#   agtask_clear(AS*)             its tasks go (the rows went)
#   agtask_dump(sb, AS*)          print-agent-tasks
.include "rhun.inc"

.text

FN agtask_busy
    xor eax, eax
    ret

FN agtask_h
    xor eax, eax
    ret

FN agtask_draw
    ret

FN agtask_clear
    ret

FN agtask_dump
    ret
