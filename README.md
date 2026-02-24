# unifi-v6plus-static-ip

[日本語](README.ja.md) | [English](README.md)

Scripts for **UniFi OS gateways (UDM / UDR)** to run a **v6plus static IPv4 (/32)** service delivered via an **IPv4-over-IPv6 (IPIP6) tunnel**, while keeping **native IPv6** working as-is.

This targets ISPs that provide something like:

- **Static IPv4 address**: `x.x.x.x/32`
- **IPv6 prefix**: `xxxx:....::/64`
- **BR (Border Relay) IPv6 address**: `xxxx:....::xx`
- **Provider-assigned IPv6 address for the tunnel local endpoint**
  (i.e., the prefix plus a fixed "host part", sometimes called an **Interface Identifier / IID**)

…and whose sample configs (e.g., Yamaha RTX) include `tunnel encapsulation ipip`.

> ⚠️ Disclaimer  
> Use at your own risk. UniFi OS / Network upgrades may change interface names, firewall chains, or behaviors.

> 🔐 Security note  
> Never commit ISP update URLs / credentials. Keep secrets out of Git.  
> The addresses in `config/v6plus.env.example` are documentation examples — replace them with ISP-assigned values.

---

## Note (Japan-specific)

"v6 Plus" (v6プラス) is a Japan-specific commercial service name (IPoE + IPv4-over-IPv6) commonly used on NTT East/West NGN-based Internet access.
Outside Japan, similar IPv4-sharing solutions are more often described as CGNAT or DS-Lite, and the term "v6 Plus" is generally not used.

Technically, this setup relies on MAP-E (RFC 7597) / IPv4-over-IPv6 concepts, but the UI/ISP terminology in this README assumes a Japanese ISP environment.

---

## What this does

- Creates an **ipip6 tunnel** (IPv4-in-IPv6) toward your ISP BR.
- Assigns your **static IPv4 /32** to the tunnel interface.
- Routes **forwarded IPv4 traffic from LAN** into a dedicated routing table using **`ip rule ... iif <LAN_IF>`** (so the gateway's own traffic is less likely to get impacted).
- Adds a **default route in the main table** so the gateway itself can also reach the internet via the tunnel.
- Adds the provider-assigned tunnel-local IPv6 to WAN as **/128** (not /64) to avoid messing with native IPv6 source address selection.
- Adds SNAT for LAN -> tunnel using your static IPv4.
- Adds TCP MSS clamp for stability.

---

## Prerequisites (UniFi Network UI)

Before running the script, configure UniFi Network so that:

1) your WAN IPv4 is set to **DHCPv4**, and
2) the WAN uses **DHCPv6** (so the gateway can receive IPv6 + Prefix Delegation), and
3) your LAN uses **Prefix Delegation** from that WAN.

> **Why DHCPv4 and not MAP-E / v6 Plus?**  
> When WAN is set to MAP-E / v6 Plus, UniFi creates its own `ip6tnl1` tunnel and adds conflicting policy routing rules (table 201) that override the custom tunnel. DHCPv4 + DHCPv6 avoids this — UniFi does not create a competing tunnel, so `v6plus0` works cleanly.

### 1) Internet (WAN): DHCPv4 + IPv6 DHCPv6

Open:

- `UniFi Network` → `Settings` → `Internet`  
  URL: `https://192.168.1.1/network/default/settings/internet`

Edit your WAN and set:

**IPv4 Configuration**
- **Connection**: `DHCPv4`

**IPv6 Configuration**
- **Connection**: `DHCPv6`

Apply/Save.

### 2) Networks (LAN): IPv6 Interface Type = Prefix Delegation

Open:

- `UniFi Network` → `Settings` → `Networks`  
  URL: `https://192.168.1.1/network/default/settings/networks`

Edit your LAN network (e.g., `Default`) and set:

**IPv6**
- **Interface Type**: `Prefix Delegation`
- **Prefix Delegation Interface**: select the WAN from step 1

Apply/Save.

---

## Repository layout

```text
unifi-v6plus-static-ip/
  README.md
  README.ja.md
  LICENSE
  scripts/
    v6plus-static-ip-iif.sh
    v6plus-watch.sh
    v6plus-diag.sh
  config/
    v6plus.env.example
  systemd/
    v6plus-static-ip.service
    v6plus-watch.service
```

---

## Quick start (SCP-based)

This guide assumes you copy files from your PC to the gateway via **SCP**.

### 0) Enable SSH and prepare your PC

- Enable SSH on the gateway (UniFi settings).
- Make sure your PC has `ssh` and `scp` available (macOS/Linux usually do).

Gateway IP in examples below: `192.168.1.1`  
Adjust it if your gateway IP is different.

### 1) Copy files to the gateway (from your PC)

From your PC, in the cloned repo directory:

```sh
# copy the main script
scp scripts/v6plus-static-ip-iif.sh root@192.168.1.1:/data/v6plus-static-ip-iif.sh

# copy the watchdog script
scp scripts/v6plus-watch.sh root@192.168.1.1:/data/v6plus-watch.sh

# copy the diagnostic script
scp scripts/v6plus-diag.sh root@192.168.1.1:/data/v6plus-diag.sh

# copy the env template (you will edit it on the gateway)
scp config/v6plus.env.example root@192.168.1.1:/data/v6plus.env
```

