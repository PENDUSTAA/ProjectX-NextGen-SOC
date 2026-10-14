# ElastAlert2 on elk01 – detections → Shuffle → TheHive

Kibana's webhook connector needs a paid Elastic license, so detections run in **ElastAlert2** (open source). It queries Elasticsearch every minute and POSTs matches to the Shuffle webhook, which creates a TheHive alert.

- **Version:** ElastAlert2 **2.31.0** (needs Python ≥ 3.12; Ubuntu 24.04 ships 3.12)
- **Built:** 2026-10-14, first live detection (nmap from 172.16.20.53) reached TheHive about 1 minute after the scan

## Files

| Repo | Host | Notes |
|---|---|---|
| `config.yaml` | `/etc/elastalert/config.yaml` | No credentials |
| `rules/*.yaml` | `/etc/elastalert/rules/` | Webhook URL is the placeholder `__SHUFFLE_WEBHOOK_URL__`; the real URL is inserted on the host only |
| `elastalert.service` | `/etc/systemd/system/elastalert.service` | Runs as system user `elastalert` |
| – | `/etc/elastalert/elastalert.env` | `ES_USERNAME` / `ES_PASSWORD`, root:elastalert 640, **never in Git** |
| – | `/etc/elastalert/http_ca.crt` | Copy of the Elasticsearch HTTP CA |
| – | `/opt/elastalert2/` | Python venv |

Not deployed by CI yet: copy files manually (below). Adding a `deploy_elastalert` function is the next CI step (see [`cicd/ADDING-INTEGRATIONS.md`](../cicd/ADDING-INTEGRATIONS.md), Level 2).

## Rules

| Rule | Logic | TheHive alert |
|---|---|---|
| `opnsense-portscan` | Same `source.ip` hits **> 20 distinct `destination.port`** within 5 min (pass or block); re-alert per IP at most every 30 min | `Port scan detected from <ip>`, type `portscan`, ip observable (MITRE T1046) |

Every rule posts the payload contract from [`hive01/README.md`](../hive01/README.md): `title`, `description`, `type`, `ref` (unique), `src_ip`.

## Build

```bash
CA=/etc/elasticsearch/certs/http_ca.crt; ES=https://192.168.50.10:9200
# Elasticsearch role + user (read logs-*, own elastalert* indices only)
sudo curl -s --cacert $CA -u elastic -X POST "$ES/_security/role/elastalert" -H 'Content-Type: application/json' \
  -d '{"cluster":["monitor"],"indices":[{"names":["logs-*"],"privileges":["read","view_index_metadata"]},{"names":["elastalert*"],"privileges":["all"]}]}'
EA_PASS=$(openssl rand -hex 20)
sudo curl -s --cacert $CA -u elastic -X POST "$ES/_security/user/elastalert" -H 'Content-Type: application/json' \
  -d "{\"password\":\"$EA_PASS\",\"roles\":[\"elastalert\"]}"
# Single node: 0 replicas for ElastAlert's indices (they are not logs-*, so logs@custom doesn't apply)
sudo curl -s --cacert $CA -u elastic -X PUT "$ES/_index_template/elastalert" -H 'Content-Type: application/json' \
  -d '{"index_patterns":["elastalert*"],"priority":100,"template":{"settings":{"number_of_replicas":0}}}'

# Install
sudo apt -y install python3-venv
sudo useradd -r -s /usr/sbin/nologin -d /opt/elastalert2 elastalert
sudo python3 -m venv /opt/elastalert2 && sudo /opt/elastalert2/bin/pip install elastalert2==2.31.0

# Config (C = repo checkout)
sudo install -d -o root -g elastalert -m 750 /etc/elastalert /etc/elastalert/rules
sudo install -o root -g elastalert -m 640 $CA /etc/elastalert/http_ca.crt
sudo install -o root -g elastalert -m 644 $C/elastalert/config.yaml /etc/elastalert/config.yaml
printf 'ES_USERNAME=elastalert\nES_PASSWORD=%s\n' "$EA_PASS" | sudo tee /etc/elastalert/elastalert.env >/dev/null
sudo chown root:elastalert /etc/elastalert/elastalert.env && sudo chmod 640 /etc/elastalert/elastalert.env

# State indices
sudo -u elastalert bash -c 'cd / && set -a && . /etc/elastalert/elastalert.env && /opt/elastalert2/bin/elastalert-create-index --config /etc/elastalert/config.yaml'

# Rule + real webhook URL (host only)
sudo install -o root -g elastalert -m 640 $C/elastalert/rules/opnsense-portscan.yaml /etc/elastalert/rules/
sudo sed -i 's|__SHUFFLE_WEBHOOK_URL__|https://192.168.50.15:3443/api/v1/hooks/webhook_<id>|' /etc/elastalert/rules/opnsense-portscan.yaml

# Service
sudo install -m 644 $C/elastalert/elastalert.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now elastalert
```

## Test and operate

```bash
# Dry run a rule against the last 24 h (sends nothing)
sudo -u elastalert bash -c 'cd /tmp && set -a && . /etc/elastalert/elastalert.env && /opt/elastalert2/bin/elastalert-test-rule --config /etc/elastalert/config.yaml /etc/elastalert/rules/<rule>.yaml'
sudo journalctl -u elastalert -f | grep -E "Ran |alerts sent|ERROR"      # live
```

Live test for the port-scan rule, from the admin workstation: `nmap -Pn -sT --top-ports 100 172.16.10.17`, then check TheHive Alerts (as a Project-X user) after 1–2 minutes.

**Kibana's Alerts page stays empty**: it only shows Kibana's own rules. ElastAlert2's history is in its own indices; add data views `elastalert` (timestamp `alert_time`; one row per alert, `alert_sent`, `alert_exception`, `match_body`) and `elastalert_status` (timestamp `@timestamp`; one row per rule run).

## Build notes and gotchas

1. **Kibana webhook connector is not in the Basic license.** That's why ElastAlert2 is used.
2. **No run logs without `--verbose`.** The journal only showed "Started"; the rule had in fact already fired. `--verbose` logs every run (`Ran … N hits, N matches, N alerts sent`).
3. **Heredocs pasted as part of a big block can silently not run.** The env file was missing on the first try. Use `printf … | sudo tee`, and check files with `ls -l` afterwards.
4. **ElastAlert's indices default to 1 replica** (cluster turns yellow on a single node); the `elastalert` index template sets 0.
5. **Shuffle uses a self-signed certificate**, so the rule sets `http_post2_ignore_ssl_errors: true` (same as `curl -k`). Hardening item: trust Shuffle's cert instead.
6. **Count pass and block.** The admin workstation is allowed by the WAN rule for some ports, so its scan is partly logged as `pass`; filtering on `block` only would under-count.
