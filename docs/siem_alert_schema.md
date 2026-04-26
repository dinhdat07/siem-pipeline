# SIEM Alert Schema (`siem.alerts`)

## Overview

`siem.alerts` is the canonical alert topic produced by Flink and retained in Kafka for downstream consumers.

Phase 3 keeps the same topic but expands the payload so multiple rule types can emit explainable alerts with a shared structure.

## Required Alert Fields

| Field | Type | Description |
| --- | --- | --- |
| `@timestamp` | date | Alert timestamp in UTC ISO-8601 |
| `event.kind` | keyword | Always `alert` |
| `event.category` | keyword[] | High-level category such as `network` or `intrusion_detection` |
| `event.type` | keyword[] | Alert type such as `indicator`, `correlation`, or `anomaly` |
| `event.module` | keyword | Producing module, currently `flink` |
| `event.dataset` | keyword | Always `siem.alert` |
| `event.severity` | integer | Numeric severity used by dashboards and filtering |
| `rule.id` | keyword | Stable rule identifier |
| `rule.name` | keyword | Human-readable rule name |
| `rule.category` | keyword | Detection family such as `reconnaissance` or `correlation` |
| `source.ip` | ip | Source IP when present |
| `destination.ip` | ip | Destination IP when present |
| `network.bytes` | long | Bytes associated with the alert when applicable |
| `alert.reason` | text | Plain-language explanation of why the alert was emitted |
| `alert.evidence` | text | Compact evidence string with threshold-relevant context |
| `window.start` | date | Detection window start or originating event time |
| `window.end` | date | Detection window end or correlated event time |
| `related.ip` | ip[] | Involved IPs used for investigation pivots |
| `pipeline` | keyword | Producing Flink pipeline name |
| `message` | text | Short alert summary |

## Optional Rule-Specific Fields

| Field | Type | Description |
| --- | --- | --- |
| `alert.count` | long | Aggregated event count for windowed detections |
| `alert.rule_ids` | keyword | Comma-separated Snort rule IDs for aggregated Snort detections |
| `destination.port` | integer | Destination port when a single port is relevant |
| `zeek.scan.unique_destination_ports` | long | Port-scan unique port count |
| `zeek.scan.unique_destination_ips` | long | Port-scan or exfil unique destination count |
| `zeek.volume.direction` | keyword | Whether volume aggregation was by source or destination host |
| `zeek.volume.total_bytes` | long | Total bytes accumulated for a Zeek volume alert |
| `zeek.connection.count` | long | Connection or flow count used by the rule |
| `correlation.type` | keyword | Correlation or anomaly subtype |

## Notes

- Kafka remains the source of truth for realtime alerts.
- Elasticsearch indexes the same alert payload into `siem-alerts-*` for search and dashboards.
- The schema stays explainable and rule-based instead of using opaque scores or ML-only outputs.
