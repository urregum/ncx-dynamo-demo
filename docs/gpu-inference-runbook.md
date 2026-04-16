# GPU Inference Runbook

This runbook covers the GPU inference track (Phase 4): deploying real vLLM inference on
the dedicated `rack-gpu` node using NVIDIA Dynamo's disaggregated serving mode.

**Prerequisites:** `make cluster-setup` and `make stack-install` must be complete. The
mocker-benchmark track does not need to be run first — the GPU track uses a separate DGD
on a separate node and is fully independent.

NGC credentials must be configured — image pulls in this track (and any future tracks)
require `nvcr.io` authentication. If you followed the stack runbook, this is already
done. If not, see [`docs/stack-runbook.md`](stack-runbook.md) for credential setup before
proceeding.

If you are coming directly from `stack-install` without having run the mocker-benchmark
track, two one-time setup steps are required before proceeding:

```bash
make download-model     # Cache Qwen3-0.6B locally (~1.5 GB); required for vLLM startup
make install-aiperf     # Install aiperf benchmark tool; required only for gpu-benchmark
```

`download-model` populates the host HF cache that is mounted into all Kind nodes at
`/root/.cache/huggingface`. Without it, the decode and prefill workers will fail to load
the model at startup. `install-aiperf` is only needed if you plan to run `gpu-benchmark`.

---

## What This Track Demonstrates

- Real token generation via vLLM, not simulated
- Disaggregated inference topology (prefill worker + decode worker) on a single GPU
- KV cache transfer via NixlConnector (in-GPU-memory, effectively zero latency)
- The same Dynamo operator, KAI gang scheduling, and Grove orchestration as the mocker track

**What it does not demonstrate:** cross-rack KV transfer cost (that requires two physical
GPUs on different nodes). Latency numbers here are compute-driven, not bandwidth-driven,
and are not directly comparable to mocker results.

---

## Hardware Requirements

- NVIDIA GPU (any CUDA-capable card)
- 8+ GiB VRAM recommended for disaggregated mode with Qwen3-0.6B at `--gpu-memory-utilization 0.4`
- `nvidia-container-toolkit` installed on the host (required for `infra/kind-config-gpu.yaml.tpl`)

