#!/usr/bin/env sh
# 99-cleanup.sh — delete everything this project created (cluster, toolbox, built
# images, .terraform, .kube) and nothing else; base images are kept unless --images.
# Usage:  ./scripts/99-cleanup.sh [--dry-run] [--yes] [--images]
# Runs on the HOST (a container cannot delete itself).
set -eu
. "$(dirname "$0")/lib.sh"

DRY_RUN=0; ASSUME_YES=0; PURGE_IMAGES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -y|--yes)  ASSUME_YES=1 ;;
    --images)  PURGE_IMAGES=1 ;;
    *) die "unknown option: $arg (use --dry-run, --yes, --images)" ;;
  esac
done

[ -f /.dockerenv ] && die "run this on your machine, not inside the toolbox"
command -v docker >/dev/null 2>&1 || die "docker CLI not found"

PROJECT=$(basename "$REPO_ROOT" | tr 'A-Z' 'a-z')   # docker compose project name

k3d_containers=$(docker ps -aq --filter "label=k3d.cluster=${CLUSTER_NAME}")
k3d_volumes=$(docker volume ls -q --filter "label=k3d.cluster=${CLUSTER_NAME}")
k3d_network=$(docker network ls -q --filter "name=^k3d-${CLUSTER_NAME}$")
toolbox=$(docker ps -aq --filter "name=^elsa-toolbox$")
app_images=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '(^|/)quote-api:' || true)
toolbox_image=$(docker images -q "${PROJECT}-toolbox" 2>/dev/null || true)
base_images=""
if [ "$PURGE_IMAGES" = 1 ]; then
  base_images=$(docker images --format '{{.Repository}}:{{.Tag}}' |
    grep -E '^(rancher/k3s|ghcr\.io/k3d-io/k3d-(proxy|tools)|node:24-trixie-slim|gcr\.io/distroless/nodejs24-debian13|debian:bookworm-slim)' || true)
fi
files=""
for f in part-5-iac/cloudflare/.terraform .kube; do [ -e "$f" ] && files="$files $f"; done

count() { if [ -n "$1" ]; then echo "$1" | wc -w | tr -d ' '; else echo 0; fi; }

step "This will delete"
log "k3d cluster '${CLUSTER_NAME}': $(count "$k3d_containers") container(s), $(count "$k3d_volumes") volume(s), network: $([ -n "$k3d_network" ] && echo "k3d-${CLUSTER_NAME}" || echo none)"
log "toolbox: container $([ -n "$toolbox" ] && echo elsa-toolbox || echo none), compose network + kubeconfig volume, image $([ -n "$toolbox_image" ] && echo "${PROJECT}-toolbox" || echo none)"
log "quote-api images: $(count "$app_images")$([ -n "$app_images" ] && printf ' (%s)' "$(echo $app_images)")"
[ "$PURGE_IMAGES" = 1 ] && log "base images (--images): $(count "$base_images")$([ -n "$base_images" ] && printf ' (%s)' "$(echo $base_images)")"
log "workspace files:${files:- none}"

if [ "$DRY_RUN" = 1 ]; then
  step "Dry run: nothing was deleted"
  exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
  [ -t 0 ] || die "refusing to delete without confirmation; re-run with --yes"
  printf '\n    Type "yes" to delete all of the above: '
  read -r answer
  [ "$answer" = "yes" ] || die "aborted, nothing deleted"
fi

step "Deleting k3d cluster '${CLUSTER_NAME}'"
[ -n "$k3d_containers" ] && docker rm -f $k3d_containers >/dev/null
[ -n "$k3d_network" ]    && docker network rm "k3d-${CLUSTER_NAME}" >/dev/null
[ -n "$k3d_volumes" ]    && docker volume rm $k3d_volumes >/dev/null
log "done"

step "Deleting toolbox (docker compose down)"
docker compose down --volumes --remove-orphans --rmi local >/dev/null 2>&1 || true
log "done"

step "Deleting images"
for img in $app_images $base_images; do
  docker rmi "$img" >/dev/null 2>&1 && log "removed $img" || warn "kept $img (in use by another container?)"
done
[ -z "$app_images$base_images" ] && log "none"

step "Deleting workspace leftovers"
for f in $files; do rm -rf "$f" && log "removed $f"; done
[ -z "$files" ] && log "none"

step "Workspace is back to its initial state. Start again with:  docker compose up -d && ./scripts/run-all.sh"
