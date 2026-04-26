#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

STAGE="${1:-infra}"

require_smoke_commands
ensure_docker_ready
check_compose_config

case "$STAGE" in
  infra|core)
    maybe_start_services kafka
    wait_for_container kafka "Kafka broker"
    ;;
  hot)
    maybe_start_services kafka elasticsearch connect flink-jobmanager flink-taskmanager
    wait_for_container kafka "Kafka broker"
    wait_for_http_service "$ELASTICSEARCH_URL" "Elasticsearch"
    wait_for_http_service "$CONNECT_URL/connectors" "Kafka Connect"
    wait_for_http_service "$FLINK_REST_URL/overview" "Flink REST API"
    ;;
  cold)
    maybe_start_services kafka minio minio-init iceberg-rest flink-jobmanager flink-taskmanager
    wait_for_container kafka "Kafka broker"
    wait_for_container minio "MinIO"
    wait_for_http_service "$ICEBERG_REST_URL" "Iceberg REST catalog"
    wait_for_http_service "$FLINK_REST_URL/overview" "Flink REST API"
    ;;
  detect|detection)
    maybe_start_services kafka flink-jobmanager flink-taskmanager
    wait_for_container kafka "Kafka broker"
    wait_for_http_service "$FLINK_REST_URL/overview" "Flink REST API"
    ;;
  full)
    maybe_start_services kafka elasticsearch kibana connect minio minio-init iceberg-rest flink-jobmanager flink-taskmanager
    wait_for_container kafka "Kafka broker"
    wait_for_http_service "$ELASTICSEARCH_URL" "Elasticsearch"
    wait_for_http_service "$CONNECT_URL/connectors" "Kafka Connect"
    wait_for_http_service "http://localhost:${KIBANA_PORT:-5601}/api/status" "Kibana"
    wait_for_container minio "MinIO"
    wait_for_http_service "$ICEBERG_REST_URL" "Iceberg REST catalog"
    wait_for_http_service "$FLINK_REST_URL/overview" "Flink REST API"
    ;;
  *)
    smoke_fail "unknown stage '$STAGE' (expected infra, hot, cold, detect, or full)"
    ;;
esac

smoke_pass "Infrastructure checks passed for stage '$STAGE'"
