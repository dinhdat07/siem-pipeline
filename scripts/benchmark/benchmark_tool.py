#!/usr/bin/env python3
import argparse
import csv
import json
import math
import os
import random
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable
from urllib import error, parse, request

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCHMARK_POSTGRES_SCHEMA_PATH = REPO_ROOT / "benchmark" / "postgres" / "init" / "01_schema.sql"

DEFAULT_EVENT_SOURCES = [
    "data/sample/conn-logs/zeek_conn_sample.jsonl",
    "data/sample/snort-alerts/snort_alerts_sample.jsonl",
    "data/test/phase35/hot/zeek_conn_hot_smoke.jsonl",
    "data/test/phase35/hot/snort_alert_hot_smoke.jsonl",
    "data/test/phase35/cold/zeek_conn_cold_smoke.jsonl",
    "data/test/phase35/cold/snort_alert_cold_smoke.jsonl",
    "data/test/phase35/detections/zeek_conn_detection_smoke.jsonl",
    "data/test/phase35/detections/snort_alert_detection_smoke.jsonl",
]

SIZE_MULTIPLIERS = {
    "small": 1,
    "medium": 10,
    "large": 50,
    "single-1m": None,
    "distributed-1m": None,
    "distributed-3m": None,
}

SIZE_TARGET_EVENT_COUNTS = {
    "single-1m": 1_000_000,
    "distributed-1m": 1_000_000,
    "distributed-3m": 3_000_000,
}


@dataclass
class QueryDefinition:
    name: str
    description: str
    kind: str
    index_or_table: str
    payload: Any


def die(message: str) -> None:
    print(f"[ERROR] {message}", file=sys.stderr)
    raise SystemExit(1)


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    return rows


def iter_jsonl(path: Path):
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line:
                yield json.loads(line)


def write_json(path: Path, payload: Any) -> None:
    ensure_dir(path.parent)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    ensure_dir(path.parent)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True))
            handle.write("\n")


def write_jsonl_row(handle: Any, row: dict[str, Any]) -> None:
    handle.write(json.dumps(row, sort_keys=True))
    handle.write("\n")


