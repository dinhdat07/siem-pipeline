# Phase 3 Flink Detections

Phase 3 upgrades Flink from simple one-off filters into a small set of practical SIEM detections over the existing normalized Zeek and Snort streams.

## Detection Runtime Model

All Phase 3 detections:

- read normalized events from Kafka topics `zeek.conn` and `snort.alert`
- use event-time semantics with a configurable watermark (`DETECTION_WATERMARK_SECONDS`)
- emit standardized alerts back to Kafka topic `siem.alerts`
- stay rule-based and explainable

Shared detection SQL lives in:

- base tables and watermark definitions: `flink/sql/detections/00_create_detection_base.sql`
- detection rules: `flink/sql/detections/04_detect_*.sql` through `09_detect_*.sql`

Thresholds live in `configs/flink/detection-thresholds.env`.

## Shared Alert Schema

Every rule writes a common alert structure with these core fields:

- `@timestamp`
- `event.kind`
- `event.category`
- `event.type`
- `event.module`
- `event.dataset`
- `rule.id`
- `rule.name`
- `rule.category`
- `event.severity`
- `source.ip`
- `destination.ip`
- `network.bytes`
- `alert.reason`
- `alert.evidence`
- `window.start`
- `window.end`
- `related.ip`

Some rules add optional context such as:

- `alert.count`
- `alert.rule_ids`
- `zeek.scan.unique_destination_ports`
- `zeek.scan.unique_destination_ips`
- `zeek.volume.direction`
- `zeek.volume.total_bytes`
- `zeek.connection.count`
- `correlation.type`

## Rule Details

### 04 Detect Port Scan Zeek

- purpose
  - identify one source IP contacting many ports or many destination IPs in a short period
- input topic
  - `zeek.conn`
- output topic
  - `siem.alerts`
- event-time logic
  - hop window over Zeek events
  - default size: 2 minutes
  - default slide: 30 seconds
- threshold
  - `DETECTION_PORT_SCAN_UNIQUE_PORT_THRESHOLD=5`
  - `DETECTION_PORT_SCAN_UNIQUE_IP_THRESHOLD=3`
- emitted context
  - source IP, flow count, unique destination ports, unique destination IPs, total bytes, window start/end
- known limitations
  - tuned for the lab, so it may still flag legitimate bursty scanning tools or service discovery

### 05 Detect Top Talkers Zeek

- purpose
  - identify source or destination hosts with unusually high aggregate network volume
- input topic
  - `zeek.conn`
- output topic
  - `siem.alerts`
- event-time logic
  - tumbling window over Zeek events
  - default size: 5 minutes
- threshold
  - `DETECTION_TOP_TALKERS_BYTES_THRESHOLD=5000000`
  - `DETECTION_TOP_TALKERS_CONNECTION_THRESHOLD=3`
- emitted context
  - host IP, direction (`source` or `destination`), total bytes, flow count, window start/end
- known limitations
  - uses static byte thresholds instead of percentile baselines or host-role awareness

### 06 Detect Possible Exfiltration Zeek

- purpose
  - identify sustained outbound byte volume from internal to external IPs
- input topic
  - `zeek.conn`
- output topic
  - `siem.alerts`
- event-time logic
  - hop window over Zeek events
  - default size: 5 minutes
  - default slide: 1 minute
- threshold
  - `DETECTION_EXFIL_SOURCE_BYTES_THRESHOLD=4000000`
  - `DETECTION_EXFIL_FLOW_COUNT_THRESHOLD=3`
- emitted context
  - source IP, sample destination IP, source bytes, total bytes, destination count, flow count, window start/end
- internal/external assumption
  - uses a configurable RFC1918-style regex placeholder from `DETECTION_INTERNAL_NETWORK_REGEX`
- known limitations
  - the placeholder does not know real asset inventory, NAT behavior, or business-approved transfer destinations

### 07 Detect Repeated Critical Snort

- purpose
  - identify repeated high-severity Snort alerts from the same source IP
- input topic
  - `snort.alert`
- output topic
  - `siem.alerts`
- event-time logic
  - hop window over Snort alerts
  - default size: 5 minutes
  - default slide: 1 minute
- threshold
  - `DETECTION_CRITICAL_SNORT_SEVERITY_MAX=2`
  - `DETECTION_CRITICAL_SNORT_COUNT_THRESHOLD=3`
- emitted context
  - source IP, aggregated alert count, comma-separated rule IDs, sample destination IP, window start/end
