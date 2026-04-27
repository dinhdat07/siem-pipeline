# Benchmark Results

This directory stores benchmark outputs written by `scripts/benchmark/run_benchmark.sh` and the lower-level benchmark scripts.

Expected per-run layout:

- `benchmark/results/<run-id>/metadata.json`
- `benchmark/results/<run-id>/prepare-summary.json`
- `benchmark/results/<run-id>/load-elasticsearch.json`
- `benchmark/results/<run-id>/load-postgres.json`
- `benchmark/results/<run-id>/queries-elasticsearch.json`
- `benchmark/results/<run-id>/queries-postgres.json`
- `benchmark/results/<run-id>/concurrent-elasticsearch.json`
- `benchmark/results/<run-id>/concurrent-postgres.json`
- `benchmark/results/<run-id>/ingest.json`
- `benchmark/results/<run-id>/summary.md`

These files are safe to compare across runs because they record the benchmark size, benchmark id, and execution time.
