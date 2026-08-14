# ZFS track selector — released vs testing

**Status: Debian backports SHIPPED 2026-08-13; the track selector itself
is still DESIGNED, not built.** Decided with the operator after an
OpenZFS developer confirmed they test on Debian via backports.

## The problem

kldload pins a kernel to whatever the current OpenZFS RELEASE supports,
because a kernel above `Linux-Maximum` is one OpenZFS cannot build
against — an unbootable machine on ZFS root. That pin is the substrate's
core promise and the reason `tools/zfs-kernel-pin` exists.

But there are two legitimate postures, and they want opposite things:

| | wants | who |
|---|---|---|
| **released** | a kernel that STAYS, ZFS that is shipped | operators |
| **testing** | the NEWEST kernel, ZFS from git | OpenZFS developers |

Today only the first is a supported product, and the second exists as a
Fedora-only build flag.

## Why this is now urgent rather than theoretical

Measured 2026-08-13:

    trixie-backports kernel        : 7.1.3
    UPSTREAM OpenZFS 2.4.3 maximum : 7.0
    DEBIAN zfs-dkms 2.4.3-2~bpo13+1: 7.1   <- Debian raised the ceiling

An earlier revision of this document read the ceiling off UPSTREAM's META
and concluded the backports kernel was unbuildable without moving ZFS to
git master. That is wrong for Debian specifically: Debian's packaged
zfs-dkms ships `Linux-Maximum: 7.1` (read directly out of
`zfs-dkms_2.4.3-2~bpo13+1_all.deb`), so the backports kernel and the
backports ZFS are a matched pair the archive ships together on purpose.

The coupling argument still holds in general — a kernel above the ZFS
ceiling is an unbootable root — it simply does not bite here, because the
distro that ships the kernel also ships the ZFS that supports it. The
build gate below is what keeps that true rather than assumed.

## What already exists

`KLDLOAD_ZFS_GIT` (builder/build-iso.sh): builds OpenZFS rpms from git
and UNPINS the kernel, described in its own comment as the escape hatch
for "the zfs lags the kernel window". Opt-in, marked unsupported, and
byte-identical to the release path when unset. That is exactly the
testing posture — but it is Fedora-only and build-time.

## The design

A THIRD axis, orthogonal to distro and profile, defaulting to released:

    ZFS track:  (o) released   stable kernel, released ZFS
                ( ) testing    newest kernel, ZFS from git

Not a profile: it would have to be duplicated per distro. Not a feature
tile: "use unreleased ZFS" is a different kind of decision from "install
KVM", and putting them side by side invites an accidental click.

Per distro it resolves to:

| track | Fedora | Debian |
|---|---|---|
| released | koji pin from `zfs-kernel-pin`, release repo | trixie kernel + trixie zfs-dkms |
| testing | `KLDLOAD_ZFS_GIT=master`, kernel unpinned | trixie-backports kernel + ZFS from git |

## The rule that makes it safe

The selector must not be free-choice. `tools/zfs-kernel-pin` already
resolves the ceiling from META; the build should REFUSE a combination
where the kernel exceeds the chosen ZFS's `Linux-Maximum`, rather than
producing an ISO that fails at DKMS time on the operator's hardware.

That check is the actual product of this work. The radio button is just
how it gets expressed.

## Debian backports notes

Backports is NOT Debian testing. It is packages from testing/unstable
rebuilt against stable, at APT priority 100 versus stable's 500 — so
nothing installs from it unless named with `-t trixie-backports`. Adding
the source alone changes nothing, which is what makes it safe to enable
by default and select from per package.

An implementation was started and reverted earlier on 2026-08-13, on the
reasoning that the Debian path had no baseline yet. That baseline now
exists: a Debian install was audited on hardware and found running stock
trixie (kernel 6.12.101, zfs 2.3.2) with no backports source at all —
i.e. two years behind the Fedora substrate on kernel and a full minor
behind on ZFS. Backports is now enabled by default for Debian:

- `k_debian_backports_suite` (lib/bootstrap.sh) names the pocket, and
  returns EMPTY for Ubuntu, for an offline darksite mirror, or when
  `KLDLOAD_DEBIAN_BACKPORTS=0`.
- The source is written both at install time and into the installed
  system's sources.list — omitting the latter makes the next
  `apt full-upgrade` offer to REMOVE the backports kernel.
- The kernel, its headers and the whole ZFS stack are named in one
  `-t <suite>-backports` transaction, so apt cannot resolve zfs-dkms
  from stable against a backports kernel.
- The install then asserts both installed versions contain `bpo` and
  logs a loud WARNING if apt silently fell back to stable.

## Order of work

1. Baseline a Debian install and diff its apt request list against the
   darksite mirror — the Fedora audit found 93 requested packages absent
   from the mirror; nobody has run that check for Debian.
2. Teach `zfs-kernel-pin` to answer per-distro, not just Fedora/koji.
3. Wire the ceiling check as a build gate.
4. Only then expose the selector.
