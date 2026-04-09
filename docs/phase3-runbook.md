# Phase 3 Runbook — Benchmarking with Dynamo Mocker

## Overview

Phase 3 deploys real Dynamo mocker workers and runs AIPerf latency benchmarks to compare same-rack vs cross-rack placement. The mocker simulates disaggregated inference by parameterising KV-cache transfer bandwidth.

**What Happens:**
1. Download Qwen3-0.6B model to local cache
2. Deploy DynamoGraphDeployment (DGD) — creates Frontend + Prefill/Decode workers
3. Run AIPerf benchmark tool to measure latency (p50, p99, throughput)
4. Compare results side-by-side
5. Visualize placement effect (3× latency difference at ISL=4096)

---

## Prerequisites

From Phase 2:
- ✅ KAI + Grove + Dynamo platform running
- ✅ Placeholder workload validated

New for Phase 3:
- 15+ GB free disk space (for Qwen3-0.6B model)
- huggingface_hub, aiperf in Python venv: `make install-aiperf`

---

## Execution

### Quick Start

```bash
# One-time model download
make download-model

# Phase 3 complete setup
make phase3

# Deploy same-rack scenario
make phase3-same-rack

# Run benchmark
make run-benchmark

# Deploy cross-rack scenario
make phase3-cross-rack

# Run benchmark again
make run-benchmark

# Compare results side-by-side
make compare-results
```

### Step-by-Step

**Step 1: Install aiperf**
```bash
make install-aiperf
# Creates .venv/, installs aiperf==0.7.0 + huggingface_hub + hf_transfer
```

**Step 2: Download model** (one-time, ~5 GB)
```bash
make download-model
# Uses huggingface_hub to cache Qwen/Qwen3-0.6B locally
# Saved to: models/hf-cache/models--Qwen--Qwen3-0.6B/snapshots/<hash>/
```

**Step 3: Clean up Phase 2 placeholder**
```bash
make cleanup-placeholder
# Deletes placeholder workload (dynamo-placeholder-workload.yaml)
```

**Step 4: Deploy mocker image**
```bash
make download-mocker-image
# Pre-pulls ghcr.io/urregum/ncx-dynamo-demo/dynamo-mocker:1.0.1 into kind nodes
```

**Step 5: Deploy DGD (choose scenario)**

Same-rack:
```bash
make phase3-same-rack
# Applies dynamo-mock-workers-same-rack.yaml
# Prefill + Decode both on rack-01, 400 GB/s KV bandwidth
```

Or cross-rack:
```bash
make phase3-cross-rack
# Applies dynamo-mock-workers-cross-rack.yaml
# Prefill on rack-01, Decode on rack-02, 12.5 GB/s KV bandwidth
```

**Step 6: Validate DGD**
```bash
make validate-phase3
# 6-check validation:
#  1. DGD state = "successful"
#  2. 3+ pods Running (Frontend, Prefill, Decode)
#  3. Frontend Service endpoint reachable
#  4. /health returns 200
#  5. Inference request succeeds (returns chatcmpl)
#  6. Response includes disaggregation worker IDs
```

**Step 7: Run benchmark**
```bash
make run-benchmark
# Profiles model with aiperf at ISL=4096, OSL=32, concurrency=4, 20 requests
# Saves JSON to: results/same-rack.json or results/cross-rack.json
# Based on DGD's demo/scenario label
```

**Step 8: Compare results**
```bash
make compare-results
# Reads results/*.json
# Prints side-by-side latency + throughput table
```

---

## Benchmark Characteristics

### Default Settings
| Parameter | Value | Notes |
|-----------|-------|-------|
| Model | Qwen/Qwen3-0.6B | 370M parameters, lightweight |
| ISL (Input Seq Len) | 4096 | Large prompts → large KV cache |
| OSL (Output Seq Len) | 32 | Short responses |
| Concurrency | 4 | 4 overlapping requests |
| Requests | 20 | Per scenario |
| Artifact dir | `results/` | JSON per scenario |

### Expected Results (Mocker Baselines)

**Same-Rack (400 GB/s):**
- p50 latency: ~9.4 ms
- p99 latency: ~12.6 ms
- Throughput: ~374 req/s

**Cross-Rack (12.5 GB/s):**
- p50 latency: ~28.3 ms (3× same-rack)
- p99 latency: ~29.9 ms
- Throughput: ~136 req/s (2.7× lower)

