# Part 1: Service and image

Builds `part-1-service/` and `scripts/10-build-service.sh`.

## Build prompt: the API

```text
Write a small Node.js + Express service in part-1-service/src/index.js (about 150 lines).
Node and Express because they are widely known and keep the code short.

Endpoints:
- GET /healthz: liveness, always 200 while the process runs.
- GET /readyz: 200 normally, 503 after SIGTERM, so Kubernetes stops sending traffic
  before the pod exits (graceful drain during rollouts and node drains).
- GET /metrics: prom-client with default metrics, a counter
  quote_api_http_requests_total and a histogram quote_api_http_request_duration_seconds,
  labeled by method, route and status_code. The histogram is what the Part 6
  latency alert and dashboard need.
- GET /api/quote: random quote as JSON plus pod name and timestamp (the pod name
  shows load balancing), after about 100 ms of real CPU work, so the HPA in Part 6
  scales on CPU.

Use the route template as the metric label and a single "unmatched" value for unknown
paths, because labeling with the raw URL lets a 404 scan create unlimited series.

Tests with the built-in node:test runner, because it needs no extra dependencies.
```

## Review prompt: the CPU work blocks health checks

```text
If the 100 ms of CPU work is one synchronous loop, 20 concurrent requests block the
event loop for about 2 seconds. /healthz and /readyz would then time out under load
and Kubernetes would restart healthy pods.

Keep the real CPU cost (pbkdf2) but run it in 10 ms slices with
`await new Promise(r => setImmediate(r))` between them. Each request still uses
100 ms of CPU, but probes and /metrics get answered between slices.
```

## Build prompt: image and build script

```text
part-1-service/Dockerfile, two stages:
1. node:24-trixie-slim: copy package.json + package-lock.json, run
   `npm ci --omit=dev --ignore-scripts` (exact lockfile versions, no dev deps,
   no install scripts from dependencies).
2. gcr.io/distroless/nodejs24-debian13:nonroot: copy node_modules, package.json and
   src only. Distroless has no shell or package manager, which keeps the image small
   and the attack surface low; nonroot runs as UID 65532.
Add a .dockerignore so node_modules and tests never enter the build context.

scripts/10-build-service.sh:
- Name the image the same way CI does, ghcr.io/<owner>/<repo>/quote-api, derived
  from the git remote, so the local build and the CI build are the same image name.
- Tag sha-<12-char commit>. If part-1-service has uncommitted changes, add a content
  hash, because the same tag must never mean two different images.
- Push only when GHCR credentials are set; always `k3d image import`, so the cluster
  never needs registry access.
- Do not edit tracked files; the tag reaches the cluster through 20-deploy.sh.
```

## Review prompt: base image vulnerabilities

```text
Run the same Trivy gate CI uses (HIGH/CRITICAL, ignore-unfixed) on the built image.
It fails on the Node 20 / Debian 12 distroless base: OpenSSL has fixable CRITICAL
and HIGH findings. Node 20 is end of life and the Debian 12 distroless images no
longer get updates. Scan the Debian 13 alternatives and switch to Node 24
(nodejs24-debian13), because it scans clean and is supported the longest. Update
engines, CI's node-version and the docs to match.
```
