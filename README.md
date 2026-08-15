# k8s-deployment-demo

Portfolio project demonstrating a security-conscious Kubernetes deployment workflow —
evolving `compose-multiservice-app` from Docker Compose to a production-style Kubernetes
setup (Deployment, Service, ConfigMaps, Secrets, health probes, autoscaling, Ingress with
TLS, and a Helm chart).

## Status
🚧 In progress — built incrementally, one real commit per day.

## Core Kubernetes concepts (quick primer)

- **Pod** — the smallest deployable unit; one or more containers that share network/storage
  and are always scheduled together.
- **Deployment** — manages a desired number of Pod replicas, handles rolling updates, and
  restarts failed Pods automatically (self-healing).
- **Service** — a stable network endpoint that routes traffic to the right Pods, even as
  they are replaced or rescheduled.

## Roadmap

| Step | Goal |
|---|---|
| Deployment + Service | Deploy `compose-multiservice-app` API on Kubernetes |
| ConfigMaps + Secrets | Externalize configuration securely |
| Probes | Liveness/readiness health checks |
| HPA | Horizontal Pod Autoscaler |
| Ingress + TLS | External access with TLS termination |
| Helm chart | Package everything for install/upgrade/rollback |
| Persistent storage | PostgreSQL data survives Pod restarts |

## Local development

This project is developed and tested against [minikube](https://minikube.sigs.k8s.io/).