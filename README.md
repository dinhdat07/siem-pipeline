# SIEM Pipeline

This repository is a data-engineering lab for a SIEM-style pipeline built around Kafka, Flink, Elasticsearch, Kibana, MinIO, and Apache Iceberg.

Implemented now:

- Phase 1 hot path: Kafka -> Kafka Connect -> Elasticsearch -> Kibana
- Phase 2 cold path: Kafka -> Flink SQL -> Iceberg -> MinIO
- Kafka remains the central event bus for both paths
- Flink still produces `siem.alerts` for the hot path only; Phase 3 detections are not implemented yet

More detail lives in `docs/architecture.md`, `docs/phase1-hot-path.md`, `docs/cold-path.md`, and `docs/roadmap.md`.

## Architecture

```text
Zeek raw logs ----> parser/replay ----> zeek.conn -----\
                                                        \
Snort raw logs ---> parser/replay ----> snort.alert ----> Kafka ----> Kafka Connect ----> Elasticsearch ----> Kibana
                                                        /   |
Flink SQL rules <--------------------------------------/    +----> Flink SQL cold path ----> Iceberg REST catalog ----> MinIO
   |                                                                                                 |
   +----> siem.alerts ----> Kafka Connect ----> Elasticsearch alerts index ----> Kibana              +----> future Trino queries
```

Key design decisions:

- Kafka is still the system boundary and fan-out point.
- The hot path is unchanged: Elasticsearch and Kibana remain the realtime investigation layer.
- The cold path uses an Iceberg REST catalog in front of object storage so the catalog contract can stay stable as the deployment grows.
- Cold data is stored as Parquet-backed Iceberg tables partitioned by `event_date` and `event_dataset`.
- The cold-path table keeps a shared normalized schema with nullable dataset-specific columns so Zeek and Snort can land in one table without breaking future schema evolution.

## Repository Layout

```text
.
|-- configs/
|   |-- elasticsearch/
|   |-- kafka/
|   |-- kafka-connect/
|   `-- trino/
|-- dashboards/
|-- data/
|-- docker/
|   |-- connect/
|   `-- flink/
|-- docs/
|   |-- architecture.md
|   |-- cold-path.md
|   |-- phase1-hot-path.md
|   `-- roadmap.md
|-- flink/
|   |-- sql/
|   |   `-- cold-path/
|   `-- usrlib/
|-- parser/
|-- scripts/
|   |-- bootstrap-hot-path.sh
|   |-- bootstrap-cold-path.sh
|   |-- run-cold-path.sh
|   |-- verify-cold-path.sh
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

Adjust ports, credentials, bucket names, or catalog settings in `.env` if needed.

## Start The Stack

Build and start Kafka, Flink, Elasticsearch, Kibana, Kafka Connect, MinIO, and the Iceberg REST catalog:

```bash
docker compose up -d --build
```

Default local endpoints:

- Kafka external bootstrap: `localhost:9092`
- Flink UI: `http://localhost:8081`
- Elasticsearch: `http://localhost:9200`
- Kibana: `http://localhost:5601`
- Kafka Connect: `http://localhost:8083`
- MinIO API: `http://localhost:9000`
- MinIO Console: `http://localhost:9001`
- Iceberg REST catalog: `http://localhost:8181`

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

## Run Flink Jobs

Phase 1 alert jobs still read Kafka and write `siem.alerts` back to Kafka:

```bash
docker exec flink-jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/sql/02_insert_high_priority_snort.sql
docker exec flink-jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/sql/03_insert_large_transfer_zeek.sql
```

Start the Phase 2 cold-path sink job:

```bash
bash scripts/run-cold-path.sh
```

That job:

1. ensures the MinIO warehouse bucket exists
2. creates the Iceberg catalog, namespace, and table if they are missing
3. creates Kafka source tables for `zeek.conn` and `snort.alert`
4. submits the streaming insert from Kafka into the Iceberg table

## Verify Phase 2

Run the cold-path verification helper:

```bash
bash scripts/verify-cold-path.sh
```

Useful manual checks:

```bash
curl http://localhost:8181/v1/config
curl http://localhost:8081/jobs
docker exec minio mc ls --recursive local/warehouse
```

Expected result:

- MinIO contains Iceberg metadata and Parquet data files under the warehouse bucket
- `siem.normalized_events` contains records from both `zeek.conn` and `snort.alert`
- The hot path still indexes events and alerts into Elasticsearch and Kibana as before

## Current Scope And Gaps

Implemented now:

- Kafka-based ingest and replay
- Elasticsearch/Kibana hot path
- Iceberg/MinIO cold path written by Flink SQL
- config-driven local deployment via `.env`
- a REST-catalog shape that can later be reused by Trino or a multi-node deployment

Not implemented yet:

- Phase 3 detection rules beyond the existing Phase 1 alert examples
- Trino as an active compose service
- production-grade checkpoint storage, HA catalog backing store, or autoscaling
- benchmarking and validation harness
