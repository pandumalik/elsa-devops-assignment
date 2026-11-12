# Part 1: quote-api service

Node.js 24 + Express HTTP API, packaged as a two-stage image on Google distroless (`gcr.io/distroless/nodejs24-debian13:nonroot`).

## Endpoints

| Path | Purpose | Behaviour |
|---|---|---|
| `GET /healthz` | Liveness probe | `200 {"status":"ok"}` while the process runs |
| `GET /readyz` | Readiness probe | `200` normally; `503` after SIGTERM, so Kubernetes stops routing traffic before the pod exits |
| `GET /metrics` | Prometheus scrape | Default process metrics plus `quote_api_http_requests_total`, `quote_api_http_request_duration_seconds` and `quote_api_cpu_work_duration_seconds`. The `route` label uses route templates; unknown paths share one `unmatched` value so 404 scans cannot create unlimited series |
| `GET /api/quote` | The API | About 100 ms of PBKDF2 CPU work in 10 ms slices (yielding between slices so probes are answered under load), then a random quote with the pod name and a timestamp |

## Image

- **Stage 1** (`node:24-trixie-slim`): `npm ci --omit=dev --ignore-scripts` installs exactly the locked production dependencies.
- **Stage 2** (`gcr.io/distroless/nodejs24-debian13:nonroot`): only the Node runtime, `node_modules`, `package.json` and `src/`. No shell, no package manager, runs as UID 65532. Trivy (HIGH/CRITICAL, fixable only): 0 findings.
- **Tag:** `ghcr.io/<owner>/<repo>/quote-api:sha-<12-char git sha>`, built by `scripts/10-build-service.sh` locally and by `.github/workflows/ci.yml` in CI.

## Tests

`npm test` (Node's built-in test runner): the four endpoints, about 100 ms of CPU work per quote, and the `unmatched` route label.
