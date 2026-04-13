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

`make phase2` automatically runs `make validate-phase1` before installing anything — running it manually first gives explicit visibility into Phase 1 state before the scheduling stack is installed.

From Phase 1:
- ✅ Kind cluster with 4 nodes (1 control plane + 3 workers in 2 racks)
- ✅ GPU resources advertised
- ✅ Rack topology labels

New for Phase 2:
- NGC API credentials (see setup below) — required before running `make phase2`
- Qwen3-0.6B model pre-staged: `make download-model` (for Phase 3)

### NGC API Key Setup

The Dynamo operator image (`nvcr.io/nvidia/ai-dynamo/kubernetes-operator`) is hosted on NVIDIA's NGC registry. Get a key at [org.ngc.nvidia.com/setup/api-keys](https://org.ngc.nvidia.com/setup/api-keys) (free NVIDIA developer account required).

Two forms of authentication are required before running `make phase2`:
- **Docker login on host** — so `make phase2` can pull and load the operator image into Kind nodes
- **Kubernetes imagePullSecret** — so pods can pull NGC images at runtime (created automatically by `make phase2`)

> [!IMPORTANT]
> Docker login to `nvcr.io` must be completed before running `make phase2`. This is a manual step — `make phase2` will fail at the prepull stage if credentials are absent. Run `make check-ngc-login` to verify before proceeding.

Choose one credential path and complete **both** steps for it:

**Option A — environment variable:**
```bash
export NGC_API_KEY='<your-key>'
echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin
# make phase2 picks up NGC_API_KEY automatically for the imagePullSecret
```

**Option B — key file:**
```bash
mkdir -p ~/.ngc && echo '<your-key>' > ~/.ngc/apikey && chmod 600 ~/.ngc/apikey
cat ~/.ngc/apikey | docker login nvcr.io -u '$oauthtoken' --password-stdin
# make phase2 reads ~/.ngc/apikey automatically for the imagePullSecret
```

---

## Execution

### Automated (Recommended)

```bash
make phase2
```

**Time:** ~1.5-2 minutes

This runs all steps:
1. Pre-pull Dynamo operator image into kind nodes
2. Install KAI Scheduler (Helm)
3. Install Grove (Helm)
4. Install Dynamo platform (Helm from cloned source)
5. Create NGC imagePullSecret in `dynamo-system` and `dynamo-demo` namespaces (reads `NGC_API_KEY` or `~/.ngc/apikey`)
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
# These are nginx placeholder pods (not Dynamo workers) — names chosen to mirror
# the Phase 3 component roles. All should share the same grove.io/podgang label,
# confirming gang scheduling is working before real workloads are deployed.
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

Gang scheduling requires all pods in a group to be schedulable simultaneously. If the admission webhook rejects a pod or the scheduler can't satisfy all constraints, the entire gang waits. Start with the admission webhook, then the scheduler, then Grove:

```bash
kubectl logs -n kai-scheduler -l app.kubernetes.io/name=admission -f
kubectl logs -n kai-scheduler -l app.kubernetes.io/name=kai-scheduler -f
kubectl logs -n grove-system -l app.kubernetes.io/name=grove-operator -f
```

### Helm Errors

`install-dynamo-platform` downloads the Dynamo chart and its sub-chart dependencies (NATS, bitnami) at install time. Network issues or rate limiting can cause this step to fail. If it does, the dependencies can be pulled manually before retrying:

```bash
git clone --depth 1 --branch v1.0.1 \
  https://github.com/ai-dynamo/dynamo.git /tmp/dynamo-chart-src
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update
helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
helm dependency update /tmp/dynamo-chart-src/deploy/helm/charts/platform
```

For any issue not covered here, `make clean` followed by `make phase1 phase2` is the fastest recovery path.

---

## Next Steps

Proceed to Phase 3: [`docs/phase3-runbook.md`](phase3-runbook.md)

---

**Last Updated:** 2026-04-13
