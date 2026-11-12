# AI Usage Disclosure

How AI tools were used, three prompts that helped, and the cases where the AI was wrong and how that was caught. The full prompt set is in [prompts/](prompts/README.md).

## 1. Tools and scope

| Tool                                        | Used for                                                                                                                                                                                                                                                                             |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Antigravity (Gemini coding agent)** | First implementation of Parts 1–7: Express service, Karpenter v1 manifests, k6 script, scripts and docs.                                                                                                                                                                           |
| **Claude Code (Anthropic)**           | Review and hardening pass: found and fixed bugs (list in section 4), ran the CI gates locally (Semgrep, Trivy), ran the Golden Rule on a clean machine, measured the load-test numbers, captured the real Grafana screenshot, added the optional helper scripts and tidied the docs. |

AI output was accepted only after it ran: `npm test`, `helm lint`/`template`, `terraform validate`, Semgrep and Trivy locally, `troubleshoot/verify.sh`, the reclaim drill, a full `run-all.sh` from an empty Docker state, and three k6 runs.

## 2. Three prompts that helped

**Placement design (Part 2)**

> "We have 4 worker nodes: 2 spot, 1 on-demand, 1 GPU with taint `nvidia.com/gpu=true:NoSchedule`. For a 3-replica Deployment, combine node affinity and topology spread so that: pods never land on the GPU node even if untainted, spot is preferred, at least one pod is always on on-demand, and a drained spot node's pod reschedules instead of staying Pending."

Why it helped: it framed all four requirements at once, which exposed that they pull against each other (a hard rule guarantees on-demand but risks Pending pods; a soft rule never blocks but guarantees nothing). The final answer took two revisions; see mistake 2.

**Troubleshooting audit (Part 3)**

> "Cross-reference `broken-app.yaml`, `prepare.sh`, `smoke-job.yaml` and `verify.sh`. List every independent reason `verify.sh` does not print PASS, including network failures when `default-deny` is active."

Why it helped: it pointed out that `default-deny` also blocks egress, so the smoke client needs DNS egress (UDP/TCP 53 to CoreDNS) and not only TCP 80 to the web pods.

**Karpenter v1 (Part 5)**

> "Write a `karpenter.sh/v1` NodePool and `karpenter.k8s.aws/v1` EC2NodeClass for GPU inference, spot preferred with on-demand fallback. Check every v1 change from v1beta1: `nodeClassRef.group`, `amiSelectorTerms`, `consolidateAfter` with `consolidationPolicy`, and `spec.template.spec.expireAfter`."

Why it helped: listing the known v1 changes explicitly made the answer easy to check field by field.

## 3. Where the AI was wrong (first implementation)

### Mistake 1: blocking the event loop in `/api/quote`

- **Suggested:** a synchronous loop running `pbkdf2Sync` until 100 ms had passed.
- **Caught by:** reasoning about Part 6 load. Node runs JavaScript on one thread, so 20 concurrent requests block it for about 2 seconds, and `/healthz` and `/readyz` time out. Kubernetes would then mark healthy pods unready and restart them.
- **Fix:** the same CPU work in 10 ms slices with `await new Promise(r => setImmediate(r))` between them ([`part-1-service/src/index.js`](part-1-service/src/index.js)). Each request still uses about 100 ms of CPU, so the HPA still scales on it. Under the load tests no probe failed and every request succeeded.

### Mistake 2: topology spread for the on-demand replica (two wrong answers)

- **First suggestion:** `DoNotSchedule` with `maxSkew: 1` on `acme.io/capacity`. That forces a 50/50 split (5 of 10 pods on the single on-demand node), and with drained nodes still counted, pods could stay Pending.
- **First "fix":** switch both constraints to `ScheduleAnyway`. That never blocks, but it only *prefers* an on-demand pod, so it does not meet "at least one replica must always run on on-demand".
- **Final design:** hard again, but `maxSkew: 2` (3/0 is impossible, spot keeps the majority), `nodeTaintsPolicy: Honor` (drained nodes stop counting, so nothing goes Pending when both spot nodes are drained) and `matchLabelKeys: [pod-template-hash]` (holds during rolling updates). The hostname spread stays soft.
- **Then testing found one more gap:** after an HPA scale-in all 3 pods were on spot, because spread rules are only checked at scheduling time. A descheduler now restores the on-demand pod (measured: about 30 s).
- **Lesson:** a fix for an AI mistake needs the same testing as the original suggestion.

### Mistake 3: v1beta1 fields in Karpenter v1

- **Suggested:** `expireAfter` under `spec.disruption`, and `nodeClassRef` without `group`.
- **Caught by:** checking against the v1 API: `expireAfter` moved to `spec.template.spec`, `nodeClassRef` needs `group`, `kind` and `name`, and `consolidateAfter` is required with `consolidationPolicy`.
- **Fix:** [`part-5-iac/karpenter/gpu-nodepool.yaml`](part-5-iac/karpenter/gpu-nodepool.yaml) follows the v1 schema.

## 4. Issues found in the review pass

All of these were in AI-written code that looked correct; each was found by running something.

| Area   | Problem                                                                                                       | How it was found                      | Fix                                                           |
| ------ | ------------------------------------------------------------------------------------------------------------- | ------------------------------------- | ------------------------------------------------------------- |
| Part 1 | `Dockerfile` and `.dockerignore` were empty files                                                         | file listing (0 bytes)                | wrote the two-stage distroless build                          |
| Part 1 | Node 20 / Debian 12 base had 1 CRITICAL + 6 HIGH                                                              | Trivy with the CI settings            | Node 24 / Debian 13 (0 findings)                              |
| Part 2 | ArgoCD never synced: core install has no `default` project                                                  | clean-machine run                     | least-privilege `AppProject`                                |
| Part 2 | Local git mirror served "dumb HTTP", which ArgoCD's go-git cannot read                                        | clean-machine run                     | `git daemon` (`git://`)                                   |
| Part 2 | Image tag written into Git could never match the commit, so ArgoCD would deploy an image that was never built | reading the deploy flow               | tag passed as an ArgoCD Helm parameter                        |
| Part 4 | Custom Semgrep rule combined two patterns with AND, so it could never fire                                    | test file with 4 bad and 2 safe cases | `pattern-either`                                            |
| Part 4 | `40-verify-ci.sh` failed on its own workflow comment                                                        | running it                            | ignore YAML comments                                          |
| Part 5 | Karpenter key `instance-gpu-Count` (keys are lowercase)                                                     | review                                | `instance-gpu-count`, plus a check in `50-validate-tf.sh` |
| Part 6 | The dashboard "screenshot" was a hand-drawn SVG and LOADTEST numbers were not from a run                      | review                                | real screenshot during a run, measured numbers                |
| Part 6 | Grafana 13 timed out on first start (250m CPU), and an old headless browser could not load its plugins        | clean-machine run, screenshot attempt | 1 CPU limit and pinned chart; current Playwright              |
| Part 7 | OPS-ANSWERS was about 1,400 words for a 1.5-page limit                                                        | word count                            | trimmed to about 700 words                                    |
