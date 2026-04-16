.PHONY: help cluster-up cluster-down cluster-status cluster-setup stack-install mocker-deploy clean validate-prereqs \
        download-mocker-image build-mocker-image validate-stack \
        cleanup-placeholder validate-mocker benchmark-same-rack benchmark-cross-rack \
        show-placement install-aiperf run-benchmark compare-results kind-config \
        fix-inotify-limits apply-runtimeclass advertise-gpu-resources validate-cluster \
        gpu-prepull gpu-deploy gpu-validate gpu-stream gpu-status gpu-benchmark \
        setup-gpu-node gpu-sdk-example install-openai

# ============================================================================
# NCX Dynamo Demo - Makefile
# ============================================================================
# This Makefile orchestrates the demo environment for NVIDIA Dynamo,
# focused on scheduling, coordination, and observability with GPU mockers.
#
# Core setup (run in order):
#   cluster-setup   — Kind cluster with rack topology + GPU scaffolding
#   stack-install   — KAI Scheduler, Grove, Dynamo operator via Helm
#
# Demo tracks (run after core setup, independently):
#   mocker-deploy       — Pull mocker image + deploy same-rack DGD
#   benchmark-same-rack — Configure same-rack placement (400 GB/s KV)
#   benchmark-cross-rack— Configure cross-rack placement (12.5 GB/s KV)
# ============================================================================

CLUSTER_NAME := ncx-demo-cluster
KIND_CONFIG := infra/kind-config.yaml

# Helm chart versions
KAI_VERSION     := v0.14.0
GROVE_VERSION   := v0.1.0-alpha.7
DYNAMO_VERSION  := v1.0.1

# Worker image (vLLM, cuda13 tag: 9.13 GB vs 14.93 GB SGLang; full KVBM support)
WORKER_IMAGE   := nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.0.1-cuda13
OPERATOR_IMAGE := nvcr.io/nvidia/ai-dynamo/kubernetes-operator:1.0.1
CURL_IMAGE     := curlimages/curl:8.11.1

# Model staging — MODELS_DIR is used when generating infra/kind-config.yaml
# Run: make kind-config   (generates infra/kind-config.yaml from template)
MODELS_DIR  := $(CURDIR)/models/hf-cache
QWEN_MODEL  := Qwen/Qwen3-0.6B

# Namespace layout
NS_KAI      := kai-scheduler
NS_GROVE    := grove-system
NS_DYNAMO   := dynamo-system
NS_WORKLOAD := dynamo-demo

help: ## Show this help message
	@echo "NCX Dynamo Demo - Available targets:"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Quick start:"
	@echo "  make validate-prereqs       # Check system requirements"
	@echo "  make cluster-setup          # Create cluster with rack topology"
	@echo "  make stack-install          # Install KAI, Grove, Dynamo operator"
	@echo "  make mocker-deploy          # Deploy mocker workers (benchmark track)"

# ============================================================================
# Prerequisites Validation
# ============================================================================

validate-prereqs: ## Validate system has required tools
	@echo "==> Validating prerequisites..."
	@command -v kind >/dev/null 2>&1 || { echo "ERROR: kind not found. Install from https://kind.sigs.k8s.io/"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }
	@command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found"; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }
	@echo "✓ All prerequisites installed"
	@echo ""
	@echo "==> Checking for NVIDIA GPU (not required for demo with mockers only)..."
	@if command -v nvidia-smi >/dev/null 2>&1; then \
		nvidia-smi -L | head -1; \
	else \
		echo "⚠ No NVIDIA GPU detected - will use software mockers only"; \
	fi

# ============================================================================
# Phase 1: Cluster Infrastructure
# ============================================================================

cluster-setup: validate-prereqs cluster-up fix-inotify-limits apply-runtimeclass advertise-gpu-resources ## Create Kind cluster with rack topology + GPU scaffolding
	@if [ -e /dev/nvidia0 ]; then \
		echo "==> GPU detected — running setup-gpu-node..."; \
		$(MAKE) setup-gpu-node; \
	fi
	@echo ""
	@echo "==> Cluster setup complete!"
	@echo "Cluster: $(CLUSTER_NAME)"
	@kubectl get nodes -L rack
	@echo ""
	@echo "Run 'make validate-cluster' to verify all checks pass."
	@echo "Next step: make stack-install"

kind-config: ## Generate infra/kind-config.yaml (auto-selects GPU or no-GPU cluster template)
	@if [ -e /dev/nvidia0 ]; then \
		TPL=infra/kind-config-gpu.yaml.tpl; \
		echo "==> GPU detected — using GPU cluster template"; \
	else \
		TPL=infra/kind-config-no-gpu.yaml.tpl; \
		echo "==> No GPU detected — using no-GPU cluster template (mocker-only)"; \
	fi; \
	REPO_ROOT="$(CURDIR)" envsubst < $$TPL > infra/kind-config.yaml
	@echo "✓ infra/kind-config.yaml written"

cluster-up: kind-config ## Create kind cluster with rack topology
	@mkdir -p $(MODELS_DIR)
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER_NAME)$$"; then \
		echo "==> Cluster $(CLUSTER_NAME) already exists"; \
	else \
		echo "==> Creating kind cluster: $(CLUSTER_NAME)..."; \
		kind create cluster --config=$(KIND_CONFIG) --name=$(CLUSTER_NAME); \
		echo "✓ Cluster created"; \
	fi
	@kubectl cluster-info --context kind-$(CLUSTER_NAME)

