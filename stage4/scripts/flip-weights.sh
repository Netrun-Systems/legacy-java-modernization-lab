#!/usr/bin/env bash
# legacy-java-modernization-lab Stage 4 — HAProxy weight flip via admin socket
#
# Usage (run on lb, or via pct exec):
#   flip-weights.sh canary    # legacy=90, container=10
#   flip-weights.sh cutover   # legacy=0,  container=100
#   flip-weights.sh rollback  # legacy=100, container=0
#   flip-weights.sh status    # show current weights + stats
#
# The admin socket is at /var/run/haproxy/admin.sock (configured in haproxy.cfg).
# socat is used as the socket client.
#
# PCI note: weight changes are ephemeral — they survive a process reload
# but NOT a full restart.  For a permanent change, update haproxy.cfg
# (which would trigger an OpenVox config resource notify → haproxy reload).

SOCK="/var/run/haproxy/admin.sock"
BACKEND="petclinic"
LEGACY="legacy-app"
CONTAINER="container-app"

haproxy_cmd() {
  echo "$1" | socat - UNIX-CONNECT:"$SOCK"
}

show_status() {
  echo "=== HAProxy backend status ==="
  haproxy_cmd "show stat" | \
    awk -F, 'NR==1{for(i=1;i<=NF;i++) col[$i]=i; next}
             $2=="legacy-app" || $2=="container-app" {
               printf "  %-16s  wght=%-4s  status=%-7s  rq_tot=%-6s\n",
               $2, $col["weight"], $col["status"], $col["req_tot"]
             }'
  echo
  echo "=== Sample request (10 x curl to :80/petclinic/owners) ==="
  for i in $(seq 1 10); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      "http://127.0.0.1:80/petclinic/owners?lastName=" 2>/dev/null)
    printf "%d " "$CODE"
  done
  echo
}

set_weights() {
  LW=$1; CW=$2; LABEL=$3
  echo "--- $LABEL: legacy weight=$LW  container weight=$CW ---"
  haproxy_cmd "set weight $BACKEND/$LEGACY $LW"
  haproxy_cmd "set weight $BACKEND/$CONTAINER $CW"
  sleep 1
  show_status
}

case "${1:-status}" in
  canary)   set_weights 90 10 "CANARY (10% to container)" ;;
  cutover)  set_weights  0 100 "CUTOVER (100% to container)" ;;
  rollback) set_weights 100  0 "ROLLBACK (100% to legacy)" ;;
  status)   show_status ;;
  *)
    echo "Usage: $0 {canary|cutover|rollback|status}"
    exit 1
    ;;
esac
