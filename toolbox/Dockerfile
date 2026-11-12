FROM debian:bookworm-slim

ARG TARGETARCH
ARG KUBECTL_VERSION=v1.31.2
ARG HELM_VERSION=v3.16.3
ARG TERRAFORM_VERSION=1.9.8
ARG K3D_VERSION=v5.7.5
ARG K6_VERSION=v0.54.0

ENV DEBIAN_FRONTEND=noninteractive \
    KUBECONFIG=/root/.kube/config \
    IN_TOOLBOX=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      gnupg \
      jq \
      unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI (for k3d and multi-stage image builds via /var/run/docker.sock)
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin && \
    rm -rf /var/lib/apt/lists/*

# Install kubectl, helm, terraform, k3d, and k6 (multi-arch: amd64 & arm64)
RUN set -eux; \
    ARCH="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl; \
    chmod +x /usr/local/bin/kubectl; \
    \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" -o /tmp/helm.tar.gz; \
    tar -xzf /tmp/helm.tar.gz -C /tmp; \
    mv "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm; \
    rm -rf /tmp/helm*; \
    \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" -o /tmp/terraform.zip; \
    unzip -q /tmp/terraform.zip -d /usr/local/bin; \
    rm -f /tmp/terraform.zip; \
    \
    curl -fsSL "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-${ARCH}" -o /usr/local/bin/k3d; \
    chmod +x /usr/local/bin/k3d; \
    \
    curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${ARCH}.tar.gz" -o /tmp/k6.tar.gz; \
    tar -xzf /tmp/k6.tar.gz -C /tmp; \
    mv "/tmp/k6-${K6_VERSION}-linux-${ARCH}/k6" /usr/local/bin/k6; \
    rm -rf /tmp/k6*

WORKDIR /workspace

# The repo is bind-mounted from the host with a different owner; let git read it
RUN git config --system --add safe.directory /workspace

CMD ["sh", "-c", "sh ./scripts/00-bootstrap-cluster.sh && exec sleep infinity"]