fix-inotify-limits: ## Fix inotify limits in all worker nodes (prevents file-watcher crashes)
	@echo "==> Fixing inotify limits on all worker nodes..."
	@for node in $(CLUSTER_NAME)-worker $(CLUSTER_NAME)-worker2 $(CLUSTER_NAME)-worker3 $(CLUSTER_NAME)-worker4; do \
		echo "  Fixing $$node"; \
		docker exec $$node sysctl -w fs.inotify.max_user_watches=524288; \
		docker exec $$node sysctl -w fs.inotify.max_user_instances=8192; \
		docker exec $$node sysctl -w fs.file-max=131072; \
	done
	@echo "✓ inotify limits fixed"

apply-runtimeclass: ## Apply NVIDIA RuntimeClass for GPU pods
	@echo "==> Applying NVIDIA RuntimeClass..."
	@kubectl apply -f manifests/nvidia-runtimeclass.yaml
	@echo "✓ RuntimeClass applied"

advertise-gpu-resources: ## Advertise nvidia.com/gpu resources on all worker nodes
	@echo "==> Advertising GPU resources via kubectl API patch..."
	@bash scripts/advertise-gpu-resources.sh
	@echo "✓ GPU resources advertised"

setup-gpu-node: ## Copy versioned NVIDIA CDI libraries into the GPU Kind node (run once after cluster-setup)
	@echo "==> Resolving versioned NVIDIA library paths on host..."
	@LIBCUDA=$$(readlink -f /usr/lib/x86_64-linux-gnu/libcuda.so.1 2>/dev/null); \
	LIBNVML=$$(readlink -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>/dev/null); \
	if [ -z "$$LIBCUDA" ] || [ ! -f "$$LIBCUDA" ]; then echo "ERROR: cannot resolve libcuda.so.1 — is the NVIDIA driver installed?"; exit 1; fi; \
	if [ -z "$$LIBNVML" ] || [ ! -f "$$LIBNVML" ]; then echo "ERROR: cannot resolve libnvidia-ml.so.1 — is the NVIDIA driver installed?"; exit 1; fi; \
	echo "  libcuda:  $$LIBCUDA"; \
	echo "  libnvml:  $$LIBNVML"; \
	echo "==> Copying into $(CLUSTER_NAME)-worker4..."; \
	docker cp $$LIBCUDA $(CLUSTER_NAME)-worker4:/usr/lib/x86_64-linux-gnu/; \
	docker cp $$LIBNVML $(CLUSTER_NAME)-worker4:/usr/lib/x86_64-linux-gnu/; \
	echo "✓ CDI library chain ready in $(CLUSTER_NAME)-worker4"

cluster-down: ## Delete the kind cluster
	@echo "==> Deleting cluster: $(CLUSTER_NAME)..."
	@kind delete cluster --name=$(CLUSTER_NAME)
	@echo "✓ Cluster deleted"

cluster-status: ## Show cluster status
	@echo "==> Cluster Status"
	@kubectl get nodes -o wide
	@echo ""
	@echo "==> Rack Topology"
	@kubectl get nodes -L rack
	@echo ""
	@echo "==> Pods by Namespace"
	@kubectl get pods -A

# ============================================================================
# Phase 2: Schedulers + Dynamo + GPU Mockers
# ============================================================================

check-ngc-login: ## Verify nvcr.io docker login credentials are present
	@if ! grep -q "nvcr.io" $${DOCKER_CONFIG:-$$HOME/.docker}/config.json 2>/dev/null; then \
		echo "ERROR: Not logged into nvcr.io."; \
		echo "  Run one of:"; \
		echo "    echo \"\$$NGC_API_KEY\" | docker login nvcr.io -u '\$$oauthtoken' --password-stdin"; \
		echo "    cat ~/.ngc/apikey    | docker login nvcr.io -u '\$$oauthtoken' --password-stdin"; \
		exit 1; \
	fi
	@echo "✓ nvcr.io credentials present"

stack-install: validate-cluster check-ngc-login prepull-operator install-schedulers install-dynamo-platform deploy-workload ## Install KAI Scheduler, Grove, and Dynamo operator via Helm
	@echo ""
	@echo "==> Stack installation complete!"
	@echo ""
	@echo "Installed Helm releases:"
	@helm list -A
	@echo ""
	@echo "Run 'make validate-stack' to verify all checks pass."
	@echo ""
	@echo "Demo tracks (independent — run either or both):"
	@echo ""
	@echo "  Track 1: Mocker benchmark (no GPU required)"
	@echo "    make download-mocker-image  # pre-pull mocker image (~500 MB, one-time)"
	@echo "    make install-aiperf         # install aiperf benchmark tool into .venv"
	@echo "    make mocker-deploy          # deploy mocker DGD and run benchmark"
	@echo ""
	@if [ -e /dev/nvidia0 ]; then \
		echo "  Track 2: GPU inference (NVIDIA GPU detected)"; \
		echo "    make download-model         # cache Qwen3-0.6B locally (~1.5 GB, one-time)"; \
		echo "    make gpu-prepull            # load vLLM runtime image into kind nodes (~9 GB)"; \
		echo "    make gpu-deploy             # deploy disaggregated vLLM inference DGD"; \
	else \
		echo "  Track 2: GPU inference (requires NVIDIA GPU — not detected on this system)"; \
		echo "    See docs/gpu-inference-runbook.md for hardware requirements"; \
	fi
	@echo ""

validate-cluster: ## Validate cluster is ready (nodes, racks, GPU resources)
	@./scripts/validate-cluster.sh

