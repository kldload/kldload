# ZFSBootMenu under Secure Boot — why it does not work, and what would

Status: **UNSOLVED**. Secure Boot installs boot the GRUB `direct` entry and
the operator silently loses the boot-environment picker and snapshot
rollback at boot. This file records what was tested on fiend (2026-08-13)
so the same two dead ends are not retried.

## What was believed

`grub.cfg` defaults to `direct` when Secure Boot is on, with the comment
"ZBM cannot chainload under shim 15.8". Two facts suggested that had gone
stale:

- ZBM on the ESP is signed with the enrolled kldload MOK
  (`CN=kldload-mok-...`), the same key whose signature lets zfs.ko and
  nvidia.ko load under Secure Boot.
- The installed shim is **16.1**, not 15.8.

## Dead end 1 — chainload from GRUB

Set `default=zbm` and rebooted. shim refused; GRUB fell through to
`fallback=direct`. Console showed a shim failure, a menu, then a normal
boot. The original comment is correct and should not be re-litigated:
GRUB's `chainloader` cannot get an arbitrary binary past shim, and the
binary being MOK-signed does not change that.

## Dead end 2 — stage shim as ZBM's own first stage

The obvious next move, and it also fails. Staged:

    /EFI/zbm/BOOTX64.EFI   <- shimx64.efi (Microsoft-signed)
    /EFI/zbm/grubx64.efi   <- ZBM         (kldload MOK-signed)

with `mmx64.efi` already present and a dedicated NVRAM entry. `grubx64.efi`
is the second-stage name Fedora's shim looks for (confirmed in its UTF-16
strings), so the layout is right.

Result: **MokManager blue screen, "Verification failed: 0x1A security
violation"**, and the machine would not continue. Recovery was a
power-cycle plus selecting the GRUB entry from the firmware boot menu.

## Why it fails — NOT YET ESTABLISHED

Two plausible explanations were checked on the running system and BOTH
are ruled out. Recorded here precisely so neither is chased again.

**Not a revoked SBAT generation.** ZBM's `.sbat` declares
`systemd-stub,1,...` and `systemd-stub.void,1,...,256.6_2`, and the
first guess was that shim 16.1 revokes old systemd-stub generations. The
firmware's actual revocation level says otherwise:

    sbat,1,2024040900
    shim,4
    grub,4
    grub.peimage,2

There is no `systemd-stub` entry, so nothing about ZBM's SBAT is
revoked. (`mokutil --list-sbat` — answerable on a running system, no
reboot.)

**Not an unenrolled key.** The certificate that signed ZBM,
`CN=kldload-mok-20260813022408-...`, is present in MokList and shim
consults MokList when validating its second stage.

So a binary with acceptable SBAT, signed by an enrolled key, laid out
where shim looks for it, is still refused with 0x1A. The cause is
something else and is currently unknown. **Do not reboot into another
attempt until there is a specific hypothesis that can be tested
offline.**

Whatever the cause, do NOT enroll at the MokManager prompt: it offers to
trust the hash of the binary that just failed, which grants boot trust to
something on the basis that it was rejected.

## What to investigate next — WITHOUT rebooting first

1. Read the firmware's current SBAT revocation level (`mokutil --list-sbat`,
   or the `SbatLevel` UEFI variable) and compare it against ZBM's declared
   generation. That settles the diagnosis on a running system, offline.
2. If the generation is revoked, the fix is upstream shape, not layout:
   a ZBM build whose systemd-stub generation is current.
3. Alternative worth checking: ZBM also releases a plain **kernel +
   initramfs**, not only the UKI. GRUB can `linux`/`initrd` a kernel under
   Secure Boot when it passes shim's verification, which is a different
   code path from `chainloader`. If that kernel is signed with the kldload
   MOK it may boot where the UKI cannot.

## Rule learned

"SBAT section present" is not "SBAT accepted". The question is which
*generation* the running shim revokes. Check that before a reboot, not
after — on fiend this cost a MokManager lockout and a power-cycle on a
machine that was otherwise healthy.

## Unrelated finding: MOK certificates accumulate

`mokutil --list-enrolled` on fiend shows **eight** distinct kldload MOK
certificates, one per install/rebuild since 2026-08-02, none ever
removed:

    kldload-mok-20260802201418   kldload-mok-20260803214716
    kldload-mok-20260802230137   kldload-mok-20260810132316
    kldload-mok-20260803122931   kldload-mok-20260811021059
    kldload-mok-20260803160104   kldload-mok-20260813022408

Only the newest signs anything. The other seven remain trusted to load
kernel modules and EFI binaries on this machine forever. Each is a
private key that existed on some earlier build host, and the whole point
of Secure Boot is that the set of keys allowed to load code is small and
deliberate. Worth a cleanup pass that removes superseded kldload MOKs at
enrollment time.
