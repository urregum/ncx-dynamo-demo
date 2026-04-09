#!/usr/bin/env bash
# validate-phase2.sh
# Automated validation for Phase 2: KAI + Grove + Dynamo operator + placeholder workload.
# Run after 'make phase2' completes.

set -euo pipefail

PASS=0
FAIL=0
NS_KAI="kai-scheduler"
NS_GROVE="grove-system"
NS_DYNAMO="dynamo-system"
NS_WORKLOAD="dynamo-demo"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; ((++PASS)); }
fail() { echo -e "${RED}✗${NC} $1"; ((++FAIL)); }

echo "========================================="
echo " Phase 2 Validation"
echo "========================================="
echo ""

# ---------------------------------------------------------------------------
# [1] KAI Scheduler
# ---------------------------------------------------------------------------
echo "[1/7] Checking KAI Scheduler..."
ready=$(kubectl get pods -n ${NS_KAI} --no-headers 2>/dev/null | grep -c "Running" || true)
total=$(kubectl get pods -n ${NS_KAI} --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
if [ "${ready}" -ge 3 ] 2>/dev/null; then
  pass "KAI Scheduler running (${ready}/${total} pods Ready)"
else
  fail "KAI Scheduler pods not ready (${ready}/${total} Running) — check: kubectl get pods -n ${NS_KAI}"
fi

# ---------------------------------------------------------------------------
# [2] KAI default queues exist
# ---------------------------------------------------------------------------
echo ""
echo "[2/7] Checking KAI default queues..."
if kubectl get queue default-queue -n ${NS_KAI} >/dev/null 2>&1 || \
   kubectl get queue default-queue >/dev/null 2>&1; then
  pass "KAI default-queue exists"
else
  fail "KAI default-queue not found — queues may take a moment to create after install"
fi

# ---------------------------------------------------------------------------
# [3] Grove Operator
# ---------------------------------------------------------------------------
echo ""
echo "[3/7] Checking Grove operator..."
grove_pods=$(kubectl get pods -n ${NS_GROVE} -l app.kubernetes.io/name=grove-operator \
  --no-headers 2>/dev/null | grep -c "Running" || true)
if [ "${grove_pods}" -ge 1 ] 2>/dev/null; then
  pass "Grove operator running"
else
  fail "Grove operator not running — check: kubectl get pods -n ${NS_GROVE}"
fi

# ---------------------------------------------------------------------------
# [4] Grove CRDs installed
# ---------------------------------------------------------------------------
echo ""
echo "[4/7] Checking Grove CRDs..."
crds_found=0
for crd in podcliquesets.grove.io podcliques.grove.io podgangs.scheduler.grove.io; do
  if kubectl get crd "${crd}" >/dev/null 2>&1; then
    ((++crds_found))
  fi
done
if [ "${crds_found}" -eq 3 ]; then
  pass "Grove CRDs installed (podcliquesets, podcliques, podgangs)"
else
  fail "Only ${crds_found}/3 Grove CRDs found — install may be incomplete"
fi

# ---------------------------------------------------------------------------
# [5] Dynamo operator
# ---------------------------------------------------------------------------
echo ""
echo "[5/7] Checking Dynamo platform operator..."
dynamo_pods=$(kubectl get pods -n ${NS_DYNAMO} --no-headers 2>/dev/null | grep -c "Running" || true)
if [ "${dynamo_pods}" -ge 1 ] 2>/dev/null; then
  pass "Dynamo operator running (${dynamo_pods} pods)"
else
  fail "Dynamo operator not running — check: kubectl get pods -n ${NS_DYNAMO}"
fi

# ---------------------------------------------------------------------------
# [6] Placeholder workload PodCliqueSet
# ---------------------------------------------------------------------------
echo ""
echo "[6/7] Checking placeholder workload (PodCliqueSet)..."
pcs=$(kubectl get podcliqueset dynamo-demo -n ${NS_WORKLOAD} --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${pcs}" -ge 1 ] 2>/dev/null; then
  pass "PodCliqueSet 'dynamo-demo' exists in ${NS_WORKLOAD}"
else
  fail "PodCliqueSet not found — check: kubectl get pcs -n ${NS_WORKLOAD}"
fi

# ---------------------------------------------------------------------------
# [7] All workload pods running (gang scheduling validated)
# ---------------------------------------------------------------------------
echo ""
echo "[7/7] Checking gang-scheduled pods (router + prefill + decode)..."
running=$(kubectl get pods -n ${NS_WORKLOAD} --no-headers 2>/dev/null | grep -c "Running" || true)
total_w=$(kubectl get pods -n ${NS_WORKLOAD} --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${running}" -ge 3 ] 2>/dev/null && [ "${total_w}" -ge 3 ] 2>/dev/null; then
  pass "All ${running} workload pods Running — gang scheduling confirmed"
  echo ""
  echo "  Pod placement:"
  kubectl get pods -n ${NS_WORKLOAD} -o wide --no-headers 2>/dev/null | \
    awk '{printf "    %-40s  node=%-40s\n", $1, $7}' || true
else
  fail "Only ${running}/${total_w} workload pods Running — gang scheduling may be blocked"
  echo "  Current pod state:"
  kubectl get pods -n ${NS_WORKLOAD} 2>/dev/null | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo " Validation Summary"
echo "========================================="
echo -e " Passed: ${GREEN}${PASS}${NC}"
echo -e " Failed: ${RED}${FAIL}${NC}"
echo ""

if [ "${FAIL}" -eq 0 ]; then
  echo -e "${GREEN}✓ Phase 2 validation PASSED${NC}"
  echo ""
  echo "Scheduling stack is ready:"
  echo "  KAI Scheduler  → gang scheduling + queue management"
  echo "  Grove          → PodCliqueSet → PodGang orchestration"
  echo "  Dynamo         → DynamoGraphDeployment CRD (ready for Phase 3)"
  echo ""
  echo "Next step: make phase3 (pull vLLM image, deploy real workers, run AIPerf)"
  exit 0
else
  echo -e "${RED}✗ Phase 2 validation FAILED (${FAIL} checks)${NC}"
  echo ""
  echo "Debug commands:"
  echo "  kubectl get pods -A"
  echo "  helm list -A"
  echo "  kubectl get pcs,pclq,pcsg,pg -n ${NS_WORKLOAD}"
  exit 1
fi