def ensure_postgres_benchmark_schema(conn: Any) -> None:
    schema_sql = BENCHMARK_POSTGRES_SCHEMA_PATH.read_text(encoding="utf-8")
    with conn.cursor() as cur:
        cur.execute(schema_sql)
    conn.commit()


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * pct
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[int(position)]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def parse_ts(value: str) -> datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def isoformat_z(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def promoted_severity(record: dict[str, Any]) -> int | None:
    severity = record.get("event.severity")
    if severity is not None:
        try:
            return int(severity)
        except (TypeError, ValueError):
            return None
    return None


def benchmark_tag(record: dict[str, Any], benchmark_id: str, size: str, cycle: int, seq: int) -> None:
    record["benchmark.id"] = benchmark_id
    record["benchmark.size"] = size
    record["benchmark.cycle"] = cycle
    record["benchmark.seq"] = seq
    record.setdefault("event.id", f"{benchmark_id}-event-{seq}")


def make_prefix_search_term(message_term: str) -> str:
    words = [word for word in message_term.split() if word]
    if not words:
        return message_term
    if len(words) >= 3 and len(words[-1]) >= 3:
        words[-1] = words[-1][:3]
        return " ".join(words)
    return " ".join(words[:1])


def make_fuzzy_search_term(message_term: str) -> str:
    words = [word for word in message_term.split() if word]
    if not words:
        return message_term
    last = words[-1]
    if len(last) > 1:
        words[-1] = last[:-1]
    return " ".join(words)


def derive_rule_family(record: dict[str, Any]) -> tuple[str, str, str, int]:
    dataset = record.get("event.dataset", "unknown")
    message = (record.get("message") or "").lower()
    network_bytes = int(record.get("network.bytes") or 0)
    severity = promoted_severity(record)

    if dataset == "snort.alert":
        rule_id = record.get("rule.id") or "benchmark.snort.alert"
        rule_name = record.get("rule.name") or "benchmark.snort"
        rule_category = record.get("rule.category") or "intrusion_detection"
        return rule_id, rule_name, rule_category, severity if severity is not None else 2

    if network_bytes >= 1_000_000:
        return "benchmark.zeek.large_transfer", "benchmark.large_transfer", "network_volume", 2
    if "http" in message and record.get("destination.port") not in (80, 8080, 8000, 8888):
        return "benchmark.zeek.protocol_anomaly", "benchmark.protocol_anomaly", "protocol_anomaly", 3
    if dataset == "zeek.conn":
        return "benchmark.zeek.connection", "benchmark.connection", "network", 3
    return "benchmark.generic", "benchmark.generic", "generic", 3


def build_alert(record: dict[str, Any], benchmark_id: str, size: str, cycle: int, seq: int) -> dict[str, Any]:
    ts = parse_ts(record["@timestamp"]) + timedelta(seconds=2)
    rule_id, rule_name, rule_category, severity = derive_rule_family(record)
    source_ip = record.get("source.ip")
    destination_ip = record.get("destination.ip")
    network_bytes = int(record.get("network.bytes") or 0)
    related_ips = [ip for ip in [source_ip, destination_ip] if ip]
    return {
        "@timestamp": isoformat_z(ts),
        "benchmark.id": benchmark_id,
        "benchmark.size": size,
        "benchmark.cycle": cycle,
        "benchmark.seq": seq,
        "event.kind": "alert",
        "event.category": [rule_category],
        "event.type": ["indicator"],
        "event.module": "benchmark",
        "event.dataset": "siem.alert",
        "event.severity": severity,
        "rule.id": rule_id,
        "rule.name": rule_name,
        "rule.category": rule_category,
        "source.ip": source_ip,
        "destination.ip": destination_ip,
        "network.bytes": network_bytes,
        "alert.reason": f"Benchmark-derived alert for {record.get('event.dataset', 'event')}.",
        "alert.evidence": f"event_id={record.get('event.id')} dataset={record.get('event.dataset')} bytes={network_bytes}",
        "alert.count": 1,
        "window.start": record["@timestamp"],
        "window.end": isoformat_z(ts),
        "related.ip": related_ips,
        "pipeline": "benchmark.synthetic",
        "message": f"Benchmark alert for {rule_name}",
        "event.original": json.dumps(record, sort_keys=True),
        "event.id": f"{benchmark_id}-alert-{seq}",
    }


def prepare_data(args: argparse.Namespace) -> None:
    output_dir = Path(args.output_dir)
    ensure_dir(output_dir)
    event_sources = [Path(path) for path in (args.event_source or DEFAULT_EVENT_SOURCES)]
    base_events: list[dict[str, Any]] = []
    skipped_without_timestamp = 0
    for source in event_sources:
        if not source.exists():
            die(f"missing benchmark event source: {source}")
        for row in read_jsonl(source):
            if "@timestamp" not in row:
                skipped_without_timestamp += 1
                continue
            base_events.append(row)

    if not base_events:
        die("no benchmark source events were loaded")

    explicit_target = args.target_events if args.target_events and args.target_events > 0 else None
    target_event_count = explicit_target or SIZE_TARGET_EVENT_COUNTS.get(args.size)
    multiplier = SIZE_MULTIPLIERS.get(args.size)
    if target_event_count is None:
        assert multiplier is not None
        target_event_count = len(base_events) * multiplier
    else:
        multiplier = math.ceil(target_event_count / len(base_events))

    benchmark_id = args.benchmark_id or f"phase5-{args.size}"
    seq = 0
    alert_count = 0
    dataset_values: set[str] = set()
    sample_source_ip = None
    sample_destination_ip = None
    start_ts = None
    end_ts = None
    first_event: dict[str, Any] | None = None

    paths = {
        "events": output_dir / "events.jsonl",
        "zeek": output_dir / "events.zeek.jsonl",
        "snort": output_dir / "events.snort.jsonl",
        "alerts": output_dir / "alerts.jsonl",
        "events_bulk": output_dir / "events.bulk.ndjson",
        "alerts_bulk": output_dir / "alerts.bulk.ndjson",
    }

    for path in paths.values():
        ensure_dir(path.parent)

    with (
        paths["events"].open("w", encoding="utf-8") as events_handle,
        paths["zeek"].open("w", encoding="utf-8") as zeek_handle,
        paths["snort"].open("w", encoding="utf-8") as snort_handle,
        paths["alerts"].open("w", encoding="utf-8") as alerts_handle,
        paths["events_bulk"].open("w", encoding="utf-8") as events_bulk_handle,
        paths["alerts_bulk"].open("w", encoding="utf-8") as alerts_bulk_handle,
    ):
        while seq < target_event_count:
            cycle = seq // len(base_events)
            cycle_offset = timedelta(minutes=cycle)
            event = base_events[seq % len(base_events)]
            seq += 1
            cloned = json.loads(json.dumps(event))
            shifted_ts = parse_ts(cloned["@timestamp"]) + cycle_offset
            cloned["@timestamp"] = isoformat_z(shifted_ts)
            benchmark_tag(cloned, benchmark_id, args.size, cycle, seq)

            if first_event is None:
                first_event = cloned
            event_ts = parse_ts(cloned["@timestamp"])
            start_ts = event_ts if start_ts is None else min(start_ts, event_ts)
            end_ts = event_ts if end_ts is None else max(end_ts, event_ts)
            if sample_source_ip is None and cloned.get("source.ip"):
                sample_source_ip = cloned.get("source.ip")
            if sample_destination_ip is None and cloned.get("destination.ip"):
                sample_destination_ip = cloned.get("destination.ip")
            if cloned.get("event.dataset"):
                dataset_values.add(cloned["event.dataset"])

            write_jsonl_row(events_handle, cloned)
            if cloned.get("event.dataset") == "zeek.conn":
                write_jsonl_row(zeek_handle, cloned)
            if cloned.get("event.dataset") == "snort.alert":
                write_jsonl_row(snort_handle, cloned)

            events_bulk_handle.write(json.dumps({"index": {"_id": cloned["event.id"]}}))
            events_bulk_handle.write("\n")
            events_bulk_handle.write(json.dumps(cloned, sort_keys=True))
            events_bulk_handle.write("\n")

            if seq % max(1, args.alert_every) == 0:
                alert = build_alert(cloned, benchmark_id, args.size, cycle, seq)
                write_jsonl_row(alerts_handle, alert)
                alerts_bulk_handle.write(json.dumps({"index": {"_id": alert["event.id"]}}))
                alerts_bulk_handle.write("\n")
                alerts_bulk_handle.write(json.dumps(alert, sort_keys=True))
                alerts_bulk_handle.write("\n")
                alert_count += 1

        if alert_count == 0 and first_event is not None:
            alert = build_alert(first_event, benchmark_id, args.size, 0, 1)
            write_jsonl_row(alerts_handle, alert)
            alerts_bulk_handle.write(json.dumps({"index": {"_id": alert["event.id"]}}))
            alerts_bulk_handle.write("\n")
            alerts_bulk_handle.write(json.dumps(alert, sort_keys=True))
            alerts_bulk_handle.write("\n")
            alert_count = 1

    assert start_ts is not None
    assert end_ts is not None
    mid_ts = start_ts + (end_ts - start_ts) / 2

    metadata = {
        "benchmark_id": benchmark_id,
        "size": args.size,
        "multiplier": multiplier,
        "target_event_count": target_event_count,
        "event_count": seq,
        "alert_count": alert_count,
        "source_files": [str(path) for path in event_sources],
        "dataset_values": sorted(dataset_values),
        "sample_source_ip": sample_source_ip,
        "sample_destination_ip": sample_destination_ip,
        "message_search_term": args.message_search_term,
        "autocomplete_search_term": make_prefix_search_term(args.message_search_term),
        "fuzzy_search_term": make_fuzzy_search_term(args.message_search_term),
        "time_range_start": isoformat_z(start_ts),
        "time_range_mid": isoformat_z(mid_ts),
        "time_range_end": isoformat_z(end_ts),
        "prepared_at": isoformat_z(datetime.now(timezone.utc)),
    }
    write_json(output_dir / "metadata.json", metadata)
    write_json(
        output_dir / "prepare-summary.json",
        {
            "benchmark_id": benchmark_id,
            "size": args.size,
            "target_event_count": target_event_count,
            "event_count": seq,
            "alert_count": alert_count,
            "skipped_without_timestamp": skipped_without_timestamp,
            "output_dir": str(output_dir),
        },
    )


def http_json(method: str, url: str, payload: Any | None = None, headers: dict[str, str] | None = None) -> tuple[int, Any]:
    request_headers = {"Content-Type": "application/json"}
    if headers:
        request_headers.update(headers)
    data = None
    if payload is not None:
        if isinstance(payload, (bytes, bytearray)):
            data = payload
        else:
            data = json.dumps(payload).encode("utf-8")
    req = request.Request(url, method=method, data=data, headers=request_headers)
    try:
        with request.urlopen(req, timeout=60) as response:
            body = response.read()
            content = body.decode("utf-8") if body else ""
            parsed = json.loads(content) if content else None
            return response.status, parsed
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} for {url}: {body}") from exc


