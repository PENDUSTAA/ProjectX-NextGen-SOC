#!/usr/bin/env bash
# Runs real OPNsense sample lines through the production filter and checks the parsed fields.
# Usage: ci/test-logstash-filter.sh   (needs docker + jq; LS_IMAGE optional)
set -euo pipefail

LS_IMAGE="${LS_IMAGE:-docker.elastic.co/logstash/logstash:8.19.23}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Test pipeline = stdin input + the real filter file + JSON to stdout.
# Pipeline files get their own folder: Logstash loads every file in the -f directory.
PIPE="$WORK/pipeline"; mkdir -p "$PIPE"
cat > "$PIPE/00-input.conf" <<'EOF'
input { stdin { tags => ["opnsense"] } }
EOF
cp "$ROOT/elk/logstash/conf.d/50-filter-opnsense.conf" "$PIPE/"
cat > "$PIPE/99-output.conf" <<'EOF'
output { stdout { codec => json_lines } }
EOF
chmod -R a+rX "$WORK"

# GitHub annotation helper (visible in the PR/run UI and via the API)
annotate() { printf '::error title=%s::%s\n' "$1" "$(printf '%s' "$2" | head -c 3000 | tr '\n' ' ')"; }

rc=0
docker run --rm -i -e XPACK_MONITORING_ENABLED=false -v "$PIPE:/test:ro" "$LS_IMAGE" \
  -f /test -w 1 --log.level error \
  < "$ROOT/elk/logstash/tests/opnsense.log" \
  > "$WORK/raw.out" 2> "$WORK/raw.err" || rc=$?
grep '^{' "$WORK/raw.out" > "$WORK/out.jsonl" || true

lines=$(wc -l < "$WORK/out.jsonl")
echo "Logstash exit code $rc, parsed $lines events"
if [ "$lines" -ne 4 ]; then
  echo "FAIL: expected 4 events"; echo "--- stdout ---"; cat "$WORK/raw.out"; echo "--- stderr ---"; cat "$WORK/raw.err"
  annotate "parser: expected 4 events, got $lines (exit $rc)" "stdout: $(tail -c 1500 "$WORK/raw.out") | stderr: $(tail -c 1500 "$WORK/raw.err")"
  exit 1
fi

fail=0
check() {  # check <line-number 1..N> <description> <jq expression that must be true>
  if sed -n "${1}p" "$WORK/out.jsonl" | jq -e "$3" > /dev/null; then
    echo "  ok   [$1] $2"
  else
    echo "  FAIL [$1] $2"; sed -n "${1}p" "$WORK/out.jsonl" | jq -c .; fail=1
    annotate "parser [$1] $2" "$(sed -n "${1}p" "$WORK/out.jsonl" | jq -c 'del(.message, .event.original)')"
  fi
}

# Every event: no parse failure tags, no leftover CSV/auto-named columns
for n in 1 2 3 4; do
  check $n "no failure tags"   '[.tags[]? | select(startswith("_"))] | length == 0'
  check $n "no stray columns"  '[keys[] | select(test("^(column[0-9]+|f[0-9]+|syslog_msg)$"))] | length == 0'
  check $n "dataset set"       '.event.dataset == "opnsense.firewall"'
  check $n "hostname is OPNsense" '.host.hostname == "OPNsense.internal"'
done

check 1 "tcp block parsed"   '.event.action == "block" and .network.transport == "tcp" and .["@timestamp"] == "2026-10-11T12:37:47.000Z"'
check 1 "tcp ips and ports"  '.source.ip == "172.16.20.53" and .destination.ip == "172.16.10.17" and .destination.port == 443 and .source.port == 42631'
check 1 "tcp flags + iface"  '.opnsense.tcp_flags == "S" and .observer.ingress.interface.name == "em0" and .opnsense.dir == "in"'
check 2 "udp ports numeric"  '.network.transport == "udp" and .source.port == 123 and .destination.port == 123'
check 2 "udp has no tcp flags" '.opnsense.tcp_flags == null'
check 3 "icmp has no ports"  '.network.transport == "icmp" and .destination.port == null and .source.ip == "172.16.20.53"'
check 4 "lan pass parsed"    '.event.action == "pass" and .observer.ingress.interface.name == "em1" and .destination.port == 5601 and .rule.id == "64"'

[ "$fail" -eq 0 ] && echo "All filter checks passed" || { echo "Filter checks FAILED"; exit 1; }
