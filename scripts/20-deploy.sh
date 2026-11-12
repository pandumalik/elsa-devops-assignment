#!/usr/bin/env sh
# 20-deploy.sh — Part 2: install ArgoCD and deploy quote-api via an ArgoCD
# Application that syncs the Helm chart in part-2-gitops/.
set -eu
. "$(dirname "$0")/lib.sh"
delegate_to_toolbox "$@"

ARGOCD_VERSION="v2.13.2"
GITOPS_DIR=part-2-gitops
IMAGE_REPO=$(image_repo)
IMAGE_TAG=$(image_tag)

docker image inspect "${IMAGE_REPO}:${IMAGE_TAG}" >/dev/null 2>&1 ||
  die "image ${IMAGE_REPO}:${IMAGE_TAG} not built yet; run scripts/10-build-service.sh first"

step "Installing ArgoCD core ${ARGOCD_VERSION}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
run_logged "$LOG_DIR/argocd-install.log" kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/core-install.yaml"
for r in deployment/argocd-repo-server deployment/argocd-redis statefulset/argocd-application-controller; do
  # 600s: on a cold machine every node pulls the ArgoCD image (measured: ~3 min)
  kubectl rollout status "$r" -n argocd --timeout=600s >/dev/null
done
log "ArgoCD is ready"

# Choose the Git source ArgoCD syncs from. On a clean clone (the reviewer's case)
# that is the GitHub repo itself. Only when the local chart differs from the
# remote (unpushed commits or local edits under part-2-gitops/) do we serve the
# local chart from an in-cluster Git mirror, so ArgoCD deploys what is on disk.
# The image tag is not in Git at all: it is passed as a Helm parameter below.
ORIGIN_URL=$(git_repo config --get remote.origin.url 2>/dev/null || true)
case "$ORIGIN_URL" in
  git@github.com:*) ORIGIN_URL="https://github.com/${ORIGIN_URL#git@github.com:}" ;;
esac

SYNC_REPO_URL=""
if [ -n "$ORIGIN_URL" ]; then
  remote_head=$(git ls-remote "$ORIGIN_URL" HEAD 2>/dev/null | cut -f1 || true)
  local_head=$(git_repo rev-parse HEAD 2>/dev/null || true)
  if [ -n "$remote_head" ] && [ "$remote_head" = "$local_head" ] &&
     [ -z "$(git_repo status --porcelain -- "$GITOPS_DIR")" ]; then
    SYNC_REPO_URL="$ORIGIN_URL"
  fi
fi

if [ -n "$SYNC_REPO_URL" ]; then
  step "Syncing from public remote ${SYNC_REPO_URL} (matches local HEAD)"
else
  step "Serving local ${GITOPS_DIR}/ to ArgoCD via in-cluster Git mirror"
  # git:// (git daemon): ArgoCD's go-git client cannot read "dumb HTTP" static file servers
  SYNC_REPO_URL="git://git-mirror.argocd.svc.cluster.local/repo.git"

  TMP_GIT=$(mktemp -d)
  trap 'rm -rf "$TMP_GIT"' EXIT
  # Only the GitOps tree is needed: keeps the bundle far below the 1 MiB ConfigMap limit
  mkdir -p "$TMP_GIT/work"
  cp -R "$GITOPS_DIR" "$TMP_GIT/work/"
  git -C "$TMP_GIT/work" init -q -b main
  git -C "$TMP_GIT/work" add .
  git -C "$TMP_GIT/work" -c user.email=gitops@elsa.local -c user.name="Elsa GitOps" commit -q -m "GitOps sync snapshot"
  git clone -q --bare "$TMP_GIT/work" "$TMP_GIT/repo.git"
  tar -czf "$TMP_GIT/repo-bare.tar.gz" -C "$TMP_GIT" repo.git
  BUNDLE_SHA=$(sha256sum "$TMP_GIT/repo-bare.tar.gz" | cut -c1-12)

  kubectl create configmap git-mirror-bundle -n argocd \
    --from-file=repo-bare.tar.gz="$TMP_GIT/repo-bare.tar.gz" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # The bundle checksum annotation rolls the mirror only when the content changed
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: git-mirror
  namespace: argocd
