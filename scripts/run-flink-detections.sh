#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_repo_env "$REPO_ROOT"
load_optional_env_file "$REPO_ROOT/configs/flink/detection-thresholds.env"

RULES=(
  "$REPO_ROOT/flink/sql/detections/04_detect_port_scan_zeek.sql"
  "$REPO_ROOT/flink/sql/detections/05_detect_top_talkers_zeek.sql"
  "$REPO_ROOT/flink/sql/detections/06_detect_possible_exfiltration_zeek.sql"
  "$REPO_ROOT/flink/sql/detections/07_detect_repeated_critical_snort.sql"
  "$REPO_ROOT/flink/sql/detections/08_detect_snort_zeek_correlation.sql"
  "$REPO_ROOT/flink/sql/detections/09_detect_protocol_anomalies_zeek.sql"
)

BASE_SQL="$REPO_ROOT/flink/sql/detections/00_create_detection_base.sql"

for rule in "${RULES[@]}"; do
  log_info "Submitting detection job: $(basename "$rule")"
  bash "$SCRIPT_DIR/run-flink-sql.sh" "$BASE_SQL" "$rule"
done

log_info "Phase 3 Flink detection jobs submitted"
