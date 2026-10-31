#!/bin/bash
# setup_node_exporter.sh — installs node_exporter 1.8.2 on an Ubuntu 24.04 CT.
# Run on each target CT: 730 (legacy-app), 731 (container-app), 732 (lb),
#   733 (monitor), 734 (db), 735 (log-indexer).
# CT IDs above are examples from .env.example; substitute your own values.
# Pin: sha256 verified against the official checksum file.
#
# Usage: pct exec <CTID> -- bash < setup_node_exporter.sh

set -euo pipefail

NODE_EXPORTER_VERSION="1.8.2"
NODE_EXPORTER_ARCHIVE="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_ARCHIVE}"
# sha256 from https://github.com/prometheus/node_exporter/releases/download/v1.8.2/sha256sums.txt
NODE_EXPORTER_SHA256="6809dd0b3ec45fd6e992c19071d6b5253aed3ead7bf0686885a51d85c6643c66"

echo "==> Downloading node_exporter ${NODE_EXPORTER_VERSION}"
cd /tmp
curl -fsSL -o "${NODE_EXPORTER_ARCHIVE}" "${NODE_EXPORTER_URL}"

echo "==> Verifying sha256"
echo "${NODE_EXPORTER_SHA256}  ${NODE_EXPORTER_ARCHIVE}" | sha256sum -c -

echo "==> Installing"
tar -xzf "${NODE_EXPORTER_ARCHIVE}"
install -m 755 "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/node_exporter
rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64" "${NODE_EXPORTER_ARCHIVE}"

echo "==> Creating systemd unit"
cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/node_exporter \
  --collector.disable-defaults \
  --collector.cpu \
  --collector.meminfo \
  --collector.diskstats \
  --collector.filesystem \
  --collector.netdev \
  --collector.netstat \
  --collector.loadavg \
  --collector.uname \
  --web.listen-address=:9100
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter
sleep 2
curl -sf http://localhost:9100/metrics | grep -c '^node_' || echo "WARN: no node_ metrics yet"
echo "==> node_exporter running on :9100"
