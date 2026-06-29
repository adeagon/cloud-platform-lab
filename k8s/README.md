# sarif Kubernetes manifests

Kustomize base + overlays for deploying the [sarif](https://github.com/adeagon/sarif) application.

## Why every decision was made the way it was

These notes exist so that every choice can be explained in a technical interview, not just executed.

---

## Application topology

`sarif` is a single Node.js process. It runs an Express HTTP server **and** a background alert-polling loop (`setInterval`) in the same process, sharing the same SQLite `better-sqlite3` connection. `startPolling(...)` is called inside the `app.listen` callback, so both subsystems start together and share in-process state.

**K8s implication:** there is one Deployment, one container. No separate worker container, no separate frontend container, no init container for DB migration. Every K8s object in this repo maps to something real in the app.

---

## Replicas: 1 and strategy: Recreate

**Why replicas: 1?**

The app uses SQLite backed by a `ReadWriteOnce` PVC. A RWO volume can only be mounted by one node at a time. Running two replicas risks:
- If scheduled to different nodes: the second pod cannot mount the PVC at all (stuck `Pending`).
- If co-located: SQLite WAL mode allows concurrent reads but only one writer — the second replica's poller would write concurrently, which SQLite handles via locking but which creates contention and risks corruption under unusual failure modes.

**Why Recreate instead of RollingUpdate?**

`maxSurge: 1` (the RollingUpdate default) spins up a new pod *before* terminating the old one. With a RWO PVC this is exactly the same problem as replicas: 2. Recreate terminates the old pod first (brief downtime), then starts the new one (clean single writer).

**Production gap (documented):** this is the correct tradeoff for SQLite. The right fix is replacing SQLite with a managed database (RDS/Aurora), at which point you can use RollingUpdate with multiple replicas. That's a future phase.

---

## Port: 3001 throughout

The app's default `PORT` is `3001` and the Dockerfile `EXPOSE`s `3001`. The Compose file sets `PORT=3002` and maps `3002:3002` to avoid a host port conflict on the Raspberry Pi where another service occupies port 3001. That is a host-level concern irrelevant in Kubernetes pod networking. K8s manifests use `3001` everywhere.

Port `3001` lives in one structural place — the container's named port `http`. Everything else (probes, Service) references it by name.

---

## Probes: both on `/api/health`

`GET /api/health` at port 3001 returns:
- `200 { ok: true }` — SQLite `SELECT 1` succeeded (DB is reachable).
- `503 { ok: false }` — DB threw; pod is unhealthy.

This endpoint checks the thing that actually matters for correctness (the DB), not just "is Node alive." Both probes point here.

**Readiness** (initialDelay 10s, period 15s, failureThreshold 3): gates traffic. Fails fast on a sick DB — keeps broken pods out of rotation.

**Liveness** (initialDelay 20s, period 30s, failureThreshold 5): triggers a pod restart. More forgiving — avoids restarting on a transient blip. You want liveness to catch a truly stuck process, not to react to brief DB hiccups.

---

## ConfigMap vs Secret

`envFrom` pulls both:
- `sarif-config` (ConfigMap) — non-sensitive configuration: `HOST`, `PORT`, `SARIF_DB_PATH`, `CORS_ORIGIN`, `ALERT_POLL_INTERVAL_MS`, `MAX_ALERTS`.
- `sarif-secrets` (Secret) — five API keys: `SEATS_API_KEY`, `RAPIDAPI_KEY`, `TRAVELPAYOUTS_TOKEN`, `PUSHOVER_TOKEN`, `PUSHOVER_USER_KEY`.

`envFrom` is cleaner than listing individual `env[].valueFrom` entries — the app reads all these vars anyway, no selective exposure is needed.

### CORS_ORIGIN behavior

`CORS_ORIGIN` is empty in base. The app does `cors({ origin: process.env.CORS_ORIGIN || /localhost:\d+/ })`. An empty string falls back to the localhost regex — this is not "CORS disabled." The local overlay patches it to `http://sarif.local`. Since the Express app serves both the API and the built React frontend from the same origin and port, CORS is largely irrelevant for the bundled production setup.

---

## Out-of-band secret management

`secret.example.yaml` is committed with placeholder values. **It is NOT referenced by `base/kustomization.yaml`** — deliberately excluded so that `kubectl apply -k` never renders or overwrites a real Secret with placeholders.

### Workflow

```bash
cp k8s/base/secret.example.yaml k8s/base/secret.yaml
# Fill in real values in secret.yaml
kubectl apply -f k8s/base/secret.yaml  # gitignored; applied manually
```

### Apply order

`envFrom.secretRef` is **not** marked `optional`, so the pod will not start until `sarif-secrets` exists. Correct order on a fresh cluster:

1. `kubectl apply -f k8s/base/namespace.yaml` — creates the `sarif` Namespace first, which is required before the Secret can be created in it.
2. `kubectl apply -f k8s/base/secret.yaml` — creates `sarif-secrets` in the `sarif` namespace.
3. `kubectl apply -k k8s/overlays/local` — creates all remaining resources (Namespace idempotently, ConfigMap, PVC, Deployment, Service, Ingress).
4. The Deployment's pod will now start without entering `CreateContainerConfigError`.

(`secret.yaml` carries `namespace: sarif` explicitly since kustomize doesn't manage it.)

---

## Local cluster setup (kind)

Verified bring-up sequence for the `lab` kind cluster on macOS/Apple Silicon (arm64).

**Prerequisites:** `kind`, `kubectl` (with built-in kustomize), Docker Desktop.

### 1. Create the cluster

```bash
kind create cluster --name lab --config kind/cluster.yaml
```

`kind/cluster.yaml` configures `extraPortMappings` for host ports 80 and 443. These are
**load-bearing**: they route host TCP 80/443 into the kind node, where the ingress-nginx controller
binds `hostPort: 80/443` directly on the container. The `ingress-ready=true` node label is
included (matches the canonical kind example and is harmless), but the pinned controller manifest
does **not** select on it — it schedules via `nodeSelector: kubernetes.io/os: linux` and
tolerations for the control-plane taint. Do not cite the label in an interview as the scheduling
mechanism.

### 2. Install ingress-nginx

Current kind documentation notes that `cloud-provider-kind` now supports Ingress natively and
third-party controllers are not required by default. nginx ingress is chosen here deliberately
to practice a real, controller-based ingress and mirror production routing concepts.

The manifest is **pinned** to `controller-v1.15.1` (verified: creates the `ingress-nginx`
namespace, the `nginx` IngressClass, and runs controller image `v1.15.1`) rather than the
floating `main` branch for reproducibility.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s
```

Wait for the controller before deploying the app — the admission webhook must be ready or the
Ingress object will be rejected.

### 3. `/etc/hosts`

```bash
grep -qE '(^|[[:space:]])sarif\.local([[:space:]]|$)' /etc/hosts \
  || echo '127.0.0.1 sarif.local' | sudo tee -a /etc/hosts
```

Fallback if `sudo` is unavailable: `curl -H 'Host: sarif.local' http://localhost/api/health`.

### 4. Deploy the app

```bash
# On Apple Silicon — build natively for arm64, no --platform flag.
docker build -t sarif:local /path/to/sarif/app
kind load docker-image sarif:local --name lab

# Apply order: namespace first, then the Secret, then everything else.
kubectl apply -f k8s/base/namespace.yaml
# Apply the Secret (placeholder values are sufficient for /api/health):
kubectl create secret generic sarif-secrets \
  --from-literal=SEATS_API_KEY=placeholder \
  --from-literal=RAPIDAPI_KEY=placeholder \
  --from-literal=TRAVELPAYOUTS_TOKEN=placeholder \
  --from-literal=PUSHOVER_TOKEN=placeholder \
  --from-literal=PUSHOVER_USER_KEY=placeholder \
  -n sarif --dry-run=client -o yaml | kubectl apply -f -
# For real values, see "Out-of-band secret management" above.

kubectl apply -k k8s/overlays/local
kubectl wait pod --selector=app.kubernetes.io/name=sarif -n sarif \
  --for=condition=Ready --timeout=120s
```

### 5. Verified end state

```
pod/sarif-*   Running  Ready 1/1
pvc/sarif-data  Bound  1Gi  standard (kind local-path provisioner)
ingress/sarif   class:nginx  host:sarif.local  ADDRESS:localhost
endpoint sarif  <podIP>:3001
```

```bash
curl http://sarif.local/api/health
# → 200 {"ok":true,"service":"sarif"}
```

> The Ingress `ADDRESS` field showing `localhost` is controller/version-dependent in kind.
> A blank `ADDRESS` is not a failure if the `curl` returns 200.

---

## Kustomize over Helm

Kustomize is built into `kubectl` — no extra tooling, no templating language to learn, no chart packaging. Overlays are plain YAML patches that are easy to read and explain. Helm is reserved for platform components installed from upstream charts (ingress-nginx, cert-manager, etc.).

---

## EKS overlay

`overlays/eks/kustomization.yaml` is a **stub** and is **NOT deployable in this state.** It renders the same output as base (no `ingressClassName`, no host on the Ingress) — applying it would create an ambiguous Ingress. It will be completed in Phase 1C when EKS, ECR, and the AWS Load Balancer Controller exist.

---

## Known gaps / future work

| Gap | Notes |
|-----|-------|
| `securityContext / fsGroup` | **Resolved (Session 2).** The runtime image (`node:20-bookworm-slim`) has no `USER` directive — the container runs as root and writes the `/data` PVC without `fsGroup`. Omitted `securityContext` is correct for local. Production hardening (run non-root, add `runAsNonRoot` + `fsGroup`) is a future phase. |
| Default StorageClass | PVC omits `storageClassName` — deliberate. Works on any cluster with a default SC. **Verified (Session 2):** PVC bound on kind's `standard` (local-path provisioner). EKS requires the EBS CSI driver + a default StorageClass. Production would pin one. |
| SQLite → managed DB | Required to enable `replicas > 1` and `RollingUpdate`. Future phase. |
| EKS overlay | Stub only — Phase 1C. |
| `.env` / Dockerfile `COPY . .` | **Verified (Session 2):** `app/.dockerignore` excludes `.env` — not baked into the `sarif:local` image. Re-confirm at Phase 1C ECR build time. |

---

## Directory layout

```
k8s/
  base/
    kustomization.yaml          # namespace: sarif; resources list (no secret)
    namespace.yaml
    configmap.yaml              # 6 config env vars (all quoted strings)
    secret.example.yaml         # TEMPLATE only — never in kustomize resources
    pvc.yaml                    # RWO, 1Gi, default StorageClass
    deployment.yaml             # replicas:1, Recreate, envFrom, probes, PVC mount
    service.yaml                # ClusterIP :3001
    ingress.yaml                # no host, no ingressClassName (overlays add these)
  overlays/
    local/
      kustomization.yaml        # images newTag:local; two patches
      configmap-cors-patch.yaml # CORS_ORIGIN: http://sarif.local
      ingress-patch.yaml        # ingressClassName:nginx, host:sarif.local
    eks/
      kustomization.yaml        # STUB — Phase 1C
  README.md                     # this file
```