def http_bytes(method: str, url: str, payload: bytes) -> tuple[int, str]:
    req = request.Request(url, method=method, data=payload, headers={"Content-Type": "application/x-ndjson"})
    try:
        with request.urlopen(req, timeout=300) as response:
            return response.status, response.read().decode("utf-8")
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} for {url}: {body}") from exc


EVENT_INDEX = "siem-benchmark-events"
ALERT_INDEX = "siem-benchmark-alerts"
DEFAULT_ES_BULK_CHUNK_BYTES = int(os.environ.get("BENCHMARK_ES_BULK_CHUNK_BYTES", str(8 * 1024 * 1024)))
DEFAULT_ES_BULK_RETRIES = int(os.environ.get("BENCHMARK_ES_BULK_RETRIES", "3"))


def set_index_refresh_interval(base_url: str, index_name: str, refresh_interval: str) -> None:
    http_json("PUT", f"{base_url}/{index_name}/_settings", {"index": {"refresh_interval": refresh_interval}})


def is_retriable_bulk_exception(exc: Exception) -> bool:
    if isinstance(exc, error.URLError):
        return True
    message = str(exc)
    return any(message.startswith(f"HTTP {status}") for status in (408, 429, 500, 502, 503, 504))


def post_bulk_chunk(bulk_url: str, payload: bytes, label: str, chunk_number: int, retries: int) -> None:
    attempt = 0
    while True:
        attempt += 1
        try:
            status, body = http_bytes("POST", bulk_url, payload)
            if status != 200 or '"errors":true' in body:
                raise RuntimeError(f"Elasticsearch {label} bulk load failed in chunk {chunk_number}: {body[:1000]}")
            return
        except Exception as exc:
            if attempt > retries + 1 or not is_retriable_bulk_exception(exc):
                raise
            time.sleep(min(8.0, 2 ** (attempt - 1)))


def upload_bulk_file(
    base_url: str,
    index_name: str,
    bulk_path: Path,
    label: str,
    max_chunk_bytes: int = DEFAULT_ES_BULK_CHUNK_BYTES,
    retries: int = DEFAULT_ES_BULK_RETRIES,
) -> int:
    if max_chunk_bytes <= 0:
        raise ValueError("max_chunk_bytes must be greater than zero")

    bulk_url = f"{base_url}/{index_name}/_bulk?filter_path=errors"
    chunk: list[bytes] = []
    chunk_bytes = 0
    chunk_count = 0

    def flush_chunk() -> None:
        nonlocal chunk
        nonlocal chunk_bytes
        nonlocal chunk_count

        if not chunk:
            return

        post_bulk_chunk(bulk_url, b"".join(chunk), label, chunk_count + 1, retries)
        chunk = []
        chunk_bytes = 0
        chunk_count += 1

    with bulk_path.open("rb") as handle:
        while True:
            action_line = handle.readline()
            if not action_line:
                break

            document_line = handle.readline()
            if not document_line:
                raise RuntimeError(f"Malformed bulk payload in {bulk_path}: missing document line after action line")

            pair_size = len(action_line) + len(document_line)
            if chunk and chunk_bytes + pair_size > max_chunk_bytes:
                flush_chunk()

            chunk.extend((action_line, document_line))
            chunk_bytes += pair_size

    flush_chunk()
    http_json("POST", f"{base_url}/{index_name}/_refresh")
    return chunk_count


