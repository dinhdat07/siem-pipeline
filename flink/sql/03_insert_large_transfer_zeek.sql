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
  `@timestamp` STRING,
  `event.kind` STRING,
  `event.category` ARRAY<STRING>,
  `event.type` ARRAY<STRING>,
  `event.module` STRING,
  `event.dataset` STRING,
  `event.severity` INT,
  `rule.id` STRING,
  `rule.name` STRING,
  `message` STRING,
  `source.ip` STRING,
  `destination.ip` STRING,
  `related.ip` ARRAY<STRING>,
  `pipeline` STRING,
  evidence STRING
) WITH (
  'connector' = 'kafka',
  'topic' = 'siem.alerts',
  'properties.bootstrap.servers' = 'kafka:29092',
  'format' = 'json',
  'json.timestamp-format.standard' = 'ISO-8601'
);

INSERT INTO siem_alerts_sink
SELECT
  `@timestamp`,
  'alert' AS `event.kind`,
  ARRAY['network'] AS `event.category`,
  ARRAY['indicator'] AS `event.type`,
  'flink' AS `event.module`,
  'siem.alert' AS `event.dataset`,
  3 AS `event.severity`,
  'flink.zeek.large_transfer' AS `rule.id`,
  CONCAT('zeek.large_transfer.', COALESCE(`network.transport`, 'unknown')) AS `rule.name`,
  CONCAT(
    'Large transfer detected from ',
    COALESCE(`source.ip`, 'unknown'),
    ' to ',
    COALESCE(`destination.ip`, 'unknown')
  ) AS `message`,
  `source.ip`,
  `destination.ip`,
  ARRAY[`source.ip`, `destination.ip`] AS `related.ip`,
  'flink.zeek.large_transfer' AS `pipeline`,
  `message` AS evidence
FROM zeek_conn_src
WHERE `network.bytes` IS NOT NULL
  AND `network.bytes` > 1000000;
