# SIEM Pipeline

This repository is a data-engineering lab for a SIEM-style pipeline built around Kafka, Flink, Elasticsearch, Kibana, MinIO, and Apache Iceberg.

Implemented now:

- Phase 1 hot path: Kafka -> Kafka Connect -> Elasticsearch -> Kibana
- Phase 2 cold path: Kafka -> Flink SQL -> Iceberg -> MinIO
- Phase 3 detections: Kafka -> Flink SQL -> `siem.alerts`
- Phase 3.5 validation: staged smoke tests for infra, hot path, cold path, and detections
- Kafka remains the central event bus for all ingest, storage, and alerting paths

More detail lives in `docs/architecture.md`, `docs/cold-path.md`, `docs/flink-detections.md`, `docs/phase1-hot-path.md`, `docs/roadmap.md`, and `docs/validation-smoke-tests.md`.

## Architecture

```text
Zeek raw logs ----> parser/replay ----> zeek.conn -----\
                                                        \
Snort raw logs ---> parser/replay ----> snort.alert ----> Kafka ----> Kafka Connect ----> Elasticsearch ----> Kibana
                                                        /   |\
Flink SQL detections <---------------------------------/    | +----> Flink SQL cold path ----> Iceberg REST catalog ----> MinIO
   |                                                        |
   +----> siem.alerts --------------------------------------+----> future Trino queries / downstream consumers
```

Key design decisions:

- Kafka is the system boundary and fan-out point.
- Flink remains the main stream-processing and detection engine.
- Phase 3 keeps rule logic explainable and event-time driven instead of introducing ML or opaque scoring.
- The hot and cold paths remain intact while detections continue to emit alerts to Kafka topic `siem.alerts`.

## Repository Layout

```text
.
|-- configs/
|   |-- elasticsearch/
|   |-- flink/
|   |-- kafka/
|   |-- kafka-connect/
|   `-- trino/
|-- dashboards/
|-- data/
|   `-- test/
|-- docker/
|   |-- connect/
|   `-- flink/
|-- docs/
|   |-- architecture.md
|   |-- cold-path.md
|   |-- flink-detections.md
|   |-- phase1-hot-path.md
|   |-- roadmap.md
|   |-- validation-smoke-tests.md
|   `-- siem_alert_schema.md
|-- flink/
|   |-- sql/
|   |   |-- detections/
|   |   |-- cold-path/
|   |   `-- smoke/
|   `-- usrlib/
|-- parser/
|-- scripts/
|   |-- bootstrap-hot-path.sh
|   |-- bootstrap-cold-path.sh
|   |-- replay-normalized-jsonl.sh
|   |-- replay-phase3-synthetic.sh
|   |-- run-cold-path.sh
|   |-- run-flink-detections.sh
|   |-- smoke/
|   |-- verify-cold-path.sh
|   |-- verify-flink-detections.sh
|   `-- run-flink-sql.sh
|-- .env.example
`-- docker-compose.yml
```

## Prerequisites

- Docker Desktop or another Docker runtime
- Python 3.10+
- `pip`
- Bash shell to run `.sh` scripts on Windows, for example Git Bash or WSL

Install parser dependencies:

```bash
pip install -r parser/requirements.txt
```

Create a local environment file before starting the stack:

```bash
cp .env.example .env
```

Detection thresholds live in `configs/flink/detection-thresholds.env` and can be edited directly for the lab.

## RAM Guidance

Recommended Docker memory for the full stack:

- `8 GB` minimum for local validation
- `10-12 GB` is more reliable when Elasticsearch, Kafka Connect, Flink, MinIO, Iceberg REST, and Kibana are all running together
- below `8 GB`, prefer staged validation and stop services between stages

Heap and Flink process-memory defaults are intentionally conservative in `.env.example`:

- `ELASTICSEARCH_JAVA_OPTS=-Xms512m -Xmx512m`
- `KAFKA_CONNECT_HEAP_OPTS=-Xms256m -Xmx256m`
- `FLINK_JOBMANAGER_MEMORY=512m`
- `FLINK_TASKMANAGER_MEMORY=768m`

## Start The Stack

Full stack:

```bash
docker compose up -d --build
```

Low-resource staged startup:

```bash
docker compose up -d kafka
docker compose up -d kafka elasticsearch connect flink-jobmanager flink-taskmanager
docker compose up -d kafka minio minio-init iceberg-rest flink-jobmanager flink-taskmanager
docker compose up -d kafka elasticsearch kibana connect minio minio-init iceberg-rest flink-jobmanager flink-taskmanager
```

Those commands map to:

- `kafka` only: infrastructure and topic checks
- `kafka + elasticsearch + connect + flink`: hot-path validation
- `kafka + minio + iceberg-rest + flink`: cold-path validation
- full stack: dashboards plus end-to-end cross-checks

Default local endpoints:

- Kafka external bootstrap: `localhost:9092`
- Flink UI: `http://localhost:8081`
- Elasticsearch: `http://localhost:9200`
- Kibana: `http://localhost:5601`
- Kafka Connect: `http://localhost:8083`
- MinIO API: `http://localhost:9000`
- MinIO Console: `http://localhost:9001`
- Iceberg REST catalog: `http://localhost:8181`

## Phase 3.5 Validation

Phases 1-3 should be treated as complete only after the relevant smoke tests pass.

