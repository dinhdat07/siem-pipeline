-- Detect high-volume hosts from Zeek by aggregating bytes in event-time tumbling windows.
INSERT INTO siem_alerts_detection_sink
SELECT
  REPLACE(DATE_FORMAT(window_end, 'yyyy-MM-dd HH:mm:ss.SSS'), ' ', 'T') AS `@timestamp`,
  'alert' AS `event.kind`,
  ARRAY['network'] AS `event.category`,
  ARRAY['indicator'] AS `event.type`,
  'flink' AS `event.module`,
  'siem.alert' AS `event.dataset`,
  CASE WHEN total_bytes >= ${DETECTION_TOP_TALKERS_BYTES_THRESHOLD} * 2 THEN 2 ELSE 3 END AS `event.severity`,
  'flink.zeek.top_talker' AS `rule.id`,
  'zeek.top_talker' AS `rule.name`,
  'network_volume' AS `rule.category`,
  CASE WHEN direction = 'source' THEN host_ip ELSE CAST(NULL AS STRING) END AS `source.ip`,
  CASE WHEN direction = 'destination' THEN host_ip ELSE CAST(NULL AS STRING) END AS `destination.ip`,
  CAST(NULL AS INT) AS `destination.port`,
  total_bytes AS `network.bytes`,
  CONCAT('Host ', host_ip, ' exceeded the top-talker threshold as ', direction, '.') AS `alert.reason`,
  CONCAT('direction=', direction, ', total_bytes=', CAST(total_bytes AS STRING), ', flow_count=', CAST(flow_count AS STRING)) AS `alert.evidence`,
  flow_count AS `alert.count`,
  CAST(NULL AS STRING) AS `alert.rule_ids`,
  CAST(window_start AS STRING) AS `window.start`,
  CAST(window_end AS STRING) AS `window.end`,
  ARRAY[host_ip] AS `related.ip`,
  'flink.zeek.top_talker' AS `pipeline`,
  CONCAT('High-volume ', direction, ' host detected: ', host_ip) AS `message`,
  CAST(NULL AS BIGINT) AS `zeek.scan.unique_destination_ports`,
  CAST(NULL AS BIGINT) AS `zeek.scan.unique_destination_ips`,
  direction AS `zeek.volume.direction`,
  total_bytes AS `zeek.volume.total_bytes`,
  flow_count AS `zeek.connection.count`,
  CAST(NULL AS STRING) AS `correlation.type`
FROM (
  SELECT
    window_start,
    window_end,
    'source' AS direction,
    `source.ip` AS host_ip,
    COUNT(*) AS flow_count,
    SUM(COALESCE(`network.bytes`, 0)) AS total_bytes
  FROM TABLE(
    TUMBLE(
      TABLE zeek_detection_src,
      DESCRIPTOR(event_time),
      INTERVAL '${DETECTION_TOP_TALKERS_WINDOW_MINUTES}' MINUTE
    )
  )
  GROUP BY window_start, window_end, `source.ip`

  UNION ALL

  SELECT
    window_start,
    window_end,
    'destination' AS direction,
    `destination.ip` AS host_ip,
    COUNT(*) AS flow_count,
    SUM(COALESCE(`network.bytes`, 0)) AS total_bytes
  FROM TABLE(
    TUMBLE(
      TABLE zeek_detection_src,
      DESCRIPTOR(event_time),
      INTERVAL '${DETECTION_TOP_TALKERS_WINDOW_MINUTES}' MINUTE
    )
  )
  GROUP BY window_start, window_end, `destination.ip`
) top_talkers
WHERE host_ip IS NOT NULL
  AND total_bytes >= ${DETECTION_TOP_TALKERS_BYTES_THRESHOLD}
  AND flow_count >= ${DETECTION_TOP_TALKERS_CONNECTION_THRESHOLD};
