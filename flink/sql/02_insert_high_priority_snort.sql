ADD JAR 'file:///opt/flink/usrlib/flink-sql-connector-kafka-3.2.0-1.19.jar';

CREATE TEMPORARY TABLE snort_alert_src (
  `@timestamp` STRING,
  `rule.name` STRING,
  `event.severity` INT,
  `source.ip` STRING,
  `destination.ip` STRING,
  `message` STRING
) WITH (
  'connector' = 'kafka',
  'topic' = 'snort.alert',
  'properties.bootstrap.servers' = 'kafka:29092',
  'properties.group.id' = 'flink-snort-src',
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
  ARRAY['intrusion_detection'] AS `event.category`,
  ARRAY['indicator'] AS `event.type`,
  'flink' AS `event.module`,
  'siem.alert' AS `event.dataset`,
  `event.severity`,
  'flink.snort.high_priority' AS `rule.id`,
  COALESCE(`rule.name`, 'snort.high_priority') AS `rule.name`,
  CONCAT('High priority Snort alert: ', COALESCE(`rule.name`, 'snort.high_priority')) AS `message`,
  `source.ip`,
  `destination.ip`,
  ARRAY[`source.ip`, `destination.ip`] AS `related.ip`,
  'flink.snort.high_priority' AS `pipeline`,
  `message` AS evidence
FROM snort_alert_src
WHERE `event.severity` IS NOT NULL
  AND `event.severity` <= 2;
