# k8s-deployment-demo

[![Kubernetes](https://img.shields.io/badge/kubernetes-ready-326CE5.svg?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Helm](https://img.shields.io/badge/helm-chart-0F1689.svg?logo=helm&logoColor=white)](https://helm.sh/)
[![Docker](https://img.shields.io/badge/docker-ready-2496ED.svg?logo=docker&logoColor=white)](https://www.docker.com/)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)

A production-style Kubernetes deployment of [`compose-multiservice-app`](https://github.com/SYRRUS-Ali/compose-multiservice-app) — evolving a Docker Compose stack into a Kubernetes setup with externalized configuration, health checks, autoscaling, persistent storage, TLS-terminated ingress, and Helm packaging.

> 🚧 **Status: in progress.** Built incrementally, one real commit per day, as
> part of a structured DevSecOps portfolio sprint. See [Roadmap](#roadmap)
> for what's done and what's next — this README is updated as the project
> grows, not written after the fact.

## Table of contents

- [What this deploys](#what-this-deploys)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Health checks](#health-checks)
- [Autoscaling (HPA)](#autoscaling-hpa)
- [Persistent storage](#persistent-storage)
- [Ingress and TLS](#ingress-and-tls)
- [Design decisions](#design-decisions)
- [Helm release lifecycle](#helm-release-lifecycle)
- [Problems encountered and solved](#problems-encountered-and-solved)
- [Known limitations](#known-limitations)
- [Project structure](#project-structure)
- [Roadmap](#roadmap)
- [License](#license)

## What this deploys

Two workloads on a local [minikube](https://minikube.sigs.k8s.io/) cluster,
packaged as a single [Helm](https://helm.sh/) chart:

- **`api`** — the FastAPI service from `compose-multiservice-app`, built
  directly into minikube's own Docker daemon (no registry needed locally).
- **`postgres`** — PostgreSQL 16, backed by a `PersistentVolumeClaim` so
  data survives pod restarts.

Both are wired together through a `ConfigMap` and a `Secret`, protected by
liveness/readiness probes, autoscaled under CPU load, and reachable from
outside the cluster only through an NGINX `Ingress` with TLS termination.
The whole stack installs and upgrades as one Helm release.

> Redis and Nginx from the original Docker Compose stack are **not** part of
> this Kubernetes setup — see [Known limitations](#known-limitations).

## Architecture

![Architecture diagram](docs/architecture.svg)

Request flow: `Client → Ingress (TLS) → Service: api → Deployment: api`,
scaled by the `HorizontalPodAutoscaler` and configured from the
`ConfigMap`/`Secret`, talking to `Service: postgres → Deployment: postgres`,
backed by a `PersistentVolumeClaim`. Every resource in the diagram installs
and upgrades as one Helm release, with the sole exception of the `Secret`
(see [Design decisions](#design-decisions) for why).

## Prerequisites

- [minikube](https://minikube.sigs.k8s.io/docs/start/)
- `kubectl`
- [Helm](https://helm.sh/docs/intro/install/) 3+
- Docker
- `openssl` (for the self-signed TLS certificate)

## Quick start

```bash
# 1. Start the cluster (3GB memory is enough for this workload)
minikube start --driver=docker --memory=3072mb --cpus=2
minikube addons enable metrics-server
minikube addons enable ingress

# 2. Build the API image directly into minikube's Docker daemon
eval $(minikube docker-env)
git clone https://github.com/SYRRUS-Ali/compose-multiservice-app.git
docker build -t compose-multiservice-app-api:latest ./compose-multiservice-app/api

# 3. Create your local Secret from the committed template
cp helm/k8s-deployment-demo/secret.template.yaml helm/k8s-deployment-demo/secret.yaml
# edit helm/k8s-deployment-demo/secret.yaml and replace the REPLACE_ME placeholders
kubectl apply -f helm/k8s-deployment-demo/secret.yaml

# 4. Generate a self-signed TLS cert and point a local hostname at it
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/tls.key -out certs/tls.crt \
  -subj "/CN=k8s-deployment-demo.local/O=k8s-deployment-demo"
kubectl create secret tls api-tls --cert=certs/tls.crt --key=certs/tls.key
echo "$(minikube ip) k8s-deployment-demo.local" | sudo tee -a /etc/hosts

# 5. Install the chart
helm upgrade --install k8s-deployment-demo helm/k8s-deployment-demo

# 6. Verify
curl -k https://k8s-deployment-demo.local/health
```

## Configuration

Following the same `.env.example` / `.env` pattern used in
`compose-multiservice-app`, sensitive and non-sensitive settings are split:

| Source | Contains | Committed? |
|---|---|---|
| `helm/k8s-deployment-demo/values.yaml` | `LOG_LEVEL`, `ACCESS_TOKEN_EXPIRE_MINUTES`, `CACHE_TTL_SECONDS`, `REDIS_URL`, `POSTGRES_USER`, `POSTGRES_DB` | ✅ Yes |
| `helm/k8s-deployment-demo/secret.template.yaml` | Placeholder keys only (`POSTGRES_PASSWORD`, `JWT_SECRET_KEY`) | ✅ Yes |
| `helm/k8s-deployment-demo/secret.yaml` | Real secret values | ❌ Git-ignored |

`POSTGRES_USER` and `POSTGRES_DB` live in the `ConfigMap` (rendered from
`values.yaml`) and are referenced by **both** the `postgres` and `api`
Deployments — a single source of truth, so the two can never drift out of
sync. The API's `DATABASE_URL` is built dynamically from those values using
Kubernetes' `$(VAR_NAME)` env interpolation rather than duplicating
credentials as a literal string:

```yaml
- name: DATABASE_URL
  value: "postgresql+asyncpg://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres:5432/$(POSTGRES_DB)"
```

## Health checks

Both Deployments define `readinessProbe` and `livenessProbe`:

- **`api`** — HTTP `GET /health`
- **`postgres`** — `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB`

Readiness controls whether the Service routes traffic to a pod at all;
liveness controls whether Kubernetes restarts a pod that's stopped
responding. See [Problems encountered](#problems-encountered-and-solved) for
a real crash these probes are designed to guard against.

## Autoscaling (HPA)

`api` has a `HorizontalPodAutoscaler` (min 1, max 4 replicas, target 50% CPU
utilization). This was tested with a real synthetic load generator, not
just deployed and assumed to work:

**Scaling up under load** (1 → 2 replicas as CPU crosses the 50% target):

![HPA scale up](docs/hpa-scale-up.png)

**Scaling down after load stops**, respecting Kubernetes' default 5-minute
stabilization window before reducing replicas (visible as the ~5 minute gap
between the load stopping and `REPLICAS` dropping back to 1):

![HPA scale down](docs/hpa-scale-down.png)

## Persistent storage

PostgreSQL is backed by a `PersistentVolumeClaim` (1Gi, `ReadWriteOnce`), so
its data survives pod deletion, restarts, and rescheduling — instead of
living only in the pod's ephemeral container filesystem.

```yaml
- name: PGDATA
  value: /var/lib/postgresql/data/pgdata
```

`PGDATA` points to a *subdirectory* of the mount rather than the mount root.
The official PostgreSQL image's documentation warns that some storage
backends place a `lost+found` directory at a new volume's root, which makes
PostgreSQL treat the directory as "not empty" and refuse to initialize —
pointing `PGDATA` one level deeper avoids this entirely.

**Verified with a real test, not just deployed and assumed to work:**

1. Wrote a test row into PostgreSQL.
2. Deleted the `postgres` pod entirely (`kubectl delete pod -l app=postgres`).
3. Confirmed the replacement pod started and the row was still there.

The same row also survived two subsequent `helm upgrade` attempts — one of
which partially failed on the Ingress step, consistent with the pattern
documented in [Helm release lifecycle](#helm-release-lifecycle) — confirming
the PVC persists independently of both pod lifecycle and Helm release
outcomes.

## Ingress and TLS

The `api` Service is `ClusterIP` — it has no direct external exposure.
The only entry point is an NGINX `Ingress` (via minikube's `ingress` addon)
terminating TLS with a self-signed certificate, redirecting HTTP to HTTPS.

This replaced an earlier `NodePort` setup used during initial development —
a deliberate two-step evolution (get it reachable first, then put a proper
front door on it), not two access methods running side by side.

## Design decisions

- **Plaintext env vars before ConfigMap/Secret.** The first working
  Deployment (Day 3) used literal env values on purpose, before splitting
  them into a ConfigMap (Day 4) and Secret (Day 5) — mirroring how
  confidence is normally built incrementally in real infrastructure work,
  rather than trying to get every layer right in one commit.
- **Image built locally, not pushed to a registry.** For this local-dev
  milestone, the API image is built directly into minikube's own Docker
  daemon (`eval $(minikube docker-env)`) with `imagePullPolicy: Never` —
  no registry round-trip needed for a single-node local cluster.
- **The `Secret` is intentionally not managed by Helm.** The chart's
  Deployments reference an existing Secret (`app-secret`) by name only —
  Helm never sees or templates its values. This mirrors how secret
  management is commonly separated from application deployment in real
  clusters (e.g. via Vault or an External Secrets Operator), and keeps the
  same `secret.template.yaml` (committed) / `secret.yaml` (git-ignored)
  pattern already used before Helm was introduced, rather than reinventing
  it inside `values.yaml`.
- **`replicas` is omitted from the Deployment template when autoscaling is
  enabled.** Helm and the HPA both want to control replica count; if the
  chart always set a fixed `replicas`, every `helm upgrade` would silently
  reset the pod count back to the value in `values.yaml`, undoing whatever
  the HPA had scaled to. The template only sets `replicas` when
  `api.autoscaling.enabled` is `false`, leaving Kubernetes' own HPA
  controller as the sole source of truth otherwise.
- **`Deployment`, not `StatefulSet`, for PostgreSQL.** With a single
  replica and no horizontal scaling planned for the database, a
  `StatefulSet`'s main benefits (stable network identity, ordered
  multi-replica scaling) don't apply here — a `Deployment` with a
  `PersistentVolumeClaim` is simpler and sufficient for this milestone.
- **Kubernetes-recommended labels (`app.kubernetes.io/*`)** were added
  across every manifest before the Helm migration, since Helm expects and
  generates these labels by convention — this made the templating pass
  straightforward instead of retrofitting labels at the same time.

## Helm release lifecycle

The full `install` → `upgrade` → `rollback` cycle was tested end-to-end
with a real, verifiable change (`maxReplicas` on the HPA: 4 → 6), not just
run once and assumed to work:

| Revision | Status | What happened |
|---|---|---|
| 1 | `superseded` (failed) | Initial `helm install` — failed on the Ingress due to a stale `ingress-nginx` admission webhook (see [Problems encountered](#problems-encountered-and-solved)) |
| 2 | `superseded` (was `deployed`) | Retried after clearing the webhook — full stack live |
| 3 | `failed` | `helm upgrade` (`maxReplicas: 4 → 6`) hit the *same* stale-webhook class of failure again on the Ingress — but see below |
| 4 | `superseded` (was `deployed`) | `helm rollback k8s-deployment-demo 2` — confirmed `maxReplicas` back to 4 |
| 5 | `failed` | `helm upgrade` adding the PostgreSQL `PersistentVolumeClaim` — the *same* stale-webhook issue recurred a third time on the Ingress |
| 6 | `deployed` | Retried after clearing the webhook again — PVC and Deployment changes confirmed live |

**A partial-failure gotcha worth knowing:** in both revision 3 and revision
5, the Ingress apply failed and Helm correctly marked the whole release
`failed` — but the *other* resources in the same upgrade (the HPA's
`maxReplicas`, and later the PVC and Deployment changes) had already been
applied to the live cluster regardless. Without
[`--atomic`](https://helm.sh/docs/helm/helm_upgrade/), `helm upgrade`
applies resources as it goes; a failure partway through can leave the
cluster in a state that doesn't match *any* single revision's intended
manifest — some resources updated, others not — even though the release is
labeled `failed`. This turned out to be a consistent, repeatable pattern
tied specifically to the Ingress/webhook interaction, not a one-off.

**Also worth knowing:** `helm rollback` only affects the live cluster
state — it does not touch `values.yaml` on disk. After rolling back
revision 3, the file still read `maxReplicas: 6` and had to be reverted by
hand to match what the cluster was actually running, to avoid the repo
silently disagreeing with reality.

## Problems encountered and solved

Real issues hit during this build, documented as they happened (see commit
history for exact context):

- **minikube OOM crash.** `minikube start` without an explicit `--memory`
  flag defaulted to allocating more RAM (7.8GB) than the host machine
  actually has (6.87GB), silently crashing the cluster under the first real
  build load. Fixed by starting with `--memory=3072mb` explicitly.
- **Startup race condition.** Kubernetes has no equivalent to Docker
  Compose's `depends_on: condition: service_healthy` — Deployments start in
  parallel. The API's `lifespan` hook calls the database on startup, so on
  a cold start it would occasionally hit PostgreSQL before the pod was
  ready (`ConnectionRefusedError`, and once — after a cluster restart —
  a transient `socket.gaierror` from CoreDNS not being ready yet either).
  Kubernetes' automatic restart-with-backoff recovers from this within
  seconds; the [health checks](#health-checks) added later exist
  specifically to manage this class of problem more gracefully.
- **Stale `ingress-nginx` admission webhook — recurred three times, two
  distinct symptoms.** After a `minikube stop`/`start` cycle, or sometimes
  even a routine `helm upgrade`, `ingress-nginx`'s validating webhook has
  repeatedly been left in a broken state while its backing pod restarts —
  as a plain connection-refused error, and as an
  `x509: certificate signed by unknown authority` (its self-generated
  internal TLS cert going out of sync with the pod actually serving it).
  Every time, the fix has been the same:
  `kubectl delete validatingwebhookconfiguration ingress-nginx-admission`,
  letting Kubernetes re-register a fresh one. Each occurrence also
  demonstrated the same partial-failure behavior described in
  [Helm release lifecycle](#helm-release-lifecycle) — the non-Ingress parts
  of the upgrade succeeded regardless.
- **A `.gitignore` path drifted during the Helm migration.** When
  `secret.yaml` moved from `manifests/` to
  `helm/k8s-deployment-demo/`, `.gitignore` still pointed at the old path
  for one commit — long enough for `git add helm/` to accidentally stage
  the real (local, throwaway-dev-value) secret file. Caught before
  `git push` by reviewing `git status` and the commit diff, fixed with
  `git rm --cached` and `git commit --amend` on the still-local commit.
  Reinforces why every commit in this repo is checked with `git status`
  immediately before pushing.

## Known limitations

> Documented deliberately rather than hidden — see the same pattern in
> [`compose-multiservice-app`](https://github.com/SYRRUS-Ali/compose-multiservice-app#known-limitation).

- **Self-signed TLS certificate.** Fine for local development; a real
  deployment would use a CA-issued certificate (e.g. via `cert-manager`).
- **Secret values are base64, not encrypted.** Kubernetes `Secret`s are
  base64-encoded, not encrypted by default — real protection requires
  RBAC restrictions and encryption-at-rest at the cluster level, which is
  out of scope for a local minikube cluster.
- **Redis caching is not deployed here.** `compose-multiservice-app`'s
  Redis cache-aside layer is intentionally out of scope for this
  Kubernetes milestone; cache-dependent endpoints work in the Docker
  Compose version but are not required for this deployment's health check.
- **Single PostgreSQL replica, no backup strategy.** The PVC protects
  against pod loss, not against volume-level failure — a real deployment
  would add scheduled backups (e.g. `pg_dump` to external storage) on top.

## Project structure

```
k8s-deployment-demo/
├── helm/
│   └── k8s-deployment-demo/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── .helmignore
│       ├── secret.template.yaml   # secret keys with placeholder values (committed)
│       └── templates/
│           ├── _helpers.tpl
│           ├── configmap.yaml
│           ├── postgres-deployment.yaml
│           ├── postgres-service.yaml
│           ├── postgres-pvc.yaml
│           ├── api-deployment.yaml
│           ├── api-service.yaml
│           ├── hpa.yaml
│           └── ingress.yaml
├── docs/
│   ├── architecture.svg       # full request-flow / component diagram
│   ├── hpa-scale-up.png       # real autoscaling test, scale-up
│   └── hpa-scale-down.png     # real autoscaling test, scale-down
├── sandbox/
│   └── nginx-test-pod.yaml    # Day 1 cluster connectivity check (not app-related)
├── .gitignore
├── LICENSE
└── README.md
```

## Roadmap

- [x] Deployment + Service (API + PostgreSQL)
- [x] ConfigMap for non-sensitive configuration
- [x] Secret for sensitive configuration
- [x] Liveness and readiness probes
- [x] Resource requests/limits
- [x] Horizontal Pod Autoscaler (tested with real synthetic load)
- [x] Ingress with TLS termination
- [x] Standardized Kubernetes-recommended labels
- [x] Helm chart packaging
- [x] Documented `helm install` / `upgrade` / `rollback` cycle
- [x] Persistent storage (PVC) for PostgreSQL
- [x] Final documentation and polish pass
- [ ] `v1.0.0` tag

## License

MIT — see [LICENSE](LICENSE).