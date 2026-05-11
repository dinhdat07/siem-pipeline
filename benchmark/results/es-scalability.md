# Elasticsearch vs PostgreSQL Scalability Report (1 run)

## Run Overview

| run id | size | mode | events | alerts | created |
|---|---|---|---:|---:|---|
| `20260511T130422Z-distributed-1m` | `distributed-1m` | `distributed` | 1,000,000 | 200,000 | `2026-05-11T13:04:22Z` |

## Ingest Scaling

| run id | events | ES event rows/s | PG event rows/s | ES/PG | ES alert rows/s | PG alert rows/s | ES/PG | hot-path events/s | alert visibility latency | data growth vs baseline | hot-path efficiency vs baseline |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `20260511T130422Z-distributed-1m` | 1,000,000 | 2,972.28 | 2,959.17 | 1.00x | 1,950.48 | 1,633.31 | 1.19x | 6,027.47 | 9,467.25 ms | 1.00x | 1.00x |

- `hot-path efficiency` compares throughput growth against dataset growth; values closer to `1x` mean throughput scales proportionally with more data.
- `ES/PG` above `1x` means Elasticsearch is faster for that load step; below `1x` means PostgreSQL is faster.

## Search Scaling (p95)

### Multi-field latest hits

| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |
|---|---:|---:|---:|---:|---:|---:|
| `20260511T130422Z-distributed-1m` | 1,000,000 | 156.43 ms | 26.98 ms | 5.80x | 1.00x | 1.00x |

- Uses `multi_field_latest_hits` when present and falls back to legacy aliases `phrase_latest_hits`.

### Autocomplete latest hits

| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |
|---|---:|---:|---:|---:|---:|---:|
| `20260511T130422Z-distributed-1m` | 1,000,000 | 120.84 ms | 2,610.45 ms | 0.05x | 1.00x | 1.00x |

- Uses `autocomplete_latest_hits` when present and falls back to legacy aliases `none`.

### Fuzzy latest hits

| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |
|---|---:|---:|---:|---:|---:|---:|
| `20260511T130422Z-distributed-1m` | 1,000,000 | 165.75 ms | 53,610.82 ms | 0.00x | 1.00x | 1.00x |

- Uses `fuzzy_latest_hits` when present and falls back to legacy aliases `none`.

### Facet: top destination ports

| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |
|---|---:|---:|---:|---:|---:|---:|
| `20260511T130422Z-distributed-1m` | 1,000,000 | 37.55 ms | 456.90 ms | 0.08x | 1.00x | 1.00x |

- Uses `search_facet_top_destination_ports` when present and falls back to legacy aliases `none`.

### Facet: top source IPs

| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |
|---|---:|---:|---:|---:|---:|---:|
| `20260511T130422Z-distributed-1m` | 1,000,000 | 30.39 ms | 21.21 ms | 1.43x | 1.00x | 1.00x |

- Uses `search_facet_top_source_ips` when present and falls back to legacy aliases `none`.

### Timeline histogram

| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |
|---|---:|---:|---:|---:|---:|---:|
| `20260511T130422Z-distributed-1m` | 1,000,000 | 57.36 ms | 25.75 ms | 2.23x | 1.00x | 1.00x |

- Uses `search_timeline_histogram` when present and falls back to legacy aliases `none`.

### IP pivot latest hits

| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |
|---|---:|---:|---:|---:|---:|---:|
| `20260511T130422Z-distributed-1m` | 1,000,000 | 104.01 ms | 10.62 ms | 9.79x | 1.00x | 1.00x |

- Uses `ip_pivot_latest_hits` when present and falls back to legacy aliases `none`.


## Concurrent Search Scaling (p95)

### Concurrency 1

| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |
|---|---:|---:|---:|---:|---:|---:|
| `20260511T130422Z-distributed-1m` | 1,000,000 | 221.94 ms | 13,964.22 ms | 0.02x | 1.00x | 1.00x |

### Concurrency 5

| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |
|---|---:|---:|---:|---:|---:|---:|
| `20260511T130422Z-distributed-1m` | 1,000,000 | 130.01 ms | 9,528.02 ms | 0.01x | 1.00x | 1.00x |

### Concurrency 10

| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |
|---|---:|---:|---:|---:|---:|---:|
| `20260511T130422Z-distributed-1m` | 1,000,000 | 192.75 ms | 24,349.78 ms | 0.01x | 1.00x | 1.00x |

### Concurrency 25

| run id | events | ES p95 | PG p95 | PG/ES | latency growth vs baseline | data/latency efficiency |
|---|---:|---:|---:|---:|---:|---:|
| `20260511T130422Z-distributed-1m` | 1,000,000 | 365.80 ms | 56,070.44 ms | 0.01x | 1.00x | 1.00x |


## Interpretation

- One run is enough to capture ES ingest and search shape, but at least two sizes are needed to claim scalability trends.
