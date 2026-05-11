# References and Design Rationale

This document maps official references to the concrete implementation in this repository.
It is intended for report writing, thesis appendices, and lecturer review.

Version context used by this project:

- Apache Flink `1.19.x` via `deploy/distributed/env/common.env` and `docker/flink/Dockerfile`
- Apache Kafka `4.1.2` via `deploy/distributed/env/common.env`
- Elasticsearch and Kibana `8.17.3` via `deploy/distributed/env/common.env`
- Apache Iceberg `1.10.1` via `deploy/distributed/env/common.env`
- PostgreSQL `17-alpine` via `deploy/distributed/env/common.env`
- MinIO release family configured in `deploy/distributed/env/common.env`

When an official page is easier to cite from the "current" or "latest" documentation than from an older versioned page, this document says so explicitly.

## 1. Overall system architecture

- Official references
  - Apache Flink docs home: <https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/>
  - Apache Kafka Connect overview: <https://kafka.apache.org/41/kafka-connect/overview/>
  - Elasticsearch reference home: <https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html>
  - Apache Iceberg docs home: <https://iceberg.apache.org/docs/latest/>
  - MinIO object storage overview: <https://min.io/product/overview>
- Implemented in repo
  - `docs/architecture.md`
  - `docs/distributed-deployment.md`
  - `deploy/distributed/docker-compose.yml`
- What we derived from these references
  - Hot path is best separated as `Kafka -> Kafka Connect -> Elasticsearch -> Kibana`.
  - Detection path is best modeled as `Kafka -> Flink SQL -> Kafka topic -> Kafka Connect -> Elasticsearch`.
  - Cold path is best modeled as `Kafka -> Flink SQL -> Iceberg -> MinIO`.
  - This separation keeps stream processing, search/indexing, and lake storage loosely coupled and easier to scale independently.

## 2. Flink SQL event time, watermarks, and source idleness

- Official references
  - Flink `CREATE` statements and watermark definition: <https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/dev/table/sql/create/>
  - Flink table configuration, including `table.exec.source.idle-timeout` (current page, same concept used in this project): <https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/table/config/>
- Implemented in repo
  - `flink/sql/detections/00_create_detection_base.sql`
  - `docs/flink-detections.md`
- What we derived from these references
  - Detection logic must use event time, not wall-clock processing time, because SIEM events may arrive slightly late or out of order.
  - Watermarks are required so windowed detections know when to emit results.
  - `table.exec.source.idle-timeout` is important in a demo cluster because a quiet source can otherwise hold back watermarks and prevent windows from firing.
  - In this project, enabling source idleness is key to making all rule families emit reliably during staged demos and smoke datasets.

## 3. Flink SQL windowing with HOP and TUMBLE

- Official references
  - Flink Windowing TVF: <https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/dev/table/sql/queries/window-tvf/>
- Implemented in repo
  - `flink/sql/detections/04_detect_port_scan_zeek.sql`
  - `flink/sql/detections/05_detect_top_talkers_zeek.sql`
  - `flink/sql/detections/06_detect_possible_exfiltration_zeek.sql`
  - `flink/sql/detections/07_detect_repeated_critical_snort.sql`
- What we derived from these references
  - `HOP` windows are a good fit for overlapping threat-detection windows such as port scan, repeated alerts, and exfiltration.
  - `TUMBLE` windows are a good fit for clean periodic aggregation such as top talkers by bytes.
  - A single event may belong to multiple `HOP` windows, which explains why overlapping rule outputs can produce multiple alerts from the same event set.
  - This behavior is acceptable for SIEM use cases when alert reasoning includes the window boundaries.

## 4. Flink SQL interval joins for cross-stream correlation

- Official references
  - Flink SQL joins, including interval joins: <https://nightlies.apache.org/flink/flink-docs-master/docs/sql/reference/queries/joins/>
