# ELK – PROJECT X SIEM (single node)

Elasticsearch, Kibana and Logstash on one Ubuntu VM behind the OPNsense gateway. OPNsense firewall logs are parsed into ECS fields.

- **Version:** Elastic 8.19.x (native .deb packages, systemd)
- **Host:** `elk01`, Ubuntu 24.04, 4 vCPU / 16 GB RAM / 100 GB disk
- **Built:** 2026-10-12

> All IP addresses are placeholders. Passwords are never stored in this repo.

## Topology

```
OPNsense LAN 192.168.50.1 ──syslog UDP 5514──► elk01 192.168.50.10
                                                 ├─ Logstash   :5514/udp  (in)
                                                 ├─ Elasticsearch :9200   (TLS)
                                                 └─ Kibana     :5601
Admin network 172.16.20.0/24 ──► OPNsense WAN 172.16.10.17
                                   ├─ :2210 → elk01:22   (SSH)
                                   └─ :5601 → elk01:5601 (Kibana)
```

## Files

| Path on VM | Repo file | Notes |
|---|---|---|
| `/etc/elasticsearch/elasticsearch.yml` | [`elasticsearch/elasticsearch.yml`](elasticsearch/elasticsearch.yml) | Full file |
| `/etc/elasticsearch/jvm.options.d/heap.options` | [`elasticsearch/heap.options`](elasticsearch/heap.options) | 6 GB heap |
| `/etc/kibana/kibana.yml` | [`kibana/kibana.yml`](kibana/kibana.yml) | Lines **appended** to the default file |
| `/etc/logstash/conf.d/10-input-opnsense.conf` | [`logstash/conf.d/10-input-opnsense.conf`](logstash/conf.d/10-input-opnsense.conf) | UDP 5514 input, tags events `opnsense` |
| `/etc/logstash/conf.d/50-filter-opnsense.conf` | [`logstash/conf.d/50-filter-opnsense.conf`](logstash/conf.d/50-filter-opnsense.conf) | filterlog → ECS parser (tested in CI) |
| `/etc/logstash/conf.d/90-output-elasticsearch.conf` | [`logstash/conf.d/90-output-elasticsearch.conf`](logstash/conf.d/90-output-elasticsearch.conf) | Data stream output; password from keystore |
| *(CI only)* | [`logstash/tests/opnsense.log`](logstash/tests/opnsense.log) | Real sample lines the parser test runs |
| ILM policy `projectx-logs-90d` | [`elasticsearch/api/ilm/`](elasticsearch/api/ilm/) | Deployed via the Elasticsearch API |
| Component template `logs@custom` | [`elasticsearch/api/component_template/`](elasticsearch/api/component_template/) | Deployed via the Elasticsearch API |

The pipeline is split into input / filter / output so each new log source adds its own files, and CI can test a filter on its own. Every filter is wrapped in `if "<tag>" in [tags]`, so sources never touch each other's events.

## Memory budget (16 GB)

| Component | Heap |
|---|---|
| Elasticsearch | 6 GB |
| Logstash | 1 GB (default) |
| Kibana | ~1 GB (Node.js) |
| OS + Lucene page cache | the rest |

## Build steps

### 1. VM network

The netplan file is `/etc/netplan/*.yaml`. Set the address, the default route via the OPNsense LAN IP, and DNS.

```yaml
network:
  version: 2
  ethernets:
    ens160:
      addresses: ["192.168.50.10/24"]
      routes:
        - to: default
          via: 192.168.50.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
```

```bash
sudo netplan apply
sudo hostnamectl set-hostname elk01
sudo timedatectl set-timezone Asia/Kuala_Lumpur
sudo swapoff -a && sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

### 2. Elasticsearch

```bash
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-8.x.list
sudo apt update && sudo apt -y install elasticsearch
```

Copy in `elasticsearch.yml` and `heap.options`, then start the service and set the `elastic` password:

```bash
sudo chown root:elasticsearch /etc/elasticsearch/elasticsearch.yml && sudo chmod 660 /etc/elasticsearch/elasticsearch.yml
sudo systemctl daemon-reload && sudo systemctl enable --now elasticsearch
sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -i
sudo curl --cacert /etc/elasticsearch/certs/http_ca.crt -u elastic https://192.168.50.10:9200
```

### 3. Kibana

```bash
sudo apt -y install kibana
sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u kibana_system -i
sudo mkdir -p /etc/kibana/certs && sudo cp /etc/elasticsearch/certs/http_ca.crt /etc/kibana/certs/
sudo chown -R root:kibana /etc/kibana/certs && sudo chmod 640 /etc/kibana/certs/http_ca.crt
# append kibana/kibana.yml settings, then:
sudo /usr/share/kibana/bin/kibana-encryption-keys generate -q | sudo tee -a /etc/kibana/kibana.yml
sudo systemctl enable --now kibana
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.50.10:5601/api/status   # expect 200
```

Log in to Kibana as `elastic`, not as `kibana_system`.

### 4. Logstash

Create a least-privilege writer role and user:

```bash
CA=/etc/elasticsearch/certs/http_ca.crt; ES=https://192.168.50.10:9200
sudo curl -s --cacert $CA -u elastic -X POST "$ES/_security/role/logstash_writer" -H 'Content-Type: application/json' -d '{
  "cluster": ["monitor"],
  "indices": [{ "names": ["logs-opnsense-*"], "privileges": ["create_doc","auto_configure","create_index"] }]
}'
sudo curl -s --cacert $CA -u elastic -X POST "$ES/_security/user/logstash_writer" -H 'Content-Type: application/json' -d '{
  "password": "<LOGSTASH_WRITER_PASSWORD>", "roles": ["logstash_writer"]
}'
```

Install Logstash. Store the password in the Logstash keystore so it never sits in the pipeline file:

```bash
sudo apt -y install logstash
sudo mkdir -p /etc/logstash/certs && sudo cp /etc/elasticsearch/certs/http_ca.crt /etc/logstash/certs/
sudo chown -R root:logstash /etc/logstash/certs && sudo chmod 640 /etc/logstash/certs/http_ca.crt

