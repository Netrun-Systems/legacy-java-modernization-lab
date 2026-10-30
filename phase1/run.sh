#!/usr/bin/env bash
# Run phase1-jetty12-ee8.sh inside eclipse-temurin:21-jdk-noble (no host JDK needed).
# First real run of this script; report results honestly.
# Usage: bash phase1/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/work"
mkdir -p "${WORK_DIR}"

echo "=== Phase 1: Running inside eclipse-temurin:21-jdk-noble container ==="
echo "    Work dir: ${WORK_DIR}"
echo "    Ports: 8094 (Jetty 9.4), 8012 (Jetty 12.1)"
echo ""

docker run --rm \
  --name pj-phase1 \
  -v "${SCRIPT_DIR}:/phase1:ro" \
  -v "${WORK_DIR}:/root/legacy-java-modernization-lab/phase1" \
  -e WORK=/root/legacy-java-modernization-lab/phase1 \
  -p 8094:8094 \
  -p 8012:8012 \
  eclipse-temurin:21-jdk-noble \
  bash -c "
    set -euo pipefail
    echo '--- Installing git and curl ---'
    apt-get update -qq && apt-get install -y -qq git curl 2>/dev/null
    echo '--- Launching phase1 script ---'
    bash /phase1/phase1-jetty12-ee8.sh
    echo ''
    echo '--- Phase 1 complete. Results above. ---'
  "
