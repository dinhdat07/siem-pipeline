ADD JAR 'file:///opt/flink/usrlib/flink-sql-connector-kafka-3.2.0-1.19.jar';

CREATE TEMPORARY TABLE zeek_conn_src (
  `@timestamp` STRING,
  `source.ip` STRING,
  `destination.ip` STRING,
  `network.transport` STRING,
  `network.bytes` BIGINT,
  `message` STRING
) WITH (
  'connector' = 'kafka',
  'topic' = 'zeek.conn',
  'properties.bootstrap.servers' = 'kafka:29092',
  'properties.group.id' = 'flink-zeek-src',
  'scan.startup.mode' = 'earliest-offset',
  'format' = 'json',
  'json.ignore-parse-errors' = 'true'
);

CREATE TEMPORARY TABLE siem_alerts_sink (
  alert_time STRING,
  rule_name STRING,
  source_ip STRING,
  destination_ip STRING,
  severity INT,
  evidence STRING,
  pipeline STRING
) WITH (
  'connector' = 'kafka',
  'topic' = 'siem.alerts',
  'properties.bootstrap.servers' = 'kafka:29092',
  'format' = 'json',
  'json.timestamp-format.standard' = 'ISO-8601'
);

INSERT INTO siem_alerts_sink
SELECT
  `@timestamp` AS alert_time,
  CONCAT('zeek.large_transfer.', COALESCE(`network.transport`, 'unknown')) AS rule_name,
  `source.ip` AS source_ip,
  `destination.ip` AS destination_ip,
  3 AS severity,
  `message` AS evidence,
  'flink.zeek.large_transfer' AS pipeline
FROM zeek_conn_src
WHERE `network.bytes` IS NOT NULL
  AND `network.bytes` > 1000000;
