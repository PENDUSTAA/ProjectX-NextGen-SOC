# misp01 – MISP (threat intelligence)

MISP stores threat-intel feeds and IOCs. Cortex's **MISP analyzer** searches it for every alert observable, so a TheHive alert shows whether the attacker is a known Tor exit, botnet C2, scanner, etc.

- **Host:** `misp01`, Ubuntu 24.04, 4 vCPU / 8 GB RAM / 100 GB disk, `192.168.50.12/24`, gateway `192.168.50.1`
- **Built:** 2026-10-15
- **Stack:** official [MISP/misp-docker](https://github.com/MISP/misp-docker): MISP **2.5.50** (misp-core, misp-nginx, misp-modules), MariaDB 10.11, Valkey 7.2, mail relay
- **Path on host:** `~/misp-docker/` (user `misp`)

> Secrets (`.env`, admin password file, API keys, TLS key) stay on the host, not in this repo.

## Access

| What | URL |
|---|---|
| MISP GUI (admin workstation) | `https://172.16.10.17:7443` (OPNsense forward WAN 7443 → 192.168.50.12:443) |
| Cortex → MISP (internal) | `https://192.168.50.12` |
| SSH | `ssh -J elk@172.16.10.17:2210 misp@192.168.50.12` |

## Build

```bash
# Host prep: hostname, timezone, lvextend; Docker CE (official repo, NOT the Ubuntu installer's snap)
git clone https://github.com/MISP/misp-docker.git && cd misp-docker
cp template.env .env && chmod 600 .env
# .env: BASE_URL=https://172.16.10.17:7443 (the URL the browser uses), ADMIN_EMAIL=admin@projectx.local,
#       ADMIN_ORG=ProjectX, ADMIN_PASSWORD, ENCRYPTION_KEY, MYSQL_PASSWORD, MYSQL_ROOT_PASSWORD,
#       REDIS_PASSWORD (all generated with openssl rand), DISABLE_PRINTING_PLAINTEXT_CREDENTIALS=true
# TLS: create ssl/ BEFORE the first "up" (see gotcha 2)
mkdir -p ssl && openssl req -x509 -nodes -newkey rsa:4096 -days 825 -keyout ssl/key.pem -out ssl/cert.pem \
  -subj "/CN=misp01" -addext "subjectAltName = DNS:misp01, IP:192.168.50.12, IP:172.16.10.17, IP:127.0.0.1"
chmod 644 ssl/*.pem
docker compose pull && docker compose up -d
docker compose logs -f misp-core        # wait for "MISP is now live", then: docker compose up -d
curl -sk https://localhost/users/login | grep -o "<title>[^<]*"     # Users - MISP
```

## Configuration

| Item | Value |
|---|---|
| Organisation | `ProjectX` |
| Users | `admin@projectx.local` (site admin); `svc-integrations@projectx.local` role **Read Only** + auth key (used by Cortex) |
| Read Only role | *Auth key access* on; **Limit restSearch Results off** (it was on with limit 0: every API search would return nothing) |
| Feeds (MISP format) | CIRCL OSINT Feed, The Botvrij.eu Data |
| Feeds (freetext, Fixed Event + Delta merge, org only) | Tor exit nodes (`check.torproject.org/torbulkexitlist`, tag `tor-exit`), blocklist.de all (tag `blocklist`), abuse.ch Feodo C2 (tag `botnet-c2`) |
| Cortex analyzer | `MISP_2_1`: url `https://192.168.50.12`, svc-integrations key, name `ProjectX MISP`, **cert_check False** |

Tested 2026-10-15: `demo/simulate-attack.sh portscan 185.220.101.179` → TheHive alert → auto-enrichment → MISP report *"899 – Tor exit nodes feed"* plus correlated CIRCL OSINT events.

## Build notes and gotchas

1. **misp-core shows `unhealthy` on the first start.** Its healthcheck allows 60 s, but the first boot loads the schema and runs all updates (several minutes); `misp-nginx` (which depends on it) is created but not started. Wait for `MISP is now live` in the logs, then `docker compose up -d` again.
2. **misp-nginx restart loop: "BASE_URL starts with https://, but SSL certificate is NOT present".** Since the nginx split, MISP Docker no longer generates a certificate; it expects `ssl/cert.pem` + `ssl/key.pem`. If `ssl/` doesn't exist at the first `up`, Docker creates it **owned by root**, and `openssl` as the normal user silently fails to write into it. Fix: `sudo chown $USER ssl`, generate, recreate misp-nginx.
3. **"Load default feed metadata" only adds two feeds** in this version (CIRCL, Botvrij). IP blocklists are added by hand as *Freetext Parsed Feed*.
4. **Auth-key user dropdown only listed admin** from the global *Add authentication key* page; add the key from the user's own page (*List Users → eye icon → Auth keys*) instead.
5. **Cortex MISP analyzer `CERTIFICATE_VERIFY_FAILED`.** `cert_check` is a boolean that **defaults to True**; set it to False for the self-signed cert (hardening: use `cert_path` with the MISP cert instead).
6. **Long list of `WARN … variable is not set`** from compose is normal (optional LDAP/OIDC/S3/etc. settings).

## Operations

```bash
cd ~/misp-docker && docker compose ps
docker compose logs --tail 50 misp-core
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}"
```
Feeds refresh: *Sync Actions → Feeds → Fetch and store all feed data* (schedule it under *Administration → Scheduled Tasks* → `fetch_feeds`, e.g. daily).

## Next

- Schedule daily feed fetch
- TheHive → MISP export of confirmed cases (needs a separate write-capable account)
- Hardening: real CA / pinned cert for Cortex, tighten `ssl/key.pem` permissions
