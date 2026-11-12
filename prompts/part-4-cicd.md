# Part 4: GitLab CI to GitHub Actions

Produces `.github/workflows/ci.yml` (copy in `part-4-cicd/ci-cd.yml`), `.semgrep.yml`, `MIGRATION-NOTES.md` and `scripts/40-verify-ci.sh`.

## Build prompt: what not to carry over

```text
Read ci/legacy.gitlab-ci.yml and list the practices we must not copy:
hardcoded AWS keys, a quality job with allow_failure, tests on EOL node:16 with
`npm install` and `|| echo` hiding failures, images pushed only as :latest, jobs
limited to master (no checks on merge requests), and a deploy job that writes a
kubeconfig from a variable and runs `kubectl set image ...:latest`.

Then write .github/workflows/ci.yml with three jobs:
- unit-test: Node 24, `npm ci --ignore-scripts`, `npm test`, with no way to soft-fail.
- sast-semgrep: Semgrep with p/nodejs, p/dockerfile and our .semgrep.yml, with
  --error, so any finding fails the run (the assignment's main point for this part).
- build-scan-push: build the image once and load it, scan that image with Trivy
  (HIGH/CRITICAL, exit code 1), then push the same image and sign its digest with
  Cosign keyless. Building twice would mean the pushed image is not the one scanned.
Run on pull requests too, and push/sign only on main, because PR code should be
checked but not published.

Security basics:
- `permissions: {}` at the top and per-job grants, because only the build job needs
  packages:write and id-token:write.
- Pin every action to a commit SHA (with the version in a comment), because tags can
  be moved.
- Pass step outputs to shell through env variables, not ${{ }} inside `run:`.
```

## Review prompt: test the gates themselves

```text
A gate that never fires looks the same as a gate that passes. Check them:
- The custom rule that should catch child_process.exec used two `pattern:` entries
  under `patterns:`, which Semgrep combines with AND. No call matches both, so the rule
  never fired. Use pattern-either and cover `require(...).exec`, a variable holding the
  module, and destructured `exec`. Test it on a file with 4 bad and 2 safe cases.
- Run Trivy locally on the built image with the CI settings, before pushing.
- 40-verify-ci.sh must ignore YAML comments when checking for `|| echo` and
  `continue-on-error`, otherwise the comment describing the old pipeline fails the check.
  Also make it fail when an action is not pinned to a SHA, and test that with a copy
  that contains an unpinned action.
```

## Build prompt: migration notes

```text
MIGRATION-NOTES.md: a table of each legacy practice, why it is a problem and what
replaced it. Then a short plan for moving GitLab variables in a real project: AWS keys
become GitHub OIDC role assumption (no stored keys), registry passwords become the
built-in GITHUB_TOKEN, the deploy kubeconfig goes away because ArgoCD pulls from Git,
and any remaining third-party tokens go into protected GitHub Environments and are
rotated at cutover, because the old values were visible to everyone with GitLab access.
```
