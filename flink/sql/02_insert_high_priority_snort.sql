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
  COALESCE(`rule.name`, 'snort.alert') AS rule_name,
  `source.ip` AS source_ip,
  `destination.ip` AS destination_ip,
  `event.severity` AS severity,
  `message` AS evidence,
  'flink.snort.high_priority' AS pipeline
FROM snort_alert_src
WHERE `event.severity` IS NOT NULL
  AND `event.severity` <= 2;
