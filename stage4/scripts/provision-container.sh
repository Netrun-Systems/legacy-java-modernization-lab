#!/usr/bin/env bash
# Run on container-app AFTER Docker is installed.
# Pulls the pinned image digest and runs it as a systemd container service.
# Implements what petclinic::container Puppet class would manage.
set -euo pipefail

REGISTRY="${REGISTRY_HOST}"
IMAGE_NAME="petclinic"
IMAGE_DIGEST="sha256:f1a2edaec14300cd4e3cd29966c7248ef5f7de024bf12e71e79ef1e4af30203d"
IMAGE_REF="${REGISTRY}/${IMAGE_NAME}@${IMAGE_DIGEST}"

# --- Pull image by digest ---
echo "Pulling ${IMAGE_REF} ..."
docker pull "${IMAGE_REF}"
echo "Pull complete"

# --- Stop old container if running ---
docker rm -f petclinic 2>/dev/null || true

# --- systemd unit ---
cat > /etc/systemd/system/petclinic-container.service <<EOF
[Unit]
Description=PetClinic — Jetty 12.1 container
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/docker run --rm --name petclinic \\
  -p 8080:8080 \\
  -e JDBC_DRIVER_CLASS=com.mysql.cj.jdbc.Driver \\
  -e "JDBC_URL=jdbc:mysql://${DB_HOST}:3306/petclinic?useUnicode=true&characterEncoding=UTF-8&useSSL=false&allowPublicKeyRetrieval=true" \\
  -e "JDBC_USER=${JDBC_USER:-petclinic}" \\
  -e "JDBC_PASSWORD=${JDBC_PASSWORD}" \\
  -e DB_SCRIPT=mysql \\
  -e JPA_DATABASE=MYSQL \\
  ${IMAGE_REF}
ExecStop=/usr/bin/docker stop petclinic
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable petclinic-container
systemctl restart petclinic-container
sleep 3
systemctl status petclinic-container --no-pager | head -6
echo "=== Container service started — image digest pinned ==="
docker inspect petclinic --format='Running digest: {{.Image}}' 2>/dev/null || \
  echo "Container starting..."
