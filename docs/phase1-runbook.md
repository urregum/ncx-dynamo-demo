# Phase 1 Runbook — Cluster Setup

## Overview

Phase 1 creates a Kind cluster (4 nodes) with GPU support and rack topology labels. This is the foundation for the scheduling stack and Dynamo workloads.

**Cluster Topology:**
- 1 control plane
- 3 workers: 2 in rack-01, 1 in rack-02
- All workers share one RTX 3070 Ti via NVIDIA container runtime

---

## Prerequisites

Run this first to validate your system:

```bash
make validate-prereqs
```

**Required:**
- Docker 28+
- Kind v0.31.0+
- kubectl v1.34+
- Helm v3.20+
- nvidia-container-toolkit 1.19+

**Note on GPU requirement:**
The current cluster template (`kind-config.yaml.tpl`) mounts `/dev/nvidia*` device files from the host at cluster creation time. A GPU must be present for `kind create cluster` to succeed, even though no mocker pod uses it. The mocker workload itself is GPU-free; a no-GPU cluster template is a planned improvement.

**Expected output:**
```
✓ All prerequisites installed
GPU 0: NVIDIA GeForce RTX 3070 Ti   # present if GPU detected; warning (not error) if absent
```

---

## Execution

### Automated (Recommended)

```bash
make phase1
```

This runs in sequence:
1. `make validate-prereqs` — Check system
2. `make cluster-up` — Create Kind cluster
3. `make fix-inotify-limits` — Prevent file-watcher crashes
4. `make apply-runtimeclass` — Deploy nvidia RuntimeClass
5. `make advertise-gpu-resources` — Advertise GPU capacity

**Time:** ~3-5 minutes (mostly waiting for nodes to boot)

### Manual Steps (for debugging)

```bash
# 1. Generate kind-config from template
make kind-config

# 2. Create cluster
kind create cluster --config=infra/kind-config.yaml --name=ncx-demo-cluster

# 3. Fix inotify (prevents "too many open files" crashes)
for node in ncx-demo-cluster-worker ncx-demo-cluster-worker2 ncx-demo-cluster-worker3; do
  docker exec $node sysctl -w fs.inotify.max_user_watches=524288
  docker exec $node sysctl -w fs.inotify.max_user_instances=8192
done

# 4. Apply NVIDIA RuntimeClass
kubectl apply -f manifests/nvidia-runtimeclass.yaml

# 5. Advertise GPU resources (patches fake nvidia.com/gpu capacity onto Kind nodes
#    so the Dynamo operator's GPU resource requirements are satisfied — no real GPU
#    is consumed by the mocker workload)
bash scripts/advertise-gpu-resources.sh
```

---

## Validation

### Automated

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

**GPU device mounts:**
```bash
for node in ncx-demo-cluster-worker ncx-demo-cluster-worker2 ncx-demo-cluster-worker3; do
  docker exec $node ls /dev/nvidia0 /dev/nvidia-uvm /dev/nvidiactl
done
# No "No such file or directory" errors
```

**NVIDIA RuntimeClass:**
```bash
kubectl get runtimeclass nvidia
# Should exist
```

---

## Troubleshooting

### Nodes Not Ready
```bash
kubectl describe node <node-name>
# Check Conditions section for errors
# Usually: CNI plugin starting up (wait 1-2 min) or insufficient memory
```

### GPU Resources Not Showing
```bash
bash scripts/advertise-gpu-resources.sh
# Re-run the resource advertising script
```

### "Too Many Open Files" Errors
```bash
# Re-run inotify fix
make fix-inotify-limits
```

---

## Next Steps

Once Phase 1 validation passes, proceed to Phase 2:

```bash
make phase2
```

This installs KAI Scheduler, Grove, and Dynamo platform.

---

**Runbook Version:** 1.0  
**Last Updated:** 2026-04-09
