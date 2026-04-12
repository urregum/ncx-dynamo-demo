# Phase 1 Runbook — Cluster Setup

## Overview

Phase 1 creates a Kind cluster (4 nodes) with rack topology labels. This is the foundation for the scheduling stack and Dynamo workloads.

**Cluster Topology:**
- 1 control plane
- 3 workers: 2 in rack-01, 1 in rack-02

---

## Prerequisites

`make phase1` automatically runs `make validate-prereqs` before doing anything — running it manually first gives explicit visibility into your system state before any cluster is created, which is useful on first setup.

```bash
make validate-prereqs
```

**Required:**
- Docker 28+
- Kind v0.31.0+
- kubectl v1.34+
- Helm v3.20+

**GPU (optional for mocker demo):**
`make phase1` auto-detects GPU presence at `make kind-config` time:
- **GPU present** (`/dev/nvidia0` exists): uses `infra/kind-config-gpu.yaml.tpl` — mounts GPU device files into Kind nodes. Requires `nvidia-container-toolkit 1.19+`.
- **No GPU**: uses `infra/kind-config-no-gpu.yaml.tpl` — no device mounts. Mocker workload runs identically in either case.

**Expected output:**
```
✓ All prerequisites installed

==> Checking for NVIDIA GPU (not required for demo with mockers only)...
GPU 0: NVIDIA GeForce RTX 3070 Ti (UUID: ...)   # if GPU present
# or:
⚠ No NVIDIA GPU detected - will use software mockers only
```

The template selection message (`==> GPU detected — using GPU cluster template`) appears later, during `make phase1` when `kind-config` runs.

---

## Execution

```bash
make phase1
```

This runs in sequence:
1. `make validate-prereqs` — Check system
2. `make cluster-up` — Create Kind cluster
3. `make fix-inotify-limits` — Prevent file-watcher crashes
4. `make apply-runtimeclass` — Deploy nvidia RuntimeClass
5. `make advertise-gpu-resources` — Advertise GPU capacity

**Time:** ~30 seconds with Docker image layers already cached; up to 2 minutes on a completely fresh system while Kind pulls node images.

If a specific step fails, run it individually. See `make help` for all available targets.

---

## Validation

```bash
make validate-phase1
```

Expected output: **7/7 checks passing**

### Manual Checks

**Cluster health:**
```bash
kubectl get nodes
# All 4 nodes should be Ready
```

**Rack topology:**
```bash
kubectl get nodes -L rack
# worker, worker2 should have rack=01
# worker3 should have rack=02
```

**GPU resources advertised:**
```bash
kubectl describe nodes | grep -E "(Name:|nvidia.com/gpu)"
# Each worker should show nvidia.com/gpu: 1 in capacity and allocatable
```

**NVIDIA RuntimeClass:**
```bash
kubectl get runtimeclass nvidia
# Should exist
```

---

## Troubleshooting

### Nodes Not Ready

Kind nodes are Docker containers; the CNI plugin initializes asynchronously after cluster creation. If nodes remain NotReady for more than 2 minutes, check for resource constraints or initialization errors:

```bash
kubectl describe node <node-name>
# Check the Conditions section — common causes: CNI still initializing, insufficient memory
```

### GPU Resources Not Showing

The `advertise-gpu-resources` step patches `nvidia.com/gpu` capacity onto nodes via the Kubernetes API. This patch is not persisted — a Docker or node restart drops it. Re-run to restore:

```bash
make advertise-gpu-resources
```

### "Too Many Open Files" Errors

The inotify limits are set per Kind node via `sysctl` and are not persisted across node restarts. Re-run to restore:

```bash
make fix-inotify-limits
```

For any issue not covered here, `make clean` followed by `make phase1` is the fastest recovery path in a demo environment.

---

## Next Steps

Proceed to Phase 2: [`docs/phase2-runbook.md`](phase2-runbook.md)

---

**Last Updated:** 2026-04-12
