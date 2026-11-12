# Part 6 — Load Test, Scaling Proof & Bottleneck Analysis (`LOADTEST.md`)

## 1. Baseline & Measured Capacity

All numbers below were measured on 2026-11-12 on Docker Desktop with **4 vCPU / 8 GB** shared by the 5 k3d nodes, ArgoCD, kube-prometheus-stack and k6 itself.

- **Single-Request Baseline (1 VU, 30 s, 268 requests):** `GET /api/quote` executes `100ms` of deterministic PBKDF2 SHA-256 CPU work in 10ms yielded slices. Unloaded response time through the Traefik Ingress is **P50 = 105ms, P95 = 139ms, P99 = 145ms** (0% errors).
- **Single-Replica Ceiling:** Each `quote-api` pod has `resources.requests.cpu = 100m` and `resources.limits.cpu = 500m` (`0.5` vCPU). At `100ms` CPU time per request, 1 replica saturates its `500m` CFS bandwidth quota at:
  $$\text{Max RPS}_{\text{pod}} = \frac{0.5\text{ cores}}{0.100\text{ core-seconds/req}} = 5.0\text{ RPS}$$
- **Max Sustainable RPS on Local 4-Worker Cluster:**
  - At **3 initial replicas** the ceiling is the CPU limit: 3 × 5 RPS ≈ **15 RPS**.
  - Under the `k6` ramp (`scripts/60-loadtest.sh`, up to 20 VUs, 115 s), HPA (`averageUtilization: 60` of the `100m` request = `60m` CPU per pod) scales the Deployment **3 → 10 replicas in ~75 seconds**.
  - At **10 replicas** the service peaks at **~48 RPS** (Grafana request-rate panel). Three full k6 runs: **3,839 / 4,023 / 4,031 requests, 0.00% errors, P50 = 132–145ms, P95 = 275–316ms, P99 = 396–436ms**, average 33–35 RPS over the whole ramp including warm-up and cool-down. All thresholds (`p(95)<450`, `p(99)<850`, `http_req_failed<1%`, `checks>99%`) passed.

## 2. HPA Scale-Out & Spot/On-Demand Placement Proof

HPA log written by `./scripts/60-loadtest.sh` (it records only changes; `cpu` is utilisation of the 100m request):

```text
05:55:25  replicas=3 desired=3 cpu=8%
05:55:40  replicas=3 desired=3 cpu=10%
05:55:56  replicas=3 desired=3 cpu=54%
05:56:11  replicas=3 desired=5 cpu=252%
05:56:27  replicas=5 desired=7 cpu=459%
05:56:43  replicas=7 desired=9 cpu=459%
05:56:59  replicas=9 desired=10 cpu=391%
05:57:15  replicas=10 desired=10 cpu=329%
```

Pod placement at peak scale (`10/10` replicas) respects the Part 2 policy. The hard capacity spread (`maxSkew: 2`) allows at most a 6/4 split, which is exactly what the scheduler chose:

| Worker Node | Pool Label | Running `quote-api` Replicas |
|---|---|---|
| `k3d-elsa-agent-0` | `acme.io/capacity=spot` | 3 |
| `k3d-elsa-agent-1` | `acme.io/capacity=spot` | 3 |
| `k3d-elsa-agent-2` | `acme.io/capacity=on-demand` | 4 |
| `k3d-elsa-agent-3` | `acme.io/node-type=gpu` (tainted) | 0 |

Screenshot taken **during** a load run (RPS ramping, HPA 3 → 10): [`part-6-loadtest/monitoring/grafana-dashboard-under-load.png`](part-6-loadtest/monitoring/grafana-dashboard-under-load.png).

## 3. Alert Threshold (`QuoteApiHighLatencyP95`, P95 > 450ms for 2m)

The unloaded P95 is 139ms, and the worst P95 during a normal HPA scale-out (3 -> 10 pods, three runs) was 316ms, so a healthy scale-out stays under 450ms. Each pod serves about 5 RPS (0.5 CPU / 0.1 CPU per request); when load keeps exceeding replicas x 5 RPS (HPA at maxReplicas, pods throttled, nodes full), requests queue and P95 rises past 450ms and stays there. Requiring 2 minutes above the threshold means the alert fires on that sustained saturation, not on the short bump while the HPA adds pods (about 75s measured). A second rule pages when more than 1% of requests return 5xx for 1 minute ([`prometheusrule.yaml`](part-6-loadtest/monitoring/prometheusrule.yaml)).

## 4. Where the Bottleneck Is & What to Scale First in Production

1. **Primary Bottleneck — Application CPU & CFS Bandwidth Throttling (`500m` limit):**
   - Neither Traefik Ingress nor network I/O is the bottleneck (payloads are `< 250 bytes`). The bottleneck is **CPU compute time per request (`100ms`)**: at 3 replicas it is the `500m` container CPU limit (`container_cpu_cfs_throttled_periods_total`).
   - At 10 replicas each pod used only ~0.35–0.4 cores (below its 0.5 limit), so the limit is no longer the cap: 10 × ~0.4 cores ≈ the 4 vCPU of the whole Docker VM, which also runs k6, Prometheus and the control plane. **On this machine the next bottleneck is node capacity**, which is why scaling nodes (Karpenter) comes right after per-pod tuning below.
2. **What We Would Scale First in Production & Why:**
   - **Step 1 (Immediate — Raise Pod CPU Request/Limit to `1000m` + Offload Crypto to `worker_threads`):** Raising each pod to 1 full vCPU doubles single-pod capacity to ~10 RPS and eliminates sub-100ms Linux CFS period throttling latency spikes. Moving CPU-bound work into a bounded Node.js `worker_threads` pool prevents event-loop slice queuing.
   - **Step 2 (Horizontal — HPA + Karpenter Spot Auto-Provisioning):** Increase HPA `maxReplicas` from `10` to `50+` backed by a Karpenter compute-optimized `c7i`/`c7g` Spot + On-Demand `NodePool` so cluster vCPU capacity scales elastically with replica count.
   - **Step 3 (Architectural — Edge/Redis Caching if Quotes Are Non-Unique):** Serving random quotes from a short-TTL cache or Cloudflare Worker removes the 100ms origin CPU cost entirely for >95% of requests.

