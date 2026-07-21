# Samba Active Directory Domain Controller — a real AD-compatible DC for local testing.
# Samba's AD DC mode reimplements Microsoft AD: same LDAP schema (sAMAccountName,
# objectGUID, userAccountControl), same Kerberos realm behavior. Keycloak's
# "Active Directory" vendor setting works against it exactly as against real AD.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends samba winbind ldb-tools \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 389 = LDAP, 636 = LDAPS (Samba auto-generates a self-signed TLS cert at provision)
EXPOSE 389 636

ENTRYPOINT ["/entrypoint.sh"]
