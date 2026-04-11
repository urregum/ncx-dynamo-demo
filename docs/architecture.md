# NCX Dynamo Demo — Architecture & Design

## Project Scope

This demonstration showcases **NVIDIA Dynamo** in a local Kubernetes environment — specifically gang scheduling, disaggregated inference architecture, and latency-aware placement on simulated rack topology.

**Not a production system.** The environment uses:
- Local GPU (RTX 3070 Ti) for scheduling validation, not inference compute
- Kind cluster with containerized nodes
- Mock Dynamo workers simulating disaggregated prefill/decode inference
- AIPerf benchmarking to measure latency differences from placement changes

---

## Design Goals

### Primary Objectives
1. **Demonstrate gang scheduling** — KAI + Grove coordinate groups of pods (prefill + decode workers)
2. **Measure placement impact on latency** — Same-rack (NVLink analog, 400 GB/s) vs cross-rack (100 GbE, 12.5 GB/s)
3. **Showcase Kubernetes + Dynamo integration** — CRD-driven platform with NATS coordination
4. **Support iterative development** — Fast cluster bring-up/teardown via Makefile

### Why These Choices?
- **Kind cluster:** Local development, full Kubernetes API, matches production topology abstractions
- **GPU mockers:** Avoids complexity of vLLM/CUDA setup; latency is dominated by KV transfer simulation, not compute
- **Rack topology via labels:** Simulates multi-rack deployment; placement constraints are testable
- **AIPerf benchmarking:** Portable latency measurement tool, compatible with any HTTP inference backend

---

## Architecture Layers

### Layer 1: Infrastructure (Kind Cluster)

**Topology:**
- 1 control plane
- 3 worker nodes split across 2 racks (rack-01: 2 workers, rack-02: 1 worker)
- All workers share one physical RTX 3070 Ti via NVIDIA container runtime
- HuggingFace model cache mounted read-only on all nodes

**GPU Setup:**
- GPU device files (`/dev/nvidia0`, `/dev/nvidia-uvm`, `/dev/nvidiactl`) mounted into worker nodes
- NVIDIA container runtime binaries mounted for pod GPU access
- `nvidia` RuntimeClass available for pods requesting GPU
- No GPU Operator — avoids library dependency issues with containerized environment

### Layer 2: Scheduling Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| **KAI Scheduler** | v0.14.0 | Kubernetes native gang scheduler with queue management |
| **Grove** | v0.1.0-alpha.7 | Operator: converts `PodCliqueSet` → ganged deployments |
| **Dynamo Platform** | v1.0.1 | Disaggregated inference operator + NATS messaging |

**Data Flow:**
1. User applies `DynamoGraphDeployment` (DGD) CRD
2. Dynamo operator creates 3 pod templates: Frontend, Prefill Worker, Decode Worker
3. Each template becomes a `PodClique` (via Grove); related cliques form `PodCliqueSet`
4. KAI Scheduler enforces gang scheduling: all pods in cliques start together or none start — this applies to both the Phase 2 placeholder and the Phase 3 DGD workload
5. NATS bus coordinates inter-pod communication (worker discovery, request routing)

### Component Topology Rationale

This demo deploys the minimum viable disaggregated configuration: **1 frontend, 1 prefill worker, 1 decode worker**.

In production, Dynamo's planner dynamically computes prefill and decode replica counts based on traffic (input/output sequence length distribution, throughput targets, and ITL SLA). Decode workers typically outnumber prefill workers because token generation is the longer operation. No fixed ratio is prescribed upstream.

For this demo, production asymmetry is not meaningful — there is no real compute to model, and the mocker's latency is entirely determined by KV transfer delay, not worker count. The 1:1 topology cleanly isolates the placement variable: one prefill per scenario, one decode worker placed on the target rack.

This topology has no bearing on a future KVBM extension, which concerns cache block management within a single worker's GPU memory rather than prefill/decode ratios.

---

### Layer 3: Workload (Mock Dynamo Mocker)

**Image:** `ghcr.io/urregum/ncx-dynamo-demo/dynamo-mocker:1.0.1`

**Components:**
- **Frontend** (Python + integrated KV router)
  - Listens on HTTP port 8000
  - Routes requests to prefill/decode workers based on KV cache overlap (`--router-mode kv`)
  - The router is not a separate pod — it is an integrated mode of the frontend process, consistent with upstream Dynamo's implementation
  - Resolves tokenizer from HF cache for KV routing logic
  
