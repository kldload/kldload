# Provision a rack from one USB

One kldload USB stick installs one machine. The same stick, booted in its
**rack mode**, is the network server for every other machine on the switch: it
serves its own kernel, initramfs and root image, and nothing is installed or
written on the machine running it. This page is the whole procedure for 1.5.0,
including the parts that bite.

## What you need

- **The image.** The full edition carries every offline mirror and is what a
  rack with no internet needs:

  ```bash
  curl -L -o kldload.iso https://dl.kldload.com/kldload-free-latest.iso
  curl -L -o kldload.iso.sha256 https://dl.kldload.com/kldload-free-latest.iso.sha256
  # the .sha256 names the release file (kldload-1.5.0-x86_64.iso), so compare the hash itself
  [ "$(sha256sum < kldload.iso | cut -d' ' -f1)" = "$(cut -d' ' -f1 kldload.iso.sha256)" ] && echo OK
  ```

- **A USB stick of 32 GB or more.** The 1.5.0 full image is 16.9 GB.
- **The master:** any x86_64 machine that boots UEFI from USB and has a port on
  the rack's switch. It keeps nothing: pull the stick and it is untouched.
- **Each target:** UEFI network boot on a port on the same switch, and **more
  RAM than the image**. A network install loads the whole 16.9 GB root image
  into memory. An 8 GB machine gets part way and panics with *System is
  deadlocked on memory* (measured 2026-09-27). The exact floor has not been
  measured, so allow the image size plus room for the installer.

## 1. Make the master USB

```bash
sudo wipefs -af /dev/sdX
sudo dd if=kldload.iso of=/dev/sdX bs=4M oflag=direct conv=fsync status=progress && sync
```

From a checkout, `sudo ./deploy.sh burn /dev/sdX` does the same and shows you
the device before it writes.

## 2. Boot the master in rack mode

Boot the stick and press **`p`** at the boot menu: *kldloadOS Live — provision
the rack from this USB (PXE server)*. The live system starts
`kldload-netboot-live.service`, which arms **every** machine that network-boots
with the install menu and serves the stick's own files.

Log in on the console, or over ssh, as `live` / `live`, and check:

```bash
sudo kldload-netboot-server status
# payload : the live medium (/run/initramfs/live) ...
# armed   : any -> install menu for ANY machine (open mode: a key installs,
#           the countdown boots its own disk)
```

## 3. The network: which of two cases is yours

**A switch that already has a DHCP server** (a router, pfSense, an office LAN):
nothing to do. The server runs in *proxy* mode: it answers only the network-boot
part and hands out no addresses, so it never fights the DHCP you have.

**An air-gapped switch with nothing else on it** — the case the offline image
exists for: the master has to hand out the addresses itself, and it needs an
address first. On the master:

```bash
ip -br link                                   # find the rack NIC, e.g. enp3s0
sudo ip addr add 10.99.0.1/24 dev enp3s0
printf 'NETBOOT_IFACE=enp3s0\nNETBOOT_DHCP=standalone\n' | sudo tee /etc/kldload/netboot.env
sudo systemctl restart kldload-netboot-live
sudo kldload-netboot-server status             # service : active
```

`standalone` serves addresses from the interface's own /24 (set
`NETBOOT_DHCP_RANGE` for anything else). Setting `NETBOOT_IFACE` matters in 1.5.0
for a second reason: see *Known issues*. Standalone mode has not yet been run on
the live stick in our own tests; proxy mode has (2026-09-27, below).

## 4. Boot the targets

Put network boot first in each target's firmware and power it on. It shows the
kldload menu with a countdown:

- **Left alone, it boots its own disk.** A machine that network-boots by
  mistake loses nothing.
- **Any key opens the install.** Pick a profile (core, server, desktop, kvm,
  k8s, storage, ai), a distribution, and options. The password, and the disk to
  erase, are asked for on the target's own screen before anything is erased —
  nothing secret ever crosses the wire.

## 5. Unattended: a directory of machines

With no one at each keyboard, arm machines by MAC with a complete answers file.
From the master's shell:

```bash
mkdir rack && cp /etc/kldload/answers/TEMPLATE.env rack/TEMPLATE.env
# edit TEMPLATE.env: KLDLOAD_DISK (by-id), KLDLOAD_PASSWORD, profile, ...
while read -r mac; do
    sed "s/^KLDLOAD_HOSTNAME=.*/KLDLOAD_HOSTNAME=node-${mac//:/}/" rack/TEMPLATE.env > "rack/${mac}.env"
done < macs.txt
rm rack/TEMPLATE.env
sudo kldload-netboot-server arm-all ./rack/ --dry-run   # checks every file, arms nothing
sudo kldload-netboot-server arm-all ./rack/             # exit is non-zero unless every one armed
```

An armed machine shows what it was armed with, counts down, and installs
exactly that file. `arm-all` refuses the whole batch on a duplicate MAC or
hostname. **An answers file with a password is served to the wire until you
disarm it:** `sudo kldload-netboot-server disarm <mac>` once a machine is
installing, or `disarm-all`.

Tested on 2026-09-27 on a build newer than 1.5.0: the stick booted in rack mode
in a VM on an isolated network, a UEFI client armed by MAC from the live shell
fetched its boot script, its armed menu, the kernel and initramfs, and pulled
the root image off the stick — with nothing installed on the machine serving.

## Known issues in 1.5.0

- **No default route, no service.** The server picks its interface from the
  default route. On a switch with no gateway it finds none and
  `kldload-netboot-live` restarts every few seconds with *could not determine an
  address to serve on*. Set `NETBOOT_IFACE` as in step 3. Fixed after 1.5.0
  (5c020bd6): with no default route it serves on the one interface that has an
  address.
- **Target RAM.** See *What you need*. A check that tells a small machine why,
  or sends it the 2.1 GB net image, is not written yet.
- **The Kubernetes profile is not offline in 1.5.0.** Its cluster build fetches
  containerd, kubeadm and the container images from the internet. Fixed after
  1.5.0: the goldens now build from the master's own mirror.
- **Turning the shows off.** 1.5.0 has no answers-file switch for the install
  and first-boot shows. `kldload.kiosk=0` on a boot line gives a desktop instead
  of the install kiosk, and `kldload.firstboot_show=console` (or `=0`) keeps the
  first boot on the plain console. After 1.5.0, `KLDLOAD_SHOW=0` in an answers
  file does all of it.

See also: [arming a node, its failure modes and what to check](demo/arming-a-node.md).
