# Slide References

Use this short version on slides. Keep the long explanations in `docs/references.md`.

## Core stack references

1. Apache Flink SQL
   - Watermarks and DDL: <https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/dev/table/sql/create/>
   - Windowing TVF: <https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/dev/table/sql/queries/window-tvf/>
   - Kafka SQL connector: <https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/connectors/table/kafka/>
   - Main takeaway: event-time, windows, and Kafka-native SQL tables drive detection and cold-path logic.

2. Apache Kafka Connect
   - User guide: <https://kafka.apache.org/41/kafka-connect/user-guide/>
   - Administration: <https://kafka.apache.org/41/kafka-connect/administration/>
   - Main takeaway: distributed sink workers decouple indexing from Flink and scale across nodes.

3. Confluent Elasticsearch Sink Connector
   - Overview: <https://docs.confluent.io/kafka-connectors/elasticsearch/current/overview.html>
   - Main takeaway: Kafka topics are indexed into Elasticsearch without embedding ES writes inside Flink jobs.

4. Elasticsearch and Kibana
   - Templates: <https://www.elastic.co/guide/en/elasticsearch/reference/current/indices-templates.html>
   - Aliases: <https://www.elastic.co/guide/en/elasticsearch/reference/current/aliases.html>
   - Aggregations: <https://www.elastic.co/guide/en/elasticsearch/reference/current/search-aggregations.html>
   - Saved objects import: <https://www.elastic.co/docs/api/doc/kibana/v8/operation/operation-importsavedobjectsdefault>
   - Main takeaway: ES is the hot search and aggregation layer; Kibana is the investigation and demo UI.

5. Elastic Common Schema (ECS)
   - Field reference: <https://www.elastic.co/docs/reference/ecs/ecs-field-reference>
   - Main takeaway: ECS-like normalization lets Zeek, Snort, and Flink alerts share one query model.

6. Apache Iceberg + MinIO
   - REST Catalog Spec: <https://iceberg.apache.org/rest-catalog-spec/>
   - Flink Writes: <https://iceberg.apache.org/docs/latest/docs/flink-writes/>
   - MinIO S3 compatibility: <https://min.io/product/s3-compatibility>
   - Main takeaway: Iceberg gives table semantics on object storage for cold-path retention.

7. PostgreSQL baseline
   - JSONB: <https://www.postgresql.org/docs/current/static/datatype-json.html>
   - Full text search: <https://www.postgresql.org/docs/current/textsearch.html>
   - Main takeaway: PostgreSQL is a fair baseline for comparison, but not the primary SIEM search layer.

## Project implementation references

- Architecture: `docs/architecture.md`
- Distributed deployment: `docs/distributed-deployment.md`
- Detection SQL: `flink/sql/detections/`
- Cold path SQL: `flink/sql/cold-path/`
- Demo runner: `scripts/demo/demo.sh`
- Benchmark methodology: `docs/benchmark.md`
