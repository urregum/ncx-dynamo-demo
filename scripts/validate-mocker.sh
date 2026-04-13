#!/usr/bin/env bash
# validate-mocker.sh — Verify mocker stack is healthy
#
# Checks:
#   1. dynamo-bench DGD exists and is Ready
#   2. All 3 DGD pods Running (frontend, prefill, decode)
#   3. dynamo-bench-frontend Service endpoint is reachable
#   4. /health returns HTTP 200
#   5. Inference request succeeds (returns chatcmpl response)
#   6. Response includes nvext worker IDs (disaggregation confirmed)
# ============================================================================
set -euo pipefail

NS=dynamo-demo
SVC=dynamo-bench-frontend
PASS=0
FAIL=0

pass() { echo "  [PASS] $*"; ((++PASS)); }
fail() { echo "  [FAIL] $*"; ((++FAIL)); }
header() { echo ""; echo "==> $*"; }

header "Check 1: DGD exists and is Ready"
DGD_READY=false
for i in $(seq 1 20); do
  STATE=$(kubectl get dynamographdeployment dynamo-bench -n "$NS" \
    -o jsonpath='{.status.state}' 2>/dev/null || echo "")
  READY_COND=$(kubectl get dynamographdeployment dynamo-bench -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "$STATE" = "successful" ] || [ "$READY_COND" = "True" ]; then
    DGD_READY=true
    break
  fi
  if [ "$i" -eq 20 ]; then break; fi
  printf "  Waiting for DGD Ready (state=%s, attempt %s/20)\\r" "$STATE" "$i"
  sleep 3
done
if [ "$DGD_READY" = true ]; then
  pass "dynamo-bench DGD is Ready (state=${STATE})"
else
  fail "dynamo-bench DGD not Ready after 60s (state=${STATE}, Ready=${READY_COND})"
fi

header "Check 2: All 3 DGD pods Running"
RUNNING=$(kubectl get pods -n "$NS" \
  -l app.kubernetes.io/part-of=dynamo-bench \
  --field-selector=status.phase=Running \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$RUNNING" -ge 3 ]; then
  pass "$RUNNING pods Running (frontend + prefill + decode)"
else
  fail "Only $RUNNING pods Running, expected ≥3"
  kubectl get pods -n "$NS" -l app.kubernetes.io/part-of=dynamo-bench 2>/dev/null
fi

header "Check 3: Frontend Service exists"
SVC_PORT=$(kubectl get svc "$SVC" -n "$NS" \
  -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "")
if [ "$SVC_PORT" = "8000" ]; then
  pass "Frontend Service $SVC exists on port 8000"
else
  fail "Service $SVC not found or not on port 8000 (got: '$SVC_PORT')"
fi

header "Check 4 & 5: /health and inference via port-forward"
kubectl port-forward "svc/$SVC" -n "$NS" 18000:8000 &>/tmp/pf3.log &
PF_PID=$!
sleep 2

HEALTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:18000/health 2>/dev/null)
if [ "$HEALTH" = "200" ]; then
  pass "/health returned HTTP 200"
else
  fail "/health returned HTTP $HEALTH (expected 200)"
fi

header "Check 5: Inference request"
RESPONSE=$(curl -s --max-time 15 -X POST http://localhost:18000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Hi"}],"max_tokens":8}' \
  2>/dev/null || echo "")
kill "$PF_PID" 2>/dev/null || true
wait "$PF_PID" 2>/dev/null || true

if echo "$RESPONSE" | grep -q '"chatcmpl-'; then
  pass "Inference request returned chatcmpl response"
else
  fail "Inference request failed or returned no chatcmpl ID"
  echo "  Response: ${RESPONSE:0:200}"
fi

header "Check 6: Disaggregated inference (nvext worker IDs)"
if echo "$RESPONSE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ext=d.get('nvext',{})
w=ext.get('worker_id',{})
prefill=w.get('prefill_worker_id')
decode=w.get('decode_worker_id')
if prefill and decode:
    print(f'  prefill_worker_id={prefill}')
    print(f'  decode_worker_id={decode}')
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
  pass "Disaggregated inference confirmed (separate prefill + decode worker IDs)"
else
  fail "nvext.worker_id not present — disaggregation not confirmed"
fi

echo ""
echo "========================================================"
echo " Mocker Validation: $PASS passed, $FAIL failed"
echo "========================================================"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "✓ Mocker stack is healthy. Ready for benchmarking:"
  echo "  make run-benchmark"
  echo "  make benchmark-cross-rack && make run-benchmark"
  echo "  make compare-results"
  exit 0
else
  echo "✗ $FAIL check(s) failed. Investigate before benchmarking."
  exit 1
fi
