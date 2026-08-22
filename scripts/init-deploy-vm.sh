#!/usr/bin/env bash
set -euo pipefail

# deploy-vm.sh — applies the Kubernetes-layer manifests to the real 3-node
# k3s cluster on the DISI lab VM. Assumes k3s is already bootstrapped on
# k8s-cp/k8s-worker-1/k8s-worker-2, and KUBECONFIG is already pointed at it.
# Does NOT install Gatekeeper — see step 2 below, run once manually if missing.

echo "==> Verifying cluster is reachable..."
kubectl cluster-info

echo "==> Applying namespaces + ResourceQuota/LimitRange..."
kubectl apply -f k8s/00-namespaces/
# retry needed: LimitRange sometimes races the Namespace creation depending
# on file ordering within the same kubectl apply -f call
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