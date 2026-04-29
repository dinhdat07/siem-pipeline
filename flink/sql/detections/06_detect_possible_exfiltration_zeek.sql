-- Detect sustained outbound traffic from RFC1918-style internal hosts to external destinations.
INSERT INTO siem_alerts_detection_sink
SELECT
  REPLACE(DATE_FORMAT(window_end, 'yyyy-MM-dd HH:mm:ss.SSS'), ' ', 'T') AS `@timestamp`,
  'alert' AS `event.kind`,
  ARRAY['network', 'data_access'] AS `event.category`,
  ARRAY['indicator'] AS `event.type`,
  'flink' AS `event.module`,
  'siem.alert' AS `event.dataset`,
  CASE WHEN total_source_bytes >= ${DETECTION_EXFIL_SOURCE_BYTES_THRESHOLD} * 2 THEN 1 ELSE 2 END AS `event.severity`,
  'flink.zeek.possible_exfiltration' AS `rule.id`,
  'zeek.possible_exfiltration' AS `rule.name`,
  'exfiltration' AS `rule.category`,
  `source.ip`,
  sample_destination_ip AS `destination.ip`,
  CAST(NULL AS INT) AS `destination.port`,
  total_network_bytes AS `network.bytes`,
  CONCAT('Internal source ', `source.ip`, ' sent sustained outbound traffic to external destinations.') AS `alert.reason`,
  CONCAT(
    'total_source_bytes=', CAST(total_source_bytes AS STRING),
    ', total_destination_bytes=', CAST(total_destination_bytes AS STRING),
    ', total_network_bytes=', CAST(total_network_bytes AS STRING),
    ', destination_count=', CAST(destination_count AS STRING)
  ) AS `alert.evidence`,
  flow_count AS `alert.count`,
  CAST(NULL AS STRING) AS `alert.rule_ids`,
  CAST(window_start AS STRING) AS `window.start`,
  CAST(window_end AS STRING) AS `window.end`,
  ARRAY[`source.ip`, sample_destination_ip] AS `related.ip`,
  'flink.zeek.possible_exfiltration' AS `pipeline`,
  CONCAT('Possible exfiltration from ', `source.ip`) AS `message`,
  CAST(NULL AS BIGINT) AS `zeek.scan.unique_destination_ports`,
  destination_count AS `zeek.scan.unique_destination_ips`,
  'source' AS `zeek.volume.direction`,
  total_network_bytes AS `zeek.volume.total_bytes`,
  flow_count AS `zeek.connection.count`,
  'internal-to-external' AS `correlation.type`
FROM (
  SELECT
    window_start,
    window_end,
    `source.ip`,
    MIN(`destination.ip`) AS sample_destination_ip,
    COUNT(*) AS flow_count,
    COUNT(DISTINCT `destination.ip`) AS destination_count,
    SUM(COALESCE(`source.bytes`, 0)) AS total_source_bytes,
    SUM(COALESCE(`destination.bytes`, 0)) AS total_destination_bytes,
    SUM(COALESCE(`network.bytes`, 0)) AS total_network_bytes
  FROM TABLE(
    HOP(
      TABLE zeek_detection_enriched,
      DESCRIPTOR(event_time),
      INTERVAL '${DETECTION_EXFIL_SLIDE_MINUTES}' MINUTE,
      INTERVAL '${DETECTION_EXFIL_WINDOW_MINUTES}' MINUTE
    )
  )
  WHERE source_is_internal = TRUE
    AND destination_is_internal = FALSE
  GROUP BY window_start, window_end, `source.ip`
) exfil_candidates
WHERE total_source_bytes >= ${DETECTION_EXFIL_SOURCE_BYTES_THRESHOLD}
  AND flow_count >= ${DETECTION_EXFIL_FLOW_COUNT_THRESHOLD};
