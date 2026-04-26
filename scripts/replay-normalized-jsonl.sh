#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_repo_env "$REPO_ROOT"
require_command docker

if [ "$#" -ne 2 ]; then
  log_error "usage: $0 <topic> <jsonl-file>"
  exit 1
fi

TOPIC="$1"
INPUT_FILE="$2"
KAFKA_CONTAINER="${KAFKA_CONTAINER:-kafka}"
BOOTSTRAP_SERVER="${KAFKA_BOOTSTRAP_SERVERS_INTERNAL:-kafka:29092}"
KAFKA_PRODUCER_BIN="${KAFKA_PRODUCER_BIN:-/opt/kafka/bin/kafka-console-producer.sh}"

if [ ! -f "$INPUT_FILE" ]; then
  log_error "missing input file: $INPUT_FILE"
  exit 1
fi

log_info "Replaying normalized JSONL from $INPUT_FILE into topic $TOPIC"
MSYS_NO_PATHCONV=1 docker exec -i "$KAFKA_CONTAINER" "$KAFKA_PRODUCER_BIN" --bootstrap-server "$BOOTSTRAP_SERVER" --topic "$TOPIC" < "$INPUT_FILE"
