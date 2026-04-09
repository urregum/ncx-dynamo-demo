#!/usr/bin/env bash
# advertise-gpu-resources.sh
# Patches nvidia.com/gpu capacity onto each worker node via the Kubernetes API.
#
# Why this exists: We mount GPU devices directly into kind worker nodes (Phase 1)
# but don't run the NVIDIA device plugin (inotify + CUDA library issues in kind).
# This manual patch achieves the same result for scheduling purposes.
#
# Limitation: resources disappear on node restart — re-run this script if nodes restart.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ncx-demo-cluster}"
PROXY_PORT="${PROXY_PORT:-8001}"
WORKERS=(
  "${CLUSTER_NAME}-worker"
  "${CLUSTER_NAME}-worker2"
  "${CLUSTER_NAME}-worker3"
)

# Kill any existing proxy on this port
pkill -f "kubectl proxy --port=${PROXY_PORT}" 2>/dev/null || true
sleep 1

# Start proxy in background
kubectl proxy --port="${PROXY_PORT}" >/dev/null 2>&1 &
PROXY_PID=$!
sleep 2

# Patch each worker node
for node in "${WORKERS[@]}"; do
  echo "  Advertising nvidia.com/gpu on ${node}"
  response=$(curl -s -o /dev/null -w "%{http_code}" \
    --header "Content-Type: application/json-patch+json" \
    --request PATCH \
    --data '[{"op": "add", "path": "/status/capacity/nvidia.com~1gpu", "value": "1"}]' \
    "http://localhost:${PROXY_PORT}/api/v1/nodes/${node}/status")

  if [ "${response}" != "200" ]; then
    echo "ERROR: Failed to patch ${node} (HTTP ${response})"
    kill "${PROXY_PID}" 2>/dev/null || true
    exit 1
  fi
done

kill "${PROXY_PID}" 2>/dev/null || true

echo "✓ nvidia.com/gpu: 1 advertised on ${#WORKERS[@]} worker nodes"
echo "  Note: re-run this script if worker nodes are restarted."
