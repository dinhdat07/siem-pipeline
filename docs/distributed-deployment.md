# Distributed Deployment Runbook

This runbook promotes the local SIEM demo into a 3-node Tailscale deployment.

## Cluster Layout

| Node | Tailscale IP | Roles |
|---|---:|---|
| `dvm-sgp-02` | `100.76.241.30` | Kafka, Elasticsearch, Flink JobManager, PostgreSQL, MinIO, Iceberg REST, Kibana, control scripts |
| `dvm-sgp-01` | `100.123.190.84` | Kafka, Elasticsearch, Kafka Connect, Flink TaskManager |
| `dvm-sgp-03` | `100.90.64.86` | Kafka, Elasticsearch, Kafka Connect, Flink TaskManager |

The deployment uses Docker Compose per node and SSH from `dvm-sgp-02`.

## First Deploy

```bash
cd /root/siem-pipeline
bash deploy/distributed/siemctl.sh sync
bash deploy/distributed/siemctl.sh tune
bash deploy/distributed/siemctl.sh up
bash deploy/distributed/siemctl.sh bootstrap
bash deploy/distributed/siemctl.sh validate
```

`deploy/distributed/siemctl.sh tune` is intentionally separate because it restarts Docker on every node. It raises `nofile`, keeps `vm.max_map_count=1048576`, and enables Docker service limits required by Elasticsearch and Kafka.

## Daily Operations

```bash
bash deploy/distributed/siemctl.sh status
bash deploy/distributed/siemctl.sh logs dvm-sgp-01 connect
bash deploy/distributed/siemctl.sh validate
bash deploy/distributed/siemctl.sh down
```

## Distributed Benchmark

Safe benchmark sequence for the current hardware is:

```bash
bash deploy/distributed/siemctl.sh benchmark distributed-1m
bash deploy/distributed/siemctl.sh benchmark distributed-3m
bash deploy/distributed/siemctl.sh benchmark-es-nodes distributed-1m
```

`distributed-1m` is the apples-to-apples baseline. `distributed-3m` is the recommended headline run for this 6-vCPU/24GB cluster. Larger runs can push PostgreSQL temp files, ES disk watermarks, or swap and should be treated as stress tests only.

Benchmark outputs are written under `benchmark/results/<run-id>/`. Each distributed run also writes `es-vs-postgres-showcase.md` with ES/PG latency ratios for SIEM search workflows.

## Distributed Demo

Use the distributed demo runner from the control node:

```bash
cd /root/siem-pipeline
bash scripts/demo/demo.sh full
bash scripts/demo/run_distributed_demo.sh hot
bash scripts/demo/run_distributed_demo.sh cold
bash scripts/demo/run_distributed_demo.sh detect
```

`scripts/demo/demo.sh full` is the recommended lecturer-facing flow. It resets stale SIEM demo state, pauses between stages, prints short talking points for each screen, keeps the cold-path job running long enough to show Flink and MinIO, then stops it before starting detection so the 4-slot lab does not run out of resources.

The runner is intentionally sequential on the current 3-node lab:

- `hot` verifies Kafka -> Connect -> Elasticsearch.
- `cold` verifies Kafka -> Flink -> Iceberg/MinIO.
- `detect` verifies one Flink detection rule at a time so the cluster does not run out of slots.

By default `detect` verifies `phase4-demo-detect-protocol-anomaly`, which is the most reliable smoke rule on the current hardware and datasets. If you want to try extra rules manually, set `DEMO_DETECTION_INDEXES` to a comma-separated list such as:

```bash
DEMO_DETECTION_INDEXES=0,4,5 bash scripts/demo/run_distributed_demo.sh detect
```

Index mapping:

- `0` = port scan
- `1` = top talker
- `2` = possible exfiltration
- `3` = repeated critical Snort
- `4` = Snort/Zeek correlation
- `5` = protocol anomaly

Windowed rules need enough event-time progress to close their windows. The bundled distributed smoke flow therefore defaults to protocol anomaly instead of trying to force all six rules at once.

## Important Defaults

- Kafka topics use 12 partitions, replication factor 3, and minimum ISR 2.
- Elasticsearch benchmark indices use 3 primary shards and 1 replica.
- Kafka Connect runs as a distributed worker group on `dvm-sgp-01` and `dvm-sgp-03`.
- Flink checkpoints and savepoints use MinIO: `s3://warehouse/flink/...`.
- Iceberg REST uses PostgreSQL catalog metadata instead of local SQLite.

## Troubleshooting

- If Elasticsearch reports disk flood-stage blocks, free disk or lower benchmark size before clearing index blocks.
- If Kafka topics show under-replicated partitions, check all three Kafka containers and Tailscale reachability.
- If Connect tasks stay failed, inspect `bash deploy/distributed/siemctl.sh logs dvm-sgp-01 connect` and verify `ELASTICSEARCH_CONNECT_URL` reaches all ES nodes.
- If Flink TaskManagers do not register, verify ports `6123`, `6124`, `6121`, and `6122` over Tailscale.
