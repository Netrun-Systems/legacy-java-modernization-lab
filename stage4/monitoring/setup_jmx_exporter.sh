#!/bin/bash
# setup_jmx_exporter.sh — installs jmx_prometheus_javaagent on a lab CT.
# Run on: legacy-app and container-app.
#
# jmx_prometheus_javaagent 1.0.1 is the latest stable release.
# The jar is placed at /opt/jmx/ which the templates reference.
# sha256 from Maven Central published checksums.
#
# Usage:



set -euo pipefail

JMX_VERSION="1.0.1"
JMX_JAR="jmx_prometheus_javaagent-${JMX_VERSION}.jar"
JMX_URL="https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_VERSION}/${JMX_JAR}"
# sha256 from Maven Central .sha256 file
# Verified 2026-10-30 against download from repo1.maven.org
JMX_SHA256="7d61f737fd661610ccc14aea79764faa1ea94a340cbc8f0029b3d2edea3d80c1"

echo "==> Creating /opt/jmx"
mkdir -p /opt/jmx

echo "==> Downloading jmx_prometheus_javaagent ${JMX_VERSION}"
cd /tmp
curl -fsSL -o "${JMX_JAR}" "${JMX_URL}"

echo "==> Verifying sha256"
echo "${JMX_SHA256}  ${JMX_JAR}" | sha256sum -c - || {
  echo "ERROR: sha256 mismatch — aborting"
  rm -f "/tmp/${JMX_JAR}"
  exit 1
}

echo "==> Installing jar"
install -m 644 "/tmp/${JMX_JAR}" /opt/jmx/jmx_prometheus_javaagent.jar
rm -f "/tmp/${JMX_JAR}"

echo "==> Writing JMX config"
cat > /opt/jmx/jmx_config.yml << 'EOF'
---
startDelaySeconds: 0
ssl: false
lowercaseOutputName: true
lowercaseOutputLabelNames: true
rules:
  - pattern: "java.lang<type=Memory><>(HeapMemoryUsage|NonHeapMemoryUsage): (.*)"
    name: jvm_memory_$1_bytes
    type: GAUGE
  - pattern: "java.lang<type=GarbageCollector, name=(.+)><CollectionTime>(.*)"
    name: jvm_gc_collection_seconds_total
    labels:
      gc: "$1"
    type: COUNTER
  - pattern: "java.lang<type=Threading><>(ThreadCount|DaemonThreadCount|PeakThreadCount)"
    name: jvm_threads_$1
    type: GAUGE
  - pattern: "org.eclipse.jetty.util.thread<type=queuedthreadpool, id=(.+)><>(threads|idleThreads|queueSize)"
    name: jetty_threadpool_$2
    labels:
      pool: "$1"
    type: GAUGE
  - pattern: ".*"
EOF

chmod 644 /opt/jmx/jmx_config.yml
ls -lh /opt/jmx/
echo "==> JMX exporter installed at /opt/jmx/"
echo "==> Agent string: -javaagent:/opt/jmx/jmx_prometheus_javaagent.jar=5556:/opt/jmx/jmx_config.yml"