def load_elasticsearch(args: argparse.Namespace) -> None:
    events_bulk = Path(args.events_bulk)
    alerts_bulk = Path(args.alerts_bulk)
    metadata = json.loads(Path(args.metadata).read_text(encoding="utf-8"))
    benchmark_id = metadata["benchmark_id"]
    base_url = args.elasticsearch_url.rstrip("/")

    for index_name in [f"{EVENT_INDEX}-000001", f"{ALERT_INDEX}-000001"]:
        try:
            http_json("DELETE", f"{base_url}/{index_name}")
        except RuntimeError as exc:
            if "404" not in str(exc):
                raise

    concrete_indices = {
        EVENT_INDEX: f"{EVENT_INDEX}-000001",
        ALERT_INDEX: f"{ALERT_INDEX}-000001",
    }
    index_settings = {
        "number_of_shards": int(os.environ.get("BENCHMARK_ES_SHARDS", "1")),
        "number_of_replicas": int(os.environ.get("BENCHMARK_ES_REPLICAS", "0")),
    }
    include_node_names = os.environ.get("BENCHMARK_ES_INCLUDE_NODE_NAMES", "").strip()
    if include_node_names:
        # Pin benchmark indices to a chosen subset of ES nodes for fair node-scaling tests.
        index_settings["index.routing.allocation.include._name"] = include_node_names

    for alias, concrete in concrete_indices.items():
        http_json(
            "PUT",
            f"{base_url}/{concrete}",
            {
                "settings": index_settings,
                "aliases": {
                    alias: {"is_write_index": True}
                }
            },
        )

    for concrete in concrete_indices.values():
        set_index_refresh_interval(base_url, concrete, "-1")

    try:
        started = time.perf_counter()
        event_bulk_chunks = upload_bulk_file(base_url, EVENT_INDEX, events_bulk, "event")
        event_duration = time.perf_counter() - started

        started = time.perf_counter()
        alert_bulk_chunks = upload_bulk_file(base_url, ALERT_INDEX, alerts_bulk, "alert")
        alert_duration = time.perf_counter() - started
    finally:
        for concrete in concrete_indices.values():
            set_index_refresh_interval(base_url, concrete, "5s")

    write_json(
        Path(args.output_json),
        {
            "backend": "elasticsearch",
            "benchmark_id": benchmark_id,
            "event_index": EVENT_INDEX,
            "alert_index": ALERT_INDEX,
            "event_bulk_chunks": event_bulk_chunks,
            "alert_bulk_chunks": alert_bulk_chunks,
            "event_bulk_seconds": round(event_duration, 6),
            "alert_bulk_seconds": round(alert_duration, 6),
            "event_rows_per_second": round(metadata["event_count"] / event_duration, 2) if event_duration else 0,
            "alert_rows_per_second": round(metadata["alert_count"] / alert_duration, 2) if alert_duration else 0,
            "allocation_include_node_names": include_node_names.split(",") if include_node_names else [],
        },
    )


class PostgresClient:
    def __init__(self, dsn: str):
        try:
            import psycopg
        except ImportError as exc:
            raise RuntimeError("psycopg is required. Install benchmark/requirements.txt") from exc
        self.psycopg = psycopg
        self.dsn = dsn

    def connect(self):
        return self.psycopg.connect(self.dsn)


def load_postgres(args: argparse.Namespace) -> None:
    client = PostgresClient(args.postgres_dsn)
    events_path = Path(args.events_jsonl)
    alerts_path = Path(args.alerts_jsonl)
    metadata = json.loads(Path(args.metadata).read_text(encoding="utf-8"))
    benchmark_id = metadata["benchmark_id"]

    with client.connect() as conn:
        ensure_postgres_benchmark_schema(conn)
        with conn.cursor() as cur:
            cur.execute("DELETE FROM siem_benchmark.alerts WHERE benchmark_id = %s", (benchmark_id,))
            cur.execute("DELETE FROM siem_benchmark.events WHERE benchmark_id = %s", (benchmark_id,))
        conn.commit()

        event_started = time.perf_counter()
        with conn.cursor() as cur:
            with cur.copy(
                "COPY siem_benchmark.events (benchmark_id, event_id, event_timestamp, event_dataset, event_module, event_kind, event_severity, source_ip, destination_ip, rule_id, rule_name, network_bytes, message, event_original, payload) FROM STDIN"
            ) as copy:
                for row in iter_jsonl(events_path):
                    copy.write_row((
                        benchmark_id,
                        row.get("event.id"),
                        row.get("@timestamp"),
                        row.get("event.dataset"),
                        row.get("event.module"),
                        row.get("event.kind"),
                        row.get("event.severity"),
                        row.get("source.ip"),
                        row.get("destination.ip"),
                        row.get("rule.id"),
                        row.get("rule.name"),
                        row.get("network.bytes"),
                        row.get("message"),
                        row.get("event.original"),
                        json.dumps(row, sort_keys=True),
                    ))
        conn.commit()
        event_duration = time.perf_counter() - event_started

        alert_started = time.perf_counter()
        with conn.cursor() as cur:
            with cur.copy(
                "COPY siem_benchmark.alerts (benchmark_id, alert_id, event_timestamp, event_dataset, event_module, event_kind, event_severity, source_ip, destination_ip, rule_id, rule_name, network_bytes, message, event_original, payload) FROM STDIN"
            ) as copy:
                for row in iter_jsonl(alerts_path):
                    copy.write_row((
                        benchmark_id,
                        row.get("event.id"),
                        row.get("@timestamp"),
                        row.get("event.dataset"),
                        row.get("event.module"),
                        row.get("event.kind"),
                        row.get("event.severity"),
                        row.get("source.ip"),
                        row.get("destination.ip"),
                        row.get("rule.id"),
                        row.get("rule.name"),
                        row.get("network.bytes"),
                        row.get("message"),
                        row.get("event.original"),
                        json.dumps(row, sort_keys=True),
                    ))
        conn.commit()
        alert_duration = time.perf_counter() - alert_started

    write_json(
        Path(args.output_json),
        {
            "backend": "postgres",
            "benchmark_id": benchmark_id,
            "event_copy_seconds": round(event_duration, 6),
            "alert_copy_seconds": round(alert_duration, 6),
            "event_rows_per_second": round(metadata["event_count"] / event_duration, 2) if event_duration else 0,
            "alert_rows_per_second": round(metadata["alert_count"] / alert_duration, 2) if alert_duration else 0,
        },
    )


