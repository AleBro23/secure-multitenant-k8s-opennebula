set -euo pipefail


echo "==> Verifying cluster is reachable..."
kubectl cluster-info

echo "==> Applying namespaces + ResourceQuota/LimitRange..."
kubectl apply -f k8s/00-namespaces/
# retry needed: LimitRange sometimes races the Namespace creation depending on file ordering within the same kubectl apply -f call
kubectl apply -f k8s/00-namespaces/

echo "==> Applying RBAC..."
kubectl apply -f k8s/01-rbac/

echo "==> Applying NetworkPolicy..."
kubectl apply -f k8s/02-networkpolicy/

echo "==> Checking Gatekeeper is installed..."
if ! kubectl get deployment gatekeeper-controller-manager -n gatekeeper-system &>/dev/null; then
  echo "Gatekeeper not found — installing (one-time)..."
  kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/v3.16.3/deploy/gatekeeper.yaml
  kubectl wait --for=condition=Available deployment/gatekeeper-controller-manager -n gatekeeper-system --timeout=120s
fi

echo "==> Applying Gatekeeper ConstraintTemplates + Constraints..."
kubectl apply -f k8s/03-gatekeeper/
sleep 5
kubectl apply -f k8s/03-gatekeeper/

echo "==> Applying workloads..."
kubectl apply -f k8s/04-workloads/

echo "==> Done. Current state:"
kubectl get pods -A