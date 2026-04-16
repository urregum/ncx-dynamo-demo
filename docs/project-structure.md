# Project Structure

```
ncx-dynamo-demo/
├── Makefile                              # Orchestration targets (cluster-setup → stack-install → demo tracks)
├── README.md                             # Project overview
├── VERSION                               # Repo version (semver, e.g. 1.0.0)
├── CONTRIBUTING.md                       # Commit standards, branch workflow, versioning policy
├── LICENSE                               # MIT
├── requirements.txt                      # Python dependencies (aiperf, huggingface_hub)
├── .pre-commit-config.yaml               # YAML linting, whitespace, conventional-pre-commit, gitlint
├── .gitlint                              # gitlint config: enforces Signed-off-by in commit body
├── .yamllint.yaml                        # yamllint rules (line-length warning at 120, truthy checks)
├── .gitignore                            # Excludes .venv/, models/, .vscode/, results/*.json, etc.
├── .github/
│   └── workflows/
│       ├── build-mocker.yml              # Builds and pushes dynamo-mocker image on Dockerfile.mocker changes
│       └── lint.yml                      # PR lint: pre-commit file hooks + conventional commits PR title check
├── docs/
│   ├── architecture.md                   # Design overview, topology, decisions
│   ├── cluster-runbook.md                # Cluster setup instructions
│   ├── stack-runbook.md                  # Scheduling stack installation
│   ├── mocker-benchmark-runbook.md       # Mocker deployment, AIPerf benchmarking, troubleshooting
│   ├── gpu-inference-runbook.md          # Real vLLM inference: deploy, validate, benchmark, troubleshoot
│   └── project-structure.md              # This file
├── manifests/
│   ├── dynamo-mock-workers-same-rack.yaml        # DGD: mocker same-rack scenario
│   ├── dynamo-mock-workers-cross-rack.yaml       # DGD: mocker cross-rack scenario
│   ├── dynamo-vllm-gpu.yaml                      # DGD: disaggregated real vLLM on rack-gpu node
│   ├── dynamo-namespace.yaml                     # Workload namespace
│   ├── dynamo-placeholder-workload.yaml          # Phase 2 gang scheduling validation
│   ├── nvidia-device-plugin.yaml                 # NVIDIA device plugin daemonset
│   └── nvidia-runtimeclass.yaml                  # GPU pod runtime
├── infra/
│   ├── kind-config-gpu.yaml.tpl          # Kind cluster template with GPU device mounts
│   ├── kind-config-no-gpu.yaml.tpl       # Kind cluster template without GPU (mocker-only)
│   ├── kind-config.yaml                  # Generated from template by make kind-config (gitignored)
│   ├── kai-default-queues.yaml           # KAI Scheduler default queue configuration
│   └── operator-values.yaml              # Dynamo Helm chart overrides
├── container/
│   └── Dockerfile.mocker                 # Dynamo mocker image (no GPU required); built by build-mocker.yml
├── scripts/
│   ├── validate-cluster.sh               # Cluster health checks
│   ├── validate-stack.sh                 # Scheduling stack health checks
│   ├── validate-mocker.sh                # Mocker stack health checks
│   ├── compare-results.py                # Parses results/*.json, prints side-by-side latency table
│   ├── advertise-gpu-resources.sh        # Patches nvidia.com/gpu capacity onto Kind nodes
│   └── setup-ngc-secret.sh               # Creates NGC imagePullSecret in a namespace
├── models/
│   ├── hf-cache/                         # HuggingFace model cache (staged via make download-model)
│   └── .gitkeep
├── results/
│   ├── README.md                         # Notes on benchmark data
│   └── examples/
│       ├── same-rack.json                # Reference output from Ubuntu environment
│       └── cross-rack.json               # Reference output from Ubuntu environment
└── .venv/                                # Python virtual environment (gitignored)
```

## Key Files

| File | Purpose |
|------|---------|
| `Makefile` | Single entry point for all demo operations. Run `make help` for full target list. Core targets: `cluster-setup`, `stack-install`, `mocker-deploy`. |
| `VERSION` | Semver version string. Increment as part of squash commit per CONTRIBUTING.md policy. |
| `infra/kind-config-{gpu,no-gpu}.yaml.tpl` | Cluster templates. `make kind-config` selects based on `/dev/nvidia0` presence. |
| `manifests/dynamo-mock-workers-*.yaml` | DynamoGraphDeployment resources — mocker placement scenarios. |
| `manifests/dynamo-vllm-gpu.yaml` | DGD for real vLLM inference: disaggregated Frontend + prefill + decode on rack-gpu. |
| `container/Dockerfile.mocker` | Builds the mocker image; `build-mocker.yml` extracts the image version from the `ai-dynamo==` pin here. |
| `scripts/validate-cluster.sh`, `validate-stack.sh`, `validate-mocker.sh` | Exit-0 on pass, exit-1 on failure. Called by `make validate-cluster`, `validate-stack`, `validate-mocker`. |
| `scripts/setup-ngc-secret.sh` | Creates `ngc-registry` imagePullSecret. Reads `NGC_API_KEY` or `~/.ngc/apikey`. |
| `scripts/advertise-gpu-resources.sh` | Patches `nvidia.com/gpu` capacity onto Kind worker nodes via `kubectl`. |
| `scripts/compare-results.py` | Reads mocker results (same-rack/cross-rack) and optionally gpu-real.json; prints latency table. |
| `scripts/gpu-sdk-example.py` | OpenAI SDK chat completion example against the GPU frontend. Run via `make gpu-sdk-example`. |

## Generated / Gitignored

| Path | How it's created |
|------|-----------------|
| `infra/kind-config.yaml` | `make kind-config` — auto-selects GPU or no-GPU template |
| `models/hf-cache/` | `make download-model` — downloads Qwen3-0.6B |
| `.venv/` | `python3 -m venv .venv && .venv/bin/pip install ...` |
| `results/*.json` | `make run-benchmark` — AIPerf output per scenario |
| `results/logs/`, `results/inputs.json` | AIPerf run metadata (gitignored) |
| `results/examples/` | Reference outputs committed to repo; not overwritten by benchmark runs |
