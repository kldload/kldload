# ZFS track selector — released vs testing

**Status: DESIGNED, not built.** Decided 2026-08-13 with the operator
after an OpenZFS developer confirmed they test on Debian via backports.

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

    trixie-backports kernel : 7.1.3
    OpenZFS 2.4.3 maximum   : 7.0     <- released ZFS CANNOT build here
    OpenZFS master maximum  : 7.1     <- only master reaches it

Debian backports — the channel OpenZFS uses for Debian testing — has
moved PAST the ceiling of the current ZFS release. So "enable backports
on Debian" is not a small convenience: taken with the backports kernel it
produces a machine where ZFS will not compile, unless ZFS also moves to
master. The two choices are coupled, and nothing currently enforces that.

This is the same failure kldload left Fedora to avoid — the kernel
outrunning ZFS — arriving on Debian by a different road.

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

An implementation was started and reverted on 2026-08-13: the Debian path
has no established baseline yet, and changing the least-tested substrate
before it has one makes a new bug indistinguishable from an old one.
Establish the baseline first.

## Order of work

1. Baseline a Debian install and diff its apt request list against the
   darksite mirror — the Fedora audit found 93 requested packages absent
   from the mirror; nobody has run that check for Debian.
2. Teach `zfs-kernel-pin` to answer per-distro, not just Fedora/koji.
3. Wire the ceiling check as a build gate.
4. Only then expose the selector.
