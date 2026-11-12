# shellcheck shell=sh
# lib.sh — shared helpers for the numbered scripts.
# Source it first thing:   . "$(dirname "$0")/lib.sh"

SCRIPT_NAME=$(basename "$0")
SCRIPT_TAG=$(basename "$0" .sh)
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

CLUSTER_NAME="${CLUSTER_NAME:-elsa}"
INGRESS_PORT="${INGRESS_PORT:-8080}"

# Outside the toolbox, never use (or overwrite) the user's own ~/.kube/config,
# which may point at a real cluster: use a project-local, git-ignored kubeconfig.
if [ ! -f /.dockerenv ]; then
  KUBECONFIG="${REPO_ROOT}/.kube/config"
  export KUBECONFIG
fi
LOG_DIR="${LOG_DIR:-/tmp/elsa-logs}"
mkdir -p "$LOG_DIR"

step() { printf '\n==> [%s] %s\n' "$SCRIPT_TAG" "$*"; }
log()  { printf '    %s\n' "$*"; }
warn() { printf '    WARN: %s\n' "$*" >&2; }
die()  { printf '    ERROR [%s]: %s\n' "$SCRIPT_TAG" "$*" >&2; exit 1; }

# run_logged <logfile> <cmd...>
# Runs a noisy command with its output captured in <logfile>; prints the tail
# of the log only when the command fails.
run_logged() {
  _logfile="$1"; shift
  if "$@" >"$_logfile" 2>&1; then
    log "ok (full log: $_logfile)"
  else
    _rc=$?
    tail -n 40 "$_logfile" >&2
    die "command failed (exit $_rc): $1 ... (full log: $_logfile)"
  fi
}

# When invoked from the host while the elsa-toolbox container is running,
# re-execute the same script inside the toolbox (which has every CLI installed).
delegate_to_toolbox() {
  [ "${IN_TOOLBOX:-0}" = "1" ] && return 0
  [ -f /.dockerenv ] && return 0
  command -v docker >/dev/null 2>&1 || return 0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'elsa-toolbox' || return 0
  # Stop Git Bash on Windows from rewriting the container path
  MSYS_NO_PATHCONV=1
  export MSYS_NO_PATHCONV
  # Run through `sh` so the script works even if Git lost its executable bit
  # Forward the settings scripts read (only those set on the host are passed)
  exec docker exec -e GHCR_USER -e GHCR_TOKEN -e GHCR_IMAGE -e CLUSTER_NAME -e INGRESS_PORT \
    elsa-toolbox sh "/workspace/scripts/${SCRIPT_NAME}" "$@"
}

# Base URL of the cluster ingress, reachable from wherever this script runs.
ingress_base_url() {
  if [ -f /.dockerenv ]; then
    echo "http://k3d-${CLUSTER_NAME}-serverlb:80"
  else
    echo "http://localhost:${INGRESS_PORT}"
  fi
}

# git wrapper that tolerates the bind-mounted repo being owned by another UID
git_repo() { git -c safe.directory="$REPO_ROOT" -C "$REPO_ROOT" "$@"; }

# Same naming as CI: ghcr.io/<owner>/<repo>/quote-api, derived from the GitHub
# remote so there is no hard-coded organisation. GHCR_IMAGE overrides it.
image_repo() {
  if [ -n "${GHCR_IMAGE:-}" ]; then echo "$GHCR_IMAGE"; return; fi
  _url=$(git_repo config --get remote.origin.url 2>/dev/null || true)
  case "$_url" in
    *github.com[:/]*)
      _slug=$(printf '%s' "$_url" | sed -E 's#^.*github\.com[:/]##; s#\.git$##' | tr 'A-Z' 'a-z')
      echo "ghcr.io/${_slug}/quote-api" ;;
    *) echo "ghcr.io/local/quote-api" ;;   # no GitHub remote: image only lives in k3d
  esac
}

# Content hash of everything that goes into the image
_src_hash() {
  (cd "$REPO_ROOT/part-1-service" && find Dockerfile .dockerignore package.json package-lock.json src -type f |
    LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-12)
}

# Immutable tag: sha-<git sha> (same as CI) on a clean checkout, otherwise
# suffixed/derived from a content hash so a different build never reuses a tag.
image_tag() {
  if _sha=$(git_repo rev-parse --short=12 HEAD 2>/dev/null); then
    if [ -n "$(git_repo status --porcelain -- part-1-service)" ]; then
      echo "sha-${_sha}-dirty.$(_src_hash)"
    else
      echo "sha-${_sha}"
    fi
  else
    echo "src-$(_src_hash)"
  fi
}

# show_placement [namespace]
# One compact table: pod -> ready -> node -> capacity pool, plus a per-pool count.
show_placement() {
  _ns="${1:-quote-api}"
  NODES=$(kubectl get nodes --no-headers \
    -o custom-columns='N:.metadata.name,C:.metadata.labels.acme\.io/capacity,T:.metadata.labels.acme\.io/node-type,U:.spec.unschedulable')
  export NODES
  kubectl get pods -n "$_ns" --no-headers \
    -o custom-columns='P:.metadata.name,R:.status.containerStatuses[0].ready,N:.spec.nodeName' |
  awk '
    BEGIN {
      n = split(ENVIRON["NODES"], rows, "\n")
      for (i = 1; i <= n; i++) {
        split(rows[i], f, " ")
        pool[f[1]] = (f[2] != "<none>") ? f[2] : ((f[3] != "<none>") ? f[3] : "-")
        if (f[4] == "true") pool[f[1]] = pool[f[1]] " (cordoned)"
      }
      printf "    %-36s %-6s %-24s %s\n", "POD", "READY", "NODE", "POOL"
    }
    {
      p = ($3 in pool) ? pool[$3] : "-"
      printf "    %-36s %-6s %-24s %s\n", $1, $2, $3, p
      split(p, q, " "); count[q[1]]++
    }
    END {
      s = ""; for (k in count) s = s sprintf("%s=%d ", k, count[k])
      printf "    pods per pool: %s\n", s
    }'
}
