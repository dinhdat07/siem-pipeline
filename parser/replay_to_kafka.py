import json
import time
import argparse
from pathlib import Path
from confluent_kafka import Producer
from zeek_conn_parser import parse_conn_line


def delivery_report(err, msg):
    if err is not None:
        print(f"[ERROR] delivery failed: {err}")


def build_producer(bootstrap_servers: str) -> Producer:
    return Producer(
        {
            "bootstrap.servers": bootstrap_servers,
            "client.id": "zeek-conn-replay",
            "acks": "all",
        }
    )


def replay_file(
    input_path: Path,
    topic: str,
    bootstrap_servers: str,
    limit: int | None = None,
    interval_ms: int = 100,
    use_event_time: bool = False,
):
    producer = build_producer(bootstrap_servers)

    sent = 0
    failed = 0
    prev_ts = None

    with input_path.open("r", encoding="utf-8", errors="replace") as fin:
        for line in fin:
            if limit is not None and sent >= limit:
                break

            line = line.strip()
            if not line or line.startswith("#"):
                continue

            try:
                event = parse_conn_line(line)

                event_ts = event["@timestamp"]
                raw_ts = line.split()[0]
                current_ts = float(raw_ts)

                if use_event_time and prev_ts is not None:
                    delta = max(0.0, current_ts - prev_ts)
                    if delta > 0:
                        time.sleep(delta)
                else:
                    time.sleep(interval_ms / 1000.0)

                key = event.get("zeek.conn.uid")
                producer.produce(
                    topic=topic,
                    key=key.encode("utf-8") if key else None,
                    value=json.dumps(event).encode("utf-8"),
                    on_delivery=delivery_report,
                )
                producer.poll(0)

                sent += 1
                prev_ts = current_ts

                if sent % 1000 == 0:
                    print(f"[INFO] sent={sent}")

            except Exception as e:
                failed += 1
                print(f"[WARN] failed to parse/send line: {e}")

    producer.flush()
    print(f"[DONE] topic={topic} sent={sent} failed={failed}")


def main():
    parser = argparse.ArgumentParser(description="Replay Zeek conn.log to Kafka")
    parser.add_argument(
        "-i",
        "--input",
        type=Path,
        default=Path("data/raw/zeek/conn.log"),
        help="Path to input conn.log file",
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
        default="zeek.conn",
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

    replay_file(
        input_path=args.input,
        topic=args.topic,
        bootstrap_servers=args.bootstrap_servers,
        limit=args.limit,
        interval_ms=args.interval_ms,
        use_event_time=args.use_event_time,
    )


if __name__ == "__main__":
    main()