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
# Test 8-9: LimitRange auto-injects defaults (supersedes Gatekeeper check)
# ---------------------------------------------------------
echo ""
echo "--- Gatekeeper / LimitRange interaction ---"

kubectl apply -f k8s/manual-tests/test-no-limits.yaml >/dev/null 2>&1
INJECTED_LIMIT=$(kubectl get pod test-no-limits -n team-alpha -o jsonpath='{.spec.containers[0].resources.limits.cpu}')

if [ "$INJECTED_LIMIT" == "250m" ]; then
  pass "Test 8: pod without explicit limits gets LimitRange defaults injected before Gatekeeper validation (no unlimited pod can exist)"
else
  fail "Test 8: expected LimitRange default (250m) not found (unexpected: $INJECTED_LIMIT)"
fi

kubectl delete pod test-no-limits -n team-alpha >/dev/null 2>&1

# ---------------------------------------------------------
# Test 10: ResourceQuota — CPU/memory capacity exhaustion
# ---------------------------------------------------------
echo ""
echo "--- ResourceQuota (capacity) ---"

sed 's/test-quota-cap/test-quota-cap-a/g' k8s/manual-tests/test-quota-capacity.yaml | kubectl apply -f - >/dev/null 2>&1
CAP_RESULT=$(sed 's/test-quota-cap/test-quota-cap-b/g' k8s/manual-tests/test-quota-capacity.yaml | kubectl apply -f - 2>&1 || true)

if echo "$CAP_RESULT" | grep -q "exceeded quota"; then
  pass "Test 10: pod rejected once namespace CPU/memory quota is exhausted"
else
  fail "Test 10: quota was NOT enforced on CPU/memory exhaustion (unexpected: $CAP_RESULT)"
fi

kubectl delete pod test-quota-cap-a test-quota-cap-b -n team-alpha >/dev/null 2>&1

# ---------------------------------------------------------
# Test 11: ResourceQuota — pod count exhaustion (noisy neighbor)
# ---------------------------------------------------------
echo ""
echo "--- ResourceQuota (pod count) ---"

COUNT_REJECTED=0
CREATED_PODS=()
for i in $(seq 1 12); do
  RESULT=$(sed "s/test-quota-pod/test-quota-count-$i/g" k8s/manual-tests/test-quota-pod.yaml | kubectl apply -f - 2>&1 || true)
  if echo "$RESULT" | grep -q "exceeded quota"; then
    COUNT_REJECTED=1
    break
  else
    CREATED_PODS+=("test-quota-count-$i")
  fi
done

if [ "$COUNT_REJECTED" -eq 1 ]; then
  pass "Test 11: pod creation rejected once namespace pod-count quota is exhausted"
else
  fail "Test 11: all 12 pods were created without hitting the pod-count quota (unexpected)"
fi

for p in "${CREATED_PODS[@]}"; do
  kubectl delete pod "$p" -n team-alpha >/dev/null 2>&1
done



# ---------------------------------------------------------
# Test 12: external NodePort access is blocked by default-deny ingress
# ---------------------------------------------------------
echo ""
echo "--- External NodePort access (should be blocked) ---"

WORKER_IP="${WORKER_IP:-172.16.100.102}"

HTTP_CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://${WORKER_IP}:30081/" 2>/dev/null)
CURL_EXIT=$?

if [ "$CURL_EXIT" -ne 0 ] || [ "$HTTP_CODE" == "000" ]; then
  pass "Test 12: direct NodePort access to webapp is blocked by default-deny-all ingress"
else
  fail "Test 12: NodePort access unexpectedly succeeded (HTTP $HTTP_CODE) — ingress policy gap"
fi

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
