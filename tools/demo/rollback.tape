# ─────────────────────────────────────────────────────────────────────────
# rollback.tape — the 1.4.0 headline feature, recorded as a real session.
#
# What it does, in order:
#   1. SSHes into a real kldload install (KLD_DEMO_HOST) so every line on
#      screen is a command that actually ran on a machine, not a mockup.
#   2. Shows the boot environments, installs a package, shows the snapshot
#      the package manager took on its way past, rolls it back, and shows
#      the new boot environment waiting for a reboot.
#   3. Ends on the version locks, because "you can undo it" and "the kernel
#      cannot drift out from under ZFS" are the same promise from two ends.
#
# WHY vhs rather than a screen recorder: the tape is the script. A re-record
# after a copy change is `vhs rollback.tape`, not a person retyping at the
# right speed with the right typo count, and the output is byte-identical
# between runs — which matters when the video sits next to a claim.
#
# Inputs:  a reachable install with passwordless sudo for the demo user.
#          Set KLD_DEMO_HOST in the environment (default kldload-node).
# Outputs: tools/demo/out/rollback.mp4 and .gif
#
# Run:     cd tools/demo && vhs rollback.tape
#
# Notes:
#   - Sleeps are deliberately long around output the viewer has to READ.
#     The instinct is to keep it moving; the point of this clip is a line
#     of text (the snapshot name) that means nothing if it flashes past.
#   - dnf's own progress output sets the pace of the install step. If the
#     box is slow, raise the Sleep after it rather than trimming it — a cut
#     mid-transaction looks like an edit that hid something.
# ─────────────────────────────────────────────────────────────────────────

Output out/rollback.mp4
Output out/rollback.gif

Set Shell bash
Set FontSize 18
Set Width 1400
Set Height 800
Set Padding 24
Set Theme "Builtin Dark"
Set TypingSpeed 45ms
Set PlaybackSpeed 1.0

Hide
Type "clear" Enter
Show

Type "ssh admin@${KLD_DEMO_HOST:-kldload-node}"
Enter
Sleep 4s

Type "# ZFS on root. These are boot environments, not backups."
Enter
Type "zfs list -o name,used,mountpoint -d 1 rpool/ROOT"
Enter
Sleep 4s

Type "# Install something. Watch the first line."
Enter
Type "sudo dnf install -y tree"
Enter
Sleep 25s

Type "# dnf took a snapshot on its way past — no wrapper, no flag."
Enter
Type "zfs list -t snapshot -o name,used,creation rpool/ROOT/kldload-node | tail -4"
Enter
Sleep 6s

Type "# Undo it."
Enter
Type "sudo dnf rollback"
Enter
Sleep 8s

Type "# A new boot environment, cloned from that snapshot. Nothing overwritten."
Enter
Type "zfs list -o name,origin -d 1 rpool/ROOT"
Enter
Sleep 6s

Type "# And the kernel cannot drift out from under ZFS or NVIDIA:"
Enter
Type "sudo dnf versionlock list | head -12"
Enter
Sleep 7s

Type "exit"
Enter
Sleep 2s
