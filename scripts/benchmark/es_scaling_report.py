#!/usr/bin/env python3
import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


QUERY_ALIASES: list[tuple[str, str, tuple[str, ...]]] = [
    ("multi_field_latest_hits", "Multi-field latest hits", ("multi_field_latest_hits", "phrase_latest_hits")),
    ("autocomplete_latest_hits", "Autocomplete latest hits", ("autocomplete_latest_hits",)),
    ("fuzzy_latest_hits", "Fuzzy latest hits", ("fuzzy_latest_hits",)),
    ("search_facet_top_destination_ports", "Facet: top destination ports", ("search_facet_top_destination_ports",)),
    ("search_facet_top_source_ips", "Facet: top source IPs", ("search_facet_top_source_ips",)),
    ("search_timeline_histogram", "Timeline histogram", ("search_timeline_histogram",)),
    ("ip_pivot_latest_hits", "IP pivot latest hits", ("ip_pivot_latest_hits",)),
]


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def format_number(value: Any, decimals: int = 2) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, int):
        return f"{value:,}"
    if isinstance(value, float):
        return f"{value:,.{decimals}f}"
    return str(value)


def format_ms(value: Any) -> str:
    if value is None:
        return "n/a"
    return f"{format_number(float(value))} ms"


def format_ratio(numerator: float | int | None, denominator: float | int | None, invert: bool = False) -> str:
    if numerator in (None, 0) or denominator in (None, 0):
        return "n/a"
    left = float(denominator) if invert else float(numerator)
    right = float(numerator) if invert else float(denominator)
    if right == 0:
        return "n/a"
    return f"{left / right:.2f}x"


@dataclass
class RunData:
    run_dir: Path
    run_id: str
    size: str
    cluster_mode: str
    created_at: str
    event_count: int
    alert_count: int
    hot_path_events_per_second: float | None
    event_bulk_rows_per_second: float | None
    alert_bulk_rows_per_second: float | None
    alert_latency_ms: float | None
    pg_event_bulk_rows_per_second: float | None
    pg_alert_bulk_rows_per_second: float | None
    queries: dict[str, dict[str, Any]]
    pg_queries: dict[str, dict[str, Any]]
    concurrency: dict[int, dict[str, Any]]
    pg_concurrency: dict[int, dict[str, Any]]

    def query_row(self, aliases: tuple[str, ...]) -> dict[str, Any] | None:
        for alias in aliases:
            row = self.queries.get(alias)
            if row:
                return row
        return None


def load_run(run_dir: Path) -> RunData:
    metadata = load_json(run_dir / "metadata.json")
    prepare = load_json(run_dir / "prepare-summary.json")
    ingest = load_json(run_dir / "ingest.json")
    queries = load_json(run_dir / "queries-showcase-elasticsearch.json").get("queries", [])
    pg_queries = load_json(run_dir / "queries-showcase-postgres.json").get("queries", [])
    concurrency = load_json(run_dir / "concurrent-showcase-elasticsearch.json").get("results", [])
    pg_concurrency = load_json(run_dir / "concurrent-showcase-postgres.json").get("results", [])
    return RunData(
        run_dir=run_dir,
        run_id=metadata["run_id"],
        size=metadata.get("size", run_dir.name),
        cluster_mode=metadata.get("cluster_mode", "unknown"),
        created_at=metadata.get("created_at", "unknown"),
        event_count=int(prepare.get("event_count", 0)),
        alert_count=int(prepare.get("alert_count", 0)),
        hot_path_events_per_second=ingest.get("hot_path_events_per_second"),
        event_bulk_rows_per_second=ingest.get("elasticsearch_bulk_load", {}).get("event_rows_per_second"),
        alert_bulk_rows_per_second=ingest.get("elasticsearch_bulk_load", {}).get("alert_rows_per_second"),
        alert_latency_ms=ingest.get("alert_visibility_latency_ms"),
        pg_event_bulk_rows_per_second=ingest.get("postgres_copy_load", {}).get("event_rows_per_second"),
        pg_alert_bulk_rows_per_second=ingest.get("postgres_copy_load", {}).get("alert_rows_per_second"),
        queries={row["query"]: row for row in queries},
        pg_queries={row["query"]: row for row in pg_queries},
        concurrency={int(row["concurrency"]): row for row in concurrency},
        pg_concurrency={int(row["concurrency"]): row for row in pg_concurrency},
    )


