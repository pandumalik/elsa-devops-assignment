# Part 3: Troubleshooting

Produces `troubleshoot/fixed-app.yaml` (copy in `part-3-troubleshoot/`), `TROUBLESHOOTING.md` and `scripts/30-troubleshoot.sh`.

## Build prompt: find every issue

```text
Read the four provided files in troubleshoot/ (prepare.sh, broken-app.yaml,
smoke-job.yaml, verify.sh) and list every reason verify.sh does not print PASS.
Read verify.sh first, because it defines what "fixed" means, including two rules:
- the default-deny NetworkPolicy must stay; add allow rules instead,
- node labels and taints must not change; fix the workloads instead.
For each issue give the symptom, the command that shows it, the root cause and the fix.
```

## Review prompt: DNS is blocked too

```text
default-deny covers both Ingress and Egress for every pod in the namespace. Allowing
TCP 80 from app=smoke-client to app=web is not enough: the smoke client first has to
resolve web-svc.troubleshoot.svc.cluster.local, and that DNS query is egress.

So the fix needs two least-privilege policies:
- allow-web-ingress: TCP 80 into app=web, only from app=smoke-client,
- allow-smoke-egress: from app=smoke-client to CoreDNS (k8s-app=kube-dns in
  kube-system) on UDP and TCP 53, and to app=web on TCP 80.
Keep the policies this narrow, because the point of default-deny is that nothing
else is allowed.

The other fixes: nginx tag that does not exist, a 16Gi memory request no node can fit,
wrong ConfigMap name, probes on 8080 instead of 80, Service selector and targetPort
mismatch, and the GPU workload's nodeSelector key and missing toleration.
```

## Build prompt: write-up and script

```text
TROUBLESHOOTING.md: one section per issue with the same four parts: symptom, the exact
commands used to diagnose it and what they showed, root cause, fix. The assignment
says the narrative matters as much as the fix, so describe how each issue was found.

scripts/30-troubleshoot.sh: apply troubleshoot/fixed-app.yaml and run verify.sh.
```
