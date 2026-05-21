# WireGuard kill-switch via AllowedIPs

A WireGuard peer config with `AllowedIPs = 0.0.0.0/0` routes ALL the
client's traffic through the tunnel. If the tunnel drops, the routes
go with it — and the client suddenly has no internet. That's the
kill-switch.

## How it works

`AllowedIPs` in a `[Peer]` block does two things simultaneously:
1. **Crypto-routing**: decides which traffic gets encrypted to this peer
2. **OS routing**: `wg-quick` installs system routes matching the same list

So `AllowedIPs = 0.0.0.0/0, ::/0` adds a default route via the tunnel.
When `wg-quick down` runs (or the tunnel dies), `wg-quick` removes
those routes. The client falls back to its underlying default route
— but that route is the LAN gateway, which only sees encrypted WG
packets to the server. Without WG up, those packets stop.

## Belt-and-suspenders firewall kill-switch

`wg-quick`'s `PostUp` / `PostDown` hooks let you add explicit firewall
rules that DROP traffic to/from any interface EXCEPT the WG interface.
Then even a botched `wg-quick down` (e.g., manual `ip link set wg0 down`)
keeps the client offline:

```ini
[Interface]
Address    = 10.250.1.5/24
PrivateKey = …
DNS        = 10.250.1.1

# Kill-switch: block everything except WG itself + DHCP/DNS
PostUp = iptables -I OUTPUT ! -o %i -m mark ! --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT
PostDown = iptables -D OUTPUT ! -o %i -m mark ! --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT
# ip6tables variants follow the same pattern with v6 addresses.

[Peer]
PublicKey  = …
Endpoint   = your-host:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

After `wg-quick up`, the OUTPUT chain rejects any packet that isn't
either:
- destined for the WG interface (marked with the tunnel's fwmark), OR
- destined for a LOCAL address (so 127.0.0.1 + LAN broadcast still work)

If `wg0` goes down, traffic that would have gone via the default route
now hits the REJECT rule. No leaks.

## Verify the kill-switch works

```bash
# Bring up tunnel
sudo wg-quick up wg0
curl https://api.ipify.org    # should show tunnel exit IP

# Simulate tunnel failure WITHOUT cleanly tearing down — the
# kill-switch should keep blocking traffic
sudo ip link set wg0 down
curl --connect-timeout 5 https://api.ipify.org    # should TIMEOUT / fail

# Clean teardown removes the kill-switch
sudo wg-quick down wg0
curl https://api.ipify.org    # back to public IP
```

## Not a kill-switch for the server

The kill-switch protects the client. The kldload box (server side) sees
encrypted WG packets and uses normal routing. If you also need the
SERVER side to refuse traffic from unauthorised endpoints, that's
firewall + `wg set wg0 peer <pub> allowed-ips <client-only-cidr>`
work, not kill-switch territory.
