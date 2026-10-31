#!/usr/bin/env bash
# Flip HAProxy backend weights between legacy-app and container-app.
# Connects to the HAProxy admin socket on lb (${LB_HOST}).
# Uses socat (installed on the HAProxy CT) via ssh from the workstation.
#
# Usage:
#   bash scripts/flip-weights.sh canary     # 90/10 — legacy/container
#   bash scripts/flip-weights.sh cutover    # 0/100
#   bash scripts/flip-weights.sh rollback   # 100/0 — instant rollback
#   bash scripts/flip-weights.sh status     # show current weights
#   bash scripts/flip-weights.sh custom LEGACY_W CONTAINER_W
#
# The HAProxy admin socket is at /var/run/haproxy/admin.sock on lb.
# We reach it via ssh to root@${HYPERVISOR_HOST}, then pct exec ${CT_LB:-732}.
set -euo pipefail

HAPROXY_IP="${LB_HOST}"
HAPROXY_CT="${CT_LB:-732}"   # override via CT_LB env var; 732 is the example default in .env.example
HYPERVISOR="root@${HYPERVISOR_HOST}"
BACKEND="petclinic"

# Execute a socat command on the HAProxy CT via Proxmox pct exec
haproxy_cmd() {
  local CMD="$1"
  ssh "${HYPERVISOR}" "pct exec ${HAPROXY_CT} -- bash -c \"echo '${CMD}' | socat - /var/run/haproxy/admin.sock\""
}

case "${1:-}" in
  canary)
    echo "Setting weights: legacy=90 container=10 (canary)"
    haproxy_cmd "set weight ${BACKEND}/legacy-app 90"
    haproxy_cmd "set weight ${BACKEND}/container-app 10"
    ;;
  cutover)
    echo "Setting weights: legacy=0 container=100 (full cutover)"
    haproxy_cmd "set weight ${BACKEND}/legacy-app 0"
    haproxy_cmd "set weight ${BACKEND}/container-app 100"
    ;;
  rollback)
    echo "Setting weights: legacy=100 container=0 (rollback)"
    haproxy_cmd "set weight ${BACKEND}/legacy-app 100"
    haproxy_cmd "set weight ${BACKEND}/container-app 0"
    ;;
  status)
    echo "Backend ${BACKEND} server weights:"
    haproxy_cmd "show servers state ${BACKEND}"
    ;;
  custom)
    LEGACY_W="${2:?usage: flip-weights.sh custom LEGACY_W CONTAINER_W}"
    CONTAINER_W="${3:?usage: flip-weights.sh custom LEGACY_W CONTAINER_W}"
    echo "Setting weights: legacy=${LEGACY_W} container=${CONTAINER_W}"
    haproxy_cmd "set weight ${BACKEND}/legacy-app ${LEGACY_W}"
    haproxy_cmd "set weight ${BACKEND}/container-app ${CONTAINER_W}"
    ;;
  *)
    echo "Usage: $0 {canary|cutover|rollback|status|custom LEGACY_W CONTAINER_W}"
    exit 1
    ;;
esac

echo "Done. Verify:"
haproxy_cmd "show servers state ${BACKEND}"