def build_query_definitions(metadata: dict[str, Any], backend: str, suite: str = "baseline") -> list[QueryDefinition]:
    benchmark_id = metadata["benchmark_id"]
    dataset = metadata["dataset_values"][0]
    source_ip = metadata["sample_source_ip"]
    destination_ip = metadata["sample_destination_ip"]
    time_start = metadata["time_range_start"]
    time_mid = metadata["time_range_mid"]
    time_end = metadata["time_range_end"]
    message_term = metadata["message_search_term"]
    prefix_term = metadata.get("autocomplete_search_term", message_term)
    fuzzy_term = metadata.get("fuzzy_search_term", message_term)

    if suite == "showcase":
        pivot_ip = source_ip
        combined_text_fields = ["message", "event.original"]
        combined_text_clause = {
            "combined_fields": {
                "query": message_term,
                "fields": combined_text_fields,
                "operator": "and",
            }
        }
        combined_text_sql = "to_tsvector('simple', COALESCE(message, '') || ' ' || COALESCE(event_original, '')) @@ plainto_tsquery('simple', %s)"
        if backend == "elasticsearch":
            phrase_filter = {
                "bool": {
                    "filter": [
                        {"term": {"benchmark.id": benchmark_id}},
                        {"range": {"@timestamp": {"gte": time_start, "lte": time_end}}},
                    ],
                    "must": [
                        combined_text_clause,
                    ],
                }
            }
            return [
                QueryDefinition(
                    "multi_field_latest_hits",
                    "Latest hits for a combined message and raw-event investigation search",
                    "es_search",
                    EVENT_INDEX,
                    {
                        "size": 25,
                        "track_total_hits": False,
                        "sort": [{"@timestamp": {"order": "desc"}}],
                        "query": phrase_filter,
                    },
                ),
                QueryDefinition(
                    "autocomplete_latest_hits",
                    "Latest hits for a search-as-you-type prefix investigation",
                    "es_search",
                    EVENT_INDEX,
                    {
                        "size": 25,
                        "track_total_hits": False,
                        "sort": [{"@timestamp": {"order": "desc"}}],
                        "query": {
                            "bool": {
                                "filter": [
                                    {"term": {"benchmark.id": benchmark_id}},
                                    {"range": {"@timestamp": {"gte": time_start, "lte": time_end}}},
                                ],
                                "must": [
                                    {
                                        "multi_match": {
                                            "query": prefix_term,
                                            "type": "bool_prefix",
                                            "fields": [
                                                "message.autocomplete",
                                                "message.autocomplete._2gram",
                                                "message.autocomplete._3gram",
                                            ],
                                        }
                                    }
                                ],
                            }
                        },
                    },
                ),
                QueryDefinition(
                    "fuzzy_latest_hits",
                    "Latest hits for a fuzzy typo-tolerant investigation",
                    "es_search",
                    EVENT_INDEX,
                    {
                        "size": 25,
                        "track_total_hits": False,
                        "sort": [{"@timestamp": {"order": "desc"}}],
                        "query": {
                            "bool": {
                                "filter": [
                                    {"term": {"benchmark.id": benchmark_id}},
                                    {"range": {"@timestamp": {"gte": time_start, "lte": time_end}}},
                                ],
                                "must": [
                                    {
                                        "match": {
                                            "message": {
                                                "query": fuzzy_term,
                                                "fuzziness": "AUTO",
                                                "prefix_length": 1,
                                            }
                                        }
                                    }
                                ],
                            }
                        },
                    },
                ),
                QueryDefinition(
                    "search_facet_top_destination_ports",
                    "Top destination ports within combined search results",
                    "es_search",
                    EVENT_INDEX,
                    {
                        "size": 0,
                        "query": phrase_filter,
                        "aggs": {
                            "top_destination_ports": {
                                "terms": {"field": "destination.port", "size": 10}
                            }
                        },
                    },
                ),
                QueryDefinition(
                    "search_facet_top_source_ips",
                    "Top source IPs within combined search results",
                    "es_search",
                    EVENT_INDEX,
                    {
                        "size": 0,
                        "query": phrase_filter,
                        "aggs": {
                            "top_source_ips": {
                                "terms": {"field": "source.ip", "size": 10}
                            }
                        },
                    },
                ),
                QueryDefinition(
                    "search_timeline_histogram",
                    "Timeline histogram for combined search results",
                    "es_search",
                    EVENT_INDEX,
                    {
                        "size": 0,
                        "query": phrase_filter,
                        "aggs": {
                            "timeline": {
                                "date_histogram": {
                                    "field": "@timestamp",
                                    "fixed_interval": "1m",
                                    "min_doc_count": 1,
                                }
                            }
                        },
                    },
                ),
                QueryDefinition(
                    "ip_pivot_latest_hits",
                    "Latest hits for a pivot IP across source or destination",
                    "es_search",
                    EVENT_INDEX,
                    {
                        "size": 25,
                        "track_total_hits": False,
                        "sort": [{"@timestamp": {"order": "desc"}}],
                        "query": {
                            "bool": {
                                "filter": [
                                    {"term": {"benchmark.id": benchmark_id}},
                                    {"range": {"@timestamp": {"gte": time_start, "lte": time_end}}},
                                ],
                                "should": [
                                    {"term": {"source.ip": pivot_ip}},
                                    {"term": {"destination.ip": pivot_ip}},
                                ],
                                "minimum_should_match": 1,
                            }
                        },
                    },
                ),
            ]

        return [
            QueryDefinition(
                "multi_field_latest_hits",
                "Latest hits for a combined message and raw-event investigation search",
                "pg",
                "events",
                (
                    f"SELECT event_id, event_timestamp FROM siem_benchmark.events WHERE benchmark_id = %s AND event_timestamp BETWEEN %s AND %s AND {combined_text_sql} ORDER BY event_timestamp DESC LIMIT 25",
                    [benchmark_id, time_start, time_end, message_term],
                ),
            ),
            QueryDefinition(
                "autocomplete_latest_hits",
                "Latest hits for a search-as-you-type prefix investigation",
                "pg",
                "events",
                (
                    "SELECT event_id, event_timestamp FROM siem_benchmark.events WHERE benchmark_id = %s AND event_timestamp BETWEEN %s AND %s AND lower(message) LIKE lower(%s) || '%%' ORDER BY event_timestamp DESC LIMIT 25",
                    [benchmark_id, time_start, time_end, prefix_term],
                ),
            ),
            QueryDefinition(
                "fuzzy_latest_hits",
                "Latest hits for a fuzzy typo-tolerant investigation",
                "pg",
                "events",
                (
                    "SELECT event_id, event_timestamp FROM siem_benchmark.events WHERE benchmark_id = %s AND event_timestamp BETWEEN %s AND %s AND lower(message) %% lower(%s) ORDER BY similarity(lower(message), lower(%s)) DESC, event_timestamp DESC LIMIT 25",
                    [benchmark_id, time_start, time_end, fuzzy_term, fuzzy_term],
                ),
            ),
            QueryDefinition(
                "search_facet_top_destination_ports",
                "Top destination ports within combined search results",
                "pg",
                "events",
                (
                    f"SELECT NULLIF(payload ->> 'destination.port', '')::integer AS destination_port, COUNT(*) FROM siem_benchmark.events WHERE benchmark_id = %s AND event_timestamp BETWEEN %s AND %s AND payload ? 'destination.port' AND NULLIF(payload ->> 'destination.port', '') IS NOT NULL AND {combined_text_sql} GROUP BY destination_port ORDER BY COUNT(*) DESC LIMIT 10",
                    [benchmark_id, time_start, time_end, message_term],
                ),
            ),
            QueryDefinition(
                "search_facet_top_source_ips",
                "Top source IPs within combined search results",
                "pg",
                "events",
                (
                    f"SELECT source_ip, COUNT(*) FROM siem_benchmark.events WHERE benchmark_id = %s AND event_timestamp BETWEEN %s AND %s AND {combined_text_sql} GROUP BY source_ip ORDER BY COUNT(*) DESC LIMIT 10",
                    [benchmark_id, time_start, time_end, message_term],
                ),
            ),
            QueryDefinition(
                "search_timeline_histogram",
                "Timeline histogram for combined search results",
                "pg",
                "events",
                (
                    f"SELECT date_trunc('minute', event_timestamp) AS minute_bucket, COUNT(*) FROM siem_benchmark.events WHERE benchmark_id = %s AND event_timestamp BETWEEN %s AND %s AND {combined_text_sql} GROUP BY minute_bucket ORDER BY minute_bucket DESC LIMIT 120",
                    [benchmark_id, time_start, time_end, message_term],
                ),
            ),
            QueryDefinition(
                "ip_pivot_latest_hits",
                "Latest hits for a pivot IP across source or destination",
                "pg",
                "events",
                (
                    "SELECT event_id, event_timestamp FROM siem_benchmark.events WHERE benchmark_id = %s AND event_timestamp BETWEEN %s AND %s AND (source_ip = %s OR destination_ip = %s) ORDER BY event_timestamp DESC LIMIT 25",
                    [benchmark_id, time_start, time_end, pivot_ip, pivot_ip],
                ),
            ),
        ]

    if backend == "elasticsearch":
        return [
            QueryDefinition(
                "time_range_search",
                "Time-range event search",
                "es_search",
                EVENT_INDEX,
                {
                    "size": 50,
                    "sort": [{"@timestamp": {"order": "desc"}}],
                    "query": {"bool": {"filter": [
                        {"term": {"benchmark.id": benchmark_id}},
                        {"range": {"@timestamp": {"gte": time_start, "lte": time_mid}}}
                    ]}},
                },
            ),
            QueryDefinition("filter_by_dataset", "Filter events by dataset", "es_count", EVENT_INDEX, {"query": {"bool": {"filter": [{"term": {"benchmark.id": benchmark_id}}, {"term": {"event.dataset": dataset}}]}}}),
            QueryDefinition("filter_by_source_ip", "Filter events by source IP", "es_count", EVENT_INDEX, {"query": {"bool": {"filter": [{"term": {"benchmark.id": benchmark_id}}, {"term": {"source.ip": source_ip}}]}}}),
            QueryDefinition("filter_by_destination_ip", "Filter events by destination IP", "es_count", EVENT_INDEX, {"query": {"bool": {"filter": [{"term": {"benchmark.id": benchmark_id}}, {"term": {"destination.ip": destination_ip}}]}}}),
            QueryDefinition("alerts_by_severity", "Alert counts by severity", "es_search", ALERT_INDEX, {"size": 0, "query": {"term": {"benchmark.id": benchmark_id}}, "aggs": {"by_severity": {"terms": {"field": "event.severity"}}}}),
            QueryDefinition("alerts_by_rule", "Alert counts by rule", "es_search", ALERT_INDEX, {"size": 0, "query": {"term": {"benchmark.id": benchmark_id}}, "aggs": {"by_rule": {"terms": {"field": "rule.id", "size": 10}}}}),
            QueryDefinition("top_source_ip_by_event_count", "Top source IPs by event count", "es_search", EVENT_INDEX, {"size": 0, "query": {"term": {"benchmark.id": benchmark_id}}, "aggs": {"top_source": {"terms": {"field": "source.ip", "size": 10}}}}),
            QueryDefinition("top_destination_ip_by_event_count", "Top destination IPs by event count", "es_search", EVENT_INDEX, {"size": 0, "query": {"term": {"benchmark.id": benchmark_id}}, "aggs": {"top_destination": {"terms": {"field": "destination.ip", "size": 10}}}}),
            QueryDefinition("top_talkers_by_network_bytes", "Top source IPs by total network bytes", "es_search", EVENT_INDEX, {"size": 0, "query": {"term": {"benchmark.id": benchmark_id}}, "aggs": {"top_talkers": {"terms": {"field": "source.ip", "size": 10}, "aggs": {"total_bytes": {"sum": {"field": "network.bytes"}}}}}}),
            QueryDefinition(
                "message_search",
                "Full-text message search",
                "es_search",
                EVENT_INDEX,
                {
                    "size": 25,
                    "track_total_hits": False,
                    "sort": [{"@timestamp": {"order": "desc"}}],
                    "query": {
                        "bool": {
                            "filter": [
                                {"term": {"benchmark.id": benchmark_id}},
                                {"range": {"@timestamp": {"gte": time_start, "lte": time_end}}},
                            ],
                            "must": [
                                {"match": {"message": {"query": message_term, "operator": "and"}}}
                            ],
                        }
                    },
                },
            ),
        ]

    return [
        QueryDefinition("time_range_search", "Time-range event search", "pg", "events", ("SELECT event_id, event_timestamp FROM siem_benchmark.events WHERE benchmark_id = %s AND event_timestamp BETWEEN %s AND %s ORDER BY event_timestamp DESC LIMIT 50", [benchmark_id, time_start, time_mid])),
        QueryDefinition("filter_by_dataset", "Filter events by dataset", "pg", "events", ("SELECT COUNT(*) FROM siem_benchmark.events WHERE benchmark_id = %s AND event_dataset = %s", [benchmark_id, dataset])),
        QueryDefinition("filter_by_source_ip", "Filter events by source IP", "pg", "events", ("SELECT COUNT(*) FROM siem_benchmark.events WHERE benchmark_id = %s AND source_ip = %s", [benchmark_id, source_ip])),
        QueryDefinition("filter_by_destination_ip", "Filter events by destination IP", "pg", "events", ("SELECT COUNT(*) FROM siem_benchmark.events WHERE benchmark_id = %s AND destination_ip = %s", [benchmark_id, destination_ip])),
        QueryDefinition("alerts_by_severity", "Alert counts by severity", "pg", "alerts", ("SELECT event_severity, COUNT(*) FROM siem_benchmark.alerts WHERE benchmark_id = %s GROUP BY event_severity ORDER BY event_severity", [benchmark_id])),
        QueryDefinition("alerts_by_rule", "Alert counts by rule", "pg", "alerts", ("SELECT rule_id, COUNT(*) FROM siem_benchmark.alerts WHERE benchmark_id = %s GROUP BY rule_id ORDER BY COUNT(*) DESC LIMIT 10", [benchmark_id])),
        QueryDefinition("top_source_ip_by_event_count", "Top source IPs by event count", "pg", "events", ("SELECT source_ip, COUNT(*) FROM siem_benchmark.events WHERE benchmark_id = %s GROUP BY source_ip ORDER BY COUNT(*) DESC LIMIT 10", [benchmark_id])),
        QueryDefinition("top_destination_ip_by_event_count", "Top destination IPs by event count", "pg", "events", ("SELECT destination_ip, COUNT(*) FROM siem_benchmark.events WHERE benchmark_id = %s GROUP BY destination_ip ORDER BY COUNT(*) DESC LIMIT 10", [benchmark_id])),
        QueryDefinition("top_talkers_by_network_bytes", "Top source IPs by total network bytes", "pg", "events", ("SELECT source_ip, SUM(COALESCE(network_bytes, 0)) AS total_bytes FROM siem_benchmark.events WHERE benchmark_id = %s GROUP BY source_ip ORDER BY total_bytes DESC LIMIT 10", [benchmark_id])),
        QueryDefinition(
            "message_search",
            "Full-text message search",
            "pg",
            "events",
            (
                "SELECT event_id FROM siem_benchmark.events WHERE benchmark_id = %s AND event_timestamp BETWEEN %s AND %s AND to_tsvector('simple', COALESCE(message, '')) @@ plainto_tsquery('simple', %s) ORDER BY event_timestamp DESC LIMIT 25",
                [benchmark_id, time_start, time_end, message_term],
            ),
        ),
    ]


