#!/usr/bin/env sh
# 10-build-service.sh — Part 1: build the distroless quote-api image with an
# immutable tag, push it to GHCR (when credentials exist) and import it into k3d.
# The tag reaches the cluster as an ArgoCD Helm parameter (see 20-deploy.sh);
# no tracked file is modified.
set -eu
. "$(dirname "$0")/lib.sh"
delegate_to_toolbox "$@"

IMAGE_REPO=$(image_repo)
TAG=$(image_tag)
FULL_IMAGE="${IMAGE_REPO}:${TAG}"
case "$TAG" in
  sha-*-dirty.*) warn "part-1-service has uncommitted changes; tagging ${TAG}" ;;
  src-*)         warn "not a git checkout; using content-hash tag ${TAG}" ;;
esac

step "Building ${FULL_IMAGE}"
run_logged "$LOG_DIR/docker-build.log" docker build -t "${FULL_IMAGE}" ./part-1-service
log "image: $(docker image ls "${FULL_IMAGE}" --format '{{.Repository}}:{{.Tag}}  {{.Size}}')"

if [ -n "${GHCR_TOKEN:-}" ] && [ -n "${GHCR_USER:-}" ]; then
  step "Pushing ${FULL_IMAGE} to GHCR"
  echo "${GHCR_TOKEN}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin >/dev/null
  run_logged "$LOG_DIR/docker-push.log" docker push "${FULL_IMAGE}"
else
  log "GHCR_USER/GHCR_TOKEN not set; skipping registry push (CI publishes the same sha-tag)"
fi

step "Importing ${FULL_IMAGE} into k3d cluster '${CLUSTER_NAME}' (pods start without a registry pull)"
run_logged "$LOG_DIR/k3d-import.log" k3d image import "${FULL_IMAGE}" -c "${CLUSTER_NAME}"
