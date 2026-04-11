kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ncx-demo-cluster

# ==============================================================================
# NCX Dynamo Demo Cluster Configuration - NO GPU (mocker-only)
# ==============================================================================
# Selected automatically by `make kind-config` when /dev/nvidia0 is absent.
#
# No GPU device files, container runtime binaries, or NVML library are mounted.
# GPU resource advertisement (nvidia.com/gpu: 1) is still applied to each worker
# via kubectl patch so the Dynamo operator's resource requirements are satisfied —
# no actual GPU is consumed by the mocker workload.
#
# Topology:
#   - 1 control plane
#   - 2 workers in rack "01" (same-rack locality for low latency)
#   - 1 worker in rack "02" (cross-rack for latency comparison)
# ==============================================================================

nodes:
  # ----------------------------------------------------------------------------
  # Control Plane
  # ----------------------------------------------------------------------------
  - role: control-plane
    extraPortMappings:
      # Expose standard HTTP/HTTPS ports for ingress/gateway access
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP

  # ----------------------------------------------------------------------------
  # Worker Nodes - Rack 01 (Local Rack)
  # ----------------------------------------------------------------------------
  - role: worker
    labels:
      rack: "01"
    extraMounts: &shared_mounts
      # -----------------------------------------------------------------------
      # HuggingFace Model Cache (pre-staged for demo)
      # Mounts host HF cache into nodes so mocker workers find the tokenizer locally
      # without downloading at pod startup.
      #
      # REPO_ROOT is substituted by: make kind-config   (uses current directory)
      #   Host:      ${REPO_ROOT}/models/hf-cache
      #   Container: /root/.cache/huggingface  (standard HF cache path)
      #
      # Populate model cache with: make download-model
      # -----------------------------------------------------------------------
      - hostPath: ${REPO_ROOT}/models/hf-cache
        containerPath: /root/.cache/huggingface
        readOnly: true

  - role: worker
    labels:
      rack: "01"
    extraMounts: *shared_mounts

  # ----------------------------------------------------------------------------
  # Worker Nodes - Rack 02 (Remote Rack)
  # ----------------------------------------------------------------------------
  - role: worker
    labels:
      rack: "02"
    extraMounts: *shared_mounts

# ==============================================================================
# Notes
# ==============================================================================
# GPU resources are advertised via: make advertise-gpu-resources
# This patches nvidia.com/gpu: 1 onto each worker node using the Kubernetes API,
# satisfying the Dynamo operator's resource requirements without physical GPU hardware.
# ==============================================================================
