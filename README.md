<div align="center">

<img src="docs/assets/banner.svg" alt="DevOps Lab" width="100%">

### A complete local DevOps playground. One command up, one command down.

![Platform](https://img.shields.io/badge/platform-macOS%20Apple%20Silicon-8b5cf6?style=for-the-badge&logo=apple&logoColor=white)
![Kubernetes](https://img.shields.io/badge/kind-Kubernetes-22d3ee?style=for-the-badge&logo=kubernetes&logoColor=white)
![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-fb7185?style=for-the-badge&logo=argo&logoColor=white)
![Jenkins](https://img.shields.io/badge/Jenkins-CI-fbbf24?style=for-the-badge&logo=jenkins&logoColor=black)
![Grafana](https://img.shields.io/badge/Grafana-Dashboards-a3e635?style=for-the-badge&logo=grafana&logoColor=black)
![License](https://img.shields.io/badge/license-MIT-ff3d9a?style=for-the-badge)

[Portfolio page](docs/index.html) · [Architecture](docs/ARCHITECTURE.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Changelog](CHANGELOG.md)

</div>

---

## ✨ What is this?

DevOps Lab sets up a full CI/CD and GitOps environment on your laptop, for learning and experiments, with no cloud account needed.

| Tool | URL | Login | Runs in |
|------|-----|-------|---------|
| 🏗️ **Jenkins** | http://localhost:8080 | `admin` / `admin123` | its own Docker container |
| 🐙 **ArgoCD** | http://localhost:8081 | `admin` / run `lab creds` | kind cluster |
| 📈 **Grafana** | http://localhost:8082 | `admin` / `admin123` | kind cluster |
| 🔥 **Prometheus** | http://localhost:8083 | none | kind cluster |
| 🚨 **Alertmanager** | http://localhost:8084 | none | kind cluster |
| 🧪 **Spare port** | http://localhost:9090 | none | NodePort `30090` for your own apps |

> The logins above are for a localhost-only lab. Everything binds to `127.0.0.1`. Never reuse these passwords elsewhere.

## 🧭 Architecture

```mermaid
flowchart LR
  dev([You]) -->|git push| git[(Git repo)]
  subgraph Mac["Your Mac (Docker)"]
    subgraph J["container: lab-jenkins"]
      jenkins[Jenkins<br/>docker · kubectl · helm · argocd]
    end
    subgraph K["container: lab-control-plane (kind)"]
      argo[ArgoCD]
      app[Your apps]
      prom[Prometheus]
      graf[Grafana]
      alert[Alertmanager]
    end
  end
  jenkins -->|build + commit manifests| git
  git -->|watched by| argo
  argo -->|syncs| app
  prom -->|scrapes| app
  prom --> graf
  prom --> alert
  jenkins -.->|kubeconfig over the shared kind network| K
```

Jenkins runs **outside** the cluster on the same Docker network, so pipelines can call `kubectl`, `helm`, `docker` and `argocd` directly. Details are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## 🚀 Quick start

**Requirements:** a Mac, Docker Desktop or OrbStack (give it about 8 GB RAM), and [Homebrew](https://brew.sh). The script installs `kind`, `kubectl`, `helm`, `k9s` and `argocd` for you.

```bash
git clone <your-repo-url> devops-lab && cd devops-lab
./lab.sh up          # first run takes roughly 15-20 minutes
source ~/.zshrc      # enables the short alias: lab
```

### Daily routine

```bash
lab start     # morning: cluster first, then Jenkins
k9s           # explore the cluster
lab stop      # evening: Jenkins first, then the cluster. Data is kept
```

### All commands

| Command | What it does |
|---------|--------------|
| `lab up` | First-time setup. Safe to re-run |
| `lab start` | Start everything and re-connect ArgoCD |
| `lab stop` | Stop everything, keep all data |
| `lab status` | Containers, pods, services, URLs and logins |
| `lab creds` | Just the URL and login table |
| `lab verify` | Prove where each tool runs |
| `lab configs` | Regenerate config files only |
| `lab destroy` | Delete the cluster and Jenkins container, keep `jenkins_wp/` |
| `lab destroy --purge` | Same, and wipe `jenkins_wp/` too |

Every command finishes with the same summary: containers, nodes, pods, NodePort services and the URL/login table with live UP/DOWN status.

## 🔌 How the pieces are connected

- **Jenkins ⇄ your disk.** The local folder `jenkins_wp/` is used by Jenkins only. It is the container's `/var/jenkins_home`, so you can browse its files from your Mac without logging into the container (jobs, plugins and settings also survive rebuilds).
- **Jenkins ⇄ cluster.** The Jenkins container joins the `kind` Docker network and gets a kubeconfig pointing at `lab-control-plane:6443`.
- **ArgoCD ⇄ cluster.** ArgoCD manages the cluster it runs in (`in-cluster`). A sample `guestbook` app is registered automatically so you can see it sync.
- **ArgoCD ⇄ CLI.** `lab up` and `lab start` log the `argocd` CLI in, both on your Mac and inside Jenkins.
- **Prometheus ⇄ ArgoCD.** ArgoCD metrics are exposed through ServiceMonitors, which Prometheus picks up.

## 🧪 Try it

```bash
argocd app list                     # the sample app
kubectl get pods -n guestbook       # what ArgoCD deployed
```

A starter pipeline is in [examples/Jenkinsfile](examples/Jenkinsfile). Create a Pipeline job in Jenkins and paste it in.

## 📁 Project layout

```
.
├── lab.sh                  # the one script (heavily commented)
├── kind-config.yaml        # cluster + port mappings (generated)
├── argocd-values.yaml      # ArgoCD Helm values (generated)
├── monitoring-values.yaml  # Prometheus/Grafana Helm values (generated)
├── guestbook-app.yaml      # sample ArgoCD Application (generated)
├── jenkins/                # Jenkins image: Dockerfile, plugins, JCasC (generated)
├── jenkins_wp/             # Jenkins home on your Mac (git-ignored)
├── examples/Jenkinsfile    # sample CI → ArgoCD pipeline
├── docs/                   # portfolio page, architecture, troubleshooting
└── Makefile                # make up / start / stop ...
```

Config files are regenerated from `lab.sh` (see the settings block at the top), so change ports or passwords there and run `lab configs`.

## 🛠️ Customise

Open `lab.sh` and edit the **SETTINGS** section: ports, passwords, cluster name. Changing a cluster port needs `lab destroy` then `lab up`, because kind cannot change port mappings on a live cluster.

## 🩺 Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). The most common causes are a port already in use, or too little Docker memory.

## 🤝 Contributing

Ideas and fixes are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first, and report security issues as described in [SECURITY.md](SECURITY.md).

## 📜 License

MIT, see [LICENSE](LICENSE).
