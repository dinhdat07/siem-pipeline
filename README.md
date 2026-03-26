# SIEM Pipeline

This repository is a data-engineering lab for a SIEM-style pipeline built around Kafka, Zeek connection logs, and Snort alert logs.

The current scope is:

- parse raw Zeek `conn.log` into ECS-like JSON events
- parse raw Snort full alert logs into JSONL
- replay Zeek connection events into Kafka for downstream ingestion experiments
- replay Snort alert events into Kafka for downstream ingestion experiments

It is not yet a full end-to-end SIEM stack. There is no consumer, search backend, dashboard, or detection layer in this repo yet.

## Architecture

Current data flow:

1. Raw datasets live under `data/raw/`.
2. Parsers normalize events into JSONL under `data/sample/`.
3. Kafka runs locally through Docker Compose.
4. Zeek connection logs can be replayed into Kafka topic `zeek.conn`.

Main event types:

- `zeek.conn`: normalized network connection events
- `snort.alert`: normalized IDS alert events

## Repository Layout

```text
.
|-- configs/
|   `-- kafka/
|       `-- topics.env
|-- data/
|   |-- raw/
|   |   |-- snort-alert/
|   |   `-- zeek/
|   `-- sample/
|       |-- conn-logs/
|       `-- snort-alerts/
|-- docs/
|   |-- sample-data.md
|   |-- snort_alert_schema.md
|   `-- zeek_conn_schema.md
|-- parser/
|   |-- replay_snort_to_kafka.py
|   |-- replay_to_kafka.py
|   |-- requirements.txt
|   |-- snort_alert_parser.py
|   `-- zeek_conn_parser.py
|-- scripts/
|   `-- create-kafka-topics.sh
`-- docker-compose.yml
```

## Prerequisites

- Docker Desktop or another Docker runtime
- Python 3.10+
- pip
- Bash shell to run `.sh` scripts on Windows, for example Git Bash or WSL

Install Python dependencies:

```powershell
pip install -r parser/requirements.txt
```

## Kafka Setup

Start Kafka:

```powershell
docker compose up -d
```

This Compose file runs a single-node Kafka 4.x broker in KRaft mode.

Topic auto-creation is disabled, so create topics explicitly after the broker is up:

```powershell
bash scripts/create-kafka-topics.sh
```

The bootstrap script is compatible with the current `docker-compose.yml` because:

- the Kafka container name is `kafka`
- the script execs `/opt/kafka/bin/kafka-topics.sh` inside that container
- the broker listens on `localhost:9092` inside the container, which matches both the Compose healthcheck and `configs/kafka/topics.env`
- the script waits for readiness before creating topics
- it creates source topics for both `zeek.conn` and `snort.alert`, plus downstream `siem.alerts`

If you rename the container in Compose, override `KAFKA_CONTAINER` before running the script:

```powershell
$env:KAFKA_CONTAINER="your-container-name"
bash scripts/create-kafka-topics.sh
```

Topic names and defaults are documented in `configs/kafka/topics.env`.

## Generate Sample Data

Detailed instructions live in `docs/sample-data.md`.

Generate a 10,000-event Zeek sample:

```powershell
python parser/zeek_conn_parser.py --input data/raw/zeek/conn.log --output data/sample/conn-logs/zeek_conn_sample.jsonl --limit 10000
```

Generate a 10,000-event Snort sample:

```powershell
python parser/snort_alert_parser.py --input-dir data/raw/snort-alert --output data/sample/snort-alerts/snort_alerts_sample.jsonl --limit 10000
```

Snort parsing now runs directly from `parser/snort_alert_parser.py`.

Zeek parsing also runs directly from `parser/zeek_conn_parser.py`.

## Replay Zeek Events To Kafka

Replay Zeek connection logs into Kafka with a fixed interval:

```powershell
python parser/replay_to_kafka.py --input data/raw/zeek/conn.log --topic zeek.conn --bootstrap-servers localhost:9092 --limit 1000 --interval-ms 100
```

Replay using original event-time gaps:

```powershell
python parser/replay_to_kafka.py --input data/raw/zeek/conn.log --topic zeek.conn --bootstrap-servers localhost:9092 --limit 1000 --use-event-time
```

Replay Snort alert logs into Kafka:

```powershell
python parser/replay_snort_to_kafka.py --input-dir data/raw/snort-alert --topic snort.alert --bootstrap-servers localhost:9092 --limit 1000 --interval-ms 100
```

Replay Snort using original event-time gaps:

```powershell
python parser/replay_snort_to_kafka.py --input-dir data/raw/snort-alert --topic snort.alert --bootstrap-servers localhost:9092 --limit 1000 --use-event-time
```

## Schemas And Conventions

- Zeek connection schema: `docs/zeek_conn_schema.md`
- Snort alert schema: `docs/snort_alert_schema.md`
- Output format: JSON Lines (`.jsonl`)
- Field naming: ECS-inspired, not a full ECS implementation

Examples:

- Zeek sample output: `data/sample/conn-logs/zeek_conn_sample.jsonl`
- Snort sample output: `data/sample/snort-alerts/snort_alerts_sample.jsonl`

## Current Gaps

- no root test suite yet
- docs were previously written against an older `input/` and `output/` layout; this README reflects the current `data/raw/` and `data/sample/` structure
