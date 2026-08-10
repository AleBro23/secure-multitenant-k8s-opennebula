# Secure Multi-Tenant Kubernetes Platform on OpenNebula IaaS

Fog and Cloud Computing (145771) — University of Trento
Alessandro Brognara (261216) · Lorenzo Bergami (266671)

## Project Description

_TODO: summary of the problem and the architecture (see `docs/proposal.pdf`)_

## Architecture

_TODO: diagram + explanation of the IaaS/PaaS layers_

```
Azure Lab VM (Ubuntu 24.04, 16 GB RAM, 4 vCPU)
│
├── OpenNebula (MiniONE) — IaaS layer
│   ├── Private Virtual Network
│   ├── Security Group "k3s-cluster-sg"
│   └── 3 Ubuntu VMs:
│       ├── k8s-cp       (control-plane, 3 GB RAM, 2 vCPU)
│       ├── k8s-worker-1 (3.5 GB RAM, 2 vCPU)
│       └── k8s-worker-2 (3.5 GB RAM, 2 vCPU)
│
└── k3s runs on the 3 VMs — PaaS layer
    ├── namespace team-alpha   (webapp + postgres + PVC)
    ├── namespace team-beta    (webapp + postgres + PVC)
    └── namespace gatekeeper-system (OPA Gatekeeper)
```

## Prerequisites

- Access to the Azure Lab VM (OpenNebula/FireEdge)
- `kubectl`
- `k3s` (installed automatically by the setup scripts)

## Setup

### 1. IaaS Provisioning

_TODO: OpenNebula VM templates, instantiation, security group_

### 2. Cluster Bootstrap

_TODO: k3s install on control-plane and workers_

### 3. Applying the Manifests

Manifests must be applied in the order given by the folder prefixes:

```bash
kubectl apply -f k8s/00-namespaces/
kubectl apply -f k8s/01-rbac/
kubectl apply -f k8s/02-networkpolicy/
kubectl apply -f k8s/03-gatekeeper/
kubectl apply -f k8s/04-workloads/
```

_TODO: expand with any manual steps needed before/between these commands_

## Validation

Run the automated validation suite:

```bash
./scripts/validate.sh
```

_TODO: describe the five violation tests once implemented_

## Cleanup

_TODO: teardown instructions (delete VMs, cluster, etc.)_

## Repository Structure

```
.
├── docs/              # proposal, environment notes, final report
├── iaas/              # OpenNebula templates and configuration
├── k8s/               # Kubernetes manifests, applied in numeric order
├── app/               # demo webapp source code
└── scripts/           # setup and validation automation
```
