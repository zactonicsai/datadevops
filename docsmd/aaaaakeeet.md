That reframes the problem. The Iron Bank hardened image differs from `quay.io/keycloak/keycloak` in two ways that both break runtime augmentation:

**1. Non-root by default.** The image sets a non-root `USER` (typically UID 1000), and `/opt/keycloak/lib/quarkus` is often owned `root:root` without group write. `kc.sh build` has to *write* the augmentation output there — it can't, so the build fails or leaves a partial state.

**2. Aggressive slimming.** Iron Bank strips jars to reduce CVE counts. If the deployment-time Quarkus jars got removed, the app is effectively no longer a mutable-jar and re-augmentation is impossible no matter what permissions you set.

Check which one you're hitting:

```bash
docker login registry1.dso.mil
IMG=registry1.dso.mil/ironbank/opensource/keycloak/keycloak:<tag>

docker run --rm --entrypoint ls $IMG -la /opt/keycloak/lib/quarkus
docker run --rm --entrypoint ls $IMG -la /opt/keycloak/lib/ | head
docker run --rm --entrypoint id $IMG
docker inspect $IMG --format '{{.Config.User}} {{json .Config.Entrypoint}} {{json .Config.Cmd}}'
```

If `lib/quarkus/` contains a populated `generated-bytecode.jar` / `transformed-bytecode.jar`, **the image is already built** — stop trying to build. Run it optimized and pass only runtime options:

```bash
docker run -d --name keycloak -p 8443:8443 \
  -e KC_DB_URL='jdbc:postgresql://host/keycloak' \
  -e KC_DB_USERNAME=... -e KC_DB_PASSWORD=... \
  -e KC_HOSTNAME=https://your.domain \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD='<pw>' \
  $IMG start --optimized
```

If you genuinely need a build (adding a provider JAR, enabling a feature, switching DB vendor), do it in a builder stage as root and hand ownership back:

```dockerfile
ARG IMG=registry1.dso.mil/ironbank/opensource/keycloak/keycloak:<tag>
FROM ${IMG} AS builder
USER 0
ENV KC_DB=postgres KC_HEALTH_ENABLED=true
# COPY providers/*.jar /opt/keycloak/providers/
RUN /opt/keycloak/bin/kc.sh build && chown -R 1000:0 /opt/keycloak && chmod -R g+rwX /opt/keycloak

FROM ${IMG}
USER 0
COPY --from=builder --chown=1000:0 /opt/keycloak/ /opt/keycloak/
USER 1000
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
```

Two extra Iron Bank gotchas: if the image ships FIPS-enabled, you must build with `--features=fips` and the BouncyCastle FIPS jars present or augmentation fails, and Iron Bank tags lag upstream, so don't copy config from current Keycloak docs without checking the version in the image.

Paste the output of the `ls -la /opt/keycloak/lib/quarkus` check and I can tell you which of the two cases you're in.