prepull-operator: ## Pull Dynamo operator image into kind nodes (67 MB, fast)
	@echo "==> Pulling Dynamo operator image on host..."
	@docker pull $(OPERATOR_IMAGE)
	@echo "==> Loading operator image into kind nodes..."
	@for node in $(CLUSTER_NAME)-control-plane $(CLUSTER_NAME)-worker $(CLUSTER_NAME)-worker2 $(CLUSTER_NAME)-worker3 $(CLUSTER_NAME)-worker4; do \
		echo "  Loading into $$node"; \
		docker save $(OPERATOR_IMAGE) | docker exec -i $$node ctr images import -; \
	done
	@echo "✓ Operator image pre-loaded into all nodes"

install-schedulers: ## Install KAI scheduler (v$(KAI_VERSION)) and Grove (v$(GROVE_VERSION))
	@echo "==> Installing KAI Scheduler $(KAI_VERSION)..."
	@helm upgrade -i kai-scheduler \
		oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
		-n $(NS_KAI) --create-namespace \
		--version $(KAI_VERSION) \
		--set admission.gpuPodRuntimeClassName="" \
		--wait --timeout 5m
	@echo "==> Restarting KAI Scheduler to ensure fresh credentials after install..."
	@kubectl rollout restart deployment/kai-scheduler-default -n $(NS_KAI)
	@kubectl rollout status deployment/kai-scheduler-default -n $(NS_KAI) --timeout=60s
	@echo "==> Creating KAI default queues..."
	@for i in 1 2 3 4 5; do \
	    kubectl apply -f infra/kai-default-queues.yaml && break; \
	    echo "  Webhook not ready yet, retrying in 10s (attempt $$i/5)..."; \
	    sleep 10; \
	done
	@echo "✓ KAI Scheduler installed"
	@echo ""
	@echo "==> Installing Grove $(GROVE_VERSION)..."
	@helm upgrade -i grove \
		oci://ghcr.io/ai-dynamo/grove/grove-charts \
		--version $(GROVE_VERSION) \
		-n $(NS_GROVE) --create-namespace \
		--wait --timeout 5m
	@echo "✓ Grove installed"

install-dynamo-platform: ## Install Dynamo platform operator from source
	@echo "==> Cloning Dynamo $(DYNAMO_VERSION) chart source..."
	@rm -rf /tmp/dynamo-chart-src
	@git clone --depth 1 --branch $(DYNAMO_VERSION) \
		https://github.com/ai-dynamo/dynamo.git /tmp/dynamo-chart-src 2>&1 | tail -3
	@echo "==> Adding Helm chart dependencies..."
	@helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update >/dev/null
	@helm repo add bitnami https://charts.bitnami.com/bitnami --force-update >/dev/null
	@helm repo update >/dev/null
	@helm dependency update /tmp/dynamo-chart-src/deploy/helm/charts/platform >/dev/null
	@echo "==> Installing dynamo-platform (operator + NATS)..."
	@kubectl create namespace $(NS_DYNAMO) --dry-run=client -o yaml | kubectl apply -f -
	@bash scripts/setup-ngc-secret.sh $(NS_DYNAMO)
	@helm upgrade -i dynamo-platform \
		/tmp/dynamo-chart-src/deploy/helm/charts/platform \
		-n $(NS_DYNAMO) \
		--set global.kai-scheduler.enabled=true \
		--set global.grove.enabled=true \
		--set global.etcd.install=false \
		--set dynamo-operator.discoveryBackend=kubernetes \
		--wait --timeout 10m
	@echo "✓ Dynamo platform operator installed"

deploy-workload: ## Deploy placeholder DynamoInferenceService workload (nginx, validates scheduling)
	@echo "==> Creating workload namespace and secrets..."
	@kubectl create namespace $(NS_WORKLOAD) --dry-run=client -o yaml | kubectl apply -f -
	@bash scripts/setup-ngc-secret.sh $(NS_WORKLOAD)
	@echo "==> Deploying placeholder workload..."
	@kubectl apply -f manifests/dynamo-namespace.yaml
	@kubectl apply -f manifests/dynamo-placeholder-workload.yaml
	@echo "==> Waiting for gang scheduling (up to 2 minutes)..."
	@for i in $$(seq 1 40); do \
		READY=$$(kubectl get pods -n $(NS_WORKLOAD) -l app.kubernetes.io/part-of=dynamo-demo --no-headers 2>/dev/null | awk '$$2~/^[0-9]+\/[0-9]+$$/{split($$2,a,"/"); if(a[1]==a[2] && a[1]>0) c++} END{print c+0}'); \
		if [ "$$READY" -ge 3 ]; then \
			echo "✓ Workload gang-scheduled ($$READY pods Ready)"; \
			break; \
		fi; \
		if [ "$$i" -eq 40 ]; then \
			echo "⚠ Pods not ready after 80s — check: kubectl get pods -n $(NS_WORKLOAD)"; \
			exit 1; \
		fi; \
		printf "  Pods Ready: $$READY/3 (attempt $$i/40)\\r"; \
		sleep 2; \
	done

# ============================================================================
# Phase 3: Mocker Workers + AIPerf Benchmarking
# ============================================================================

# Mocker image coordinates
MOCKER_IMAGE  := ghcr.io/urregum/ncx-dynamo-demo/dynamo-mocker:1.0.1
AIPERF_IMAGE  := nvcr.io/nvidia/ai-dynamo/aiperf:0.7.0

