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

## Query Latency Highlights

- time-range search: `ES ... ms`, `PG ... ms`
- top talkers aggregation: `ES ... ms`, `PG ... ms`
- alert counts by severity: `ES ... ms`, `PG ... ms`
- message search: `ES ... ms`, `PG ... ms`

## Concurrent Queries

- concurrency 1: `ES p95 ...`, `PG p95 ...`
- concurrency 5: `ES p95 ...`, `PG p95 ...`
- concurrency 10: `ES p95 ...`, `PG p95 ...`
- concurrency 25: `ES p95 ...`, `PG p95 ...`

## Notes

- PostgreSQL is the comparison baseline, not the serving layer replacement.
- Message search results should be interpreted carefully because PostgreSQL uses simple `ILIKE` in this benchmark unless the operator adds a full-text baseline extension.
- Alert latency is an approximation from replay start to alert visibility in Elasticsearch.
