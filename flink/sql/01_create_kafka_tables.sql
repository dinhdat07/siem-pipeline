ADD JAR 'file:///opt/flink/usrlib/flink-sql-connector-kafka-3.2.0-1.19.jar';

CREATE TABLE zeek_conn_src (
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

CREATE TABLE snort_alert_src (
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

CREATE TABLE siem_alerts_sink (
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
