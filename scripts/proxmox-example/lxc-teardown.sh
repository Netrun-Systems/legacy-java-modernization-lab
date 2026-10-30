#!/usr/bin/env bash
# Tear down all lab LXC containers on the hypervisor host.
# Run from workstation: ssh root@${HYPERVISOR_HOST} "bash -s" < scripts/hypervisor-lxc-teardown.sh
set -euo pipefail

LAB_IDS="730 731 732 733 734 735"

echo "=== Tearing down lab LXC containers ==="
for CTID in ${LAB_IDS}; do
  if pct status "${CTID}" &>/dev/null; then
    echo "Stopping and destroying CT ${CTID}..."
    pct stop "${CTID}" --timeout 10 2>/dev/null || true
    pct destroy "${CTID}" --destroy-unreferenced-disks 1
    echo "CT ${CTID} destroyed."
  else
    echo "CT ${CTID} not found, skipping."
  fi
done
echo "=== Teardown complete ==="
