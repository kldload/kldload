# Substrate matrix — reducing eight targets to four

**Status: DECIDED 2026-08-14 with the operator. Not yet implemented.**

## The decision

Four supported substrates. Everything else is deprecated.

| keep | package manager | why it earns a slot |
|---|---|---|
| Fedora | dnf | the fast substrate — kernel 7.x, ZFS 2.4.x. Primary dev target. |
| RHEL | dnf | the enterprise substrate — kernel 6.12, ZFS 2.3.x. Genuinely different from Fedora, not a duplicate. |
| Debian | apt | the stable substrate, and the only apt target worth maintaining. |
| CachyOS | pacman | replaces Arch. Ships kernel+ZFS and kernel+NVIDIA **prebuilt and paired**. |

| deprecate | why it does not |
|---|---|
| CentOS Stream | RHEL with a different logo. Triples the EL matrix for near-zero extra coverage. |
| Rocky | same. |
| Ubuntu | a Debian variant that costs a second APT darksite mirror to build and keep current. |
| Arch | rolling, so the kernel routinely outruns ZFS's `Linux-Maximum`; already the darksite exception (needs internet). Superseded by CachyOS. |

## Why keep BOTH dnf targets when one example per package manager was the goal

The package manager is not what breaks. The *substrate* is. Fedora 44 and
RHEL 10 differ in kernel (7.x vs 6.12), ZFS (2.4.x vs 2.3.x), repo layout,
and EPEL availability — and that gap has produced real incidents (EL9's
5.14/zfs-2.2 wedged dracut and nvidia, which is why EL moved to 10).

CentOS Stream and Rocky are the actual duplicates: same packages, same
versions, same failure modes as RHEL. Dropping those three-into-one is where
the matrix saving is, without losing a substrate that behaves differently.

## Why CachyOS instead of Arch

Measured 2026-08-14 from `mirror.cachyos.org`:

    linux-cachyos-zfs-7.1.8                  kernel shipped WITH matched ZFS
    linux-cachyos-server-nvidia-open-7.1.8   kernel shipped WITH matched nvidia-open
    zfs-dkms-2.4.3-1 / zfs-utils-2.4.3-2

CachyOS maintains the kernel/ZFS pairing upstream. That removes the entire
failure class this project spends most of its time policing — the DKMS race,
the `Linux-Maximum` ceiling, `tools/zfs-kernel-pin`. On Arch that pairing is
ours to defend on every kernel bump; on CachyOS it is theirs.

The 2026-08-14 Debian session is the argument in miniature: a day lost to a
kernel that outran its out-of-tree modules. A substrate that ships those
already matched is worth more than one that shares Arch's package manager.

## The Secure Boot exception — read this before promising SB everywhere

The operator's stated default is **Secure Boot on, all protections on**. That
is achievable on three of the four substrates and NOT on the fourth:

| substrate | signed shim? | SB story |
|---|---|---|
| Fedora / RHEL / Debian | YES | shim is Microsoft-signed. MOK enrollment ADDS the local module-signing key under a trust root the firmware already has. Documented, per-machine, one reboot. |
| CachyOS (Arch family) | **NO** | there is no shim package in the Arch repos at all. Secure Boot requires enrolling your OWN Platform Key via `sbctl` — REPLACING the firmware trust root, not extending it. |

This is a category difference, not a harder version of the same step. MOK
enrollment trusts one more key; custom PK enrollment makes the operator the
root of trust for the machine, and a mistake there can leave a box that will
not boot anything signed. It is the same wall documented in
`zbm-secure-boot.md`.

So the honest posture is: **SB-on-by-default for the three shim substrates;
CachyOS ships with an explicit, different SB path.** Do not paper over this in
the installer UI — a checkbox that silently means "replace your platform keys"
on one distro and "add a module key" on the others is a trap.

## Open questions before CachyOS is wired in

Neither is answered yet, and neither should be guessed:

1. **Darksite mirrorability.** Arch is currently the "requires internet"
   exception because rolling repos have no stable snapshot. CachyOS repos are
   ordinary pacman repos, so a mirror looks feasible — but it has not been
   tried, and the 100%-darksite goal makes this load-bearing.
2. **Unattended install path.** What CachyOS offers for a scripted,
   non-interactive install, and whether the kldload installer can target it
   the way it targets the other three.

## Current status — FLAGGED, NOT REMOVED (2026-08-14)

Nothing has been removed and nothing should be until Debian is fully working.
This section is the flag; the code is untouched on purpose.

**Priority order, decided with the operator 2026-08-14:**

1. **Debian + backports fully working end to end.** This is the only active
   work. Kernel 7.1.3 + ZFS 2.4.3 + NVIDIA 610 from the vendor repo, installing
   cleanly from the ISO with no hand-holding.
2. Everything below waits. Ripping out four distros while the fifth is still
   being stabilised turns one moving target into five, and a new bug becomes
   indistinguishable from an old one — the same reasoning that made the earlier
   backports attempt get reverted.

**Flagged for removal, in this order, once Debian is done:**

| target | disposition |
|---|---|
| Ubuntu | remove first. Not just dead code: it builds a SECOND full APT mirror on every `deploy.sh build` (2.6 GB cache) and gets gated like a real target. It aborted an ISO build on 2026-08-14 because a Debian-shaped check ran against an Ubuntu mirror. |
| CentOS Stream | remove — RHEL clone. |
| Rocky | remove — RHEL clone. |
| Alpine | remove as an INSTALL TARGET only. |
| Arch | **keep** until CachyOS lands, then remove in the same change. |

**Two traps for whoever does the removal:**

- `profiles.sh` falls back to `"${KLDLOAD_DISTRO:-centos}"` — **CentOS is the
  current default distro.** Removing CentOS without changing that default
  leaves the fallback pointing at a distro that no longer exists. It should
  become `fedora`.
- `alpine` appears in Helm charts and eBPF examples under
  `usr/local/share/kldload-examples/` as a CONTAINER BASE IMAGE. That is
  unrelated to Alpine-as-an-install-target. A blind string removal breaks the
  demo charts.

Most hits are shared `case` branches that need editing rather than deleting —
`debian | ubuntu)` becomes `debian)`, `centos | rocky | rhel | fedora)` becomes
`rhel | fedora)`, `arch | alpine | *)` becomes `arch | *)`.

## Migration

Deprecation is a two-step, not a deletion:

1. Mark CentOS Stream, Rocky, Ubuntu and Arch as deprecated in the installer
   and docs; keep them installable and keep them in CI until CachyOS is
   proven. A deprecated target that still builds costs little; a removed
   target that someone was relying on costs trust.
2. Remove them once CachyOS answers both open questions above and has one
   clean end-to-end install on hardware.

Order matters: do not remove Arch before CachyOS works, or the pacman slot is
empty and the matrix is three.
