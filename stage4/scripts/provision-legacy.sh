#!/usr/bin/env bash
# Run on legacy-app AFTER Temurin 21 JDK is installed.
# Installs Jetty 9.4, deploys petclinic.war, starts the systemd service.
# Implements what petclinic::legacy Puppet class would manage.
set -euo pipefail

JETTY_VER="9.4.58.v20250814"
MAVEN_CENTRAL="https://repo.maven.apache.org/maven2"
INSTALL_DIR="/opt/petclinic-legacy"
JETTY_HOME="${INSTALL_DIR}/jetty-home-${JETTY_VER}"
JETTY_BASE="${INSTALL_DIR}/base"
RUN_USER="petclinic"
WAR_SOURCE="${1:-http://${HYPERVISOR_HOST}:8082/petclinic.war}"   # served by Python on the hypervisor host

# --- User and dirs ---
id -u "$RUN_USER" &>/dev/null || useradd -r -s /sbin/nologin "$RUN_USER"
mkdir -p "$INSTALL_DIR"
chown "$RUN_USER" "$INSTALL_DIR"

# --- Jetty 9.4 ---
if [ ! -d "$JETTY_HOME" ]; then
  curl -fsSL -o /tmp/jetty.tgz \
    "${MAVEN_CENTRAL}/org/eclipse/jetty/jetty-home/${JETTY_VER}/jetty-home-${JETTY_VER}.tar.gz"
  tar xzf /tmp/jetty.tgz -C "$INSTALL_DIR"
  chown -R "$RUN_USER" "$JETTY_HOME"
  rm /tmp/jetty.tgz
  echo "Jetty $JETTY_VER extracted"
fi

# --- Base ---
if [ ! -d "${JETTY_BASE}/start.d" ]; then
  sudo -u "$RUN_USER" \
    java -jar "${JETTY_HOME}/start.jar" \
      --jetty.base="$JETTY_BASE" \
      --add-to-start=http,deploy,jsp,jstl,annotations 2>&1 | grep -v "^$" || true
  echo "Jetty base initialised"
fi

# --- Deploy WAR ---
WAR_DEST="${JETTY_BASE}/webapps/petclinic.war"
if [ ! -f "$WAR_DEST" ]; then
  curl -fsSL -o "$WAR_DEST" "$WAR_SOURCE"
  chown "$RUN_USER" "$WAR_DEST"
  echo "WAR deployed from $WAR_SOURCE"
fi

# --- systemd unit ---
cat > /etc/systemd/system/petclinic-legacy.service <<EOF
[Unit]
Description=PetClinic — Jetty 9.4 legacy
After=network.target

[Service]
User=${RUN_USER}
WorkingDirectory=${JETTY_BASE}
ExecStart=/usr/bin/java \\
  -Djetty.base=${JETTY_BASE} \\
  -Djetty.port=8080 \\
  -Dspring.datasource.url=jdbc:mysql://${DB_HOST}:3306/petclinic \\
  -Dspring.datasource.username=petclinic \\
  -Dspring.datasource.password=petclinic \\
  -jar ${JETTY_HOME}/start.jar
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable petclinic-legacy
systemctl restart petclinic-legacy
systemctl status petclinic-legacy --no-pager | head -5
echo "=== Jetty 9.4 service started on port 8080 ==="
