# Ambiente di sviluppo

## Lab VM Azure
- Owner:
- Ore residue (controllare periodicamente):

## VM OpenNebula (Fase 1)

| Nome | IP privato | RAM | vCPU |
|---|---|---|---|
| k8s-cp | | 3072 MB | 2 |
| k8s-worker-1 | | 3584 MB | 2 |
| k8s-worker-2 | | 3584 MB | 2 |


## Note

## Cluster locale k3d (sviluppo senza VM)

- Nome cluster: `fcc-dev`
- **Importante:** su questo laptop (VPN aziendale attiva) `k3d cluster create` semplice fallisce perché `host.docker.internal` si risolve tramite la VPN invece che verso Docker locale.   Va sempre creato con: `k3d cluster create fcc-dev --api-port 127.0.0.1:6550`

## NetworkPolicy — comportamento kube-router (k3s/k3d)

Verificato che il default-deny funziona correttamente, ma con un comportamento diverso da quanto
inizialmente atteso. Da documentare nel report finale (Fase 8.2, sezione "problemi incontrati").

**Comportamento atteso (ipotesi iniziale):** traffico bloccato = timeout silenzioso (drop del pacchetto).

**Comportamento reale con kube-router (l'implementazione NetworkPolicy embedded in k3s):**
traffico bloccato = `Connection refused` immediato, non timeout.

**Causa:** kube-router non fa DROP silenzioso. Usa REJECT con
`icmp-port-unreachable` per i pacchetti privi del mark di conformità a una NetworkPolicy di allow.
Lo stack TCP del chiamante traduce quell'ICMP in ECONNREFUSED — da cui "Connection refused" invece
di timeout.

**Verificato via iptables sul nodo k3d:**
REJECT ... mark match ! 0x10000/0x10000 reject-with icmp-port-unreachable
**Implicazione pratica per i test di validazione (Fase 7, Test #3):** l'esito atteso da documentare è "Connection refused" (o REJECT), non "timeout". Aggiornare la tabella dei test in Fase 7 di conseguenza.

**Nota tecnica:** i nomi delle chain iptables generate da kube-router (es. `KUBE-POD-FW-*`, `KUBE-NWPLCY-*`) cambiano ad ogni ciclo di resync (~1 minuto). Per debug futuro, non affidarsi
a un nome di chain ottenuto in un comando precedente — va sempre ricavato al volo nello stesso `docker exec`.

## Gatekeeper — bug Rego: assegnazione vs. negazione diretta su campo assente

Riscontrato scrivendo la policy `k8srequiredtenantlabel`. Da documentare nel report finale
(sezione problemi incontrati) — è un errore di semantica Rego facile da fare e istruttivo.

**Sintomo:** un pod senza il campo `labels` in `metadata` veniva creato con successo, nonostante la policy dovesse richiedere la label `team` obbligatoria.

**Causa:** la regola faceva `labels := input.review.object.metadata.labels` seguito da `not labels.team`. Se `metadata.labels` non esiste, l'assegnazione è "undefined" e l'intera regola Rego smette di essere valutata — nessun risultato, quindi nessuna violazione generata, quindi il pod passa. In Rego, un'assegnazione che fallisce silenziosamente blocca la valutazione
della regola, non produce automaticamente "falso".

**Fix:** negare il percorso completo direttamente, senza variabile intermedia:
`not input.review.object.metadata.labels.team`. Qui `not` su un percorso undefined restituisce
vero correttamente.

**Lezione generale:** in Rego, preferire la negazione diretta sul percorso completo quando il campo potrebbe non esistere, evitare di assegnare prima a una variabile e poi negare quella.

## Bug: collisione tra env var applicativa e variabile auto-iniettata da Kubernetes

Riscontrato sul Deployment della webapp — da documentare (sezione problemi incontrati).

**Sintomo:** la webapp falliva la connessione a Postgres con errore
`invalid integer value "tcp://<ip>:5432" for connection option "port"`, nonostante rete e DNS
verificati funzionanti (test con `nc -z postgres 5432` riuscito).

**Causa:** Kubernetes inietta automaticamente variabili d'ambiente per ogni Service esistente nel namespace, con naming `<NOMESERVICE>_PORT`, `<NOMESERVICE>_SERVICE_HOST`, ecc. Il Service Postgres
si chiama `postgres`, quindi Kubernetes genera da solo `POSTGRES_PORT=tcp://<clusterIP>:5432` — esattamente lo stesso nome che l'app usava per la propria variabile di configurazione della porta. La variabile auto-iniettata da Kubernetes ha sovrascritto il default applicativo.

**Fix:** rimossa la dipendenza da una env var per il numero di porta (fisso, sempre 5432 per Postgres) — hardcoded direttamente nel codice invece di leggerlo da env.

**Lezione generale:** evitare nomi di variabili d'ambiente applicative che iniziano col nome di un Service Kubernetes esistente nello stesso namespace — rischio concreto di collisione silenziosa.

## ResourceQuota / LimitRange — noisy-neighbor mitigation

**Issue addressed:** proposal feedback noted that Gatekeeper's per-pod resource limit
constraint does not prevent a tenant from exhausting node capacity via many small pods
(e.g. 1000 pods each within the per-pod limit). Fixed by adding namespace-level
`ResourceQuota` (hard caps on total requests.cpu/memory, limits.cpu/memory, and pod count)
and `LimitRange` (default + min/max per container) to `team-alpha` and `team-beta`.

**Admission chain discovery:** when testing enforcement, a single test pod triggered
rejections from *three different* admission layers before ever reaching ResourceQuota,
revealing the actual evaluation order in this cluster:

1. **Pod Security Standards** (`restricted`) — rejects missing `securityContext` fields
   (`runAsNonRoot`, `seccompProfile`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`)
2. **Gatekeeper** (`require-tenant-label` constraint) — rejects pods missing the `team` label
3. **LimitRange** — rejects requests without matching limits, or outside min/max bounds
4. **ResourceQuota** — only evaluated once the pod passes all of the above; rejects if the
   namespace total would be exceeded

Practical implication: a valid test pod must satisfy PSS + carry the correct `team` label
+ respect LimitRange bounds *before* it can be used to test ResourceQuota at all. Test
manifests in `k8s/manual-tests/` are built to satisfy 1–3 so they isolate ResourceQuota
behaviour specifically.

**Validation performed (local k3d, `team-alpha`):**
- Two pods requesting `1 CPU / 1Gi` each: first admitted (total 1.2/2 CPU used), second
  rejected — `exceeded quota: team-alpha-quota, requested: requests.cpu=1..., limited: requests.cpu=2`
- 12 concurrent pod creations at `50m CPU / 64Mi` each against `pods: 10` hard limit:
  admitted up to the cap, then rejected from the 11th onward —
  `exceeded quota: team-alpha-quota, requested: pods=1, used: pods=10, limited: pods=10`

Confirms noisy-neighbor threat is now mitigated at the namespace level, independent of
per-pod Gatekeeper limits.


## OpenNebula provisioning — VM (labJU7KS0)

Provisioned independently on the DISI lab VM.

- Host: 4 vCPU / 15.6 GB RAM (miniONE), datastore `default` (122.9G, qcow2)
- Image: Ubuntu 22.04 cloud image (ubuntu22.tmpl), registered as image ID 1
- VNet: `fcc-k3s-net`, bridge `minionebr` (shared with default miniONE vnet,
  separate IP pool: .101-.120 vs default's .2-.100)
- Security Group: `k3s-cluster-sg` (ID 100) — SSH/NodePort open externally;
  API server (6443), VXLAN (8472/UDP), kubelet (10250) restricted to VNet range
- VM Template: `k3s-node` — 1 vCPU / 2.5GB RAM / 10GB disk per node
  (sized down from original 2 vCPU plan: host only has 4 physical cores total)
- Contextualization: SSH_PUBLIC_KEY injection via CONTEXT, NETWORK=YES for
  automatic IP config — verified working, passwordless SSH as `ubuntu` user

3 VMs instantiated from template:
- k8s-cp       172.16.100.101
- k8s-worker-1 172.16.100.102
- k8s-worker-2 172.16.100.103

SSH: ssh -i ~/.ssh/fcc-k3s-cluster ubuntu@172.16.100.10{1,2,3}