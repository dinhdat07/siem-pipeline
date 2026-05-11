#!/usr/bin/env bash
set -euo pipefail

LIMITS_FILE=/etc/security/limits.d/99-siem-pipeline.conf
SYSCTL_FILE=/etc/sysctl.d/99-siem-pipeline.conf
SYSTEMD_DIR=/etc/systemd/system/docker.service.d
SYSTEMD_FILE=$SYSTEMD_DIR/99-siem-pipeline-limits.conf

if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] Run as root" >&2
  exit 1
fi

cat > "$SYSCTL_FILE" <<'EOF'
vm.max_map_count=1048576
fs.file-max=9223372036854775807
EOF
sysctl --system >/dev/null

cat > "$LIMITS_FILE" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

mkdir -p "$SYSTEMD_DIR"
cat > "$SYSTEMD_FILE" <<'EOF'
[Service]
LimitNOFILE=1048576
LimitMEMLOCK=infinity
EOF

systemctl daemon-reload
if systemctl is-active --quiet docker; then
  systemctl restart docker
fi

echo "[INFO] Host tuned for SIEM distributed workload"
echo "[INFO] vm.max_map_count=$(sysctl -n vm.max_map_count)"
echo "[INFO] current shell nofile=$(ulimit -n)"
