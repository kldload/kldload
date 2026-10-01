#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# smoke-snapshots.sh — on a freshly installed kldload machine, verify the
# snapshot policy, package rollback, the NVIDIA driver and the display.
#
# What it checks, in order (one line each: PASS/FAIL/WARN <name>: detail):
#   1. core (no sanoid): no scheduler, by design; stops there.
#   2. kldload-snapshot-policy owns sanoid.conf ("# pool:" marker), every
#      section names an existing dataset, ROOT/vms/never-snapshot classes are
#      right, the regenerable dirs are their own datasets.
#   3. sanoid + the guard timer on, the three legacy timers off, first boot
#      ran apply, sanoid runs clean, autosnaps on the root and none on the
#      never-snapshot datasets, sanoid.service syncs the policy first.
#   4. the guard: a no-op below its threshold, and forced (GUARD_HIGH=0)
#      destroys exactly one scheduled snapshot and no protected one -- read
#      from the guard's own "destroyed" lines, never a pool diff.
#   5. apply again changes nothing; package snapshots exist; rollback lists.
#   6. NVIDIA (when present): loaded, no NVRM assertion, the module written
#      before first boot, loaded early. Display (when gdm is on): gdm did not
#      give up, no gnome-shell crash, a greeter or shell running.
#
# WHY: two overnight batteries (2026-09-30/10-01) found what nothing else
# looked at: datasets made after first boot's apply were never covered (build
# 168, 11-storage), and a desktop whose NVIDIA module was built at first boot
# came up black while the sweep marked it PASS (build 168, 5-desktop). Each
# check here is one of those, or the probe mistake that hid one.
#
# Run by: tests/estate-sweep.sh after the profile report, as root on the
# installed machine (`sudo bash /tmp/smoke-snapshots.sh`). By hand: same.
# It CHANGES the machine, and only the way the policy itself would: one
# sanoid run, the guard twice (one forced destroy of a scheduled snapshot),
# one apply. Meant for a bench install, not a machine you care about.
# Exit: 0 no FAIL; 1 any FAIL.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "FAIL smoke-snapshots-internal: line $LINENO: $BASH_COMMAND"' ERR
fails=0
p() { echo "PASS $*"; }
f() {
    echo "FAIL $*"
    fails=$((fails + 1))
}
w() { echo "WARN $*"; }
T=/usr/local/sbin/kldload-snapshot-policy
C=/etc/sanoid/sanoid.conf
pool=rpool

if ! command -v sanoid >/dev/null 2>&1; then
    # core: no sanoid by design
    if systemctl is-active sanoid.timer >/dev/null 2>&1; then f "core-no-sanoid: sanoid.timer active"; else p "core-no-sanoid: no sanoid, no timer (by design)"; fi
    if [[ ! -f /var/log/kldload/firstboot.log ]]; then
        p "core-firstboot-note: no firstboot.log at all (core installs no kldload first boot; $(systemctl is-enabled kldload-firstboot.service 2>&1 | head -1))"
    elif grep -q 'no sanoid on this profile' /var/log/kldload/firstboot.log; then
        p "core-firstboot-note: firstboot logged the no-sanoid case"
    else
        w "core-firstboot-note: firstboot.log exists but has no no-sanoid line: $(grep -c . /var/log/kldload/firstboot.log) lines, last: $(tail -1 /var/log/kldload/firstboot.log | cut -c1-120)"
    fi
    echo "RESULT fails=${fails}"
    ((fails == 0))
    exit
fi

[[ -x "$T" ]] && p "tool: $T present" || f "tool: $T missing"
grep -q 'WRITTEN BY kldload-snapshot-policy' "$C" && p "conf-owner: sanoid.conf written by the policy" || f "conf-owner: $C not written by the policy"
ds_all="$(zfs list -H -o name -t filesystem,volume -r "$pool")"
missing=0
for s in $(sed -n 's/^\[\(rpool\/[^]]*\)\]$/\1/p' "$C"); do
    grep -qxF "$s" <<<"$ds_all" || {
        missing=$((missing + 1))
        echo "  section for absent dataset: $s"
    }