**Key Insight:** Placement dominates latency. KV transfer time scales linearly with cache size (ISL) and inversely with bandwidth. This demo clearly shows the effect.

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
  - No bandwidth arg (inherits from prefill's configured link)

### `manifests/dynamo-mock-workers-cross-rack.yaml`

Same structure, different placement:
- Prefill: `rack=01`
- Decode: `rack=02` (cross-rack)
- KV bandwidth: `12.5 GB/s` (100 GbE inter-rack)

---

## Troubleshooting

### DGD Stuck in Creating

**Check DGD status:**
```bash
kubectl get dynamographdeployment dynamo-bench -n dynamo-demo
kubectl describe dynamographdeployment dynamo-bench -n dynamo-demo
```

**Check pods:**
```bash
kubectl get pods -n dynamo-demo -l app.kubernetes.io/part-of=dynamo-bench
kubectl describe pod <pod-name> -n dynamo-demo
```

### Mocker Pod CrashLoopBackOff

**Check logs:**
```bash
kubectl logs <pod-name> -n dynamo-demo -f
```

**Common issues:**
- "Failed to create cache directory" → `HF_HOME` not writable (should be `/tmp`)
- "Model snapshots not found" → Model path mismatch or HF cache not mounted
- "Tokenizer load failed" → Frontend doesn't have HF cache mounted

### Inference Returns 404

**Check Frontend logs:**
```bash
kubectl logs -n dynamo-demo -l nvidia.com/dynamo-component-type=frontend
```

**Check model resolution:**
```bash
# Inside Frontend pod:
kubectl exec -it <frontend-pod> -n dynamo-demo -- ls /root/.cache/huggingface/models--Qwen*
```

### AIPerf Hangs or Fails

**Verify connectivity:**
```bash
# Test port-forward
kubectl port-forward svc/dynamo-bench-frontend -n dynamo-demo 8000:8000 &
sleep 3
curl http://localhost:8000/health
```

**Check firewall/routing:**
```bash
# From host, directly test the service
kubectl run -it --rm debug --image=curlimages/curl -n dynamo-demo -- \
  curl http://dynamo-bench-frontend:8000/health
```

---

## Next Steps

### Visualization & Reporting

Generate a markdown report with results:

```bash
cat > results/summary.md << 'EOF'
# Latency Comparison Results

| Scenario | p50 (ms) | p99 (ms) | Throughput (req/s) |
|----------|----------|----------|-------------------|
| Same-Rack | 9.4 | 12.6 | 374 |
| Cross-Rack | 28.3 | 29.9 | 136 |
| **Delta** | **3.0×** | **2.4×** | **0.36×** |

Placement matters: cross-rack KV transfer (12.5 GB/s) vs same-rack (400 GB/s).
EOF
```

### Real GPU Inference (Future Extension)

To run actual inference instead of mocker:
1. Replace `dynamo-mocker` image with vLLM/SGLang runtime
2. Remove `--speedup-ratio 0` (let compute latency contribute)
3. Extend ISL to 1024+ for clearer signal
4. Validate throughput via token generation, not just request count

### Multi-Scenario Benchmarks

```bash
# Run multiple ISL values
for ISL in 512 1024 2048 4096 8192; do
  make phase3-same-rack
  sed -i "s/BENCHMARK_ISL=4096/BENCHMARK_ISL=$ISL/" Makefile
  make run-benchmark
done

# Analyze scaling: latency should grow ~linearly with ISL
```

---

## Files & Locations

| File | Purpose |
|------|---------|
| `manifests/dynamo-mock-workers-same-rack.yaml` | DGD manifest: same-rack scenario |
| `manifests/dynamo-mock-workers-cross-rack.yaml` | DGD manifest: cross-rack scenario |
| `results/same-rack.json` | AIPerf profile output |
| `results/cross-rack.json` | AIPerf profile output |
| `models/hf-cache/` | Qwen3-0.6B model cache |
| `scripts/validate-phase3.sh` | 6-check validation script |
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

Output: `DIR/SCENARIO_NAME.json` (not nested under model slug)

---

**Runbook Version:** 1.0  
**Last Updated:** 2026-04-09  
**Audience:** Demo operators, benchmarking researchers