mocker-deploy: validate-stack download-mocker-image cleanup-placeholder benchmark-same-rack ## Pull mocker image, remove placeholder, deploy same-rack DGD
	@echo ""
	@echo "==> Mocker deployed — Dynamo disaggregated inference running (same-rack)."
	@echo ""
	@kubectl get pods -n $(NS_WORKLOAD) -l app.kubernetes.io/name=dynamo-bench
	@echo ""
	@echo "Demo flow:"
	@echo "  make show-placement             # Show prefill/decode node placement"
	@echo "  make run-benchmark              # Benchmark same-rack latency (save to results/same-rack.json)"
	@echo "  make benchmark-cross-rack       # Redeploy workload cross-rack"
	@echo "  make run-benchmark              # Benchmark cross-rack latency"
	@echo "  make compare-results            # Side-by-side latency table"

validate-stack: ## Validate scheduling stack is ready (KAI, Grove, Dynamo, placeholder)
	@./scripts/validate-stack.sh

validate-mocker: ## Validate mocker stack is healthy (DGD, pods, inference, disaggregation)
	@./scripts/validate-mocker.sh

cleanup-placeholder: ## Remove stack validation placeholder workload (nginx PodCliqueSet)
	@echo "==> Removing Phase 2 placeholder workload..."
	@kubectl delete podcliqueset dynamo-demo -n $(NS_WORKLOAD) --ignore-not-found
	@echo "✓ Placeholder removed"

# ----------------------------------------------------------------------------
# Mocker image management
# ----------------------------------------------------------------------------

download-mocker-image: ## Pull mocker image from ghcr.io and load into all kind nodes (default)
	@echo "==> Pulling mocker image: $(MOCKER_IMAGE)"
	@docker pull $(MOCKER_IMAGE)
	@echo "==> Loading mocker image into kind nodes..."
	@for node in $(CLUSTER_NAME)-control-plane $(CLUSTER_NAME)-worker $(CLUSTER_NAME)-worker2 $(CLUSTER_NAME)-worker3; do \
		echo "  Loading into $$node"; \
		docker save $(MOCKER_IMAGE) | docker exec -i $$node ctr images import -; \
	done
	@echo "✓ Mocker image loaded into all nodes"

build-mocker-image: ## Build mocker image locally from Dockerfile (fallback / development)
	@echo "==> Building mocker image from container/Dockerfile.mocker..."
	@docker build -f container/Dockerfile.mocker -t $(MOCKER_IMAGE) .
	@echo "==> Loading locally-built image into kind nodes..."
	@for node in $(CLUSTER_NAME)-control-plane $(CLUSTER_NAME)-worker $(CLUSTER_NAME)-worker2 $(CLUSTER_NAME)-worker3; do \
		echo "  Loading into $$node"; \
		docker save $(MOCKER_IMAGE) | docker exec -i $$node ctr images import -; \
	done
	@echo "✓ Mocker image built and loaded into all nodes"

# ============================================================================
# Demo Scenarios
# ============================================================================

demo-latency-comparison: benchmark-same-rack run-benchmark benchmark-cross-rack run-benchmark compare-results ## Demo: Full same-rack vs cross-rack latency comparison

demo-observability: ## Demo: Show cluster observability
	@echo "==> Demo: Cluster Observability"
	@kubectl get nodes -L rack
	@echo ""
	@helm list -A

# ----------------------------------------------------------------------------
# Phase 3 scenario transitions
# ----------------------------------------------------------------------------

FRONTEND_SVC := dynamo-bench-frontend
RESULTS_DIR  := $(CURDIR)/results

benchmark-same-rack: ## Deploy same-rack DGD (prefill+decode both on rack-01, 400 GB/s KV)
	@echo "==> Deploying same-rack scenario..."
	@kubectl delete dynamographdeployment dynamo-bench -n $(NS_WORKLOAD) --ignore-not-found
	@kubectl apply -f manifests/dynamo-mock-workers-same-rack.yaml
	@echo "==> Waiting for exactly 3 dynamo-bench pods Ready (up to 3 minutes)..."
	@for i in $$(seq 1 60); do \
		READY=$$(kubectl get pods -n $(NS_WORKLOAD) -l app.kubernetes.io/part-of=dynamo-bench --no-headers 2>/dev/null | awk '$$2~/^[0-9]+\/[0-9]+$$/{split($$2,a,"/"); if(a[1]==a[2] && a[1]>0) c++} END{print c+0}'); \
		if [ "$$READY" -eq 3 ]; then \
			echo "✓ dynamo-bench pods Ready (3/3)"; \
			break; \
		fi; \
		if [ "$$i" -eq 60 ]; then \
			echo "⚠ Pods not ready after 3 minutes ($$READY/3 Ready) — check: kubectl get pods -n $(NS_WORKLOAD)"; \
			exit 1; \
		fi; \
		printf "  Pods Ready: $$READY/3 (attempt $$i/60)\\r"; \
		sleep 3; \
	done
	@echo ""
	@echo "✓ Same-rack scenario active"
	@$(MAKE) show-placement

benchmark-cross-rack: ## Redeploy DGD cross-rack (prefill rack-01, decode rack-02, 12.5 GB/s KV)
	@echo "==> Switching to cross-rack scenario..."
	@kubectl delete dynamographdeployment dynamo-bench -n $(NS_WORKLOAD) --ignore-not-found
	@kubectl apply -f manifests/dynamo-mock-workers-cross-rack.yaml
	@echo "==> Waiting for exactly 3 dynamo-bench pods Ready (old pods terminate, new ones start, up to 3 minutes)..."
	@for i in $$(seq 1 60); do \
		READY=$$(kubectl get pods -n $(NS_WORKLOAD) -l app.kubernetes.io/part-of=dynamo-bench --no-headers 2>/dev/null | awk '$$2~/^[0-9]+\/[0-9]+$$/{split($$2,a,"/"); if(a[1]==a[2] && a[1]>0) c++} END{print c+0}'); \
		if [ "$$READY" -eq 3 ]; then \
			echo "✓ dynamo-bench pods Ready (3/3)"; \
			break; \
		fi; \
		if [ "$$i" -eq 60 ]; then \
			echo "⚠ Pods not ready after 3 minutes ($$READY/3 Ready) — check: kubectl get pods -n $(NS_WORKLOAD)"; \
			exit 1; \
		fi; \
		printf "  Pods Ready: $$READY/3 (attempt $$i/60)\\r"; \
		sleep 3; \
	done
	@echo ""
	@echo "✓ Cross-rack scenario active"
	@$(MAKE) show-placement