done
((missing == 0)) && p "conf-existing: every section names an existing dataset" || f "conf-existing: ${missing} section(s) name absent datasets"
# swallow: no such section is a FAIL reported on the next line
sec="$(grep -A1 -x '\[rpool/ROOT\]' "$C" || true)"
grep -q 'use_template = bootenv' <<<"$sec" && p "conf-root: ROOT is bootenv" || f "conf-root: ROOT not bootenv"
if grep -qxF rpool/vms <<<"$ds_all"; then
    # swallow: no such section is a FAIL reported on the next line
    sec="$(grep -A1 -x '\[rpool/vms\]' "$C" || true)"
    grep -q 'use_template = vms' <<<"$sec" && p "conf-vms: rpool/vms is the vms class" || f "conf-vms: rpool/vms missing or wrong class"
fi
for d in rpool/var/lib/containers rpool/var/lib/libvirt/images rpool/var/lib/kldload-netboot; do
    grep -qxF "$d" <<<"$ds_all" || continue
    # swallow: no such section is a FAIL reported on the next line
    sec="$(grep -A1 -x "\[$d\]" "$C" || true)"
    grep -q 'use_template = none' <<<"$sec" && p "conf-none: $d never snapshotted" || f "conf-none: $d not in the none class"
done
for d in var/lib/libvirt/images var/lib/kldload-netboot; do
    # swallow: absent mount is the failure reported below
    src="$(findmnt -no SOURCE "/$d" 2>/dev/null || true)"
    [[ "$src" == "$pool/$d" ]] && p "regen-dataset: /$d is $pool/$d" || f "regen-dataset: /$d is '${src:-not a mount}'"
done
for t in sanoid.timer kldload-snapshot-guard.timer; do
    if systemctl is-enabled "$t" >/dev/null 2>&1 && systemctl is-active "$t" >/dev/null 2>&1; then p "timer-on: $t enabled+active"; else f "timer-on: $t is $(systemctl is-enabled "$t" 2>&1 | head -1)/$(systemctl is-active "$t" 2>&1 | head -1)"; fi
done
for t in kldload-snapshot.timer kldload-srv-snapshot.timer kvm-snapshot.timer; do
    if systemctl is-enabled "$t" >/dev/null 2>&1; then f "timer-legacy-off: $t enabled"; else p "timer-legacy-off: $t not enabled"; fi
done
grep -q 'kldload-snapshot-policy: wrote /etc/sanoid/sanoid.conf' /var/log/kldload/firstboot.log 2>/dev/null &&
    p "firstboot-apply: firstboot ran apply" || f "firstboot-apply: no apply in firstboot.log"
grep -q 'WARNING: kldload-snapshot-policy' /var/log/kldload/firstboot.log 2>/dev/null &&
    f "firstboot-apply-warn: $(grep 'WARNING: kldload-snapshot-policy' /var/log/kldload/firstboot.log | head -1)" || p "firstboot-apply-warn: none"

