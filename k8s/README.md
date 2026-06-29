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

### Apply order (Session 2)

`envFrom.secretRef` is **not** marked `optional`, so the pod will not start until `sarif-secrets` exists. Correct order:

1. `kubectl apply -k k8s/overlays/local` — creates the `sarif` Namespace (and all other resources).
2. `kubectl apply -f k8s/base/secret.yaml` — creates `sarif-secrets` in the `sarif` namespace.
3. The Deployment's pod will now become schedulable (kubelet can resolve both `envFrom` refs).

(`secret.yaml` carries `namespace: sarif` explicitly since kustomize doesn't manage it.)

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
| `securityContext / fsGroup` | Omitted pending verification of the `sarif` image `USER` in Session 2. If the container runs non-root it may not write `/data`; add `fsGroup` then. |
| Default StorageClass | PVC omits `storageClassName` — deliberate. Works on any cluster with a default SC (docker-desktop, minikube, kind). EKS requires the EBS CSI driver + a default StorageClass. Production would pin one. |
| SQLite → managed DB | Required to enable `replicas > 1` and `RollingUpdate`. Future phase. |
| EKS overlay | Stub only — Phase 1C. |
| `.env` / Dockerfile `COPY . .` | Verify `app/.env` remains git-ignored and Docker-ignored before Phase 1C image builds. Currently not baked into the image; re-confirm at build time. |

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