def run_es_query(base_url: str, query: QueryDefinition) -> None:
    if query.kind == "es_search":
        http_json("POST", f"{base_url}/{query.index_or_table}/_search", query.payload)
    elif query.kind == "es_count":
        http_json("POST", f"{base_url}/{query.index_or_table}/_count", query.payload)
    else:
        raise ValueError(query.kind)


def run_pg_query(dsn: str, query: QueryDefinition, connection: Any | None = None) -> None:
    client = PostgresClient(dsn) if connection is None else None
    sql_text, params = query.payload
    if connection is not None:
        with connection.cursor() as cur:
            cur.execute(sql_text, params)
            cur.fetchall() if cur.description else None
        return

    assert client is not None
    with client.connect() as conn:
        with conn.cursor() as cur:
            cur.execute(sql_text, params)
            cur.fetchall() if cur.description else None


def benchmark_queries(args: argparse.Namespace) -> None:
    metadata = json.loads(Path(args.metadata).read_text(encoding="utf-8"))
    queries = build_query_definitions(metadata, args.backend, args.suite)
    results: list[dict[str, Any]] = []
    pg_connection = None
    if args.backend == "postgres":
        pg_connection = PostgresClient(args.postgres_dsn).connect()

    try:
        for query in queries:
            durations: list[float] = []
            for _ in range(args.iterations):
                started = time.perf_counter()
                if args.backend == "elasticsearch":
                    run_es_query(args.elasticsearch_url.rstrip("/"), query)
                else:
                    run_pg_query(args.postgres_dsn, query, pg_connection)
                durations.append((time.perf_counter() - started) * 1000.0)
            results.append(
                {
                    "query": query.name,
                    "description": query.description,
                    "iterations": args.iterations,
                    "avg_ms": round(sum(durations) / len(durations), 3),
                    "p50_ms": round(percentile(durations, 0.50), 3),
                    "p95_ms": round(percentile(durations, 0.95), 3),
                    "p99_ms": round(percentile(durations, 0.99), 3),
                    "min_ms": round(min(durations), 3),
                    "max_ms": round(max(durations), 3),
                    "samples_ms": [round(item, 3) for item in durations],
                }
            )
    finally:
        if pg_connection is not None:
            pg_connection.close()

    output_path = Path(args.output_json)
    write_json(output_path, {"backend": args.backend, "benchmark_id": metadata["benchmark_id"], "suite": args.suite, "queries": results})
    csv_path = output_path.with_suffix(".csv")
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["query", "avg_ms", "p50_ms", "p95_ms", "p99_ms", "min_ms", "max_ms", "iterations"])
        writer.writeheader()
        for row in results:
            writer.writerow({key: row[key] for key in writer.fieldnames})


