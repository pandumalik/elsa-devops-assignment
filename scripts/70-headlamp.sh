#!/usr/bin/env sh
# 70-headlamp.sh — OPTIONAL: install the Headlamp web UI to inspect the cluster.
# Not part of run-all.sh. Prints the URL and a read-only login token.
# Re-run any time to get a fresh token.
set -eu
. "$(dirname "$0")/lib.sh"
delegate_to_toolbox "$@"

HEADLAMP_CHART_VERSION="0.46.0"
HOST_URL="http://headlamp.localhost:${INGRESS_PORT}"

step "Installing Headlamp ${HEADLAMP_CHART_VERSION}"
kubectl apply -f ./tools/headlamp/rbac.yaml >/dev/null
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ --force-update >/dev/null
run_logged "$LOG_DIR/helm-headlamp.log" helm upgrade --install headlamp headlamp/headlamp \
  --namespace kube-system \
  --version "$HEADLAMP_CHART_VERSION" \
  --values ./tools/headlamp/values.yaml \
  --wait --timeout 10m

# Traefik needs a few seconds to pick up the new route
if [ -f /.dockerenv ]; then
  check_url="http://k3d-${CLUSTER_NAME}-serverlb:80/"
else
  check_url="${HOST_URL}/"
fi
curl -fsS -o /dev/null --retry 10 --retry-delay 2 --retry-all-errors -H "Host: headlamp.localhost" "$check_url" ||
  die "Headlamp is installed but not reachable through the ingress"

step "Headlamp is ready"
log "Open:  ${HOST_URL}"
log "Login with this read-only token (valid 24h; re-run this script for a new one):"
echo
kubectl create token headlamp-viewer -n kube-system --duration=24h
echo
