#!/usr/bin/env bash
# End-to-end verification script for all lab stages.
# Prints HTTP status codes for each endpoint; PASS/FAIL each check.
# Run after bringing up all components.
set -euo pipefail

HAPROXY="${LB_HOST}"
LEGACY="${LEGACY_HOST}"
CONTAINER="${CONTAINER_HOST}"
REGISTRY="localhost:5000"
JENKINS="localhost:8080"
PORT="8080"
PASS=0
FAIL=0

check_http() {
  local DESC="$1"
  local URL="$2"
  local EXPECTED="${3:-200}"
  local STATUS
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "${URL}" 2>/dev/null || echo "000")
  if [[ "${STATUS}" == "${EXPECTED}" ]]; then
    printf "  PASS  %-40s  HTTP %s  %s\n" "${DESC}" "${STATUS}" "${URL}"
    ((PASS++))
  else
    printf "  FAIL  %-40s  HTTP %s (expected %s)  %s\n" "${DESC}" "${STATUS}" "${EXPECTED}" "${URL}"
    ((FAIL++))
  fi
}

echo ""
echo "=== legacy-java-modernization-lab End-to-End Verification ==="
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

echo "--- Stage 1: Phase 1 WAR builds (check logs, not live endpoints) ---"
echo "  (Phase 1 runs in a container — check phase1/run.sh output for HTTP 200)"
echo ""

echo "--- Stage 2: Direct app health checks ---"
check_http "legacy-app (Jetty 9.4) /petclinic/"      "http://${LEGACY}:${PORT}/petclinic/owners?lastName="
check_http "container-app (Jetty 12.1) /petclinic/"  "http://${CONTAINER}:${PORT}/petclinic/owners?lastName="
echo ""

echo "--- Stage 3: Jenkins and registry ---"
check_http "Jenkins UI"                               "http://${JENKINS}/login"
check_http "Registry catalog (plain HTTP)"            "http://${REGISTRY}/v2/_catalog"
echo ""

echo "--- Stage 4: HAProxy frontend ---"
check_http "HAProxy -> /petclinic/ (via LB)"         "http://${HAPROXY}/petclinic/owners?lastName="
check_http "HAProxy stats page"                       "http://${HAPROXY}:8404/stats" "200"
echo ""

echo "--- Stage 4: Parity check (same owner list from both backends) ---"
LEGACY_BODY=$(curl -s "http://${LEGACY}:${PORT}/petclinic/owners?lastName=" 2>/dev/null | wc -c)
CONTAINER_BODY=$(curl -s "http://${CONTAINER}:${PORT}/petclinic/owners?lastName=" 2>/dev/null | wc -c)
if [[ "${LEGACY_BODY}" -gt 100 && "${CONTAINER_BODY}" -gt 100 ]]; then
  DELTA=$(( LEGACY_BODY - CONTAINER_BODY ))
  if [[ "${DELTA#-}" -lt 500 ]]; then
    printf "  PASS  %-40s  legacy=%d bytes, container=%d bytes (delta=%d)\n" \
      "Response parity (size)" "${LEGACY_BODY}" "${CONTAINER_BODY}" "${DELTA}"
    ((PASS++))
  else
    printf "  FAIL  %-40s  legacy=%d bytes vs container=%d bytes (delta=%d > 500)\n" \
      "Response parity (size)" "${LEGACY_BODY}" "${CONTAINER_BODY}" "${DELTA}"
    ((FAIL++))
  fi
else
  printf "  FAIL  %-40s  one or both endpoints returned empty body\n" "Response parity"
  ((FAIL++))
fi
echo ""

echo "--- Stage 4: Weight flip test ---"
echo "  Current backend state (via HAProxy stats API):"
if STATS=$(curl -s "http://${HAPROXY}:8404/stats;csv" 2>/dev/null); then
  echo "${STATS}" | grep "petclinic,legacy-app\|petclinic,container-app" | \
    awk -F, '{printf "  %-20s weight=%-5s status=%s\n", $2, $20, $18}' || \
    echo "  (stats parse failed — check HAProxy CSV column order)"
else
  echo "  (HAProxy stats unreachable)"
fi
echo ""

echo "=== SUMMARY: ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]] && exit 0 || exit 1
