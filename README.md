# unifi-v6plus-static-ip

Scripts for **UniFi OS gateways (UDM / UDR)** to run a **v6plus static IPv4 (/32)** service delivered via an **IPv4-over-IPv6 (IPIP6) tunnel**, while keeping **native IPv6** working as-is.

This targets ISPs that provide something like:

- **Static IPv4 address**: `x.x.x.x/32`
- **IPv6 prefix**: `xxxx:....::/64`
- **BR (Border Relay) IPv6 address**: `xxxx:....::xx`
- **Provider-assigned IPv6 address for the tunnel local endpoint**
  (i.e., the prefix plus a fixed “host part”, sometimes called an **Interface Identifier / IID**)

…and whose sample configs (e.g., Yamaha RTX) include `tunnel encapsulation ipip`.

> ⚠️ Disclaimer  
> Use at your own risk. UniFi OS / Network upgrades may change interface names, firewall chains, or behaviors.

> 🔐 Security note  
> Never commit ISP update URLs / credentials. Keep secrets out of Git.  
> The addresses in `config/v6plus.env.example` are documentation examples — replace them with ISP-assigned values.

---

## What this does

- Creates an **ipip6 tunnel** (IPv4-in-IPv6) toward your ISP BR.
- Assigns your **static IPv4 /32** to the tunnel interface.
- Routes **forwarded IPv4 traffic from LAN** into a dedicated routing table using **`ip rule ... iif <LAN_IF>`** (so the gateway’s own traffic is less likely to get impacted).
- Adds the provider-assigned tunnel-local IPv6 to WAN as **/128** (not /64) to avoid messing with native IPv6 source address selection.
- Adds SNAT for LAN -> tunnel using your static IPv4.
- Adds TCP MSS clamp for stability.

> Note: There is **no health-check / watchdog logic** in this repo.

---

## Prerequisites (UniFi Network UI)

Before running the script, configure UniFi Network so that:

1) your WAN is set to **IPv4 over IPv6 (MAP-E / v6 Plus)**, and  
2) the WAN uses **DHCPv6** (so the gateway can receive IPv6 + Prefix Delegation), and  
3) your LAN uses **Prefix Delegation** from that WAN.

### 1) Internet (WAN): IPv4 over IPv6 (MAP-E / v6 Plus) + IPv6 DHCPv6

Open:

- `UniFi Network` → `Settings` → `Internet`  
  URL: `https://192.168.1.1/network/default/settings/internet`

Edit the WAN you use for this service (e.g. `Internet 2` / `WAN2`) and set:

**IPv4 Configuration**
- **Connection**: `IPv4 over IPv6`
- **Type**: `MAP-E`
- **Service**: `v6 Plus`

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
- **Prefix Delegation Interface**: select the WAN from step 1 (e.g., `Internet 2`)

Apply/Save.

---

## Repository layout

```text
unifi-v6plus-static-ip/
  README.md
  LICENSE
  scripts/
    v6plus-static-ip-iif.sh
    on_boot/
      99-v6plus-static-ip.sh
  config/
    v6plus.env.example
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
# copy the script
scp scripts/v6plus-static-ip-iif.sh root@192.168.1.1:/data/v6plus-static-ip-iif.sh

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

### 3) Make the script executable

```sh
chmod +x /data/v6plus-static-ip-iif.sh
```

### 4) Apply

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh apply
```

### 5) Check status

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh status
```

### 6) Rollback / disable

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh off
```

---

## Persistence (keep settings after reboot)

UniFi OS does **not** automatically run user scripts from `/data/on_boot.d` by default.
Changes made by this script (tunnel / ip rule / iptables) will be lost after reboot unless
you install an **on-boot runner** (community tooling) or re-apply manually.

### Option A: Install on-boot-script-2.x (recommended)

Install **on-boot-script-2.x** from `unifi-utilities/unifios-utilities`, which sets up `udm-boot`
and executes scripts placed under `/data/on_boot.d/`.

> Security note: this uses `curl | sh`. Review the script if you prefer.

#### One-liner install (requires outbound Internet from the gateway)

```sh
curl -fsL "https://raw.githubusercontent.com/unifi-utilities/unifios-utilities/HEAD/on-boot-script-2.x/remote_install.sh" | /bin/sh
```

#### Safer (download, review, then run)

The one-liner (`curl | sh`) is convenient, but it executes whatever is downloaded **immediately**.
If you prefer to **review the script before running it**, download it first, inspect it, then execute it:

```sh
curl -fsLo /tmp/remote_install.sh "https://raw.githubusercontent.com/unifi-utilities/unifios-utilities/HEAD/on-boot-script-2.x/remote_install.sh"

# review the script contents before running (recommended)
less /tmp/remote_install.sh

# run it only after you are comfortable with what it does
sh /tmp/remote_install.sh
```

> Tip: If `less` is not available on your device, you can use:
>
> ```sh
> sed -n '1,200p' /tmp/remote_install.sh
> ```

#### Install the wrapper script

Once the on-boot runner is installed, place your boot script in `/data/on_boot.d/`:

```sh
mkdir -p /data/on_boot.d

# ensure the main script + env exist in /data (persistent)
ls -la /data/v6plus-static-ip-iif.sh
ls -la /data/v6plus.env

# install the wrapper
cp /path/to/repo/scripts/on_boot/99-v6plus-static-ip.sh /data/on_boot.d/99-v6plus-static-ip.sh
chmod +x /data/on_boot.d/99-v6plus-static-ip.sh
```

> Note: The wrapper script expects:
> - `/data/v6plus-static-ip-iif.sh`
> - `/data/v6plus.env`

Reboot and verify:

```sh
ip -d link show v6plus0
ip -4 rule
iptables -t nat -L -n -v | sed -n '1,80p'
```

### Option B: Manual re-apply after reboot

If you do not install an on-boot runner, re-run after each reboot:

```sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh apply
```

---

## Validation

```sh
# IPv4: confirm your egress IP is the static one
curl -4 -s https://api.ipify.org ; echo

# IPv6: confirm native IPv6 still works
curl -6 -s https://api6.ipify.org ; echo

# policy routing / routes
ip -4 rule
ip -4 route show table 300
ip -d link show v6plus0
```

---

## Common pitfalls

- Adding the provider-assigned tunnel-local IPv6 address as `/64` can break native IPv6 due to source-address selection changes.  
  This repo adds it as **/128** on WAN.

- Using `ip rule from 192.168.1.0/24 lookup 300` can inadvertently affect the gateway’s own traffic and make the UI/SSH unstable.  
  This repo uses **`ip rule ... iif <LAN_IF>`** to target forwarded LAN traffic only.

- MSS/MTU values matter. If you see stalls or slow sites, try adjusting `TUN_MTU` and `MSS`.

---

## Acknowledgements

Thanks to **unifi-utilities/unifios-utilities** (on-boot-script-2.x / udm-boot) maintainers and contributors.
- https://github.com/unifi-utilities/unifios-utilities

## License

MIT. See `LICENSE`.
