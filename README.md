# Secure Multi-Tenant Kubernetes Platform on OpenNebula IaaS

Fog and Cloud Computing (145771) — University of Trento
Alessandro Brognara (261216) · Lorenzo Bergami (266671)

## Project Description

This project implements a secure multi-tenant Kubernetes platform deployed on top of an
OpenNebula IaaS layer running on an Azure lab VM. Two simulated tenants (`team-alpha`,
`team-beta`) share the same physical Kubernetes cluster while being isolated through five
independent, layered security mechanisms:

- **RBAC** — per-tenant ServiceAccount/Role/RoleBinding, scoping API access to each tenant's own namespace
- **NetworkPolicy** — default-deny-all with explicit allow rules (DNS scoped to CoreDNS pods only, tenant-internal traffic only)
- **Pod Security Standards** — `restricted` profile enforced at namespace level
- **OPA/Gatekeeper** — custom admission policies (mandatory resource limits, tenant label matching)
- **ResourceQuota / LimitRange** — namespace-level caps on total CPU/memory and pod count, closing the noisy-neighbor gap left open by Gatekeeper's per-pod-only enforcement

Each tenant runs an identical demo web application (Flask + Postgres task board), deliberately
kept as the *same* container image for both tenants — the isolation guarantee comes entirely
from the platform, not from the application itself.

## Architecture

![Architecture diagram — IaaS/PaaS boundary, VMs, tenant namespaces and isolation mechanisms](docs/architecture.png)

Summary:

```
Azure Lab VM (Ubuntu 24.04, 16 GB RAM, 4 vCPU)
│
├── OpenNebula (MiniONE) — IaaS layer
│   ├── Private Virtual Network "fcc-k3s-net" (172.16.100.101-120)
│   ├── Security Group "k3s-cluster-sg"
│   └── 3 Ubuntu 22.04 VMs (1 vCPU / 2.5 GB RAM / 10 GB disk each):
│       ├── k8s-cp       172.16.100.101 (control-plane, tainted NoSchedule)
│       ├── k8s-worker-1 172.16.100.102
│       └── k8s-worker-2 172.16.100.103
│
└── k3s runs on the 3 VMs — PaaS layer (tenant workloads: workers only)
    ├── namespace team-alpha   (webapp + postgres + PVC on local-path,
    │                           PSS restricted, ResourceQuota + LimitRange)
    ├── namespace team-beta    (webapp + postgres + PVC on local-path,
    │                           PSS restricted, ResourceQuota + LimitRange)
    └── namespace gatekeeper-system (OPA Gatekeeper)
```

The control-plane node is tainted (`node-role.kubernetes.io/control-plane=true:NoSchedule`)
so tenant pods are only ever scheduled on the two worker nodes.

> The IPs shown (172.16.100.101-103) are private, valid only within this project's OpenNebula
> VNet — not reachable from outside, and may change if the VMs are ever reprovisioned from
> scratch. See `docs/environment.md` for the up-to-date table.

**Local development note:** most of the Kubernetes-layer work (namespaces, RBAC, NetworkPolicy,
Gatekeeper, ResourceQuota/LimitRange, workloads) was first developed and validated on a local
[k3d](https://k3d.io/) single-node cluster, then deployed and re-verified on the real 3-node
cluster provisioned on the DISI lab VM. k3d runs actual k3s in Docker, including the same
kube-router-based NetworkPolicy controller used in production — see `docs/environment.md` for
details.

**IaaS provisioning:** completed independently on a dedicated OpenNebula (MiniONE) instance on
the lab VM — image registration, VNet, security group, VM template with SSH-key contextualization,
and instantiation of the 3 VMs, all via CLI. See `docs/vm-setup-runbook.md` for the full command
sequence, and `docs/environment.md` for the networking issues encountered and resolved along the
way (host-level routing, DNS resolution on Azure, iptables persistence).

## Prerequisites

- Access to the Azure Lab VM (OpenNebula/FireEdge)
- `kubectl`
- `k3s` (installed manually on each node — see `docs/vm-setup-runbook.md`)
- Docker (for building the demo webapp image)

## Setup

### 1. IaaS Provisioning

Full command sequence (image, VNet, security group, VM template, instantiation) in
`docs/vm-setup-runbook.md`. Also see `iaas/` for the OpenNebula template files.

### 2. Cluster Bootstrap

```bash
# On k8s-cp:
curl -sfL https://get.k3s.io | sh -
sudo cat /var/lib/rancher/k3s/server/node-token   # copy the token

# On each worker:
curl -sfL https://get.k3s.io | K3S_URL=https://172.16.100.101:6443 K3S_TOKEN=<token> sh -
```

Real VM IPs, the control-plane taint command, and the DNS/networking fixes required on this
specific Azure/OpenNebula setup are documented in `docs/vm-setup-runbook.md` and
`docs/environment.md`.

### 3. Build and Import the Webapp Image

```bash
cd app
docker build -t team-webapp:local .
cd ..

# Local k3d cluster:
k3d image import team-webapp:local -c fcc-dev

# Real k3s cluster — import on every worker node (containerd caches are per-node,
# not shared; the control-plane is tainted so it never needs the image):
docker save team-webapp:local | ssh <worker-host> sudo k3s ctr images import -
```

### 4. Create the Postgres Secrets

Credentials are kept out of version control (see `k8s/04-workloads/*.env.example`).
Copy each example, fill in real values, then generate the Secret imperatively — ideally using a
kubeconfig scoped to the tenant's own ServiceAccount rather than a cluster-admin one, to keep the
operation consistent with each tenant's actual RBAC permissions:

```bash
cp k8s/04-workloads/postgres-alpha.env.example k8s/04-workloads/postgres-alpha.env
cp k8s/04-workloads/postgres-beta.env.example k8s/04-workloads/postgres-beta.env
# edit both files with real credentials, then:

kubectl create secret generic postgres-credentials \
  --from-env-file=k8s/04-workloads/postgres-alpha.env --namespace=team-alpha

kubectl create secret generic postgres-credentials \
  --from-env-file=k8s/04-workloads/postgres-beta.env --namespace=team-beta
```

### 5. Applying the Manifests

Manifests must be applied in the order given by the folder prefixes. `00-namespaces/` includes
the ResourceQuota and LimitRange for each tenant alongside the namespace definitions:

```bash
kubectl apply -f k8s/00-namespaces/
kubectl apply -f k8s/01-rbac/
kubectl apply -f k8s/02-networkpolicy/
kubectl apply -f k8s/03-gatekeeper/
kubectl apply -f k8s/04-workloads/
```

`scripts/init-local.sh` automates this for the local k3d environment (including installing
Gatekeeper from scratch); `scripts/init-deploy-vm.sh` automates it for the real cluster, assuming
k3s is already bootstrapped and `KUBECONFIG` is already pointed at it.

`ResourceQuota`/`LimitRange` values in `k8s/00-namespaces/resourcequota-*.yaml` and
`limitrange-*.yaml` are calibrated for this project's real worker capacity (1 vCPU / 2.5 GB each,
control-plane excluded) — recalibrate if deploying to a cluster with different worker specs, see
the comment header in each file.

