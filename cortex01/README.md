# cortex01 – Cortex (observable analysis)

Cortex runs **analyzers** on observables (IPs, domains, hashes …) for TheHive. Each analyzer runs as its own short-lived Docker container. Separate VM per the architecture plan (host `.13`).

- **Host:** `cortex01`, Ubuntu 24.04, 4 vCPU / 16 GB RAM / 100 GB disk, `192.168.50.13/24`, gateway `192.168.50.1`
- **Built:** 2026-10-14/15
- **Stack:** [StrangeBeeCorp/docker](https://github.com/StrangeBeeCorp/docker) profile **`prod1-cortex`**: Cortex **4.1.0**, Elasticsearch **8.19.23** (its own, not the SIEM's), nginx 1.31 (HTTPS, self-signed)
- **Path on host:** `~/cortex-docker/prod1-cortex/` (user `cortex`)

> Secrets (`.env`, `secret.conf`, certificates, API keys) stay on the host, not in this repo.

## Access

| What | URL |
|---|---|
| Cortex GUI (admin workstation) | `https://172.16.10.17:9443` (OPNsense forward WAN 9443 → 192.168.50.13:443) |
| TheHive → Cortex (internal) | `https://192.168.50.13` |
| SSH | `ssh -J elk@172.16.10.17:2210 cortex@192.168.50.13` (via elk01, no extra forward) |

## Build

```bash
# Host prep: same as hive01 (hostname, timezone, swap off, vm.max_map_count=262144, lvextend), then Docker CE from the official repo
git clone https://github.com/StrangeBeeCorp/docker.git cortex-docker && cd cortex-docker/prod1-cortex
# Lab memory limits (default 7 GB ES + 5 GB Cortex leaves nothing for analyzer containers on 16 GB):
#   elasticsearch -Xms4G -Xmx4G, limit 5G ; cortex -Xms3000M -Xmx3000M, limit 4G
# Socket fix (see gotcha 2): in the cortex service environment add
#   - daemon_user=<id -u>:<getent group docker GID>
bash ./scripts/init.sh          # server name 192.168.50.13
docker compose up -d && docker compose ps
curl -sk https://localhost/api/status | jq -r .versions.Cortex    # 4.1.0-1
```

## Configuration

| Item | Value |
|---|---|
| Superadmin | `admin` (platform only) |
| Organisation | `ProjectX` |
| Users | `admin@projectx.local` read/analyze/orgadmin (team lead); `svc-thehive@projectx.local` **read/analyze** (API key used by TheHive) |
| Analyzers enabled | `Abuse_Finder_3_0`, `DShield_lookup_1_0`, `Robtex_IP_Query_1_0` (no key); `AbuseIPDB_2_0`, `VirusTotal_GetReport_3_1` (free API keys, stored only in Cortex; VT rate limit 4/min); `MISP_2_1` (searches misp01, see [`../misp01/`](../misp01/README.md)) |
| TheHive connector | *Platform management → Connectors → Cortex*: server `cortex01`, URL `https://192.168.50.13`, svc-thehive key, CA check off (self-signed), all organisations |

Tested 2026-10-15: case observable `ip 103.16.182.23` → *Run analyzers* → reports and taxonomy tags back in TheHive.

**Public-IP only:** these analyzers query internet services, so private IPs (10.x, 192.168.x) return nothing. Expected, not an error.

## Automatic enrichment (Shuffle)

Every new alert is enriched without analyst action: the Shuffle step `auto_enrich` (source: [`../shuffle/auto-enrich.py`](../shuffle/auto-enrich.py), *Shuffle Tools → Execute python*, after *TheHive 1*) lists the alert's observables, lists the analyzers TheHive knows, and starts every matching analyzer **through TheHive** (`/api/connector/cortex/job`), so reports and taxonomy tags land on the alert. Non-global IPs (RFC1918 etc.) are skipped to save API quota.

Tested 2026-10-15 with `demo/simulate-attack.sh portscan 45.155.205.233`: alert → 5 analyzers ran automatically within ~4 min; VirusTotal `18/92` (red), AbuseIPDB usage "Data Center/Web Hosting".

## Build notes and gotchas

1. **Cortex took over the host's Docker socket.** The image entrypoint runs `chown cortex:cortex /var/run/docker.sock` on the **bind-mounted host socket**, with the container's default user `1001:1001`. After the first start, the host user got `permission denied` for every `docker` command (socket owned `1001 1001`). Fix: set `daemon_user=<host UID>:<docker GID>` in the cortex service environment, `sudo chown root:docker /var/run/docker.sock`, `docker compose up -d --force-recreate`. Log line to confirm: `Using user <UID> and group <docker GID>`.
2. **`systemctl restart docker` does not reset the socket.** The socket file belongs to `docker.socket`; fix ownership with `chown` (or restart `docker.socket`).
3. **StrangeBee `init.sh` runs `docker compose up`.** Its final message has `` `docker compose up` `` in double quotes, so bash executes it (command substitution). With Docker access it would start the stack in the foreground during init.
4. **Healthcheck shows `unhealthy`.** The compose healthcheck calls `/cortex/api/status`, but this profile serves Cortex at `/`. Check with `curl -sk https://localhost/api/status` instead.
5. **Typo trap in TheHive:** an observable saved as `103.16.182.23.` (trailing dot) is shown as `103[.]16[.]182[.]23[.]` and analyzers return nothing.
6. **First run of each analyzer is slow**: Cortex pulls the analyzer image (needs outbound internet via OPNsense).

## Operations

```bash
cd ~/cortex-docker/prod1-cortex && docker compose ps
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}"
docker logs cortex --tail 50
ls -l /var/run/docker.sock        # must stay group docker
```

## Next

- Hardening: trust Cortex's certificate in TheHive instead of disabling the CA check
