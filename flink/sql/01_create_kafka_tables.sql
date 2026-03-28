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
