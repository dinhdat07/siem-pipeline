import json
import argparse
from pathlib import Path
from datetime import datetime, timezone
from tqdm import tqdm

FIELDS = [
    "ts",
    "uid",
    "id.orig_h",
    "id.orig_p",
    "id.resp_h",
    "id.resp_p",
    "proto",
    "service",
    "duration",
    "orig_bytes",
    "resp_bytes",
    "conn_state",
    "local_orig",
    "missed_bytes",
    "history",
    "orig_pkts",
    "orig_ip_bytes",
    "resp_pkts",
    "resp_ip_bytes",
    "tunnel_parents",
]


def parse_zeek_value(field: str, value: str):
    if value == "-":
        return None
    if value == "(empty)":
        return []

    int_fields = {
        "id.orig_p",
        "id.resp_p",
        "orig_bytes",
        "resp_bytes",
        "missed_bytes",
        "orig_pkts",
        "orig_ip_bytes",
        "resp_pkts",
        "resp_ip_bytes",
    }
    float_fields = {"ts", "duration"}

    if field in int_fields:
        return int(value)
    if field in float_fields:
        return float(value)
    return value


def epoch_to_iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def build_event(raw: dict) -> dict:
    source_bytes = raw.get("orig_bytes") or 0
    dest_bytes = raw.get("resp_bytes") or 0
    source_pkts = raw.get("orig_pkts") or 0
    dest_pkts = raw.get("resp_pkts") or 0

    service = raw.get("service")
    proto = raw.get("proto")

    event = {
        "@timestamp": epoch_to_iso(raw["ts"]),
        "event.kind": "event",
        "event.category": ["network"],
        "event.type": ["connection"],
        "event.module": "zeek",
        "event.dataset": "zeek.conn",
        "source.ip": raw.get("id.orig_h"),
        "source.port": raw.get("id.orig_p"),
        "destination.ip": raw.get("id.resp_h"),
        "destination.port": raw.get("id.resp_p"),
        "source.bytes": source_bytes,
        "destination.bytes": dest_bytes,
        "source.packets": source_pkts,
        "destination.packets": dest_pkts,
        "network.transport": proto,
        "network.protocol": service,
        "network.bytes": source_bytes + dest_bytes,
        "network.packets": source_pkts + dest_pkts,
        "zeek.conn.uid": raw.get("uid"),
        "zeek.conn.service": service,
        "zeek.conn.duration": raw.get("duration"),
        "zeek.conn.state": raw.get("conn_state"),
        "zeek.conn.history": raw.get("history"),
        "zeek.conn.missed_bytes": raw.get("missed_bytes"),
        "zeek.conn.local_orig": raw.get("local_orig"),
        "zeek.conn.tunnel_parents": raw.get("tunnel_parents"),
        "related.ip": [ip for ip in [raw.get("id.orig_h"), raw.get("id.resp_h")] if ip],
        "event.original": " ".join(str(raw.get(f, "-")) for f in FIELDS),
    }

    msg_service = f"{service} " if service else ""
    event["message"] = (
        f"{msg_service}{proto} connection "
        f"{raw.get('id.orig_h')}:{raw.get('id.orig_p')} -> "
        f"{raw.get('id.resp_h')}:{raw.get('id.resp_p')}"
    )

    return event


def parse_conn_line(line: str) -> dict:
    parts = line.strip().split()
    if len(parts) != len(FIELDS):
        raise ValueError(f"Expected {len(FIELDS)} columns, got {len(parts)}: {line}")

    raw = {}
    for field, value in zip(FIELDS, parts):
        raw[field] = parse_zeek_value(field, value)
    return build_event(raw)


def count_data_lines(input_path: Path) -> int:
    count = 0
    with input_path.open("r", encoding="utf-8", errors="replace") as fin:
        for line in fin:
            line = line.strip()
            if line and not line.startswith("#"):
                count += 1
    return count


def parse_file(input_path: Path, output_path: Path, limit: int | None = None):
    output_path.parent.mkdir(parents=True, exist_ok=True)

    parsed = 0
    failed = 0

    total_data_lines = count_data_lines(input_path)
    progress_total = min(total_data_lines, limit) if limit is not None else total_data_lines

    with input_path.open("r", encoding="utf-8", errors="replace") as fin, \
         output_path.open("w", encoding="utf-8") as fout, \
         tqdm(total=progress_total, desc="Parsing conn.log", unit="event") as pbar:

        for line in fin:
            if limit is not None and parsed >= limit:
                break

            line = line.strip()
            if not line or line.startswith("#"):
                continue

            try:
                event = parse_conn_line(line)
                fout.write(json.dumps(event, ensure_ascii=False) + "\n")
                parsed += 1
                pbar.update(1)
                pbar.set_postfix(parsed=parsed, failed=failed)
            except Exception:
                failed += 1
                pbar.set_postfix(parsed=parsed, failed=failed)

    return parsed, failed


def main():
    parser = argparse.ArgumentParser(description="Parse Zeek conn.log to JSONL")
    parser.add_argument(
        "-i",
        "--input",
        type=Path,
        default=Path("input/zeek/conn.log"),
        help="Path to input conn.log file",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("output/conn-logs/zeek_conn_sample.jsonl"),
        help="Path to output JSONL file",
    )
    parser.add_argument(
        "-n",
        "--limit",
        type=int,
        default=None,
        help="Maximum number of successfully parsed records to write",
    )

    args = parser.parse_args()

    parsed, failed = parse_file(args.input, args.output, args.limit)
    print(f"input={args.input}")
    print(f"output={args.output}")
    print(f"limit={args.limit}")
    print(f"parsed={parsed}, failed={failed}")


if __name__ == "__main__":
    main()