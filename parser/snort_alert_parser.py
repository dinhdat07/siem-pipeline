import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path

RULE_RE = re.compile(r"^\[\*\*\] \[(\d+):(\d+):(\d+)\] (.+) \[\*\*\]$")
CLASS_RE = re.compile(r"^\[Classification: (.+?)\] \[Priority: (\d+)\]\s*$")
IP_RE = re.compile(
    r"^(\d{2}/\d{2})-(\d{2}:\d{2}:\d{2}\.\d{6}) "
    r"(\d+\.\d+\.\d+\.\d+):(\d+) -> (\d+\.\d+\.\d+\.\d+):(\d+)$"
)
PROTO_RE = re.compile(
    r"^(TCP|UDP|ICMP)\s+TTL:(\d+)\s+TOS:(\S+)\s+ID:(\d+)\s+IpLen:(\d+)\s+DgmLen:(\d+)(?:\s+(.*))?$"
)
TCP_RE = re.compile(
    r"^(\S+)\s+Seq:\s+(0x[0-9A-Fa-f]+)\s+Ack:\s+(0x[0-9A-Fa-f]+)\s+Win:\s+(0x[0-9A-Fa-f]+)\s+TcpLen:\s+(\d+)$"
)
XREF_RE = re.compile(r"^\[Xref => (.+?)\]$")

YEAR = 2012
SNORT_GLOB = "alert.full.maccdc2012_*.pcap"


def parse_event_datetime(mmdd: str, time_str: str) -> datetime:
    return datetime.strptime(
        f"{YEAR}/{mmdd} {time_str}",
        "%Y/%m/%d %H:%M:%S.%f",
    ).replace(tzinfo=timezone.utc)


def parse_timestamp(mmdd: str, time_str: str) -> str:
    return parse_event_datetime(mmdd, time_str).isoformat()


def iter_input_files(input_dir: Path):
    files = sorted(input_dir.glob(SNORT_GLOB))
    if not files:
        raise FileNotFoundError(f"No input files found in {input_dir}")
    yield from files


def iter_blocks_in_file(input_path: Path):
    block_lines: list[str] = []

    with input_path.open("r", encoding="utf-8", errors="replace") as fin:
        for raw_line in fin:
            line = raw_line.rstrip("\r\n")
            if line.strip():
                block_lines.append(line)
                continue

            if block_lines:
                yield "\n".join(block_lines)
                block_lines = []

    if block_lines:
        yield "\n".join(block_lines)


def parse_block(block: str) -> dict | None:
    lines = [line.strip() for line in block.splitlines() if line.strip()]
    if len(lines) < 3:
        return None

    event = {
        "event.kind": "alert",
        "event.category": ["intrusion_detection"],
        "event.type": ["info"],
        "event.module": "snort",
        "event.dataset": "snort.alert",
        "event.original": block,
    }

    m = RULE_RE.match(lines[0])
    if not m:
        return None

    gid, sid, rev, rule_name = m.groups()
    event["rule.id"] = f"{gid}:{sid}:{rev}"
    event["rule.name"] = rule_name
    event["snort.generator_id"] = int(gid)
    event["snort.signature_id"] = int(sid)
    event["snort.signature_revision"] = int(rev)
    event["message"] = rule_name

    idx = 1

    if idx < len(lines):
        m = CLASS_RE.match(lines[idx])
        if m:
            classification, priority = m.groups()
            event["rule.category"] = classification
            event["event.severity"] = int(priority)
            idx += 1

    if idx >= len(lines):
        return event

    m = IP_RE.match(lines[idx])
    if not m:
        return event

    mmdd, time_str, src_ip, src_port, dst_ip, dst_port = m.groups()
    event["@timestamp"] = parse_timestamp(mmdd, time_str)
    event["source.ip"] = src_ip
    event["source.port"] = int(src_port)
    event["destination.ip"] = dst_ip
    event["destination.port"] = int(dst_port)
    event["related.ip"] = [src_ip, dst_ip]
    idx += 1

    if idx < len(lines):
        m = PROTO_RE.match(lines[idx])
        if m:
            proto, ttl, tos, ip_id, ip_len, dgm_len, extras = m.groups()
            event["network.transport"] = proto.lower()
            event["snort.ip.ttl"] = int(ttl)
            event["snort.ip.tos"] = tos
            event["snort.ip.id"] = int(ip_id)
            event["snort.ip.len"] = int(ip_len)
            event["snort.packet.len"] = int(dgm_len)
            if extras:
                event["snort.ip.flags"] = extras
            idx += 1

    if idx < len(lines):
        m = TCP_RE.match(lines[idx])
        if m:
            flags_raw, seq, ack, win, tcp_len = m.groups()
            event["snort.tcp.flags_raw"] = flags_raw
            event["snort.tcp.seq"] = seq
            event["snort.tcp.ack"] = ack
            event["snort.tcp.window"] = win
            event["snort.tcp.len"] = int(tcp_len)
            idx += 1

    while idx < len(lines):
        m = XREF_RE.match(lines[idx])
        if m:
            event["snort.xref"] = m.group(1)
        else:
            event.setdefault("snort.extra", []).append(lines[idx])
        idx += 1

    return event


def build_event_key(event: dict) -> str:
    parts = [
        event.get("rule.id"),
        event.get("@timestamp"),
        event.get("source.ip"),
        event.get("source.port"),
        event.get("destination.ip"),
        event.get("destination.port"),
    ]
    return "|".join(str(part) for part in parts if part is not None)


def parse_files_to_jsonl(input_dir: Path, output_path: Path, limit: int | None = None):
    output_path.parent.mkdir(parents=True, exist_ok=True)

    parsed = 0
    failed = 0

    with output_path.open("w", encoding="utf-8") as fout:
        for input_file in iter_input_files(input_dir):
            for block in iter_blocks_in_file(input_file):
                if limit is not None and parsed >= limit:
                    return parsed, failed

                event = parse_block(block)
                if event is None:
                    failed += 1
                    continue

                event["log.file.path"] = str(input_file)
                fout.write(json.dumps(event, ensure_ascii=False) + "\n")
                parsed += 1

    return parsed, failed


def main():
    parser = argparse.ArgumentParser(description="Parse Snort full alert logs to JSONL")
    parser.add_argument(
        "-i",
        "--input-dir",
        type=Path,
        default=Path("data/raw/snort-alert"),
        help="Directory containing Snort alert files",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("data/sample/snort-alerts/snort_alerts_sample.jsonl"),
        help="Output JSONL file path",
    )
    parser.add_argument(
        "-n",
        "--limit",
        type=int,
        default=None,
        help="Maximum number of successfully parsed records to write",
    )

    args = parser.parse_args()

    parsed, failed = parse_files_to_jsonl(args.input_dir, args.output, args.limit)

    print(f"input_dir={args.input_dir}")
    print(f"output={args.output}")
    print(f"limit={args.limit}")
    print(f"parsed={parsed}, failed={failed}")


if __name__ == "__main__":
    main()
