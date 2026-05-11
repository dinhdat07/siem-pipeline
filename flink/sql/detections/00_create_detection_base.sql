SET 'table.exec.source.idle-timeout' = '5 s';

CREATE TEMPORARY TABLE zeek_detection_src (
  `@timestamp` TIMESTAMP_LTZ(3),
  `event.kind` STRING,
  `event.category` ARRAY<STRING>,
  `event.type` ARRAY<STRING>,
  `event.module` STRING,
  `event.dataset` STRING,
  `source.ip` STRING,
  `source.port` INT,
  `source.bytes` BIGINT,
  `source.packets` BIGINT,
  `destination.ip` STRING,
  `destination.port` INT,
  `destination.bytes` BIGINT,
  `destination.packets` BIGINT,
  `network.transport` STRING,
  `network.protocol` STRING,
  `network.bytes` BIGINT,
  `network.packets` BIGINT,
  `related.ip` ARRAY<STRING>,
  `message` STRING,
  `event.original` STRING,
  `zeek.conn.uid` STRING,
  `zeek.conn.service` STRING,
  `zeek.conn.duration` DOUBLE,
  `zeek.conn.state` STRING,
  `zeek.conn.history` STRING,
  `zeek.conn.missed_bytes` BIGINT,
  `zeek.conn.local_orig` BOOLEAN,
  `zeek.conn.tunnel_parents` ARRAY<STRING>,
  event_time AS `@timestamp`,
  WATERMARK FOR event_time AS event_time - INTERVAL '${DETECTION_WATERMARK_SECONDS}' SECOND
) WITH (
  'connector' = 'kafka',
  'topic' = 'zeek.conn',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP_SERVERS_INTERNAL}',
  'scan.startup.mode' = '${KAFKA_SCAN_STARTUP_MODE}',
  'format' = 'json',
  'json.ignore-parse-errors' = 'true',
  'json.timestamp-format.standard' = 'ISO-8601'
);

CREATE TEMPORARY TABLE snort_detection_src (
  `@timestamp` TIMESTAMP_LTZ(3),
  `event.kind` STRING,
  `event.category` ARRAY<STRING>,
  `event.type` ARRAY<STRING>,
  `event.module` STRING,
  `event.dataset` STRING,
  `event.severity` INT,
  `rule.id` STRING,
  `rule.name` STRING,
  `rule.category` STRING,
  `source.ip` STRING,
  `source.port` INT,
  `destination.ip` STRING,
  `destination.port` INT,
  `network.transport` STRING,
  `related.ip` ARRAY<STRING>,
  `message` STRING,
  `event.original` STRING,
  `snort.generator_id` INT,
  `snort.signature_id` INT,
  `snort.signature_revision` INT,
  `snort.ip.ttl` INT,
  `snort.ip.tos` STRING,
  `snort.ip.id` INT,
  `snort.ip.len` INT,
  `snort.ip.flags` STRING,
  `snort.packet.len` INT,
  `snort.tcp.flags_raw` STRING,
  `snort.tcp.seq` STRING,
  `snort.tcp.ack` STRING,
  `snort.tcp.window` STRING,
  `snort.tcp.len` INT,
  `snort.xref` STRING,
  `log.file.path` STRING,
  event_time AS `@timestamp`,
  WATERMARK FOR event_time AS event_time - INTERVAL '${DETECTION_WATERMARK_SECONDS}' SECOND
) WITH (
  'connector' = 'kafka',
  'topic' = 'snort.alert',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP_SERVERS_INTERNAL}',
  'scan.startup.mode' = '${KAFKA_SCAN_STARTUP_MODE}',
  'format' = 'json',
  'json.ignore-parse-errors' = 'true',
  'json.timestamp-format.standard' = 'ISO-8601'
);

CREATE TEMPORARY TABLE siem_alerts_detection_sink (
  `@timestamp` STRING,
  `event.kind` STRING,
  `event.category` ARRAY<STRING>,
  `event.type` ARRAY<STRING>,
  `event.module` STRING,
  `event.dataset` STRING,
  `event.severity` INT,
  `rule.id` STRING,
  `rule.name` STRING,
  `rule.category` STRING,
  `source.ip` STRING,
  `destination.ip` STRING,
  `destination.port` INT,
  `network.bytes` BIGINT,
  `alert.reason` STRING,
  `alert.evidence` STRING,
  `alert.count` BIGINT,
  `alert.rule_ids` STRING,
  `window.start` STRING,
  `window.end` STRING,
  `related.ip` ARRAY<STRING>,
  `pipeline` STRING,
  `message` STRING,
  `zeek.scan.unique_destination_ports` BIGINT,
  `zeek.scan.unique_destination_ips` BIGINT,
  `zeek.volume.direction` STRING,
  `zeek.volume.total_bytes` BIGINT,
  `zeek.connection.count` BIGINT,
  `correlation.type` STRING
) WITH (
  'connector' = 'kafka',
  'topic' = 'siem.alerts',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP_SERVERS_INTERNAL}',
  'format' = 'json',
  'json.timestamp-format.standard' = 'ISO-8601'
);

CREATE TEMPORARY VIEW zeek_detection_enriched AS
SELECT
  *,
  (
    `source.ip` LIKE '10.%'
    OR `source.ip` LIKE '192.168.%'
    OR `source.ip` LIKE '172.16.%'
    OR `source.ip` LIKE '172.17.%'
    OR `source.ip` LIKE '172.18.%'
    OR `source.ip` LIKE '172.19.%'
    OR `source.ip` LIKE '172.2_.%'
    OR `source.ip` LIKE '172.30.%'
    OR `source.ip` LIKE '172.31.%'
  ) AS source_is_internal,
  (
    `destination.ip` LIKE '10.%'
    OR `destination.ip` LIKE '192.168.%'
    OR `destination.ip` LIKE '172.16.%'
    OR `destination.ip` LIKE '172.17.%'
    OR `destination.ip` LIKE '172.18.%'
    OR `destination.ip` LIKE '172.19.%'
    OR `destination.ip` LIKE '172.2_.%'
    OR `destination.ip` LIKE '172.30.%'
    OR `destination.ip` LIKE '172.31.%'
  ) AS destination_is_internal
FROM zeek_detection_src;
