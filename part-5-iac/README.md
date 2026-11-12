# Part 5 — IaC Design: Karpenter GPU NodePools & Cloudflare Terraform

## 5a — Karpenter (`karpenter/gpu-nodepool.yaml`)

Uses the **current stable Karpenter v1 API** (`karpenter.sh/v1` `NodePool` and `karpenter.k8s.aws/v1` `EC2NodeClass`):
- **Spot Preferred + On-Demand Fallback:** Implemented using two weighted `NodePool` resources referencing the `gpu-inference` `EC2NodeClass`:
  - `gpu-inference-spot` (`weight: 80`, `karpenter.sh/capacity-type: spot`) is evaluated first by Karpenter.
  - `gpu-inference-ondemand` (`weight: 20`, `karpenter.sh/capacity-type: on-demand`) is used when the spot pool cannot launch a node, for example when EC2 has no spot capacity for `g5`/`g6`/`g6e`.
- **Pinned AMI:** `amiSelectorTerms` uses `alias: bottlerocket@v1.69.0` (not `@latest`), so a new AMI release never drifts production GPU nodes without a reviewed change. The AMI family is implied by the alias.
- **Taint Protection:** Both NodePools apply `nvidia.com/gpu=true:NoSchedule` so non-GPU workloads never consume expensive GPU instances.
- **Consolidation only when empty (`consolidationPolicy: WhenEmpty`):** inference pods hold model weights in GPU memory and serve long requests, so Karpenter should not evict them just to pack pods onto fewer nodes (`WhenEmptyOrUnderutilized` would). With `WhenEmpty` + `consolidateAfter: 5m`, consolidation only removes nodes that have no inference pods left. Nodes are still replaced on purpose by `expireAfter` (7 days spot, 30 days on-demand), by drift (for example a new pinned AMI), and of course by spot reclaims; those go through a normal drain that respects PDBs, so the workload needs a PDB and enough replicas.

### Spot vs. On-Demand Trade-Off for AI Inference Workloads

Spot GPU instances (`g5`, `g6`, `g6e`) offer **60–70% cost savings** over On-Demand pricing, which is substantial given the high hourly cost of NVIDIA A10G/L4/L40S accelerators, but they carry two acute operational risks for AI inference: **long cold-start times** (pulling 15–50 GB container images and loading model weights into GPU VRAM takes 2–5 minutes, which exceeds AWS's 2-minute EC2 Spot interruption warning) and **correlated regional capacity droughts** during peak hours. Consequently, running 100% Spot for synchronous, user-facing inference risks latency spikes or dropped requests during reclaims. A practical pattern is an **on-demand baseline** sized for steady traffic, with autoscaled replicas and batch inference on **several spot GPU families** (`g5`, `g6`, `g6e`) so one family's shortage does not stop scaling. Cold starts can be shortened further by keeping model weights on a pre-built EBS snapshot attached to new nodes (not configured in this YAML, which only defines a 200Gi gp3 data volume), and Karpenter's interruption handling drains a spot node as soon as the 2-minute notice arrives.

---

## 5b — Cloudflare DNS & Cache Rules (`cloudflare/`)

Uses the Cloudflare provider **v5** (`~> 5.0`, locked at 5.29.0).

- `cloudflare_dns_record.quote_api`: Proxied (`proxied = true`) CNAME for `${record_name}.${zone_name}` (default `quote-api.example.com`).
- `cloudflare_ruleset.quote_api_cache_rules` (`phase = "http_request_cache_settings"`):
  - **Rule 1:** Bypasses cache (`cache = false`) for `http.host eq "quote-api.example.com" and starts_with(http.request.uri.path, "/api/")`.
  - **Rule 2:** Caches static extensions (`js`, `css`, `png`, `webp`, `woff2`, etc.) with a 30-day Edge TTL and 7-day Browser TTL.
- `import` block: Declaratively adopts the pre-existing manual DNS record `cloudflare_dns_record.legacy_status_cname` into Terraform state (ID built from `zone_id` + `legacy_status_record_id`).
- **No hardcoded account values:** `cloudflare_api_token`, `zone_id`, `origin_alb_dns` and `legacy_status_record_id` have no defaults. Copy `terraform.tfvars.example` to `terraform.tfvars` (git-ignored) or export `TF_VAR_*`.
- Validated via `./scripts/50-validate-tf.sh` (`terraform fmt -check`, `terraform init -backend=false`, `terraform validate`; validation needs no variable values).

