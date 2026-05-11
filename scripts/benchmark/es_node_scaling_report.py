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
    return "n/a" if value is None else f"{format_number(float(value))} ms"


def format_ratio(value: float | int | None, baseline: float | int | None) -> str:
    if value in (None, 0) or baseline in (None, 0):
        return "n/a"
    return f"{float(value) / float(baseline):.2f}x"


def format_speedup(baseline: float | int | None, value: float | int | None) -> str:
    if value in (None, 0) or baseline in (None, 0):
        return "n/a"
    return f"{float(baseline) / float(value):.2f}x"


@dataclass
class RunData:
    run_dir: Path
    run_id: str
    size: str
    node_count: int
    target_nodes: list[str]
    event_count: int
    event_rows_per_second: float | None
    alert_rows_per_second: float | None
    queries: dict[str, dict[str, Any]]
    concurrency: dict[int, dict[str, Any]]

    def query_row(self, aliases: tuple[str, ...]) -> dict[str, Any] | None:
        for alias in aliases:
            row = self.queries.get(alias)
            if row:
                return row
        return None


def load_run(run_dir: Path) -> RunData:
    metadata = load_json(run_dir / "metadata.json")
    prepare = load_json(run_dir / "prepare-summary.json")
    load_es = load_json(run_dir / "load-elasticsearch.json")
    queries = load_json(run_dir / "queries-showcase-elasticsearch.json").get("queries", [])
    concurrency = load_json(run_dir / "concurrent-showcase-elasticsearch.json").get("results", [])
    target_nodes = metadata.get("benchmark_target_nodes") or load_es.get("allocation_include_node_names") or []
    node_count = metadata.get("benchmark_node_count") or len(target_nodes) or 0
    return RunData(
        run_dir=run_dir,
        run_id=metadata["run_id"],
        size=metadata.get("size", run_dir.name),
        node_count=int(node_count),
        target_nodes=list(target_nodes),
        event_count=int(prepare.get("event_count", 0)),
        event_rows_per_second=load_es.get("event_rows_per_second"),
        alert_rows_per_second=load_es.get("alert_rows_per_second"),
        queries={row["query"]: row for row in queries},
        concurrency={int(row["concurrency"]): row for row in concurrency},
    )


def render_overview(runs: list[RunData]) -> list[str]:
    lines = [
        "## Topology Overview",
        "",
        "| run id | size | ES nodes used | target nodes | events | event bulk rows/s |",
        "|---|---|---:|---|---:|---:|",
    ]
    for run in runs:
        target = ", ".join(f"`{name}`" for name in run.target_nodes) if run.target_nodes else "n/a"
        lines.append(
            f"| `{run.run_id}` | `{run.size}` | {run.node_count} | {target} | {format_number(run.event_count, 0)} | {format_number(run.event_rows_per_second)} |"
        )
    return lines


def render_ingest_scaling(runs: list[RunData]) -> list[str]:
    baseline = runs[0]
    lines = [
        "## Bulk Ingest Speedup",
        "",
        "| ES nodes | event bulk rows/s | speedup vs 1-node | node efficiency | alert bulk rows/s |",
        "|---:|---:|---:|---:|---:|",
    ]
    for run in runs:
        speedup = format_ratio(run.event_rows_per_second, baseline.event_rows_per_second)
        efficiency = "n/a"
        if run.node_count and baseline.node_count and run.event_rows_per_second not in (None, 0) and baseline.event_rows_per_second not in (None, 0):
            efficiency = f"{(float(run.event_rows_per_second) / float(baseline.event_rows_per_second)) / (run.node_count / baseline.node_count):.2f}x"
        lines.append(
            f"| {run.node_count} | {format_number(run.event_rows_per_second)} | {speedup} | {efficiency} | {format_number(run.alert_rows_per_second)} |"
        )
    lines.append("")
    lines.append("- `node efficiency` compares ingest speedup with node-count growth; values near `1x` mean close-to-linear scale-out.")
    return lines


