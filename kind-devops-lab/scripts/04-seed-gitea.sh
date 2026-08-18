#!/usr/bin/env bash
# Step 4: create a Gitea admin user, create two repos, push the sample apps.
source "$(dirname "$0")/lib.sh"
need kubectl; need git; need curl

GITEA="$(gitea_addr)"
AUTH="${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}"

log "waiting for Gitea to answer"
for i in $(seq 1 60); do
  curl -sf "http://${GITEA}/api/healthz" >/dev/null && break
  sleep 5
done

log "creating admin user '${GITEA_ADMIN_USER}' (ok if it already exists)"
kubectl -n "${NAMESPACE}" exec deploy/gitea -- \
  su git -c "gitea admin user create --username '${GITEA_ADMIN_USER}' \
    --password '${GITEA_ADMIN_PASSWORD}' --email '${GITEA_ADMIN_EMAIL}' \
    --admin --must-change-password=false" || warn "user probably exists already"

create_repo() {
  local repo="$1"
  log "creating repo ${repo}"
  curl -sf -X POST "http://${GITEA}/api/v1/user/repos" \
    -u "${AUTH}" -H 'Content-Type: application/json' \
    -d "{\"name\":\"${repo}\",\"private\":false,\"auto_init\":false}" >/dev/null \
    || warn "repo ${repo} probably exists already"
}

push_sample() {
  local repo="$1" dir="$2"
  local url="http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}@${GITEA}/${GITEA_ADMIN_USER}/${repo}.git"
  log "pushing ${dir} -> ${repo}"
  ( cd "${dir}"
    rm -rf .git
    git init -q -b main
    git -c user.email="${GITEA_ADMIN_EMAIL}" -c user.name="seed" add -A
    git -c user.email="${GITEA_ADMIN_EMAIL}" -c user.name="seed" commit -qm "initial commit"
    git push -q --force "${url}" main )
}

create_repo java-app
create_repo cpp-app
push_sample java-app "${ROOT_DIR}/samples/java-app"
push_sample cpp-app  "${ROOT_DIR}/samples/cpp-app"

log "done. Repos: http://${GITEA}/${GITEA_ADMIN_USER}/java-app and .../cpp-app"
log "Jenkins polls every 2 minutes, or hit 'Build Now' at http://$(jenkins_addr)"