show-placement: ## Show which rack each dynamo-bench pod landed on
	@echo "==> Node rack topology:"
	@kubectl get nodes -L rack --no-headers | awk '{printf "  %-40s rack=%s\n", $$1, $$NF}'
	@echo ""
	@echo "==> dynamo-bench pod placement:"
	@kubectl get pods -n $(NS_WORKLOAD) \
		-l app.kubernetes.io/part-of=dynamo-bench \
		-o custom-columns="POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase" \
		--no-headers | while read pod node status; do \
		  rack=$$(kubectl get node $$node -L rack --no-headers 2>/dev/null | awk '{print $$NF}'); \
		  printf "  %-50s -> node=%-35s rack=%s\n" "$$pod" "$$node" "$$rack"; \
		done

# Mocker benchmark: ISL=4096 stresses KV transfer bandwidth gap between rack topologies.
BENCHMARK_ISL    := 4096
BENCHMARK_OSL    := 32
BENCHMARK_CONC   := 4
BENCHMARK_REQS   := 20
BENCHMARK_MODEL  := Qwen/Qwen3-0.6B

# GPU benchmark: ISL=128 fits within max-model-len=2048 (8 GiB VRAM constraint at gmu=0.25).
# Measures real compute TTFT on the RTX 3070 Ti; not directly comparable to mocker results.
GPU_BENCHMARK_ISL   := 128
GPU_BENCHMARK_OSL   := 32
GPU_BENCHMARK_CONC  := 4
GPU_BENCHMARK_REQS  := 20

install-aiperf: ## Install aiperf into .venv (creates .venv if absent)
	@echo "==> Installing aiperf into .venv..."
	@if [ ! -x "$(CURDIR)/.venv/bin/pip" ]; then \
		echo "  .venv not found — creating..."; \
		python3 -m venv $(CURDIR)/.venv; \
	fi
	@$(CURDIR)/.venv/bin/pip install --quiet huggingface_hub hf_transfer aiperf
	@echo "✓ aiperf installed in .venv"

run-benchmark: ## Benchmark active DGD via port-forward; saves JSON to results/<scenario>.json
	@echo "==> Running aiperf benchmark (ISL=$(BENCHMARK_ISL), OSL=$(BENCHMARK_OSL), concurrency=$(BENCHMARK_CONC))..."
	@VENV_AIPERF=$(CURDIR)/.venv/bin/aiperf; \
	if [ ! -x "$$VENV_AIPERF" ]; then \
		echo "ERROR: aiperf not found in .venv. Run: make install-aiperf"; \
		exit 1; \
	fi; \
	mkdir -p $(RESULTS_DIR); \
	SCENARIO=$$(kubectl get dynamographdeployment dynamo-bench -n $(NS_WORKLOAD) \
		-o jsonpath='{.metadata.labels.demo/scenario}' 2>/dev/null); \
	if [ -z "$$SCENARIO" ]; then \
		echo "ERROR: dynamo-bench DGD not found in namespace $(NS_WORKLOAD)"; exit 1; \
	fi; \
	echo "  Scenario: $$SCENARIO → $(RESULTS_DIR)/$$SCENARIO.json"; \
	echo "==> Port-forwarding frontend service to localhost:8000..."; \
	if [ -f /tmp/pf-dynamo-bench.pid ]; then kill $$(cat /tmp/pf-dynamo-bench.pid) 2>/dev/null || true; rm -f /tmp/pf-dynamo-bench.pid; fi; \
	STALE_PF=$$(lsof -ti tcp:8000 2>/dev/null || true); \
	if [ -n "$$STALE_PF" ]; then kill $$STALE_PF 2>/dev/null || true; sleep 1; fi; \
	kubectl port-forward svc/dynamo-bench-frontend -n $(NS_WORKLOAD) 8000:8000 >/tmp/pf.log 2>&1 & \
	PF_PID=$$!; \
	echo $$PF_PID > /tmp/pf-dynamo-bench.pid; \
	sleep 3; \
	echo "==> Running benchmark..."; \
	$$VENV_AIPERF profile $(BENCHMARK_MODEL) \
		--url http://localhost:8000 \
		--isl $(BENCHMARK_ISL) \
		--osl $(BENCHMARK_OSL) \
		--concurrency $(BENCHMARK_CONC) \
		--num-requests $(BENCHMARK_REQS) \
		--artifact-dir $(RESULTS_DIR) \
		--profile-export-prefix $$SCENARIO; \
	BENCH_EXIT=$$?; \
	kill $$PF_PID 2>/dev/null; wait $$PF_PID 2>/dev/null; rm -f /tmp/pf-dynamo-bench.pid; true; \
	if [ $$BENCH_EXIT -ne 0 ]; then \
		echo "ERROR: aiperf failed (exit $$BENCH_EXIT)"; exit $$BENCH_EXIT; \
	fi; \
	echo "✓ Benchmark complete → $(RESULTS_DIR)/$$SCENARIO.json"