This was developed on an RTX 3070 Ti (8 GiB). See [VRAM Budget](#vram-budget) for
guidance on other hardware.

---

## Step 1 — Pre-pull the vLLM Runtime Image

The vLLM runtime image is approximately 9 GB. This step pulls it once to the host Docker
cache, then imports it into all 5 Kind nodes (control-plane + 4 workers) so pod startup
does not trigger a live registry pull.

```bash
make gpu-prepull
```

**Disk usage:** ~9 GB host Docker cache + ~9 GB per Kind node containerd store = roughly
50 GB total. All of this is reclaimed when the cluster is torn down (`make cluster-down`
deletes the Kind containers and their filesystems). Ensure you have at least 60 GB free
before running this step.

This takes several minutes on first run. Run it once after `cluster-setup` and again only
if the cluster is recreated.

---

## Step 2 — Deploy the GPU Inference DGD

```bash
make gpu-deploy
```

This applies `manifests/dynamo-vllm-gpu.yaml` and waits for all three pods to reach
Running state (Frontend, decode, prefill). Allow up to 10 minutes — vLLM loads model
weights and runs a GPU memory profiling pass at startup.

**Expected pod placement:**

```
dynamo-gpu-frontend-...   -> rack-01  (no affinity; KAI places on available worker)
dynamo-gpu-decode-...     -> rack-gpu (forced by nodeAffinity)
dynamo-gpu-prefill-...    -> rack-gpu (forced by nodeAffinity)
```

### Startup Sequencing

vLLM pre-allocates its full `--gpu-memory-utilization` VRAM budget at startup via a
profiling pass (loads weights, runs a forward pass to measure peak activation memory,
then calculates how many KV cache blocks fit in the remainder). Two workers running
this pass simultaneously on the same GPU can exceed VRAM during the profiling phase.

The prefill pod uses a `wait-for-decode` init container that polls decode's Dynamo
system health endpoint until decode reports `generate:ready`:

```yaml
initContainers:
  - name: wait-for-decode
    image: curlimages/curl:8.11.1
    command: ['sh', '-c',
      'until curl -sf http://dynamo-gpu-decode.dynamo-demo.svc.cluster.local:9090/health;
       do echo "waiting for decode..."; sleep 5; done']
```

The Dynamo system endpoint at port 9090 reports `generate:ready` only after vLLM
completes its profiling pass and VRAM is locked in steady state. The Kubernetes
service only routes to decode once the pod's readiness probe passes — which uses the
same endpoint — so a successful curl is a hardware-agnostic guarantee that decode
is fully initialized. The `curlimages/curl:8.11.1` image is pre-loaded into all Kind
nodes by `make gpu-prepull` to avoid a live registry pull at pod start.

---

## Step 3 — Validate the Deployment

```bash
make gpu-validate
```

Runs two checks:
1. `GET /health` — expects HTTP 200
2. `POST /v1/chat/completions` with `{"content": "What is 2+2?"}` — prints the response

Sample output:
```
==> Health check...
 ✓ /health OK
==> Inference request (What is 2+2?)...
 Response: 2 + 2 = 4
✓ GPU inference validation passed
```

---

## Step 4 — Benchmark (Optional)

AIPerf runs against the GPU frontend using the same parameters as the mocker benchmark
(ISL=4096, OSL=32, concurrency=4). Results are saved to `results/gpu-real.json`.

```bash
make gpu-benchmark
```

GPU inference latency is compute-bound, not bandwidth-bound — these numbers reflect
model throughput on the RTX 3070 Ti and are not directly comparable to the mocker
benchmark results (which measure KV transfer bandwidth cost). Run `make compare-results`
separately if you also have mocker results and want the same-rack vs cross-rack table.

---

## Additional Commands

### Streaming Response

Shows real token arrival timing, visually distinct from the smoke test:

```bash
make gpu-stream
```

Run `watch -n1 nvidia-smi` in a separate terminal during this to confirm GPU utilization.

### Model and Scheduler Status

```bash
make gpu-status
```

Shows registered models (`/v1/models`), KAI PodGang state, and pod placement.

### OpenAI SDK

For developer-oriented exploration:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:9000/v1", api_key="unused")
response = client.chat.completions.create(
    model="Qwen/Qwen3-0.6B",
    messages=[{"role": "user", "content": "What is disaggregated inference?"}],
    max_tokens=128,
)
print(response.choices[0].message.content)
```

Requires an active port-forward in a separate terminal:

```bash
kubectl port-forward svc/dynamo-gpu-frontend -n dynamo-demo 9000:8000
```

---

## Teardown

```bash
kubectl delete dynamographdeployment dynamo-gpu -n dynamo-demo
```

The mocker track can then be redeployed with `make mocker-deploy` if needed.

---

## VRAM Budget

Each worker process carries ~1.6 GiB of fixed overhead (CUDA context, PyTorch
allocator, NCCL buffers, Dynamo runtime) on top of the `--gpu-memory-utilization`
budget. On an 8 GiB card this overhead dominates: two workers at `gmu=0.4` would
require ~9.5 GiB total. The maximum viable `gmu` satisfies:

```
2 × (gmu × usable_VRAM + 1.6 GiB) ≤ usable_VRAM
```

Reference configuration (Qwen3-0.6B, disaggregated same-GPU):

| Hardware | Usable VRAM | `--gpu-memory-utilization` | `--max-model-len` | Notes |
|----------|-------------|----------------------------|-------------------|-------|
| RTX 3070 Ti | ~7.6 GiB | 0.25 | 2048 | Overhead-constrained; demo-only context |
| RTX 4090 | ~23.6 GiB | 0.6 | 32768 | Comfortable; larger models viable |
| RTX 5090 | ~31.6 GiB | 0.7 | 40960 | Qwen3-1.7B feasible without quantization |
| RTX 6000 Ada | ~47.6 GiB | 0.85 | 40960 | Upstream reference; full context window |
| GB200 NVL | HBM | 0.9+ | 40960 | Multi-GPU topology; different NixlConnector path |

On higher-VRAM cards the overhead fraction shrinks, allowing both larger `gmu` values
and full context windows. OOM at startup is the failure mode if `gmu` is set too
high — decrease by 0.05 increments and re-deploy.

---

## Troubleshooting

### Pods stuck in Pending

```bash
kubectl describe pod <pod-name> -n dynamo-demo
```

Common causes:
- `nvidia.com/gpu` resource not advertised: `make advertise-gpu-resources`
- `rack-gpu` node not present: check `kubectl get nodes -L rack`; recreate cluster if needed
- Image not pre-loaded: `make gpu-prepull`

### Prefill pod OOM at startup

The `wait-for-decode` init container ensures prefill only starts after decode is
fully initialized. If prefill still OOMs, the VRAM overhead budget is exceeded —
lower `--gpu-memory-utilization` on both workers and see [VRAM Budget](#vram-budget)
for the constraint formula.

If the init container hangs indefinitely, check decode's logs:
```bash
kubectl logs -n dynamo-demo <decode-pod-name> --follow
```
If decode itself is crashing (e.g., OOM during its own startup), fix decode first.

### `kv-transfer-config` errors in prefill/decode logs

```bash
# List pods to find exact names
kubectl get pods -n dynamo-demo -l app.kubernetes.io/name=dynamo-gpu
# Then stream logs for the relevant pod
kubectl logs -n dynamo-demo <pod-name> --follow
```

Verify the `--kv-transfer-config` JSON format against the upstream reference:
`ai-dynamo/dynamo` tag `v1.0.1`, path `examples/backends/vllm/launch/disagg_same_gpu.sh`.
The `kv_rank`, `kv_parallel_size`, and `kv_role` fields must match between the two workers.

### Health check fails after `gpu-deploy`

If `/health` returns non-200 or times out, the model may still be loading. Wait 2-3
minutes and retry `make gpu-validate`. The 10-minute pod wait in `gpu-deploy` covers
pod Running state, not model load completion.

---

**Last Updated:** 2026-04-15
