# WireGuard, from first principles

> Background for the [wgxplore README](../README.md): what the protocol is,
> why it changes networking, and the kernel trick the container attach uses.

If you already run WireGuard, skip ahead. If not, this is the foundation
everything below stands on.

**WireGuard is a VPN protocol built into the Linux kernel** (mainline
since 5.6, 2020 — and implemented on every other OS that matters). It
does one thing: an encrypted tunnel between two machines.

Chances are you've used it without knowing. **NordVPN's "NordLynx" is
WireGuard** under a brand name. **Mullvad**, **Proton VPN**, and
**Surfshark** run on it. **Tailscale** is WireGuard with a SaaS
coordination service wrapped around it. Your **MikroTik**, **Ubiquiti
UniFi**, **OPNsense**, **OpenWrt**, or **GL.iNet** router speaks it
natively, and the stock WireGuard app is on every phone's app store.
When the industry ships a VPN today, this protocol is what's inside the
box — the brands differ in what they wrap around it.

What made it famous is how it does it:

- **Identity is a keypair, like ssh.** No certificates, no CAs, no
  usernames. A machine *is* its key; a tunnel is "my private key + your
  public key." If you've ever added an ssh public key to
  `authorized_keys`, you already understand WireGuard's entire trust
  model.
- **The peer list is the firewall.** Each peer entry says which addresses
  that key may use (*cryptokey routing*). A packet from an address the
  key doesn't own is dropped by the kernel; a machine whose key you never
  added cannot produce a single byte your interface will accept. Policy
  isn't a service that checks packets — it's arithmetic on keys.
- **It's ~4,000 lines of code.** OpenVPN and IPsec are hundreds of
  thousands. Small enough to actually audit, with one modern cipher suite
  (Noise framework, ChaCha20-Poly1305, Curve25519) and **no negotiation**
  — there is no "downgrade to the broken cipher" attack because there is
  nothing to negotiate.
- **It's invisible.** A WireGuard port never answers an unauthenticated
  packet — to a scanner, the port doesn't exist. Your network can't be
  probed by anyone who isn't already in it.
- **It's in the kernel**, so it runs at line rate on all cores, and
  roaming is built in — change networks mid-connection (wifi → LTE) and
  the tunnel just follows.

Why this changes how we interact with networks: the old model trusts
*places* — the office LAN, the home wifi, the cloud VPC — and breaks the
moment your machines live in more than one place. WireGuard inverts it:
**trust keys, not networks.** Any two machines that hold each other's
public keys share a private, encrypted wire across any hostile network in
between — coffee-shop wifi, an ISP, the open internet. The network stops
being something you're *on* and becomes something you *declare*.

But notice what WireGuard actually hands you: **a perfect wire** — one
encrypted link between two keys. A *network* is everything it
deliberately doesn't ship: deciding who belongs, giving them addresses,
choosing the shape (mesh? hub and spokes?), keeping every machine's
config consistent as members come and go, seeing the whole thing at
once, and noticing a wire you never declared. Its authors left all of
that to userspace, on purpose.

**wgxplore is the tool you build the networks with.** You declare the
network — members, addresses, topology — in one file, and wgxplore
renders it down to perfect wires: plain WireGuard configs, applied with
plain `wg`/`ip` commands, watched as one estate. WireGuard is the wire.
wgxplore is the network.


## The netns move

Linux runs many independent network stacks on one kernel — each *network
namespace* (netns) has its own interfaces, routes, firewall, sockets. A
container's "network isolation" is exactly this; `--network none` means its
netns holds nothing but loopback.

WireGuard interfaces have a property most tooling ignores: **the encrypted
UDP socket stays anchored in the namespace where the interface was
created**, even after the interface moves. `wgx attach` exploits exactly
that: create and configure the interface in the **host** namespace (the
socket anchors where the real NIC lives), move it into the container with
`ip link set … netns`, address it from inside via `nsenter`. Everything the
container sends is encrypted *by the kernel* before it exists anywhere else;
the container never touches the underlay. The same move works on any netns —
VMs bridged through one, or namespaces you built with `ip netns add`.


### The same idea, no jargon

Your Minecraft world is just a save file: copy it to a friend's PC, open
it, and it's your whole world — you didn't rebuild anything. Most servers
don't work like that; they're Lego builds *glued to the table*. Want one
somewhere else? Order the pieces again and rebuild by hand.

This stack unglues them, with two tricks. **One:** everything — the
database, the website, a whole virtual computer — becomes a save file
(a ZFS dataset) that copies perfectly, and re-copies send only what
changed since yesterday, like syncing new photos instead of the whole
camera roll. **Two:** every machine and app gets a phone number that
follows it around (its wgxplore address) — the number belongs to the
*thing*, not the place it's plugged in, and the line is encrypted by the
operating system itself.

Save file + phone number = you can **beam an app between machines**:
copy the changes, start it there, the number comes with it, and
everything that talked to it before keeps working like nothing moved. If
the connection dies halfway, it resumes where it stopped. Apps stop
being glued to computers — they become save files with phone numbers,
and those can live anywhere.