spec:
  replicas: 1
  selector:
    matchLabels:
      app: git-mirror
  template:
    metadata:
      labels:
        app: git-mirror
      annotations:
        elsa.local/bundle-sha: "${BUNDLE_SHA}"
    spec:
      containers:
        - name: git-daemon
          # Reuse the ArgoCD image (already pulled; its git ships git-daemon)
          image: quay.io/argoproj/argocd:${ARGOCD_VERSION}
          ports:
            - containerPort: 9418
          command:
            - sh
            - -c
            - |
              mkdir -p /tmp/git && tar -xzf /bundle/repo-bare.tar.gz -C /tmp/git
              exec git daemon --reuseaddr --export-all --base-path=/tmp/git --listen=0.0.0.0 --port=9418 /tmp/git
          volumeMounts:
            - name: bundle
              mountPath: /bundle
      volumes:
        - name: bundle
          configMap:
            name: git-mirror-bundle
---
apiVersion: v1
kind: Service
metadata:
  name: git-mirror
  namespace: argocd
spec:
  selector:
    app: git-mirror
  ports:
    - name: git
      port: 9418
      targetPort: 9418
EOF
  kubectl rollout status deployment/git-mirror -n argocd --timeout=600s >/dev/null
  log "mirror ready (bundle ${BUNDLE_SHA})"
fi

kubectl apply -f ./part-2-gitops/argocd/project.yaml >/dev/null

step "Applying ArgoCD Application (repoURL=${SYNC_REPO_URL}, image=${IMAGE_REPO}:${IMAGE_TAG})"
# The image built by 10-build-service.sh is injected as Helm parameters, so the
# chart in Git never has to be edited to roll out a new build.
render_application() {
  awk -v url="$SYNC_REPO_URL" -v repo="$IMAGE_REPO" -v tag="$IMAGE_TAG" '
    /^    repoURL:/ { print "    repoURL: " url; next }
    { print }
    /^      releaseName: quote-api/ {
      print "      parameters:"
      print "        - name: image.repository"
      print "          value: \"" repo "\""
      print "        - name: image.tag"
      print "          value: \"" tag "\""
    }' ./part-2-gitops/argocd/application.yaml
}
render_application | kubectl apply -f - >/dev/null

log "waiting for ArgoCD to create deployment/quote-api"
i=0
until kubectl get deployment quote-api -n quote-api >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -ge 45 ] && die "deployment/quote-api not created after 90s; inspect: kubectl -n argocd get application quote-api -o yaml"
  sleep 2
done
kubectl rollout status deployment/quote-api -n quote-api --timeout=120s >/dev/null

# spec.replicas is owned by the HPA, so the Deployment starts at 1 and the HPA
# raises it to minReplicas; wait for that before showing placement.
min=$(kubectl get hpa quote-api -n quote-api -o jsonpath='{.spec.minReplicas}' 2>/dev/null || true)
min=${min:-1}
log "waiting for ${min} ready replicas (HPA minReplicas)"
i=0
until [ "$(kubectl get deployment quote-api -n quote-api -o jsonpath='{.status.readyReplicas}')" -ge "$min" ] 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -ge 90 ] && die "fewer than ${min} ready replicas after 180s"
  sleep 2
done

step "Installing descheduler (restores the on-demand replica after HPA scale-in)"
helm repo add descheduler https://kubernetes-sigs.github.io/descheduler/ --force-update >/dev/null
run_logged "$LOG_DIR/helm-descheduler.log" helm upgrade --install descheduler descheduler/descheduler \
  --namespace kube-system \
  --version 0.37.0 \
  --values ./part-2-gitops/descheduler/values.yaml \
  --wait --timeout 10m

step "Pod placement (Spot preferred + On-Demand baseline)"
show_placement quote-api

step "Smoke test: GET /api/quote through the ingress"
# --retry-all-errors: Traefik answers 404 for a few seconds until it loads a new route
curl -fsS --retry 10 --retry-delay 2 --retry-all-errors "$(ingress_base_url)/api/quote"
echo
log "Part 2 GitOps deployment complete"
