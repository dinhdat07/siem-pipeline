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

JOBMANAGER_CONTAINER="${FLINK_JOBMANAGER_CONTAINER:-flink-jobmanager}"
FLINK_UI_URL="${FLINK_UI_URL:-http://localhost:${FLINK_UI_PORT:-8081}/overview}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-180}"
WAIT_INTERVAL_SEC="${WAIT_INTERVAL_SEC:-3}"

if [ "$#" -lt 1 ]; then
  log_error "usage: $0 <sql-file> [sql-file ...]"
  exit 1
fi

if ! docker container inspect "$JOBMANAGER_CONTAINER" >/dev/null 2>&1; then
  log_error "Flink JobManager container not found: $JOBMANAGER_CONTAINER"
  log_error "start the stack first with: docker compose up -d --build"
  exit 1
fi

wait_for_http "$FLINK_UI_URL" "$WAIT_TIMEOUT_SEC" "$WAIT_INTERVAL_SEC" "Flink UI"

GENERATED_DIR="$REPO_ROOT/flink/sql/.generated"
mkdir -p "$GENERATED_DIR"
GENERATED_FILE="$GENERATED_DIR/run-$(date +%s)-$$.sql"
GENERATED_FILE_CONTAINER="/opt/flink/sql/.generated/$(basename "$GENERATED_FILE")"
OUTPUT_FILE="$GENERATED_DIR/run-$(date +%s)-$$.out"

trap 'rm -f "$GENERATED_FILE" "$OUTPUT_FILE"' EXIT

"$PYTHON_BIN" - "$@" > "$GENERATED_FILE" <<'PY'
import os
import sys
from pathlib import Path

for file_path in sys.argv[1:]:
    path = Path(file_path)
    print(f"-- Begin {path}")
    print(os.path.expandvars(path.read_text(encoding='utf-8')))
    print(f"-- End {path}")
PY

MSYS_NO_PATHCONV=1 docker exec "$JOBMANAGER_CONTAINER" /opt/flink/bin/sql-client.sh -f "$GENERATED_FILE_CONTAINER" 2>&1 | tee "$OUTPUT_FILE"

if grep -Eq '\[ERROR\]|Could not execute SQL statement' "$OUTPUT_FILE"; then
  log_error "Flink SQL execution reported an error"
  exit 1
fi
