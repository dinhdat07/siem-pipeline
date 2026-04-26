-- Detect a critical Snort alert followed by unusual Zeek traffic from the same source IP within a short event-time interval.
INSERT INTO siem_alerts_detection_sink
SELECT
  CAST(z.event_time AS STRING) AS `@timestamp`,
  'alert' AS `event.kind`,
  ARRAY['intrusion_detection', 'network'] AS `event.category`,
  ARRAY['indicator', 'correlation'] AS `event.type`,
  'flink' AS `event.module`,
  'siem.alert' AS `event.dataset`,
  CASE
    WHEN s.`event.severity` <= 1 AND COALESCE(z.`network.bytes`, 0) >= ${DETECTION_CORRELATION_ZEEK_BYTES_THRESHOLD} * 2 THEN 1
    ELSE 2
  END AS `event.severity`,
  'flink.snort_zeek.correlation' AS `rule.id`,
  'snort_zeek.correlation' AS `rule.name`,
  'correlation' AS `rule.category`,
  s.`source.ip`,
  z.`destination.ip`,
  z.`destination.port`,
  z.`network.bytes`,
  CONCAT('Critical Snort alert was followed by unusual Zeek traffic from the same source IP.') AS `alert.reason`,
  CONCAT(
    'snort_rule_id=', COALESCE(s.`rule.id`, 'unknown'),
    ', snort_severity=', CAST(COALESCE(s.`event.severity`, -1) AS STRING),
    ', zeek_uid=', COALESCE(z.`zeek.conn.uid`, 'unknown'),
    ', zeek_bytes=', CAST(COALESCE(z.`network.bytes`, 0) AS STRING)
  ) AS `alert.evidence`,
  CAST(2 AS BIGINT) AS `alert.count`,
  s.`rule.id` AS `alert.rule_ids`,
  CAST(s.event_time AS STRING) AS `window.start`,
  CAST(z.event_time AS STRING) AS `window.end`,
  ARRAY[s.`source.ip`, z.`destination.ip`] AS `related.ip`,
  'flink.snort_zeek.correlation' AS `pipeline`,
  CONCAT('Snort-to-Zeek correlation for ', s.`source.ip`) AS `message`,
  CAST(NULL AS BIGINT) AS `zeek.scan.unique_destination_ports`,
  CAST(NULL AS BIGINT) AS `zeek.scan.unique_destination_ips`,
  'source' AS `zeek.volume.direction`,
  z.`network.bytes` AS `zeek.volume.total_bytes`,
  CAST(1 AS BIGINT) AS `zeek.connection.count`,
  'snort-followed-by-high-bytes' AS `correlation.type`
FROM snort_detection_src AS s
JOIN zeek_detection_enriched AS z
  ON s.`source.ip` = z.`source.ip`
 AND z.event_time BETWEEN s.event_time AND s.event_time + INTERVAL '${DETECTION_CORRELATION_WINDOW_MINUTES}' MINUTE
WHERE s.`event.severity` IS NOT NULL
  AND s.`event.severity` <= ${DETECTION_CRITICAL_SNORT_SEVERITY_MAX}
  AND COALESCE(z.`network.bytes`, 0) >= ${DETECTION_CORRELATION_ZEEK_BYTES_THRESHOLD};
