#!/usr/bin/env bash
# PROJECT X demo: inject realistic OPNsense filterlog lines into Logstash (udp/5514) so the whole
# pipeline runs for real: Logstash -> Elasticsearch -> ElastAlert2 -> Shuffle -> TheHive (+ Cortex).
# Events carry host.hostname "demo-sim" so they can be told apart in Kibana.
#
# Usage: demo/simulate-attack.sh <scenario> [attacker-ip]
#   portscan    25 blocked TCP SYNs to different ports on the WAN   -> opnsense-portscan   (T1046)
#   bruteforce  12 allowed SSH connections to the WAN               -> opnsense-ssh-bruteforce (T1110)
#   burst       40 blocked packets in a few seconds                 -> opnsense-block-spike (T1595)
#   hostsweep   a LAN host contacts 12 private IPs outside the LAN  -> opnsense-lan-host-sweep (T1018)
#   all         portscan + bruteforce + burst (+ hostsweep)
# attacker-ip defaults to 185.220.101.1 (public, well known in reputation feeds -> Cortex finds hits).
# Each rule re-alerts per source at most every 30 min; use another attacker IP to repeat sooner.
set -euo pipefail

SCENARIO="${1:-}"; ATTACKER="${2:-185.220.101.1}"
LS_HOST="${LS_HOST:-192.168.50.10}"; LS_PORT="${LS_PORT:-5514}"
WAN_IP="172.16.10.17"; LAN_HOST="192.168.50.10"
RULE_UUID="02f4bab031b57d1e30553ce08e0ec131"   # OPNsense default deny (as seen in real logs)
SEQ=$((RANDOM))

send() {  # send <action> <src> <dst> <sport> <dport> <iface> <dir>
  local ts; ts="$(date +%Y-%m-%dT%H:%M:%S%:z)"; SEQ=$((SEQ+1))
  local line="<134>1 ${ts} demo-sim filterlog $$ - [meta sequenceId=\"${SEQ}\"] 6,,,${RULE_UUID},$6,match,$1,$7,4,0x0,,64,$((RANDOM)),0,DF,6,tcp,60,$2,$3,$4,$5,0,S,$((RANDOM*RANDOM)),,64240,,mss;sackOK;TS;nop;wscale"
  printf '%s\n' "$line" > "/dev/udp/${LS_HOST}/${LS_PORT}"
}

portscan() {
  echo "==> portscan: ${ATTACKER} -> ${WAN_IP}, 25 ports (blocked)"
  for p in 21 22 23 25 53 80 110 111 135 139 143 389 443 445 993 995 1433 1521 1723 3306 3389 5432 5900 6379 8080; do
    send block "$ATTACKER" "$WAN_IP" $((40000 + RANDOM % 20000)) "$p" em0 in; sleep 0.1
  done
}
bruteforce() {
  echo "==> bruteforce: ${ATTACKER} -> ${WAN_IP}:22, 12 connections (allowed)"
  for _ in $(seq 1 12); do send pass "$ATTACKER" "$WAN_IP" $((40000 + RANDOM % 20000)) 22 em0 in; sleep 0.5; done
}
burst() {
  echo "==> burst: 40 blocked packets from ${ATTACKER}"
  for _ in $(seq 1 40); do send block "$ATTACKER" "$WAN_IP" $((40000 + RANDOM % 20000)) 445 em0 in; sleep 0.05; done
}
hostsweep() {
  echo "==> hostsweep: ${LAN_HOST} -> 192.168.99.1-12:443 (allowed, leaves the LAN)"
  for i in $(seq 1 12); do send pass "$LAN_HOST" "192.168.99.$i" $((40000 + RANDOM % 20000)) 443 em1 in; sleep 0.1; done
}

case "$SCENARIO" in
  portscan|bruteforce|burst|hostsweep) "$SCENARIO" ;;
  all) portscan; bruteforce; burst; hostsweep ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
echo "Done. ElastAlert2 checks every minute: expect TheHive alert(s) within 1-2 minutes."
echo "Kibana: host.hostname : \"demo-sim\"   |   elk01: sudo journalctl -u elastalert -f | grep -E 'matches|alerts sent'"
