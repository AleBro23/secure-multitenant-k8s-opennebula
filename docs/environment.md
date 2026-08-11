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