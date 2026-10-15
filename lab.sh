#!/usr/bin/env bash
# =============================================================================
#  DevOps Lab  -  a one-command local DevOps playground for Apple Silicon Macs
# =============================================================================
#
#  WHAT YOU GET
#  ------------
#   Docker container  lab-jenkins        Jenkins (its own image, own container)
#                                        its files are mirrored to ./jenkins_wp on
#                                        your Mac so you can browse them without
#                                        `docker exec` (Jenkins only, nothing else)
#   Docker container  lab-control-plane  a kind (Kubernetes-in-Docker) cluster,
#                                        and inside it:
#                                          - ArgoCD            (GitOps)
#                                          - Prometheus        (metrics)
#                                          - Grafana           (dashboards)
#                                          - Alertmanager      (alerts)
#   Your Mac                             only CLI tools: kind, kubectl, helm,
#                                        k9s, argocd  (installed via Homebrew)
#
#  PORTS ON YOUR MAC (all bound to 127.0.0.1)
#  ------------------------------------------
#   8080  Jenkins        8081  ArgoCD        8082  Grafana
#   8083  Prometheus     8084  Alertmanager  9090  spare (for your own apps)
#   6443  Kubernetes API   (these are the defaults; change them in lab.env)
#
#  COMMANDS
#  --------
#   ./lab.sh up         first-time setup (safe to re-run, it is idempotent)
#   ./lab.sh start      daily start
#   ./lab.sh stop       daily stop (all data is kept)
#   ./lab.sh status     show everything that is running
#   ./lab.sh creds      show URLs and logins
#   ./lab.sh verify     prove where each tool runs
#   ./lab.sh sync       push edits from ./gitops to ArgoCD (no git needed)
#   ./lab.sh init       create lab.env (your settings file) from the example
#   ./lab.sh configs    (re)generate the config files only, touch nothing else
#   ./lab.sh destroy    delete cluster + Jenkins container (keeps ./jenkins_wp)
#   ./lab.sh destroy --purge   same, and also wipe ./jenkins_wp
#
#  Every command ends by printing the same summary: containers, pods, services
#  and a table of URLs + logins.
# =============================================================================

# -E : ERR trap also works inside functions
# -e : stop on the first failing command
# -u : using an unset variable is an error
# -o pipefail : a pipeline fails if any command in it fails
set -Eeuo pipefail

LAB_VERSION="1.1.0"

# ---------------------------------------------------------------------------
# 1. SETTINGS  (defaults; override them in lab.env, no need to edit this file)
# ---------------------------------------------------------------------------

# The folder this script lives in. All config files and Jenkins data go here,
# so you can clone the repo anywhere and it just works.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
LAB_DIR="$(dirname "$SELF")"

# Your personal settings live in a plain KEY=value file, so you never have to
# edit this script. Files are read in this order (later ones win):
#   1. built-in defaults (below)
#   2. ~/.config/devops-lab/lab.env   (global: shared by every copy of the lab)
#   3. <lab folder>/lab.env           (local: this copy only)
#   4. the file named in LAB_ENV_FILE (optional, e.g. LAB_ENV_FILE=~/work.env ./lab.sh up)
# See lab.env.example for every setting. Create your file with: ./lab.sh init
load_env() {
  local f
  for f in "${HOME}/.config/devops-lab/lab.env" "${LAB_DIR}/lab.env" "${LAB_ENV_FILE:-}"; do
    [[ -n "$f" && -f "$f" ]] || continue
    set -a          # every variable assigned while sourcing becomes exported
    # shellcheck disable=SC1090
    source "$f"
    set +a
  done
}
load_env

# --- kind cluster ---
: "${CLUSTER:=lab}"                       # cluster name
: "${API_PORT:=6443}"                     # Kubernetes API port on your Mac
KIND_NET="kind"                           # Docker network shared by kind and Jenkins (fixed by kind)

# --- Jenkins (runs as a normal Docker container, NOT in the cluster) ---
: "${JENKINS_CT:=lab-jenkins}"            # container name
: "${JENKINS_IMG:=lab-jenkins:latest}"    # image name
: "${JENKINS_PORT:=8080}"                 # port on your Mac
: "${JENKINS_USER:=admin}"
: "${JENKINS_PASS:=admin123}"             # lab only, never reuse
: "${JENKINS_HEAP:=1g}"                   # Java max heap
: "${JENKINS_HOME_DIR:=${LAB_DIR}/jenkins_wp}"   # bind-mounted to /var/jenkins_home

# --- ArgoCD (in the cluster) ---
: "${ARGOCD_PORT:=8081}"                  # port on your Mac
: "${ARGOCD_NODEPORT:=30080}"             # port on the kind node (ArgoCD service)
: "${ARGOCD_USER:=admin}"
: "${DEPLOY_SAMPLE_APP:=true}"            # deploy the demo apps (podinfo + hello-web) through ArgoCD

# --- GitOps (local folders instead of GitHub) ---
: "${GITOPS_DIR:=${LAB_DIR}/gitops}"             # YOU edit this folder: app manifests + values files
: "${GITOPS_REPO_DIR:=${LAB_DIR}/.lab-git}"      # generated git snapshot of GITOPS_DIR (do not edit)
GIT_SERVER_URL="git://lab-git.lab-git.svc.cluster.local/gitops"   # how ArgoCD reaches that snapshot

# --- Monitoring (in the cluster) ---
: "${GRAFANA_PORT:=8082}";      : "${GRAFANA_NODEPORT:=30082}"
: "${PROMETHEUS_PORT:=8083}";   : "${PROMETHEUS_NODEPORT:=30083}"
: "${ALERTMANAGER_PORT:=8084}"; : "${ALERTMANAGER_NODEPORT:=30084}"
: "${GRAFANA_USER:=admin}"
: "${GRAFANA_PASS:=admin123}"             # lab only, never reuse
: "${SPARE_PORT:=9090}";        : "${SPARE_NODEPORT:=30090}"

# Names kind derives from the cluster name.
NODE="${CLUSTER}-control-plane"           # Docker container kind creates
CTX="kind-${CLUSTER}"                     # kubectl context kind creates