> `/data` is the persistent storage area on UniFi OS gateways.

### 2) SSH into the gateway and edit the env

```sh
ssh root@192.168.1.1
vi /data/v6plus.env
```

At minimum you must set these values:

- `WAN_IF` (your WAN interface name)
- `LAN_IF` (typically `br0`)
- `LAN_CIDR` (e.g., `192.168.1.0/24`)
- `STATIC_V4` (your static IPv4)
- `PROVIDER_ASSIGNED_LOCAL_V6` (tunnel local IPv6, added to WAN as /128)
- `BR_V6` (BR IPv6)
- `TUN_IF` (e.g., `v6plus0`)
- `TUN_MTU`, `MSS`
- `ROUTE_TABLE`, `RULE_PREF`

Tip to find interface names:

```sh
ip link
ip -6 addr
```

### 3) Make scripts executable

```sh
chmod +x /data/v6plus-static-ip-iif.sh
chmod +x /data/v6plus-watch.sh
chmod +x /data/v6plus-diag.sh
```

### 4) Apply

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh apply
```

### 5) Check status

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh status
# or use the diagnostic script
/data/v6plus-diag.sh
```

### 6) Rollback / disable

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh off
```

---

## Persistence (keep settings after reboot)

UniFi OS resets tunnel / ip rule / iptables on reboot. Use **systemd** to persist settings.

> **Note:** On UDR/UDM, systemd unit files must be placed as **real files** in `/etc/systemd/system/` — symlinks to `/data` do **not** work.

### Install systemd services

Copy the service files to the gateway:

```sh
scp systemd/v6plus-static-ip.service root@192.168.1.1:/etc/systemd/system/
scp systemd/v6plus-watch.service root@192.168.1.1:/etc/systemd/system/
```

Enable and start:

```sh
ssh root@192.168.1.1
systemctl daemon-reload
systemctl enable v6plus-static-ip.service
systemctl enable v6plus-watch.service
systemctl start v6plus-static-ip.service
systemctl start v6plus-watch.service
```

Check status:

```sh
systemctl status v6plus-static-ip.service
systemctl status v6plus-watch.service
journalctl -t v6plus-watch -f
```

---

## Watchdog

`v6plus-watch.sh` runs as a systemd service and handles three things:

1. **SNAT monitoring**: If UniFi wipes the SNAT rule after a config change (e.g., WiFi settings), it re-runs `apply` automatically.
2. **Routing cleanup**: Removes conflicting UniFi-generated policy routing rules (table 201 / ip6tnl1) that would override the custom tunnel.
3. **dpinger hijack**: Redirects UniFi's WAN health check process to use `v6plus0` instead of the DS-Lite tunnel interface, so Site Manager can see the gateway as online.

---

## Validation

```sh
# IPv4: confirm your egress IP is the static one (run from gateway)
curl -4 -s --interface <TUN_IF> https://api.ipify.org ; echo

# IPv4: confirm from LAN client
curl -4 -s https://api.ipify.org ; echo

# IPv6: confirm native IPv6 still works
curl -6 -s https://api6.ipify.org ; echo

# policy routing / routes
ip -4 rule
ip -4 route show table 300
ip -d link show v6plus0
```

---

## Known limitations

- **UniFi UI shows WAN IP as `192.0.0.2`** (DS-Lite CGNAT address). This is expected. Actual egress IP is your static IPv4. Verify with: `curl -4 -s --interface <TUN_IF> https://api.ipify.org`

- **Uptime / Internet Down in UI**: The watchdog hijacks `dpinger` to use `v6plus0`, which helps Site Manager recognize the connection. However the WAN IP shown in the UI will remain `192.0.0.2`.

- **No health-check / watchdog logic in the main script**: This is handled separately by `v6plus-watch.sh`.

---

## Common pitfalls

- Adding the provider-assigned tunnel-local IPv6 address as `/64` can break native IPv6 due to source-address selection changes.  
  This repo adds it as **/128** on WAN.

- Using `ip rule from 192.168.1.0/24 lookup 300` can inadvertently affect the gateway's own traffic and make the UI/SSH unstable.  
  This repo uses **`ip rule ... iif <LAN_IF>`** to target forwarded LAN traffic only.

- MSS/MTU values matter. If you see stalls or slow sites, try adjusting `TUN_MTU` and `MSS`.

- **Do not change MSS Clamping in the UniFi UI** — it can interfere with the custom iptables rules. Leave MSS management to the script via `v6plus.env`.

- **Do not set WAN to MAP-E / v6 Plus** — UniFi will create a competing `ip6tnl1` tunnel and add table 201 routing rules that conflict with `v6plus0`. Use DS-Lite instead.

---

## Acknowledgements

Thanks to **unifi-utilities/unifios-utilities** maintainers and contributors for the on-boot-script-2.x / udm-boot tooling, which informed the early design of this project.
- https://github.com/unifi-utilities/unifios-utilities

Also thanks to the community discussion that led to the discovery that systemd unit files must be placed as real files in `/etc/systemd/system/` (not symlinks) on UDR/UDM devices — this is what made on-boot-script unnecessary.

---

## License

MIT. See `LICENSE`.
