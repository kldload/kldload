[General]
Name=kldload
Parent=FALLBACK/
TerminalColumns=200
TerminalRows=60

[Interaction Options]
# AutoCopySelectedText=true → mouse-drag selection writes to system
# clipboard automatically on release. Combined with tmux's
# `set -g set-clipboard on` (OSC52), tmux pane selections also flow
# through to the clipboard. Without this, the operator drags a
# selection but has to press Ctrl+Shift+C or right-click → Copy
# to commit it — that's the "copy paste functionality is missing"
# the operator on .142 b644 hit.
AutoCopySelectedText=true
TrimLeadingSpacesInSelectedText=true
TrimTrailingSpacesInSelectedText=true
OpenLinksByDirectClickEnabled=true
UnderlineLinksEnabled=true

[Scrolling]
HistoryMode=2
HistorySize=50000
ScrollBarPosition=2