# Fail early on a typo like ARGOCD_PORT=80a1.
validate_settings() {
  local v
  for v in API_PORT JENKINS_PORT ARGOCD_PORT ARGOCD_NODEPORT GRAFANA_PORT GRAFANA_NODEPORT \
           PROMETHEUS_PORT PROMETHEUS_NODEPORT ALERTMANAGER_PORT ALERTMANAGER_NODEPORT \
           SPARE_PORT SPARE_NODEPORT; do
    [[ "${!v}" =~ ^[0-9]+$ ]] && (( ${!v} >= 1 && ${!v} <= 65535 )) \
      || { printf 'ERROR: %s must be a port number (1-65535), got "%s"\n' "$v" "${!v}" >&2; exit 1; }
  done
  [[ "$CLUSTER" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || { printf 'ERROR: CLUSTER must be lowercase letters, digits and dashes, got "%s"\n' "$CLUSTER" >&2; exit 1; }
}
validate_settings

# ---------------------------------------------------------------------------
# 2. PRETTY OUTPUT HELPERS
# ---------------------------------------------------------------------------
# ANSI colour codes. Printing them makes the terminal text coloured.
BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'; MAGENTA=$'\033[1;35m'; CYAN=$'\033[1;36m'

log()  { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }
warn() { printf '%sWARN:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# If anything fails unexpectedly, say which line broke.
trap 'die "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

# ---------------------------------------------------------------------------
# 3. PREREQUISITES
# ---------------------------------------------------------------------------

# Install any missing CLI tool with Homebrew.
ensure_tools() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script is written for macOS."
  [[ "$(uname -m)" == "arm64"  ]] || warn "Not Apple Silicon (arm64); continuing anyway."

  # Make sure `brew` is on PATH (Apple Silicon and Intel locations).
  if ! command -v brew >/dev/null 2>&1; then
    if   [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew    ]]; then eval "$(/usr/local/bin/brew shellenv)"
    else die "Homebrew not found. Install it from https://brew.sh and re-run."
    fi
  fi

  # "command:brew-formula" pairs.
  local pair tool formula
  for pair in kind:kind kubectl:kubernetes-cli helm:helm k9s:k9s argocd:argocd; do
    tool="${pair%%:*}"; formula="${pair##*:}"
    if ! command -v "$tool" >/dev/null 2>&1; then
      log "Installing ${formula}..."
      brew install "$formula"
    fi
  done
}

# Make sure the Docker daemon is running; try to open the app if it is not.
ensure_docker() {
  if docker info >/dev/null 2>&1; then return 0; fi
  command -v docker >/dev/null 2>&1 || die "docker CLI not found. Install Docker Desktop or OrbStack."

  log "Docker is not running, starting it..."
  if   [[ -d "/Applications/Docker.app"   ]]; then open -a Docker
  elif [[ -d "/Applications/OrbStack.app" ]]; then open -a OrbStack
  else die "Start your Docker runtime manually and re-run."
  fi

  local i
  for i in $(seq 1 90); do            # wait up to 3 minutes
    docker info >/dev/null 2>&1 && { log "Docker is up."; return 0; }
    sleep 2
  done
  die "Docker did not become ready within 3 minutes."
}

# Warn (do not fail) if Docker has too little memory for the whole lab.
check_docker_resources() {
  local mem_bytes
  mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  if [[ "$mem_bytes" =~ ^[0-9]+$ ]] && (( mem_bytes < 7500000000 )); then
    warn "Docker has less than ~8 GB RAM. Jenkins + Prometheus + Grafana + ArgoCD want 8-10 GB."
    warn "Raise it in Docker Desktop > Settings > Resources."
  fi
}

port_in_use()    { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; }

# ---------------------------------------------------------------------------
# 4. CONFIG FILES  (generated, so the script is fully self-contained)
# ---------------------------------------------------------------------------
write_configs() {
  mkdir -p "$LAB_DIR" "${LAB_DIR}/jenkins" "$JENKINS_HOME_DIR"

  # ----- kind cluster -------------------------------------------------------
  # extraPortMappings = "open a door" from your Mac to a NodePort in the cluster.
  # Left number (containerPort) is the NodePort, right (hostPort) is on your Mac.
  cat > "${LAB_DIR}/kind-config.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER}
networking:
  apiServerAddress: "127.0.0.1"
  apiServerPort: ${API_PORT}              # pinned so kubeconfig survives Docker restarts
nodes:
  - role: control-plane
    extraMounts:
      # makes the local git snapshot visible inside the kind node at /lab/git
      - hostPath: ${GITOPS_REPO_DIR}
        containerPath: /lab/git
    extraPortMappings:
      - containerPort: ${ARGOCD_NODEPORT}       # ArgoCD
        hostPort: ${ARGOCD_PORT}
        listenAddress: "127.0.0.1"
        protocol: TCP
      - containerPort: ${GRAFANA_NODEPORT}       # Grafana
        hostPort: ${GRAFANA_PORT}
        listenAddress: "127.0.0.1"
        protocol: TCP
      - containerPort: ${PROMETHEUS_NODEPORT}       # Prometheus
        hostPort: ${PROMETHEUS_PORT}
        listenAddress: "127.0.0.1"
        protocol: TCP
      - containerPort: ${ALERTMANAGER_NODEPORT}       # Alertmanager
        hostPort: ${ALERTMANAGER_PORT}
        listenAddress: "127.0.0.1"
        protocol: TCP
      - containerPort: ${SPARE_NODEPORT}       # spare for your own apps
        hostPort: ${SPARE_PORT}
        listenAddress: "127.0.0.1"
        protocol: TCP
EOF

  # ----- monitoring (kube-prometheus-stack Helm values) ---------------------
  cat > "${LAB_DIR}/monitoring-values.yaml" <<EOF
# Alertmanager: kept small, exposed on a NodePort so you can open its UI.
alertmanager:
  enabled: true
  service:
    type: NodePort
    nodePort: ${ALERTMANAGER_NODEPORT}

# node-exporter fails on kind inside Docker on macOS (mount propagation)
nodeExporter:
  enabled: false

# kind control-plane components bind to localhost; these targets would just be red
kubeEtcd:
  enabled: false
kubeScheduler:
  enabled: false
kubeControllerManager:
  enabled: false
kubeProxy:
  enabled: false

grafana:
  adminUser: ${GRAFANA_USER}
  adminPassword: ${GRAFANA_PASS}
  service:
    type: NodePort
    nodePort: ${GRAFANA_NODEPORT}
  persistence:
    enabled: true
    type: pvc
    size: 2Gi

prometheus:
  service:
    type: NodePort
    nodePort: ${PROMETHEUS_NODEPORT}
  prometheusSpec:
    retention: 3d
    # scrape every ServiceMonitor/PodMonitor in the cluster (e.g. ArgoCD's)
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    resources:
      requests:
        cpu: 200m
        memory: 400Mi
      limits:
        memory: 1Gi
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi
EOF

  # ----- argocd (Helm values) ----------------------------------------------
  cat > "${LAB_DIR}/argocd-values.yaml" <<EOF
configs:
  params:
    server.insecure: true          # plain HTTP, fine for a localhost lab
server:
  service:
    type: NodePort
    nodePortHttp: ${ARGOCD_NODEPORT}
  metrics:                         # expose metrics so Prometheus scrapes ArgoCD
    enabled: true
    serviceMonitor:
      enabled: true
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
repoServer:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
EOF

  # ----- Jenkins image: Dockerfile, plugin list, config-as-code -------------
  # Quoted 'EOF' = nothing is expanded by bash, the text is written as-is.
  cat > "${LAB_DIR}/jenkins/Dockerfile" <<'EOF'
FROM jenkins/jenkins:lts-jdk17
USER root

ARG DOCKER_VERSION=27.3.1
ARG HELM_VERSION=v3.16.2

# CLI tools pipelines can use:
#   docker  - talks to the Mac's Docker daemon through the mounted socket
#   kubectl - talks to the kind cluster
#   helm    - installs charts into the kind cluster
#   argocd  - talks to ArgoCD (sync apps from a pipeline)
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates jq \
 && ARCH="$(dpkg --print-architecture)" \
 && case "$ARCH" in \
      arm64) DARCH=aarch64 ;; \
      amd64) DARCH=x86_64 ;; \
      *) echo "unsupported arch: $ARCH" && exit 1 ;; \
    esac \
 && curl -fsSL "https://download.docker.com/linux/static/stable/${DARCH}/docker-${DOCKER_VERSION}.tgz" \
      | tar -xz --strip-components=1 -C /usr/local/bin docker/docker \
 && KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" \
 && curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
      | tar -xz --strip-components=1 -C /usr/local/bin "linux-${ARCH}/helm" \
 && curl -fsSL -o /usr/local/bin/argocd "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${ARCH}" \
 && chmod +x /usr/local/bin/argocd \
 && rm -rf /var/lib/apt/lists/*

# Install plugins at build time so Jenkins starts ready to use.
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Configuration as Code: Jenkins configures itself from this file on boot.
COPY casc.yaml /usr/share/jenkins/casc.yaml
ENV CASC_JENKINS_CONFIG=/usr/share/jenkins/casc.yaml

# Runs as root on purpose (lab only) so it can use the mounted docker socket.
EOF

  cat > "${LAB_DIR}/jenkins/plugins.txt" <<'EOF'
configuration-as-code
workflow-aggregator
git
credentials-binding
docker-workflow
pipeline-stage-view
timestamper
ws-cleanup
EOF

  # The \${...} below is escaped so bash leaves it alone; Jenkins fills it in
  # from the container environment variables.
  cat > "${LAB_DIR}/jenkins/casc.yaml" <<EOF
jenkins:
  systemMessage: "Local DevOps lab"
  numExecutors: 2
  securityRealm:
    local:
      allowsSignup: false
      users:
        - id: "\${JENKINS_ADMIN_ID}"
          password: "\${JENKINS_ADMIN_PASSWORD}"
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false
unclassified:
  location:
    url: "http://localhost:${JENKINS_PORT}/"
EOF

  # ----- GitOps folder with demo apps (created once, never overwritten) -----
  seed_gitops
}

# Create the local GitOps folder with demo apps. Existing files are NEVER
# overwritten, so your edits are safe.
#
# ONE FOLDER PER APPLICATION. Everything an app needs lives in its own folder:
#   gitops/apps/<app-name>/
# The folder name becomes the ArgoCD app name AND the Kubernetes namespace.
# ArgoCD detects the type by what is inside the folder:
#   Chart.yaml + values.yaml   -> Helm app (values.yaml is your values file)
#   plain *.yaml files         -> plain Kubernetes manifests
# To add an app: create a folder, then run `lab sync`. No other file is needed.
seed_gitops() {
  mkdir -p "${GITOPS_DIR}/apps/podinfo" "${GITOPS_DIR}/apps/hello-web" "$GITOPS_REPO_DIR"

  # write the file only if it does not exist yet; content comes from stdin
  seed_file() { [[ -e "$1" ]] || cat > "$1"; }

  seed_file "${GITOPS_DIR}/README.md" <<'EOF'
# GitOps folder

This local folder is the "git repo" ArgoCD deploys from. No GitHub needed.

    apps/
      <app-name>/      one folder per application (folder name = app name = namespace)
        ...            everything that app needs

What goes inside an app folder:

    Helm app           Chart.yaml (wraps a public chart) + values.yaml (your settings)
    Plain YAML app     any number of *.yaml Kubernetes files

Workflow: edit files here, then run `lab sync`. ArgoCD picks the change up.
To add an app: create `apps/<name>/`, put files in it, run `lab sync`.
To remove an app: delete its folder, run `lab sync`.
Examples: apps/podinfo (Helm) and apps/hello-web (plain YAML).
EOF

  # --- demo app 1 (Helm): a public chart, wrapped in a tiny local chart so its
  #     values file lives in the same folder ---
  seed_file "${GITOPS_DIR}/apps/podinfo/Chart.yaml" <<'EOF'
apiVersion: v2
name: podinfo
version: 0.1.0
dependencies:
  - name: podinfo                 # the real chart, downloaded by ArgoCD
    version: 6.x.x
    repository: https://stefanprodan.github.io/podinfo
EOF

  seed_file "${GITOPS_DIR}/apps/podinfo/values.yaml" <<EOF
# Your settings for podinfo. Everything goes under the "podinfo:" key,
# because the chart above is a dependency of this wrapper chart.
# Edit, run \`lab sync\`, watch ArgoCD roll it out.
podinfo:
  replicaCount: 1
  ui:
    message: "Hello from DevOps Lab"
    color: "#6d8bff"
  service:
    type: NodePort
    nodePort: ${SPARE_NODEPORT}     # open it at http://localhost:${SPARE_PORT}
EOF

  # --- demo app 2 (plain YAML) ---
  seed_file "${GITOPS_DIR}/apps/hello-web/hello-web.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: hello-web-page
data:
  index.html: |
    <h1>hello-web</h1><p>Deployed by ArgoCD from a local folder.</p>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-web
spec:
  replicas: 2
  selector:
    matchLabels: {app: hello-web}
  template:
    metadata:
      labels: {app: hello-web}
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports: [{containerPort: 80}]
          volumeMounts:
            - {name: page, mountPath: /usr/share/nginx/html}
      volumes:
        - name: page
          configMap: {name: hello-web-page}
---
apiVersion: v1
kind: Service
metadata:
  name: hello-web
spec:
  selector: {app: hello-web}
  ports: [{port: 80, targetPort: 80}]
EOF
}

# Add a `lab` shortcut to ~/.zshrc so you can type `lab start` from anywhere.
install_alias() {
  chmod +x "$SELF"
  local rc="${HOME}/.zshrc"
  touch "$rc"
  if ! grep -q "alias lab=" "$rc"; then
    echo "alias lab='${SELF}'" >> "$rc"
    log "Added alias 'lab' to ~/.zshrc (run: source ~/.zshrc)"
  fi
}

# ---------------------------------------------------------------------------
# 5. CLUSTER HELPERS
# ---------------------------------------------------------------------------
wait_for_api() {
  log "Waiting for the Kubernetes API..."
  local i
  for i in $(seq 1 60); do
    if kubectl --context "$CTX" get nodes >/dev/null 2>&1; then return 0; fi
    sleep 3
  done
  die "Kubernetes API did not come up in time."
}

# verify_nodeport <namespace> <service> <expected nodePort>
# Returns 0 when the service is a NodePort service using the expected port.
verify_nodeport() {
  local ns="$1" svc="$2" want="$3" type nps
  type="$(kubectl --context "$CTX" -n "$ns" get svc "$svc" -o jsonpath='{.spec.type}' 2>/dev/null || true)"
  nps="$(kubectl --context "$CTX" -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[*].nodePort}' 2>/dev/null || true)"
  if [[ "$type" == "NodePort" && " ${nps} " == *" ${want} "* ]]; then
    log "${ns}/${svc}: NodePort ${want} OK"
    return 0
  fi
  return 1
}

# If the ArgoCD service is not on the expected NodePort, patch it.
ensure_argocd_nodeport() {
  if ! verify_nodeport argocd argocd-server "$ARGOCD_NODEPORT"; then
    warn "argocd-server is not NodePort ${ARGOCD_NODEPORT}, forcing it..."
    kubectl --context "$CTX" -n argocd patch svc argocd-server \
      -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"http\",\"port\":80,\"nodePort\":${ARGOCD_NODEPORT}}]}}"
  fi
}

check_monitoring_nodeports() {
  verify_nodeport monitoring monitoring-grafana "$GRAFANA_NODEPORT" \
    || warn "Grafana service is not NodePort ${GRAFANA_NODEPORT}; check: kubectl -n monitoring get svc"
  verify_nodeport monitoring monitoring-kube-prometheus-prometheus "$PROMETHEUS_NODEPORT" \
    || warn "Prometheus service is not NodePort ${PROMETHEUS_NODEPORT}; check: kubectl -n monitoring get svc"
  verify_nodeport monitoring monitoring-kube-prometheus-alertmanager "$ALERTMANAGER_NODEPORT" \
    || warn "Alertmanager service is not NodePort ${ALERTMANAGER_NODEPORT}; check: kubectl -n monitoring get svc"
}

wait_for_cluster_workloads() {
  log "Waiting for cluster pods (non-fatal, can take a few minutes)..."
  kubectl --context "$CTX" -n monitoring wait --for=condition=Available deployment --all --timeout=300s \
    || warn "Monitoring is not fully ready yet; check with: lab status"
  kubectl --context "$CTX" -n argocd wait --for=condition=Available deployment --all --timeout=300s \
    || warn "ArgoCD is not fully ready yet; check with: lab status"
}

# ---------------------------------------------------------------------------
# 6. ARGOCD <-> CLUSTER <-> JENKINS WIRING
# ---------------------------------------------------------------------------

# Read ArgoCD's generated admin password (empty if the secret was deleted).
argocd_password() {
  kubectl --context "$CTX" --request-timeout=5s -n argocd get secret argocd-initial-admin-secret \
    -o go-template='{{.data.password | base64decode}}' 2>/dev/null || true
}

# Log the argocd CLI in from your Mac AND from inside the Jenkins container,
# then show which clusters ArgoCD manages. ArgoCD registers the cluster it runs
# in automatically as "in-cluster" (https://kubernetes.default.svc).
connect_argocd() {
  local pw i
  pw="$(argocd_password)"
  if [[ -z "$pw" ]]; then
    warn "ArgoCD initial admin secret not found, skipping CLI login (you probably changed the password)."
    return 0
  fi

  log "Waiting for the ArgoCD API..."
  for i in $(seq 1 40); do
    curl -fs -o /dev/null -m 3 "http://127.0.0.1:${ARGOCD_PORT}/healthz" && break
    sleep 3
  done

  # 1) from your Mac, through the published port
  if argocd login "localhost:${ARGOCD_PORT}" --username "$ARGOCD_USER" --password "$pw" \
       --plaintext --grpc-web >/dev/null 2>&1; then
    log "argocd CLI on your Mac is logged in (localhost:${ARGOCD_PORT})."
    argocd cluster list --grpc-web 2>/dev/null | sed 's/^/   /' || true
  else
    warn "argocd CLI login from the Mac failed; try: argocd login localhost:${ARGOCD_PORT} --plaintext --grpc-web"
  fi

  # 2) from Jenkins, over the shared Docker network (straight to the NodePort)
  if jenkins_running && docker exec "$JENKINS_CT" argocd login "${NODE}:${ARGOCD_NODEPORT}" \
       --username "$ARGOCD_USER" --password "$pw" --plaintext --grpc-web >/dev/null 2>&1; then
    log "argocd CLI inside Jenkins is logged in (${NODE}:${ARGOCD_NODEPORT})."
  else
    warn "argocd CLI login from the Jenkins container failed (is Jenkins running?)."
  fi
}

# ---- GitOps from local folders -------------------------------------------
# ArgoCD can only read git repos, not plain folders. So the lab:
#   1. copies your GITOPS_DIR into a small git repo (GITOPS_REPO_DIR) on every sync,
#   2. mounts that repo into the kind node,
#   3. runs a tiny "git daemon" pod ("lab-git") that serves it inside the cluster.
# ArgoCD then clones git://lab-git.lab-git.svc.cluster.local/gitops like any repo.

# Copy the folder into the snapshot repo and commit if anything changed.
sync_gitops() {
  [[ -d "$GITOPS_DIR" ]] || seed_gitops
  local repo="${GITOPS_REPO_DIR}/gitops"
  mkdir -p "$repo"
  [[ -d "${repo}/.git" ]] || git -C "$repo" init -q -b main
  rsync -a --delete --exclude '.git' "${GITOPS_DIR}/" "${repo}/"
  git -C "$repo" add -A
  if ! git -C "$repo" diff --cached --quiet; then
    git -C "$repo" -c user.name="DevOps Lab" -c user.email="lab@localhost" \
      commit -q -m "lab sync $(date '+%F %T')"
    log "GitOps folder snapshot updated."
  fi
}

# Ask ArgoCD to re-read the repo right now instead of waiting for its 3 min poll.
refresh_gitops() {
  kubectl --context "$CTX" -n argocd annotate applications --all \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  # makes the ApplicationSet re-scan gitops/apps/ for new or removed folders
  kubectl --context "$CTX" -n argocd annotate applicationset lab-apps \
    argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null 2>&1 || true
}

# The in-cluster git server that serves the snapshot repo.
install_git_server() {
  log "Installing the in-cluster git server (lab-git)..."
  kubectl --context "$CTX" apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: lab-git
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lab-git
  namespace: lab-git
spec:
  replicas: 1
  selector:
    matchLabels: {app: lab-git}
  template:
    metadata:
      labels: {app: lab-git}
    spec:
      containers:
        - name: git-daemon
          image: alpine/git:latest
          command: ["sh", "-c"]
          args:
            - >-
              apk add --no-cache git-daemon >/dev/null &&
              git config --global --add safe.directory '*' &&
              exec git daemon --reuseaddr --export-all --base-path=/repos
              --listen=0.0.0.0 --port=9418 /repos
          ports: [{containerPort: 9418}]
          readinessProbe:
            tcpSocket: {port: 9418}
            initialDelaySeconds: 10
            periodSeconds: 5
          volumeMounts:
            - {name: repos, mountPath: /repos, readOnly: true}
      volumes:
        - name: repos
          hostPath: {path: /lab/git, type: Directory}
---
apiVersion: v1
kind: Service
metadata:
  name: lab-git
  namespace: lab-git
spec:
  selector: {app: lab-git}
  ports: [{port: 9418, targetPort: 9418}]
EOF
  kubectl --context "$CTX" -n lab-git rollout status deploy/lab-git --timeout=180s \
    || warn "lab-git is not ready yet; check: kubectl -n lab-git get pods"
}

# Connect ArgoCD to the local repo and start the app generator.
deploy_gitops() {
  install_git_server
  log "Registering the local repo in ArgoCD and creating the app generator (lab-apps)..."
  # An ApplicationSet turns every folder under gitops/apps/ into an ArgoCD app.
  kubectl --context "$CTX" apply -f - >/dev/null <<EOF || warn "Could not register the GitOps repo."
apiVersion: v1
kind: Secret
metadata:
  name: lab-gitops-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  name: lab-gitops
  url: ${GIT_SERVER_URL}
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: lab-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: ${GIT_SERVER_URL}
        revision: HEAD
        directories:
          - path: apps/*            # one app per folder
  template:
    metadata:
      name: '{{ .path.basename }}'  # folder name = app name
    spec:
      project: default
      source:
        repoURL: ${GIT_SERVER_URL}
        targetRevision: HEAD
        path: '{{ .path.path }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{ .path.basename }}'   # folder name = namespace
      syncPolicy:
        automated: {prune: true, selfHeal: true}
        syncOptions: [CreateNamespace=true]
EOF
}

# ---------------------------------------------------------------------------
# 7. JENKINS (standalone container) HELPERS
# ---------------------------------------------------------------------------
jenkins_exists()  { docker container inspect "$JENKINS_CT" >/dev/null 2>&1; }
jenkins_running() {
  [[ "$(docker container inspect -f '{{.State.Running}}' "$JENKINS_CT" 2>/dev/null || echo false)" == "true" ]]
}

build_jenkins_image() {
  log "Building Jenkins image (first build takes a few minutes)..."
  docker build -t "$JENKINS_IMG" "${LAB_DIR}/jenkins"
}

create_jenkins() {
  docker network inspect "$KIND_NET" >/dev/null 2>&1 \
    || die "Docker network '${KIND_NET}' not found. Create the cluster first (lab up)."
  if port_in_use "$JENKINS_PORT"; then
    die "Port ${JENKINS_PORT} is already in use on your Mac. Free it, or change JENKINS_PORT in lab.sh."
  fi

  # Jenkins-only folder on your Mac: the container's /var/jenkins_home appears here,
  # so you can open its files in Finder/VS Code instead of logging into the container.
  mkdir -p "$JENKINS_HOME_DIR"

  # Mount the Docker socket so pipelines can run `docker build`.
  local sock_args=()
  if [[ -S /var/run/docker.sock ]]; then
    sock_args=(-v /var/run/docker.sock:/var/run/docker.sock)
  else
    warn "/var/run/docker.sock not found: Jenkins will not be able to run docker builds."
  fi

  log "Creating Jenkins container '${JENKINS_CT}' (data: ${JENKINS_HOME_DIR})..."
  #  --network kind                join the cluster's network, so Jenkins can reach the API
  #  -p 127.0.0.1:8080:8080        Jenkins UI, only reachable from your Mac
  #  -v jenkins_wp:/var/jenkins_home   your local folder IS Jenkins' home directory
  docker run -d \
    --name "$JENKINS_CT" \
    --hostname "$JENKINS_CT" \
    --network "$KIND_NET" \
    -p "127.0.0.1:${JENKINS_PORT}:8080" \
    -v "${JENKINS_HOME_DIR}:/var/jenkins_home" \
    ${sock_args[@]+"${sock_args[@]}"} \
    -e "JENKINS_ADMIN_ID=${JENKINS_USER}" \
    -e "JENKINS_ADMIN_PASSWORD=${JENKINS_PASS}" \
    -e "JAVA_OPTS=-Djenkins.install.runSetupWizard=false -Xmx${JENKINS_HEAP}" \
    -e "KUBECONFIG=/var/jenkins_home/.kube/config" \
    -e "ARGOCD_SERVER=${NODE}:${ARGOCD_NODEPORT}" \
    -e "ARGOCD_OPTS=--plaintext --grpc-web" \
    "$JENKINS_IMG" >/dev/null
}

# Make sure the container exists (recreated if the image changed) and is running.
reconcile_jenkins() {
  if jenkins_exists; then
    local cur want
    cur="$(docker container inspect -f '{{.Image}}' "$JENKINS_CT")"
    want="$(docker image inspect -f '{{.Id}}' "$JENKINS_IMG")"
    if [[ "$cur" != "$want" ]]; then
      log "Jenkins image changed, recreating container (your data folder is kept)..."
      docker rm -f "$JENKINS_CT" >/dev/null
      create_jenkins
    elif ! jenkins_running; then
      docker start "$JENKINS_CT" >/dev/null
    fi
  else
    create_jenkins
  fi
}

# Give Jenkins a kubeconfig that reaches the cluster over the shared Docker
# network ("--internal" swaps 127.0.0.1:${API_PORT} for ${NODE}:6443).
sync_jenkins_kubeconfig() {
  local f="${LAB_DIR}/.jenkins-kubeconfig"
  kind get kubeconfig --name "$CLUSTER" --internal > "$f"
  chmod 600 "$f"
  docker exec "$JENKINS_CT" mkdir -p /var/jenkins_home/.kube
  docker cp "$f" "${JENKINS_CT}:/var/jenkins_home/.kube/config"
  rm -f "$f"
  if docker exec "$JENKINS_CT" kubectl get nodes >/dev/null 2>&1; then
    log "Jenkins container can reach the cluster (kubectl OK)."
  else
    warn "Jenkins container could not reach the cluster yet; retry: lab start"
  fi
}

wait_for_jenkins() {
  log "Waiting for Jenkins (first boot can take 2-4 min)..."
  local i code
  for i in $(seq 1 120); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${JENKINS_PORT}/login" || true)"
    if [[ "$code" == "200" ]]; then log "Jenkins is up."; return 0; fi
    sleep 3
  done
  warn "Jenkins is not answering yet; check logs: docker logs -f ${JENKINS_CT}"
  return 0
}

# ---------------------------------------------------------------------------
# 8. SUMMARY  (printed at the end of EVERY command)
# ---------------------------------------------------------------------------

# http_state <url>  ->  prints a coloured "UP" / "DOWN" marker
http_state() {
  local code
  code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$1" 2>/dev/null || true)"
  case "$code" in
    2*|3*|401|403) printf '%s● UP  %s' "$GREEN" "$RESET" ;;
    *)             printf '%s● DOWN%s' "$RED" "$RESET" ;;
  esac
}

# One row of the table:  name | url | login | status | where it runs
row() {
  printf ' %s%-13s%s %-24s %-27s ' "$BOLD" "$1" "$RESET" "$2" "$3"
  http_state "$4"
  printf '  %s%s%s\n' "$DIM" "$5" "$RESET"
}

# The URL + credentials table.
print_banner() {
  local pw
  pw="$(argocd_password)"
  [[ -n "$pw" ]] || pw="(see lab status)"

  printf '\n%s╔══════════════════════════════════════════════════════════════════════════════╗%s\n' "$MAGENTA" "$RESET"
  printf '%s║%s  %sDevOps Lab v%s%s   Jenkins · ArgoCD · Prometheus · Grafana · kind                %s║%s\n' \
    "$MAGENTA" "$RESET" "$BOLD" "$LAB_VERSION" "$RESET" "$MAGENTA" "$RESET"
  printf '%s╚══════════════════════════════════════════════════════════════════════════════╝%s\n' "$MAGENTA" "$RESET"
  printf ' %s%-13s %-24s %-27s %-7s  %s%s\n' "$DIM" "TOOL" "URL" "LOGIN" "STATUS" "RUNS IN" "$RESET"
  row "Jenkins"      "http://localhost:${JENKINS_PORT}"      "${JENKINS_USER} / ${JENKINS_PASS}"  "http://127.0.0.1:${JENKINS_PORT}/login"        "Docker container"
  row "ArgoCD"       "http://localhost:${ARGOCD_PORT}"       "${ARGOCD_USER} / ${pw}"             "http://127.0.0.1:${ARGOCD_PORT}/healthz"       "kind cluster"
  row "Grafana"      "http://localhost:${GRAFANA_PORT}"      "${GRAFANA_USER} / ${GRAFANA_PASS}"  "http://127.0.0.1:${GRAFANA_PORT}/api/health"   "kind cluster"
  row "Prometheus"   "http://localhost:${PROMETHEUS_PORT}"   "(no login)"                         "http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy" "kind cluster"
  row "Alertmanager" "http://localhost:${ALERTMANAGER_PORT}" "(no login)"                         "http://127.0.0.1:${ALERTMANAGER_PORT}/-/healthy" "kind cluster"
  if [[ "$DEPLOY_SAMPLE_APP" == "true" ]]; then
    row "Podinfo demo" "http://localhost:${SPARE_PORT}" "(no login)" "http://127.0.0.1:${SPARE_PORT}/healthz" "kind cluster (via ArgoCD)"
  else
    printf ' %s%-13s%s %-24s\n' "$BOLD" "Spare" "$RESET" "localhost:${SPARE_PORT}  ->  NodePort ${SPARE_NODEPORT}"
  fi
  printf '%s──────────────────────────────────────────────────────────────────────────────%s\n' "$MAGENTA" "$RESET"
  printf ' %sK8s API%s      https://127.0.0.1:${API_PORT}   (context: %s)\n' "$BOLD" "$RESET" "$CTX"
  printf ' %sJenkins data%s %s\n' "$BOLD" "$RESET" "$JENKINS_HOME_DIR"
  printf ' %sGitOps folder%s %s   (edit, then: lab sync)\n' "$BOLD" "$RESET" "$GITOPS_DIR"
  printf ' %sConfigs%s      %s\n' "$BOLD" "$RESET" "$LAB_DIR"
  printf '%s──────────────────────────────────────────────────────────────────────────────%s\n\n' "$MAGENTA" "$RESET"
}

# Containers, nodes, pods, services and then the banner.
print_summary() {
  printf '\n%s━━ Docker containers ━━%s\n' "$CYAN" "$RESET"
  docker ps -a --filter "name=^${JENKINS_CT}$" --filter "name=^${NODE}$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true

  # Only query Kubernetes if the cluster container is actually running.
  if [[ "$(docker container inspect -f '{{.State.Running}}' "$NODE" 2>/dev/null || echo false)" == "true" ]] \
     && kubectl --context "$CTX" --request-timeout=5s get nodes >/dev/null 2>&1; then
    printf '\n%s━━ Nodes ━━%s\n' "$CYAN" "$RESET"
    kubectl --context "$CTX" get nodes || true
    printf '\n%s━━ Pods ━━%s\n' "$CYAN" "$RESET"
    kubectl --context "$CTX" get pods -A 2>/dev/null | grep -E 'NAMESPACE|argocd|monitoring|lab-git|podinfo|hello-web' || true
    printf '\n%s━━ NodePort services ━━%s\n' "$CYAN" "$RESET"
    kubectl --context "$CTX" get svc -A 2>/dev/null | grep -E 'NAMESPACE|NodePort' || true
    printf '\n%s━━ ArgoCD applications ━━%s\n' "$CYAN" "$RESET"
    kubectl --context "$CTX" -n argocd get applications 2>/dev/null || echo "none yet"
  else
    printf '\n%sCluster is not running. Start it with: lab start%s\n' "$YELLOW" "$RESET"
  fi
  print_banner
}

# ---------------------------------------------------------------------------
# 9. COMMANDS
# ---------------------------------------------------------------------------
cmd_up() {
  ensure_tools
  ensure_docker
  check_docker_resources
  write_configs
  sync_gitops          # the snapshot folder must exist before kind mounts it
  install_alias

  if cluster_exists; then
    log "Cluster '${CLUSTER}' already exists, making sure it is running..."
    docker start "$NODE" >/dev/null 2>&1 || true
    # kind cannot change port mappings of a live cluster. Detect an old layout.
    if ! docker port "$NODE" "${ARGOCD_NODEPORT}/tcp" 2>/dev/null | grep -q ":${ARGOCD_PORT}$"; then
      die "Existing cluster uses an older port layout. Run './lab.sh destroy' then './lab.sh up'."
    fi
    if ! docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$NODE" 2>/dev/null | grep -q '/lab/git'; then
      die "Existing cluster was created before local GitOps support. Run './lab.sh destroy' then './lab.sh up'."
    fi
  else
    local p
    for p in "$API_PORT" "$ARGOCD_PORT" "$GRAFANA_PORT" "$PROMETHEUS_PORT" "$ALERTMANAGER_PORT" "$SPARE_PORT"; do
      if port_in_use "$p"; then
        die "Port ${p} is already in use on your Mac. Free it, or edit the ports at the top of lab.sh."
      fi
    done
    log "Creating kind cluster '${CLUSTER}'..."
    kind create cluster --config "${LAB_DIR}/kind-config.yaml" --wait 180s
  fi

  kubectl config use-context "$CTX" >/dev/null
  wait_for_api

  log "Adding Helm repos..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm repo update >/dev/null

  # Monitoring first: it installs the ServiceMonitor CRDs that ArgoCD metrics need.
  log "Installing Prometheus + Grafana + Alertmanager (kube-prometheus-stack)..."
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --kube-context "$CTX" -n monitoring --create-namespace \
    -f "${LAB_DIR}/monitoring-values.yaml" \
    --wait --timeout 10m \
    || warn "Monitoring install did not finish within the timeout; it may still be starting."
  kubectl --context "$CTX" get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1 \
    || die "Prometheus CRDs are missing; monitoring install failed. Check: helm -n monitoring status monitoring"
  check_monitoring_nodeports

  log "Installing ArgoCD..."
  helm upgrade --install argocd argo/argo-cd \
    --kube-context "$CTX" -n argocd --create-namespace \
    -f "${LAB_DIR}/argocd-values.yaml" \
    --wait --timeout 10m
  ensure_argocd_nodeport

  build_jenkins_image
  reconcile_jenkins
  sync_jenkins_kubeconfig
  wait_for_jenkins

  # Connect ArgoCD to the cluster, to your Mac's CLI and to Jenkins.
  connect_argocd
  if [[ "$DEPLOY_SAMPLE_APP" == "true" ]]; then deploy_gitops; fi

  log "Setup complete."
  print_summary
  cat <<EOF
Next:
  source ~/.zshrc        # enables the 'lab' alias
  k9s                    # browse the cluster
  lab verify             # see where everything runs
  lab stop / lab start   # daily use

Jenkins pipelines can use 'agent any' and call docker, kubectl, helm and argocd.
EOF
}

cmd_start() {
  ensure_docker
  cluster_exists || die "Cluster '${CLUSTER}' not found. Run: lab up"
  log "Starting cluster container..."
  docker start "$NODE" >/dev/null
  kubectl config use-context "$CTX" >/dev/null
  wait_for_api
  kubectl --context "$CTX" wait --for=condition=Ready node --all --timeout=180s

  log "Starting Jenkins container..."
  docker image inspect "$JENKINS_IMG" >/dev/null 2>&1 || { write_configs; build_jenkins_image; }
  reconcile_jenkins
  sync_jenkins_kubeconfig

  wait_for_cluster_workloads
  wait_for_jenkins
  connect_argocd
  if [[ "$DEPLOY_SAMPLE_APP" == "true" ]]; then sync_gitops; refresh_gitops; fi
  print_summary
}

cmd_stop() {
  ensure_docker
  log "Stopping Jenkins container..."
  docker stop "$JENKINS_CT" >/dev/null 2>&1 || true
  log "Stopping cluster container..."
  docker stop "$NODE" >/dev/null 2>&1 || true
  log "Stopped (all data preserved). Run 'lab start' to bring it back."
  print_summary
}

# Create lab.env from the example so you can start editing it.
cmd_init() {
  if [[ -f "${LAB_DIR}/lab.env" ]]; then
    log "lab.env already exists: ${LAB_DIR}/lab.env"
  else
    cp "${LAB_DIR}/lab.env.example" "${LAB_DIR}/lab.env"
    log "Created ${LAB_DIR}/lab.env. Edit it, then run: lab configs (or lab up)."
  fi
}

# Push edits from the local GitOps folder to ArgoCD.
cmd_sync() {
  ensure_docker
  cluster_exists || die "Cluster '${CLUSTER}' not found. Run: lab up"
  sync_gitops
  refresh_gitops
  log "ArgoCD was asked to refresh. Watch it: argocd app list   (or http://localhost:${ARGOCD_PORT})"
  print_summary
}

cmd_status() {
  ensure_docker
  print_summary
}

cmd_creds() {
  print_banner
}

cmd_verify() {
  ensure_docker
  cluster_exists || die "Cluster '${CLUSTER}' not found. Run: lab up"

  log "1) Two Docker containers make up the lab:"
  docker ps --filter "name=^${JENKINS_CT}$" --filter "name=^${NODE}$" \
    --format '   {{.Names}}  image={{.Image}}  status={{.Status}}'

  log "2) Inside the cluster container (containerd):"
  local out name count
  out="$(docker exec "$NODE" crictl ps 2>/dev/null || true)"
  for name in argocd-server grafana prometheus alertmanager jenkins; do
    count="$(printf '%s\n' "$out" | grep -c -E "[[:space:]]${name}[[:space:]]" || true)"
    printf '   %-14s containers running: %s\n' "$name" "$count"
  done
  echo "   (jenkins should be 0: it runs as its own Docker container)"

  log "3) Jenkins container can use docker, the cluster and ArgoCD:"
  docker exec "$JENKINS_CT" docker version --format '   docker server: {{.Server.Version}}' 2>/dev/null \
    || echo "   docker socket not available inside Jenkins"
  docker exec "$JENKINS_CT" kubectl get nodes --no-headers 2>/dev/null | sed 's/^/   /' \
    || echo "   kubectl cannot reach the cluster"
  docker exec "$JENKINS_CT" argocd cluster list 2>/dev/null | sed 's/^/   /' \
    || echo "   argocd cannot reach ArgoCD (try: lab start)"

  log "4) Jenkins data folder on your Mac is the container's home:"
  docker inspect -f '   {{range .Mounts}}{{if eq .Destination "/var/jenkins_home"}}{{.Source}} -> {{.Destination}}{{end}}{{end}}' "$JENKINS_CT" 2>/dev/null || true

  log "5) Host ports are owned by the Docker runtime:"
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
    | grep -E ":(${API_PORT}|${JENKINS_PORT}|${ARGOCD_PORT}|${GRAFANA_PORT}|${PROMETHEUS_PORT}|${ALERTMANAGER_PORT}|${SPARE_PORT}) " \
    | awk '{printf "   %-27s %s\n", $1, $9}' || true

  log "6) CLI tools on the Mac:"
  local t
  for t in kind kubectl helm k9s argocd docker; do
    printf '   %-8s %s\n' "$t" "$(command -v "$t" || echo 'not installed')"
  done
  print_summary
}

# Print exactly what `destroy` is about to remove (and what it keeps).
print_destroy_plan() {
  local purge="$1" size="empty"
  printf '\n%s━━ The following will be DESTROYED ━━%s\n' "$RED" "$RESET"

  # Docker containers
  if jenkins_exists; then
    printf '  %s✗%s Docker container  %s  (Jenkins)\n' "$RED" "$RESET" "$JENKINS_CT"
  fi
  if cluster_exists; then
    printf '  %s✗%s Docker container  %s  (the whole kind cluster)\n' "$RED" "$RESET" "$NODE"
    printf '  %s✗%s kubectl context   %s  (removed from ~/.kube/config)\n' "$RED" "$RESET" "$CTX"

    # What is inside the cluster (only if the API answers)
    if kubectl --context "$CTX" --request-timeout=5s get nodes >/dev/null 2>&1; then
      printf '  %s✗%s Helm releases:\n' "$RED" "$RESET"
      helm --kube-context "$CTX" list -A --no-headers 2>/dev/null \
        | awk '{printf "        - %s  (namespace %s)\n", $1, $2}' || true
      printf '  %s✗%s Namespaces: argocd, monitoring, lab-git, podinfo, hello-web and any you created\n' "$RED" "$RESET"
      printf '  %s✗%s Persistent data (Prometheus metrics, Grafana dashboards):\n' "$RED" "$RESET"
      kubectl --context "$CTX" get pvc -A --no-headers 2>/dev/null \
        | awk '{printf "        - %s/%s  (%s)\n", $1, $2, $5}' || true
      printf '  %s✗%s ArgoCD applications:\n' "$RED" "$RESET"
      kubectl --context "$CTX" -n argocd get applications --no-headers 2>/dev/null \
        | awk '{printf "        - %s  (%s)\n", $1, $3}' || true
    fi
  fi
  if ! jenkins_exists && ! cluster_exists; then
    printf '  (nothing is running; there is nothing to delete)\n'
  fi

  # Jenkins data folder
  if [[ -d "$JENKINS_HOME_DIR" ]]; then
    size="$(du -sh "$JENKINS_HOME_DIR" 2>/dev/null | awk '{print $1}')"
  fi
  if [[ "$purge" == "--purge" ]]; then
    printf '  %s✗%s Local folder      %s  (%s: Jenkins jobs, plugins, credentials)\n' "$RED" "$RESET" "$JENKINS_HOME_DIR" "$size"
  fi

  printf '\n%s━━ The following will be KEPT ━━%s\n' "$GREEN" "$RESET"
  if [[ "$purge" != "--purge" ]]; then
    printf '  %s✓%s Local folder      %s  (%s). Add --purge to delete it\n' "$GREEN" "$RESET" "$JENKINS_HOME_DIR" "$size"
  fi
  printf '  %s✓%s Docker image      %s  (build cache)\n' "$GREEN" "$RESET" "$JENKINS_IMG"
  printf '  %s✓%s GitOps folder     %s  (your apps and values files)\n' "$GREEN" "$RESET" "$GITOPS_DIR"
  printf '  %s✓%s Config files      %s  (kind, helm values, jenkins/)\n' "$GREEN" "$RESET" "$LAB_DIR"
  printf '  %s✓%s CLI tools         kind, kubectl, helm, k9s, argocd\n\n' "$GREEN" "$RESET"
}

cmd_destroy() {
  local purge="${1:-}"
  ensure_docker
  print_destroy_plan "$purge"
  read -r -p "Type 'yes' to destroy the items above: " ans
  [[ "$ans" == "yes" ]] || { echo "Aborted. Nothing was changed."; exit 0; }
  docker rm -f "$JENKINS_CT" >/dev/null 2>&1 || true
  kind delete cluster --name "$CLUSTER" || true
  if [[ "$purge" == "--purge" ]]; then
    log "Purging Jenkins data folder ${JENKINS_HOME_DIR}..."
    rm -rf "${JENKINS_HOME_DIR:?}"
  else
    log "Jenkins data kept in ${JENKINS_HOME_DIR} (use 'lab destroy --purge' to wipe it)."
  fi
  log "Destroyed. The Jenkins image is kept as a build cache (docker rmi ${JENKINS_IMG} to remove)."
  print_summary
}

# ---------------------------------------------------------------------------
# 10. ENTRY POINT
# ---------------------------------------------------------------------------
case "${1:-}" in
  up)      cmd_up ;;
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  creds)   cmd_creds ;;
  verify)  cmd_verify ;;
  sync)    cmd_sync ;;
  init)    cmd_init ;;
  configs) write_configs; log "Config files written to ${LAB_DIR}" ;;
  destroy) cmd_destroy "${2:-}" ;;
  *) echo "Usage: $0 {up|start|stop|status|creds|verify|sync|init|configs|destroy [--purge]}"; exit 1 ;;
esac