compare-results: ## Print side-by-side latency table from results/ (same-rack vs cross-rack)
	@echo ""
	@echo "================================================================"
	@echo " Latency Comparison: Same-rack vs Cross-rack"
	@echo " (KV bandwidth: 400 GB/s vs 12.5 GB/s, ISL=$(BENCHMARK_ISL) tokens)"
	@echo "================================================================"
	@printf " %-16s %14s %14s %16s\n" "Scenario" "Latency p50" "Latency p99" "Throughput"
	@printf " %-16s %14s %14s %16s\n" "" "(ms)" "(ms)" "(req/s)"
	@echo "----------------------------------------------------------------"
	@$(CURDIR)/.venv/bin/python3 $(CURDIR)/scripts/compare-results.py $(RESULTS_DIR)
	@echo "================================================================"
	@echo ""

# ============================================================================
# Phase 4: GPU Real Inference (vLLM disaggregated, rack-gpu node)
# ============================================================================
#
# Prerequisites (additive to stack-install):
#   make gpu-prepull        — one-time, slow (~9 GB image load into kind nodes)
#   make download-model     — already done for mocker track
#
# GPU inference workflow:
#   make gpu-prepull        # One-time: load vllm-runtime into kind nodes
#   make gpu-deploy         # Deploy disaggregated DGD (Frontend + prefill + decode)
#   make gpu-validate       # Smoke test: /health + one inference request
#   make gpu-stream         # Streaming response (shows real token arrival)
#   make gpu-status         # Model listing + KAI gang state
#   make gpu-benchmark      # AIPerf benchmark against GPU frontend → results/gpu-real.json
#                         (GPU results are compute-driven; use compare-results only
#                          if mocker benchmarks have also been run and you want the
#                          placement latency comparison separately)
#
GPU_FRONTEND_SVC := dynamo-gpu-frontend
GPU_FRONTEND_PORT := 9000

gpu-prepull: check-ngc-login ## Pull vllm-runtime (~9 GB) and curl init-container images into all kind nodes
	@echo "==> Pulling vLLM runtime image on host: $(WORKER_IMAGE)"
	@docker pull $(WORKER_IMAGE)
	@echo "==> Pulling curl init-container image on host: $(CURL_IMAGE)"
	@docker pull $(CURL_IMAGE)
	@echo "==> Loading images into kind nodes (this takes a few minutes)..."
	@for node in $(CLUSTER_NAME)-control-plane $(CLUSTER_NAME)-worker $(CLUSTER_NAME)-worker2 $(CLUSTER_NAME)-worker3 $(CLUSTER_NAME)-worker4; do \
		echo "  Loading vllm-runtime into $$node"; \
		docker save $(WORKER_IMAGE) | docker exec -i $$node ctr -n k8s.io images import -; \
		echo "  Loading curl into $$node"; \
		docker save $(CURL_IMAGE) | docker exec -i $$node ctr -n k8s.io images import -; \
	done
	@echo "✓ vllm-runtime and curl pre-loaded into all nodes"

gpu-deploy: ## Deploy GPU inference DGD (Frontend + disaggregated prefill + decode)
	@echo "==> Deploying GPU inference DGD (dynamo-gpu)..."
	@kubectl apply -f manifests/dynamo-vllm-gpu.yaml
	@echo "==> Waiting for 3 dynamo-gpu pods Ready (vLLM profiling pass ~5 min; allow up to 10 minutes)..."
	@for i in $$(seq 1 120); do \
		READY=$$(kubectl get pods -n $(NS_WORKLOAD) -l app.kubernetes.io/part-of=dynamo-gpu --no-headers 2>/dev/null | awk '$$2~/^[0-9]+\/[0-9]+$$/{split($$2,a,"/"); if(a[1]==a[2] && a[1]>0) c++} END{print c+0}'); \
		if [ "$$READY" -eq 3 ]; then \
			echo "✓ dynamo-gpu pods Ready (3/3)"; \
			break; \
		fi; \
		if [ "$$i" -eq 120 ]; then \
			echo "⚠ Pods not ready after 10 minutes ($$READY/3 Ready) — check: kubectl get pods -n $(NS_WORKLOAD)"; \
			exit 1; \
		fi; \
		printf "  Pods Ready: $$READY/3 (attempt $$i/120)\\r"; \
		sleep 5; \
	done
	@echo ""
	@echo "==> Pod placement:"
	@kubectl get pods -n $(NS_WORKLOAD) -l app.kubernetes.io/name=dynamo-gpu \
		-o custom-columns="POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase" \
		--no-headers | while read pod node status; do \
		  rack=$$(kubectl get node $$node -L rack --no-headers 2>/dev/null | awk '{print $$NF}'); \
		  printf "  %-50s -> node=%-35s rack=%s\n" "$$pod" "$$node" "$$rack"; \
		done
	@echo ""
	@echo "Run 'make gpu-validate' to smoke test the deployment."

