# =============================================================================
# DOCKERFILE: servers/Dockerfile
# -----------------------------------------------------------------------------
# WHAT:  Builds the "server" image used by server1/server2/server3. It is a
#        plain Ubuntu 24.04 box running sshd, with an "ansible" sudo user and
#        the Python bits Ansible needs to manage it.
# WHY:   The lab's controller connects to these over SSH and drives them with
#        Ansible; this image is the managed target host.
# GOAL:  A reproducible, SSH-reachable Ubuntu node that Ansible can configure.
#
# ARM64 / Apple Silicon note: on M1/M2/M3 these containers are arm64, so apt
# fetches from http://ports.ubuntu.com/ubuntu-ports (the canonical ARM archive,
# a single Cloudflare-fronted endpoint with no mirror redundancy). During a
# mirror sync that endpoint can briefly serve an index whose size doesn't match
# the release manifest, producing:
#   "File has unexpected size (... != ...). Mirror sync in progress?"
# The apt hardening below makes the build (and later runtime apt) ride through
# those transient windows instead of failing.
# =============================================================================

# Base image: Ubuntu 24.04 LTS ("noble"). Pulled for the host's architecture
# (arm64 on Apple Silicon), which is what routes apt to ports.ubuntu.com.
FROM ubuntu:24.04

# Run apt non-interactively so package installs never block on prompts
# (tzdata, etc.). WHY: required for an unattended image build.
ENV DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# APT HARDENING (drop-in config) - the actual fix for the mirror-sync failure.
# WHAT: writes /etc/apt/apt.conf.d/99-lab-resilient-apt with retry + tolerance
#       settings that apply to EVERY apt invocation, at build time AND at
#       runtime (so the bootstrap.yml "update_cache" step benefits too).
# WHY each setting:
#   Acquire::Retries "8"            -> retry a failed/short download up to 8x
#                                      instead of giving up, riding out a sync.
#   Acquire::http::Timeout "30"     -> don't hang forever on a stalled mirror;
#   Acquire::https::Timeout "30"       fail fast so a Retry can kick in.
#   Acquire::CompressionTypes::Order
#       "gz";                       -> prefer the .gz index; avoids some
#                                      by-hash mismatch edge cases on ports.
#   Acquire::By-Hash "force"        -> fetch indexes by their content hash
#                                      path, which is immune to the
#                                      "unexpected size" race during a sync.
# GOAL: turn a transient mirror inconsistency into a brief retry, not a build
#       break. (By-Hash is the key line that defeats THIS specific error.)
# -----------------------------------------------------------------------------
RUN printf '%s\n' \
    'Acquire::Retries "8";' \
    'Acquire::http::Timeout "30";' \
    'Acquire::https::Timeout "30";' \
    'Acquire::CompressionTypes::Order { "gz"; };' \
    'Acquire::By-Hash "force";' \
    > /etc/apt/apt.conf.d/99-lab-resilient-apt

# -----------------------------------------------------------------------------
# OPTIONAL: pin a different mirror.
# Ubuntu 24.04 stores its sources in DEB822 format at
# /etc/apt/sources.list.d/ubuntu.sources. On arm64 the URIs point at
# http://ports.ubuntu.com/ubuntu-ports. That IS the canonical ARM archive, so
# there is no faster geographic mirror network to switch to the way there is
# for x86. If you run a LOCAL apt cache/proxy (e.g. apt-cacher-ng) or a private
# mirror of ports, uncomment and set it here for maximum reliability:
#
# RUN sed -i 's|http://ports.ubuntu.com/ubuntu-ports|http://YOUR-LOCAL-MIRROR/ubuntu-ports|g' \
#       /etc/apt/sources.list.d/ubuntu.sources
#
# Leaving it commented keeps the default archive + the By-Hash/retry hardening
# above, which already resolves the reported error for nearly all cases.
# -----------------------------------------------------------------------------

# Install the OS packages the lab node needs.
# WHY these: ca-certificates/curl/gnupg for secure fetches; iproute2/procps for
# diagnostics; netcat-openbsd for readiness checks; openssh-server so Ansible
# can connect; python3 + python3-apt so Ansible's apt module works; sudo for
# privilege escalation. GOAL: a node Ansible can SSH to and manage.
# "--no-install-recommends" keeps the image lean; the apt hardening above makes
# this update step resilient to the ports.ubuntu.com sync race.
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

# Create the unprivileged "ansible" user the controller logs in as.
# WHY: matches ansible_user/ansible_password in inventory/hosts.ini and grants
# passwordless sudo so become:true works. Also pre-creates /opt/data-platform.
# GOAL: a ready-to-manage login that Ansible can escalate from.
RUN useradd -ms /bin/bash ansible \
    && echo 'ansible:ansible' | chpasswd \
    && echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible \
    && chmod 0440 /etc/sudoers.d/ansible \
    && mkdir -p /var/run/sshd /opt/data-platform

# Install the lab's SSH server config (key/password policy for the lab).
COPY sshd_config /etc/ssh/sshd_config

# Document that the container listens on the SSH port.
EXPOSE 22

# Run sshd in the foreground (-D) with logging to stderr (-e) as PID 1 so the
# container stays alive and Ansible can connect. GOAL: a long-lived SSH target.
CMD ["/usr/sbin/sshd", "-D", "-e"]
