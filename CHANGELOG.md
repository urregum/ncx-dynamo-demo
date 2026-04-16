# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.1.0] - 2026-04-16

### Added

- **GPU inference track** (`make gpu-deploy`): disaggregated real vLLM inference on
  a dedicated `rack-gpu` Kind node using NVIDIA Dynamo's prefill/decode split topology
- `make gpu-prepull` — pre-loads the vLLM runtime image (~9 GB) and curl init-container
  image into all Kind nodes to avoid live registry pulls at pod start
- `make gpu-validate` — smoke test: `/health` check + one inference request
- `make gpu-stream` — streaming SSE response showing real token arrival timing
- `make gpu-benchmark` — AIPerf benchmark against the GPU frontend; saves
  `results/gpu-real.json` (ISL=128, OSL=32, concurrency=4, tuned for 8 GiB VRAM)
- `make gpu-status` — registered models, KAI PodGang state, and pod placement
- `make gpu-sdk-example` — OpenAI SDK Python example (`scripts/gpu-sdk-example.py`)
- `make setup-gpu-node` — copies versioned NVIDIA CDI libraries into the GPU Kind node
  via `readlink -f` discovery; called automatically by `cluster-setup` on GPU systems
- `docs/gpu-inference-runbook.md` — full runbook covering startup sequencing, VRAM
  budget formula, hardware compatibility table, and troubleshooting guide
- `infra/kind-config-gpu.yaml.tpl` — fourth worker node (`rack: gpu`) with GPU device
  mounts; `nvidia-ctk` added to shared mount anchor
- Deterministic prefill startup gate: `wait-for-decode` init container polls decode's
  Dynamo health endpoint until `generate:ready`, replacing an arbitrary sleep

### Changed

- `make stack-install` post-run output now shows both demo tracks with per-track
  setup steps; GPU track section is conditional on `/dev/nvidia0` presence
- All pod wait loops now use `app.kubernetes.io/part-of=<dgd-name>` label selector
  and count Ready pods (all containers `1/1`) rather than grepping for Running phase
- `make benchmark-same-rack` and `make benchmark-cross-rack` wait loops scoped to
  `dynamo-bench` pods only, preventing false counts when GPU track runs concurrently
- GPU benchmark uses separate `GPU_BENCHMARK_ISL/OSL/CONC/REQS` variables
  (ISL=128) independent of mocker benchmark variables (ISL=4096)
- Qwen3 thinking mode disabled (`enable_thinking=false`) in `gpu-validate` and
  `gpu-stream` to prevent chain-of-thought tokens consuming the token budget
- `kubectl port-forward` output suppressed in all GPU targets (replaced `&>` bashism
  with POSIX-compatible `>/file 2>&1`; `/health` response body discarded with `-o /dev/null`)

---

## [1.0.0] - 2026-04-14

### Added

- **Mocker benchmark track**: rack-aware KV cache transfer cost demonstration using
  NVIDIA Dynamo's disaggregated inference topology with GPU mockers (no real GPU required)
- `make cluster-setup` — Kind cluster with 4 worker nodes in a two-rack topology
  (`rack-01` × 2, `rack-02` × 1, `rack-gpu` × 1) plus GPU scaffolding
- `make stack-install` — KAI Scheduler, Grove, and Dynamo operator via Helm
- `make mocker-deploy` — deploys the mocker DGD (Frontend + prefill + decode workers)
- `make benchmark-same-rack` / `make benchmark-cross-rack` — switches placement between
  same-rack (400 GB/s simulated KV) and cross-rack (12.5 GB/s simulated KV) scenarios
- `make run-benchmark` — AIPerf benchmark via port-forward; saves results JSON
- `make compare-results` — prints same-rack vs cross-rack latency comparison table
- `make validate-cluster` / `make validate-stack` / `make validate-mocker` — exit-0
  health checks at each setup phase
- `scripts/advertise-gpu-resources.sh` — patches `nvidia.com/gpu` capacity onto Kind
  worker nodes for gang scheduling demonstration
- `scripts/setup-ngc-secret.sh` — creates `ngc-registry` imagePullSecret
- `docs/runbook.md`, `docs/stack-runbook.md`, `docs/mocker-benchmark-runbook.md` —
  step-by-step operator guides for each setup phase
- `docs/architecture.md` — system design, scheduling topology, and KV transfer model
- Pre-commit hooks (conventional commits, trailing whitespace, YAML/JSON lint)
- CI: PR title lint workflow (`.github/workflows/pr-title.yml`)
- GPU auto-detection in `make kind-config` — selects GPU or no-GPU cluster template

[1.1.0]: https://github.com/urregum/ncx-dynamo-demo/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/urregum/ncx-dynamo-demo/releases/tag/v1.0.0
