#!/usr/bin/env sh
# run-all.sh — run every numbered script in order, stop at the first failure,
# and print a per-step timing summary.
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STEPS="00-bootstrap-cluster 10-build-service 20-deploy 25-reclaim-drill 30-troubleshoot 40-verify-ci 50-validate-tf 60-loadtest"
SUMMARY=""
status=0

for s in $STEPS; do
  start=$(date +%s)
  if sh "$DIR/$s.sh"; then
    result="ok  "
  else
    result="FAIL"
    status=1
  fi
  SUMMARY="${SUMMARY}$(printf '  %s  %-22s %4ss' "$result" "$s" "$(( $(date +%s) - start ))")
"
  [ "$status" -eq 0 ] || break
done

echo
echo "==================== run-all summary ===================="
printf '%s' "$SUMMARY"
if [ "$status" -eq 0 ]; then
  echo "  ALL STEPS PASSED"
else
  echo "  STOPPED at first failure (later steps depend on it)"
fi
exit "$status"