- Implemented in repo
  - `flink/sql/detections/08_detect_snort_zeek_correlation.sql`
  - `docs/flink-detections.md`
- What we derived from these references
  - Snort/Zeek correlation should be expressed as an interval join, not as a batch-style join.
  - The join must include both an equality condition and a bounded time condition.
  - For this project, `source.ip` is the simplest explainable join key for classroom demo and report writing.
  - Replay order matters in demos because the interval join is directional: Snort alert first, then unusual Zeek traffic.

## 5. Flink Kafka SQL connector and startup modes

- Official references
  - Flink Kafka SQL connector: <https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/connectors/table/kafka/>
- Implemented in repo
  - `flink/sql/detections/00_create_detection_base.sql`
  - `flink/sql/cold-path/04_create_kafka_sources.sql`
  - `scripts/demo/demo.sh`
- What we derived from these references
  - `scan.startup.mode` is operationally important, not cosmetic.
  - `latest-offset` is the correct default for clean demo runs because it prevents accidental re-consumption of old data.
  - Kafka tables in Flink SQL are sufficient for both event ingestion and alert emission in this project.
  - Kafka remains the central event bus for both hot path and detection path.

## 6. Kafka Connect distributed mode

- Official references
  - Kafka Connect overview: <https://kafka.apache.org/41/kafka-connect/overview/>
  - Kafka Connect user guide: <https://kafka.apache.org/41/kafka-connect/user-guide/>
  - Kafka Connect administration: <https://kafka.apache.org/41/kafka-connect/administration/>
- Implemented in repo
  - `deploy/distributed/docker-compose.yml`
  - `docs/distributed-deployment.md`
  - `scripts/register-kafka-connectors.sh`
- What we derived from these references
  - Connect should run as a distributed worker group on more than one node so sink tasks can survive worker loss and rebalance cleanly.
  - Internal topics for config, offsets, and status are not optional operational details; they are part of Connect reliability.
  - Keeping Connect on worker nodes instead of the control node reduces role concentration on the cluster head.
  - This architecture also keeps Elasticsearch indexing logic outside Flink, which makes pipeline responsibilities easier to explain.

## 7. Confluent Elasticsearch Sink Connector

- Official references
  - Connector overview: <https://docs.confluent.io/kafka-connectors/elasticsearch/current/overview.html>
  - Connector configuration options: <https://docs.confluent.io/kafka-connectors/elasticsearch/current/configuration_options.html>
- Implemented in repo
  - `configs/kafka-connect/siem-events-sink.json`
  - `configs/kafka-connect/siem-alerts-sink.json`
  - `configs/kafka-connect/siem-snort-events-sink.json`
- What we derived from these references
  - The Elasticsearch sink connector is a natural fit for decoupled indexing from Kafka topics.
  - DLQ configuration is important for resilience during schema drift or malformed records.
  - Alias-based routing is cleaner than hard-coding concrete index names into connector topic mappings.
  - Synchronous flushing and modest batch sizes are good tradeoffs for demo stability and benchmark repeatability on limited hardware.

## 8. Elasticsearch index templates and aliases

- Official references
  - Index templates: <https://www.elastic.co/guide/en/elasticsearch/reference/current/indices-templates.html>
  - Aliases: <https://www.elastic.co/guide/en/elasticsearch/reference/current/aliases.html>
- Implemented in repo
  - `configs/elasticsearch/templates/siem-events-template.json`
  - `configs/elasticsearch/templates/siem-alerts-template.json`
  - `scripts/bootstrap-elasticsearch.sh`
- What we derived from these references
  - Templates must be bootstrapped before indexing starts, otherwise Elasticsearch may infer field types incorrectly.
  - Write aliases let the pipeline target stable logical names such as `siem-events` and `siem-alerts` while the backing indices remain replaceable.
  - This pattern also makes the demo cleaner because dashboards and connectors can reference aliases instead of rotating physical indices.
  - Alias plus template bootstrap is one of the main reasons the hot path behaves predictably after reset.

