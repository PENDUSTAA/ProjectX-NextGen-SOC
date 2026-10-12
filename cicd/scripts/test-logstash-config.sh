#!/usr/bin/env bash
# Syntax-checks the full production pipeline (input + filter + output) with logstash -t.
set -euo pipefail

LS_IMAGE="${LS_IMAGE:-docker.elastic.co/logstash/logstash:8.19.23}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The output references a CA file and a keystore variable; give it dummies.
echo "dummy" > "$WORK/http_ca.crt"
chmod -R a+rX "$WORK" "$ROOT/elk/logstash/conf.d"

docker run --rm -e XPACK_MONITORING_ENABLED=false \
  -e LOGSTASH_WRITER_PASSWORD=ci-dummy \
  -v "$ROOT/elk/logstash/conf.d:/test:ro" \
  -v "$WORK/http_ca.crt:/etc/logstash/certs/http_ca.crt:ro" \
  "$LS_IMAGE" -t -f /test --log.level warn
