#!/usr/bin/env bash
# ==========================================================================
# 00-kc-config.sh -- Settings for the Keycloak server.
#
# This file first loads ../scripts/00-config.sh, so it inherits your region,
# tags, VPC and the NiFi deployment's state. Then it adds Keycloak-specific
# settings and switches to its own state file (.kc-state).
#
# Sourced by every other script here. Do not run it on its own.
# ==========================================================================

KC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KC_DIR

# --- inherit everything from the NiFi deployment ---------------------------
# shellcheck disable=SC1091
source "${KC_DIR}/../scripts/00-config.sh"

# The NiFi state file (VPC_ID, SUBNET_IDs, SG_ID, PUBLIC_IP of NiFi, ...)
export NIFI_STATE_FILE="${STATE_FILE}"
load_nifi_state() {
  [ -f "$NIFI_STATE_FILE" ] || die "NiFi state file not found at $NIFI_STATE_FILE
       Deploy NiFi first: cd ../scripts && ./deploy-all.sh"
  # shellcheck disable=SC1090
  source "$NIFI_STATE_FILE"
  # Give the NiFi values clearer names so they cannot be confused with Keycloak's.
  export NIFI_INSTANCE_ID="${INSTANCE_ID:-}"
  export NIFI_PUBLIC_IP="${PUBLIC_IP:-}"
  export NIFI_SG_ID="${SG_ID:-}"
}

# From here on, save_state / load_state use KEYCLOAK's state file.
export STATE_FILE="${KC_DIR}/.kc-state"
export BUILD_DIR="${KC_DIR}/build"
export SCRIPT_DIR="${KC_DIR}"

# ==========================================================================
# Keycloak settings
# ==========================================================================
# 26.7.0 is the current release (July 2026). Keycloak has no LTS line: only
# the newest version gets security fixes, so prefer the latest.
export KC_VERSION="26.7.0"
export KC_IMAGE="quay.io/keycloak/keycloak"
export KC_PORT="8443"

# The Keycloak EC2 instance. Keycloak needs ~1 GB of RAM; t3.small (2 GB) is
# comfortable for a lab.
export KC_INSTANCE_TYPE="t3.small"
export KC_ROOT_VOLUME_GB="20"
export KC_SG_NAME="${PROJECT}-keycloak-sg"
export KC_NAME="${PROJECT}-keycloak"

# --- Keycloak's own admin console login (the "master" realm) --------------
export KC_ADMIN_USER="kcadmin"
export KC_ADMIN_PASSWORD="ChangeMe-KcAdmin-2026!"   # <-- CHANGE THIS

# --- The realm and client NiFi will use -----------------------------------
export KC_REALM="nifi"
export KC_CLIENT_ID="nifi"
# Shared secret between NiFi and Keycloak. Leave empty to auto-generate one.
export KC_CLIENT_SECRET=""

# --- The first person who can log in to NiFi ------------------------------
# This email becomes NiFi's "Initial Admin Identity" - the only account that
# starts with full permissions. Everyone else is added from inside NiFi.
export NIFI_ADMIN_EMAIL="nifi.admin@example.com"
export NIFI_ADMIN_USERNAME="nifiadmin"
export NIFI_ADMIN_PASSWORD="ChangeMe-NiFiAdmin-2026!"   # <-- CHANGE THIS

# Which claim from the ID token NiFi uses as the user's identity.
# "email" is the usual choice; "preferred_username" also works, but then the
# Initial Admin Identity must be the username instead of the email address.
export OIDC_IDENTITY_CLAIM="email"

# Give Keycloak a fixed public IP? Its hostname is derived from that IP, so
# if it changes, every URL changes. true is safer, ~$3.60/month.
export KC_ALLOCATE_EIP="false"
