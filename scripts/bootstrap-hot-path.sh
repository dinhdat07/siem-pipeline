#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/create-kafka-topics.sh"
bash "$SCRIPT_DIR/bootstrap-elasticsearch.sh"
bash "$SCRIPT_DIR/register-kafka-connectors.sh"
bash "$SCRIPT_DIR/import-kibana-saved-objects.sh"

echo "[INFO] Phase 1 hot path bootstrap completed"
