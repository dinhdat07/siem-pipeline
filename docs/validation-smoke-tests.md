# Phase 3.5 Validation And Smoke Tests

Phase 3.5 adds validation and stabilization around the existing SIEM pipeline so Phases 1-3 can be proven in a staged, low-resource way.

## Validation Goals

The smoke tests are designed to prove:

- Phase 1 hot path
  - normalized events can flow from Kafka through Kafka Connect into Elasticsearch
  - Flink-generated alerts can flow into Kafka topic `siem.alerts` and then into Elasticsearch
- Phase 2 cold path
  - Flink can write normalized events from Kafka into the Iceberg table on MinIO-backed object storage
- Phase 3 detections
  - all six advanced detection rules emit the expected alert rule IDs from a tiny synthetic dataset

The smoke tests are intentionally staged so low-RAM machines do not need the full stack up at once.

## What Is Verified

### `scripts/smoke/01_check_infra.sh`

- Docker engine is reachable
- `docker compose config` parses successfully
- the requested stage services are running or reachable

Supported stages:

- `infra`
- `hot`
- `cold`
- `detect`
- `full`

### `scripts/smoke/02_verify_kafka_topics.sh`

- required Kafka topics exist:
  - `zeek.conn`
  - `snort.alert`
  - `siem.alerts`
  - Kafka Connect internal topics
  - `siem.connect.dlq`

### `scripts/smoke/03_verify_hot_path.sh`

- bootstraps Elasticsearch templates and Kafka Connect sinks
- replays two tiny normalized smoke events:
  - one Zeek event that should index as a raw event and trigger one anomaly alert
  - one Snort event that should index as a raw event
- proves:
  - raw normalized events appear in `siem-events`
  - a Flink alert appears in Kafka topic `siem.alerts`
  - that alert appears in `siem-alerts`

Expected minimums:

- `siem-events`: `+2` documents
- `siem-alerts`: `+1` document
- Kafka alert rule ID:
  - `flink.zeek.protocol_anomaly`

### `scripts/smoke/04_verify_cold_path.sh`

- bootstraps the Iceberg catalog and table
- submits the cold-path Flink insert job in `latest-offset` mode
- replays two tiny normalized smoke events
- proves:
  - MinIO receives new Iceberg metadata or data objects
  - the Iceberg table remains queryable
  - row-count verification is attempted for the dedicated smoke-event prefix

Expected minimums:

- MinIO warehouse object count increases by at least `1`
- Iceberg smoke rows should increase by at least `2` when the batch verification query is available

### `scripts/smoke/05_verify_detections.sh`

- submits all six advanced detection jobs in `latest-offset` mode
- replays a tiny synthetic dataset from `data/test/phase35/detections/`
- proves `siem.alerts` receives at least one alert from each rule family

Expected Kafka alert rule IDs:

- `flink.zeek.port_scan`
- `flink.zeek.top_talker`
- `flink.zeek.possible_exfiltration`
- `flink.snort.repeated_critical`
- `flink.snort_zeek.correlation`
- `flink.zeek.protocol_anomaly`

When Elasticsearch and Kafka Connect are already running, the same script also asserts that at least `6` new detection alerts are indexed into `siem-alerts`.

## What Is Not Verified

The smoke tests do not try to prove everything:

- Kibana dashboard rendering is not browser-tested
- parser correctness against the full raw MACCDC datasets is not revalidated here
- throughput, latency, or benchmark targets are not measured
- multi-node failover, HA catalog backing store, and production durability are not tested
- exact alert counts are not enforced for hop-window rules because overlapping windows can legitimately emit more than one alert per fixture set

That scope boundary is intentional. Phase 3.5 is validation and stabilization, not benchmarking or new feature work.

## How To Run

### Lowest-resource order

```bash
bash scripts/smoke/run_smoke_tests.sh infra
bash scripts/smoke/run_smoke_tests.sh hot
docker compose stop elasticsearch kibana connect
bash scripts/smoke/run_smoke_tests.sh cold
docker compose stop minio minio-init iceberg-rest
bash scripts/smoke/run_smoke_tests.sh detect
```

### Full validation

```bash
docker compose up -d --build
bash scripts/smoke/run_smoke_tests.sh full
```

### Slow startup override

If services are still starting but the host is simply slow, increase the smoke timeout instead of immediately falling back to the full stack:

```bash
SMOKE_WAIT_TIMEOUT_SEC=150 bash scripts/smoke/run_smoke_tests.sh hot
SMOKE_WAIT_TIMEOUT_SEC=150 bash scripts/smoke/run_smoke_tests.sh cold
SMOKE_WAIT_TIMEOUT_SEC=150 bash scripts/smoke/run_smoke_tests.sh detect
```

### Individual scripts

```bash
bash scripts/smoke/01_check_infra.sh hot
bash scripts/smoke/02_verify_kafka_topics.sh
bash scripts/smoke/03_verify_hot_path.sh
bash scripts/smoke/04_verify_cold_path.sh
bash scripts/smoke/05_verify_detections.sh
```

## Low-RAM Troubleshooting

Recommended Docker memory for the full stack is `8 GB` minimum. If the stack becomes unstable:

- run only one validation stage at a time
- stop unused services before starting the next stage
- keep Kibana stopped unless you are specifically checking the UI
- lower JVM and Flink process memory in `.env`
- avoid using the full raw datasets during smoke validation
- prune stale containers or volumes only when you are intentionally resetting the lab

Useful commands:

```bash
docker compose stop elasticsearch kibana connect
docker compose stop minio minio-init iceberg-rest
docker compose stop flink-jobmanager flink-taskmanager
docker compose ps
docker system prune
```

If you are on Windows, use a real POSIX shell such as Git Bash or WSL. Do not rely on `C:\Windows\System32\bash.exe` for these scripts.

If you run manual `docker exec` commands from Git Bash, prefix them with `MSYS_NO_PATHCONV=1` so container paths like `/opt/flink/...` are not rewritten into Windows host paths.

## Notes On Reruns

The smoke jobs are designed to be safe to rerun:

- topic creation uses `--if-not-exists`
- Elasticsearch bootstrap is idempotent
- Kafka Connect registration is an upsert
- smoke-owned Flink jobs are submitted with explicit pipeline names and cancelled on exit
- smoke Flink reads use `latest-offset` so the checks focus on fresh test input instead of replaying the full topic history
