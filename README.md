# NCX Dynamo Demo

A lightweight, local Kubernetes demonstration of **NVIDIA Dynamo** disaggregated inference — showing gang scheduling, rack-aware placement, and latency impact via benchmarking.

**Core Demo:**
- Deploy a 4-node Kind cluster with rack topology
- Install KAI Scheduler + Grove + Dynamo platform
- Run two placement scenarios (same-rack vs cross-rack)
- Measure KV-cache transfer latency with AIPerf
- **Observe ~3× latency difference** driven by placement

> ⚠️ **Not Production.** Uses GPU mockers (simulated inference), Kind cluster (containerized), and local machine resources. Designed for learning and portfolio demonstration.

---

## Quick Start

### 1. Verify Prerequisites

```bash
make validate-prereqs
```

Requires: Docker, Kind, kubectl, Helm, nvidia-container-toolkit, GPU with drivers

### 2. Create Cluster (Phase 1)

```bash
make phase1
# Creates 4-node Kind cluster with rack topology
# Time: ~3-5 minutes
```

### 3. Install Scheduling Stack (Phase 2)

```bash
make phase2
# Installs KAI Scheduler, Grove, Dynamo platform
# Deploys placeholder workload
# Time: ~3-5 minutes
```

### 4. Run Benchmarks (Phase 3)

```bash
make phase3                 # Download model, deploy mocker
make phase3-same-rack       # Deploy same-rack scenario
make run-benchmark          # Benchmark it
make phase3-cross-rack      # Deploy cross-rack scenario
make run-benchmark          # Benchmark it
make compare-results        # Print latency comparison
```

---

## What You'll See

### Benchmark Results

| Scenario | p50 Latency | p99 Latency | Throughput |
|----------|-------------|-------------|-----------|
| **Same-Rack** (400 GB/s) | 9.4 ms | 12.6 ms | 374 req/s |
| **Cross-Rack** (12.5 GB/s) | 28.3 ms | 29.9 ms | 136 req/s |
| **Ratio** | **3.0×** | **2.4×** | **0.36×** |

Placement dramatically affects latency in disaggregated inference due to KV-cache transfer costs.

---

## Architecture

Three-phase setup:

### Phase 1: Cluster
- Kind cluster (1 control plane + 3 workers)
- Rack topology (rack-01, rack-02) for placement simulation
- GPU device passthrough via NVIDIA container runtime
- No GPU Operator — keeps setup lightweight

### Phase 2: Scheduling Stack
- **KAI Scheduler** — Gang scheduling, queue management
- **Grove** — Converts PodCliqueSet CRDs → ganged deployments
- **Dynamo Platform** — Disaggregated inference operator + NATS bus
- Placeholder workload validates gang scheduling

### Phase 3: Benchmarking
- **Dynamo Mocker** — Simulates disaggregated inference by parameterising KV transfer bandwidth
- **AIPerf** — Measures latency (p50, p99, throughput)
- Compare two scenarios: same-rack (collocated) vs cross-rack (distant)

**Full architecture details:** See [`docs/architecture.md`](docs/architecture.md)

---

## Documentation

| Document | Purpose |
|----------|---------|
| [`docs/architecture.md`](docs/architecture.md) | Design decisions, topology, GPU strategy, future extensions |
| [`docs/phase1-runbook.md`](docs/phase1-runbook.md) | Cluster creation, prerequisites, validation checklist |
| [`docs/phase2-runbook.md`](docs/phase2-runbook.md) | Scheduling stack installation, KAI + Grove + Dynamo |
| [`docs/phase3-runbook.md`](docs/phase3-runbook.md) | Mocker deployment, AIPerf benchmarking, troubleshooting |

---

## Project Structure

```
ncx-dynamo-demo/
├── Makefile                              # Orchestration targets (3-phase automation)
├── README.md                             # This file
├── requirements.txt                      # Python dependencies (aiperf, huggingface_hub)
├── .pre-commit-config.yaml               # YAML linting, trailing whitespace
├── .gitignore                            # Excludes .venv/, models/, .vscode/, etc.
├── docs/
│   ├── architecture.md                   # Design overview, topology, future work
│   ├── phase1-runbook.md                 # Cluster setup instructions
│   ├── phase2-runbook.md                 # Scheduling stack installation
│   └── phase3-runbook.md                 # Mocker deployment, benchmarking
├── manifests/
│   ├── dynamo-mock-workers-same-rack.yaml        # DGD: same-rack scenario
│   ├── dynamo-mock-workers-cross-rack.yaml       # DGD: cross-rack scenario
│   ├── dynamo-namespace.yaml                     # Workload namespace
│   ├── dynamo-placeholder-workload.yaml          # Phase 2 gang scheduling validation
│   ├── nvidia-runtimeclass.yaml                  # GPU pod runtime
│   ├── nvidia-device-plugin.yaml                 # NVIDIA device plugin (optional)
│   └── dynamo-namespace.yaml                     # Workload namespace
├── infra/
│   ├── kind-config.yaml.tpl              # Kind cluster config template (REPO_ROOT placeholder)
│   ├── kind-config.yaml                  # Generated from template (gitignored)
│   └── operator-values.yaml              # Dynamo Helm chart overrides
├── scripts/
│   ├── validate-phase1.sh                # Phase 1 health checks
│   ├── validate-phase2.sh                # Phase 2 health checks
│   ├── validate-phase3.sh                # Phase 3 health checks
│   ├── advertise-gpu-resources.sh        # Manual GPU resource patching
│   └── setup-ngc-secret.sh               # Create NGC imagePullSecret
├── models/
│   ├── hf-cache/                         # HuggingFace model cache (staged via make download-model)
│   └── .gitkeep
├── results/
│   ├── README.md                         # Notes on benchmark data
│   ├── same-rack.json                    # AIPerf profile (illustrative)
│   └── cross-rack.json                   # AIPerf profile (illustrative)
├── artifacts/                            # Intermediate build outputs (gitignored)
├── container/                            # Custom container build configs (if needed)
├── LICENSE                               # MIT
└── .venv/                                # Python virtual environment (gitignored)
```

