Here's the full set for a NiFi 1.28 + OIDC deployment. Replace the Keycloak URLs with your IdP's.

**`nifi.properties`** — the security-relevant lines (leave the rest of the file as shipped):

```properties
# --- Web: HTTPS only, HTTP must be blank ---
nifi.web.http.host=
nifi.web.http.port=
nifi.web.https.host=nifi01.example.com
nifi.web.https.port=8443
nifi.web.proxy.host=nifi.example.com:8443,nifi01.example.com:8443
nifi.web.proxy.context.path=
nifi.web.max.header.size=32 KB

# --- TLS ---
nifi.security.keystore=./conf/keystore.p12
nifi.security.keystoreType=PKCS12
nifi.security.keystorePasswd=<pw>
nifi.security.keyPasswd=<pw>
nifi.security.truststore=./conf/truststore.p12
nifi.security.truststoreType=PKCS12
nifi.security.truststorePasswd=<pw>

# --- Auth wiring ---
nifi.security.user.authorizer=managed-authorizer
nifi.security.user.login.identity.provider=
nifi.security.allow.anonymous.authentication=false

# --- OIDC ---
nifi.security.user.oidc.discovery.url=https://keycloak.example.com/realms/nifi/.well-known/openid-configuration
nifi.security.user.oidc.connect.timeout=5 secs
nifi.security.user.oidc.read.timeout=5 secs
nifi.security.user.oidc.client.id=nifi
nifi.security.user.oidc.client.secret=<secret>
nifi.security.user.oidc.preferred.jwsalgorithm=RS256
nifi.security.user.oidc.additional.scopes=profile,email
nifi.security.user.oidc.claim.identifying.user=email
nifi.security.user.oidc.fallback.claims.identifying.user=
nifi.security.user.oidc.truststore.strategy=JDK

# --- Identity mapping: normalize email case, shorten cert DNs ---
nifi.security.identity.mapping.pattern.dn=^CN=(.*?), OU=(.*)$
nifi.security.identity.mapping.value.dn=$1
nifi.security.identity.mapping.transform.dn=NONE
nifi.security.identity.mapping.pattern.email=^(.*@.*)$
nifi.security.identity.mapping.value.email=$1
nifi.security.identity.mapping.transform.email=LOWER
```

`login.identity.provider` **must** be empty — leaving `single-user-provider` there (the default in a fresh 1.28 install) silently wins over OIDC.

**`authorizers.xml`** — full file, single node:

```xml
<authorizers>
    <userGroupProvider>
        <identifier>file-user-group-provider</identifier>
        <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
        <property name="Users File">./conf/users.xml</property>
        <property name="Initial User Identity 1">admin@example.com</property>
        <property name="Initial User Identity 2">nifi01.example.com</property>
    </userGroupProvider>

    <accessPolicyProvider>
        <identifier>file-access-policy-provider</identifier>
        <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
        <property name="User Group Provider">file-user-group-provider</property>
        <property name="Authorizations File">./conf/authorizations.xml</property>
        <property name="Initial Admin Identity">admin@example.com</property>
        <property name="Node Identity 1">nifi01.example.com</property>
        <property name="Node Group"></property>
    </accessPolicyProvider>

    <authorizer>
        <identifier>managed-authorizer</identifier>
        <class>org.apache.nifi.authorization.StandardManagedAuthorizer</class>
        <property name="Access Policy Provider">file-access-policy-provider</property>
    </authorizer>
</authorizers>
```

Node identities are the cert DNs *after* the `dn` mapping above — so `CN=nifi01.example.com, OU=NIFI` becomes `nifi01.example.com`. Every node needs an entry in both providers. For a 3-node cluster, add `Initial User Identity 3/4` and `Node Identity 2/3`.

**IdP-side (Keycloak client settings):**

- Client type: OpenID Connect, **confidential** (client authentication on)
- Valid redirect URI: `https://nifi.example.com:8443/nifi-api/access/oidc/callback`
- Valid post-logout redirect URI: `https://nifi.example.com:8443/nifi/logout-complete`
- Web origin: `https://nifi.example.com:8443`
- Ensure the `email` claim is in the ID token, and that emails are verified/unique in the realm

**First boot:** start with `users.xml` and `authorizations.xml` absent. NiFi generates them from the Initial* properties on that one startup only — after that the files are authoritative and edits to `authorizers.xml` are ignored. Any typo means deleting both files on every node and restarting.

For group-based policies instead of per-user, swap in `CompositeConfigurableUserGroupProvider` wrapping the file provider plus `LdapUserGroupProvider` or `AzureGraphUserGroupProvider`. Say the word and I'll write that variant out.