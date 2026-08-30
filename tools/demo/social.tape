# social.tape — shared look for short LinkedIn/Reddit clips.
#
# WHY these numbers: a feed clip is watched on a phone. rollback.tape is
# 1400x800 at FontSize 18 — ~129 columns — fine in a README, an unreadable grey
# smear at thumbnail size.
#
# MEASURED on onyx 2026-08-29 by rendering a 60-character ruler, because the
# column count is not what you would guess from the arithmetic:
#     FontSize 30  ->  ~36 columns   (very readable, far too narrow: everything wrapped)
#     FontSize 22  ->  ~58 columns   (legible on a handset, usable width)
# 22 is the compromise. THE BUDGET IS 58 COLUMNS. Anything wider wraps and the
# clip looks broken, so narrow the command rather than shrinking the font:
#     zpool list -o name,size,cap,health      not  zpool list        (66 cols)
#     rollback list | cut -c1-58              not  rollback list     (80 cols)
#
# Source this from a clip tape:  Source social.tape
Set Shell bash
Set Width 1080
Set Height 1080
Set FontSize 22
Set Padding 40
Set Margin 30
Set MarginFill "#0b0e14"
Set BorderRadius 12
Set WindowBar Colorful
Set Theme "Builtin Dark"
Set TypingSpeed 35ms
Set Framerate 30
