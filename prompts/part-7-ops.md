# Part 7: Ops answers

Produces `OPS-ANSWERS.md` (copy in `part-7-ops/`).

## Build prompt

```text
Answer the four questions in OPS-ANSWERS.md in at most 1.5 pages (about 800 words),
because the assignment sets that limit and a long answer reads as padding. Use short
numbered steps and a reason for each step, not general advice.

1. EKS 1.33 -> 1.35 without downtime: two hops, because minor versions cannot be
   skipped. Order: pre-flight checks (removed APIs, PDBs) -> control plane -> add-ons
   (vpc-cni, then kube-proxy and coredns, then CSI drivers) -> nodes (Karpenter drift
   creates new nodes before draining old ones) -> let it run a day, then repeat. Top 3
   risks: PDBs that block drains, subnet IP exhaustion during the node surge, and
   single-replica webhooks with failurePolicy Fail.

2. Spot reclaims paging at 3 AM: remove the cause first (Karpenter interruption
   handling or Node Termination Handler deletes the Node before it goes unreachable),
   then page only for on-demand nodes, and still page for real problems: many spot
   nodes lost at once, capacity below baseline, pods Pending too long, SLO burn.

3. Mobile LCP 5 s behind Cloudflare: check cf-cache-status with a mobile user agent
   (HTML is not cached by default), then the origin's own headers (Set-Cookie,
   Cache-Control), then the cache rule and cache key (query strings, device type),
   then, once HTML is a cache hit, the page itself (hero image, blocking scripts).

4. Secrets on EKS: compare External Secrets Operator vs the Secrets Store CSI driver
   (compatibility with env vars and charts, behavior when the AWS API throttles,
   rotation, where the secret ends up). Pick ESO for a startup with several clusters
   and say how to cover its downside (secrets in etcd: KMS encryption and RBAC).
```

## Review prompt

```text
The first draft was about 1,400 words, almost twice the limit. Cut repetition and
general statements, keep every decision and its reason, and check the word count.
```
