FROM alpine/ansible:2.20.0

RUN apk add --no-cache \
    bash \
    curl \
    openssh-client \
    sshpass \
    docker-cli \
    py3-pip \
    python3

RUN ansible-galaxy collection install community.docker ansible.posix

WORKDIR /work
