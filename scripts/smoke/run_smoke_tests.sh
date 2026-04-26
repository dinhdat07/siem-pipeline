#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET="${1:-infra}"

case "$TARGET" in
  infra|core)
    bash "$SCRIPT_DIR/01_check_infra.sh" infra
    ;;
  hot)
    bash "$SCRIPT_DIR/01_check_infra.sh" hot
    bash "$SCRIPT_DIR/02_verify_kafka_topics.sh"
    bash "$SCRIPT_DIR/03_verify_hot_path.sh"
    ;;
  cold)
    bash "$SCRIPT_DIR/01_check_infra.sh" cold
    bash "$SCRIPT_DIR/02_verify_kafka_topics.sh"
    bash "$SCRIPT_DIR/04_verify_cold_path.sh"
    ;;
  detect|detection)
    bash "$SCRIPT_DIR/01_check_infra.sh" detect
    bash "$SCRIPT_DIR/02_verify_kafka_topics.sh"
    bash "$SCRIPT_DIR/05_verify_detections.sh"
    ;;
  full|all)
    bash "$SCRIPT_DIR/01_check_infra.sh" full
    bash "$SCRIPT_DIR/02_verify_kafka_topics.sh"
    bash "$SCRIPT_DIR/03_verify_hot_path.sh"
    bash "$SCRIPT_DIR/04_verify_cold_path.sh"
    bash "$SCRIPT_DIR/05_verify_detections.sh"
    ;;
  *)
    echo "usage: $0 [infra|hot|cold|detect|full]" >&2
    exit 1
    ;;
esac
