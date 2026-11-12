# Part 2: GitOps deployment and spot/on-demand placement

| Path | What it is |
|---|---|
| `helm/microservice/` | The Helm chart (v1.1.0) with `values.yaml` defaults and the `values-quote-api.yaml` overlay |
| `argocd/application.yaml` | ArgoCD Application. `scripts/20-deploy.sh` sets `repoURL` and the image as Helm parameters when it applies it |
| `argocd/project.yaml` | Least-privilege AppProject: only namespace `quote-api`, only `Namespace` as cluster-scoped kind. Needed because ArgoCD core install has no `default` project |
| `descheduler/values.yaml` | Descheduler settings that restore an on-demand replica after HPA scale-in (see point 5 below) |

## The chart

The chart is one I wrote for earlier work and reused here, so the service only needs a small overlay with the values that differ from the defaults. What quote-api uses: HTTP probes on the named `http` port, requests/limits, non-root with a read-only root filesystem (plus an `emptyDir` at `/tmp`, since a read-only root still needs a writable temp dir), Service, Traefik Ingress, HPA (min 3, max 10, 60% CPU) and PDB (min 2 available). With the HPA enabled the chart does not render `spec.replicas`, so an ArgoCD sync never resets the replica count the HPA chose.

The chart also supports things this service does not use: TCP probes, extra `envFrom` sources, a Java `application.properties` ConfigMap (`runtime: java`), Stakater Reloader annotations and OpenShift Routes.

---

## Placement (spot preferred, at least one on-demand replica)

Our cluster has 4 worker nodes labeled by `troubleshoot/prepare.sh`:
- 2 nodes: `acme.io/capacity=spot`
- 1 node: `acme.io/capacity=on-demand`
- 1 node: `acme.io/node-type=gpu` + taint `nvidia.com/gpu=true:NoSchedule`

### How (`values-quote-api.yaml`)

1. **Exclude the GPU node and unlabeled nodes (`requiredDuringSchedulingIgnoredDuringExecution`)**
   - Requires `acme.io/capacity In [spot, on-demand]`, so `quote-api` cannot land on the GPU node even if its taint is removed.
2. **Prefer spot over on-demand (`preferredDuringSchedulingIgnoredDuringExecution`)**
   - Assigns weight `60` to `acme.io/capacity=spot` and weight `40` to `acme.io/capacity=on-demand`.
3. **Guarantee ≥1 On-Demand Replica (hard capacity spread, `maxSkew: 2`)**
   - Constraint 1 (`topologyKey: acme.io/capacity`, `maxSkew: 2`, `whenUnsatisfiable: DoNotSchedule`): the pod count of the `spot` and `on-demand` pools may differ by at most 2. With 3 replicas a `3/0` split (skew 3) is impossible, so **at least one replica is always scheduled on on-demand**. Spot still holds the majority (`2/1` at 3 pods, up to `6/4` at 10), which a `maxSkew: 1` rule would not allow (it forces `5/5`).
   - `nodeTaintsPolicy: Honor`: cordoned/drained nodes carry the `node.kubernetes.io/unschedulable` taint and are dropped from the domain count. When both spot nodes are reclaimed, the spot pool stops being a domain and pods land on on-demand instead of going `Pending`.
   - `matchLabelKeys: [pod-template-hash]`: the skew is evaluated per ReplicaSet, so the rule also holds for the new pods of a rolling update.
4. **Spread Across Nodes, softly (`kubernetes.io/hostname`, `maxSkew: 1`, `ScheduleAnyway`)**
   - Spreads the 3 initial replicas across the 3 eligible nodes (2 spot + 1 on-demand). Because it is soft, an evicted pod can always reschedule during `scripts/25-reclaim-drill.sh`.
5. **Scale-in is covered by the descheduler:** spread constraints are only enforced when a pod is *scheduled*. On an HPA scale-in (10 → 3) the ReplicaSet deletes pods from the most crowded node first, and in testing that removed every on-demand replica (3/3 left on spot). `scripts/20-deploy.sh` therefore installs the Kubernetes descheduler (`part-2-gitops/descheduler/values.yaml`, chart `0.37.0`, every 30 s, `RemovePodsViolatingTopologySpreadConstraint` limited to `quote-api` and to the hard constraint). It evicts one spot pod and the scheduler must place the replacement on on-demand. Measured recovery: about 30 s, with the PDB (`minAvailable: 2`) respected.