def render_query_scaling(runs: list[RunData]) -> list[str]:
    baseline = runs[0]
    lines = ["## Search Speedup (showcase p95)", ""]
    for _, label, aliases in QUERY_ALIASES:
        baseline_row = baseline.query_row(aliases)
        baseline_p95 = baseline_row.get("p95_ms") if baseline_row else None
        lines.extend(
            [
                f"### {label}",
                "",
                "| ES nodes | p95 | speedup vs 1-node | speedup efficiency |",
                "|---:|---:|---:|---:|",
            ]
        )
        for run in runs:
            row = run.query_row(aliases)
            p95 = row.get("p95_ms") if row else None
            speedup = format_speedup(baseline_p95, p95)
            efficiency = "n/a"
            if run.node_count and baseline.node_count and p95 not in (None, 0) and baseline_p95 not in (None, 0):
                efficiency = f"{(float(baseline_p95) / float(p95)) / (run.node_count / baseline.node_count):.2f}x"
            lines.append(f"| {run.node_count} | {format_ms(p95)} | {speedup} | {efficiency} |")
        lines.append("")
    return lines


def render_concurrency_scaling(runs: list[RunData]) -> list[str]:
    baseline = runs[0]
    levels = sorted({level for run in runs for level in run.concurrency})
    lines = ["## Concurrent Search Speedup (showcase p95)", ""]
    for level in levels:
        baseline_row = baseline.concurrency.get(level)
        baseline_p95 = baseline_row.get("p95_ms") if baseline_row else None
        lines.extend(
            [
                f"### Concurrency {level}",
                "",
                "| ES nodes | p95 | speedup vs 1-node | speedup efficiency |",
                "|---:|---:|---:|---:|",
            ]
        )
        for run in runs:
            row = run.concurrency.get(level)
            p95 = row.get("p95_ms") if row else None
            speedup = format_speedup(baseline_p95, p95)
            efficiency = "n/a"
            if run.node_count and baseline.node_count and p95 not in (None, 0) and baseline_p95 not in (None, 0):
                efficiency = f"{(float(baseline_p95) / float(p95)) / (run.node_count / baseline.node_count):.2f}x"
            lines.append(f"| {run.node_count} | {format_ms(p95)} | {speedup} | {efficiency} |")
        lines.append("")
    return lines


def render_interpretation(runs: list[RunData]) -> list[str]:
    baseline = runs[0]
    largest = runs[-1]
    lines = ["## Interpretation", ""]
    lines.append(
        "- This benchmark keeps the same 3-node SIEM cluster alive and only pins the benchmark indices to `1`, `2`, or `3` Elasticsearch nodes."
    )
    lines.append(
        "- That makes the result safe for the side-by-side deployment and isolates Elasticsearch node-scale behavior without reconfiguring Kafka, Flink, or PostgreSQL."
    )
    if baseline.event_rows_per_second and largest.event_rows_per_second:
        lines.append(
            f"- Event bulk ingest moves from `{format_number(baseline.event_rows_per_second)}` rows/s on `{baseline.node_count}` node to `{format_number(largest.event_rows_per_second)}` rows/s on `{largest.node_count}` nodes."
        )
    return lines


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate an Elasticsearch node-scalability report")
    parser.add_argument("--run-dir", action="append", type=Path, required=True, help="Benchmark run directory; pass once per topology")
    parser.add_argument("--output", type=Path, required=True, help="Output markdown path")
    args = parser.parse_args()

    runs = sorted((load_run(path) for path in args.run_dir), key=lambda run: (run.node_count, run.run_id))
    lines = [f"# Elasticsearch Node Scalability ({len(runs)} topologies)", ""]
    lines.extend(render_overview(runs))
    lines.extend([""])
    lines.extend(render_ingest_scaling(runs))
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
