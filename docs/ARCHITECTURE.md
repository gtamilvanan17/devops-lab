# Architecture

## Containers

| Container | Image | Purpose |
|-----------|-------|---------|
| `lab-jenkins` | `lab-jenkins:latest` (built from `jenkins/Dockerfile`) | Jenkins plus docker, kubectl, helm and argocd CLIs |
| `lab-control-plane` | kind node image | The whole Kubernetes cluster (single node) |

Both attach to the Docker network `kind`, so they resolve each other by name.

## Why Jenkins is outside the cluster
- It restarts and upgrades independently of the cluster.
- Rebuilding the cluster never touches Jenkins data.
- Pipelines can use the Mac's Docker daemon directly (via the mounted socket) to build images.

## Data and persistence

| Data | Where |
|------|-------|
| Jenkins home (jobs, plugins, credentials) | `./jenkins_wp` on your Mac, bind-mounted at `/var/jenkins_home`. Used by Jenkins only, so its files are visible locally without logging into the container |
| Prometheus data (5 Gi PVC, 3 day retention) | Inside the kind node |
| Grafana data (2 Gi PVC) | Inside the kind node |

`lab stop` keeps all of it. `lab destroy` deletes the cluster data but keeps `jenkins_wp`. Use `--purge` to remove that as well.

## Ports

| Mac port | Target | Notes |
|----------|--------|-------|
| 8080 | Jenkins container port 8080 | Docker `-p` mapping |
| 8081 | kind node 30080 → ArgoCD | kind `extraPortMappings` |
| 8082 | kind node 30082 → Grafana | |
| 8083 | kind node 30083 → Prometheus | |
| 8084 | kind node 30084 → Alertmanager | |
| 9090 | kind node 30090 | Free for your own apps |
| 6443 | Kubernetes API | Pinned so the kubeconfig survives restarts |

Port mappings are fixed when the cluster is created. To change one, edit `lab.sh`, then `lab destroy` and `lab up`.

## Connections

```mermaid
sequenceDiagram
  participant Lab as lab.sh
  participant K as kind cluster
  participant A as ArgoCD
  participant J as Jenkins
  Lab->>K: kind create cluster
  Lab->>K: helm install monitoring, argocd
  Lab->>J: docker run (network kind, jenkins_wp mounted)
  Lab->>J: copy internal kubeconfig
  Lab->>A: argocd login (Mac CLI)
  Lab->>J: argocd login (inside Jenkins)
  Lab->>K: apply guestbook Application
  A->>K: sync guestbook (in-cluster)
```

## Startup order
`lab start` brings up the cluster first (Jenkins needs its network and API), then Jenkins. `lab stop` does the reverse.
