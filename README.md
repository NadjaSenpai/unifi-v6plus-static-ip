# unifi-v6plus-static-ip

Scripts for **UniFi OS gateways (UDM / UDR)** to run a **v6plus static IPv4 (/32)** service delivered as an **IPv4-over-IPv6 (IPIP6) tunnel** (static IPv4 + BR IPv6 + provider-assigned IID), while keeping **native IPv6** working as-is.

This targets ISPs that provide something like:
- Static IPv4: `x.x.x.x/32`
- IPv6 prefix: `xxxx:....::/64`
- BR IPv6 address: `xxxx:....::xx`
- Provider-assigned Interface ID (IID): `....`

…and whose sample configs (e.g., Yamaha RTX) include `tunnel encapsulation ipip`.

> ⚠️ Disclaimer  
> Use at your own risk. UniFi OS upgrades may change behaviors.  
> Never commit ISP update URLs / credentials. Keep secrets out of Git.  
> The addresses in `config/v6plus.env.example` are **documentation examples** — replace them with ISP-assigned values.

## Repository layout

~~~text
unifi-v6plus-static-ip/
  README.md
  LICENSE
  .gitignore
  scripts/
    v6plus-static-ip-iif.sh
    on_boot/
      99-v6plus-static-ip.sh
  config/
    v6plus.env.example
~~~

## Quick start (manual)

1) Copy the example env file to your gateway and edit values:

~~~sh
cp config/v6plus.env.example /data/v6plus.env
vi /data/v6plus.env
~~~

2) Copy the script and run:

~~~sh
cp scripts/v6plus-static-ip-iif.sh /data/v6plus-static-ip-iif.sh
chmod +x /data/v6plus-static-ip-iif.sh

ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh apply
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh status
~~~

Rollback:

~~~sh
ENV_FILE=/data/v6plus.env /data/v6plus-static-ip-iif.sh off
~~~

## Persistence (udm-boot / on-boot-script-2.x)

A common approach on UniFi OS is to use **on-boot-script-2.x** (udm-boot) so scripts placed in `/data/on_boot.d/` are executed on boot.

Copy the wrapper:

~~~sh
mkdir -p /data/on_boot.d
cp scripts/on_boot/99-v6plus-static-ip.sh /data/on_boot.d/99-v6plus-static-ip.sh
chmod +x /data/on_boot.d/99-v6plus-static-ip.sh
~~~

The wrapper waits until WAN has a global IPv6 address and then runs:
- `BASE=/data/v6plus-static-ip-iif.sh`
- `ENV_FILE=/data/v6plus.env`

## Validation

~~~sh
# IPv4: check your egress IP is the static one
curl -4 -s https://api.ipify.org ; echo

# IPv6: make sure native IPv6 is still alive
curl -6 -s https://api6.ipify.org ; echo

# policy routing / routes
ip -4 rule
ip -4 route show table 300
ip -d link show v6plus0
~~~

## Common pitfalls

- Adding the provider-assigned IID IPv6 address to WAN as `/64` can break native IPv6 due to source-address selection changes.  
  This repo adds it as **/128** on WAN.
- Using `ip rule from 192.168.1.0/24 lookup 300` can inadvertently affect the gateway’s own management traffic and make the UI/SSH unstable.  
  This repo uses **`ip rule ... iif br0`** (ingress-interface based) to target forwarded LAN traffic only.
- fwmark-based policy routing may conflict with UniFi’s internal mangle/connmark rules; this repo avoids fwmark.

## License

MIT. See `LICENSE`.
