# Prompts (`prompts/`)

These are the prompts used to build this repo with an AI assistant, one file per part. They are written the way I would brief a colleague: what to build, and why each choice was made, so the assistant (or a reviewer) can judge the result against the reason, not just the instruction.

Each file has:
- **Build prompts**: what to create and the reasoning behind each decision.
- **Review prompts**: follow-ups that caught real mistakes in the first answer, and what the fix was.

| File | Scope |
|---|---|
| [part-0-harness.md](part-0-harness.md) | Compose harness, toolbox image, bootstrap, `run-all.sh`, README and AI-USAGE |
| [part-1-service.md](part-1-service.md) | Node.js service, tests, distroless Dockerfile, build script |
| [part-2-gitops.md](part-2-gitops.md) | Helm chart, ArgoCD, spot/on-demand placement, reclaim drill |
| [part-3-troubleshoot.md](part-3-troubleshoot.md) | Fixing `troubleshoot/broken-app.yaml`, NetworkPolicies, `TROUBLESHOOTING.md` |
| [part-4-cicd.md](part-4-cicd.md) | GitLab CI to GitHub Actions, Semgrep, Trivy, Cosign, `MIGRATION-NOTES.md` |
| [part-5-iac.md](part-5-iac.md) | Karpenter GPU NodePools, Cloudflare Terraform |
| [part-6-loadtest.md](part-6-loadtest.md) | Prometheus, Grafana, k6, HPA evidence, `LOADTEST.md` |
| [part-7-ops.md](part-7-ops.md) | Written ops answers (`OPS-ANSWERS.md`) |
| [part-8-local-tooling.md](part-8-local-tooling.md) | Optional helpers: stop, cleanup, Headlamp, in-cluster network test |
