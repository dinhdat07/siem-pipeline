# Sample Data Guide

This guide explains how to generate small development datasets from the raw Zeek and Snort sources used by this repository.

Related schema docs:

- `docs/zeek_conn_schema.md`
- `docs/snort_alert_schema.md`

The repository currently uses this layout:

```text
data/
|-- raw/
|   |-- snort-alert/
|   |   `-- alert.full.maccdc2012_*.pcap
|   `-- zeek/
|       `-- conn.log
`-- sample/
    |-- conn-logs/
    |   `-- zeek_conn_sample.jsonl
    `-- snort-alerts/
        `-- snort_alerts_sample.jsonl
```

## Requirements

- Python 3.10+
- Dependencies from `parser/requirements.txt`

Install dependencies:

```bash
pip install -r parser/requirements.txt
```

## Data Sources

This repo is organized around the MACCDC 2012 lab datasets.

- Zeek connection log: `data/raw/zeek/conn.log`
- Snort full alert logs: `data/raw/snort-alert/alert.full.maccdc2012_*.pcap`

Important note:

- Files named `alert.full.*.pcap` in this dataset are Snort alert logs in text format, not packet-capture files.

## Generate A 10k Zeek Sample

Zeek parsing lives in `parser/zeek_conn_parser.py` and can be run directly:

```bash
python parser/zeek_conn_parser.py --input data/raw/zeek/conn.log --output data/sample/conn-logs/zeek_conn_sample.jsonl --limit 10000
```

Output:

- `data/sample/conn-logs/zeek_conn_sample.jsonl`
- event schema: `docs/zeek_conn_schema.md`

## Generate A 10k Snort Sample

Snort parsing logic lives in `parser/snort_alert_parser.py` and can be run directly:

```bash
python parser/snort_alert_parser.py --input-dir data/raw/snort-alert --output data/sample/snort-alerts/snort_alerts_sample.jsonl --limit 10000
```

Output:

- `data/sample/snort-alerts/snort_alerts_sample.jsonl`
- event schema: `docs/snort_alert_schema.md`

## Replay To Kafka

Replay Zeek raw logs into Kafka:

```bash
python parser/replay_to_kafka.py --input data/raw/zeek/conn.log --topic zeek.conn --bootstrap-servers localhost:9092 --limit 1000
```

Replay Snort raw alerts into Kafka:

```bash
python parser/replay_snort_to_kafka.py --input-dir data/raw/snort-alert --topic snort.alert --bootstrap-servers localhost:9092 --limit 1000
```

## Output Format

Both generated datasets are written as JSON Lines (`.jsonl`):

- one event per line
- UTF-8 text
- suitable for replay, indexing, or downstream enrichment experiments

Field naming is ECS-inspired, but not a complete ECS implementation.

The checked-in sample files may lag behind the latest parser fields after refactors. When schema accuracy matters, treat the parser modules and schema docs as the source of truth, then regenerate samples if needed.

## Development Notes

- Use `--limit` or equivalent sampling during development because the raw datasets are large.
- Validate transformations on `data/sample/` before replaying or indexing larger volumes.
- Re-run sample generation after parser changes so sample files stay aligned with the documented schema.
- If disk usage matters, sample outputs can be compressed separately after generation.
- Raw input data should stay outside version control; this repo already ignores `data/raw/`.