---

## Common Tasks

### Validate Everything

```bash
make validate-phase1  # Cluster health
make validate-phase2  # Scheduling stack
make validate-phase3  # DGD + mocker + inference
```

### Check Cluster Status

```bash
make cluster-status   # Nodes, pods, resources
make show-placement   # Which rack each pod landed on
```

### Benchmark Specific Parameters

Edit `Makefile` variables:
```makefile
BENCHMARK_ISL := 4096      # Input Sequence Length (tokens)
BENCHMARK_OSL := 32        # Output Sequence Length
BENCHMARK_CONC := 4        # Concurrent requests
BENCHMARK_REQS := 20       # Total requests
```

Then:
```bash
make run-benchmark
```

### Clean Up

```bash
make clean          # Delete cluster (careful!)
make cluster-down   # Just delete cluster, keep other resources
```

---

## Troubleshooting

### Common Issues

**Cluster won't create:**
```bash
kind get clusters
kind delete cluster --name=ncx-demo-cluster  # Clean up stale cluster
make phase1  # Try again
```

**GPU resources not showing:**
```bash
make advertise-gpu-resources
```

**Pods stuck in CrashLoopBackOff:**
```bash
kubectl logs -n dynamo-demo <pod-name> -f
# Check HF cache mount, model path, environment variables
```

**AIPerf benchmark hangs:**
```bash
# Verify frontend is reachable
kubectl port-forward svc/dynamo-bench-frontend -n dynamo-demo 8000:8000 &
curl http://localhost:8000/health
```

See runbook docs for detailed troubleshooting.

---

## Key Concepts

### Disaggregated Inference
Splitting inference into two stages:
- **Prefill:** Processes user prompt, produces KV cache
- **Decode:** Consumes KV cache, generates response tokens one-by-one

Enables placement optimization: prefill may prefer fast GPU for batching, decode benefits from lower memory bandwidth.

### KV-Cache Transfer
The bottleneck in disaggregated inference. Prefill produces cache; decode needs it.
- **Same-rack (NVLink, 400 GB/s):** ~0.1 ms for 512-token cache
- **Cross-rack (100 GbE, 12.5 GB/s):** ~3 ms for same cache

This demo uses a mocker to parameterise this cost and show placement impact.

### Gang Scheduling
KAI Scheduler ensures all pods in a gang (prefill + decode + frontend) start together or none start. Prevents partial deployments.

---

## Limitations

### What This Demo Does
- ✅ Demonstrates gang scheduling and rack-aware placement
- ✅ Measures KV-cache transfer latency impact
- ✅ Validates Dynamo operator integration with Kubernetes
- ✅ Provides fast cluster bring-up/teardown (reproducible setup)

### What This Demo Doesn't
- ❌ Run real GPU inference (uses mocks)
- ❌ Support multi-cluster federation
- ❌ Include observability stack (Prometheus, Grafana)
- ❌ Demonstrate token-by-token generation or batching

### Scaling
- Suitable for 3-10 pod workloads
- Single shared RTX 3070 Ti (consumer GPU)
- Not intended for production deployment

---

## Future Enhancements

See [`docs/architecture.md`](docs/architecture.md#future-extensions) for planned extensions:
- Real vLLM/SGLang inference
- Multi-cluster federation
- Prometheus + Grafana observability
- Network latency injection (tc/netem) for more realistic scenarios

---

## Contributing

This is a demonstration project. For bug reports or improvements:

1. Check existing issues
2. Include:
   - OS/version (e.g., Ubuntu 24.04)
   - Docker/Kind/kubectl versions
   - Steps to reproduce
   - Logs from relevant pods

---

## License

MIT License — See [`LICENSE`](LICENSE)

---

## Acknowledgments

Built on:
- **NVIDIA Dynamo** — Disaggregated inference platform
- **KAI Scheduler** — Kubernetes native gang scheduler
- **Grove** — PodCliqueSet orchestration
- **Kind** — Local Kubernetes for testing
- **AIPerf** — Benchmarking tool

---

**Last Updated:** 2026-04-09  
**Status:** Phase 3 Complete ✅ (benchmarking ready)  
**Next Steps:** Run `make phase3` to benchmark placement impact on latency
