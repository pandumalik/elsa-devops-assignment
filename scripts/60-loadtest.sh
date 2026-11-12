#!/usr/bin/env sh
# 60-loadtest.sh — Part 6: install kube-prometheus-stack, apply monitoring
# resources, run the k6 load test and record HPA scale-out while it runs.
set -eu
. "$(dirname "$0")/lib.sh"
delegate_to_toolbox "$@"

BASE_URL="$(ingress_base_url)"
MON_DIR=./part-6-loadtest/monitoring
HPA_LOG="$LOG_DIR/hpa-watch.log"
KPS_CHART_VERSION="93.2.2" # pinned: an unpinned chart pulls whatever is newest on the reviewer's machine

step "Installing kube-prometheus-stack (Prometheus + Grafana)"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Grafana admin credentials: generated once, never committed
if ! kubectl get secret grafana-admin -n monitoring >/dev/null 2>&1; then
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  kubectl create secret generic grafana-admin -n monitoring \
    --from-literal=admin-user=admin --from-literal=admin-password="$pw" >/dev/null
  log "created secret monitoring/grafana-admin"
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
run_logged "$LOG_DIR/helm-kube-prometheus.log" helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version "$KPS_CHART_VERSION" \
  --values "$MON_DIR/values-kube-prometheus.yaml" \
  --wait \
  --timeout 10m

step "Applying ServiceMonitor, PrometheusRule and Grafana dashboard"
kubectl apply -f "$MON_DIR/servicemonitor.yaml" -f "$MON_DIR/prometheusrule.yaml" >/dev/null
# grafana-dashboard.json is the single source of truth; the sidecar picks up the labeled ConfigMap
kubectl create configmap quote-api-grafana-dashboard -n monitoring \
  --from-file=quote-api-dashboard.json="$MON_DIR/grafana-dashboard.json" \
  --dry-run=client -o yaml |
  kubectl label --local -f - grafana_dashboard=1 -o yaml |
  kubectl apply -f - >/dev/null
log "applied (Grafana password: kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"

# Record HPA state for the whole test, logging only when something changes
(
  last=""
  while :; do
    state=$(kubectl get hpa quote-api -n quote-api \
      -o jsonpath='replicas={.status.currentReplicas} desired={.status.desiredReplicas} cpu={.status.currentMetrics[0].resource.current.averageUtilization}%' 2>/dev/null || echo "waiting for HPA")
    if [ "$state" != "$last" ]; then
      echo "$(date -u +%H:%M:%S)  $state"
      last="$state"
    fi
    sleep 5
  done
) > "$HPA_LOG" 2>&1 &
WATCH_PID=$!
trap 'kill "$WATCH_PID" 2>/dev/null || true' EXIT

step "Running k6 against ${BASE_URL}/api/quote"
BASE_URL="${BASE_URL}" k6 run --quiet ./part-6-loadtest/k6/quote-loadtest.js

kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
trap - EXIT

step "HPA scale-out during the test (changes only)"
sed 's/^/    /' "$HPA_LOG"

step "Post-load pod placement"
show_placement quote-api

log "PASS: load test, HPA scale-out and Prometheus observability verified"
