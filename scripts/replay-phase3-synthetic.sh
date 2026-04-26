#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

bash "$SCRIPT_DIR/replay-normalized-jsonl.sh" zeek.conn "$REPO_ROOT/data/test/phase3/zeek_conn_detections.jsonl"
bash "$SCRIPT_DIR/replay-normalized-jsonl.sh" snort.alert "$REPO_ROOT/data/test/phase3/snort_alert_detections.jsonl"
