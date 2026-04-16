#!/bin/bash
# Cluster Validation Script
# Validates that cluster is properly configured and ready for stack installation

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
FAIL=0

echo "========================================="
echo "Cluster Validation"
echo "========================================="
echo ""

# Helper functions
check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASS++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAIL++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Check 1: Cluster exists
echo "[1/7] Checking cluster exists..."
if kind get clusters 2>/dev/null | grep -q "ncx-demo-cluster"; then
    check_pass "Cluster 'ncx-demo-cluster' exists"
else
    check_fail "Cluster 'ncx-demo-cluster' not found"
    echo "   Run: make rebuild"
    exit 1
fi
echo ""

# Check 2: All nodes Ready
echo "[2/7] Checking node health..."
NOT_READY=$(kubectl get nodes --no-headers | grep -v "Ready" | wc -l || true)
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
if [ "$NOT_READY" -eq 0 ]; then
    check_pass "All $TOTAL_NODES nodes are Ready"
else
    check_fail "$NOT_READY node(s) not Ready"
    kubectl get nodes
fi
echo ""

# Check 3: Rack topology
echo "[3/7] Checking rack topology..."
RACK01_COUNT=$(kubectl get nodes -l rack=01 --no-headers | wc -l)
RACK02_COUNT=$(kubectl get nodes -l rack=02 --no-headers | wc -l)
RACKGPU_COUNT=$(kubectl get nodes -l rack=gpu --no-headers | wc -l)

if [ -e /dev/nvidia0 ]; then
    # GPU cluster: expect rack-gpu node as well
    if [ "$RACK01_COUNT" -eq 2 ] && [ "$RACK02_COUNT" -eq 1 ] && [ "$RACKGPU_COUNT" -eq 1 ]; then
        check_pass "Rack topology correct (2 nodes in rack-01, 1 in rack-02, 1 in rack-gpu)"
    else
        check_fail "Rack topology incorrect (expected 2 in rack-01, 1 in rack-02, 1 in rack-gpu)"
        echo "   Found: $RACK01_COUNT in rack-01, $RACK02_COUNT in rack-02, $RACKGPU_COUNT in rack-gpu"
    fi
else
    # No-GPU cluster: rack-gpu node not expected
    if [ "$RACK01_COUNT" -eq 2 ] && [ "$RACK02_COUNT" -eq 1 ]; then
        check_pass "Rack topology correct (2 nodes in rack-01, 1 in rack-02; no-GPU cluster)"
    else
        check_fail "Rack topology incorrect (expected 2 in rack-01, 1 in rack-02)"
        echo "   Found: $RACK01_COUNT in rack-01, $RACK02_COUNT in rack-02"
    fi
fi
echo ""

# Check 4: GPU resources advertised
# All worker nodes require nvidia.com/gpu capacity for the Dynamo operator,
# regardless of whether actual GPU hardware is present.
echo "[4/7] Checking GPU resources..."
GPU_NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.capacity."nvidia.com/gpu" != null) | .metadata.name' | wc -l)
EXPECTED_GPU_NODES=$([ "$RACKGPU_COUNT" -eq 1 ] && echo 4 || echo 3)

if [ "$GPU_NODES" -eq "$EXPECTED_GPU_NODES" ]; then
    check_pass "GPU resources advertised on all $EXPECTED_GPU_NODES worker nodes"
else
    check_fail "GPU resources found on $GPU_NODES nodes (expected $EXPECTED_GPU_NODES)"
    echo "   Run: make advertise-gpu-resources  (see docs/cluster-runbook.md)"
fi
echo ""

# Check 5: GPU device mounts
echo "[5/7] Checking GPU device mounts..."
if [ ! -e /dev/nvidia0 ]; then
    check_pass "GPU device mount check skipped — no GPU on host (mocker-only cluster)"
else
    MOUNT_FAILURES=0
    for node in ncx-demo-cluster-worker ncx-demo-cluster-worker2 ncx-demo-cluster-worker3 ncx-demo-cluster-worker4; do
        if ! docker exec $node test -c /dev/nvidia0 2>/dev/null; then
            check_fail "$node missing /dev/nvidia0"
            ((MOUNT_FAILURES++))
        fi
    done
    if [ "$MOUNT_FAILURES" -eq 0 ]; then
        check_pass "GPU devices mounted in all worker nodes"
    else
        check_fail "$MOUNT_FAILURES node(s) missing GPU device mounts"
    fi
fi
echo ""

# Check 6: RuntimeClass exists
echo "[6/7] Checking RuntimeClass..."
if kubectl get runtimeclass nvidia &>/dev/null; then
    check_pass "RuntimeClass 'nvidia' exists"
else
    check_fail "RuntimeClass 'nvidia' not found"
    echo "   Run: kubectl apply -f manifests/nvidia-runtimeclass.yaml"
fi
echo ""

# Check 7: System pods healthy (poll up to 90s — pods may still be starting after cluster creation)
echo "[7/7] Checking system pods..."
SYSTEM_READY=false
for i in $(seq 1 30); do
    UNHEALTHY_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l | tr -d ' ')
    if [ "$UNHEALTHY_PODS" -eq 0 ]; then
        SYSTEM_READY=true
        break
    fi
    if [ "$i" -eq 30 ]; then
        break
    fi
    printf "  Waiting for system pods (%s not ready, attempt %s/30)\\r" "$UNHEALTHY_PODS" "$i"
    sleep 3
done

if [ "$SYSTEM_READY" = true ]; then
    check_pass "All system pods running"
else
    check_fail "$UNHEALTHY_PODS pod(s) not in Running/Completed state"
    kubectl get pods -A --no-headers | grep -v "Running\|Completed" | head -10 || true
fi
echo ""

# Summary
echo "========================================="
echo "Validation Summary"
echo "========================================="
echo -e "Passed: ${GREEN}$PASS${NC}"
echo -e "Failed: ${RED}$FAIL${NC}"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}✓ Cluster validation PASSED${NC}"
    echo ""
    echo "Cluster is ready for stack installation (make stack-install)"
    exit 0
else
    echo -e "${RED}✗ Cluster validation FAILED${NC}"
    echo ""
    echo "Please fix the failed checks before proceeding to stack installation"
    echo "See docs/cluster-runbook.md for troubleshooting guidance"
    exit 1
fi
