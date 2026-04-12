# Benchmark Results

`make run-benchmark` writes AIPerf output here (`same-rack.json`, `cross-rack.json`, and associated CSVs). These files are gitignored — run the benchmark yourself to generate them.

## Reference Examples

`results/examples/` contains illustrative outputs from the Ubuntu reference environment. These are **not real GPU measurements** — the mocker simulates KV-cache transfer latency by parameterizing bandwidth; compute time is suppressed (`--speedup-ratio 0`).

| File | Scenario | KV Bandwidth | p50 | p99 | Throughput |
|------|----------|-------------|-----|-----|------------|
| `examples/same-rack.json` | Prefill + decode on rack-01 | 400 GB/s (NVLink analog) | 9.4 ms | 12.6 ms | 374 req/s |
| `examples/cross-rack.json` | Prefill rack-01, decode rack-02 | 12.5 GB/s (100 GbE inter-rack) | 28.3 ms | 29.9 ms | 136 req/s |

**~3× latency and ~2.7× throughput difference** between placements at ISL=4096, OSL=32, concurrency=4.

## Reproducing

```bash
make phase3-same-rack && make run-benchmark
make phase3-cross-rack && make run-benchmark
make compare-results
```
