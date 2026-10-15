# Shuffle "Shuffle Tools -> Execute python" step, placed after "TheHive 1" (Create alert).
# Runs every applicable Cortex analyzer on the new alert's observables, through TheHive, so the
# reports and taxonomy tags land on the alert. Private/internal IPs are skipped (no reputation data,
# saves AbuseIPDB / VirusTotal quota).
# Paste into Shuffle and replace __SVC_SHUFFLE_KEY__ with the svc-shuffle API key (never commit it).
import ipaddress, json
import requests, urllib3

urllib3.disable_warnings()                      # TheHive uses a self-signed cert (hardening item)
TH = "https://192.168.50.15"
KEY = "__SVC_SHUFFLE_KEY__"
H = {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"}
ALERT_ID = "$thehive_1.body._id"                # filled in by Shuffle before the code runs

def skip(o):
    if o.get("dataType") != "ip":
        return False
    try:
        ip = ipaddress.ip_address(o.get("data", ""))
        return not ip.is_global
    except ValueError:
        return True

result = {"alert": ALERT_ID, "jobs": [], "skipped": []}
if not ALERT_ID.startswith("~"):
    result["error"] = "no alert id from TheHive 1 (alert not created?)"
else:
    q = {"query": [{"_name": "getAlert", "idOrName": ALERT_ID}, {"_name": "observables"}]}
    obs = requests.post(f"{TH}/api/v1/query", headers=H, json=q, verify=False, timeout=30).json()
    ana = requests.get(f"{TH}/api/connector/cortex/analyzer", headers=H, verify=False, timeout=30).json()
    for o in obs:
        if skip(o):
            result["skipped"].append(o.get("data"))
            continue
        for a in ana:
            if o.get("dataType") not in a.get("dataTypeList", []):
                continue
            for cortex in a.get("cortexIds") or ["cortex01"]:
                r = requests.post(f"{TH}/api/connector/cortex/job", headers=H, verify=False, timeout=30,
                                  json={"analyzerId": a["id"], "cortexId": cortex, "artifactId": o["_id"]})
                result["jobs"].append({"observable": o.get("data"), "analyzer": a.get("name"),
                                       "status": r.status_code})
print(json.dumps(result))
