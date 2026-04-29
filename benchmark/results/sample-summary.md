# Sample Benchmark Summary

- run id: `20260427T120000Z-small`
- benchmark size: `small`
- benchmark id: `phase5-small`
- environment: `server`, `6 vCPU`, `12 GB RAM`

## Data Volume

- events loaded into Elasticsearch: `...`
- alerts loaded into Elasticsearch: `...`
- events loaded into PostgreSQL: `...`
- alerts loaded into PostgreSQL: `...`

## Ingest

- Elasticsearch hot-path throughput: `... events/sec`
- Elasticsearch alert visibility latency: `... ms`
- PostgreSQL direct loader throughput: `... rows/sec`

## Baseline Comparison

- time-range search: `ES ... ms`, `PG ... ms`
- top talkers aggregation: `ES ... ms`, `PG ... ms`
- alert counts by severity: `ES ... ms`, `PG ... ms`
- message search: `ES ... ms`, `PG ... ms`

## Baseline Concurrent Queries

- concurrency 1: `ES p95 ...`, `PG p95 ...`
- concurrency 5: `ES p95 ...`, `PG p95 ...`
- concurrency 10: `ES p95 ...`, `PG p95 ...`
- concurrency 25: `ES p95 ...`, `PG p95 ...`

## ES Showcase Comparison

- phrase latest hits: `ES ... ms`, `PG ... ms`
- top destination ports after phrase search: `ES ... ms`, `PG ... ms`
- top source IPs after phrase search: `ES ... ms`, `PG ... ms`
- phrase-search timeline histogram: `ES ... ms`, `PG ... ms`
- IP pivot latest hits: `ES ... ms`, `PG ... ms`

## ES Showcase Concurrent Queries

- concurrency 1: `ES p95 ...`, `PG p95 ...`
- concurrency 5: `ES p95 ...`, `PG p95 ...`
- concurrency 10: `ES p95 ...`, `PG p95 ...`
- concurrency 25: `ES p95 ...`, `PG p95 ...`

## Notes

- PostgreSQL is the comparison baseline, not the serving layer replacement.
- The baseline suite captures general comparison for common SIEM filters, aggregations, and latest-match search.
- The ES showcase suite is intentionally aimed at search-and-investigation workflows where Elasticsearch is the intended hot-path serving layer.
- Alert latency is an approximation from replay start to alert visibility in Elasticsearch.
