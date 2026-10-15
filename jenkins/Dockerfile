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
