#!/usr/bin/env bash
# Validates auditbeat/auditbeat.yml with the real Auditbeat binary (same version as the lab).
# The CI container lacks the host's CA file and log dir, so a throwaway CA is mounted and file logging
# is switched off for the test only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${AB_IMAGE:-docker.elastic.co/beats/auditbeat:8.19.23}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj "/CN=ci-dummy-ca" \
  -keyout "$TMP/ca.key" -out "$TMP/http_ca.crt" >/dev/null 2>&1
chmod 644 "$TMP/http_ca.crt"
out="$(docker run --rm -e ES_PWD=ci-dummy \
  -v "$ROOT/auditbeat/auditbeat.yml:/usr/share/auditbeat/auditbeat.yml:ro" \
  -v "$TMP/http_ca.crt:/etc/auditbeat/http_ca.crt:ro" \
  "$IMG" test config -c /usr/share/auditbeat/auditbeat.yml --strict.perms=false \
  -E logging.to_files=false -E logging.to_stderr=true 2>&1)" && rc=0 || rc=$?
echo "$out"
if [ $rc -ne 0 ] || ! grep -q "Config OK" <<<"$out"; then
  echo "::error file=auditbeat/auditbeat.yml::auditbeat test config failed: $(echo "$out" | tail -3 | tr '\n' ' ')"
  exit 1
fi
echo "Auditbeat config OK"
