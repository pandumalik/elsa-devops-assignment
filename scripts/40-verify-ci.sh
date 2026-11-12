#!/usr/bin/env sh
# 40-verify-ci.sh — Part 4: static checks on the GitHub Actions workflow and
# Semgrep rules (presence, no hardcoded keys, hard-failing gates, pinned actions).
set -eu
. "$(dirname "$0")/lib.sh"
delegate_to_toolbox "$@"

WORKFLOW=.github/workflows/ci.yml

step "Verifying Part 4 CI/CD files"
for f in "$WORKFLOW" .semgrep.yml MIGRATION-NOTES.md part-4-cicd/ci-cd.yml part-4-cicd/.semgrep.yml part-4-cicd/MIGRATION-NOTES.md; do
  [ -s "$f" ] || die "missing or empty required file: $f"
done
log "workflow, Semgrep rules and migration notes present"

grep -qE "AKIA[A-Z0-9]{16}" "$WORKFLOW" && die "hardcoded AWS access key in $WORKFLOW"
log "no hardcoded AWS keys"

# Gate checks look at executable YAML only; comments may mention the legacy anti-patterns
CODE=$(grep -vE '^[[:space:]]*#' "$WORKFLOW")

printf '%s\n' "$CODE" | grep -qE "continue-on-error:[[:space:]]*true|\|\|[[:space:]]*(echo|true)" &&
  die "soft-failing gate (continue-on-error / '|| echo' / '|| true') in $WORKFLOW"
log "all gates hard-fail"

unpinned=$(printf '%s\n' "$CODE" | grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' || true)
[ -z "$unpinned" ] || die "actions not pinned to a commit SHA:
$unpinned"
log "all third-party actions pinned to commit SHAs"

log "PASS: Part 4 CI/CD migration verified"
