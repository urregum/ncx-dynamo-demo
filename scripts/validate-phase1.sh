#!/bin/bash
# Phase 1 Validation Script
# Validates that cluster is properly configured and ready for Phase 2

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
FAIL=0

echo "========================================="
echo "Phase 1 Validation"
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
if [ "$NOT_READY" -eq 0 ]; then
    check_pass "All 4 nodes are Ready"
else
    check_fail "$NOT_READY node(s) not Ready"
    kubectl get nodes
fi
echo ""

# Check 3: Rack topology
echo "[3/7] Checking rack topology..."
RACK01_COUNT=$(kubectl get nodes -l rack=01 --no-headers | wc -l)
RACK02_COUNT=$(kubectl get nodes -l rack=02 --no-headers | wc -l)

if [ "$RACK01_COUNT" -eq 2 ] && [ "$RACK02_COUNT" -eq 1 ]; then
    check_pass "Rack topology correct (2 nodes in rack 01, 1 in rack 02)"
else
    check_fail "Rack topology incorrect (expected 2 in rack 01, 1 in rack 02)"
    echo "   Found: $RACK01_COUNT in rack 01, $RACK02_COUNT in rack 02"
fi
echo ""

# Check 4: GPU resources advertised
echo "[4/7] Checking GPU resources..."
GPU_NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.capacity."nvidia.com/gpu" != null) | .metadata.name' | wc -l)

if [ "$GPU_NODES" -eq 3 ]; then
    check_pass "GPU resources advertised on all 3 worker nodes"
else
    check_fail "GPU resources found on $GPU_NODES nodes (expected 3)"
    echo "   Run: make advertise-gpu-resources  (see docs/phase1-runbook.md)"
fi
echo ""

# Check 5: GPU device mounts
echo "[5/7] Checking GPU device mounts..."
MOUNT_FAILURES=0
for node in ncx-demo-cluster-worker ncx-demo-cluster-worker2 ncx-demo-cluster-worker3; do
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

# Check 7: System pods healthy
echo "[7/7] Checking system pods..."
UNHEALTHY_PODS=$(kubectl get pods -A --no-headers | grep -v "Running\|Completed" | wc -l || true)

if [ "$UNHEALTHY_PODS" -eq 0 ]; then
    check_pass "All system pods running"
else
    check_fail "$UNHEALTHY_PODS pod(s) not in Running/Completed state"
    kubectl get pods -A | grep -v "Running\|Completed" | head -10 || true
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
    echo -e "${GREEN}✓ Phase 1 validation PASSED${NC}"
    echo ""
    echo "Cluster is ready for Phase 2 (Dynamo + schedulers installation)"
    exit 0
else
    echo -e "${RED}✗ Phase 1 validation FAILED${NC}"
    echo ""
    echo "Please fix the failed checks before proceeding to Phase 2"
    echo "See docs/phase1-runbook.md for troubleshooting guidance"
    exit 1
fi
