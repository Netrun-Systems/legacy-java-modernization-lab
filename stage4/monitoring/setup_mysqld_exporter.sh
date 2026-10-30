#!/bin/bash
# setup_mysqld_exporter.sh — installs mysqld_exporter 0.15.1 on the db host.
# Creates a least-privilege MySQL exporter user.
# Password is written to /etc/.mysqld_exporter.cnf (mode 600, root-owned).
# The cnf path is gitignored — add it to .gitignore if not already present.
#
# Pre-requisite: MySQL 8.4 running (Stage 4 base), root password in secrets.yaml.
# Usage: pct exec ${CT_DB:-733} -- bash < setup_mysqld_exporter.sh

set -euo pipefail

MYSQLD_EXPORTER_VERSION="0.15.1"
MYSQLD_EXPORTER_ARCHIVE="mysqld_exporter-${MYSQLD_EXPORTER_VERSION}.linux-amd64.tar.gz"
MYSQLD_EXPORTER_URL="https://github.com/prometheus/mysqld_exporter/releases/download/v${MYSQLD_EXPORTER_VERSION}/${MYSQLD_EXPORTER_ARCHIVE}"
# sha256 from https://github.com/prometheus/mysqld_exporter/releases/download/v0.15.1/sha256sums.txt
MYSQLD_EXPORTER_SHA256="c5c1ba0e3fc1b4f3c0e86dfdb9f3893e0a8ccfcf17e4c3ffc0f0d5cf0a1f7cf6"

echo "==> Downloading mysqld_exporter ${MYSQLD_EXPORTER_VERSION}"
cd /tmp
curl -fsSL -o "${MYSQLD_EXPORTER_ARCHIVE}" "${MYSQLD_EXPORTER_URL}"

echo "==> Verifying sha256"
echo "${MYSQLD_EXPORTER_SHA256}  ${MYSQLD_EXPORTER_ARCHIVE}" | sha256sum -c - || {
  echo "ERROR: sha256 mismatch — aborting"
  rm -f "/tmp/${MYSQLD_EXPORTER_ARCHIVE}"
  exit 1
}

echo "==> Installing"
tar -xzf "${MYSQLD_EXPORTER_ARCHIVE}"
install -m 755 "mysqld_exporter-${MYSQLD_EXPORTER_VERSION}.linux-amd64/mysqld_exporter" /usr/local/bin/mysqld_exporter
rm -rf "mysqld_exporter-${MYSQLD_EXPORTER_VERSION}.linux-amd64" "${MYSQLD_EXPORTER_ARCHIVE}"

echo "==> Generating exporter password"
EXPORTER_PASS=$(openssl rand -base64 18 | tr -d '=+/')
echo "Password length: ${#EXPORTER_PASS}"

echo "==> Creating MySQL least-privilege exporter user"
mysql -u root -e "
CREATE USER IF NOT EXISTS 'exporter'@'localhost'
  IDENTIFIED BY '${EXPORTER_PASS}'
  WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'localhost';
GRANT SELECT ON performance_schema.* TO 'exporter'@'localhost';
FLUSH PRIVILEGES;
"

echo "==> Writing credentials to /etc/.mysqld_exporter.cnf"
cat > /etc/.mysqld_exporter.cnf << EOF
[client]
user=exporter
password=${EXPORTER_PASS}
host=localhost
port=3306
EOF
chmod 600 /etc/.mysqld_exporter.cnf
chown root:root /etc/.mysqld_exporter.cnf

echo "==> Creating systemd unit"
cat > /etc/systemd/system/mysqld_exporter.service << 'EOF2'
[Unit]
Description=Prometheus MySQL Exporter
After=mysql.service
Requires=mysql.service

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/mysqld_exporter \
  --config.my-cnf=/etc/.mysqld_exporter.cnf \
  --web.listen-address=:9104 \
  --collect.global_status \
  --collect.global_variables \
  --collect.info_schema.tables \
  --collect.slave_status \
  --no-collect.info_schema.processlist
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF2

systemctl daemon-reload
systemctl enable mysqld_exporter
systemctl start mysqld_exporter
sleep 2
curl -sf http://localhost:9104/metrics | grep '^mysql_up' || echo "WARN: mysql_up metric not visible yet"
echo "==> mysqld_exporter running on :9104"
