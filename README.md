# SIEM Pipeline

This repository is a data-engineering lab for a SIEM-style pipeline built around Kafka, Flink, Elasticsearch, and Kibana.

The repository now implements phase 1 of the roadmap:

- normalized Zeek and Snort events are replayed into Kafka
- Kafka remains the central event bus
- Kafka Connect indexes normalized events into Elasticsearch
- Flink consumes Kafka topics and produces `siem.alerts`
- Kafka Connect also indexes `siem.alerts` into a dedicated alerts index
- Kibana dashboards and saved searches provide basic investigation views

Phases 2-5 are planned but not implemented yet. See [docs/roadmap.md](/mnt/e/coding/learn%20data/data%20engineering/siem-pipeline/docs/roadmap.md).

## Phase 1 Architecture

```text
Zeek raw logs ----> parser/replay ----> zeek.conn -----\
                                                        \
Snort raw logs ---> parser/replay ----> snort.alert ----> Kafka ----> Kafka Connect ----> Elasticsearch ----> Kibana
                                                        /
Flink SQL <--------------------------------------------/
   |
   +----> siem.alerts ----> Kafka Connect ----> Elasticsearch alerts index ----> Kibana
```

Key design decisions for phase 1:

- Kafka is the system boundary. Elasticsearch is a hot search sink, not the event bus.
- Normalized events from `zeek.conn` and `snort.alert` are indexed into one events index pattern: `siem-events-*`.
- Flink keeps generating alerts into Kafka topic `siem.alerts`; that same payload is also indexed into `siem-alerts-*`.
- Kafka Connect is used for Elasticsearch indexing so Flink stays focused on stream processing and alert generation.

More detail lives in [docs/phase1-hot-path.md](/mnt/e/coding/learn%20data/data%20engineering/siem-pipeline/docs/phase1-hot-path.md).

## Repository Layout

```text
.
|-- configs/
|   |-- elasticsearch/
|   |   `-- templates/
|   |-- kafka/
|   |   `-- topics.env
|   `-- kafka-connect/
|-- dashboards/
|   `-- siem-phase1.ndjson
|-- data/
|   |-- raw/
|   `-- sample/
|-- docker/
|   `-- connect/
|-- docs/
|   |-- phase1-hot-path.md
|   |-- roadmap.md
|   |-- siem_alert_schema.md
|   |-- sample-data.md
|   |-- snort_alert_schema.md
|   `-- zeek_conn_schema.md
|-- flink/
|   |-- sql/
|   `-- usrlib/
|-- parser/
|-- scripts/
|   |-- bootstrap-elasticsearch.sh
|   |-- bootstrap-hot-path.sh
|   |-- create-kafka-topics.sh
|   |-- import-kibana-saved-objects.sh
|   |-- register-kafka-connectors.sh
|   `-- download-flink-kafka-connector.sh
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

## Start The Stack

Start Kafka, Flink, Elasticsearch, Kibana, and Kafka Connect:

```bash
docker compose up -d --build
```

The local endpoints are:

- Kafka external bootstrap: `localhost:9092`
- Flink UI: `http://localhost:8081`
- Elasticsearch: `http://localhost:9200`
- Kibana: `http://localhost:5601`
- Kafka Connect: `http://localhost:8083`

## Bootstrap Phase 1

After the stack is healthy, bootstrap topics, Elasticsearch templates and aliases, Kafka Connect sinks, and Kibana saved objects:

```bash
bash scripts/bootstrap-hot-path.sh
```

What this does:

1. creates Kafka source topics, `siem.alerts`, Kafka Connect internal topics, and the connector DLQ topic
2. installs Elasticsearch index templates for events and alerts
3. creates `siem-events-000001` and `siem-alerts-000001` with write aliases `siem-events` and `siem-alerts`
4. registers the Kafka Connect Elasticsearch sink connectors
5. imports the Kibana data views, saved searches, and dashboards

If you want to run the bootstrap steps individually:

```bash
bash scripts/create-kafka-topics.sh
bash scripts/bootstrap-elasticsearch.sh
bash scripts/register-kafka-connectors.sh
bash scripts/import-kibana-saved-objects.sh
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

## Run Flink Rules

Download the Kafka connector jar once:

```bash
bash scripts/download-flink-kafka-connector.sh
```

Run the current phase 1 Flink jobs:

```bash
docker exec flink-jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/sql/02_insert_high_priority_snort.sql
```

Optional second rule:

```bash
docker exec flink-jobmanager /opt/flink/bin/sql-client.sh -f /opt/flink/sql/03_insert_large_transfer_zeek.sql
```

The current Flink jobs read from Kafka and write alerts back to Kafka topic `siem.alerts`. Kafka Connect then indexes those alerts into Elasticsearch.

## Verify Phase 1

Kafka topic checks:

```bash
docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic zeek.conn --from-beginning --max-messages 5 --timeout-ms 10000
docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic snort.alert --from-beginning --max-messages 5 --timeout-ms 10000
docker exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic siem.alerts --from-beginning --max-messages 5 --timeout-ms 10000
```

Elasticsearch checks:

```bash
curl http://localhost:9200/_cat/indices/siem-events-*?v
curl http://localhost:9200/_cat/indices/siem-alerts-*?v
curl http://localhost:9200/siem-events/_search?q=event.dataset:zeek.conn&size=3
curl http://localhost:9200/siem-alerts/_search?q=event.kind:alert&size=3
```

Kafka Connect checks:

```bash
curl http://localhost:8083/connectors
curl http://localhost:8083/connectors/siem-events-sink/status
curl http://localhost:8083/connectors/siem-alerts-sink/status
```

Kibana checks:

- open `http://localhost:5601`
- confirm the imported dashboards exist
- open `SIEM Overview`
- open `SIEM Alerts`
- open `Alert Investigation Workflow`
- the dashboards should open on the sample data time range automatically (`2012-03-16T07:00:00Z` to `2012-03-16T13:00:00Z`)

Expected result:

- `zeek.conn` and `snort.alert` documents appear in `siem-events-*`
- `siem.alerts` documents appear in `siem-alerts-*`
- Kibana dashboards render event volume, alert severity/rules, top IPs, top talkers, and timeline views without `Invalid visualization type "bar"` errors
- you can pivot from an alert to related raw events by filtering on `source.ip`, `destination.ip`, and time range

## Schemas

- Zeek connection schema: [docs/zeek_conn_schema.md](/mnt/e/coding/learn%20data/data%20engineering/siem-pipeline/docs/zeek_conn_schema.md)
- Snort alert schema: [docs/snort_alert_schema.md](/mnt/e/coding/learn%20data/data%20engineering/siem-pipeline/docs/snort_alert_schema.md)
- Canonical SIEM alert schema: [docs/siem_alert_schema.md](/mnt/e/coding/learn%20data/data%20engineering/siem-pipeline/docs/siem_alert_schema.md)

## Current Scope And Gaps

Implemented now:

- Kafka-based ingest and replay
- phase 1 Elasticsearch and Kibana hot path
- Kafka Connect sinks for events and alerts
- simple Flink-generated alerts written to Kafka and indexed for investigation

Not implemented yet:

- MinIO and Iceberg cold storage
- advanced SIEM detection logic
- one-command end-to-end reproducible lab bootstrap for all later phases
- benchmarking and validation harness
