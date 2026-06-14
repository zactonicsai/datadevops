FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    iproute2 \
    netcat-openbsd \
    openssh-server \
    procps \
    python3 \
    python3-apt \
    sudo \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -ms /bin/bash ansible \
    && echo 'ansible:ansible' | chpasswd \
    && echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible \
    && chmod 0440 /etc/sudoers.d/ansible \
    && mkdir -p /var/run/sshd /opt/data-platform

COPY sshd_config /etc/ssh/sshd_config

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
