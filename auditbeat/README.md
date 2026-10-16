# Auditbeat – Linux host telemetry

Auditbeat 8.19.23 on every Linux lab server (elk01, hive01, cortex01, misp01) sends host events straight to Elasticsearch. It closes the firewall's blind spot: traffic between two lab servers never crosses OPNsense, but the target host records the logins, commands and account changes.

- **Config:** [`auditbeat.yml`](auditbeat.yml) → `/etc/auditbeat/auditbeat.yml` (same file on all hosts)
- **CI:** job *Auditbeat config* runs `auditbeat test config` with the real `docker.elastic.co/beats/auditbeat:8.19.23` image ([`../ci/test-auditbeat-config.sh`](../ci/test-auditbeat-config.sh))
- **Data:** data stream `auditbeat-8.19.23`, ILM `projectx-logs-90d` (90 days), 0 replicas
- **Built:** 2026-10-15/16. All 4 hosts reporting.

## What is collected

| Module | Events | Detection use |
|---|---|---|
| `auditd` | `execve` by real users only (auid ≥ 1000, so not daemons or containers) with full arguments; writes to passwd/group/shadow/sudoers | Recon tools, suspicious commands |
| `file_integrity` | `/etc/ssh`, `/etc/sudoers.d`, `/etc/cron.d`, `/etc/systemd/system`, `/root/.ssh` | Persistence (keys, cron, services) |
| `system` | logins incl. **failed** (btmp), user/group changes, packages, host info (polled every 1 min) | Brute force, new accounts |

## Accounts

| Account | Privileges | Where the secret lives |
|---|---|---|
| `auditbeat_writer` (ES) | cluster `monitor, read_ilm, read_pipeline`; `auditbeat-*`: `create_doc, view_index_metadata, auto_configure` | Auditbeat keystore `ES_PWD` on each host; master copy `/etc/projectx/auditbeat_writer.pwd` on elk01 (root 600) |
| `elastalert` (ES) | role extended to read `auditbeat-*` | – |

## Install (per host)

```bash
# Elastic apt repo (elk01 already has it)
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --dearmor -o /usr/share/keyrings/elastic.gpg
echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-8.x.list
sudo apt-get update && sudo apt-get install -y auditbeat=8.19.23
sudo install -m 600 -o root -g root auditbeat.yml /etc/auditbeat/auditbeat.yml
sudo install -m 644 http_ca.crt /etc/auditbeat/http_ca.crt          # ES HTTP CA from elk01
sudo auditbeat keystore create --force
tr -d '\r\n ' < pwd | sudo auditbeat keystore add ES_PWD --stdin --force   # never paste by hand (see gotcha 2)
systemctl is-active auditd && sudo systemctl disable --now auditd         # auditbeat needs the kernel audit socket
sudo auditbeat test output && sudo systemctl enable --now auditbeat
```

**One-time index setup** (from elk01, as `elastic`): `sudo auditbeat setup --index-management -E setup.template.enabled=true -E setup.ilm.check_exists=true -E output.elasticsearch.username=elastic -E output.elasticsearch.password=…`. The agents themselves have `setup.template.enabled: false` and `setup.ilm.check_exists: false`, because the writer account cannot manage templates.

## Detections on this data

See [`../elastalert/README.md`](../elastalert/README.md): `host-ssh-bruteforce` (T1110), `host-recon-tool` (T1046), `host-new-user` (T1136).

Tested 2026-10-16: 6 wrong-password SSH logins from elk01 to hive01 (same LAN, invisible to the firewall) → 13 failure events from hive01 → alert *Failed logins on hive01 from 192.168.50.10*.

## Build notes and gotchas

1. **CI container lacks the host's CA file and log dir.** The first `test config` failed only on `/etc/auditbeat/http_ca.crt` and `/var/log/auditbeat`; the test now mounts a throwaway CA and disables file logging.
2. **401 Unauthorized after pasting the password into the keystore prompt.** The paste carried extra characters. Copy the password file and pipe it with `tr -d '\r\n ' | auditbeat keystore add ES_PWD --stdin`.
3. **Failed logins arrive up to ~1 min late.** The `system/login` dataset polls btmp every minute, so the rule run right after an attack can miss it; the next run (15-min lookback) catches it.
4. **`auditd` service must not run** alongside the `auditd` module (both want the kernel audit socket). Ubuntu server doesn't install it by default.
5. **Only human commands are recorded** (`auid>=1000`). Container and daemon processes would flood the index on the Docker hosts.
