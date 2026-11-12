# Part 4 — CI/CD Migration Notes (`MIGRATION-NOTES.md`)

We migrated the legacy GitLab CI pipeline (`ci/legacy.gitlab-ci.yml`) to GitHub Actions (`.github/workflows/ci.yml`, copy in `part-4-cicd/ci-cd.yml`) and replaced seven legacy practices, listed below.

---

## 1. What Changed from the Legacy Pipeline & Why

| Legacy Practice (`ci/legacy.gitlab-ci.yml`) | Problem / Risk | New Practice (`.github/workflows/ci.yml`) |
|---|---|---|
| **Hardcoded AWS credentials** (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` in `variables`) | Static credentials committed to Git are exposed to every repo reader and Git history clone. | Removed completely. Added custom Semgrep rule `no-hardcoded-aws-access-key` to block any future credential commits. |
| **`allow_failure: true` on `sonar_check`** | A static analysis job that cannot fail the pipeline is only decoration: vulnerable code still builds and deploys. | Replaced with a **Semgrep SAST** gate (`semgrep scan --error` with `p/nodejs`, `p/dockerfile`, and `.semgrep.yml`) that **hard-fails** on any finding. |
| **`npm test \|\| echo "tests flaky, continuing"`** | Swallowing non-zero exit codes allows broken builds to reach production. Also ran on EOL `node:16` with non-deterministic `npm install`. | Upgraded to **Node 24 LTS**, switched to `npm ci --ignore-scripts` with lockfile caching, and removed the `\|\| echo` mask so any test failure stops the build. |
| **Building & deploying mutable `:latest` tags** (`$IMAGE_NAME:latest`) | Mutable `:latest` tags break rollback determinism, auditability, and Kubernetes image caching (`IfNotPresent`). | Tagged images with immutable Git commit SHAs (`sha-<12-char-sha>` and full 40-char `$GITHUB_SHA`), pushed to `ghcr.io`. |
| **`only: [master]` on all jobs** | Defects were only discovered *after* merging to the default branch. | `unit-test`, `sast-semgrep`, and `trivy` container scanning run on every **Pull Request** as well as pushes to `main`/`master`. |
| **No container vulnerability scanning or image signing** | Vulnerable base images or tampered artifacts could be deployed undetected. | Added **Trivy** (`exit-code: "1"` on `HIGH,CRITICAL`) before registry push, plus **Cosign keyless OIDC signing** against the immutable image digest. |
| **Imperative `kubectl set image` using plaintext `$KUBECONFIG_CONTENT`** | Storing a cluster-admin kubeconfig in CI and mutating live Deployments causes drift against Git state. | Removed: CI has no cluster access. **ArgoCD** (`part-2-gitops/argocd/application.yaml`) reconciles the cluster from the Helm chart in Git. In this repo `scripts/20-deploy.sh` passes the new image tag to ArgoCD as a Helm parameter; in a team setup that step would be a CI job committing the tag to the GitOps repo (or ArgoCD Image Updater). |

Also new, with no legacy equivalent: `permissions: {}` by default with per-job grants (only the build job can write packages and request an OIDC token), every action pinned to a commit SHA (tags can be moved), and step outputs passed to shell via `env:` instead of `${{ }}` inside `run:` (avoids script injection). Both gates were run locally with the same tools before pushing: Semgrep 0 findings, Trivy 0 HIGH/CRITICAL.

---

## 2. How to Migrate GitLab CI Variables & Secrets for a Real Project

In a real production migration from GitLab CI to GitHub Actions, we do **not** simply copy-paste static secrets from GitLab CI/CD Variables into GitHub Repository Secrets:

1. **Inventory & Classify GitLab Variables:**
   - Export metadata (variable names, scope, protected/masked flags) via the GitLab Group/Project Variables API without writing secret values to disk.
   - Classify each variable into one of three buckets:
     - **Cloud Provider Credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`):** **Delete and replace with OIDC federation.** Configure an IAM OIDC Identity Provider for `token.actions.githubusercontent.com` in AWS with a trust policy scoped to `repo:<org>/<repo>:environment:production`, using `aws-actions/configure-aws-credentials` (pinned to a commit SHA) to get short-lived STS credentials.
     - **Container Registry Credentials (`CI_REGISTRY_USER`, `CI_REGISTRY_PASSWORD`):** **Replace with native ephemeral `secrets.GITHUB_TOKEN`** (`packages: write` permission) for GHCR, or OIDC-backed ECR login.
     - **Cluster Credentials (`KUBECONFIG_CONTENT`):** **Eliminate push-based cluster credentials from CI.** Switch to pull-based **ArgoCD** running inside the cluster so CI only needs permission to update the GitOps manifest repository.
     - **Third-Party API Tokens (e.g. `SONAR_TOKEN`, Slack webhooks):** Rotate the token at the provider, then store the new value in **GitHub Environments** (`staging`, `production`) with required reviewers and branch protection rules, or fetch dynamically at workflow runtime from AWS Secrets Manager / HashiCorp Vault via OIDC.
2. **Revoke Legacy Credentials:**
   - Immediately deactivate and delete all legacy IAM users/keys and GitLab runner tokens once cutover is verified.