sudo /usr/share/logstash/bin/logstash-keystore --path.settings /etc/logstash create
sudo /usr/share/logstash/bin/logstash-keystore --path.settings /etc/logstash add LOGSTASH_WRITER_PASSWORD
sudo chown root:logstash /etc/logstash/logstash.keystore && sudo chmod 640 /etc/logstash/logstash.keystore

# "Continue without password protection?" -> answer y (N cancels and no keystore is created)
# copy in logstash/conf.d/*.conf, then:
sudo -u logstash /usr/share/logstash/bin/logstash --path.settings /etc/logstash -t
sudo systemctl enable --now logstash
sudo ss -ulnp | grep 5514
```

### 5. OPNsense → Logstash

*System → Settings → Logging → Remote → +*

| Field | Value |
|---|---|
| Transport | UDP(4) |
| Applications | filter (pf), system, configd |
| Facilities | *(none = all)* |
| Hostname / Port | `192.168.50.10` / `5514` |
| rfc5424 | ✔ |

### 6. Verify

```bash
sudo tcpdump -ni ens160 udp port 5514 -c 5
sudo curl -s --cacert /etc/elasticsearch/certs/http_ca.crt -u elastic "https://192.168.50.10:9200/logs-opnsense-default/_count?pretty"
```

In Kibana, create a data view named `OPNsense` with the pattern `logs-opnsense-*`, then open Discover.

## Parsed fields (ECS)

| Field | From |
|---|---|
| `@timestamp` | syslog timestamp |
| `host.hostname`, `process.name` | syslog header |
| `rule.id`, `rule.uuid` | pf rule number and label |
| `observer.ingress.interface.name` | em0 / em1 |
| `event.action` | pass / block |
| `event.reason` | match |
| `network.transport`, `network.bytes` | tcp / udp / icmp, packet length |
| `source.ip`, `source.port` | |
| `destination.ip`, `destination.port` | |
| `opnsense.dir`, `opnsense.tcp_flags` | in/out, S/SA/R… |

Data stream: `logs-opnsense-default`.

## Retention and index settings

| Object | Effect |
|---|---|
| ILM `projectx-logs-90d` | Roll over weekly or at 50 GB per shard; **delete 90 days after rollover** (data kept 90–97 days) |
| Component template `logs@custom` | Applies that policy to **every** `logs-*-*` data stream, and sets `number_of_replicas: 0` |

`logs@custom` is the hook Elastic's built-in `logs` template leaves for overrides, so no built-in template is copied or modified. Replicas are 0 because a single node can never place a replica copy, which otherwise keeps cluster health **yellow**.

Templates only affect new backing indices. Indices that already exist were updated once:

```bash
curl --cacert $CA -u elastic -X PUT "$ES/logs-*/_settings" -H 'Content-Type: application/json' \
  -d '{"index":{"lifecycle":{"name":"projectx-logs-90d"},"number_of_replicas":0}}'
```

Result: cluster health **green**, and `logs-opnsense-default` is managed by `projectx-logs-90d`.

## Build notes and gotchas

1. **Wrong default gateway.** Netplan had `via: 192.168.50.254` (nothing at that address), so every off-subnet ping gave "Destination Host Unreachable" from the VM itself. The gateway is the OPNsense LAN IP.
2. **elasticsearch.yml wiped in nano.** Only four lines remained, so `path.logs` was missing and the service exited with code 78 ("Unable to create logs dir"). The auto-generated security block was gone too. Rebuilt the full file; the certs in `/etc/elasticsearch/certs` survived. Back up the file before editing (`cp elasticsearch.yml elasticsearch.yml.bak`).
3. **`discovery.type: single-node`** replaces `cluster.initial_master_nodes`. This avoids a mismatch when `node.name` differs from the install-time hostname.
4. **Logstash 401 restart loop.** The `logstash_writer` password in the pipeline didn't match Elasticsearch, so the pipeline died before opening UDP 5514. Symptom: tcpdump shows packets arriving, but `ss -ulnp | grep 5514` is empty. Fix: reset the password with `_security/user/logstash_writer/_password`, test it with `curl -u`, and use the keystore.
5. **Stray `column25/27/29` fields.** TCP filterlog lines have 29 CSV fields. Name all 29 in the `csv` filter, or Logstash auto-names the extras.
6. **Logstash cannot bind ports below 1024** as the `logstash` user. OPNsense sends to 5514 directly, so no rsyslog relay is needed.
7. **Only logged rules reach the SIEM.** Enable *Log packets* on the OPNsense rules you care about.
8. **Duplicate `syslog_msg` on every event.** Found by the CI parser test on its first real run: the raw CSV was stored twice per event. The filter now removes it.
9. **Keystore never created.** `logstash-keystore create` asks *"Continue without password protection?"*; answering N cancels silently. Answer **y**.
10. **Keystore keys are stored lowercase.** `add LOGSTASH_WRITER_PASSWORD` is stored as `logstash_writer_password`. Logstash resolves `${...}` case-insensitively, so the pipeline works, but any script checking for the key must compare case-insensitively.

## Next

- [x] Custom ILM retention (90 days) and single-node replica fix
- [x] Configs in a private infra repo with CI validation and automated deploy (see [`../cicd/`](../cicd/README.md))
- [ ] Detection rules in Kibana Security on `logs-opnsense-*`
- [ ] IPv6 filterlog layout