## 9. Elasticsearch query and aggregation model

- Official references
  - Aggregations overview: <https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations.html>
  - Terms aggregation: <https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations-bucket-terms-aggregation.html>
  - Bool query: <https://www.elastic.co/guide/reference/query-dsl/bool-query/>
- Implemented in repo
  - `scripts/benchmark/benchmark_tool.py`
  - `docs/benchmark.md`
  - Kibana dashboards bootstrapped by `scripts/bootstrap-elasticsearch.sh`
- What we derived from these references
  - Elasticsearch is especially strong for SIEM-style filtering, faceting, top-N grouping, and exploratory drill-down.
  - Terms aggregations map directly to common SOC questions such as top talkers, top destination ports, and alert breakdowns by rule.
  - Bool queries fit the multi-condition SIEM search style better than plain single-field search.
  - These strengths explain why the benchmark story should emphasize filtering, aggregation, and investigation workflows rather than every possible full-text case.

## 10. Kibana saved objects and UI bootstrap

- Official references
  - Saved objects API group: <https://www.elastic.co/docs/api/doc/kibana/v8/group/endpoint-saved-objects>
  - Import saved objects API: <https://www.elastic.co/docs/api/doc/kibana/v8/operation/operation-importsavedobjectsdefault>
  - Saved objects guidance: <https://www.elastic.co/docs/extend/kibana/saved-objects>
- Implemented in repo
  - `scripts/bootstrap-elasticsearch.sh`
  - `docs/phase1-hot-path.md`
  - saved object payloads under Elasticsearch/Kibana bootstrap assets
- What we derived from these references
  - Saved objects should be imported through Kibana APIs, not by writing directly to `.kibana`.
  - Version compatibility matters for imports, so dashboard assets should track Kibana minor versions.
  - This project uses API-driven bootstrap so the UI can be recreated after reset without manual clicking.
  - That makes the demo reproducible and easier to grade.

## 11. Elastic Common Schema (ECS) normalization

- Official references
  - ECS field reference: <https://www.elastic.co/docs/reference/ecs/ecs-field-reference>
  - ECS base fields: <https://www.elastic.co/docs/reference/ecs/ecs-base>
  - ECS source fields: <https://www.elastic.co/docs/reference/ecs/ecs-source>
  - ECS categorization fields: <https://www.elastic.co/docs/reference/ecs/ecs-category-field-values-reference>
  - ECS usage of categorization fields: <https://www.elastic.co/docs/reference/ecs/ecs-using-categorization-fields>
- Implemented in repo
  - `docs/zeek_conn_schema.md`
  - `docs/snort_alert_schema.md`
  - `docs/siem_alert_schema.md`
  - `data/sample/conn-logs/zeek_conn_sample.jsonl`
  - `data/sample/snort-alerts/snort_alerts_sample.jsonl`
- What we derived from these references
  - ECS-like normalization is essential for mixing Zeek events, Snort alerts, and Flink-generated alerts in one search layer.
  - `@timestamp`, `message`, `source.*`, `destination.*`, and `event.*` fields are the core interoperability layer.
  - `event.kind`, `event.category`, `event.type`, and `event.dataset` make dashboards and filtering much easier to standardize.
  - This normalization is also what makes cross-source correlation explainable in both SQL and Kibana.

## 12. Iceberg REST catalog

- Official references
  - REST Catalog Spec: <https://iceberg.apache.org/rest-catalog-spec/>
  - Iceberg configuration docs: <https://iceberg.apache.org/docs/latest/configuration/>
- Implemented in repo
  - `flink/sql/cold-path/01_create_iceberg_catalog.sql`
  - `deploy/distributed/docker-compose.yml`
  - `docker/iceberg-rest/Dockerfile`
