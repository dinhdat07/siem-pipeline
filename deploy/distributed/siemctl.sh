#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMON_ENV="$SCRIPT_DIR/env/common.env"
# shellcheck disable=SC1090
set -a; . "$COMMON_ENV"; set +a

NODES=(dvm-sgp-02 dvm-sgp-01 dvm-sgp-03)

declare -A NODE_IP=(
  [dvm-sgp-02]="$SIEM_NODE_1_IP"
  [dvm-sgp-01]="$SIEM_NODE_2_IP"
  [dvm-sgp-03]="$SIEM_NODE_3_IP"
)

SSH_KEY="${SIEM_SSH_KEY:-/root/.ssh/siem_pipeline_ed25519}"
SSH_USER="${SIEM_SSH_USER:-root}"
REMOTE_ROOT="${SIEM_REMOTE_ROOT:-/root/siem-pipeline}"
COMPOSE_FILE="deploy/distributed/docker-compose.yml"
CONTROL_NODE="${SIEM_CONTROL_NODE:-dvm-sgp-02}"

is_local_node() {
  [ "$1" = "$CONTROL_NODE" ]
}

ssh_cmd() {
  local node="$1"; shift
  if is_local_node "$node"; then
    bash -lc "$*"
    return 0
  fi
  ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@${NODE_IP[$node]}" "$@"
}

node_env_cmd() {
  local node="$1"
  cat <<EOF
cd '$REMOTE_ROOT' && set -a && . deploy/distributed/env/common.env && . deploy/distributed/env/$node.env && set +a
export ENV_FILE=/dev/null ENV_FILE_OVERRIDE=/dev/null
EOF
}

remote_compose() {
  local node="$1"; shift
  local prefix
  prefix="$(node_env_cmd "$node")"
  ssh_cmd "$node" "$prefix && docker compose -f '$COMPOSE_FILE' $*"
}

sync_node() {
  local node="$1"
  if is_local_node "$node"; then
    echo "[INFO] $node is the local control node; skipping sync"
    return 0
  fi
  echo "[INFO] Syncing repo to $node (${NODE_IP[$node]})"
  tar \
    --exclude='.git' \
    --exclude='benchmark/generated' \
    --exclude='benchmark/results/*' \
    --exclude='parser/__pycache__' \
    --exclude='**/__pycache__' \
    -C "$REPO_ROOT" -czf - . | \
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_USER@${NODE_IP[$node]}" \
      "mkdir -p '$REMOTE_ROOT' && tar -xzf - -C '$REMOTE_ROOT'"
}

sync_all() {
  for node in "${NODES[@]}"; do
    sync_node "$node"
  done
}

tune_all() {
  sync_all
  for node in "${NODES[@]}"; do
    echo "[INFO] Tuning host $node"
    ssh_cmd "$node" "bash '$REMOTE_ROOT/deploy/distributed/scripts/host-tune.sh'"
  done
}

up_all() {
  if [ "${SIEM_SKIP_PREFLIGHT:-0}" != "1" ]; then
    preflight
  fi
  sync_all
  for node in "${NODES[@]}"; do
    echo "[INFO] Starting $node"
    remote_compose "$node" "up -d --build"
  done
}

down_all() {
  for node in "${NODES[@]}"; do
    echo "[INFO] Stopping $node"
    remote_compose "$node" "down --remove-orphans" || true
  done
}

status_all() {
  for node in "${NODES[@]}"; do
    echo "== $node (${NODE_IP[$node]}) =="
    ssh_cmd "$node" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
  done
}

preflight() {
  local ports=(
    "${KAFKA_BROKER_PORT:-19092}"
    "${KAFKA_CONTROLLER_PORT:-19093}"
    "${ELASTICSEARCH_HTTP_PORT:-19200}"
    "${ELASTICSEARCH_TRANSPORT_PORT:-19300}"
    "${KIBANA_PORT:-15601}"
    "${KAFKA_CONNECT_PORT:-18083}"
    "${FLINK_UI_PORT:-18081}"
    "${FLINK_JOBMANAGER_RPC_PORT:-16123}"
    "${FLINK_BLOB_PORT:-16124}"
    "${FLINK_TASKMANAGER_DATA_PORT:-16121}"
    "${FLINK_TASKMANAGER_RPC_PORT:-16122}"
    "${MINIO_API_PORT:-19000}"
    "${MINIO_CONSOLE_PORT:-19001}"
    "${ICEBERG_REST_PORT:-18181}"
    "${POSTGRES_PORT:-15432}"
  )
  local node port port_regex conflicts
  port_regex="$(IFS='|'; echo "${ports[*]}")"

  for node in "${NODES[@]}"; do
    echo "== preflight $node (${NODE_IP[$node]}) =="
    conflicts="$(
      ssh_cmd "$node" "ss -ltnH | tr -s ' ' | cut -d' ' -f4 | grep -E ':($port_regex)$' || true"
    )"
    if [ -n "$conflicts" ]; then
      echo "[ERROR] SIEM side-by-side ports are already in use on $node:" >&2
      echo "$conflicts" >&2
      exit 1
    fi
    echo "[OK] no SIEM port conflicts"
  done
}

