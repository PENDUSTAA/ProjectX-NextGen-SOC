# Adding a new integration

Every integration follows the same four steps:

1. **Config in the repo**: files live in a folder named after the service.
2. **A check in CI**: something that fails *before* deploy if the config is broken.
3. **A deploy step**: how the config gets onto the server safely.
4. **Secrets stay out**: passwords live on the server (keystore or env file), never in Git.

There are two levels. Pick the one that fits.

| You are adding… | Level | Deploy script change? |
|---|---|---|
| A new **detection rule** (ElastAlert2 → Shuffle → TheHive) | **0** | No |
| A new **log source** into the existing Logstash (FortiGate, Windows, Palo Alto, Sophos…) | **1** | No |
| A new **service** (TheHive, MISP, Shuffle, Wazuh…) or new settings for ES/Kibana | **2** | Yes |

---

## The daily workflow (same for every change)

**GitHub web:**
1. Open the file → ✏️ **Edit** → make the change.
2. **Commit changes…** → choose **Create a new branch** → **Propose changes** → **Create pull request**.
3. Wait for the checks on the PR (~3 min). Red = read the failing job, fix on the same branch.
4. Green → **Merge pull request**. The deploy runs on elk01 (once `DEPLOY_ENABLED=true`).

**GitHub Desktop:** Current branch → **New branch** → edit files locally → **Commit** → **Publish branch** → **Create Pull Request** → same as steps 3–4.

Never commit straight to `main` for real changes. The PR is where CI checks your work before it can reach elk01.

---

## Level 0: New detection rule (ElastAlert2)

One YAML file in `elastalert/rules/`. CI checks it; the deploy copies it to elk01, inserts the real Shuffle webhook URL, restarts ElastAlert2 and rolls back if it doesn't come up healthy. Deleting the file removes the rule from elk01.