# sanoid: run once now (what the timer does) and read the OUTCOME
# swallow: Result read just below
systemctl start sanoid.service || true
r="$(systemctl show -p Result --value sanoid.service)"
[[ "$r" == success ]] && p "sanoid-run: Result=success" || f "sanoid-run: Result=$r"
# swallow: grep -c exits 1 when the count is 0, which is an answer
errs="$(journalctl -b -u sanoid.service -u sanoid-prune.service --no-pager 2>/dev/null | grep -ciE 'cannot open|does not exist|error' || true)"
((errs == 0)) && p "sanoid-journal: no errors this boot" || f "sanoid-journal: ${errs} error line(s): $(journalctl -b -u sanoid.service --no-pager | grep -iE 'cannot open|does not exist|error' | head -2 | tr '\n' ' ')"
snaps="$(zfs list -H -t snapshot -o name -r "$pool")"
# swallow: grep -c exits 1 when the count is 0, which is an answer
n_root="$(grep -c '^rpool/ROOT/[^@]*@autosnap_' <<<"$snaps" || true)"
((n_root > 0)) && p "autosnap-root: ${n_root} on the boot environment" || f "autosnap-root: none on rpool/ROOT"
# swallow: grep exits 1 when nothing matches, which is the PASS case
bad="$(grep -E '^rpool/var/lib/(containers|libvirt/images|kldload-netboot)[^@]*@autosnap_|^rpool/var/(cache|tmp)[^@]*@autosnap_' <<<"$snaps" || true)"
[[ -z "$bad" ]] && p "autosnap-excluded: none on never-snapshot datasets" || f "autosnap-excluded: $(head -3 <<<"$bad" | tr '\n' ' ')"
# swallow: grep -c exits 1 when the count is 0, which is an answer
n_auto="$(grep -c '@auto-' <<<"$snaps" || true)"
((n_auto == 0)) && p "no-legacy-auto: no @auto- snapshots (legacy scheduler off)" || w "no-legacy-auto: ${n_auto} @auto- snapshot(s)"

# guard: ask the TOOL what it destroyed (its "destroyed <snap>" lines), never
# diff the pool's snapshot list -- other actors make and remove snapshots
# meanwhile (9-ai, build 168: the sweep's own rpool@smoketest-* came and went
# inside this window and read as the guard's doing).
prot_before="$(zfs list -H -t snapshot -o name -r "$pool" | grep -E '@(apt-pre|apt-post|dnf-pre|dnf-post|kpkg|golden|install)' || true)" # none is a valid state
# direction 1: below the threshold it must do nothing
cur="$(journalctl -u kldload-snapshot-guard.service -n 0 --show-cursor --no-pager 2>/dev/null | sed -n 's/^-- cursor: //p')"
# swallow: Result read just below
systemctl start kldload-snapshot-guard.service || true
r="$(systemctl show -p Result --value kldload-snapshot-guard.service)"
[[ "$r" == success ]] && p "guard-unit: Result=success" || f "guard-unit: Result=$r"
# swallow: grep -c exits 1 when the count is 0, which is an answer
nd="$(journalctl -u kldload-snapshot-guard.service ${cur:+--after-cursor="$cur"} --no-pager 2>/dev/null | grep -c 'destroyed ' || true)"
((nd == 0)) && p "guard-noop: the guard destroyed nothing at $(zpool list -H -o capacity "$pool")" || f "guard-noop: the guard logged ${nd} destroy(s) below the threshold"
# direction 2: forced, it must destroy exactly one SCHEDULED snapshot
# swallow: outcome read from its log below
GUARD_HIGH=0 GUARD_LOW=100 "$T" guard >/tmp/snapcheck-guard.log 2>&1 || true
gone="$(sed -n 's/^kldload-snapshot-policy: destroyed //p' /tmp/snapcheck-guard.log)"
# swallow: grep -c exits 1 when the count is 0, which is an answer
ngone="$(grep -c . <<<"$gone" || true)"
if ((ngone == 0)); then
    w "guard-forced: nothing destroyed (no dataset has 2+ scheduled snapshots yet)"
elif ((ngone == 1)) && [[ "$gone" =~ @(autosnap_|auto-) ]]; then
    if zfs list -H -t snapshot "$gone" >/dev/null 2>&1; then
        f "guard-forced: logged ${gone} destroyed but it still exists"
    else
        p "guard-forced: destroyed exactly ${gone} (gone from the pool)"
    fi
else
    f "guard-forced: destroyed ${ngone}: $(tr '\n' ' ' <<<"$gone")"
fi
lost=0
for s in $prot_before; do
    zfs list -H -t snapshot "$s" >/dev/null 2>&1 || {
        lost=$((lost + 1))
        echo "  protected snapshot gone: $s"
    }
