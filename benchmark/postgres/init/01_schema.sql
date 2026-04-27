CREATE SCHEMA IF NOT EXISTS siem_benchmark;

CREATE TABLE IF NOT EXISTS siem_benchmark.events (
  id BIGSERIAL PRIMARY KEY,
  benchmark_id TEXT NOT NULL,
  event_id TEXT NOT NULL,
  event_timestamp TIMESTAMPTZ NOT NULL,
  event_dataset TEXT NOT NULL,
  event_module TEXT,
  event_kind TEXT,
  event_severity INTEGER,
  source_ip INET,
  destination_ip INET,
  rule_id TEXT,
  rule_name TEXT,
  network_bytes BIGINT,
  message TEXT,
  event_original TEXT,
  payload JSONB NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_benchmark_events_event_id
  ON siem_benchmark.events (benchmark_id, event_id);
CREATE INDEX IF NOT EXISTS idx_benchmark_events_timestamp
  ON siem_benchmark.events (event_timestamp);
CREATE INDEX IF NOT EXISTS idx_benchmark_events_dataset
  ON siem_benchmark.events (event_dataset);
CREATE INDEX IF NOT EXISTS idx_benchmark_events_source_ip
  ON siem_benchmark.events (source_ip);
CREATE INDEX IF NOT EXISTS idx_benchmark_events_destination_ip
  ON siem_benchmark.events (destination_ip);
CREATE INDEX IF NOT EXISTS idx_benchmark_events_severity
  ON siem_benchmark.events (event_severity);
CREATE INDEX IF NOT EXISTS idx_benchmark_events_rule_id
  ON siem_benchmark.events (rule_id);
CREATE INDEX IF NOT EXISTS idx_benchmark_events_benchmark_id
  ON siem_benchmark.events (benchmark_id);
CREATE INDEX IF NOT EXISTS idx_benchmark_events_payload_gin
  ON siem_benchmark.events USING GIN (payload jsonb_path_ops);

CREATE TABLE IF NOT EXISTS siem_benchmark.alerts (
  id BIGSERIAL PRIMARY KEY,
  benchmark_id TEXT NOT NULL,
  alert_id TEXT NOT NULL,
  event_timestamp TIMESTAMPTZ NOT NULL,
  event_dataset TEXT NOT NULL,
  event_module TEXT,
  event_kind TEXT,
  event_severity INTEGER,
  source_ip INET,
  destination_ip INET,
  rule_id TEXT,
  rule_name TEXT,
  network_bytes BIGINT,
  message TEXT,
  event_original TEXT,
  payload JSONB NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_benchmark_alerts_alert_id
  ON siem_benchmark.alerts (benchmark_id, alert_id);
CREATE INDEX IF NOT EXISTS idx_benchmark_alerts_timestamp
  ON siem_benchmark.alerts (event_timestamp);
CREATE INDEX IF NOT EXISTS idx_benchmark_alerts_dataset
  ON siem_benchmark.alerts (event_dataset);
CREATE INDEX IF NOT EXISTS idx_benchmark_alerts_source_ip
  ON siem_benchmark.alerts (source_ip);
CREATE INDEX IF NOT EXISTS idx_benchmark_alerts_destination_ip
  ON siem_benchmark.alerts (destination_ip);
CREATE INDEX IF NOT EXISTS idx_benchmark_alerts_severity
  ON siem_benchmark.alerts (event_severity);
CREATE INDEX IF NOT EXISTS idx_benchmark_alerts_rule_id
  ON siem_benchmark.alerts (rule_id);
CREATE INDEX IF NOT EXISTS idx_benchmark_alerts_benchmark_id
  ON siem_benchmark.alerts (benchmark_id);
CREATE INDEX IF NOT EXISTS idx_benchmark_alerts_payload_gin
  ON siem_benchmark.alerts USING GIN (payload jsonb_path_ops);
