#!/usr/bin/env bash
# Deploys ELK configs from a repo checkout to this host (elk01).
# Installed root-owned at /opt/projectx/deploy-elk.sh and run by the GitHub runner via sudo.
# Changes to this script take effect only after a manual re-install (by design: the repo
# cannot change what root runs).
#
# Usage: deploy-elk.sh <checkout-dir> [--check]
#   --check   show what would change, apply nothing
#
# Order: Elasticsearch first (Logstash depends on it), then ES API objects, Logstash, ElastAlert2.
# Each component: diff -> validate -> backup -> apply -> restart -> health check -> rollback on failure.
set -euo pipefail

CHECKOUT="${1:-}"; MODE="${2:-apply}"
RUNNER_WORK="/home/gh-runner/actions-runner/_work"
BACKUP_ROOT="/var/backups/projectx"
TS="$(date +%Y%m%d-%H%M%S)-$$"

die()  { echo "::error::$*"; echo "ERROR: $*" >&2; exit 1; }
log()  { echo "==> $*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (via sudo)"
[ -n "$CHECKOUT" ] || die "usage: deploy-elk.sh <checkout-dir> [--check]"
CHECKOUT="$(realpath -e "$CHECKOUT")" || die "checkout dir not found"
case "$CHECKOUT" in "$RUNNER_WORK"/*) ;; *) die "checkout must be under $RUNNER_WORK" ;; esac
SRC="$CHECKOUT/elk"
[ -d "$SRC" ] || die "no elk/ folder in $CHECKOUT"

exec 9>/run/projectx-deploy.lock
flock -n 9 || die "another deploy is running"

CHANGED=0
STAGE="$(mktemp -d /tmp/ls-stage.XXXXXX)"; SDATA="$(mktemp -d /tmp/ls-data.XXXXXX)"
EA_ST=""
trap 'rm -rf "$STAGE" "$SDATA" ${EA_ST:+"$EA_ST"}' EXIT

# ---------------------------------------------------------------- Elasticsearch
deploy_elasticsearch() {
  local yml_src="$SRC/elasticsearch/elasticsearch.yml" heap_src="$SRC/elasticsearch/heap.options"
  local yml_dst="/etc/elasticsearch/elasticsearch.yml" heap_dst="/etc/elasticsearch/jvm.options.d/heap.options"

  if cmp -s "$yml_src" "$yml_dst" && cmp -s "$heap_src" "$heap_dst"; then
    log "Elasticsearch: no changes"; return 0
  fi
  log "Elasticsearch: changes detected"
  diff -u "$yml_dst" "$yml_src" || true
  diff -u "$heap_dst" "$heap_src" || true
  [ "$MODE" = "--check" ] && return 0

  local host; host="$(awk -F': *' '/^network.host:/{print $2}' "$yml_src")"
  [ -n "$host" ] || die "network.host missing in elasticsearch.yml"

  local bk="$BACKUP_ROOT/$TS/elasticsearch"; mkdir -p "$bk"
  cp -a "$yml_dst" "$heap_dst" "$bk/"
  log "Elasticsearch: backup in $bk"

  install -o root -g elasticsearch -m 660 "$yml_src" "$yml_dst"
  install -o root -g elasticsearch -m 660 "$heap_src" "$heap_dst"
  systemctl restart elasticsearch || true

  # Healthy = HTTPS answers (401 without credentials is fine) within 180 s
  local code=""
  for _ in $(seq 1 36); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' "https://$host:9200/" || true)"
    [ "$code" = "401" ] || [ "$code" = "200" ] && break
    sleep 5
  done
  if [ "$code" != "401" ] && [ "$code" != "200" ]; then
    echo "::error::Elasticsearch did not come back (last HTTP code '$code'); rolling back"
    journalctl -u elasticsearch --no-pager -n 30 || true
    install -o root -g elasticsearch -m 660 "$bk/elasticsearch.yml" "$yml_dst"
    install -o root -g elasticsearch -m 660 "$bk/heap.options" "$heap_dst"
    systemctl restart elasticsearch || true
    die "Elasticsearch deploy failed and was rolled back"
  fi
  log "Elasticsearch: healthy (HTTP $code)"; CHANGED=1
}

# ---------------------------------------------------------------- Elasticsearch API objects
# ILM policies and component templates from elk/elasticsearch/api/. Needs a deploy user
# whose credentials live in a root-only file (never in the repo):
#   /etc/projectx/es-deployer.env  ->  ES_URL=https://<host>:9200  ES_USER=...  ES_PASS=...
ES_CA="/etc/elasticsearch/certs/http_ca.crt"
ES_ENV="/etc/projectx/es-deployer.env"

es_call() {  # es_call <METHOD> <path> [body-file]  -> prints body, returns 0 only on HTTP 2xx
  local method="$1" path="$2" body="${3:-}" out code
  out="$(mktemp)"
  local args=(-sS --cacert "$ES_CA" -o "$out" -w '%{http_code}' -X "$method" -H 'Content-Type: application/json')
  [ -n "$body" ] && args+=(--data-binary "@$body")
  # credentials via stdin config, so they never appear in the process list
  code="$(printf 'user = "%s:%s"\n' "$ES_USER" "$ES_PASS" | curl -K - "${args[@]}" "$ES_URL$path" || true)"
  cat "$out"; rm -f "$out"
  [[ "$code" == 2* ]]
}

deploy_es_api() {
  local api="$SRC/elasticsearch/api"
  [ -d "$api" ] || { log "Elasticsearch API: nothing in repo"; return 0; }
  command -v jq >/dev/null || die "jq is required on this host (apt install jq)"
  [ -r "$ES_ENV" ] || die "missing $ES_ENV (deploy user credentials); see README"
  # shellcheck disable=SC1090
  . "$ES_ENV"
  : "${ES_URL:?ES_URL missing in $ES_ENV}" "${ES_USER:?}" "${ES_PASS:?}"
  es_call GET /_security/_authenticate >/dev/null \
    || die "cannot log in to Elasticsearch as $ES_USER (check $ES_ENV)"

  local kind file name path cur_filter want have bk
  # ILM first: component templates reference the policies
  for kind in ilm component_template; do
    for file in "$api/$kind"/*.json; do
      [ -e "$file" ] || continue
      name="$(basename "$file" .json)"
      if [ "$kind" = ilm ]; then
        path="/_ilm/policy/$name"; cur_filter=".\"$name\".policy // empty"; want="$(jq -S .policy "$file")"
      else
        path="/_component_template/$name"; cur_filter=".component_templates[0].component_template // empty"; want="$(jq -S . "$file")"
      fi
      have="$(es_call GET "$path" | jq -S "$cur_filter" 2>/dev/null || true)"
      if [ "$have" = "$want" ]; then log "ES API $kind/$name: no changes"; continue; fi

      log "ES API $kind/$name: changes detected"
      diff -u <(echo "${have:-<none>}") <(echo "$want") || true
      [ "$MODE" = "--check" ] && continue

      bk="$BACKUP_ROOT/$TS/es-api/$kind"; mkdir -p "$bk"
      if [ -n "$have" ]; then
        if [ "$kind" = ilm ]; then jq '{policy: .}' <<<"$have" > "$bk/$name.json"; else echo "$have" > "$bk/$name.json"; fi
      fi
      if ! es_call PUT "$path" "$file" >/dev/null; then
        die "ES API $kind/$name: PUT rejected by Elasticsearch; nothing changed for this object"
      fi
      have="$(es_call GET "$path" | jq -S "$cur_filter" 2>/dev/null || true)"
      if [ "$have" != "$want" ]; then
        echo "::error::ES API $kind/$name: stored object differs from repo after PUT; restoring"
        diff -u <(echo "$have") <(echo "$want") || true
        [ -f "$bk/$name.json" ] && es_call PUT "$path" "$bk/$name.json" >/dev/null || true
        die "ES API $kind/$name: verify failed and previous version was restored"
      fi
      log "ES API $kind/$name: applied and verified"; CHANGED=1
    done
  done
}

# ---------------------------------------------------------------- Logstash
deploy_logstash() {
  local src="$SRC/logstash/conf.d" dst="/etc/logstash/conf.d"
  local stage="$STAGE" sdata="$SDATA"

  cp "$src"/*.conf "$stage/"
  if diff -rq --exclude='*.bak' "$stage" "$dst" >/dev/null 2>&1; then
    log "Logstash: no changes"; return 0
  fi
  log "Logstash: changes detected"
  diff -ru "$dst" "$stage" || true
  [ "$MODE" = "--check" ] && return 0

  # Keystore must hold every ${VAR} the pipeline references
  local vars; vars="$(grep -ohE '\$\{[A-Z0-9_]+\}' "$stage"/*.conf | tr -d '${}' | sort -u || true)"
  if [ -n "$vars" ]; then
    local have; have="$(/usr/share/logstash/bin/logstash-keystore --path.settings /etc/logstash list 2>/dev/null || true)"
    for v in $vars; do
      # keystore stores keys lowercase; Logstash resolves ${VAR} case-insensitively
      grep -qix "$v" <<<"$have" || die "Logstash keystore is missing $v (add it with logstash-keystore add $v)"
    done
  fi

  # Validate the staged pipeline as the logstash user before touching anything
  chown -R root:logstash "$stage"; chmod 750 "$stage"; chmod 640 "$stage"/*.conf
  chown logstash:logstash "$sdata"
  log "Logstash: validating staged pipeline"
  sudo -u logstash /usr/share/logstash/bin/logstash --path.settings /etc/logstash \
    --path.data "$sdata" -t -f "$stage" --log.level warn \
    || die "Logstash config test failed; nothing was changed"

  local bk="$BACKUP_ROOT/$TS/logstash-conf.d"; mkdir -p "$bk"
  cp -a "$dst"/. "$bk/"
  log "Logstash: backup in $bk"

  rm -f "$dst"/*.conf
  install -o root -g logstash -m 640 "$stage"/*.conf "$dst/"
  systemctl restart logstash || true

  # Healthy = service active and UDP 5514 listening, still true 20 s later
  local ok=0
  for _ in $(seq 1 30); do
    if systemctl is-active -q logstash && ss -ulnH 'sport = :5514' | grep -q .; then ok=1; break; fi
    sleep 5
  done
  if [ "$ok" -eq 1 ]; then
    sleep 20
    systemctl is-active -q logstash && ss -ulnH 'sport = :5514' | grep -q . || ok=0
  fi
  if [ "$ok" -ne 1 ]; then
    echo "::error::Logstash not healthy after deploy; rolling back"
    journalctl -u logstash --no-pager -n 40 || true
    rm -f "$dst"/*.conf
    cp -a "$bk"/. "$dst/"
    systemctl restart logstash || true
    die "Logstash deploy failed and was rolled back"
  fi
  log "Logstash: healthy (listening on udp/5514)"; CHANGED=1
}

# ---------------------------------------------------------------- ElastAlert2
# Rules in the repo carry the placeholder __SHUFFLE_WEBHOOK_URL__; the real URL lives in a
# root-only file on this host (never in Git) and is inserted here:
#   /etc/projectx/shuffle-webhook.env  ->  SHUFFLE_WEBHOOK_URL=https://<hive01>:3443/api/v1/hooks/webhook_<id>
# Rules deleted from the repo are removed from the host.
EA_SRC="$CHECKOUT/elastalert"
EA_DST="/etc/elastalert"
EA_UNIT="/etc/systemd/system/elastalert.service"
EA_HOOK_ENV="/etc/projectx/shuffle-webhook.env"
EA_PLACEHOLDER="__SHUFFLE_WEBHOOK_URL__"

redact() { sed -E 's#hooks/webhook_[A-Za-z0-9-]+#hooks/webhook_<redacted>#g'; }

deploy_elastalert() {
  [ -d "$EA_SRC/rules" ] || { log "ElastAlert2: nothing in repo"; return 0; }
  [ -x /opt/elastalert2/bin/elastalert ] || die "ElastAlert2 is not installed in /opt/elastalert2 (see elastalert/README.md)"
  [ -r "$EA_HOOK_ENV" ] || die "missing $EA_HOOK_ENV (SHUFFLE_WEBHOOK_URL=...); see elastalert/README.md"
  local SHUFFLE_WEBHOOK_URL=""
  # shellcheck disable=SC1090
  . "$EA_HOOK_ENV"
  [[ "$SHUFFLE_WEBHOOK_URL" =~ ^https?://[^\ \|]+/api/v1/hooks/webhook_[A-Za-z0-9-]+$ ]] \
    || die "SHUFFLE_WEBHOOK_URL in $EA_HOOK_ENV is missing or malformed"

  # Stage: config + rules with the real URL, readable by the elastalert user for validation
  EA_ST="$(mktemp -d /tmp/ea-stage.XXXXXX)"; local st="$EA_ST"
  mkdir "$st/rules"
  cp "$EA_SRC/config.yaml" "$st/config.yaml"
  local f
  for f in "$EA_SRC"/rules/*.yaml; do
    [ -e "$f" ] || continue
    sed "s|$EA_PLACEHOLDER|$SHUFFLE_WEBHOOK_URL|g" "$f" > "$st/rules/$(basename "$f")"
  done
  grep -l "$EA_PLACEHOLDER" "$st"/rules/*.yaml 2>/dev/null && die "placeholder left in a staged rule"

  local cfg_same=1 rules_same=1 unit_same=1
  cmp -s "$st/config.yaml" "$EA_DST/config.yaml" || cfg_same=0
  diff -rq "$st/rules" "$EA_DST/rules" >/dev/null 2>&1 || rules_same=0
  cmp -s "$EA_SRC/elastalert.service" "$EA_UNIT" || unit_same=0
  if [ $cfg_same -eq 1 ] && [ $rules_same -eq 1 ] && [ $unit_same -eq 1 ]; then
    rm -rf "$st"; log "ElastAlert2: no changes"; return 0
  fi
  log "ElastAlert2: changes detected (webhook URL redacted in output)"
  diff -u "$EA_DST/config.yaml" "$st/config.yaml" | redact || true
  diff -ruN "$EA_DST/rules" "$st/rules" | redact || true
  diff -u "$EA_UNIT" "$EA_SRC/elastalert.service" || true
  if [ "$MODE" = "--check" ]; then rm -rf "$st"; return 0; fi

  # Validate every staged rule with ElastAlert2's own schema check, as the elastalert user
  chown -R root:elastalert "$st"; chmod 750 "$st" "$st/rules"; chmod 640 "$st/config.yaml" "$st"/rules/*.yaml
  sed -i "s|^rules_folder:.*|rules_folder: $st/rules|" "$st/config.yaml"
  for f in "$st"/rules/*.yaml; do
    sudo -u elastalert /opt/elastalert2/bin/elastalert-test-rule --config "$st/config.yaml" --schema-only "$f" >/dev/null 2>&1 \
      || { rm -rf "$st"; die "ElastAlert2 rule $(basename "$f") failed the schema check; nothing was changed"; }
  done
  cp "$EA_SRC/config.yaml" "$st/config.yaml"   # restore real rules_folder

  local bk="$BACKUP_ROOT/$TS/elastalert"; mkdir -p "$bk/rules"
  cp -a "$EA_DST/config.yaml" "$bk/"; cp -a "$EA_DST"/rules/. "$bk/rules/"; cp -a "$EA_UNIT" "$bk/"
  chmod -R go-rwx "$bk"   # backups contain the webhook URL
  log "ElastAlert2: backup in $bk"

  install -o root -g elastalert -m 640 "$st/config.yaml" "$EA_DST/config.yaml"
  rm -f "$EA_DST"/rules/*.yaml
  for f in "$st"/rules/*.yaml; do install -o root -g elastalert -m 640 "$f" "$EA_DST/rules/"; done
  install -o root -g root -m 644 "$EA_SRC/elastalert.service" "$EA_UNIT"
  rm -rf "$st"
  systemctl daemon-reload
  local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
  systemctl restart elastalert || true

  # Healthy = still active 45 s after restart and no rule-load errors in the journal
  sleep 45
  local errs; errs="$(journalctl -u elastalert --since "$since" --no-pager 2>/dev/null | grep -E 'Traceback|ERROR|Error loading|is not valid' | redact || true)"
  if ! systemctl is-active -q elastalert || [ -n "$errs" ]; then
    echo "::error::ElastAlert2 not healthy after deploy; rolling back"
    journalctl -u elastalert --since "$since" --no-pager -n 40 | redact || true
    install -o root -g elastalert -m 640 "$bk/config.yaml" "$EA_DST/config.yaml"
    rm -f "$EA_DST"/rules/*.yaml
    cp -a "$bk"/rules/. "$EA_DST/rules/"
    install -o root -g root -m 644 "$bk/elastalert.service" "$EA_UNIT"
    systemctl daemon-reload; systemctl restart elastalert || true
    die "ElastAlert2 deploy failed and was rolled back"
  fi
  log "ElastAlert2: healthy ($(ls "$EA_DST"/rules/*.yaml | wc -l) rule(s) loaded)"; CHANGED=1
}

log "Deploying from $CHECKOUT (mode: $MODE)"
deploy_elasticsearch
deploy_es_api
deploy_logstash
deploy_elastalert
[ "$MODE" = "--check" ] && { log "Check only: nothing applied"; exit 0; }
[ "$CHANGED" -eq 1 ] && log "Deploy complete" || log "Nothing to deploy"