done
# swallow: grep -c exits 1 when the count is 0, which is an answer
((lost == 0)) && p "guard-protected: all $(grep -c . <<<"$prot_before" || true) package/golden/install snapshots still there" || f "guard-protected: ${lost} protected snapshot(s) gone"

# apply is idempotent on a real install
cp "$C" /tmp/snapcheck-conf.before
h1="$(sha256sum <"$C")"
"$T" apply >/tmp/snapcheck-apply.log 2>&1 && p "apply-rerun: exit 0" || f "apply-rerun: exit $? ($(tail -2 /tmp/snapcheck-apply.log | tr '\n' ' '))"
if [[ "$(sha256sum <"$C")" == "$h1" ]]; then
    p "apply-idempotent: conf unchanged"
else
    # diff exits 1 when the files differ, which is the case being reported
    f "apply-idempotent: conf changed on rerun: $({ diff /tmp/snapcheck-conf.before "$C" || true; } | grep '^[<>] \[' | tr '\n' ' ')"
    echo "  firstboot.log apply lines: $(grep -n 'kldload-snapshot-policy' /var/log/kldload/firstboot.log | tr '\n' ' ' | cut -c1-400)"
    echo "  datasets created after first boot's apply (creation, name): $(zfs list -H -p -o creation,name -s creation -r rpool | tail -8 | tr '\n' ' ')"
fi
# what apply itself says it created or moved -- not a pool-wide count, which
# the sweep's own test datasets change meanwhile (2-server, build 168)
nc="$(grep -cE ': (created |would create |.* is now dataset )' /tmp/snapcheck-apply.log || true)"
((nc == 0)) && p "apply-idempotent: the rerun created no dataset" || f "apply-idempotent: the rerun created ${nc}: $(grep -E 'created |is now dataset' /tmp/snapcheck-apply.log | tr '\n' ' ' | cut -c1-300)"
"$T" status >/dev/null 2>&1 && p "status: exit 0" || f "status: exit nonzero"
# builds from 9b7e8575 on: sanoid re-syncs the conf before every run
if grep -q 'cmd_sync()' "$T"; then
    # swallow: absent unit is the failure reported below
    sancat="$(systemctl cat sanoid.service 2>/dev/null || true)"
    grep -q 'kldload-snapshot-policy sync' <<<"$sancat" &&
        p "sanoid-sync-dropin: sanoid.service syncs the policy first" || f "sanoid-sync-dropin: no sync ExecStartPre on sanoid.service"
    grep -qx "# pool: ${pool}" "$C" && p "conf-pool-marker: # pool: ${pool}" || f "conf-pool-marker: missing"
fi

# package snapshots + rollback (untouched by the policy; prove it still works)
be="$(zpool get -H -o value bootfs "$pool")"
# swallow: grep -c exits 1 when the count is 0, which is an answer
pk="$(zfs list -H -t snapshot -o name "$be" | grep -cE "^${be}@(apt-pre|dnf-pre|kpkg)-" || true)"
((pk > 0)) && p "pkg-snapshots: ${pk} on ${be}" || w "pkg-snapshots: none on ${be} (no package transaction since install?)"
if command -v kldload-rollback >/dev/null 2>&1; then
    # swallow: grep -c exits 1 when the count is 0, which is an answer
    kldload-rollback list >/tmp/snapcheck-rb.log 2>&1 && p "rollback-list: exit 0 ($(grep -cE 'before (apt|dnf)|kpkg' /tmp/snapcheck-rb.log || true) package points listed)" || f "rollback-list: exit nonzero: $(tail -2 /tmp/snapcheck-rb.log | tr '\n' ' ')"
else
    f "rollback: kldload-rollback missing"
fi

