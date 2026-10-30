#!/usr/bin/env bash
# Create the lab LXC containers on the hypervisor host.
# Run from the WORKSTATION via: ssh root@${HYPERVISOR_HOST} "bash -s" < scripts/hypervisor-lxc-setup.sh
#
# New CT IDs: configurable via environment variables. Pick IDs that do not conflict
# with any existing containers on your hypervisor before running this script.
# This script allocates ~10 GB RAM and ~85 GB disk total across all six containers.
#
# Resources (CT IDs below are examples — override via env vars):
#   legacy-app    (Jetty 9.4)             1.5GB RAM 20GB
#   container-app (Jetty 12.1 ee8)        1.5GB RAM 20GB
#   lb            (HAProxy)               512MB RAM 10GB
#   monitor       (Prometheus/Grafana)    1.5GB RAM 20GB
#   db            (MySQL 8.0)             2GB   RAM 20GB
#   log-indexer   (Splunk Enterprise)     2GB   RAM 20GB
#
# Ubuntu 24.04 template: ubuntu-24.04-standard_24.04-2_amd64.tar.zst
# (confirmed available on local storage in the pre-session check)

set -euo pipefail

TEMPLATE="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
BRIDGE="vmbr0"
GW="${GATEWAY_IP}"
DNS="${GATEWAY_IP}"
STORAGE="local-lvm"

declare -A CT_CONFIG=(
  [730]="legacy-app:${LEGACY_HOST}:1536:20"
  [731]="container-app:${CONTAINER_HOST}:1536:20"
  [732]="lb:${LB_HOST}:512:10"
  [733]="monitor:${MONITOR_HOST}:1536:20"
  [734]="db:${DB_HOST}:2048:20"
  [735]="log-indexer:${LOG_INDEXER_HOST}:2048:20"
)

# Verify none of the target IDs already exist
for CTID in "${!CT_CONFIG[@]}"; do
  if pct status "${CTID}" &>/dev/null; then
    echo "ERROR: CT ${CTID} already exists. Aborting."
    exit 1
  fi
done

echo "=== Creating lab LXC containers ==="

for CTID in $(echo "${!CT_CONFIG[@]}" | tr ' ' '\n' | sort); do
  IFS=: read -r HOSTNAME IP MEMORY DISK <<< "${CT_CONFIG[$CTID]}"
  echo ""
  echo "--- Creating CT ${CTID}: ${HOSTNAME} (${IP}, ${MEMORY}MB RAM, ${DISK}GB disk) ---"

  pct create "${CTID}" "${TEMPLATE}" \
    --hostname "${HOSTNAME}" \
    --memory "${MEMORY}" \
    --swap 512 \
    --cores 2 \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP}/24,gw=${GW}" \
    --nameserver "${DNS}" \
    --ostype ubuntu \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 0 \
    --tags "lab"

  pct start "${CTID}"
  sleep 3

  # Install base packages
  pct exec "${CTID}" -- bash -c "
    apt-get update -qq &&
    apt-get install -y -qq curl wget git socat ca-certificates &&
    echo 'Base packages installed on ${HOSTNAME}'
  "

  echo "CT ${CTID} (${HOSTNAME}) created and started at ${IP}"
done

echo ""
echo "=== All lab containers created ==="
echo ""
echo "LXC inventory:"
for CTID in $(echo "${!CT_CONFIG[@]}" | tr ' ' '\n' | sort); do
  IFS=: read -r HOSTNAME IP MEMORY DISK <<< "${CT_CONFIG[$CTID]}"
  printf "  CT %s  %-25s  %s\n" "${CTID}" "${HOSTNAME}" "${IP}"
done

echo ""
echo "Next: Configure the registry as insecure on LXCs that need Docker:"
echo "  pct exec ${CT_CONTAINER:-731} -- bash -c 'mkdir -p /etc/docker && echo {\"insecure-registries\":[\"${REGISTRY_HOST}\"]} > /etc/docker/daemon.json'"
echo ""
echo "Tear down: bash scripts/hypervisor-lxc-teardown.sh"
