# Phase 2 Runbook — Scheduling Stack

## Overview

Phase 2 installs the scheduling stack: KAI Scheduler, Grove operator, and Dynamo platform. A placeholder workload validates gang scheduling before Phase 3 brings in real Dynamo workers.

**What Gets Installed:**
- **KAI Scheduler v0.14.0** — Gang scheduling, queue management
- **Grove v0.1.0-alpha.7** — Converts PodCliqueSet → ganged deployments
- **Dynamo Platform v1.0.1** — Disaggregated inference operator + NATS
- **Placeholder workload** — Nginx pods demonstrating gang scheduling

---

## Prerequisites

From Phase 1:
- ✅ Kind cluster with 4 nodes (1 control plane + 3 workers in 2 racks)
- ✅ GPU resources advertised
- ✅ Rack topology labels

New for Phase 2:
- NGC API credentials configured via `docker login nvcr.io` (for pulling operator images)
- Qwen3-0.6B model pre-staged: `make download-model` (for Phase 3)

---

## Execution

### Automated (Recommended)

```bash
make phase2
```

**Time:** ~3-5 minutes

This runs all steps:
1. Pre-pull Dynamo operator image into kind nodes
2. Install KAI Scheduler (Helm)
3. Install Grove (Helm)
4. Install Dynamo platform (Helm from cloned source)
5. Create NGC imagePullSecret (for operator images)
6. Deploy placeholder PodCliqueSet workload

---

## Validation

### Automated

```bash
make validate-phase2
```

Expected output: **7/7 checks passing**

Validates:
- KAI Scheduler pods running
- KAI default queue created
- Grove operator running
- Grove CRDs installed
- Dynamo operator running
- Placeholder PodCliqueSet deployed
- All workload pods running (gang scheduling confirmed)

### Manual Checks

**KAI Scheduler:**
```bash
kubectl get pods -n kai-scheduler
# Should have kai-scheduler, admission, binder, queue-controller pods
```

**Grove:**
```bash
kubectl get pods -n grove-system
# Should have grove-operator
kubectl get crd | grep grove.io
# Should see podcliquesets, podcliques, podcliquesets
```

**Dynamo Platform:**
```bash
kubectl get pods -n dynamo-system
# Should have dynamo-operator and nats pods
```

**Placeholder Workload:**
```bash
kubectl get pods -n dynamo-demo -o wide
# Should show 3 pods: router, prefill, decode
# All should have same grove.io/podgang label (gang scheduling confirmed)
```

---

## What's Running

### Namespaces

| Namespace | Purpose |
|-----------|---------|
| `kai-scheduler` | Gang scheduling controller and admission webhooks |
| `grove-system` | PodCliqueSet operator |
| `dynamo-system` | Dynamo operator + NATS messaging |
| `dynamo-demo` | Workload namespace (placeholder + Phase 3 jobs) |

### Key CRDs

| CRD | Example | Purpose |
|-----|---------|---------|
| `DynamoGraphDeployment` (nvidia.com/v1alpha1) | `dynamo-bench` | User-facing: deploy disaggregated workload |
| `PodCliqueSet` (grove.io/v1alpha1) | `dynamo-demo` | Operator creates this from DGD |
| `PodGang` (scheduler.grove.io/v1alpha1) | `dynamo-demo-0` | Enforces all-or-nothing scheduling |

---

## Troubleshooting

### Pods Stuck in Pending

**Check admission webhook:**
```bash
kubectl logs -n kai-scheduler -l app.kubernetes.io/name=admission -f
```

**Check scheduler logs:**
```bash
kubectl logs -n kai-scheduler -l app.kubernetes.io/name=kai-scheduler -f
```

**Check Grove logs:**
```bash
kubectl logs -n grove-system -l app.kubernetes.io/name=grove-operator -f
```

### Helm Errors

If Helm install fails, manually pull Helm dependencies:

```bash
git clone --depth 1 --branch v1.0.1 \
  https://github.com/ai-dynamo/dynamo.git /tmp/dynamo-chart-src
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update
helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
helm dependency update /tmp/dynamo-chart-src/deploy/helm/charts/platform
```

---

## Next Steps

Once Phase 2 validation passes, proceed to Phase 3:

```bash
make download-model           # Pre-stage Qwen3-0.6B model (one-time)
make phase3                   # Deploy real Dynamo mocker workers
make phase3-same-rack         # Deploy same-rack scenario
make run-benchmark            # Run aiperf latency test
```

---

**Runbook Version:** 1.0  
**Last Updated:** 2026-04-09
