# Project Structure

```
ncx-dynamo-demo/
├── Makefile                              # Orchestration targets (3-phase automation)
├── README.md                             # Project overview
├── requirements.txt                      # Python dependencies (aiperf, huggingface_hub)
├── .pre-commit-config.yaml               # YAML linting, trailing whitespace
├── .gitignore                            # Excludes .venv/, models/, .vscode/, etc.
├── docs/
│   ├── architecture.md                   # Design overview, topology, decisions
│   ├── phase1-runbook.md                 # Cluster setup instructions
│   ├── phase2-runbook.md                 # Scheduling stack installation
│   ├── phase3-runbook.md                 # Mocker deployment, benchmarking
│   └── project-structure.md              # This file
├── manifests/
│   ├── dynamo-mock-workers-same-rack.yaml        # DGD: same-rack scenario
│   ├── dynamo-mock-workers-cross-rack.yaml       # DGD: cross-rack scenario
│   ├── dynamo-namespace.yaml                     # Workload namespace
│   ├── dynamo-placeholder-workload.yaml          # Phase 2 gang scheduling validation
│   └── nvidia-runtimeclass.yaml                  # GPU pod runtime
├── infra/
│   ├── kind-config-gpu.yaml.tpl          # Kind cluster template with GPU device mounts
│   ├── kind-config-no-gpu.yaml.tpl       # Kind cluster template without GPU (mocker-only)
│   ├── kind-config.yaml                  # Generated from template by make kind-config (gitignored)
│   └── operator-values.yaml              # Dynamo Helm chart overrides
├── scripts/
│   ├── validate-phase1.sh                # Phase 1 health checks
│   ├── validate-phase2.sh                # Phase 2 health checks
│   ├── validate-phase3.sh                # Phase 3 health checks
│   ├── advertise-gpu-resources.sh        # Patches nvidia.com/gpu capacity onto Kind nodes
│   └── setup-ngc-secret.sh               # Creates NGC imagePullSecret in a namespace
├── models/
│   ├── hf-cache/                         # HuggingFace model cache (staged via make download-model)
│   └── .gitkeep
├── results/
│   ├── README.md                         # Notes on benchmark data
│   ├── examples/
│   │   ├── same-rack.json                # Reference output from Ubuntu environment
│   │   └── cross-rack.json               # Reference output from Ubuntu environment
│   ├── same-rack.json                    # AIPerf output (written by make run-benchmark, gitignored)
│   └── cross-rack.json                   # AIPerf output (written by make run-benchmark, gitignored)
├── artifacts/                            # Intermediate build outputs (gitignored)
├── container/                            # Custom container build configs (if needed)
├── LICENSE                               # MIT
└── .venv/                                # Python virtual environment (gitignored)
```

## Key Files

| File | Purpose |
|------|---------|
| `Makefile` | Single entry point for all demo operations. Run `make help` for full target list. |
| `infra/kind-config-{gpu,no-gpu}.yaml.tpl` | Cluster templates. `make kind-config` selects based on `/dev/nvidia0` presence. |
| `manifests/dynamo-mock-workers-*.yaml` | DynamoGraphDeployment resources — one per placement scenario. |
| `scripts/validate-phase*.sh` | Exit-0 on pass, exit-1 on failure. Called by `make validate-phase*` targets. |
| `scripts/setup-ngc-secret.sh` | Creates `ngc-registry` imagePullSecret. Reads `NGC_API_KEY` or `~/.ngc/apikey`. |
| `scripts/advertise-gpu-resources.sh` | Patches `nvidia.com/gpu` capacity onto Kind worker nodes via `kubectl`. |

## Generated / Gitignored

| Path | How it's created |
|------|-----------------|
| `infra/kind-config.yaml` | `make kind-config` — auto-selects GPU or no-GPU template |
| `models/hf-cache/` | `make download-model` — downloads Qwen3-0.6B |
| `.venv/` | `python3 -m venv .venv && .venv/bin/pip install ...` |
| `results/*.json` | `make run-benchmark` — AIPerf output per scenario (gitignored) |
| `results/examples/` | Reference outputs committed to repo; not overwritten by benchmark runs |
