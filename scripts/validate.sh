#!/bin/bash
# Validation suite — Secure Multi-Tenant Kubernetes Platform
# Fase 7: raccoglie tutti i test di sicurezza in un unico script ripetibile.

set -uo pipefail

PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }

echo "=================================================="
echo " Secure Multi-Tenant K8s Platform — Validation Suite"
echo "=================================================="
echo ""

# ---------------------------------------------------------
# Test 1-3: RBAC
# ---------------------------------------------------------
echo "--- RBAC ---"

if [ "$(kubectl auth can-i get pods -n team-beta --as=system:serviceaccount:team-alpha:alpha-dev)" == "no" ]; then
  pass "Test 1: alpha-dev cannot read pods in team-beta"
else
  fail "Test 1: alpha-dev CAN read pods in team-beta (should be denied)"
fi

if [ "$(kubectl auth can-i get pods -n team-alpha --as=system:serviceaccount:team-beta:beta-dev)" == "no" ]; then
  pass "Test 2: beta-dev cannot read pods in team-alpha"
else
  fail "Test 2: beta-dev CAN read pods in team-alpha (should be denied)"
fi

if [ "$(kubectl auth can-i create deployments -n team-alpha --as=system:serviceaccount:team-alpha:alpha-dev)" == "yes" ]; then
  pass "Test 3: alpha-dev can create deployments in its own namespace"
else
  fail "Test 3: alpha-dev CANNOT create deployments in team-alpha (should be allowed)"
fi

# ---------------------------------------------------------
# Test 4-5: NetworkPolicy
# ---------------------------------------------------------
echo ""
echo "--- NetworkPolicy ---"

kubectl apply -f k8s/manual-tests/test-alpha.yaml >/dev/null 2>&1
kubectl apply -f k8s/manual-tests/test-beta.yaml >/dev/null 2>&1
kubectl wait --for=condition=Ready pod/test-alpha -n team-alpha --timeout=60s >/dev/null 2>&1
kubectl wait --for=condition=Ready pod/test-beta -n team-beta --timeout=60s >/dev/null 2>&1

BETA_IP=$(kubectl get pod test-beta -n team-beta -o jsonpath='{.status.podIP}')
RESULT=$(kubectl exec -n team-alpha test-alpha -- wget -T 5 -O- "$BETA_IP" 2>&1 || true)

if echo "$RESULT" | grep -q "refused"; then
  pass "Test 4: cross-namespace traffic (alpha -> beta) is rejected"
else
  fail "Test 4: cross-namespace traffic was NOT rejected (unexpected: $RESULT)"
fi

DNS_RESULT=$(kubectl exec -n team-alpha test-alpha -- nslookup kubernetes.default.svc.cluster.local 2>&1 || true)
if echo "$DNS_RESULT" | grep -q "Address: 10.43"; then
  pass "Test 5: DNS resolution works despite default-deny-all"
else
  fail "Test 5: DNS resolution failed (unexpected: $DNS_RESULT)"
fi

kubectl delete pod test-alpha -n team-alpha >/dev/null 2>&1
kubectl delete pod test-beta -n team-beta >/dev/null 2>&1

# ---------------------------------------------------------
# Test 6: webapp -> postgres connectivity (diretto)
# ---------------------------------------------------------
echo ""
echo "--- Webapp to Postgres connectivity ---"

CONN_RESULT=$(kubectl exec -n team-alpha deployment/webapp -- python3 -c "
import socket
try:
    s = socket.create_connection(('postgres', 5432), timeout=5)
    print('OK')
    s.close()
except Exception as e:
    print('FAIL:', e)
" 2>&1 || true)

if echo "$CONN_RESULT" | grep -q "OK"; then
  pass "Test 6: webapp can reach its own postgres on port 5432"
else
  fail "Test 6: webapp CANNOT reach postgres (unexpected: $CONN_RESULT)"
fi

# ---------------------------------------------------------
# Test 7: Pod Security Standards
# ---------------------------------------------------------
echo ""
echo "--- Pod Security Standards ---"

PSS_RESULT=$(kubectl run test-pss --image=busybox -n team-alpha --restart=Never -- sleep 10 2>&1 || true)
if echo "$PSS_RESULT" | grep -q "Forbidden"; then
  pass "Test 7: privileged pod (no securityContext) rejected by PSS restricted"
else
  fail "Test 7: privileged pod was NOT rejected (unexpected: $PSS_RESULT)"
  kubectl delete pod test-pss -n team-alpha >/dev/null 2>&1
fi

# ---------------------------------------------------------
# Test 8-9: Gatekeeper
# ---------------------------------------------------------
echo ""
echo "--- Gatekeeper ---"

kubectl apply -f k8s/manual-tests/test-no-limits.yaml >/tmp/gk_test8.log 2>&1
if grep -q "denied the request" /tmp/gk_test8.log && grep -q "resource limit" /tmp/gk_test8.log; then
  pass "Test 8: pod without resource limits rejected by Gatekeeper"
else
  fail "Test 8: pod without resource limits was NOT rejected as expected"
  kubectl delete pod test-no-limits -n team-alpha >/dev/null 2>&1
fi

kubectl apply -f k8s/manual-tests/test-wrong-label.yaml >/tmp/gk_test9.log 2>&1
if grep -q "denied the request" /tmp/gk_test9.log && grep -q "does not match namespace" /tmp/gk_test9.log; then
  pass "Test 9: pod with mismatched tenant label rejected by Gatekeeper"
else
  fail "Test 9: pod with mismatched label was NOT rejected as expected"
  kubectl delete pod test-wrong-label -n team-alpha >/dev/null 2>&1
fi

rm -f /tmp/gk_test8.log /tmp/gk_test9.log

# ---------------------------------------------------------
# Test 10: Persistenza dati
# ---------------------------------------------------------
echo ""
echo "--- Data persistence ---"
echo "Test 10 (data survives pod restart) is a manual/visual test — see docs/environment.md."
echo "Skipped in automated run."

# ---------------------------------------------------------
# Summary
# ---------------------------------------------------------
echo ""
echo "=================================================="
echo -e " Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "=================================================="

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
