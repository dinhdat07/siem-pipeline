# Phase 1 Hot Path

Phase 1 completes the realtime path for search and visualization:

- events: `Kafka -> Kafka Connect -> Elasticsearch`
- alerts: `Kafka -> Flink -> siem.alerts -> Kafka Connect -> Elasticsearch`

## Why This Shape

- Kafka stays central so future cold storage, rule expansion, replay, and benchmarking all branch from the same bus.
- Flink does not index directly into Elasticsearch. It only reads Kafka and writes alert results back to Kafka.
- Kafka Connect handles Elasticsearch indexing for both normalized events and alerts.

## Index Naming

- `siem-events-*`
  - one shared events index pattern for normalized raw events
  - dashboards filter by `event.dataset` instead of hard-coding separate Zeek and Snort index names
- `siem-alerts-*`
  - dedicated alert index pattern for investigation and alert-centric dashboards
- write aliases
  - `siem-events` writes to `siem-events-000001`
  - `siem-alerts` writes to `siem-alerts-000001`

This keeps phase 1 simple while leaving room for rollover later.

## Elasticsearch Mappings

The templates define explicit mappings for fields that matter most in phase 1:

- `@timestamp` as `date`
- `source.ip`, `destination.ip`, `related.ip` as `ip`
- `event.dataset`, `event.kind`, `event.severity`, `rule.name`, `pipeline` as filterable fields
- `message` and `evidence` as full-text searchable fields
- `network.bytes` and packet counters as numeric fields for aggregations

The templates stay permissive for the rest of the ECS-like dotted fields so the lab can evolve without heavy schema management.

## Kafka Connect Setup

Kafka Connect is used instead of Logstash because it matches the roadmap and keeps the sink path simple:

- `siem-events-sink`
  - consumes `zeek.conn` and `snort.alert`
  - rewrites both topics to alias `siem-events`
- `siem-alerts-sink`
  - consumes `siem.alerts`
  - rewrites the topic to alias `siem-alerts`
- both connectors:
  - use JSON without schemas
  - ignore keys for document identity in the MVP
  - write bad records to `siem.connect.dlq`
  - use `flush.synchronously=true` because topic rewriting is enabled

## Kibana Structure

Imported saved objects create:

- data views
  - `siem-events-*`
  - `siem-alerts-*`
- dashboards
  - `SIEM Overview`
  - `SIEM Alerts`
  - `Top Source and Destination IPs`
  - `Large Transfers and Top Talkers`
  - `Alert Investigation Workflow`
  - `Event Timeline View`

For the sample dataset, the "large transfer" saved search uses a lab threshold of `network.bytes >= 1000` so the dashboard shows representative records without requiring production-scale traffic volumes.

The chart panels use Vega-based saved visualizations instead of hand-authored legacy vislib objects. This keeps the lab dashboards compatible with Kibana `8.17.x`, where the old `bar`/`histogram` saved object shape is brittle.

The dashboards also restore the sample data time range by default:

- from `2012-03-16T07:00:00Z`
- to `2012-03-16T13:00:00Z`

## Investigation Flow

The phase 1 workflow is intentionally simple:

1. open the alerts dashboard or investigation dashboard
2. narrow the time range
3. click `source.ip`, `destination.ip`, or `rule.name` in the alerts table
4. inspect the related raw events table or open Discover with the same filters

This gives the lab a usable alert-to-evidence path without adding a more complex case-management layer.
