# a click posted at a titlebar button while the pointer rests elsewhere: no frame sees the pointer
# over the button, and the press is still the button's, not a window move
move 900 20
tap 1124 20
print-window
print-state
# resting on the welcome page's Settings, which must not take the press too
move 700 400
tap 1124 20
print-window
print-state
# the other way round: a press on the empty title area moves the window whatever the pointer hovers,
# and a second one there maximizes it
move 1124 20
tap 900 20
print-window
tap 900 20
print-window
print-state
# the project menu opens on the release of a tap, and that frame's press is not a click outside it
tap 60 20
print-menu
tap 1000 700
print-menu
quit
