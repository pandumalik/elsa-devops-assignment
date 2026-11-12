# Part 5: Karpenter and Cloudflare

Produces `part-5-iac/karpenter/gpu-nodepool.yaml`, `part-5-iac/cloudflare/*.tf`, `part-5-iac/README.md` and `scripts/50-validate-tf.sh`.

## Build prompt: Karpenter GPU NodePools (5a)

```text
Write Karpenter resources for a GPU inference workload on EKS using the current
stable API: karpenter.sh/v1 NodePool and karpenter.k8s.aws/v1 EC2NodeClass. Check the
fields against the v1 docs, because older v1beta1 fields are easy to mix in.

- One EC2NodeClass with a pinned Bottlerocket alias (not @latest, so a new AMI never
  rolls GPU nodes without a reviewed change) and a 200Gi gp3 data volume for
  model weights.
- Two NodePools on that class: spot with weight 80 and on-demand with weight 20.
  Karpenter tries the higher weight first and falls back when spot capacity is missing.
- Taint nvidia.com/gpu=true:NoSchedule so only GPU workloads land there.
- Instance families g5, g6, g6e and GPU count 1/2/4.
- consolidationPolicy WhenEmpty with a consolidateAfter delay, because consolidating
  underutilized nodes would evict inference pods in the middle of requests.
- CPU, memory and GPU limits per pool, to cap cost.

In the README, one paragraph on spot vs on-demand for inference: spot saves a lot on
GPUs, but loading a model takes minutes while spot gives a 2-minute warning, so
user-facing inference needs an on-demand baseline.
```

## Review prompt: label keys

```text
Well-known Karpenter labels are lowercase. The requirement key was written
karpenter.k8s.aws/instance-gpu-Count, which either fails validation or never matches.
Fix it to instance-gpu-count, and have 50-validate-tf.sh fail on any mixed-case
karpenter.sh / karpenter.k8s.aws key. Also remove instance-category ["g","p"]: the
family list already excludes all "p" types, so it only suggested p4d is possible.
```

## Build prompt: Cloudflare in Terraform (5b)

```text
Terraform with the Cloudflare provider v5 (current major; v4 is legacy):
- cloudflare_dns_record: proxied CNAME for quote-api.example.com.
- cloudflare_ruleset in http_request_cache_settings with two rules: bypass cache for
  paths starting with /api/ (dynamic responses), and cache static extensions with a
  30-day edge TTL and 7-day browser TTL.
- An import {} block adopting a manually created record, because adopting existing
  resources is a routine task for the team.
- No defaults for the API token, zone ID or origin, because defaults for secrets and
  account IDs end up committed. Provide terraform.tfvars.example and git-ignore *.tfvars.
- Build the import ID from variables (needs Terraform 1.6+).

scripts/50-validate-tf.sh: terraform fmt -check, init -backend=false, validate.
validate does not need variable values, so it runs without credentials. Commit the
lock file with hashes for linux, darwin and windows, so init gives the same provider
on every machine.
```