- What we derived from these references
  - REST catalog is a portability choice, not only a convenience choice.
  - It decouples compute engines from catalog implementation details and makes future multi-engine access easier.
  - In this project, it also helps move from local demo behavior toward a more production-like distributed layout.
  - Replacing embedded metadata with PostgreSQL-backed catalog metadata is a meaningful improvement over a purely local fixture setup.

## 13. Iceberg Flink DDL and streaming writes

- Official references
  - Flink DDL for Iceberg: <https://iceberg.apache.org/docs/latest/flink-ddl/>
  - Flink writes for Iceberg: <https://iceberg.apache.org/docs/latest/docs/flink-writes/>
- Implemented in repo
  - `flink/sql/cold-path/01_create_iceberg_catalog.sql`
  - `flink/sql/cold-path/03_create_iceberg_tables.sql`
  - `flink/sql/cold-path/05_insert_normalized_events.sql`
  - `docs/cold-path.md`
- What we derived from these references
  - `INSERT INTO` is the right pattern for streaming append into the normalized event table.
  - Iceberg is appropriate for long-term cold storage because it keeps table semantics over object storage instead of raw file dumps.
  - The project keeps one shared normalized table rather than many engine-specific tables to preserve schema consistency.
  - This design also supports later schema evolution more cleanly.

## 14. Iceberg schema evolution

- Official references
  - Iceberg evolution docs: <https://iceberg.apache.org/docs/latest/evolution/>
- Implemented in repo
  - architectural direction described in `docs/cold-path.md` and `docs/architecture.md`
- What we derived from these references
  - Iceberg is not only a file format choice; it is a table management choice with controlled schema evolution.
  - This matters for SIEM because event fields tend to expand over time.
  - Choosing Iceberg now reduces migration pain later when new normalized columns are added.

## 15. MinIO as S3-compatible object storage

- Official references
  - MinIO S3 compatibility: <https://min.io/product/s3-compatibility>
  - MinIO container docs: <https://min.io/docs/minio/container/index.html>
- Implemented in repo
  - `deploy/distributed/docker-compose.yml`
  - `flink/sql/cold-path/01_create_iceberg_catalog.sql`
  - `scripts/demo/demo.sh`
- What we derived from these references
  - MinIO is suitable for this lab because it preserves the S3 API contract used by Iceberg and Flink.
  - That lets the cold path stay close to a cloud/object-storage deployment model without requiring public cloud services.
  - Using `s3.endpoint` and path-style access in Flink SQL is a practical way to keep the warehouse portable.
  - MinIO console is also useful in demo because it makes Iceberg metadata and Parquet outputs visible to the audience.

## 16. PostgreSQL as benchmark baseline

- Official references
  - JSON types and `jsonb`: <https://www.postgresql.org/docs/current/static/datatype-json.html>
  - Full text search: <https://www.postgresql.org/docs/current/textsearch.html>
  - Aggregate functions: <https://www.postgresql.org/docs/current/functions-aggregate.html>
- Implemented in repo
  - `benchmark/postgres/init/01_schema.sql`
  - `scripts/benchmark/benchmark_tool.py`
  - `docs/benchmark.md`
- What we derived from these references
  - PostgreSQL is a valid baseline because it supports JSONB, aggregation, and full-text search, so the comparison is not against a weak toy system.
  - This makes the ES-vs-PG benchmark fairer for report writing.
  - PostgreSQL remains useful for exact relational-style queries, but it is not the primary hot investigation layer in this architecture.
  - The benchmark should therefore explain both where PostgreSQL is competitive and where Elasticsearch better fits SIEM workflows.

## 17. Internal references for the exact implementation

These are repository-local references that should be cited together with official docs whenever possible.

### Core architecture and deployment

- `docs/architecture.md`
- `docs/distributed-deployment.md`
- `deploy/distributed/docker-compose.yml`
- `deploy/distributed/siemctl.sh`

### Hot path

