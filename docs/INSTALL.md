# Installing kldload

The complete install guide. The README carries a short version; this is the
one to read if something goes wrong, or if you want to understand what the
installer is actually doing to your machine.

**Version this describes:** 1.4.0-rc2 · **Last verified:** 2026-08-10

---

## Contents

1. [Before you start](#1-before-you-start)
2. [Get and verify the image](#2-get-and-verify-the-image)
3. [Write it to a USB stick](#3-write-it-to-a-usb-stick)
4. [Boot the installer](#4-boot-the-installer)
5. [Answer the installer](#5-answer-the-installer)
6. [First boot: the Secure Boot enrollment](#6-first-boot-the-secure-boot-enrollment)
7. [Secure Boot: on or off](#7-secure-boot-on-or-off)
8. [Verify the install](#8-verify-the-install)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Before you start

**What you need**

| | |
|---|---|
| A 64-bit x86 machine | UEFI firmware. Legacy BIOS-only machines are not supported. |
| A USB stick, 16 GB or larger | The image is ~12 GB. |
| A target disk | **It will be erased.** |
| Network | Optional for most distributions — see below. |

**About the network.** Debian, Ubuntu and Fedora installs are fully
offline: their packages are baked into the image. **Arch installs require
internet** — it is a rolling release with no fixed package set to pre-stage.
Enterprise Linux targets (CentOS Stream, Rocky, RHEL) fall back to the
network for some packages because the image is built on Fedora and cannot
mirror EL repositories.

**About RAM.** The installer runs from a live environment that holds the
package mirror in memory. 8 GB is comfortable; 4 GB works but is tight on
the desktop profile.

---

## 2. Get and verify the image

Download the ISO and its checksum from the release page, then check it
before you write it. A truncated download produces an installer that fails
in confusing ways much later.

```bash
sha256sum -c kldload-1.4.0-rc2-x86_64.iso.sha256
```

Building from source instead:

```bash
git clone https://github.com/kldload/kldload.git
cd kldload
PROFILE=desktop ./deploy.sh build      # 30–60 min
```

The build runs in a container and needs podman with the ZFS storage driver.
If it complains that a dataset does not exist, create the chain first —
the README's build section has the three `zfs create` commands.

---

## 3. Write it to a USB stick

**Identify the stick first.** This step destroys whatever is on the target.

```bash
lsblk -dno NAME,SIZE,RM,MODEL          # RM=1 means removable
```

Then write it:

```bash
sudo ./deploy.sh burn /dev/sdX         # asks for confirmation
```

or by hand:

```bash
sudo dd if=kldload-1.4.0-rc2-x86_64.iso of=/dev/sdX bs=4M \
        status=progress oflag=direct conv=fsync
```

`conv=fsync` matters: without it `dd` returns while gigabytes are still in
the page cache, and pulling the stick at that point gives you a half-written
image that boots far enough to fail strangely.

**Verify the write** — worth the two minutes, because a bad stick looks
exactly like a broken installer:

```bash
SIZE=$(stat -c%s kldload-1.4.0-rc2-x86_64.iso)
sudo dd if=/dev/sdX bs=1M count=$((SIZE/1048576)) iflag=fullblock status=none | sha256sum
sha256sum kldload-1.4.0-rc2-x86_64.iso
```

The two digests must match. **Leave the stick plugged in until this
finishes** — unplugging mid-read produces I/O errors that look like a
failing stick but are not.

---

## 4. Boot the installer

1. Boot the machine from the USB stick (usually `F12`, `F11` or `Esc` for a
   boot menu).
2. **If Secure Boot is currently enabled**, the live image may refuse to
   boot. Disable it in firmware setup for now — you will turn it back on in
   step 6, after the installer has generated and staged its key.
3. The desktop loads and the installer opens automatically in the browser at
   `https://<host>:8443`. There is no login prompt and no certificate
   warning.

The live environment's own credentials are `live` / `live` if you need a
shell.

---

## 5. Answer the installer

The installer asks for, in order:

**Distribution.** One of Debian, Ubuntu, Fedora, CentOS Stream, Rocky, RHEL,
Arch, or Alpine. This is the substrate that gets installed — kldload is the
installer and the assembled system, not a distribution of its own.

**Profile.** `desktop` gives a workstation with the graphical consoles;
`server`, `kvm`, `klab`, `zfslab` and `core` give progressively narrower
server-class systems whose only surface is the web console on port 8443.

**Target disk.** Erased completely.

**Encryption.** Pre-selected, and recommended. Set a **disk encryption
passphrase** here — you will be asked for it at every boot, before the
system starts. It is not your login password.

**Secure Boot.** Enabled by default. See
[section 7](#7-secure-boot-on-or-off) if you are unsure.

**Account.** The name you enter here is the admin account. It is a
`wheel`/`sudo` member and, from 1.4.0-rc3, is also added to the `libvirt`
and `kvm` groups so the virtualisation tools do not raise a password prompt
on every action.

When a Secure Boot install finishes, the machine **powers off** rather than
rebooting. That is deliberate: it hands you control of the enrollment boot
instead of racing an automatic restart. **Remove the USB stick now.**

---

## 6. First boot: the Secure Boot enrollment

This is the step people get wrong, so it gets its own section.

kldload generates a **Machine Owner Key** (MOK) unique to each install. It
signs two things with it:

- **ZFSBootMenu** on the EFI system partition — the boot chain.
- **DKMS kernel modules**, notably ZFS itself.

For Secure Boot to allow either, that key has to be enrolled in firmware.
Enrollment cannot be automated: it deliberately requires physical presence.

**The sequence**

1. Power on and enter firmware setup (usually `Del`, `F2` or `F10`).
2. **Enable Secure Boot.** Save and exit.
3. On the next boot a blue **MokManager** screen appears. It waits about
   **ten seconds**, so press a key immediately.
4. **Enroll MOK → Continue → Yes → password `kldload` → Reboot.**

> The password is literally `kldload`. It is not your admin password and not
> your encryption passphrase. Set a different one at install time with
> `KLDLOAD_MOK_PASSWORD`.

5. At the **ZFSBootMenu** prompt, enter your encryption passphrase.
6. The desktop loads and the console is at `https://<host>:8443`.

**Two ways this goes wrong, and they look nothing alike:**

**You miss the ten-second window, or click "Continue boot".** The request is
discarded. Nothing breaks immediately — that is the trap. The machine boots
normally and looks fine. It stays fine until the next kernel update rebuilds
the ZFS module, at which point the new module is signed by a key firmware
does not trust, and the machine stops booting properly. See
[emergency mode](#boots-to-emergency-mode) below.

kldload re-stages the enrollment on every boot while the key is neither
enrolled nor pending, so simply rebooting usually gives you the prompt
again. If it does not:

```bash
sudo kldload-mok-repair repair
sudo reboot
```

**You type the password wrong.** MokManager silently consumes the request
and boots normally. There is no error. It is indistinguishable from having
clicked past the prompt, so if enrollment "did not take", re-stage and try
again rather than assuming something deeper is broken.

---

## 7. Secure Boot: on or off

Both are supported. Neither is wrong. The question is what you are
protecting against.

**What Secure Boot buys you.** It defends the boot chain against someone
who already has root or physical access — specifically, a bootkit that
survives a reinstall. It does nothing about remote compromise of a running
system.

**What it costs you.** Enabling it puts the kernel in lockdown, which
restricts `/dev/mem`, `kexec`, hibernation and some kernel-debugging paths.
On a machine doing ZFS module or eBPF work that is real friction.

**A reasonable default**

| Machine | Recommendation |
|---|---|
| Laptop, or anything that leaves the building | **On**, enrolled properly. This is the threat model Secure Boot exists for. |
| Lab box, build host, rack server behind a locked door | Either. **Off** is defensible and removes the enrollment step entirely. |
| Anything being demonstrated | **On** — a signed boot chain is part of what is being shown. |

**The one state to avoid is half-enrolled**: Secure Boot on, key not
enrolled. That is the configuration that looks fine today and fails at the
next kernel update. Decide, then be consistent — if you are running with
Secure Boot off, that is fine, but do not leave a staged-and-never-enrolled
key behind you.

Turning Secure Boot off does **not** bypass disk encryption. The
ZFSBootMenu passphrase is asked either way.

---

## 8. Verify the install

```bash
sudo kldload-mok-repair status     # Secure Boot state, enrolled keys, boot-chain signature
zpool status                       # the pool imported and is healthy
systemctl --failed                 # nothing should be listed
```

`kldload-mok-repair status` is the one that answers "is Secure Boot set up
correctly on this machine" in a single line. It reports whether Secure Boot
is on, every enrolled MOK (flagging stale ones from previous installs),
anything pending, and whether the ZFSBootMenu on the ESP is signed by a key
that is actually enrolled.

The console is at `https://<host>:8443`. On the machine itself it never
prompts for a login; remote browsers sign in with the admin account.

---

## 9. Troubleshooting

### Boots to emergency mode

Systemd reached a shell but could not bring the system up. Because systemd
started at all, the bootloader and kernel are fine — this is a later mount
or unit failing.

The most common cause on a Secure Boot machine is an unenrolled MOK. With
Secure Boot on, the kernel refuses modules it cannot verify; once DKMS has
rebuilt ZFS against an untrusted key, the module will not load, non-root
datasets do not mount, and you land here.

Confirm it:

```bash
mokutil --sb-state              # is Secure Boot on?
modprobe zfs                    # look for "Key was rejected by service"
lsmod | grep zfs
systemctl --failed
journalctl -xb -p err --no-pager | tail -40
```

`Key was rejected by service` (`-EKEYREJECTED`) is conclusive: that is
lockdown refusing an unverified module.

**Two fixes.** Either enroll the key properly —

```bash
sudo kldload-mok-repair repair
sudo reboot                     # then Enroll MOK, password kldload
```

— or, if this is a lab box and you do not want Secure Boot anyway, disable
Secure Boot in firmware. The machine boots straight away and there is
nothing to undo later.

If instead the pool failed to import, it is a different problem: check
`zpool import` and compare `hostid` with `/etc/hostid`. A hostid mismatch
and a pool feature set the target's ZFS cannot mount read-write are the two
other known causes of a boot that never reaches a login.

### "Secure Boot validation failed" at boot

The boot chain itself is rejected — the ZFSBootMenu on the ESP is signed by
a key firmware does not trust. There is no OS to fix it from, so boot the
live USB and run `sudo kldload-mok-repair repair` there; it read-only
imports the installed pool to find the key.

Temporarily disabling Secure Boot in firmware also gets you booted, which is
often the faster route to a working shell.

### Reinstalled several times, MOK operations start failing

Every install generates a fresh key, so NVRAM accumulates stale
`kldload-mok-*` certificates — seventeen were observed on one lab machine.
`sudo kldload-mok-repair repair` queues a MOK-list reset **and** an
enrollment of the current key in one pass.

### Modules will not load (ZFS, NVIDIA)

Same cause as emergency mode: the signing key is not enrolled.
`sudo kldload-mok-repair status` shows the signer.

### Virtualisation tools prompt for a password on every action

The admin account is not in the `libvirt` group. Being in `wheel` or `sudo`
does not help — the distribution's polkit rule grants passwordless libvirt
access to that group specifically.

```bash
sudo usermod -aG libvirt,kvm "$USER"
```

Then **log out and back in** — group membership is established at login.
Fixed at install time from 1.4.0-rc3 on; this only affects earlier installs.

### Console certificate warning

Should not happen on a fresh install. If it does, re-import the CA root:

```bash
kldload-trust-cert
```

If that does not clear it, drop the stale entries first:

```bash
certutil -d sql:"$HOME/.pki/nssdb" -D -n kldload-webui 2>/dev/null
certutil -d sql:"$HOME/.pki/nssdb" -D -n kldload-ca     2>/dev/null
kldload-trust-cert
```

### Console asks for a password

Only remote browsers do. Sign in with the admin account. On the machine
itself the console never prompts.

### Forgot the MOK password

It is `kldload`.

---

## Where things live

| | |
|---|---|
| Install log | `/var/log/kldload/` |
| Install answers | `/etc/kldload/install-manifest.env` |
| MOK keypair | `/var/lib/dkms/mok.{key,pub,der}` |
| Console | `https://<host>:8443` |
| Ingested console versions | `/etc/kldload/{zxplore,wgxplore,vmxplore}-commit` |
