#!/usr/bin/env sh
# 80-network-test.sh — OPTIONAL: test quote-api from inside the cluster at every
# network layer (DNS, Service, pod IPs, Traefik, host path, NetworkPolicy).
set -eu
. "$(dirname "$0")/lib.sh"
delegate_to_toolbox "$@"

NS=default
POD=net-test
IMAGE=curlimages/curl:8.11.1
SVC_FQDN=quote-api.quote-api.svc.cluster.local
fails=0

pass() { printf '    PASS  %-50s %s\n' "$1" "$2"; }
fail() { printf '    FAIL  %-50s %s\n' "$1" "$2"; fails=$((fails + 1)); }
in_pod() { kubectl exec -n "$NS" "$POD" -- "$@"; }

# expect_200 <url>: GET from inside the test pod must return HTTP 200
expect_200() {
  code=$(in_pod curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null) || true
  if [ "$code" = 200 ]; then pass "$1" "HTTP 200"; else fail "$1" "HTTP ${code:-no response}"; fi
}

step "Starting test pod ${NS}/${POD} (${IMAGE})"
kubectl delete pod "$POD" -n "$NS" --ignore-not-found --wait=true >/dev/null
kubectl run "$POD" -n "$NS" --image="$IMAGE" --restart=Never --command -- sleep 600 >/dev/null
kubectl wait pod/"$POD" -n "$NS" --for=condition=Ready --timeout=180s >/dev/null
trap 'kubectl delete pod "$POD" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

step "1. Cluster DNS -> Service"
for name in quote-api.quote-api quote-api.quote-api.svc "$SVC_FQDN"; do
  expect_200 "http://${name}/healthz"
done

step "2. Service load balancing (30 requests to /api/quote)"
ready=$(kubectl get deploy quote-api -n quote-api -o jsonpath='{.status.readyReplicas}')
dist=$(in_pod sh -c "for i in \$(seq 30); do curl -s --max-time 5 http://${SVC_FQDN}/api/quote; echo; done" |
  sed -n 's/.*"pod":"\([^"]*\)".*/\1/p' | sort | uniq -c)
printf '%s\n' "$dist" | sed 's/^/    /'
seen=$(printf '%s\n' "$dist" | grep -c . || true)
if [ "$seen" -ge 2 ]; then pass "requests spread over pods" "${seen} of ${ready} ready pods answered"
else fail "requests spread over pods" "only ${seen} pod(s) answered (${ready} ready)"; fi

step "3. Pod network (direct pod IP, port 3000, no Service)"
for ip in $(kubectl get pods -n quote-api -l app.kubernetes.io/name=quote-api -o jsonpath='{.items[*].status.podIP}'); do
  expect_200 "http://${ip}:3000/readyz"
done

step "4. Ingress inside the cluster (Traefik Service in kube-system)"
expect_200 "http://traefik.kube-system.svc.cluster.local/api/quote"

step "5. Host path (k3d load balancer -> Traefik -> Service -> pod)"
url="$(ingress_base_url)/api/quote"
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null) || true
if [ "$code" = 200 ]; then pass "$url" "HTTP 200"; else fail "$url" "HTTP ${code:-no response}"; fi

step "6. NetworkPolicy enforcement (namespace troubleshoot has default-deny)"
if kubectl get svc web-svc -n troubleshoot >/dev/null 2>&1; then
  WEB=http://web-svc.troubleshoot.svc.cluster.local/
  # Precondition: the service is up, so a failed connection can only be the policy
  eps=$(kubectl get endpoints web-svc -n troubleshoot -o jsonpath='{.subsets[*].addresses[*].ip}')
  if [ -z "$eps" ]; then
    fail "web-svc has ready endpoints" "none: cannot test the policy"
  else
    pass "web-svc has ready endpoints" "$eps"

    # Negative: our pod (no app=smoke-client label, other namespace) must be denied.
    # k3s' policy engine rejects (curl exit 7) or drops (exit 28) denied traffic.
    rc=0
    in_pod curl -s -o /dev/null --max-time 4 "$WEB" 2>/dev/null || rc=$?
    case "$rc" in
      7|28) pass "unlabeled pod -> web-svc is denied" "curl exit ${rc} (refused/timed out by NetworkPolicy)" ;;
      0)    fail "unlabeled pod -> web-svc is denied" "connected: NetworkPolicy is NOT enforced" ;;
      *)    fail "unlabeled pod -> web-svc is denied" "unexpected curl exit code ${rc}" ;;
    esac

    # Positive control: a pod labeled app=smoke-client in `troubleshoot` must get through.
    # k3s programs policy rules for a new pod a few seconds after it starts, so retry.
    code=$(kubectl run net-allowed -n troubleshoot --labels=app=smoke-client --image="$IMAGE" \
      --restart=Never --rm -i --quiet --command -- sh -c \
      "for i in 1 2 3 4 5 6 7 8 9 10; do c=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 $WEB); [ \"\$c\" = 200 ] && break; sleep 2; done; echo \$c" 2>/dev/null) || true
    if [ "$code" = 200 ]; then pass "app=smoke-client pod -> web-svc is allowed" "HTTP 200"
    else fail "app=smoke-client pod -> web-svc is allowed" "HTTP ${code:-no response}"; fi
  fi
else
  log "skipped: run scripts/30-troubleshoot.sh first"
fi

step "Result"
[ "$fails" -eq 0 ] || die "${fails} network check(s) failed"
log "PASS: quote-api reachable at every network layer; NetworkPolicy enforced"
