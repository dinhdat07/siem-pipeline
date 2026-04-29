-- Detect one source IP reaching many destination ports and/or destination IPs within a short event-time hop window.
INSERT INTO siem_alerts_detection_sink
SELECT
  REPLACE(DATE_FORMAT(window_end, 'yyyy-MM-dd HH:mm:ss.SSS'), ' ', 'T') AS `@timestamp`,
  'alert' AS `event.kind`,
  ARRAY['network'] AS `event.category`,
  ARRAY['indicator', 'connection'] AS `event.type`,
  'flink' AS `event.module`,
  'siem.alert' AS `event.dataset`,
  CASE
    WHEN unique_destination_ports >= ${DETECTION_PORT_SCAN_UNIQUE_PORT_THRESHOLD} * 2
      OR unique_destination_ips >= ${DETECTION_PORT_SCAN_UNIQUE_IP_THRESHOLD} * 2 THEN 2
    ELSE 3
  END AS `event.severity`,
  'flink.zeek.port_scan' AS `rule.id`,
  'zeek.port_scan' AS `rule.name`,
  'reconnaissance' AS `rule.category`,
  `source.ip`,
  CAST(NULL AS STRING) AS `destination.ip`,
  CAST(NULL AS INT) AS `destination.port`,
  total_network_bytes AS `network.bytes`,
  CONCAT(
    'Source IP ', `source.ip`, ' contacted ',
    CAST(unique_destination_ports AS STRING), ' unique destination ports across ',
    CAST(unique_destination_ips AS STRING), ' destination IPs in ',
    CAST(${DETECTION_PORT_SCAN_WINDOW_MINUTES} AS STRING), ' minute(s).'
  ) AS `alert.reason`,
  CONCAT(
    'flow_count=', CAST(flow_count AS STRING),
    ', unique_destination_ports=', CAST(unique_destination_ports AS STRING),
    ', unique_destination_ips=', CAST(unique_destination_ips AS STRING),
    ', total_network_bytes=', CAST(total_network_bytes AS STRING)
  ) AS `alert.evidence`,
  flow_count AS `alert.count`,
  CAST(NULL AS STRING) AS `alert.rule_ids`,
  CAST(window_start AS STRING) AS `window.start`,
  CAST(window_end AS STRING) AS `window.end`,
  ARRAY[`source.ip`] AS `related.ip`,
  'flink.zeek.port_scan' AS `pipeline`,
  CONCAT('Possible port scan from ', `source.ip`) AS `message`,
  unique_destination_ports AS `zeek.scan.unique_destination_ports`,
  unique_destination_ips AS `zeek.scan.unique_destination_ips`,
  CAST(NULL AS STRING) AS `zeek.volume.direction`,
  total_network_bytes AS `zeek.volume.total_bytes`,
  flow_count AS `zeek.connection.count`,
  CAST(NULL AS STRING) AS `correlation.type`
FROM (
  SELECT
    window_start,
    window_end,
    `source.ip`,
    COUNT(*) AS flow_count,
    COUNT(DISTINCT `destination.port`) AS unique_destination_ports,
    COUNT(DISTINCT `destination.ip`) AS unique_destination_ips,
    SUM(COALESCE(`network.bytes`, 0)) AS total_network_bytes
  FROM TABLE(
    HOP(
      TABLE zeek_detection_src,
      DESCRIPTOR(event_time),
      INTERVAL '${DETECTION_PORT_SCAN_SLIDE_SECONDS}' SECOND,
      INTERVAL '${DETECTION_PORT_SCAN_WINDOW_MINUTES}' MINUTE
    )
  )
  GROUP BY window_start, window_end, `source.ip`
) port_scan_candidates
WHERE unique_destination_ports >= ${DETECTION_PORT_SCAN_UNIQUE_PORT_THRESHOLD}
   OR unique_destination_ips >= ${DETECTION_PORT_SCAN_UNIQUE_IP_THRESHOLD};
