# hive01 – TheHive + Shuffle

Case management (TheHive) and security SOAR (Shuffle), co-hosted on one VM as in the PROJECT X architecture diagram (host `.15`).

- **Host:** `hive01`, Ubuntu 24.04, 8 vCPU / 24 GB RAM / 200 GB disk, `192.168.50.15/24`, gateway `192.168.50.1`
- **Built:** 2026-10-13/14
- **Runtime:** Docker Engine + Compose plugin, one Compose stack per product

> Secrets (`.env` files, generated passwords, certificates, API keys) stay on the host and are **not** in this repo.

## Layout on the host

| Path | What |
|---|---|
| `/opt/thehive-docker/prod1-thehive/` | TheHive stack ([StrangeBeeCorp/docker](https://github.com/StrangeBeeCorp/docker), profile `prod1-thehive`) |
| `/opt/shuffle/` | Shuffle stack ([Shuffle/Shuffle](https://github.com/Shuffle/Shuffle)) |
| `/opt/shuffle/shuffle-database/` | OpenSearch data for Shuffle, owned `1000:1000` |

## Services and ports

| Stack | Container | Image (at build) | Host port | Exposed via OPNsense |
|---|---|---|---|---|
| TheHive | nginx | nginx 1.31 | **443** (HTTPS, self-signed) | WAN **8443** → 443 |
| TheHive | thehive | strangebee/thehive **5.8.1** | 9000 (plain HTTP, bypasses nginx) | **no, never forward** |
| TheHive | elasticsearch | elasticsearch 8.19 | internal only | no |
| TheHive | cassandra | cassandra 4.1 | internal only | no |
| Shuffle | shuffle-frontend | shuffle-frontend:latest | 3001 (HTTP), **3443** (HTTPS) | WAN **3443** → 3443 |
| Shuffle | shuffle-backend | shuffle-backend:latest | 5001 (API) | no |
| Shuffle | shuffle-opensearch | opensearch 3.2 | 9200 (auth required) | **no** |
| Shuffle | shuffle-orborus | shuffle-orborus:latest | none (workflow runner) | no |
| Shuffle | shuffle-security | shuffle-security:latest | 3002 / 3444 | no |

Admin URLs (from 172.16.20.0/24): TheHive `https://172.16.10.17:8443`, Shuffle `https://172.16.10.17:3443`.

## Memory (24 GB host)

| Component | Limit / usage at build |
|---|---|
| TheHive app | 4 GB limit (~3 GB used) |
| TheHive Elasticsearch | 4 GB limit (~3.5 GB used) |
| Cassandra | 4 GB limit (~3.4 GB used) |
| Shuffle (all containers) | ~4–6 GB |
| Free for OS / page cache | ~6 GB |

## Build steps

### 1. Host prep

```bash
sudo hostnamectl set-hostname hive01
sudo timedatectl set-timezone Asia/Kuala_Lumpur
sudo swapoff -a && sudo sed -i '/ swap / s/^/#/' /etc/fstab
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf && sudo sysctl --system
# Ubuntu's installer only allocates ~half the disk to the root LV; claim the rest
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv && sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

### 2. Docker

Official Docker apt repo → `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`. TheHive needs Docker ≥ 23.0.15 and Compose ≥ 2.20.2.

### 3. TheHive

```bash
git clone https://github.com/StrangeBeeCorp/docker.git thehive-docker
cd thehive-docker/prod1-thehive
bash ./scripts/init.sh          # server name: 192.168.50.15, self-signed cert
docker compose up -d && docker compose ps
```

### 4. Shuffle

```bash
git clone https://github.com/Shuffle/Shuffle shuffle && cd shuffle
mkdir -p shuffle-database && sudo chown -R 1000:1000 shuffle-database
# BEFORE first start: set a strong OpenSearch admin password in .env
# (SHUFFLE_OPENSEARCH_PASSWORD and OPENSEARCH_INITIAL_ADMIN_PASSWORD, same value)
docker compose up -d && docker compose ps
```

Then open Shuffle immediately and create the admin account. The first visitor to `/adminsetup` becomes admin.

## TheHive configuration

| Item | Value |
|---|---|
| License | Platinum trial at install → **Community** license via StrangeBee portal, **activated 2026-10-14** (2 licensed users, 1 org, 1 Cortex, 1 MISP) |
| Organisation | `Project-X` |
| Users | `admin@projectx.local` Normal / org-admin (team lead); `analyst@projectx.local` Normal / analyst; `svc-shuffle@projectx.local` **Service** / analyst (API key for Shuffle) |

Service accounts and read-only users don't count toward the 2 licensed seats. Other team members are read-only until a paid tier.

## Integrations

| From → To | How |
|---|---|
| Shuffle → TheHive | ✅ **Working.** TheHive app in Shuffle, URL `https://192.168.50.15`, API key of `svc-shuffle`. Test workflow `Test - TheHive alert` creates alerts with observables |
| elk01 → Shuffle → TheHive | ✅ **Working, automatic (2026-10-14).** ElastAlert2 on elk01 ([`../elastalert/`](../elastalert/README.md)) → webhook trigger `elk-alerts` → TheHive 1 *Create alert*. First live detection: nmap port scan → TheHive alert in ~1 min |
| TheHive → Cortex (`.13`) | ✅ **Working (2026-10-15).** Connector `cortex01` → `https://192.168.50.13`, svc-thehive key; see [`../cortex01/`](../cortex01/README.md) |
| TheHive → MISP (`.12`) | Later (Community license allows one) |

Kibana's own webhook connector needs a paid Elastic license, so ElastAlert2 (open source) does the ELK → Shuffle step.

## ELK → Shuffle webhook

Workflow: **Webhook `elk-alerts` → TheHive 1 (Create alert, Advanced)**. Click the webhook node → **Start** (button then shows *Stop*) → copy the URI → **Save**.

- The URI the UI shows uses the address you browse from (`172.16.10.17`, via the port forward). From inside the LAN use **`https://192.168.50.15:3443/api/v1/hooks/webhook_<id>`**.
- The webhook ID works like a password: anyone who can reach 3443 can trigger the workflow. Keep it out of Git (ElastAlert2 will read it from a root-only file on elk01).

TheHive 1 body; `$exec` is the JSON posted to the webhook:

```json
{"title":"$exec.title","description":"$exec.description","type":"$exec.type","source":"elk","sourceRef":"$exec.ref","severity":2,"tlp":2,"pap":2,"flag":false,"tags":["elk","$exec.type"],"observables":[{"dataType":"ip","data":"$exec.src_ip","message":"Source IP"}]}
```

Payload contract (what the sender must post):

| Field | Example | Notes |
|---|---|---|
| `title` | `Port scan detected from 172.16.20.53` | |
| `description` | free text | |
| `type` | `portscan` | Also added as a tag |
| `ref` | `wh-1760414544` | Must be unique per alert (`type:source:sourceRef`); use the detection's ID so repeats de-duplicate |
| `src_ip` | `172.16.20.53` | Becomes an `ip` observable |

Test from elk01:

```bash
URL='https://192.168.50.15:3443/api/v1/hooks/webhook_<id>'
curl -sk -X POST "$URL" -H 'Content-Type: application/json' -d "{\"title\": \"Port scan detected from 172.16.20.53\", \"description\": \"Webhook test from elk01\", \"type\": \"portscan\", \"ref\": \"wh-$(date +%s)\", \"src_ip\": \"172.16.20.53\"}"
# expect {"success": true, "execution_id": "..."}; the run shows TheHive 1 status 201
```

`{"success": false, "reason": "Hook ID not valid"}` = wrong ID or webhook not started (but it proves the network path works).

## Build notes and gotchas

1. **OpenSearch rejected the admin password.** OpenSearch ≥ 2.12 requires upper + lower + digit + special character. A hex-only password (`openssl rand -hex`) crash-looped `shuffle-opensearch` with *"Password does not match validation regex"*. Fix: strong password in both `.env` variables, wipe `shuffle-database/` (empty at that point), `docker compose up -d`. Avoid `!` in shell-generated passwords (bash history expansion).
2. **Half the disk unused.** 200 GB VM disk, but `/` was 97 GB: Ubuntu's LVM default. Fixed online with `lvextend` + `resize2fs`. Check elk01 for the same.
3. **License limit on users.** Creating a third *Normal* user fails with `LicenseLimitExceeded: Capability(users.normal) (2/2)`. Integration accounts must be **Service** type, which is unlimited.
4. **Service vs Normal type.** Service users are API-only (no UI login). A human created as Service cannot log in; the type can't be changed, so delete and recreate.
5. **Least privilege for svc-shuffle.** `analyst` is enough to create alerts and cases; `org-admin` would also allow user and settings changes.
6. **Port 443 on the WAN is OPNsense's GUI**, so TheHive is published on WAN 8443. Port 9000 (TheHive direct, no TLS) and 9200 (OpenSearch) are never forwarded.
7. **Port forward "saved ≠ loaded"** (same as the OPNsense build). Confirm with `pfctl -sn | grep <port>` and `pfctl -sr | grep <port>`, then `configctl filter reload` if empty.
8. **init.sh run as root.** StrangeBee's guide says run as a normal user (TheHive runs as that user). It works; keep using the same user for `docker compose` in that folder.

## Shuffle → TheHive: working alert body

Use the TheHive app action **Create alert** in **Advanced** mode, and replace the whole `body` with real JSON:

```json
{
  "title": "Port scan detected from 172.16.20.53",
  "description": "Simulated detection: 25 distinct destination ports blocked on OPNsense WAN (em0) within 5 minutes.",
  "type": "opnsense-portscan",
  "source": "shuffle",
  "sourceRef": "scan-{{ 'now' | date: '%s' }}",
  "severity": 2, "tlp": 2, "pap": 2, "flag": false,
  "tags": ["opnsense", "portscan", "T1046"],
  "observables": [
    {"dataType": "ip", "data": "172.16.20.53", "message": "Scanning source", "tags": ["source"]},
    {"dataType": "ip", "data": "172.16.10.17", "message": "Target: OPNsense WAN", "tags": ["target"]}
  ]
}
```

- `type:source:sourceRef` must be unique per alert. Liquid (`{{ 'now' | date: '%s' }}`) works in the body and gives each test run a fresh ID. Real alerts should use the original detection's ID, which also de-duplicates.
- Numbers and booleans unquoted; `tags` is a list.
- View alerts as a **Project-X user** (e.g. the team lead account). `admin@thehive.local` is platform admin and cannot see organisation alerts or cases.

### Shuffle troubleshooting (what we hit)

| Symptom | Cause | Fix |
|---|---|---|
| Run stuck in EXECUTING on first use of an app | Orborus downloading the app image (~500 MB) | Wait; check `docker logs shuffle-orborus` |
| 401 `AuthenticationError` | Wrong key stored in Shuffle. Key was valid (`curl -H "Authorization: Bearer $KEY" https://192.168.50.15/api/v1/user/current` → 200) | Delete and re-add the app authentication |
| 400 `Invalid json`, `Unrecognized token '$'` or `'f'` | **Create alert** body is a template with `{placeholders}`; unfilled ones break the JSON | Advanced → replace the whole body |
| 400 `CreateError ... already exists` | Duplicate `type:source:sourceRef`; the earlier run *did* create the alert | Unique `sourceRef` |
| Editing in **App editor** | That screen edits the app definition (header names), not credentials | Credentials go in the node's *Authenticate* / Admin → App Authentication |

## Operations

```bash
cd /opt/thehive-docker/prod1-thehive && docker compose ps      # TheHive health
cd /opt/shuffle && docker compose ps                           # Shuffle health
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}"   # memory per container
docker logs <container> --tail 50                                    # troubleshoot
```