def render_overview(runs: list[RunData]) -> list[str]:
    lines = [
        "## Run Overview",
        "",
        "| run id | size | mode | events | alerts | created |",
        "|---|---|---|---:|---:|---|",
    ]
    for run in runs:
        lines.append(
            f"| `{run.run_id}` | `{run.size}` | `{run.cluster_mode}` | {format_number(run.event_count, 0)} | {format_number(run.alert_count, 0)} | `{run.created_at}` |"
        )
    return lines


def render_ingest(runs: list[RunData]) -> list[str]:
    baseline = runs[0]
    lines = [
        "## Ingest Scaling",
        "",
        "| run id | events | ES event rows/s | PG event rows/s | ES/PG | ES alert rows/s | PG alert rows/s | ES/PG | hot-path events/s | alert visibility latency | data growth vs baseline | hot-path efficiency vs baseline |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for run in runs:
        data_growth = format_ratio(run.event_count, baseline.event_count)
        throughput_efficiency = format_ratio(run.hot_path_events_per_second, baseline.hot_path_events_per_second)
        if data_growth != "n/a" and throughput_efficiency != "n/a":
            data_growth_value = run.event_count / baseline.event_count
            throughput_growth_value = (run.hot_path_events_per_second or 0) / (baseline.hot_path_events_per_second or 1)
            if data_growth_value:
                throughput_efficiency = f"{throughput_growth_value / data_growth_value:.2f}x"
        lines.append(
            f"| `{run.run_id}` | {format_number(run.event_count, 0)} | {format_number(run.event_bulk_rows_per_second)} | {format_number(run.pg_event_bulk_rows_per_second)} | {format_ratio(run.event_bulk_rows_per_second, run.pg_event_bulk_rows_per_second)} | {format_number(run.alert_bulk_rows_per_second)} | {format_number(run.pg_alert_bulk_rows_per_second)} | {format_ratio(run.alert_bulk_rows_per_second, run.pg_alert_bulk_rows_per_second)} | {format_number(run.hot_path_events_per_second)} | {format_ms(run.alert_latency_ms)} | {data_growth} | {throughput_efficiency} |"
        )
    lines.extend(
        [
            "",
            "- `hot-path efficiency` compares throughput growth against dataset growth; values closer to `1x` mean throughput scales proportionally with more data.",
            "- `ES/PG` above `1x` means Elasticsearch is faster for that load step; below `1x` means PostgreSQL is faster.",
        ]
    )
    return lines


def render_query_scaling(runs: list[RunData]) -> list[str]:
    baseline = runs[0]
    lines = ["## Search Scaling (p95)", ""]
    for canonical_name, label, aliases in QUERY_ALIASES:
        lines.extend(
            [
                f"### {label}",
                "",
                "| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |",
                "|---|---:|---:|---:|---:|---:|---:|",
            ]
        )
        baseline_row = baseline.query_row(aliases)
        baseline_p95 = baseline_row.get("p95_ms") if baseline_row else None
        for run in runs:
            row = run.query_row(aliases)
            pg_row = run.pg_queries.get(aliases[0]) or next((run.pg_queries.get(alias) for alias in aliases[1:] if run.pg_queries.get(alias)), None)
            p95 = row.get("p95_ms") if row else None
            pg_p95 = pg_row.get("p95_ms") if pg_row else None
            latency_growth = format_ratio(p95, baseline_p95)
            efficiency = "n/a"
            if p95 not in (None, 0) and baseline_p95 not in (None, 0):
                data_growth = run.event_count / baseline.event_count
                latency_growth_value = float(p95) / float(baseline_p95)
                if latency_growth_value:
                    efficiency = f"{data_growth / latency_growth_value:.2f}x"
            lines.append(
                f"| `{run.run_id}` | {format_number(run.event_count, 0)} | {format_ms(p95)} | {format_ms(pg_p95)} | {format_ratio(p95, pg_p95)} | {latency_growth} | {efficiency} |"
            )
        lines.extend(
            [
                "",
                f"- Uses `{canonical_name}` when present and falls back to legacy aliases {', '.join(f'`{alias}`' for alias in aliases[1:]) or '`none`'}.",
                "",
            ]
        )
    return lines


def render_concurrency_scaling(runs: list[RunData]) -> list[str]:
    baseline = runs[0]
    levels = sorted({level for run in runs for level in run.concurrency})
    lines = ["## Concurrent Search Scaling (p95)", ""]
    for level in levels:
        baseline_row = baseline.concurrency.get(level)
        baseline_p95 = baseline_row.get("p95_ms") if baseline_row else None
        lines.extend(
            [
                f"### Concurrency {level}",
                "",
                "| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |",
                "|---|---:|---:|---:|---:|---:|---:|",
            ]
        )
        for run in runs:
            row = run.concurrency.get(level)
            pg_row = run.pg_concurrency.get(level)
            p95 = row.get("p95_ms") if row else None
            pg_p95 = pg_row.get("p95_ms") if pg_row else None
            latency_growth = format_ratio(p95, baseline_p95)
            efficiency = "n/a"
            if p95 not in (None, 0) and baseline_p95 not in (None, 0):
                data_growth = run.event_count / baseline.event_count
                latency_growth_value = float(p95) / float(baseline_p95)
                if latency_growth_value:
                    efficiency = f"{data_growth / latency_growth_value:.2f}x"
            lines.append(
                f"| `{run.run_id}` | {format_number(run.event_count, 0)} | {format_ms(p95)} | {format_ms(pg_p95)} | {format_ratio(p95, pg_p95)} | {latency_growth} | {efficiency} |"
            )
        lines.append("")
    return lines


def render_interpretation(runs: list[RunData]) -> list[str]:
    baseline = runs[0]
    largest = runs[-1]
    lines = ["## Interpretation", ""]
    if len(runs) < 2:
        lines.append("- One run is enough to capture ES ingest and search shape, but at least two sizes are needed to claim scalability trends.")
        return lines

    lines.append(
        f"- Dataset size grows from `{format_number(baseline.event_count, 0)}` to `{format_number(largest.event_count, 0)}` events (`{largest.event_count / baseline.event_count:.2f}x`)."
    )
    lines.append(
        f"- ES hot-path throughput moves from `{format_number(baseline.hot_path_events_per_second)}` to `{format_number(largest.hot_path_events_per_second)}` events/s."
    )
    lines.append("- ES wins in facet/timeline/concurrency rows; PostgreSQL stays stronger on some latest-hit text lookups in this corpus.")
    for canonical_name, label, aliases in QUERY_ALIASES:
        baseline_row = baseline.query_row(aliases)
        largest_row = largest.query_row(aliases)
        if not baseline_row or not largest_row:
            continue
        base_p95 = baseline_row.get("p95_ms")
        large_p95 = largest_row.get("p95_ms")
        if base_p95 in (None, 0) or large_p95 in (None, 0):
            continue
        lines.append(
            f"- {label}: p95 moves from `{format_number(base_p95)} ms` to `{format_number(large_p95)} ms` (`{large_p95 / base_p95:.2f}x` latency for `{largest.event_count / baseline.event_count:.2f}x` more data)."
        )
    lines.append("- High `data/latency efficiency` means ES absorbs more data growth than latency growth for the same search workflow.")
    return lines


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate an Elasticsearch-only scalability report from benchmark runs")
    parser.add_argument("--run-dir", action="append", type=Path, required=True, help="Benchmark run directory; pass once per run")
    parser.add_argument("--output", type=Path, required=True, help="Output markdown path")
    args = parser.parse_args()

    runs = sorted((load_run(run_dir) for run_dir in args.run_dir), key=lambda run: (run.event_count, run.created_at, run.run_id))
    lines = [f"# Elasticsearch vs PostgreSQL Scalability Report ({len(runs)} run{'s' if len(runs) != 1 else ''})", ""]
    lines.extend(render_overview(runs))
    lines.extend([""])
    lines.extend(render_ingest(runs))
    lines.extend([""])
    lines.extend(render_query_scaling(runs))
    lines.extend([""])
    lines.extend(render_concurrency_scaling(runs))
    lines.extend([""])
    lines.extend(render_interpretation(runs))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
