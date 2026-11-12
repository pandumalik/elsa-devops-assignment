#!/usr/bin/env sh
# 30-troubleshoot.sh — Part 3: apply the fixed manifests and run troubleshoot/verify.sh
set -eu
. "$(dirname "$0")/lib.sh"
delegate_to_toolbox "$@"

step "Applying remediated manifests (troubleshoot/fixed-app.yaml)"
kubectl apply -f ./troubleshoot/fixed-app.yaml >/dev/null
log "applied"

step "Running troubleshoot/verify.sh"
sh ./troubleshoot/verify.sh
