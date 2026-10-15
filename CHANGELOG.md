# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-10-15

### Added
- Jenkins data now lives in the local `jenkins_wp/` folder (bind-mounted as Jenkins' home).
- ArgoCD is connected to the cluster at setup. The `argocd` CLI is logged in on the Mac and inside Jenkins, and the demo apps are registered.
- Alertmanager exposed on port 8084.
- Every command now ends with a summary of containers, nodes, pods, NodePort services, ArgoCD apps and a URL/login table with live UP/DOWN status.
- Demo apps (`podinfo` (Helm) and `hello-web` (plain YAML)) deployed through ArgoCD by default, visible in the ArgoCD UI.
- Local-folder GitOps: edit `gitops/` and run `lab sync`. A small in-cluster git server (`lab-git`) serves a snapshot of the folder to ArgoCD, so no GitHub is needed. One folder per app under `gitops/apps/<name>/` (Helm wrapper chart or plain YAML); an ApplicationSet (`lab-apps`) turns each folder into an ArgoCD app, so adding an app needs no extra file.
- Reworked issue and pull request templates (forms).
- `lab destroy` lists what will be deleted and kept before asking for confirmation.
- `lab.env` settings file (cluster name, ports, logins, Jenkins heap, sample-app toggle) with a global `~/.config/devops-lab/lab.env`, `lab init`, and validation of ports and cluster name.
- `lab configs` command and `lab destroy --purge`.
- `argocd` CLI in the Jenkins image.
- Portfolio page, animated README, architecture and troubleshooting docs, sample Jenkinsfile, Makefile, CI lint workflow and community files.
- GitHub Pages workflow (`.github/workflows/pages.yml`) that publishes the portfolio, with SEO metadata, JSON-LD, sitemap and robots.txt.

### Changed
- Ports: Jenkins is on 8080 and ArgoCD on 8081 (previously swapped).
- `lab.sh` works from any folder (no hard-coded path) and has beginner-friendly comments.

### Migration
- The port layout changed, so run `lab destroy` then `lab up`.

## [1.0.0] - 2026-10-08

### Added
- Initial lab: kind cluster with ArgoCD, Prometheus and Grafana, Jenkins in its own container, and `up`, `start`, `stop`, `status`, `creds`, `verify`, `destroy` commands.