1. Copy `elastalert/rules/opnsense-portscan.yaml` to `elastalert/rules/<rule-name>.yaml`.
2. Set `name:` to exactly `<rule-name>` (CI checks this).
3. Change the detection part: `type`, `filter`, thresholds. Rule types: [ElastAlert2 docs](https://elastalert2.readthedocs.io/en/latest/ruletypes.html). Field names are the ECS names you see in Kibana Discover (`source.ip`, `destination.port`, `event.action`…).
4. Keep `alert: [post2]` and `http_post2_url: "__SHUFFLE_WEBHOOK_URL__"` exactly as they are. **Never paste the real webhook URL**; CI fails if you do.
5. Fill `http_post2_payload` with the five fields Shuffle expects: `title`, `description`, `type` (short, e.g. `bruteforce`), `ref` (unique per alert, include `{{ source.ip }}` and `{{ _data['@timestamp'] }}`), `src_ip`.
6. If your rule uses fields that aren't in `elastalert/tests/sample-event.json`, add them there, or CI reports the payload renders empty.
7. PR → CI → merge → deploy (daily workflow above).
8. Test it for real and check TheHive Alerts.

Before the PR, you can dry-run a rule against real data on elk01 (sends nothing):
```bash
sudo -u elastalert bash -c 'cd /tmp && set -a && . /etc/elastalert/elastalert.env && /opt/elastalert2/bin/elastalert-test-rule --config /etc/elastalert/config.yaml /path/to/<rule-name>.yaml'
```
(The webhook placeholder is fine for a dry run.)

| CI message | Fix |
|---|---|
| `unknown rule type` | Typo in `type:` (the message lists valid types) |
| `<option>: … is not of type …` | Wrong value type, e.g. a number in quotes |
| `rule does not match the ElastAlert2 schema` | Misspelled option name, e.g. `minutez`; compare with the docs |
| `must be the placeholder` / `contains a real Shuffle webhook URL` | Put `__SHUFFLE_WEBHOOK_URL__` back |
| `payload fields render empty` | Field name in `{{ … }}` doesn't exist in the sample event (or in your data) |

---

## Level 1: New log source into Logstash (example: FortiGate)

No new server pieces. You add three files and a few test lines.

### 1. Pick a port and tag

| Source | Port | Tag |
|---|---|---|
| OPNsense | 5514/udp | `opnsense` (exists) |
| FortiGate | 5515/udp | `fortigate` |
| *next…* | 5516/udp | … |

Write the port down in this table when you add one. Two sources on one port is the most common mistake.

### 2. Input: `elk/logstash/conf.d/11-input-fortigate.conf`

```
input {
  udp { port => 5515 tags => ["fortigate"] }
}
```

### 3. Filter: `elk/logstash/conf.d/51-filter-fortigate.conf`

Always wrap the filter in the tag check, so it never touches other sources' events:

```
filter {
  if "fortigate" in [tags] {
    kv {
      source      => "message"
      value_split => "="
      field_split => " "
      target      => "fgt"
    }
    mutate {
      rename  => { "[fgt][srcip]" => "[source][ip]" "[fgt][dstip]" => "[destination][ip]"
                   "[fgt][srcport]" => "[source][port]" "[fgt][dstport]" => "[destination][port]"
                   "[fgt][action]" => "[event][action]" }
      convert => { "[source][port]" => "integer" "[destination][port]" => "integer" }
      add_field => { "[event][dataset]" => "fortigate.traffic" "[observer][vendor]" => "Fortinet" }
    }
  }
}
```

This is a starting point. Real FortiGate lines start with a syslog header (`<189>`), so expect to adjust the filter. That's exactly what the test in step 6 is for: iterate until it's green.

### 4. Output: add a block to `90-output-elasticsearch.conf`

Copy the OPNsense block and change the tag and dataset:

```
  if "fortigate" in [tags] {
    elasticsearch {
      hosts       => ["https://192.168.50.10:9200"]
      user        => "logstash_writer"
      password    => "${LOGSTASH_WRITER_PASSWORD}"
      ssl_certificate_authorities => ["/etc/logstash/certs/http_ca.crt"]
      data_stream => true
      data_stream_type      => "logs"
      data_stream_dataset   => "fortigate"
      data_stream_namespace => "default"
    }
  }
```

Elasticsearch side (one time): the `logstash_writer` role only allows `logs-opnsense-*`. Add the new pattern in Kibana under **Stack Management → Roles → logstash_writer → Indices**: add `logs-fortigate-*` with the same privileges.

### 5. Test data: `elk/logstash/tests/fortigate.log`

Paste 3–5 **real** log lines from the device (one per line): one allow, one deny, one UDP. Real lines catch real problems.

### 6. Test checks

Copy `ci/test-logstash-filter.sh` to `ci/test-fortigate-filter.sh` and change only these parts:

```bash
# which filter + which sample file + which tag
cp "$ROOT/elk/logstash/conf.d/51-filter-fortigate.conf" "$PIPE/"
input { stdin { tags => ["fortigate"] } }          # in the 00-input.conf heredoc
< "$ROOT/elk/logstash/tests/fortigate.log"         # in the docker run line
[ "$lines" -eq 3 ]                                 # number of sample lines

# then your own checks, one per thing you care about:
check 1 "deny parsed"   '.event.action == "deny" and .destination.port == 443'
check 2 "allow parsed"  '.event.action == "accept"'
```

A `check` is: **line number**, **description**, **jq condition that must be true** for that output line.

### 7. Run it in CI: add one step to the `logstash` job in `.github/workflows/ci.yml`

```yaml
      - name: Parser test (FortiGate)
        run: bash ci/test-fortigate-filter.sh
```

### 8. Send logs

Point the device's syslog at `192.168.50.10:5515/udp`. Then in Kibana, create a data view `logs-fortigate-*`.

That's it. The existing deploy script already copies every `*.conf` in `conf.d/`, validates it and rolls back on failure.

---

## Level 2: New service or new config files

### 1. Folder

```
thehive/
  application.conf          (or docker-compose.yml, etc.)
  README.md                 what it is, which host, how to check it's healthy
```

### 2. Pick the validator

Every service has a way to say "is this config valid?" without starting it. Find it first. It becomes your CI check.

| File type | Validator (CI step) |
|---|---|
| YAML | already covered by the `YAML lint` job |
| JSON | `jq empty file.json` |
| Docker Compose | `docker compose -f file.yml config -q` |
| Logstash | `logstash -t` (see `ci/test-logstash-config.sh`) |
| Nginx | `docker run --rm -v $PWD/nginx:/etc/nginx:ro nginx nginx -t` |
| Shell scripts | `shellcheck script.sh` |

### 3. CI job template: append to `.github/workflows/ci.yml` under `jobs:`

```yaml
  thehive:
    name: TheHive config check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: Validate compose file
        run: docker compose -f thehive/docker-compose.yml config -q
```

Then add it to the deploy job's `needs:` so a failure blocks deploy:

```yaml
    needs: [lint, secrets, logstash, thehive]
```

### 4. Deploy function template

Add a function to `ci/deploy-elk.sh` that copies the pattern. Every deploy function does the same six things:

```bash
deploy_myservice() {
  local src="$SRC/../myservice/myservice.conf" dst="/etc/myservice/myservice.conf"

  # 1. compare: nothing to do if identical
  if cmp -s "$src" "$dst"; then log "myservice: no changes"; return 0; fi
  log "myservice: changes detected"; diff -u "$dst" "$src" || true
  [ "$MODE" = "--check" ] && return 0

  # 2. validate the NEW file before touching anything (service-specific command)
  myservice --test-config "$src" || die "myservice config invalid; nothing changed"

  # 3. backup
  local bk="$BACKUP_ROOT/$TS/myservice"; mkdir -p "$bk"; cp -a "$dst" "$bk/"

  # 4. apply
  install -o root -g myservice -m 640 "$src" "$dst"

  # 5. restart + health check (pick a real signal: port open, HTTP code, status API)
  systemctl restart myservice || true
  local ok=0
  for _ in $(seq 1 30); do
    curl -s -o /dev/null http://127.0.0.1:9000/health && { ok=1; break; }; sleep 5
  done

  # 6. rollback if unhealthy
  if [ "$ok" -ne 1 ]; then
    install -o root -g myservice -m 640 "$bk/$(basename "$dst")" "$dst"
    systemctl restart myservice || true
    die "myservice deploy failed and was rolled back"
  fi
  log "myservice: healthy"; CHANGED=1
}
```

Call it at the bottom next to the others:

```bash
deploy_elasticsearch
deploy_logstash
deploy_myservice
```

### 5. Re-install the script on elk01 (the security step)

The runner never runs the repo's copy of the script, only the root-owned copy. After your PR is merged:

```bash
C=/home/gh-runner/actions-runner/_work/projectx-infra/projectx-infra
sudo diff /opt/projectx/deploy-elk.sh $C/ci/deploy-elk.sh     # review what changed
sudo install -o root -g root -m 755 $C/ci/deploy-elk.sh /opt/projectx/deploy-elk.sh
```

Then **Actions → CI → Run workflow → mode: check** to see the dry run before anything is applied.

### 6. If the service runs on a **different VM**

The elk01 runner can only deploy to elk01. For another VM, either:
- install a second runner on that VM (same steps as elk01, label e.g. `hive01`, its own deploy script), or
- move to Ansible from one runner. This is worth doing once there are 3+ VMs.

---

## Secrets checklist

- Passwords go in the service's keystore or a root-only env file on the server (`/etc/<service>/secrets.env`, mode 600), referenced as `${VAR}`.
- Never write a real password in a repo file, even "temporarily". Git keeps it in history forever.
- If gitleaks fails your PR, it found something. Remove it **and** change that password, because it's already in the branch history.

## When CI fails: where to look

| Red job | Usual cause | Where to see why |
|---|---|---|
| YAML lint | Tab instead of spaces, wrong indentation | Click job → the line number is in the log |
| Secret scan | A literal password in a file | Job log shows file and line (value redacted) |
| Logstash config test | Syntax error: missing `}` or quote | Log shows `Expected one of ... at line X` |
| Parser test | Your filter output changed | The failing `check` and the parsed event appear as annotations at the top of the run |
| Deploy to elk01 | Validation failed or the service didn't come back | Deploy step log; elk01 was rolled back, `/var/backups/projectx/` has the previous files |
