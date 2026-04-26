#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

load_repo_env "$REPO_ROOT"
require_command curl
require_command docker

ALERT_RULE_FILTER="${1:-}"
KAFKA_ALERTS_TOPIC="${KAFKA_ALERTS_TOPIC:-siem.alerts}"
ES_ALERTS_URL="${ELASTICSEARCH_URL:-http://localhost:9200}/siem-alerts/_search?size=20&sort=@timestamp:desc"

log_info "Recent Kafka alerts"
docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic "$KAFKA_ALERTS_TOPIC" \
  --from-beginning \
  --max-messages 20 \
  --timeout-ms 10000

log_info "Recent Elasticsearch alerts"
if [ -n "$ALERT_RULE_FILTER" ]; then
  curl -s -H 'Content-Type: application/json' "$ES_ALERTS_URL" -d "{\"query\":{\"term\":{\"rule.id\":\"$ALERT_RULE_FILTER\"}}}"
else
  curl -s "$ES_ALERTS_URL"
fi
