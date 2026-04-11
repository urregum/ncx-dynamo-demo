kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ncx-demo-cluster

# ==============================================================================
# NCX Dynamo Demo Cluster Configuration - WITH GPU SUPPORT
# ==============================================================================
# This cluster provides real GPU access to pods by mounting:
#   1. GPU device files (/dev/nvidia*)
#   2. NVIDIA container runtime binaries
#   3. NVML library for GPU monitoring
#
# All 3 worker nodes share the single RTX 3070 Ti from the host.
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
    extraMounts: &gpu_mounts
      # -----------------------------------------------------------------------
      # GPU Device Files
      # -----------------------------------------------------------------------
      - hostPath: /dev/nvidia0
        containerPath: /dev/nvidia0
      - hostPath: /dev/nvidia-uvm
        containerPath: /dev/nvidia-uvm
      - hostPath: /dev/nvidiactl
        containerPath: /dev/nvidiactl

      # -----------------------------------------------------------------------
      # NVIDIA Container Runtime Binaries
      # These allow containerd inside kind nodes to inject GPU devices into pods
      # -----------------------------------------------------------------------
      - hostPath: /usr/bin/nvidia-container-runtime
        containerPath: /usr/bin/nvidia-container-runtime
      - hostPath: /usr/bin/nvidia-container-runtime-hook
        containerPath: /usr/bin/nvidia-container-runtime-hook

      # -----------------------------------------------------------------------
      # NVIDIA Management Library (NVML)
      # Required for GPU monitoring and device plugin validation
      # -----------------------------------------------------------------------
      - hostPath: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1
        containerPath: /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1

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
    extraMounts: *gpu_mounts

  # ----------------------------------------------------------------------------
  # Worker Nodes - Rack 02 (Remote Rack)
  # ----------------------------------------------------------------------------
  - role: worker
    labels:
      rack: "02"
    extraMounts: *gpu_mounts

# ==============================================================================
# Container Runtime Configuration
# ==============================================================================
# Configure containerd inside kind nodes to use the NVIDIA container runtime
# This enables GPU passthrough from kind nodes to pods
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
    privileged_without_host_devices = false
    runtime_type = "io.containerd.runc.v2"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
      BinaryName = "/usr/bin/nvidia-container-runtime"

# ==============================================================================
# Notes
# ==============================================================================
# After cluster creation, deploy the NVIDIA device plugin:
#   kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.15.0/deployments/static/nvidia-device-plugin.yml
#
# This will advertise nvidia.com/gpu resources on all worker nodes.
# All workers share the single physical RTX 3070 Ti - Kubernetes will see
# 1 GPU per node (3 total) but they map to the same physical GPU.
# ==============================================================================
