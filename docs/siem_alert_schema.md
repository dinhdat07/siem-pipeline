# SIEM Alert Schema (`siem.alerts`)

## Overview

`siem.alerts` is the canonical alert topic produced by Flink and retained in Kafka for downstream consumers.

Phase 1 uses the same alert payload for both:

- Kafka retention and downstream processing
- Elasticsearch indexing into the hot investigation index

## Core Fields

| Field | Type | Description |
| --- | --- | --- |
| `@timestamp` | date | Alert timestamp in UTC ISO-8601 |
| `event.kind` | keyword | Always `alert` |
| `event.category` | keyword[] | Alert category, for example `intrusion_detection` or `network` |
| `event.type` | keyword[] | Alert type, currently `indicator` |
| `event.module` | keyword | Producing module, currently `flink` |
| `event.dataset` | keyword | Always `siem.alert` |
| `event.severity` | integer | Numeric severity used by dashboards and filtering |
| `rule.id` | keyword | Stable rule identifier |
| `rule.name` | keyword | Human-readable rule name |
| `message` | text | Short alert summary |
| `source.ip` | ip | Source IP when present |
| `destination.ip` | ip | Destination IP when present |
| `related.ip` | ip[] | Involved IPs used for investigation pivots |
| `pipeline` | keyword | Producing pipeline name |
| `evidence` | text | Source event context used to explain the alert |

## Notes

- Kafka remains the source of truth for realtime alerts.
- Elasticsearch indexes the same alert payload into `siem-alerts-*` for search and dashboards.
- Future rules in phases 3-5 should reuse this schema instead of introducing rule-specific alert payloads.