Staged smoke checks:

```bash
bash scripts/smoke/run_smoke_tests.sh infra
bash scripts/smoke/run_smoke_tests.sh hot
bash scripts/smoke/run_smoke_tests.sh cold
bash scripts/smoke/run_smoke_tests.sh detect
```

Full validation:

```bash
bash scripts/smoke/run_smoke_tests.sh full
```

If a low-RAM machine is slow but still healthy, raise the smoke wait budget instead of switching straight to the full stack:

```bash
SMOKE_WAIT_TIMEOUT_SEC=150 bash scripts/smoke/run_smoke_tests.sh hot
SMOKE_WAIT_TIMEOUT_SEC=150 bash scripts/smoke/run_smoke_tests.sh cold
```

What the smoke stages verify:

- `infra`
  - Docker engine is reachable
  - compose config parses
  - required stage services are reachable
- `hot`
  - Kafka topics exist
  - normalized Zeek and Snort smoke events reach Elasticsearch through Kafka Connect
  - a Flink detection emits an alert to `siem.alerts`
  - that alert reaches Elasticsearch through Kafka Connect
- `cold`
  - Kafka topics exist
  - the Iceberg catalog and table exist
  - a Flink cold-path job writes tiny smoke data into MinIO-backed Iceberg storage
  - object-level output is asserted, with row-count verification attempted when available
- `detect`
  - all six advanced detection rules emit their expected rule IDs into `siem.alerts`
  - alert indexing into Elasticsearch is also checked when the hot-path services are already running

More detail, expected rule IDs, and limitations are documented in `docs/validation-smoke-tests.md`.

## Bootstrap The Paths

Bootstrap the existing hot path:

```bash
bash scripts/bootstrap-hot-path.sh
```

Bootstrap the cold-path catalog, namespace, and Iceberg table:

```bash
bash scripts/bootstrap-cold-path.sh
```

## Replay Data Into Kafka

Replay Zeek connection logs:

```bash
python3 parser/replay_to_kafka.py --input data/raw/zeek/conn.log --topic zeek.conn --bootstrap-servers localhost:9092 --limit 1000 --interval-ms 50
```

Replay Snort alerts:

```bash
python3 parser/replay_snort_to_kafka.py --input-dir data/raw/snort-alert --topic snort.alert --bootstrap-servers localhost:9092 --limit 1000 --interval-ms 50
```

Replay the Phase 3 synthetic normalized test data:

```bash
bash scripts/replay-phase3-synthetic.sh
```

## Run Flink Jobs

Phase 1 sample rules still exist:

```bash
docker exec flink-jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/sql/02_insert_high_priority_snort.sql
docker exec flink-jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/sql/03_insert_large_transfer_zeek.sql
```

Start the Phase 2 cold-path sink job:

```bash
bash scripts/run-cold-path.sh
```

Start the Phase 3 detection jobs:

```bash
bash scripts/run-flink-detections.sh
```

That script submits six independent streaming detection jobs:

1. port scan from Zeek
2. top talkers from Zeek
3. possible exfiltration from Zeek
4. repeated critical Snort alerts
5. Snort-plus-Zeek correlation
6. suspicious service/protocol anomalies from Zeek

## Verify Alerts And Cold Storage

Verify the cold path:

```bash
bash scripts/verify-cold-path.sh
```

Verify detection alerts in Kafka and Elasticsearch:

```bash
bash scripts/verify-flink-detections.sh
```

Useful manual checks:

```bash
MSYS_NO_PATHCONV=1 docker exec flink-jobmanager /opt/flink/bin/flink list
curl http://localhost:8081/jobs/overview
curl http://localhost:9200/siem-alerts/_search?size=5\&sort=@timestamp:desc
curl http://localhost:8181/v1/config
MSYS_NO_PATHCONV=1 docker exec minio mc ls --recursive local/warehouse
```

The smoke tests are the preferred validation path for this repository. The older bootstrap and verify scripts remain useful for manual exploration.

## Phase 3 Rules At A Glance

- `04_detect_port_scan_zeek.sql`
  - detects one source IP hitting many ports or destination IPs in a short event-time window
- `05_detect_top_talkers_zeek.sql`
  - detects high-volume source or destination hosts over a tumbling window
- `06_detect_possible_exfiltration_zeek.sql`
  - detects sustained outbound bytes from internal to external IPs using an RFC1918 placeholder
- `07_detect_repeated_critical_snort.sql`
  - detects repeated high-severity Snort alerts from one source IP in a hop window
- `08_detect_snort_zeek_correlation.sql`
  - correlates critical Snort alerts with later high-byte Zeek traffic from the same source IP
- `09_detect_protocol_anomalies_zeek.sql`
  - flags explainable service or protocol anomalies such as null service with high bytes or HTTP on unexpected ports

## Current Scope And Gaps

Implemented now:

- Kafka-based ingest and replay
- Elasticsearch/Kibana hot path
- Iceberg/MinIO cold path written by Flink SQL
- advanced event-time Flink detections writing to `siem.alerts`
- synthetic validation data for Phase 3 rule checks
- staged smoke tests and low-RAM validation guidance

Not implemented yet:

- Phase 4 reproducibility work beyond the current helper scripts
- Trino as an active compose service
- production-grade checkpoint storage, HA catalog backing store, or autoscaling
- Phase 5 benchmarking and stress validation
