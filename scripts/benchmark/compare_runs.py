#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from typing import Any


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def query_map(run_dir: Path, name: str) -> dict[str, dict[str, Any]]:
    data = load_json(run_dir / name)
    return {row["query"]: row for row in data.get("queries", [])}


def concurrent_rows(run_dir: Path, name: str) -> list[dict[str, Any]]:
    return load_json(run_dir / name).get("results", [])


def ratio(a: float | int | None, b: float | int | None) -> str:
    if not a or not b:
        return "n/a"
    return f"{round(float(b) / float(a), 2)}x"


def format_ms(value: Any) -> str:
    return "n/a" if value is None else f"{value} ms"


def emit_backend_comparison(run_dir: Path) -> str:
    metadata = load_json(run_dir / "metadata.json")
    prepare = load_json(run_dir / "prepare-summary.json")
    es = query_map(run_dir, "queries-showcase-elasticsearch.json")
    pg = query_map(run_dir, "queries-showcase-postgres.json")
    es_conc = concurrent_rows(run_dir, "concurrent-showcase-elasticsearch.json")
    pg_conc = concurrent_rows(run_dir, "concurrent-showcase-postgres.json")
    lines = [
        f"# ES vs PostgreSQL Showcase: {metadata['run_id']}",
        "",
        f"- mode: `{metadata.get('cluster_mode', 'unknown')}`",
        f"- events: `{prepare.get('event_count')}`",
        f"- alerts: `{prepare.get('alert_count')}`",
        "",
        "## Query p95",
        "",
        "| query | ES p95 | PG p95 | PG/ES latency ratio |",
        "|---|---:|---:|---:|",
    ]
    for name in [
        "multi_field_latest_hits",
        "autocomplete_latest_hits",
        "fuzzy_latest_hits",
        "search_facet_top_destination_ports",
        "search_facet_top_source_ips",
        "search_timeline_histogram",
        "ip_pivot_latest_hits",
    ]:
        es_p95 = es.get(name, {}).get("p95_ms")
        pg_p95 = pg.get(name, {}).get("p95_ms")
        lines.append(f"| `{name}` | {format_ms(es_p95)} | {format_ms(pg_p95)} | {ratio(es_p95, pg_p95)} |")
    lines.extend(["", "## Concurrent showcase p95", "", "| concurrency | ES p95 | PG p95 | PG/ES latency ratio |", "|---:|---:|---:|---:|"])
    for es_row, pg_row in zip(es_conc, pg_conc):
        es_p95 = es_row.get("p95_ms")
        pg_p95 = pg_row.get("p95_ms")
        lines.append(f"| {es_row.get('concurrency')} | {format_ms(es_p95)} | {format_ms(pg_p95)} | {ratio(es_p95, pg_p95)} |")
    lines.extend([
        "",
        "## Interpretation",
        "",
        "- Ratios greater than `1x` mean PostgreSQL observed latency is higher than Elasticsearch for the same logical investigation workflow.",
        "- The showcase suite intentionally emphasizes hot SIEM search: multi-field search, search-as-you-type prefix search, fuzzy search, facets, timelines, pivots, and concurrent investigation queries.",
    ])
    return "\n".join(lines) + "\n"


def emit_single_distributed_comparison(single_dir: Path, distributed_dir: Path) -> str:
    single_meta = load_json(single_dir / "metadata.json")
    dist_meta = load_json(distributed_dir / "metadata.json")
    single_ingest = load_json(single_dir / "ingest.json") if (single_dir / "ingest.json").exists() else {}
    dist_ingest = load_json(distributed_dir / "ingest.json") if (distributed_dir / "ingest.json").exists() else {}
    single_es = query_map(single_dir, "queries-showcase-elasticsearch.json")
    dist_es = query_map(distributed_dir, "queries-showcase-elasticsearch.json")
    lines = [
        f"# Single vs Distributed: {single_meta['run_id']} -> {dist_meta['run_id']}",
        "",
        "| metric | single | distributed | distributed/single ratio |",
        "|---|---:|---:|---:|",
    ]
    single_thr = single_ingest.get("hot_path_events_per_second")
    dist_thr = dist_ingest.get("hot_path_events_per_second")
    lines.append(f"| hot-path events/sec | {single_thr or 'n/a'} | {dist_thr or 'n/a'} | {ratio(single_thr, dist_thr)} |")
    for name in ["multi_field_latest_hits", "autocomplete_latest_hits", "fuzzy_latest_hits", "search_timeline_histogram", "ip_pivot_latest_hits"]:
        s = single_es.get(name, {}).get("p95_ms")
        d = dist_es.get(name, {}).get("p95_ms")
        lines.append(f"| `{name}` p95 latency | {format_ms(s)} | {format_ms(d)} | {ratio(d, s)} faster |")
    lines.extend(["", "- For latency rows, ratio is `single/distributed`; higher is better for distributed.", ""])
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description="Summarize SIEM benchmark runs")
    parser.add_argument("--run-dir", type=Path, help="Run directory for ES vs PostgreSQL comparison")
    parser.add_argument("--single-run-dir", type=Path, help="Single-node run directory")
    parser.add_argument("--distributed-run-dir", type=Path, help="Distributed run directory")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if args.run_dir:
        text = emit_backend_comparison(args.run_dir)
    elif args.single_run_dir and args.distributed_run_dir:
        text = emit_single_distributed_comparison(args.single_run_dir, args.distributed_run_dir)
    else:
        raise SystemExit("Provide --run-dir or both --single-run-dir and --distributed-run-dir")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