def benchmark_concurrent(args: argparse.Namespace) -> None:
    metadata = json.loads(Path(args.metadata).read_text(encoding="utf-8"))
    queries = build_query_definitions(metadata, args.backend, args.suite)
    seed = args.seed
    random.seed(seed)
    levels = [int(item.strip()) for item in args.levels.split(",") if item.strip()]
    results: list[dict[str, Any]] = []
    pg_local = threading.local()

    def single_call(query: QueryDefinition) -> float:
        started = time.perf_counter()
        if args.backend == "elasticsearch":
            run_es_query(args.elasticsearch_url.rstrip("/"), query)
        else:
            if not hasattr(pg_local, "connection"):
                pg_local.connection = PostgresClient(args.postgres_dsn).connect()
            run_pg_query(args.postgres_dsn, query, pg_local.connection)
        return (time.perf_counter() - started) * 1000.0

    for concurrency in levels:
        latencies: list[float] = []
        with ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = []
            for worker_id in range(concurrency):
                worker_queries = [queries[(worker_id + offset) % len(queries)] for offset in range(args.queries_per_worker)]
                for query in worker_queries:
                    futures.append(executor.submit(single_call, query))
            for future in as_completed(futures):
                latencies.append(future.result())
        results.append(
            {
                "concurrency": concurrency,
                "request_count": len(latencies),
                "avg_ms": round(sum(latencies) / len(latencies), 3),
                "p50_ms": round(percentile(latencies, 0.50), 3),
                "p95_ms": round(percentile(latencies, 0.95), 3),
                "p99_ms": round(percentile(latencies, 0.99), 3),
                "min_ms": round(min(latencies), 3),
                "max_ms": round(max(latencies), 3),
            }
        )

    output_path = Path(args.output_json)
    write_json(output_path, {"backend": args.backend, "benchmark_id": metadata["benchmark_id"], "suite": args.suite, "seed": seed, "results": results})
    csv_path = output_path.with_suffix(".csv")
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["concurrency", "request_count", "avg_ms", "p50_ms", "p95_ms", "p99_ms", "min_ms", "max_ms"])
        writer.writeheader()
        for row in results:
            writer.writerow(row)


