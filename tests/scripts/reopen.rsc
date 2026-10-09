# Reopen Closed Tab: the last closed tab first, in its place, with its cursor and selection; Close All
# comes back one tab at a time, in order; Ctrl+K still picks a theme
open README.md
open tests/data/words.txt
open tests/data/case.txt
cmd prev_tab
key Down
key Down
key Right
key shift+End
cmd close_tab
print-tabs
key ctrl+shift+t
print-tabs
print-state
cmd settings
cmd close_all_tabs
print-tabs
key ctrl+shift+t
key ctrl+shift+t
print-tabs
key ctrl+shift+t
key ctrl+shift+t
key ctrl+shift+t
print-tabs
key ctrl+k
print-state
quit