- `docs/phase1-hot-path.md`
- `configs/kafka-connect/siem-events-sink.json`
- `configs/kafka-connect/siem-snort-events-sink.json`
- `configs/elasticsearch/templates/siem-events-template.json`
- `scripts/bootstrap-elasticsearch.sh`

### Detection path

- `docs/flink-detections.md`
- `flink/sql/detections/00_create_detection_base.sql`
- `flink/sql/detections/04_detect_port_scan_zeek.sql`
- `flink/sql/detections/05_detect_top_talkers_zeek.sql`
- `flink/sql/detections/06_detect_possible_exfiltration_zeek.sql`
- `flink/sql/detections/07_detect_repeated_critical_snort.sql`
- `flink/sql/detections/08_detect_snort_zeek_correlation.sql`
- `flink/sql/detections/09_detect_protocol_anomalies_zeek.sql`

### Cold path

- `docs/cold-path.md`
- `flink/sql/cold-path/01_create_iceberg_catalog.sql`
- `flink/sql/cold-path/03_create_iceberg_tables.sql`
- `flink/sql/cold-path/04_create_kafka_sources.sql`
- `flink/sql/cold-path/05_insert_normalized_events.sql`

### Demo and validation

- `scripts/demo/demo.sh`
- `scripts/demo/run_distributed_demo.sh`
- `scripts/smoke/03_verify_hot_path.sh`
- `scripts/smoke/04_verify_cold_path.sh`
- `scripts/smoke/05_verify_detections.sh`
- `docs/validation-smoke-tests.md`

### Benchmarks

- `docs/benchmark.md`
- `scripts/benchmark/benchmark_tool.py`
- `scripts/benchmark/benchmark_ingest.sh`
- `scripts/benchmark/run_benchmark.sh`

## 18. Suggested citation pattern for report sections

Use a two-layer citation style:

- cite the official source for the concept
- cite the repository file for the concrete implementation

Examples:

- "The detection pipeline uses event-time processing and watermarks in Flink SQL to handle streaming threat logic [Flink CREATE Statements; Flink Table Config], implemented in `flink/sql/detections/00_create_detection_base.sql`."
- "The cold path uses an Iceberg REST catalog over S3-compatible object storage [Iceberg REST Catalog Spec; MinIO S3 Compatibility], implemented in `flink/sql/cold-path/01_create_iceberg_catalog.sql`."
- "Hot-path indexing uses Kafka Connect Elasticsearch sinks with template and alias bootstrap [Kafka Connect User Guide; Elasticsearch Templates; Elasticsearch Aliases], implemented in `configs/kafka-connect/siem-events-sink.json` and `scripts/bootstrap-elasticsearch.sh`."

## 19. Short list of the most important references

If the report only allows a short bibliography, these are the highest-priority references:

1. Flink Windowing TVF - <https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/dev/table/sql/queries/window-tvf/>
2. Flink Kafka SQL connector - <https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/connectors/table/kafka/>
3. Kafka Connect user guide - <https://kafka.apache.org/41/kafka-connect/user-guide/>
4. Confluent Elasticsearch Sink Connector - <https://docs.confluent.io/kafka-connectors/elasticsearch/current/overview.html>
5. Elasticsearch templates - <https://www.elastic.co/guide/en/elasticsearch/reference/current/indices-templates.html>
6. Elasticsearch aliases - <https://www.elastic.co/guide/en/elasticsearch/reference/current/aliases.html>
7. ECS field reference - <https://www.elastic.co/docs/reference/ecs/ecs-field-reference>
8. Iceberg REST Catalog Spec - <https://iceberg.apache.org/rest-catalog-spec/>
9. Iceberg Flink Writes - <https://iceberg.apache.org/docs/latest/docs/flink-writes/>
10. PostgreSQL JSONB and FTS docs - <https://www.postgresql.org/docs/current/static/datatype-json.html>, <https://www.postgresql.org/docs/current/textsearch.html>
