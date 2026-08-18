# A small "control station" image: kind + kubectl + helm + docker CLI + git + make.
FROM debian:bookworm-slim

ARG KIND_VERSION=v0.29.0
ARG KUBECTL_VERSION=v1.33.1
ARG HELM_VERSION=v3.18.2

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates git make jq gnupg bash \
    && rm -rf /var/lib/apt/lists/*

# docker CLI only (no daemon) - it talks to the host daemon via the mounted socket
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
 && rm -rf /var/lib/apt/lists/*

RUN ARCH=$(dpkg --print-architecture) \
 && curl -Lo /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" \
 && chmod +x /usr/local/bin/kind \
 && curl -Lo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && curl -L "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" | tar xz -C /tmp \
 && mv "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm && chmod +x /usr/local/bin/helm

WORKDIR /workspace
CMD ["/bin/bash"]
