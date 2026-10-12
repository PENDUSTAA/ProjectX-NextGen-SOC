#!/usr/bin/env bash
# Deploys ELK configs from a repo checkout to this host (elk01).
# Installed root-owned at /opt/projectx/deploy-elk.sh and run by the GitHub runner via sudo.
# Changes to this script take effect only after a manual re-install (by design: the repo
# cannot change what root runs).
#
# Usage: deploy-elk.sh <checkout-dir> [--check]
#   --check   show what would change, apply nothing
#
# Order: Elasticsearch first (Logstash depends on it), then Logstash.
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
trap 'rm -rf "$STAGE" "$SDATA"' EXIT

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

log "Deploying from $CHECKOUT (mode: $MODE)"
deploy_elasticsearch
deploy_es_api
deploy_logstash
[ "$MODE" = "--check" ] && { log "Check only: nothing applied"; exit 0; }
[ "$CHANGED" -eq 1 ] && log "Deploy complete" || log "Nothing to deploy"