def main() -> None:
    parser = argparse.ArgumentParser(description="Phase 5 benchmark helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--size", choices=sorted(SIZE_MULTIPLIERS), required=True)
    prepare.add_argument("--output-dir", required=True)
    prepare.add_argument("--benchmark-id")
    prepare.add_argument("--target-events", type=int, default=int(os.environ.get("BENCHMARK_TARGET_EVENTS", "0")))
    prepare.add_argument("--alert-every", type=int, default=5)
    prepare.add_argument("--message-search-term", default=os.environ.get("BENCHMARK_MESSAGE_SEARCH_TERM", "ssl tcp connection"))
    prepare.add_argument("--event-source", action="append")
    prepare.set_defaults(func=prepare_data)

    load_es = subparsers.add_parser("load-elasticsearch")
    load_es.add_argument("--elasticsearch-url", required=True)
    load_es.add_argument("--events-bulk", required=True)
    load_es.add_argument("--alerts-bulk", required=True)
    load_es.add_argument("--metadata", required=True)
    load_es.add_argument("--output-json", required=True)
    load_es.set_defaults(func=load_elasticsearch)

    load_pg = subparsers.add_parser("load-postgres")
    load_pg.add_argument("--postgres-dsn", required=True)
    load_pg.add_argument("--events-jsonl", required=True)
    load_pg.add_argument("--alerts-jsonl", required=True)
    load_pg.add_argument("--metadata", required=True)
    load_pg.add_argument("--output-json", required=True)
    load_pg.set_defaults(func=load_postgres)

    query = subparsers.add_parser("benchmark-queries")
    query.add_argument("--backend", choices=["elasticsearch", "postgres"], required=True)
    query.add_argument("--metadata", required=True)
    query.add_argument("--output-json", required=True)
    query.add_argument("--suite", choices=["baseline", "showcase"], default="baseline")
    query.add_argument("--iterations", type=int, default=5)
    query.add_argument("--elasticsearch-url")
    query.add_argument("--postgres-dsn")
    query.set_defaults(func=benchmark_queries)

    concurrent = subparsers.add_parser("benchmark-concurrent")
    concurrent.add_argument("--backend", choices=["elasticsearch", "postgres"], required=True)
    concurrent.add_argument("--metadata", required=True)
    concurrent.add_argument("--output-json", required=True)
    concurrent.add_argument("--suite", choices=["baseline", "showcase"], default="baseline")
    concurrent.add_argument("--levels", required=True)
    concurrent.add_argument("--queries-per-worker", type=int, default=5)
    concurrent.add_argument("--seed", type=int, default=42)
    concurrent.add_argument("--elasticsearch-url")
    concurrent.add_argument("--postgres-dsn")
    concurrent.set_defaults(func=benchmark_concurrent)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
