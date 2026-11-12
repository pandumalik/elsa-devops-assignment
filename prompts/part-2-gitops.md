# Part 2: GitOps and spot/on-demand placement

Builds `part-2-gitops/` (Helm chart, ArgoCD Application and AppProject, descheduler values), `scripts/20-deploy.sh` and `scripts/25-reclaim-drill.sh`.

## Build prompt: Helm chart

```text
Use my existing `microservice` Helm chart from earlier work (part-2-gitops/helm/microservice)
instead of writing a new one, and keep service-specific settings in a small
values-quote-api.yaml overlay. The overlay should only contain what differs from the
chart defaults, because duplicated values drift.

The chart must have: HTTP probes on the named port `http`; requests and limits;
non-root, read-only root filesystem, all capabilities dropped (with an emptyDir at
/tmp, because a read-only root still needs a writable temp dir); Service and Traefik
Ingress; HPA with minReplicas 3 and a 60% CPU target; PDB with minAvailable 2.

When the HPA is enabled, do not render spec.replicas. Otherwise every ArgoCD sync
resets the replica count the HPA chose.
```

## Build prompt: placement policy

```text
Nodes: 2 spot, 1 on-demand, 1 GPU (tainted). Requirements: prefer spot, always keep at
least one replica on on-demand, and let pods reschedule when a spot node is drained.

- Required node affinity: acme.io/capacity In [spot, on-demand], so the app never
  lands on the GPU node even if its taint is removed.
- Preferred affinity: spot weight 60, on-demand 40 (cost).
- Hard topology spread on acme.io/capacity with maxSkew 2 and DoNotSchedule. With
  3 replicas a 3/0 split has skew 3, so at least one pod must go to on-demand; spot
  can still hold the majority (6/4 at 10 pods). maxSkew 1 would force 50/50.
- nodeTaintsPolicy: Honor on that constraint, so cordoned (drained) nodes stop
  counting as a domain. Without it, draining both spot nodes leaves pods Pending.
- matchLabelKeys: [pod-template-hash], so the rule also holds for the new pods of a
  rolling update.
- Soft (ScheduleAnyway) spread on kubernetes.io/hostname, so replicas spread across
  nodes but rescheduling is never blocked.
```

## Build prompt: deploy and drill scripts

```text
scripts/20-deploy.sh:
- Install ArgoCD core-install (lighter than the full install, and nothing here needs
  the UI or SSO), pinned to one version.
- Apply part-2-gitops/argocd/project.yaml first: core-install has no argocd-server,
  which is what normally creates the `default` project. Make it least-privilege:
  destination only namespace quote-api, cluster-scoped kind Namespace only.
- Sync from the GitHub repo when the local chart matches it (the reviewer's clean
  clone). If the local chart differs (unpushed changes), serve part-2-gitops/ from an
  in-cluster `git daemon` (git://). Use git daemon because ArgoCD's go-git client
  cannot read a static "dumb HTTP" server such as plain nginx.
- Pass the image built by 10-build-service.sh as Helm parameters in the Application,
  so a new build never requires editing files in Git.
- After sync, wait for the HPA's minReplicas to be ready (the Deployment starts at 1
  because spec.replicas is owned by the HPA), print placement and curl /api/quote
  through the ingress. Retry the curl on 404, because Traefik needs a few seconds to
  load a new route.
- Use long timeouts (10 min) for anything that pulls images, because on a fresh
  machine each node pulls the ArgoCD image itself (about 3 minutes measured).

scripts/25-reclaim-drill.sh:
- Drain one spot node in the background and curl /api/quote every second until the
  drain finishes, then a few more times. A fixed number of requests can finish before
  the drain evicts anything.
- Show placement before and during, uncordon in a trap so the cluster is always left
  usable, and fail if any request failed.
```

## Review prompt: does "always on on-demand" really hold?

```text
Test it instead of reasoning about it: run the load test (HPA 3 -> 10), wait for the
scale-in, then check placement. Result: all 3 pods ended up on spot. Spread rules are
only checked when a pod is scheduled; on scale-in the ReplicaSet deletes pods from the
most crowded node, which was the on-demand node with 4 pods.

Add the Kubernetes descheduler (pinned chart, every 30 s) with only
RemovePodsViolatingTopologySpreadConstraint, limited to namespace quote-api and to
DoNotSchedule constraints. Allow evicting pods with local storage, because quote-api's
/tmp emptyDir holds nothing. Then force all pods onto spot and confirm one moves back
to on-demand (measured: about 30 s), and drain both spot nodes and confirm nothing
stays Pending.
```
