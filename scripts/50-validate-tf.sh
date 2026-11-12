#!/usr/bin/env sh
# 50-validate-tf.sh — Part 5: sanity-check the Karpenter v1 GPU NodePools and
# validate the Cloudflare Terraform (fmt, init without backend, validate).
set -eu
. "$(dirname "$0")/lib.sh"
delegate_to_toolbox "$@"

NODEPOOL=./part-5-iac/karpenter/gpu-nodepool.yaml
TF_DIR=./part-5-iac/cloudflare

step "Validating Karpenter v1 GPU NodePools"
for pattern in "apiVersion: karpenter.sh/v1" "apiVersion: karpenter.k8s.aws/v1" "consolidationPolicy: WhenEmpty" "karpenter.k8s.aws/instance-gpu-count"; do
  grep -q "$pattern" "$NODEPOOL" || die "expected '$pattern' in $NODEPOOL"
done
# Well-known Karpenter labels are lowercase; a mistyped key never matches
grep -nE 'karpenter\.(sh|k8s\.aws)/[a-z-]*[A-Z]' "$NODEPOOL" && die "mixed-case Karpenter label key in $NODEPOOL"
log "API versions, consolidation policy and label keys OK"

step "Validating Cloudflare Terraform"
terraform -chdir="$TF_DIR" fmt -check -recursive >/dev/null || die "terraform fmt -check failed (run: terraform -chdir=$TF_DIR fmt)"
log "fmt OK"
run_logged "$LOG_DIR/terraform-init.log" terraform -chdir="$TF_DIR" init -backend=false -input=false
terraform -chdir="$TF_DIR" validate -no-color | sed 's/^/    /'

log "PASS: Part 5 IaC validation succeeded"