- known limitations
  - repeated benign signatures can still aggregate into an alert if the environment is noisy

### 08 Detect Snort Zeek Correlation

- purpose
  - identify a critical Snort alert followed by high-byte Zeek traffic from the same source IP
- input topics
  - `snort.alert`
  - `zeek.conn`
- output topic
  - `siem.alerts`
- event-time logic
  - interval join between Snort and Zeek streams
  - default look-ahead: 2 minutes
- threshold
  - `DETECTION_CORRELATION_ZEEK_BYTES_THRESHOLD=1000000`
- emitted context
  - source IP, destination IP, destination port, Snort rule ID, Snort severity, Zeek bytes, join time range
- known limitations
  - joins on `source.ip` only, so it does not yet cover every pivot pattern across source and destination roles

### 09 Detect Protocol Anomalies Zeek

- purpose
  - flag explainable protocol or service mismatches on individual Zeek events
- input topic
  - `zeek.conn`
- output topic
  - `siem.alerts`
- event-time logic
  - per-event rule with alert timestamp taken from the event itself
- checks
  - null service with high bytes
  - HTTP on unexpected ports
  - DNS on unexpected ports
  - SSH on non-standard ports
  - HTTP paired with UDP transport
- threshold
  - `DETECTION_PROTOCOL_UNKNOWN_SERVICE_BYTES_THRESHOLD=750000`
- emitted context
  - source IP, destination IP, destination port, service, transport, bytes, anomaly type
- known limitations
  - port-based protocol expectations are simple heuristics and do not model custom environments

## Event-Time And Watermark Decisions

The detections use event time because the sample data is replayed after the fact and arrival order should not redefine the window logic.

Chosen defaults:

- watermark: 30 seconds
  - enough slack for slight replay skew without making alert emission too delayed in the lab
- hop windows for burst or sustained behavior
  - port scan, exfiltration, and repeated critical Snort benefit from overlapping windows so detections are less sensitive to exact minute boundaries
- tumbling windows for top talkers
  - top-talker alerts work well as periodic summaries and do not need overlapping windows in the MVP
- interval join for correlation
  - keeps the Snort-to-Zeek correlation easy to explain and tied to direct temporal proximity

## Expected Synthetic Alerts

The synthetic JSONL files in `data/test/phase3/` are designed to trigger all six rule types.

Expected examples include alerts such as:

- `flink.zeek.port_scan`
- `flink.zeek.top_talker`
- `flink.zeek.possible_exfiltration`
- `flink.snort.repeated_critical`
- `flink.snort_zeek.correlation`
- `flink.zeek.protocol_anomaly`

## Runbook

Start the jobs:

```bash
bash scripts/run-flink-sql.sh \
  flink/sql/detections/00_create_detection_base.sql \
  flink/sql/detections/04_detect_port_scan_zeek.sql \
  flink/sql/detections/05_detect_top_talkers_zeek.sql \
  flink/sql/detections/06_detect_possible_exfiltration_zeek.sql \
  flink/sql/detections/07_detect_repeated_critical_snort.sql \
  flink/sql/detections/08_detect_snort_zeek_correlation.sql \
  flink/sql/detections/09_detect_protocol_anomalies_zeek.sql
```

Replay the synthetic validation data:

```bash
bash scripts/replay-phase3-synthetic.sh
```

Verify alerts in Kafka and Elasticsearch:

```bash
bash scripts/verify-flink-detections.sh
```

## Example Alert Shape

```json
{
  "@timestamp": "2012-03-16T12:42:00Z",
  "event.kind": "alert",
  "event.category": ["network"],
  "event.type": ["indicator"],
  "event.module": "flink",
  "event.dataset": "siem.alert",
  "rule.id": "flink.zeek.port_scan",
  "rule.name": "zeek.port_scan",
  "rule.category": "reconnaissance",
  "event.severity": 3,
  "source.ip": "192.168.10.10",
  "network.bytes": 200,
  "alert.reason": "Source IP 192.168.10.10 contacted many unique destination ports in a short interval.",
  "alert.evidence": "flow_count=5, unique_destination_ports=5, unique_destination_ips=4, total_network_bytes=200",
  "window.start": "2012-03-16T12:40:00Z",
  "window.end": "2012-03-16T12:42:00Z",
  "related.ip": ["192.168.10.10"],
  "zeek.scan.unique_destination_ports": 5,
  "zeek.scan.unique_destination_ips": 4
}
```
