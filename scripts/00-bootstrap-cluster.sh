#!/usr/bin/env sh
# 00-bootstrap-cluster.sh — Idempotent k3d cluster (1 server, 4 agents), then
# troubleshoot/prepare.sh labels/taints the Spot, On-Demand and GPU nodes.
set -eu
. "$(dirname "$0")/lib.sh"
delegate_to_toolbox "$@"

# Lock so compose startup and an immediate ./scripts/run-all.sh never race.
# The owner PID is recorded so a lock left behind by a killed run is reclaimed.
LOCK_DIR=/tmp/elsa-bootstrap.lock
waited=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
    warn "removing stale bootstrap lock (pid $owner is gone)"
    rm -rf "$LOCK_DIR"
    continue
  fi
  [ "$waited" -ge 600 ] && die "bootstrap lock $LOCK_DIR held for >10 min; remove it if no bootstrap is running"
  log "another bootstrap is running (pid ${owner:-?}), waiting..."
  sleep 5
  waited=$((waited + 5))
done
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT
trap 'exit 130' INT TERM

step "Ensuring k3d cluster '${CLUSTER_NAME}' (1 server, 4 agents)"
if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "${CLUSTER_NAME}"; then
  log "cluster already exists; making sure it is started (no-op if running)"
  run_logged "$LOG_DIR/k3d-start.log" k3d cluster start "${CLUSTER_NAME}" --wait
else
  run_logged "$LOG_DIR/k3d-create.log" k3d cluster create "${CLUSTER_NAME}" \
    --servers 1 \
    --agents 4 \
    --port "${INGRESS_PORT}:80@loadbalancer" \
    --wait
fi

if [ -f /.dockerenv ]; then
  # Inside the toolbox: join the k3d network and talk to the server container directly
  docker network connect "k3d-${CLUSTER_NAME}" "$(hostname)" 2>/dev/null || true
  mkdir -p /root/.kube
  k3d kubeconfig get "${CLUSTER_NAME}" |
    sed -E "s#(0\.0\.0\.0|127\.0\.0\.1|host\.docker\.internal):[0-9]+#k3d-${CLUSTER_NAME}-server-0:6443#g" > /root/.kube/config
  chmod 600 /root/.kube/config
else
  # Host run: project-local kubeconfig (set in lib.sh), never ~/.kube/config
  mkdir -p "$(dirname "$KUBECONFIG")"
  k3d kubeconfig get "${CLUSTER_NAME}" > "$KUBECONFIG"
fi

log "waiting for all nodes to be Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=120s >/dev/null

step "Configuring Spot / On-Demand / GPU nodepools (troubleshoot/prepare.sh)"
sh ./troubleshoot/prepare.sh

log "cluster bootstrap complete"
