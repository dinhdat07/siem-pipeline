-- Detect simple per-event protocol and service anomalies from Zeek.
INSERT INTO siem_alerts_detection_sink
SELECT
  CAST(event_time AS STRING) AS `@timestamp`,
  'alert' AS `event.kind`,
  ARRAY['network'] AS `event.category`,
  ARRAY['indicator', 'anomaly'] AS `event.type`,
  'flink' AS `event.module`,
  'siem.alert' AS `event.dataset`,
  severity AS `event.severity`,
  'flink.zeek.protocol_anomaly' AS `rule.id`,
  'zeek.protocol_anomaly' AS `rule.name`,
  'protocol_anomaly' AS `rule.category`,
  `source.ip`,
  `destination.ip`,
  `destination.port`,
  `network.bytes`,
  reason AS `alert.reason`,
  evidence AS `alert.evidence`,
  CAST(1 AS BIGINT) AS `alert.count`,
  CAST(NULL AS STRING) AS `alert.rule_ids`,
  CAST(event_time AS STRING) AS `window.start`,
  CAST(event_time AS STRING) AS `window.end`,
  `related.ip`,
  'flink.zeek.protocol_anomaly' AS `pipeline`,
  CONCAT('Protocol anomaly from ', `source.ip`) AS `message`,
  CAST(NULL AS BIGINT) AS `zeek.scan.unique_destination_ports`,
  CAST(NULL AS BIGINT) AS `zeek.scan.unique_destination_ips`,
  'source' AS `zeek.volume.direction`,
  `network.bytes` AS `zeek.volume.total_bytes`,
  CAST(1 AS BIGINT) AS `zeek.connection.count`,
  anomaly_type AS `correlation.type`
FROM (
  SELECT
    event_time,
    `source.ip`,
    `destination.ip`,
    `destination.port`,
    `related.ip`,
    `network.bytes`,
    CASE
      WHEN `network.protocol` IS NULL AND COALESCE(`network.bytes`, 0) >= ${DETECTION_PROTOCOL_UNKNOWN_SERVICE_BYTES_THRESHOLD}
        THEN 'unknown_service_high_bytes'
      WHEN `network.protocol` = 'http' AND `destination.port` NOT IN (80, 8080, 8000, 8888)
        THEN 'http_unexpected_port'
      WHEN `network.protocol` = 'dns' AND `destination.port` NOT IN (53, 5353)
        THEN 'dns_unexpected_port'
      WHEN `network.protocol` = 'ssh' AND `destination.port` <> 22
        THEN 'ssh_unexpected_port'
      WHEN `network.protocol` = 'http' AND `network.transport` = 'udp'
        THEN 'http_over_udp'
      ELSE NULL
    END AS anomaly_type,
    CASE
      WHEN `network.protocol` IS NULL AND COALESCE(`network.bytes`, 0) >= ${DETECTION_PROTOCOL_UNKNOWN_SERVICE_BYTES_THRESHOLD}
        THEN 2
      ELSE 3
    END AS severity,
    CASE
      WHEN `network.protocol` IS NULL AND COALESCE(`network.bytes`, 0) >= ${DETECTION_PROTOCOL_UNKNOWN_SERVICE_BYTES_THRESHOLD}
        THEN 'Unknown or null service carried unusually high bytes.'
      WHEN `network.protocol` = 'http' AND `destination.port` NOT IN (80, 8080, 8000, 8888)
        THEN 'HTTP-like traffic appeared on an uncommon destination port.'
      WHEN `network.protocol` = 'dns' AND `destination.port` NOT IN (53, 5353)
        THEN 'DNS-like traffic appeared on an uncommon destination port.'
      WHEN `network.protocol` = 'ssh' AND `destination.port` <> 22
        THEN 'SSH-like traffic appeared on a non-standard destination port.'
      WHEN `network.protocol` = 'http' AND `network.transport` = 'udp'
        THEN 'HTTP service was paired with UDP transport.'
      ELSE NULL
    END AS reason,
    CONCAT(
      'service=', COALESCE(`network.protocol`, 'null'),
      ', transport=', COALESCE(`network.transport`, 'null'),
      ', destination_port=', CAST(COALESCE(`destination.port`, -1) AS STRING),
      ', network_bytes=', CAST(COALESCE(`network.bytes`, 0) AS STRING)
    ) AS evidence
  FROM zeek_detection_src
) anomalies
WHERE anomaly_type IS NOT NULL;
