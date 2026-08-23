# k8s-deployment-demo

[![Kubernetes](https://img.shields.io/badge/kubernetes-ready-326CE5.svg?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Docker](https://img.shields.io/badge/docker-ready-2496ED.svg?logo=docker&logoColor=white)](https://www.docker.com/)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)

A production-style Kubernetes deployment of [`compose-multiservice-app`](https://github.com/SYRRUS-Ali/compose-multiservice-app) — evolving a Docker Compose stack into a Kubernetes setup with externalized configuration, health checks, autoscaling, and TLS-terminated ingress.

> 🚧 **Status: in progress.** Built incrementally, one real commit per day, as
> part of a structured DevSecOps portfolio sprint. See [Roadmap](#roadmap)
> for what's done and what's next — this README is updated as the project
> grows, not written after the fact.

## Table of contents

- [What this deploys](#what-this-deploys)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Health checks](#health-checks)
- [Autoscaling (HPA)](#autoscaling-hpa)
- [Ingress and TLS](#ingress-and-tls)
- [Design decisions](#design-decisions)
- [Problems encountered and solved](#problems-encountered-and-solved)
- [Known limitations](#known-limitations)
- [Project structure](#project-structure)
- [Roadmap](#roadmap)
- [License](#license)

## What this deploys

Two workloads on a local [minikube](https://minikube.sigs.k8s.io/) cluster:

- **`api`** — the FastAPI service from `compose-multiservice-app`, built
  directly into minikube's own Docker daemon (no registry needed locally).
- **`postgres`** — PostgreSQL 16, backing the API's persistence layer.

Both are exposed internally, wired together through a `ConfigMap` and a
`Secret`, protected by liveness/readiness probes, autoscaled under CPU load,
and reachable from outside the cluster only through an NGINX `Ingress` with
TLS termination.

> Redis and Nginx from the original Docker Compose stack are **not** part of
> this Kubernetes setup — see [Known limitations](#known-limitations).

## Prerequisites

- [minikube](https://minikube.sigs.k8s.io/docs/start/)
- `kubectl`
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
cp manifests/secret.template.yaml manifests/secret.yaml
# edit manifests/secret.yaml and replace the REPLACE_ME placeholders

# 4. Apply everything (order matters — Secret and ConfigMap first)
kubectl apply -f manifests/secret.yaml
kubectl apply -f manifests/configmap.yaml
kubectl apply -f manifests/postgres.yaml
kubectl apply -f manifests/api.yaml
kubectl apply -f manifests/hpa.yaml
kubectl apply -f manifests/ingress.yaml

# 5. Generate a self-signed TLS cert and point a local hostname at it
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/tls.key -out certs/tls.crt \
  -subj "/CN=k8s-deployment-demo.local/O=k8s-deployment-demo"
kubectl create secret tls api-tls --cert=certs/tls.crt --key=certs/tls.key
echo "$(minikube ip) k8s-deployment-demo.local" | sudo tee -a /etc/hosts

# 6. Verify
curl -k https://k8s-deployment-demo.local/health
```

## Configuration

Following the same `.env.example` / `.env` pattern used in
`compose-multiservice-app`, sensitive and non-sensitive settings are split:

| Source | Contains | Committed? |
|---|---|---|
| `manifests/configmap.yaml` | `LOG_LEVEL`, `ACCESS_TOKEN_EXPIRE_MINUTES`, `CACHE_TTL_SECONDS`, `REDIS_URL`, `POSTGRES_USER`, `POSTGRES_DB` | ✅ Yes |
| `manifests/secret.template.yaml` | Placeholder keys only (`POSTGRES_PASSWORD`, `JWT_SECRET_KEY`) | ✅ Yes |
| `manifests/secret.yaml` | Real secret values | ❌ Git-ignored |

`POSTGRES_USER` and `POSTGRES_DB` live in the `ConfigMap` and are referenced
by **both** the `postgres` and `api` Deployments — a single source of truth,
so the two can never drift out of sync. The API's `DATABASE_URL` is built
dynamically from those values using Kubernetes' `$(VAR_NAME)` env
interpolation rather than duplicating credentials as a literal string:

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
- **Kubernetes-recommended labels (`app.kubernetes.io/*`)** were added
  across every manifest ahead of the Helm chart work, since Helm expects
  and generates these labels by convention.

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
- **Stale ingress-nginx admission webhook.** After a `minikube stop`/
  `start` cycle, `ingress-nginx`'s validating webhook occasionally stays
  registered while its backing pod is still restarting, causing
  `kubectl apply` on the Ingress to fail with a connection-refused error
  from the webhook itself. Resolved by deleting and letting Kubernetes
  re-register it: `kubectl delete validatingwebhookconfiguration ingress-nginx-admission`.

## Known limitations

> Documented deliberately rather than hidden — see the same pattern in
> [`compose-multiservice-app`](https://github.com/SYRRUS-Ali/compose-multiservice-app#known-limitation).

- **Self-signed TLS certificate.** Fine for local development; a real
  deployment would use a CA-issued certificate (e.g. via `cert-manager`).
- **No persistent storage yet.** PostgreSQL data does not survive a pod
  restart or deletion — a `PersistentVolumeClaim` is on the
  [roadmap](#roadmap) but not yet implemented.
- **Secret values are base64, not encrypted.** Kubernetes `Secret`s are
  base64-encoded, not encrypted by default — real protection requires
  RBAC restrictions and encryption-at-rest at the cluster level, which is
  out of scope for a local minikube cluster.
- **Redis caching is not deployed here.** `compose-multiservice-app`'s
  Redis cache-aside layer is intentionally out of scope for this
  Kubernetes milestone; cache-dependent endpoints work in the Docker
  Compose version but are not required for this deployment's health check.

## Project structure

```
k8s-deployment-demo/
├── manifests/
│   ├── configmap.yaml         # non-sensitive shared configuration
│   ├── secret.template.yaml   # secret keys with placeholder values (committed)
│   ├── postgres.yaml          # Deployment + Service
│   ├── api.yaml               # Deployment + Service
│   ├── hpa.yaml                # HorizontalPodAutoscaler
│   └── ingress.yaml             # Ingress with TLS termination
├── docs/
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
- [ ] Helm chart packaging
- [ ] Persistent storage (PVC) for PostgreSQL
- [ ] Final documentation and polish pass
- [ ] `v1.0.0` tag

## License

MIT — see [LICENSE](LICENSE).