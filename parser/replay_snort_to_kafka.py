import argparse
import json
import time
from datetime import datetime
from pathlib import Path

from confluent_kafka import Producer
from snort_alert_parser import build_event_key, iter_blocks_in_file, iter_input_files, parse_block


def delivery_report(err, msg):
    if err is not None:
        print(f"[ERROR] delivery failed: {err}")


def build_producer(bootstrap_servers: str) -> Producer:
    return Producer(
        {
            "bootstrap.servers": bootstrap_servers,
            "client.id": "snort-alert-replay",
            "acks": "all",
        }
    )


def replay_directory(
    input_dir: Path,
    topic: str,
    bootstrap_servers: str,
    limit: int | None = None,
    interval_ms: int = 100,
    use_event_time: bool = False,
):
    producer = build_producer(bootstrap_servers)

    sent = 0
    failed = 0
    prev_ts: datetime | None = None

    for input_file in iter_input_files(input_dir):
        for block in iter_blocks_in_file(input_file):
            if limit is not None and sent >= limit:
                producer.flush()
                print(f"[DONE] topic={topic} sent={sent} failed={failed}")
                return

            try:
                event = parse_block(block)
                if event is None:
                    raise ValueError("failed to parse snort alert block")

                event["log.file.path"] = str(input_file)

                current_ts = None
                if "@timestamp" in event:
                    current_ts = datetime.fromisoformat(event["@timestamp"])

                if use_event_time and current_ts is not None and prev_ts is not None:
                    delta = max(0.0, (current_ts - prev_ts).total_seconds())
                    if delta > 0:
                        time.sleep(delta)
                else:
                    time.sleep(interval_ms / 1000.0)

                key = build_event_key(event)
                producer.produce(
                    topic=topic,
                    key=key.encode("utf-8") if key else None,
                    value=json.dumps(event).encode("utf-8"),
                    on_delivery=delivery_report,
                )
                producer.poll(0)

                sent += 1
                if current_ts is not None:
                    prev_ts = current_ts

                if sent % 1000 == 0:
                    print(f"[INFO] sent={sent}")

            except Exception as exc:
                failed += 1
                print(f"[WARN] failed to parse/send block from {input_file.name}: {exc}")

    producer.flush()
    print(f"[DONE] topic={topic} sent={sent} failed={failed}")


def main():
    parser = argparse.ArgumentParser(description="Replay Snort alert logs to Kafka")
    parser.add_argument(
        "-i",
        "--input-dir",
        type=Path,
        default=Path("data/raw/snort-alert"),
        help="Directory containing Snort alert files",
    )
    parser.add_argument(
        "-b",
        "--bootstrap-servers",
        default="localhost:9092",
        help="Kafka bootstrap servers",
    )
    parser.add_argument(
        "-t",
        "--topic",
        default="snort.alert",
        help="Kafka topic name",
    )
    parser.add_argument(
        "-n",
        "--limit",
        type=int,
        default=None,
        help="Maximum number of records to send",
    )
    parser.add_argument(
        "--interval-ms",
        type=int,
        default=100,
        help="Fixed interval between events in milliseconds",
    )
    parser.add_argument(
        "--use-event-time",
        action="store_true",
        help="Replay using original event timestamp gaps",
    )

    args = parser.parse_args()

    replay_directory(
        input_dir=args.input_dir,
        topic=args.topic,
        bootstrap_servers=args.bootstrap_servers,
        limit=args.limit,
        interval_ms=args.interval_ms,
        use_event_time=args.use_event_time,
    )


if __name__ == "__main__":
    main()
