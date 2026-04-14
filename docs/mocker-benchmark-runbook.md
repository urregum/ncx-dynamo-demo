# Mocker Benchmark Runbook

## Overview

This track deploys Dynamo mocker workers and runs AIPerf latency benchmarks to compare same-rack vs cross-rack placement. The mocker simulates disaggregated inference by parameterizing KV-cache transfer bandwidth — no GPU required.

**What Happens:**
1. Remove Phase 2 placeholder workload (frees node resources for the DGD)
2. Download Qwen3-0.6B model to local cache (tokenizer + config needed by mocker)
3. Deploy DynamoGraphDeployment (DGD) — creates Frontend + Prefill/Decode workers
4. Run AIPerf benchmark to measure latency (p50, p99, throughput)
5. Compare results side-by-side

> [!NOTE]
> `make mocker-deploy` is not idempotent — the placeholder removal is a one-way transition. If it fails after that point, `make clean` followed by the full sequence is required to restore a valid stack state. See [Troubleshooting](#troubleshooting) for details.

---

## Prerequisites

`make mocker-deploy` automatically runs `make validate-stack` before deploying workers — running it manually first gives explicit visibility into stack state.

From Phase 2:
- ✅ KAI + Grove + Dynamo platform running
- ✅ Placeholder workload validated (confirms gang scheduling; removed by `make mocker-deploy`)

New for Phase 3:
- ~2 GB free disk space (for Qwen3-0.6B model cache)
- Python venv with aiperf: `make install-aiperf`

---

## Execution

### Quick Start

```bash
# One-time setup
make install-aiperf
make download-model

# Deploy and validate
make mocker-deploy
make validate-mocker

# Benchmark same-rack scenario (already deployed by make mocker-deploy)
make show-placement          # Confirm prefill + decode both on rack-01
make run-benchmark           # Saves results/same-rack.json

# Switch to cross-rack and benchmark
make benchmark-cross-rack    # Confirm decode moved to rack-02
make run-benchmark           # Saves results/cross-rack.json

# Compare
make compare-results
```

### Step-by-Step

**Step 1: Install aiperf**
```bash
make install-aiperf
# Creates .venv/, installs aiperf==0.7.0 + huggingface_hub + hf_transfer
```

**Step 2: Download model**
```bash
make download-model
# Uses huggingface_hub to cache Qwen/Qwen3-0.6B locally (~1.5 GB)
# Saved to: models/hf-cache/models--Qwen--Qwen3-0.6B/snapshots/<hash>/
```

Must be done if the model cache is absent. Safe to re-run to update to the latest model revision.

The mocker does not run inference, but the model cache serves two purposes:
- **Frontend** — loads the tokenizer to support KV-aware routing (`--router-mode kv`)
- **Workers** — read model config (`num_layers`, `num_kv_heads`, `head_dim`) to compute `kv_bytes_per_token`, which drives the KV transfer delay formula

The weights themselves (~1.2 GB of the total) are present in the cache but unused by the mocker.

**Step 3: Deploy mocker workers**
```bash
make mocker-deploy
# Validates stack, pulls mocker image, removes placeholder, deploys same-rack DGD
```

**Step 4: Validate**
```bash
make validate-mocker
# 6-check validation:
#  1. DGD state = "successful"
#  2. 3+ pods Running (Frontend, Prefill, Decode)
#  3. Frontend Service endpoint reachable
#  4. /health returns 200
#  5. Inference request succeeds (returns chatcmpl)
#  6. Response includes disaggregation worker IDs
```

**Step 5: Benchmark same-rack scenario**
```bash
make show-placement    # Confirm prefill + decode on rack-01
make run-benchmark     # ISL=4096, OSL=32, concurrency=4, 20 requests
                       # Saves results/same-rack.json
```

**Step 6: Switch to cross-rack and benchmark**
```bash
make benchmark-cross-rack
make show-placement    # Confirm decode moved to rack-02
make run-benchmark     # Saves results/cross-rack.json
```

**Step 7: Compare results**
```bash
make compare-results
# Prints side-by-side latency + throughput table with computed ratio row
```

---

## Benchmark Characteristics

### Default Settings

| Parameter | Value | Notes |
|-----------|-------|-------|
| Model | Qwen/Qwen3-0.6B | 370M parameters, lightweight |
| ISL (Input Sequence Length) | 4096 tokens | Large prompts → large KV cache → large bandwidth difference |
| OSL (Output Sequence Length) | 32 tokens | Short responses; keeps test fast |
| Concurrency | 4 | 4 overlapping requests |
| Requests | 20 | Per scenario |
| Artifact dir | `results/` | JSON per scenario |

ISL is the dominant parameter for this benchmark: KV cache size grows linearly with input length, so a higher ISL amplifies the bandwidth difference between scenarios. At ISL=4096, the same-rack/cross-rack delta is clearly visible (~3×). At ISL=512 the delta narrows; at ISL=8192 it widens. This makes ISL the most informative axis to vary if exploring beyond the default benchmark. See `make help` for configurable Makefile variables (`BENCHMARK_ISL`, `BENCHMARK_OSL`, `BENCHMARK_CONC`).

### Expected Results (Mocker Baselines)

**Same-Rack (400 GB/s):**
- p50 latency: ~9.4 ms
- p99 latency: ~12.6 ms
- Throughput: ~374 req/s

**Cross-Rack (12.5 GB/s):**
- p50 latency: ~28.3 ms (3× same-rack)
- p99 latency: ~29.9 ms
- Throughput: ~136 req/s (2.7× lower)

Reference environment: Ubuntu 24.04, RTX 3070 Ti host. Absolute numbers will differ, but the ratios are stable — they reflect the bandwidth formula directly.

---

## How the Mocker Simulates Latency

The mocker (`dynamo.mocker`, Rust-based) does not run real inference. Instead, it:

1. **Suppresses GPU compute** — `--speedup-ratio 0` means infinite speedup; no simulation of prefill or decode compute time.
2. **Injects a real KV transfer delay** — when a prefill worker completes a request, it sleeps for a duration proportional to the KV cache size and the configured bandwidth:
   ```
   delay_ms = num_input_tokens × kv_bytes_per_token / (bandwidth_GB_s × 1e9) × 1000
   ```
3. **Auto-computes KV size from model config** — `kv_bytes_per_token = num_layers × 2 × num_kv_heads × head_dim × dtype_bytes`. For Qwen3-0.6B (28 layers, 8 KV heads, 64 head_dim, bfloat16): **57,344 bytes/token**.
4. **Uses Linux timerfd for sleep precision** — the delay is a real async sleep, not an approximation.

At ISL=4096 (~235 MB KV cache):
- 400 GB/s → ~0.6 ms modeled transfer
- 12.5 GB/s → ~18.8 ms modeled transfer

The ~8.8 ms p50 baseline in the same-rack result is container networking overhead (port-forward + Kind CNI), not mocker behavior. The delta between scenarios reflects the transfer formula directly.

---

## Manifest Structure

### `manifests/dynamo-mock-workers-same-rack.yaml`

DynamoGraphDeployment resource:
- **Global env vars:**
  - `HF_HUB_OFFLINE=1` — No HuggingFace Hub network calls
  - `HF_HOME=/tmp` — Rust mocker writes cache here
  - `HF_HUB_CACHE=/root/.cache/huggingface` — Python reads from mounted HF cache

- **Frontend service:**
  - `image: dynamo-mocker:1.0.1`
  - `python3 -m dynamo.frontend --router-mode kv --http-port 8000`
  - Mounted HF cache for tokenizer resolution

- **Prefill worker:**
  - Affinity: `rack=01`
  - `--disaggregation-mode prefill`
  - `--kv-transfer-bandwidth 400` (GB/s, NVLink analog)
  - Full model snapshot path (avoids HF Hub lookup)

- **Decode worker:**
  - Affinity: `rack=01` (same as prefill)
  - `--disaggregation-mode decode`
  - No bandwidth arg; transfer cost is modeled on the prefill side

### `manifests/dynamo-mock-workers-cross-rack.yaml`

Same structure, different placement:
- Prefill: `rack=01`
- Decode: `rack=02` (cross-rack)
- KV bandwidth: `12.5 GB/s` (100 GbE inter-rack)

---

## Troubleshooting

### DGD Stuck in Creating

The Dynamo operator creates pods from the DGD spec; if image pulls fail or resources are unavailable the DGD stays in Creating. Check the DGD status and the pods it created:

```bash
kubectl get dynamographdeployment dynamo-bench -n dynamo-demo
kubectl describe dynamographdeployment dynamo-bench -n dynamo-demo
kubectl get pods -n dynamo-demo -l app.kubernetes.io/part-of=dynamo-bench
kubectl describe pod <pod-name> -n dynamo-demo
```

### Mocker Pod CrashLoopBackOff

```bash
kubectl logs <pod-name> -n dynamo-demo -f
```

**Common causes:**
- "Failed to create cache directory" → `HF_HOME` not writable (should be `/tmp`)
- "Model snapshots not found" → Model path mismatch or HF cache not mounted; run `make download-model` to verify the cache
- "Tokenizer load failed" → Frontend doesn't have HF cache mounted

### Inference Returns 404

The frontend registers the model when workers come online via NATS. A 404 usually means the frontend started but workers haven't registered yet — wait a few seconds and retry. If it persists:

```bash
kubectl logs -n dynamo-demo -l nvidia.com/dynamo-component-type=frontend
kubectl exec -it <frontend-pod> -n dynamo-demo -- ls /root/.cache/huggingface/models--Qwen*
```

### AIPerf Hangs or Fails

The benchmark port-forwards to localhost:8000. If the port-forward itself fails (address in use, pod not ready), verify connectivity first:

```bash
kubectl port-forward svc/dynamo-bench-frontend -n dynamo-demo 8000:8000 &
sleep 2 && curl http://localhost:8000/health
```

For in-cluster connectivity issues, a debug pod bypasses the port-forward entirely:

```bash
kubectl run -it --rm debug --image=curlimages/curl -n dynamo-demo -- \
  curl http://dynamo-bench-frontend:8000/health
```

### Re-running make mocker-deploy Fails at validate-stack

`make mocker-deploy` removes the placeholder workload as its first step. If it then fails for any reason, the placeholder is gone and `make validate-stack` will fail at check 6 on any subsequent run. This is expected — the placeholder's existence is the stack completion marker, and once removed it cannot be trivially restored without re-running the full sequence.

**Recovery:** `make clean` followed by `make cluster-setup stack-install mocker-deploy`.

For any issue not covered here, `make clean` followed by running all three steps is the fastest recovery path.

---

## Files & Locations

| File | Purpose |
|------|---------|
| `manifests/dynamo-mock-workers-same-rack.yaml` | DGD manifest: same-rack scenario |
| `manifests/dynamo-mock-workers-cross-rack.yaml` | DGD manifest: cross-rack scenario |
| `results/same-rack.json` | AIPerf output (written by `make run-benchmark`) |
| `results/cross-rack.json` | AIPerf output (written by `make run-benchmark`) |
| `results/examples/` | Reference outputs from Ubuntu reference environment |
| `models/hf-cache/` | Qwen3-0.6B model cache |
| `scripts/validate-mocker.sh` | 6-check validation script — run via `make validate-mocker` |
| `.venv/` | Python virtual environment (aiperf, huggingface_hub) |

---

## Key Concepts

### DynamoGraphDeployment (DGD)
User-facing CRD. Operator creates pods for Frontend, Prefill, Decode based on `services` spec.

### nvext Worker IDs
Dynamo extends JSON responses with `nvext.worker_id` containing:
- `prefill_worker_id` — ID of prefill pod that produced KV
- `decode_worker_id` — ID of decode pod that consumed KV
- Confirms disaggregation (different pods for each stage)

### AIPerf v0.7.0 CLI
```bash
aiperf profile MODEL_NAME \
  --url http://localhost:8000 \
  --isl ISL --osl OSL \
  --concurrency N --num-requests N \
  --artifact-dir DIR \
  --profile-export-prefix SCENARIO_NAME
```

Output: `DIR/SCENARIO_NAME.json` (not nested under model slug). See the [AIPerf documentation](https://github.com/ai-dynamo/dynamo/tree/main/benchmarks/aiperf) for the full parameter reference.

---

## Next Steps

See [`docs/architecture.md`](architecture.md#future-extensions) for planned extensions including real GPU inference (Phase 4) and scheduling scenario demonstrations (Phase 5).

---

**Last Updated:** 2026-04-13