gpu-validate: ## Smoke test GPU inference: /health check + one inference request
	@echo "==> Port-forwarding GPU frontend to localhost:$(GPU_FRONTEND_PORT)..."
	@if [ -f /tmp/pf-dynamo-gpu.pid ]; then kill $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null || true; rm -f /tmp/pf-dynamo-gpu.pid; fi
	@STALE=$$(lsof -ti tcp:$(GPU_FRONTEND_PORT) 2>/dev/null || true); \
	if [ -n "$$STALE" ]; then kill $$STALE 2>/dev/null || true; sleep 1; fi
	@kubectl port-forward svc/$(GPU_FRONTEND_SVC) -n $(NS_WORKLOAD) $(GPU_FRONTEND_PORT):8000 >/tmp/pf-gpu.log 2>&1 & \
	echo $$! > /tmp/pf-dynamo-gpu.pid
	@sleep 3
	@echo "==> Health check..."
	@curl -sf http://localhost:$(GPU_FRONTEND_PORT)/health -o /dev/null && echo " ✓ /health OK" || { echo "✗ /health failed"; kill $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null; exit 1; }
	@echo "==> Inference request (What is 2+2?)..."
	@curl -s http://localhost:$(GPU_FRONTEND_PORT)/v1/chat/completions \
		-H "Content-Type: application/json" \
		-d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"What is 2+2?"}],"max_tokens":64,"chat_template_kwargs":{"enable_thinking":false}}' \
		| python3 -c "import sys,json; d=json.load(sys.stdin); print(' Response:', d['choices'][0]['message']['content'])" \
		2>/dev/null || { echo "✗ Inference request failed (see /tmp/pf-gpu.log)"; kill $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null; exit 1; }
	@kill $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null; rm -f /tmp/pf-dynamo-gpu.pid; true
	@echo "✓ GPU inference validation passed"

gpu-stream: ## Streaming inference request — shows real token arrival timing
	@echo "==> Port-forwarding GPU frontend to localhost:$(GPU_FRONTEND_PORT)..."
	@if [ -f /tmp/pf-dynamo-gpu.pid ]; then kill $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null || true; rm -f /tmp/pf-dynamo-gpu.pid; fi
	@STALE=$$(lsof -ti tcp:$(GPU_FRONTEND_PORT) 2>/dev/null || true); \
	if [ -n "$$STALE" ]; then kill $$STALE 2>/dev/null || true; sleep 1; fi
	@kubectl port-forward svc/$(GPU_FRONTEND_SVC) -n $(NS_WORKLOAD) $(GPU_FRONTEND_PORT):8000 >/tmp/pf-gpu.log 2>&1 & \
	echo $$! > /tmp/pf-dynamo-gpu.pid
	@sleep 3
	@echo "==> Streaming response (Ctrl-C to stop):"
	@curl -s -N http://localhost:$(GPU_FRONTEND_PORT)/v1/chat/completions \
		-H "Content-Type: application/json" \
		-d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Explain KV cache in one sentence."}],"max_tokens":64,"stream":true,"chat_template_kwargs":{"enable_thinking":false}}'; \
	echo ""
	@kill $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null; rm -f /tmp/pf-dynamo-gpu.pid; true

gpu-benchmark: ## AIPerf benchmark against GPU frontend; saves results/gpu-real.json
	@echo "==> Running aiperf benchmark against GPU inference frontend..."
	@VENV_AIPERF=$(CURDIR)/.venv/bin/aiperf; \
	if [ ! -x "$$VENV_AIPERF" ]; then \
		echo "ERROR: aiperf not found in .venv. Run: make install-aiperf"; \
		exit 1; \
	fi; \
	mkdir -p $(RESULTS_DIR); \
	if [ -f /tmp/pf-dynamo-gpu.pid ]; then kill $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null || true; rm -f /tmp/pf-dynamo-gpu.pid; fi; \
	STALE=$$(lsof -ti tcp:$(GPU_FRONTEND_PORT) 2>/dev/null || true); \
	if [ -n "$$STALE" ]; then kill $$STALE 2>/dev/null || true; sleep 1; fi; \
	kubectl port-forward svc/$(GPU_FRONTEND_SVC) -n $(NS_WORKLOAD) $(GPU_FRONTEND_PORT):8000 >/tmp/pf-gpu.log 2>&1 & \
	echo $$! > /tmp/pf-dynamo-gpu.pid; \
	sleep 3; \
	echo "==> Running benchmark (ISL=$(GPU_BENCHMARK_ISL), OSL=$(GPU_BENCHMARK_OSL), concurrency=$(GPU_BENCHMARK_CONC))..."; \
	$$VENV_AIPERF profile $(BENCHMARK_MODEL) \
		--url http://localhost:$(GPU_FRONTEND_PORT) \
		--isl $(GPU_BENCHMARK_ISL) \
		--osl $(GPU_BENCHMARK_OSL) \
		--concurrency $(GPU_BENCHMARK_CONC) \
		--num-requests $(GPU_BENCHMARK_REQS) \
		--artifact-dir $(RESULTS_DIR) \
		--profile-export-prefix gpu-real; \
	BENCH_EXIT=$$?; \
	kill $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null; wait $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null; rm -f /tmp/pf-dynamo-gpu.pid; true; \
	if [ $$BENCH_EXIT -ne 0 ]; then \
		echo "ERROR: aiperf failed (exit $$BENCH_EXIT)"; exit $$BENCH_EXIT; \
	fi; \
	echo "✓ GPU benchmark complete → $(RESULTS_DIR)/gpu-real.json"