- **Prefill Worker** (Rust-based mock)
  - Simulates KV-cache production via `--disaggregation-mode prefill`
  - On completing a request, injects a real sleep delay modeling KV transfer to the decode worker:
    ```
    delay_ms = num_input_tokens × kv_bytes_per_token / (bandwidth_GB_s × 1e9) × 1000
    ```
  - `kv_bytes_per_token` is auto-computed from model config (`num_layers × 2 × num_kv_heads × head_dim × dtype_bytes`)
  - `--speedup-ratio 0` suppresses all GPU compute delays; only the KV transfer handoff delay remains
  - `--kv-transfer-bandwidth` is set only on the prefill worker — it models the cost of transferring the cache *from* prefill *to* decode

- **Decode Worker** (Rust-based mock)
  - Consumes KV cache via `--disaggregation-mode decode`
  - No bandwidth arg; the transfer cost is modeled on the prefill side as the cost of moving the KV cache to the decode worker

---

## Scenario Definitions

### Scenario A: Same-Rack (NVLink Analog)
**Goal:** Measure latency when prefill and decode collocate (best case)

**Configuration:**
- Prefill: rack-01 (node affinity)
- Decode: rack-01 (node affinity)
- KV bandwidth: 400 GB/s (simulates NVLink3 intra-rack)

**Expected Result at ISL=4096, concurrency=4:**
- p50: ~9.4 ms
- p99: ~12.6 ms
- Throughput: ~374 req/s

### Scenario B: Cross-Rack (East-West Hop)
**Goal:** Measure latency when prefill and decode span racks (worst case)

**Configuration:**
- Prefill: rack-01 (node affinity)
- Decode: rack-02 (node affinity)
- KV bandwidth: 12.5 GB/s (simulates 100 GbE inter-rack link)

**Expected Result at ISL=4096, concurrency=4:**
- p50: ~28.3 ms (~3× same-rack)
- p99: ~29.9 ms
- Throughput: ~136 req/s (~2.7× difference)

**Key Insight:** Placement dramatically affects latency due to KV transfer cost. The mock allows manipulation of network parameters to show the effect without real network modification.

---

## Environment Setup

### Prerequisites on Host
- Docker (28+)
- Kind (v0.31.0+)
- kubectl (v1.34+)
- Helm (v3.20+)
- nvidia-container-toolkit (1.19+) — required for Kind node GPU device mounts
- NVIDIA GPU with drivers — required by the current cluster template (`kind-config.yaml.tpl` mounts `/dev/nvidia*` at cluster creation time); the mocker workload itself does not use the GPU, but the cluster setup does. A GPU-free cluster template is a planned improvement.

### Installation

**Phase 1: Cluster**
```bash
make validate-prereqs
make phase1              # Creates Kind cluster with rack topology
```

**Phase 2: Scheduling Stack**
```bash
make phase2              # Installs KAI + Grove + Dynamo
```

**Phase 3: Benchmarking**
```bash
make phase3              # Downloads mocker, deploys DGD, installs aiperf
make phase3-same-rack    # Deploy same-rack scenario
make run-benchmark       # Run aiperf profile
make compare-results     # Print side-by-side latency table
```

---

## Key Technical Decisions

### 1. HF Cache Access (Rust + Python Split)
**Problem:** Dynamo mocker (Rust) writes to `$HF_HOME/hub` (needs writable dir). Python HF Hub reads from `$HF_HUB_CACHE` (read-only mount).

**Solution:**
```bash
HF_HOME=/tmp                              # Rust writes here (writable)
HF_HUB_CACHE=/root/.cache/huggingface     # Python reads here (read-only)
```

Plus: Model name must include namespace slash (`Qwen/Qwen3-0.6B`) so Rust cache dir matches Python's (`models--Qwen--Qwen3-0.6B`).

### 2. Kind Cluster Design
**Why not GPU Operator?**
- GPU Operator is enterprise-focused (drivers, monitoring, MIG management)
- Kind nodes are containers; GPU Operator adds unnecessary complexity
- Manual mount of nvidia-container-runtime is simpler and sufficient

**Why not vLLM/real inference?**
- Adds 9+ GB image per node, slow to deploy
- SGLang/CUDA library dependencies complicate setup
- GPU mocker simulates latency purely via KV transfer — sufficient for demo goal

