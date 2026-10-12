#!/usr/bin/env bash
# Checks Elasticsearch API objects in elk/elasticsearch/api/ before they reach elk01.
set -euo pipefail
API="$(cd "$(dirname "$0")/.." && pwd)/elk/elasticsearch/api"
fail=0
err() { echo "::error file=$1::$2"; echo "FAIL $1: $2"; fail=1; }

for f in "$API"/*/*.json; do
  [ -e "$f" ] || continue
  jq empty "$f" 2>/dev/null || { err "$f" "not valid JSON"; continue; }
  echo "ok   valid JSON  ${f#"$API"/}"
done

# ILM policies: must have a policy object and keep a delete phase (retention guard)
for f in "$API"/ilm/*.json; do
  [ -e "$f" ] || continue
  jq -e '.policy.phases' "$f" >/dev/null || err "$f" "missing .policy.phases"
  jq -e '.policy.phases.delete.actions.delete' "$f" >/dev/null \
    || err "$f" "no delete phase: logs would never be removed and the disk would fill"
  echo "ok   retention   $(basename "$f" .json): delete after $(jq -r '.policy.phases.delete.min_age' "$f")"
done

# Component templates: any referenced ILM policy must exist in the repo
for f in "$API"/component_template/*.json; do
  [ -e "$f" ] || continue
  pol="$(jq -r '.template.settings.index.lifecycle.name // empty' "$f")"
  [ -z "$pol" ] && continue
  if [ -f "$API/ilm/$pol.json" ]; then
    echo "ok   reference   $(basename "$f" .json) -> ilm/$pol"
  else
    err "$f" "references ILM policy '$pol' but elk/elasticsearch/api/ilm/$pol.json does not exist"
  fi
done

[ "$fail" -eq 0 ] && echo "All Elasticsearch API checks passed" || exit 1
