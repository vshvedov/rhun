# A typed row's inline diff (AT_a to AT_b, ATF_DIFF) and a written file's coloured text (AT_b, ATF_PRE): built
# once, laid out per width, drawn for the lines in view (phase 3 task 7 builds it; until then a row shows
# neither). Generic.
#
#   agdiff_h(AT*, w) -> eax                 its height at that width (0: none)
#   agdiff_draw(AT*, x, y, w, id) -> eax 1  clicked ("Click to expand")
#   agdiff_free(AT*)                        its record goes (AT_diff)
#   agdiff_dump(sb, AT*)                    print-agent-rows' diff lines
.include "rhun.inc"

.text

FN agdiff_h
    xor eax, eax
    ret

FN agdiff_draw
    xor eax, eax
    ret

FN agdiff_free
    ret

FN agdiff_dump
    ret
