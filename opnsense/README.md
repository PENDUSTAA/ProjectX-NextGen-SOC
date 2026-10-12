# OPNsense – PROJECT X Gateway

Internal gateway for the PROJECT X lab, running as a VM on ESXi.

- **Version:** OPNsense 25.7 (amd64)
- **Hostname:** OPNsense.internal
- **Built:** 2026-10-11

> All IP addresses and network names in this repo are placeholders. Substitute your own values when deploying.

## Topology

```
ISP → FortiGate (172.16.10.254) → ESXi lab segment 172.16.10.0/24
                                   └─ OPNsense WAN em0 172.16.10.17
                                      OPNsense LAN em1 192.168.50.1
                                        └─ PROJECT X VMs 192.168.50.0/24
Admin workstation: 172.16.20.0/24 (admin network), routed via FortiGate
```

## ESXi VM

| Item | Value |
|---|---|
| vCPU / RAM / Disk | 4 / 8 GB / 16 GB |
| Network adapter 1 → em0 | `PG-Lab-Uplink` (shared lab segment) |
| Network adapter 2 → em1 | `PG-ProjectX-Internal` |

## Interfaces

| Role | NIC | Address | Gateway | Notes |
|---|---|---|---|---|
| WAN | em0 | 172.16.10.17/24 (static) | 172.16.10.254 | No DHCP on this segment |
| LAN | em1 | 192.168.50.1/24 | – | DHCP server enabled |

**WAN settings:** Block private networks and Block bogon networks are both **unticked**. The WAN sits on RFC1918 space, so leaving them on blocks everything.

## IP plan – 192.168.50.0/24

| Range | Use |
|---|---|
| 192.168.50.1 | OPNsense LAN gateway |
| 192.168.50.2 – .99 | Static servers (ELK, TheHive, MISP, OpenCTI, Shuffle, etc.) |
| 192.168.50.100 – .200 | DHCP pool |

## DNS

Set under *System → Settings → General*: `8.8.8.8`, `1.1.1.1`.

## Firewall rules

### WAN

| # | Action | Proto | Source | Destination | Port | Log | Description |
|---|---|---|---|---|---|---|---|
| 1 | Pass | any | 172.16.20.0/24 | WAN address | any | yes | Allow GUI from admin workstation |

Everything else inbound on WAN hits the default deny.

**To do:** tighten rule 1 to TCP 443 and 22 only.

### LAN

Default rules: allow LAN to any. Outbound NAT is on Automatic.

### Port forwards (Firewall → NAT → Port Forward)

Temporary admin access to lab VMs, used until the FortiGate route and policy are in place. Each forward has an associated filter rule.

| WAN port | Source | Redirect to | Purpose |
|---|---|---|---|
| 2210/tcp | 172.16.20.0/24 | 192.168.50.10:22 | SSH to elk01 |
| 5601/tcp | 172.16.20.0/24 | 192.168.50.10:5601 | Kibana |

Destination port must never be *any*. That would redirect 443 too and lock you out of the OPNsense GUI. In the Source field, the mask goes in the separate dropdown: type `172.16.20.0` and select `24`, not `172.16.20.0/24`.

## Remote logging

*System → Settings → Logging → Remote*: filter (pf), system and configd are sent via UDP to `192.168.50.10:5514` (Logstash on elk01) in RFC5424 format. Facilities are left empty (all). See [`../elk/`](../elk/README.md).

## Admin access

- GUI: `https://172.16.10.17` (from the admin network) or `https://192.168.50.1` (from the lab LAN)
- SSH: `172.16.10.17:22`
- elk01 SSH: `ssh -p 2210 <user>@172.16.10.17`
- Kibana: `http://172.16.10.17:5601`

## Verification commands

```sh
pfctl -s info | head -1                     # filter enabled?
pfctl -sr | grep <unique text>              # is a rule actually loaded?
grep <unique text> /tmp/rules.debug         # is a rule generated?
configctl filter reload                     # regenerate + load ruleset
tail -f /var/log/filter/latest.log          # live firewall log
tcpdump -n -e -ttt -i pflog0                # decoded live hits
df -h /                                     # installed to disk (not iso9660/md)?
```

## Build notes and gotchas

1. **Live mode vs install.** Booting the ISO starts live mode. Log in as `installer` / `opnsense` to install to disk, then detach the ISO in ESXi.
2. **NIC roles were swapped at first.** em0 defaulted to LAN, which put 192.168.1.1 plus DHCP on the shared 172.16.10.x segment. Re-assigned with console option 1 (em0 = WAN, em1 = LAN). Check the mapping by MAC (`ifconfig em0 | grep ether`) against ESXi.
3. **DNS failed after the initial setup.** Temporary fix: `echo "nameserver 8.8.8.8" > /etc/resolv.conf`. Permanent fix: set DNS in System → Settings → General.
4. **GUI from WAN.** `pfctl -d` disables the filter temporarily for first access. Run it from the shell (option 8), not at the menu prompt. Any filter reload turns it back on.
5. **A saved rule is not a loaded rule.** The WAN rule was in `/conf/config.xml`, but traffic still hit default deny (label `02f4bab0…`). Apply had not regenerated `/tmp/rules.debug`. `configctl filter reload` fixed it. Always confirm with `pfctl -sr | grep`.
6. **Leftover RST blocks after a reload.** After a reload the state table is empty, so RST/ACK packets from old sessions hit default deny. The rule only creates state on SYN (`flags S/SA`). This is harmless.
7. **Source must be an IP, not a MAC.** Traffic from 172.16.20.x is routed through FortiGate, so source MACs are rewritten. Use IP or network aliases for WAN rules.

## Not in this repo

The raw `config.xml` is not committed. It contains the root password hash, SSH host keys and certificates. Take backups from *System → Configuration → Backups* and store them somewhere private.