### 3. Rack Topology via Labels
**Why Kubernetes labels, not actual network config?**

In a real Superpod environment, nodes are labeled with their rack and NVLink domain during cluster provisioning. KAI Scheduler is designed to use these labels for topology-aware PodClique placement — keeping gang members within the same rack to minimize KV transfer cost.

This demo applies the same mechanism: `rack=01` / `rack=02` labels on Kind worker nodes, and node affinity in the DGD manifests, mirror exactly what production infrastructure would provide. The mocker then parameterizes the bandwidth to match each topology.

Both placement scenarios are **forced via node affinity** rather than left to the scheduler. Without a prior workload to create load imbalance, KAI would always schedule optimally (same-rack) — so forcing cross-rack is necessary to demonstrate the penalty that topology-aware placement is designed to prevent.

### 4. NATS for Coordination
Dynamo operator auto-injects NATS_SERVER env var into all pods. Workers use NATS to:
- Register with frontend (service discovery)
- Coordinate request routing
- Achieve leader election among parallel workers

---

## Validation Checkpoints

| Phase | Validation | Script |
|-------|-----------|--------|
| 1 | Cluster health, rack labels, GPU resources | `scripts/validate-phase1.sh` |
| 2 | KAI + Grove + Dynamo running, workload ganged | `scripts/validate-phase2.sh` |
| 3 | DGD healthy, inference works, disaggregation confirmed | `scripts/validate-phase3.sh` |

---

## Performance Characteristics

### What This Demo Measures
- **KV Transfer Latency:** Dominant component of end-to-end latency in disaggregated inference
- **Scheduling Overhead:** KAI gang scheduling, Grove PodCliqueSet → deployment conversion
- **Placement Sensitivity:** How rack affinity affects latency (3× difference in test scenario)

### What This Demo Does NOT Measure
- Compute latency (suppressed via `--speedup-ratio 0`)
- Real GPU utilization or memory bandwidth
- Tokenizer latency (single batch, no batching optimization)
- Production network characteristics (simulated via bandwidth param)

### Scaling Limitations
- Kind cluster suitable for 3-10 pod workloads; scales poorly beyond
- Mocker workers do not use the GPU; no resource contention between pods in the current demo
- A real inference workload would be constrained by the single RTX 3070 Ti (see [Future Extensions](#future-extensions))

---

## Future Extensions

### If You Later Add KV Block Manager (KVBM) Demo
- Extend a decode worker with KVBM configuration (block eviction policy, prefix cache size)
- Demonstrates cache block management and prefix reuse on a single GPU without requiring multi-GPU transfer paths
- NIXL (NVIDIA Interconnect Library — the real KV transfer substrate using NVLink/RDMA) is not applicable in this environment; the mocker simulates its latency consequence only
- Does not require changes to the current 1:1 prefill/decode topology

### If You Later Add Real Inference
- Replace mocker image with vLLM runtime
- Pre-stage vLLM image on nodes during cluster creation
- Adjust KV bandwidth to match actual hardware (e.g., NVLink3 = 900 GB/s)
- Extend AIPerf validation to check token generation quality

### If You Later Add Multi-Cluster
- Deploy multiple kind clusters in different network zones
- Use Istio/Envoy for cross-cluster traffic
- Test KAI scheduler with global queue spanning clusters

### If You Later Add Observability
- Deploy Prometheus + Grafana (already running in many demos)
- Scrape Dynamo operator metrics (request rates, queue depth)
- Correlate with latency measurements from AIPerf

---

## Glossary

| Term | Definition |
|------|-----------|
| **DGD** | DynamoGraphDeployment CRD; deployed by user, orchestrates workload |
| **PodCliqueSet** | Grove CRD; groups related pods (frontend, prefill, decode) |
| **PodGang** | Scheduling group created by KAI; enforces all-or-nothing execution |
| **KV Cache** | Key-Value cache produced by prefill, consumed by decode |
| **Disaggregation** | Splitting inference into prefill + decode stages on different workers |
| **ISL** | Input Sequence Length (prompt tokens); affects KV size |
| **OSL** | Output Sequence Length (response tokens); drives decode iterations |

---

**Architecture Version:** 1.0  
**Last Updated:** 2026-04-09  
**Audience:** Demo users, documentation readers, future contributors