gpu-status: ## Show model registration + KAI gang scheduling state for GPU DGD
	@echo "==> Port-forwarding GPU frontend to localhost:$(GPU_FRONTEND_PORT)..."
	@if [ -f /tmp/pf-dynamo-gpu.pid ]; then kill $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null || true; rm -f /tmp/pf-dynamo-gpu.pid; fi
	@STALE=$$(lsof -ti tcp:$(GPU_FRONTEND_PORT) 2>/dev/null || true); \
	if [ -n "$$STALE" ]; then kill $$STALE 2>/dev/null || true; sleep 1; fi
	@kubectl port-forward svc/$(GPU_FRONTEND_SVC) -n $(NS_WORKLOAD) $(GPU_FRONTEND_PORT):8000 >/tmp/pf-gpu.log 2>&1 & \
	echo $$! > /tmp/pf-dynamo-gpu.pid
	@sleep 3
	@echo "==> Registered models:"
	@curl -s http://localhost:$(GPU_FRONTEND_PORT)/v1/models | python3 -m json.tool 2>/dev/null || echo "  (not available)"
	@kill $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null; rm -f /tmp/pf-dynamo-gpu.pid; true
	@echo ""
	@echo "==> KAI PodGang state:"
	@kubectl get podgang -A 2>/dev/null || echo "  (no podgangs found)"
	@echo ""
	@echo "==> KAI queue state:"
	@kubectl get queue -n $(NS_WORKLOAD) 2>/dev/null || echo "  (no queues found)"
	@echo ""
	@echo "==> dynamo-gpu pod placement:"
	@kubectl get pods -n $(NS_WORKLOAD) -l app.kubernetes.io/name=dynamo-gpu \
		-o custom-columns="POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase" \
		--no-headers 2>/dev/null | while read pod node status; do \
		  rack=$$(kubectl get node $$node -L rack --no-headers 2>/dev/null | awk '{print $$NF}'); \
		  printf "  %-50s -> node=%-35s rack=%s\n" "$$pod" "$$node" "$$rack"; \
		done

gpu-sdk-example: ## Run OpenAI SDK chat completion example against GPU frontend
	@echo "==> Checking openai package..."
	@if ! $(CURDIR)/.venv/bin/python3 -c "import openai" 2>/dev/null; then \
		echo "  openai not found — installing into .venv..."; \
		if [ ! -x "$(CURDIR)/.venv/bin/pip" ]; then \
			echo "  .venv not found — creating..."; \
			python3 -m venv $(CURDIR)/.venv; \
		fi; \
		$(CURDIR)/.venv/bin/pip install --quiet openai; \
		echo "  ✓ openai installed"; \
	else \
		echo "  ✓ openai already available"; \
	fi
	@echo "==> Port-forwarding GPU frontend to localhost:$(GPU_FRONTEND_PORT)..."
	@if [ -f /tmp/pf-dynamo-gpu.pid ]; then kill $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null || true; rm -f /tmp/pf-dynamo-gpu.pid; fi
	@STALE=$$(lsof -ti tcp:$(GPU_FRONTEND_PORT) 2>/dev/null || true); \
	if [ -n "$$STALE" ]; then kill $$STALE 2>/dev/null || true; sleep 1; fi
	@kubectl port-forward svc/$(GPU_FRONTEND_SVC) -n $(NS_WORKLOAD) $(GPU_FRONTEND_PORT):8000 >/tmp/pf-gpu.log 2>&1 & \
	echo $$! > /tmp/pf-dynamo-gpu.pid
	@sleep 3
	@$(CURDIR)/.venv/bin/python3 scripts/gpu-sdk-example.py; \
	STATUS=$$?; \
	kill $$(cat /tmp/pf-dynamo-gpu.pid) 2>/dev/null; rm -f /tmp/pf-dynamo-gpu.pid; true; \
	exit $$STATUS

# ============================================================================
# Utility Targets
# ============================================================================

download-model: ## Download Qwen3-0.6B to host model cache (one-time, ~1.2 GB)
	@echo "==> Creating model cache directory: $(MODELS_DIR)"
	@mkdir -p $(MODELS_DIR)
	@echo "==> Downloading $(QWEN_MODEL) via huggingface-cli..."
	@if [ ! -x "$(CURDIR)/.venv/bin/pip" ]; then \
		echo "  .venv not found — creating..."; \
		python3 -m venv $(CURDIR)/.venv; \
		$(CURDIR)/.venv/bin/pip install --quiet huggingface_hub hf_transfer; \
	fi
	@$(CURDIR)/.venv/bin/hf download $(QWEN_MODEL) --cache-dir $(MODELS_DIR)
	@echo "✓ Model cached at $(MODELS_DIR)"
	@echo "  (Kind nodes will mount this at /root/.cache/huggingface)"

clean: cluster-down ## Clean up everything
	@echo "✓ Cleanup complete"

rebuild: clean cluster-setup ## Rebuild cluster from scratch
	@echo "✓ Cluster rebuilt"

logs-dynamo: ## Show Dynamo logs
	@echo "⚠ Not yet implemented - Dynamo not installed"

debug-gpu: ## Debug GPU visibility in cluster
	@echo "==> Testing GPU device access in worker nodes..."
	@for node in $$(kubectl get nodes -o name | grep worker); do \
		echo ""; \
		echo "Node: $$node"; \
		node_name=$$(echo $$node | cut -d'/' -f2); \
		docker exec $$node_name ls -la /dev/nvidia* 2>&1 || echo "No GPU devices mounted"; \
	done
	@echo ""
	@echo "==> Checking for GPU device plugin..."
	@kubectl get daemonset -A | grep -i "gpu\|nvidia" || echo "No GPU device plugin found"

# ============================================================================
# GPU Operator (Optional - for future use if needed)
# ============================================================================

install-gpu-operator: ## [OPTIONAL] Install NVIDIA GPU Operator
	@echo "==> Installing NVIDIA GPU Operator..."
	@echo "⚠ This is OPTIONAL and likely not needed for mocker-based demo"
	@echo ""
	@read -p "Continue? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		helm upgrade --install gpu-operator nvidia/gpu-operator \
			--namespace gpu-operator-system \
			--create-namespace \
			--version $(GPU_OPERATOR_VERSION) \
			--values infra/operator-values.yaml \
			--wait; \
	fi

uninstall-gpu-operator: ## Remove GPU Operator
	@helm uninstall gpu-operator -n gpu-operator-system || true
	@kubectl delete namespace gpu-operator-system || true