### 6. Access the Webapp

On the real cluster, use `scripts/port-forward.sh` (starts both port-forwards in the background,
safe to re-run) and `scripts/stop-port-forward.sh` to stop them:

```bash
./scripts/port-forward.sh
```

From a laptop, open an SSH tunnel to the Azure VM forwarding both ports, then browse to
`http://localhost:5000` (Team Alpha) and `http://localhost:5001` (Team Beta). See
`docs/vm-setup-runbook.md` for the full tunnel command.

Locally (k3d):
```bash
kubectl port-forward -n team-alpha svc/webapp 5000:5000
kubectl port-forward -n team-beta svc/webapp 5001:5000
```

## Validation

Run the automated validation suite, which covers RBAC isolation, NetworkPolicy enforcement,
Pod Security Standards, Gatekeeper admission policies, and ResourceQuota/LimitRange enforcement
(11 automated checks):

```bash
./scripts/validate.sh
```

See `docs/environment.md` for a detailed write-up of testing methodology and issues encountered
during development (e.g. the kube-router REJECT-vs-timeout behavior, PSS securityContext
requirements for Postgres, the admission controller evaluation order — PSS → Gatekeeper →
LimitRange → ResourceQuota — discovered while testing the noisy-neighbor fix, and the
Azure/OpenNebula networking issues encountered while bootstrapping the real cluster).

`docs/vm-setup-runbook.md` also includes ready-to-run examples demonstrating a scoped
ServiceAccount (`alpha-dev`) creating pods successfully in its own namespace and being rejected
with a real `Forbidden` when targeting the other tenant's namespace.

## Cleanup

```bash
# Local k3d cluster:
k3d cluster delete fcc-dev

# Real cluster — remove workloads only, keep infrastructure:
kubectl delete -f k8s/04-workloads/
kubectl delete -f k8s/03-gatekeeper/
kubectl delete -f k8s/02-networkpolicy/
kubectl delete -f k8s/01-rbac/
kubectl delete -f k8s/00-namespaces/
```

## Repository Structure

```
.
├── docs/                environment.md (setup notes, issues log), architecture.png,
│                        vm-setup-runbook.md (full Azure VM command sequence + demo examples),
│                        proposal, final report
├── iaas/                OpenNebula templates and configuration
├── k8s/
│   ├── 00-namespaces/   tenant + gatekeeper-system namespaces, ResourceQuota, LimitRange
│   ├── 01-rbac/         per-tenant ServiceAccount/Role/RoleBinding
│   ├── 02-networkpolicy/ default-deny, DNS (scoped to CoreDNS), webapp-to-postgres rules
│   ├── 03-gatekeeper/   ConstraintTemplates + Constraints
│   ├── 04-workloads/    postgres + webapp Deployments/Services/PVCs per tenant
│   └── manual-tests/    ad-hoc pods used to validate policies during development
├── app/                 Flask + Postgres demo webapp (task board), shared image for both tenants
└── scripts/
    ├── init-local.sh          bootstrap/resume the local k3d dev environment
    ├── init-deploy-vm.sh      apply manifests to the real 3-node cluster
    ├── validate.sh            automated validation suite
    ├── port-forward.sh        expose both tenant webapps (idempotent, backgrounded)
    └── stop-port-forward.sh   stop the port-forwards started above
```