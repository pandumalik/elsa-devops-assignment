#!/usr/bin/env sh
# 25-reclaim-drill.sh — Part 2.4: simulate a Spot reclaim. Drains one spot node
# while continuously curling the service, shows pods rescheduling, then
# uncordons the node. Fails if any request was dropped.
set -eu
. "$(dirname "$0")/lib.sh"
delegate_to_toolbox "$@"

TARGET_URL="$(ingress_base_url)/api/quote"
POST_DRAIN_REQUESTS=3   # keep probing a little after the drain completes
MAX_REQUESTS=120        # hard cap (~2 min) in case the drain hangs

SPOT_NODE=$(kubectl get nodes -l acme.io/capacity=spot -o jsonpath='{.items[0].metadata.name}')
[ -n "$SPOT_NODE" ] || die "no node labeled acme.io/capacity=spot"
trap 'kubectl uncordon "$SPOT_NODE" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM

step "Spot reclaim drill on ${SPOT_NODE}: before"
show_placement quote-api

step "Draining ${SPOT_NODE} while curling ${TARGET_URL}"
kubectl drain "$SPOT_NODE" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --grace-period=10 \
  --timeout=60s >"$LOG_DIR/drain.log" 2>&1 &
DRAIN_PID=$!

ok=0; fail=0; total=0; after=0; pods=""
printf '    requests: '
while [ "$total" -lt "$MAX_REQUESTS" ]; do
  if ! kill -0 "$DRAIN_PID" 2>/dev/null; then
    [ "$after" -ge "$POST_DRAIN_REQUESTS" ] && break
    after=$((after + 1))
  fi
  total=$((total + 1))
  if out=$(curl -fsS --max-time 3 "$TARGET_URL" 2>/dev/null); then
    ok=$((ok + 1)); printf '.'
    pod=$(printf '%s' "$out" | sed -n 's/.*"pod":"\([^"]*\)".*/\1/p')
    case " $pods " in *" $pod "*) ;; *) pods="$pods $pod" ;; esac
  else
    fail=$((fail + 1)); printf 'x'
  fi
  sleep 1
done
echo

if ! wait "$DRAIN_PID"; then
  tail -n 20 "$LOG_DIR/drain.log" >&2
  die "kubectl drain failed (full log: $LOG_DIR/drain.log)"
fi
log "served by:${pods}"

kubectl rollout status deployment/quote-api -n quote-api --timeout=90s >/dev/null
step "During the outage (${SPOT_NODE} cordoned)"
show_placement quote-api

kubectl uncordon "$SPOT_NODE" >/dev/null
trap - EXIT
log "uncordoned ${SPOT_NODE}"

step "Result: ${ok}/${total} requests OK, ${fail} failed"
[ "$fail" -eq 0 ] || die "service dropped requests during the spot reclaim"
log "PASS: zero downtime during spot node reclaim"
