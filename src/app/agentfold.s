# Focus view: a run of consecutive thinking and tool rows as one fold line (AS_folds, AF records that keep
# their counts as rows are added and calls change state). Phase 3 task 9 builds it; until then no row is
# folded. Generic.
#
#   agfold_add(AS*, row)                    a row is whole: it joins a fold or starts one
#   agfold_state(AS*, row, old ATS_*, new)  a call's state changed: its fold's counts follow
#   agfold_h(AS*, index, w, h) -> eax       the height the engine uses for that row (0: a fold hides it)
#   agfold_draw(...) -> eax 1 drew it       a fold's line in place of its rows
#   agfold_dump(sb, AS*)                    the folds, for tests
.include "rhun.inc"

.text

FN agfold_add
    ret

FN agfold_state
    ret

FN agfold_h
    mov eax, ecx
    ret

FN agfold_draw
    xor eax, eax
    ret

FN agfold_dump
    ret
