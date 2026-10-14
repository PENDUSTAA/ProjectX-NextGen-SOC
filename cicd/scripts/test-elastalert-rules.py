#!/usr/bin/env python3
"""Checks ElastAlert2 rules in elastalert/rules/ before they reach elk01.

Run with the Python that has elastalert2 installed (CI: a venv with the same version as elk01):
    python ci/test-elastalert-rules.py

Per rule:
  1. ElastAlert2's own schema check (elastalert-test-rule --schema-only)
  2. name == file name, names unique
  3. alerts via post2 to the placeholder URL only (the real Shuffle webhook never goes in Git)
  4. payload has the fields the Shuffle -> TheHive workflow expects
  5. payload renders to valid JSON against a sample OPNsense event (elastalert/tests/sample-event.json),
     with no empty values and src_ip a valid IP
"""
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock

import elastalert
import jsonschema
import yaml
from elastalert.alerters.httppost2 import HTTPPost2Alerter
from elastalert.loaders import RulesLoader
from jsonschema.exceptions import best_match

ROOT = Path(__file__).resolve().parent.parent
EA = ROOT / "elastalert"
RULES = sorted((EA / "rules").glob("*.yaml"))
SAMPLE = json.loads((EA / "tests" / "sample-event.json").read_text())
PLACEHOLDER = "__SHUFFLE_WEBHOOK_URL__"
PAYLOAD_KEYS = ["title", "description", "type", "ref", "src_ip"]
BIN = Path(sys.executable).parent
SCHEMA = jsonschema.Draft7Validator(yaml.safe_load((Path(elastalert.__file__).parent / "schema.yaml").read_text()))


def schema_reason(rule):
    """Readable reason for a schema failure (ElastAlert2 itself only says 'not valid under any of the given schemas')."""
    if rule.get("type") not in RulesLoader.rules_mapping:
        return f"unknown rule type '{rule.get('type')}' (valid: {', '.join(sorted(RulesLoader.rules_mapping))})"
    bad = [a for a in (rule.get("alert") or []) if isinstance(a, str) and a not in RulesLoader.alerts_mapping]
    if bad:
        return f"unknown alerter {bad}"
    e = best_match(SCHEMA.iter_errors(rule))
    while e is not None and e.context:
        e = best_match(e.context)
    if e is not None and e.absolute_path:
        return f"{'.'.join(map(str, e.absolute_path))}: {e.message[:200]}"
    return "rule does not match the ElastAlert2 schema (check option names and value types)"

failed = False


def err(path, msg):
    global failed
    failed = True
    rel = path.relative_to(ROOT)
    print(f"::error file={rel}::{msg}")
    print(f"FAIL {rel}: {msg}")


def ok(path, msg):
    print(f"ok   {path.relative_to(ROOT)}: {msg}")


# No real webhook anywhere under elastalert/
for f in EA.rglob("*"):
    if f.is_file() and re.search(r"hooks/webhook_[0-9a-f-]{8,}", f.read_text(errors="ignore")):
        err(f, "contains a real Shuffle webhook URL; use the placeholder " + PLACEHOLDER)

# Global config: parses, no credentials
cfg_path = EA / "config.yaml"
cfg = yaml.safe_load(cfg_path.read_text())
for k in ("rules_folder", "run_every", "buffer_time", "es_host", "es_port", "writeback_index"):
    if k not in cfg:
        err(cfg_path, f"missing {k}")
for k in ("es_username", "es_password", "es_api_key", "es_bearer"):
    if k in cfg:
        err(cfg_path, f"{k} must not be in Git; it comes from /etc/elastalert/elastalert.env")
if not failed:
    ok(cfg_path, "config valid, no credentials")

if not RULES:
    err(EA / "rules", "no rules found")

# Schema check needs a config whose rules_folder exists
tmp = Path(tempfile.mkdtemp())
(tmp / "rules").mkdir()
test_cfg = dict(cfg, rules_folder=str(tmp / "rules"))
(tmp / "config.yaml").write_text(yaml.safe_dump(test_cfg))

names = {}
for rule_path in RULES:
    rule = yaml.safe_load(rule_path.read_text())

    r = subprocess.run([str(BIN / "elastalert-test-rule"), "--config", str(tmp / "config.yaml"),
                        "--schema-only", str(rule_path)], capture_output=True, text=True)
    if r.returncode != 0:
        err(rule_path, f"ElastAlert2 schema check failed: {schema_reason(rule)}")
        continue
    ok(rule_path, "schema valid")

    name = rule.get("name")
    if name != rule_path.stem:
        err(rule_path, f"name '{name}' must equal the file name '{rule_path.stem}'")
    if name in names:
        err(rule_path, f"duplicate rule name '{name}' (also in {names[name]})")
    names[name] = rule_path.name

    if "post2" not in (rule.get("alert") or []):
        err(rule_path, "alert must include post2 (Shuffle webhook)")
    if rule.get("http_post2_url") != PLACEHOLDER:
        err(rule_path, f"http_post2_url must be the placeholder {PLACEHOLDER}; the real URL is inserted on elk01")

    payload = rule.get("http_post2_payload") or {}
    missing = [k for k in PAYLOAD_KEYS if k not in payload]
    if missing:
        err(rule_path, f"http_post2_payload missing {missing} (Shuffle -> TheHive contract, see hive01/README.md)")
        continue

    # Render exactly as ElastAlert2 would, without sending anything
    alerter = HTTPPost2Alerter(dict(rule, http_post2_url="http://ci.invalid/hook"))
    with mock.patch("requests.post") as post:
        try:
            alerter.alert([SAMPLE])
        except Exception as e:  # noqa: BLE001
            err(rule_path, f"payload does not render: {e}")
            continue
    sent = json.loads(post.call_args.kwargs["data"])
    empty = [k for k in PAYLOAD_KEYS if not str(sent.get(k, "")).strip()]
    if empty:
        err(rule_path, f"payload fields render empty against the sample event: {empty} (wrong field name?)")
        continue
    try:
        ipaddress.ip_address(sent["src_ip"])
    except ValueError:
        err(rule_path, f"src_ip renders to '{sent['src_ip']}', not an IP address")
        continue
    ok(rule_path, f"payload renders: {sent['title']}")

if failed:
    sys.exit(1)
print(f"All ElastAlert2 checks passed ({len(RULES)} rule(s))")
