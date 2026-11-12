# Part 7 — Operations Questions (`OPS-ANSWERS.md`)

## 1. Zero-Downtime EKS Upgrade `1.33` → `1.35`

Minor versions cannot be skipped: run two hops (`1.33 → 1.34`, bake, then `1.34 → 1.35`), staging first.

**Order (per hop):**
1. **Pre-flight:** `kubent`/`pluto` for removed APIs, zero blocking findings in EKS Cluster Insights, every critical workload has `replicas >= 2`, a sane PDB and spread constraints.
2. **Control plane:** upgrade via Terraform/AWS API (AWS replaces API servers/etcd in place; the data plane keeps running).
3. **Add-ons, in order:** `vpc-cni` → `kube-proxy` + `coredns` (≥2 replicas, spread) → EBS/EFS CSI drivers; verify volume attach/mount.
4. **Nodes:** bump the `EC2NodeClass` AMI version; Karpenter drift launches new nodes *before* draining old ones, within `disruption.budgets` (e.g. `10%`). Managed node groups: surge update, `maxUnavailable: 1`.
5. **Bake 24–48 h** on golden signals (5xx, latency, DNS errors, IP allocation), then repeat for `1.35`.

**Top 3 risks:**
1. **PDBs that block drains** (`maxUnavailable: 0`, `minAvailable: 100%`) stall node rotation until forced termination causes downtime. → Audit PDBs before starting.
2. **Subnet IP exhaustion / CNI skew during surge** leaves new pods in `ContainerCreating`. → Check free IPs, enable prefix delegation.
3. **Single-replica webhooks with `failurePolicy: Fail`** (cert-manager, Kyverno, Istio) on a draining node block all pod creation. → ≥2 replicas, anti-affinity, PDB.

## 2. Killing 3 AM Spot `KubeNodeUnreachable` Storms

A reclaimed spot VM disappears after its 2-minute notice; if the `Node` object lingers, it turns `Ready=Unknown` and fires `KubeNodeUnreachable` for an expected event.

1. **Remove the cause:** Karpenter's interruption queue (or AWS Node Termination Handler) cordons, drains and **deletes the Node** on the EventBridge interruption warning, so it rarely becomes unreachable.
2. **Split severity by capacity type:** join the unreachable taint with `kube_node_labels{label_karpenter_sh_capacity_type}`:
   - On-demand node unreachable `for: 3m` → **page** (these should not vanish).
   - Single spot node → **ticket/info only**.
3. **Still catch real failures:** page on `SpotPoolMassFailure` (>25% of spot nodes NotReady within 5 min, or ready capacity below baseline for 5 min = Karpenter cannot replace), and on workload impact (pods `Pending` > 5 min, SLO burn on error rate/latency).

## 3. Mobile LCP 5 s Behind Cloudflare (Suspected HTML Cache Miss)

1. **Edge headers with a mobile UA:**
   `curl -sI -A "Mozilla/5.0 (iPhone...) Mobile" https://www.example.com/ | grep -iE "cf-cache-status|cache-control|age|set-cookie|vary"`
   Cloudflare does **not** cache HTML by default. `DYNAMIC` = no cache rule; `BYPASS` = origin sent `Set-Cookie` or `private/no-store`; repeated `MISS` = cache-key fragmentation (`utm_*`, `gclid`, `Vary`).
2. **Origin headers directly:** `curl -sI --resolve www.example.com:443:<ORIGIN_IP> https://www.example.com/`. Look for `Set-Cookie` on anonymous pages or `Cache-Control: private/max-age=0`; with "Respect origin" Edge TTL these force a bypass.
3. **Rules and cache key:** use Cloudflare Trace with a mobile UA and `?gclid=123`. Expect a cache rule that makes HTML eligible, overrides Edge TTL (e.g. 1 h + stale-while-revalidate) and drops marketing query params from the key. Check *Cache by Device Type* (cold mobile bucket) and that Tiered Cache is on.
4. **Separate TTFB from rendering:** once `HIT` with TTFB < 80 ms, profile on throttled 4G (WebPageTest/DevTools). If LCP is still slow, it is the hero image (`fetchpriority="high"`, preload, modern format) or render-blocking third-party JS, not caching.

## 4. Application Secrets on EKS

| | **A: External Secrets Operator + AWS Secrets Manager** | **B: Secrets Store CSI Driver + AWS provider** |
|---|---|---|
| Mechanism | Controller (IRSA/Pod Identity) syncs into native K8s `Secret`s | Kubelet mounts secrets as `tmpfs` volumes at pod start |
| Compatibility | `envFrom`/`secretKeyRef`/Helm charts work unchanged | Needs volumes per workload; env vars need `Secret` mirroring anyway |
| AWS API outage/throttling | Pods keep starting (secret cached in etcd) | Every new pod calls AWS; scale-outs stall in `ContainerCreating` |
| Rotation | `refreshInterval` + Reloader rolling restart | Files update, but env-var apps never see new values |
| Exposure | Secrets in etcd: needs KMS envelope encryption + tight RBAC | Can avoid etcd if mirroring is off |

**Pick: ESO + AWS Secrets Manager (with EKS Pod Identity).** For a startup with several production clusters it keeps Git free of secret material (only `ExternalSecret` manifests), works with every existing chart and env-var app, survives AWS API throttling during HPA scale-outs, and centralises shared secrets with least-privilege IAM per namespace. Compensate for the etcd copy with KMS encryption and RBAC that denies `get/list secrets` to non-admins.
