#!/usr/bin/env bash
# advertise-gpu-resources.sh
# Patches nvidia.com/gpu capacity onto worker nodes via the Kubernetes API.
#
# WHY mocker workers need this (rack-01 / rack-02 nodes):
#   The Dynamo operator requires schedulable nvidia.com/gpu resources on nodes
#   where it places worker pods, even when the workload does not consume GPU
#   (e.g. mocker-benchmark). The NVIDIA device plugin is not used here due to
#   inotify + CUDA library issues in Kind, so this manual patch replicates what
#   the device plugin would otherwise advertise.
#   Each mocker worker receives nvidia.com/gpu: 1 (artificial; no GPU consumed).
#
# WHY the GPU inference worker gets nvidia.com/gpu: 2 (rack-gpu node):
#   Disaggregated vLLM deploys two pods (prefill + decode) that each request
#   nvidia.com/gpu: 1. Both run on the same physical GPU (CUDA_VISIBLE_DEVICES=0).
#   Advertising 2 units allows Kubernetes to schedule both pods onto this node
#   without a resource conflict, while the actual GPU sharing is managed by CUDA.
#
# Limitation: resource patches disappear on node restart — re-run this script
# (make advertise-gpu-resources) if worker nodes are restarted.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ncx-demo-cluster}"
PROXY_PORT="${PROXY_PORT:-8001}"

# Always patch — required by Dynamo operator even on mocker-only clusters.
MOCKER_WORKERS=(
  "${CLUSTER_NAME}-worker"
  "${CLUSTER_NAME}-worker2"
  "${CLUSTER_NAME}-worker3"
)

# Only present on GPU cluster template (kind-config-gpu.yaml.tpl).
GPU_WORKER="${CLUSTER_NAME}-worker4"

# Kill any existing proxy on this port
pkill -f "kubectl proxy --port=${PROXY_PORT}" 2>/dev/null || true
sleep 1

# Start proxy in background
kubectl proxy --port="${PROXY_PORT}" >/dev/null 2>&1 &
PROXY_PID=$!
sleep 2

patch_node() {
  local node="$1"
  local count="$2"
  echo "  Advertising nvidia.com/gpu: ${count} on ${node}"
  response=$(curl -s -o /dev/null -w "%{http_code}" \
    --header "Content-Type: application/json-patch+json" \
    --request PATCH \
    --data "[{\"op\": \"add\", \"path\": \"/status/capacity/nvidia.com~1gpu\", \"value\": \"${count}\"}]" \
    "http://localhost:${PROXY_PORT}/api/v1/nodes/${node}/status")

  if [ "${response}" != "200" ]; then
    echo "ERROR: Failed to patch ${node} (HTTP ${response})"
    kill "${PROXY_PID}" 2>/dev/null || true
    exit 1
  fi
}

for node in "${MOCKER_WORKERS[@]}"; do
  patch_node "${node}" "1"
done

# Patch the GPU inference worker if it exists (GPU cluster template only).
if kubectl get node "${GPU_WORKER}" &>/dev/null 2>&1; then
  patch_node "${GPU_WORKER}" "2"
  GPU_MSG="  ${GPU_WORKER} → nvidia.com/gpu: 2 (disaggregated prefill + decode)"
else
  GPU_MSG="  ${GPU_WORKER} not present — GPU inference track unavailable (no-GPU cluster)"
fi

kill "${PROXY_PID}" 2>/dev/null || true

echo "✓ nvidia.com/gpu resources advertised:"
echo "  ${#MOCKER_WORKERS[@]} mocker workers → nvidia.com/gpu: 1 each (Dynamo operator requirement)"
echo "${GPU_MSG}"
echo "  Note: re-run this script if worker nodes are restarted."