# ─── NVIDIA + display (build 168: 5-desktop black screen passed the sweep) ───
gpus="$(lspci -nn 2>/dev/null | grep -iE 'vga|3d controller' || true)" # no display device is an answer
if grep -qi nvidia <<<"$gpus"; then
    # captured first: `cmd | grep -q` under pipefail fails when grep exits
    # early and cmd takes SIGPIPE (it read "not loaded" for a loaded module)
    mods="$(lsmod)"
    # swallow: no journal access reads as empty, reported below
    klog="$(journalctl -k -b --no-pager 2>/dev/null || true)"
    # swallow: no journal access reads as empty, reported below
    kmono="$(journalctl -k -b -o short-monotonic --no-pager 2>/dev/null || true)"
    if grep -q '^nvidia ' <<<"$mods"; then p "nvidia-loaded: nvidia.ko loaded"; else f "nvidia-loaded: nvidia.ko NOT loaded"; fi
    # swallow: grep -c exits 1 when the count is 0, which is an answer
    na="$(grep -c 'nvAssertFailed' <<<"$klog" || true)"
    ((na == 0)) && p "nvidia-assert: no NVRM assertion this boot" || f "nvidia-assert: ${na} NVRM assertion(s): $(grep -m1 nvAssertFailed <<<"$klog" | cut -c1-140)"
    # the module must come from the INSTALL, not be built during first boot.
    # Family-neutral (deb-11-storage, build 172: Debian builds nvidia through
    # DKMS, so an RPM-name check failed a machine that was fine): ask the
    # kernel which file it loaded, and compare that file's time with the
    # start of first boot.
    mf="$(/usr/sbin/modinfo -n nvidia 2>/dev/null || modinfo -n nvidia 2>/dev/null || true)" # absent module is reported just below
    bt="$(date -d "$(uptime -s)" +%s)"
    fb="$(sed -n 's/^\[\([0-9-]* [0-9:]*\)\].*/\1/p' /var/log/kldload/firstboot.log 2>/dev/null | head -1)"
    fbt="$([[ -n "$fb" ]] && date -d "$fb" +%s || echo "$bt")"
    if [[ -n "$mf" && -f "$mf" ]]; then
        mt="$(stat -c %Y "$mf")"
        ((mt < fbt - 60)) && p "nvidia-kmod-at-install: ${mf##*/} written $(date -d @"$mt" '+%F %T'), before first boot" ||
            f "nvidia-kmod-at-install: ${mf} written $(date -d @"$mt" +%T), first boot started $(date -d @"$fbt" +%T) -- built at first boot"
    else
        f "nvidia-kmod-at-install: modinfo cannot find the nvidia module file"
    fi
    ns="$(grep -m1 'NVRM: loading' <<<"$kmono" | sed -n 's/^\[ *\([0-9]*\)\..*/\1/p')"
    [[ -n "$ns" ]] && { ((ns <= 20)) && p "nvidia-early: NVRM loaded ${ns}s into boot" || f "nvidia-early: NVRM loaded ${ns}s into boot (late: after the framebuffer took the display)"; }
fi
if systemctl list-unit-files gdm.service >/dev/null 2>&1 && systemctl is-enabled gdm.service >/dev/null 2>&1; then
    # swallow: grep -c exits 1 when the count is 0, which is an answer
    gf="$(journalctl -b -u gdm --no-pager 2>/dev/null | grep -c 'maximum number of display failures' || true)"
    ((gf == 0)) && p "display-gdm: gdm did not give up" || f "display-gdm: gdm reached its display-failure limit (black screen)"
    # swallow: grep -c exits 1 when the count is 0, which is an answer
    gc="$(coredumpctl list --no-pager --since "$(uptime -s)" 2>/dev/null | grep -c gnome-shell || true)"
    ((gc == 0)) && p "display-shell: no gnome-shell crash this boot" || f "display-shell: ${gc} gnome-shell crash(es) this boot"
    # swallow: no sessions is reported below
    sess="$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' || true)"
    if grep -qx gdm <<<"$sess" || pgrep -x gnome-shell >/dev/null; then
        p "display-session: a greeter/shell is running"
    else
        f "display-session: no gdm greeter and no gnome-shell running"
    fi
fi
echo "RESULT fails=${fails}"
((fails == 0))
