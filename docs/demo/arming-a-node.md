# Arming a node for an unattended netboot install

How to point a bare machine at the netboot server and have it install itself,
and the failure modes that cost an afternoon on 2026-09-16 when filming the
demo. The mechanics are simple. The ordering rules are not obvious and every
one of them below was learned by breaking it.

---

## What "armed" means

The netboot server serves an image to anyone who asks, but it will not install
over a machine's disk unless that machine's MAC has a **consent token**. Arming
writes that token. Disarming removes it.

An unarmed machine that netboots fetches the boot script, finds no entry for its
MAC, prints that it is continuing the boot order, and boots from its own disk.
That is the safe default and it is why the token exists: an accidental network
boot cannot wipe a machine.

    kldload-netboot-server arm-install <mac> <answers.env>
    kldload-netboot-server status
    kldload-netboot-server disarm <mac>

**While armed, the answers file is served over HTTP with no authentication.**
It contains the install password. Disarm as soon as the install is done; the
tool warns about this every time for a reason.

---

## The procedure

1. **Clear any leftover connections**, then confirm zero:

       ss -tn 'sport = :8081'

   If any linger from an earlier attempt, restart the service rather than
   killing sockets by hand.

2. **Arm**, and read the line back. It names the profile it will install, so a
   wrong answers file is visible here rather than twenty minutes later:

       kldload-netboot-server arm-install f0:2f:74:... .../<mac>.env
       # ARMED-INSTALL f0:2f:74:... — next netboot installs fedora/desktop

3. **Boot the machine** into its network entry. If nothing sets a one-time boot
   order, pick it from the firmware menu; the arm alone does not cause a
   netboot.

4. **Leave everything alone until it finishes.** This is the rule that matters.
   See below.

5. **Disarm** once it has rebooted into the installed system.

---

## The same thing, for a rack

Nothing above is per-machine except the answers file, and that is the point.
The work of provisioning N machines is inventorying N MAC addresses; everything
after that is one command.

    kldload-netboot-server arm-all <dir> [--dry-run]

It arms every `<mac>.env` in a directory, and **refuses duplicate MACs or
hostnames** rather than half-arming a rack and leaving you to find the clash
later. It exits non-zero unless all of them armed, so a partial success is a
failure you hear about.

    kldload-netboot-server disarm-all

The economics are what make this different from provisioning at scale over the
internet:

- **The image is uploaded once.** One 13.9 GB payload is staged on the server
  and served to every machine that asks. Adding the fiftieth machine costs
  nothing extra to prepare.
- **There is no other network traffic.** No package mirrors, no container
  registries, no vendor endpoints. Everything a machine needs to become a
  working system is inside the image already. A rack can be built in a room
  with no internet connection at all, which is the entire reason the darksite
  payload exists.
- **The only thing that reaches outside is building cloud images**, and that is
  a separate, earlier step done once on the build host — not something every
  target does for itself while you watch.

So the scaling story is honest in a way "it scales" usually is not: the second
machine and the fiftieth cost the same, because the expensive part happened
before any of them were switched on.

Per-machine differences live in the answers file: hostname, disk, profile, how
many control planes and workers. Same image, different answers.

---

## Do not touch it while a boot is in flight

Every failure on 2026-09-16 traces back to changing something mid-boot.

**Disarming mid-boot is not a clean abort.** The target had already pulled the
full 13.9 GB image and was about to fetch its answers. Disarming deleted the
answers from the served tree, the fetch returned 404, and with nothing to
install the target fell back and restarted the entire download. Watching from
outside it looked like a slow network. It was the same image being fetched and
thrown away, repeatedly.

**Arming "just in case" is worse than not arming.** A token that exists for a
few seconds can be caught by a machine mid-boot, which then starts an install it
cannot complete once the token is gone.

**Never kill connections or reload the server during a transfer.** Doing so
drops the client's root image and the screen goes black. If a run must be
abandoned: stop it, wait for the sockets to close, then re-arm.

To abort cleanly: power the target off, wait for the connections to clear,
then decide what to do.

---

## Why a target can look "slow"

Three separate causes, all of which present as low throughput.

**The target takes TWO DHCP leases.** One in iPXE and another in dracut, so it
appears as two addresses with the same MAC. Both can end up fetching the image,
which means a machine oversubscribing its own single NIC with two copies of the
same 13.9 GB file. Check for this before blaming the network:

    ip neigh show | grep <mac>    # two addresses, one MAC

**Abandoned transfers linger.** nginx's `send_timeout` is 300s, so a transfer
whose client vanished keeps retransmitting for five minutes and competes with
the live one. Shortening that timeout is tempting and is a trap: too short and
it reaps a client that merely stalled, which is just as fatal. Prefer clearing
connections between runs over tuning the timeout down.

**Speed mismatch between server and target.** A 10G server streaming to a 1G
target forces the switch to buffer 10:1 into that port; when the buffer fills it
drops. Measured on this pair: 2.3% retransmits under cubic. Capping the server
with nginx `limit_rate` to roughly 80% of the target's link removes it. This is
**not** currently the shipped default — it was applied by hand and is worth
considering if you provision 1G targets from a 10G server.

Do not "fix" this with a different congestion control algorithm. BBR was tried
and made it worse — 8.7% loss versus 2.3% — precisely because it does not back
off on loss and so overran the buffer faster. The loss is receiver-side, not
congestion, and BBR is the wrong tool for it.

---

## Confirming the install actually started

Two lines in the netboot access log, and only these two, prove an unattended
install rather than an interactive installer sitting idle:

    GET /kldload/squashfs.img          200  14936690688   <- COMPLETE image
    GET /answers/<mac>.env             200                <- token was present

A short byte count is an aborted transfer. A 404 on the answers file means the
machine booted with nothing to install and will loop.

On the target itself, progress is visible long before the installer's step
counter moves — it sits on step 1 through the whole unpack:

    zpool list -H -o alloc rpool      # bytes landed on the target
    rpm --root=/target -qa | wc -l    # packages installed

---

## After it reboots

**The installed system may come back on a different address than the installer
had.** The PXE lease and the installed system's lease are not the same. Looking
for the old address and concluding the machine is dead is an easy mistake; scan
for the MAC instead.

**Check the profile installed what you expected.** A profile with no desktop
packages ends at a console, which is only discovered at the end unless you look:

    rpm --root=/target -q gnome-shell gdm    # during the install, not after
