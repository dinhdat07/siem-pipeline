#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_repo_env "$REPO_ROOT"
require_command docker
require_command curl
PYTHON_BIN="$(resolve_python_bin)"

MINIO_CONTAINER="${MINIO_CONTAINER:-minio}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-password}"
MINIO_WAREHOUSE_BUCKET="${MINIO_WAREHOUSE_BUCKET:-warehouse}"
ICEBERG_REST_BASE="${ICEBERG_REST_URI_HOST:-http://localhost:8181}"
ICEBERG_REST_URL="${ICEBERG_REST_URL:-$ICEBERG_REST_BASE/v1/config}"
ICEBERG_NAMESPACE="${ICEBERG_NAMESPACE:-siem}"
ICEBERG_TABLE="${ICEBERG_TABLE:-normalized_events}"
TABLE_METADATA_URL="${ICEBERG_REST_BASE}/v1/namespaces/${ICEBERG_NAMESPACE}/tables/${ICEBERG_TABLE}"
VERIFY_COLD_PATH_USE_FLINK_SQL="${VERIFY_COLD_PATH_USE_FLINK_SQL:-0}"
TABLE_METADATA_FILE="$(mktemp)"

trap 'rm -f "$TABLE_METADATA_FILE"' EXIT

wait_for_http "$ICEBERG_REST_URL" 180 3 "Iceberg REST catalog"

log_info "Listing Iceberg warehouse objects from MinIO"
MSYS_NO_PATHCONV=1 docker exec "$MINIO_CONTAINER" /bin/sh -lc "
  mc alias set local http://127.0.0.1:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null &&
  mc ls --recursive 'local/$MINIO_WAREHOUSE_BUCKET'
"

log_info "Reading Iceberg table metadata from REST catalog"
curl -fsS "$TABLE_METADATA_URL" > "$TABLE_METADATA_FILE"
"$PYTHON_BIN" - "$TABLE_METADATA_FILE" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
metadata_location = payload["metadata-location"]
metadata = payload["metadata"]
snapshots = metadata.get("snapshots", [])
current_snapshot_id = metadata.get("current-snapshot-id")
current_snapshot = next(
    (snapshot for snapshot in snapshots if snapshot.get("snapshot-id") == current_snapshot_id),
    snapshots[-1] if snapshots else None,
)
current_summary = current_snapshot.get("summary", {}) if current_snapshot else {}

def fmt_ts(timestamp_ms):
    if not timestamp_ms:
        return "n/a"
    dt = datetime.fromtimestamp(timestamp_ms / 1000, tz=timezone.utc)
    return dt.isoformat()

print(f"[INFO] Iceberg table: {metadata.get('location', 'n/a')}")
print(f"[INFO] Metadata file: {metadata_location}")
print(f"[INFO] Current snapshot: {current_snapshot_id or 'n/a'}")
print(f"[INFO] Total records: {current_summary.get('total-records', 'n/a')}")
print(f"[INFO] Total data files: {current_summary.get('total-data-files', 'n/a')}")
print(f"[INFO] Total files size bytes: {current_summary.get('total-files-size', 'n/a')}")
print("[INFO] Snapshot history:")

for snapshot in snapshots:
    summary = snapshot.get("summary", {})
    print(
        "[INFO] "
        f"  snapshot_id={snapshot.get('snapshot-id')} "
        f"committed_at={fmt_ts(snapshot.get('timestamp-ms'))} "
        f"operation={summary.get('operation', 'n/a')} "
        f"added_records={summary.get('added-records', '0')} "
        f"total_records={summary.get('total-records', 'n/a')}"
    )
PY

if ! is_truthy "$VERIFY_COLD_PATH_USE_FLINK_SQL"; then
  log_info "Skipping Flink SQL verification by default to avoid blocking when the demo cluster has no free slots"
  log_info "Set VERIFY_COLD_PATH_USE_FLINK_SQL=1 to run SQL-based verification as an extra check"
  exit 0
fi

free_slots="$(
  curl -fsS "${FLINK_UI_URL:-http://localhost:${FLINK_UI_PORT:-8081}}/taskmanagers" | \
    "$PYTHON_BIN" -c 'import json,sys; data=json.load(sys.stdin); print(sum(tm.get("freeSlots", 0) for tm in data.get("taskmanagers", [])))'
)"

if [ "${free_slots:-0}" -lt 1 ]; then
  log_warn "Skipping Flink SQL verification because the cluster has no free slots"
  log_warn "Run after stopping some streaming jobs, or increase FLINK_TASK_SLOTS / taskmanager capacity for ad-hoc SQL"
  exit 0
fi

log_info "Running optional Flink SQL verification"
bash "$SCRIPT_DIR/run-flink-sql.sh" "$REPO_ROOT/flink/sql/cold-path/90_verify_iceberg_events.sql"
