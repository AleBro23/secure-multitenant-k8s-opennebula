#!/usr/bin/env bash
set -euo pipefail

# Bootstrap or resume the local k3d dev environment for the project.
# Safe to run every time you reopen the project.

CLUSTER_NAME="fcc-dev"
API_PORT="127.0.0.1:6550"   # workaround for VPN interference on default port
GATEKEEPER_VERSION="v3.16.3"  # pin to the version you're actually using

echo "==> Checking for existing k3d cluster '${CLUSTER_NAME}'..."

if k3d cluster list | grep -q "^${CLUSTER_NAME}"; then
    STATE=$(k3d cluster list -o json | grep -A2 "\"name\": \"${CLUSTER_NAME}\"" || true)
    echo "==> Cluster found. Starting it (no-op if already running)..."
    k3d cluster start "${CLUSTER_NAME}"
else
    echo "==> Cluster not found. Creating '${CLUSTER_NAME}' from scratch..."
    k3d cluster create "${CLUSTER_NAME}" --api-port "${API_PORT}"

    echo "==> Waiting for node to be Ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=90s

    echo "==> Installing Gatekeeper (${GATEKEEPER_VERSION})..."
    kubectl apply -f "https://raw.githubusercontent.com/open-policy-agent/gatekeeper/${GATEKEEPER_VERSION}/deploy/gatekeeper.yaml"

    echo "==> Waiting for Gatekeeper webhook to be ready..."
    kubectl wait --for=condition=Available deployment/gatekeeper-controller-manager \
        -n gatekeeper-system --timeout=120s
fi

echo "==> Verifying cluster is reachable..."
kubectl cluster-info

echo "==> Applying manifests in order..."
kubectl apply -f k8s/00-namespaces/
kubectl apply -f k8s/01-rbac/
kubectl apply -f k8s/02-networkpolicy/

echo "==> Applying Gatekeeper constraint templates and constraints..."
kubectl apply -f k8s/03-gatekeeper/

echo "==> Waiting a few seconds for ConstraintTemplates to be established..."
sleep 5

echo "==> Applying workloads..."
kubectl apply -f k8s/04-workloads/

echo "==> Done. Current state:"
kubectl get ns
kubectl get pods -A

echo ""
echo "Environment ready. Sunstone (if OpenNebula VM is up) should be reachable"
echo "via your existing SSH port-forward on port 2616."