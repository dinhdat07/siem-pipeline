-- Detect repeated high-severity Snort alerts from the same source IP in a short event-time hop window.
INSERT INTO siem_alerts_detection_sink
SELECT
  REPLACE(DATE_FORMAT(window_end, 'yyyy-MM-dd HH:mm:ss.SSS'), ' ', 'T') AS `@timestamp`,
  'alert' AS `event.kind`,
  ARRAY['intrusion_detection'] AS `event.category`,
  ARRAY['indicator'] AS `event.type`,
  'flink' AS `event.module`,
  'siem.alert' AS `event.dataset`,
  CASE WHEN alert_count >= ${DETECTION_CRITICAL_SNORT_COUNT_THRESHOLD} * 2 THEN 1 ELSE 2 END AS `event.severity`,
  'flink.snort.repeated_critical' AS `rule.id`,
  'snort.repeated_critical' AS `rule.name`,
  'intrusion_detection' AS `rule.category`,
  `source.ip`,
  sample_destination_ip AS `destination.ip`,
  CAST(NULL AS INT) AS `destination.port`,
  CAST(NULL AS BIGINT) AS `network.bytes`,
  CONCAT('Source IP ', `source.ip`, ' triggered repeated critical Snort alerts.') AS `alert.reason`,
  CONCAT('alert_count=', CAST(alert_count AS STRING), ', rule_ids=', rule_ids_csv) AS `alert.evidence`,
  alert_count AS `alert.count`,
  rule_ids_csv AS `alert.rule_ids`,
  REPLACE(CAST(window_start AS STRING), ' ', 'T') AS `window.start`,
  REPLACE(CAST(window_end AS STRING), ' ', 'T') AS `window.end`,
  ARRAY[`source.ip`, sample_destination_ip] AS `related.ip`,
  'flink.snort.repeated_critical' AS `pipeline`,
  CONCAT('Repeated critical Snort alerts from ', `source.ip`) AS `message`,
  CAST(NULL AS BIGINT) AS `zeek.scan.unique_destination_ports`,
  CAST(NULL AS BIGINT) AS `zeek.scan.unique_destination_ips`,
  CAST(NULL AS STRING) AS `zeek.volume.direction`,
  CAST(NULL AS BIGINT) AS `zeek.volume.total_bytes`,
  alert_count AS `zeek.connection.count`,
  'snort-burst' AS `correlation.type`
FROM (
  SELECT
    window_start,
    window_end,
    `source.ip`,
    MIN(`destination.ip`) AS sample_destination_ip,
    COUNT(*) AS alert_count,
    LISTAGG(`rule.id`, ',') AS rule_ids_csv
  FROM TABLE(
    HOP(
      TABLE snort_detection_src,
      DESCRIPTOR(event_time),
      INTERVAL '${DETECTION_CRITICAL_SNORT_SLIDE_MINUTES}' MINUTE,
      INTERVAL '${DETECTION_CRITICAL_SNORT_WINDOW_MINUTES}' MINUTE
    )
  )
  WHERE `event.severity` IS NOT NULL
    AND `event.severity` <= ${DETECTION_CRITICAL_SNORT_SEVERITY_MAX}
    AND `source.ip` IS NOT NULL
  GROUP BY window_start, window_end, `source.ip`
) repeated_alerts
WHERE alert_count >= ${DETECTION_CRITICAL_SNORT_COUNT_THRESHOLD};
