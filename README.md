# Secure Multi-Tenant Kubernetes Platform on OpenNebula IaaS

Fog and Cloud Computing (145771) — University of Trento
Alessandro Brognara (261216) · Lorenzo Bergami (266671)

## Project Description

This project implements a secure multi-tenant Kubernetes platform deployed on top of an
OpenNebula IaaS layer running on the DISI lab VM (Azure-hosted). Two simulated tenants (`team-alpha`,
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
DISI Lab VM — Azure-hosted (Ubuntu 24.04, 16 GB RAM, 4 vCPU)
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
> scratch.

**Local development note:** most of the Kubernetes-layer work (namespaces, RBAC, NetworkPolicy,
Gatekeeper, ResourceQuota/LimitRange, workloads) was first developed and validated on a local
[k3d](https://k3d.io/) single-node cluster, then deployed and re-verified on the real 3-node
cluster provisioned on the DISI lab VM. k3d runs actual k3s in Docker, including the same
kube-router-based NetworkPolicy controller used in production.

**IaaS provisioning:** completed independently on a dedicated OpenNebula (MiniONE) instance on
the lab VM — image registration, VNet, security group, VM template with SSH-key contextualization,
and instantiation of the 3 VMs, all via CLI. The four OpenNebula template files used
(`ubuntu22.tmpl`, `fcc-k3s-net.tmpl`, `k3s-cluster-sg.tmpl`, `k3s-node.tmpl`) are in `iaas/`.

## Prerequisites

- Access to the DISI lab VM (OpenNebula/FireEdge)
- `kubectl`
- `k3s` (installed manually on each node — see step 3 below)
- Docker (for building the demo webapp image)

## Setup

### 1. IaaS Provisioning

Generate the real OpenNebula templates from the `.example` files (injects your own SSH public key):

​```bash
./scripts/gen-iaas-templates.sh
​```

OpenNebula template files (image, VNet, security group, VM template) are in `iaas/`:

```bash
oneimage create iaas/ubuntu22.tmpl -d 1
onevnet create iaas/fcc-k3s-net.tmpl
onesecgroup create iaas/k3s-cluster-sg.tmpl
onetemplate create iaas/k3s-node.tmpl

# instantiate the 3 VMs from the k3s-node template (ID 1):
onetemplate instantiate 1 --name k8s-cp
onetemplate instantiate 1 --name k8s-worker-1
onetemplate instantiate 1 --name k8s-worker-2
```

Each VM boots with network config and an SSH public key already injected via contextualization
(see the `CONTEXT` section in `iaas/k3s-node.tmpl`) — no manual per-VM setup or console login
required. IDs (`-d 1` for the datastore, `1` for the template) match this project's OpenNebula
instance and may differ on a fresh install — check with `onedatastore list` / `onetemplate list`.

### 2. Host Networking Fixes (Azure/OpenNebula-specific)

Two fixes are required on the OpenNebula host VM itself before the 3 VMs can reach each other and
the outside network.

**FORWARD chain** — traffic between the `minionebr` bridge (VNet) and the host's external
interface is dropped by default:

```bash
sudo iptables -I FORWARD -i minionebr -o eth0 -s 172.16.100.0/24 -j ACCEPT
sudo iptables -I FORWARD -i eth0 -o minionebr -d 172.16.100.0/24 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

Make it persist across reboots:

```bash
sudo DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent
sudo netfilter-persistent save
```

**DNS** — miniONE's default `dnsmasq` has no working upstream, and Azure blocks outbound UDP/53
to arbitrary public resolvers. The only reachable DNS is Azure's internal endpoint
(`168.63.129.16`). On each of the 3 VMs (`ssh -i ~/.ssh/fcc-k3s-cluster ubuntu@172.16.100.10{1,2,3}`):

```bash
sudo nano /etc/netplan/50-cloud-init.yaml
# change nameservers.addresses from 172.16.100.1 to 168.63.129.16
sudo netplan apply
```

### 3. Cluster Bootstrap

On the control-plane (`k8s-cp`, `172.16.100.101`):

```bash
curl -sfL https://get.k3s.io | sh -
sudo k3s kubectl get nodes
sudo cat /var/lib/rancher/k3s/server/node-token   # copy the token
```

On each worker (`k8s-worker-1` at `.102`, `k8s-worker-2` at `.103`), joining it to the
control-plane via the token generated above:

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://172.16.100.101:6443 K3S_TOKEN=<token> sh -
```

There is no auto-discovery — a node's role (server vs. agent) is decided purely by which install
command you run and, for workers, by the `K3S_URL`/`K3S_TOKEN` pair pointing them at the
control-plane. Verify from the control-plane:

```bash
sudo k3s kubectl get nodes -o wide
```

Taint the control-plane so tenant workloads only ever land on the two workers (replace the node
name with whatever `get nodes` reports — it defaults to the VM's hostname, not the OpenNebula VM
name):

```bash
kubectl taint nodes <control-plane-node-name> node-role.kubernetes.io/control-plane=true:NoSchedule
```

### 4. kubeconfig

From outside the cluster (e.g. the OpenNebula host VM, or your own machine via SSH tunnel), pull
the kubeconfig generated by the control-plane and point it at the real IP instead of `127.0.0.1`:

```bash
ssh -i ~/.ssh/fcc-k3s-cluster ubuntu@172.16.100.101 "sudo cat /etc/rancher/k3s/k3s.yaml"
# paste the output into ~/.kube/config, then replace 127.0.0.1 with 172.16.100.101
mkdir -p ~/.kube
export KUBECONFIG=~/.kube/config
kubectl get nodes
```

### 5. Build and Import the Webapp Image

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

### 6. Create the Postgres Secrets

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

### 7. Applying the Manifests

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

### 8. Access the Webapp

On the real cluster, use `scripts/port-forward.sh` (starts both port-forwards in the background,
safe to re-run) and `scripts/stop-port-forward.sh` to stop them:

**Note:** direct access via the NodePort (30081/30082) is intentionally blocked by the default-deny-all NetworkPolicy — port-forward is the only supported access path.

```bash
./scripts/port-forward.sh
```

From a laptop, open an SSH tunnel to the lab VM forwarding both ports, then browse to
`http://localhost:5000` (Team Alpha) and `http://localhost:5001` (Team Beta):

```bash
ssh -L 5000:localhost:5000 -L 5001:localhost:5001 <lab-vm-host>
```

Locally (k3d):
```bash
kubectl port-forward -n team-alpha svc/webapp 5000:5000
kubectl port-forward -n team-beta svc/webapp 5001:5000
```

## Validation

Run the automated validation suite, which covers RBAC isolation, NetworkPolicy enforcement,
Pod Security Standards, Gatekeeper admission policies, and ResourceQuota/LimitRange enforcement
(13 automated checks):

```bash
./scripts/validate.sh
```

Among these, Tests 1-3 demonstrate a scoped ServiceAccount (`alpha-dev`) creating pods
successfully in its own namespace and being rejected with a real `Forbidden` when targeting the
other tenant's namespace.


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
├── docs/                architecture.png
├── iaas/                OpenNebula templates: ubuntu22.tmpl (base image), fcc-k3s-net.tmpl
│                        (VNet), k3s-cluster-sg.tmpl (security group), k3s-node.tmpl (VM
│                        template, instantiated 3x for k8s-cp/k8s-worker-1/k8s-worker-2)
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
    ├── seed.sh                seed demo data into the webapp
    ├── validate.sh            automated validation suite
    ├── port-forward.sh        expose both tenant webapps (idempotent, backgrounded)
    └── stop-port-forward.sh   stop the port-forwards started above
```