logs_node() {
  local node="${1:-dvm-sgp-02}"
  shift || true
  remote_compose "$node" "logs --tail=200 $*"
}

bootstrap() {
  local prefix
  prefix="$(node_env_cmd dvm-sgp-02)"
  ssh_cmd dvm-sgp-02 "$prefix && KAFKA_TOPICS_ENV_FILE=deploy/distributed/configs/kafka/topics.env bash scripts/create-kafka-topics.sh"
  ssh_cmd dvm-sgp-02 "$prefix && bash scripts/bootstrap-elasticsearch.sh"
  ssh_cmd dvm-sgp-02 "$prefix && CONNECTOR_CONFIG_DIR=deploy/distributed/configs/kafka-connect bash scripts/register-kafka-connectors.sh"
  ssh_cmd dvm-sgp-02 "$prefix && bash scripts/bootstrap-cold-path.sh"
}

validate() {
  local prefix
  prefix="$(node_env_cmd dvm-sgp-02)"
  echo "[INFO] Kafka brokers"
  ssh_cmd dvm-sgp-02 "$prefix && docker exec '${KAFKA_CONTAINER:-siem-kafka}' /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server '$KAFKA_BOOTSTRAP_SERVERS_HOST' | grep -E 'id:|usable' || true"
  echo "[INFO] Kafka topics"
  ssh_cmd dvm-sgp-02 "$prefix && docker exec '${KAFKA_CONTAINER:-siem-kafka}' /opt/kafka/bin/kafka-topics.sh --bootstrap-server '$KAFKA_BOOTSTRAP_SERVERS_HOST' --describe | egrep 'Topic: (zeek.conn|snort.alert|siem.alerts|connect-|siem.connect.dlq)|ReplicationFactor|Isr'"
  echo "[INFO] Elasticsearch cluster"
  curl -fsS "$ELASTICSEARCH_URL/_cluster/health?pretty"
  curl -fsS "$ELASTICSEARCH_URL/_cat/nodes?v"
  echo "[INFO] Connect cluster"
  curl -fsS "$CONNECT_URL/connectors?expand=status&expand=info" | python3 -m json.tool | sed -n '1,220p'
  echo "[INFO] Flink overview"
  curl -fsS "$FLINK_REST_URL/overview" | python3 -m json.tool
  echo "[INFO] Iceberg REST"
  curl -fsS "$ICEBERG_REST_URI_HOST/v1/config" | python3 -m json.tool | sed -n '1,120p'
}

benchmark() {
  local size="${1:-distributed-1m}"
  local prefix
  prefix="$(node_env_cmd dvm-sgp-02)"
  ssh_cmd dvm-sgp-02 "$prefix && bash scripts/benchmark/run_distributed_showcase.sh '$size'"
}

benchmark_es_nodes() {
  local size="${1:-distributed-1m}"
  local prefix
  prefix="$(node_env_cmd dvm-sgp-02)"
  ssh_cmd dvm-sgp-02 "$prefix && bash scripts/benchmark/run_es_node_scaling.sh '$size'"
}

usage() {
  cat <<USAGE
usage: $0 <command> [args]

commands:
  sync                 copy repo to all nodes
  tune                 apply host sysctl/limits tuning on all nodes and restart Docker
  up                   sync and start distributed services on all nodes
  down                 stop distributed services on all nodes
  status               show containers on all nodes
  preflight            check side-by-side SIEM ports before starting
  logs [node] [svc]    show compose logs from a node
  bootstrap            create topics/templates/connectors/cold catalog from control node
  validate             validate distributed Kafka/ES/Connect/Flink/Iceberg health
  benchmark [size]     run distributed benchmark from control node; default distributed-1m
  benchmark-es-nodes [size]
                      run ES-only node scalability benchmark from control node; default distributed-1m
USAGE
}

cmd="${1:-}"
shift || true
case "$cmd" in
  sync) sync_all ;;
  tune) tune_all ;;
  up) up_all ;;
  down) down_all ;;
  status) status_all ;;
  preflight) preflight ;;
  logs) logs_node "$@" ;;
  bootstrap) bootstrap ;;
  validate) validate ;;
  benchmark) benchmark "$@" ;;
  benchmark-es-nodes) benchmark_es_nodes "$@" ;;
  *) usage; exit 1 ;;
esac
