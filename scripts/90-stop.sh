#!/usr/bin/env sh
# 90-stop.sh — pause the whole harness without losing anything: stops the k3d
# cluster containers and the toolbox. Everything (ArgoCD, apps, Prometheus data,
# images) is kept.
#
# Resume:  docker compose up -d   (the toolbox restarts and 00-bootstrap starts
#                                   the stopped cluster again)
# Runs on the HOST (a container cannot stop itself).
set -eu
. "$(dirname "$0")/lib.sh"

[ -f /.dockerenv ] && die "run this on your machine, not inside the toolbox"
command -v docker >/dev/null 2>&1 || die "docker CLI not found"

step "Stopping k3d cluster '${CLUSTER_NAME}'"
nodes=$(docker ps -q --filter "label=k3d.cluster=${CLUSTER_NAME}")
if [ -n "$nodes" ]; then
  # Same containers `k3d cluster stop` stops; selected by k3d's own label
  docker stop $nodes >/dev/null
  log "stopped $(echo "$nodes" | wc -l | tr -d ' ') cluster container(s)"
else
  log "no running cluster containers"
fi

step "Stopping toolbox (docker compose stop)"
docker compose stop >/dev/null 2>&1
log "stopped"

step "Done. State is kept; resume with:  docker compose up -d"
